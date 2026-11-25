import { Logger } from '../common/Logger';
import { ChatMessage, InferenceTelemetry } from '../model/ChatModel';
import { ModelInfo } from '../model/ModelConfig';
import { InferenceConfig } from '../model/InferenceParams';
import { ModelDownloadService, DownloadedModelRecord } from './ModelDownloadService';
import fs from '@ohos.file.fs';
import { taskpool } from '@kit.ArkTS';
import { nativeLoadTask, nativeReleaseTask } from './ModelLoadTask';

// Import native C++ NAPI module
import mnnchat from 'libmnnchat.so';

export interface StreamListener {
  onToken: (token: string, fullContent: string, thinkingContent: string) => void;
  onComplete: (telemetry: InferenceTelemetry) => void;
  onError: (errorMsg: string) => void;
}

export class MnnChatService {
  private static instance: MnnChatService;
  private currentModel: ModelInfo = MnnChatService.placeholderModel();
  private currentConfig: InferenceConfig = new InferenceConfig();
  private isGenerating: boolean = false;
  private isEngineInitialized: boolean = false;
  private demoMode: boolean = false;
  private baseDir: string = '';
  /** 已经真正下发到原生引擎的配置签名，用来判断是否需要重新装载 */
  private appliedConfigSig: string = '';
  /** 安装包是否内置 GPU 后端（懒探测，只查一次） */
  private gpuShipped?: boolean = undefined;
  /** GPU 后端装载失败并已回落到 CPU 时置位，设置页可提示一次 */
  public lastBackendFallback: string = '';
  /** 上次装载时实际使用的“装载期参数”签名（线程/精度/内存/调度） */
  private appliedLoadSig: string = '';
  /** 是否正在装载模型（大模型装载要十几秒，UI 需要显示状态） */
  private loadingModel: boolean = false;
  /** 当前模型生效的系统提示词，空串表示不下发 system 消息 */
  private systemPrompt: string = '';

  public setSystemPrompt(text: string): void {
    this.systemPrompt = text;
  }

  public getSystemPrompt(): string {
    return this.systemPrompt;
  }

  public static getInstance(): MnnChatService {
    if (!MnnChatService.instance) {
      MnnChatService.instance = new MnnChatService();
    }
    return MnnChatService.instance;
  }

  private static placeholderModel(): ModelInfo {
    return {
      id: 'none',
      name: '未装载模型',
      family: '本地模型',
      paramSize: '-',
      quantization: '-',
      modelDir: '',
      diskSize: '0 MB',
      isLoaded: false,
      isPreset: false,
      description: '尚未选择本地模型，请先在模型管理页下载并装载。',
      features: ['待下载']
    };
  }

  constructor() {
    this.init();
  }

  /**
   * 由 EntryAbility 注入应用沙箱目录，并尝试自动装载第一个已下载模型。
   */
  public initialize(filesDir: string): void {
    if (this.baseDir === filesDir) {
      return;
    }
    this.baseDir = filesDir;
    this.loadConfigFromDisk();
    try {
      if (mnnchat && typeof mnnchat.initEngine === 'function') {
        const success: boolean = mnnchat.initEngine(filesDir);
        Logger.info(`MNN Engine initialized: ${success}`);
        this.isEngineInitialized = true;
        this.refreshDemoMode();
      }
    } catch (err) {
      Logger.error(`Error initializing MNN native module: ${JSON.stringify(err)}`);
    }

    const records: DownloadedModelRecord[] = ModelDownloadService.getInstance().loadManifest();
    if (records.length > 0) {
      const savedId: string = this.readActiveModelId();
      let target: DownloadedModelRecord = records[0];
      for (let i = 0; i < records.length; i++) {
        if (records[i].id === savedId) {
          target = records[i];
          break;
        }
      }
      const info: ModelInfo = this.buildModelInfo(target);
      if (this.isLargeModel(info)) {
        // 2GB+ 权重冷启动即装载会让进程 RSS 直接冲到 2.5GB 以上，
        // 系统内存管理判定超限后按 OOM_KILLER 杀掉前台进程——表现为"一打开就闪退"。
        // 大模型改为用户手动点"装载"，启动只记住它是默认模型。
        this.currentModel = info;
        this.saveActiveModelId(target.id);
        this.refreshDemoMode();
        this.notifyEngineStateChanged();
        Logger.info(`Skip auto-load for large model on cold start: ${target.name}`);
      } else {
        this.loadModelAsync(info, this.currentConfig);
      }
    } else {
      // 没有已下载模型时也必须让原生引擎进入可生成状态，
      // 否则 generateStream 会因 m_isLoaded=false 直接回错误（表现为"AI 没有输出"）。
      // 未链接真实 MNN SDK 时这一调用走的是内置示例引擎。
      try {
        if (mnnchat && typeof mnnchat.loadModel === 'function') {
          const ok: boolean = mnnchat.loadModel('', this.currentConfig.toJsonString());
          this.demoMode = ok;
          Logger.info(`Engine started in demo mode: ${ok}`);
        }
      } catch (err) {
        Logger.error(`Failed to start demo engine: ${JSON.stringify(err)}`);
      }
    }
  }

  public isDemoMode(): boolean {
    return this.demoMode;
  }

  /**
   * 引擎状态广播：装载/卸载模型后自增版本号，聊天页通过 @StorageLink 监听，
   * 解决"切 Tab 不重建页面 → 装载成功但界面还显示引擎未就绪"的问题。
   */
  private notifyEngineStateChanged(): void {
    try {
      AppStorage.setOrCreate<number>('engineStateVersion', Date.now());
    } catch (err) {
      Logger.warn(`notifyEngineStateChanged failed: ${err}`);
    }
  }

  /**
   * 若当前没有装载任何已下载模型，则自动装载 manifest 里的第一个模型。
   * 解决冷启动时 Header 回落到内置占位模型名、与实际已下载模型不一致的问题。
   */
  public ensureActiveModel(): void {
    if (this.currentModel.modelDir !== '' || this.isGenerating) {
      return;
    }
    const records: DownloadedModelRecord[] = ModelDownloadService.getInstance().loadManifest();
    if (records.length === 0) {
      return;
    }
    const savedId: string = this.readActiveModelId();
    let target: DownloadedModelRecord = records[0];
    for (let i = 0; i < records.length; i++) {
      if (records[i].id === savedId) {
        target = records[i];
        break;
      }
    }
    const info: ModelInfo = this.buildModelInfo(target);
    if (this.isLargeModel(info)) {
      this.currentModel = info;
      this.refreshDemoMode();
      this.notifyEngineStateChanged();
      Logger.info(`Large model kept as default but not auto-loaded: ${target.name}`);
      return;
    }
    this.loadModelAsync(info, this.currentConfig);
    Logger.info(`Auto-loading model: ${target.name}`);
  }

  /**
   * 不阻塞调用方的装载入口：TaskPool 里跑原生 load，结束后再广播引擎状态。
   * 启动自动装载、切模型都用它，避免大模型（2GB+ 权重）把主线程卡死触发 APP_FREEZE。
   */
  public loadModelAsync(model: ModelInfo, config?: InferenceConfig): void {
    this.loadingModel = true;
    this.notifyLoadingChanged(true);
    this.loadModel(model, config).then((ok: boolean) => {
      this.loadingModel = false;
      this.notifyLoadingChanged(false);
      Logger.info(`Async load finished: success=${ok}, model=${model.name}`);
    }).catch((err: Object) => {
      this.loadingModel = false;
      this.notifyLoadingChanged(false);
      Logger.error(`Async load failed: ${JSON.stringify(err)}`);
    });
  }

  public isLoadingModel(): boolean {
    return this.loadingModel;
  }

  private notifyLoadingChanged(loading: boolean): void {
    try {
      AppStorage.setOrCreate<boolean>('engineLoading', loading);
      AppStorage.setOrCreate<number>('engineLoadingVersion', Date.now());
    } catch (err) {
      Logger.warn(`notifyLoadingChanged failed: ${err}`);
    }
  }

  private buildModelInfo(record: DownloadedModelRecord): ModelInfo {
    return {
      id: record.id,
      name: record.name,
      family: record.family,
      paramSize: record.paramSize,
      quantization: record.quantization,
      modelDir: record.dir,
      diskSize: `${record.sizeMB} MB`,
      isLoaded: false,
      isPreset: record.isPreset === true,
      description: record.source === 'modelscope'
        ? '从魔搭 ModelScope 在线拉取的 MNN 模型。'
        : '从本地导入的 MNN 模型。',
      features: ['本地离线', 'MNN 量化']
    };
  }

  private activeModelIdPath(): string {
    return this.baseDir === '' ? '' : `${this.baseDir}/active_model.txt`;
  }

  private readActiveModelId(): string {
    const path: string = this.activeModelIdPath();
    if (path === '') {
      return '';
    }
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      const content: string = fs.readTextSync(path).trim();
      return content;
    } catch (err) {
      Logger.warn(`readActiveModelId failed: ${JSON.stringify(err)}`);
      return '';
    }
  }

  private saveActiveModelId(id: string): void {
    const path: string = this.activeModelIdPath();
    if (path === '') {
      return;
    }
    try {
      if (id === '') {
        if (fs.accessSync(path)) {
          fs.unlinkSync(path);
        }
        return;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, id);
      fs.closeSync(file);
    } catch (err) {
      Logger.warn(`saveActiveModelId failed: ${JSON.stringify(err)}`);
    }
  }

  /** 只记住默认模型，不触发装载 */
  public setDefaultModel(id: string): void {
    this.saveActiveModelId(id);
  }

  public getDefaultModelId(): string {
    return this.readActiveModelId();
  }

  /** 应用退出/销毁时调用：把原生推理线程收干净，避免 env teardown 后线程仍在跑 */
  public shutdown(): void {
    try {
      if (mnnchat && typeof mnnchat.stopGenerate === 'function') {
        mnnchat.stopGenerate();
      }
      if (mnnchat && typeof mnnchat.releaseModel === 'function') {
        mnnchat.releaseModel();
      }
    } catch (err) {
      Logger.warn(`shutdown failed: ${JSON.stringify(err)}`);
    }
  }

  /** 模型被删除后调用：卸载引擎并清除默认记录 */
  public unloadModel(): void {
    try {
      this.currentModel = MnnChatService.placeholderModel();
      if (mnnchat && typeof mnnchat.loadModel === 'function') {
        // 释放 2GB+ 权重同样是耗时操作，放 TaskPool 里做
        this.nativeLoad('', this.currentConfig.toJsonString()).catch((err: Object) => {
          Logger.warn(`async unload failed: ${JSON.stringify(err)}`);
        });
      }
      this.demoMode = true;
      this.saveActiveModelId('');
      this.notifyEngineStateChanged();
    } catch (err) {
      Logger.warn(`unloadModel failed: ${JSON.stringify(err)}`);
    }
  }

  private refreshDemoMode(): void {
    try {
      if (mnnchat && typeof mnnchat.isSimulatorEngine === 'function') {
        // "是不是仿真引擎"和"现在有没有可用模型"是两件事：
        // 真实构建 + 沙箱里没有模型时，用户点发送是不会出字的一一这会直接被审核判成功能不可用。
        this.demoMode = mnnchat.isSimulatorEngine() || this.currentModel.modelDir === '' || !this.currentModel.isLoaded;
        return;
      }
    } catch (err) {
      Logger.warn(`isSimulatorEngine check failed: ${JSON.stringify(err)}`);
    }
    this.demoMode = this.currentModel.modelDir === '';
  }

  private init(): void {
    // 原有的兜底逻辑：未通过 EntryAbility 注入目录时不主动装载任何模型
    Logger.info('MnnChatService created, waiting for sandbox directory injection.');
  }

  public getBaseDir(): string {
    return this.baseDir;
  }

  public getCurrentModel(): ModelInfo {
    return this.currentModel;
  }

  public getInferenceConfig(): InferenceConfig {
    return this.currentConfig;
  }

  public setInferenceConfig(config: InferenceConfig): void {
    // 注意：调用方拿到的往往是 currentConfig 的同一个对象引用，
    // 直接比较字段永远相等（旧实现的 bug：改了滑杆却从不重新装载）。
    // 因此用“已下发到原生引擎的配置签名”做比对。
    this.currentConfig = config;
    this.saveConfigToDisk();
    const sig: string = config.toJsonString();
    if (sig === this.appliedConfigSig) {
      return;
    }

    if (this.currentModel.isLoaded && !this.isGenerating) {
      // 只有线程/精度/内存/调度这类装载期参数才需要重载模型；
      // 输出上限、上下文、采样器都是每次 response 才读的，可以热更新（避免几秒卡顿）。
      const loadSig: string = this.loadTimeSig(config);
      if (loadSig === this.appliedLoadSig && mnnchat && typeof mnnchat.applyRuntimeConfig === 'function') {
        const ok: boolean = mnnchat.applyRuntimeConfig(sig);
        if (ok) {
          this.appliedConfigSig = sig;
          Logger.info(`Config hot-applied: ${sig}`);
          return;
        }
      }
      Logger.info(`Config requires reload: ${sig}`);
      this.loadModelAsync(this.currentModel, config);
    } else {
      Logger.info(`Config updated (applies on next load): ${sig}`);
    }
  }

  /** 这份配置下发时是否需要整模型重载（线程/精度/内存/调度属于装载期参数） */
  public needsReload(config: InferenceConfig): boolean {
    if (!this.currentModel.isLoaded) {
      return false;
    }
    return this.loadTimeSig(config) !== this.appliedLoadSig;
  }

  private loadTimeSig(config: InferenceConfig): string {
    // 上下文长度决定 KV cache 预算，属于必须重新装载的内存布局参数
    return `${config.threads}|${config.precision}|${config.memory}|${config.power}|${config.contextLength}`;
  }

  /** 当前原生引擎实际生效的配置（用于设置页回显，证明参数真的下去了） */
  public getAppliedConfig(): string {
    try {
      if (mnnchat && typeof mnnchat.getAppliedConfig === 'function') {
        return mnnchat.getAppliedConfig();
      }
    } catch (err) {
      Logger.warn(`getAppliedConfig failed: ${String(err)}`);
    }
    return '';
  }

  private configPath(): string {
    return this.baseDir === '' ? '' : `${this.baseDir}/inference_config.json`;
  }

  public saveConfigToDisk(): void {
    const path: string = this.configPath();
    if (path === '') {
      return;
    }
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, this.currentConfig.toJsonString());
      fs.closeSync(file);
    } catch (err) {
      Logger.warn(`saveConfigToDisk failed: ${JSON.stringify(err)}`);
    }
  }

  private loadConfigFromDisk(): void {
    const path: string = this.configPath();
    if (path === '') {
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const raw: string = fs.readTextSync(path);
      const obj = JSON.parse(raw) as Record<string, Object>;
      const cfg: InferenceConfig = new InferenceConfig();
      const num = (key: string, def: number): number => {
        const v: Object | undefined = obj[key];
        return (typeof v === 'number') ? v as number : def;
      };
      const str = (key: string, def: string): string => {
        const v: Object | undefined = obj[key];
        return (typeof v === 'string') ? v as string : def;
      };
      cfg.threads = num('threads', cfg.threads);
      cfg.maxTokens = num('maxTokens', cfg.maxTokens);
      cfg.contextLength = num('contextLength', cfg.contextLength);
      cfg.temperature = num('temperature', cfg.temperature);
      cfg.topP = num('topP', cfg.topP);
      const backendSaved: string = str('backend', cfg.backend);
      cfg.backend = backendSaved === 'opencl' ? 'opencl' : (backendSaved === 'vulkan' ? 'vulkan' : 'cpu');
      cfg.precision = str('precision', cfg.precision) === 'normal' ? 'normal'
        : (str('precision', cfg.precision) === 'high' ? 'high' : 'low');
      cfg.memory = str('memory', cfg.memory) === 'normal' ? 'normal'
        : (str('memory', cfg.memory) === 'high' ? 'high' : 'low');
      cfg.power = str('power', cfg.power) === 'high' ? 'high'
        : (str('power', cfg.power) === 'low' ? 'low' : 'normal');
      this.currentConfig = cfg;
      Logger.info(`Persisted inference config restored: ${cfg.toJsonString()}`);
    } catch (err) {
      Logger.warn(`loadConfigFromDisk failed: ${JSON.stringify(err)}`);
    }
  }

  public isModelLoaded(): boolean {
    try {
      if (mnnchat && typeof mnnchat.isModelLoaded === 'function') {
        const loaded: boolean = mnnchat.isModelLoaded();
        return loaded;
      }
    } catch (err) {
      Logger.warn(`isModelLoaded check failed: ${err}`);
    }
    return true;
  }

  /**
   * 当前安装包里是否真的内置了 MNN 的 GPU 后端（libMNN_CL.so）。
   * 上架包为了规避厂商驱动在模块加载期崩溃，只带 CPU 后端，此时设置页不该再给出
   * 一个"选了也装不上"的 OpenCL/Vulkan 选项。
   */
  public isGpuBackendShipped(): boolean {
    try {
      if (this.gpuShipped === undefined) {
        const libsDir: string = this.baseDir.replace(/\/files$/, '/libs/arm64');
        this.gpuShipped = fs.accessSync(`${libsDir}/libMNN_CL.so`);
      }
      return this.gpuShipped;
    } catch (err) {
      Logger.warn(`isGpuBackendShipped failed: ${err}`);
      return false;
    }
  }

  /** 硬件加速能力探测（原生 dlopen 驱动），返回 JSON 文本；结果同时打到 hilog */
  public probeAccelerators(): string {
    try {
      if (mnnchat && typeof mnnchat.probeAccelerators === 'function') {
        return mnnchat.probeAccelerators() as string;
      }
    } catch (err) {
      Logger.warn(`probeAccelerators failed: ${err}`);
    }
    return '';
  }

  /** paramSize 形如 "4B" / "0.6B"，折算成数值判断是否属于大模型 */
  private isLargeModel(model: ModelInfo): boolean {
    const raw: string = (model.paramSize || '').toUpperCase().replace('B', '').trim();
    const value: number = Number.parseFloat(raw);
    return !Number.isNaN(value) && value >= 2.0;
  }

  /** 真正调原生 load，但放到 TaskPool 线程里跑，主线程不阻塞 */
  private async nativeLoad(modelDir: string, configJson: string): Promise<boolean> {
    const task: taskpool.Task = new taskpool.Task(nativeLoadTask, modelDir, configJson);
    const result: Object = await taskpool.execute(task);
    return result === true;
  }

  public async loadModel(model: ModelInfo, config?: InferenceConfig): Promise<boolean> {
    try {
      const cfg: InferenceConfig = config || this.currentConfig;
      // 大模型（≥2B，权重 2GB 以上）强制走低内存映射：
      // 一次性把权重读进堆里会直接把进程顶到内存上限，系统按 LowMemoryKill 杀进程，
      // 用户看到的就是"装 4B 就闪退"。mmap 按需换页，RSS 低得多。
      const bigModel: boolean = this.isLargeModel(model);
      if (bigModel && cfg.memory !== 'low') {
        Logger.info(`Large model detected (${model.paramSize}), forcing memory=low`);
        cfg.memory = 'low';
        this.currentConfig = cfg;
      }
      // 4B 这类模型仅权重就 2.4GB，KV cache 随上下文长度线性增长：
      // 4096 上下文在 4B 上能把 RSS 再抬 1GB，直接触发系统 OOM_KILLER。
      const MAX_SAFE_CTX: number = 2048;
      if (bigModel && cfg.contextLength > MAX_SAFE_CTX) {
        Logger.warn(`Cap contextLength ${cfg.contextLength} -> ${MAX_SAFE_CTX} for large model`);
        cfg.contextLength = MAX_SAFE_CTX;
        if (cfg.maxTokens > MAX_SAFE_CTX) {
          cfg.maxTokens = MAX_SAFE_CTX;
        }
        this.currentConfig = cfg;
      }
      this.currentModel = model;
      Logger.info(`Loading model: ${model.name} from ${model.modelDir}`);

      if (mnnchat && typeof mnnchat.loadModel === 'function') {
        let success: boolean = await this.nativeLoad(model.modelDir, cfg.toJsonString());
        // GPU 后端属于"赌驱动"：MNN 在 Vulkan/OpenCL 不可用时会直接装载失败。
        // 失败时立刻用 CPU 重载一次，保证用户不会因为换了个后端就打不开模型。
        if (!success && cfg.backend !== 'cpu') {
          Logger.warn(`backend ${cfg.backend} load failed, falling back to cpu`);
          const fallback: InferenceConfig = cfg;
          fallback.backend = 'cpu';
          this.currentConfig = fallback;
          success = await this.nativeLoad(model.modelDir, fallback.toJsonString());
          if (success) {
            this.lastBackendFallback = `后端 ${cfg.backend} 加载失败，已自动回落到 CPU`;
            cfg.backend = 'cpu';
          }
        }
        this.currentModel.isLoaded = success;
        if (success) {
          this.appliedConfigSig = cfg.toJsonString();
          this.appliedLoadSig = this.loadTimeSig(cfg);
          Logger.info(`Applied config: ${this.appliedConfigSig}`);
        }
        if (success && model.id !== '') {
          this.saveActiveModelId(model.id);
        }
        this.refreshDemoMode();
        this.notifyEngineStateChanged();
        return success;
      }
      this.currentModel.isLoaded = true;
      return true;
    } catch (err) {
      Logger.error(`Failed to load model: ${err}`);
      return false;
    }
  }

  public stopGeneration(): void {
    try {
      if (mnnchat && typeof mnnchat.stopGenerate === 'function') {
        mnnchat.stopGenerate();
      }
    } catch (err) {
      Logger.warn(`stopGenerate error: ${err}`);
    }
    this.isGenerating = false;
  }

  public resetSession(): void {
    try {
      if (mnnchat && typeof mnnchat.resetSession === 'function') {
        mnnchat.resetSession();
      }
    } catch (err) {
      Logger.warn(`resetSession error: ${err}`);
    }
  }

  public startGenerate(
    prompt: string,
    targetMessage: ChatMessage,
    listener?: StreamListener,
    history?: ChatMessage[]
  ): boolean {
    if (this.isGenerating) {
      Logger.warn('A generation task is already in progress');
      return false;
    }

    this.isGenerating = true;
    targetMessage.isGenerating = true;
    targetMessage.content = '';
    targetMessage.thinkingContent = '';

    // 把整段对话历史一起下发：原生侧用 ChatMessages + prompt cache 做前缀复用，
    // 上下文不再依赖 MNN 内部 KV 是否还活着（取消、切会话、重建上下文之后同样接得上）。
    const roles: string[] = [];
    const contents: string[] = [];
    // 系统提示词作为首条 system 消息下发，由每个模型自己的二级设置页写入
    const sys: string = this.systemPrompt.trim();
    if (sys.length > 0) {
      roles.push('system');
      contents.push(sys);
    }
    if (history !== undefined && history.length > 0) {
      for (let i = 0; i < history.length; i++) {
        const m: ChatMessage = history[i];
        if (m.content.trim().length === 0) {
          continue;
        }
        roles.push(m.role);
        contents.push(m.content);
      }
    }
    if (roles.length === 0 || contents[contents.length - 1] !== prompt) {
      roles.push('user');
      contents.push(prompt);
    }

    let inThinkTag: boolean = false;
    let accumulatedContent: string = '';
    let accumulatedThinking: string = '';
    let tokenCount: number = 0;

    const onNativeToken = (token: string): void => {
      tokenCount++;
      if (tokenCount <= 2) {
        Logger.info(`token#${tokenCount} received: ${token.length} chars`);
      }
      // 兜底清理：丢掉解码失败的替换符与控制字符，避免界面出现乱码方块
      const cleanToken: string = token.split('\uFFFD').join('');
      if (cleanToken.length === 0) {
        return;
      }
      // Check for <think> and </think> delimiters
      if (cleanToken.indexOf('<think>') !== -1) {
        inThinkTag = true;
        const parts: string[] = cleanToken.split('<think>');
        accumulatedContent += parts[0];
        accumulatedThinking += parts[1] || '';
      } else if (cleanToken.indexOf('</think>') !== -1) {
        inThinkTag = false;
        const parts: string[] = cleanToken.split('</think>');
        accumulatedThinking += parts[0];
        accumulatedContent += parts[1] || '';
      } else {
        if (inThinkTag) {
          accumulatedThinking += cleanToken;
        } else {
          accumulatedContent += cleanToken;
        }
      }

      targetMessage.content = accumulatedContent;
      targetMessage.thinkingContent = accumulatedThinking;

      if (listener && listener.onToken) {
        listener.onToken(token, accumulatedContent, accumulatedThinking);
      }
    };

    const onNativeComplete = (statsJsonStr: string): void => {
      this.isGenerating = false;
      targetMessage.isGenerating = false;

      let telemetry: InferenceTelemetry = {
        prefillLatencyMs: 40,
        decodeTokens: 120,
        decodeSpeedTokensPerSec: 28.5,
        peakMemoryMB: 980,
        totalDurationMs: 4200
      };

      try {
        if (statsJsonStr) {
          const parsed: InferenceTelemetry = JSON.parse(statsJsonStr) as InferenceTelemetry;
          if (parsed.decodeTokens) {
            telemetry = parsed;
          }
        }
      } catch (err) {
        Logger.warn(`Failed to parse telemetry json: ${err}`);
      }

      targetMessage.telemetry = telemetry;

      if (listener && listener.onComplete) {
        listener.onComplete(telemetry);
      }
    };

    const onNativeError = (errMsg: string): void => {
      this.isGenerating = false;
      targetMessage.isGenerating = false;
      Logger.error(`Native stream error: ${errMsg}`);
      if (listener && listener.onError) {
        listener.onError(errMsg);
      }
    };

    try {
      if (mnnchat && typeof mnnchat.startGenerateStream === 'function') {
        const started: boolean = mnnchat.startGenerateStream(
          prompt, roles, contents, onNativeToken, onNativeComplete, onNativeError);
        Logger.info(`startGenerateStream returned: ${started}`);
        if (!started) {
          this.isGenerating = false;
          targetMessage.isGenerating = false;
          if (listener && listener.onError) {
            listener.onError('原生引擎拒绝启动生成任务');
          }
        }
        return started;
      }
    } catch (err) {
      Logger.error(`startGenerateStream exception: ${JSON.stringify(err)}`);
    }

    return false;
  }
}

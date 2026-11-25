/**
 * 每个模型各自的运行参数与系统提示词。
 * 存成 ${filesDir}/model_settings.json，形如 { "<modelId>": {...} }，跟着模型走，
 * 换模型时各自恢复自己的配置，不会把 4B 的上下文上限带到 0.3B 上。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';

export const DEFAULT_SYSTEM_PROMPT: string = '你是 LocAI 的端侧助手。请用简体中文、简洁准确地回答，' +
  '不确定的内容要说明不确定，不要编造事实。';

export class ModelSettings {
  systemPrompt: string = DEFAULT_SYSTEM_PROMPT;
  maxTokens: number = 3072;
  contextLength: number = 4096;
  temperature: number = 0.7;
  topP: number = 0.9;
  sampler: string = 'greedy';
  threads: number = 4;
  precision: string = 'low';
  memory: string = 'low';
  power: string = 'high';
}

export class ModelSettingsService {
  private static instance: ModelSettingsService | null = null;
  private filesDir: string = '';
  private cache: Record<string, ModelSettings> = {};
  private loaded: boolean = false;

  public static getInstance(): ModelSettingsService {
    if (ModelSettingsService.instance === null) {
      ModelSettingsService.instance = new ModelSettingsService();
    }
    return ModelSettingsService.instance;
  }

  public init(filesDir: string): void {
    if (this.filesDir === filesDir && this.loaded) {
      return;
    }
    this.filesDir = filesDir;
    this.load();
  }

  private path(): string {
    return `${this.filesDir}/model_settings.json`;
  }

  private load(): void {
    if (this.filesDir === '' || this.loaded) {
      return;
    }
    try {
      if (fs.accessSync(this.path())) {
        const raw: string = fs.readTextSync(this.path());
        this.cache = JSON.parse(raw) as Record<string, ModelSettings>;
      }
      this.loaded = true;
    } catch (err) {
      Logger.warn(`model settings load failed: ${JSON.stringify(err)}`);
      this.cache = {};
      this.loaded = true;
    }
  }

  /** 取某个模型的配置，没有就返回一份默认值（不落盘，等用户保存） */
  public get(modelId: string): ModelSettings {
    this.load();
    const found: ModelSettings | undefined = this.cache[modelId];
    const settings: ModelSettings = new ModelSettings();
    if (found === undefined) {
      return settings;
    }
    settings.systemPrompt = found.systemPrompt !== undefined ? found.systemPrompt : DEFAULT_SYSTEM_PROMPT;
    settings.maxTokens = found.maxTokens !== undefined ? found.maxTokens : 3072;
    settings.contextLength = found.contextLength !== undefined ? found.contextLength : 4096;
    settings.temperature = found.temperature !== undefined ? found.temperature : 0.7;
    settings.topP = found.topP !== undefined ? found.topP : 0.9;
    settings.sampler = found.sampler !== undefined ? found.sampler : 'greedy';
    settings.threads = found.threads !== undefined ? found.threads : 4;
    settings.precision = found.precision !== undefined ? found.precision : 'low';
    settings.memory = found.memory !== undefined ? found.memory : 'low';
    settings.power = found.power !== undefined ? found.power : 'high';
    return settings;
  }

  public save(modelId: string, settings: ModelSettings): boolean {
    this.load();
    this.cache[modelId] = settings;
    try {
      if (this.filesDir === '') {
        return false;
      }
      const file: fs.File = fs.openSync(this.path(),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(this.cache));
      fs.closeSync(file);
      return true;
    } catch (err) {
      Logger.error(`model settings save failed: ${JSON.stringify(err)}`);
      return false;
    }
  }
}

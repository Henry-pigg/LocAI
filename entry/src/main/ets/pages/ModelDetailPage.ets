import { Constants } from '../common/Constants';
import { ModelInfo } from '../model/ModelConfig';
import { SettingChoice, SettingSlider } from '../components/SettingWidgets';
import { DEFAULT_SYSTEM_PROMPT, ModelSettings, ModelSettingsService } from '../service/ModelSettingsService';
import { MnnChatService } from '../service/MnnChatService';
import promptAction from '@ohos.promptAction';

/**
 * 模型二级设置页：从模型卡片进入，管理该模型专属的生成参数与系统提示词。
 * 配置按 modelId 分开存，不会互相污染。
 */
@Component
export struct ModelDetailView {
  @Prop model: ModelInfo;
  /** 状态栏高度（px）：窗口全屏后由 EntryAbility 写入，正文让开标题栏 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  onBack?: () => void;
  /** 标题栏里的“保存”由外层 Navigation 触发：外层递增该值，这里 @Watch 收到后执行保存 */
  @Prop @Watch('onSaveSignal') saveSignal: number = 0;
  /** 脏状态回传，行内标题栏据此切换保存按钮的视觉状态 */
  onDirtyChange?: (dirty: boolean) => void;
  onSaved?: () => void;

  @State maxTokens: number = 3072;
  @State contextLength: number = 4096;
  @State temperature: number = 0.7;
  @State topP: number = 0.9;
  @State threads: number = 4;
  @State samplerMode: string = 'greedy';
  @State precisionMode: string = 'low';
  @State memoryMode: string = 'low';
  @State powerMode: string = 'high';
  @State systemPrompt: string = DEFAULT_SYSTEM_PROMPT;
  @State appliedText: string = '尚未装载';
  @State dirty: boolean = false;
  /** 进入页面时的配置快照：改成和快照一致就自动回到「未修改」状态 */
  private originSig: string = '';

  aboutToAppear() {
    this.reload();
  }

  private onSaveSignal(): void {
    if (this.saveSignal > 0) {
      this.apply();
    }
  }

  /** 用一个可比较的签名判断是否真的改过，避免控件初始化回调让脏标记一进页面就亮起 */
  private signature(): string {
    const s: ModelSettings = this.current();
    return `${s.maxTokens}|${s.contextLength}|${s.temperature.toFixed(2)}|${s.topP.toFixed(2)}|` +
      `${s.threads}|${s.sampler}|${s.precision}|${s.memory}|${s.power}|${s.systemPrompt}`;
  }

  private markDirty(): void {
    const dirty: boolean = this.signature() !== this.originSig;
    if (dirty !== this.dirty) {
      this.dirty = dirty;
      if (this.onDirtyChange) {
        this.onDirtyChange(dirty);
      }
    }
  }

  private reload() {
    const s: ModelSettings = ModelSettingsService.getInstance().get(this.model.id);
    this.maxTokens = s.maxTokens;
    this.contextLength = s.contextLength;
    this.temperature = s.temperature;
    this.topP = s.topP;
    this.threads = s.threads;
    this.samplerMode = s.sampler;
    this.precisionMode = s.precision;
    this.memoryMode = s.memory;
    this.powerMode = s.power;
    this.systemPrompt = s.systemPrompt;
    this.refreshApplied();
    // 载入完成即作为基准快照
    this.originSig = this.signature();
    if (this.dirty) {
      this.dirty = false;
      if (this.onDirtyChange) {
        this.onDirtyChange(false);
      }
    }
  }

  private refreshApplied(): void {
    const raw: string = MnnChatService.getInstance().getAppliedConfig();
    if (raw === '') {
      this.appliedText = '尚未装载模型';
      return;
    }
    this.appliedText = `线程 ${this.pickNumber(raw, 'thread_num')} · 输出上限 ` +
      `${this.pickNumber(raw, 'max_new_tokens')} · 上下文 ${this.pickNumber(raw, 'max_all_tokens')}`;
  }

  private pickNumber(json: string, key: string): string {
    const token: string = `"${key}":`;
    const at: number = json.indexOf(token);
    if (at < 0) {
      return '-';
    }
    let i: number = at + token.length;
    let out: string = '';
    while (i < json.length) {
      const ch: string = json.charAt(i);
      if ((ch >= '0' && ch <= '9') || ch === '-') {
        out += ch;
      } else if (out.length > 0) {
        break;
      }
      i++;
    }
    return out === '' ? '-' : out;
  }

  private current(): ModelSettings {
    const s: ModelSettings = new ModelSettings();
    s.maxTokens = this.maxTokens;
    s.contextLength = this.contextLength;
    s.temperature = this.temperature;
    s.topP = this.topP;
    s.sampler = this.samplerMode;
    s.threads = this.threads;
    s.precision = this.precisionMode;
    s.memory = this.memoryMode;
    s.power = this.powerMode;
    s.systemPrompt = this.systemPrompt;
    return s;
  }

  /** 保存并下发：参数立即进引擎，系统提示词从下一条消息开始生效 */
  private apply(): void {
    const settings: ModelSettings = this.current();
    ModelSettingsService.getInstance().save(this.model.id, settings);

    const svc: MnnChatService = MnnChatService.getInstance();
    const cfg = svc.getInferenceConfig();
    cfg.maxTokens = settings.maxTokens;
    cfg.contextLength = settings.contextLength;
    cfg.temperature = settings.temperature;
    cfg.topP = settings.topP;
    cfg.sampler = settings.sampler === 'mixed' ? 'mixed' : 'greedy';
    cfg.threads = settings.threads;
    cfg.precision = settings.precision === 'normal' ? 'normal' : (settings.precision === 'high' ? 'high' : 'low');
    cfg.memory = settings.memory === 'normal' ? 'normal' : 'low';
    cfg.power = settings.power === 'high' ? 'high' : (settings.power === 'low' ? 'low' : 'normal');
    // 先算是否需要重载，再下发：setInferenceConfig 会刷新签名，之后再问永远是 false
    const needReload: boolean = svc.needsReload(cfg);
    svc.setInferenceConfig(cfg);
    svc.setSystemPrompt(settings.systemPrompt);

    this.dirty = false;
    this.originSig = this.signature();
    if (this.onDirtyChange) {
      this.onDirtyChange(false);
    }
    if (this.onSaved) {
      this.onSaved();
    }
    setTimeout(() => {
      this.refreshApplied();
    }, 400);
    promptAction.showToast({ message: needReload ? '已保存，下次装载生效' : '已保存并下发到引擎' });
  }

  private resetPrompt(): void {
    this.systemPrompt = DEFAULT_SYSTEM_PROMPT;
    this.markDirty();
    promptAction.showToast({ message: '已恢复默认提示词，记得保存' });
  }

  /** 卡片外的分组标题：小巧的灰字，跟卡片左内边对齐 */
  @Builder
  SectionHeader(title: string, note: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(13)
        .fontColor(Constants.COLOR_TEXT_TERTIARY)
      if (note) {
        Text(note)
          .fontSize(12)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
          .lineHeight(17)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 20, bottom: 8 })
  }

  @Builder
  CardDivider() {
    Divider()
      .strokeWidth(0.5)
      .color('#EDEEF0')
      .margin({ left: 16 })
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(Constants.FONT_BODY)
        .fontColor(Constants.COLOR_TEXT_PRIMARY)
      Blank()
      Text(value)
        .fontSize(Constants.FONT_CAPTION)
        .fontColor(Constants.COLOR_TEXT_SECONDARY)
        .constraintSize({ maxWidth: 220 })
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  private sizeLine(): string {
    const size: string = this.model.paramSize === '未知' || this.model.paramSize === ''
      ? this.model.quantization
      : `${this.model.paramSize} · ${this.model.quantization}`;
    return size;
  }

  build() {
    Column() {
      List() {
        ListItem() {
          this.SectionHeader('模型信息', '文件保存在应用私有目录，不联网')
        }
        ListItem() {
          Column() {
            this.InfoRow(this.model.paramSize === '未知' || this.model.paramSize === '' ? '量化' : '参数量 / 量化',
              this.sizeLine())
            this.CardDivider()
            this.InfoRow('占用空间', this.model.diskSize)
          }
          .width('100%')
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .clip(true)
        }

        ListItem() {
          this.SectionHeader('系统提示词', '决定模型的角色与回答风格，从下一条消息开始生效')
        }
        ListItem() {
          Column({ space: 8 }) {
            TextArea({ text: this.systemPrompt, placeholder: '例如：你是一名严谨的技术助手，回答控制在 200 字内' })
              .height(120)
              .fontSize(14)
              .fontColor(Constants.COLOR_TEXT_PRIMARY)
              .backgroundColor('#F5F6F8')
              .borderRadius(12)
              .padding(12)
              .maxLength(1000)
              .onChange((value: string) => {
                this.systemPrompt = value;
                this.markDirty();
              })
            Row() {
              Text(`${this.systemPrompt.length} / 1000`)
                .fontSize(12)
                .fontColor(Constants.COLOR_TEXT_TERTIARY)
              Blank()
              Text('恢复默认')
                .fontSize(Constants.FONT_CAPTION)
                .fontColor(Constants.COLOR_PRIMARY)
                .onClick(() => {
                  this.resetPrompt();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .clip(true)
        }

        ListItem() {
          this.SectionHeader('生成参数', '输出/采样即时生效；上下文、线程、精度、驻留改动后需重新装载')
        }
        ListItem() {
          Column() {
            SettingSlider({
              label: '最大输出长度',
              unit: ' tokens',
              value: this.maxTokens,
              minValue: 256,
              maxValue: 8192,
              stepValue: 256,
              decimals: 0,
              onLive: (v: number) => {
                this.maxTokens = Math.round(v);
                this.markDirty();
              },
              onEnd: () => {
              }
            })
            this.CardDivider()
            SettingSlider({
              label: '上下文长度',
              unit: ' tokens',
              value: this.contextLength,
              minValue: 512,
              maxValue: 16384,
              stepValue: 512,
              decimals: 0,
              onLive: (v: number) => {
                this.contextLength = Math.round(v);
                this.markDirty();
              },
              onEnd: () => {
              }
            })
            this.CardDivider()
            SettingSlider({
              label: 'Temperature',
              unit: '',
              value: this.temperature,
              minValue: 0.1,
              maxValue: 1.5,
              stepValue: 0.05,
              decimals: 2,
              onLive: (v: number) => {
                this.temperature = v;
                this.markDirty();
              },
              onEnd: () => {
              }
            })
            this.CardDivider()
            SettingSlider({
              label: 'Top-P',
              unit: '',
              value: this.topP,
              minValue: 0.1,
              maxValue: 1.0,
              stepValue: 0.05,
              decimals: 2,
              onLive: (v: number) => {
                this.topP = v;
                this.markDirty();
              },
              onEnd: () => {
              }
            })
            this.CardDivider()
            SettingChoice({
              label: '采样策略',
              current: this.samplerMode,
              choices: ['greedy', 'mixed'],
              labels: ['确定性', '多样性'],
              onPick: (v: string) => {
                this.samplerMode = v;
                this.markDirty();
              }
            })
          }
          .width('100%')
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .clip(true)
        }

        ListItem() {
          this.SectionHeader('性能', '线程数只影响解码速度，不改变输出质量')
        }
        ListItem() {
          Column() {
            SettingSlider({
              label: 'CPU 线程数',
              unit: ' 线程',
              value: this.threads,
              minValue: 1,
              maxValue: 8,
              stepValue: 1,
              decimals: 0,
              onLive: (v: number) => {
                this.threads = Math.round(v);
                this.markDirty();
              },
              onEnd: () => {
              }
            })
            this.CardDivider()
            SettingChoice({
              label: '权重量化精度',
              current: this.precisionMode,
              choices: ['low', 'normal', 'high'],
              labels: ['低', '标准', '高'],
              onPick: (v: string) => {
                this.precisionMode = v;
                this.markDirty();
              }
            })
            this.CardDivider()
            SettingChoice({
              label: '权重驻留',
              current: this.memoryMode,
              choices: ['low', 'normal'],
              labels: ['低内存', '展开'],
              onPick: (v: string) => {
                this.memoryMode = v;
                this.markDirty();
              }
            })
            this.CardDivider()
            SettingChoice({
              label: '调度策略',
              current: this.powerMode,
              choices: ['normal', 'high', 'low'],
              labels: ['均衡', '性能', '省电'],
              onPick: (v: string) => {
                this.powerMode = v;
                this.markDirty();
              }
            })
          }
          .width('100%')
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .clip(true)
        }

        ListItem() {
          this.SectionHeader('引擎', '数值来自原生层回报，不是界面推算')
        }
        ListItem() {
          Column() {
            this.InfoRow('实际生效', this.appliedText)
            this.CardDivider()
            this.InfoRow('推理后端', 'CPU (NEON) · 端侧单机推理，无 GPU 依赖')
          }
          .width('100%')
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .clip(true)
        }

        ListItem() {
          Button('保存并下发到该模型')
            .width('100%')
            .height(46)
            .fontSize(Constants.FONT_BODY)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(Constants.COLOR_PRIMARY)
            .borderRadius(14)
            .margin({ top: 16, bottom: 8 })
        .onClick(() => {
              this.apply();
            })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16, bottom: 24 })
      .contentStartOffset(64 + px2vp(this.statusBarPx))
              .clipContent(ContentClipMode.BOUNDARY)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Constants.COLOR_PAGE_BG)
  }
}

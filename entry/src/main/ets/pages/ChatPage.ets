import { Constants } from '../common/Constants';
import { ChatMessage } from '../model/ChatModel';
import { ModelInfo } from '../model/ModelConfig';
import { MnnChatService } from '../service/MnnChatService';
import { ChatSession, SessionService } from '../service/SessionService';
import { ChatHeader } from '../components/ChatHeader';
import { MessageBubble } from '../components/MessageBubble';
import { QuickPrompts } from '../components/QuickPrompts';
import { ChatInputBar } from '../components/ChatInputBar';
import { WatermarkService } from '../service/WatermarkService';
import { ModelSettingsService } from '../service/ModelSettingsService';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { LengthMetrics, UIContext } from '@kit.ArkUI';
import { Immersive } from '../common/Immersive';

@Component
export struct ChatPage {
  @State messageList: ChatMessage[] = [];
  @State inputText: string = '';
  @State isGenerating: boolean = false;
  @State currentModel: ModelInfo = MnnChatService.getInstance().getCurrentModel();
  @State isModelLoaded: boolean = MnnChatService.getInstance().isModelLoaded();
  @State isDemoMode: boolean = MnnChatService.getInstance().isDemoMode();
  @State showHistory: boolean = false;
  @State sessions: ChatSession[] = [];
  @State activeSessionId: string = '';
  // 引擎装载/卸载时由 MnnChatService 广播版本号：切 Tab 不会重建页面，
  // 光靠 aboutToAppear 刷新会出现"模型装载成功但界面仍显示引擎未就绪"。
  @StorageLink('engineStateVersion') @Watch('onEngineStateChanged') engineStateVersion: number = 0;
  /** 装载中状态：大模型权重放进 TaskPool 后台装载，头部显示"装载中…"而不是"引擎未就绪" */
  @StorageLink('engineLoading') @Watch('onEngineStateChanged') isLoadingModel: boolean = false;

  private scroller: Scroller = new Scroller();
  /** 流式输出时的自动滚动节流时间戳（毫秒） */
  private lastAutoScrollTs: number = 0;
  /** 状态栏高度（px）：窗口全屏后由 EntryAbility 写入，标题栏据此向内让位 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  /** 键盘高度（px）：只把输入区往上垫，整页和页签栏都不动 */
  @StorageProp('keyboardPx') keyboardPx: number = 0;
  /** 底部手势条高度（px） */
  @StorageProp('bottomBarPx') bottomBarPx: number = 0;
  onNavigateToModelManager?: () => void;
  onNavigateToSettings?: () => void;

  /** 标题栏总高：可视 60vp + 状态栏高度，模糊与渐变能铺到屏幕顶部 */
  private titleHeight(): number {
    return Immersive.TITLE_HEIGHT + px2vp(this.statusBarPx);
  }

  /**
   * 输入区需要上垫的高度：键盘高度减去页签栏（含手势条）高度。
   * 页签栏高度是页签栏白底到这里之间的那一段，键盘下面被盖住的部分正好是它。
   */
  private keyboardLift(): number {
    return Math.max(0, px2vp(this.keyboardPx) - (56 + px2vp(this.bottomBarPx)));
  }

  aboutToAppear() {
    this.reloadFromSession();
    // 隐式标识需要沙箱目录来落溯源清单，这里只初始化一次
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      WatermarkService.getInstance().init(ctx.filesDir);
      ModelSettingsService.getInstance().init(ctx.filesDir);
    } catch (e) {
      // 拿不到上下文时水印仍会打，只是不落清单
    }
    MnnChatService.getInstance().ensureActiveModel();
    this.refreshEngineState();
    // 通过 aa start --ps bench 1 触发的自动化基准，用于不接触界面地对比线程数
    const benchFlag: string = AppStorage.get<string>('benchMode') ?? '';
    if (benchFlag === '1') {
      setTimeout(() => {
        this.runBenchSuite();
      }, 5000);
    } else if (benchFlag === '2') {
      // 单次测速：用磁盘里的当前配置跑一条固定 prompt，便于外部脚本做矩阵对比
      setTimeout(() => {
        this.runBenchSingle();
      }, 5000);
    }
  }

  private wait(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
  }

  private async runBenchSingle(): Promise<void> {
    const svc: MnnChatService = MnnChatService.getInstance();
    const cfg = svc.getInferenceConfig();
    const label: string = `t${cfg.threads}/ctx${cfg.contextLength}/new${cfg.maxTokens}/${cfg.sampler}` +
      `/${cfg.precision}/${cfg.memory}/${cfg.power}`;
    const msg = new ChatMessage('assistant', '');
    msg.isGenerating = true;
    let tokens: number = 0;
    svc.startGenerate('用三句话介绍端侧大模型推理。', msg, {
      onToken: (token: string, full: string, thinking: string) => {
        tokens++;
        if (tokens > 80) {
          svc.stopGeneration();
        }
      },
      onComplete: (t) => {
        console.info(`[BENCH] ${label} tokPerSec=${t.decodeSpeedTokensPerSec}` +
          ` prefillMs=${t.prefillLatencyMs} tokens=${t.decodeTokens} memMB=${t.peakMemoryMB}`);
      },
      onError: (err) => {
        console.info(`[BENCH] ${label} error=${err}`);
      }
    });
  }

  private async runBenchSuite(): Promise<void> {
    const svc: MnnChatService = MnnChatService.getInstance();
    const model: ModelInfo = svc.getCurrentModel();
    if (!model || model.modelDir === '') {
      console.info('[BENCH] no model loaded, skip');
      return;
    }
    const labels: string[] = [
      'A t6/ctx16384/mixed', 'B t6/ctx4096/mixed', 'C t6/ctx4096/greedy',
      'D t4/ctx4096/greedy', 'E t8/ctx4096/greedy', 'F t6/ctx16384/greedy'
    ];
    const threadList: number[] = [6, 6, 6, 4, 8, 6];
    const ctxList: number[] = [16384, 4096, 4096, 4096, 4096, 16384];
    const samplerList: string[] = ['mixed', 'mixed', 'greedy', 'greedy', 'greedy', 'greedy'];
    for (let i = 0; i < labels.length; i++) {
      const label: string = labels[i];
      const cfg = svc.getInferenceConfig();
      cfg.threads = threadList[i];
      cfg.contextLength = ctxList[i];
      cfg.sampler = samplerList[i] === 'mixed' ? 'mixed' : 'greedy';
      svc.setInferenceConfig(cfg);
      await this.wait(6000);
      const msg = new ChatMessage('assistant', '');
      msg.isGenerating = true;
      let tokens: number = 0;
      svc.startGenerate('用三句话介绍端侧大模型推理。', msg, {
        onToken: (token: string, full: string, thinking: string) => {
          tokens++;
          if (tokens > 64) {
            svc.stopGeneration();
          }
        },
        onComplete: (t) => {
          console.info(`[BENCH] ${label} tokPerSec=${t.decodeSpeedTokensPerSec}` +
            ` prefillMs=${t.prefillLatencyMs} tokens=${t.decodeTokens} memMB=${t.peakMemoryMB}`);
        },
        onError: (err) => {
          console.info(`[BENCH] ${label} error=${err}`);
        }
      });
      await this.wait(14000);
    }
    console.info('[BENCH] suite finished');
  }

  public refreshEngineState() {
    this.currentModel = MnnChatService.getInstance().getCurrentModel();
    this.isModelLoaded = MnnChatService.getInstance().isModelLoaded();
    this.isDemoMode = MnnChatService.getInstance().isDemoMode();
    this.isLoadingModel = MnnChatService.getInstance().isLoadingModel();
  }

  /** 引擎状态广播回调：服务端装载/卸载模型后立即同步头部状态 */
  onEngineStateChanged() {
    this.refreshEngineState();
  }

  private scrollTimerPending: boolean = false;

  private scrollToBottom() {
    // 合并同一帧内的多次滚动请求，避免每个 chunk 都堆一个定时器
    if (this.scrollTimerPending) {
      return;
    }
    this.scrollTimerPending = true;
    setTimeout(() => {
      this.scrollTimerPending = false;
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
  }

  private handleSendMessage(query: string) {
    if (!query || this.isGenerating) {
      return;
    }
    if (!this.isModelLoaded) {
      promptAction.showToast({ message: '引擎尚未就绪，请到模型页重新装载' });
      return;
    }

    const userMsg = new ChatMessage('user', query);
    this.messageList.push(userMsg);
    SessionService.getInstance().addMessage(userMsg);

    const assistantMsg = new ChatMessage('assistant', '');
    assistantMsg.isGenerating = true;
    this.messageList.push(assistantMsg);
    SessionService.getInstance().addMessage(assistantMsg);

    this.isGenerating = true;
    this.scrollToBottom();

    // 系统提示词跟着模型走：每次发送前从该模型的二级设置里取一次
    const settings = ModelSettingsService.getInstance().get(this.currentModel.id);
    MnnChatService.getInstance().setSystemPrompt(settings.systemPrompt);

    MnnChatService.getInstance().startGenerate(
      query,
      assistantMsg,
      {
        onToken: (token: string, fullContent: string, thinkingContent: string) => {
          // ChatMessage 已 @Observed，MessageBubble 通过 @ObjectLink 自动跟随更新。
          // 滚动不能每个 token 都做：一次 scrollEdge 是整屏布局，几千 token 会把
          // UI 线程占满，进而拖慢流式观感。这里节流到 ~10fps，收尾再补一次。
          const now: number = Date.now();
          if (now - this.lastAutoScrollTs >= 100) {
            this.lastAutoScrollTs = now;
            this.scrollToBottom();
          }
        },
        onComplete: (telemetry) => {
          this.isGenerating = false;
          assistantMsg.isGenerating = false;
          this.finalizeAssistant(assistantMsg);
        },
        onError: (err) => {
          this.isGenerating = false;
          assistantMsg.isGenerating = false;
          assistantMsg.content = `推理失败：${err}`;
          SessionService.getInstance().commit();
          this.scrollToBottom();
        }
      },
      // 历史包含刚压入的这条用户消息，末尾的助手占位消息会被原生侧跳过（内容为空）
      // 送给模型前先剥掉上一轮回复里的隐式标识，避免零宽字符进入上下文
      this.plainHistory()
    );
  }

  /** 收尾：按附录 E 打隐式标识后再落盘，标识内的哈希计算是异步的 */
  private finalizeAssistant(msg: ChatMessage): void {
    WatermarkService.getInstance()
      .markText(msg.content, this.currentModel.name, '1.0.0')
      .then((marked: string) => {
        msg.content = marked;
        SessionService.getInstance().commit();
        this.scrollToBottom();
      })
      .catch(() => {
        SessionService.getInstance().commit();
        this.scrollToBottom();
      });
  }

  /**
   * 构造送给原生引擎的历史副本：剥掉水印，其余字段原样保留。
   * 直接用 messageList 会把不可见编码带进上下文，白占 token。
   */
  private plainHistory(): ChatMessage[] {
    const list: ChatMessage[] = [];
    for (let i = 0; i < this.messageList.length; i++) {
      const src: ChatMessage = this.messageList[i];
      const copy: ChatMessage = new ChatMessage(src.role, WatermarkService.getInstance().strip(src.content));
      copy.thinkingContent = src.thinkingContent;
      copy.timestamp = src.timestamp;
      list.push(copy);
    }
    return list;
  }

  private handleStopGenerate() {
    // 原生侧只置取消标志并立刻返回，界面不会被 join 卡住
    MnnChatService.getInstance().stopGeneration();
    this.isGenerating = false;
    // 给最后一条助手消息收尾，避免停止后光标一直闪
    if (this.messageList.length > 0) {
      const last: ChatMessage = this.messageList[this.messageList.length - 1];
      if (last.role === 'assistant') {
        last.isGenerating = false;
      }
    }
    SessionService.getInstance().commit();
  }

  private reloadFromSession(): void {
    const svc: SessionService = SessionService.getInstance();
    this.messageList = svc.getMessages().slice();
    this.activeSessionId = svc.getActiveId();
    this.sessions = svc.getSessions().slice();
  }

  private handleOpenHistory(): void {
    this.sessions = SessionService.getInstance().getSessions().slice();
    this.activeSessionId = SessionService.getInstance().getActiveId();
    this.showHistory = true;
  }

  private handleNewChat(): void {
    if (this.isGenerating) {
      MnnChatService.getInstance().stopGeneration();
      this.isGenerating = false;
    }
    SessionService.getInstance().newSession();
    // 换会话等于换上下文，原生 KV 缓存必须清掉
    MnnChatService.getInstance().resetSession();
    this.showHistory = false;
    this.reloadFromSession();
    this.scroller.scrollEdge(Edge.Top);
  }

  private handleSwitchSession(session: ChatSession): void {
    if (session.id === this.activeSessionId) {
      this.showHistory = false;
      return;
    }
    if (this.isGenerating) {
      MnnChatService.getInstance().stopGeneration();
      this.isGenerating = false;
    }
    SessionService.getInstance().switchSession(session.id);
    MnnChatService.getInstance().resetSession();
    this.showHistory = false;
    this.reloadFromSession();
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 80);
  }

  private handleDeleteSession(session: ChatSession): void {
    const ui: UIContext = this.getUIContext();
    ui.showAlertDialog({
      title: '删除对话',
      message: `「${session.title}」将被永久删除，确定继续？`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: '取消',
          action: () => {
          }
        },
        {
          value: '删除',
          fontColor: '#D93025',
          action: () => {
            SessionService.getInstance().deleteSession(session.id);
            if (session.id === this.activeSessionId) {
              MnnChatService.getInstance().resetSession();
              this.reloadFromSession();
            } else {
              this.sessions = SessionService.getInstance().getSessions().slice();
            }
          }
        }
      ],
      cancel: () => {
      }
    });
  }

  private formatTime(ts: number): string {
    const d: Date = new Date(ts);
    const pad = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  private handleClearChat() {
    SessionService.getInstance().clearMessages();
    this.messageList = SessionService.getInstance().getMessages().slice();
  }

  @Builder
  HistoryPanel() {
    Column() {
      Row() {
        Text('历史对话')
          .fontSize(Constants.FONT_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(Constants.COLOR_TEXT_PRIMARY)

        Blank()

        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor([Constants.COLOR_TEXT_SECONDARY])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .padding(10)
          .onClick(() => {
            this.showHistory = false;
          })
      }
      .width('100%')
      // 历史面板是整页覆盖，同样要让出状态栏高度，否则标题会顶到状态栏里
      .height(56 + px2vp(this.statusBarPx))
      .padding({ left: Constants.PAGE_PADDING, right: 12, top: px2vp(this.statusBarPx) })

      Divider()
        .color(Constants.COLOR_CARD_BORDER)

      List() {
        ForEach(this.sessions, (session: ChatSession) => {
          ListItem() {
            Row({ space: 8 }) {
              Column({ space: 4 }) {
                Text(session.title)
                  .fontSize(Constants.FONT_BODY)
                  .fontWeight(session.id === this.activeSessionId ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(Constants.COLOR_TEXT_PRIMARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(`${this.formatTime(session.updatedAt)} · ${Math.floor(session.messages.length / 2)} 轮`)
                  .fontSize(Constants.FONT_BADGE)
                  .fontColor(Constants.COLOR_TEXT_TERTIARY)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (session.id === this.activeSessionId) {
                Text('当前')
                  .fontSize(Constants.FONT_BADGE)
                  .fontColor(Constants.COLOR_PRIMARY)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .backgroundColor(Constants.COLOR_PRIMARY_LIGHT)
                  .borderRadius(6)
              }

              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(18)
                .fontColor([Constants.COLOR_TEXT_TERTIARY])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                .padding(11)
                .onClick(() => {
                  this.handleDeleteSession(session);
                })
            }
            .width('100%')
            .padding({ left: Constants.PAGE_PADDING, right: 12, top: 12, bottom: 12 })
            .onClick(() => {
              this.handleSwitchSession(session);
            })
          }
        }, (session: ChatSession) => session.id)
      }
      .layoutWeight(1)
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Constants.COLOR_PAGE_BG)
    .padding({ top: 0 })
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  @Builder
  EmptyState() {
    Column() {
      Blank()

      Text('LocAI')
        .fontSize(36)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(2)
        .fontColor(Constants.COLOR_TEXT_PRIMARY)

      Text('ON-DEVICE  AI')
        .fontSize(12)
        .letterSpacing(3)
        .fontColor(Constants.COLOR_TEXT_TERTIARY)
        .margin({ top: 10 })

      Text(this.isDemoMode ? '引擎以演示模式运行，回复由内置示例生成。' : '模型在设备本地完成推理，不产生云端请求。')
        .fontSize(Constants.FONT_CAPTION)
        .fontColor(Constants.COLOR_TEXT_TERTIARY)
        .textAlign(TextAlign.Center)
        .lineHeight(19)
        .margin({ top: 18 })
        .constraintSize({ maxWidth: 230 })

      Blank()
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    // 叠层标题栏浮在内容之上：空态整体下移一个栏高，避免大字被标题栏压住
    .padding({ top: this.titleHeight(), left: Constants.PAGE_PADDING, right: Constants.PAGE_PADDING })
  }

  /**
   * 叠层标题栏：标题栏浮在内容之上，正文滚到下面时由系统做渐进模糊（GRADUAL_BLUR），
   * 栏内控件自己挂 ULTRA_THIN 材质（材质只在导航标题栏范围内生效）。
   */
  @Builder
  ChatTitleBar() {
    Stack() {
      ChatHeader({
      currentModel: this.currentModel,
      isModelLoaded: this.isModelLoaded,
      isDemoMode: this.isDemoMode,
      isLoadingModel: this.isLoadingModel,
      onOpenModelManager: () => {
        if (this.onNavigateToModelManager) {
          this.onNavigateToModelManager();
        }
      },
      onOpenSettings: () => {
        if (this.onNavigateToSettings) {
          this.onNavigateToSettings();
        }
      },
      onOpenHistory: () => {
        this.handleOpenHistory();
      },
      onNewChat: () => {
        this.handleNewChat();
      }
    })
    }
    .width('100%')
    .height('100%')
    // 顶部让出状态栏高度，标题控件才落在状态栏下方；背板本身铺满整个标题栏
    .padding({ top: px2vp(this.statusBarPx) })
    // 标题栏背板：渐变蒙版，正文从下面穿过时配合系统渐进模糊
    .linearGradient({ angle: 180, colors: Immersive.TITLE_MASK_GRADIENT })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Navigation() {
        Column() {
          if (this.messageList.length === 0) {
            this.EmptyState()
          } else {
            List({ scroller: this.scroller }) {
              ForEach(this.messageList, (msg: ChatMessage) => {
                ListItem() {
                  MessageBubble({
                    message: msg,
                    onRegenerate: () => {
                      if (this.messageList.length >= 2) {
                        const lastUserMsg = this.messageList[this.messageList.length - 2];
                        if (lastUserMsg.role === 'user') {
                          this.handleSendMessage(lastUserMsg.content);
                        }
                      }
                    }
                  })
                }
              }, (msg: ChatMessage) => msg.id)
            }
            .layoutWeight(1)
            .width('100%')
            .edgeEffect(EdgeEffect.Spring)
            .scrollBar(BarState.Off)
            .backgroundColor(Constants.COLOR_PAGE_BG)
            // 首条气泡从标题栏下沿开始，往上滚时从标题栏底下穿过
            .contentStartOffset(this.titleHeight() + 8)
              .clipContent(ContentClipMode.BOUNDARY)
            .contentEndOffset(8)
          }

          if (this.messageList.length === 0 && !this.isGenerating) {
            QuickPrompts({
              onSelectPrompt: (prompt: string) => {
                this.handleSendMessage(prompt);
              }
            })
          }

          Column() {
            ChatInputBar({
              inputText: $inputText,
              isGenerating: this.isGenerating,
              onSend: (text: string) => {
                this.handleSendMessage(text);
              },
              onStop: () => {
                this.handleStopGenerate();
              }
            })

            // 交互界面显式标识：按《人工智能生成合成内容标识办法》第四条，
            // 在交互场景界面底部持续显示含“AI”“生成”要素的提示文字。
            Text('本应用对话内容由 AI 生成，仅供参考')
              .fontSize(12)
              .fontColor('#8A8F96')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 4, bottom: 6 })
          }
          .width('100%')
          // 键盘弹出时只抬这一块，页面与页签栏原地不动
          .padding({ bottom: this.keyboardLift() })
          .animation({ duration: 180, curve: Curve.EaseOut })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Constants.COLOR_PAGE_BG)
      }
      .hideBackButton(true)
      .hideToolBar(true)
      .title({ builder: this.ChatTitleBar, height: this.titleHeight() }, Immersive.titleOptions())
      .width('100%')
      .height('100%')
      .backgroundColor(Constants.COLOR_PAGE_BG)

      if (this.showHistory) {
        this.HistoryPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Constants.COLOR_PAGE_BG)
  }
}

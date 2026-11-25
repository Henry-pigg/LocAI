import { Constants } from '../common/Constants';
import { Immersive } from '../common/Immersive';
import { ModelInfo } from '../model/ModelConfig';

@Component
export struct ChatHeader {
  @Prop currentModel: ModelInfo;
  @Prop isModelLoaded: boolean = true;
  @Prop isDemoMode: boolean = false;
  /** 大模型权重装载中（TaskPool 后台跑，头部给个明确状态，别让用户以为卡死） */
  @Prop isLoadingModel: boolean = false;
  onOpenModelManager?: () => void;
  onOpenSettings?: () => void;
  onOpenHistory?: () => void;
  onNewChat?: () => void;

  private statusText(): string {
    if (this.isLoadingModel) {
      return '装载中…';
    }
    if (!this.isModelLoaded) {
      return '引擎未就绪';
    }
    return this.isDemoMode ? '演示模式' : '本地就绪';
  }

  private statusColor(): string {
    if (this.isLoadingModel) {
      return Constants.COLOR_WARNING;
    }
    if (!this.isModelLoaded) {
      return Constants.COLOR_ERROR;
    }
    return this.isDemoMode ? Constants.COLOR_WARNING : Constants.COLOR_SUCCESS;
  }

  private subtitleText(): string {
    if (this.isLoadingModel) {
      return '正在把权重映射进内存，大模型首次装载需要十几秒';
    }
    if (this.isDemoMode) {
      const name: string = this.currentModel && this.currentModel.name ? this.currentModel.name : '';
      if (name !== '') {
        return `${name} · 未接入推理库`;
      }
      return '内置示例引擎 · 未链接 MNN 权重';
    }
    // 标题放大后这一行横向就紧了，只留模型名。推理引擎之类的说明放到模型页/设置页
    return `${this.currentModel.name}`;
  }

  build() {
    Row() {
      Column({ space: 3 }) {
        Row({ space: 8 }) {
          // 字标
          Text('LocAI')
            .fontSize(Constants.FONT_CAPTION)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(0.8)
            .fontColor(Color.White)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Constants.COLOR_TEXT_PRIMARY)
            .borderRadius(6)

          Text('端侧对话')
            .fontSize(Constants.FONT_PAGE_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Constants.COLOR_TEXT_PRIMARY)
            .letterSpacing(0.2)
        }
        .alignItems(VerticalAlign.Center)

        Row({ space: 5 }) {
          Circle({ width: 5, height: 5 })
            .fill(this.statusColor())
          Text(this.statusText())
            .fontSize(Constants.FONT_CAPTION)
            .fontColor(Constants.COLOR_TEXT_TERTIARY)
          Text('·')
            .fontSize(Constants.FONT_CAPTION)
            .fontColor(Constants.COLOR_TEXT_TERTIARY)
          Text(this.subtitleText())
            .fontSize(Constants.FONT_CAPTION)
            .fontColor(Constants.COLOR_TEXT_TERTIARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .clip(true)
        .margin({ left: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 4 }) {
        // 历史会话：26+ 叠超薄材质；低版本退回透明圆钮（标题栏本身有渐变蒙版，层级不会丢）
        if (Immersive.isSupported()) {
          Button({ type: ButtonType.Circle, stateEffect: true, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(20)
              .fontColor([Constants.COLOR_TEXT_SECONDARY])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .systemMaterial(Immersive.titleMaterial())
          .onClick(() => {
            if (this.onOpenHistory) {
              this.onOpenHistory();
            }
          })
        } else {
          Button({ type: ButtonType.Circle, stateEffect: true, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(20)
              .fontColor([Constants.COLOR_TEXT_SECONDARY])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.onOpenHistory) {
              this.onOpenHistory();
            }
          })
        }

        // 新建对话
        if (Immersive.isSupported()) {
          Button({ type: ButtonType.Circle, stateEffect: true, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(20)
              .fontColor([Constants.COLOR_PRIMARY])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .systemMaterial(Immersive.titleMaterial())
          .onClick(() => {
            if (this.onNewChat) {
              this.onNewChat();
            }
          })
        } else {
          Button({ type: ButtonType.Circle, stateEffect: true, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(20)
              .fontColor([Constants.COLOR_PRIMARY])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.onNewChat) {
              this.onNewChat();
            }
          })
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding({ left: Constants.PAGE_PADDING, right: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.Transparent)
  }
}
import { Constants } from '../common/Constants';
import { common, Want } from '@kit.AbilityKit';
import promptAction from '@ohos.promptAction';
import { PrivacyConsentService } from '../service/PrivacyConsentService';

/** 完整隐私政策公网链接（飞书云文档，对外可阅读） */
const POLICY_URL: string = 'https://my.feishu.cn/docx/GqzfdGawDoPEY6xkvsucnmRqnJc';

/**
 * 首启隐私同意页：未同意前不进入主功能界面。
 * 两个按钮含义明确：「同意并继续」表示接受政策；「不同意并退出」退出应用。
 */
@Entry
@Component
export struct PrivacyConsentPage {
  /** 状态栏高度（px）：窗口全屏后由 EntryAbility 写入 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;

  private openPolicy(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: POLICY_URL
    };
    context.startAbility(want).catch((e: Error) => {
      promptAction.showToast({ message: '无法打开浏览器，请稍后重试' });
    });
  }

  private accept(): void {
    PrivacyConsentService.getInstance().grant();
  }

  private refuse(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    context.terminateSelf();
  }

  @Builder
  FactRow(text: string) {
    Row({ space: 10 }) {
      Row()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(Constants.COLOR_PRIMARY)
        .margin({ top: 8 })
      Text(text)
        .fontSize(Constants.FONT_SMALL)
        .fontColor(Constants.COLOR_TEXT_SECONDARY)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: Constants.SPACE_L }) {
          Text('隐私政策与个人信息保护说明')
            .fontSize(Constants.FONT_PAGE_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Constants.COLOR_TEXT_PRIMARY)
            .width('100%')

          Text('在使用 LocAI 前，请仔细阅读以下要点。完整条款以《LocAI 隐私政策》为准。')
            .fontSize(Constants.FONT_BODY)
            .fontColor(Constants.COLOR_TEXT_SECONDARY)
            .width('100%')

          Column({ space: 14 }) {
            this.FactRow('本应用为纯本地离线应用，对话推理全部在你的设备本机完成，不依赖网络，也不向任何服务器传输数据。')
            this.FactRow('不收集姓名、账号、设备标识符、位置信息、通讯录、相册、麦克风等个人信息，未集成统计、广告、推送等第三方 SDK。')
            this.FactRow('对话记录、模型文件与参数配置仅保存在应用私有目录，卸载应用时由系统一并清除。')
            this.FactRow('模型生成的回复会标注「内容由 AI 生成」，内容可能存在误差，不构成专业意见。')
          }
          .width('100%')
          .padding(Constants.SPACE_L)
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(Constants.RADIUS_L)

          Text('查看完整《LocAI 隐私政策》')
            .fontSize(Constants.FONT_SMALL)
            .fontColor(Constants.COLOR_PRIMARY)
            .onClick(() => {
              this.openPolicy();
            })
        }
        .width('100%')
        .padding({ left: Constants.PAGE_PADDING, right: Constants.PAGE_PADDING, bottom: Constants.SPACE_XL })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Column({ space: 12 }) {
        Button('同意并继续')
          .width('100%')
          .height(50)
          .fontSize(Constants.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(Constants.COLOR_PRIMARY)
          .fontColor(Color.White)
          .borderRadius(Constants.RADIUS_PILL)
          .onClick(() => {
            this.accept();
          })

        Text('不同意并退出')
          .fontSize(Constants.FONT_SMALL)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            this.refuse();
          })
      }
      .width('100%')
      .padding({ left: Constants.PAGE_PADDING, right: Constants.PAGE_PADDING, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Constants.COLOR_PAGE_BG)
    .padding({ top: px2vp(this.statusBarPx) + 8 })
  }
}

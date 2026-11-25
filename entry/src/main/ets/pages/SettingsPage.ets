import { Constants } from '../common/Constants';
import promptAction from '@ohos.promptAction';
import { LengthMetrics, UIContext } from '@kit.ArkUI';
import { Immersive } from '../common/Immersive';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const APP_NAME: string = 'LocAI';
const DOMAIN: number = 0x0001;
const TAG: string = 'SettingsPage';
const POLICY_URL: string = 'https://my.feishu.cn/docx/GqzfdGawDoPEY6xkvsucnmRqnJc';

/**
 * 设置页：只讲“这个应用是什么”。
 * 生成参数与系统提示词在模型卡片的二级设置页里，这里不再出现任何工程化字段。
 */
@Component
export struct SettingsPage {
  onBack?: () => void;
  /** 状态栏高度（px）：窗口全屏后由 EntryAbility 写入 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  /** 版本号不再写死，运行时从安装包信息里读，避免和 AppScope 里的 versionName 对不上 */
  @State appVersion: string = '';

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'read versionName failed: %{public}s', JSON.stringify(err));
    }
  }

  private titleHeight(): number {
    return Immersive.TITLE_HEIGHT + px2vp(this.statusBarPx);
  }

  private showLicenseDialog(): void {
    const ui: UIContext = this.getUIContext();
    ui.showAlertDialog({
      title: '开源协议 · Apache License 2.0',
      message: 'LocAI 基于阿里巴巴 MNN 开源推理引擎构建，MNN 及其 LLM 模块遵循 Apache License 2.0 发布。\n\n' +
        '你可以自由使用、修改和分发本应用及其衍生作品，需保留版权与许可声明；' +
        '原作者不对使用后果承担担保责任。完整条款见 apache.org/licenses/LICENSE-2.0。\n\n' +
        '模型文件由你自行导入，其版权与许可归对应模型发布方所有。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: '知道了',
          action: () => {
          }
        }
      ],
      cancel: () => {
      }
    });
  }

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

  private showModelPackagingDialog(): void {
    const ui: UIContext = this.getUIContext();
    ui.showAlertDialog({
      title: '模型文件要求',
      message: 'LocAI 只接受 MNN 格式的模型。把一个模型目录压成 .zip，再到「模型」页导入。\n\n' +
        '目录里需要四样东西：\n' +
        '· config.json —— 配置清单\n' +
        '· llm.mnn —— 网络结构\n' +
        '· llm.mnn.weight —— 权重\n' +
        '· tokenizer.mtok 或 tokenizer.txt —— 词表\n\n' +
        '压缩包允许套一层目录；不支持加密压缩包；GGUF、safetensors 和原始 HuggingFace 权重不能直接导入。\n\n' +
        '解压需要大约两倍压缩包大小的临时空间。0.3B 模型约 166 MB，0.6B 约 400 MB，4B 约 2.3 GB。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: '知道了',
          action: () => {
          }
        }
      ],
      cancel: () => {
      }
    });
  }

  @Builder
  SectionHeader(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(Constants.COLOR_TEXT_TERTIARY)
      .width('100%')
      .padding({ left: 16, right: 16, top: 22, bottom: 8 })
  }

  /** 标题 + 说明的两行式条目，避免做成键值对的工程面板 */
  @Builder
  InfoRow(title: string, desc: string) {
    Column({ space: 5 }) {
      Text(title)
        .fontSize(Constants.FONT_BODY)
        .fontColor(Constants.COLOR_TEXT_PRIMARY)
      Text(desc)
        .fontSize(Constants.FONT_CAPTION)
        .fontColor(Constants.COLOR_TEXT_TERTIARY)
        .lineHeight(19)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
  }

  @Builder
  LinkRow(title: string, desc: string, onTap: () => void) {
    Row() {
      Column({ space: 5 }) {
        Text(title)
          .fontSize(Constants.FONT_BODY)
          .fontColor(Constants.COLOR_TEXT_PRIMARY)
        Text(desc)
          .fontSize(Constants.FONT_CAPTION)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
          .lineHeight(19)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([Constants.COLOR_TEXT_TERTIARY])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  CardDivider() {
    Divider()
      .strokeWidth(0.5)
      .color('#EDEEF0')
      .margin({ left: 16 })
  }

  @Builder
  TitleBar() {
    Stack() {

      Row() {
        Text('设置')
          .fontSize(Constants.FONT_PAGE_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(Constants.COLOR_TEXT_PRIMARY)
        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    // 标题控件让到状态栏下方，背板渐变铺到屏幕顶部
    .padding({ top: px2vp(this.statusBarPx) })
    .linearGradient({ angle: 180, colors: Immersive.TITLE_MASK_GRADIENT })
  }

  build() {
    Stack() {
      Navigation() {
      List() {
        // 应用身份卡：单独一张圆角卡片，不跟下面的分组连成一条
        ListItem() {
          Row({ space: 14 }) {
            Image($r('app.media.app_icon'))
              .width(58)
              .height(58)
              .borderRadius(14)
              .objectFit(ImageFit.Cover)

            Column({ space: 4 }) {
              Text(APP_NAME)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(Constants.COLOR_TEXT_PRIMARY)
              Text('端侧对话 · 全程离线')
                .fontSize(Constants.FONT_CAPTION)
                .fontColor(Constants.COLOR_TEXT_SECONDARY)
              Text(this.appVersion.length > 0 ? `版本 ${this.appVersion}` : '版本')
                .fontSize(Constants.FONT_BADGE)
                .fontColor(Constants.COLOR_TEXT_TERTIARY)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(18)
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .margin({ top: 12 })
        }

        ListItem() {
          this.SectionHeader('关于')
        }

        ListItem() {
          Column() {
            this.InfoRow('应用来源',
              '基于阿里巴巴 MNN 开源推理引擎构建，所有计算都在本机完成，不经过任何服务器。')
            this.CardDivider()
            this.InfoRow('模型来源',
              '模型从魔搭 ModelScope 公开仓库在线拉取，或由你从本地导入；对话推理全程在设备端完成，不上传任何内容。')
            this.CardDivider()
            this.LinkRow('隐私政策', '个人信息收集与保护说明', () => {
              this.openPolicy();
            })
            this.CardDivider()
            this.LinkRow('开源协议', 'Apache License 2.0', () => {
              this.showLicenseDialog();
            })
          }
          .width('100%')
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .clip(true)
        }

        ListItem() {
          this.SectionHeader('AI 内容标识')
        }

        ListItem() {
          Column() {
            this.InfoRow('显式标识',
              '每条回复下方标注「内容由 AI 生成」，输入框下方常驻同一提示。')
            this.CardDivider()
            this.InfoRow('隐式标识',
              '回复末尾嵌入不易察觉的 AIGC 标识，并在本机留存溯源记录。')
            this.CardDivider()
            this.InfoRow('复制与分享',
              '复制出的文字会自动带上「内容由 AI 生成」标记。')
          }
          .width('100%')
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .clip(true)
        }

        ListItem() {
          this.SectionHeader('模型')
        }

        ListItem() {
          Column() {
            this.LinkRow('模型文件要求', '四个必备文件、支持的格式与体积参考', () => {
              this.showModelPackagingDialog();
            })
          }
          .width('100%')
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius(16)
          .clip(true)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16, bottom: 24 })
      .contentStartOffset(this.titleHeight())
              .clipContent(ContentClipMode.BOUNDARY)
    }
    .width('100%')
    .height('100%')
    .hideBackButton(true)
    .hideToolBar(true)
    .title({ builder: this.TitleBar, height: this.titleHeight() }, Immersive.titleOptions())
    .width('100%')
    .height('100%')
    .backgroundColor(Constants.COLOR_PAGE_BG)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Constants.COLOR_PAGE_BG)
  }
}
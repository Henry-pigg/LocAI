import { Constants } from '../common/Constants';
import { ONLINE_MODELS, OnlineModelSpec } from '../model/OnlineModels';
import { DownloadedModelRecord, ModelDownloadService } from '../service/ModelDownloadService';
import { Immersive } from '../common/Immersive';
import { common } from '@kit.AbilityKit';
import promptAction from '@ohos.promptAction';

/**
 * 在线模型库：从魔搭 ModelScope 拉取 MNN 5 件套模型。
 *
 * 一次只允许拉一个模型，进度直接画在对应卡片上；拉完立刻登记到本地清单，
 * 返回模型管理页就能装载对话。
 */
@Component
export struct OnlineModelView {
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  /** 正在拉取的模型 id，空串表示没有任务 */
  @State downloadingId: string = '';
  /** 当前任务百分比 0-100 */
  @State percent: number = 0;
  /** 已下载 / 总大小文案，例如 128.4 / 399.5 MB */
  @State sizeText: string = '';
  /** 实时速度文案，例如 3.2 MB/s */
  @State speedText: string = '';
  /** 已经在本地的在线模型 id 列表 */
  @State finishedIds: string[] = [];
  private lastBytes: number = 0;
  private lastAt: number = 0;
  onBack?: () => void;
  onModelReady?: (record: DownloadedModelRecord) => void;

  aboutToAppear(): void {
    this.refreshFinished();
  }

  private refreshFinished(): void {
    const ids: string[] = [];
    for (const record of ModelDownloadService.getInstance().loadManifest()) {
      ids.push(record.id);
    }
    this.finishedIds = ids;
  }

  private titleHeight(): number {
    return 64 + px2vp(this.statusBarPx);
  }

  private isFinished(id: string): boolean {
    return this.finishedIds.includes(id);
  }

  private async startDownload(item: OnlineModelSpec): Promise<void> {
    if (this.downloadingId !== '') {
      promptAction.showToast({ message: '已有模型正在拉取，等它完成再试' });
      return;
    }
    this.downloadingId = item.id;
    this.percent = 0;
    this.sizeText = `0 / ${item.sizeMB} MB`;
    this.speedText = '准备中…';
    this.lastBytes = 0;
    this.lastAt = Date.now();

    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const record: DownloadedModelRecord | null =
      await ModelDownloadService.getInstance().downloadOnlineModel(context, item,
        (received: number, total: number) => {
          const pct: number = total <= 0 ? 0 : Math.min(100, Math.round(received / total * 100));
          this.percent = pct;
          this.sizeText = `${(received / 1048576).toFixed(1)} / ${item.sizeMB} MB`;
          const now: number = Date.now();
          if (now - this.lastAt >= 800) {
            const delta: number = received - this.lastBytes;
            const seconds: number = (now - this.lastAt) / 1000;
            this.speedText = `下载中 · ${(delta / 1048576 / seconds).toFixed(1)} MB/s`;
            this.lastBytes = received;
            this.lastAt = now;
          }
        });

    this.downloadingId = '';
    this.percent = 0;
    this.speedText = '';
    if (record === null) {
      promptAction.showToast({ message: '拉取失败，检查网络后重试（模型来自魔搭 ModelScope）' });
      return;
    }
    this.refreshFinished();
    promptAction.showToast({ message: `${record.name} 已下载（${record.sizeMB} MB），返回后可装载` });
    if (this.onModelReady) {
      this.onModelReady(record);
    }
  }

  @Builder
  HeaderBar() {
    Row({ space: 8 }) {
      if (Immersive.isSupported()) {
        Button({ type: ButtonType.Circle, stateEffect: true, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([Constants.COLOR_TEXT_PRIMARY])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .systemMaterial(Immersive.titleMaterial())
        .onClick(() => {
          if (this.onBack) {
            this.onBack();
          }
        })
      } else {
        Button({ type: ButtonType.Circle, stateEffect: true, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([Constants.COLOR_TEXT_PRIMARY])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          if (this.onBack) {
            this.onBack();
          }
        })
      }

      Column({ space: 2 }) {
        Text('在线模型库')
          .fontSize(Constants.FONT_PAGE_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(Constants.COLOR_TEXT_PRIMARY)
        Text('从魔搭 ModelScope 拉取，下载后可离线对话')
          .fontSize(Constants.FONT_CAPTION)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 16, top: px2vp(this.statusBarPx) })
    .alignItems(VerticalAlign.Center)
    .linearGradient({ angle: 180, colors: Immersive.TITLE_MASK_GRADIENT })
  }

  @Builder
  ActionArea(item: OnlineModelSpec) {
    if (this.isFinished(item.id)) {
      Text('已下载')
        .fontSize(Constants.FONT_CAPTION)
        .fontColor(Constants.COLOR_SUCCESS)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor('#EAF5EC')
        .borderRadius(12)
    } else if (this.downloadingId === item.id) {
      Text(`${this.percent}%`)
        .fontSize(Constants.FONT_CAPTION)
        .fontColor(Constants.COLOR_PRIMARY)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Constants.COLOR_PRIMARY_LIGHT)
        .borderRadius(12)
    } else if (this.downloadingId !== '') {
      Text('等待中')
        .fontSize(Constants.FONT_CAPTION)
        .fontColor(Constants.COLOR_TEXT_TERTIARY)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor('#F0F2F5')
        .borderRadius(12)
    } else {
      Button('拉取')
        .fontSize(Constants.FONT_CAPTION)
        .height(32)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Constants.COLOR_PRIMARY)
        .fontColor(Color.White)
        .fontWeight(FontWeight.Medium)
        .onClick(() => {
          this.startDownload(item);
        })
    }
  }

  @Builder
  ModelCard(item: OnlineModelSpec) {
    Column() {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.square_stack_3d'))
            .fontSize(22)
            .fontColor(['#5B6472'])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(44)
        .height(44)
        .borderRadius(12)
        .backgroundColor('#F0F2F5')

        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(item.name)
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(Constants.COLOR_TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(item.badge)
              .fontSize(Constants.FONT_BADGE)
              .fontColor(Constants.COLOR_PRIMARY)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .backgroundColor(Constants.COLOR_PRIMARY_LIGHT)
              .borderRadius(9)
          }
          .width('100%')

          Text(`${item.family} · ${item.paramSize} · ${item.quantization} · ${item.sizeMB} MB`)
            .fontSize(Constants.FONT_CAPTION)
            .fontColor(Constants.COLOR_TEXT_TERTIARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        this.ActionArea(item)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      Text(item.summary)
        .fontSize(Constants.FONT_CAPTION)
        .fontColor(Constants.COLOR_TEXT_SECONDARY)
        .lineHeight(19)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 14 })

      if (this.downloadingId === item.id) {
        Column({ space: 6 }) {
          Progress({ value: this.percent, total: 100, type: ProgressType.Linear })
            .width('100%')
            .color(Constants.COLOR_PRIMARY)
            .backgroundColor('#EDEEF0')
          Row() {
            Text(this.sizeText)
              .fontSize(Constants.FONT_BADGE)
              .fontColor(Constants.COLOR_TEXT_TERTIARY)
            Blank()
            Text(this.speedText)
              .fontSize(Constants.FONT_BADGE)
              .fontColor(Constants.COLOR_TEXT_TERTIARY)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
      }
    }
    .width('100%')
    .backgroundColor(Constants.COLOR_CARD_BG)
    .borderRadius(16)
    .clip(true)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        List({ space: 12 }) {
          ListItem() {
            Text(`模型来自魔搭社区 MNN 组织公开仓库，下载文件的 SHA 与仓库一致；拉取后推理全程离线。`)
              .fontSize(Constants.FONT_CAPTION)
              .fontColor(Constants.COLOR_TEXT_TERTIARY)
              .lineHeight(19)
              .width('100%')
              .padding({ left: 4, right: 4, top: 4, bottom: 4 })
          }
          ForEach(ONLINE_MODELS, (item: OnlineModelSpec) => {
            ListItem() {
              this.ModelCard(item)
            }
          })
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
        .scrollBar(BarState.Off)
        .contentStartOffset(this.titleHeight() + 12)
        .clipContent(ContentClipMode.BOUNDARY)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Constants.COLOR_PAGE_BG)

      Column() {
        this.HeaderBar()
      }
      .width('100%')
      .height(this.titleHeight())
    }
    .width('100%')
    .height('100%')
  }
}

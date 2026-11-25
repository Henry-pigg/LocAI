import { Constants } from '../common/Constants';
import { ModelInfo } from '../model/ModelConfig';
import { MnnChatService } from '../service/MnnChatService';
import { ModelDownloadService, DownloadedModelRecord } from '../service/ModelDownloadService';
import { ModelSettingsService } from '../service/ModelSettingsService';
import { ModelDetailView } from './ModelDetailPage';
import { OnlineModelView } from './OnlineModelPage';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import promptAction from '@ohos.promptAction';
import { LengthMetrics, UIContext } from '@kit.ArkUI';
import { Immersive } from '../common/Immersive';

@Component
export struct ModelManagerPage {
  @State models: ModelInfo[] = [];
  @State activeModelId: string = MnnChatService.getInstance().getCurrentModel().id;
  @State defaultModelId: string = MnnChatService.getInstance().getDefaultModelId();
  @State isLoadingModel: boolean = false;
  @State importing: boolean = false;
  /** 在线模型库浮层是否展开 */
  @State showOnline: boolean = false;
  @State modelsDir: string = '';
  /** 状态栏高度（px）：窗口全屏后由 EntryAbility 写入 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  /** 二级设置页：走后者的 NavPathStack，二级页有官方 NavDestination 标题栏（自带材质与滚动模糊） */
  private pathStack: NavPathStack = new NavPathStack();

  private titleHeight(): number {
    return 64 + px2vp(this.statusBarPx);
  }
  @State detailModel: ModelInfo = MnnChatService.getInstance().getCurrentModel();
  @State detailDirty: boolean = false;
  /** 标题栏“保存”通过递增该值驱动二级页执行保存 */
  @State saveSignal: number = 0;
  private records: DownloadedModelRecord[] = [];
  onBack?: () => void;

  private openDetail(item: ModelInfo): void {
    this.detailModel = item;
    this.detailDirty = false;
    this.saveSignal = 0;
    this.pathStack.pushPathByName('modelDetail', null);
  }

  aboutToAppear() {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ModelDownloadService.getInstance().initialize(context);
    ModelSettingsService.getInstance().init(context.filesDir);
    this.modelsDir = ModelDownloadService.getInstance().getModelsDir();
    this.reloadModels();
  }

  private reloadModels() {
    const records: DownloadedModelRecord[] = ModelDownloadService.getInstance().loadManifest();
    this.records = records;
    const list: ModelInfo[] = [];
    const currentId: string = MnnChatService.getInstance().getCurrentModel().id;
    for (const record of records) {
      list.push({
        id: record.id,
        name: record.name,
        family: record.family,
        paramSize: record.paramSize,
        quantization: record.quantization,
        modelDir: record.dir,
        diskSize: `${record.sizeMB} MB`,
        isLoaded: currentId === record.id,
        isPreset: record.isPreset === true,
        description: record.source === 'local'
          ? `来源：${this.sourceLabel(record)} · 全程离线`
          : `来源：${this.sourceLabel(record)} · 仓库 ${record.repo}`,
        features: [record.paramSize, record.quantization, '本地离线']
      });
    }
    this.models = list;
    this.activeModelId = currentId;
    this.defaultModelId = MnnChatService.getInstance().getDefaultModelId();
  }

  private findRecord(id: string): DownloadedModelRecord | undefined {
    for (const r of this.records) {
      if (r.id === id) {
        return r;
      }
    }
    return undefined;
  }

  private setAsDefault(model: ModelInfo) {
    MnnChatService.getInstance().setDefaultModel(model.id);
    this.defaultModelId = model.id;
    promptAction.showToast({ message: `已将 ${model.name} 设为默认模型` });
  }

  private confirmDelete(model: ModelInfo) {
    const record: DownloadedModelRecord | undefined = this.findRecord(model.id);
    if (record === undefined) {
      promptAction.showToast({ message: '找不到该模型记录' });
      return;
    }
    if (record.isPreset === true) {
      promptAction.showToast({ message: '内置模型不可删除' });
      return;
    }
    const ui: UIContext = this.getUIContext();
    ui.showAlertDialog({
      title: '删除本地模型',
      message: `将删除 ${model.name} 的全部本地文件（${model.diskSize}），该操作不可恢复。`,
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
            const ok: boolean = ModelDownloadService.getInstance().deleteModel(record);
            const wasActive: boolean = this.activeModelId === model.id;
            if (wasActive) {
              MnnChatService.getInstance().unloadModel();
            }
            this.reloadModels();
            promptAction.showToast({ message: ok ? `${model.name} 已删除` : '删除失败，请检查文件占用' });
            if (wasActive && this.models.length > 0) {
              this.activateModel(this.models[0]);
            }
          }
        }
      ],
      cancel: () => {
      }
    });
  }

  private sourceLabel(record: DownloadedModelRecord): string {
    if (record.isPreset === true) {
      return '内置演示';
    }
    if (record.source === 'local') {
      return '本地导入';
    }
    if (record.source === 'modelscope') {
      return '魔搭 ModelScope';
    }
    if (record.source === 'hfmirror') {
      return 'HF-Mirror';
    }
    return 'HuggingFace';
  }

  private async activateModel(model: ModelInfo) {
    if (this.activeModelId === model.id) {
      promptAction.showToast({ message: '当前模型已在装载运行中' });
      return;
    }

    this.isLoadingModel = true;
    promptAction.showToast({ message: `正在装载 ${model.name}...` });

    const success = await MnnChatService.getInstance().loadModel(model);
    this.isLoadingModel = false;

    if (success) {
      this.activeModelId = model.id;
      this.reloadModels();
      promptAction.showToast({ message: `${model.name} 装载完成` });
    } else {
      promptAction.showToast({ message: '装载失败，请检查模型文件是否完整' });
    }
  }

  /** 从本地文件导入模型：用户自己把 MNN 模型目录压缩成 zip 选进来，全程不联网 */
  private async importFromLocal() {
    if (this.importing) {
      return;
    }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.zip'];
      const uris: string[] = await docPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      this.importing = true;
      promptAction.showToast({ message: '正在解压导入…' });
      const record: DownloadedModelRecord | null =
        await ModelDownloadService.getInstance().importLocalModel(context, uris[0]);
      this.importing = false;
      if (record === null) {
        promptAction.showToast({ message: '导入失败：压缩包内未找到 config.json' });
        return;
      }
      this.reloadModels();
      promptAction.showToast({ message: `${record.name} 已导入（${record.sizeMB} MB）` });
    } catch (err) {
      this.importing = false;
      promptAction.showToast({ message: '导入失败，请重试' });
    }
  }

  /** 一行讲完一个模型：参数量（认不出就跳过）、量化、体积、来源 */
  private metaLine(item: ModelInfo): string {
    const parts: string[] = [];
    if (item.paramSize && item.paramSize !== '未知') {
      parts.push(item.paramSize);
    }
    if (item.quantization) {
      parts.push(`${item.quantization} 量化`);
    }
    parts.push(item.diskSize);
    const record: DownloadedModelRecord | undefined = this.findRecord(item.id);
    parts.push(record ? this.sourceLabel(record) : '本地导入');
    return parts.join(' · ');
  }

  @Builder
  StatusPill(text: string, fg: ResourceColor, bg: ResourceColor) {
    Row({ space: 4 }) {
      Text(text)
        .fontSize(11)
        .fontColor(fg)
    }
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    .backgroundColor(bg)
    .borderRadius(11)
  }

  /** 返回二级页：改过参数还没保存时先问一句，避免静默丢弃 */
  private confirmLeaveDetail(): void {
    if (!this.detailDirty) {
      this.pathStack.pop();
      this.reloadModels();
      return;
    }
    const ui: UIContext = this.getUIContext();
    ui.showAlertDialog({
      title: '放弃未保存的修改？',
      message: `「${this.detailModel.name}」的设置改动还没有保存，直接返回会丢失这些修改。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: '继续编辑',
          action: () => {
          }
        },
        {
          value: '放弃修改',
          fontColor: '#D93025',
          action: () => {
            this.pathStack.pop();
            this.reloadModels();
          }
        }
      ],
      cancel: () => {
      }
    });
  }

  @Builder
  CardDivider() {
    Divider()
      .strokeWidth(0.5)
      .color('#EDEEF0')
      .margin({ left: 16 })
  }

  /** 叠层标题栏：标题与导入入口都在标题栏里，卡片从栏下沿开始 */
  @Builder
  TitleBar() {
    Stack() {

      Row() {
        Column({ space: 2 }) {
          Text('本地模型管理')
            .fontSize(Constants.FONT_PAGE_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(Constants.COLOR_TEXT_PRIMARY)

          Text(this.models.length === 0
            ? '在线拉取一个模型即可开始对话'
            : `共 ${this.models.length} 个模型 · 保存在应用私有目录`)
            .fontSize(Constants.FONT_CAPTION)
            .fontColor(Constants.COLOR_TEXT_TERTIARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 2 })
        .layoutWeight(1)

        Row({ space: 8 }) {
          Button('在线拉取')
            .fontSize(Constants.FONT_CAPTION)
            .height(38)
            .padding({ left: 14, right: 14 })
            .backgroundColor(Constants.COLOR_PRIMARY)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
            .onClick(() => {
              this.showOnline = true;
            })

          Button(this.importing ? '导入中' : '导入')
            .fontSize(Constants.FONT_CAPTION)
            .height(38)
            .padding({ left: 12, right: 12 })
            .backgroundColor(Constants.COLOR_PRIMARY_LIGHT)
            .fontColor(Constants.COLOR_PRIMARY)
            .fontWeight(FontWeight.Medium)
            .enabled(!this.importing)
            .onClick(() => {
              this.importFromLocal();
            })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .padding({ top: px2vp(this.statusBarPx) })
    .linearGradient({ angle: 180, colors: Immersive.TITLE_MASK_GRADIENT })
  }

  /** 二级页标题栏：返回圆钮自己挂超薄材质，保存按钮跟随脏状态 */
  @Builder
  DetailTitle() {
    Row({ space: 4 }) {
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
          this.confirmLeaveDetail();
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
          this.confirmLeaveDetail();
        })
      }

      Column({ space: 2 }) {
        Text('模型设置')
          .fontSize(Constants.FONT_PAGE_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(Constants.COLOR_TEXT_PRIMARY)
        Text(this.detailModel.name)
          .fontSize(Constants.FONT_CAPTION)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('保存')
        .fontSize(Constants.FONT_CAPTION)
        .height(38)
        .padding({ left: 18, right: 18 })
        .backgroundColor(this.detailDirty ? Constants.COLOR_PRIMARY : Constants.COLOR_PRIMARY_LIGHT)
        .fontColor(this.detailDirty ? Color.White : Constants.COLOR_PRIMARY)
        .fontWeight(FontWeight.Medium)
        .onClick(() => {
          this.saveSignal = this.saveSignal + 1;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 16, top: px2vp(this.statusBarPx) })
    .alignItems(VerticalAlign.Center)
    .linearGradient({ angle: 180, colors: Immersive.TITLE_MASK_GRADIENT })
  }

  /** 二级页路由：NavDestination 自带官方标题栏、返回手势与层级过渡 */
  @Builder
  DetailDest(name: string) {
    NavDestination() {
      ModelDetailView({
        model: this.detailModel,
        saveSignal: this.saveSignal,
        onDirtyChange: (dirty: boolean) => {
          this.detailDirty = dirty;
        },
        onSaved: () => {
          this.reloadModels();
        }
      })
    }
    .title({ builder: this.DetailTitle, height: this.titleHeight() }, Immersive.titleOptions())
    .hideBackButton(true)
    .backgroundColor(Constants.COLOR_PAGE_BG)
    .onBackPressed(() => {
      this.confirmLeaveDetail();
      return true;
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Navigation(this.pathStack) {
        Column() {
          if (this.models.length === 0) {
            // 空态
            Column({ space: 12 }) {
              Blank()
              Text('还没有本地模型')
                .fontSize(Constants.FONT_TITLE)
                .fontWeight(FontWeight.Medium)
                .fontColor(Constants.COLOR_TEXT_PRIMARY)
              Text('从魔搭 ModelScope 在线拉取一个 MNN 模型（推荐 Qwen3-0.6B），下载完成后即可完全离线对话；也可以把 MNN 模型目录打成 zip 从本地导入。')
                .fontSize(Constants.FONT_CAPTION)
                .fontColor(Constants.COLOR_TEXT_TERTIARY)
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
              Button('在线拉取模型')
                .fontSize(Constants.FONT_CAPTION)
                .height(40)
                .width(200)
                .backgroundColor(Constants.COLOR_PRIMARY)
                .onClick(() => {
                  this.showOnline = true;
                })
              Button(this.importing ? '导入中…' : '从本地导入 zip')
                .fontSize(Constants.FONT_CAPTION)
                .height(38)
                .width(200)
                .backgroundColor(Constants.COLOR_PRIMARY_LIGHT)
                .fontColor(Constants.COLOR_PRIMARY)
                .enabled(!this.importing)
                .onClick(() => {
                  this.importFromLocal();
                })
              Blank()
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            List({ space: 12 }) {
              ForEach(this.models, (item: ModelInfo) => {
                ListItem() {
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

                      Column({ space: 6 }) {
                        Row({ space: 8 }) {
                          Text(item.name)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(Constants.COLOR_TEXT_PRIMARY)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .layoutWeight(1)

                          if (this.activeModelId === item.id) {
                            this.StatusPill('运行中', Constants.COLOR_SUCCESS, '#EAF5EC')
                          } else if (this.defaultModelId === item.id) {
                            this.StatusPill('默认', Constants.COLOR_PRIMARY, Constants.COLOR_PRIMARY_LIGHT)
                          }
                        }
                        .width('100%')

                        Text(this.metaLine(item))
                          .fontSize(Constants.FONT_CAPTION)
                          .fontColor(Constants.COLOR_TEXT_TERTIARY)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 16, bottom: 14 })

                    this.CardDivider()

                    Row({ space: 20 }) {
                      Text('设置')
                        .fontSize(Constants.FONT_CAPTION)
                        .fontColor(Constants.COLOR_PRIMARY)
                        .onClick(() => {
                          this.openDetail(item);
                        })

                      if (this.defaultModelId !== item.id) {
                        Text('设为默认')
                          .fontSize(Constants.FONT_CAPTION)
                          .fontColor(Constants.COLOR_PRIMARY)
                          .onClick(() => {
                            this.setAsDefault(item);
                          })
                      }

                      Blank()

                      if (this.activeModelId !== item.id) {
                        Text('装载')
                          .fontSize(Constants.FONT_CAPTION)
                          .fontColor(Constants.COLOR_PRIMARY)
                          .fontWeight(FontWeight.Medium)
                          .onClick(() => {
                            this.activateModel(item);
                          })
                      }

                      if (!item.isPreset) {
                        Text('删除')
                          .fontSize(Constants.FONT_CAPTION)
                          .fontColor('#D93025')
                          .onClick(() => {
                            this.confirmDelete(item);
                          })
                      }
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 12, bottom: 14 })
                  }
                  .width('100%')
                  .backgroundColor(Constants.COLOR_CARD_BG)
                  .borderRadius(16)
                  .clip(true)
                  .onClick(() => {
                    this.openDetail(item);
                  })
                }
              })
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 16 })
            .scrollBar(BarState.Off)
            .contentStartOffset(this.titleHeight() + 16)
              .clipContent(ContentClipMode.BOUNDARY)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Constants.COLOR_PAGE_BG)
      }
      .hideBackButton(true)
      .hideToolBar(true)
      .title({ builder: this.TitleBar, height: this.titleHeight() }, Immersive.titleOptions())
      .width('100%')
      .height('100%')
      .backgroundColor(Constants.COLOR_PAGE_BG)
      .navDestination(this.DetailDest)
      }
      .width('100%')
      .height('100%')

      if (this.showOnline) {
        OnlineModelView({
          onBack: () => {
            this.showOnline = false;
          },
          onModelReady: (record: DownloadedModelRecord) => {
            this.reloadModels();
            promptAction.showToast({ message: `${record.name} 已就绪，点「装载」即可对话` });
          }
        })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
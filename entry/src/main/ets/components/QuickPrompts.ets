import { Constants } from '../common/Constants';

@Component
export struct QuickPrompts {
  onSelectPrompt?: (prompt: string) => void;

  private prompts: string[] = [
    '介绍 MNN 端侧推理的原理',
    '写一段 ArkUI 属性动画',
    '用 C++ 实现 LRU 缓存',
    '端侧模型比云端快在哪'
  ];

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.prompts, (item: string) => {
          Text(item)
            .fontSize(Constants.FONT_SMALL)
            .fontColor(Constants.COLOR_TEXT_SECONDARY)
            .padding({ left: 16, right: 16, top: 9, bottom: 9 })
            .backgroundColor(Color.Transparent)
            .border({ width: 0.5, color: '#DCE0E6' })
            .borderRadius(Constants.RADIUS_PILL)
            .onClick(() => {
              if (this.onSelectPrompt) {
                this.onSelectPrompt(item);
              }
            })
        }, (item: string) => item)
      }
      .padding({ left: Constants.PAGE_PADDING, right: Constants.PAGE_PADDING, top: 0, bottom: 10 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }
}

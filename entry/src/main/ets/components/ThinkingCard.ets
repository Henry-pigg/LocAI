import { Constants } from '../common/Constants';

@Component
export struct ThinkingCard {
  @Prop thinkingText: string = '';
  @Prop isGenerating: boolean = false;
  @State isExpanded: boolean = true;

  build() {
    Column() {
      Row() {
        Row({ space: 6 }) {
          Text(this.isGenerating ? '思考中' : '思考过程')
            .fontSize(Constants.FONT_BADGE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Constants.COLOR_TEXT_SECONDARY)

          if (this.isGenerating) {
            LoadingProgress()
              .width(12)
              .height(12)
              .color(Constants.COLOR_TEXT_TERTIARY)
          }
        }

        Blank()

        Row({ space: 2 }) {
          Text(this.isExpanded ? '收起' : '展开')
            .fontSize(Constants.FONT_BADGE)
            .fontColor(Constants.COLOR_TEXT_TERTIARY)
          Text(this.isExpanded ? '▲' : '▼')
            .fontSize(8)
            .fontColor(Constants.COLOR_TEXT_TERTIARY)
        }
        .onClick(() => {
          animateTo({ duration: 200, curve: Constants.CURVE_STANDARD }, () => {
            this.isExpanded = !this.isExpanded;
          });
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      if (this.isExpanded) {
        Divider()
          .color(Constants.COLOR_CARD_BORDER)
          .strokeWidth(0.5)

        Text(this.thinkingText)
          .fontSize(Constants.FONT_CAPTION)
          .fontColor(Constants.COLOR_TEXT_SECONDARY)
          .lineHeight(19)
          .padding({ left: 12, right: 12, top: 8, bottom: 10 })
          .width('100%')
      }
    }
    .width('100%')
    .backgroundColor('#F6F7F9')
    .borderRadius(Constants.RADIUS_M)
    .margin({ bottom: 10 })
  }
}

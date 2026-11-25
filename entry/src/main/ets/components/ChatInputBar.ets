import { Constants } from '../common/Constants';

@Component
export struct ChatInputBar {
  @Link inputText: string;
  @Prop isGenerating: boolean = false;
  onSend?: (text: string) => void;
  onStop?: () => void;

  build() {
    Column() {
      Row({ space: 8 }) {
        TextArea({
          text: this.inputText,
          placeholder: '问点什么…'
        })
          .layoutWeight(1)
          .constraintSize({ minHeight: 46, maxHeight: 116 })
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding({ left: 0, right: 0, top: 9, bottom: 9 })
          .fontSize(Constants.FONT_BODY)
          .fontColor(Constants.COLOR_TEXT_PRIMARY)
          .placeholderColor(Constants.COLOR_TEXT_TERTIARY)
          .onChange((val: string) => {
            this.inputText = val;
          })

        if (this.isGenerating) {
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            Text('■')
              .fontSize(12)
              .fontColor(Color.White)
          }
          .width(40)
          .height(40)
          .backgroundColor(Constants.COLOR_TEXT_PRIMARY)
          .margin({ bottom: 3 })
          .onClick(() => {
            if (this.onStop) {
              this.onStop();
            }
          })
        } else {
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            Text('↑')
              .fontSize(19)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
          }
          .width(40)
          .height(40)
          .backgroundColor(this.inputText.trim().length > 0 ? Constants.COLOR_PRIMARY : '#C9CFD8')
          .margin({ bottom: 3 })
          .enabled(this.inputText.trim().length > 0)
          .onClick(() => {
            const query = this.inputText.trim();
            if (query.length > 0 && this.onSend) {
              this.onSend(query);
              this.inputText = '';
            }
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 16, right: 6, top: 4, bottom: 4 })
      .backgroundColor(Constants.COLOR_CARD_BG)
      .borderRadius(26)
      .border({ width: 0.5, color: Constants.COLOR_CARD_BORDER })
      .shadow({ radius: 12, color: '#0D121826', offsetY: 2 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(Constants.COLOR_PAGE_BG)
  }
}

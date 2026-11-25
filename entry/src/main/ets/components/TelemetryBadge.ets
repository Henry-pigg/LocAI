import { InferenceTelemetry } from '../model/ChatModel';
import { Constants } from '../common/Constants';

@Component
export struct TelemetryBadge {
  @Prop telemetry: InferenceTelemetry | undefined;

  build() {
    if (this.telemetry) {
      Row({ space: 6 }) {
        Text(`${this.telemetry.decodeSpeedTokensPerSec.toFixed(1)} tok/s`)
          .fontSize(Constants.FONT_BADGE)
          .fontColor(Constants.COLOR_TEXT_SECONDARY)
        Text('·')
          .fontSize(Constants.FONT_BADGE)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
        Text(`首字 ${this.telemetry.prefillLatencyMs.toFixed(0)}ms`)
          .fontSize(Constants.FONT_BADGE)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
        Text('·')
          .fontSize(Constants.FONT_BADGE)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
        Text(`${this.telemetry.decodeTokens} tokens`)
          .fontSize(Constants.FONT_BADGE)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
        Text('·')
          .fontSize(Constants.FONT_BADGE)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
        Text(`${this.telemetry.peakMemoryMB.toFixed(0)}MB`)
          .fontSize(Constants.FONT_BADGE)
          .fontColor(Constants.COLOR_TEXT_TERTIARY)
      }
      .margin({ top: 10 })
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor('#F6F7F9')
      .borderRadius(6)
    }
  }
}

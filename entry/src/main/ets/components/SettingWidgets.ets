import { Constants } from '../common/Constants';

/**
 * 单行滑杆。必须做成独立 @Component 并走 @Prop，而不是 @Builder：
 * @Builder 里的 Slider 不会随父状态重建（表现为“拖到右边又弹回去、数字不变”）。
 */
@Component
export struct SettingSlider {
  @Prop label: string = '';
  @Prop unit: string = '';
  @Prop value: number = 0;
  @Prop minValue: number = 0;
  @Prop maxValue: number = 1;
  @Prop stepValue: number = 1;
  @Prop decimals: number = 0;
  onLive: (v: number) => void = () => {};
  onEnd: (v: number) => void = () => {};

  private display(): string {
    if (this.decimals > 0) {
      return this.value.toFixed(this.decimals);
    }
    return `${Math.round(this.value)}${this.unit}`;
  }

  build() {
    Column({ space: 4 }) {
      Row() {
        Text(this.label)
          .fontSize(Constants.FONT_BODY)
          .fontColor(Constants.COLOR_TEXT_PRIMARY)
        Blank()
        Text(this.display())
          .fontSize(Constants.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(Constants.COLOR_PRIMARY)
      }
      .width('100%')

      Slider({ value: this.value, min: this.minValue, max: this.maxValue, step: this.stepValue,
        style: SliderStyle.InSet })
        .blockColor(Constants.COLOR_PRIMARY)
        .trackColor('#E8EAED')
        .selectedColor(Constants.COLOR_PRIMARY)
        .onChange((v: number, mode: SliderChangeMode) => {
          this.onLive(v);
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.onEnd(v);
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }
}

/** 单行多选一（分段按钮） */
@Component
export struct SettingChoice {
  @Prop label: string = '';
  @Prop current: string = '';
  @Prop choices: string[] = [];
  @Prop labels: string[] = [];
  onPick: (v: string) => void = () => {};

  build() {
    Row() {
      Text(this.label)
        .fontSize(Constants.FONT_BODY)
        .fontColor(Constants.COLOR_TEXT_PRIMARY)
      Blank()
      Row({ space: 6 }) {
        ForEach(this.choices, (c: string, idx: number) => {
          Button(this.labels[idx])
            .height(30)
            .fontSize(Constants.FONT_CAPTION)
            .backgroundColor(this.current === c ? Constants.COLOR_PRIMARY : '#F2F3F5')
            .fontColor(this.current === c ? Color.White : Constants.COLOR_TEXT_SECONDARY)
            .onClick(() => {
              this.onPick(c);
            })
        }, (c: string) => c)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }
}

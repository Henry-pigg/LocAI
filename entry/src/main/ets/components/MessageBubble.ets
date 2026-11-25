import { ChatMessage } from '../model/ChatModel';
import { Constants } from '../common/Constants';
import { ThinkingCard } from './ThinkingCard';
import { MarkdownView } from './MarkdownView';
import { TelemetryBadge } from './TelemetryBadge';
import { WatermarkService } from '../service/WatermarkService';
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';

@Component
export struct MessageBubble {
  @ObjectLink message: ChatMessage;
  onRegenerate?: () => void;

  build() {
    Row() {
      if (this.message.role === 'assistant') {
        // 极简字标头像，避免彩色圆形贴纸感
        Text('M')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .letterSpacing(0.8)
          .fontColor(Constants.COLOR_TEXT_SECONDARY)
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .backgroundColor('#EDEFF3')
          .borderRadius(8)
          .margin({ right: 10, top: 2 })

        Column() {
          if (this.message.thinkingContent) {
            ThinkingCard({
              thinkingText: this.message.thinkingContent,
              isGenerating: this.message.isGenerating
            })
          }

          // 生成中也走 Markdown 渲染：标题/列表/公式即时成形，不再先出原始符号
          MarkdownView({
            rawText: this.message.content,
            isGenerating: this.message.isGenerating
          })

          if (this.message.telemetry && !this.message.isGenerating) {
            TelemetryBadge({ telemetry: this.message.telemetry })
          }

          if (!this.message.isGenerating && this.message.content) {
            Row({ space: 14 }) {
              // 生成式 AI 显式标识：每条回复常驻；字号/颜色按“清晰可辨”要求加深
              Text('内容由 AI 生成')
                .fontSize(Constants.FONT_BADGE + 1)
                .fontColor('#6B7078')

              Text('复制')
                .fontSize(Constants.FONT_BADGE)
                .fontColor(Constants.COLOR_TEXT_TERTIARY)
                .onClick(() => {
                  // 复制属于“复制功能”场景：剥掉文末的隐式水印（避免看不见的字符），
                  // 同时按办法第四条要求，在文本起始位置补上可见的“AI 生成”标识。
                  const plain: string = WatermarkService.getInstance().strip(this.message.content);
                  const withLabel: string = `（内容由 AI 生成）\n${plain}`;
                  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, withLabel);
                  pasteboard.getSystemPasteboard().setData(data).then(() => {
                    promptAction.showToast({ message: '已复制到剪贴板' });
                  }).catch((err: Error) => {
                    promptAction.showToast({ message: `复制失败：${err.message}` });
                  });
                })

              if (this.onRegenerate) {
                Text('重新生成')
                  .fontSize(Constants.FONT_BADGE)
                  .fontColor(Constants.COLOR_TEXT_TERTIARY)
                  .onClick(() => {
                    if (this.onRegenerate) {
                      this.onRegenerate();
                    }
                  })
              }
            }
            .margin({ top: 10 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ right: 12 })

      } else {
        Blank()

        Text(this.message.content)
          .fontSize(Constants.FONT_BODY)
          .fontColor(Color.White)
          .lineHeight(25)
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor(Constants.COLOR_USER_BUBBLE)
          .borderRadius({
            topLeft: 18,
            topRight: 6,
            bottomLeft: 18,
            bottomRight: 18
          })
          .constraintSize({ maxWidth: '78%' })
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .justifyContent(this.message.role === 'user' ? FlexAlign.End : FlexAlign.Start)
    .alignItems(VerticalAlign.Top)
    .padding({ left: Constants.PAGE_PADDING, right: Constants.PAGE_PADDING, top: 10, bottom: 10 })
  }
}

import { webview } from '@kit.ArkWeb';
import { Constants } from '../common/Constants';

/**
 * 用内置 KaTeX（rawfile 离线资源）真正排版一条块级公式。
 * 原生 Text 只能做 Unicode 近似，分数/根号/矩阵/boxed 这些必须交给排版引擎。
 * 若 Web 加载失败，回退到纯文本显示，保证不会“公式消失”。
 */
@Component
export struct MathBlock {
  latex: string = '';
  fallback: string = '';
  @State private heightVp: number = 46;
  @State private failed: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private rendered: boolean = false;

  private render(): void {
    if (this.rendered) {
      return;
    }
    this.rendered = true;
    const payload: string = JSON.stringify(this.latex);
    this.controller.runJavaScript(`render(${payload})`, (err, result: string) => {
      if (err) {
        this.failed = true;
        return;
      }
      const h: number = Number(result);
      if (!isNaN(h) && h > 0) {
        // Web 的 CSS px 与 ArkUI vp 基本 1:1，留 4vp 呼吸空间
        this.heightVp = Math.max(36, Math.round(h) + 6);
      }
    });
  }

  build() {
    if (this.failed) {
      Text(this.fallback)
        .fontSize(15)
        .fontFamily('monospace')
        .fontColor(Constants.COLOR_TEXT_PRIMARY)
        .lineHeight(26)
        .width('100%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .backgroundColor(Color.Transparent)
    } else {
      Web({ src: $rawfile('katex/index.html'), controller: this.controller })
        .width('100%')
        .height(this.heightVp)
        .backgroundColor(Color.Transparent)
        .domStorageAccess(false)
        .onPageEnd(() => {
          this.render();
        })
        .onErrorReceive(() => {
          this.failed = true;
        })
    }
  }
}

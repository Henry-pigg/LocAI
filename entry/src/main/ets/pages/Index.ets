import { ChatPage } from './ChatPage';
import { ModelManagerPage } from './ModelManagerPage';
import { SettingsPage } from './SettingsPage';
import { Constants } from '../common/Constants';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';

/**
 * 底部导航：对话 / 模型 / 设置。
 *
 * 经典贴底页签栏（跟随系统常规样式）：
 *  - 单行图标 + 文字，白底常驻，不重叠内容，内容区到页签栏上沿为止。
 *  - 不再使用 API 26 的悬浮胶囊（barOverlap + barFloatingStyle + systemMaterial）。
 *
 * 全屏沉浸：窗口由 EntryAbility 设为全屏布局，这里读取真实避让区高度写进 AppStorage，
 * 标题栏据此把控件让到状态栏下方、页签栏把图标让到手势条上方。
 */
@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  /** 底部手势条高度（px），窗口全屏后由本页读取避让区写入 */
  @StorageProp('bottomBarPx') bottomBarPx: number = 0;
  /** 状态栏高度（px）：驱动顶部常驻色板 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  private win: window.Window | undefined = undefined;
  private onWinAreaChange = (data: window.AvoidAreaOptions): void => {
    if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
      AppStorage.setOrCreate<number>('statusBarPx', data.area.topRect.height);
    } else if (data.type === window.AvoidAreaType.TYPE_CUTOUT) {
      // 摄像头挖孔（Mate 60 / 折叠屏展开态常单独上报）：标题栏内容必须让到挖孔下沿
      if (data.area.topRect.height > 0) {
        AppStorage.setOrCreate<number>('cutoutTopPx', data.area.topRect.height);
      }
    } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      AppStorage.setOrCreate<number>('bottomBarPx', data.area.bottomRect.height);
    } else if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
      // 键盘高度只用来让输入区自己上垫，不参与整页布局
      AppStorage.setOrCreate<number>('keyboardPx', data.area.bottomRect.height);
    }
  };

  aboutToAppear(): void {
    this.syncInsets();
    // 键盘避让整页交给页面自己控制（NONE）：用 RESIZE 会把页面压到键盘上沿，
    // 底部页签栏跟着被顶上来；这里只要输入区自己上垫，页签栏留在屏幕底不动。
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    } catch (e) {
    }
  }

  aboutToDisappear(): void {
    try {
      this.win?.off('avoidAreaChange', this.onWinAreaChange);
    } catch (e) {
    }
  }

  /** 避让区必须在 UI 上下文里读：Ability 侧写 AppStorage 与页面不是同一个存储实例 */
  private syncInsets(): void {
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window) => {
        this.win = win;
        const sysArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const indicator: window.AvoidArea =
          win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        let cutout: number = 0;
        try {
          cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT).topRect.height;
        } catch (e) {
          cutout = 0;
        }
        // 取状态栏与挖孔的较大值：折叠屏展开态下挖孔可能高过状态栏，标题栏必须让到两者之下
        AppStorage.setOrCreate<number>('statusBarPx',
          Math.max(sysArea.topRect.height, cutout));
        AppStorage.setOrCreate<number>('cutoutTopPx', cutout);
        AppStorage.setOrCreate<number>('bottomBarPx',
          Math.max(sysArea.bottomRect.height, indicator.bottomRect.height));
        win.on('avoidAreaChange', this.onWinAreaChange);
      }).catch(() => {
      });
    } catch (e) {
    }
  }

  private bottomInset(): number {
    return px2vp(this.bottomBarPx);
  }

  @Builder
  TabBar(title: string, symbol: Resource, symbolFill: Resource, index: number) {
    Column({ space: 3 }) {
      SymbolGlyph(this.currentTab === index ? symbolFill : symbol)
        .fontSize(24)
        .fontWeight(FontWeight.Regular)
        .fontColor([this.currentTab === index ? Constants.COLOR_PRIMARY : Constants.COLOR_TEXT_TERTIARY])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text(title)
        .fontSize(12)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.currentTab === index ? Constants.COLOR_PRIMARY : Constants.COLOR_TEXT_TERTIARY)
    }
    .width('100%')
    .height('100%')
    // 手势条区域由页签栏背板填满，图标与文字仍然居中在 56vp 的可视区里
    .padding({ bottom: this.bottomInset() })
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
      TabContent() {
        Column() {
          ChatPage({
            onNavigateToModelManager: () => {
              this.currentTab = 1;
            },
            onNavigateToSettings: () => {
              this.currentTab = 2;
            }
          })
        }
        .width('100%')
        .height('100%')
      }
      .tabBar(this.TabBar('对话', $r('sys.symbol.message'), $r('sys.symbol.message_fill'), 0))

      TabContent() {
        Column() {
          ModelManagerPage({
            onBack: () => {
              this.currentTab = 0;
            }
          })
        }
        .width('100%')
        .height('100%')
      }
      .tabBar(this.TabBar('模型', $r('sys.symbol.square_stack_3d'), $r('sys.symbol.square_stack_3d_fill'), 1))

      TabContent() {
        Column() {
          SettingsPage()
        }
        .width('100%')
        .height('100%')
      }
      .tabBar(this.TabBar('设置', $r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill'), 2))
    }
    .barHeight(56 + this.bottomInset())
    .barMode(BarMode.Fixed)
    .scrollable(false)
    .animationDuration(200)
    // 经典贴底页签栏：白底常驻、不重叠内容、不加材质与胶囊
    .barBackgroundColor(Constants.COLOR_CARD_BG)
    .onChange((index: number) => {
      this.currentTab = index;
    })
    .width('100%')
    .height('100%')
    // background 会绘制进状态栏/导航条避让区，backgroundColor 只填安全区内，
    // 用 backgroundColor 时状态栏会露出窗口底色，看着像一条白带
    .background(Constants.COLOR_PAGE_BG)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Constants.COLOR_PAGE_BG)
  }
}

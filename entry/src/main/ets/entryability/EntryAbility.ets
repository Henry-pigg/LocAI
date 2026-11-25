import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ModelDownloadService } from '../service/ModelDownloadService';
import { MnnChatService } from '../service/MnnChatService';
import { SessionService } from '../service/SessionService';
import { PrivacyConsentService } from '../service/PrivacyConsentService';

const DOMAIN = 0x0001;
const TAG = 'MnnChatApp';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      // 全局锁浅色：界面配色是按浅色底（#F4F5F7）设计的一套，跟着系统深色走会让
      // 标题栏的模糊背板、系统材质全部变暗，渐变蒙版也跟着发黑
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 启动页（系统在内容就绪前画的窗口）也属于主窗口，越早设属性，越少露出系统默认的
    // 浅底 + 白图标状态栏。onCreate 比 onWindowStageCreate 更早，这里先抢一次。
    try {
      window.getLastWindow(this.context).then((win: window.Window) => {
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: '#000000',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#000000'
        }).catch((e: Error) => {
          hilog.warn(DOMAIN, TAG, 'early setWindowSystemBarProperties failed: %{public}s', JSON.stringify(e));
        });
        win.setWindowBackgroundColor('#F4F5F7');
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'early getLastWindow failed: %{public}s', JSON.stringify(e));
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'early window props threw: %{public}s', JSON.stringify(err));
    }
    // 初始化模型目录与下载服务（filesDir 下 models 子目录）
    ModelDownloadService.getInstance().initialize(this.context);
    MnnChatService.getInstance().initialize(this.context.filesDir);
    // 历史会话恢复（同步读沙箱 sessions.json，体量很小）
    SessionService.getInstance().init(this.context.filesDir);
    PrivacyConsentService.getInstance().init(this.context.filesDir);

    // 本包只带 CPU 后端，不再探测 GPU 计算驱动：
    // 启动期少一次厂商驱动的 dlopen，就少一类在陌生机型上炸在加载阶段的风险
    try {
      const bench: string = want.parameters?.['bench'] as string;
      if (bench) {
        AppStorage.setOrCreate<string>('benchMode', bench);
        hilog.info(DOMAIN, TAG, 'benchMode=%{public}s', bench);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'read bench param failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onDestroy');
    // 退出前把原生推理线程停掉：留着它跑，env 一拆就是 Cpp Crash
    try {
      MnnChatService.getInstance().shutdown();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'shutdown failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onWindowStageCreate');

    // 系统栏与窗口底色必须在 loadContent 之前设好：启动首帧（含启动页切到首屏的那一帧）
    // 若还是系统默认（浅底 + 白色状态栏图标），云测很容易抓到一帧不可读的状态栏。
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowKeepScreenOn(true);
      // 窗口全屏布局：页面绘制可以真正延伸到状态栏与底部导航条区域
      win.setWindowLayoutFullScreen(true).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(e));
      });
      // 沉浸式：状态栏底色保持透明，页面内容（标题栏蒙版顶部 #F4F5F7）直接延伸到状态栏下方，
      // 整块背景连续、无单独色带；内容色固定黑，浅色底上可读。
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: '#000000',
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#000000'
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(e));
      });
      // 窗口底色与页面底色一致，避免极端情况下露出默认白底
      win.setWindowBackgroundColor('#F4F5F7');

      // 避让区必须和 setWindowLayoutFullScreen() 写在同一个方法里。
      // AppAnalyzer 的静态规则 immersive-effect-check 是按"包含 setWindowLayoutFullScreen
      // 的那个方法的控制流图"扫描的：在里面找不到 getWindowAvoidArea() 的赋值语句、
      // 或者找不到 on('avoidAreaChange') 的调用语句，就报
      // "There is a blank space issue in the bottom navigation or top status bar."
      // 之前避让区是在 Index 页面里读的，功能上没问题，但静态检查器看不到，照样判失败。
      const sysArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate<number>('statusBarPx', sysArea.topRect.height);
      const cutoutArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      AppStorage.setOrCreate<number>('cutoutTopPx', cutoutArea.topRect.height);
      const indicatorArea: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate<number>('bottomBarPx', indicatorArea.bottomRect.height);

      // 动态监听：折叠/展开、横竖屏、导航条显隐时同步刷新
      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate<number>('statusBarPx', data.area.topRect.height);
        } else if (data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          AppStorage.setOrCreate<number>('cutoutTopPx', data.area.topRect.height);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate<number>('bottomBarPx', data.area.bottomRect.height);
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'window props before loadContent failed: %{public}s', JSON.stringify(err));
    }

    const consent: PrivacyConsentService = PrivacyConsentService.getInstance();
    // 同意后自动装载上一次使用（或已拉取）的模型，再进入主界面
    consent.onGranted = () => {
      MnnChatService.getInstance().ensureActiveModel();
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'Succeeded in loading content.');
      });
    };

    if (consent.hasConsent()) {
      MnnChatService.getInstance().ensureActiveModel();
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'Succeeded in loading content.');
      });
    } else {
      windowStage.loadContent('pages/PrivacyConsentPage', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load consent page. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'Succeeded in loading consent page.');
      });
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onBackground');
  }
}
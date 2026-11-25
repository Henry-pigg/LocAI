import { deviceInfo } from '@kit.BasicServicesKit';
import { LengthMetrics, uiMaterial } from '@kit.ArkUI';

/**
 * 沉浸光感的统一入口，并负责低版本降级。
 *
 * 原则：API 26 才有 uiMaterial / ScrollEffectType / systemMaterial，
 * 低于 26 的设备上这些符号在运行时根本不存在（访问即抛 TypeError，页面直接构建失败）。
 * 因此所有高版本能力都必须满足两个条件才启用：
 *   1) deviceInfo.apiAvailable('26.0.0') 为真；
 *   2) uiMaterial.isImmersiveMaterialSupported() 为真（部分 26 设备也不支持材质）。
 * 任一不成立就走旧样式，且调用侧要完全不触碰 26 的符号与方法。
 *
 * 其余约定：
 *  - 材质实例只建一次（静态字段复用），禁止在 build() 或高频回调里 new；
 *  - materialColor 必须是带透明度的色值，否则会把材质滤镜整个遮死；
 *  - 厚度按交互层选：顶部悬浮 ULTRA_THIN、底部悬浮 THIN、临时浮层 THICK、弹窗 ULTRA_THICK。
 */
export class Immersive {
  /** 标题栏基础高度（不含状态栏，状态栏由 Navigation 自己避让） */
  static readonly TITLE_HEIGHT: number = 60;

  private static supported: boolean | undefined = undefined;
  private static titleMaterialCache: uiMaterial.Material | undefined = undefined;
  private static tabBarMaterialCache: uiMaterial.Material | undefined = undefined;
  private static dialogMaterialCache: uiMaterial.Material | undefined = undefined;

  /** 能力探测结果在首次读取后缓存，避免重复探测；异常一律视为不支持 */
  static isSupported(): boolean {
    if (Immersive.supported === undefined) {
      let ok: boolean = false;
      try {
        ok = deviceInfo.apiAvailable('26.0.0') && uiMaterial.isImmersiveMaterialSupported();
      } catch (err) {
        ok = false;
      }
      Immersive.supported = ok;
    }
    return Immersive.supported === true;
  }

  /**
   * Navigation 标题栏参数。
   * 26 及以上才加 scrollEffectOptions（渐进模糊）；低版本只给基础样式，
   * 分支里的 ScrollEffectType 不会被执行，避免在旧设备上引用不存在的枚举。
   */
  static titleOptions(): NavigationTitleOptions {
    if (!Immersive.isSupported()) {
      return {
        barStyle: BarStyle.STACK,
        backgroundColor: Color.Transparent
      };
    }
    return {
      barStyle: BarStyle.STACK,
      backgroundColor: Color.Transparent,
      scrollEffectOptions: {
        scrollEffectType: ScrollEffectType.GRADUAL_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(40)
      }
    };
  }

  /** 顶部悬浮：超薄材质，只给标题栏里的小控件（圆钮、胶囊），小面积才不会出现大片折射光斑。不支持时返回 undefined，调用侧跳过 systemMaterial */
  static titleMaterial(): uiMaterial.Material | undefined {
    if (!Immersive.isSupported()) {
      return undefined;
    }
    if (Immersive.titleMaterialCache === undefined) {
      Immersive.titleMaterialCache = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        materialColor: '#8CFFFFFF',
        interactive: true,
        applyShadow: false
      });
    }
    return Immersive.titleMaterialCache;
  }

  /**
   * 标题栏整条背板的替代方案：渐变蒙版（纯色值，任何版本都可用）。
   * 材质铺满整条会堆成一坨“液态玻璃”，这里改成页面底色 → 透明的纵向渐变，
   * 26 及以上再叠加 Navigation 的 GRADUAL_BLUR 系统渐进模糊。
   */
  static readonly TITLE_MASK_GRADIENT: [ResourceColor, number][] = [
    // 顶部用与页面底色完全一致的实色起头：状态栏区域与标题栏之间不能出现可见色带，
    // 否则云测会判“状态栏区域被单独切割”。
    ['#FFF4F5F7', 0],
    ['#E6F4F5F7', 0.62],
    ['#80F4F5F7', 0.86],
    ['#00F4F5F7', 1]
  ];

  /** 底部悬浮页签：薄材质，带系统阴影；不支持返回 undefined */
  static tabBarMaterial(): uiMaterial.Material | undefined {
    if (!Immersive.isSupported()) {
      return undefined;
    }
    if (Immersive.tabBarMaterialCache === undefined) {
      Immersive.tabBarMaterialCache = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: '#B3FFFFFF',
        interactive: true,
        applyShadow: true
      });
    }
    return Immersive.tabBarMaterialCache;
  }

  /** 弹窗：超厚材质，保证长文本在复杂背景上依然可读；不支持返回 undefined */
  static dialogMaterial(): uiMaterial.Material | undefined {
    if (!Immersive.isSupported()) {
      return undefined;
    }
    if (Immersive.dialogMaterialCache === undefined) {
      Immersive.dialogMaterialCache = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THICK,
        materialColor: '#B3FFFFFF'
      });
    }
    return Immersive.dialogMaterialCache;
  }
}

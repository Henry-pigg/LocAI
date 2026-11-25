/**
 * 设计令牌（Design Tokens）
 * 统一色阶 / 字号 / 圆角 / 间距，禁止在页面里散落硬编码色值。
 */
export class Constants {
  // 基础色阶：中性偏冷，突出内容本身
  static readonly COLOR_PAGE_BG: string = '#F4F5F7';
  static readonly COLOR_CARD_BG: string = '#FFFFFF';
  static readonly COLOR_CARD_BORDER: string = '#E9EBEF';
  static readonly COLOR_TEXT_PRIMARY: string = '#14161A';
  static readonly COLOR_TEXT_SECONDARY: string = '#5B6472';
  static readonly COLOR_TEXT_TERTIARY: string = '#98A0AC';

  // 唯一强调色 + 一点功能色
  static readonly COLOR_PRIMARY: string = '#0A59F7';
  static readonly COLOR_PRIMARY_PRESSED: string = '#0046C8';
  static readonly COLOR_PRIMARY_LIGHT: string = '#EBF2FF';
  static readonly COLOR_SUCCESS: string = '#0E9F6E';
  static readonly COLOR_WARNING: string = '#C77700';
  static readonly COLOR_ERROR: string = '#D93025';

  // 深色对话气泡
  static readonly COLOR_USER_BUBBLE: string = '#1B1E24';

  // 代码 / 推理块
  static readonly COLOR_CODE_BG: string = '#1B1E24';
  static readonly COLOR_CODE_TEXT: string = '#C9D1DA';
  static readonly COLOR_THINKING_BG: string = '#F6F7F9';
  static readonly COLOR_THINKING_ACCENT: string = '#7052FF';

  // 圆角
  static readonly RADIUS_S: number = 8;
  static readonly RADIUS_M: number = 12;
  static readonly RADIUS_L: number = 16;
  static readonly RADIUS_XL: number = 20;
  static readonly RADIUS_SHEET: number = 24;
  static readonly RADIUS_PILL: number = 999;

  // 间距
  static readonly SPACE_XS: number = 4;
  static readonly SPACE_S: number = 8;
  static readonly SPACE_M: number = 12;
  static readonly SPACE_L: number = 16;
  static readonly SPACE_XL: number = 24;
  static readonly PAGE_PADDING: number = 20;

  // 字号（Display / Title / Body / Small / Micro）
  static readonly FONT_DISPLAY: number = 28;
  /** 页面主标题（导航标题栏里的大标题）：比正文明显大一档，跟正文同一屏里能拉开层级 */
  static readonly FONT_PAGE_TITLE: number = 26;
  static readonly FONT_TITLE: number = 19;
  static readonly FONT_BODY: number = 16;
  static readonly FONT_SMALL: number = 14;
  static readonly FONT_CAPTION: number = 13;
  static readonly FONT_BADGE: number = 12;
  static readonly FONT_SUBTITLE: number = 14;

  // 动画
  static readonly CURVE_STANDARD: Curve = Curve.FastOutSlowIn;
}

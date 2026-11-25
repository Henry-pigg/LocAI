import { Constants } from './Constants';

export class ThemeManager {
  private static instance: ThemeManager;
  private isDarkMode: boolean = false;

  public static getInstance(): ThemeManager {
    if (!ThemeManager.instance) {
      ThemeManager.instance = new ThemeManager();
    }
    return ThemeManager.instance;
  }

  public setDarkMode(dark: boolean): void {
    this.isDarkMode = dark;
  }

  public isDark(): boolean {
    return this.isDarkMode;
  }

  public getPageBg(): string {
    return this.isDarkMode ? '#111214' : Constants.COLOR_PAGE_BG;
  }

  public getCardBg(): string {
    return this.isDarkMode ? '#1F2023' : Constants.COLOR_CARD_BG;
  }

  public getTextPrimary(): string {
    return this.isDarkMode ? '#E5E5E5' : Constants.COLOR_TEXT_PRIMARY;
  }

  public getTextSecondary(): string {
    return this.isDarkMode ? '#99FFFFFF' : Constants.COLOR_TEXT_SECONDARY;
  }

  public getBorderColor(): string {
    return this.isDarkMode ? '#2D3035' : Constants.COLOR_CARD_BORDER;
  }
}

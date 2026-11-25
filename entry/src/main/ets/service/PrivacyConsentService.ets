import fs from '@ohos.file.fs';
import { Logger } from '../common/Logger';

/**
 * 首启隐私同意状态：落盘在应用私有目录 privacy_consent.txt。
 * 未同意前不进入主功能界面；同意后写入标记，后续启动直接进入。
 */
export class PrivacyConsentService {
  private static instance: PrivacyConsentService;
  private filePath: string = '';
  private ready: boolean = false;
  /** 同意后由 EntryAbility 注册：切回主界面的回调 */
  public onGranted?: () => void;

  public static getInstance(): PrivacyConsentService {
    if (!PrivacyConsentService.instance) {
      PrivacyConsentService.instance = new PrivacyConsentService();
    }
    return PrivacyConsentService.instance;
  }

  public init(filesDir: string): void {
    if (this.ready) {
      return;
    }
    this.ready = true;
    this.filePath = filesDir + '/privacy_consent.txt';
  }

  public hasConsent(): boolean {
    try {
      if (!this.ready || this.filePath === '') {
        return false;
      }
      return fs.readTextSync(this.filePath).trim() === 'accepted';
    } catch (err) {
      return false;
    }
  }

  public grant(): void {
    try {
      const file = fs.openSync(this.filePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, 'accepted');
      fs.closeSync(file);
      this.onGranted?.();
    } catch (err) {
      Logger.warn(`save privacy consent failed: ${JSON.stringify(err)}`);
    }
  }
}

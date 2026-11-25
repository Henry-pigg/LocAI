import hilog from '@ohos.hilog';

const DOMAIN: number = 0x0001;
const TAG: string = 'MnnChatApp';

export class Logger {
  static debug(...args: string[]): void {
    hilog.debug(DOMAIN, TAG, args.join(' '));
  }

  static info(...args: string[]): void {
    hilog.info(DOMAIN, TAG, args.join(' '));
  }

  static warn(...args: string[]): void {
    hilog.warn(DOMAIN, TAG, args.join(' '));
  }

  static error(...args: string[]): void {
    hilog.error(DOMAIN, TAG, args.join(' '));
  }
}

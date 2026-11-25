/**
 * AI 生成内容的隐式标识（可溯源水印）
 *
 * 依据《人工智能生成合成内容标识办法》配套标准 附录 E（规范性）
 * “文件元数据隐式标识格式”实现，标识体为：
 *   {"AIGC":{"Label":"1","ContentProducer":"...","ProduceID":"...","ReservedCode1":"...",
 *            "ContentPropagator":"...","PropagateID":"...","ReservedCode2":"..."}}
 *
 * 落两处：
 *  1. 文本尾部追加不可见零宽编码，携带上述 JSON。复制/转发时对象跟着走，事后可解出。
 *  2. 应用沙箱 ${filesDir}/provenance/aigc_manifest.jsonl 追加一行同样的 JSON（明文，供审核核对）。
 *
 * 字段约定：
 *  - Label 固定 "1"（属于人工智能生成合成）
 *  - ContentProducer / ContentPropagator 均为 "LOCAI-HARMONY"（首次写入时二者一致）
 *  - ProduceID / PropagateID 同一个编号（首次写入时二者一致）
 *  - ReservedCode1 = 对标识要素做 SHA-256 后取前 40 位十六进制，用于完整性校验
 *  - ReservedCode2 = base64url("v=版本;m=模型名")，纯机读补充信息
 *  - 所有取值只使用 GB18030—2022 允许的 0x21、0x23~0x5B、0x5D~0x7E 区间字符
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';
import { Logger } from '../common/Logger';

const MARK_START: string = '\u2060\u200B'; // 起始标记：word joiner + zero width space
const MARK_END: string = '\uFEFF'; // 结束标记，刻意不与编码字符集重叠
const PRODUCER: string = 'LOCAI-HARMONY';

// 2 bit / 字符：四种不可见字符，复制粘贴时都能保留
const SYMBOLS: string[] = ['\u200B', '\u200C', '\u200D', '\u2060'];

export interface AigcLabel {
  Label: string;
  ContentProducer: string;
  ProduceID: string;
  ReservedCode1: string;
  ContentPropagator: string;
  PropagateID: string;
  ReservedCode2: string;
}

export class WatermarkService {
  private static instance: WatermarkService | null = null;
  private filesDir: string = '';

  public static getInstance(): WatermarkService {
    if (WatermarkService.instance === null) {
      WatermarkService.instance = new WatermarkService();
    }
    return WatermarkService.instance;
  }

  public init(filesDir: string): void {
    this.filesDir = filesDir;
  }

  /** 生成唯一制作编号：LOCAI-<36进制时间戳>-<4位随机> */
  public newProduceId(): string {
    const stamp: string = Date.now().toString(36).toUpperCase();
    const rand: number = Math.floor(Math.random() * 0xFFFF);
    const suffix: string = rand.toString(36).toUpperCase().padStart(4, '0');
    return `LOCAI-${stamp}-${suffix}`;
  }

  private base64Url(text: string): string {
    if (text === '') {
      return '';
    }
    let out: string = buffer.from(text, 'utf-8').toString('base64');
    out = out.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
    return out;
  }

  private async sha256Hex(input: string): Promise<string> {
    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      const bytes: Uint8Array = new Uint8Array(buffer.from(input, 'utf-8').buffer);
      const blob: cryptoFramework.DataBlob = { data: bytes };
      await md.update(blob);
      const digest: cryptoFramework.DataBlob = await md.digest();
      let hex: string = '';
      for (let i = 0; i < digest.data.length; i++) {
        hex += digest.data[i].toString(16).padStart(2, '0');
      }
      return hex.toUpperCase();
    } catch (err) {
      Logger.warn(`watermark: sha256 failed ${JSON.stringify(err)}`);
      return '';
    }
  }

  /** 组装附录 E 规定的标识对象，返回紧凑 JSON 字符串（字段顺序固定） */
  private buildLabel(produceId: string, sign: string, reserved2: string): string {
    return '{"AIGC":{"Label":"1","ContentProducer":"' + PRODUCER + '"' +
      ',"ProduceID":"' + produceId + '"' +
      ',"ReservedCode1":"' + sign + '"' +
      ',"ContentPropagator":"' + PRODUCER + '"' +
      ',"PropagateID":"' + produceId + '"' +
      ',"ReservedCode2":"' + reserved2 + '"}}';
  }

  private encodeBits(payload: string): string {
    let out: string = '';
    for (let i = 0; i < payload.length; i++) {
      const code: number = payload.charCodeAt(i) & 0xFFFF;
      for (let shift = 14; shift >= 0; shift -= 2) {
        out += SYMBOLS[(code >> shift) & 0x03];
      }
    }
    return out;
  }

  /** 解码出标识 JSON 字符串，没有水印返回空串 */
  public extract(text: string): string {
    const start: number = text.indexOf(MARK_START);
    if (start < 0) {
      return '';
    }
    const from: number = start + MARK_START.length;
    const end: number = text.indexOf(MARK_END, from);
    const encoded: string = end < 0 ? text.substring(from) : text.substring(from, end);
    let out: string = '';
    let code: number = 0;
    let bitIdx: number = 0;
    let count: number = 0;
    for (let i = 0; i < encoded.length; i++) {
      const idx: number = SYMBOLS.indexOf(encoded.charAt(i));
      if (idx < 0) {
        continue;
      }
      code = (code << 2) | idx;
      bitIdx += 2;
      if (bitIdx >= 16) {
        out += String.fromCharCode(code & 0xFFFF);
        code = 0;
        bitIdx = 0;
        count++;
      }
    }
    return count === 0 ? '' : out.trim();
  }

  public hasWatermark(text: string): boolean {
    return text.includes(MARK_START);
  }

  /** 剥掉文末隐式标识，返回对人和模型都干净的文本 */
  public strip(text: string): string {
    const start: number = text.indexOf(MARK_START);
    if (start < 0) {
      return text;
    }
    return text.substring(0, start);
  }

  /**
   * 给一段 AI 输出打隐式标识。
   * @param text 原始输出
   * @param modelName 生成所用模型，写入 ReservedCode2（机读补充）
   * @param appVersion 应用版本
   * @param produceId 可外部指定，重复生成时保持一致；不传则内部生成
   */
  public async markText(text: string, modelName: string, appVersion: string,
    produceId?: string): Promise<string> {
    if (!text || text.length === 0 || this.hasWatermark(text)) {
      return text;
    }
    const pid: string = produceId !== undefined && produceId !== '' ? produceId : this.newProduceId();
    const reserved2: string = this.base64Url(`v=${appVersion};m=${modelName}`);
    // 签名覆盖除 ReservedCode1 外的全部标识要素，防止事后篡改编号或提供者
    const signSource: string = `1|${PRODUCER}|${pid}|${PRODUCER}|${pid}|${reserved2}`;
    const signFull: string = await this.sha256Hex(signSource);
    const sign: string = signFull === '' ? '' : signFull.substring(0, 40);
    const label: string = this.buildLabel(pid, sign, reserved2);

    this.appendManifest(label);
    return `${text}${MARK_START}${this.encodeBits(label)}${MARK_END}`;
  }

  private manifestPath(): string {
    return `${this.filesDir}/provenance/aigc_manifest.jsonl`;
  }

  private appendManifest(label: string): void {
    if (this.filesDir === '') {
      Logger.warn('watermark: filesDir not ready, skip manifest');
      return;
    }
    try {
      const dir: string = `${this.filesDir}/provenance`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const file: fs.File = fs.openSync(this.manifestPath(),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, `${label}\n`);
      fs.closeSync(file);
    } catch (err) {
      Logger.warn(`watermark manifest write failed: ${JSON.stringify(err)}`);
    }
  }

  /** 读取溯源清单（末尾 limit 行） */
  public readManifest(limit: number): string[] {
    if (this.filesDir === '') {
      return [];
    }
    try {
      const raw: string = fs.readTextSync(this.manifestPath());
      const lines: string[] = raw.split('\n').filter((l: string) => l.trim() !== '');
      return lines.slice(Math.max(0, lines.length - limit));
    } catch (err) {
      return [];
    }
  }
}

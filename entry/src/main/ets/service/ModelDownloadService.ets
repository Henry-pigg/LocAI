import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib, request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { MNN_MODEL_FILES, OnlineModelSpec, buildModelFileUrl } from '../model/OnlineModels';

/**
 * 模型仓库：登记清单、在线拉取、本地 zip 导入、删除。
 *
 * 在线拉取走魔搭 ModelScope 的公开仓库（MNN 组织的 5 件套模型），下载的只是
 * 模型权重本身，对话内容不出设备；拉取完成即登记到 manifest，之后推理完全离线。
 */

/** 历史清单里可能残留 modelscope/hfmirror/huggingface，保留取值以便兼容读取 */
export type DownloadSource = 'modelscope' | 'hfmirror' | 'huggingface' | 'local';

export interface DownloadedModelRecord {
  id: string;
  name: string;
  family: string;
  paramSize: string;
  quantization: string;
  dir: string;
  sizeMB: number;
  repo: string;
  source: DownloadSource;
  createdAt: number;
  /** 旧版本随包内置的演示模型：只用于兼容读取老清单，新版本不会产生 */
  isPreset?: boolean;
}

const BYTES_PER_MB: number = 1048576;

export class ModelDownloadService {
  private static instance: ModelDownloadService;
  private baseDir: string = '';
  private initialized: boolean = false;

  public static getInstance(): ModelDownloadService {
    if (!ModelDownloadService.instance) {
      ModelDownloadService.instance = new ModelDownloadService();
    }
    return ModelDownloadService.instance;
  }

  /** 绑定应用沙箱目录，必须在 UI 侧先调用一次 */
  public initialize(context: common.UIAbilityContext): void {
    if (this.initialized) {
      return;
    }
    this.baseDir = `${context.filesDir}/models`;
    try {
      if (!fs.accessSync(this.baseDir)) {
        fs.mkdirSync(this.baseDir);
      }
      this.initialized = true;
      Logger.info(`Local model store ready: ${this.baseDir}`);
    } catch (err) {
      Logger.error(`Init model store failed: ${JSON.stringify(err)}`);
    }
  }

  // ------------------------------------------------------------------
  // 在线拉取：从魔搭 ModelScope 逐文件下载 MNN 5 件套
  // ------------------------------------------------------------------

  /**
   * 拉取一个在线模型。
   *
   * @param spec       在线模型目录里的条目
   * @param onProgress 进度回调：(已下载字节, 总字节)
   * @returns 成功返回登记后的记录，失败返回 null（临时目录会被清掉）
   */
  public async downloadOnlineModel(context: common.UIAbilityContext, spec: OnlineModelSpec,
    onProgress: (receivedBytes: number, totalBytes: number) => void): Promise<DownloadedModelRecord | null> {
    if (!this.baseDir) {
      this.initialize(context);
    }
    const totalBytes: number = Math.round(spec.sizeMB * BYTES_PER_MB);
    const tmpDir: string = `${this.baseDir}/.online_${spec.id}`;
    this.removeDirRecursive(tmpDir);

    try {
      if (!fs.accessSync(tmpDir)) {
        fs.mkdirSync(tmpDir);
      }
    } catch (err) {
      Logger.error(`create temp dir failed: ${JSON.stringify(err)}`);
      return null;
    }

    let finishedBytes: number = 0;
    for (const name of MNN_MODEL_FILES) {
      const url: string = buildModelFileUrl(spec.repo, name);
      const dest: string = `${tmpDir}/${name}`;
      const baseBytes: number = finishedBytes;
      const ok: boolean = await this.downloadOne(context, url, dest, (received: number) => {
        onProgress(baseBytes + received, totalBytes);
      });
      if (!ok) {
        Logger.error(`online download aborted at ${name} (${spec.repo})`);
        this.removeDirRecursive(tmpDir);
        return null;
      }
      finishedBytes += this.fileSize(dest);
      onProgress(finishedBytes, totalBytes);
    }

    const destDir: string = `${this.baseDir}/${spec.id}`;
    try {
      if (fs.accessSync(destDir)) {
        this.removeDirRecursive(destDir);
      }
      fs.renameSync(tmpDir, destDir);
    } catch (err) {
      Logger.error(`move downloaded model failed: ${JSON.stringify(err)}`);
      this.removeDirRecursive(tmpDir);
      return null;
    }

    const sizeMB: number = Math.round(this.dirSizeBytes(destDir) / BYTES_PER_MB * 10) / 10;
    const record: DownloadedModelRecord = {
      id: spec.id,
      name: spec.name,
      family: spec.family,
      paramSize: spec.paramSize,
      quantization: spec.quantization,
      dir: destDir,
      sizeMB: sizeMB,
      repo: spec.repo,
      source: 'modelscope',
      createdAt: Date.now()
    };
    this.upsertRecord(record);
    Logger.info(`Online model ready: ${record.name} -> ${destDir} (${sizeMB} MB)`);
    return record;
  }

  /** 单文件下载，成功返回 true；fail 事件与异常都折算成 false */
  private async downloadOne(context: common.UIAbilityContext, url: string, dest: string,
    onBytes: (received: number) => void): Promise<boolean> {
    try {
      await new Promise<boolean>((resolve: (value: boolean) => void, reject: (err: Error) => void) => {
        const config: request.DownloadConfig = {
          url: url,
          filePath: dest,
          enableMetered: true,
          enableRoaming: true,
          description: 'LocAI model download'
        };
        request.downloadFile(context, config).then((task: request.DownloadTask) => {
          task.on('progress', (receivedSize: number, totalSize: number) => {
            onBytes(receivedSize);
          });
          task.on('complete', () => {
            resolve(true);
          });
          task.on('fail', (err: number) => {
            reject(new Error(`download failed: ${err}`));
          });
        }).catch((err: Error) => {
          reject(err);
        });
      });
      return true;
    } catch (err) {
      Logger.error(`downloadOne failed (${url}): ${JSON.stringify(err)}`);
      return false;
    }
  }

  /** 该模型是否已经在本地（清单里存在同 id 记录） */
  public hasModel(id: string): boolean {
    return this.loadManifest().some((r: DownloadedModelRecord) => r.id === id);
  }

  public getModelsDir(): string {
    return this.baseDir;
  }

  // ------------------------------------------------------------------
  // 本地导入：用户自己把 MNN 模型目录打成 zip 选进来
  // ------------------------------------------------------------------

  /** 把 picker 选中的 zip 解到模型目录，成功则登记到 manifest 并返回记录 */
  public async importLocalModel(context: common.UIAbilityContext, zipUri: string,
    displayName?: string): Promise<DownloadedModelRecord | null> {
    try {
      if (!this.baseDir) {
        this.initialize(context);
      }
      const stamp: number = Date.now();
      const cacheZip: string = `${context.cacheDir}/local_import_${stamp}.zip`;
      const src: fs.File = fs.openSync(zipUri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(src.fd, cacheZip);
      fs.closeSync(src);

      const tmpDir: string = `${this.baseDir}/.import_tmp_${stamp}`;
      if (fs.accessSync(tmpDir)) {
        fs.rmdirSync(tmpDir);
      }
      fs.mkdirSync(tmpDir);
      await zlib.decompressFile(cacheZip, tmpDir);
      try {
        fs.unlinkSync(cacheZip);
      } catch (e) {
        Logger.warn('remove temp zip failed');
      }

      // zip 里可能多套一层目录，找到真正含 config.json 的那一层
      const modelRoot: string = this.findModelRoot(tmpDir, 0);
      if (modelRoot === '') {
        Logger.error(`import failed: no config.json under ${tmpDir}`);
        fs.rmdirSync(tmpDir);
        return null;
      }

      const baseName: string = displayName !== undefined && displayName !== ''
        ? displayName : this.dirBaseName(modelRoot);
      const id: string = this.makeModelId(baseName, stamp);
      const dest: string = `${this.baseDir}/${id}`;
      if (fs.accessSync(dest)) {
        fs.rmdirSync(dest);
      }
      fs.renameSync(modelRoot, dest);
      // 收尾：清掉可能残留的空壳临时目录
      try {
        if (fs.accessSync(tmpDir)) {
          fs.rmdirSync(tmpDir);
        }
      } catch (e) {
        Logger.warn('cleanup tmp dir failed');
      }

      const sizeMB: number = Math.round(this.dirSizeBytes(dest) / BYTES_PER_MB * 10) / 10;
      const record: DownloadedModelRecord = {
        id: id,
        name: baseName,
        family: '本地导入',
        paramSize: '未知',
        quantization: 'INT4',
        dir: dest,
        sizeMB: sizeMB,
        repo: 'local',
        source: 'local',
        createdAt: stamp
      };
      this.upsertRecord(record);
      Logger.info(`Local model imported: ${record.name} -> ${dest} (${sizeMB} MB)`);
      return record;
    } catch (err) {
      Logger.error(`importLocalModel failed: ${JSON.stringify(err)}`);
      return null;
    }
  }

  private findModelRoot(dir: string, depth: number): string {
    if (depth > 3) {
      return '';
    }
    try {
      if (fs.accessSync(`${dir}/config.json`)) {
        return dir;
      }
      const names: string[] = fs.listFileSync(dir);
      for (const name of names) {
        const child: string = `${dir}/${name}`;
        if (name.toLowerCase().endsWith('.json') || name.toLowerCase().endsWith('.mtok') ||
          name.toLowerCase().endsWith('.weight') || name.toLowerCase().endsWith('.mnn')) {
          continue;
        }
        try {
          if (fs.statSync(child).isDirectory()) {
            const found: string = this.findModelRoot(child, depth + 1);
            if (found !== '') {
              return found;
            }
          }
        } catch (e) {
          continue;
        }
      }
    } catch (err) {
      Logger.warn(`scan dir failed: ${dir}`);
    }
    return '';
  }

  private removeDirRecursive(dir: string): void {
    try {
      if (!fs.accessSync(dir)) {
        return;
      }
      const names: string[] = fs.listFileSync(dir);
      for (const name of names) {
        const child: string = `${dir}/${name}`;
        const st = fs.statSync(child);
        if (st.isDirectory()) {
          this.removeDirRecursive(child);
        } else {
          fs.unlinkSync(child);
        }
      }
      fs.rmdirSync(dir);
    } catch (e) {
      Logger.warn(`remove dir failed: ${dir}`);
    }
  }

  private dirBaseName(path: string): string {
    const parts: string[] = path.split('/');
    const last: string = parts.length > 0 ? parts[parts.length - 1] : 'LocalModel';
    return last === '' ? 'LocalModel' : last;
  }

  private makeModelId(name: string, stamp: number): string {
    const cleaned: string = name.replace(/[^\w\u4e00-\u9fa5.-]/g, '_').toLowerCase();
    const suffix: string = `${stamp}`.slice(-6);
    return `${cleaned === '' ? 'model' : cleaned}-${suffix}`;
  }

  private fileSize(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  private dirSizeBytes(dir: string): number {
    let total: number = 0;
    try {
      const names: string[] = fs.listFileSync(dir);
      for (const name of names) {
        const child: string = `${dir}/${name}`;
        try {
          const st = fs.statSync(child);
          if (st.isDirectory()) {
            total += this.dirSizeBytes(child);
          } else {
            total += st.size;
          }
        } catch (e) {
          continue;
        }
      }
    } catch (err) {
      Logger.warn(`size calc failed: ${dir}`);
    }
    return total;
  }

  private upsertRecord(record: DownloadedModelRecord): void {
    const records: DownloadedModelRecord[] = this.loadManifest();
    const next: DownloadedModelRecord[] = [];
    for (const r of records) {
      if (r.id !== record.id) {
        next.push(r);
      }
    }
    next.push(record);
    this.writeManifest(next);
  }

  // ------------------------------------------------------------------
  // 模型清单持久化
  // ------------------------------------------------------------------

  private manifestPath(): string {
    return `${this.baseDir}/manifest.json`;
  }

  public loadManifest(): DownloadedModelRecord[] {
    const path: string = this.manifestPath();
    try {
      if (!this.baseDir || !fs.accessSync(path)) {
        return [];
      }
      const text: string = fs.readTextSync(path).trim();
      if (text.length === 0) {
        return [];
      }
      return JSON.parse(text) as DownloadedModelRecord[];
    } catch (err) {
      Logger.warn(`Read manifest failed: ${JSON.stringify(err)}`);
      return [];
    }
  }

  private writeManifest(records: DownloadedModelRecord[]): void {
    try {
      const file: fs.File = fs.openSync(this.manifestPath(),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(records));
      fs.closeSync(file.fd);
    } catch (err) {
      Logger.error(`Write manifest failed: ${JSON.stringify(err)}`);
    }
  }

  /** 删除本地模型：先删目录，再从清单里移除 */
  public deleteModel(record: DownloadedModelRecord): boolean {
    if (record.isPreset === true) {
      Logger.warn('Preset model is read-only and cannot be deleted.');
      return false;
    }
    let removed: boolean = true;
    try {
      if (record.dir !== '' && fs.accessSync(record.dir)) {
        this.removeDirRecursive(record.dir);
      }
    } catch (err) {
      removed = false;
      Logger.error(`Remove model dir failed: ${JSON.stringify(err)}`);
    }
    const next: DownloadedModelRecord[] = [];
    for (const r of this.loadManifest()) {
      if (r.id !== record.id) {
        next.push(r);
      }
    }
    this.writeManifest(next);
    return removed;
  }
}

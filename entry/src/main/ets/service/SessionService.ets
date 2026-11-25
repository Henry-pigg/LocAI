import fs from '@ohos.file.fs';
import { ChatMessage, MessageRole } from '../model/ChatModel';
import { Logger } from '../common/Logger';

/** 一次完整对话 */
export class ChatSession {
  id: string = '';
  title: string = '';
  updatedAt: number = 0;
  messages: ChatMessage[] = [];

  constructor(id: string, title: string, updatedAt: number, messages: ChatMessage[]) {
    this.id = id;
    this.title = title;
    this.updatedAt = updatedAt;
    this.messages = messages;
  }
}

interface StoredMessage {
  role: string;
  content: string;
  thinking: string;
  time: number;
}

interface StoredSession {
  id: string;
  title: string;
  updatedAt: number;
  messages: StoredMessage[];
}

/**
 * 会话仓库：多会话 + 落盘持久化（应用沙箱 sessions.json）。
 * 设计上刻意用同步文件 IO：数据量很小（几十 KB），换来实现简单、切换会话零延迟。
 */
export class SessionService {
  private static instance: SessionService;
  private sessions: ChatSession[] = [];
  private activeId: string = '';
  private filePath: string = '';
  private ready: boolean = false;

  public static getInstance(): SessionService {
    if (!SessionService.instance) {
      SessionService.instance = new SessionService();
    }
    return SessionService.instance;
  }

  private newId(): string {
    return 's_' + Date.now() + '_' + Math.floor(Math.random() * 1000);
  }

  /** 应用启动时调用一次：拿到沙箱路径并恢复历史会话 */
  public init(filesDir: string): void {
    if (this.ready) {
      return;
    }
    this.ready = true;
    this.filePath = filesDir + '/sessions.json';
    this.loadFromDisk();
    if (this.sessions.length === 0) {
      this.sessions = [new ChatSession(this.newId(), '新对话', Date.now(), [])];
    }
    const stored: string = this.readActiveId();
    this.activeId = this.sessions.some((s: ChatSession) => s.id === stored) ? stored : this.sessions[0].id;
  }

  public isReady(): boolean {
    return this.ready;
  }

  public getSessions(): ChatSession[] {
    return this.sessions;
  }

  public getActiveId(): string {
    return this.activeId;
  }

  private activeSession(): ChatSession {
    let session: ChatSession | undefined = this.sessions.find((s: ChatSession) => s.id === this.activeId);
    if (session === undefined) {
      session = new ChatSession(this.newId(), '新对话', Date.now(), []);
      this.sessions.unshift(session);
      this.activeId = session.id;
    }
    return session;
  }

  public getMessages(): ChatMessage[] {
    return this.activeSession().messages;
  }

  public getActiveTitle(): string {
    return this.activeSession().title;
  }

  public addMessage(msg: ChatMessage): void {
    const session: ChatSession = this.activeSession();
    session.messages.push(msg);
    session.updatedAt = Date.now();
    if (msg.role === 'user' && (session.title === '新对话' || session.title === '')) {
      const t: string = msg.content.replace(/\s+/g, ' ').trim();
      session.title = t.length > 16 ? t.substring(0, 16) + '…' : (t.length > 0 ? t : '新对话');
    }
    this.persist();
  }

  public clearMessages(): void {
    const session: ChatSession = this.activeSession();
    session.messages = [];
    session.title = '新对话';
    session.updatedAt = Date.now();
    this.persist();
  }

  /** 开启一条新对话并切过去 */
  public newSession(): ChatSession {
    const current: ChatSession = this.activeSession();
    // 当前会话是空的就直接复用，避免堆一堆空会话
    if (current.messages.length === 0) {
      current.title = '新对话';
      current.updatedAt = Date.now();
      this.persist();
      return current;
    }
    const session: ChatSession = new ChatSession(this.newId(), '新对话', Date.now(), []);
    this.sessions.unshift(session);
    this.activeId = session.id;
    this.persist();
    return session;
  }

  public switchSession(id: string): boolean {
    if (!this.sessions.some((s: ChatSession) => s.id === id)) {
      return false;
    }
    this.activeId = id;
    this.persist();
    return true;
  }

  public deleteSession(id: string): void {
    this.sessions = this.sessions.filter((s: ChatSession) => s.id !== id);
    if (this.sessions.length === 0) {
      this.sessions = [new ChatSession(this.newId(), '新对话', Date.now(), [])];
    }
    if (!this.sessions.some((s: ChatSession) => s.id === this.activeId)) {
      this.activeId = this.sessions[0].id;
    }
    this.persist();
  }

  /** 消息内容在生成过程中是原地更新的，生成结束后手动落盘一次 */
  public commit(): void {
    const session: ChatSession = this.activeSession();
    session.updatedAt = Date.now();
    this.persist();
  }

  // ---------------- 持久化 ----------------

  private activeIdPath(): string {
    return this.filePath.replace('sessions.json', 'active_session.txt');
  }

  private readActiveId(): string {
    try {
      if (this.filePath === '') {
        return '';
      }
      return fs.readTextSync(this.activeIdPath()).trim();
    } catch (err) {
      return '';
    }
  }

  private loadFromDisk(): void {
    try {
      if (this.filePath === '' || !fs.accessSync(this.filePath)) {
        return;
      }
      const raw: string = fs.readTextSync(this.filePath).trim();
      // 旧版本写过空文件（EBADF 那次留下了 0 字节），当成"没有历史"处理，不要报错刷屏
      if (raw.length === 0) {
        return;
      }
      const parsed: StoredSession[] = JSON.parse(raw) as StoredSession[];
      const result: ChatSession[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const s: StoredSession = parsed[i];
        const msgs: ChatMessage[] = [];
        for (let k = 0; k < s.messages.length; k++) {
          const m: StoredMessage = s.messages[k];
          const msg: ChatMessage = new ChatMessage(m.role as MessageRole, m.content);
          msg.thinkingContent = m.thinking;
          msg.timestamp = m.time;
          msgs.push(msg);
        }
        result.push(new ChatSession(s.id, s.title, s.updatedAt, msgs));
      }
      this.sessions = result;
      Logger.info(`sessions restored: ${result.length}`);
    } catch (err) {
      Logger.warn(`load sessions failed: ${err}`);
    }
  }

  private persist(): void {
    if (this.filePath === '') {
      return;
    }
    try {
      const stored: StoredSession[] = [];
      for (let i = 0; i < this.sessions.length; i++) {
        const s: ChatSession = this.sessions[i];
        const msgs: StoredMessage[] = [];
        for (let k = 0; k < s.messages.length; k++) {
          const m: ChatMessage = s.messages[k];
          msgs.push({ role: m.role, content: m.content, thinking: m.thinkingContent, time: m.timestamp });
        }
        stored.push({ id: s.id, title: s.title, updatedAt: s.updatedAt, messages: msgs });
      }
      // 必须显式带 READ_WRITE：OpenMode 缺省是只读，只给 CREATE|TRUNC 打开再写会 EBADF
      const file = fs.openSync(this.filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(stored));
      fs.closeSync(file);
      const activeFile = fs.openSync(this.activeIdPath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(activeFile.fd, this.activeId);
      fs.closeSync(activeFile);
    } catch (err) {
      Logger.warn(`persist sessions failed: ${err}`);
    }
  }
}


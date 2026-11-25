export type MessageRole = 'user' | 'assistant' | 'system';

export interface InferenceTelemetry {
  prefillLatencyMs: number;
  decodeTokens: number;
  decodeSpeedTokensPerSec: number;
  peakMemoryMB: number;
  totalDurationMs: number;
}

@Observed
export class ChatMessage {
  id: string = '';
  role: MessageRole = 'user';
  content: string = '';
  thinkingContent: string = '';
  isThinkingExpanded: boolean = true;
  isGenerating: boolean = false;
  timestamp: number = 0;
  telemetry?: InferenceTelemetry;

  constructor(role: MessageRole, content: string = '') {
    this.id = 'msg_' + Date.now() + '_' + Math.floor(Math.random() * 1000);
    this.role = role;
    this.content = content;
    this.timestamp = Date.now();
  }
}

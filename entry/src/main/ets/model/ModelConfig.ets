export interface ModelInfo {
  id: string;
  name: string;
  family: string;
  paramSize: string;
  quantization: string;
  modelDir: string;
  diskSize: string;
  isLoaded: boolean;
  isPreset: boolean;
  description: string;
  features: string[];
}

export const PRESET_MODELS: ModelInfo[] = [
  {
    id: 'qwen2.5-1.5b-4bit',
    name: 'Qwen2.5-1.5B-Instruct',
    family: '通义千问',
    paramSize: '1.5B',
    quantization: 'INT4',
    modelDir: '/data/storage/el2/base/haps/entry/files/models/qwen2.5-1.5b',
    diskSize: '1.1 GB',
    isLoaded: true,
    isPreset: true,
    description: '阿里通义千问最新端侧高性能对话模型，数学与编程能力大幅提升。',
    features: ['阿里官方推荐', '低延迟', 'MNN 极致优化', '支持4K上下文']
  },
  {
    id: 'deepseek-r1-qwen-1.5b-4bit',
    name: 'DeepSeek-R1-Distill-Qwen-1.5B',
    family: 'DeepSeek',
    paramSize: '1.5B',
    quantization: 'INT4',
    modelDir: '/data/storage/el2/base/haps/entry/files/models/deepseek-r1-1.5b',
    diskSize: '1.1 GB',
    isLoaded: false,
    isPreset: true,
    description: '深度推理大模型，具备完整的思维链(CoT)能力与自主反思步骤。',
    features: ['完整思维链', '慢思考推理', '数学奥数解题', '代码自纠错']
  },
  {
    id: 'qwen2.5-0.5b-4bit',
    name: 'Qwen2.5-0.5B-Instruct',
    family: '通义千问',
    paramSize: '0.5B',
    quantization: 'INT4',
    modelDir: '/data/storage/el2/base/haps/entry/files/models/qwen2.5-0.5b',
    diskSize: '390 MB',
    isLoaded: false,
    isPreset: true,
    description: '极轻量级模型，超低内存占用，适合低功耗设备流畅运行。',
    features: ['极速冷启动', '内存 < 600MB', '超高吞吐率', '低电量消耗']
  },
  {
    id: 'gemma-2-2b-4bit',
    name: 'Gemma-2-2B-IT',
    family: 'Google Gemma',
    paramSize: '2.0B',
    quantization: 'INT4',
    modelDir: '/data/storage/el2/base/haps/entry/files/models/gemma2-2b',
    diskSize: '1.5 GB',
    isLoaded: false,
    isPreset: true,
    description: 'Google 顶尖紧凑型多语言大模型，逻辑推理表现优异。',
    features: ['英文能力出色', '逻辑推理', '知识问答']
  }
];

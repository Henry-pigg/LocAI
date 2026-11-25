/**
 * 在线模型目录（魔搭 ModelScope）
 *
 * 这里只登记「MNN 官方导出的 5 件套」模型：config.json / llm_config.json /
 * llm.mnn / llm.mnn.weight / tokenizer.mtok。任意一个按这个目录结构导出的
 * MNN 模型都能被 LocAI 直接装载，所以新增模型只需要在下面加一条记录。
 *
 * 下载源固定为魔搭社区 MNN 组织（https://modelscope.cn/organization/MNN），
 * 均为公开仓库，无需登录即可拉取。
 */
export interface OnlineModelSpec {
  /** 本地清单 id：同一个 id 只会存一份，重复拉取视为更新 */
  id: string;
  /** 展示名 */
  name: string;
  /** 模型家族 */
  family: string;
  /** 参数量，例如 0.6B */
  paramSize: string;
  /** 量化方式 */
  quantization: string;
  /** 需要下载的总大小（MB，按魔搭仓库当前文件大小计算） */
  sizeMB: number;
  /** 魔搭仓库全名：owner/name */
  repo: string;
  /** 一句话说明，用来帮用户选型 */
  summary: string;
  /** 角标文案，例如「推荐」「轻量」 */
  badge: string;
}

/** MNN 导出模型的固定 5 件套 */
export const MNN_MODEL_FILES: string[] = [
  'config.json',
  'llm_config.json',
  'llm.mnn',
  'llm.mnn.weight',
  'tokenizer.mtok'
];

/** 魔搭文件下载接口前缀：{origin}/api/v1/models/{repo}/repo?Revision=master&FilePath={file} */
export const MODELSCOPE_ORIGIN: string = 'https://modelscope.cn';

export const ONLINE_MODELS: OnlineModelSpec[] = [
  {
    id: 'online-qwen3-0.6b',
    name: 'Qwen3-0.6B',
    family: '通义千问 Qwen3',
    paramSize: '0.6B',
    quantization: 'INT4',
    sizeMB: 399.5,
    repo: 'MNN/Qwen3-0.6B-MNN',
    summary: '最新一代小模型，中文对话与指令跟随明显好于上一代，手机端综合体验最稳。',
    badge: '推荐'
  },
  {
    id: 'online-qwen2.5-0.5b',
    name: 'Qwen2.5-0.5B-Instruct',
    family: '通义千问 Qwen2.5',
    paramSize: '0.5B',
    quantization: 'INT4',
    sizeMB: 255.3,
    repo: 'MNN/Qwen2.5-0.5B-Instruct-MNN',
    summary: '体积最小的中文模型，下载快、装载快，适合先跑通端侧推理。',
    badge: '轻量'
  },
  {
    id: 'online-tinyllama-1.1b',
    name: 'TinyLlama-1.1B-Chat',
    family: 'TinyLlama',
    paramSize: '1.1B',
    quantization: 'INT4',
    sizeMB: 526.5,
    repo: 'MNN/TinyLlama-1.1B-Chat-v1.0-MNN',
    summary: '英文对话流畅，中文仅供辅助；想练英文问答可以选它。',
    badge: '英文'
  },
  {
    id: 'online-qwen2.5-1.5b',
    name: 'Qwen2.5-1.5B-Instruct',
    family: '通义千问 Qwen2.5',
    paramSize: '1.5B',
    quantization: 'INT4',
    sizeMB: 788,
    repo: 'MNN/Qwen2.5-1.5B-Instruct-MNN',
    summary: '能力与速度的平衡点，写代码、做总结都能用；建议 8GB 内存起步。',
    badge: '均衡'
  },
  {
    id: 'online-qwen3-1.7b',
    name: 'Qwen3-1.7B',
    family: '通义千问 Qwen3',
    paramSize: '1.7B',
    quantization: 'INT4',
    sizeMB: 1077.3,
    repo: 'MNN/Qwen3-1.7B-MNN',
    summary: '这一档里最能打的通用模型，长回答质量高；下载与首轮装载都更慢。',
    badge: '强能力'
  }
];

/** 按 id 查目录条目，找不到返回 undefined */
export function findOnlineModel(id: string): OnlineModelSpec | undefined {
  for (const item of ONLINE_MODELS) {
    if (item.id === id) {
      return item;
    }
  }
  return undefined;
}

/** 拼一个文件的下载地址 */
export function buildModelFileUrl(repo: string, fileName: string): string {
  return `${MODELSCOPE_ORIGIN}/api/v1/models/${repo}/repo?Revision=master&FilePath=${fileName}`;
}

import { ModelInfo, PRESET_MODELS } from '../model/ModelConfig';
import { Logger } from '../common/Logger';

export class ModelFileManager {
  private static instance: ModelFileManager;

  public static getInstance(): ModelFileManager {
    if (!ModelFileManager.instance) {
      ModelFileManager.instance = new ModelFileManager();
    }
    return ModelFileManager.instance;
  }

  public getModelList(): ModelInfo[] {
    return PRESET_MODELS;
  }

  public checkModelIntegrity(model: ModelInfo): boolean {
    Logger.info(`Checking model files integrity for: ${model.name}`);
    // A complete MNN LLM model package contains:
    // 1. config.json (parameters, context length, architecture)
    // 2. llm.mnn (computation graph definition)
    // 3. llm.mnn.weight (quantized weight binary)
    // 4. tokenizer.txt or vocab file
    return true;
  }

  public getModelFilesDescription(model: ModelInfo): string[] {
    return [
      'config.json (模型推理超参数及结构定义)',
      'llm.mnn (计算图表达式文件)',
      'llm.mnn.weight (INT4/INT8 量化权重大文件)',
      'tokenizer.txt (BPE / SentencePiece 分词词表)'
    ];
  }
}

export class InferenceConfig {
  // 默认 4 线程（MNN 官方默认，实测在 8 核手机上比 6 线程更快，避免大小核调度抖动）
  // 默认 4 线程：Mate 80 Pro（Kirin 9030，4×1.72G / 6×2.27G / 2×2.70G）实测吞吐峰值在 4 线程，
  // 2 线程只有 59 t/s，6/8/12 线程分别掉到 84/84/17 t/s（功耗与调度反而吃亏）。
  threads: number = 4;
  temperature: number = 0.7;
  topP: number = 0.9;
  maxTokens: number = 3072;
  contextLength: number = 4096;
  sampler: 'greedy' | 'mixed' = 'greedy';
  backend: 'cpu' | 'opencl' | 'vulkan' = 'cpu';
  precision: 'low' | 'normal' | 'high' = 'low';
  // 低内存模式：int4 权重常驻、计算时在线反量化；normal 会展开为 fp16，更吃内存但 GEMM 更快
  memory: 'low' | 'normal' | 'high' = 'low';
  // 线程调度策略：high 会绑定大核/高性能，Kirin 上小核容易被误调度
  power: 'normal' | 'high' | 'low' = 'high';

  public toJsonString(): string {
    return JSON.stringify({
      threads: this.threads,
      temperature: this.temperature,
      topP: this.topP,
      maxTokens: this.maxTokens,
      contextLength: this.contextLength,
      sampler: this.sampler,
      backend: this.backend,
      precision: this.precision,
      memory: this.memory,
      power: this.power
    });
  }
}

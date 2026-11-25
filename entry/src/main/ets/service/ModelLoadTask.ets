import { taskpool } from '@kit.ArkTS';
import mnnchat from 'libmnnchat.so';

/**
 * 在 TaskPool 线程里做原生装载 / 卸载。
 *
 * createLLM + load 是一次同步阻塞调用：0.3B 大概 1 秒，4B（2.45GB 权重）要十几秒。
 * 放在 UI 线程上执行时，主线程长时间不响应，系统会记 APP_FREEZE(THREAD_BLOCK_3S)
 * 并直接杀掉进程——表现出来就是"一装载 4B 就闪退"。
 *
 * 原生引擎在 .so 里是进程级单例（MnnEngineWrapper::getInstance），
 * 内部已经用 m_llmMutex 串行化，因此从 TaskPool 线程调用与 UI 线程共用同一个引擎实例。
 */
@Concurrent
export function nativeLoadTask(modelDir: string, configJson: string): boolean {
  try {
    const ok: boolean = mnnchat.loadModel(modelDir, configJson) as boolean;
    return ok === true;
  } catch (err) {
    return false;
  }
}

@Concurrent
export function nativeReleaseTask(): boolean {
  try {
    mnnchat.releaseModel();
    return true;
  } catch (err) {
    return false;
  }
}

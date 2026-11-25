#ifndef MNN_ENGINE_WRAPPER_H
#define MNN_ENGINE_WRAPPER_H

#include <string>
#include <memory>
#include <thread>
#include <atomic>
#include <mutex>
#include <vector>
#include <utility>
#include "mnn_chat_types.h"

#ifdef HAVE_MNN_SDK
namespace MNN {
namespace Transformer {
    class Llm;
}
}
#endif

namespace mnnchat {

class MnnEngineWrapper {
public:
    static MnnEngineWrapper& getInstance();

    bool initEngine(const std::string& baseDir);
    bool loadModel(const std::string& modelDir, const ModelLoadParams& params);
    // 不重载模型，只把可热更新的配置（max_new_tokens / max_all_tokens / sampler）下发到已装载实例
    bool applyRuntimeConfig(const ModelLoadParams& params);
    bool isLoaded() const;
    void releaseModel();
    void resetSession();

    bool generateStream(
        const std::string& prompt,
        const std::vector<std::pair<std::string, std::string>>& history,
        TokenCallback onToken,
        CompleteCallback onComplete,
        ErrorCallback onError
    );

    void stopGenerate();
    InferenceStats getLastStats() const;
    std::string getVersion() const;
    // 最近一次真正下发给 MNN 的配置 JSON（设置页回显用）
    std::string getAppliedConfig() const;
    // 当前二进制是否编译自"无 MNN SDK"的仿真分支
    bool isSimulator() const;

private:
    MnnEngineWrapper();
    ~MnnEngineWrapper();

    MnnEngineWrapper(const MnnEngineWrapper&) = delete;
    MnnEngineWrapper& operator=(const MnnEngineWrapper&) = delete;

    std::string m_baseDir;
    std::string m_currentModelDir;
    std::string m_appliedConfig;
    ModelLoadParams m_currentParams;
    std::atomic<bool> m_isLoaded{false};
    std::atomic<bool> m_isGenerating{false};
    std::atomic<bool> m_cancelRequested{false};

    InferenceStats m_lastStats;
    mutable std::mutex m_mutex;
    // 专管 m_mnnLlm 的独占访问：worker 在 response() 期间持锁，UI 侧的 reset/release 必须等它退出，
    // 否则就是"UI 线程 reset 一个正在被推理线程使用的对象"——上架云测报的 Cpp Crash 就出自这里。
    mutable std::mutex m_llmMutex;
    std::thread m_workerThread;
    // 生成期间到达的配置热更新，落地到下一次 response 之前
    std::string m_pendingConfig;
    std::atomic<bool> m_hasPendingConfig{false};
    // 等生成线程真正退出（只在装载/卸载/析构这类必须确定时机的路径用，绝不放在 UI 线程的 stop 里）
    void joinWorker();

#ifdef HAVE_MNN_SDK
    std::unique_ptr<MNN::Transformer::Llm> m_mnnLlm;
#endif
};

// 加速后端能力探测：运行期尝试 dlopen 各 GPU 计算驱动，返回 JSON。
// HarmonyOS 只保证 libvulkan.so，OpenCL 取决于设备厂商是否把驱动暴露给应用进程。
std::string probeAccelerators();

} // namespace mnnchat

#endif // MNN_ENGINE_WRAPPER_H

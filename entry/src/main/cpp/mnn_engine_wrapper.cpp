#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "mnn_engine_wrapper.h"
#include "mnn_stream_buffer.hpp"
#include <chrono>
#include <sstream>
#include <vector>
#include <fstream>
#include <algorithm>
#include <cstdlib>
#include <string>
#include <cstdint>
#include <dlfcn.h>
#include <unistd.h>
#include <hilog/log.h>
#ifdef __linux__
#include <sched.h>
#include <unistd.h>
#endif

#ifdef HAVE_MNN_SDK
#include <MNN/expr/Expr.hpp>
#include <llm/llm.hpp>
#endif

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "MnnChatNative"

namespace mnnchat {
namespace {
bool fileExists(const std::string& path) {
    if (path.empty()) {
        return false;
    }
    return ::access(path.c_str(), F_OK) == 0;
}
}

// 从 /proc/self/statm 读取当前进程常驻内存，用于如实显示占用
static double readResidentMemoryMB() {
    std::ifstream statm("/proc/self/statm");
    if (!statm.is_open()) {
        return 0.0;
    }
    long totalPages = 0;
    long residentPages = 0;
    statm >> totalPages >> residentPages;
    long pageSize = 4096;
    return static_cast<double>(residentPages) * pageSize / (1024.0 * 1024.0);
}

// 组装下发到 MNN 的配置 JSON。max_new_tokens / max_all_tokens 属于可热更新项，
// 不必重载模型；thread_num / precision / memory / power 只在装载期生效。
namespace {

std::string readSmallFile(const std::string& path) {
    std::ifstream in(path);
    if (!in.is_open()) {
        return std::string();
    }
    std::string line;
    std::getline(in, line);
    return line;
}

struct CpuCluster {
    int maxFreqKHz = 0;
    std::vector<int> ids;
};

/** 通过 sysfs 读取每核最大频率并聚成簇（按频率升序：小核 -> 大核） */
std::vector<CpuCluster> probeCpuClusters() {
    std::vector<CpuCluster> clusters;
    for (int cpu = 0; cpu < 16; ++cpu) {
        std::string base = "/sys/devices/system/cpu/cpu" + std::to_string(cpu) + "/cpufreq/cpuinfo_max_freq";
        std::string freqStr = readSmallFile(base);
        if (freqStr.empty()) {
            continue;
        }
        int freq = std::atoi(freqStr.c_str());
        if (freq <= 0) {
            continue;
        }
        bool placed = false;
        for (auto& c : clusters) {
            if (c.maxFreqKHz == freq) {
                c.ids.push_back(cpu);
                placed = true;
                break;
            }
        }
        if (!placed) {
            CpuCluster c;
            c.maxFreqKHz = freq;
            c.ids.push_back(cpu);
            clusters.push_back(c);
        }
    }
    std::sort(clusters.begin(), clusters.end(),
              [](const CpuCluster& a, const CpuCluster& b) { return a.maxFreqKHz < b.maxFreqKHz; });
    return clusters;
}

/**
 * 把当前线程绑到大核簇。MNN 的 worker 线程是在首次 response 时从调用线程派生出来的，
 * 会继承调用线程的 affinity，所以在生成线程里调用一次就能把整个推理线程池钉在大核上。
 */
void applyBigCoreAffinity(int threadNum, const char* where) {
#ifdef __linux__
    auto clusters = probeCpuClusters();
    if (clusters.empty()) {
        OH_LOG_WARN(LOG_APP, "Affinity[%{public}s] skipped: cpu freq unreadable", where);
        return;
    }
    std::string desc;
    for (auto& c : clusters) {
        desc += " [" + std::to_string(c.maxFreqKHz / 1000) + "MHz:";
        for (size_t i = 0; i < c.ids.size(); ++i) {
            desc += (i == 0 ? "" : ",") + std::to_string(c.ids[i]);
        }
        desc += "]";
    }
    // 选核策略：优先在“单个簇”里取够 threadNum 个核（同簇同频最均匀）。
    // MNN 的线程池每个算子都要 barrier 同步，只要混进一个低频核，
    // 所有高频核都会被它拖住；所以宁可少用一个簇，也不要把大小核混着跑。
    std::vector<int> chosen;
    int remaining = threadNum > 0 ? threadNum : 4;

    // 1) 从快到慢找一个容量足够的簇，取它的前 remaining 个核
    for (int i = static_cast<int>(clusters.size()) - 1; i >= 0; --i) {
        if (static_cast<int>(clusters[i].ids.size()) >= remaining) {
            for (int k = 0; k < remaining; ++k) {
                chosen.push_back(clusters[i].ids[k]);
            }
            remaining = 0;
            break;
        }
    }
    // 2) 没有单簇能装下：从快到慢整簇取，最后用低频簇补齐
    if (remaining > 0) {
        chosen.clear();
        remaining = threadNum > 0 ? threadNum : 4;
        int groupIndex = static_cast<int>(clusters.size()) - 1;
        while (groupIndex >= 0 && remaining > 0) {
            auto& group = clusters[groupIndex];
            if (static_cast<int>(group.ids.size()) <= remaining) {
                chosen.insert(chosen.end(), group.ids.begin(), group.ids.end());
                remaining -= static_cast<int>(group.ids.size());
                groupIndex--;
            } else {
                for (int i = 0; i < remaining; ++i) {
                    chosen.push_back(group.ids[i]);
                }
                remaining = 0;
            }
        }
    }
    cpu_set_t mask;
    CPU_ZERO(&mask);
    for (int id : chosen) {
        CPU_SET(id, &mask);
    }
    int ret = sched_setaffinity(0, sizeof(mask), &mask);
    OH_LOG_INFO(LOG_APP, "Affinity[%{public}s] clusters:%{public}s -> chosen=%{public}zu ret=%{public}d",
                where, desc.c_str(), chosen.size(), ret);
#endif
}

} // namespace

static std::string buildConfigJson(const ModelLoadParams& params) {
    int threads = params.threads > 0 ? params.threads : 4;
    int maxNew = params.maxNewTokens > 0 ? params.maxNewTokens : 2048;
    int maxAll = params.contextLength > 0 ? params.contextLength : 4096;
    // 总 token 预算必须不小于“新生成 + prompt”，这里留出 prompt 余量
    if (maxAll < maxNew + 512) {
        maxAll = maxNew + 512;
    }
    std::string precision = params.precision.empty() ? "low" : params.precision;
    std::string memoryMode = params.memory.empty() ? "low" : params.memory;
    std::string powerMode = params.power.empty() ? "normal" : params.power;
    std::string sampler = params.sampler.empty() ? "greedy" : params.sampler;
    // MNN 用 backend_type 选择推理后端：cpu / opencl / metal。
    // 鸿蒙侧没有 libOpenCL，选 opencl 时 MNN 会加载失败并回落到 CPU，
    // 设置页在切换前会先用 probeAccelerators() 判断驱动是否存在。
    std::string backend = params.backend.empty() ? "cpu" : params.backend;
    std::ostringstream cfg;
    cfg << "{\"backend_type\":\"" << backend << "\""
        << ",\"thread_num\":" << threads
        << ",\"precision\":\"" << precision << "\""
        << ",\"memory\":\"" << memoryMode << "\""
        << ",\"power\":\"" << powerMode << "\""
        << ",\"sampler_type\":\"" << sampler << "\""
        << ",\"temperature\":" << params.temperature
        << ",\"top_p\":" << params.topP
        << ",\"top_k\":20"
        << ",\"max_new_tokens\":" << maxNew
        << ",\"max_all_tokens\":" << maxAll
        << "}";
    return cfg.str();
}

MnnEngineWrapper& MnnEngineWrapper::getInstance() {
    static MnnEngineWrapper instance;
    return instance;
}

MnnEngineWrapper::MnnEngineWrapper() {
    OH_LOG_INFO(LOG_APP, "MnnEngineWrapper initialized.");
}

MnnEngineWrapper::~MnnEngineWrapper() {
    stopGenerate();
    releaseModel();
}

bool MnnEngineWrapper::initEngine(const std::string& baseDir) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_baseDir = baseDir;
    OH_LOG_INFO(LOG_APP, "Engine initialized with base dir: %{public}s", baseDir.c_str());
    return true;
}

bool MnnEngineWrapper::loadModel(const std::string& modelDir, const ModelLoadParams& params) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_isGenerating.load()) {
        OH_LOG_WARN(LOG_APP, "Cannot load model while generating.");
        return false;
    }

    m_currentModelDir = modelDir;
    m_currentParams = params;

#ifdef HAVE_MNN_SDK
    try {
        std::string configPath = modelDir + "/config.json";
        // 先验证模型文件齐全：MNN 内部遇到缺失权重会走到 abort 路径，
        // 在云测的干净设备上直接表现为 Cpp Crash。
        if (!mnnchat::fileExists(configPath)) {
            OH_LOG_ERROR(LOG_APP, "Model config missing: %{public}s", configPath.c_str());
            m_isLoaded.store(false);
            return false;
        }
        if (!mnnchat::fileExists(modelDir + "/llm.mnn.weight")) {
            OH_LOG_ERROR(LOG_APP, "Model weight missing under: %{public}s", modelDir.c_str());
            m_isLoaded.store(false);
            return false;
        }
        OH_LOG_INFO(LOG_APP, "Loading MNN LLM model from: %{public}s", configPath.c_str());

        // 装载前先把本线程钉到大核，后续派生的 MNN worker 线程会继承这个 affinity
        applyBigCoreAffinity(params.threads, "load");

        {
            std::lock_guard<std::mutex> llmLock(m_llmMutex);
            m_mnnLlm.reset(MNN::Transformer::Llm::createLLM(configPath.c_str()));
            if (!m_mnnLlm) {
                OH_LOG_ERROR(LOG_APP, "Failed to create MNN LLM instance.");
                m_isLoaded.store(false);
                return false;
            }

            // 用 MNN 真实支持的键名覆盖模型自带 config.json：
            // thread_num / precision / memory / power / sampler_type
            std::string cfgStr = mnnchat::buildConfigJson(params);
            m_mnnLlm->set_config(cfgStr);
            m_appliedConfig = cfgStr;
            OH_LOG_INFO(LOG_APP, "MNN LLM config applied: %{public}s", cfgStr.c_str());

            m_mnnLlm->load();
        }
        m_isLoaded.store(true);
        OH_LOG_INFO(LOG_APP, "MNN LLM model loaded successfully.");
        return true;
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "Exception loading MNN model: %{public}s", e.what());
        m_isLoaded.store(false);
        return false;
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "Unknown exception loading MNN model.");
        m_isLoaded.store(false);
        return false;
    }
#else
    // Fallback native engine simulation when compiling without MNN prebuilt binaries
    OH_LOG_INFO(LOG_APP, "Running in High-Fidelity Native Simulator mode (model: %{public}s, threads: %{public}d)",
                modelDir.c_str(), params.threads);
    m_isLoaded.store(true);
    return true;
#endif
}

bool MnnEngineWrapper::applyRuntimeConfig(const ModelLoadParams& params) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_isLoaded.load()) {
        return false;
    }
    m_currentParams = params;
    std::string cfgStr = mnnchat::buildConfigJson(params);
#ifdef HAVE_MNN_SDK
    {
        // 生成中不能直接 set_config：MNN 正在读同一份配置对象。
        // 排队到下一次 response 之前落地，UI 立刻返回，不会"点了没反应"。
        std::unique_lock<std::mutex> llmLock(m_llmMutex, std::try_to_lock);
        if (!llmLock.owns_lock()) {
            m_pendingConfig = cfgStr;
            m_hasPendingConfig.store(true);
            m_appliedConfig = cfgStr;
            OH_LOG_INFO(LOG_APP, "MNN LLM config queued (generating): %{public}s", cfgStr.c_str());
            return true;
        }
        if (!m_mnnLlm) {
            return false;
        }
        m_mnnLlm->set_config(cfgStr);
    }
#endif
    m_appliedConfig = cfgStr;
    OH_LOG_INFO(LOG_APP, "MNN LLM config hot-updated: %{public}s", cfgStr.c_str());
    return true;
}

bool MnnEngineWrapper::isLoaded() const {
    return m_isLoaded.load();
}

void MnnEngineWrapper::releaseModel() {
    // 先在锁外把生成线程收干净：worker 结尾要拿 m_mutex 写统计，持锁 join 会死锁
    stopGenerate();
    joinWorker();
    std::lock_guard<std::mutex> lock(m_mutex);
#ifdef HAVE_MNN_SDK
    {
        std::lock_guard<std::mutex> llmLock(m_llmMutex);
        m_mnnLlm.reset();
    }
#endif
    m_isLoaded.store(false);
    OH_LOG_INFO(LOG_APP, "MNN LLM model released.");
}

void MnnEngineWrapper::resetSession() {
    // 关键：清上下文必须先把 worker 收掉。原来直接在 UI 线程 m_mnnLlm->reset()，
    // 而推理线程可能正在同一对象里跑 response()，这就是云测报的 Cpp Crash。
    stopGenerate();
    joinWorker();
#ifdef HAVE_MNN_SDK
    {
        std::lock_guard<std::mutex> llmLock(m_llmMutex);
        if (m_mnnLlm) {
            m_mnnLlm->reset();
        }
    }
#endif
    OH_LOG_INFO(LOG_APP, "MNN session reset.");
}

void MnnEngineWrapper::stopGenerate() {
    // 只置取消标志，立即返回：这个方法由 NAPI 同步调用，跑在 UI 线程上，
    // 一旦在这里 join，界面就会一直卡到 MNN 自己算到 max_new_tokens。
    // 置位后生成线程会在下一个 token 写入点抛异常退出（见 MnnOutputStream）。
    m_cancelRequested.store(true);
    OH_LOG_INFO(LOG_APP, "Cancel requested (non-blocking).");
}

void MnnEngineWrapper::joinWorker() {
    if (m_workerThread.joinable()) {
        m_workerThread.join();
    }
    m_isGenerating.store(false);
}

InferenceStats MnnEngineWrapper::getLastStats() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_lastStats;
}

std::string MnnEngineWrapper::getVersion() const {
    return "Alibaba MNN LLM Engine v2.9.2 (HarmonyOS Native Port)";
}

std::string MnnEngineWrapper::getAppliedConfig() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_appliedConfig;
}

bool MnnEngineWrapper::isSimulator() const {
#ifdef HAVE_MNN_SDK
    return false;
#else
    return true;
#endif
}

bool MnnEngineWrapper::generateStream(
    const std::string& prompt,
    const std::vector<std::pair<std::string, std::string>>& history,
    TokenCallback onToken,
    CompleteCallback onComplete,
    ErrorCallback onError
) {
    if (!m_isLoaded.load()) {
        if (onError) {
            onError("MNN model is not loaded. Please select and load a model first.");
        }
        return false;
    }

    if (m_isGenerating.load()) {
        if (!m_cancelRequested.load()) {
            if (onError) {
                onError("Another generation task is currently running.");
            }
            return false;
        }
        // 上一条已被用户停止：此时它正在 token 写入点退出，收尾耗时是毫秒级，
        // 在这里等一下再接着跑，比直接报"正在生成"更符合用户预期。
        joinWorker();
    }

    if (m_workerThread.joinable()) {
        m_workerThread.join();
    }

    m_cancelRequested.store(false);
    m_isGenerating.store(true);

    // 线程数在 UI 线程可能被热改，先快照下来，避免 worker 读 m_currentParams 时与写并发
    int threadsSnapshot = m_currentParams.threads;
    m_workerThread = std::thread([this, prompt, history, onToken, onComplete, onError, threadsSnapshot]() {
        auto startTime = std::chrono::high_resolution_clock::now();
        InferenceStats stats;
        // 这个线程会派生 MNN 的推理线程池，先把 affinity 钉到大核
        applyBigCoreAffinity(threadsSnapshot, "generate");

#ifdef HAVE_MNN_SDK
        // 输出流放在 try 外面，取消抛出异常后仍然能拿回已生成的字数与耗时
        MnnOutputStream outputStream(onToken, m_cancelRequested);
        bool cancelled = false;
        try {
            // 整个推理期间独占 m_mnnLlm：UI 侧的 reset/release/hot-config 都会在这把锁上排队，
            // 从根上消除"边生成边改对象"的竞争。
            std::lock_guard<std::mutex> llmLock(m_llmMutex);
            if (!m_mnnLlm) {
                throw std::runtime_error("model released before generation");
            }
            if (m_hasPendingConfig.exchange(false)) {
                m_mnnLlm->set_config(m_pendingConfig);
                OH_LOG_INFO(LOG_APP, "Applied queued config before response.");
            }
            // 多轮上下文有两种走法：
            //  - 有 chat template：把整段历史作为 ChatMessages 下发，MNN 自己做 prompt cache 前缀复用，
            //    不依赖内部 KV 是否还在（取消/重建上下文后依然接得上）；
            //  - 没有 template（纯 completion 模型）：退回只发本轮文本。
            bool useChatMessages = !history.empty() && m_mnnLlm->has_chat_template();
            if (useChatMessages) {
                MNN::Transformer::ChatMessages msgs;
                msgs.reserve(history.size());
                for (const auto& item : history) {
                    msgs.emplace_back(item.first, item.second);
                }
                m_mnnLlm->response(msgs, &outputStream);
            } else {
                m_mnnLlm->response(prompt, &outputStream);
            }
            outputStream.flushAll();
        } catch (const std::exception& e) {
            cancelled = m_cancelRequested.load();
            if (!cancelled) {
                OH_LOG_ERROR(LOG_APP, "Inference error: %{public}s", e.what());
                if (onError) {
                    onError(std::string("MNN Engine Error: ") + e.what());
                }
                if (m_mnnLlm) {
                    std::lock_guard<std::mutex> llmLock(m_llmMutex);
                    if (m_mnnLlm) {
                        m_mnnLlm->reset();
                    }
                }
                m_isGenerating.store(false);
                return;
            }
            OH_LOG_INFO(LOG_APP, "Generation aborted by cancel request.");
        }

        {
            auto endTime = std::chrono::high_resolution_clock::now();
            double totalMs = std::chrono::duration<double, std::milli>(endTime - startTime).count();

            stats.decodeTokens = outputStream.getTokenCount();
            stats.totalDurationMs = totalMs;
            // 首 token 延迟直接实测（不再写死 45ms）
            double firstTokenMs = outputStream.getFirstTokenMs();
            stats.prefillLatencyMs = firstTokenMs < 0 ? 0.0 : firstTokenMs;
            double decodeDurationSec = (totalMs - stats.prefillLatencyMs) / 1000.0;
            int decodedTokens = stats.decodeTokens > 0 ? stats.decodeTokens - 1 : 0;
            if (decodeDurationSec > 0.01 && decodedTokens > 0) {
                stats.decodeSpeedTokensPerSec = decodedTokens / decodeDurationSec;
            } else {
                stats.decodeSpeedTokensPerSec = stats.decodeTokens / (totalMs / 1000.0);
            }
            stats.peakMemoryMB = readResidentMemoryMB();
            OH_LOG_INFO(LOG_APP,
                        "Inference stats: tokens=%{public}d totalMs=%{public}.1f prefillMs=%{public}.1f decodeTokPerSec=%{public}.1f rssMB=%{public}.1f droppedBytes=%{public}d cancelled=%{public}d",
                        stats.decodeTokens, totalMs, stats.prefillLatencyMs,
                        stats.decodeSpeedTokensPerSec, stats.peakMemoryMB,
                        outputStream.getDroppedBytes(), cancelled ? 1 : 0);
        }

        if (cancelled && m_mnnLlm) {
            // 取消是在 token 写入点抛异常硬退的，KV 缓存停在半写状态，
            // 这里清一次上下文，避免下一条回答读到脏缓存。
            std::lock_guard<std::mutex> llmLock(m_llmMutex);
            if (m_mnnLlm) {
                m_mnnLlm->reset();
            }
            // 清完把状态拉回 RUNNING（reset 不会破坏已装载状态）
            OH_LOG_INFO(LOG_APP, "LLM context reset after cancel.");
        }

        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_lastStats = stats;
        }

        if (onComplete) {
            onComplete(stats);
        }
#else
        // Fallback realistic streaming simulation (supports DeepSeek Think tags + Markdown)
        auto prefillStart = std::chrono::high_resolution_clock::now();
        // Simulate prefill latency (approx 35ms)
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
        auto prefillEnd = std::chrono::high_resolution_clock::now();
        stats.prefillLatencyMs = std::chrono::duration<double, std::milli>(prefillEnd - prefillStart).count();

        // Prepare simulated tokens demonstrating Huawei official ArkUI design
        std::vector<std::string> tokens;
        bool isMathOrReasoning = (prompt.find("为什么") != std::string::npos ||
                                  prompt.find("思考") != std::string::npos ||
                                  prompt.find("代码") != std::string::npos ||
                                  prompt.find("鸿蒙") != std::string::npos);

        if (isMathOrReasoning) {
            tokens.push_back("<think>\n");
            tokens.push_back("收到问题：");
            tokens.push_back(prompt.substr(0, std::min<size_t>(prompt.length(), 24)));
            tokens.push_back("\n当前处于演示模式，没有真实模型权重，无法给出真正的推理结论。\n");
            tokens.push_back("</think>\n\n");
        }

        tokens.push_back("**演示模式**：当前二进制没有链接 MNN 推理库，");
        tokens.push_back("这条回复由内置示例引擎生成，仅用于验证流式输出与界面渲染。\n\n");
        tokens.push_back("模型文件可以从「模型」页下载并装载，");
        tokens.push_back("但要真正跑出模型结果，还需要把 `libMNN.so` / `libllm.so` 一起编进工程。\n\n");
        tokens.push_back("流式链路本身已经跑通：同一套 `startGenerateStream` 接口，");
        tokens.push_back("接入真实推理库后输出就会换成模型真实结果。");

        int tokenCount = 0;
        for (const auto& tok : tokens) {
            if (m_cancelRequested.load()) {
                break;
            }
            if (onToken) {
                onToken(tok);
            }
            tokenCount++;
            // Simulate realistic 30 tokens/sec decoding speed
            std::this_thread::sleep_for(std::chrono::milliseconds(32));
        }

        auto endTime = std::chrono::high_resolution_clock::now();
        double totalMs = std::chrono::duration<double, std::milli>(endTime - startTime).count();

        stats.decodeTokens = tokenCount;
        stats.totalDurationMs = totalMs;
        stats.decodeSpeedTokensPerSec = (tokenCount * 1000.0) / std::max(1.0, totalMs - stats.prefillLatencyMs);
        stats.peakMemoryMB = 860.0;

        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_lastStats = stats;
        }

        if (onComplete && !m_cancelRequested.load()) {
            onComplete(stats);
        }
#endif
        m_isGenerating.store(false);
    });

    return true;
}

} // namespace mnnchat

namespace {
// OpenCL 最小 ABI 声明：鸿蒙 SDK 不带 CL 头文件，这里只声明探测要用到的几个入口，
// 全部通过 dlopen/dlsym 在运行时解析，没有驱动时不会链接失败。
typedef int32_t cl_int_t;
typedef uint32_t cl_uint_t;
typedef void* cl_platform_id_t;
typedef void* cl_device_id_t;

typedef cl_int_t (*PFN_clGetPlatformIDs)(cl_uint_t, cl_platform_id_t*, cl_uint_t*);
typedef cl_int_t (*PFN_clGetPlatformInfo)(cl_platform_id_t, cl_uint_t, size_t, void*, size_t*);
typedef cl_int_t (*PFN_clGetDeviceIDs)(cl_platform_id_t, uint64_t, cl_uint_t, cl_device_id_t*, cl_uint_t*);
typedef cl_int_t (*PFN_clGetDeviceInfo)(cl_device_id_t, cl_uint_t, size_t, void*, size_t*);

const cl_uint_t CL_PLATFORM_NAME = 0x0902;
const cl_uint_t CL_DEVICE_NAME = 0x102B;
const uint64_t CL_DEVICE_TYPE_GPU = (1ULL << 2);
const uint64_t CL_DEVICE_TYPE_ALL = 0xFFFFFFFFULL;

std::string jsonEscape(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (c == '"' || c == '\\') {
            out.push_back('\\');
            out.push_back(c);
        } else if (c == '\n' || c == '\r' || c == '\t') {
            out.push_back(' ');
        } else {
            out.push_back(c);
        }
    }
    return out;
}
}

std::string mnnchat::probeAccelerators() {
    std::ostringstream ss;
    ss << "{";

    long cores = 0;
#ifdef __linux__
    cores = sysconf(_SC_NPROCESSORS_CONF);
#endif
    ss << "\"cpu\":{\"available\":true,\"cores\":" << (cores > 0 ? cores : 0) << "},";

    // ---- OpenCL ----
    ss << "\"opencl\":{";
    const char* clLibs[] = {"libOpenCL.so", "libOpenCL.so.1", "libopencl.so", "libOpenCL.so.3"};
    void* clHandle = nullptr;
    std::string clLibName;
    for (const char* name : clLibs) {
        clHandle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
        if (clHandle != nullptr) {
            clLibName = name;
            break;
        }
    }
    if (clHandle == nullptr) {
        ss << "\"available\":false,\"reason\":\"libOpenCL not found\",\"platforms\":0,\"devices\":0,\"deviceName\":\"\"";
        OH_LOG_INFO(LOG_APP, "probe: OpenCL driver not present");
    } else {
        auto pGetPlatformIDs = reinterpret_cast<PFN_clGetPlatformIDs>(dlsym(clHandle, "clGetPlatformIDs"));
        auto pGetPlatformInfo = reinterpret_cast<PFN_clGetPlatformInfo>(dlsym(clHandle, "clGetPlatformInfo"));
        auto pGetDeviceIDs = reinterpret_cast<PFN_clGetDeviceIDs>(dlsym(clHandle, "clGetDeviceIDs"));
        auto pGetDeviceInfo = reinterpret_cast<PFN_clGetDeviceInfo>(dlsym(clHandle, "clGetDeviceInfo"));
        cl_uint_t platformCount = 0;
        cl_int_t rc = pGetPlatformIDs ? pGetPlatformIDs(0, nullptr, &platformCount) : -1;
        std::string platformName;
        cl_uint_t deviceCount = 0;
        std::string deviceName;
        if (rc == 0 && platformCount > 0 && pGetPlatformIDs != nullptr) {
            cl_platform_id_t platform = nullptr;
            pGetPlatformIDs(1, &platform, nullptr);
            if (pGetPlatformInfo != nullptr) {
                char buf[256] = {0};
                pGetPlatformInfo(platform, CL_PLATFORM_NAME, sizeof(buf) - 1, buf, nullptr);
                platformName = buf;
            }
            if (pGetDeviceIDs != nullptr) {
                pGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 0, nullptr, &deviceCount);
                if (deviceCount > 0 && pGetDeviceInfo != nullptr) {
                    cl_device_id_t device = nullptr;
                    pGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 1, &device, nullptr);
                    char buf[256] = {0};
                    pGetDeviceInfo(device, CL_DEVICE_NAME, sizeof(buf) - 1, buf, nullptr);
                    deviceName = buf;
                }
            }
        }
        const bool ok = (rc == 0 && platformCount > 0 && deviceCount > 0);
        ss << "\"available\":" << (ok ? "true" : "false")
           << ",\"lib\":\"" << jsonEscape(clLibName) << "\""
           << ",\"platforms\":" << platformCount
           << ",\"devices\":" << deviceCount
           << ",\"platformName\":\"" << jsonEscape(platformName) << "\""
           << ",\"deviceName\":\"" << jsonEscape(deviceName) << "\"";
        if (!ok) {
            ss << ",\"reason\":\"driver loaded but no usable platform/device\"";
        }
        OH_LOG_INFO(LOG_APP, "probe: OpenCL lib=%{public}s platforms=%{public}u devices=%{public}u platform=%{public}s device=%{public}s",
                    clLibName.c_str(), platformCount, deviceCount, platformName.c_str(), deviceName.c_str());
        // 句柄保持打开到进程结束：真正跑 OpenCL 时 MNN 会自己 dlopen 同一个驱动，
        // 首次加载的初始化成本也提前摊掉了。
    }
    ss << "},";

    // ---- Vulkan ----
    ss << "\"vulkan\":{";
    const char* vkLibs[] = {"libvulkan.so", "libvulkan.so.1"};
    void* vkHandle = nullptr;
    std::string vkLibName;
    for (const char* name : vkLibs) {
        vkHandle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
        if (vkHandle != nullptr) {
            vkLibName = name;
            break;
        }
    }
    const bool vkHasEntry = vkHandle != nullptr && dlsym(vkHandle, "vkEnumerateInstanceVersion") != nullptr;
    ss << "\"available\":" << (vkHasEntry ? "true" : "false")
       << ",\"lib\":\"" << jsonEscape(vkLibName) << "\"";
    if (vkHandle == nullptr) {
        ss << ",\"reason\":\"libvulkan not found\"";
    }
    ss << "}";

    ss << "}";
    std::string report = ss.str();
    OH_LOG_INFO(LOG_APP, "probe report: %{public}s", report.c_str());
    return report;
}

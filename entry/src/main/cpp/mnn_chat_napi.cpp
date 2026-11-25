#include <napi/native_api.h>
#include <hilog/log.h>
#include <atomic>
#include <mutex>
#include <cstdlib>
#include <string>
#include <sstream>
#include <vector>
#include <memory>
#include "mnn_engine_wrapper.h"
#include "mnn_chat_types.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "MnnChatNapi"

namespace {

// 轻量 JSON 取值（只用于我们自己拼的扁平配置串）
static int jsonInt(const std::string& s, const std::string& key, int defVal) {
    size_t pos = s.find("\"" + key + "\"");
    if (pos == std::string::npos) {
        return defVal;
    }
    size_t colon = s.find(':', pos);
    if (colon == std::string::npos) {
        return defVal;
    }
    size_t i = colon + 1;
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) {
        i++;
    }
    int sign = 1;
    if (i < s.size() && s[i] == '-') {
        sign = -1;
        i++;
    }
    int value = 0;
    bool hasDigit = false;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') {
        value = value * 10 + (s[i] - '0');
        hasDigit = true;
        i++;
    }
    return hasDigit ? sign * value : defVal;
}

static std::string jsonStr(const std::string& s, const std::string& key, const std::string& defVal) {
    size_t pos = s.find("\"" + key + "\"");
    if (pos == std::string::npos) {
        return defVal;
    }
    size_t colon = s.find(':', pos);
    if (colon == std::string::npos) {
        return defVal;
    }
    size_t firstQuote = s.find('"', colon);
    if (firstQuote == std::string::npos) {
        return defVal;
    }
    size_t secondQuote = s.find('"', firstQuote + 1);
    if (secondQuote == std::string::npos) {
        return defVal;
    }
    return s.substr(firstQuote + 1, secondQuote - firstQuote - 1);
}

static float jsonFloat(const std::string& s, const std::string& key, float defVal) {
    size_t pos = s.find("\"" + key + "\"");
    if (pos == std::string::npos) {
        return defVal;
    }
    size_t colon = s.find(':', pos);
    if (colon == std::string::npos) {
        return defVal;
    }
    const char* begin = s.c_str() + colon + 1;
    while (*begin == ' ' || *begin == '\t') {
        begin++;
    }
    char* end = nullptr;
    float v = strtof(begin, &end);
    if (end == begin) {
        return defVal;
    }
    return v;
}

struct StreamContext {
    napi_env env = nullptr;
    napi_threadsafe_function tsfnToken = nullptr;
    napi_threadsafe_function tsfnComplete = nullptr;
    napi_threadsafe_function tsfnError = nullptr;
    // 三个 TSFN 只能释放一次：complete 与 error 互斥但 cancel 与 error 可能并发到达，
    // 重复调用 napi_release_threadsafe_function 在 OHOS 实现上是 UAF。
    std::atomic<bool> released{false};

    void releaseAll() {
        bool expected = false;
        if (!released.compare_exchange_strong(expected, true)) {
            return;
        }
        if (tsfnToken != nullptr) {
            napi_release_threadsafe_function(tsfnToken, napi_tsfn_release);
            tsfnToken = nullptr;
        }
        if (tsfnComplete != nullptr) {
            napi_release_threadsafe_function(tsfnComplete, napi_tsfn_release);
            tsfnComplete = nullptr;
        }
        if (tsfnError != nullptr) {
            napi_release_threadsafe_function(tsfnError, napi_tsfn_release);
            tsfnError = nullptr;
        }
    }
};

void CallJsToken(napi_env env, napi_value jsCallback, void* context, void* data) {
    if (env == nullptr || jsCallback == nullptr || data == nullptr) {
        OH_LOG_WARN(LOG_APP, "CallJsToken dropped (env=%{public}p cb=%{public}p data=%{public}p)",
                    env, jsCallback, data);
        return;
    }
    static int s_tokenCalls = 0;
    s_tokenCalls++;
    if (s_tokenCalls <= 3 || s_tokenCalls % 5 == 0) {
        OH_LOG_INFO(LOG_APP, "CallJsToken #%{public}d", s_tokenCalls);
    }
    std::string* tokenStr = static_cast<std::string*>(data);
    napi_value jsArg = nullptr;
    napi_create_string_utf8(env, tokenStr->c_str(), tokenStr->length(), &jsArg);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCallback, 1, &jsArg, nullptr);
    delete tokenStr;
}

void CallJsComplete(napi_env env, napi_value jsCallback, void* context, void* data) {
    if (env == nullptr || jsCallback == nullptr || data == nullptr) {
        return;
    }
    std::string* statsJson = static_cast<std::string*>(data);
    napi_value jsArg = nullptr;
    napi_create_string_utf8(env, statsJson->c_str(), statsJson->length(), &jsArg);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCallback, 1, &jsArg, nullptr);
    delete statsJson;
}

void CallJsError(napi_env env, napi_value jsCallback, void* context, void* data) {
    if (env == nullptr || jsCallback == nullptr || data == nullptr) {
        return;
    }
    std::string* errStr = static_cast<std::string*>(data);
    napi_value jsArg = nullptr;
    napi_create_string_utf8(env, errStr->c_str(), errStr->length(), &jsArg);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCallback, 1, &jsArg, nullptr);
    delete errStr;
}

static std::shared_ptr<StreamContext> g_activeStreamContext;
static std::mutex g_streamCtxMutex;

static std::shared_ptr<StreamContext> exchangeStreamContext(const std::shared_ptr<StreamContext>& next) {
    std::lock_guard<std::mutex> lock(g_streamCtxMutex);
    std::shared_ptr<StreamContext> prev = g_activeStreamContext;
    g_activeStreamContext = next;
    return prev;
}

} // anonymous namespace

// ArkTS: initEngine(baseDir: string): boolean
static napi_value InitEngine(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char dirBuf[512] = {0};
    size_t strLen = 0;
    if (argc >= 1) {
        napi_get_value_string_utf8(env, args[0], dirBuf, sizeof(dirBuf), &strLen);
    }

    bool success = mnnchat::MnnEngineWrapper::getInstance().initEngine(dirBuf);

    napi_value result = nullptr;
    napi_get_boolean(env, success, &result);
    return result;
}

// ArkTS: loadModel(modelDir: string, paramsJson: string): boolean
static napi_value LoadModel(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char modelDirBuf[512] = {0};
    size_t dirLen = 0;
    if (argc >= 1) {
        napi_get_value_string_utf8(env, args[0], modelDirBuf, sizeof(modelDirBuf), &dirLen);
    }

    mnnchat::ModelLoadParams params;
    if (argc >= 2) {
        char jsonBuf[1024] = {0};
        size_t jsonLen = 0;
        napi_get_value_string_utf8(env, args[1], jsonBuf, sizeof(jsonBuf), &jsonLen);
        std::string jsonStr(jsonBuf);

        // 按字段名取值，不依赖 "字段: 值" 的空格写法（ArkTS 的 JSON.stringify 不带空格）
        auto findInt = [&jsonStr](const std::string& key, int defVal) -> int {
            size_t pos = jsonStr.find("\"" + key + "\"");
            if (pos == std::string::npos) {
                return defVal;
            }
            size_t colon = jsonStr.find(':', pos);
            if (colon == std::string::npos) {
                return defVal;
            }
            size_t i = colon + 1;
            while (i < jsonStr.size() && (jsonStr[i] == ' ' || jsonStr[i] == '\t')) {
                i++;
            }
            int sign = 1;
            if (i < jsonStr.size() && jsonStr[i] == '-') {
                sign = -1;
                i++;
            }
            int value = 0;
            bool hasDigit = false;
            while (i < jsonStr.size() && jsonStr[i] >= '0' && jsonStr[i] <= '9') {
                value = value * 10 + (jsonStr[i] - '0');
                hasDigit = true;
                i++;
            }
            return hasDigit ? sign * value : defVal;
        };
        auto findString = [&jsonStr](const std::string& key, const std::string& defVal) -> std::string {
            size_t pos = jsonStr.find("\"" + key + "\"");
            if (pos == std::string::npos) {
                return defVal;
            }
            size_t colon = jsonStr.find(':', pos);
            size_t firstQuote = jsonStr.find('"', colon);
            if (colon == std::string::npos || firstQuote == std::string::npos) {
                return defVal;
            }
            size_t secondQuote = jsonStr.find('"', firstQuote + 1);
            if (secondQuote == std::string::npos) {
                return defVal;
            }
            return jsonStr.substr(firstQuote + 1, secondQuote - firstQuote - 1);
        };

        params.threads = findInt("threads", 4);
        params.backend = findString("backend", "cpu");
        params.precision = findString("precision", "low");
        params.maxNewTokens = findInt("maxTokens", 2048);
        params.contextLength = findInt("contextLength", 4096);
        params.memory = findString("memory", "low");
        params.power = findString("power", "normal");
        params.sampler = findString("sampler", "greedy");
        params.temperature = jsonFloat(jsonStr, "temperature", 0.7f);
        params.topP = jsonFloat(jsonStr, "topP", 0.9f);
        OH_LOG_INFO(LOG_APP,
                    "LoadModel params: threads=%{public}d backend=%{public}s precision=%{public}s memory=%{public}s power=%{public}s maxNew=%{public}d ctx=%{public}d",
                    params.threads, params.backend.c_str(), params.precision.c_str(),
                    params.memory.c_str(), params.power.c_str(),
                    params.maxNewTokens, params.contextLength);
    }

    bool success = mnnchat::MnnEngineWrapper::getInstance().loadModel(modelDirBuf, params);

    napi_value result = nullptr;
    napi_get_boolean(env, success, &result);
    return result;
}

// ArkTS: applyRuntimeConfig(paramsJson): boolean —— 不重载模型，热更新输出上限/上下文/采样器
static napi_value ApplyRuntimeConfig(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    mnnchat::ModelLoadParams params;
    std::string jsonStrIn;
    if (argc >= 1) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        jsonStrIn.resize(len + 1);
        napi_get_value_string_utf8(env, args[0], jsonStrIn.data(), len + 1, &len);
        jsonStrIn.resize(len);

        params.threads = jsonInt(jsonStrIn, "threads", 4);
        params.precision = jsonStr(jsonStrIn, "precision", "low");
        params.memory = jsonStr(jsonStrIn, "memory", "low");
        params.power = jsonStr(jsonStrIn, "power", "normal");
        params.sampler = jsonStr(jsonStrIn, "sampler", "greedy");
        params.maxNewTokens = jsonInt(jsonStrIn, "maxTokens", 2048);
        params.contextLength = jsonInt(jsonStrIn, "contextLength", 4096);
        params.temperature = jsonFloat(jsonStrIn, "temperature", 0.7f);
        params.topP = jsonFloat(jsonStrIn, "topP", 0.9f);
    }

    bool ok = mnnchat::MnnEngineWrapper::getInstance().applyRuntimeConfig(params);
    OH_LOG_INFO(LOG_APP, "ApplyRuntimeConfig result=%{public}d json=%{public}s",
                ok ? 1 : 0, jsonStrIn.c_str());
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

// ArkTS: isModelLoaded(): boolean
static napi_value IsModelLoaded(napi_env env, napi_callback_info info) {
    bool loaded = mnnchat::MnnEngineWrapper::getInstance().isLoaded();
    napi_value result = nullptr;
    napi_get_boolean(env, loaded, &result);
    return result;
}

// ArkTS: releaseModel(): boolean
static napi_value ReleaseModel(napi_env env, napi_callback_info info) {
    mnnchat::MnnEngineWrapper::getInstance().releaseModel();
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

// ArkTS: resetSession(): boolean
static napi_value ResetSession(napi_env env, napi_callback_info info) {
    mnnchat::MnnEngineWrapper::getInstance().resetSession();
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

// ArkTS: stopGenerate(): boolean
static napi_value StopGenerate(napi_env env, napi_callback_info info) {
    mnnchat::MnnEngineWrapper::getInstance().stopGenerate();
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

// ArkTS: startGenerateStream(prompt, roles[], contents[], onToken, onComplete, onError): boolean
static napi_value StartGenerateStream(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 6) {
        napi_throw_type_error(env, nullptr, "startGenerateStream requires 6 arguments");
        return nullptr;
    }

    // 1. Prompt string
    char promptBuf[4096] = {0};
    size_t promptLen = 0;
    napi_get_value_string_utf8(env, args[0], promptBuf, sizeof(promptBuf), &promptLen);
    std::string promptStr(promptBuf);

    // 2. 对话历史：roles[] + contents[]，逐个取字符串，避免在 C++ 里造 JSON 解析器
    std::vector<std::pair<std::string, std::string>> history;
    uint32_t roleCount = 0;
    uint32_t contentCount = 0;
    napi_get_array_length(env, args[1], &roleCount);
    napi_get_array_length(env, args[2], &contentCount);
    uint32_t count = roleCount < contentCount ? roleCount : contentCount;
    history.reserve(count);
    for (uint32_t i = 0; i < count; i++) {
        napi_value rv = nullptr;
        napi_value cv = nullptr;
        napi_get_element(env, args[1], i, &rv);
        napi_get_element(env, args[2], i, &cv);

        std::size_t rLen = 0;
        napi_get_value_string_utf8(env, rv, nullptr, 0, &rLen);
        // napi 会写入 rLen 个字符 + '\0'，缓冲区必须是 rLen + 1，
        // 原来申请 rLen 却传 rLen + 1 是堆溢出，随机崩溃的来源之一。
        std::string role(rLen + 1, '\0');
        napi_get_value_string_utf8(env, rv, role.data(), rLen + 1, &rLen);
        role.resize(rLen);

        std::size_t cLen = 0;
        napi_get_value_string_utf8(env, cv, nullptr, 0, &cLen);
        std::string content(cLen + 1, '\0');
        napi_get_value_string_utf8(env, cv, content.data(), cLen + 1, &cLen);
        content.resize(cLen);

        history.emplace_back(role, content);
    }
    OH_LOG_INFO(LOG_APP, "history messages=%{public}u promptLen=%{public}zu", count, promptStr.size());

    // 3. ThreadSafe functions for async callbacks
    auto streamCtx = std::make_shared<StreamContext>();
    streamCtx->env = env;

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "MnnStreamToken", NAPI_AUTO_LENGTH, &resourceName);
    napi_status tokenStatus = napi_create_threadsafe_function(env, args[3], nullptr, resourceName, 0, 1, nullptr,
                                   nullptr, nullptr, CallJsToken, &streamCtx->tsfnToken);

    napi_create_string_utf8(env, "MnnStreamComplete", NAPI_AUTO_LENGTH, &resourceName);
    napi_status completeStatus = napi_create_threadsafe_function(env, args[4], nullptr, resourceName, 0, 1, nullptr,
                                   nullptr, nullptr, CallJsComplete, &streamCtx->tsfnComplete);

    napi_create_string_utf8(env, "MnnStreamError", NAPI_AUTO_LENGTH, &resourceName);
    napi_status errorStatus = napi_create_threadsafe_function(env, args[5], nullptr, resourceName, 0, 1, nullptr,
                                   nullptr, nullptr, CallJsError, &streamCtx->tsfnError);

    OH_LOG_INFO(LOG_APP, "TSFN status token=%{public}d complete=%{public}d error=%{public}d",
                tokenStatus, completeStatus, errorStatus);

    // 旧上下文可能还在收尾，不要直接覆盖：先拿到旧引用，由它自己在回调里释放 TSFN。
    auto previousCtx = exchangeStreamContext(streamCtx);
    (void)previousCtx;

    auto onToken = [streamCtx](const std::string& token) {
        if (streamCtx && streamCtx->tsfnToken != nullptr && !streamCtx->released.load()) {
            std::string* data = new std::string(token);
            // 必须是非阻塞投递：TSFN 队列无上限（创建时 max_queue_size=0），
            // 用 blocking 会让解码线程等 JS 线程渲染完 Markdown 才继续，
            // 实测把 100 t/s 的模型拖到 13 t/s。
            napi_call_threadsafe_function(streamCtx->tsfnToken, data, napi_tsfn_nonblocking);
        }
    };

    auto onComplete = [streamCtx](const mnnchat::InferenceStats& stats) {
        if (streamCtx && streamCtx->tsfnComplete != nullptr) {
            std::ostringstream ss;
            ss << "{"
               << "\"prefillLatencyMs\":" << stats.prefillLatencyMs << ","
               << "\"decodeTokens\":" << stats.decodeTokens << ","
               << "\"decodeSpeedTokensPerSec\":" << stats.decodeSpeedTokensPerSec << ","
               << "\"peakMemoryMB\":" << stats.peakMemoryMB << ","
               << "\"totalDurationMs\":" << stats.totalDurationMs
               << "}";
            std::string* data = new std::string(ss.str());
            // 这里也改非阻塞：退到后台/退出应用时 JS 线程可能已经不再泵消息，
            // blocking 会把原生线程永久挂在 teardown 阶段，表现为卡死或崩溃。
            napi_call_threadsafe_function(streamCtx->tsfnComplete, data, napi_tsfn_nonblocking);
            streamCtx->releaseAll();
        }
    };

    auto onError = [streamCtx](const std::string& err) {
        if (streamCtx && streamCtx->tsfnError != nullptr) {
            std::string* data = new std::string(err);
            napi_call_threadsafe_function(streamCtx->tsfnError, data, napi_tsfn_nonblocking);
            streamCtx->releaseAll();
        }
    };

    bool started = mnnchat::MnnEngineWrapper::getInstance().generateStream(
        promptStr, history, onToken, onComplete, onError
    );
    if (!started) {
        // 未装载模型等失败路径，若引擎没有回调 onError，这里兜底释放，避免 TSFN 泄漏
        streamCtx->releaseAll();
    }
    OH_LOG_INFO(LOG_APP, "generateStream started=%{public}d promptLen=%{public}zu", started, promptStr.size());

    napi_value result = nullptr;
    napi_get_boolean(env, started, &result);
    return result;
}

// ArkTS: getInferenceStats(): string
static napi_value GetInferenceStats(napi_env env, napi_callback_info info) {
    auto stats = mnnchat::MnnEngineWrapper::getInstance().getLastStats();
    std::ostringstream ss;
    ss << "{"
       << "\"prefillLatencyMs\":" << stats.prefillLatencyMs << ","
       << "\"decodeTokens\":" << stats.decodeTokens << ","
       << "\"decodeSpeedTokensPerSec\":" << stats.decodeSpeedTokensPerSec << ","
       << "\"peakMemoryMB\":" << stats.peakMemoryMB << ","
       << "\"totalDurationMs\":" << stats.totalDurationMs
       << "}";
    std::string str = ss.str();

    napi_value result = nullptr;
    napi_create_string_utf8(env, str.c_str(), str.length(), &result);
    return result;
}

// ArkTS: getEngineVersion(): string
static napi_value GetEngineVersion(napi_env env, napi_callback_info info) {
    std::string ver = mnnchat::MnnEngineWrapper::getInstance().getVersion();
    napi_value result = nullptr;
    napi_create_string_utf8(env, ver.c_str(), ver.length(), &result);
    return result;
}

// ArkTS: isSimulatorEngine(): boolean
static napi_value IsSimulatorEngine(napi_env env, napi_callback_info info) {
    bool sim = mnnchat::MnnEngineWrapper::getInstance().isSimulator();
    napi_value result = nullptr;
    napi_get_boolean(env, sim, &result);
    return result;
}

// ArkTS: getAppliedConfig(): string
static napi_value GetAppliedConfig(napi_env env, napi_callback_info info) {
    std::string cfg = mnnchat::MnnEngineWrapper::getInstance().getAppliedConfig();
    napi_value result = nullptr;
    napi_create_string_utf8(env, cfg.c_str(), cfg.length(), &result);
    return result;
}

// ArkTS: probeAccelerators(): string (JSON)
static napi_value ProbeAccelerators(napi_env env, napi_callback_info info) {
    std::string report = mnnchat::probeAccelerators();
    napi_value result = nullptr;
    napi_create_string_utf8(env, report.c_str(), report.length(), &result);
    return result;
}

// Module initialization
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"initEngine", nullptr, InitEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadModel", nullptr, LoadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isModelLoaded", nullptr, IsModelLoaded, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"applyRuntimeConfig", nullptr, ApplyRuntimeConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseModel", nullptr, ReleaseModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resetSession", nullptr, ResetSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startGenerateStream", nullptr, StartGenerateStream, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopGenerate", nullptr, StopGenerate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getInferenceStats", nullptr, GetInferenceStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getEngineVersion", nullptr, GetEngineVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAppliedConfig", nullptr, GetAppliedConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isSimulatorEngine", nullptr, IsSimulatorEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeAccelerators", nullptr, ProbeAccelerators, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module mnnchatModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mnnchat",
    .nm_priv = ((void*)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterMnnChatModule(void) {
    napi_module_register(&mnnchatModule);
}

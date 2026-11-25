#ifndef MNN_CHAT_TYPES_H
#define MNN_CHAT_TYPES_H

#include <string>
#include <functional>
#include <chrono>

namespace mnnchat {

struct InferenceStats {
    double prefillLatencyMs = 0.0;
    int decodeTokens = 0;
    double decodeSpeedTokensPerSec = 0.0;
    double peakMemoryMB = 0.0;
    double totalDurationMs = 0.0;
};

struct ModelLoadParams {
    int threads = 4;
    std::string precision = "normal"; // "low" (int4), "normal" (int8/fp16), "high" (fp32)
    std::string backend = "cpu";      // "cpu", "opencl"
    int contextLength = 4096;
    int maxNewTokens = 2048;
    std::string memory = "low";       // "low" 在线反量化 / "normal" 展开权重
    std::string power = "normal";     // "high" 绑大核高性能 / "normal"
    std::string sampler = "greedy";   // "greedy" 最快 / "mixed" 启用 temperature+topP
    float temperature = 0.7f;
    float topP = 0.9f;
};

using TokenCallback = std::function<void(const std::string& token)>;
using CompleteCallback = std::function<void(const InferenceStats& stats)>;
using ErrorCallback = std::function<void(const std::string& errorMessage)>;

} // namespace mnnchat

#endif // MNN_CHAT_TYPES_H

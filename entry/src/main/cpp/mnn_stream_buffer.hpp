#ifndef MNN_STREAM_BUFFER_HPP
#define MNN_STREAM_BUFFER_HPP

#include <iostream>
#include <streambuf>
#include <string>
#include <functional>
#include <atomic>
#include <chrono>
#include "mnn_chat_types.h"

namespace mnnchat {

/**
 * MNN LLM 通过 std::ostream 逐 token 写文本。逐 token 回调到 ArkTS 代价很高：
 * 每次都要跨线程 TSFN + JS 回调 + 整篇 Markdown 重排，会和推理线程抢 CPU。
 * 这里按"时间窗口 + 体量阈值"攒批：30ms 或 64 字符先到者触发一次回调，
 * 结束时 flushAll() 强制吐净，观感仍是逐字出现。
 */
class MnnStreamBuffer : public std::streambuf {
public:
    explicit MnnStreamBuffer(TokenCallback onToken, std::atomic<bool>& cancelFlag)
        : m_onToken(onToken), m_cancelFlag(cancelFlag), m_tokenCount(0),
          m_firstTokenMs(-1.0), m_invalidBytes(0), m_startTime(std::chrono::steady_clock::now()),
          m_lastFlush(m_startTime) {}

    int overflow(int c) override {
        if (m_cancelFlag.load()) {
            return traits_type::eof();
        }
        if (c != traits_type::eof()) {
            m_buffer += static_cast<char>(c);
            maybeFlush();
        }
        return c;
    }

    std::streamsize xsputn(const char* s, std::streamsize n) override {
        if (m_cancelFlag.load()) {
            return 0;
        }
        // MNN 每个 token 调一次 xsputn，按调用次数统计 token
        m_tokenCount++;
        if (m_firstTokenMs < 0) {
            m_firstTokenMs = elapsedMs();
        }
        m_buffer.append(s, static_cast<size_t>(n));
        maybeFlush();
        return n;
    }

    void flushBuffer(bool force = false) {
        if (m_buffer.empty()) {
            return;
        }
        // 先剔除非法字节，再只在完整 UTF-8 字符边界切分。
        // 逐 token 输出的是 byte-level BPE 的片段，一个汉字/emoji 会跨多个 token，
        // 必须把不完整的尾序列留到下一批，否则 ArkTS 侧解出残字。
        size_t safeLen = 0;
        std::string sanitized = sanitizeUtf8(m_buffer, safeLen, force);
        m_buffer.erase(0, safeLen);
        if (sanitized.empty()) {
            return;
        }
        if (m_onToken && !m_cancelFlag.load()) {
            m_onToken(sanitized);
        }
        m_lastFlush = std::chrono::steady_clock::now();
    }

    int sync() override {
        flushBuffer(true);
        return 0;
    }

    int getTokenCount() const {
        return m_tokenCount;
    }

    double getFirstTokenMs() const {
        return m_firstTokenMs;
    }

    int getDroppedBytes() const {
        return m_invalidBytes;
    }

private:
    /**
     * 严格按 UTF-8 走一遍缓冲区：
     *  - 合法的完整字符原样保留
     *  - 末尾尚未收齐的多字节序列保留在缓冲区，等待下一批
     *  - 中间出现的非法字节直接丢弃（避免把残码喂给 ArkTS 产生乱码）
     * 返回值是本次可以回调的文本；consumed 是缓冲区应移除的字节数。
     */
    std::string sanitizeUtf8(const std::string& src, size_t& consumed, bool force) {
        std::string out;
        out.reserve(src.size());
        size_t i = 0;
        size_t n = src.size();
        consumed = 0;
        while (i < n) {
            unsigned char c = static_cast<unsigned char>(src[i]);
            size_t need = 0;
            if (c < 0x80) {
                out.push_back(src[i]);
                i += 1;
                consumed = i;
                continue;
            }
            if ((c & 0xE0) == 0xC0) {
                need = 2;
            } else if ((c & 0xF0) == 0xE0) {
                need = 3;
            } else if ((c & 0xF8) == 0xF0) {
                need = 4;
            } else {
                // 孤立 continuation byte 或非法 lead（0xF8+）：丢弃
                m_invalidBytes++;
                i += 1;
                consumed = i;
                continue;
            }
            if (i + need > n) {
                if (force) {
                    // 流已结束，残留的半截字符无法还原，丢弃
                    m_invalidBytes++;
                    consumed = n;
                    i = n;
                }
                // 否则留给下一批
                break;
            }
            bool ok = true;
            for (size_t k = 1; k < need; k++) {
                unsigned char cc = static_cast<unsigned char>(src[i + k]);
                if ((cc & 0xC0) != 0x80) {
                    ok = false;
                    break;
                }
            }
            if (!ok) {
                m_invalidBytes++;
                i += 1;
                consumed = i;
                continue;
            }
            out.append(src, i, need);
            i += need;
            consumed = i;
        }
        return out;
    }

    int getInvalidBytes() const {
        return m_invalidBytes;
    }

    double elapsedMs() const {        auto now = std::chrono::steady_clock::now();
        return std::chrono::duration<double, std::milli>(now - m_startTime).count();
    }

    void maybeFlush() {
        if (m_buffer.empty()) {
            return;
        }
        if (m_buffer.size() >= 64) {
            flushBuffer();
            return;
        }
        double sinceLast = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - m_lastFlush).count();
        if (sinceLast >= 30.0) {
            flushBuffer();
        }
    }

    std::string m_buffer;
    TokenCallback m_onToken;
    std::atomic<bool>& m_cancelFlag;
    int m_tokenCount;
    double m_firstTokenMs;
    int m_invalidBytes;
    std::chrono::steady_clock::time_point m_startTime;
    std::chrono::steady_clock::time_point m_lastFlush;
};

class MnnOutputStream : public std::ostream {
public:
    explicit MnnOutputStream(TokenCallback onToken, std::atomic<bool>& cancelFlag)
        : std::ostream(&m_buffer), m_buffer(onToken, cancelFlag) {
        // 关键：用户点“停止”时让写入失败立刻抛异常，
        // 直接把控制流从 MNN 的 token 生成循环里摘出来。
        // 否则 MNN 会一路算到 max_new_tokens 才返回，stop 就成了几十秒的卡死。
        this->exceptions(std::ios_base::badbit | std::ios_base::failbit);
    }

    int getTokenCount() const {
        return m_buffer.getTokenCount();
    }

    double getFirstTokenMs() const {
        return m_buffer.getFirstTokenMs();
    }

    void flushAll() {
        m_buffer.sync();
    }

    int getDroppedBytes() const {
        return m_buffer.getDroppedBytes();
    }

private:
    MnnStreamBuffer m_buffer;
};

} // namespace mnnchat

#endif // MNN_STREAM_BUFFER_HPP

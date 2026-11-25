# LocAI

**基于阿里巴巴 MNN 推理引擎的 HarmonyOS 端侧离线 AI 对话应用。**

LocAI 把大模型完整跑在手机本地：装载模型后全程离线推理，对话内容不出设备。这个仓库是 **LocAI 社区版（GitHub 分发版）**，与华为应用市场版本的区别是：应用市场版为了过审不联网、模型只能本地导入；社区版恢复了**在线拉取模型**，打开应用即可从魔搭 ModelScope 直接拉一个 MNN 模型下来对话。

- 包名：`com.henry.local`
- 版本：`1.1.0`（versionCode 1000002）
- 目标 SDK：HarmonyOS API 26，向下兼容 HarmonyOS 6.0.0（API 20）
- 安装包：`dist/LocAI-1.1.0-signed.hap`（约 7.5 MB，不含模型；模型按需拉取）

---

## 功能

- **在线模型库**：从魔搭 ModelScope 的 `MNN` 组织公开仓库拉取模型，内置 Qwen3-0.6B、Qwen2.5-0.5B / 1.5B、TinyLlama-1.1B、Qwen3-1.7B 五个条目，带实时进度、速度与体积。
- **本地导入**：自己用 `llmexport.py` 导出 MNN 模型目录，打成 zip 后从文件选择器导入（解压、识别 `config.json`、登记清单）。
- **端侧推理**：C++ NAPI 封装 `MNN::Transformer::Llm`，流式 Token 经线程安全函数回传 ArkUI，首 Token / 解码速率 / 峰值内存实时可见。
- **对话体验**：Markdown 与代码高亮、公式排版、深度思考（CoT）折叠卡片、会话历史、复制与重新生成。
- **模型级参数**：每个模型独立保存 temperature / top-p / 上下文长度 / 线程数 / 量化精度 / 系统提示词。
- **合规与隐私**：首启隐私政策同意页、设置页政策入口、AI 生成内容显式标识与隐式水印；`INTERNET` 权限只用于在线拉取模型。

## 在线模型库

| 模型 | 参数量 | 大小 | 说明 |
| --- | --- | --- | --- |
| Qwen3-0.6B | 0.6B | 399.5 MB | 推荐，中文对话与指令跟随最稳 |
| Qwen2.5-0.5B-Instruct | 0.5B | 255.3 MB | 最轻量，下载与装载最快 |
| TinyLlama-1.1B-Chat | 1.1B | 526.5 MB | 英文对话，中文辅助 |
| Qwen2.5-1.5B-Instruct | 1.5B | 788 MB | 能力与速度均衡，建议 8 GB 内存 |
| Qwen3-1.7B | 1.7B | 1077 MB | 长回答质量最好，装载较慢 |

下载地址拼装规则（公开仓库，无需登录）：

```
https://modelscope.cn/api/v1/models/{owner}/{repo}/repo?Revision=master&FilePath={file}
```

每个模型固定 5 个文件：`config.json`、`llm_config.json`、`llm.mnn`、`llm.mnn.weight`、`tokenizer.mtok`。下载完成后落到应用私有目录 `files/models/<id>/` 并登记到 `files/models/manifest.json`。

## 安装（侧载）

> 鸿蒙应用没有 Android 那种“任意 apk 装了就完事”的自由度：官方明确「暂不支持侧载（直接安装包体）」，安装必须带合法签名。下面两条路都能用，按你的情况选。

**方式一：直接装已签名包（推荐先试）**

1. 手机开启「开发者模式」与「USB 调试」，用数据线连电脑，手机上允许调试授权；
2. 电脑装好 DevEco Studio（自带 `hdc`），执行：

```powershell
hdc list targets
hdc install -r dist\LocAI-1.1.0-signed.hap
hdc shell aa start -a EntryAbility -b com.henry.local
```

`dist/` 里的包使用作者在 AGC 申请的**发布证书 + app_gallery 发布 Profile** 签名（有效期至 2029-11-22），签名链校验通过。如果系统提示签名与设备策略不符（部分机型会拦发布证书直装），改用方式二。

**方式二：自己签名（最稳）**

1. 用 DevEco Studio 打开本仓库工程；
2. `File → Project Structure → Signing Configs` 勾选 **Automatically generate signature**，登录你的华为开发者账号（需实名）；
3. 连接手机，点 **Run 'entry'**，DevEco 会用你的调试证书重签并直接装上。

调试签名会写入你设备的 UDID，**只对你自己注册过的设备有效**，不要把它当成可分发的安装包。仓库里的 `dist/LocAI-1.1.0-unsigned.hap` 供你自己签名使用。

## 从源码构建

环境：DevEco Studio 6.0（自带 API 26 SDK）、Node 与 hvigor 随 IDE 提供、`arm64-v8a` 真机。

```powershell
# 命令行编译（Windows，pwsh）
$env:PATH = "D:\Apps\DevEco Studio\tools\node;D:\Apps\DevEco Studio\tools\hvigor\bin;D:\Apps\DevEco Studio\jbr\bin;D:\Apps\DevEco Studio\sdk\default\openharmony\toolchains;" + $env:PATH
$env:DEVECO_SDK_HOME = "D:\Apps\DevEco Studio\sdk"
hvigorw --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

产物在 `entry/build/default/outputs/default/`。仓库不含 `.cert/`（`.gitignore` 已排除 p12 / cer / p7b），`build-profile.json5` 的签名配置指向 `.cert/locai.p12`，所以**在你自己的机器上要么补上证书，要么改成你的签名配置**；只编译不装可用 `-BuildOnly`：

```powershell
pwsh -File scripts\build-and-install.ps1 -BuildOnly
```

## 工程结构

```
locai_github/
├── AppScope/                         # 应用级配置与图标
├── entry/src/main/
│   ├── cpp/                          # MNN 桥接层（NAPI、流式缓冲、引擎包装）
│   ├── ets/
│   │   ├── entryability/EntryAbility.ets   # 窗口沉浸、首启同意页、自动装载
│   │   ├── common/                         # 设计令牌、日志、沉浸工具
│   │   ├── model/
│   │   │   ├── OnlineModels.ets            # 在线模型目录（仓库、文件、体积）
│   │   │   ├── ModelConfig.ets             # 模型展示实体
│   │   │   └── InferenceParams.ets
│   │   ├── service/
│   │   │   ├── ModelDownloadService.ets    # 在线拉取 / 本地导入 / 清单 / 删除
│   │   │   ├── MnnChatService.ets          # 推理调度与流式解析
│   │   │   └── SessionService.ets          # 会话持久化
│   │   ├── components/                     # 气泡、输入栏、Markdown、CoT 卡片等
│   │   └── pages/
│   │       ├── ChatPage.ets                # 对话主界面
│   │       ├── ModelManagerPage.ets        # 模型管理（含在线模型库入口）
│   │       ├── OnlineModelPage.ets         # 在线模型库浮层
│   │       └── SettingsPage.ets            # 推理参数与应用信息
│   └── resources/                          # 字符串、颜色、图标
├── scripts/build-and-install.ps1     # 一键编译 / 装机
└── dist/                             # 已打包的 HAP 与校验值
```

## 权限与隐私

- 仅申请 `ohos.permission.INTERNET`，用途是**在线拉取模型**；对话、会话记录、参数配置全部留在应用沙箱，不上传任何内容。
- 模型下载结束后可断网使用；卸载应用时系统会一并清除模型与对话记录。
- 回复会带「内容由 AI 生成」标识，并写入隐式水印用于溯源；内容可能存在误差，不构成专业意见。

## 已知限制

- 仅打包 `arm64-v8a`（MNN 原生库如此），**x86_64 模拟器装不上**，请用真机。
- 1.5B / 1.7B 模型首轮装载峰值内存较高，内存小于 8 GB 的设备建议先用 0.5B / 0.6B。
- 在线拉取只覆盖魔搭 `MNN` 组织的公开仓库；想用别的模型请自行导出后用 zip 导入。
- 发布证书签名包在部分机型会被系统策略拦下，这是鸿蒙分发机制决定的，此时请自行用调试证书签名。

## 许可

- 本仓库代码：Apache License 2.0（见 `LICENSE`）。
- 推理引擎：阿里巴巴 [MNN](https://github.com/alibaba/MNN)，Apache License 2.0。
- 模型权重版权归各模型原作者，下载即表示你同意对应仓库的许可条款（魔搭 `MNN` 组织仓库均为公开模型）。

## 更新日志

**1.1.0（2026-11-25）**

- 恢复在线拉取模型：新增在线模型库页面，五款 MNN 模型带进度下载，落盘即登记。
- 社区版不再内置 0.3B 演示模型，安装包从 175 MB 降到 7.5 MB，模型按需下载。
- 重新申请 `INTERNET` 权限，仅用于模型下载。
- 打包签名改为 AGC 发布证书（`com.henry.local`），并提供未签名包供自行签名。

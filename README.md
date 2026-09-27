# ASR 语音转文字客户端 (ASR Client)

一款现代、高效、跨平台的语音转文字客户端，支持 **Windows 桌面端** 与 **Android 移动端**。内置多 ASR 服务商支持（小米 MiMo、硅基流动 SenseVoice、Groq、OpenAI、本地 Faster-Whisper 等），支持复数音频文件批量排队与多开并发转写、长录音 VAD 智能分段停顿切片及两阶段断点自愈容灾。

---

## ✨ 核心特性

- 📁 **多文件批量转写（多开队列）**：支持一次性拖入或批量多选导入复数个音频文件，列表卡片式展示各文件独立转写进度、阶段状态与结果文本。
- ⚡ **单任务独立高并发（Per-Task Concurrency）**：多个音频文件同时转写时互不挤占切片并发额度，每个音频任务独立享有最高 16 路并发请求能力，多文件全速无阻并行识别。
- 🌐 **多模型服务商与双标准协议**：
  - **OpenAI Audio Transcriptions 规范** (`multipart/form-data`)：兼容 SiliconFlow (FunAudioLLM / SenseVoiceSmall / Whisper)、Groq (whisper-large-v3)、OpenAI 官方、本地自建 (Faster-Whisper / LocalAI / vLLM)。
  - **OpenAI Chat Completions 规范** (`application/json` + `input_audio`)：兼容小米 MiMo-V2.5-ASR、Qwen-Audio 等。
  - 内置 6 款预设，并支持完全自定义 Base URL、模型名称与 API Key。
- 🎙️ **长录音 VAD 智能停顿切片（最长 2 小时）**：
  - 超长录音由系统原生解码器直接转码为 16kHz 单声道 16-bit WAV（零笨重 FFmpeg 依赖）；
  - 基于短时能量检测（MAV）与滑动平滑算法，自适应在 50s~65s 自然呼吸停顿或静音谷底断句切片，彻底避免机械切片导致的吞字破音。
- 🛡️ **两阶段高可用自愈容灾与限流隔离**：
  - **阶段一（并发主跑）**：单段网络失败绝不中断全局任务；遭遇 429 时进入退避冷却；
  - **阶段二（自动单路串行补漏）**：并发结束后自动针对偶发失败段发起静默串行重试；
  - **阶段三（断点会话保持）**：若有顽固失败段，界面生成失败占位并激活会话，支持用户一键重试失败段，无需重跑整段音频；各文件任务间限流退避互不波及。
- 🧹 **模型特殊 Token 与幻觉文本清洗**：
  - 自动剥除 `<chinese>`, `<english>`, `[BLANK]`, `(music)`, `(applause)` 等副语言与控制符号；
  - 智能过滤静音段引起的极端重复词（Repetition Hallucination）与纯标点噪音。
- 🎨 **双端原生质感 UI**：
  - **Windows 端**：深度复刻微软 **WinUI 3 (Fluent Design)** 原生质感，支持亚克力（Acrylic）卡片、进度环、InfoBar 与原生弹窗；
  - **Android 端**：基于 **Material Design 3** 设计，支持自适应手势与深浅明暗主题跟随。
- 💾 **灵活结果导出**：
  - 单任务展开一键复制、单独导出同名 `.txt`；
  - 批量导出：选择目标目录一键将所有已完成音频分别保存为独立同名 `.txt`（具备重名自愈）；
  - 合并导出：一键将所有音频的识别文本合并汇总为一个总 `.txt` 文件。

---

## 🚀 快速开始

### 1. 获取 API Key

应用支持多种主流 ASR 服务商，可根据网络与场景自由选择：
- **小米 MiMo**：前往 [MiMo 开放平台](https://platform.xiaomimimo.com) 获取 API Key（内置 `mimo-v2.5-asr` 模型）；
- **硅基流动 (SiliconFlow)**：前往 [SiliconFlow 控制台](https://cloud.siliconflow.cn) 获取 API Key（推荐极速高准确率的 `FunAudioLLM/SenseVoiceSmall`）；
- **Groq**：前往 [Groq Console](https://console.groq.com) 获取 API Key（推荐超低延迟 `whisper-large-v3`）；
- **OpenAI**：前往 [OpenAI Platform](https://platform.openai.com) 获取 API Key（`whisper-1`）；
- **本地自建服务**：自建 Faster-Whisper / LocalAI，接口地址填 `http://localhost:8000/v1`，无需填写 Key。

### 2. 下载发行版安装包

直接前往 **[Releases](../../releases)** 页面下载最新安装包：
- **Windows 桌面端**：下载 `ASR-Client-Windows.zip`，解压后双击运行 `asr_client.exe` 即可（绿色便携，无需配置环境）；
- **Android 移动端**：下载 `app-release.apk`，安装到手机或平板后直接使用。

### 3. 源码构建

如需本地自编译或二次开发：

```bash
# 1. 克隆代码仓库
git clone https://github.com/BakaXXXXXL/ASR_test.git
cd ASR_test/client

# 2. 安装依赖 (要求 Flutter >= 3.38, Dart >= 3.10)
flutter pub get

# 3. 运行静态代码检查与全量单元测试
flutter analyze
flutter test

# 4. 调试运行
flutter run -d windows
flutter run -d android

# 5. 生成 Release 发行包
flutter build windows --release
flutter build apk --release
```

---

## 📖 使用指引

1. **配置服务商**：初次打开应用，点击右上角齿轮图标打开设置面板，选择服务商预设（如 MiMo 或 硅基流动），填入对应的 API Key，设置期望的并发路数（推荐 4~8 路，最高支持 16 路）；
2. **添加音频**：点击主界面的“添加音频”按钮或空态上传区，可一次性多选导入多个音频文件（支持 `.wav`、`.mp3`、`.m4a`）；
3. **开始转写**：
   - 点击顶部工具栏“全部开始”按钮，所有文件将同时启动转写；
   - 亦可点击单个卡片右侧的“▶”按钮独立运行指定音频；
4. **实时追踪**：卡片实时展示转码中、分段转写进度（如 `正在分段转写 4/10 段...`）与总进度条；
5. **查看与导出**：
   - 点击任务卡片右侧的折叠箭头，可展开查看转写文本，点击“复制”或“导出 .txt”；
   - 点击顶部工具栏“批量导出”，可选择“分别导出各文件 .txt”到指定文件夹，或“合并为单个总 .txt”。

---

## 📐 规格与格式支持

| 项目 | 参数规格与策略 |
| :--- | :--- |
| **容器格式支持** | WAV (`RIFF/WAVE`), MP3 (`ID3`/裸 MPEG 同步字), M4A (`ftyp`) |
| **格式嗅探方式** | 读取文件头前 12 字节魔数判定真实类型，绝不依赖扩展名 |
| **转码规格** | 16 kHz 采样率、单声道 (Mono)、16-bit 线性 PCM（由系统原生硬件加速解码） |
| **短音频上传上限** | Base64 编码后 ≤ 10 MB（原始体积 ≤ 7.5 MB，直接单请求上传） |
| **长录音转写上限** | 最长支持 **2 小时**（超限音频智能切片为 50s~65s 并发并行转写） |
| **并发度范围** | 每个任务 **1 ~ 16 路独立并发 Worker**，多文件任务互不挤占 |

---

## 📂 项目结构

```
ASR_test/
├── .github/workflows/
│   └── build-release.yml           # CI/CD：标签推送自动触发全平台编译与 Release 发布
├── client/                         # Flutter 客户端源码
│   ├── lib/
│   │   ├── main.dart               # 应用入口与桌面窗口自适应初始化
│   │   ├── config.dart             # 配置管理、服务商预设与持久化
│   │   ├── app_fluent.dart         # Windows WinUI 3 顶层 App
│   │   ├── app_material.dart       # Android Material 3 顶层 App
│   │   ├── models/
│   │   │   └── transcribe_task.dart # 任务实体与生命周期状态模型
│   │   ├── services/
│   │   │   ├── asr_service.dart     # 双协议 ASR 调用、容灾编排与会话重试
│   │   │   ├── async_semaphore.dart # 异步信号量受控调度组件
│   │   │   ├── batch_transcribe_manager.dart # 批量任务流调度管理器
│   │   │   ├── batch_export_helper.dart      # 单文件/批量/合并导出辅助类
│   │   │   ├── audio_format.dart    # 格式嗅探 / MIME / VAD 算法 / 文本清洗
│   │   │   ├── audio_converter.dart # 16kHz WAV 本地原生解码转换器
│   │   │   └── audio_segment_transcriber.dart # 智能切片、两阶段自愈与 429 退避
│   │   └── screens/
│   │       ├── home_screen.dart     # 自适应平台路由分流器
│   │       ├── windows/
│   │       │   ├── fluent_home_screen.dart     # WinUI 3 折叠卡片流主界面
│   │       │   └── fluent_settings_dialog.dart # WinUI 3 风格设置弹窗
│   │       └── android/
│   │           └── material_home_screen.dart   # Material 3 折叠卡片流主界面
│   ├── test/
│   │   ├── audio_format_test.dart              # 魔数嗅探、VAD 切片与清洗测试
│   │   ├── long_audio_fault_tolerance_test.dart# 429 容灾、断点重试与会话自愈测试
│   │   ├── multi_provider_test.dart            # 多服务商协议适配与向下兼容测试
│   │   └── batch_transcribe_test.dart          # 批量队列调度与并发测试
│   └── pubspec.yaml
├── docs/                           # 技术文档
│   ├── architecture.md             # 架构设计与数据流文档
│   ├── api-reference.md            # 服务商接口协议规格说明
│   └── deployment.md               # 编译构建与排错指南
└── README.md
```

---

## 🛠️ 技术栈清单

| 组件类别 | 选型技术 | 选型理由 |
| :--- | :--- | :--- |
| **跨平台客户端** | Flutter 3.x (Dart 3.x) | 一套代码同时编译高性能 Windows 原生桌面端与 Android 移动端 |
| **Windows UI** | `fluent_ui` (WinUI 3) | 深度贴合 Windows 11 Fluent Design System（Mica/Acrylic 原生质感） |
| **Android UI** | Material Design 3 | 契合 Android 现代设计规范，自适应动态色彩 |
| **音频原生解码** | `audio_decoder` | 调用系统原生 MediaCodec / Media Foundation，无需打包 20MB+ 笨重 FFmpeg |
| **网络通信** | `dio` | 支持拦截器、FormData 上传、CancelToken 优雅取消与超时退避控制 |
| **文件交互** | `file_picker` | 支持系统原生文件选择对话框与批量多选 |
| **CI/CD** | GitHub Actions | 云端双 Runner (Ubuntu / Windows-2022) 自动化测试门禁与发布 |

---

## 📄 许可证

本项目基于 [MIT 许可证](LICENSE) 开源。

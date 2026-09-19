# 部署指南

## 一、获取 MiMo API Key

1. 访问 https://platform.xiaomimimo.com
2. 注册/登录账号
3. 在控制台获取 API Key
4. 查看计费说明：https://mimo.mi.com/docs/zh-CN/price/pay-as-you-go

## 二、客户端构建

### 2.1 环境要求

| 项目 | 要求 |
|------|------|
| Flutter SDK | >= 3.38（Dart >= 3.10.8，audio_decoder 插件要求；CI 固定 3.47.4） |
| Android Studio | 用于 Android 构建 |
| Visual Studio | 用于 Windows 构建（含 C++ 桌面开发） |

Android 工程已配置：`minSdk 24`、`compileSdk 36`、Java 17、AGP 9.1.0、Kotlin 2.4.0、Gradle 9.3.1；NDK 跟随 Flutter（`flutter.ndkVersion`，首次构建会自动安装）。

### 2.2 创建 Flutter 项目（首次）

如果 `client/` 目录中还没有 `android/` 和 `windows/` 平台目录：

```bash
cd client/
flutter create . --platforms=windows,android
```

这会生成 `android/` 和 `windows/` 目录及其平台配置文件。

### 2.3 安装依赖

```bash
cd client/
flutter pub get
```

### 2.4 构建 Windows

```bash
flutter build windows --release
```

输出位于 `client/build/windows/x64/runner/Release/`。

### 2.5 构建 Android APK

```bash
flutter build apk --release
```

输出位于 `client/build/app/outputs/flutter-apk/app-release.apk`。

### 2.6 运行单元测试

```bash
cd client/
flutter analyze
flutter test
```

### 2.7 配置 API Key

应用启动后，点击右上角齿轮图标，在设置对话框中填入从 MiMo 平台获取的 API Key。

---

## 三、常见问题

### 提示"无法识别的音频格式，仅支持 WAV / MP3 / M4A"
应用按**文件头魔数**判断真实格式，不看扩展名。请确认文件确实是 wav / mp3 / m4a；其他格式（flac / ogg / amr / silk 等）可用 ffmpeg 转换：
```bash
ffmpeg -i input.flac output.mp3
ffmpeg -i input.ogg output.mp3
```

### 长录音如何转写
超过单次上传上限（Base64 后 10MB）的录音会自动走分段路径：先统一转成 16kHz 单声道 WAV，应用内置 VAD（语音活动检测）能量扫描在 50s~65s 候选区间内寻找自然呼吸与静音停顿切片，4 并发并行识别，再按序合并结果，最长支持 **2 小时**。界面会显示"正在转写 x/N 段…"。由于在自然停顿处切分，有效避免了机械截断导致的断词与吞字问题。

### 提示"第 x/N 段识别失败"
分段转写中某段重试（429/5xx/超时，退避 1s/2s/4s）后仍失败，其余段会被取消以避免静默丢内容。多为网络波动或触发 API 限流，稍后重试即可；频繁出现可降低并发（`audio_segment_transcriber.dart` 的 `segmentConcurrency`）。

### 提示"音频时长约…超过上限 2 小时"
超过 2 小时的录音需要先裁剪，例如：
```bash
ffmpeg -i input.m4a -ss 0 -t 7200 output.wav
```

### 提示"音频解码失败"
解码依赖系统原生解码器（转码 m4a 或长录音归一化时都会用到）：
- **Android**：MediaCodec（Android 7.0+ 自带）
- **Windows**：Media Foundation 的 AAC 解码器（Windows 10/11 自带，N 版或精简系统可能缺失）

遇到该提示时，先用 ffmpeg 转成标准 wav / mp3 再上传。

### 提示"音频数据过大"
新版中超限长录音会自动分段，该提示基本只在文件读取竞计时出现。若遇到，重新选择文件再试。

### 导出 TXT
识别结果卡片右上角下载按钮 → 弹出"另存为"对话框选择位置，UTF-8 编码写入 `.txt`。取消对话框不会有任何副作用。

### Android 网络请求失败
确认 `android/app/src/main/AndroidManifest.xml` 声明了（release 包必须，debug/profile 里的声明不会进入 release 包）：
```xml
<uses-permission android:name="android.permission.INTERNET"/>
```
MiMo API 使用 HTTPS，不需要 cleartext 配置。

### Windows 构建失败
确认安装了 Visual Studio 及 C++ 桌面开发工作负载。运行 `flutter doctor` 检查环境。

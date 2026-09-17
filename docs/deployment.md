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

Android 工程已配置：`minSdk 24`、`compileSdk 36`、Java 17、AGP 9.1.0、Kotlin 2.4.0、Gradle 9.3.1、NDK 27.0.12077973。

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

### m4a 提示"超过上限…约 4 分钟以内"
MiMo API 只接受 wav / mp3，m4a 需要先在本地转成 16kHz 单声道 WAV 再上传，而 Base64 后上限为 10MB，等效约 4 分钟。裁剪后再试：
```bash
ffmpeg -i input.m4a -ss 0 -t 240 -ar 16000 -ac 1 output.wav
```

### 提示"M4A 解码失败"
m4a 解码依赖系统原生解码器：
- **Android**：MediaCodec（Android 7.0+ 自带）
- **Windows**：Media Foundation 的 AAC 解码器（Windows 10/11 自带，N 版或精简系统可能缺失）

遇到该提示时，先用 ffmpeg 转成 wav / mp3 再上传。

### 提示"音频数据过大"
上限针对 **Base64 字符串**（10MB），约为原始文件的 1.33 倍，即原始文件需不大于 **7.5MB**。建议裁剪或压缩音频时长。

### Android 网络请求失败
确认 `android/app/src/main/AndroidManifest.xml` 声明了（release 包必须，debug/profile 里的声明不会进入 release 包）：
```xml
<uses-permission android:name="android.permission.INTERNET"/>
```
MiMo API 使用 HTTPS，不需要 cleartext 配置。

### Windows 构建失败
确认安装了 Visual Studio 及 C++ 桌面开发工作负载。运行 `flutter doctor` 检查环境。

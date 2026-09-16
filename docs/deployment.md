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
| Flutter SDK | >= 3.7.0 |
| Android Studio | 用于 Android 构建 |
| Visual Studio | 用于 Windows 构建（含 C++ 桌面开发） |

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

### 2.6 配置 API Key

应用启动后，点击右上角齿轮图标，在设置对话框中填入从 MiMo 平台获取的 API Key。

---

## 三、常见问题

### 提示"仅支持 wav 和 mp3 格式"
MiMo API 目前仅支持 wav 和 mp3 格式。如需转换，可使用 ffmpeg：
```bash
ffmpeg -i input.m4a output.wav
ffmpeg -i input.flac output.mp3
```

### 提示"文件过大"
Base64 编码后文件大小约为原始的 1.33 倍，且上限为 10MB。建议音频时长控制在合理范围内。

### Android 网络请求失败
确保 `android/app/src/main/AndroidManifest.xml` 中配置了：
```xml
<application android:usesCleartextTraffic="true" ...>
```
（MiMo API 使用 HTTPS，通常不需要此配置）

### Windows 构建失败
确认安装了 Visual Studio 及 C++ 桌面开发工作负载。运行 `flutter doctor` 检查环境。

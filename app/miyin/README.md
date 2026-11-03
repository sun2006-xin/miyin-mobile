# 觅音

觅音是独立的Flutter手机应用，代码和Android/iOS工程位于本目录，不依赖译学助手主程序。当前开发为`1.6.0-preview`系列，准确构建号见`pubspec.yaml`。Android是目前的运行与真机验证目标；存在iOS工程不代表iOS语音/媒体链路已经验收。

当前已实现翻译、图片覆盖译图、文章对照、面对面、同传字幕、双声源有声录屏，以及本机/外部模型AI聊天与本地语音。功能边界、近期证据和公开测试版准备状态见[仓库说明](../../README.md)。以下版本条目为早期迭代留档，不是当前完整功能清单。

## 版本与迭代

- `V1.0` 是首个可安装体验版本，对应 `pubspec.yaml` 中的 `1.0.0+1`。
- `V1.1` 是手机体验优化版本，对应 `pubspec.yaml` 中的 `1.1.0+2`；已在 OPPO PEHM00（Android 12）做安装与主题界面冒烟检查，尚未证明所有设备达到稳定 60/90 FPS。
- `V1.2` 对应 `pubspec.yaml` 中的 `1.2.0+3`：Android 简体中文 ↔ 英语本机文字翻译、本机历史、语言/引擎扩展接口，以及空历史/草稿/AI 输入区问题修复；ML Kit 管理器按需初始化以避开首页启动同步初始化。英语模型随 Android 服务提供；简体中文模型需要用户在应用内明确下载。其他语言及从觅音网站分发语言包仍是后续工作。
- `V1.3` 对应 `pubspec.yaml` 中的 `1.3.0+4`：在保留薄荷、冷雾和石墨夜主题的基础上，增加商务蓝白琥珀、森林绿奶油、紫罗兰珊瑚、石墨灰湖蓝、午夜蓝橙金及黑金尊贵六款主题，并将新 Logo 用作 Android/iOS 图标。iOS 图标资源已生成，构建需 macOS/Xcode 环境。
- `V1.4` 对应 `pubspec.yaml` 中的 `1.4.0+5`：增加极光琉璃、薰衣草珍珠、薄荷泡泡、冰晶流光、森林纸笺、陶釉暖砂、极地钛银及黑曜鎏金八款材质主题；修整 AI 对话输入区与模式轮盘间距、统一轮盘位置、让面对面翻译背景跟随当前主题，并修复球体外观页面返回设置时的导航循环。
- V1.1 收录手机体验优化；之后每完成并验收一个功能切片，依次发布 `V1.2`、`V1.3`、`V1.4` 等；Flutter 版本号同步递增，例如 `1.2.0+3`、`1.3.0+4`、`1.4.0+5`。
- `main`保留已确认版本，功能分支用于开发；具体发布版本以实际tag和Release记录为准，不把某个预定版本号当成全部功能已完成。
- GitHub 仓库为 `sun2006-xin/miyin-mobile`，本机仓库根目录是 `D:\YixueMobile`，Android Studio 项目目录是 `D:\YixueMobile\app\miyin`。它与 `D:\译学助手` 的本机 Git 仓库分开；觅音尝试先在本仓库迭代，确认后再决定是否同步到译学助手。

## 用 Android Studio 打开

1. 在 Android Studio 选择 **Open**，打开 `D:\YixueMobile\app\miyin` 文件夹。
2. 安装 Flutter 与 Dart 插件，并设置 Flutter SDK。Dart SDK 已包含在 Flutter SDK 的 `bin/cache/dart-sdk` 目录中，不需要另行下载 Dart。
3. 在 SDK Manager 安装 Android SDK；连接 Android 手机并开启 USB 调试，或创建模拟器。
4. 在 `miyin` 项目终端运行 `flutter pub get`，选择设备后运行。

命令行也可以在本目录运行：

```powershell
flutter pub get
flutter run
```

## 项目结构

- `lib/main.dart`：觅音独立启动入口，仅启动觅音。
- `lib/features/miyin/miyin_mobile_app.dart`：Flutter 外壳、状态栏和本地 WebView。
- `assets/miyin_v5/`：随应用打包的 V5 HTML、CSS、JavaScript 和着色器桥接资源。
- `assets/brand/miyin-logo-selected.png`：觅音新 Logo 方形母版；Android/iOS 启动图标以该设计为来源，Android 另有自适应前景、渐变背景与单色层。
- `android/`、`ios/`：觅音自己的原生平台工程和应用标识。

## Android 调试包

Android SDK 配置完成后，在本目录运行：

```powershell
flutter build apk --debug
```

APK 输出到 `build/app/outputs/flutter-apk/app-debug.apk`。

当前版本通过Flutter WebView加载本地V5页面，以保留已确认的界面和交互。翻译、SQLite历史、本地ASR/TTS、系统音频和录屏已有实现；其他离线翻译语言包由ML Kit在应用内管理。语音资源不要求用户去GitHub下载。

模型采用Git LFS，构建前必须取得真实模型对象。当前开发机使用Flutter3.47.2与项目固定的Gradle/Android工具链；新环境仍需验证完整LFS克隆和干净构建。现有候选包沿用Android Debug签名，仅用于测试体验；公开分发前的许可证与资源材料见[开源准备清单](../../docs/product/开源测试版准备清单-2026-11-03.md)。

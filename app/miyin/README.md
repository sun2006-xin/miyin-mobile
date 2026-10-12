# 觅音

觅音是独立的 Flutter 手机应用，代码和 Android/iOS 工程位于本目录，不依赖译学助手的 Flutter 主程序。应用以本地打包的 V5 页面资源承载已确认的 UI。V1.2 将中英文字翻译和翻译历史保存在本机；V1.3 增加六款主题和新应用图标；V1.4 增加八款材质主题并修整翻译、面对面和 AI 对话界面。体验 APK 采用 Android Debug 签名，面向当前设备体验和后续迭代，不是应用商店签名版本。

## 版本与迭代

- `V1.0` 是首个可安装体验版本，对应 `pubspec.yaml` 中的 `1.0.0+1`。
- `V1.1` 是手机体验优化版本，对应 `pubspec.yaml` 中的 `1.1.0+2`；已在 OPPO PEHM00（Android 12）做安装与主题界面冒烟检查，尚未证明所有设备达到稳定 60/90 FPS。
- `V1.2` 对应 `pubspec.yaml` 中的 `1.2.0+3`：Android 简体中文 ↔ 英语本机文字翻译、本机历史、语言/引擎扩展接口，以及空历史/草稿/AI 输入区问题修复；ML Kit 管理器按需初始化以避开首页启动同步初始化。英语模型随 Android 服务提供；简体中文模型需要用户在应用内明确下载。其他语言及从觅音网站分发语言包仍是后续工作。
- `V1.3` 对应 `pubspec.yaml` 中的 `1.3.0+4`：在保留薄荷、冷雾和石墨夜主题的基础上，增加商务蓝白琥珀、森林绿奶油、紫罗兰珊瑚、石墨灰湖蓝、午夜蓝橙金及黑金尊贵六款主题，并将新 Logo 用作 Android/iOS 图标。iOS 图标资源已生成，构建需 macOS/Xcode 环境。
- `V1.4` 对应 `pubspec.yaml` 中的 `1.4.0+5`：增加极光琉璃、薰衣草珍珠、薄荷泡泡、冰晶流光、森林纸笺、陶釉暖砂、极地钛银及黑曜鎏金八款材质主题；修整 AI 对话输入区与模式轮盘间距、统一轮盘位置、让面对面翻译背景跟随当前主题，并修复球体外观页面返回设置时的导航循环。
- V1.1 收录手机体验优化；之后每完成并验收一个功能切片，依次发布 `V1.2`、`V1.3`、`V1.4` 等；Flutter 版本号同步递增，例如 `1.2.0+3`、`1.3.0+4`、`1.4.0+5`。
- 全部计划功能完成后发布 `V2.0`。
- `main` 保持最近确认发布的版本，`develop` 用于下一功能迭代；Git tag（如 `V1.1`）对应发布 APK，不为每个版本长期保留分支。
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

当前版本通过 Flutter WebView 加载本地 V5 网页资源，以保留已确认的界面和交互；页面尚未重写为 Flutter 原生 Widget。V1.2 的中英翻译使用 Google ML Kit 本机模型，成功结果写入 SQLite；语音识别、语音合成、觅音网站语言包下载器和系统音频服务仍待实现。GitHub 体验 APK 使用 Android Debug 签名，适用于下载安装体验和后续迭代，不是应用商店发布签名。

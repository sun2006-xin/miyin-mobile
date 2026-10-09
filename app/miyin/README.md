# 觅音

觅音是独立的 Flutter 手机应用，代码和 Android/iOS 工程位于本目录，不依赖译学助手的 Flutter 主程序。当前版本以本地打包的 V5 页面资源承载已确认的 UI；产品服务和业务逻辑仍在后续实现。

## 用 Android Studio 打开

1. 在 Android Studio 选择 **Open**，打开仓库中的 `app/miyin` 文件夹。
2. 安装 Flutter 插件（Android Studio 会提示安装 Dart 插件），并设置 Flutter SDK。
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
- `assets/brand/miyin-logo-selected.png`：已选定的觅音 Logo 母版；Android/iOS 启动图标使用相同设计。
- `android/`、`ios/`：觅音自己的原生平台工程和应用标识。

## Android 调试包

Android SDK 配置完成后，在本目录运行：

```powershell
flutter build apk --debug
```

APK 输出到 `build/app/outputs/flutter-apk/app-debug.apk`。

此阶段通过 Flutter WebView 加载本地 V5 网页资源，以保留已确认的界面和交互；页面尚未重写为 Flutter 原生 Widget，也未接入翻译服务。

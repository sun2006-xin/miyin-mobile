# 觅音

觅音是独立 Android 翻译与同传应用。GitHub 工程仓库名为 `miyin-mobile`；应用名为“觅音”。

## 当前阶段

当前版本为 **V1.5.1+13**（2026-10-25）。支持文字、语音、图片与文章翻译，面对面翻译，同传字幕、截图翻译与双声源有声录屏。录屏和原声保存在手机公共媒体目录，可从觅音与系统文件应用打开。详细变化见 [更新记录](CHANGELOG.md)。

Android App 位于 [`app/miyin/`](app/miyin/)，采用 Flutter 加随包本地界面，原生服务负责语音、翻译、存储和 Android 媒体权限。基础语音模型随 APK 提供；额外的离线翻译语言包由应用内管理。模型文件通过 Git LFS 保存，克隆后需执行 `git lfs pull`；Android 构建在应用目录执行 `flutter pub get` 和 `flutter build apk --release --target-platform android-arm64`。

界面支持独立搭配主题、按钮材质、按压反馈、字体与 AI 球体；材质兼容 OPPO 的旧版 WebView。真实 AI 模型调用、流式聊天与语音对话将在下一阶段接入，目前 AI 回答和服务配置仍属于交互预览。

## 品牌方向

- 应用名：觅音。
- 应用使用已确认的蓝青色语音对话图标；Android 与 iOS 图标资源已纳入工程。字体及模型许可见 [第三方声明](app/miyin/THIRD_PARTY_NOTICES.md)。
- UI 基线：用户已确认 V4 的整体主题和页面布局；V5 只扩展已讨论的 AI 对话与历史交互，保持独立目录供审阅和取舍。

## 产品方向

- Android 手机端先行，桌面端暂缓。
- 面对面交流是首屏主场景：按住说话为默认，也支持免按住连续收音；播报可以自动、点按或关闭。
- 视频、直播和会议共享同传会话与字幕核心，由 Android 平台适配器提供麦克风、系统播放音频和 PiP 能力。
- 阅读器与译学共用 Agent。AI 助手也支持普通聊天；会话复盘由用户在对话中发起，相关记录必须由用户明确附加。
- Agent 模型与翻译模型分开配置；远程 API 只在用户配置、测试并选择后使用。

## 架构方向

保持会话、上下文、Agent 与工具协议跨平台共享；Android 权限、麦克风、系统播放音频和 PiP 放在平台适配层。共享核心的版本化方式将在工程骨架阶段结合现有 Flutter/Dart 与 Rust Core 边界确定。首阶段不包含桌面客户端。

## 设计材料

- [V5 可交互预览](./docs/designs/miyin-full-app-preview-v5/index.html)
- [V5 AI 对话截图（390 × 844）](./output/playwright/miyin-v5-chat-390x844.png)
- [V5 AI 历史截图（390 × 844）](./output/playwright/miyin-v5-history-390x844.png)
- [V5 AI 历史详情截图（390 × 844）](./output/playwright/miyin-v5-history-detail-390x844.png)
- [V5 桌面浏览器截图（1280 × 900）](./output/playwright/miyin-v5-desktop-1280x900.png)
- [V4 已确认视觉基线](./docs/designs/miyin-full-app-preview-v4/index.html)
- [V5 功能规格](./docs/superpowers/specs/2026-10-08-miyin-ai-chat-history-voice-design.md)
- [V5 实施与验收计划](./docs/superpowers/plans/2026-10-08-miyin-v5-ai-preview.md)
- [旧交互草案 V1（未采纳，仅留档）](./docs/designs/译学Android同传手机端交互预览-v1.html)
- [旧首页截图](./docs/designs/译学Android手机端预览-home-v1.png)
- [旧面对面同传截图](./docs/designs/译学Android手机端预览-face-v1.png)
- [产品边界与阶段门](./docs/product/移动端产品边界-v0.1.md)
- [品牌启动动画概念](./docs/brand/品牌启动动画概念-v0.1.md)

旧设计目录用于留档；实际安装包以 `app/miyin/` 源码为准。已完成的真机验收以版本说明为准，不代表所有品牌或所有语种都达到相同效果。当前 APK 沿用项目现有调试签名，供体验和分享。

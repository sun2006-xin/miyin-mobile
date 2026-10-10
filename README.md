# 觅音

觅音是独立 Android 同传应用。GitHub 工程仓库名为 `miyin-mobile`；应用名已确定为“觅音”。

## 当前阶段

V4 是已确认的视觉与布局基线，原文件保持不变。V5 是独立的可交互网页预览，沿用 V4 的主题和模式转轮；面对面记录区只保留顶部细分割线，AI 回复操作带中文标签，AI 语音页按 Pen 草图实现为同一会话中的沉浸球体与字幕两态，并共用固定底部控件。V5 当前可供审阅。

Android App 工程骨架现位于 [`app/miyin/`](app/miyin/)，是独立 Flutter 工程；Android/iOS 入口加载随包的 V5 本地界面。V1.1 已在 OPPO PEHM00（Android 12）完成安装与主题界面冒烟检查；真实翻译、麦克风和系统音频仍未接入，长时间稳定性与 60/90 FPS 也尚未验收。

## 品牌方向

- 应用名：觅音。
- 图标方向已确认：白色玻璃质感圆角底块，抽象黑色线条勾勒侧面唇形，左侧黑色声线隐约形成耳形。确认稿见 [觅音图标 PNG](./docs/brand/miyin-icon-approved-v1.png)；Android 启动器尺寸资源尚未导出。
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

旧的交互预览只留档，不作为实现依据。V5 的权限、收音、翻译、播报、回答、模型连接和分享状态均为模拟；正式 Android 功能需在后续工程阶段逐项实现和设备验收。

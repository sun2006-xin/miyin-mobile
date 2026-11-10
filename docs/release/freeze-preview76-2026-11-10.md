# Preview 76 验收记录

本轮修复应用启动时同步触发版本状态读取的问题。首次可用页面出现后才开始版本检查，GitHub 请求由 Android 后台任务处理。

## 发布产物

- 版本：`1.6.0-preview+76`，Android `versionCode`：`76`
- GitHub Release：[v1.6.0-preview.76](https://github.com/sun2006-xin/miyin-mobile/releases/tag/v1.6.0-preview.76)
- 源码提交：`11d38c18445bb02f87d76b99b902dbb7efe408bb`
- 完整 APK：`2,235,344,664` 字节；SHA-256：`ff44d14567c82ef09d37c83f3eb3df057323b047325817f9a373aa4ea1e4f733`
- 发行证书 SHA-256：`31366f2557af4b1d3a22fa01b1701ca6bca5bf48ccbd94cf3d7f8bab7fe4b800`
- Release 将完整 APK 分成两个文件上传；下载页提供合并脚本、下载清单和各文件校验值。

## 自动化检查

- PR 源码检查通过：Flutter/Dart 测试、Web 逻辑测试、浏览器交互测试和词典生成检查。
- `main` 源码检查通过。
- Android arm64 APK 构建、发行签名校验和 Release 发布工作流均通过。
- 完整 APK 的 SHA-256 与更新清单一致；下载得到的包安装在 OPPO 后，Android 接受了发行签名。

## OPPO 实机检查

- 设备：OPPO PEHM00，Android 12。
- 使用覆盖安装升级到 `versionCode 76`，ADB 返回 `Success`。
- `userId` 和 `firstInstallTime` 与升级前相同；没有卸载应用，现有应用数据沿用。
- 打开后约 6 秒已显示完整翻译首页。配置的延迟窗口之后，`MiyinUpdateCheckWorker` 成功结束，主页面仍在前台，没有出现启动期更新失败提示或页面卡住。

## 本轮未覆盖

- 设备当时已经安装 76，因此没有可用的更高版本触发完整的自动分卷下载、合并和系统安装流程；本轮验证的是首屏启动和后台版本检查。
- 实机范围只有 OPPO PEHM00，其他厂商和 Android 版本仍需单独验收。

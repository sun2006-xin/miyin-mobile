<p align="center"><img src="docs/brand/promo/hero.png" alt="觅音：翻译、同传与本地 AI 对话" width="100%"></p>

<h1 align="center">觅音 · Miyin</h1>
<p align="center">让交流，自然发生。<br>以本地能力为基础的 Android 翻译、同传与 AI 对话应用。</p>
<p align="center">
<a href="LICENSE"><img src="https://img.shields.io/badge/source-Apache--2.0-0f766e" alt="自有源码 Apache-2.0"></a>
<img src="https://img.shields.io/badge/Android-arm64--v8a-178f83" alt="Android arm64-v8a">
<img src="https://img.shields.io/badge/status-public%20preview-b7791f" alt="公开测试版">
</p>
<p align="center"><a href="https://github.com/sun2006-xin/miyin-mobile/releases/tag/v1.6.0-preview.68">下载体验</a> · <a href="docs/README.md">开发与设计记录</a> · <a href="https://github.com/sun2006-xin/miyin-mobile/issues">问题反馈</a></p>

Miyin is an Android app for translation, live captions and AI conversations,
with bundled on-device speech and chat models. This is a preview release;
device compatibility and language quality are still being improved.

## 下载与安装

安装包统一放在 **[GitHub Releases](https://github.com/sun2006-xin/miyin-mobile/releases)**，源码仓库不保存 APK。
当前公开候选为 **1.6.0-preview+68**。完整包约 **2.23 GB**，保留本机 AI、视觉与离线语音资源。

GitHub Release 单文件必须小于 2 GiB，因此完整 APK 分为两个文件：

1. 下载 `.apk.part1`、`.apk.part2`，保持文件名并放在同一文件夹。
2. Windows 用户下载同页 `Merge-APK-Windows.cmd`，运行后合并并自动核对 SHA-256。
3. 将得到的 `.apk` 传入 Android 手机安装。手机直接下载需用支持分割合并的文件工具；分卷本身不能安装。

发布页同时提供 `INSTALL-README.txt`、`DOWNLOAD-MANIFEST.json` 和 `SHA256SUMS.txt`。
需支持 **arm64-v8a** 的 Android 手机。建议为安装及首次准备模型预留 **10 GB**；这是保守建议，不是已测出的最低要求。
当前使用测试签名，后续固定发行签名可能影响覆盖升级，请保留需要的导出文件。

## 功能总览

![觅音能力总览](docs/brand/promo/overview.png)

以下图片为功能概念宣传图，并非真实操作截图；说明以当前实现与已知边界为准。

### 文字与语音翻译

输入文字或说话，查看识别原文与译文，按需朗读译文。翻译语言与额外离线语言资源在应用内选择和管理。

![文字与语音翻译](docs/brand/promo/translation.png)

### 面对面交流

双方轮流说话，在同一会话查看原文和译文，减少反复切换页面。适用于出行、问路和日常跨语言交流；识别效果受语言与环境影响。

<details>
<summary>查看面对面交流宣传图</summary>

![面对面交流](docs/brand/promo/face.png)

</details>

### 图片与相机翻译

从相册导入图片或使用相机取图，识别并翻译图片文字，将译文覆盖到原位置，保留图像内容和空间关系。支持点击放大、原图与译图切换、对照与保存；复杂排版仍可能需要校对。

![图片与相机翻译](docs/brand/promo/image.png)

### 文章对照阅读

查看文章原文与译文的对应内容，方便结合上下文阅读。当前重点是应用内文章阅读与翻译，不承诺Word等办公文档完整排版导出。

<details>
<summary>查看文章对照阅读宣传图</summary>

![文章对照阅读](docs/brand/promo/article.png)

</details>

### 视频、直播与会议同传

选择麦克风、其他App音频或双方音源，同传识别并显示译文。支持应用内字幕预览、跨App悬浮字幕、原译文显示和字幕样式设置。其他App是否允许音频捕获取决于系统与应用策略。

![视频、直播与会议同传](docs/brand/promo/captions.png)

### 有声录屏与会话回看

在已授权的同传录制中，将麦克风与其他App音频记录到有声MP4，并保留字幕历史与录制文件入口。文件可在应用内查看，也可通过手机文件管理使用。当前不将自动会议纪要或AI总结作为已完成能力。

<details>
<summary>查看有声录屏与会话回看宣传图</summary>

![有声录屏与会话回看](docs/brand/promo/recording.png)

</details>

### AI文字、图片与语音对话

可选择内置本机模型，或配置自己的API模型，进行流式文字对话与语音朗读。图片附件按所选模型的视觉能力处理；同时提供会话上下文、历史、模型选择和隐私设置。联网搜索与公开网页读取可为回答提供来源链接，实际可用性受网络与服务影响。

![AI文字、图片与语音对话](docs/brand/promo/chat.png)

### 内置语音与离线资源

随包提供本地识别、语音合成和本机AI资源，减少寻找语音包的额外操作。可管理额外翻译语言资源，选择朗读音色和速度。识别、翻译与合成的语言覆盖范围并不完全相同，不能理解为全部功能、全部语言都离线可用。

<details>
<summary>查看内置语音与离线资源宣传图</summary>

![内置语音与离线资源](docs/brand/promo/offline.png)

</details>

### 悬浮工具与截图翻译

从贴边悬浮入口快速进入相关功能，使用截图翻译、字幕及设置入口。悬浮显示和截图需取得对应Android授权。

<details>
<summary>查看悬浮工具与截图翻译宣传图</summary>

![悬浮工具与截图翻译](docs/brand/promo/floating.png)

</details>

### 主题、材质与自由外观

在觅音外观中搭配主题背景、按钮材质、按压反馈、字体与AI球体，提供玻璃、陶釉、金属、纸质等不同观感。

<details>
<summary>查看主题、材质与自由外观宣传图</summary>

![主题、材质与自由外观](docs/brand/promo/appearance.png)

</details>

### 词典、历史与模型管理

- **离线词典**：按词典浏览或查询词条，在有界单词列表中查找，查看当前数据集提供的释义、音标与例句；不同数据集的覆盖和完整度有所不同。
- **历史记录**：按类别回看普通翻译、面对面、图片、文章、同传与AI会话，管理需要保留或删除的记录。
- **模型配置**：管理本机及外部模型，检测连接、获取服务商返回的模型列表，勾选需要出现在聊天选择器中的模型。勾选显示名单不等于立即切换聊天模型。
- **隐私选项**：控制外部请求、上下文携带、本机会话保存、较早会话整理和联网策略；具体能力还取决于所选模型。

## 本地与联网的边界

随包 ASR、TTS 和本机聊天模型在手机运行，语音资源不要求用户另去网页寻找。
选择外部聊天模型时，请求会发送给用户配置的服务商，其费用与隐私政策分别适用。
额外离线翻译语言包由 Google ML Kit 在应用内下载；搜索和网页读取需要联网。
ML Kit SDK 还可能获取更新、发送性能和使用情况指标，因此本地推理不等于整个应用绝不联网。
历史和录制文件保存在本机；导出到手机公共目录的文件需另行管理。详见[隐私说明](PRIVACY.md)。

## 当前限制

- 主要真机验证设备为 OPPO PEHM00 / Android 12，其他品牌与逐语种质量仍需反馈。
- 首次准备、首次英文朗读和较长回答仍可能等待；识别与翻译准确率受口音、环境和模型影响。
- 某些 App 禁止系统音频捕获；录屏和麦克风需要 Android 授权。
- preview68 更换中英混读发音前端，自动化与合成检查已通过，仍需扩大听感验收。
- 手机 Agent 自动操作尚未完成；iOS 工程存在不代表 iOS 语音和媒体链路已验收。
- 旧实验 APK 只作开发留档，不建议作为当前体验入口；历史组件许可与当前版不同。

## 构建

使用 **Git + Git LFS** 克隆，只下载源码 ZIP 不等于取得模型内容：

```sh
git lfs install
git clone https://github.com/sun2006-xin/miyin-mobile.git
cd miyin-mobile
git lfs pull
cd app/miyin
flutter pub get
flutter build apk --release --target-platform android-arm64
```

已使用 Flutter **3.47.2** 与项目锁定依赖构建。独立目录构建记录见
[开源准备记录](docs/release/open-source-preflight-2026-11-03.md)；
该轮使用本机 LFS 对象和依赖缓存，不能代替远程下载或空缓存构建验证。
工具链和目录结构见[应用说明](app/miyin/README.md)。

## 参与开发

当前应用在 `app/miyin/`。Flutter 外壳承载随包页面，Android 适配层负责权限、音频、录屏和原生模型运行。
`main` 为统一公开分支，版本通过 tag 和 Release 留存。

- [贡献说明](CONTRIBUTING.md)：构建、修改与提交检查。
- [文档索引](docs/README.md)：当前规范与历史试验分开阅读。
- [更新记录](CHANGELOG.md)：版本演进。
- [安全说明](SECURITY.md)：报告前移除密钥和私人数据。

## 许可

觅音自有源码采用 **[Apache-2.0](LICENSE)**，可学习、修改、商用和再分发，须遵守许可要求。另见 [NOTICE](NOTICE)。
**第三方模型、字体、词典、SDK 与原生库保留各自许可，并非全部采用 Apache-2.0。**
例如 Supertonic 模型使用 OpenRAIL-M，含使用限制。再分发前请阅读
[第三方声明](app/miyin/THIRD_PARTY_NOTICES.md)及随包完整文本。

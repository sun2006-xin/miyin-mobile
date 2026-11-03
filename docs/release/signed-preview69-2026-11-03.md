# preview69正式签名与云端发行验收

2026-11-03。版本1.6.0-preview+69，应用功能保持现有公开测试版，新增发行签名和完整自动构建闭环。

## 已完成证据

- 源码：`6057cca13839b2b92777b38ed423461de8f7fde3`。
- 完整云端签名构建：[成功运行](https://github.com/sun2006-xin/miyin-mobile/actions/runs/41649433090)。
- 源码检查：[成功运行](https://github.com/sun2006-xin/miyin-mobile/actions/runs/41649432951)。本地229项Dart、10组网页和浏览器测试也通过。
- 云端转存Release草稿：[成功运行](https://github.com/sun2006-xin/miyin-mobile/actions/runs/41661832013)。验证构建来源、证书和分卷SHA后转存，不需重复编译。
- 已下载同一云端产物，本地核对每卷与合并APK SHA，独立apksigner验证证书。
- OPPO/Android12：先验证旧签名到新签名原地迁移，再安装云端版本69。均未卸载，UID与首次安装时间保持一致。未读取私人对话或使用麦克风。
- [公开下载](https://github.com/sun2006-xin/miyin-mobile/releases/tag/v1.6.0-preview.69)，全部Release附件服务端哈希已核对。

## 公开校验信息

APK：2234926232字节。
SHA-256：`aa0ec0bf43a19e0766ffb3b3a05d7aceba934e617373d74f4144cac21f454ec6`。
新证书SHA-256：`31366f2557af4b1d3a22fa01b1701ca6bca5bf48ccbd94cf3d7f8bab7fe4b800`。
证书与轮换证明在`docs/release/signing/`，其中没有私钥。

Android7/8(API24～27)保留旧兼容签名；Android9及以上使用新密钥。
签名工具分别验证API24～27、28～32、33～36，真机仅声称已验收OPPO/Android12。

## 安全与运行边界

正式私钥和密码位于仓库外，另有同机第二磁盘副本；应另做离机备份。
GitHub`miyin-release`环境仅main可使用，公开PR检查不接触密钥。
官方构建先生成unsignedAPK，固定签名后核对指纹；失败不会回退成临时签名。
临时私钥任务结束清理，产物仅包含分卷、说明、校验及公开签名信息。
构建产物保留7天；正式公开文件在Release留存。转存工作流只创建草稿，发布前仍进行产物与设备核验。

首次云端编译成功后曾因sdkmanager不在PATH导致签名步骤停止；修正SDK工具定位后完整重跑成功。
首次本机下载Actions产物超时，改为云端核验并转存Release草稿，随后从Release完成本地下载和验收。
本次没有更换模型或承诺语音性能改善。

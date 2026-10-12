# 觅音材质主题设计系统（V1.4 开发稿）

本稿把 8 张单页视觉参考转成应用内可选的表面主题。既有 9 个主题继续作为常规配色；新增主题通过页面背景、卡片表面、边缘高光与轻量纹理表达材质，不把整张参考截图当壁纸。

## 主题目录

| ID | 显示名称 | 主要材质语言 |
| --- | --- | --- |
| `palette-material-aurora` | 极光琉璃 | 蓝青到粉紫的极光层、透明玻璃卡片与虹彩边缘 |
| `palette-material-lavender` | 薰衣草珍珠 | 月白底色、淡紫雾光与柔和珠光层 |
| `palette-material-mint-bubble` | 薄荷泡泡 | 薄荷玻璃表面、低密度彩色浮泡和清透边缘 |
| `palette-material-ice-glass` | 冰晶流光 | 冷白冰蓝、折射带与半透明玻璃卡片 |
| `palette-material-rice-paper` | 森林纸笺 | 暖白宣纸纤维、淡墨竹叶与哑光卡片 |
| `palette-material-porcelain` | 陶釉暖砂 | 象牙暖砂、陶土橙釉色、细颗粒和釉面高光 |
| `palette-material-brushed-silver` | 极地钛银 | 拉丝方向纹、银灰反射带和冷蓝边光 |
| `palette-material-obsidian-gold` | 黑曜鎏金 | 深色石面、细金脉、暗金边线与暖色高光 |

## 表面规则

- 主题 ID 使用 `palette-material-` 前缀，沿用已有主题存储键和通用主题控件，不改变旧版 ID。
- 材质主题影响整个 App：翻译气泡、AI 对话、面对面对话、设置、历史、词典、离线资源和弹窗都读取同一组表面 token。
- 玻璃和珍珠类主题用半透明表面及柔焦；纸、陶、金属和石材类主题用低对比纹理与方向性光带。
- 纹理限制在背景和卡片中，避免压过正文。高对比文本、已选主题边框、按钮焦点状态保持清晰。
- 材质主题保持静态或使用低成本 CSS 渐变，不依赖持续动画、视频壁纸或大尺寸位图。

## 共享 token

每个主题提供 `--page`、`--surface`、`--surface-2`、`--ink`、`--title`、`--muted`、`--accent`、`--theme-accent`、`--line`、`--selected`、`--theme-wash` 以及以下材质 token：

- `--material-surface`、`--material-raised`：常规和抬高卡片的表面。
- `--material-avatar`：圆形头像控件底面。
- `--material-edge`、`--material-card-shadow`：材质轮廓和阴影。
- `--material-backdrop`：透明表面的背景柔焦。
- `--material-panel`：设置行及主要面板的主题表面。

宣纸主题使用单独的叶片 SVG 叠加纹理；其余材质通过渐变和 CSS 图层呈现，方便在不同屏幕比例下适配。

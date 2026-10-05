# 前台图形

项目原创 SVG。由原有图标派生的前台副本采用独立的深靛蓝与朱红配色；战斗继续使用 `../icons`。`club_mark.svg` 为首页与牌盒使用的几何标记。

`home_*_pattern.svg` 是首页十种属性牌盒的原创压纹蒙版，由 `ShowcaseFinishes` 选择。首页使用独立 `HomePalette`，不覆盖其他前台页面的样式。

`home_dragon_badge.svg` 使用 [Malie Library 的 Dragon TCG 矢量符号](https://malie.io/static/draft/html/_images/Dragon.svg)（2026-10-05 获取；轮廓路径保持原样，仅等比缩放与移动），配以本项目的金色球面渐变与高光。与现有能量图标统一为 256×256 透明画布、约 208px 圆球直径、居中留白与 mipmap 采样，不再截取或放大卡图上的小角标。
`res://tests/home_badge_style_review.gd` 可生成水／草／钢／龙的同尺寸原图与同灯光模型对照，保存到 `build/badge-style-review/comparison.png`。

`result_placeholder.svg` 为本项目原创的中性卡片／精灵球几何，用于平局及缺少代表卡的结算，不使用深色应用图标充当卡面。各前台页面的属性徽章统一通过 `FrontendAttributes.texture_for()` 取得。

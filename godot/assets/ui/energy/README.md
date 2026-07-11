# 能量图标

本目录保存可在前台牌组、卡牌组件和对局 HUD 间共享的能量图标。所有文件均为
256×256 RGBA PNG，图形居中且背景透明。对应 `.import` 固定使用 Lossless、mipmap 与
`fix_alpha_border`；重新导入或替换源图时应保留这些小尺寸 UI 采样设置。

| 文件 | 能量类型 | 取样卡图 |
|---|---|---|
| `grass.png` | Grass / 草 | `sv1-ener-1.webp` |
| `fire.png` | Fire / 火 | `sv1-ener-2.webp` |
| `water.png` | Water / 水 | `sv1-ener-3.webp` |
| `lightning.png` | Lightning / 雷 | `sv1-ener-4.webp` |
| `psychic.png` | Psychic / 超 | `sv1-ener-5.webp` |
| `fighting.png` | Fighting / 斗 | `sv1-ener-6.webp` |
| `darkness.png` | Darkness / 恶 | `sv1-ener-7.webp` |
| `metal.png` | Metal / 钢 | `sv1-ener-8.webp` |
| `colorless.png` | Colorless / 无色 | `svi-mirc.webp`（幸运能量） |
| `luminous.png` | Luminous / 夜光 | `svg2-lume.webp`（夜光能量） |

运行时统一通过 `res://ui/energy_icon_catalog.gd` 的 `EnergyIconCatalog` 读取，不要在各页面
重复维护路径表。基础属性和无色通过 `texture_for(type)` 读取；夜光能量是特殊能量，通过
`texture_for_card_id("svg2-lume")` 精确读取，泛型 `Rainbow` 不会误用夜光图标。未知能量类型
应让 catalog 返回空纹理，再由调用方保留文字或中性徽章作为回退；不要静默替换成
`Colorless`，因为无色需求与未知规则类型并不等价。

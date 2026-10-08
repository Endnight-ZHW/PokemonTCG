# Godot 4.7 客户端

这是项目当前的发布版本，版本号为 0.8.0。客户端使用 Godot 4.7
Windows 使用 Compatibility，移动端使用 Forward Mobile（Android Vulkan），支持 Windows x86_64 和 Android 9+ ARM64。

## 已实现

- 本地双人和原生 Challenge AI；产品不注册 Deep 模式或第二套 AI 回退策略。
- 14 套预组卡组，包含嗨皮组合第4弹的狙射树枭、美录梅塔ex、故勒顿和密勒顿ex；产品运行时和导出包不包含 ONNX 模型或研究文件。
- ENet LAN 与 WebSocket Relay Protocol v6 联机；旧 Protocol 5 房间明确拒绝且不提供桥接。
- Native ABI 2 `ptcg_core` 是唯一规则引擎；GDScript 只负责会话绑定、UI、网络和表现，
  同一 C++ 核心通过研究目录中的显式 pybind 服务离线实验。
- 响应式三维实体牌桌、卡牌正反面与厚度、空间动画、三维硬币、音频和移动端自动画质分档。
- 战斗统一通过选卡后的按钮使用卡牌；顶部任务条说明来源和下一步，目标以光边和文字标记。选目标时提供返回操作／取消操作并暂停结束回合；攻击和撤退提供确认。手牌滑动仅用于浏览。所有卡牌操作菜单统一纵向排列，内容超出可见高度时只上下滚动。
- 能量分配支持任意顺序选能量、独立改派、移除及撤销清空；共同目标同步调整，最后一次确认。目标列表优先展示，卡牌详情按需打开，操作工具固定在底部。
- 首页使用独立 `HomePalette`：暖白底、深蓝标题、红／蓝／金色图标徽章与柔和立体按钮，设置和帮助位于右上角。
  右侧保留收窄的皮质翻盖牌盒、主卡、镂空卡架和两张卡背，并增加展示硬币。盒身无文字，以素色皮革为主，十种属性各有右下角小面积同色压纹；盒盖和侧面不铺花纹。
  点击牌盒开合、主卡直接放大、硬币翻转，拖动转动视角；右侧不设文字提示、浮动图标或手动切换按钮。
  14 套预组空闲每 12 秒随机轮换，不连续重复；悬停物件、开盒、翻币、拖动、弹窗及后台时暂停，恢复空闲后重新计时。
  选牌为三列／两列完整卡图画廊与双人准备区，浏览不改分配；联机使用单页房间面板和单人换牌浮层。
  设置、帮助使用固定分类与独立正文滚动；卡牌详情按规则分组，牌组详情合并为卡图网格。
  结算显示完整代表卡、属性光晕和一次轻庆祝；对战牌桌与战斗弹窗保留原有风格。
  前台交互控件有清晰边界，当前选项用深蓝实底标识；牌组卡图采用暖白底衬，卡牌详情提供明确放大入口。
- 前台导航仅支持鼠标与触控，交互目标仍遵循至少 48px 的触控尺寸；网络文本框可在点击或
  轻触后输入，Android 系统返回按钮/手势继续用于返回与打开对局菜单。
- 全游戏统一沿用 1600×900 桌面布局；电脑和平板横屏保持相同的分区与操作流程，
  仅调整尺寸、间距和内容滚动。低画质、减少动画时停止展示卡的装饰动效。
- LAN 与 Relay 均允许双方选择同一牌组，牌库和隐藏信息仍按玩家隔离。

## 打开工程

从仓库根目录执行：

```powershell
.\tools\setup_godot_toolchain.ps1
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --editor --path .\godot
```

工具链安装在仓库的 `.tools/`，不会修改系统 `PATH`。

### 可视化编辑与学习入口

- 三维对战的结构、资源边界、画质策略和验证命令见
  [`../docs/GODOT_DEVELOPMENT_GUIDE.md`](../docs/GODOT_DEVELOPMENT_GUIDE.md)。新安装默认电影化动画；
  Android 对局自动从中画质 60 FPS 开始，持续性能不足时在动作完成后降至低画质 30 FPS。

- 打开 `res://tools/ui_workbench.tscn` 后按 `F6`，可安全预览标题、选牌、
  网络、设置、复杂选择、战斗和胜利界面，并触发主要战斗演出。
- Workbench 侧栏「属性动画实验台」可组合全部动作、十种属性、双方视角、四档动画和三档画质，
  并保存关键帧至 `build/animation-preview/`。对局时长、运动幅度与属性配色统一在
  `res://presentation/default_battle_animation.tres` 中调整；攻击数值／HP 在命中帧同步，
  附能和进化的光效随飞牌推进，卡面与标记在落地帧更新。
- `tools/test_battle3d_graphics.ps1` 同时录制完整动作和十属性重击到 `build/animation-review/`；
  从仓库根目录运行 `./tools/build_animation_review.ps1` 可生成支持修改前后对照、慢放和时间轴的本地播放器
  `build/battle-animation-upgrade/review.html`。基线放在 `build/battle-animation-upgrade/before/animation-review/`，没有基线时仍可回放当前版本。
  实验台提供普通命中、重击和「击倒 → 离场 → 奖励」连续演出，支持实时音效试听。
- Workbench 侧栏新增「声音实验台」：87 类声音、261 个变体和 7 首经典配乐可独立试听，支持固定变体与连续对战。音频制作、来源与前后录音见 [`../tools/audio/README.md`](../tools/audio/README.md)。
- 主要页面和组件现在都包含完整可编辑场景树；动态手牌和动作按钮仍由实时数据生成。
- 前台 Theme 位于 `res://ui/frontend/front_end_theme.tres`，只挂到标题、牌组、网络、
  设置、帮助、详情和胜利等前台 surface；战斗仍为 `res://ui/game_theme.tres`，
  战斗弹窗冻结为 `res://ui/frontend/battle_modal_theme.tres`，共享面板通过 `SurfacePalette` 跟随上下文。
  不要把前台 Theme 挂到 `Main` 或 `BattleTable` 根节点。
- 前台背景与动效位于 `res://ui/frontend/frontend_backdrop.*` 和 `frontend_motion.gd`；
  所有变体都不加载边角装饰卡牌，胜利页只保留面板内的代表卡。弹窗用
  `ModalSpec.frontend(...)` / `ModalSpec.battle(...)` 隔离尺寸、遮罩和 Theme。
- 发布运行时禁用 `ui_accept`、`ui_select`、`ui_cancel`、Tab、方向键和手柄导航；按钮、卡牌、
  选项与滑杆均通过鼠标/触控操作。网络地址、端口和房间码 `LineEdit` 使用点击焦点，以保留
  实体键盘文字输入和移动端虚拟键盘；Android 系统返回事件不属于 `ui_cancel`，仍由 `Main`
  处理。
- 标题页使用暖白底与裁切精灵球几何组成的程序化背景；`F5` 时由 `Main` 的
  `TitleFullBleedBackdrop` 显示，单独按 `F6` 或在 Workbench 中预览时使用页面内的
  `EmbeddedBackdrop`，两份背景保持互斥以避免重复绘制或额外外框。
- 前台字体为 `res://assets/ui/fonts/NotoSansCJKsc-VF.ttf`，来源、SHA-256 和 OFL 许可证见
  同目录 `SOURCE.md` / `OFL.txt`；前台正文 500、控件 600、标题 700；战斗保持原字重。
  前台原创 SVG 位于 `res://assets/ui/frontend/`，原有战斗图标仍位于 `res://assets/ui/icons/`。
- 8 种基础能量、无色和夜光能量的 256×256 RGBA 透明 PNG 位于
  `res://assets/ui/energy/`；运行时通过共享 `res://ui/energy_icon_catalog.gd` 读取。未知类型
  由调用方保留文字或中性徽章回退，不自动替换成无色；夜光能量按 `svg2-lume` 卡 ID 精确
  映射，不会覆盖通用 `Rainbow`。前台统一由 `FrontendAttributes.texture_for` 读取十种属性，龙系使用已修正的矢量球面徽章；战斗仍使用原 `EnergyIconCatalog`。
  完整来源表见该目录 `README.md`。
- 177 张发布卡牌已按 `res://authoring/card_review_manifest.json` 与卡图 SHA-256
  完成对战字段审核；新旧卡的印刷信息和卡图统一由 `card_source_manifest.json` 固定到同一简中
  数据源，使用 `tools/sync_card_sources.ps1` 导入或加 `-Check` 核对。卡图均为 300×419 无损 WebP。
  内容 `lint` 会拒绝缺卡、缺图、来源遗漏、哈希覆盖不完整或残留 `G/M/D/[C]`
  等内部能量符号的作者数据。卡牌详情统一由 `CardPresentation` 生成，战斗预览、选择弹窗
  与完整检查器不会再各自维护一套卡文格式。
- `UILayoutPolicy` 是画布、留白、弹窗尺寸和牌桌阅读空间的共享策略。设计尺寸为 1600×900，
  原生布局下限为 1024×720；1024×768、16:9、16:10 和超宽屏共用桌面布局。
  更小窗口与竖屏窗口缩放同一横向布局，移动端保持横屏。主要支持尺寸内按钮至少 48×48，
  标题内容最大宽度仍为 1440。桌面跨显示器窗口不把显示器边缘当作移动端安全区。
  Workbench 的弹窗预览复用共享间距策略；完整安全区、缩放和弹窗仍从 `F5` 主流程验证。
- 详细学习路线见
  [`../docs/GODOT_DEVELOPMENT_GUIDE.md`](../docs/GODOT_DEVELOPMENT_GUIDE.md)。

### 前台稳定接口

- `TitlePage`：`configure(version_text)` 继续接收单个版本字符串，并提供
  `set_embedded_backdrop_visible(...)` 切换独立预览背景。主入口节点固定为
  `LocalTwoPlayerButton`、`AIButton`、`NetworkButton`，另保留 `SettingsButton`、`HelpButton`；
  标题页发出的默认模式分别为 `local`、`challenge` 和 `relay`。
  互联网联机默认填入 `ws+srv://relay.114600.xyz`，通过 `_ptcg._tcp` SRV 记录发现实际服务器和端口；允许修改并保留局域网入口。
  空地址、旧默认回环地址及旧公网地址自动迁移，其他自定义地址保持原值。
- `DeckSelectPage`：使用 `selected_deck_key(player_idx)`、`select_deck(player_idx, key)` 和
  `deck_count()`；挑战模式固定为 `challenge`，先后攻由开局硬币胜者选择。
  左侧三列／两列画廊和右侧准备区始终并排；点击卡组仅浏览，由两个选用按钮通过 `_assign_preview_to(player_idx)` 更新对应玩家。
  两个区域独立滚动，调整窗口不进入另一页或重置牌组分配。
  `start_requested(mode, deck1, deck2, forced_first, apply_type_matchups)` 中 `forced_first` 传 `-1`，
  最后一个参数来自默认关闭的项目规则开关。
  两个槽位允许选择同一牌组。
  卡册使用哑光面板与清晰卡图，已分配标签与当前浏览高亮相互独立。
- `NetworkLobbyPage`：使用 `ConnectionState` 的 `IDLE`、`VALIDATING`、`CONNECTING`、
  `WAITING`、`CONNECTED`、`ERROR`，通过 `NetworkKindOption` 分段按钮选择 LAN / Relay，并通过
  `set_connection_state(state, message, room_code)` 更新左侧状态区；`kind_changed(kind)` 只在
  `IDLE` / `ERROR` 可触发。左侧展示连接字段与状态，右侧展示当前牌组与规则；`deck_picker_requested` 打开复用画廊的单人选择浮层，`select_deck(key)` 更新现有选项数据；`connect_requested(...)` 最后一个参数为房主设置的
  `apply_type_matchups`。地址、端口和房间码只有在
  点击或轻触文本框后才接收文字输入，页面不提供 Tab、方向键或手柄焦点导航。房主还会在
  开局前锁定弱点/抗性选项，挑战者只读确认。
  SRV 地址会先查询 DNS，每个解析服务器最多等待 2 秒，依次尝试三个服务器；
  解析完成后的 WebSocket 连接及房间握手最多等待 10 秒，失败后可直接修改地址重试；
  房主取得房间码后才进入等待挑战者状态，此后不会因等待对手而触发握手超时。
- 页面仍通过 `configure(...)` 接收数据、通过既有信号报告意图；规则权威校验在
  `NativeRulesSession`，网络房主通过同一会话执行动作与玩家视图投影。

## 测试与构建

```powershell
.\tools\test_godot.ps1
.\tools\test_godot_ai.ps1
.\tools\test_godot_network.ps1

# 需要图形渲染器；主基线固定 High + reduced motion，并额外生成 low/reduced 标题基线
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe `
  --path .\godot `
  --script res://tests/ui_preview.gd

# 只生成卡牌效果选择基线，不运行依赖桌面焦点的鼠标状态截图
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe `
  --path .\godot `
  --script res://tests/ui_preview.gd `
  -- --semantic-choice-only

# 只生成战斗卡牌详情的宽屏、720p 与紧凑屏基线
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe `
  --path .\godot `
  --script res://tests/ui_preview.gd `
  -- --battle-detail-only

# 对战可用性：四档分辨率、安全区、详情、退出确认与低画质
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe `
  --path .\godot `
  --script res://tests/ui_preview.gd `
  -- --battle-usability-only

.\tools\build_native_ai.ps1 -Target all -Configuration all
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\smoke_godot_build.ps1
```

`test_godot.ps1` 包含首页交互、模型与既有功能回归入口；音频归入动画、通知文案归入卡牌呈现、手牌布局归入三维契约，
原有回归用例继续覆盖。它包含统一桌面布局、较小窗口缩放、前台多分辨率、四边安全区、鼠标/触控专用输入契约、
弹窗历史、Android 系统返回、Theme 隔离、原生会话/搜索和交互 contract。本地、Challenge、
LAN 与 Relay 另有完整实战回归；研究模型不参与产品门禁。
截图输出到 `build/ui-preview/`，其中 `title.png`、`title-1280x720.png`、
`title-compact.png`、`title-portrait.png` 覆盖统一桌面布局在较小窗口与竖屏窗口中的缩放，
`title-hover.png` 检查鼠标悬停，`title-rotated.png` 检查三维展示卡替换，
`title-low-reduced.png` 检查静态降级；目录还包含 LAN/Relay 概览、网络状态、设置滚动、加载和
Toast，以及 `choice-energy.png`、`choice-energy-1280x720.png`、
`choice-energy-compact.png` 的能量分配工作区基线，用于人工检查全屏背景、视觉层级、目标状态、
溢出和长文案。`choice-switch-confirm.png`、`choice-treasure-energy.png`、
`choice-treasure-energy-compact.png` 与 `choice-exp-share-confirm.png` 额外覆盖换位、宝藏能量和
学习装置的真实语义选择；`choice-deck-search-valid.png`、`choice-deck-search-all.png` 与
`choice-deck-search-compact.png` 覆盖牌库检索的可选/全部切换、只读卡牌和紧凑滚动。它不代替 Windows/Android
调试导出与真机烟雾测试。

前台专项图形验收：`./tools/test_frontend_club_graphics.ps1`，快速检查布局可加
`-SkipPerformance`。它覆盖五种尺寸、同一页面连续缩放、弹窗遮挡三维展示、八次进出页面，
并在真实图形下采集首页三档帧时间。截图与 JSON 位于 `build/frontend-club/`；
当前设计与验证方法见 [`../docs/GODOT_DEVELOPMENT_GUIDE.md`](../docs/GODOT_DEVELOPMENT_GUIDE.md)。

其中 `desktop_layout_contract.gd` 额外覆盖 1024×768、1280×720、1280×800、1600×900、
1920×1080、2560×1600 与 2000×900，以及平板四边 48px 安全区和小窗口保底。
对战选卡始终自动打开左侧说明，关闭说明不改变牌位与状态栏位置；选择弹窗中的选项与卡文始终并排。
传入 `-- --capture` 可生成 `build/layout-unification/after/` 的截图与几何报告。

首页使用 `FrontendCardShowcase3D.set_cards(card_ids)` / `set_active(active)`；随机展示对应牌组的一张代表卡、
两张卡背、背部相连的薄折盖牌盒、盒内合并卡叠、镂空卡架与可翻转硬币，公开卡替换接口仍最多接受三张。组件复用实体卡与纹理缓存，拥有单个独立 SubViewport；
主卡通过 `card_activated(card_id)` 转发至首页 `card_art_requested(card_id)`，复用 `CardArtPanel`，关闭后保留原陈列状态。
观看角度可拖动调整，随机轮换与硬币使用独立的外观 RNG；新卡图预取完成后再切换。弹窗覆盖、失焦、应用暂停或页面隐藏时收束动作并停止更新，不参与对局自动画质会话。弹窗根据 surface 隔离主题，
`ModalSpec` 继续负责尺寸、遮罩、取消权限与返回恢复；对战 HUD 仍使用独立的游戏主题。

发布包构建：

```powershell
.\tools\package_release.ps1 -AndroidSigning test
.\tools\test_release.ps1
```

正式 Android 签名通过以下环境变量注入，不写入仓库：

- `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`
- `GODOT_ANDROID_KEYSTORE_RELEASE_USER`
- `GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD`

## 数据来源

`authoring/` 是卡牌、牌组、策略与 VM 描述符的唯一 JSON 作者源，`data/` 是由
`NativeContentCompiler` 生成并提交的运行数据；`assets/cards/` 是按 card ID 命名的唯一卡图源。
不要直接手工维护生成的 Card IR/卡牌数据。修改作者源后执行：

```powershell
.\tools\content.ps1 export
.\tools\content.ps1 check
```

版本、schema 和发布牌组以 [`data/release_manifest.json`](data/release_manifest.json)
为唯一来源；当前发布状态见 [`../docs/RELEASE_NOTES.md`](../docs/RELEASE_NOTES.md)。


前台快速截图：运行 `res://tests/ui_preview.gd -- --frontend-only`；仅检查首页可使用 `--title-only`。
完整图形验收仍使用 `tools/test_frontend_club_graphics.ps1`，其中包含五种尺寸与三档帧时间门禁。

首页专项回归为 `res://tests/title_showcase_contract.gd`，覆盖 14 套牌组与三个视角的模型间距、卡架各部件的穿模检查、随机轮换及暂停。
图形脚本 `res://tests/showcase_model_review.gd` 输出正反面、双侧、俯仰、左右连接端、35°／90°开盖与空卡架共 19 张近景，保存到 `build/hinged-case-review/angles/`。首页默认闭盖，点击可打开；专项回归验证连接两端在各角度不分离。
`res://tests/home_interaction_contract.gd` 覆盖鼠标／触控、开盖反向、赏卡返回、遮罩关闭、翻币防重入、失焦与弹窗中断、轮换及六种尺寸的全开视角边界。
`res://tests/home_prop_clearance_contract.gd` 核验龙属性角标的分辨率、透明边缘、圆球尺寸与符号占比，并以 2,892 个姿态检查硬币与台面、牌盒、卡架、卡牌的间距；加 `-- --capture` 输出 `build/home-fixes/` 的角标近景和抛币关键帧。硬币先抬起后翻转、放平后落下，旋转外轮廓始终保留台面间隙。
龙属性角标采用标准矢量轮廓与 256px 金色球面处理，来源见 `assets/ui/frontend/README.md`；`res://tests/home_badge_style_review.gd` 输出水／草／钢／龙的同尺寸与同灯光对照。
使用图形 Godot 并加 `-- --capture`，可生成 `build/home-redesign/after/` 的首页、全部牌组、按钮状态、开盒、赏卡和翻币截图。前台图形验收另采集三档画质的空闲与动作期间 P95 帧时间。
`ui_preview.gd -- --home-review-only` 可输出三套牌组和对应侧视角截图。

自动化测试通过 `Initialize-GodotTestEnvironment` 将用户数据隔离到 `.test_tmp/godot-userdata/`，测试保存设置不会覆盖 `.tools/appdata/` 的便携客户端设置或系统用户设置。

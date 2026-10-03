# Godot 4.7 客户端

这是项目当前的发布版本，版本号为 0.8.0。客户端使用 Godot 4.7
Compatibility 渲染器，支持 Windows x86_64 和 Android 9+ ARM64。

## 已实现

- 本地双人和原生 Challenge AI；产品不注册 Deep 模式或第二套 AI 回退策略。
- 10 套预组卡组；产品运行时和导出包不包含 ONNX 模型或研究文件。
- ENet LAN 与 WebSocket Relay Protocol v6 联机；旧 Protocol 5 房间明确拒绝且不提供桥接。
- Native ABI 2 `ptcg_core` 是唯一规则引擎；GDScript 只负责会话绑定、UI、网络和表现，
  同一 C++ 核心通过研究目录中的显式 pybind 服务离线实验。
- 响应式三维实体牌桌、卡牌正反面与厚度、空间动画、三维硬币、音频和移动端自动画质分档。
- 战斗统一通过选卡后的按钮使用卡牌；顶部任务条、合法目标及可用卡光边引导操作，攻击和撤退提供确认。手牌滑动仅用于浏览。
- 奶油暖色全屏标题页，使用暖白面板、焦糖色操作、浅木质感展示台和八种基础能量；
  首页只保留本地对战、挑战 AI、联机对战三个主入口，LAN/Relay 在网络大厅中选择。
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
  [`../docs/GODOT_DEVELOPMENT_GUIDE.md`](../docs/GODOT_DEVELOPMENT_GUIDE.md)。新安装默认标准动画；
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
- 主要页面和组件现在都包含完整可编辑场景树；动态手牌和动作按钮仍由实时数据生成。
- 前台 Theme 位于 `res://ui/frontend/front_end_theme.tres`，只挂到标题、牌组、网络、
  设置、帮助、详情和胜利等前台 surface；战斗与兼容 Theme 仍为 `res://ui/game_theme.tres`。
  不要把前台 Theme 挂到 `Main` 或 `BattleTable` 根节点。
- 前台背景与动效位于 `res://ui/frontend/frontend_backdrop.*` 和 `frontend_motion.gd`；
  所有变体都不加载边角装饰卡牌，胜利页只保留面板内的代表卡。弹窗用
  `ModalSpec.frontend(...)` / `ModalSpec.battle(...)` 隔离尺寸、遮罩和 Theme。
- 发布运行时禁用 `ui_accept`、`ui_select`、`ui_cancel`、Tab、方向键和手柄导航；按钮、卡牌、
  选项与滑杆均通过鼠标/触控操作。网络地址、端口和房间码 `LineEdit` 使用点击焦点，以保留
  实体键盘文字输入和移动端虚拟键盘；Android 系统返回事件不属于 `ui_cancel`，仍由 `Main`
  处理。
- 标题页使用奶油米色渐变、低反差织物与浅木边缘组成的程序化背景；`F5` 时由 `Main` 的
  `TitleFullBleedBackdrop` 显示，单独按 `F6` 或在 Workbench 中预览时使用页面内的
  `EmbeddedBackdrop`，两份背景保持互斥以避免重复绘制或额外外框。
- 前台字体为 `res://assets/ui/fonts/NotoSansCJKsc-VF.ttf`，来源、SHA-256 和 OFL 许可证见
  同目录 `SOURCE.md` / `OFL.txt`；普通 UI/HUD 使用 600，控件与标题使用 700，长段文字使用
  500 字重。项目原创 24×24 SVG 图标位于 `res://assets/ui/icons/`。
- 8 种基础能量、无色和夜光能量的 256×256 RGBA 透明 PNG 位于
  `res://assets/ui/energy/`；运行时通过共享 `res://ui/energy_icon_catalog.gd` 读取。未知类型
  由调用方保留文字或中性徽章回退，不自动替换成无色；夜光能量按 `svg2-lume` 卡 ID 精确
  映射，不会覆盖通用 `Rainbow`。标题页仅使用草、火、水、雷、超、斗、恶、钢八枚基础
  能量图标，并以无黑色外框的透明素材直接组成能量带。完整来源表见该目录 `README.md`。
- 137 张发布卡牌已按 `res://authoring/card_review_manifest.json` 与卡图 SHA-256
  完成对战字段审核；内容 `lint` 会拒绝缺卡、缺图、哈希覆盖不完整或残留 `G/M/D/[C]`
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
  标题页发出的默认模式分别为 `local`、`challenge` 和 `lan`。
- `DeckSelectPage`：使用 `selected_deck_key(player_idx)`、`select_deck(player_idx, key)` 和
  `deck_count()`；挑战模式固定为 `challenge`，先后攻由开局硬币胜者选择。
  左侧双列卡册和右侧详情始终并排；点击卡册仅浏览，点击“分配给玩家”后才更新对应槽位。
  两个区域独立滚动，调整窗口不进入另一页或重置牌组分配。
  `start_requested(mode, deck1, deck2, forced_first, apply_type_matchups)` 中 `forced_first` 传 `-1`，
  最后一个参数来自默认关闭的项目规则开关。
  两个槽位允许选择同一牌组。
  卡册使用哑光面板与清晰卡图，已分配标签与当前浏览高亮相互独立。
- `NetworkLobbyPage`：使用 `ConnectionState` 的 `IDLE`、`VALIDATING`、`CONNECTING`、
  `WAITING`、`CONNECTED`、`ERROR`，通过 `NetworkKindOption` 选择 LAN / Relay，并通过
  `set_connection_state(state, message, room_code)` 更新固定状态区；`kind_changed(kind)` 只在
  `IDLE` / `ERROR` 可触发。左栏始终展示方式图标、连接特性、身份徽章与角色提示，
  右栏使用可滚动的完整表单；`connect_requested(...)` 最后一个参数为房主设置的
  `apply_type_matchups`。地址、端口和房间码只有在
  点击或轻触文本框后才接收文字输入，页面不提供 Tab、方向键或手柄焦点导航。房主还会在
  开局前锁定弱点/抗性选项，挑战者只读确认。
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

`test_godot.ps1` 按 25 个功能入口运行；音频归入动画、通知文案归入卡牌呈现、手牌布局归入三维契约，
原有回归用例继续覆盖。它包含统一桌面布局、较小窗口缩放、前台多分辨率、四边安全区、鼠标/触控专用输入契约、
弹窗历史、Android 系统返回、Theme 隔离、原生会话/搜索和交互 contract。本地、Challenge、
LAN 与 Relay 另有完整实战回归；研究模型不参与产品门禁。
截图输出到 `build/ui-preview/`，其中 `title.png`、`title-1280x720.png`、
`title-compact.png`、`title-portrait.png` 覆盖统一桌面布局在较小窗口与竖屏窗口中的缩放，
`title-hover.png` 检查鼠标悬停，`title-rotated.png` 检查三维展示卡替换，
`title-low-reduced.png` 检查静态降级；目录还包含 LAN/Relay 概览、网络状态、设置滚动、加载和
Toast，以及 `choice-energy.png`、`choice-energy-1280x720.png`、
`choice-energy-compact.png` 的逐张能量分配基线，用于人工检查全屏背景、视觉层级、目标状态、
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

首页使用 `FrontendCardShowcase3D.set_cards(card_ids)` / `set_active(active)`，最多展示三张公开卡。
该组件复用实体卡网格与纹理缓存，拥有独立 SubViewport；低画质、减少动画时静态渲染，
弹窗覆盖或页面隐藏时停止更新，不参与对局自动画质会话。所有弹窗统一前台主题，
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

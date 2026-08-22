# Godot 4.7 客户端

这是项目当前的发布版本，版本号为 0.7.0。客户端使用 Godot 4.7
Compatibility 渲染器，支持 Windows x86_64 和 Android 9+ ARM64。

## 已实现

- 本地双人和 Challenge AI；信息集 AlphaZero v3 尚未晋升模型，Deep 入口停用并回退 Challenge。
- 10 套预组卡组；Deep v3 运行时使用一个 universal ONNX 和十项牌组路由，当前发布未捆绑模型。
- ENet LAN 与 WebSocket Relay Protocol v6 联机；旧 Protocol 5 房间明确拒绝且不提供桥接。
- Native ABI 2 `ptcg_core` 是唯一规则引擎；GDScript 只负责会话绑定、UI、网络和表现，
  同一 C++ 核心也通过 pybind 服务训练工具与原生搜索。
- 响应式实体牌桌、卡图、动画、音频和移动端画质分档。
- 深色“午夜竞技场”全屏标题页，使用深海军蓝、青蓝舞台光、金色点缀和八种基础能量；
  首页只保留本地对战、挑战 AI、联机对战三个主入口，LAN/Relay 在网络大厅中选择。
- 前台导航仅支持鼠标与触控，交互目标仍遵循至少 48px 的触控尺寸；网络文本框可在点击或
  轻触后输入，Android 系统返回按钮/手势继续用于返回与打开对局菜单。
- 标题页按 Wide、Compact landscape、Dense 三档响应式布局，三张展示卡会从可用宝可梦
  卡图中定时轮换；低画质、减少动画或 Dense 布局下停止轮换、漂浮和视差。
- LAN 与 Relay 均允许双方选择同一牌组，牌库和隐藏信息仍按玩家隔离。

## 打开工程

从仓库根目录执行：

```powershell
.\tools\setup_godot_toolchain.ps1
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --editor --path .\godot
```

工具链安装在仓库的 `.tools/`，不会修改系统 `PATH`。

### 可视化编辑与学习入口

- 打开 `res://tools/ui_workbench.tscn` 后按 `F6`，可安全预览标题、选牌、
  网络、设置、复杂选择、战斗和胜利界面，并触发主要战斗演出。
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
- 标题页使用深海军蓝渐变、青蓝聚光、金色点缀、宝可球同心徽记与竞技场地面环组成的
  程序化午夜背景；`F5` 时由 `Main` 的
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
- 标题页按安全区尺寸选择布局：Wide 要求宽度至少 1180、高度至少 650 且纵横比至少 1.5；
  Compact landscape 要求宽度至少 900、高度至少 600 且纵横比至少 1.15；其余使用 Dense 并隐藏展示卡扇。
  标题内容最大宽度为 1440。Wide/Compact 中的三张展示卡通过 `CardCatalog.shared()` 只选择
  带有效卡图的宝可梦，并经 `CardTextureCache` 按需加载、约每 5.5–8 秒逐张轮换；首次画面和
  reduced/low 预览保持确定。Workbench 可快速检查各档布局，但全屏背景、安全区和真实弹窗
  仍应从 `F5` 主流程验证。
- 详细学习路线见
  [`../docs/GODOT_DEVELOPMENT_GUIDE.md`](../docs/GODOT_DEVELOPMENT_GUIDE.md)。

### 前台稳定接口

- `TitlePage`：`configure(version_text)` 继续接收单个版本字符串，并提供
  `set_embedded_backdrop_visible(...)` 切换独立预览背景。主入口节点固定为
  `LocalTwoPlayerButton`、`AIButton`、`NetworkButton`，另保留 `SettingsButton`、`HelpButton`；
  标题页发出的默认模式分别为 `local`、`challenge` 和 `lan`。
- `DeckSelectPage`：使用 `selected_deck_key(player_idx)`、`select_deck(player_idx, key)` 和
  `deck_count()`；发布版 `AIModeOption` 固定为 `challenge`，先后攻由开局硬币胜者选择。
  `start_requested(mode, deck1, deck2, forced_first, apply_type_matchups)` 中 `forced_first` 传 `-1`，
  最后一个参数来自默认关闭的项目规则开关。
  两个槽位允许选择同一牌组。
  画廊 tile 使用中性深蓝交互层级，属性色仅保留在徽章和卡图细边框中。
- `NetworkLobbyPage`：使用 `ConnectionState` 的 `IDLE`、`VALIDATING`、`CONNECTING`、
  `WAITING`、`CONNECTED`、`ERROR`，通过 `NetworkKindOption` 选择 LAN / Relay，并通过
  `set_connection_state(state, message, room_code)` 更新固定状态区；`kind_changed(kind)` 只在
  `IDLE` / `ERROR` 可触发。wide 左栏会同步展示方式图标、连接特性、身份徽章与角色提示，
  compact 下隐藏；`connect_requested(...)` 最后一个参数为房主设置的
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

.\tools\build_native_ai.ps1 -Target all -Configuration all
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\smoke_godot_build.ps1
```

`test_godot.ps1` 包含标题页三档布局、前台多分辨率、四边安全区、鼠标/触控专用输入契约、
弹窗历史、Android 系统返回、Theme 隔离、原生会话/搜索和交互 contract。本地、Challenge、
LAN 与 Relay 另有完整实战回归；Deep 模型未晋升时入口保持关闭，不虚构模型对局。
截图输出到 `build/ui-preview/`，其中 `title.png`、`title-1280x720.png`、
`title-compact.png`、`title-portrait.png` 覆盖午夜竞技场的 Wide/Compact/Dense 布局，
`title-hover.png` 检查鼠标悬停，`title-rotated.png` 检查动态展示卡，
`title-low-reduced.png` 检查静态降级；目录还包含 LAN/Relay 概览、网络状态、设置滚动、加载和
Toast，以及 `choice-energy.png`、`choice-energy-1280x720.png`、
`choice-energy-compact.png` 的逐张能量分配基线，用于人工检查全屏背景、视觉层级、目标状态、
溢出和长文案。它不代替 Windows/Android
调试导出与真机烟雾测试。

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

`data/` 和 `assets/cards/` 由 Python 类型化卡牌 DSL 与导入数据生成。不要直接手工维护
生成的 Card IR/卡牌数据；Python 只编译描述，权威执行仍在 `ptcg_core`。修改作者源后执行：

```powershell
.\.tools\python311\python.exe -B .\python\scripts\export_godot_data.py
.\tools\export_onnx_models.ps1
```

版本、schema、发布牌组和模型集合以 [`../release_manifest.json`](../release_manifest.json)
为唯一来源；当前发布状态见 [`../docs/RELEASE_NOTES.md`](../docs/RELEASE_NOTES.md)。

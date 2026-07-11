# Godot 4.7 客户端

这是项目当前的发布版本，版本号为 0.3.2。客户端使用 Godot 4.7
Compatibility 渲染器，支持 Windows x86_64 和 Android 9+ ARM64。

## 已实现

- 本地双人、Challenge AI 和 Deep AI。
- 10 套预组卡组和 10 个离线 FP32 ONNX 模型。
- ENet LAN 与 WebSocket Relay 协议 v3 联机。
- 原生 GDScript 规则引擎和 C++ GDExtension ONNX Runtime 推理。
- 响应式实体牌桌、卡图、动画、音频和移动端画质分档。
- 明亮竞技场式全屏标题页，首页只保留本地对战、挑战 AI、联机对战三个主入口；
  Challenge/Deep 与 LAN/Relay 分别在牌组选择页和网络大厅中选择。
- 前台支持安全区、键盘/手柄/触控焦点与减少动画；标题页按 Wide、Compact landscape、
  Dense 三档响应式布局，低画质与减少动画时停用漂浮和视差。
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
  不要把前台 Theme 挂到 `Main` 或 `BattleScreen` 根节点。
- 前台背景与动效位于 `res://ui/frontend/frontend_backdrop.*` 和 `frontend_motion.gd`；
  `neutral` 二级页背景不绘制装饰卡扇，胜利页仍保留庆祝卡牌。弹窗用
  `ModalSpec.frontend(...)` / `ModalSpec.battle(...)` 隔离尺寸、遮罩、焦点和 Theme。
- `FrontendFocus` 提供输入模态焦点：鼠标/触控保留真实焦点但隐藏持久焦点环，键盘/手柄输入
  会立即恢复可见焦点，不影响方向导航与弹窗关闭后的焦点恢复。
- 标题页使用浅蓝天空、徽记与竞技台组成的程序化全屏背景；`F5` 时由 `Main` 的
  `TitleFullBleedBackdrop` 显示，单独按 `F6` 或在 Workbench 中预览时使用页面内的
  `EmbeddedBackdrop`，避免主流程出现深色边框。
- 前台字体为 `res://assets/ui/fonts/NotoSansCJKsc-VF.ttf`，来源、SHA-256 和 OFL 许可证见
  同目录 `SOURCE.md` / `OFL.txt`；普通 UI/HUD 使用 600，控件与标题使用 700，长段文字使用
  500 字重。项目原创 24×24 SVG 图标位于 `res://assets/ui/icons/`。
- 8 种基础能量、无色和夜光能量的 256×256 RGBA 透明 PNG 位于
  `res://assets/ui/energy/`；运行时通过共享 `res://ui/energy_icon_catalog.gd` 读取。未知类型
  由调用方保留文字或中性徽章回退，不自动替换成无色；夜光能量按 `svg2-lume` 卡 ID 精确
  映射，不会覆盖通用 `Rainbow`。完整来源表见该目录 `README.md`。
- 标题页按安全区尺寸选择布局：Wide 要求宽度至少 1180、高度至少 650 且纵横比至少 1.5；
  Compact landscape 要求宽度至少 900、高度至少 600 且纵横比至少 1.15；其余使用 Dense 并隐藏展示卡扇。
  标题内容最大宽度为 1500。Workbench 可快速检查各档布局，但全屏背景、安全区和真实弹窗
  仍应从 `F5` 主流程验证。
- 详细学习路线见
  [`../docs/GODOT_DEVELOPMENT_GUIDE.md`](../docs/GODOT_DEVELOPMENT_GUIDE.md)。

### 前台稳定接口

- `TitlePage`：`configure(version_text)` 继续接收单个版本字符串，并提供
  `set_embedded_backdrop_visible(...)` 切换独立预览背景。主入口节点固定为
  `LocalTwoPlayerButton`、`AIButton`、`NetworkButton`，另保留 `SettingsButton`、`HelpButton`；
  标题页发出的默认模式分别为 `local`、`challenge` 和 `lan`。
- `DeckSelectPage`：使用 `selected_deck_key(player_idx)`、`select_deck(player_idx, key)` 和
  `deck_count()`；AI 对局通过 `AIModeOption` 在 `challenge` / `deep` 间选择，
  `start_requested(mode, deck1, deck2, forced_first)` 的参数顺序不变。两个槽位允许选择同一牌组。
  画廊 tile 使用中性深蓝交互层级，属性色仅保留在徽章和卡图细边框中。
- `NetworkLobbyPage`：使用 `ConnectionState` 的 `IDLE`、`VALIDATING`、`CONNECTING`、
  `WAITING`、`CONNECTED`、`ERROR`，通过 `NetworkKindOption` 选择 LAN / Relay，并通过
  `set_connection_state(state, message, room_code)` 更新固定状态区；`kind_changed(kind)` 只在
  `IDLE` / `ERROR` 可触发。wide 左栏会同步展示方式图标、连接特性、身份徽章与角色提示，
  compact 下隐藏；`connect_requested(...)` 的协议参数保持不变。
- 页面仍通过 `configure(...)` 接收数据、通过既有信号报告意图；规则与网络权威校验留在 `Main`。

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

`test_godot.ps1` 包含标题页三档布局、前台多分辨率、四边安全区、跨阈值焦点、弹窗历史、
Theme 隔离和交互 contract，并验证五种实际对战路径仍可到达。截图输出到
`build/ui-preview/`，包含 1280×720 明亮标题页、Wide/Dense 页面、LAN/Relay 概览、网络状态、设置滚动、
加载和 Toast 等基线，用于人工检查全屏背景、视觉层级、溢出和长文案；它不代替
Windows/Android 调试导出与真机烟雾测试。

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

`data/` 和 `assets/cards/` 由 Python 权威数据生成。不要直接手工维护生成的
卡牌规则数据；修改 Python 数据后执行：

```powershell
.\.tools\python311\python.exe -B .\python\scripts\export_godot_data.py
.\tools\export_onnx_models.ps1
```

版本、schema、发布牌组和模型集合以 [`../release_manifest.json`](../release_manifest.json)
为唯一来源；当前发布状态见 [`../docs/RELEASE_NOTES.md`](../docs/RELEASE_NOTES.md)。

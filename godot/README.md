# Godot 4.7 客户端

这是项目当前的发布版本，版本号为 0.3.2。客户端使用 Godot 4.7
Compatibility 渲染器，支持 Windows x86_64 和 Android 9+ ARM64。

## 已实现

- 本地双人、Challenge AI 和 Deep AI。
- 10 套预组卡组和 10 个离线 FP32 ONNX 模型。
- ENet LAN 与 WebSocket Relay 协议 v3 联机。
- 原生 GDScript 规则引擎和 C++ GDExtension ONNX Runtime 推理。
- 响应式实体牌桌、卡图、动画、音频和移动端画质分档。
- 深蓝桌游风格的非战斗前台，支持 wide/compact、安全区、键盘/手柄焦点与减少动画。
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
  弹窗用 `ModalSpec.frontend(...)` / `ModalSpec.battle(...)` 隔离尺寸、遮罩、焦点和 Theme。
- 前台字体为 `res://assets/ui/fonts/NotoSansCJKsc-VF.ttf`，来源、SHA-256 和 OFL 许可证见
  同目录 `SOURCE.md` / `OFL.txt`；项目原创 24×24 SVG 图标位于 `res://assets/ui/icons/`。
- 前台以安全区宽度 1360、纵横比 1.5 为 wide/compact 分界，最大内容宽度 1480；
  Workbench 的窄预览宿主可快速检查 compact，但真实弹窗仍应从 `F5` 主流程验证。
- 详细学习路线见
  [`../docs/GODOT_DEVELOPMENT_GUIDE.md`](../docs/GODOT_DEVELOPMENT_GUIDE.md)。

### 前台稳定接口

- `DeckSelectPage`：使用 `selected_deck_key(player_idx)`、`select_deck(player_idx, key)` 和
  `deck_count()`；旧的内部双下拉适配器已经移除。两个槽位允许选择同一牌组。
- `NetworkLobbyPage`：使用 `ConnectionState` 的 `IDLE`、`VALIDATING`、`CONNECTING`、
  `WAITING`、`CONNECTED`、`ERROR`，并通过
  `set_connection_state(state, message, room_code)` 更新固定状态区。
- 页面仍通过 `configure(...)` 接收数据、通过既有信号报告意图；规则与网络权威校验留在 `Main`。

## 测试与构建

```powershell
.\tools\test_godot.ps1
.\tools\test_godot_ai.ps1
.\tools\test_godot_network.ps1

# 需要图形渲染器；截图期间固定 reduced motion 并等待布局稳定
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe `
  --path .\godot `
  --script res://tests/ui_preview.gd

.\tools\build_native_ai.ps1 -Target all -Configuration all
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\smoke_godot_build.ps1
```

`test_godot.ps1` 包含前台多分辨率、四边安全区、跨阈值焦点、弹窗历史、Theme 隔离和
交互 contract。截图输出到 `build/ui-preview/`，包含 compact 页面、网络状态、设置滚动、
加载和 Toast 等基线，用于人工检查视觉层级、溢出和长文案；它不代替 Windows/Android
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

`data/` 和 `assets/cards/` 由 Python 权威数据生成。不要直接手工维护生成的
卡牌规则数据；修改 Python 数据后执行：

```powershell
.\.tools\python311\python.exe -B .\python\scripts\export_godot_data.py
.\tools\export_onnx_models.ps1
```

版本、schema、发布牌组和模型集合以 [`../release_manifest.json`](../release_manifest.json)
为唯一来源；当前发布状态见 [`../docs/RELEASE_NOTES.md`](../docs/RELEASE_NOTES.md)。

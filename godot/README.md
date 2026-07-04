# Godot 4.7 客户端

这是项目当前的发布版本，版本号为 0.3.2。客户端使用 Godot 4.7
Compatibility 渲染器，支持 Windows x86_64 和 Android 9+ ARM64。

## 已实现

- 本地双人、Challenge AI 和 Deep AI。
- 8 套预组卡组和 8 个离线 FP32 ONNX 模型。
- ENet LAN 与 WebSocket Relay 协议 v3 联机。
- 原生 GDScript 规则引擎和 C++ GDExtension ONNX Runtime 推理。
- 响应式实体牌桌、卡图、动画、音频和移动端画质分档。

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
- 全局 Theme 位于 `res://ui/game_theme.tres`，牌桌尺寸和动画参数可在各场景根节点
  的 Inspector 分组中调整。
- 详细学习路线见
  [`../docs/GODOT_DEVELOPMENT_GUIDE.md`](../docs/GODOT_DEVELOPMENT_GUIDE.md)。

## 测试与构建

```powershell
.\tools\test_godot.ps1
.\tools\test_godot_ai.ps1
.\tools\test_godot_network.ps1

.\tools\build_native_ai.ps1 -Target all -Configuration all
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\smoke_godot_build.ps1
```

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

详细状态和外部验收项见 [`../docs/GODOT_MIGRATION_REPORT.md`](../docs/GODOT_MIGRATION_REPORT.md)。

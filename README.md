# PokemonTCG

宝可梦集换式卡牌对战项目。Godot 4.7 是唯一发布客户端；Python 是本地
调试、规则验证、AI 训练评估以及卡牌/卡图导入工具链。

![Godot 4.7“午夜竞技场”开始界面](docs/images/godot-guide/title-midnight-arena.png)

## 版本选择

| 目录 | 定位 | 状态 |
|---|---|---|
| [`godot/`](godot/) | 当前发布客户端 | Godot 4.7，版本 0.4.0 |
| [`python/`](python/) | Pygame 本地调试、规则对照、AI 训练与数据/卡图导出 | 开发工具，不发布、不提供客户端联机 |
| [`tools/`](tools/) | 测试、模型导出、Godot 构建和发布脚本 | 由根目录 manifest 驱动 |
| [`docs/`](docs/) | 规则、开发手册、发布说明和 AI rollout | 项目文档 |

Godot 版本已经具备本地双人、Challenge AI、ENet LAN 和
WebSocket Relay。旧 Deep v10 模型仍作为历史产物保留，但不兼容本轮规则，发布 UI 已停用
Deep 并稳定回退 Challenge。联机双方可选择相同或不同牌组；每名玩家拥有独立的牌库、
手牌和洗牌随机流。前台采用鼠标与触控导航；网络文本框点击后仍可输入文字，
Android 系统返回按钮或手势继续有效。

发布版本、协议/规则/RNG schema、Android versionCode、10 套发布牌组及旧模型状态
统一记录在 [`release_manifest.json`](release_manifest.json)。

## 快速开始

### Godot 4.7 主版本

```powershell
.\tools\setup_godot_toolchain.ps1
.\tools\test_godot.ps1
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --editor --path .\godot
```

需要 Android、原生 AI 扩展或完整构建时：

```powershell
.\tools\setup_android_toolchain.ps1
.\tools\setup_ai_toolchain.ps1
.\tools\setup_native_ai_deps.ps1
.\tools\build_native_ai.ps1 -Target all -Configuration all
.\tools\build_godot.ps1 -Target all -Configuration debug
```

更多命令见 [`godot/README.md`](godot/README.md)。

### Python 本地调试与训练工具链

```powershell
python -m pip install -r .\python\requirements.txt
python .\python\main.py
```

Pygame 只启动本地 `DebugMatchSession`，不包含 Lobby 或客户端网络状态。
GPU 训练使用精确锁定的 `python/environment.yml`；发布 ONNX 使用
`python/environment-export.yml` 或 `tools/setup_ai_toolchain.ps1` 创建的 CPU 环境。
更多说明见
[`python/README.md`](python/README.md)。

### Relay 服务

Relay 仅验证并转发 Godot Protocol v4 消息，不承载 Python 客户端协议；旧 v3 房间会收到
明确的不兼容诊断，不能恢复为 v4 对局：

```powershell
.\.tools\python311\python.exe .\python\relay_server.py --host 0.0.0.0 --port 8766
```

## 验证

```powershell
# 每次提交
.\tools\test_fast.ps1

# 完整 Python + Godot core/network + 双端 golden
.\tools\test_standard.ps1

# 发布前
.\tools\test_godot_ai.ps1
.\tools\smoke_godot_build.ps1
.\tools\test_release.ps1
```

## 文档

- [发布说明](docs/RELEASE_NOTES.md)
- [Godot 4.7 新手开发手册](docs/GODOT_DEVELOPMENT_GUIDE.md)
- [Deep AI v10 历史模型与迁移门禁](docs/deep_ai_v10_rollout.md)
- [游戏规则](docs/RULES.md)

卡牌名称、规则和图片仅供学习交流。游戏规则基于宝可梦集换式卡牌游戏官方规则。

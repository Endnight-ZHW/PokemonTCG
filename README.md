# PokemonTCG

宝可梦集换式卡牌对战项目。Godot 4.7 是唯一发布客户端；Python 是本地
卡牌作者工具、AI 训练评估以及数据/卡图导入工具链。

![Godot 4.7“午夜竞技场”开始界面](docs/images/godot-guide/title-midnight-arena.png)

## 版本选择

| 目录 | 定位 | 状态 |
|---|---|---|
| [`godot/`](godot/) | 当前发布客户端 | Godot 4.7，版本 0.7.0 |
| [`python/`](python/) | 卡牌 DSL、原生规则绑定、AI 训练与数据/卡图导出 | 开发工具，不发布客户端 |
| [`tools/`](tools/) | 测试、模型导出、Godot 构建和发布脚本 | 由根目录 manifest 驱动 |
| [`docs/`](docs/) | 规则、开发手册、发布说明和 AI rollout | 项目文档 |

Godot 版本已经具备本地双人、Challenge AI、ENet LAN 和
WebSocket Relay。Deep AI 训练基础设施已切换到高吞吐信息集 AlphaZero v3；整局 actor、
continuation 和搜索世界均留在原生 C++，Python 只负责 GPU 批量推理、流式 replay 和持续
learner。本轮不晋升模型，发布 UI 仍停用
Deep 并稳定回退 Challenge。联机双方可选择相同或不同牌组；每名玩家拥有独立的牌库、
手牌和洗牌随机流。前台采用鼠标与触控导航；网络文本框点击后仍可输入文字，
Android 系统返回按钮或手势继续有效。

发布版本、协议/规则/RNG schema、Android versionCode、10 套发布牌组及当前 v3 模型状态
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

### Python 作者与训练工具链

```powershell
python -m pip install -r .\python\requirements.txt
python .\python\scripts\card_author.py status --json
```

Python 不再提供 Pygame 客户端；场景调试和日志回放统一使用 Godot Workbench。
GPU 训练使用精确锁定的 `python/environment.yml`；发布 ONNX 使用
`python/environment-export.yml` 或 `tools/setup_ai_toolchain.ps1` 创建的 CPU 环境。
更多说明见
[`python/README.md`](python/README.md)。

### Relay 服务

Relay 仅验证并转发 Godot Protocol v6 消息，不承载 Python 客户端协议；旧 Protocol 5 房间会收到
明确的不兼容诊断，不能恢复为 v6 对局：

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
- [Native ABI 2 单一规则核心迁移](docs/NATIVE_RULES_CORE_MIGRATION.md)
- [Challenge 传统 AI 分层策略架构](docs/TRADITIONAL_AI_ARCHITECTURE.md)
- [Deep AI 高吞吐 AlphaZero v3](docs/deep_ai_alphazero_v3.md)
- [游戏规则](docs/RULES.md)

卡牌名称、规则和图片仅供学习交流。游戏规则基于宝可梦集换式卡牌游戏官方规则。

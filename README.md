# PokemonTCG

宝可梦集换式卡牌对战项目，同时保留当前 Godot 4.7 客户端和旧版
Python/Pygame 开发环境。

## 版本选择

| 目录 | 定位 | 状态 |
|---|---|---|
| [`godot/`](godot/) | 当前发布客户端 | Godot 4.7，版本 0.3.2 |
| [`python/`](python/) | 旧版客户端、规则对照、AI 训练与数据导出 | 继续用于开发和迁移验证 |
| [`tools/`](tools/) | Godot 工具链、测试、构建和发布脚本 | 两个版本共享 |
| [`docs/`](docs/) | 规则、开发手册、发布说明和 AI rollout | 项目文档 |

Godot 版本已经具备本地双人、Challenge AI、Deep AI、ENet LAN 和
WebSocket Relay。Python/Pygame 版本不再作为发布版运行时，但仍是规则对照、
模型训练和 Godot 数据生成的权威开发环境。

## 快速开始

### Godot 4.7 主版本

```powershell
.\tools\setup_godot_toolchain.ps1
.\tools\test_godot.ps1
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --editor --path .\godot
```

需要 Android、Deep AI 原生扩展或完整构建时：

```powershell
.\tools\setup_android_toolchain.ps1
.\tools\setup_ai_toolchain.ps1
.\tools\setup_native_ai_deps.ps1
.\tools\build_native_ai.ps1 -Target all -Configuration all
.\tools\build_godot.ps1 -Target all -Configuration debug
```

更多命令见 [`godot/README.md`](godot/README.md)。

### Python/Pygame 旧版本

```powershell
python -m pip install -r .\python\requirements.txt
python .\python\main.py
```

需要训练 AI 时安装 `python/requirements-ai.txt`，或使用
`python/environment.yml` 创建/更新 `DL` Conda 环境；Deep AI 训练和 ONNX 导出命令
默认通过 `conda run -n DL python -B ...` 执行。更多说明见
[`python/README.md`](python/README.md)。

### Relay 服务

Godot 客户端使用协议 v3；旧 Pygame 联机客户端使用旧协议，两者不能直接互联。
共享 Relay 服务支持两种协议入口：

```powershell
.\.tools\python311\python.exe .\python\relay_server.py --host 0.0.0.0 --port 8766
```

## 验证

```powershell
# Python
Set-Location .\python
..\.tools\python311\python.exe -B -m unittest discover -q
Set-Location ..

# Godot 数据与运行时
.\.tools\python311\python.exe -B .\python\scripts\export_godot_data.py --check --skip-images
.\tools\test_godot.ps1
.\tools\test_godot_ai.ps1
.\tools\test_godot_network.ps1
```

## 文档

- [发布说明](docs/RELEASE_NOTES.md)
- [Godot 4.7 新手开发手册](docs/GODOT_DEVELOPMENT_GUIDE.md)
- [Deep AI v10/v3 发布进度](docs/deep_ai_v10_rollout.md)
- [游戏规则](docs/RULES.md)

卡牌名称、规则和图片仅供学习交流。游戏规则基于宝可梦集换式卡牌游戏官方规则。

# 宝可梦集换式卡牌游戏

基于 Python + Pygame 的宝可梦卡牌对战客户端。客户端入口保持 UI-only：所有可玩的运行时功能都从游戏界面进入，包括本地对战、挑战 AI、AI 训练、远程大厅、卡图管理、帮助和属性克制开关。

## 快速开始

```bash
# Conda（推荐给需要 AI 训练的源码环境，含 PyTorch + CUDA）
conda env create -f environment.yml
conda activate DL
python main.py

# 或使用 pip 运行游戏客户端
pip install -r requirements.txt
python main.py

# pip 环境如需从源码使用 AI 训练，再安装训练依赖
pip install -r requirements-ai.txt
```

启动后在标题界面选择模式。联机端口、Relay 地址和房间码都在「远程联机对战」界面填写。

## Godot 4.7 客户端

Godot 迁移版已实现本地双人、Challenge AI、Deep AI、ENet 局域网联机和 WebSocket Relay 联机。工具链全部安装在项目 `.tools/` 下，不修改系统 `PATH`。

```powershell
.\tools\setup_godot_toolchain.ps1
.\tools\setup_android_toolchain.ps1
.\tools\setup_ai_toolchain.ps1
.\tools\setup_native_ai_deps.ps1

.\tools\build_native_ai.ps1 -Target all -Configuration all
.\tools\test_godot.ps1
.\tools\test_godot_ai.ps1
.\tools\test_godot_network.ps1
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\smoke_godot_build.ps1
.\tools\package_release.ps1 -AndroidSigning test
.\tools\test_release.ps1
```

依赖版本和下载摘要锁定在 `tools/toolchain.lock.json`。0.2.0 release 候选已生成，Windows/Android 发布包内置 8 个 FP32 ONNX 模型和 ONNX Runtime CPU Provider，不包含 Python、PyTorch 或训练工具。Android 离线 AI 基本真机验收已通过；新版设置、生命周期和跨设备联网矩阵仍待真机验收，详细状态见 `GODOT_MIGRATION_REPORT.md`。

Godot 客户端的局域网模式使用 ENet，默认端口为 `8765`。Relay 模式可连接 `ws://` 或 `wss://` 地址；本地 Relay 可这样启动：

```powershell
.\.tools\python311\python.exe .\relay_server.py --host 0.0.0.0 --port 8766
```

房主创建四位房间码，挑战者填写相同 Relay URL 和房间码加入。Godot 客户端仅兼容协议 v3，不与旧 Pygame 联机客户端互联。

`package_release.ps1 -AndroidSigning test` 会生成供真机验收的稳定本地测试签名 APK。正式发布时使用 `-AndroidSigning production`，并通过 `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`、`GODOT_ANDROID_KEYSTORE_RELEASE_USER` 和 `GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD` 注入签名信息。签名文件和密码不会写入仓库。

## 游戏模式

| 模式 | 说明 |
|------|------|
| 本地对战 | 两名玩家在同一台电脑上轮流操作 |
| 挑战 AI | 本地单人挑战内置 AI |
| AI 训练 | 通过 UI 选择卡组、对局数量和训练类型 |
| 局域网联机 | 大厅内创建或加入 LAN 房间，端口由 UI 输入 |
| Relay 联机 | 大厅内连接 Relay 服务器创建或加入房间 |

`main.py` 不再接受 `--host`、`--client`、`--relay` 或 `--room` 等客户端联机参数。

## 深度 AI 训练

推荐在 `DL` Conda 环境中使用 CUDA。训练脚本会自动使用多进程生成对局、在 GPU 上进行混合精度批量更新，并从该牌组已有评估结果最好的检查点继续训练。

```bash
conda run -n DL python scripts/train_deep_ai.py \
  --deck fire --device cuda --workers 12 \
  --bootstrap-games 512 --dagger-games 128 --games 256 \
  --pure-rl-games 64 --replay-same-deal 16 \
  --mcts-simulations 96 --eval-games 600 \
  --acceptance-metric points \
  --progress-jsonl data/ai_models/train_fire.jsonl
```

只有通过同种子评估门槛且无非法/无目标动作的模型才会被标记为可部署。使用 `--no-warm-start` 可强制从随机初始化模型重新训练。

## 预组卡组

项目内置 8 套 60 张预组卡组：

| # | 卡组 | 属性 | 核心 |
|---|------|------|------|
| 1 | 烈焰猴 | 火 | 烈焰猴 |
| 2 | 甲贺忍蛙ex | 水 | 甲贺忍蛙ex |
| 3 | 天然鸟 | 超 | 天然雀 / 天然鸟 |
| 4 | 皮卡丘ex | 雷 | 皮卡丘ex |
| 5 | 路卡利欧 | 斗 | 路卡利欧 |
| 6 | 一对鼠ex | 无色 | 一对鼠ex |
| 7 | 七夕青鸟ex | 龙 | 七夕青鸟ex |
| 8 | 土台龟 | 草 | 土台龟 |

## 项目结构

```text
PokemonTCG/
├── main.py                    # UI-only 客户端入口
├── config.py                  # 客户端默认值和跨层共享配置
├── relay_server.py            # Relay 服务端部署工具
├── build_exe.py               # PyInstaller 构建工具
├── engine/                    # 游戏规则、状态、动作解析和 AI
│   ├── rules_constants.py     # 引擎规则常量
│   └── ai/challenge/          # ChallengeAI 类型与协作模块
├── ui/                        # Pygame 界面、画面和组件
├── data/                      # 卡牌模型、注册表、卡组定义和图片
├── card_data/
│   ├── templates/             # 内置卡牌模板，按类型拆分
│   ├── effects/               # 卡牌效果数据，按类型拆分
│   └── card_effects.py        # 兼容聚合入口
├── scripts/
│   ├── train_challenge_ai.py  # UI 调用的挑战 AI 训练脚本
│   └── train_deep_ai.py       # UI 调用的深度 AI 训练脚本
└── tests/                     # unittest 测试
```

## 卡牌图片

卡图位于 `data/images/`，映射文件为 `data/card_image_mapping.json`。游戏内「卡图管理工作台」以 `api_id` 作为权威映射键，新增或迁移后的文件命名为 `卡名__api_id.ext`，可以稳定区分同名卡；未匹配到图片时会显示文字替代卡面。

## 打包构建

```bash
python build_exe.py
python build_exe.py --onefile
```

`build_exe.py` 和 `relay_server.py` 是构建/部署工具，不属于客户端 UI-only 运行入口。打包版默认不包含 `scripts/`、PyTorch 或训练依赖，AI 训练入口仅在源码环境可用。

## 验证

```bash
python -B -m unittest discover -q
python -B tests/test_multiplayer.py
```

当前测试套件使用 `unittest`。未安装 `pytest` 时无需用 `pytest` 作为默认验证入口。

## 依赖

| 包 | 用途 |
|----|------|
| `pygame` | 窗口、输入、渲染 |
| `requests` | 卡图管理界面下载远程图片 |
| `Pillow` | 图片加载回退 |
| `websockets` | LAN / Relay 网络通信 |
| `numpy` | 音效波形生成（不可用时自动静音） |
| `matplotlib` | AI 训练可视化/分析（`requirements-ai.txt` / `environment.yml`） |
| `torch` | 深度 AI 训练（`requirements-ai.txt` / `environment.yml`） |
| `PyInstaller` | 构建独立 exe |

## 致谢

游戏规则基于宝可梦集换式卡牌游戏官方规则。卡牌名称、效果和图片仅供学习交流。

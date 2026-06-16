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

## 游戏模式

| 模式 | 说明 |
|------|------|
| 本地对战 | 两名玩家在同一台电脑上轮流操作 |
| 挑战 AI | 本地单人挑战内置 AI |
| AI 训练 | 通过 UI 选择卡组、对局数量和训练类型 |
| 局域网联机 | 大厅内创建或加入 LAN 房间，端口由 UI 输入 |
| Relay 联机 | 大厅内连接 Relay 服务器创建或加入房间 |

`main.py` 不再接受 `--host`、`--client`、`--relay` 或 `--room` 等客户端联机参数。

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

卡图位于 `data/images/`，映射文件为 `data/card_image_mapping.json`。游戏内「卡牌图片分配」画面可以维护卡牌名称、API ID 与本地图片路径的映射；未匹配到图片时会显示文字替代卡面。

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

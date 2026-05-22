# 宝可梦集换式卡牌游戏 (Pokemon TCG)

基于 Python + Pygame 开发的双人数字版宝可梦集换式卡牌游戏。实现了朱&紫（Scarlet & Violet）时代完整的 PTCG 规则，支持本地同屏、局域网直连、以及云端中继三种对战模式。内置 8 套 60 张的预组卡组，附带 117 张卡牌图片。

---

## 目录

- [特性](#特性)
- [快速开始](#快速开始)
- [游戏模式](#游戏模式)
- [预组卡组](#预组卡组)
- [命令行参数](#命令行参数)
- [项目架构](#项目架构)
- [打包构建](#打包构建)
- [卡牌图片系统](#卡牌图片系统)
- [API 集成（可选）](#api-集成可选)
- [依赖](#依赖)

---

## 特性

### 完整游戏规则

- 60 张卡组，同名卡最多 4 张，7 张起手手牌，6 张奖赏卡
- 5 个备战区席位，每回合 1 次能量附着，1 次撤退，1 张支援者
- 完整回合结构：抽牌阶段 → 主要阶段（拍宝可梦、进化、附着能量、使用训练家、使用特性、撤退） → 战斗阶段 → 宝可梦检测
- 伤害计算：基础伤害 → 弱点（x2） → 抗性（-20/-30） → 最低 0
- 五种特殊状态：中毒、灼伤、睡眠、麻痹、混乱（互斥规则）
- 胜利条件：拿完 6 张奖赏卡 / 对方无宝可梦在场 / 对方回合开始无法抽牌
- 奖赏卡价值：基础宝可梦=1，ex/GX/V=2，VMAX/TAG TEAM=3
- 再战规则：起手无基础宝可梦→洗回牌组重抽 7 张，对方多抽 1 张

### 三种对战模式

| 模式 | 说明 |
|------|------|
| **本地同屏** | 两人在同一台电脑上轮流操作（热座模式） |
| **局域网直连** | 通过 WebSocket P2P 直连，一人建主机一人加入 |
| **云端中继** | 通过部署在 AWS EC2 的中继服务器自动匹配对战 |

### 8 套预组卡组

基于朱&紫时代真实卡牌构筑，每套 60 张，开箱即玩。

### 全中文界面

卡牌名称、按钮标签、规则文本、状态效果全部中文化。屏幕分辨率 1600×1000，支持等比例缩放。

---

## 快速开始

### 环境要求

- Python 3.10+
- Windows / macOS / Linux

### 安装与运行

```bash
# 1. 克隆仓库
git clone https://github.com/你的用户名/PokemonTCG.git
cd PokemonTCG

# 2. 安装依赖
pip install -r requirements.txt

# 3. 启动游戏
python main.py
```

启动后将进入标题画面，选择游戏模式后即可开始对战。

---

## 游戏模式

### 本地同屏（热座）

```bash
python main.py
```

选择「本地对战」后，两名玩家在同一屏幕上轮流操作。每位玩家的回合开始时会显示「传递画面」提示对方回避视线，确保手牌私密。

### 局域网直连

**主机方：**
```bash
python main.py --host
# 或指定端口
python main.py --host 8765
```

**客机方：**
```bash
python main.py --client <主机IP> <端口>
# 例如
python main.py --client 192.168.1.100 8765
```

### 云端中继

```bash
# 连接到默认中继服务器
python main.py --relay <中继服务器IP> <端口>

# 加入指定房间
python main.py --relay <中继服务器IP> <端口> --room <房间码>
```

中继服务器默认部署在 `ws://52.78.231.177:8766`（AWS EC2 韩国区域）。

---

## 预组卡组

| # | 卡组 | 属性 | 核心 | 策略简介 |
|---|------|------|------|----------|
| 1 | 烈焰猴 | 火 | 烈焰猴 | 弃牌堆能量越多伤害越高，「燃烧飞膝」高爆发 |
| 2 | 甲贺忍蛙ex | 水 | 甲贺忍蛙ex | 备战区狙击，条件式爆发伤害 |
| 3 | 天然鸟 | 超 | 天然雀/天然鸟 | 手牌能量加速，多核心基础宝可梦 |
| 4 | 皮卡丘ex | 雷 | 皮卡丘ex | 220 伤害大招，能量弃置风险 |
| 5 | 路卡利欧 | 斗 | 路卡利欧 | 自伤换能量加速，斗能量弃置爆发 |
| 6 | 一对鼠ex | 无色 | 一对鼠ex | 手牌数决定伤害，反伤特性 |
| 7 | 七夕青鸟ex | 龙 | 七夕青鸟ex | 大量回复，免疫攻击 |
| 8 | 土台龟 | 草 | 土台龟 | 进化宝可梦数量决定伤害 |

---

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--host [端口]` | 创建局域网主机（默认端口 8765） |
| `--client <IP> <端口>` | 加入局域网对战 |
| `--relay <主机> <端口>` | 连接到中继服务器 |
| `--room <房间码>` | 配合 `--relay`，加入指定房间 |

---

## 项目架构

```
PokemonTCG/
├── main.py                    # 入口，命令行参数解析
├── config.py                  # 全局配置（API Key、服务器地址等）
├── relay_server.py            # 云端中继服务器（可独立部署）
├── build_exe.py               # PyInstaller 打包脚本
│
├── ui/                        # 用户界面层 (Pygame)
│   ├── game_app.py            # 主应用类，游戏循环
│   ├── screen_manager.py      # 画面管理器（栈式路由）
│   ├── image_manager.py       # 卡牌图片加载与缓存
│   ├── screens/               # 各画面实现
│   │   ├── title_screen.py    # 标题画面
│   │   ├── lobby_screen.py    # 大厅/联机画面
│   │   ├── deck_select.py     # 卡组选择
│   │   ├── game_screen.py     # 主对战画面
│   │   ├── end_screen.py      # 胜负结算画面
│   │   ├── help_screen.py     # 规则帮助画面
│   │   └── ...
│   └── components/            # 可复用 UI 组件
│       ├── board_renderer.py  # 棋盘渲染
│       ├── hand_display.py    # 手牌显示
│       ├── action_menu.py     # 操作菜单
│       ├── card_detail.py     # 卡牌详情弹窗
│       └── ...
│
├── engine/                    # 游戏引擎层（核心逻辑）
│   ├── game_state.py          # 主游戏状态
│   ├── player_state.py        # 玩家状态
│   ├── turn_manager.py        # 回合状态机
│   ├── action_resolver.py     # 动作解析执行
│   ├── damage_calculator.py   # 伤害计算
│   ├── rules_validator.py     # 规则校验
│   ├── enums.py               # 枚举定义
│   ├── snapshot.py            # 状态序列化
│   ├── commands/              # 新版指令系统（DSL 编译器、效果注册表）
│   └── effects/               # 效果处理器（伤害、抽牌、能量、检索等）
│
├── network/                   # 网络层
│   ├── network_manager.py     # WebSocket 线程桥接
│   ├── message_protocol.py    # 消息协议定义
│   └── state_serializer.py    # GameState ↔ JSON
│
├── data/                      # 卡牌数据层
│   ├── card_registry.py       # 卡牌注册表（离线卡牌模板 ~85 张）
│   ├── card_models.py         # 卡牌数据模型（dataclass）
│   ├── deck_definitions.py    # 8 套预组卡组定义
│   ├── api_client.py          # pokemontcg.io API 客户端
│   ├── cache_manager.py       # JSON 文件缓存管理
│   └── images/                # 卡牌图片（117 张）
│       ├── 宝可梦/             # 69 张宝可梦卡图
│       ├── 支援者/             # 15 张支援者卡图
│       ├── 物品/               # 16 张物品卡图
│       ├── 能量/               # 12 张能量卡图
│       ├── 宝可梦道具/          # 4 张宝可梦道具卡图
│       └── 卡背.webp           # 卡背图片
│
├── card_data/                 # 卡牌效果数据
│   └── card_effects.py        # 每张卡的攻击/特性/训练家效果定义
│
├── scripts/                   # 辅助脚本
│   ├── fetch_cards.py         # 从 API 拉取卡牌数据/图片
│   └── launch_multiplayer.py  # 一键启动双窗口测试
│
├── tests/                     # 测试
│   └── test_multiplayer.py    # 多人对战测试
│
└── utils/                     # 工具
    └── logger.py              # 日志配置
```

---

## 打包构建

使用 PyInstaller 打包为独立 Windows 可执行文件：

```bash
# onedir 模式（推荐，图片缓存可保留）
python build_exe.py

# 单文件模式（图片缓存在退出时丢失）
python build_exe.py --onefile
```

打包产物在 `dist/` 目录下。

---

## 卡牌图片系统

### 图片组织

卡牌图片按类型分目录存放在 `data/images/` 下，支持 `.webp`、`.png`、`.jpg` 格式。

### 图片映射

`data/card_image_mapping.json` 维护了卡牌中文名称和 API ID 到图片文件路径的映射关系。游戏启动时自动加载该映射，并支持通过游戏内的「卡牌图片分配」画面进行编辑。

### 图片查找优先级

1. 按 API ID 查自定义映射
2. 按中文名称查自定义映射
3. 按 API ID 自动匹配文件名
4. 按中文名称自动匹配文件名

未匹配到图片时，游戏显示文字替代。

---

## API 集成（可选）

项目内置了 [pokemontcg.io](https://pokemontcg.io) API 支持，用于获取卡牌数据和下载卡图。

1. 前往 https://dev.pokemontcg.io 获取免费 API Key
2. 在 `config.py` 中设置 `POKEMON_TCG_API_KEY = "你的APIKey"`
3. 使用脚本拉取卡牌数据：

```bash
# 拉取所有预组卡组的卡牌数据
python scripts/fetch_cards.py --all-deck-cards

# 拉取指定卡牌
python scripts/fetch_cards.py --card-id sv3-26

# 下载卡图
python scripts/fetch_cards.py --image sv3-26
```

**注意：** 即使不配置 API Key，游戏也能完全离线运行 —— 所有卡牌数据已通过 `OFFLINE_CARD_TEMPLATES` 硬编码内置。

---

## 依赖

| 包 | 版本 | 用途 |
|----|------|------|
| `pygame` | ≥ 2.5.0 | 窗口、输入、渲染 |
| `pokemontcgsdk` | ≥ 2.0.0 | 宝可梦 TCG API SDK（可选） |
| `requests` | ≥ 2.28.0 | HTTP 请求 |
| `Pillow` | ≥ 10.0.0 | 图片加载（WebP 回退） |
| `websockets` | ≥ 12.0 | WebSocket 网络通信 |
| `PyInstaller` | 构建时 | 打包为独立 exe |

---

## 致谢

- 卡牌数据来自 [pokemontcg.io](https://pokemontcg.io)
- 游戏规则基于宝可梦集换式卡牌游戏官方规则

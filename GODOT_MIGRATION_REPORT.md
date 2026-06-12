# PokemonTCG 迁移 Godot 方案报告

## 1. 报告目的

本文档用于评估当前 `PokemonTCG` 项目迁移到 Godot 的可行性，并给出一套可执行的迁移方案。报告重点回答以下问题：

- 当前项目是否适合迁移到 Godot。
- 哪些模块适合保留，哪些模块需要重写。
- 推荐采用什么架构迁移。
- 分阶段迁移如何落地。
- 风险、成本、验收标准和后续演进路径是什么。

结论先行：

当前项目适合迁移到 Godot，但不适合一次性全量重写。推荐路线是先采用“Godot 客户端 + Python 权威规则引擎”的混合架构，用 Godot 重做表现层、交互层、动画层和资源管理层，保留现有 Python 的规则、状态、AI、训练、联机协议和测试资产。待 Godot 客户端稳定后，再决定是否逐步把规则引擎迁成 Godot 原生实现。

## 2. 当前项目概况

### 2.1 技术栈

当前项目是一个 Python + Pygame 的宝可梦集换式卡牌对战客户端，主要依赖包括：

- Python 3.11
- Pygame：窗口、输入、渲染、音频、动画
- websockets：LAN / Relay 联机通信
- requests：卡图管理界面下载远程图片
- Pillow：图片加载和 WebP 回退
- PyTorch / numpy：深度学习 AI 和训练相关能力
- unittest：当前测试套件

项目入口位于 `main.py`，启动逻辑非常简单：

```python
from ui.game_app import GameApp

def main():
    GameApp().run()
```

这说明客户端入口是 UI-only，主流程由 `ui.game_app.GameApp` 接管。

### 2.2 目录结构和职责划分

当前项目大致可以分为以下模块：

| 模块 | 主要职责 | 迁移判断 |
|---|---|---|
| `engine/` | 游戏状态、规则、动作解析、回合推进、AI | 可保留，后续可选择性迁移 |
| `ui/` | Pygame 界面、屏幕、渲染、动画、输入 | 基本需要在 Godot 中重写 |
| `network/` | WebSocket 管理、消息协议、状态序列化 | 可大量复用协议和序列化思路 |
| `data/` | 卡牌模型、卡牌注册表、卡组定义、图片映射 | 可导出为 JSON / Godot Resource |
| `card_data/` | 内置卡牌模板和效果数据 | 建议先导出 JSON，避免手工双写 |
| `scripts/` | AI 训练脚本 | 保留 Python |
| `tests/` | unittest 测试 | 保留并作为迁移对照测试 |

### 2.3 项目规模

当前项目包含大量 Python 文件，且最大模块集中在 UI 和 AI：

| 文件 | 约行数 | 说明 |
|---|---:|---|
| `ui/screens/game_screen.py` | 3700+ | 主游戏屏幕，交互和状态粘合度高 |
| `engine/ai/challenge_ai.py` | 3400+ | 挑战 AI |
| `engine/ai/dl/training.py` | 2200+ | 深度学习训练 |
| `ui/screens/ai_training_screen.py` | 1200+ | AI 训练 UI |
| `ui/screens/card_image_screen.py` | 1100+ | 卡图管理 UI |
| `ui/components/board_renderer.py` | 1000+ | 棋盘绘制 |

这说明迁移的主要成本不在规则模型本身，而在：

- 主游戏界面的重构。
- Pygame 渲染转 Godot Scene / Control。
- 复杂交互流程迁移。
- 动画和状态更新表现迁移。
- AI 训练 UI 和外部脚本集成。

## 3. 迁移可行性评估

### 3.1 总体结论

迁移可行，而且从长期维护角度看是有价值的。原因是：

- 当前规则层和 UI 层已经有一定分离。
- `GameState` / `TurnManager` / `ActionResolver` 可以作为稳定的规则边界。
- 网络状态已经使用 JSON 序列化，适合被 Godot 消费。
- 卡牌效果已经结构化为 `EffectDef`，具备数据驱动迁移基础。
- Godot 的 Scene / Node / Control 系统更适合复杂棋盘 UI、卡牌对象、拖拽、动画和弹窗。

但不建议一次性把所有 Python 代码翻译为 GDScript 或 C#。当前规则、AI、训练和测试资产已经很重，贸然全量重写会带来高风险：

- 卡牌规则回归风险高。
- pending action / callback 流程复杂。
- AI 和 PyTorch 迁移收益低、成本高。
- 联机隐藏信息和状态一致性容易出问题。
- 测试体系需要重建。

### 3.2 Godot 对项目需求的匹配度

| 需求 | Godot 匹配度 | 说明 |
|---|---:|---|
| 棋盘布局 | 高 | 可用 `Control`、`Container`、自定义场景组合 |
| 卡牌组件 | 高 | 每张牌可作为独立 `CardView.tscn` |
| 拖拽和点击 | 高 | Godot Control 支持输入事件和拖放接口 |
| 动画 | 高 | `Tween`、`AnimationPlayer`、粒子、Shader 都适合卡牌表现 |
| 音频 | 高 | Godot 原生音频系统足够替代 Pygame mixer |
| 图片资源 | 高 | 可直接管理 PNG / WebP / Texture |
| 本地对战 | 高 | Godot 负责 UI，Python 负责规则即可 |
| 远程联机 | 中高 | 现有 WebSocket + JSON 协议可延续 |
| 卡牌数据 | 中高 | 建议从 Python 模板导出 JSON |
| 规则引擎 | 中 | 保留 Python 较好；完全迁移成本较高 |
| AI 训练 | 低到中 | 应继续保留 Python / PyTorch |
| Web 发布 | 中 | 如果使用 C# 和 Python 外部进程会受限制 |

### 3.3 当前项目最适合迁移的部分

最适合迁移到 Godot 的模块：

- 标题界面
- 卡组选择界面
- 大厅界面
- 游戏棋盘
- 手牌、战斗区、备战区、弃牌区、奖品卡显示
- 卡牌放大预览
- 动作按钮
- 攻击菜单
- 特性菜单
- 搜索/选择弹窗
- 硬币动画
- 抽牌、弃牌、进化、攻击、击倒动画
- 音效和视觉反馈

最不建议第一阶段迁移的模块：

- `engine/action_resolver.py`
- `engine/turn_manager.py`
- `engine/effects/*`
- `engine/commands/*`
- `engine/ai/*`
- `scripts/train_*.py`
- PyTorch 模型和训练流程

这些模块已经具备可运行的业务能力，应优先作为 Godot 客户端背后的权威服务保留。

## 4. 当前架构分析

### 4.1 入口和主循环

当前入口：

- `main.py`
- `ui/game_app.py`

`GameApp` 负责：

- 初始化 Pygame。
- 创建窗口。
- 创建虚拟画布。
- 处理 resize letterbox。
- 转换鼠标坐标。
- 调用 `ScreenManager`。
- 启动本地游戏或联机游戏。

在 Godot 中，这部分应整体替换为：

- Godot Project 主场景。
- `SceneRouter` 或 `ScreenManager` Autoload。
- Godot Viewport / window stretch 设置。
- Godot 输入系统。
- Godot SceneTree。

不建议逐行迁移 `GameApp`。Godot 已经提供了主循环和窗口管理能力。

### 4.2 规则状态

核心状态：

- `engine/game_state.py`
- `engine/player_state.py`
- `data/card_models.py`

关键对象：

- `GameState`
- `PlayerState`
- `PokemonInPlay`
- `Card`
- `AttackDef`
- `AbilityDef`
- `EffectDef`
- `ActionRequest`
- `ActionResult`

这些对象有较清晰的边界：

- `GameState` 管理双方玩家、回合、阶段、胜负、日志、场馆、待晋升等。
- `PlayerState` 管理手牌、牌库、弃牌区、奖品卡、战斗宝可梦、备战宝可梦和每回合标记。
- `ActionResolver` 修改 `GameState` 并返回 `ActionResult`。
- 遇到需要玩家选择的效果时，返回 `ActionRequest`。

这套设计非常适合作为服务端权威引擎保留。Godot 端无需知道所有内部规则，只需要：

- 显示当前状态。
- 根据状态启用/禁用操作。
- 将用户动作转换为 JSON。
- 显示 `ActionResult` 和 `ActionRequest`。

### 4.3 动作和回合

核心动作入口：

- `TurnManager.perform_action(action, player_idx, **params)`
- `ActionResolver.resolve(action, **params)`

当前支持的主要动作：

- `PLAY_BASIC`
- `EVOLVE`
- `ATTACH_ENERGY`
- `PLAY_TRAINER`
- `USE_ABILITY`
- `USE_STADIUM`
- `RETREAT`
- `DECLARE_ATTACK`
- `END_TURN`

Godot 端应把所有 UI 操作统一转换为这些动作，而不是直接修改状态。

示例：

```json
{
  "type": "action",
  "action": "ATTACH_ENERGY",
  "params": {
    "player_idx": 0,
    "hand_idx": 3,
    "target_slot": "active"
  }
}
```

Python 引擎处理后返回：

```json
{
  "type": "state_update",
  "state": {},
  "result": {
    "success": true,
    "log_message": "玩家1将火能量附着于战斗宝可梦。",
    "damage_dealt": 0,
    "pokemon_ko": [],
    "status_applied": []
  }
}
```

### 4.4 Pending Action 流程

当前项目有很多需要玩家继续选择的效果：

- 从牌库检索。
- 选择手牌弃置。
- 选择备战宝可梦。
- 选择对手备战宝可梦。
- 硬币判定。
- 选择能量分配。
- 确认操作。

这些由 `ActionRequest` 表示，其中包括：

- `request_type`
- `player`
- `prompt`
- `min_select`
- `max_select`
- `from_zone`
- `card_list`
- `target_player`
- `bench_indices`
- `allow_duplicates`
- `flip_count`
- `until_tails`
- `distribute_mode`
- `target_info`
- `request_id`
- `callback`

迁移重点：

`callback` 不能跨进程传给 Godot，也不能序列化。正确做法是：

- Python 端保留 `request_id -> callback`。
- Godot 端只收到可展示字段。
- Godot 展示选择界面。
- 用户完成选择后，Godot 发回 `choice_response`。
- Python 根据 `request_id` 找回 callback 并继续结算。

这和当前联机逻辑中的 `serialize_action_request` / `deserialize_action_request` 思路一致，可以复用并强化。

## 5. 推荐目标架构

### 5.1 架构选择

推荐第一阶段采用混合架构：

```text
Godot Client
  - UI
  - 动画
  - 输入
  - 卡图展示
  - 弹窗选择
  - 本地/远程连接管理

Python Engine Service
  - GameState
  - TurnManager
  - ActionResolver
  - CardRegistry
  - Effect DSL
  - AI
  - Training
  - 权威状态

Relay Server
  - 保留现有 relay_server.py
  - 或逐步替换为独立服务
```

### 5.2 架构图

```text
+------------------------------------------------+
|                 Godot Client                   |
|------------------------------------------------|
| TitleScene                                     |
| LobbyScene                                     |
| DeckSelectScene                                |
| BoardScene                                     |
|   - BoardView                                  |
|   - HandView                                   |
|   - CardView                                   |
|   - ZoneView                                   |
|   - ActionPanel                                |
|   - LogPanel                                   |
|   - ChoiceOverlay                              |
|                                                |
| Autoloads                                      |
|   - GameSession                                |
|   - CardDatabase                               |
|   - NetClient                                  |
|   - SceneRouter                                |
|   - AssetResolver                              |
+-------------------------+----------------------+
                          |
                          | JSON / WebSocket
                          |
+-------------------------v----------------------+
|              Python Engine Service             |
|------------------------------------------------|
| GameState                                      |
| PlayerState                                    |
| TurnManager                                    |
| ActionResolver                                 |
| CardRegistry                                   |
| Effect/Command system                          |
| AI Controller                                  |
| PendingRequestStore                            |
+-------------------------+----------------------+
                          |
                          | Optional
                          |
+-------------------------v----------------------+
|                 Relay Server                   |
|------------------------------------------------|
| Room create / join                             |
| Message relay                                  |
| Heartbeat                                      |
+------------------------------------------------+
```

### 5.3 Godot 项目结构建议

建议新建 Godot 项目目录，例如：

```text
godot_client/
  project.godot
  scenes/
    title/
      TitleScene.tscn
      TitleScene.gd
    lobby/
      LobbyScene.tscn
      LobbyScene.gd
    deck_select/
      DeckSelectScene.tscn
      DeckSelectScene.gd
    board/
      BoardScene.tscn
      BoardScene.gd
      CardView.tscn
      CardView.gd
      ZoneView.tscn
      ZoneView.gd
      HandView.tscn
      HandView.gd
      ActionPanel.tscn
      ActionPanel.gd
      LogPanel.tscn
      LogPanel.gd
      ChoiceOverlay.tscn
      ChoiceOverlay.gd
  autoload/
    GameSession.gd
    CardDatabase.gd
    NetClient.gd
    SceneRouter.gd
    AssetResolver.gd
  data/
    cards.json
    effects.json
    decks.json
    card_image_mapping.json
  assets/
    cards/
    ui/
    audio/
    fonts/
```

### 5.4 Python 服务结构建议

在现有项目中新增服务入口，而不是修改 `main.py`：

```text
engine_service/
  __init__.py
  server.py
  session.py
  protocol.py
  pending_requests.py
  export_cards.py
```

职责：

- `server.py`：本地 WebSocket 或 TCP/JSON 服务入口。
- `session.py`：封装一局游戏，持有 `GameState`、`TurnManager`、玩家座位和模式。
- `protocol.py`：定义 Godot 和 Python 之间的消息格式。
- `pending_requests.py`：维护 `request_id -> ActionRequest.callback`。
- `export_cards.py`：导出 Godot 可读的卡牌 JSON。

## 6. 协议设计

### 6.1 设计原则

协议应满足：

- Godot 不直接修改游戏状态。
- Python 是权威状态源。
- 所有动作都通过消息发送给 Python。
- 所有状态变化都通过 `state_update` 返回给 Godot。
- pending action 通过 `request_id` 继续结算。
- 本地对战、AI 对战、远程对战尽量使用同一套协议。

### 6.2 消息类型

建议协议包含以下消息：

| 消息 | 方向 | 说明 |
|---|---|---|
| `hello` | Godot -> Python | 客户端握手 |
| `hello_ack` | Python -> Godot | 服务确认 |
| `start_game` | Godot -> Python | 开始本地/AI/远程游戏 |
| `state_update` | Python -> Godot | 推送权威状态 |
| `action` | Godot -> Python | 玩家动作 |
| `action_result` | Python -> Godot | 动作结果，可与 `state_update` 合并 |
| `pending_action` | Python -> Godot | 要求玩家继续选择 |
| `choice_response` | Godot -> Python | 玩家完成选择 |
| `game_over` | Python -> Godot | 游戏结束 |
| `error` | Python -> Godot | 协议或规则错误 |
| `ping` / `pong` | 双向 | 心跳 |

### 6.3 开始游戏

Godot 发送：

```json
{
  "type": "start_game",
  "mode": "local",
  "players": [
    {"seat": 0, "kind": "human", "deck_key": "fire"},
    {"seat": 1, "kind": "human", "deck_key": "water"}
  ],
  "options": {
    "apply_type_matchups": false
  }
}
```

Python 返回：

```json
{
  "type": "state_update",
  "seq": 1,
  "state": {
    "phase": "SETUP",
    "turn_number": 1,
    "active_player_idx": 0,
    "your": {},
    "opponent": {}
  }
}
```

### 6.4 玩家动作

Godot 发送：

```json
{
  "type": "action",
  "request_seq": 12,
  "player_idx": 0,
  "action": "PLAY_BASIC",
  "params": {
    "hand_idx": 2,
    "target": "bench_0"
  }
}
```

Python 返回：

```json
{
  "type": "state_update",
  "seq": 13,
  "state": {},
  "result": {
    "success": true,
    "log_message": "玩家1将小火焰猴放置于备战区0。",
    "damage_dealt": 0,
    "pokemon_ko": [],
    "status_applied": [],
    "cards_drawn": 0,
    "cards_discarded": 0
  }
}
```

### 6.5 Pending Action

Python 返回：

```json
{
  "type": "pending_action",
  "request_id": "req-42",
  "request": {
    "request_type": "search_deck",
    "player": 0,
    "prompt": "从牌库选择1张基础宝可梦。",
    "min_select": 1,
    "max_select": 1,
    "from_zone": "deck",
    "card_list": ["svi-chim", "svi-ente", "svi-sqwk"]
  }
}
```

Godot 发送：

```json
{
  "type": "choice_response",
  "request_id": "req-42",
  "selected_indices": [0]
}
```

Python 继续执行 callback，然后返回新的 `state_update` 或下一个 `pending_action`。

### 6.6 错误处理

建议错误统一为：

```json
{
  "type": "error",
  "code": "INVALID_ACTION",
  "message": "不是你的回合。",
  "request_seq": 12
}
```

Godot 端只负责显示 toast / 日志，不直接回滚本地状态。因为 Godot 不做权威状态修改，所以回滚问题会显著减少。

## 7. 数据迁移方案

### 7.1 卡牌数据现状

当前卡牌数据分布在：

- `card_data/templates/*.py`
- `card_data/effects/*.py`
- `data/card_models.py`
- `data/card_registry.py`
- `data/deck_definitions.py`
- `data/card_image_mapping.json`
- `data/images/`

卡牌模板和效果目前是 Python dict，不是纯 JSON。Godot 不能直接加载 Python 模块，所以需要导出。

### 7.2 导出目标

建议导出以下文件：

```text
godot_client/data/cards.json
godot_client/data/effects.json
godot_client/data/decks.json
godot_client/data/card_image_mapping.json
```

### 7.3 `cards.json` 格式

```json
{
  "svi-chim": {
    "api_id": "svi-chim",
    "name": "小火焰猴",
    "supertype": "Pokémon",
    "subtypes": ["Basic"],
    "hp": 50,
    "energy_types": ["Fire"],
    "evolves_from": "",
    "attacks": [
      {
        "name": "火花",
        "cost": ["Fire"],
        "damage": 30,
        "text": "选择附着于这只宝可梦身上的1个能量，放于弃牌区。",
        "effects": [
          {
            "effect_type": "energy_discard",
            "params": {
              "amount": 1,
              "from": "self",
              "filter": "any"
            }
          }
        ]
      }
    ],
    "weaknesses": [{"energy_type": "Water", "value": "×2"}],
    "resistances": [],
    "retreat_cost": 1,
    "image_path": "assets/cards/宝可梦/小火焰猴.webp"
  }
}
```

### 7.4 `decks.json` 格式

```json
{
  "fire": {
    "name": "烈焰猴",
    "type": "Fire",
    "cards": [
      {"card_id": "svi-chim", "count": 4},
      {"card_id": "svi-monf", "count": 3}
    ]
  }
}
```

### 7.5 是否使用 Godot Resource

建议分两步：

第一步使用 JSON。优点：

- 与现有 Python 数据结构接近。
- 便于导出和对照。
- 便于 Python 与 Godot 同时读取。
- 便于协议调试。

第二步再考虑生成 `.tres` Resource。优点：

- 编辑器内可视化。
- 可绑定类型。
- 可被 Godot 资源系统索引。

不建议一开始手工维护 Resource，因为会导致 Python 和 Godot 两份卡牌数据不一致。

## 8. Godot 客户端设计

### 8.1 Autoload 设计

#### GameSession.gd

职责：

- 保存当前完整状态。
- 保存当前模式。
- 保存当前玩家座位。
- 统一派发状态更新信号。
- 提供查询当前玩家、对手、阶段、可操作状态的方法。

建议信号：

```gdscript
signal state_updated(state)
signal result_received(result)
signal pending_action_received(request)
signal game_over(winner, reason)
signal connection_status_changed(status)
```

#### NetClient.gd

职责：

- 连接 Python 引擎服务。
- 连接远程 relay 或 host。
- 发送 JSON。
- 接收 JSON。
- 维护心跳和重连状态。

接口：

```gdscript
func connect_local_engine(port: int) -> void
func send_action(action: String, params: Dictionary) -> void
func send_choice_response(request_id: String, payload: Dictionary) -> void
func send_start_game(config: Dictionary) -> void
```

#### CardDatabase.gd

职责：

- 加载 `cards.json`。
- 加载 `decks.json`。
- 通过 card_id 查询展示数据。
- 提供卡牌图片路径。

#### AssetResolver.gd

职责：

- 统一加载卡图、卡背、能量图标、字体、音效。
- 处理缺图 fallback。
- 做资源缓存。

### 8.2 Scene 设计

#### BoardScene

主游戏场景，建议结构：

```text
BoardScene
  BoardBackground
  OpponentArea
    OpponentInfo
    OpponentBench
    OpponentActive
    OpponentDeck
    OpponentDiscard
  CenterBar
    StadiumSlot
    PhaseLabel
    ConnectionIndicator
    ConcedeButton
    QuitButton
  PlayerArea
    PlayerActive
    PlayerBench
    PlayerInfo
    PlayerDeck
    PlayerDiscard
  HandView
  ActionPanel
  LogPanel
  CardDetailPanel
  OverlayLayer
    ChoiceOverlay
    ConfirmDialog
    CoinFlipOverlay
```

#### CardView

每张卡牌一个独立场景，字段：

- `card_id`
- `face_up`
- `selected`
- `hovered`
- `disabled`
- `zone`
- `owner_idx`
- `slot`

职责：

- 显示卡图或卡背。
- 显示伤害、状态、能量、工具、进化层数。
- 响应 hover / click / drag。
- 播放移动、翻转、闪光动画。

#### ZoneView

用于：

- 战斗区
- 备战区
- 手牌
- 牌库
- 弃牌区
- 奖品卡区
- 场馆区

职责：

- 接收 zone state。
- 创建和复用 `CardView`。
- 管理布局。
- 暴露 `card_clicked`、`zone_clicked` 信号。

#### ActionPanel

职责：

- 根据当前状态显示可用动作。
- 显示攻击、特性、撤退、结束回合等按钮。
- 根据规则状态禁用按钮。
- 不直接执行规则，只发出 `action_requested` 信号。

#### ChoiceOverlay

职责：

- 处理所有 `ActionRequest`：
  - `search_deck`
  - `select_hand`
  - `select_hand_to_discard`
  - `select_bench`
  - `select_opponent_bench`
  - `select_bench_targets`
  - `coin_flip`
  - `confirm`
  - `distribute_energy`

建议每种 request type 可以拆成子组件，但对外统一接口：

```gdscript
func show_request(request: Dictionary) -> void
signal choice_completed(request_id, payload)
signal choice_cancelled(request_id)
```

### 8.3 UI 行为映射

| 当前 Pygame 行为 | Godot 迁移方式 |
|---|---|
| 鼠标坐标碰撞 `pygame.Rect.collidepoint` | `Control` 输入事件 / 自定义 hit test |
| 手动绘制按钮 | Godot Button / TextureButton / 自定义 Control |
| 手动绘制卡牌 | `CardView` + `TextureRect` / 自绘 Control |
| 手动布局常量 | Container + anchor + responsive layout |
| ScreenManager 栈 | SceneTree + SceneRouter + overlay layer |
| Pygame animation manager | Tween / AnimationPlayer |
| Pygame particle manager | GPUParticles2D / CPUParticles2D |
| Pygame mixer | AudioStreamPlayer |
| Pygame image cache | Godot ResourceLoader + AssetResolver |

## 9. Python 引擎服务设计

### 9.1 为什么保留 Python 引擎

保留 Python 引擎有几个明显收益：

- 保留现有规则正确性。
- 保留现有测试。
- 保留 AI 和训练能力。
- 保留 PyTorch 模型。
- 保留卡牌效果 DSL。
- 降低第一版迁移风险。

### 9.2 Session 设计

建议新增 `GameSession`：

```python
class GameSession:
    def __init__(self, mode: str, players: list[dict], options: dict):
        self.state = GameState()
        self.tm = TurnManager(self.state)
        self.pending = PendingRequestStore()
        self.seq = 0

    def start_game(self):
        ...

    def perform_action(self, player_idx: int, action: str, params: dict) -> dict:
        ...

    def resolve_choice(self, request_id: str, payload: dict) -> dict:
        ...

    def serialize_for_player(self, player_idx: int) -> dict:
        ...
```

### 9.3 PendingRequestStore

```python
class PendingRequestStore:
    def __init__(self):
        self._callbacks = {}
        self._counter = 0

    def register(self, req: ActionRequest) -> dict:
        self._counter += 1
        req.request_id = f"req-{self._counter}"
        self._callbacks[req.request_id] = req.callback
        return serialize_action_request(req)

    def resolve(self, request_id: str, payload: dict):
        callback = self._callbacks.pop(request_id, None)
        if callback is None:
            raise ValueError("Unknown pending request")
        return callback(payload)
```

注意：

- `callback` 只存在 Python 进程内。
- 发送给 Godot 的请求必须去掉 callback。
- 每次 callback 返回 `ActionRequest` 时，要继续注册新的 request。

### 9.4 本地服务通信方式

推荐优先使用 WebSocket，而不是 stdin/stdout：

- 当前项目已经使用 WebSocket。
- Godot 有 WebSocket 支持。
- 本地对战和远程对战可以使用相同消息格式。
- 调试工具更容易接入。

本地启动方式：

- Godot 启动时检查 Python engine service 是否运行。
- 如果未运行，Godot 通过 `OS.create_process` 启动本地 Python 服务。
- Python 服务监听 `127.0.0.1` 的固定或随机端口。
- Godot 连接后发送 `hello`。

桌面版可行。Web 版不适合这个方案，因为浏览器环境不能启动本地 Python 进程。

## 10. 联机迁移方案

### 10.1 当前联机特点

当前项目已有：

- `network/network_manager.py`
- `network/message_protocol.py`
- `network/state_serializer.py`
- `relay_server.py`

现有设计关键点：

- WebSocket 通信。
- host/client 模式。
- relay 房间模式。
- 心跳。
- 序列号。
- 状态更新 coalescing。
- 按玩家隐藏手牌和隐藏牌库/奖品信息。

这些都应尽量保留。

### 10.2 第一阶段联机架构

推荐：

- Python host 仍是权威状态源。
- Godot 客户端连接 Python host 或 relay。
- relay 服务暂时保持 Python 实现。
- 消息协议尽量沿用现有 `MSG_STATE_UPDATE`、`MSG_ACTION`、`MSG_CHOICE_RESPONSE`。

```text
Godot Client A
   |
   | action / choice_response
   v
Python Host Engine
   |
   | state_update for player B
   v
Relay Server
   |
   v
Godot Client B
```

### 10.3 是否使用 Godot high-level multiplayer

第一阶段不建议使用 Godot high-level multiplayer。

原因：

- 当前协议已经是 WebSocket + JSON。
- 当前状态同步需要隐藏信息过滤。
- 当前游戏是回合制，不需要低延迟状态复制。
- Godot high-level multiplayer 更适合 RPC 和同步节点，不适合作为第一阶段替代现有规则协议。

后续如果要完全 Godot 原生化，可以再评估。

## 11. AI 和训练迁移方案

### 11.1 结论

AI 和训练不建议迁移到 Godot。

原因：

- 当前 AI 代码规模大。
- 深度学习依赖 PyTorch。
- Godot 不适合作为训练运行环境。
- 训练通常是离线任务，不需要嵌入游戏主进程。

### 11.2 Godot 中如何保留 AI 功能

Godot 只做 UI：

- 选择训练类型。
- 选择卡组。
- 选择对局数量。
- 选择 CPU / CUDA。
- 启动 Python 训练脚本。
- 显示训练进度。
- 显示训练结果。

Python 训练脚本负责：

- 执行训练。
- 写入 progress JSON / log。
- 保存模型。
- 输出 benchmark。

建议训练进度文件：

```json
{
  "status": "running",
  "deck": "fire",
  "generation": 12,
  "total_generations": 50,
  "win_rate": 0.62,
  "best_score": 0.74,
  "message": "Benchmarking candidate policy"
}
```

Godot 定时读取或通过 WebSocket 接收进度事件。

## 12. 分阶段实施计划

### 阶段 0：准备和冻结协议

目标：

- 明确迁移边界。
- 冻结 Python 规则接口。
- 定义 Godot 通信协议。

任务：

- 编写 `engine_service/protocol.py`。
- 统一 `ACTION_TO_STRING` 和 `STRING_TO_ACTION`。
- 明确 `state_update` schema。
- 明确 `pending_action` schema。
- 补充协议测试。
- 编写卡牌数据导出脚本。

产出：

- 协议文档。
- Python engine service 初版。
- `cards.json` / `decks.json` 导出文件。

建议耗时：

- 1 到 2 周。

验收：

- 不启动 Pygame，也能通过 Python 服务创建一局游戏。
- 可以发送 `start_game`、`action`，收到 `state_update`。
- pending action 能注册并 resolve。

### 阶段 1：Godot 静态棋盘原型

目标：

- Godot 能展示一份 `state_update`。
- 不要求完整交互。

任务：

- 创建 Godot 项目。
- 创建 `CardDatabase.gd`。
- 创建 `BoardScene`。
- 创建 `CardView`。
- 创建基础区域：
  - 战斗区
  - 备战区
  - 手牌
  - 牌库
  - 弃牌区
  - 奖品卡
  - 日志
- 加载卡图。
- 缺图 fallback。

产出：

- Godot 可视化棋盘。

建议耗时：

- 1 到 2 周。

验收：

- 能从 JSON 状态渲染双方场面。
- 手牌、场上、弃牌、牌库数量正确。
- 卡图和卡背显示正确。
- 窗口缩放后布局不崩。

### 阶段 2：接入本地 Python 引擎

目标：

- Godot 可以启动一局本地游戏。
- Godot 点击动作后，Python 返回权威状态。

任务：

- 实现 `NetClient.gd`。
- 连接 Python engine service。
- 实现 `start_game`。
- 实现基础动作：
  - 设置战斗宝可梦
  - 放置备战宝可梦
  - 附能
  - 结束回合
- 实现日志更新。
- 实现错误 toast。

产出：

- Godot + Python 本地对战最小可玩版。

建议耗时：

- 2 周。

验收：

- 可以完成 setup。
- 可以进入 main phase。
- 可以附能和结束回合。
- Python 状态和 Godot 显示一致。

### 阶段 3：完整动作和 Pending Action

目标：

- 支持完整卡牌操作流程。

任务：

- 进化。
- 使用训练家。
- 使用特性。
- 使用竞技场。
- 撤退。
- 宣告攻击。
- 搜索牌库。
- 选择手牌弃置。
- 选择备战目标。
- 选择对手备战目标。
- 能量分配。
- 硬币动画和结果回传。
- 连锁 pending action。

产出：

- 本地完整规则可玩。

建议耗时：

- 3 到 5 周。

验收：

- 现有 8 套预组卡组的主要效果都能跑通。
- pending action 不丢 callback。
- 取消操作能正确回滚。
- 连续 pending action 能正确结算。

### 阶段 4：动画、音效、视觉表现

目标：

- 替代 Pygame 的动画和反馈。

任务：

- 抽牌动画。
- 弃牌动画。
- 进化动画。
- 附能动画。
- 攻击震动。
- 伤害数字。
- 击倒淡出。
- 状态标记。
- 硬币动画。
- 等待对手动画。
- 音效系统。

产出：

- Godot 表现层达到或超过当前 Pygame 版本。

建议耗时：

- 2 到 4 周。

验收：

- 常见动作有清晰反馈。
- 动画不阻塞规则状态。
- 远程状态更新不重复播放关键动画。

### 阶段 5：联机迁移

目标：

- Godot 支持 LAN / Relay 联机。

任务：

- 连接现有 relay。
- 支持房间创建和加入。
- 支持 host/client 座位。
- 支持隐藏信息状态。
- 支持 pending action 跨客户端选择。
- 支持断线、心跳、过期消息。

产出：

- Godot 远程联机版。

建议耗时：

- 2 到 4 周。

验收：

- 两台客户端可以完整对局。
- 对手手牌隐藏。
- 行动权限正确。
- 断线后 UI 正确提示。

### 阶段 6：AI 和训练 UI

目标：

- Godot 替代当前 Pygame AI 训练界面。

任务：

- AI 对战入口。
- 训练配置界面。
- 启动 Python 脚本。
- 显示训练进度。
- 显示 benchmark。
- 支持取消训练。

产出：

- Godot AI / 训练功能入口。

建议耗时：

- 2 到 3 周。

验收：

- Challenge AI 可对战。
- Deep AI 可加载模型。
- 训练进度可显示。
- 取消训练能正确终止进程。

## 13. 工作量预估

### 13.1 混合架构版本

| 阶段 | 估算 |
|---|---:|
| 协议和服务准备 | 1 到 2 周 |
| 静态棋盘原型 | 1 到 2 周 |
| 本地基础交互 | 2 周 |
| 完整规则交互 | 3 到 5 周 |
| 动画和音效 | 2 到 4 周 |
| 联机 | 2 到 4 周 |
| AI / 训练 UI | 2 到 3 周 |

合计：

- 最小可玩版本：4 到 6 周。
- 功能较完整版本：8 到 12 周。
- 完整替代当前 Pygame 客户端：12 到 18 周。

### 13.2 全量 Godot 原生重写版本

如果把规则、效果、AI、联机都迁入 Godot：

- 规则引擎：6 到 10 周。
- 效果 DSL：4 到 8 周。
- 卡牌数据 Resource 化：2 到 4 周。
- 联机状态一致性：4 到 6 周。
- AI 重写或桥接：4 到 12 周。
- 测试体系重建：4 到 8 周。

合计：

- 约 3 到 6 个月，且回归风险明显更高。

## 14. 风险分析

### 14.1 规则一致性风险

风险：

- Godot 端如果尝试预测规则，可能与 Python 状态不一致。

应对：

- Godot 不做权威状态修改。
- 所有动作交给 Python。
- Godot 只显示 Python 返回的状态。

### 14.2 Pending Action 回调风险

风险：

- Python callback 无法序列化。
- 多段选择可能中断。
- 取消操作可能导致卡牌没有回到正确区域。

应对：

- 使用 `request_id -> callback` 存储。
- 协议中明确每类 request 的 response 格式。
- 为每类 pending action 写集成测试。

### 14.3 隐藏信息风险

风险：

- 联机时手牌、牌库、奖品卡泄漏。

应对：

- 继续使用 `serialize_game_state(state, for_player_idx)` 的隐藏信息策略。
- Godot 只接收当前玩家视角的状态。
- 不向客户端发送对手手牌真实 card_id。

### 14.4 双状态风险

风险：

- Godot 本地维护一份状态，Python 也维护一份状态，产生分歧。

应对：

- Godot 状态只作为展示缓存。
- 每次 `state_update` 覆盖 Godot 状态。
- 动画使用 diff，不用于修改业务状态。

### 14.5 数据双写风险

风险：

- Python 卡牌模板和 Godot Resource 数据不一致。

应对：

- 第一阶段只允许 Python 数据为源。
- Godot 数据由脚本导出。
- 不手写 Godot 卡牌数据。

### 14.6 AI 训练进程风险

风险：

- Godot 启动 Python 训练后，进程未正确终止。
- CUDA 环境不可用。
- 训练日志格式不稳定。

应对：

- 训练脚本输出结构化 progress JSON。
- Godot 提供取消按钮。
- Python 训练进程支持优雅终止。
- UI 显示 CPU/CUDA 可用状态。

### 14.7 发布平台风险

风险：

- 桌面版可以启动 Python 服务。
- Web 版不能启动本地 Python。
- 移动端也不适合依赖外部 Python。

应对：

- 第一阶段目标锁定桌面版。
- 如果后续要 Web/移动版，需要服务器托管 Python 引擎，客户端只连远程服务。

## 15. 测试和验收方案

### 15.1 Python 规则测试保留

继续运行：

```bash
python -B -m unittest discover -q
```

重点保留：

- 规则测试。
- 联机测试。
- AI 测试。
- 状态序列化测试。

### 15.2 新增协议测试

建议新增：

- `test_engine_service_start_game`
- `test_engine_service_action_roundtrip`
- `test_pending_action_register_resolve`
- `test_choice_response_search_deck`
- `test_choice_response_coin_flip`
- `test_hidden_info_for_each_player`
- `test_invalid_action_returns_error`

### 15.3 Godot 客户端测试

Godot 侧建议做以下测试：

- 卡牌数据加载测试。
- 状态 JSON 渲染测试。
- BoardScene 截图测试。
- 点击动作映射测试。
- pending action UI 测试。
- 网络连接测试。

### 15.4 回归验收用例

最低验收：

- 本地对战可以完整开始。
- 双方完成 setup。
- 放置基础宝可梦。
- 附着能量。
- 进化。
- 使用物品。
- 使用支援者。
- 搜索牌库。
- 宣告攻击。
- 击倒后拿奖品卡。
- 主动晋升备战宝可梦。
- 结束游戏。

完整验收：

- 8 套预组卡组主要效果全部可用。
- AI 对战可用。
- LAN 联机可用。
- Relay 联机可用。
- 卡图管理可用或有替代流程。
- 训练 UI 可用。

## 16. 是否迁移规则到 Godot 原生

### 16.1 第一阶段不建议

原因：

- 当前规则已经可运行。
- 效果系统复杂。
- AI 和训练依赖 Python。
- Godot 原生规则重写不会立刻改善用户体验。

### 16.2 后续可选路线

如果后续要完全 Godot 原生化，可以按以下顺序迁移：

1. `data/card_models.py` -> Godot Resource / GDScript class。
2. `PlayerState` / `PokemonInPlay` -> GDScript。
3. `GameState` -> GDScript。
4. `rules_validator.py` -> GDScript。
5. `TurnManager` -> GDScript。
6. `ActionResolver` -> GDScript。
7. `effects/*` 和 `commands/*` -> GDScript DSL interpreter。
8. AI 保持远程服务或单独迁移。

### 16.3 GDScript vs C#

GDScript 优点：

- 和 Godot 集成最好。
- UI 和 Scene 操作最自然。
- 适合快速迭代。
- 更适合未来 Web 导出。

C# 优点：

- 类型系统更强。
- 更适合复杂规则引擎。
- 更接近 Python dataclass 重写后的强类型模型。

建议：

- UI 用 GDScript。
- 如果未来重写规则，可评估 C#。
- 但第一阶段不要把语言选择变成迁移阻塞点。

## 17. 推荐里程碑

### M1：协议和导出完成

交付：

- Python engine service。
- 卡牌 JSON 导出。
- 协议测试。

完成标准：

- 不启动 Pygame 也能创建游戏并执行动作。

### M2：Godot 静态棋盘

交付：

- Godot 项目。
- BoardScene。
- CardView。
- 状态渲染。

完成标准：

- 可以展示一局游戏状态。

### M3：Godot 本地最小可玩

交付：

- setup。
- 放置基础宝可梦。
- 附能。
- 结束回合。
- 状态刷新。

完成标准：

- 可以跑多个回合。

### M4：Godot 本地完整可玩

交付：

- 完整动作。
- pending action。
- 攻击。
- 胜负。

完成标准：

- 8 套预组卡组能进行主要对战流程。

### M5：Godot 联机可玩

交付：

- LAN。
- Relay。
- 隐藏信息。
- 远程 pending action。

完成标准：

- 两个 Godot 客户端可完整对局。

### M6：替代 Pygame 客户端

交付：

- 动画。
- 音效。
- AI。
- 训练 UI。
- 卡图管理或替代流程。

完成标准：

- 新 Godot 客户端可以作为主客户端使用。

## 18. 不推荐方案

### 18.1 不推荐直接逐行翻译 Pygame UI

原因：

- `GameScreen` 太厚。
- Pygame 的坐标和绘制模型与 Godot Scene 模型不同。
- 逐行翻译会保留旧架构缺点。
- Godot 的优势无法发挥。

应该按组件重构：

- `CardView`
- `ZoneView`
- `ActionPanel`
- `ChoiceOverlay`
- `BoardScene`

### 18.2 不推荐第一阶段重写 AI

原因：

- AI 代码量大。
- PyTorch 训练不适合迁入 Godot。
- 对迁移核心目标帮助有限。

### 18.3 不推荐一开始改联机模型

原因：

- 现有 WebSocket/JSON 已经可用。
- 回合制游戏不需要复杂同步系统。
- 高层 multiplayer 会引入新概念和新风险。

## 19. 参考资料

Godot 官方文档和资料：

- Godot Nodes and Scenes：<https://docs.godotengine.org/en/stable/getting_started/step_by_step/nodes_and_scenes.html>
- Godot Resources：<https://docs.godotengine.org/en/stable/tutorials/scripting/resources.html>
- Godot WebSocketPeer：<https://docs.godotengine.org/en/stable/classes/class_websocketpeer.html>
- Godot JSON：<https://docs.godotengine.org/en/stable/classes/class_json.html>
- Godot scripting languages：<https://docs.godotengine.org/en/stable/tutorials/scripting/other_languages.html>
- Godot 4.6.3 maintenance release：<https://godotengine.org/article/maintenance-release-godot-4-6-3/>

当前项目关键文件：

- `main.py`
- `ui/game_app.py`
- `ui/screens/game_screen.py`
- `ui/screens/game_screen_network.py`
- `ui/components/board_renderer.py`
- `engine/game_state.py`
- `engine/player_state.py`
- `engine/turn_manager.py`
- `engine/action_resolver.py`
- `engine/effects/`
- `engine/commands/`
- `network/network_manager.py`
- `network/state_serializer.py`
- `network/message_protocol.py`
- `data/card_models.py`
- `data/card_registry.py`
- `data/deck_definitions.py`
- `card_data/templates/`
- `card_data/effects/`

## 20. 最终建议

本项目迁移到 Godot 是合理的，但应把迁移目标定义为：

先迁移客户端体验，不急于迁移规则内核。

推荐落地路线：

1. 保留 Python 规则引擎、AI、训练和测试。
2. 新增 Python engine service，提供 WebSocket/JSON 接口。
3. 新建 Godot 客户端，先完成状态渲染。
4. 再逐步接入动作、pending action、动画和联机。
5. 通过现有 unittest 和新增协议测试保护规则一致性。
6. 等 Godot 客户端稳定后，再评估是否迁移规则到 Godot 原生。

这样可以最大化利用现有代码资产，同时让 Godot 负责它最擅长的部分：界面、动画、资源、输入和跨平台客户端体验。

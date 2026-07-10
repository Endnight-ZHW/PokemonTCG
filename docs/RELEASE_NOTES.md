# PokemonTCG Godot 0.3.2

Godot 4.7 是唯一发布客户端，支持本地双人、Challenge/Deep AI、ENet LAN 和
WebSocket Relay。Python 仅用于本地调试、规则验证、训练评估以及数据和卡图导入。

## 本轮工程加固

- 发布信息统一到根目录 `release_manifest.json`：Godot/Android 版本、协议、规则、
  action、encoder、checkpoint、RNG schema，以及 10 套牌组和 10 个模型不再分散硬编码。
- Python 规则入口 fail-closed：非法 actor、pending 期间动作、伪造 choice、回调异常、
  KO/晋升与攻击收尾均受统一事务保护，失败会恢复状态、RNG、日志和事件。
- 新增与 Godot 一致的 xorshift32 portable RNG；旧 MT RNG 仅用于历史训练恢复。
- ONNX 发布验证增加 PT 实际加载、文件哈希、内嵌 metadata/sidecar 一致性、全空
  attention mask 以及 NaN/Inf 检查，并以 staging 事务一次性提升 10 个模型。
- Godot 网络控制器使用 `CONNECTING → LOBBY → PLAYING → CLOSED` 生命周期，
  收紧 payload/状态边界、发送 sequence 和 Relay 房间并发处理。
- LAN 与 Relay 明确允许双方选择相同牌组；双方状态、牌库洗牌和隐藏信息仍相互隔离。
- reduced-motion 与画质设置会立即作用于标题、胜利演出和牌桌表现层。

## 发布合同

- Godot 4.7.stable，Android versionCode 5。
- Godot protocol/rules/action schema v3。
- Python 当前已发布模型仍绑定 rules/action schema v2；规则 v3 迁移必须先完成每牌组
  600 局配对重评，不能仅修改 metadata 冒充通过。
- Checkpoint v10、encoder v3、planner v1、portable RNG v1。
- 10 套发布牌组：fire、water、psychic、lightning、fighting、colorless、dragon、
  grass、steel、darkness。

## 已知边界

- 不支持 Python 客户端联机或 Python 可执行发布包。
- 不支持旧 protocol v2 客户端、房主迁移、公网竞技反作弊和模型量化。
- Android 正式商店签名与目标真机矩阵仍需在发布环境中执行。

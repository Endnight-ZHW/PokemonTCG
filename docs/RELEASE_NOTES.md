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
- Python 旧 v2 客户端、Lobby 和网络 UI 分支已物理删除；本地 Pygame 通过
  `DebugMatchSession` 调试，并可选择 manifest 中全部 10 套牌组。
- Pending continuation 已可序列化，JSON snapshot、AI clone 和事务回滚不再依赖
  不可恢复的内存 callback；未知 continuation 会安全拒绝。
- Python→Godot fixture v3 覆盖全部 9 个公开动作，并用 coverage manifest 对新增
  effect/VM op fail-closed；当前为 23 个场景、30 个事务、16/77 effect 与 16/80 op，
  未覆盖项及 coin 语义差异均显式记录。
- GPU `DL` 环境固定为 Python 3.11.15、NumPy 1.26.4、Torch 2.4.1+cu118，新增
  全依赖锁和 10 模型 CUDA load+infer 验收脚本。
- Snapshot、事务、AI clone 与 golden exporter 统一从 versioned canonical state 产生；
  Pygame 输入路由、Deep AI 评估统计及 Godot 牌桌布局已拆为独立可测试模块。
- `CardCatalog.shared()` 成为发布运行时的单一深只读仓库；全部派生缓存预热冻结，
  UI、引擎、AI 和网络会话支持显式注入，并通过多线程只读合同。
- Relay v3 控制握手限制为 1 KiB、同来源 60 次/秒；并发建房、客位竞争、超大帧和
  跨连接限流均有定向回归。
- PT、sidecar、ONNX 与 runtime manifest 使用持久 journal/backup 的统一提升事务；
  中断可恢复，真正 commit 前强制 Windows 导出推理与原生 ARM64 设备推理。
- Android 发布与专用 smoke APK 会逐哈希比较 17 个原生/模型/manifest 输入；
  x86 模拟器的 ARM 转译不会计为 ARM64 通过。Nightly 已覆盖完整标准回归、原生重建、
  Windows/Android 构建、打包与发布校验。

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
- 本轮不重新训练或改写模型权重；Python 模型 schema 保持 v2。当前本机只有 x86_64
  转译模拟器，因此原生 ARM64 的严格门禁已实现，但仍需连接合格设备实际执行。

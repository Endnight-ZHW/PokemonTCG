# PokemonTCG Godot 0.3.2

## Deep AI v10/v3 更新

- Deep AI checkpoint 升级到 v10、encoder 升级到 v3，统一 53 维卡牌语义特征。
- 10 套发布牌组均使用同牌组、同对手、同 seed、同先后手的 600 局 Challenge
  配对基线；强度与长局可靠性均按配对门禁验证。
- Python 与 Godot 统一使用 guarded neural prior、heuristic leaf value、MCTS64 和
  2 秒单次决策 watchdog。
- ONNX 导出会在写文件前预检完整 10 模型的 v10/v3 schema、accepted/verified
  metadata，并验证 FP32 推理误差不超过 `1e-4`。
- 原生 ONNX bridge 支持 choice-head capability；发布测试禁止跳过 Deep runtime
  用例，旧 encoder manifest 会继续安全回退到 Challenge AI。

## 系统要求

- Windows 10/11 x86_64。
- Android 9 或更高版本，仅支持 ARM64，固定横屏。
- Challenge AI 与 Deep AI 可完全离线运行。
- LAN 使用 ENet；Relay 支持 `ws://` 与 `wss://`，协议版本为 v3。

## 已实现

- 本地双人、Challenge AI、Deep AI。
- 10 套发布牌组与 10 个 FP32 ONNX 模型。
- Windows/Android 原生 ONNX Runtime CPU 推理。
- ENet LAN 与 WebSocket Relay 房主权威联机。
- 现代实体牌桌战斗界面，完整显示卡图、战斗区、备战区、牌库、弃牌区、奖品区、竞技场和手牌。
- 点击操作、长按详情与可选拖拽上场/附能；复杂选择使用卡图网格。
- 抽牌、上场、附能、进化、攻击、伤害、治疗、状态、击倒、奖品和回合切换演出。
- Master、Music、SFX、UI 分层音频，以及电影化、标准、快速、减少动画四种节奏。
- 自动、高、中、低画质档；Windows 目标 60 FPS，Android 低档目标 30 FPS。
- 音量、静音、演出节奏、画质和卡图缓存设置。
- Android 后台时取消 AI 搜索；联机对局会安全断开并在恢复时提示。

## 0.3.2 修复

- 加强联机协议 payload 校验，畸形动作、选择和局面同步消息会被拒绝或触发重同步，不再进入规则/UI 反序列化路径。
- 联机客户端增加 state view、选择请求和表现事件的最小 schema 过滤。
- Toast 提示动画增加旧 Tween 清理，避免连续提示时旧回调隐藏新消息。
- Deep AI manifest 和战斗表现事件增加类型防护，损坏资源或异常事件会优雅降级。
- Android `versionCode` 升至 5，Windows/Android 发布脚本同步为 `0.3.2`。

## 0.3.1 修复

- 修复 Android 程序化背景音乐第一次循环结束时可能在 `AudioTrack` 线程触发 SIGSEGV 的问题。
- Android 自动画质默认使用有界 Low/30 FPS 档，并限制卡图缓存、粒子和同时飞行卡牌数量。
- 卡牌数据目录改为战斗场景共享，不再在每张宝可梦刷新时重复解析 JSON。
- 右侧默认只保留阶段推进；使用训练家、攻击、特性、撤退、晋升和竞技场操作显示在对应卡牌上。
- 重排双方牌区并扩大牌库、弃牌、奖品和竞技场区域。
- 抽牌和弃牌改为多卡错峰贝塞尔弧线，增加卡牌阴影、旋转、落点反馈和对应音效。

## 已知限制

- 不支持旧 Pygame 协议 v2 客户端。
- 首版不支持房主迁移；房主断线会结束对局。
- 短时重连仅具备重新同步基础，不承诺断开后的房间保留。
- 当前 Android 包内置全部模型，安装包体积较大。
- Android 自动画质分档的 60/30 FPS 目标仍需按真机清单在主流与中低端设备上验收。
- 使用 `test` 签名生成的 APK 仅供设备验收，不能作为商店正式发布包。

## 完整性

发布目录中的 `SHA256SUMS.json` 记录 Windows ZIP、Android APK、PCK、原生库和 10 个 ONNX 模型的 SHA-256。

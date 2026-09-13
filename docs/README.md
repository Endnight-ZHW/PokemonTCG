# 项目文档

- [`MAIN_REVIEW.md`](MAIN_REVIEW.md)：三维重构提交前审核、生命周期修复与最新图形性能复测。
- [`CODE_CLEANUP.md`](CODE_CLEANUP.md)：三维迁移后的无用代码清理、公共校验去重与回归记录。
- [`BATTLE_3D_REFACTOR.md`](BATTLE_3D_REFACTOR.md)：三维牌桌、卡牌、投影输入、表现生命周期与双平台验证。
- [`BATTLE_3D_LOCALIZATION_AND_MULLIGAN_REVEAL.md`](BATTLE_3D_LOCALIZATION_AND_MULLIGAN_REVEAL.md)：操作提示中文化与对手再战手牌放大展示。
- [`BATTLE_3D_SHUFFLE_AND_ACTIONS.md`](BATTLE_3D_SHUFFLE_AND_ACTIONS.md)：卡组区内快速插洗与固定在手牌上方的使用按钮。
- [`BATTLE_3D_CARD_TRANSFERS.md`](BATTLE_3D_CARD_TRANSFERS.md)：检索入手、附能和能量转移的三维落点及接触时序修正。
- [`BATTLE_3D_SEARCH_AND_MULLIGAN.md`](BATTLE_3D_SEARCH_AND_MULLIGAN.md)：手牌放大、检索展示与开局再战手牌一致性修正。
- [`BATTLE_3D_DRAG_AND_RENDER_SYNC.md`](BATTLE_3D_DRAG_AND_RENDER_SYNC.md)：拖拽倾角、中央闪卡的实际渲染修复及最新验收记录。

- [`PROJECT_AUDIT.md`](PROJECT_AUDIT.md)：本轮职责拆分、去重、性能测量与回归证据。
- [`RELEASE_NOTES.md`](RELEASE_NOTES.md)：0.8.0 当前发布边界与验证结果。
- [`TRADITIONAL_AI_STRENGTH_REFACTOR.md`](TRADITIONAL_AI_STRENGTH_REFACTOR.md)：传统 AI 棋力重构、独立验收与收尾证据。
- [`RULES.md`](RULES.md)：游戏规则说明。
- [`GODOT_DEVELOPMENT_GUIDE.md`](GODOT_DEVELOPMENT_GUIDE.md)：Godot 4.7 场景、UI、内容、规则、AI、联机与发布实操。
- [`../deploy/relay/README.md`](../deploy/relay/README.md)：独立 C++ Relay 部署边界。
- [`../research/deep_ai/README.md`](../research/deep_ai/README.md)：独立 Deep AI Python 研究项目。

产品代码区域为 `native/ptcg_core`、`native/challenge_core`、
`native/relay_server` 和 `godot`；唯一作者源在 `godot/authoring`。产品业务不含 Python，
SCons 构建解释器和 `research/deep_ai` 不属于产品运行时。发布清单的唯一来源是
[`../godot/data/release_manifest.json`](../godot/data/release_manifest.json)。

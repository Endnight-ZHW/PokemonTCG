# 项目文档

- [`RELEASE_NOTES.md`](RELEASE_NOTES.md)：Godot 发布说明。
- [`RULES.md`](RULES.md)：游戏规则说明。
- [`GODOT_DEVELOPMENT_GUIDE.md`](GODOT_DEVELOPMENT_GUIDE.md)：面向新手的 Godot 4.7 场景、UI、动画、规则、AI、联机与发布实操手册。
- [`NATIVE_RULES_CORE_MIGRATION.md`](NATIVE_RULES_CORE_MIGRATION.md)：Native ABI 2 单一 C++ 规则核心、绑定、作者工具与切换证据。
- [`deep_ai_alphazero_v3.md`](deep_ai_alphazero_v3.md)：当前整局原生 actor、流式 replay、持续 learner 和运行时 v3 合约。

当前代码布局：

- `../godot/`：Godot 发布客户端。
- `../python/`：卡牌 DSL、原生规则绑定、AI 训练评估和数据/卡图导入；不发布客户端。
- `../tools/`：共享构建与验证脚本。
- `../release_manifest.json`：版本、schema、发布牌组与模型集合的唯一清单。

# 项目文档

- [`RELEASE_NOTES.md`](RELEASE_NOTES.md)：Godot 发布说明。
- [`RULES.md`](RULES.md)：游戏规则说明。
- [`GODOT_DEVELOPMENT_GUIDE.md`](GODOT_DEVELOPMENT_GUIDE.md)：面向新手的 Godot 4.7 场景、UI、动画、规则、AI、联机与发布实操手册。
- [`deep_ai_alphazero_v2.md`](deep_ai_alphazero_v2.md)：当前信息集 AlphaZero v2 架构、训练与发布门禁。

当前代码布局：

- `../godot/`：Godot 发布客户端。
- `../python/`：Pygame 本地调试、规则对照、AI 训练评估和数据/卡图导入；不发布、不提供客户端联机。
- `../tools/`：共享构建与验证脚本。
- `../release_manifest.json`：版本、schema、发布牌组与模型集合的唯一清单。

# 项目文档

- [`RELEASE_NOTES.md`](RELEASE_NOTES.md)：0.8.0 当前发布边界与验证结果。
- [`RULES.md`](RULES.md)：游戏规则说明。
- [`GODOT_DEVELOPMENT_GUIDE.md`](GODOT_DEVELOPMENT_GUIDE.md)：Godot 4.7 场景、UI、内容、规则、AI、联机与发布实操。
- [`../deploy/relay/README.md`](../deploy/relay/README.md)：独立 C++ Relay 部署边界。
- [`../research/deep_ai/README.md`](../research/deep_ai/README.md)：独立 Deep AI Python 研究项目。

产品代码区域为 `native/ptcg_core`、`native/challenge_core`、
`native/relay_server` 和 `godot`；唯一作者源在 `godot/authoring`。产品业务不含 Python，
SCons 构建解释器和 `research/deep_ai` 不属于产品运行时。发布清单的唯一来源是
[`../godot/data/release_manifest.json`](../godot/data/release_manifest.json)。

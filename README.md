# PokemonTCG

基于 Godot 4.7 的宝可梦卡牌对战游戏，当前版本为 0.7.0。产品支持本地双人、
Challenge AI、ENet LAN 与 WebSocket Relay；协议与存档边界保持 Action 4、
ChoiceView 2、Protocol 6、Snapshot 3、Journal 1 和 RNG 2。

![Godot 4.7 开始界面](docs/images/godot-guide/title-midnight-arena.png)

## 代码边界

- `native/ptcg_core`：无 Godot/Python 依赖的权威规则核心。
- `native/challenge_core`：唯一的产品 AI 策略与 `ChallengeController`。
- `godot/native/bindings`：只负责 Godot 类型转换和类注册。
- `godot`：发布客户端、UI、网络与唯一卡图资源。
- `python`：卡牌作者工具、数据导出与 Relay 服务。
- `research/deep_ai`：显式运行的独立研究项目，不进入产品构建、发布包或常规 CI。

版本、Android versionCode、发布牌组和 schema 的唯一清单是
[`godot/data/release_manifest.json`](godot/data/release_manifest.json)。

## 开发与验证

```powershell
.\tools\setup_godot_toolchain.ps1
.\tools\setup_native_ai_deps.ps1
.\tools\test_fast.ps1
.\tools\test_standard.ps1
.\tools\test_godot_ai.ps1
```

打开编辑器：

```powershell
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --editor --path .\godot
```

构建 Windows/Android 与发布包：

```powershell
.\tools\setup_android_toolchain.ps1
.\tools\build_native_ai.ps1 -Target all -Configuration all
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\package_release.ps1 -AndroidSigning test
.\tools\test_release.ps1
```

卡牌数据检查与 Relay：

```powershell
python -m pip install -r .\python\requirements.txt
python -B .\python\scripts\card_author.py lint
python -B .\python\scripts\export_godot_data.py --check
python -B .\python\relay_server.py --host 0.0.0.0 --port 8766
```

Deep AI 研究说明见 [`research/deep_ai/README.md`](research/deep_ai/README.md)，
手动验证入口为 `research/deep_ai/tools/test_research_smoke.ps1`。

更多资料：[`docs/README.md`](docs/README.md)、
[`docs/GODOT_DEVELOPMENT_GUIDE.md`](docs/GODOT_DEVELOPMENT_GUIDE.md)、
[`docs/RULES.md`](docs/RULES.md)。

卡牌名称、规则和图片仅供学习交流。

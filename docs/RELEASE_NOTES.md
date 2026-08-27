# PokemonTCG Godot 0.7.0

0.7.0 保持本地双人、Challenge、LAN、Relay Protocol 6、Action 4、
ChoiceView 2、Snapshot 3、Journal 1 与 RNG 2 的玩家可见行为不变，同时收紧产品边界。

## 运行时

- `native/ptcg_core` 是唯一权威规则核心，Godot 通过 `NativeRulesSession` 调用。
- `native/challenge_core/ChallengeController` 是唯一 Challenge 策略实现；Godot 与研究教师
  共用它，绑定公开接口仅为 `configure`、`decide`、`cancel`、`reset_match` 和
  `get_contract`。
- 产品扩展不含 Python、pybind、Torch 或 ONNX 依赖；Windows 与 Android 只携带规则和
  Challenge 原生库。
- Deep AI 已隔离为 `research/deep_ai` 手动研究项目，不显示产品模式，不参与默认构建、
  发布清单、常规 CI 或发布包。

## 数据与界面

- 137 张卡的印刷数据与效果规则合并到 `python/card_data/cards`；导出 CLI 保持
  `export_godot_data.py --check`。
- 卡图唯一来源为 `godot/assets/cards/<card-id>.webp`，映射与 SHA-256 按文件名生成。
- 发布清单唯一来源为 `godot/data/release_manifest.json`，版本仍为 0.7.0，Android
  versionCode 仍为 8。
- `Main` 将规则/对局流与 Choice 流委托给具体控制器；`BattleTable` 将渲染、交互、
  演出状态和卡牌运动拆为独立组件，公开信号与视觉效果保持不变。

## 验证

- 109 个 Challenge 战术夹具在无 Godot 的 C++ 测试中通过。
- 10 套牌固定种子实战的动作数、选择数、回合数和胜者与重构前一致；最近一次完整运行
  约 10.8 秒、峰值约 35 MB。
- Python 作者工具、Godot 原生规则、7 种前台尺寸/安全区、战斗演出、Workbench、LAN
  与 Relay 合约通过。
- 发布检查明确拒绝 `.onnx`、ONNX Runtime、Deep 脚本与 `research/` 内容。

发布前执行：

```powershell
.\tools\test_fast.ps1
.\tools\test_standard.ps1
.\tools\test_godot_ai.ps1
.\tools\package_release.ps1 -AndroidSigning test
.\tools\test_release.ps1
```

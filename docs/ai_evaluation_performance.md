# Challenge AI Evaluation Performance

本文档记录 Challenge AI 评测的高成本性能优化方向。目标是不降低 AI 强度、不减少局数、不改 Deep AI、不把当前规则模拟改写成 GPU 版本。

## 已落地的低风险优化

- `NativeChallengeAI` 默认复用 `CardCatalog` 和 `GameEngine`，避免每次决策重新读取卡表、牌组和构建规则引擎对象。
- `CardCatalog.expand_deck()` 缓存已展开的 60 张牌列表，返回副本以避免调用方修改缓存内容。
- `ai_evaluation_runner.gd` 缓存每个 strategy/deck 的有效参数，返回副本以保持调用方不可污染缓存。
- `ChallengeAIMath` GDExtension 已接入局面评估的纯数值聚合；GDScript 仍负责从真实状态和卡表抽取特征，原生端不复制规则。
- `tools/evaluate_godot_ai.ps1 -Profile` 会让 schema v3 JSON 产出 `performance_profile`。
- HTML 报告会显示 `性能 Profile` 和 `Profile 计数`。
- `tools/evaluate_godot_ai.ps1 -DynamicAIBudget` 会在未显式传入策略文件时生成 opt-in 动态预算 strongest 策略，用于缩短评测吞吐时间。
- `python/scripts/summarize_ai_evaluation_profile.py` 用于输出耗时榜和 C++/GDExtension 候选方向。
- `python/scripts/compare_ai_evaluation_profiles.py` 用于对比两个结果文件，验证 match 结果等价并输出耗时比例。
- `tools/evaluate_godot_ai.ps1 -DisableAICache` 仅用于 benchmark，对照旧的每次决策新建 catalog/engine 行为。
- `tools/evaluate_godot_ai.ps1 -DisableNativeMath` 仅用于 benchmark，对照 GDScript 局面评估聚合。

## 原生构建

Windows 本地验证至少需要 debug 扩展；发布包需要 release 扩展。

```powershell
.\tools\build_native_ai.ps1 -Target windows -Configuration debug
.\tools\build_native_ai.ps1 -Target windows -Configuration release
```

## 本机 Profile

```powershell
.\tools\evaluate_godot_ai.ps1 -EvalPreset Smoke -Profile -OutputDir .test_tmp\ai_eval\profile-smoke -SkipValidate
python python\scripts\summarize_ai_evaluation_profile.py --input .test_tmp\ai_eval\profile-smoke\results.json --top 12
```

Nightly profile 会更接近真实热点，但会增加计时开销。需要 profile 时建议单独跑，不要把它作为 strength gate 的唯一依据。

```powershell
.\tools\evaluate_godot_ai.ps1 -EvalPreset Nightly -MatchupMode Balanced -CrossSeedBlocksPerMatchup 10 -Workers 8 -Profile -ValidateGate auto
```

## 动态思考预算

动态预算是评测吞吐优化，默认关闭，不会自动影响玩家对局或显式 strategy JSON。它保留 strongest 的 `simulation_budget` 上限、`max_depth`、UCB 公式、启发式分数和 RNG seed，只允许 Challenge AI 在根动作明显稳定时提前停止。

```powershell
.\tools\evaluate_godot_ai.ps1 -EvalPreset Nightly -Workers 8 -DynamicAIBudget -Profile -ValidateGate equivalence
```

显式传入 `-StrategyA` 或 `-StrategyB` 时，脚本不会注入动态预算；需要在策略 JSON 里自行写入 `dynamic_budget`。结果 JSON 会记录 `budget_stop_reason` 聚合后的 `dynamic_budget_stop_reasons`、`dynamic_budget_stop_rate`，profile 会记录 `ai_dynamic_budget_checks`、`ai_dynamic_budget_confidence_stops`、`ai_dynamic_budget_single_action_stops` 和 `ai_dynamic_budget_budget_exhausted`。

动态预算不要求固定 seed 决策完全等价。验收使用统计等价 gate：

```powershell
python python\scripts\validate_ai_evaluation.py --input .test_tmp\ai_eval\nightly-dynamic\results.json --gate nightly-equivalence
```

该 gate 要求无 invalid action、choice failure、rule exception、golden failure，`time_capped_decision_rate == 0`，按策略诊断计数中候选 A 不比基线 B 更多，并要求 paired delta CI 下界不低于 `-0.02`、每 deck 不低于 `-0.04`、每 matchup 不低于 `-0.08`。如果 gate 失败，只把动态预算作为 opt-in profile 工具保留，不推荐用于全量强度评测。

## A/B Benchmark

使用固定 seed 对比缓存开关。`-DisableAICache` 是 benchmark 开关，不建议用于日常评测。

```powershell
.\tools\evaluate_godot_ai.ps1 -EvalPreset Smoke -Profile -DisableAICache -OutputDir .test_tmp\ai_eval\cache-off -SkipValidate
.\tools\evaluate_godot_ai.ps1 -EvalPreset Smoke -Profile -OutputDir .test_tmp\ai_eval\cache-on -SkipValidate
python python\scripts\compare_ai_evaluation_profiles.py --baseline .test_tmp\ai_eval\cache-off\results.json --candidate .test_tmp\ai_eval\cache-on\results.json
```

一次本机 smoke 样例结果：

- match 结果等价：`same_match_results=true`
- 总耗时比例：`cache-on / cache-off = 0.3897`
- `ai_request_context_ms` 比例：`0.0179`
- `runner_decide_action_wall_ms` 比例：`0.3602`

Smoke 样本小，比例会受机器负载影响；它证明优化方向有效，最终收益应以 Quick/Nightly profile 为准。

原生 math 对照：

```powershell
.\tools\evaluate_godot_ai.ps1 -EvalPreset Smoke -Profile -DisableNativeMath -OutputDir .test_tmp\ai_eval\native-off -SkipValidate
.\tools\evaluate_godot_ai.ps1 -EvalPreset Smoke -Profile -OutputDir .test_tmp\ai_eval\native-on -SkipValidate
python python\scripts\compare_ai_evaluation_profiles.py --baseline .test_tmp\ai_eval\native-off\results.json --candidate .test_tmp\ai_eval\native-on\results.json
```

一次本机 smoke 样例结果：

- match 结果等价：`same_match_results=true`
- 总耗时比例：`native-on / native-off = 0.9987`
- `runner_decide_action_wall_ms` 比例：`0.9966`
- `ai_simulate_total_ms` 比例：`0.9893`

这说明当前 C++ 候选的边界和验证方式成立，但它不是主要收益来源。下一步原生迁移应优先考虑 profile 更热的 `apply_action`、`legal_actions` 或启发式评分，但这些模块规则边界更复杂，必须先建立更强的等价性测试。

## 分布式 Profile

每台机器跑一个 shard：

```powershell
.\tools\evaluate_godot_ai.ps1 -EvalPreset Nightly -Workers 8 -ShardIndex 0 -ShardCount 4 -ShardOnly -Profile -OutputDir .test_tmp\ai_eval\nightly-shard-0
.\tools\evaluate_godot_ai.ps1 -EvalPreset Nightly -Workers 8 -ShardIndex 1 -ShardCount 4 -ShardOnly -Profile -OutputDir .test_tmp\ai_eval\nightly-shard-1
```

合并后汇总 profile：

```powershell
.\tools\evaluate_godot_ai.ps1 -EvalPreset Nightly -MergeInput shard0\results.json,shard1\results.json,shard2\results.json,shard3\results.json -OutputDir .test_tmp\ai_eval\nightly-merged -ValidateGate auto
python python\scripts\summarize_ai_evaluation_profile.py --input .test_tmp\ai_eval\nightly-merged\results.json --top 20
```

## C++/GDExtension 候选

优先级必须以 `performance_profile` 为准。通常候选如下：

- `ai_rollout_apply_action_ms` / `runner_apply_action_ms`：规则执行、settlement、transaction 热路径。
- `ai_rollout_legal_actions_ms` / `runner_legal_actions_ms`：合法动作生成和 `VMActionAvailability`。
- `ai_rollout_heuristic_action_ms` / `ai_heuristic_priors_ms`：Challenge AI 启发式评分。
- `ai_determinize_ms` / `ai_request_context_ms`：`GameState.from_dict`、hidden information determinization、snapshot/clone。
- `ai_rollout_evaluate_ms`：终局前局面评估。
- 已实现候选：`ChallengeAIMath.evaluate_board_features()`，用于验证“GDScript 抽特征 + C++ 数值聚合”的迁移路径。

迁移到 C++/GDExtension 前必须满足：

- 规则边界清晰，输入输出可序列化或可直接用 Godot 对象验证。
- 有固定 seed smoke/golden 对齐测试，证明结果等价。
- 不复制一套会和 GDScript 规则分叉的业务规则。
- 先迁移纯计算或稳定 VM 辅助函数，再考虑 action settlement。

## GPU 边界

当前 Challenge AI 热点是规则模拟、状态克隆、合法动作生成、分支选择和启发式评分，不是大批量张量推理。GPU 加速只有在未来把规则模拟改造成可批量张量化、并且有严格等价验证的独立项目时才值得重新评估。

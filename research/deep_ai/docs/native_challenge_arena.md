# AI 棋力评价与 Native Challenge Arena

Challenge 与 Deep v3 共用 `EvaluationProtocol / EvaluationTask / GameEvidence / EvaluationReport`、
证据日志、置信序列及晋升状态机。正式结论来自共享评价层；原生执行器只负责对战。
AI 的策略评分与训练优化算法不在此次重构范围内。

## 默认比较与命令

A 为当前候选，C 为当前认可的冠军，H 为固定历史锚点。初始 C 是
`challenge_champion_v1`（提交 `736d2ce11d3413546e3b216b6fd428eb5261bd5c`），
H 是 `challenge_release_v1`（0.8.0，提交 `d4f20ee9775b7e8c80a1994e5c9aa5f1e11c9864`）。
日后使用 `-Baseline` 显式选择冠军，评价运行本身不改写产品 AI 或冠军规格。
候选默认采用游戏中的 `strategic_intent_v3`；H 保留冻结规格中的 `turn_beam_v2`。

在仓库根目录执行：

```powershell
# 火/水两套牌完整矩阵共 16 局，默认对照 H；仅诊断
.\research\deep_ai\tools\run_challenge_arena.ps1 -Preset smoke -Workers 4

# 400 局日常筛选；可用 -Replicates 3 扩到 1200 局
.\research\deep_ai\tools\run_challenge_arena.ps1 -Preset pr -Workers 8 -Output build\evaluation\screen

# 声明并冻结三个版本与完整赛程，暂不对战
.\research\deep_ai\tools\run_challenge_arena.ps1 -Preset release -DeclareOnly -Output build\evaluation\release

# 原目录续跑声明好的协议，最多每组 40000 局
.\research\deep_ai\tools\run_challenge_arena.ps1 -Preset release -Workers 8 -Output build\evaluation\release
```

PS 入口构建并验证当前 Agent、C 及 H；正式跨版本比较仍要求 Windows external process
后端。`implementation-only` 将 C 的策略固定成 A 的策略，隔离实现变化；H 始终保持冻结。
`same-binary-strategy` 只允许诊断/筛选，不能产生正式晋升。

| Preset | 默认工作量 | 结论 |
|---|---:|---|
| smoke | 16 局，缩小搜索预算 | 结构诊断 |
| pr | 400 局，最多 3 轮 | 日常筛选；不具有晋升权限 |
| nightly | 5–100 轮完整矩阵 | 相对 C 的非劣验证，界限为 48% |
| release | 每组 5–100 轮，三组最多 120000 局 | 总体提升及锚点保护 |
| calibration | 默认 20 轮相同 Agent，需 `-AllowSelfPlay` | 实际对战的零差异诊断 |

正式单局上限默认 1024 个决策；双方相同，不用截断结果估算输赢。
`-Replicates` 为上限，证据充足时提前停止。Python 和 PowerShell 命令使用同一组
preset，直接调用共享评价器。赛程、统计方法和晋升规则由协议决定，命令行不提供
自定义门禁、bootstrap 次数、截断容忍率或墙钟搜索截止参数。

## 公平性与证据

- 每轮十套牌形成 100 个有序对阵，共 400 局；镜像四局、非镜像八局。
  每个块覆盖两个座位、两种先后手及交换套牌方向。四条相同闭包不算四局配对。
- 同场景的闭包与 A–C、A–H、C–H 对照使用同一 seed；不同场景检测并消解碰撞。
  开发和正式验证有不同随机命名空间，每个新输出目录生成独立 cohort，续跑保留它。
- 协议冻结模型/二进制、策略、代码、规则、卡牌、计算设置和赛程的内容哈希。
  校验实际结果条件与任务集合，不能靠修改 `block_size`、赢家或任务编号补齐样本。
- 权威规则仍是原生 `RulesSession`，信息来自 `ai_observation_for(actor)`，保留
  public/owner/private 过滤。玩家显示名称不参与随机性。默认规则为
  `CN_MAINLAND_3_1_0`、`apply_type_matchups=false`，与现有游戏默认相同。
- 所有评测搜索 `time_budget_ms=0`、内部单 worker，按相同工作预算比较；进程间对局并行。
  engine、牌库检查、策略优化为明确记录的 treatment；实际工作预算必须相等。
- 只有正常终局计胜/和/负。崩溃、非法响应、规则失败、挂起、截断独立记录。
  首次 watchdog 超时在相同条件下用单 worker、全新双方进程重试一次；持续超时不判负。
  正式证据有缺口则不晋升，不能删除不利块后重新分配权重。

## 统计与晋升

主指标是有序套牌对等权的得分率（胜 1、和 0.5、负 0）。统计独立单元是
同种子的完整四/八局块。每个完整矩阵轮才允许更新结论，按协议次序处理结果。

共享实现使用 Howard 等人的经验 Bernstein 置信序列（Theorems 1, 4；
https://arxiv.org/abs/1810.08240），采用 `eta=2, m=1, h(k)=(k+1)(k+2)`。
每个指标的两个方向各分 alpha/2；预测只使用该套牌对先前的结果。
以 `z=.5+(w_h/w_max)*(x-.5)` 归一化固定权重，完整轮边界按
`theta=.5+H*w_max*(mean(z)-.5)` 反变换；差值先映射到 [0,1]。
各轮置信范围求交，使已经获得的证据不因继续观察而被静默丢弃。
全胜或观测方差为零也保留有限样本不确定性。

单候选错误预算为 5%：A–C 分 2.5%，锚点整体差值分 1.25%，十套牌共同分 1.25%。
这是同时及顺序校准的范围；不能将四/八局当成独立抛硬币再计算区间。
训练按预声明的总候选轮数进一步分配预算，恢复不重新获得 5%。
2–3 个百分点是检测能力目标，不是观测胜率的硬门槛。

晋升要求：

1. A–C 得分率区间下界 > 50%。
2. A–H 相对 C–H 的整体配对差值下界 > -2 个百分点。
3. 没有套牌的固定对手差值区间上界 < -5 个百分点。
4. 对局与证据可靠性通过。

第 3 项只否决已确认的明显退步。其余套牌分别报告“非劣已证实”或“证据不足”，
不声称每套牌都变强。先运行主比较，主比较证明提升后再补齐锚点对照。
到上限仍不能满足必要条件时返回 `inconclusive`，保留冠军。

报告区分 `strength.status`、`reliability`、`gate_status` 和 `promotion_passed`。
CLI 不能覆盖协议门禁，诊断通过不能触发晋升。退出码仍为
`pass=0 / fail=3 / inconclusive=4 / infrastructure_fail=5`。

## 运行效率与恢复

原生 worker 和 Agent 跨轮保留，每局重置比赛记忆；Deep 推理服务跨轮保留，使用
float32、固定形状推理批次及单个未完成搜索叶子，避免返回时序改变搜索决策。
Deep 推理期间启用确定性算法，结束后恢复原设置；训练探索配置不变。
缓存区分设备/精度/代码/模型与完整场景条件，缓存耗时不当成新测量。

新协议文件为 `evaluation-protocol.json`。共用的 `.arena.lock`、原子不可变分片、
SHA-256、紧凑任务索引及 timeout attempts 支持逐批保存与恢复。
完整、可靠的矩阵轮可进入缓存；损坏缓存直接报错，不能悄悄替换证据。
worker 数为执行参数，可在相同确定性配置下调整；改变模型、规则、统计代码或协议
需要新的输出目录。恢复只接受当前协议和日志 schema，不转换其他格式。

主要产物：

- `arena-summary.json`：统一 `ptcg.ai_evaluation.report/1`，含三组比较与独立性能指标。
- `arena-games.jsonl` / `arena-attempts.jsonl` / `arena-failures.jsonl`：对局、重试、失败审计。
- `arena-manifest.json`：统一 `ptcg.ai_evaluation.manifest/1`，校验完整报告与对局文件。
- `agent-provenance.json`：实际构建、Agent 身份和策略来源。

所有 preset 使用同一报告与 `ptcg.ai_evaluation.run_state/1` 紧凑日志格式。
面板直接读取 `record`、`strength`、`anchor`、`per_deck`、`integrity` 和 `reliability`；
不从总局数推算失败局为负局，也不读取根层胜率或 `paired_statistics` 别名。

## 校准与性能验证

```powershell
.\research\deep_ai\tools\test_research_smoke.ps1
.\.tools\python311\python.exe -B research/deep_ai/scripts/calibrate_evaluation.py --output build/evaluation-audit/calibration.json
.\.tools\python311\python.exe -B research/deep_ai/scripts/benchmark_evaluation.py --output build/evaluation-audit/benchmark.json
node research/deep_ai/tests/test_dashboard_evaluation.cjs
```

校准使用五组各至少 10000 次模拟，检查误判、顺序覆盖及 +2.5 个百分点的检出率。
预声明块方差约 0.0625 时目标检出率至少 80%；高波动场景单独报告，不保证达到该目标。
benchmark 使用同一批 40000 局合成证据，测量共享评价器一次性汇总和逐轮增量处理
的耗时及辅助内存，并验证两者结论完全一致；
合成数据不能用作棋力晋升证据。实际 AI 速度继续使用固定决策请求的单机 benchmark，
P95 与吞吐量只作独立性能参考。

## 清理边界

评价代码只保留统一协议、共享统计与两个原生执行适配器。仓库只维护正式评测正在
使用的冠军与历史锚点规格；过期实验规格、旧评测器、报告转发脚本和旧报告已移除。
新报告写入忽略目录，过期的评测输出与内容寻址 Agent 编译缓存可以删除后重建。
模型 checkpoint、训练 replay 和正式参考模型是训练资产，不作为编译缓存清理。

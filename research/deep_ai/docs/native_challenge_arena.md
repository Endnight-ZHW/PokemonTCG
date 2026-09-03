# Native Challenge Arena

Native Challenge Arena 是研究与晋升专用的全原生、无界面对局池。权威规则状态始终位于 Arena Host 的 C++ `RulesSession`；Python 只提交批次、持续排空结果并生成可恢复报告，不参与逐决策。

默认 `release-bundle` 比较是：

- candidate：当前 working tree 的 C++ 实现与当前 `ai_strategies.json`；
- baseline：提交 `d4f20ee9775b7e8c80a1994e5c9aa5f1e11c9864`（产品 0.8.0）的 C++ 实现与该提交中冻结的策略。

## 后端与公平性契约

可信 nightly/release 比较在 Windows 上同时为双方启动 `ExternalProcessAgent`。每个 Arena worker 长期持有 candidate/baseline 各一个隐藏 Win32 子进程，双方承担相同 JSONL IPC 成本。协议为 `ptcg.challenge_agent.ipc/1`，支持 handshake、reset、decide、cancel、contract 与 shutdown；stdout 仅承载协议，stderr 单独落盘。

`same-binary-strategy` 保留为快速结构诊断模式，双方使用当前进程中的 `InProcessCurrentAgent`。首版非 Windows 环境只支持此诊断模式；跨版本与 promotion 会快速失败。

其他固定约束：

- Arena 和 Godot 正式对局都从 `RulesSession::ai_observation_for(actor)` 取得 AI observation；`view_for()` 仍是兼容的紧凑网络视图。
- Arena 为两个座位分别维护最多 4096 条结构化 `public_history`，并按 `public/owner/private` 在每个 Agent 请求边界过滤；它与 Godot Challenge 的已知手牌确定化使用同一事件合同。
- 正式 Challenge 搜索会按已知手牌自适应信念预算：完全隐藏时最多 3 个样本；至少 1 张身份确定时使用 2 个条件化样本；手牌全知且牌库为空时使用 1 个。`native_performance_counters` 同时报告请求/实际样本及已知/未知手牌数。
- 已知手牌摘要进入回合计划缓存前置条件；知识因公开离手、整手变化等发生改变时，旧计划不能跨该变化命中。
- 对局内玩家名固定为 `Arena-Seat-0/1`。`agent_id`、`build_id` 只进入结果和 manifest，不参与随机种子或语义哈希。
- 双方使用完全相同的工作预算与采样设置，内层 search worker 固定为 1；并行只发生在对局之间。`engine`、`use_deck_inspection` 与 `use_strategy_optimization` 可作为显式 A/B treatment 不同，manifest 会分别记录双方取值。
- 每个有序牌组对覆盖 candidate seat 与 first-player 的四种组合。无序牌组对、replicate 和 base seed 通过稳定 SHA-256 派生 pair seed；A-vs-B 与 B-vs-A 共享该 seed。
- Action 按 Action v4 语义字段匹配，Choice 检查 request ID、数量、成员关系、重复项与取消状态。Agent 退出或非法响应会标记违规方、保留 failure trace 并使结构门禁失败。
- 双方配置同时失败属于基础设施失败；只有单方非 watchdog 的配置或运行失败才判该 Agent 负。
- 棋力统计只接收完整配对块：镜像牌组为四局，非镜像牌组为八局。任一局截断、基础设施失败或持续超时会剔除整个块，不能留下不平衡的座位/先手样本。
- 墙钟耗时受硬件、系统负载和调度影响，只进入 `performance_advisory`。晋升只使用固定工作预算、对局结果、结构与可靠性证据。
- 单次 `external_agent_timeout` 不判负：主并行批次结束后会用相同 watchdog、单 worker 和全新双方进程重跑一次。恢复成功采用重试结果；再次超时保持中性并触发可靠性失败。
- 外部进程失败后 worker 会对称重建 candidate/baseline，避免一个失效进程污染后续任务。

## 构建与运行

在仓库根目录运行：

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset smoke `
    -Workers 4 `
    -Output build\challenge-arena\smoke
```

PowerShell 入口每次先增量构建 pybind，然后构建/复用当前 Agent 与冻结基线 Agent。基线在 detached 临时 worktree 中完整构建，产物缓存成功后安全移除 worktree。Python 直接运行时会校验 pybind sidecar 的实际路径、SHA-256 与当前构建输入哈希，拒绝过期 `.pyd`。

sidecar 与 Arena manifest v3 记录：实际二进制路径、SHA-256、UTC mtime、编译器、rules/Challenge/Agent driver/Arena 输入哈希、完整 Git commit 与 dirty 状态、冻结策略 SHA-256，以及超时重试合同。

可选比较模式：

```powershell
# 默认：当前实现/策略 vs 0.8.0 实现/策略
-ComparisonMode release-bundle

# 双方使用 candidate 策略，只隔离 C++ 实现差异
-ComparisonMode implementation-only

# 当前同二进制策略诊断；不具备跨版本晋升证据效力
-ComparisonMode same-binary-strategy
```

跨规划引擎 A/B 允许 engine 字段不同，但 `node_budget`、
`belief_samples`、smoke 降档和 watchdog 必须完全相同。例如：

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset focused `
    -CandidateEngine strategic_intent_v3 `
    -Baseline challenge_pre_v3 `
    -BaselineEngine turn_beam_v2 `
    -ComparisonMode implementation-only
```

牌库检查知识可在同一当前二进制、同一策略和同一预算下隔离验证：

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset focused `
    -MirrorOnly `
    -Replicates 5 `
    -CandidateEngine turn_beam_v2 `
    -BaselineEngine turn_beam_v2 `
    -CandidateDeckInspection enabled `
    -BaselineDeckInspection disabled `
    -ComparisonMode same-binary-strategy
```

报告中的 `deck_inspection_count` 与
`inspection_memory_decision_count` 用于确认 treatment 实际被触发；它们只记录次数，不包含任何牌库或奖赏卡身份。

策略优化也可在同一二进制中消融；该开关覆盖奖赏稀缺/死进化线检索评分与纯引擎攻击手管线，不改变合法动作或工作预算：

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset focused `
    -MirrorOnly `
    -CandidateStrategyOptimization enabled `
    -BaselineStrategyOptimization disabled `
    -ComparisonMode same-binary-strategy
```

实现、策略与 evaluation options 全部相同时默认报 `arena_agents_are_identical`。只有明确的校准或 CI 自博弈才应使用 `-AllowSelfPlay`：

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset calibration `
    -AllowSelfPlay `
    -Workers 8
```

calibration 会为双方构建相同的当前 external Agent，默认运行 20 replicates，并输出 null distribution 供阈值审计。

## Preset 与顺序门禁

| Preset | 工作量/预算 | 判定 |
|---|---:|---|
| `smoke` | 4 matchups × 4 closures = 16 局 | 仅结构验证（并要求无超限截断） |
| `pr` | 20 matchups × 4 closures × 2 replicates = 160 局 | 结构/确定性；score rate < 0.40 失败，延迟仅告警 |
| `nightly` | 完整矩阵；5–30 replicates | 顺序 regression |
| `release` | 完整矩阵；10–50 replicates | 顺序 promotion |
| `calibration` | 相同 external Agent；默认 20 replicates | 结构与 null distribution |
| `focused` | 指定 candidate/baseline decks | 诊断 |

`focused -MirrorOnly` 只生成同套牌对局。candidate 与 baseline 的套牌集合必须相同；每个套牌、replicate 仍覆盖四种座位/先后手闭包。该模式用于在单局层面消除套牌类别强度差异：

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset focused `
    -MirrorOnly `
    -CandidateDeck fire,water,psychic,lightning,fighting,colorless,dragon,grass,steel,darkness `
    -BaselineDeck fire,water,psychic,lightning,fighting,colorless,dragon,grass,steel,darkness `
    -Replicates 10 `
    -ComparisonMode implementation-only
```

nightly/release 每完成一个 replicate 做一次预声明检查。bootstrap 只重采样完整四/八局块，并按镜像/非镜像分层；Bonferroni alpha spending 使整个顺序过程保持 family-wise 95%。报告使用 `score_rate_ci`、真实 `alpha` 与 `confidence_level`：

- nightly pass：CI 下界 > 0.48；fail：CI 上界 < 0.48；用尽预算仍未命中则 `inconclusive`。
- release pass：point estimate ≥ 0.53 且 CI 下界 > 0.50；明显低于 0.50 可提前 fail；用尽预算仍未命中则 `inconclusive`。
- release 还要求零截断、零持续超时，且 candidate 每个达到 200 局的 deck 不低于 0.45。
- 非 release 的截断率上限为 0.1%；release 必须为零。

搜索决策 P95 默认仍以 candidate/baseline `1.15` 为告警线，也可提供绝对 P95 告警预算；两者只改变 `performance_advisory.status`，不改变 gate status 或退出码。延迟按 `search/forced/cache/choice` 分开报告。
双方 watchdog 可通过 `-DecisionTimeoutMilliseconds` 统一设置；它只用于发现挂起，不是棋力时间预算，且始终执行一次单 worker 隔离重试。

CLI 状态与退出码为：`pass=0`、`fail=3`、`inconclusive=4`、`infrastructure_fail=5`。

## 持久化与恢复

输出目录使用独占 `.arena.lock` 与完整 run fingerprint。fingerprint 完全一致时默认自动续跑；Agent、策略、二进制、任务矩阵、worker 数、统计配置或报告阈值不同都会立即报错。run-state v2 还保存带校验和的 timeout attempts 与 pending retry。v1 输出不能原地续跑，需使用新的输出目录。

每次 drain 生成带 SHA-256 的 immutable shard。写入流程是临时文件、flush、fsync、`os.replace`；恢复时验证 shard checksum、唯一 task ID、任务矩阵与 fingerprint，跳过已完成任务。五份最终报告也原子发布：

- `arena-games.jsonl`：按 task ID 排序的完整结果；
- `arena-attempts.jsonl`：首次 timeout 与隔离重试的不可变审计记录；
- `arena-failures.jsonl`：结构/基础设施失败与截断；
- `arena-summary.json`：完整块胜负、paired CI、可靠性、非门禁延迟、搜索指标和明确 gate status；
- `arena-manifest.json`：构建、Git、内容、搜索契约、任务与结果证据。

action、choice、search、forced 与 cache decision count 分开报告；深度、reply depth 和 belief samples 只以 `search_decision_count` 为分母。

## 验证

```powershell
.\research\deep_ai\tools\test_research_smoke.ps1
```

普通 push/PR 的 Windows workflow 还会构建当前与 0.8.0 external Agent、运行全部 Arena 测试、执行 4-worker structural smoke，并上传报告。

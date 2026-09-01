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
- 双方使用完全相同的 `fixed_contract` evaluation options，内层 search worker 固定为 1；并行只发生在对局之间。
- 每个有序牌组对覆盖 candidate seat 与 first-player 的四种组合。无序牌组对、replicate 和 base seed 通过稳定 SHA-256 派生 pair seed；A-vs-B 与 B-vs-A 共享该 seed。
- Action 按 Action v4 语义字段匹配，Choice 检查 request ID、数量、成员关系、重复项与取消状态。Agent 超时、退出或非法响应会标记违规方、保留 failure trace 并使结构门禁失败。
- 双方配置同时失败属于基础设施失败；只有单方配置或运行失败才判该 Agent 负。
- 截断局设置 `strength_eligible=false`，不进入胜率或 bootstrap，也不会被裁定为和局。

## 构建与运行

在仓库根目录运行：

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset smoke `
    -Workers 4 `
    -Output build\challenge-arena\smoke
```

PowerShell 入口每次先增量构建 pybind，然后构建/复用当前 Agent 与冻结基线 Agent。基线在 detached 临时 worktree 中完整构建，产物缓存成功后安全移除 worktree。Python 直接运行时会校验 pybind sidecar 的实际路径、SHA-256 与当前构建输入哈希，拒绝过期 `.pyd`。

sidecar 与 Arena manifest v2 记录：实际二进制路径、SHA-256、UTC mtime、编译器、rules/Challenge/Agent driver/Arena 输入哈希、完整 Git commit 与 dirty 状态，以及冻结策略 SHA-256。

可选比较模式：

```powershell
# 默认：当前实现/策略 vs 0.8.0 实现/策略
-ComparisonMode release-bundle

# 双方使用 candidate 策略，只隔离 C++ 实现差异
-ComparisonMode implementation-only

# 当前同二进制策略诊断；不具备跨版本晋升证据效力
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
| `pr` | 20 matchups × 4 closures × 2 replicates = 160 局 | 结构/确定性/延迟；score rate < 0.40 失败 |
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

nightly/release 每完成一个 replicate 做一次预声明检查。paired-block bootstrap 保留四/八局闭包，Bonferroni alpha spending 使整个顺序过程保持 family-wise 95%：

- nightly pass：CI 下界 > 0.48；fail：CI 上界 < 0.48；用尽预算仍未命中则 `inconclusive`。
- release pass：point estimate ≥ 0.53 且 CI 下界 > 0.50；明显低于 0.50 可提前 fail；用尽预算仍未命中则 `inconclusive`。
- release 还要求零截断、candidate 每个达到 200 局的 deck 不低于 0.45，且 candidate P95 ≤ baseline P95 × 1.15。
- 非 release 的截断率上限为 0.1%；release 必须为零。

CLI 状态与退出码为：`pass=0`、`fail=3`、`inconclusive=4`、`infrastructure_fail=5`。

## 持久化与恢复

输出目录使用独占 `.arena.lock` 与完整 run fingerprint。fingerprint 完全一致时默认自动续跑；Agent、策略、二进制、任务矩阵、worker 数、统计配置或报告阈值不同都会立即报错。已完成运行直接复用报告。

每次 drain 生成带 SHA-256 的 immutable shard。写入流程是临时文件、flush、fsync、`os.replace`；恢复时验证 shard checksum、唯一 task ID、任务矩阵与 fingerprint，跳过已完成任务。四份最终报告也原子发布：

- `arena-games.jsonl`：按 task ID 排序的完整结果；
- `arena-failures.jsonl`：结构/基础设施失败与截断；
- `arena-summary.json`：胜负、paired CI、拆分指标、延迟、搜索指标和明确 gate status；
- `arena-manifest.json`：构建、Git、内容、搜索契约、任务与结果证据。

action、choice、search、forced 与 cache decision count 分开报告；深度、reply depth 和 belief samples 只以 `search_decision_count` 为分母。

## 验证

```powershell
.\research\deep_ai\tools\test_research_smoke.ps1
```

普通 push/PR 的 Windows workflow 还会构建当前与 0.8.0 external Agent、运行全部 Arena 测试、执行 4-worker structural smoke，并上传报告。

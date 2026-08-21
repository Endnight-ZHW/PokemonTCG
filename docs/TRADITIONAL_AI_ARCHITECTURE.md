# PTCG 传统 AI v2：固定深度搜索

发行版 Challenge AI 使用 `turn_beam_v2`。搜索质量只由固定结构配置决定，不再由设备速度、毫秒期限或节点预算决定；Python AI 不进入生产运行时，只负责离线评测、聚合和报告。

## 信息与规则边界

`AIRuntimeStateProjection` 是主场景、评测器、候选运行时验证器以及 Deep→Challenge 回退共用的唯一请求投影。它保留己方手牌、双方已公开场面、弃牌区、隐藏区数量、公开日志、公开牌组 key、revision 和比赛种子；对手手牌、双方牌库/奖赏卡身份、未公开开局场面、结算栈、Choice 序号、开局奖励牌身份和幂等记录均被移除。投影带有 `ai_public_state_v1` 边界标记，并在 worker 入口再次验证；缺少标记或重新混入任一隐藏身份/私有字段的请求会整批拒绝。该字典保留 GameState 外形仅用于观察编码，明确不是可恢复的 Snapshot 3。

动作请求必须携带调用方从权威 `RulesSession` 取得的完整 `actions` 集合。Challenge worker 不再从公开观察调用 `query_legal_action_groups()`；它逐条验证 Action v4、actor、base revision、公开实体引用和去除 action ID 后的规范签名，缺失、过期、格式错误、隐藏引用或重复动作都会返回明确错误。规划结果仍由主原生会话按当前 revision 重新核对并应用。开局场面尚未公开时，唯一动作直接执行；多动作只使用既有静态策略评分，不尝试恢复不完整局面。

`AIInformationSet` 是规划器和牌组策略内部的唯一观察入口。信念状态只根据发行牌表和上述公开信息重建。

Challenge 与 Deep 回退固定 `apply_type_matchups=false`。策略语义目录不导出弱点、抗性或属性对位字段；卡牌 VM 明示的属性条件仍由规则引擎执行。

## 固定工作配置

生产配置不可由请求调整：

- 我方回合深度 8；
- 最多 8 个根动作，每个根动作保留 2 条线路；
- 每个节点最多 8 个语义不同的候选；
- 对手回应深度 3、宽度 4、每节点最多 4 个动作；
- 完全确定的状态使用 1 个信息集样本；存在隐藏区或随机语义时使用 3 个固定种子样本。

正常搜索没有 `seconds`、`time_budget_ms`、模拟次数、动态预算或节点预算。每个完整层全部展开后才更新 `completed_depth`；到达深度 8 报告 `depth_complete`，没有可扩展节点报告 `frontier_exhausted`。部分层不会成为可选择结果或已完成深度。

搜索只能因深度完成、搜索空间耗尽、强制战术、缓存命中、显式取消或异常结束。玩家离开对局会使后台任务尽快取消；固定的 Choice 步数、重复特性次数和强制战术节点保护仅用于防止结构性死循环，不参与正常强度裁剪。

## 决策流水线

1. `AIMandatoryTactics` 在缓存之前检查唯一合法动作、立即获胜/击倒和生存性铺场。
2. `AIPositionEvaluator` 将动作排序、叶面位置和故障回退量化为整数毫分。牌组策略只能贡献有界附加分。
3. 候选先按攻击、进化、能量、铺场、换位、特性、训练家等动作目的保底，再按来源卡、招式、目标、费用和完整 payload 的语义签名补充。结束回合和至少一个终结动作始终保留。
4. 根动作集合只选择一次。每个根动作在同一组 1/3 个信息集种子上搜索，以平均整数分、最差样本分、规范化签名依次决胜，避免根动作之间的抽样偏差。
5. 对手搜索从其公开牌组 key 加载实际 `DeckStrategy`，不再使用无策略的单步通用回应。
6. 语义计划缓存保存动作意图和公开状态前置条件。每次结算后重新核对 revision、actor、phase、公开指纹和当前合法动作；失效后重新运行完全相同的固定搜索，不降级为局部搜索。
7. `AICoordinator` 只负责异步执行、代际校验、取消和回收，不设置 1100ms 超时。异常回退使用统一战术排序器，不按动作名称排序。

`GameEngine` 在每次传统 AI 决策开始/结束时建立搜索 epoch。epoch 内按 GameState 实例、revision 和内容指纹缓存原生会话；父节点合法动作只查询一次，每个 v2 候选通过 `RulesSession.fork_for_search(seed)` 建立确定性分支，连续 Choice 在同一分支会话结算，父会话状态/RNG 保持不变。卡牌目录和规则 kernel 作为只读上下文由分支共享，搜索分支不写 MatchJournal。普通动作路径也只恢复一次并在同一会话完成合法性核对；恢复热路径按需构造 GDScript DTO，冻结 v1 因而无需修改评分、预算或源码即可恢复工作量。

每次适用搜索统一报告 `engine_id`、`requested_depth`、`completed_depth`、`max_path_depth`、`reply_completed_depth`、`layers_completed`、`nodes_expanded`、`completion_reason`、`decision_origin` 和 `failure_stage`。主场景紧急动作/Choice fallback 另有逐局计数；评测器记录 origin/stage 分布并将任何紧急 fallback 视为非干净对局。耗时仍记录为诊断数据，但不影响动作或门禁。

## 卡组策略

正式策略由 `godot/data/ai_strategies.json` 和十套牌的 `DeckStrategy` hook 提供，覆盖 Fire、Water、Psychic、Lightning、Fighting、Colorless、Dragon、Grass、Steel 与 Darkness。策略只接收深只读信息集、序列化合法动作/ChoiceView 和脱敏卡牌语义。

新增牌组时需要注册策略、生成数据、覆盖展开/进化/检索/换位/攻击/奖赏/资源/避险金标，并增加 3 条多步意图链测试。未知自定义牌组使用通用策略。

## v1 回归基线

旧时间预算实现冻结为评测专用 `turn_beam_v1`，代码和当时的策略数据快照位于 `godot/tools/ai_baseline/`。Godot 导出配置排除 `tools/*`，所以正式包只包含 v2。v1 保留一个发布周期，仅供 schema v7 的配对强度回归；缺少基线资源时必须显式失败。

## schema v7 评测与门禁

`tools/evaluate_godot_ai.ps1 -EvalPreset Nightly` 默认生成 v2（A）对冻结 v1（B）的固定配对评测：

- 10 套牌 × 50 个镜像种子块 × 2 次换席 = 1000 局；
- 45 个无序跨牌组对 × 10 个种子块 × 4 局角色/座位闭合 = 1800 局；
- 总计固定 2800 局。

镜像和跨牌组结果分别以两局/四局闭合块做分层 cluster bootstrap。`nightly-superiority` 要求两组 95% 置信区间下界都严格大于 0；任一牌组镜像点差不得低于 −4pp，任一无序跨牌组点差不得低于 −8pp。证据不足直接失败，不追加有利种子。

所有适用 v2 样本必须来自 `turn_beam_v2`，请求深度严格等于 8，且 `reached_depth == max_path_depth`。`depth_complete` 必须满足 `completed_depth == requested_depth`；`frontier_exhausted` 必须在最后一个完整层后确实不存在可扩展节点，不能用部分展开层充数。适用的对手回应同样必须完整达到深度 3 或明确耗尽搜索空间。动作决策总数、适用搜索、强制战术与缓存命中按侧守恒，规划器异常回退不能被记作非适用决策。`deadline`、`node_budget` 和其他部分搜索必须为零。深度门禁直接从主矩阵的全部适用决策重新聚合，并按候选侧和牌组核对覆盖；不再追加重复的串行深度探针。决策耗时和完整 AI 回合 P50/P95 只展示。

非法动作、规则异常、Choice 失败、非正常终局和动作上限耗尽必须为零。`weak_attack_before_development` 发生率必须较 v1 至少下降 50%，其他诊断发生率不得上升超过 0.1pp。

schema v7 使用固定 `protocol_id`，明确记录 A/B 引擎，并拒绝把 schema v6 或更早结果用于新门禁。`simulation_fingerprint` 绑定 AI、冻结 v1、规则、卡牌、策略、Godot 可执行文件精确哈希、赛程和执行配置；`analysis_fingerprint` 只绑定聚合、校验和报告代码，所以分析代码变化只需重新聚合。Nightly 固定分为 500 个两局镜像单元和 450 个四局跨牌组单元；每个单元原子写入不可变 checkpoint，重启及 CI workflow 重试只补齐缺失或校验失败单元，`-NoResume` 会同时禁止读取和写入 checkpoint。镜像记录必须恰好包含席位 0/1，跨牌组记录必须恰好包含两个相反方向各自的席位 0/1，重复席位或缺失方向均按损坏记录处理。调度前的内容检查器会复核模拟指纹、任务/分片身份、证据单元身份、干净终局和规范化比赛 SHA-256；损坏或过期记录按缺失处理并允许重新生成，但同一证据单元若出现内容不同且各自校验有效的冲突记录，整次运行立即 fail-closed，绝不选择其中任一份继续。聚合结果保留排序后的完整证据单元清单及其 SHA-256；最终 Nightly 校验器会将这 950 个身份逐一与主矩阵中重新构建的完整单元交叉核对，因此仅伪造正确计数不能通过。50 个逻辑分片始终保持证据单元完整，本机使用固定代表性前缀估算成本，再按实际缺失单元做确定性 LPT 分配；正式本机配置最多 12 个 worker，CI 使用 25 个 job、每个 job 2 个 worker。

本次公开投影、搜索实现和原生二进制均进入 `simulation_fingerprint`，因此旧 checkpoint 不可复用；只有以新指纹重新生成的结构预检、固定 280 和完整 2800 局证据有效。

本机完整 Nightly 会先运行固定 280 局结构预检；预检只能因非法动作、规则异常、Choice 失败、动作上限或金标失败，不能根据胜率或置信区间提前通过或拒绝。其 checkpoint 会由随后的完整矩阵直接复用。CI 的每个 runner 在正式分片前并发运行两份固定的两局 v1 工作量校准，以模拟正式的双 worker 负载；任一结果低于冻结工作量下限都会拒绝该 runner，避免时间门禁型基线因资源争抢被削弱。

权威聚合器是 `python/scripts/ai_evaluation_v7.py`；固定产物为 `results.json`、`validation.json`、`report.html`、`provenance.json`、`task_manifest.json`、`simulation_config.json`、`shards/` 和 `checkpoints/`。结果同时记录 `gate_depth_source=main_matches`、checkpoint 汇总、执行配置和墙钟统计作用域；CI 未记录统一分布式墙钟时明确写 `not_recorded`。本机计时从 280 局预检之前开始，同次预检生成再由主矩阵读取的 checkpoint 仍属于 `full_evidence_stage`；只有启动前已存在可恢复记录时才标为 `current_attempt_only`。只有 `full_evidence_stage` 的同机证据可以进入性能对比。需要观察单进程延迟时可显式增加 `-PerformanceBenchmark`；它运行 20 局预热和 40 局测量，只写入诊断字段，不参与强度或深度门禁。

## 测试

`tools/test_godot_ai.ps1` 覆盖信息隔离、整数确定性、完整层、搜索空间耗尽、共同样本公平性、语义候选、实际对手策略、规范化平局、缓存失效、取消和十套牌实局冒烟。相同快照与种子在注入执行延迟以及启用/禁用原生数学路径时，动作、计划、完成深度和节点数必须一致。

原有 109 个策略金标继续保留；schema v7 另外要求每套牌 3 条多步意图链，共 30 条，覆盖发展早于弱攻击、资源/能量路线和换位避险。Android 设备可用时，应以相同种子运行冒烟并比较轨迹哈希。

常用验证命令：

```powershell
.\tools\test_godot_ai.ps1
.\tools\test_godot.ps1
.\tools\test_python.ps1 -Tier core
.\tools\evaluate_godot_ai.ps1 -EvalPreset Nightly
.\tools\evaluate_godot_ai.ps1 -EvalPreset Nightly -PerformanceBenchmark
```

完整 2800 局是发布门禁，不应以本地小样本替代。

本轮修复的本机定向验收中，生产 v2 火系镜像 2/2 干净结束，36 个适用搜索样本共展开 15,904 节点；加权 `planner_ms / nodes_expanded` 为 2.3901ms，中位数 2.3555ms，低于迁移前 4.603ms/node 的 1.25 倍上限。冻结 v1 校准在原阈值下通过：2/2 干净结束、simulation sum 7,897、full-budget decisions 14、deadline decisions 68。另一个 fire/water 镜像与交叉矩阵 8/8 正常 `game_over`，覆盖 v2 347 次和 v1 309 次动作决策，未出现 `native_restore_failed`、`no_simulatable_action`、非法动作、Choice/规则失败或紧急 fallback。该定向结果用于回归和性能定位，不替代新指纹下的固定 280 等价证据或完整 2800 局 Nightly。

本次热路径优化可用固定 280 局 v2 对 v2 语料做等价与性能验收；它必须逐局、逐决策保持规范化结果和 v2 轨迹完全一致，并在同一主机、相同 worker 数下同时达到节点单位规划耗时中位数下降 25% 和完整证据阶段墙钟下降 20%。该语料只验证实现等价和性能，不代替下一次正常 Nightly 的 2800 局强度门禁。

本次最终固定 280 验收在同机 12 workers 下完成：逐决策 `planner_ms / nodes_expanded` 中位数从 6.278976208 降至 4.603160570（−26.6893%），`full_evidence_stage` 墙钟从 7,796,930.654ms 降至 5,791,977.788ms（−25.7146%），均超过 25%/20% 门槛。280 局共包含 13,668 个 v2 搜索样本，规范化比赛结果和 trace-v0 与基线全量一致，且结构性错误为零。

由于旧固定 280 产物生成时尚未记录 `decision_semantic_hash`，本次仅允许使用 `traditional_ai_v7_decision_semantics_migration_v1` 一次性迁移证明：从固定 280 中抽取覆盖全部十套牌的 20 局、988 个搜索样本，逐决策验证完整计划、根顺序、样本数、深度、节点数、缓存前置条件、belief hash 和 trace-v1；其余 12,680 个旧样本只由全量规范化结果及 trace-v0 一致性间接约束。最终候选的全部 280 局仍须独立满足严格 schema v7 合同，生产验证器不得接受迁移产物代替正常 v7 证据。

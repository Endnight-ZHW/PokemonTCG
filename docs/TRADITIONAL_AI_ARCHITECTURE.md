# PTCG 传统 AI v2：固定深度搜索

发行版 Challenge AI 使用 `turn_beam_v2`。搜索质量只由固定结构配置决定，不再由设备速度、毫秒期限或节点预算决定；Python AI 不进入生产运行时，只负责离线评测、聚合和报告。

## 信息与规则边界

`AIInformationSet` 是规划器和牌组策略的唯一观察入口。它保留己方手牌、双方公开场面、弃牌区、隐藏区数量、公开历史、合法动作、公开牌组 key 和比赛种子；对手手牌、双方牌库/奖赏卡身份、结算栈和私有日志均被移除。信念状态只根据发行牌表和公开信息重建。

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

每次适用搜索统一报告 `engine_id`、`requested_depth`、`completed_depth`、`max_path_depth`、`reply_completed_depth`、`layers_completed`、`nodes_expanded` 和 `completion_reason`。耗时仍记录为诊断数据，但不影响动作或门禁。

## 卡组策略

正式策略由 `godot/data/ai_strategies.json` 和十套牌的 `DeckStrategy` hook 提供，覆盖 Fire、Water、Psychic、Lightning、Fighting、Colorless、Dragon、Grass、Steel 与 Darkness。策略只接收深只读信息集、序列化合法动作/ChoiceView 和脱敏卡牌语义。

新增牌组时需要注册策略、生成数据、覆盖展开/进化/检索/换位/攻击/奖赏/资源/避险金标，并增加 3 条多步意图链测试。未知自定义牌组使用通用策略。

## v1 回归基线

旧时间预算实现冻结为评测专用 `turn_beam_v1`，代码和当时的策略数据快照位于 `godot/tools/ai_baseline/`。Godot 导出配置排除 `tools/*`，所以正式包只包含 v2。v1 保留一个发布周期，仅供 schema v6 的配对强度回归；缺少基线资源时必须显式失败。

## schema v6 评测与门禁

`tools/evaluate_godot_ai.ps1 -EvalPreset Nightly` 默认生成 v2（A）对冻结 v1（B）的固定配对评测：

- 10 套牌 × 50 个镜像种子块 × 2 次换席 = 1000 局；
- 45 个无序跨牌组对 × 10 个种子块 × 4 局角色/座位闭合 = 1800 局；
- 总计固定 2800 局。

镜像和跨牌组结果分别以两局/四局闭合块做分层 cluster bootstrap。`nightly-superiority` 要求两组 95% 置信区间下界都严格大于 0；任一牌组镜像点差不得低于 −4pp，任一无序跨牌组点差不得低于 −8pp。证据不足直接失败，不追加有利种子。

所有适用 v2 样本必须来自 `turn_beam_v2`，请求深度至少为 8，并满足 `depth_complete && completed_depth >= requested_depth` 或 `frontier_exhausted`。`deadline`、`node_budget` 和其他部分搜索必须为零。单进程 20 局预热 + 40 局测量探针用于验证深度；决策耗时和完整 AI 回合 P50/P95 只展示。

非法动作、规则异常、Choice 失败、非正常终局和动作上限耗尽必须为零。`weak_attack_before_development` 发生率必须较 v1 至少下降 50%，其他诊断发生率不得上升超过 0.1pp。

schema v6 明确记录 A/B 引擎并拒绝 schema v5 或更早结果。权威聚合器是 `python/scripts/ai_evaluation_v6.py`；固定产物为 `results.json`、`validation.json`、`report.html`、`provenance.json`、`shards/` 和 `search_depth_probe/`。

## 测试

`tools/test_godot_ai.ps1` 覆盖信息隔离、整数确定性、完整层、搜索空间耗尽、共同样本公平性、语义候选、实际对手策略、规范化平局、缓存失效、取消和十套牌实局冒烟。相同快照与种子在注入执行延迟以及启用/禁用原生数学路径时，动作、计划、完成深度和节点数必须一致。

原有 109 个策略金标继续保留；schema v6 另外要求每套牌 3 条多步意图链，共 30 条，覆盖发展早于弱攻击、资源/能量路线和换位避险。Android 设备可用时，应以相同种子运行冒烟并比较轨迹哈希。

常用验证命令：

```powershell
.\tools\test_godot_ai.ps1
.\tools\test_godot.ps1
.\tools\test_python.ps1 -Tier core
.\tools\evaluate_godot_ai.ps1 -EvalPreset Nightly
```

完整 2800 局是发布门禁，不应以本地小样本替代。

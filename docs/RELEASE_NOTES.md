# PokemonTCG Godot 0.7.0

0.7.0 将规则运行时收敛为 Native ABI 2 的单一 C++ `ptcg_core`。Godot 与 Python
只保留绑定/DTO、卡牌作者工具和训练编排；旧 Python/GDScript 规则执行器与 Pygame UI
已删除。Protocol 6、Actions 4、ChoiceView 2、Snapshot 3 与 VM IR 3 的对外形状保持兼容。

## 0.7.0 规则核心与发布边界

- `NativeRulesSession` 独占完整状态、xorshift32 RNG、revision、动作幂等记录、事务快照、
  continuation、结算栈与玩家视图；规则错误 fail-closed，不回退旧引擎。
- 迁移期入口已清零：Python/Godot 只接受 Action v4 与 ChoiceView v2，删除旧 ChoiceRequest、
  `ActionResult` 双重包装、规则运行时开关、网络等待镜像及旧附件字段适配。
- 137 张卡由类型化 Python DSL 编译为 Card IR v3；80 个 VM 描述符由同一 C++ handler
  集合执行，发布 C++ 源码不按卡牌 ID 分派。
- 新增 MatchJournal v1、确定性 replay/fork、Workbench 场景构造与首分歧诊断。
- 本地双人、Challenge AI、原生 Deep 搜索基础、LAN 与 Relay 均消费同一 RulesSession。
  Deep 训练工程已升级为 AlphaZero v3；当前没有已晋升模型，因此发布 UI 继续关闭 Deep
  并回退 Challenge。
- Deep v3 使用整局 `NativeActorPoolV3`、Encoder 8、Checkpoint 13、Planner 3、
  runtime manifest 4、动态候选和三分类 WDL；Replay 改为带指纹/去重/seed 分片的
  Safetensors shard，learner 与 champion 分离并可从周期边界精确恢复。旧 Deep
  trainer、replay、continuation bridge、encoder 7 与晋升脚本已删除；v2 产物拒绝加载。
- Choice 日志按显式语义区分“从弃牌区回收”和“弃置手牌/能量”，不再根据请求名
  中的 `discard` 猜测；Challenge AI 同步使用 Native ABI 2 发布的规范转附、弃置与换位语义。
- Challenge AI 不再执行两张同名、同状态宝可梦之间没有任何收益的撤退；若撤退能够
  清除特殊状态/临时效果，或换上更健康、更就绪的同名宝可梦，仍会按正常战术评估。
- 撤退、训练家/特性换位、强制换位、喷射能量及晋升事件现在都携带明确的板凳槽位；
  即使交换双方 `card_id` 完全相同也会播放双向动画。付费撤退保持先弃能量、后换位，
  离开战斗场的宝可梦会按规则清除特殊状态与临时攻击效果。
- Windows x86_64 与 Android 9+ ARM64 共用同源核心；快速门禁只运行一次 C++、一次
  Python 作者工具检查和一个 Godot 进程。
- Deep 未启用时，Release 扩展不编译搜索/ONNX 绑定且包内不携带 ONNX Runtime；Debug
  仍可按需构建完整 Deep 工具链。

## 0.7.0 验证

- 326 个 Python 作者/绑定/训练工具测试、C++ 独立核心测试、Godot 绑定/UI/协议合同通过。
- 10 组 Challenge AI、LAN 与 Relay 完整对局正常结算；冻结转换语料零分歧。
- 本次 AI 实战回归覆盖 1,095 个动作与 158 个选择；同名换位的 50% 动画检查和最终
  权威状态对账均通过。
- 原生搜索 7 次中位数为 2,843.60 simulations/s，是冻结基线的 106.37%，并显著快于
  Python 深拷贝/绑定退化路径。
- Windows Release 启动烟测、Android APK 签名/ABI/载荷静态合同通过；实体 Android
  设备烟测仍须在有设备的发布环境执行。

---

## 0.6.0 历史说明

Godot 4.7 是唯一发布客户端。0.6.0 在 0.5.0 的严格动作信封和事务管线之上，补齐 VM 描述符、可挂起触发栈、持续 Modifier 和规则/表现边界。该版本是原子破坏性升级，不提供 Protocol 5 或 Snapshot 2 桥接。

## 规则公开边界

- `query_legal_action_groups()` 返回结构化 `LegalActionQueryResult`。普通非法候选只被过滤；VM schema、描述符或预检合同错误会终止查询，不返回部分结果，也不会写入缓存。
- `ChoiceView` v2 是唯一公开选择结构，只包含请求 ID、revision、玩家、类型、公开选项、约束和白名单 presentation。continuation、guard、command、checkpoint 与事务快照只保留在权威 `GameState`。
- UI、Challenge AI、LAN 与 Relay 只调用 `GameEngine` 的查询、动作提交和 Choice response 接口；展示状态不再依赖 `resolution_stack`。

## VM 与触发结算

- Python 的冻结 VM command descriptor 文件是 80 个发布 op 的权威合同，逐 op 约束参数、分支、执行上下文、时序、挂起和替换伤害属性。Godot 启动时校验 descriptor、handler、preflight 与 golden 集合严格一致。
- 查询和执行共用纯 preflight；未知 op、额外/缺失参数、非法分支、内部 op 外泄与未知 evaluator 均 fail-closed。查询不复制事务快照、不执行动作、不读取 RNG。
- Snapshot 3 使用 `command / continuation / trigger_batch / trigger / barrier` 严格帧联合，并限制 64 帧/触发深度、4096 总步骤、256 个同批触发和 1 MiB 序列化大小。
- AFTER_DAMAGE、POKEMON_KO、ON_ATTACH、ON_PRIZE_REVEALED 与学习装置进入统一 TriggerScheduler。可选触发和同优先级排序可通过 Choice 挂起，恢复后继续保留步骤预算和 trigger origin。

## Modifier 与数据驱动规则

- 持续修正由冻结的 `ModifierDescriptorRegistry` 管理，伤害、HP、撤退、攻击许可和效果防止使用固定层级、优先级、scope、duration、stacking 与 conflict policy。
- 防伤、效果防止、输出减伤、招式锁定和炫目等临时效果迁为有期限 Modifier，并在换位、进化、回合结束或来源离场时统一清理。
- 高级球与四种特殊能量均由 compiled cost/modifier/trigger descriptor 驱动；规则端不再按卡牌 ID 分支。拥有相同描述符的克隆卡具有相同行为。
- Judge、Clara 等现有复合 op 保留并标记为严格 `native_composite`；新增规则不得使用卡名式 op。

## AI 与发布合同

- Challenge AI 升级为 `turn_beam_v2` 固定深度搜索：我方深度 8、8 个根动作×2 条线路、每节点 8 个候选，对手回应深度 3/宽度 4；隐藏或随机状态使用 3 个共同种子。
- 生产搜索移除毫秒期限、节点预算、动态预算和低配局部重规划。协调器保留异步执行、代际校验和离场取消；耗时仅作诊断。
- 新增统一整数位置评估器、分层语义候选、跨样本公平根动作比较、实际对手牌组策略回应，以及固定质量的语义计划缓存重规划。
- AI 决策种子由比赛 seed、revision、actor、请求类型与请求 ID 稳定派生，不推进规则 RNG；Challenge 与 Deep 回退固定关闭全局弱点、抗性。
- 旧实现及当时策略数据冻结为导出排除目录中的评测基线 `turn_beam_v1`，正式包只包含 v2；未知评估引擎 fail-closed。Deep runtime 继续关闭。
- AI 评测升级为 schema v7：Nightly 固定执行 2800 局 v2 对 v1 配对评测，直接以主矩阵全部决策验证完整深度 8/搜索空间耗尽和零时间/节点截断；双强度 CI、逐牌组/对局下限及诊断门禁不变，v6 或更早结果拒绝验收。
- 评测新增原子证据单元 checkpoint、固定 50 个逻辑分片、本机 280 局结构预检和基于剩余工作量的确定性 LPT 调度；调度器先逐内容复核 checkpoint 指纹、身份、干净终局与比赛哈希，镜像必须唯一覆盖两席，跨牌组必须唯一覆盖双方向各两席。聚合结果的完整单元身份清单及哈希还会与主矩阵逐一交叉核对。单条损坏或过期记录按缺失处理并可重新生成；同一证据单元出现两条内容不同但各自校验有效的记录时立即 fail-closed，禁止任选其一继续评测。CI workflow 重试可恢复已校验证据，每台 runner 在双 worker 负载下并发校准冻结 v1。20 局预热 + 40 局测量改为显式可选的性能 benchmark，只作诊断。
- v2 搜索热路径跳过未使用的蒸馏编码，复用只读公开投影、批量动作评分、父节点缓存前置条件、节点指纹/签名和单次决策内的 sample-0；合法动作提供不污染权威缓存的临时查询。等价合同要求动作、计划、根顺序、样本、深度、节点数、belief/轨迹哈希逐字段不变。
- v7 将模拟与分析来源分离指纹，模拟指纹包含精确 Godot 可执行文件哈希；固定 280 性能证据还绑定同机指纹和完整证据阶段墙钟作用域，分析代码变化不再重跑原始比赛。Nightly 门禁同时要求 50 个 checkpoint 分片合计覆盖全部 950 个证据单元；报告展示协议、执行、恢复和墙钟范围。
- 固定 280 局 v2 对 v2 最终验收通过：同机 12 workers 下，逐决策 `planner_ms / nodes_expanded` 中位数由 6.278976208 降至 4.603160570，下降 26.6893%；完整证据阶段墙钟由 7,796,930.654ms 降至 5,791,977.788ms，下降 25.7146%。280 局、13,668 个 v2 搜索样本的规范化比赛结果与 trace-v0 全量一致，非法动作、规则异常、Choice 失败和动作上限耗尽均为零。该结果只验收等价性与性能，不代替 2800 局 Nightly 强度门禁。
- 旧固定 280 基线不含 `decision_semantic_hash`，本次通过一次性迁移证据补齐发布证明：覆盖全部十套牌的固定 20 局锚点在 988 个搜索样本上严格匹配 `traditional_ai_decision_semantics_v1`，其余 12,680 个旧样本由全量规范化比赛结果和 trace-v0 一致性约束；最终 280 局候选自身通过严格 schema v7 校验。该迁移产物不被生产 v7 验证器接受。
- 保留 109 个策略金标，并增加十套牌各 3 条多步意图链金标。延迟 P50/P95 继续展示，但不参与通过判定。
- 产品 `0.6.0`，Android `versionCode=8`；Protocol 6、Godot Rules 6、Python Rules 5、VM IR 3、Snapshot 3、Encoder 5。
- Godot Actions 4、Python Actions 3、Checkpoint 10、RNG 2 保持不变；Planner 为 2，AI Evaluation 为 7。

## 验证顺序

```powershell
.\tools\test_fast.ps1
.\tools\test_standard.ps1
.\tools\test_godot_network.ps1
.\tools\test_godot_ai.ps1
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\smoke_godot_build.ps1
.\tools\test_release.ps1
```

Android 正式商店签名和目标真机矩阵仍需在发布环境执行。本版不发布 Python 客户端，也不支持旧协议房间恢复或房主迁移。

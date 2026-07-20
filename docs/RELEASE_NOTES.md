# PokemonTCG Godot 0.6.0

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

- AI 决策种子由比赛 seed、revision、actor、请求类型与请求 ID 稳定派生，不推进规则 RNG；过期 worker 结果被丢弃并回退 Challenge AI。
- Deep runtime 继续关闭，10 个旧模型保持 legacy，本轮不重新训练。
- 产品 `0.6.0`，Android `versionCode=8`；Protocol 6、Godot Rules 6、Python Rules 5、VM IR 3、Snapshot 3、Encoder 5。
- Godot Actions 4、Python Actions 3、Checkpoint 10、Planner 1、RNG 2 保持不变。

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

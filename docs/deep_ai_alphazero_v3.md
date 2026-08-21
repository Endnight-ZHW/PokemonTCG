# Deep AI：高吞吐信息集 AlphaZero v3

当前工程闭环是：

```text
GameTaskV3 -> C++ NativeActorPoolV3 <-> PyTorch CUDA batch broker
                                      |
                                      v
                           Safetensors ReplayStoreV3
                                      |
                                      v
                       persistent learner -> arena -> champion
```

发布仍保持 `deep_runtime_enabled=false`、`model_count=0`。本轮只生成工程
pilot 与候选合约，不自动晋升模型。

## 固定合约

- encoder 8、checkpoint 13、planner 3、runtime manifest 4；原生规则 ABI 2。
- 模型为 `universal_infoset_transformer_v3`：128 维、4 层、8 头，三分类 WDL。
- 输入为 `state_global[192]`、`entity_numeric[160,24]`、
  `entity_card_ids[160]`、`entity_type_ids[160,4]`、显式
  `entity_mask[160]`，以及动态候选 `candidate_numeric[A,48]`、
  `candidate_refs[A,8]` 和 mask。
- 12 个场上位置固定；其余可见实体按 owner/zone/slot/card 聚合。编码器
  遇到超过 160 token 的非法输入会报错，不会静默截断。
- 卡牌 DSL 导出的固定 53 维语义向量与可训练 card embedding 相加。

## Actor 与 replay

每个 actor 的 `RulesSession` 从建局到终局都留在 C++。搜索 fork 不写正式
journal，私有 continuation 不跨 Python；worker 复用搜索器、determinizer、
encoder 和 catalog，并共享 cooperative CPU limiter 与 GPU 推理队列。

Replay 每 4,096 样本发布一个原子 Safetensors shard，候选使用 offsets 与扁平
张量。manifest 记录 shard SHA-256、规则/卡牌/词表指纹、game seed、模型版本和
来源。seed 级 90/10 train/validation 隔离，重复样本 fail-closed。本机默认上限
500,000 样本或 8 GiB；teacher shard 永不淘汰。远端 worker 使用原子 task/result
清单，不依赖 `fcntl`，可把验证后的 shard 合并回同一 run。

## Learner、champion 与恢复

learner 与 champion 是两个独立角色。arena 拒绝只阻止 champion 更新，不回滚
learner。周期 checkpoint 包含模型 Safetensors、AdamW/GradScaler/scheduler、
Python/NumPy/PyTorch/CUDA RNG、replay sampler RNG、global step 和带 SHA-256 的
bundle。周期记录也写入 checkpoint，因此在 checkpoint 与 run-state 发布之间中断
仍能恢复完整审计行。

默认微周期生成 25,000 个新样本，再训练两个 replay pass；80% 对局为最新
learner 自博弈，20% 对 champion。训练 batch 默认按 80% self-play / 20%
Challenge teacher 分层抽样，并平衡牌组、阶段与模型新旧程度。每个混合 pass
之后会检查固定 teacher validation；若损失越过 warmup 最佳值的 110%，则在
warmup anchor 与新 learner 之间做确定性的 trust-region 投影，选择仍满足门禁的
最大新 learner 比例。该步骤保留 AdamW、GradScaler、scheduler、RNG 与 global
step，不以 champion 回滚，也不会把 validation 样本送入 SGD。

pilot 的 arena 仍覆盖全部 55 个牌组配对和座位闭包，但将单局限制为 64 个决策，
用于验证 actor/搜索/continuation 结构完整性；release 才使用配置的正式长局上限。

## 命令

```powershell
# 快速端到端
.\tools\train_deep_ai_v3.ps1 -Preset smoke

# 并行生成固定 Challenge teacher
.\tools\train_deep_ai_v3.ps1 -GenerateBootstrap -BootstrapWorkers 8 `
  -BootstrapTaskLimit 8

# 5 个 teacher warmup epoch + 两个 25,000 样本周期
.\tools\train_deep_ai_v3.ps1 -Preset pilot

# 2,200 条原生长轨迹 / 256 局 CUDA 搜索 soak
.\tools\verify_native_actor_v3.ps1 -Mode rules
.\tools\verify_native_actor_v3.ps1 -Mode cuda-soak

# 同机固定根与完整 v3 基准
.\tools\benchmark_ai_pipeline_v3.ps1

# 500,000 样本索引 RSS 与双预取 loader/learner 吞吐比
.\tools\benchmark_replay_v3.ps1 -Replay <replay-v3> -Summary <summary-v3.json>
```

dashboard 的 pause/cancel 会在 actor 决策边界、推理排空和 SGD step 边界协作
响应，并把 `paused`、`cancelled` 与可恢复 checkpoint 状态写回 run。

## 运行时

`DeepAIRuntime.load_for_deck()` 保持稳定。Godot 原生扩展只接受 v3 的 12 个
ONNX 输入；动作根、选择根、2 秒 watchdog 或任何模型/合约/数值错误都会回退
 Challenge。v2 checkpoint/run/replay 会返回明确的 unsupported-v2 诊断。
旧的 v2 PowerShell/Python 写入口、训练模块和 package facade 均已移除。

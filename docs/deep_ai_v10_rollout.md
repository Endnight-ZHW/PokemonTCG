# Deep AI v10 历史模型与规则迁移门禁

## 当前发布状态

0.4.0 已升级到 Python rules v3 / Godot rules v4。仓库中的 10 个 checkpoint v10、encoder v3
模型仍由 sidecar 如实标记为 Python rules v2、Godot rules v3；没有重新训练、重新评估，也没有
修改 metadata 冒充兼容。

因此根 `release_manifest.json` 固定记录：

```json
{
  "deep_runtime_enabled": false,
  "deep_fallback": "challenge",
  "compatible_model_count": 0,
  "legacy_model_count": 10
}
```

发布 UI 不显示 Deep 入口，`DeepAIRuntime.load_for_deck(...)` 稳定返回
`deep_runtime_disabled`，需要 AI 的路径由 Challenge AI 接管。旧 ONNX、checkpoint、sidecar 和
`ai_models_runtime.json` 仅作为历史/迁移输入保留；常规 0.4.0 冒烟不要求它们完成推理。

## 为什么不能直接启用旧模型

本轮改变了开局先后攻、首回合抽牌、再战奖励、暗置信息、伤害顺序、同时昏厥、逐张奖赏卡、
平局和多种卡牌选择语义。即使 action schema 和神经网络输入尺寸没有增加，旧模型训练时看到的
状态转移和奖励含义也不同。只修改 sidecar 版本号不能证明行为兼容。

## 重新启用的最低门禁

每个牌组至少需要：

- 使用当前规则源码重新训练，或完成足以证明迁移安全的同 seed、同牌组、同先后攻配对评估；
- PT 可实际加载，checkpoint/schema/deck metadata 与 sidecar 一致，SHA-256 匹配；
- 至少 600 局迁移评估，invalid action、非法 choice、规则异常和决策超时为零；
- 开局选择、暗置信息、`DRAW` 奖励和所有新增 choice 都有合法确定响应，训练/评估不得读取
  对手暗置宝可梦或奖赏卡 ID；
- ONNX 普通输入和空卡槽输入均通过 PyTorch parity，输出无 NaN/Inf；
- Windows 与原生 ARM64 Android 都完成真实 load+infer，不能用 x86_64 模拟器 ARM 转译代替；
- 10 套牌组必须作为同一个带 journal/backup 的事务提升，不能部分启用。

通过后才允许同时更新模型 sidecar、runtime manifest 和根 manifest，并把
`deep_runtime_enabled` 改为 `true`、`compatible_model_count` 改为实际完整模型数。任何一套缺少
证据都应保持 Challenge 回退。

## 历史工具链

模型候选仍写入 `build/ai_training/`，不得手工复制到发布目录。训练环境使用
`python/environment.yml`，CPU ONNX 导出使用 `python/environment-export.yml` 或
`tools/setup_ai_toolchain.ps1`。当前可执行只读检查：

```powershell
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -B .\python\scripts\verify_dl_environment.py
.\tools\setup_ai_toolchain.ps1
.\tools\export_onnx_models.ps1 -Check
.\tools\test_godot_ai.ps1
```

`-RequireDeepRuntime` 只应在产生并准备提升一套当前规则兼容的新模型后使用，不属于 0.4.0
发布基线。正式提升仍必须使用项目现有 staging、哈希校验、持久 journal、rollback 与原生设备
验证流程，不能直接覆盖 live artifact。

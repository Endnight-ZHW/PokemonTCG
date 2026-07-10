# Deep AI v10/v3 当前发布流程

## 当前合同

发布集合由 `release_manifest.json` 定义，共 10 个 checkpoint v10 / encoder v3 模型。
运行时采用 FP32 ONNX、opset 17、ONNX Runtime 1.26.0、MCTS64 和 2 秒 watchdog。

正式导出环境固定为 Python 3.11.15、NumPy 1.26.4、Torch 2.4.1、ONNX 1.22.0、
ONNX Runtime 1.26.0。GPU 训练使用 `python/environment.yml`，CPU 导出使用
`python/environment-export.yml` 或 `tools/setup_ai_toolchain.ps1`。

## 模型门禁

每个牌组必须满足：

- PT 可实际加载，checkpoint/schema/deck metadata 正确；
- sidecar 的 SHA-256 与 PT 一致，且 sidecar metadata 与 checkpoint 内嵌 metadata 完全一致；
- 至少 600 局同牌组、同 seed、同先后手分布的配对评估；
- invalid action、missing target、规则异常和决策超时均为零；
- paired point rate 不低于固定非劣界，长局耗尽率不劣于对应 Challenge 基线；
- 启用 choice head 时必须存在真实 choice 训练样本；
- ONNX 对普通和全空卡槽输入均通过 PyTorch parity，且输出无 NaN/Inf。

规则修复后的 Python rules v3 不允许直接给旧模型改 metadata。先对现有模型逐一运行
600 局配对重评；通过者才由门禁工具迁移，失败牌组重新训练。根 manifest 在整套模型
完成前继续如实记录已发布的 Python rules/action v2。

## 唯一提升路径

```text
候选 PT + sidecar
  → 10 模型 checkpoint/哈希/metadata 预检
  → 统一 staging 导出 FP32 ONNX
  → 普通与空 mask parity + finite 检查
  → Windows/Android 原生 load+infer smoke
  → 一次性提升 PT、sidecar、ONNX 与 runtime manifest
```

常用命令：

```powershell
.\tools\setup_ai_toolchain.ps1
.\tools\export_onnx_models.ps1 -Check
.\tools\test_godot_ai.ps1 -RequireDeepRuntime
.\tools\smoke_godot_build.ps1
```

模型重训与重新门禁产生的 candidate、rejected、日志和中间 checkpoint 只写入
`build/ai_training/`，不得手工复制到发布目录。

## 尚未冒充完成的迁移项

- Python rules v3 与 10 个模型的逐牌组 600 局重评尚未执行；在真实证据产生前，
  release manifest 会继续记录已发布模型的 rules/action v2。
- 规则轨迹已升级到 fixture v2，可比较 state、revision、choice sequence、pending
  continuation 摘要和 xorshift32 RNG；将语义场景扩展到每个 effect/op 仍是后续工作。
- Python Pygame 的网络入口和发布打包已经移除，但旧 v2 适配器源码要在 canonical
  serializer 从 UI 拆出后再物理删除，避免把调试快照测试一起误删。
- `main.gd`、`battle_table.gd`、Challenge AI、`game_screen.py` 与 `training.py` 的进一步
  拆分应在现有合同测试保护下分批完成，不与规则 schema/模型迁移混为一次提交。

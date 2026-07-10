# Deep AI v10/v3 当前发布流程

## 当前合同

发布集合由 `release_manifest.json` 定义，共 10 个 checkpoint v10 / encoder v3 模型。
运行时采用 FP32 ONNX、opset 17、ONNX Runtime 1.26.0、MCTS64 和 2 秒 watchdog。

正式导出环境固定为 Python 3.11.15、NumPy 1.26.4、Torch 2.4.1、ONNX 1.22.0、
ONNX Runtime 1.26.0。GPU 训练使用 `python/environment.yml` 和独立的
`python/requirements-ai-gpu.lock.txt`（Torch 2.4.1 + CUDA 11.8），CPU 导出使用
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
600 局配对重评；通过者才由门禁工具迁移。当前决定是不重新训练模型，因此任一牌组
未通过时会停止整套 v3 提升并继续发布 v2 模型，不会用训练或手改 metadata 绕过门禁。
根 manifest 在整套模型完成前继续如实记录已发布的 Python rules/action v2。

## 唯一提升路径

```text
候选 PT + sidecar
  → 10 模型 checkpoint/哈希/metadata 预检
  → 统一 staging 导出 FP32 ONNX
  → 普通与空 mask parity + finite 检查
  → Windows/Android 原生 load+infer smoke
  → 一次性提升 PT、sidecar、ONNX 与 runtime manifest
```

`train_deep_ai_v10.ps1 -ExportOnnx` 只写入
`build/ai_training/v10_v3/release_staging/`，不会提前覆盖 Godot live ONNX。
`-Promote` 会把候选 PT/sidecar 与 staged ONNX/runtime manifest 复制到同一个持久事务的
`prepared/` 下，再次校验完整牌组集合、PT 与 runtime manifest 的 checkpoint 哈希、ONNX
大小/哈希和 manifest 路径。全部通过后，31 个发布文件（10 PT、10 sidecar、10 ONNX、
1 runtime manifest）才作为一个带 journal/backup 的 pending transaction 安装。

pending transaction 上运行 Godot/Deep runtime 回归，并生成 Windows 与 Android debug
导出后执行 `smoke_godot_build.ps1`：Windows 必须真实 load+infer 全部发布模型，Android
必须校验正式/专用 smoke APK 的模型与原生 payload。validation-only 在没有设备时可跳过
真机步骤；真正 `-Promote` 会强制要求原生 ARM64 设备并完成 infer，没有设备即 rollback，
不会 commit。上述门禁全部通过才删除备份并 commit。
普通校验或复制失败会自动恢复上一完整发布。进程/机器中断时，持久 journal 保留每个
文件的 staged、target 与 backup 状态；下次 `-Promote` 会先 rollback 未完成事务，也可手动执行：

```powershell
conda run -n DL python -B .\python\scripts\promote_ai_models.py `
  --rollback `
  --transaction-root .\build\ai_training\v10_v3\promotion_transaction
```

commit 会在清理 backup 前先持久记录 `phase=committed`。因此即使清理到一半时中断，
恢复也只会继续清理，不会把残余旧文件恢复到已经提交的新 bundle 中。

Godot 的派生 `ai_models.json` 仅在核心四类 artifact commit 后刷新，不参与或打破上述
PT/sidecar/ONNX/runtime manifest 原子边界。

常用命令：

```powershell
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -B .\python\scripts\verify_dl_environment.py
conda run -n DL python -B .\python\scripts\evaluate_rules_migration.py `
  --deck all --games 600 --device cuda --workers 12
conda run -n DL python -B .\python\scripts\stage_rules_migration.py
.\tools\setup_ai_toolchain.ps1
.\tools\export_onnx_models.ps1 -Check
.\tools\test_godot_ai.ps1 -RequireDeepRuntime
.\tools\smoke_godot_build.ps1
.\tools\test_release.ps1 -RequireAndroidDevice -AllowAndroidCleanInstall
```

该严格模式只接受原生 `arm64-v8a` 设备；x86_64 模拟器的 ARM 转译不会计为
Android 模型推理通过。发布 APK 与专用 smoke APK 的原生库、10 个 ONNX 和运行时
manifest 必须逐文件同哈希，后者仅额外内置一次性的 phase 6 启动参数。

`evaluate_rules_migration.py` 只生成带模型哈希、规则源码指纹、固定环境版本和逐局
paired points 的证据，不修改发布文件。`stage_rules_migration.py` 要求 10 套牌组各有
至少 600 局合格证据后才会一次性生成候选 PT/sidecar；缺一套或 smoke 证据都会拒绝。
评估默认启用 `--resume`，只有模型、规则源码、环境、seed、MCTS 和门禁参数全部一致时
才复用已经完成的单牌组证据；任一身份字段变化都会重新评估该牌组。

模型重训与重新门禁产生的 candidate、rejected、日志和中间 checkpoint 只写入
`build/ai_training/`，不得手工复制到发布目录。

## 尚未冒充完成的迁移项

- Python rules v3 与 10 个模型的逐牌组 600 局重评尚未执行；在真实证据产生前，
  release manifest 会继续记录已发布模型的 rules/action v2。
- 规则轨迹已升级到 fixture v3：23 个场景、30 个逐事务检查点覆盖 9/9 公开动作，
  比较 canonical state、revision、pending、事件和 xorshift32 RNG。覆盖清单严格枚举
  77 个发布 effect、78 个注册 effect 和 80 个 VM op；真实跨实现语义轨迹已覆盖
  16/77 effect 与 16/80 op，并显式列出剩余 61/64 项。coin 语义仍保留为已知缺口：
  Godot 在动作阶段预耗 portable RNG，Python 仍暴露正反面选择，因此未将其冒充为覆盖。
- Python Pygame 的旧 v2 客户端、Lobby 和网络 UI 分支已经物理移除；规则工具仍需的
  action/choice codec 已迁移到 `engine/action_codec.py`，状态恢复统一使用 engine snapshot。
- `main.gd`、`battle_table.gd`、Challenge AI、`game_screen.py` 与 `training.py` 的进一步
  拆分应在现有合同测试保护下分批完成，不与规则 schema/模型迁移混为一次提交。

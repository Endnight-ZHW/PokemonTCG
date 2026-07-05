# Python/Pygame 版本与迁移工具

该目录包含旧版 Pygame 客户端、Python 规则引擎、AI 训练代码、测试和
Godot 数据导出工具。它继续作为迁移对照和开发环境，但不会进入 Godot
Windows/Android 发布包。

## 运行旧客户端

从仓库根目录执行：

```powershell
python -m pip install -r .\python\requirements.txt
python .\python\main.py
```

也可以进入目录运行：

```powershell
Set-Location .\python
python main.py
```

## AI 训练环境

```powershell
conda env create -f .\python\environment.yml
conda env update -n DL -f .\python\environment.yml
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -B .\python\scripts\train_deep_ai.py --help
```

仅使用 pip 时：

```powershell
python -m pip install -r .\python\requirements.txt
python -m pip install -r .\python\requirements-ai.txt
```

正式部署模型位于 `data/ai_models/`。训练产生的 candidate、rejected、
进度日志和临时检查点默认不提交 Git。

Deep AI 当前默认训练器是 `alpha_zero_rl`。它可以训练任一已导出的卡组；正式
league gate 需要同卡组已有 verified checkpoint 作为对手。从已有 checkpoint
warm start 后，训练使用神经网络 + MCTS 自对弈生成 policy target，并用终局结果生成
value target；不会加载 distill 数据，也不会生成 teacher/DAgger 标签。

环境预检：

```powershell
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -c "import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0))"
conda run -n DL python -c "import onnx, onnxruntime; print(onnx.__version__, onnxruntime.__version__)"
```

GPU 长跑示例：

```powershell
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -B .\python\scripts\train_deep_ai.py `
  --trainer alpha_zero_rl `
  --deck fire `
  --games 800 `
  --device cuda `
  --league-dir data\ai_league `
  --league-eval-games 600 `
  --min-score-rate 0.53 `
  --min-elo-delta 25 `
  --progress-jsonl build\ai_training\fire_alpha_zero.jsonl
```

默认只有自对弈训练使用 MCTS；league eval 评估部署时的 raw model policy。
确实要用 MCTS 做慢速分析时再加 `--league-use-mcts`。

极小 smoke：

```powershell
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -B .\python\scripts\train_deep_ai.py `
  --trainer alpha_zero_rl `
  --deck fire `
  --games 1 `
  --league-eval-games 0 `
  --rollout-batch-games 1 `
  --updates-per-rollout 1 `
  --mcts-simulations 1 `
  --max-steps 40 `
  --device cuda `
  --output build\ai_training\fire_alpha_zero_smoke.pt
```

保留旧 teacher/DAgger 流程时显式指定：

```powershell
conda run -n DL python -B .\python\scripts\train_deep_ai.py --trainer teacher_dagger_rl --deck fire
```

## 测试

```powershell
Set-Location .\python
..\.tools\python311\python.exe -B -m unittest discover -q
```

## Godot 数据导出

从仓库根目录执行：

```powershell
.\.tools\python311\python.exe -B .\python\scripts\export_godot_data.py --check --skip-images
.\.tools\python311\python.exe -B .\python\scripts\export_godot_data.py
.\tools\export_onnx_models.ps1
.\tools\export_onnx_models.ps1 -CondaEnv DL -Check
```

导出目标固定为仓库中的 `godot/`。

## 旧版打包与 Relay

```powershell
Set-Location .\python
python build_exe.py
python relay_server.py --host 0.0.0.0 --port 8766
```

游戏规则文档位于 [`../docs/RULES.md`](../docs/RULES.md)。

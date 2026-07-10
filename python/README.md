# Python 本地调试与训练工具链

该目录包含 Pygame 本地调试界面、Python 规则参考实现、AI 训练评估、测试、
Godot 数据/卡图导入和 protocol v3 Relay 服务端。Python 不作为发布客户端，
不提供 Lobby 或客户端联机，也不会进入 Godot Windows/Android 发布包。

## 运行本地调试界面

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

界面通过 `DebugMatchSession` 直接调用本地规则引擎，仅支持本地双人和 AI 调试。

## AI 训练与导出环境

```powershell
conda env create -f .\python\environment.yml
conda env update -n DL -f .\python\environment.yml
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -B .\python\scripts\train_deep_ai.py --help
```

`environment.yml` 是 GPU 训练锁文件；发布 ONNX 使用独立的 CPU 锁定环境：

```powershell
conda env create -f .\python\environment-export.yml
# 或创建仓库内 .tools/python311
.\tools\setup_ai_toolchain.ps1
```

仅运行 Pygame/规则测试时：

```powershell
python -m pip install -r .\python\requirements.txt
python -m pip install -r .\python\requirements-ai.txt
```

正式部署模型位于 `data/ai_models/`。训练产生的 candidate、rejected、
进度日志和临时检查点默认不提交 Git。

Deep AI 当前默认生产训练器是 `teacher_dagger_rl`。它会重新训练 v10/v3
checkpoint，并要求最终评估满足 release gate；旧 v9/v2 checkpoint 不再作为
warm start 来源。v10/v3 的强度 gate 会优先比较同卡组、同 seeds、同先后手分布的
Challenge AI paired baseline；新 metadata 会记录每局 `game_points`，优先要求
`paired_delta_point_rate >= -0.01`。固定 1% 非劣界避免通过反复更换 seed 挑选
有利样本，并且仍严于项目的通用 `deep-practical` 等价门禁。`min_point_rate=0.50`
只作为缺少 paired baseline 的旧 metadata 兜底。长局可靠性使用相同原则：无配对
基线时要求 `max_step_exhaustion_rate <= 0.05`；如果 Challenge 本身超过 5%，候选
必须不劣于 Challenge，即候选上限为 `max(0.05, challenge_exhaustion_rate)`。
`alpha_zero_rl` 保留为实验训练器，它使用神经网络 + MCTS
自对弈生成 policy target，并用终局结果生成 value target；不会加载 distill 数据，
也不会生成 teacher/DAgger 标签。

环境预检：

```powershell
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -c "import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0))"
conda run -n DL python -c "import onnx, onnxruntime; print(onnx.__version__, onnxruntime.__version__)"
```

GPU 长跑示例：

```powershell
$env:PYTHONNOUSERSITE = '1'
.\tools\train_deep_ai_v10.ps1 `
  -Decks fire `
  -Device cuda `
  -Workers 10
```

该脚本默认输出到 `build\ai_training\v10_v3\models`，不会覆盖已发布模型；每个
deck 都有独立 `*.jsonl` 和 `*.console.log`。全 10 deck 通过 gate 后可追加
`-ExportOnnx -RunGodotTests -Promote` 生成 Godot runtime artifact、跑 smoke，并在
全部检查通过后把 staged checkpoint 原子提升到 `python/data/ai_models`。`-Promote`
不能脱离前两个开关单独使用。`-RunGodotTests` 会先重建 Windows/Android 的
debug/release 原生 ONNX bridge，避免测试仍加载旧 DLL/SO；发布流程还会启用
`-RequireDeepRuntime`，任何 Deep 用例跳过都会失败。
当前默认预算使用 `quality` teacher、`MaxSteps=160`、`BootstrapGames=1000`、
`DaggerGames=1000`、`BootstrapEpochs=20`、`MctsSimulations=64`，并关闭额外
self-play/pure-RL 阶段；这是目前 `fire` paired-baseline probe 中最稳的路线。
如需分阶段试预算，可以显式覆盖 `-Games`、`-BootstrapGames`、`-DaggerGames`、
`-PureRlGames`、`-ReplaySameDeal`、`-BootstrapEpochs`、`-TeacherSearchPreset`、
`-MaxSteps` 等参数；`-Smoke` 会走极小链路，只验证脚本。当前 `fire` 诊断显示
Python/Godot Deep neural-MCTS 的 heuristic prior 温度均为 80，并对神经 prior
加 guard，只允许它在不推翻清晰启发式选择时做小幅 nudging。
候选评估默认启用 production-shaped neural-MCTS，可用 `--no-eval-use-mcts`
只跑 raw policy 诊断。

如果训练已经完成、只需要从 `pre_eval` 或现有 checkpoint 续跑候选评估，可以复用
同一次运行已完成的 Challenge 基线。脚本会校验 deck、seed、局数、步数、teacher
preset 和逐局 points，参数不一致时会直接拒绝复用：

```powershell
conda run -n DL python -B .\python\scripts\train_deep_ai.py `
  --trainer teacher_dagger_rl `
  --deck steel --seed 29 `
  --model .\python\data\ai_models\resume_steel.pt `
  --output .\build\ai_training\v10_v3\models\steel.pt `
  --games 0 --bootstrap-games 0 --dagger-games 0 --eval-games 600 `
  --pure-rl-games 0 --replay-same-deal 0 `
  --device cuda --workers 10 --max-steps 160 --mcts-simulations 64 `
  --teacher-search-preset quality `
  --reuse-challenge-baseline-progress .\build\ai_training\v10_v3\steel_seed29.jsonl `
  --reuse-challenge-baseline-seed 29 `
  --progress-jsonl .\build\ai_training\v10_v3\steel_seed29_release_reval.jsonl
```

`--reuse-challenge-baseline-seed` 只用于旧 JSONL（旧事件没有记录 seed）；新运行会在
`run_started` 和 baseline 事件中记录 `seed`/`eval_seed`，不需要人工断言。恢复入口
还会从同一已校验 JSONL 自动恢复旧 `pre_eval` checkpoint 缺失的 choice 训练样本数。

实验性 AlphaZero 路线需要显式指定 `--trainer alpha_zero_rl`。默认只有自对弈训练
使用 MCTS；league eval 评估部署时的 raw model policy。确实要用 MCTS 做慢速分析时
再加 `--league-use-mcts`。

极小 smoke：

```powershell
$env:PYTHONNOUSERSITE = '1'
conda run -n DL python -B .\python\scripts\train_deep_ai.py `
  --trainer teacher_dagger_rl `
  --deck fire `
  --games 0 `
  --bootstrap-games 0 `
  --dagger-games 0 `
  --eval-games 0 `
  --rollout-batch-games 1 `
  --updates-per-rollout 1 `
  --max-steps 40 `
  --device cuda `
  --output build\ai_training\fire_teacher_dagger_smoke.pt
```

实验性 AlphaZero smoke：

```powershell
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

## Relay 服务端

```powershell
.\.tools\python311\python.exe .\python\relay_server.py --host 0.0.0.0 --port 8766
```

Relay 仅接受 Godot protocol v3 控制消息和游戏帧；旧 Python v2 客户端协议及
PyInstaller 发布入口不再维护。

游戏规则文档位于 [`../docs/RULES.md`](../docs/RULES.md)。

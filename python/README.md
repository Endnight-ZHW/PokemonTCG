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
conda activate DL
python .\python\scripts\train_deep_ai.py --help
```

仅使用 pip 时：

```powershell
python -m pip install -r .\python\requirements.txt
python -m pip install -r .\python\requirements-ai.txt
```

正式部署模型位于 `data/ai_models/`。训练产生的 candidate、rejected、
进度日志和临时检查点默认不提交 Git。

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
```

导出目标固定为仓库中的 `godot/`。

## 旧版打包与 Relay

```powershell
Set-Location .\python
python build_exe.py
python relay_server.py --host 0.0.0.0 --port 8766
```

游戏规则文档位于 [`../docs/RULES.md`](../docs/RULES.md)。

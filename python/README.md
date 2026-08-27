# Python 作者工具与 Relay

`python/` 不包含游戏客户端、Challenge 策略或 Deep 训练运行时。这里仅保留：

- 按属性组织的单一 `card_data/cards` 卡牌定义；
- Card IR、VM 描述符、Godot 数据和资源哈希导出；
- Action/Choice/Snapshot DTO 与本地作者工具；
- Protocol v6 WebSocket Relay 服务。

安装与检查：

```powershell
python -m pip install -r .\python\requirements.txt
python -B .\python\scripts\card_author.py lint
python -B .\python\scripts\export_godot_data.py --check
.\tools\test_python.ps1 -Tier full
```

导出器 CLI 保持稳定，内部职责分别位于
`scripts/godot_export/card_data.py`、`resources.py` 和 `contracts.py`。
卡图只从 `godot/assets/cards/<card-id>.webp` 读取，不在 Python 目录保存副本。

启动 Relay：

```powershell
python -B .\python\relay_server.py --host 0.0.0.0 --port 8766
```

Deep AI 的模型、replay、actor、learner、ONNX 导出与依赖已隔离到
[`../research/deep_ai`](../research/deep_ai)。

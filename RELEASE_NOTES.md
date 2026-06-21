# PokemonTCG Godot 0.2.0

## 系统要求

- Windows 10/11 x86_64。
- Android 9 或更高版本，仅支持 ARM64，固定横屏。
- Challenge AI 与 Deep AI 可完全离线运行。
- LAN 使用 ENet；Relay 支持 `ws://` 与 `wss://`，协议版本为 v3。

## 已实现

- 本地双人、Challenge AI、Deep AI。
- 8 套发布牌组与 8 个 FP32 ONNX 模型。
- Windows/Android 原生 ONNX Runtime CPU 推理。
- ENet LAN 与 WebSocket Relay 房主权威联机。
- 音量、静音、减少动画和卡图缓存设置。
- Android 后台时取消 AI 搜索；联机对局会安全断开并在恢复时提示。

## 已知限制

- 不支持旧 Pygame 协议 v2 客户端。
- 首版不支持房主迁移；房主断线会结束对局。
- 短时重连仅具备重新同步基础，不承诺断开后的房间保留。
- 当前 Android 包内置全部模型，安装包体积较大。
- 使用 `test` 签名生成的 APK 仅供设备验收，不能作为商店正式发布包。

## 完整性

发布目录中的 `SHA256SUMS.json` 记录 Windows ZIP、Android APK、PCK、原生库和 8 个 ONNX 模型的 SHA-256。

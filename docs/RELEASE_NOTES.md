# PokemonTCG Godot 0.8.0

0.8.0 保持本地双人、Challenge、LAN、Relay Protocol 6、Action 4、ChoiceView 2、
Snapshot 3、Journal 1 与 RNG 2 的玩法和 wire shape 不变，同时把产品 Python 业务迁移到
Godot/C++。

## 内容与运行时

- `native/ptcg_core` 仍是唯一权威规则核心，并新增无框架依赖的内容编译器。
- 137 张卡、10 套牌、160 个效果和 80 个 VM 描述符的唯一作者源迁到
  `godot/authoring`；`tools/content.ps1` 统一 lint、test、export 和 stale check。
- Card IR 升级为 `ptcg_card_ir/4`，source map 使用作者文件路径与 JSON Pointer；语义和
  作者位置分别使用 SHA-256 `content_fingerprint` / `source_fingerprint`。
- `NativeContentCompiler` 通过 GDExtension 暴露结构化诊断和内容契约。
- Challenge 的 109 个战术场景由 C++ 直接读取严格 JSON，不再生成 Python 二进制夹具。

## Relay 与 Python 边界

- 新增 Boost.Beast 1.92.0 + nlohmann/json 3.12.0 的异步 C++ Relay；房间注册表由 Asio
  strand 串行化，并保留房间恢复、限流、大小/深度限制和明确拒绝 Protocol 5 的行为。
- Relay 提供 `/healthz`、单行 JSON 日志、可信代理地址和有界发送队列；公网 TLS 由
  Caddy/Nginx 终止。
- Windows x86_64 ZIP 与 Linux x86_64 tar.gz 独立发布，不进入 Windows/Android 客户端包。
- 根 `python/` 和产品 Python requirements 已删除。产品构建只用固定 SCons；
  `research/deep_ai` 保留自己的 Python 环境，并直接读取 `godot/data`。

## 版本与验证

- 产品版本为 0.8.0，Android `versionCode=9`。
- 内容编译测试覆盖 schema、未知 VM op、非法分支、牌组数量、策略引用、source pointer、
  确定性输出及 fingerprint 范围。
- Relay 测试覆盖严格 JSON、v5 拒绝、并发加入、断线恢复、限流、可信代理、IPv4/IPv6，
  Godot 回归继续完成 LAN 与真实 Relay 整局。
- 100 房间/200 连接基准未丢失合法帧；同机相同客户端下 C++ Relay 的 60 msg/s 突发吞吐
  为 Python 基线的 4.14 倍，持续和突发 p95 均改善，满足性能门禁。原始结果见
  `artifacts/relay_protocol_v6_benchmark.json`。
- Deep AI research smoke 在不加入根 Python 路径的环境中通过。

发布前执行：

```powershell
.\tools\test_fast.ps1
.\tools\test_standard.ps1
.\tools\test_godot_ai.ps1
.\tools\package_release.ps1 -AndroidSigning test
.\tools\package_relay.ps1
.\tools\test_release.ps1
```

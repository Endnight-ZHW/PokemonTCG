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
- 验证状态：Python 产品栈迁移后的新 `main` 尚待完整
  `workflow_dispatch`（fast、standard、relay-linux、release）重新验证；在该运行全绿前，
  0.8.0 视为发布候选而非已验证发布版本。
- 内容编译测试覆盖 schema、未知 VM op、非法分支、牌组数量、策略引用、source pointer、
  确定性输出及 fingerprint 范围。
- Relay 测试覆盖严格 JSON、v5 拒绝、并发加入、断线恢复、限流、可信代理、IPv4/IPv6，
  Godot 回归继续完成 LAN 与真实 Relay 整局。
- Relay 可通过 `tools/benchmark_relay.ps1` 重测；历史比较结果见 Git 历史。
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

## 2026-09-15 项目精简

- 删除旧研究编码器、旧事件别名和无调用方法；动画偏好仅保存 `animation_mode`。
- 表现事件在进入队列时统一整理并过滤玩家可见性，预取、手牌过渡和播放复用结果。
- 卡图预取不再反复序列化玩家状态；批次复用独立渲染副本，共享卡牌目录不再保留重复数据。
- 历史报告和无引用截图从当前目录移除，现行维护说明集中于开发指南、规则及研究说明。
- 客户端导出排除作者源与开发内容，构建和发布检查处理旧运行库与临时残留。
- 当前内容指纹保持 `f49ee62425b37e4c0a23c08f888499d3741a8db41753be64746382023355cf9a`。

### 本地回归与性能

Windows / Godot 4.7 Compatibility / NVIDIA GeForce RTX 4070 Ti：

- fast、standard、10 套牌 Challenge 对局、LAN／Relay 完整对局、三维图形与 UI 预览通过。
- 研究 smoke 共 93 项测试通过，覆盖回放、训练步骤、ONNX 一致性与原生 AI 控制器。
- Windows 发布客户端启动、目录与 ZIP 检查通过；Android ARM64 APK 的结构、签名与发布校验和通过。
- 两组各三轮交替 CPU 测量中，动画准备（事件整理与暖缓存卡图预取）的 P95 中位数
  从 460 μs 降至 191 μs，约减少 58%；探针内存占用减少 2,186,415 字节（约 2.1 MiB）。
- 其他 CPU 项未观察到稳定的性能变化。帧率受档位上限控制，不将删除文件数量换算为帧率提升。
- 1920×1080 实际渲染各档三轮、每轮预热后采样 300 帧：高／中／低档 P95 中位数分别为
  16.953 / 17.044 / 34.241 ms，所有样本满足 20 / 20 / 36 ms 预算。
- 当前未连接 Android 设备；真机触控、持续帧率和温升不在这些桌面结果中。

原始测量、验证日志与本地产物清理统计保存在 `build/cleanup-20260915/`。
GitHub Actions 的跨平台完整发布流程仍须按上文执行，本地结果不代替该流程。

# PokemonTCG Godot 0.9.1

- 修正 C++ 参数求值顺序导致招式学习器进化、戴鲁比附能搜寻上限变成 0 的问题。
- 为退化、道具到期弃置、非昏厥离场及备战缩减补齐准确的场地区域与附件动画来源；道具进化和附能使用对应的落地表现。
- 修正退化后昏厥的对象识别与卡面过渡；撤退等操作一旦提交，先播放已完成动作，再交由对手处理后续选择。
- 卡组编辑原地更新数量，保留滚动和控件身份；加入分类、缩略图与印刷编号、空结果提示和可点击的完整构筑检查。
- 从选牌页编辑当前浏览卡组，返回时保留双方选择及对战规则；卡组变成非法草稿或被删除时禁止开局。
- 首次保存即建立恢复备份；过长草稿明确拒绝生成无法导入的分享码。规则指纹已更新，Android `versionCode=11`。

审核详情见 [0.9.1 多角度审核与修复](REVIEW_0_9_1.md)。已通过 45 项 Godot 契约、117 个 AI 战术场景、
17 场 AI 完整对战、16 场 LAN／Relay 对局，以及 28 个实际渲染动画场景和四种尺寸的编辑器交互检查。
Android 真机运行、软键盘和真实触控尚未验证。

## 0.9.0 历史记录

- 新增“我的卡组”：搜索与多条件筛选、复制预设／自定义、改名、删除、草稿恢复和 `PTCG1:` 分享码。
- 自定义构筑使用 60 张休闲规则，原生校验同名上限和基础宝可梦；合法卡组可用于本地、Challenge AI、LAN 和 Relay。
- 新增“黑晶炽诚”CSV5C 001–164，卡池从 177 扩充到 341，预设保持 14 套。全部卡图、来源及转录修正均有审核记录。
- 补齐进化触发、道具招式、退化、动态备战上限、卡比兽娃娃、区域限制、效果防护与隐藏信息查看等规则。
- 联机升级 Protocol 7；卡表在开局冻结，恢复校验摘要。公开视图不传播自定义卡表、名称、ID 或代表卡。
- AI 仍只使用预设。面对自定义对手时，从去重的公开卡池推演未知牌，保留已公开信息并遵守构筑限制。
- 修正 Windows 原生绑定的异常处理构建配置，无效卡牌定义返回错误而非导致客户端崩溃。
- Android `versionCode=10`；Action 4、ChoiceView 2、Snapshot 3、Journal 1 和 RNG 2 保持原结构。

### 0.9.0 本地验证（2026-10-10）

- `test_fast.ps1` 通过：内容、原生规则、117 个 Challenge 战术场景、搜索状态／预算及 Relay 协议检查。
- `test_standard.ps1` 通过：42 项 Godot 契约及 16 场 LAN／Relay 完整对局，包含自定义对预设、
  自定义对自定义与自定义镜像；非法卡表、指纹不一致、重连换牌和隐藏信息隔离另有契约覆盖。
- `test_godot_ai.ps1` 通过：14 套预设回归及 3 场预设 AI 对抗新卡自定义卡组，共 17 场完整对战。
- `csv5_rules_contract.gd` 覆盖 214 个印刷招式场景、主动特性和训练家，并验证被动效果、条件不满足、
  道具招式、退化、备战缩减、娃娃、进化／附能触发顺序与效果防护。卡图审核覆盖全部 341 张。
- `test_frontend_club_graphics.ps1 -SkipPerformance` 通过。编辑器在 1600×900、900×540、1280×800
  实际渲染，检查中文搜索、48 像素触控目标、滚动、卡图边界和未保存返回提示；其余前台与战斗返回也通过。
- 卡组契约覆盖 59／60／61 张、同名异画、基本能量例外、异常数量、未知牌草稿、重启、损坏备份恢复及分享往返。
- 验证环境：Windows x86_64、Godot 4.7 Compatibility、NVIDIA GeForce RTX 4070 Ti。
  Windows／Android 的 debug、release 原生库均已编译。双平台 debug 导出与 `smoke_godot_build.ps1`
  通过，包含 Windows 启动、原生 AI、Protocol 7，以及 Android APK 元数据、签名和 ARM64 载荷检查。
  未连接 Android 设备，真机运行、软键盘和真实触控仍需设备验收（`ANDROID_RUNTIME_SKIPPED`）。
- `package_release.ps1 -AndroidSigning test` 与 `test_release.ps1` 通过：0.9.0 Windows ZIP、Android
  测试签名 APK、原生运行时及 5 项文件校验和均已验证。Relay Windows 0.9.0 包的协议元数据为 7。

## 0.8.0 历史记录

0.8.0 保持本地双人、Challenge、LAN、Relay Protocol 6、Action 4、ChoiceView 2、
Snapshot 3、Journal 1 与 RNG 2 的玩法和 wire shape 不变，同时把产品 Python 业务迁移到
Godot/C++。

## 内容与运行时

- 加入嗨皮组合第4弹的狙射树枭、美录梅塔ex、故勒顿、密勒顿ex四套60张预设，
  新增27张宝可梦与13张训练家，复用同效果的现有卡牌。古代／未来筛选、分配附能、
  洗混查看卡后置底、攻击费用、道具与回收效果均在原生规则核心结算。
- 每套新增专用 Challenge 策略；新增卡组逐套覆盖 LAN、Relay 同卡组完整对局。
  `happy4_contract.gd` 验证固定清单、真实卡牌结算、私有选择恢复和非法响应回滚；
  `happy4_visual_contract.gd` 生成桌面和紧凑尺寸的选组与选择弹窗验收图。
- 第4弹版本依据[官方商品介绍](https://www.pokemon.cn/tcg/product/21022.html)核对；全部
  177 张新旧卡统一从[简中卡牌资料集](https://github.com/duanxr/PTCG-CHS-Datasets)的固定提交
  导入印刷元数据及无损 WebP 卡图。`card_source_manifest.json` 记录每张卡的精确版本及原图
  SHA-256，`tools/sync_card_sources.ps1` 统一导入与校验；本地路径由编译器生成。
- `native/ptcg_core` 仍是唯一权威规则核心，并新增无框架依赖的内容编译器。
- 177 张卡、14 套牌、218 个效果和 80 个 VM 描述符的唯一作者源位于
  `godot/authoring`；`tools/content.ps1` 统一 lint、test、export 和 stale check。
- Card IR 升级为 `ptcg_card_ir/4`，source map 使用作者文件路径与 JSON Pointer；语义和
  作者位置分别使用 SHA-256 `content_fingerprint` / `source_fingerprint`。
- `NativeContentCompiler` 通过 GDExtension 暴露结构化诊断和内容契约。
- Challenge 的 117 个战术场景由 C++ 直接读取严格 JSON，不再生成 Python 二进制夹具。
- 跨版本 AI 对比按声明的参赛牌组加载完整卡牌规则，避免冻结旧版因无关新卡的 VM 参数而失败；
  双方与裁判使用相同输入，并记录实际输入和原始发布数据的哈希。

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

## 2026-09-28 战斗按钮交互

- 保留三维牌桌与奶油暖色风格，取消拖放出牌，统一通过选卡、操作按钮和合法目标完成卡牌动作。
- 顶部任务条持续提示赋能、放置、进化、奖励卡领取、昏厥替补及复杂效果选择；等待动画、对手或网络同步时显示对应原因。
- 可使用卡、选中来源及合法目标分别使用绿色、焦糖色和青绿色轮廓；低画质与减少动画模式使用静态高亮。
- 攻击与撤退增加确认，目标选择支持返回操作和取消；非法点击保留当前步骤，过期操作和重复提交受局面版本与权限检查保护。
- 同步帮助文案、Workbench 预览和交互契约，覆盖横竖屏、手牌滑动、长按详情、连续奖励卡及双方同时昏厥。
- Godot 功能回归、三维图形功能检查及 LAN／Relay 整局回归通过。2026-09-28 在 Windows／Godot 4.7 Compatibility／RTX 4070 Ti 上，以 1920×1080、双方各 20 张手牌、每档 300 帧实测，高／中／低画质 P95 为 17.018／16.987／33.607 ms，满足 20／20／36 ms 预算。
- Android 设备上的触屏、持续帧率和温升仍需真机验证；桌面性能结果不代表 Android 性能。

# PokemonTCG Godot 4.7 迁移实施报告

> 仓库于 2026-06-23 完成双版本目录整理：当前 Godot 客户端位于
> `godot/`，Python/Pygame 对照实现、AI 训练和数据导出环境位于
> `python/`，共享构建脚本位于 `tools/`。本报告中的历史产物记录保留原有
> 阶段语义，但路径已统一更新为当前仓库结构。

## 1. 最终目标

将当前 Python + Pygame 客户端迁移为 Godot 4.7 原生客户端，并交付：

- Windows x86_64 便携 ZIP。
- Android 9+、ARM64、固定横屏 APK，包名 `com.pokemontcg.game`。
- 无网络时可运行本地双人、Challenge AI 和 Deep AI。
- Windows 与 Android 可通过 LAN 或 WebSocket Relay 联机。
- 发布包不包含 Python、PyTorch、AI 训练脚本和卡图下载管理工作台。

Python 项目继续作为规则对照、AI 训练和模型导出环境，不作为发布版运行时。

## 2. 审核结论与修订

原方案不能直接执行，原因如下：

- 本地 Python 服务无法满足 Android 离线运行。
- 仓库已经具备统一的 `GameEngine`、`GameAction`、`ChoiceRequest`、`ChoiceResponse`、`StepResult` 和协议 v2，不需要重复建设 `engine_service`。
- Python `ActionRequest.callback` 是闭包，不能跨存档、跨网络或在 GDScript 中复现，Godot 规则内核必须使用显式、可序列化的结算栈。
- Deep AI 的 `.pt` 文件依赖 PyTorch，发布版改为 FP32 ONNX，并由 C++ GDExtension 封装 ONNX Runtime。
- 新客户端采用协议 v3，不与旧 Pygame 客户端互联。

迁移基线：

| 项目 | 基线 |
|---|---:|
| 注册卡牌 | 115 |
| 预组卡组 | 8 套，每套 60 张 |
| 数据中出现的效果类型 | 72 |
| Python 测试 | 233 通过，8 跳过 |
| 卡图 | 116 个，约 16.35 MB |
| 已部署 Deep AI 模型 | 8 个 |

## 3. 目标架构

```text
Godot 4.7 Client
├─ GDScript UI / input / animation / audio
├─ GDScript authoritative rules engine
├─ Serializable ResolutionStack / EffectFrame
├─ GDScript Challenge AI and planner
├─ C++ GDExtension
│  └─ ONNX Runtime Deep AI inference
├─ ENet LAN transport
└─ WebSocket Relay transport

Python Tooling (not shipped)
├─ Current rules engine and regression tests
├─ Golden fixture generator
├─ Card/deck/effect exporter
├─ Challenge/Deep AI training
└─ PyTorch -> ONNX exporter and parity verifier
```

核心接口在 Godot 中保持与 Python 相同的语义：

```text
GameEngine.legal_actions(state, actor)
GameEngine.apply_action(state, action, rng)
GameEngine.apply_choice(state, request, response, rng)
```

## 4. 阶段状态

| 阶段 | 状态 | 完成标准 |
|---|---|---|
| 0. 构建基线 | 完成 | Godot 工程可启动，Win/Android 导出配置可验证 |
| 1. 数据与差异框架 | 完成 | 115 张卡和 8 套牌组导入，黄金数据测试通过 |
| 2. 原生规则引擎 | 完成 | 全部发布效果和对局流程与 Python 对齐 |
| 3. 离线客户端 | 完成 | UI 自动完整对局、Win 启动和 Android ARM64 导出通过；真机发布复核列入阶段 6 |
| 4. 两种离线 AI | 完成 | Challenge/Deep AI 均可在 Windows 与 Android 离线完整对局 |
| 5. LAN/Relay 联机 | 实现完成，待跨设备验收 | ENet/Relay 完整对局通过；Win↔Android 与 Android↔Android 待真机矩阵 |
| 6. 发布收尾 | 实现完成，待 Android 验收 | 0.2.0 Win ZIP、测试签名 ARM64 APK、校验清单与发布测试通过 |
| 7. 视觉现代化 | 实现完成，待 Android 性能验收 | 0.3.0 实体牌桌、真实卡图、表现事件、动画、分层音频和视觉回归通过 |
| 8. 视觉与 Android 稳定性修复 | 实现完成，待更多真机复核 | 0.3.1 修复 AudioTrack 崩溃、卡牌内操作、牌区重排和卡牌移动动画 |
| 9. Godot 可视化创作环境 | 完成 | 主要页面、组件、牌桌、弹窗、主题和固定动画可在编辑器中直接维护，并提供 Workbench 与中文开发手册 |

## 5. 阶段记录

### 阶段 0：构建基线

开始日期：2026-06-20

计划内容：

- 创建 `godot/` Godot 4.7 Compatibility 工程。
- 创建 Windows x86_64 和 Android ARM64 导出预设。
- 固定 Android 9+、横屏、包名 `com.pokemontcg.game`。
- 创建无第三方依赖的 headless 测试入口。
- 创建便携式 Godot/JDK/Android SDK 工具链安装和构建脚本。
- 验证现有 Python 测试，确保迁移起点无回归。

已完成内容：

- 迁移方案已从“Godot + 本地 Python 服务”修订为 Godot 原生规则运行时。
- 已确认当前 Python 测试基线：233 通过，8 跳过。
- 已确认开发机缺少 Godot、Android SDK/ADB、JDK 17 和 .NET SDK；本项目使用标准版 Godot/GDScript，不依赖 .NET。
- 已创建 Godot 4.7 Compatibility 工程、主场景、应用状态 Autoload 和应用图标。
- 已创建 Windows x86_64 与 Android Gradle ARM64 导出预设。
- 已实现便携工具链脚本，安装 Godot 4.7、导出模板、Temurin JDK 17、Android SDK 35、Build Tools 35、Platform Tools 和 NDK 28.1。
- 已实现 Godot headless 测试脚本和统一 Windows/Android 构建脚本。
- 已成功生成 Windows 调试可执行文件与 Android ARM64 调试 APK。

接口变化：

- 新增 `AppState` Autoload，定义客户端版本以及规则、动作和协议 schema v3。
- Android 包名固定为 `com.pokemontcg.game`。
- Android Gradle 配置固定 `minSdk=28`、`targetSdk=35`、仅 `arm64-v8a`。

测试结果：

- `python -B -m unittest discover -q`：通过。
- `tools/test_godot.ps1`：`GODOT_TESTS_OK phase=0`。
- APK 清单检查：`minSdkVersion=28`、`targetSdkVersion=35`、`native-code=arm64-v8a`。

生成产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `godot/dist/windows/PokemonTCG.exe` | 102,915,072 B | `B1B700323D4E3812D644A2F0F2972A542D15AB930D925E5D0C53E749017C66E6` |
| `godot/dist/android/PokemonTCG.apk` | 83,986,908 B | `1B17A9B4ACE57A3F59E8A3EBE87423A7896C89B9DB47BD9B4E151CB907E077CA` |

风险与遗留：

- 当前 APK 已完成构建和清单检查，但尚未在真实 Android 设备启动验证。
- 正式签名密钥不提交仓库；阶段 6 由环境变量或本地密钥路径注入。
- 当前构建只有迁移启动页，功能代码从阶段 1 开始接入。

完成日期：2026-06-20

阶段结论：完成。

### 阶段 1：数据与差异测试框架

开始日期：2026-06-20

计划内容：

- 从 Python 权威数据自动导出卡牌、效果、牌组、图片映射和 AI 模型清单。
- 导出与 Python `blake2b` 算法一致的稳定卡牌 bucket。
- 在 Godot 中实现数据加载器、动作/选择契约、基础状态、随机源和快照结构。
- 生成固定种子的 Python 黄金 fixture，并在 Godot headless 测试中验证。

已完成内容：

- 新增 `python/scripts/export_godot_data.py`，从 Python 权威数据生成：
  - `cards.json`
  - `effects.json`
  - `decks.json`
  - `card_images.json`
  - `card_buckets.json`
  - `ai_models.json`
  - `data_contract.json` 黄金 fixture
- 导出器只遍历 115 张发布卡牌，不受测试中临时注册卡牌污染。
- 导出器支持 `--check`，可在 CI 中检测提交的生成数据是否过期。
- 已复制 115 张卡图和卡背到 Godot 资源目录。
- 已导出 8 个已部署 Deep AI 检查点的大小、SHA-256、schema 和目标 ONNX 路径。
- 已实现与 Python 编码器一致的稳定 card bucket 映射。
- 已实现 Godot 数据库 Autoload。
- 已实现 Godot 基础契约和状态类型：
  - `EntityRef`
  - `GameAction`
  - `ChoiceRequest`
  - `ChoiceResponse`
  - `StepResult`
  - `PokemonState`
  - `PlayerState`
  - `GameState`
  - `GameEventStream`
- 已实现可跨平台复现的 `xorshift32` 随机源和黄金序列。
- 已实现动作、选择和状态快照的序列化往返测试。

接口与数据格式变化：

- Godot 数据文件由 Python 单向生成，Godot 端禁止手工维护卡牌规则数据。
- 发布数据 schema 使用 Godot rules/action v3；Python 对照引擎当前仍为 v2。
- card bucket 通过生成映射读取，避免不同语言哈希实现不一致。

测试结果：

- `python -B python/scripts/export_godot_data.py --check`：通过。
- Python 新增 2 个导出测试；完整测试现为 235 通过，8 跳过。
- Godot headless：`GODOT_TESTS_OK phase=1`。
- 验证内容包括 115 张卡、8 套 60 张牌组、72 类效果、全部卡图存在、8 个模型清单、稳定随机序列及序列化往返。
- Windows 与 Android 导出在加入完整卡图和 JSON 后再次成功。

生成产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `godot/dist/windows/PokemonTCG.exe` | 102,966,784 B | `1FE9B182F09DDFB4A77B9EAE6D7DD93313511F0C3F5B2279187FB1A6C9088756` |
| `godot/dist/android/PokemonTCG.apk` | 101,832,600 B | `B71E587D55D5AEC6D9BA540D7CEF676EC135EBE8FD810E381701236EE08D7453` |

风险与遗留：

- 当前黄金 fixture 覆盖数据、哈希、随机源和基础序列化；规则动作差异 fixture 在阶段 2 扩展。
- Godot 导入卡图后 APK 已约 97 MB，阶段 6 需要重新评估纹理压缩和发布包体。

完成日期：2026-06-20

阶段结论：完成。

### 阶段 2：Godot 原生规则引擎

开始日期：2026-06-20

计划内容：

- 迁移 setup、回合、合法动作、伤害、状态、进化、撤退和胜负。
- 建立 `ResolutionStack/EffectFrame`，禁止使用不可序列化回调。
- 迁移 72 类效果并为每类建立覆盖。
- 实现按玩家视角的隐藏信息序列化。
- 扩展 Python 黄金动作 fixture 和 Godot 差异测试。

已完成内容：

- 新增原生 `GameEngine`，统一提供：
  - `legal_actions(state, actor, validate_effects)`
  - `apply_action(state, action, rng)`
  - `apply_choice(state, request, response, rng)`
  - `setup_game(state, deck_one, deck_two, rng)`
- 已迁移准备阶段、再战、先后攻、奖品设置、抽牌、主要阶段、攻击后自动结束回合、宝可梦检查、晋升和胜负判定。
- 已迁移基础宝可梦上场、进化、通常附能、训练家卡、特性、竞技场、撤退、攻击、特殊状态、击倒和奖品处理。
- 已实现动作前快照和失败回滚；重复 `action_id`、过期实体引用、重复选择、越权玩家和过期选择均会被拒绝。
- 已实现 `ResolutionStack`：
  - 效果帧、续执行帧、上下文和待处理选择均可序列化。
  - 支持嵌套选择、硬币结果、能量分配、能量转移、可取消训练家动作及攻击完成续执行。
  - 攻击基础伤害只会在全部效果与选择链完成后执行一次。
- 已实现 72 类发布效果的原生分派和真实数据样例覆盖。
- 已实现双重涡轮能量、喷射能量、夜光能量、奇迹能量、学习装置、伤害增减道具、压迫感和团结一致等被动规则。
- 已实现按玩家视角的隐藏信息序列化：
  - 仅自己的手牌身份可见。
  - 双方牌库和奖品仅暴露数量。
  - 对手手牌仅暴露数量。
- 已增加 Python 生成的 `rules_golden.json`，Godot 会重放基础上场/附能/攻击、双重涡轮撤退和进化脚本，并比较规范化最终状态。
- 已增加 8 套发布牌组的轮转自动对局；每套牌组均能通过原生规则完成一局并产生胜者。
- 已确认 115 张发布卡牌全部至少出现在一套发布牌组中。

接口与状态格式变化：

- `GameState` 新增 `setup_ready` 和最近 256 个 `processed_action_ids`。
- `resolution_stack` 新增可序列化 `context`，用于保存攻击收尾、穿透标记和可取消动作快照。
- `StateSerializer.for_player` 不再向任何客户端发送牌库顺序或奖品身份。
- 类型相克仅在 `apply_type_matchups=true` 时启用，与 Python 当前默认行为一致。
- 选择生成统一使用稳定 option ID；能量分配和能量转移允许按能量逐张选择目标。

测试结果：

- `python -B python/scripts/export_godot_data.py --check --skip-images`：通过。
- Python 完整测试：235 通过，8 跳过。
- Godot headless：`GODOT_TESTS_OK phase=2`。
- Godot 阶段 2 覆盖：
  - 72/72 类效果使用发布数据中的真实样例执行。
  - 所有生成的嵌套选择链均可完成，且不存在未知效果或未知续执行操作。
  - 3 个 Python→Godot 黄金动作脚本最终状态一致。
  - 8 套牌组分别参与完整自动对局并在 1200 个动作上限内结束。
  - 隐藏信息、动作去重、动作回滚、取消恢复、自我击倒奖品和晋升队列通过。
- Windows 调试导出：通过。
- Android ARM64 调试导出：通过；清单仍为包名 `com.pokemontcg.game`、`minSdk=28`、`targetSdk=35`、仅 `arm64-v8a`。

生成产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `godot/dist/windows/PokemonTCG.exe` | 102,966,784 B | `1FE9B182F09DDFB4A77B9EAE6D7DD93313511F0C3F5B2279187FB1A6C9088756` |
| `godot/dist/windows/PokemonTCG.pck` | 18,203,268 B | `4A89B2B44F46D069F3A085A9533412D8AE7C72514040F62433E0C05DD9320A10` |
| `godot/dist/android/PokemonTCG.apk` | 101,947,137 B | `EC6FBE7ACAF5635D0FD9F9C3BF6E2EE7486B3BAFFDDEB8D7B718FD4E8A8DD9B3` |

风险与遗留：

- Python 规则仍是对照实现；后续修改卡牌语义时必须同步更新黄金 fixture 并运行 Godot 阶段 2 测试。
- 阶段 2 的自动选择策略用于规则回归，不代表 Challenge AI 的决策质量。
- Android APK 已构建和检查清单，但真机触控与生命周期测试属于阶段 3 和阶段 6。

完成日期：2026-06-20

阶段结论：完成。

### 阶段 3：离线客户端与触控 UI

开始日期：2026-06-20

计划内容：

- 实现标题、模式选择、牌组选择、本地双人、棋盘、结束界面。
- 实现卡牌区域、动作面板、卡牌详情和统一选择 Overlay。
- Android 固定横屏，适配 16:9、20:9、安全区、触控和返回键。
- 接入阶段 2 原生 `GameEngine`，完成一局无需 Python 的本地双人对战。

已完成内容：

- 已实现标题页、模式入口、双玩家牌组选择、本地双人对局和结束界面。
- 牌组选择会从生成数据中读取全部 8 套发布牌组；Challenge AI 和 Deep AI 入口已保留并明确标记为阶段 4 功能，当前不会伪装为可用。
- 已实现本地热座隐私交接 Overlay：
  - 切换玩家、准备阶段和晋升时使用全屏不透明遮挡。
  - 用户确认前不展示下一位玩家手牌。
- 已实现横屏棋盘界面：
  - 双方战斗区和备战区。
  - 当前玩家手牌、牌库数、奖品数和对手隐藏信息摘要。
  - 可执行动作列表、动作过滤、对局日志和卡牌详情区。
  - 卡图、卡名、伤害、状态、附着能量和道具信息展示。
- 所有规则操作均通过 `GameAction`、`GameEngine.apply_action` 和 `GameEngine.apply_choice` 执行；UI 不直接修改规则状态。
- 已实现统一选择 Overlay，覆盖单选、多选、可重复选择、能量分配、硬币结果、取消和嵌套选择链。
- 完整 UI 对局测试发现并修复两处关键问题：
  - 某些多段效果只把待选择请求写入 `ResolutionStack` 时，UI 现在会从可序列化结算栈恢复请求。
  - 确认选择前会复制 option ID，避免关闭 Overlay 时清空选择并向引擎提交空响应。
- 已实现卡牌点击选择和详情查看；全部核心操作可仅通过点击完成，桌面端不依赖拖拽。
- 已实现 Android 返回键：对局中打开菜单，其余页面返回上一级或退出。
- 已实现显示安全区边距、横屏布局和 16:9、20:9 自适应。
- 核心按钮最小高度为 48 px，满足触控目标要求。
- 已实现基础页面过渡、弹窗 Tween、点击音和成功提示音；音频在运行时生成，不增加外部音频依赖。
- 已增加 UI 截图回归工具，可生成标题、牌组、隐私交接、16:9 棋盘和 20:9 棋盘截图。
- Windows 和 Android 导出包已排除 `tests/`、`tools/` 和候选模型。

接口与配置变化：

- `main.gd` 作为离线客户端 UI 状态机，提供标题、牌组、游戏和结束四类界面状态。
- 新增 `start_local_match_for_test(first_key, second_key)`，用于确定性 UI 集成测试。
- `_execute_action` 返回 `StepResult`，便于调用端和测试验证动作结果。
- 新增从 `StepResult` 或 `ResolutionStack` 读取待处理选择的兼容路径。
- 新增 `GameUITheme` 和 `UISound`，统一主题、触控尺寸和基础反馈。
- `project.godot` 启用保持屏幕常亮以及鼠标/触控输入模拟。
- Android 继续固定横屏、Android 9+ 和 `arm64-v8a`。

测试结果：

- `python -B python/scripts/export_godot_data.py --check --skip-images`：通过。
- Python 完整测试：235 通过，8 跳过。
- Godot headless：`GODOT_TESTS_OK phase=3`。
- 阶段 3 Godot 测试覆盖：
  - 标题和本地双人入口。
  - 两名玩家各 8 套牌组。
  - 48 px 最小触控目标。
  - 热座隐私遮挡、棋盘、手牌、动作区和统一选择 Overlay。
  - 通过 UI 控制器执行准备、普通动作、多段选择、回合交接、晋升和结束界面，自动完成一局本地双人对局。
- UI 截图回归：`UI_PREVIEWS_OK`；16:9、20:9 和隐私交接截图人工复核通过。
- Windows 导出启动冒烟测试：`WINDOWS_STARTUP_OK`。
- Android APK 元数据检查：`ANDROID_APK_METADATA_OK`。
- APK 信息：
  - 包名：`com.pokemontcg.game`
  - `minSdkVersion=28`
  - `targetSdkVersion=35`
  - ABI：仅 `arm64-v8a`
  - `screenOrientation=0`：Android 横屏
- 当前无 ADB 设备，故本次结果为 `ANDROID_DEVICE_SKIPPED no connected ADB device`。
- 尝试安装 Android Emulator 和 ARM64 system image 时，SDK 源清单下载失败；未以不可用的模拟器结果替代真机结论。

生成产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `godot/dist/windows/PokemonTCG.exe` | 102,966,784 B | `1FE9B182F09DDFB4A77B9EAE6D7DD93313511F0C3F5B2279187FB1A6C9088756` |
| `godot/dist/windows/PokemonTCG.pck` | 18,177,844 B | `6B4B8FCE8F132498738240DB0DB51F984036ED839A1EF060D90889964BD6178B` |
| `godot/dist/windows/PokemonTCG.console.exe` | 101,888 B | `932F700EC1C9CE40408F8A7D3B3B98514AE4406DC3B0469F5124C2C1B0691DCF` |
| `godot/dist/android/PokemonTCG.apk` | 101,958,114 B | `E3E6C2936479851BAE500E0750F5F5DD8C32193E80A8F67DB09160B1D5636001` |

提交记录：

- 工作基线提交：`9cf099f425c97aed2150673ba83e43897ecd346d`。
- 阶段 0–3 的代码、测试和文档作为同一组迁移交付提交。
- 具体提交 ID 以包含本记录的 Git 历史为准，避免在提交内容中写入无法自引用的提交哈希。

风险与遗留：

- Android APK 已成功构建且包名、SDK 和 ABI 正确，但没有可用的 Android ARM64 真机或模拟器，尚未执行安装、启动、真实触控、安全区和系统返回键验证。
- 阶段 3 标记完成的依据是跨平台代码、完整 UI 自动对局、响应式渲染、Windows 启动和 Android 构建验证；Android 真机验收不得从最终发布标准中删除，必须在阶段 6 完成。
- 当前动画和音效属于基础反馈，完整表现、资源缓存和性能优化属于阶段 6。
- 当前只开放本地双人；两种离线 AI 和联网入口必须等待对应阶段完成。

完成日期：2026-06-21

阶段结论：完成。按用户要求在此阶段停止，不进入阶段 4。

### 阶段 4：Challenge AI 与 Deep AI

开始日期：2026-06-21

已完成内容：

- 将工具链统一锁定在 `tools/toolchain.lock.json`，并安装到项目内 `.tools/`，不修改系统 `PATH`：
  - Godot 4.7 stable 与导出模板。
  - Temurin 17.0.19+10。
  - Android SDK 35、Build Tools 35.0.1、NDK 28.1.13356709。
  - Gradle 8.11.1、Python 3.11、SCons 4.10.1。
  - PyTorch 2.4.1 CPU、ONNX 1.22.0、ONNX Runtime 1.26.0。
- 所有直接下载的归档均由锁文件提供 SHA-256 或上游 SHA-1；Godot、Android、AI 与原生依赖脚本不再使用动态 `latest` 版本。
- 固定 `godot-cpp` 提交 `5ffd70e34d0ab87009a9f0ffa3361bc8f4b09731`，使用现有 Visual C++ Build Tools 构建 Windows x86_64 与 Android ARM64 GDExtension。
- 新增原生 Challenge AI：
  - 公开信息 Observation 与隐藏信息确定化。
  - 8 套牌组配置、动作评分、选择评分和可取消搜索。
  - 快速 64 次/0.5 秒、标准 256 次/1.5 秒、困难 768 次/4 秒，默认标准。
- 新增专用 AI 协调线程。请求携带状态快照、actor、revision、request ID、模式、难度、牌组和 seed；主线程只接受序列化结果，并在应用前校验 revision/request ID。
- Challenge AI 与 Deep AI 菜单已开放，支持双方牌组、难度和先后手选择；人类固定为玩家 1，AI 固定为玩家 2，AI 手牌不会显示给人类。
- 从 8 个已批准检查点导出 opset 17 FP32 ONNX。每个模型同时输出 `action_logits`、`state_value` 与 `choice_logits`，支持动态动作/选择候选数量。
- 新增 `OnnxInference` GDExtension，提供模型加载/卸载、SHA-256 与尺寸校验、批量候选推理、错误信息、运行耗时、Runtime 版本和 Provider 查询。
- ONNX Runtime 仅启用 `CPUExecutionProvider`。模型通过 Godot `FileAccess` 从 PCK/APK 读取到内存；一次只加载当前 AI 牌组模型。
- 新增 Python rules/action v2 → Godot v3 的显式兼容桥。模型不会仅因 Godot schema 版本为 v3 而被错误拒绝。
- Deep AI 固定 256 次模拟与 8 秒看门狗。模型缺失、SHA/版本错误、推理失败、运行时不可用或零次有效模拟时，会回退标准 Challenge AI 并返回明确原因。
- 暂停、应用切后台、退出对局、返回标题和节点销毁均会取消并等待搜索线程；退出对局和返回标题同时卸载模型。
- 发布预设显式包含 8 个 ONNX 模型、ONNX Runtime 许可证与 NOTICE，并排除测试、工具和候选模型。

接口与数据契约：

- 新增 `ai_models_runtime.json`，记录 checkpoint/ONNX SHA-256、opset、尺寸、输入输出名、ONNX Runtime 版本、Provider 和兼容桥版本。
- 编码契约固定为状态数值 960、卡槽 96、动作/选择 178、card bucket 4096。
- Python 现有编码器对已知卡牌实际生成 53 个语义特征，而旧的缺失卡牌分支仍生成 48 个；模型训练已包含此历史行为，因此 Godot 兼容编码器明确保留该差异并用黄金 fixture 锁定。
- `start_local_match_for_test` 与 AI 测试入口支持固定 seed，消除 UI 完整对局测试的随机波动。

测试结果：

- 项目内 Python 3.11 环境完整测试：235 通过，1 跳过；原先 8 个跳过项中的可选 AI 依赖测试已因工具链安装而启用。
- `python/scripts/export_godot_data.py --check --skip-images`：通过。
- `tools/export_onnx_models.ps1 -Check`：8 个模型均为最新且 PyTorch/ONNX 对齐通过；三类输出全局最大绝对误差 `2.86102294921875e-06`，低于 `1e-4`。
- Godot headless 阶段 0–4 测试通过，覆盖 Python/Godot Observation、card bucket、960/96/178 编码逐项一致，以及 8 个模型的加载和原生推理。
- 固定 seed 的 Challenge AI 决策可复现；后台协调线程会让出调用线程并支持取消。
- 错误 SHA-256 会被原生加载器拒绝；Deep AI 动作和选择均验证运行时不可用回退。
- 16 场完整 AI 回归通过：8 套牌组分别以 Challenge AI 和 Deep AI 完成对局，共执行 1,662 个动作、126 个选择和 606 次 AI 决策，无非法动作、重复 ID 或过期选择；桌面总耗时约 117.3 秒。
- Windows 与 Android debug 导出通过。Windows 发布包从 PCK 成功加载模型并报告 `CPUExecutionProvider / ONNX Runtime 1.26.0`。
- APK 元数据通过：包名 `com.pokemontcg.game`、`minSdk=28`、`targetSdk=35`、仅 `arm64-v8a`；APK 内确认包含 8 个 ONNX 模型、`libpokemon_ai` 与 `libonnxruntime.so`。
- 自动化构建时没有连接 ADB 真机，结果为 `ANDROID_DEVICE_SKIPPED no connected ADB device`。
- 2026-06-21 用户已在 Android ARM64 真机手动安装并测试当前 APK，确认启动、横屏、触控与两种 AI 的基本表现和电脑端一致，未发现阻断问题。

生成产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `godot/dist/windows/PokemonTCG.exe` | 102,966,784 B | `1FE9B182F09DDFB4A77B9EAE6D7DD93313511F0C3F5B2279187FB1A6C9088756` |
| `godot/dist/windows/PokemonTCG.pck` | 62,708,936 B | `C7A200720146DC21DF9A205736BA878697DED8CC087DBB9EA70C1AA67DE479DE` |
| `godot/dist/windows/PokemonTCG.console.exe` | 101,888 B | `932F700EC1C9CE40408F8A7D3B3B98514AE4406DC3B0469F5124C2C1B0691DCF` |
| `godot/dist/android/PokemonTCG.apk` | 170,506,276 B | `8C03F1928B83F3F2DA155522E4599F7976484A9D50B1BEFF69119AB02B14438F` |

原生产物校验：

| 产物 | SHA-256 |
|---|---|
| Windows debug `libpokemon_ai` | `054CCEFBF5D6072B57BDD15D9FB30B780459B49734B0159B2DF7930E22C6F158` |
| Windows `onnxruntime.dll` | `B2BA7CA16E0E4FE71AD5148744AB885A2F5809E52A0C3DE4D9BA3853A03977F9` |
| Android debug `libpokemon_ai` | `7E6975B81D90788C1A5BD21E6192EB7858B042F02FF1E8C4F9C89DB8DDF85A26` |
| Android `libonnxruntime.so` | `9F8E49B209CBAC4483C96E5FC82F0405747F39C0708FB673561CBB019DB0C0BC` |

提交与边界：

- 工作基线提交：`d64fb58eb7a11dfe1272968c8c2e44d216d3c0c2`。
- 本轮没有重新训练模型，也没有进入 LAN/Relay 联网阶段。
- 现有模型的对局步数耗尽率继续作为质量风险记录；本阶段只验证部署、兼容性和合法决策，不宣称模型强度提升。
- 8 个 FP32 模型和两套原生运行库使 debug APK 增长到约 162.6 MiB；纹理、模型与符号裁剪属于阶段 6。
- Android 真机结果来自用户手工验收；逐模型自动化性能采样和生命周期压力测试仍保留到阶段 6，不再阻塞阶段 4。

完成日期：2026-06-21。

阶段结论：完成。

### 阶段 5：LAN 与 WebSocket Relay 联机

开始日期：2026-06-21

已完成内容：

- 新增 Godot 协议 v3 envelope，固定包含：
  - `protocol_version`
  - `message_type`
  - `room_id`
  - `sender`
  - `sequence`
  - `state_revision`
  - `action_id`
  - `request_id`
  - `payload`
- 新增统一 `NetTransport` 接口及两种实现：
  - `EnetTransport`：LAN 房主/加入，可靠有序点对点传输。
  - `WebSocketRelayTransport`：支持 `ws://` 与 `wss://` Relay、创建房间和房间码加入。
- 新增 `AuthoritativeSession`：
  - 房主持有完整 `GameState`、随机源、规则引擎和结算栈。
  - 挑战者只提交动作或选择响应，不能提交状态或随机结果。
  - 房主验证玩家身份、sequence、revision、action ID、request ID 和规则合法性。
  - 支持投降、重新同步、连接超时和对手断线终止。
- 新增 `NetworkMatchController`，统一 LAN/Relay 的大厅握手、牌组交换、房间号、状态广播、心跳和错误处理。
- Godot 标题页已开放“局域网联机”和“Relay 联机”：
  - 支持创建或加入房间。
  - 双方分别选择 8 套发布牌组。
  - LAN 支持地址与端口；Relay 支持 URL 与房间码。
  - 联机客户端只使用房主发送的合法动作与选择，不在过滤后的状态上自行运行权威规则。
- 按玩家视角同步状态：
  - 自己手牌身份可见。
  - 对手手牌只发送数量。
  - 双方牌库和奖品只发送数量。
  - 只有当前选择玩家收到选择候选。
  - 只有当前行动玩家收到合法动作候选。
- Relay 服务端继续保持透明转发，不运行规则；在保留旧 Python v2 测试兼容的同时支持 Godot v3，并增加：
  - 房间与 sender 身份校验。
  - 256 KiB 消息上限。
  - 每连接每秒 60 条消息限制。
  - 未知 v3 消息和伪造身份拒绝。

协议攻击与恢复：

- 重复或回退 sequence：拒绝。
- 跳跃 sequence：拒绝。
- 过期 revision：拒绝并发送当前权威状态。
- 错误 action ID/request ID：拒绝。
- 非当前连接身份动作：拒绝。
- 未知消息类型或客户端直接写状态：拒绝。
- 超大 payload：在传输层或协议层拒绝。
- 客户端提交动作后在收到新 revision 前会锁定重复提交，避免延迟链路下的旧状态重放。
- 15 秒空闲发送心跳，45 秒无接收视为连接超时。

测试结果：

- Godot headless：`GODOT_TESTS_OK phase=5`。
- 协议 v3 单元测试覆盖版本、字段类型、房间、sender、sequence、revision、action ID、request ID、未知消息和大小限制。
- ENet 实际套接字握手、协议包发送和房主状态广播通过。
- LAN 完整自动对局：35 回合、151 个动作、30 个选择、181 个 revision，正常产生胜者。
- 本地 WebSocket Relay 完整自动对局：35 回合、151 个动作、30 个选择、181 个 revision，正常产生胜者。
- 两种完整对局的每次状态同步都检查隐藏信息，未发现对手手牌、任何牌库顺序或奖品身份泄漏。
- Python Relay v2/v3 测试：8 项通过；v3 透明转发和伪造 sender 拒绝通过。
- 项目内 Python 3.11 完整测试：236 通过，1 跳过。
- Windows/Android debug 导出通过；为包含 8 个 ONNX 模型的大资产 APK 固定 Gradle 为 8 GB 堆、单 worker，避免资产压缩阶段内存溢出。
- 导出冒烟通过：
  - `WINDOWS_STARTUP_OK`
  - `WINDOWS_DEEP_AI_OK provider=CPUExecutionProvider runtime=1.26.0`
  - `WINDOWS_NETWORK_OK protocol=3 transports=enet,websocket`
  - `ANDROID_APK_METADATA_OK`
  - `ANDROID_AI_ASSETS_OK models=8 abi=arm64-v8a`
- 本轮自动化环境没有连接 ADB 设备，因此新版联网 APK 仍为 `ANDROID_DEVICE_SKIPPED no connected ADB device`。

生成产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `godot/dist/windows/PokemonTCG.exe` | 102,966,784 B | `1FE9B182F09DDFB4A77B9EAE6D7DD93313511F0C3F5B2279187FB1A6C9088756` |
| `godot/dist/windows/PokemonTCG.pck` | 62,736,788 B | `03BF7F057558C4F3408F882FD62E8C66E06EDB8D1FDF53A5A4C1411224008F73` |
| `godot/dist/windows/PokemonTCG.console.exe` | 101,888 B | `932F700EC1C9CE40408F8A7D3B3B98514AE4406DC3B0469F5124C2C1B0691DCF` |
| `godot/dist/android/PokemonTCG.apk` | 170,534,650 B | `2E52A3D915CA3C0B3A23A808B1501AC006787F033260989DBB4DE4F03B7185E4` |

接口与文件：

- `godot/network/protocol_v3.gd`
- `godot/network/net_transport.gd`
- `godot/network/enet_transport.gd`
- `godot/network/websocket_relay_transport.gd`
- `godot/network/authoritative_session.gd`
- `godot/network/network_match_controller.gd`
- `tools/test_godot_network.ps1`

风险与遗留：

- 当前自动化在同一台 Windows 主机上使用两个真实网络端点完成 Win↔Win LAN/Relay 对局。
- 仍需用户在真实设备上完成 Win↔Android、Android↔Android 的 LAN 与 Relay 六种组合验收。
- 当前 Relay 验收使用本机 `ws://127.0.0.1`；正式公网 `wss://` 需要用户提供 TLS Relay 地址或反向代理环境。
- 首版不做房主迁移；房主断线时对局终止并明确返回标题。
- 短时重连只提供显式 `resync_request` 基础，不承诺断开连接后的会话保留；完整重连产品规则仍待锁定。

完成日期：待跨设备和公网 Relay 验收。

阶段结论：实现完成，待跨设备验收。

### 阶段 6：发布与收尾

开始日期：2026-06-21

已完成内容：

- 客户端版本升级为 `0.2.0`，Windows 文件版本与 Android `versionCode=2`、`versionName=0.2.0` 同步。
- 新增持久化运行时设置：
  - 主音量与静音。
  - 减少界面动画。
  - 12/24/48 张卡图缓存上限。
  - 最近使用的 Relay URL。
  - 设置写入应用私有目录 `user://settings.cfg`。
- 新增受控卡图 LRU 缓存；查看卡牌详情不再无限保留卡图引用，Android 收到系统内存警告时会主动清空缓存。
- 新增 Deep AI 模型加载遮罩；模型损坏或加载失败时继续保留既有 Challenge AI 回退提示。
- 完善 Android 生命周期：
  - AI 思考期间进入后台会取消搜索，恢复后按当前 revision 重新调度。
  - 联机期间进入后台会安全关闭传输；恢复后返回标题并明确提示，避免后台超时后继续使用过期状态。
  - 退出场景继续回收 AI、模型和网络对象。
- 新增 `tools/package_release.ps1`：
  - 构建 Windows x86_64 与 Android ARM64 release 原生库。
  - 生成 Godot release 导出。
  - 生成 Windows 便携 ZIP。
  - 附带 ONNX Runtime 许可证、第三方 NOTICE、发布说明和构建信息。
  - 对 ZIP、APK、PCK、原生库和 8 个 ONNX 模型生成 SHA-256 清单。
- Android 签名支持两种模式：
  - `test`：在 `.tools/signing/` 生成稳定的本地测试密钥，仅用于真机验收。
  - `production`：通过 `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`、`GODOT_ANDROID_KEYSTORE_RELEASE_USER`、`GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD` 注入正式签名，不把密钥或密码写入仓库。
- 新增 `tools/test_release.ps1`，自动验证：
  - Windows release 运行时冒烟。
  - ZIP 必需文件和开发内容排除。
  - Android 包名、版本、SDK、ABI。
  - APK v2 签名。
  - 8 个 ONNX 模型和 Android release 原生库。
  - 14 项发布校验值。
- release 导出显式排除 `dist/` 和生成的 Android Gradle 目录，避免旧校验清单或旧产物回灌进新的 PCK/APK。
- 新增 `RELEASE_NOTES.md` 和 `ANDROID_TEST_CHECKLIST.md`，后者覆盖安装升级、设置持久化、离线模式、生命周期、长局和跨设备联机矩阵。
- Android release APK 为包含全部模型和原生库的大资产包；Gradle 固定 8 GB 堆、单 worker，release APK 相比 debug APK 减少约 6.2 MB。

测试与性能：

- 项目内 Python 3.11：236 通过，1 跳过。
- Godot 数据导出检查：无漂移。
- 8 个 ONNX 模型：当前且 PyTorch/ONNX 对齐通过。
- Godot headless：`GODOT_TESTS_OK phase=6`。
- LAN/Relay 真实本机端点完整对局继续通过：
  - 两种传输均为 35 回合、151 个动作、30 个选择、181 个 revision。
- 16 场 AI 完整回归通过：
  - Challenge AI 8 场、Deep AI 8 场。
  - 无非法动作、过期选择或非预期 Deep AI 回退。
  - 总耗时 116,690 ms。
  - Godot 静态内存由 27,456,062 B 增至 29,165,530 B，峰值 47,818,121 B。
- Windows release 冒烟：
  - `PHASE6_EXPORT_RELEASE_OK version=0.2.0 settings=1 cache=1 licenses=1`
- Windows ZIP 内容裁剪通过，不包含 Python、PyTorch、测试、开发工具或 console wrapper。
- Android release 验证：
  - 包名 `com.pokemontcg.game`。
  - `versionCode=2`、`versionName=0.2.0`。
  - `minSdk=28`、`targetSdk=35`、仅 `arm64-v8a`。
  - APK Signature Scheme v2 验证通过。
  - 测试签名证书 SHA-256：`BC7864354DB28FC45C65AAEF8F1478BB5B7DE2CD2B2DB34C07BD769EB4EFF79C`。
  - 8 个模型、`libpokemon_ai.android.template_release.arm64.so` 与 `libonnxruntime.so` 均存在。

生成产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `PokemonTCG-Windows-x86_64-0.2.0.zip` | 103,432,202 B | `7E55AD36520E3BC6B6B25F95CAA7E44B5048A4B20AF78BA785654BAC7A8FFF7F` |
| Windows release `PokemonTCG.exe` | 109,071,360 B | `92DA874B0E3CBC7ED39D141734B0F91386F097FA98638C9AA6332BE2DD8A076C` |
| Windows release `PokemonTCG.pck` | 62,745,732 B | `870C0FFA826B7B2200C36C6F6B3F16CC7023BE8C9EE024E4F9F85243D1A2A3E1` |
| Windows release `libpokemon_ai` | 367,104 B | `DA07EA3BE1D8F3023CDE0754338BF5C568AE2BCB1292DD74860AC47151806C46` |
| Windows `onnxruntime.dll` | 14,897,976 B | `B2BA7CA16E0E4FE71AD5148744AB885A2F5809E52A0C3DE4D9BA3853A03977F9` |
| `PokemonTCG-Android-arm64-0.2.0-test.apk` | 164,367,293 B | `6350D63ED9E872124E71075337E1A004C067D228836EDEE9734B316E925219D0` |

风险与遗留：

- 当前 APK 使用本机测试签名，只用于用户 Android 验收；正式发布仍需注入用户持有的 production keystore 后重新生成 APK。
- Android 真机的安装升级、锁屏/切后台、音频焦点、低内存、温度、耗电和连续多局测试由用户执行，结果未自动推定为通过。
- 阶段 5 的 Win↔Android、Android↔Android LAN/Relay 与公网 `wss://` 矩阵仍依赖真实设备和 Relay 环境。
- 当前卡图已经使用平台纹理导入且 release 包裁剪了调试原生库；8 个 FP32 模型本身约 42.0 MiB，是进一步缩小 APK 的主要边界，本轮不通过量化改变已验收模型。

完成日期：待 Android 真机验收和正式签名。

阶段结论：实现完成，待用户 Android 验收。

### 阶段 7：Godot 视觉现代化

开始日期：2026-06-22

已完成内容：

- 客户端版本升级为 `0.3.0`，Windows 文件版本与 Android `versionCode=3`、`versionName=0.3.0` 同步。
- 将战斗界面重构为可复用场景组件：
  - `CardView` 负责真实卡图、卡背、HP、伤害、能量、状态和可操作提示。
  - `ZoneView` 负责战斗区、五个备战位、牌库、弃牌区、奖品区、竞技场和手牌区域。
  - `BattleScreen` 负责现代实体牌桌、响应式手牌、阶段 HUD、上下文命令、详情和折叠日志。
  - `EffectLayer` 与 `PresentationDirector` 独立负责动画和粒子，不再把表现逻辑混入规则引擎。
- 标题、牌组选择、隐私交接、复杂选择和胜利页面完成视觉重制；牌组和选择界面直接显示卡图。
- 建立统一设计令牌，规范字体层级、间距、圆角、阴影、属性色、状态色和触控尺寸。
- 建立规范化 `PresentationEvent`，覆盖抽牌、上场、进化、训练家、附能、道具、竞技场、攻击、伤害、治疗、状态、换位、击倒、奖品和洗牌。
- `PresentationDirector` 按事件序列播放弧线移动、落桌、冲击、浮动数字、闪光、震动和粒子，并在队列积压时压缩非关键演出。
- 本地、Challenge AI、Deep AI、LAN 和 Relay 共用同一表现入口；联机状态更新继续使用协议 v3，可选携带 `presentation_events`。
- 房主按观察者视角过滤表现事件；对手抽牌、奖品和隐藏选择只保留数量与卡背语义，不发送卡牌身份。
- 重连/全量同步会清空旧演出队列并直接提交最新视图，避免重放过期事件。
- 新增点击选择、合法目标高亮、约 350 ms 长按详情和约 14 px 拖拽阈值；点击与拖拽共用同一套合法动作解析。
- 新增电影化、标准、快速和减少动画四种演出模式；减少动画模式以短淡入和文字反馈替代大幅移动、震动和强闪光。
- 新增 Master、Music、SFX、UI 四条运行时 Audio Bus，以及原创程序化标题、战斗、胜利循环和主要动作音效。
- 新增自动、高、中、低画质档与 30/60 FPS 目标；桌面默认高档 60 FPS，Android 自动档根据设备能力选择。
- 固定截图预览覆盖标题、牌组、隐私交接、16:9 战斗、20:9 战斗、复杂选择、攻击、命中、击倒和结算。
- 视觉对照矩阵、资源规范和后续验收基线见 `VISUAL_UPGRADE_BASELINE.md`。

测试结果：

- 项目内 Python 3.11：236 通过，1 跳过。
- Godot 数据导出检查：无漂移。
- Godot headless：`GODOT_TESTS_OK phase=6`，新增覆盖视觉场景、表现事件过滤、动画档位、拖拽阈值和五个备战位。
- LAN 与 Relay 完整对局通过：每种传输均为 35 回合、151 个动作、30 个选择、181 个 revision。
- 16 场 AI 完整回归通过：Challenge AI 8 场、Deep AI 8 场；无非法动作、过期选择或非预期回退。
- 固定截图生成通过：`UI_PREVIEWS_OK`，共 11 张视觉基线图。
- Windows debug 导出通过，启动、Deep AI 与协议 v3 冒烟通过。
- Android ARM64 debug 导出通过，元数据为包名 `com.pokemontcg.game`、`minSdk=28`、`targetSdk=35`、`versionCode=3`、`versionName=0.3.0`。
- Windows/Android release 打包与独立发布校验通过：
  - `WINDOWS_RELEASE_RUNTIME_OK`
  - `WINDOWS_RELEASE_ZIP_OK`
  - `ANDROID_RELEASE_APK_OK signing=test models=8 abi=arm64-v8a`
  - `RELEASE_CHECKSUMS_OK entries=14`
- 动画后节点数量可恢复到测试基线；AI 回归的静态内存由 27,532,322 B 增至 29,241,790 B，未发现持续节点泄漏。

本轮调试产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| Windows debug `PokemonTCG.pck` | 62,839,048 B | `634FB6BE2DDCCCD6473B5483ABD8E314639190A600D2F25268CC6BB0EB9DD96B` |
| Android ARM64 debug `PokemonTCG.apk` | 170,636,646 B | `B39D5CC60A21540F68E708DE7134489720676730B210C36B74CDC6CCF40B20E6` |

本轮发布产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `PokemonTCG-Windows-x86_64-0.3.0.zip` | 103,519,005 B | `C94DAEC18F64A0794435E23494C42B8BCA6B3FBC570B5F1A7F1FA8760FBE1860` |
| `PokemonTCG-Android-arm64-0.3.0-test.apk` | 164,459,807 B | `78C3C04A70A64B1294F15AA673948982F7AE4A8AFE7535EBFED443044A789F1F` |
| Windows release `PokemonTCG.pck` | 62,839,048 B | `634FB6BE2DDCCCD6473B5483ABD8E314639190A600D2F25268CC6BB0EB9DD96B` |

风险与遗留：

- Windows 1600×900 High 档已按 60 FPS 目标实现，但正式性能结论仍应由 profiler 长局采样确认。
- Android 的自动分档、1080p 60 FPS、中低端 Low 档 30 FPS、温度和耗电必须在至少一台主流设备和一台中低端设备上实测，不能由桌面或 headless 结果推定。
- Godot 在 Android release 导出进程退出时报告 RID/ObjectDB 清理警告；独立包体、签名和运行时校验均通过，但后续升级 Godot 或调整导出流程时应继续观察。
- 程序化音频确保原创和许可证清晰；若后续替换为录制音乐或音效，必须在资源清单中记录来源与许可证。
- 当前视觉版本只使用既有卡图与原创抽象 UI，不新增仿制宝可梦角色插画。
- 阶段 5/6 遗留的跨设备 LAN/Relay、公网 WSS、正式签名和 Android 生命周期验收仍然有效。

完成日期：2026-06-22（实现与自动化）；Android 性能与跨设备验收待真机完成。

阶段结论：实现完成，待 Android 性能和跨设备验收。

### 阶段 8：视觉与 Android 稳定性修复

开始日期：2026-06-22

问题与根因：

- Android 版本运行数秒后退出。设备 `logcat` 复现为 `AudioTrack` 线程 `SIGSEGV`，发生时间与程序化背景音乐第一次 WAV 原生循环结束一致。
- 每次战斗视图刷新时，每张宝可梦卡都会新建 `CardCatalog` 并重新解析卡牌和牌组 JSON，造成不必要的 Android 内存与 GC 压力。
- 粒子和同时飞行卡牌没有硬上限，快速事件队列可能放大移动设备瞬时负载。
- 右侧操作列表仍承担大部分卡牌动作，牌桌被 HUD 压缩；牌库、弃牌和奖品区域过小。
- 抽牌和弃牌使用单张直线平移，缺少多卡节奏、弧线、阴影、旋转和落点反馈。

已完成修复：

- 客户端版本升级为 `0.3.1`，Android `versionCode=4`。
- 移除 `AudioStreamWAV` 原生循环点；音乐改为单次播放完成后由 `AudioStreamPlayer` 安全重播。
- Android Auto 画质默认使用 Low/30 FPS；移动端卡图缓存上限按档位限制为 12/18。
- 战斗场景共享单个 `CardCatalog`；卡牌内容使用签名跳过无变化刷新，避免重复解析 JSON 和重建状态节点。
- 粒子上限固定为 220、浮动文字上限 18、同时飞行卡牌上限 12；暂停、重连和场景切换会终止 Tween 并清理临时视觉对象。
- 表现导演加入 generation 取消令牌，旧队列在重连清空后不能与新队列并发恢复。
- 右侧默认只保留“进入下一阶段/完成准备”按钮、卡牌详情和日志；旧动作列表保持隐藏兼容。
- 训练家、攻击、特性、撤退、晋升和竞技场按钮显示在被选择的对应卡牌上；附能、进化和上场继续通过卡牌上的目标提示与高亮牌位完成。
- 牌桌 HUD 变窄，双方战斗区和五个备战位围绕中线对称重排；牌库、弃牌、奖品和竞技场放大。
- 抽牌、弃牌、奖品和击倒改为最多五张卡的错峰贝塞尔弧线，加入阴影、旋转、空中缩放、落点粒子和独立弃牌音效。
- 补齐选择弃牌和整手弃牌的 `cards_discarded` 事件，包含公开后的卡牌列表；旧式抽牌事件统一转为 owner-only 并过滤隐藏身份。

验证结果：

- Godot headless：`GODOT_TESTS_OK phase=6`。
- Python：236 通过，1 跳过。
- LAN/Relay：各 35 回合、151 动作、30 选择、181 revision，通过。
- 16 场 Challenge/Deep AI 回归通过；静态内存 27,541,360 B → 29,250,828 B，峰值 48,433,057 B。
- 视觉回归新增 `card-actions.png`、`draw.png` 和 `discard.png`，`UI_PREVIEWS_OK`。
- 自动测试覆盖共享目录、重复刷新节点稳定、220 粒子上限、12 飞行卡上限和旧抽牌事件隐藏过滤。
- Android x86_64 模拟设备通过 ARM64 翻译层复现旧版崩溃：
  - 旧版约 6 秒时在 `AudioTrack` 线程触发 `SIGSEGV`。
  - 修复后标题与战斗音乐连续循环 132 秒，进程保持存活且无 FATAL/SIGSEGV。
  - 等待前后 `TOTAL PSS` 为约 268,880 KB → 269,133 KB，没有持续增长。
- Android ARM64 debug 导出通过。
- `0.3.1` 发布校验通过：
  - `WINDOWS_RELEASE_RUNTIME_OK`
  - `WINDOWS_RELEASE_ZIP_OK`
  - `ANDROID_RELEASE_APK_OK signing=test models=8 abi=arm64-v8a`
  - `RELEASE_CHECKSUMS_OK entries=14`
- 测试签名 `0.3.1` APK 已安装到设备，确认 `versionCode=4`、`versionName=0.3.1`，启动 20 秒后仍存活且无 SIGSEGV。

发布产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `PokemonTCG-Windows-x86_64-0.3.1.zip` | 103,534,472 B | `81E0422B6A6DB5958946E3683C3EC6EE9D42F733DC7A5D52E525FA8DA19F5609` |
| `PokemonTCG-Android-arm64-0.3.1-test.apk` | 164,474,395 B | `252BC508D57DA675F86E413779A7BC604BF3F1A30546B7D031478458C72E8F68` |
| Windows release `PokemonTCG.pck` | 62,853,688 B | `5866135F5506ED9E60DAF611B7D390179A96CD4826B6EA24C698995092222344` |

风险与遗留：

- 本轮设备端稳定性验证来自 x86_64 Android 模拟设备的 ARM64 翻译环境；它足以复现并验证音频循环崩溃，但仍需要用户在原生 ARM64 真机上完成长局复核。
- 模拟设备无法加载仅 ARM64 的 Deep AI GDExtension；真机 Deep AI 验收仍按既有清单执行。
- Godot Android 导出进程退出时的 RID/ObjectDB 清理警告仍存在，但不会出现在导出后的游戏运行进程中。

阶段结论：实现完成，待原生 ARM64 Android 真机长局复核。

### 阶段 9：Godot 可视化创作环境

完成日期：2026-06-23

已完成内容：

- 将应用外壳、标题、牌组选择、网络大厅、战斗、胜利、设置、复杂选择、隐私交接和暂停内容拆为可编辑场景。
- 将 `CardView`、`ZoneView` 和战斗固定牌位从运行时节点创建迁移到 `.tscn` 场景树。
- 新增可编辑 `game_theme.tres`，并通过 Inspector 暴露牌桌尺寸、手牌间距、动画参数和卡牌交互参数。
- 为标题、牌桌、弹窗打开/关闭、卡牌选择、合法目标和胜利页加入可编辑 `AnimationPlayer` 时间轴；动态轨迹继续使用 Tween。
- 新增安全 UI Workbench 和显式固定种子的样例状态，可预览全部主要页面并触发抽牌、进化、攻击、伤害、击倒和胜利演出。
- 新增中文 Godot 开发手册，覆盖场景、UI、信号、动画、规则结算栈、AI、联机、卡牌数据导出、调试和发布，并配有场景树、Inspector、Animation、Workbench 和 Debugger 稳定截图。
- 页面统一采用 `configure(...)` 输入数据、类型化信号输出用户意图；`Main` 保留旧私有入口作为运行时兼容，并新增公开导航入口供测试与工具使用。
- 飞牌弧线、错峰时间、触控按钮高度和四档表现速度均可在 Inspector 中调整；合法目标高亮使用可编辑的 `target_pulse` 时间轴。

验证结果：

- Godot headless：`GODOT_TESTS_OK phase=6`。
- UI 截图回归：`UI_PREVIEWS_OK`，新增网络、设置和 Workbench 截图。
- 16 场 Challenge/Deep AI 回归通过。
- LAN 与 Relay 各 35 回合完整回归通过。
- Godot 生成数据 `--check --skip-images` 通过。
- Windows 与 Android 调试导出通过；Windows 启动、导出包 Deep AI、协议 v3 网络、Android APK 元数据/AI 资源和已连接 Android 设备启动冒烟全部通过。

阶段结论：完成。

## 6. 剩余任务

阶段 4 已完成；阶段 5–8 均已完成本机实现和自动化验收。剩余工作为原生 ARM64 Android 真机长局与视觉性能、跨设备联网、公网 WSS 和正式签名。

### 6.1 阶段 4：两种离线 AI（历史实施清单）

> 以下清单保留用于审计本阶段原始范围。Android 基本真机验收已完成，长局、生命周期与逐模型性能测试统一列入阶段 6.2。

#### 6.1.1 Challenge AI 原生迁移

- 盘点 Python Challenge AI 的 Observation、动作排序、启发式、搜索节点、牌组配置和选择响应逻辑。
- 在 Godot 中实现与发布规则状态一致的 Observation Builder。
- 精确实现 960 维状态编码、96 个卡槽和 178 维动作/选择编码；禁止通过 GDScript 默认哈希推导 card bucket。
- 迁移 8 套牌组对应的启发式参数和策略配置。
- 实现动作和 `ChoiceRequest` 的统一候选生成，确保 AI 能完成嵌套选择、能量分配、晋升和取消逻辑。
- 将搜索运行在 WorkerThreadPool 或专用线程；主线程只接收不可变快照和最终决策。
- 添加搜索超时、取消令牌、对局结束清理和 Android 切后台中止处理。
- 在现有模式选择页开放 Challenge AI，并提供难度、双方牌组和先后手配置。
- 建立至少以下回归：
  - 8 套牌组分别作为 AI 使用。
  - AI 不提交非法动作或过期选择。
  - 每套牌组均能完成对局。
  - 固定种子下决策可复现。
  - 后台搜索期间 UI 帧循环持续响应。

#### 6.1.2 PyTorch 到 FP32 ONNX 导出

- 新增独立 Python 导出脚本，只用于开发/训练环境，不进入发布包。
- 确认当前 8 个部署检查点的网络结构、输入张量、动作头、价值头和选择头。
- 对每个模型导出固定 opset 的 FP32 ONNX 文件。
- 生成模型版本清单，至少包含：
  - 模型 ID 和对应牌组。
  - rules/action schema。
  - 编码尺寸。
  - ONNX opset。
  - 文件大小和 SHA-256。
  - 训练检查点来源校验值。
- 为同一批固定输入运行 PyTorch/ONNX 差异测试；各输出最大绝对误差不得超过 `1e-4`。
- 检查模型是否使用 Android ONNX Runtime 不支持或会回退到低效实现的算子。
- 明确 ONNX Runtime 和模型的许可证、NOTICE 和发布归档要求。

#### 6.1.3 ONNX Runtime GDExtension

- 固定与 Godot 4.7 匹配的 `godot-cpp` 版本和提交。
- 创建 C++ GDExtension 工程、SCons/CMake 构建入口和可重复的依赖获取脚本。
- 构建并打包：
  - Windows x86_64 动态库。
  - Android `arm64-v8a` 动态库。
- 封装最小稳定接口：
  - 加载/卸载模型。
  - 校验模型 schema、版本和 SHA-256。
  - 提交批量输入。
  - 返回动作头、价值头和选择头。
  - 查询错误、运行耗时和执行提供程序。
- 禁止把 Godot 对象跨线程直接传入推理线程；使用扁平数组或不可变缓冲区。
- 实现模型加载失败、版本不匹配、推理异常和超时后的明确错误提示，并自动回退 Challenge AI。
- Deep AI 固定执行 256 次模拟；达到安全看门狗时使用已完成搜索的最佳结果并记录降级事件。
- 验证 8 个模型在完全断网的 Windows 和 Android 环境中均能加载。

#### 6.1.4 阶段 4 验收

- Challenge AI 和 Deep AI 均能从现有 UI 开始、完成完整选择链并结束对局。
- 8 个 ONNX 模型全部通过 PyTorch 对齐测试。
- 两种 AI 均不得产生非法动作、重复 action ID 或过期 request ID。
- Windows 与 Android 搜索均在后台执行，操作、动画和系统返回键持续响应。
- 模型损坏或版本不匹配时，UI 明确提示并回退 Challenge AI。
- 完成后更新本报告，记录模型清单、推理库版本、构建命令、性能数据和产物校验值。

### 6.2 阶段 5：LAN 与 WebSocket Relay 联机（历史实施清单）

> 协议、两种传输、房主权威、隐藏信息、攻击测试和 Win↔Win 完整对局均已实现；以下清单保留用于审计，尚未完成的部分仅为真实跨设备矩阵与公网 WSS 验收。

#### 6.2.1 协议 v3 与传输抽象

- 定义统一 `NetTransport` 接口：连接、监听、发送、轮询、关闭、错误和连接状态。
- 实现 ENet LAN 房主/加入流程和局域网房间参数。
- 实现 WebSocket Relay 客户端，支持 TLS、房间创建、加入、离开、心跳和超时。
- 固化协议 v3 消息 envelope，至少包含：
  - `protocol_version`
  - `message_type`
  - `room_id`
  - `sender`
  - `sequence`
  - `state_revision`
  - `action_id`
  - `request_id`
  - `payload`
- 为每种消息定义大小限制、必填字段、类型约束和错误码。
- 明确不兼容旧 Pygame v2 客户端，握手时直接拒绝错误版本。

#### 6.2.2 房主权威规则

- 房主持有完整 `GameState`、随机源和 `ResolutionStack`。
- 客户端只能提交动作或选择响应，不能提交状态、随机结果、伤害或抽牌结果。
- 房主验证玩家身份、当前行动者、sequence、revision、action ID、request ID 和合法动作。
- 对重复、过期、越权、篡改和超大消息返回稳定错误码，不得改变状态。
- 房主按玩家视角调用隐藏信息序列化：
  - 不发送对手手牌身份。
  - 不发送任何牌库顺序。
  - 不发送未公开奖品身份。
- 每次已接受动作后广播递增 revision 的视角状态和公开事件。
- 支持投降、正常离开、网络中断和房主断线；首版不做房主迁移，房主断线时终止对局并明确提示。

#### 6.2.3 恢复与 Relay

- 使用可序列化状态快照和 `ResolutionStack` 支持客户端重新同步；是否允许短时重连需在实现前锁定产品规则。
- Relay 增加房间生命周期、人数上限、心跳、空闲超时、消息大小和发送频率限制。
- Relay 仅转发协议消息，不运行规则，不获得额外隐藏信息。
- 准备可部署配置：监听地址、TLS 终止方式、反向代理、日志保留和健康检查。
- 不把生产 Relay 凭据、域名私钥或令牌提交仓库。

#### 6.2.4 阶段 5 测试矩阵

- LAN：Win↔Win、Win↔Android、Android↔Android。
- Relay：Win↔Win、Win↔Android、Android↔Android。
- 每种组合至少完成一局，并覆盖嵌套选择、晋升、投降和房主断线。
- 协议攻击测试覆盖：
  - 重复 action ID。
  - 回退或跳跃 sequence。
  - 过期 revision。
  - 错误 request ID。
  - 非当前玩家动作。
  - 客户端伪造随机结果或状态。
  - 超大 payload 和未知消息类型。
- 对两名玩家分别抓取收到的状态，自动断言隐藏信息未泄漏。
- 完成后在报告中记录 Relay 版本、测试拓扑、延迟范围、断线行为和已知限制。

### 6.3 阶段 6：发布与收尾（历史实施清单）

> 本节保留用于审计原始范围。代码、release 构建和自动化验证已经完成；尚未完成项为需要用户设备或正式密钥的外部验收。

#### 6.3.1 表现与性能

- 完成抽牌、出牌、附能、进化、攻击、伤害、击倒、拿奖品和回合切换动画。
- 补齐音效、音量设置和静音选项；确认 Android 音频焦点行为。
- 增加资源加载页、模型加载进度、错误恢复和卡图缓存策略。
- 评估卡图导入格式、VRAM、APK 大小和启动时间，按平台配置纹理压缩。
- 使用 Windows profiler 和 Android profiler 检查长局内存增长、节点泄漏、线程退出和卡顿。
- 避免每次界面刷新重建不必要的昂贵资源；对卡图和详情数据做受控缓存。

#### 6.3.2 Android 真机与生命周期

- 准备至少一台 Android 9+ ARM64 真机并通过 ADB 连接。
- 安装当前调试 APK，验证启动、横屏、安全区、触控目标、返回键、音频和完整本地双人对局。
- 验证 Challenge AI、Deep AI、LAN 和 Relay 的完整对局。
- 覆盖锁屏、切后台、恢复、旋转锁定、断网、网络切换、来电/音频焦点和低内存回收。
- 进行长局和多局连续运行，记录峰值内存、温度、耗电和 AI 搜索耗时。
- 测试 APK 覆盖安装、升级、卸载重装和存档/设置兼容性。

#### 6.3.3 发布签名与裁剪

- 创建或指定正式 Android keystore；密钥、别名和密码仅通过本地安全存储或 CI secret 注入。
- 增加 release 导出预设，不使用 debug keystore。
- 确认发布包排除：
  - Python 运行时。
  - PyTorch。
  - 训练脚本和训练数据。
  - 候选/拒绝模型。
  - Godot 测试、截图工具和开发工具链。
  - 卡图下载管理工作台。
- 包含 8 个已批准 FP32 ONNX 模型、ONNX Runtime 原生库和许可证文件。
- 生成 Windows x86_64 便携 ZIP 和 Android 签名 APK。
- 对 ZIP、APK、PCK、原生库和 ONNX 文件生成 SHA-256 清单。

#### 6.3.4 最终验收与文档

- Windows 和 Android 在完全断网状态下完成 Challenge AI 与 Deep AI 对局。
- 完成 LAN/Relay 六种设备组合测试。
- 完成至少一轮长局、连续多局、断网、切后台、低内存和安装升级测试。
- 复跑 Python 236 项测试、Godot 全部阶段测试、Python/Godot 黄金差异测试、协议攻击测试和 AI 回归。
- 更新本报告的最终差异、已知限制、构建命令、签名流程、依赖版本和发布校验值。
- 提供最小发布说明，包括系统要求、联网方式、断线行为和模型回退行为。

### 6.4 后续验收需要的外部条件

- Android 9+、ARM64、可通过 ADB 连接的真实设备；完成 Android↔Android 时需要两台。
- Relay 测试地址；进入公网测试前需提供 TLS 域名或明确由反向代理终止 TLS。
- Android 正式签名密钥或由用户指定的 CI secret 管理方式。

### 6.5 后续恢复时的执行顺序

1. 在 Win↔Android、Android↔Android 上分别完成 LAN 与 Relay 对局。
2. 使用正式 `wss://` Relay 验证 TLS、延迟、断线和重新同步行为。
3. 完成阶段 5 外部验收后进入阶段 6 的性能、生命周期与资源裁剪。
4. 注入正式签名密钥，生成 Windows ZIP 与签名 Android APK。
5. 阶段 6 所有发布验收通过后，生成最终产物和 SHA-256 清单。

## 7. 阶段完成记录格式

后续每个阶段完成时必须在本文件追加：

- 完成日期和对应提交。
- 实际完成的功能和未完成项。
- 公共接口、协议或数据格式变化。
- 执行过的测试、测试数量和结果。
- 生成的可运行产物。
- 新风险、已知限制和下一阶段前置条件。

只有代码、测试、文档三者同时完成，阶段才可标记为“完成”。

## 8. 验收原则

- Godot 客户端不得依赖本机 Python。
- Android 断网状态下必须能使用两种 AI。
- 不以“主要效果可用”为完成标准；115 张发布卡牌涉及的全部效果都必须覆盖。
- 房主是联机权威端，客户端不得提交随机结果或直接状态。
- 对手手牌、牌库和奖品身份不得出现在其视角状态中。
- Deep AI 编码尺寸固定为状态 960、卡槽 96、动作/选择 178，模型输出与 PyTorch 最大绝对误差不得超过 `1e-4`。
- Deep AI 默认搜索预算为 256 次；搜索运行于后台线程。

## 9. 已锁定的产品决策

- Godot 4.7 标准版，GDScript，Compatibility 渲染器。
- Android 9+，仅 `arm64-v8a`，固定横屏。
- Windows ZIP + Android APK。
- 房主权威，支持 ENet LAN 与 WebSocket Relay。
- 8 套 FP32 ONNX 模型全部内置。
- 不兼容旧 Pygame 联机客户端。
- 首发只包含对战核心，不迁移训练 UI 和卡图管理工作台。

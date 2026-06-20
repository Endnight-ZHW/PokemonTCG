# PokemonTCG Godot 4.7 迁移实施报告

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
| 4. 两种离线 AI | 未开始 | Challenge/Deep AI 均可离线完整对局 |
| 5. LAN/Relay 联机 | 未开始 | 三种设备组合均可完整联机对局 |
| 6. 发布收尾 | 未开始 | 生成 Win ZIP 和签名 ARM64 APK |

## 5. 阶段记录

### 阶段 0：构建基线

开始日期：2026-06-20

计划内容：

- 创建 `godot_client/` Godot 4.7 Compatibility 工程。
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
| `godot_client/dist/windows/PokemonTCG.exe` | 102,915,072 B | `B1B700323D4E3812D644A2F0F2972A542D15AB930D925E5D0C53E749017C66E6` |
| `godot_client/dist/android/PokemonTCG.apk` | 83,986,908 B | `1B17A9B4ACE57A3F59E8A3EBE87423A7896C89B9DB47BD9B4E151CB907E077CA` |

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

- 新增 `scripts/export_godot_data.py`，从 Python 权威数据生成：
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

- `python -B scripts/export_godot_data.py --check`：通过。
- Python 新增 2 个导出测试；完整测试现为 235 通过，8 跳过。
- Godot headless：`GODOT_TESTS_OK phase=1`。
- 验证内容包括 115 张卡、8 套 60 张牌组、72 类效果、全部卡图存在、8 个模型清单、稳定随机序列及序列化往返。
- Windows 与 Android 导出在加入完整卡图和 JSON 后再次成功。

生成产物：

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `godot_client/dist/windows/PokemonTCG.exe` | 102,966,784 B | `1FE9B182F09DDFB4A77B9EAE6D7DD93313511F0C3F5B2279187FB1A6C9088756` |
| `godot_client/dist/android/PokemonTCG.apk` | 101,832,600 B | `B71E587D55D5AEC6D9BA540D7CEF676EC135EBE8FD810E381701236EE08D7453` |

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

- `python -B scripts/export_godot_data.py --check --skip-images`：通过。
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
| `godot_client/dist/windows/PokemonTCG.exe` | 102,966,784 B | `1FE9B182F09DDFB4A77B9EAE6D7DD93313511F0C3F5B2279187FB1A6C9088756` |
| `godot_client/dist/windows/PokemonTCG.pck` | 18,203,268 B | `4A89B2B44F46D069F3A085A9533412D8AE7C72514040F62433E0C05DD9320A10` |
| `godot_client/dist/android/PokemonTCG.apk` | 101,947,137 B | `EC6FBE7ACAF5635D0FD9F9C3BF6E2EE7486B3BAFFDDEB8D7B718FD4E8A8DD9B3` |

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

- `python -B scripts/export_godot_data.py --check --skip-images`：通过。
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
| `godot_client/dist/windows/PokemonTCG.exe` | 102,966,784 B | `1FE9B182F09DDFB4A77B9EAE6D7DD93313511F0C3F5B2279187FB1A6C9088756` |
| `godot_client/dist/windows/PokemonTCG.pck` | 18,177,844 B | `6B4B8FCE8F132498738240DB0DB51F984036ED839A1EF060D90889964BD6178B` |
| `godot_client/dist/windows/PokemonTCG.console.exe` | 101,888 B | `932F700EC1C9CE40408F8A7D3B3B98514AE4406DC3B0469F5124C2C1B0691DCF` |
| `godot_client/dist/android/PokemonTCG.apk` | 101,958,114 B | `E3E6C2936479851BAE500E0750F5F5DD8C32193E80A8F67DB09160B1D5636001` |

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

## 6. 剩余任务

以下任务均未在本阶段启动。后续恢复迁移时应按阶段 4、5、6 顺序执行，并继续遵守“代码、测试、文档同阶段交付”。

### 6.1 阶段 4：两种离线 AI

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

### 6.2 阶段 5：LAN 与 WebSocket Relay 联机

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

### 6.3 阶段 6：发布与收尾

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
- 复跑 Python 235 项测试、Godot 全部阶段测试、Python/Godot 黄金差异测试、协议攻击测试和 AI 回归。
- 更新本报告的最终差异、已知限制、构建命令、签名流程、依赖版本和发布校验值。
- 提供最小发布说明，包括系统要求、联网方式、断线行为和模型回退行为。

### 6.4 恢复工作前必须准备的外部条件

- Android 9+、ARM64、可通过 ADB 连接的真实设备。
- ONNX Runtime 的 Windows x86_64 和 Android arm64 构建来源或可重复构建方案。
- 8 个模型对应的完整 PyTorch 网络定义和可加载检查点。
- Relay 测试地址；进入公网测试前需提供 TLS 域名或明确由反向代理终止 TLS。
- Android 正式签名密钥或由用户指定的 CI secret 管理方式。
- 若需要跨公网真机矩阵测试，至少两台 Android 设备和一台 Windows 设备。

### 6.5 后续恢复时的执行顺序

1. 先复跑 `python -B -m unittest discover -q`、`tools/test_godot.ps1` 和当前 Win/Android 导出，确认阶段 0–3 基线未回归。
2. 完成 Challenge AI 后单独验收，再开始 ONNX 导出和 GDExtension，避免同时调试决策逻辑与原生推理。
3. 阶段 4 完成并更新报告后，才开放 AI 菜单并进入阶段 5。
4. 先完成 LAN 权威对局，再接 WebSocket Relay；两者共用同一协议 v3 和状态校验层。
5. 阶段 5 完成并更新报告后，才开始 release 签名、资源裁剪和最终设备矩阵。
6. 阶段 6 所有发布验收通过后，生成最终 ZIP/APK 和校验清单。

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

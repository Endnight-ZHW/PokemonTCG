# 项目审计、职责拆分与性能验证

本轮以任务开始时的工作区为基线，包含当时尚未提交的传统 AI 简化改动。
目标是保留玩法、界面与协议，减少重复实现、无调用代码和 UI 中不必要的工作。
主要收益来自玩家视图捕获、重复牌桌刷新和静止卡牌的帧处理；没有调整 AI 搜索预算、采样或评分。

## 基线与审计范围

- 基线 HEAD：`52d094b93cdf2f29a25672d545f871ed3edb225a`，但 **HEAD 本身不等于本轮基线**。
- 完整工作区快照：`build/project-audit/baseline/`，共冻结 1,003 个文件。
- 初始状态、每个文件的 SHA-256 和字节数：`build/project-audit/baseline-manifest.json`。
- 全仓文件分类、大小、行数与完全重复文件检查：`build/project-audit/inventory.json`。
- 产品核心、Godot、联机、构建脚本和研究目录均纳入扫描；研究代码的修改限于构建指纹及用于验证产品 AI 的工具。
- 未发现非空文件的字节级完全重复。去重针对重复逻辑；作者 JSON、编译后数据、测试夹具和平台运行库仍各有用途。

卡牌作者源及生成内容未改变，内容检查仍为 137 张卡、10 套牌、160 个效果、80 个 VM 操作；
内容指纹仍是 `f49ee62425b37e4c0a23c08f888499d3741a8db41753be64746382023355cf9a`。

## 已处理问题

| 问题与证据 | 处理方式 | 验证 |
| --- | --- | --- |
| Main 同时负责规则提交、选择控件和各类查看面板 | 提取 `ChoicePresenter` 与 `AuxiliaryPanelPresenter`，分别拥有控件绑定和面板返回上下文；Main 保留规则、网络、AI 和实时请求校验 | 前台完整契约、原生会话契约、图形模式选择预览 |
| `ChoiceSelectionModel` 反向读取 Main 的状态、模式和视角 | catalog 显式注入；动作说明归选择展示器；换手计划归无 UI 依赖的 `LocalHandoffPlan.create()` | 本地换手、隐藏信息、选择中查看卡牌后的恢复 |
| Challenge 与公共目录各实现一次 SHA-256 | Challenge 复用 `native/common/ptcg_sha256.hpp` | 空串、abc、多块长输入、UTF-8 向量及逐决策一致性 |
| 内容编译器、会话和 Challenge 重复转义 JSON 字符串 | 共享 `ptcg_json_string.hpp`；数值编码继续由各自契约负责 | 控制字符、中文、负零、浮点格式、内容指纹 |
| AI 两处实现同一能量缺口算法 | 共享接受能量单位列表的函数，保持空指针和非数组成本的原处理 | 彩虹、有色、无色、空能量、空成本及输入不被修改 |
| Godot 仍保存无调用的搜索 epoch、分支缓存和旧搜索适配入口 | 删除这些内部路径，保留使用中的 GameEngine 功能和原生公开接口 | 原生会话、十套牌 AI 回归 |
| VM support 混合通用访问、公式和选择处理 | 提取公式及选择辅助编译单元，沿用内部声明与 source manifest | C++ 核心测试、内容测试和四种原生构建 |
| 所有 CardView 都逐帧同步选中框，静止牌桌也轮询拖拽 | 选中且可见时才处理选中框；有效拖拽才跟随指针 | 选中/隐藏/恢复、拖拽取消、缩放、陈旧回调和 resync 契约 |
| 玩家视图在新建后立即又克隆一次 | 直接接收新建的独占脱敏 DTO；借用输入捕获及渲染消费者仍得到独立克隆 | 视图所有权与隐私专项测试 |
| 重复交互属性赋值会反复刷新样式 | 相同选中状态、相同交互输入提前返回 | 卡牌分层、演出生命周期和像素对比 |
| 牌桌保留四个始终为 null 且无读取者的旧控件别名 | 删除无调用别名 | 全仓引用扫描、Godot 契约 |
| 多个脚本重复定位 Python/MSVC、执行与判定 Godot 测试 | 收敛到工具公共函数，保留入口参数及各自的警告处理策略 | PowerShell 解析、fast、standard、原生构建 |
| C++ 大小检查与 Arena 头文件指纹遗漏子目录 | 递归检查源码与头文件；公共头文件也参与指纹 | 边界检查、模拟修改嵌套/公共头文件时的缓存失效测试 |
| README 声称研究目录完全不进入常规 CI，但实际运行 Arena | 区分独立训练流程与产品 AI 的 Arena 验证 | 对照现有 CI 配置更新说明 |

展示器不持有 Main。选择响应通过信号交回 Main，提交前继续检查动画和同步锁；辅助面板恢复请求时，
Main 继续对照当前请求 ID、修订号及网络状态。硬币揭示保留弹窗 generation 校验，动画协调器与完成屏障不变。
展示器只在 UI 初始化时创建，提前退出的发布冒烟入口不会创建未挂载的节点。

代表性文件行数（含空行，反映职责移动，不等同于性能收益）：

| 文件 | 本轮前 | 本轮后 |
| --- | ---: | ---: |
| Main | 2,974 | 2,486 |
| ChoiceSelectionModel | 1,408 | 1,091 |
| GameEngine | 483 | 217 |
| NativeRulesSessionAdapter | 285 | 214 |
| VM support | 2,199 | 1,069 |

新增展示器、换手计划及 VM 编译单元承接了移动的代码，不能把以上行数下降相加作为净删除量。

## 保留的设计与后续边界

- `ptcg_core` 仍是权威规则；Godot 和 Python 适配层不会另算一套结算规则。
- VM 与击倒结算中的 HP 计算存在能力/修正项语义差异，本轮没有按相似代码整体合并。
- JSON 数值格式影响存档、日志及签名，保留会话和内容编译器各自的编码规则。
- 视图隔离、动画队列、取消恢复、防循环和 AI 回退具有实际作用，继续保留。
- 纹理缓存只有小规模条目；本轮探针未显示值得增加异步加载或新缓存框架的证据。
- BattleBoardView 和表现运行时中的大文件仍有进一步整理空间；本轮聚焦已明确的 Main/模型耦合与 VM 职责。
- Relay 实现和传输协议未改写；训练、模型及 Arena 功能保留。

兼容边界保持 Native ABI 2、Action 4、ChoiceView 2、Protocol 6、Snapshot 3、Journal 1、RNG 2。

## 性能测量

Godot 使用相同 Windows 编辑器、原生 debug 运行库、固定种子、1280×720 牌桌与减少动画设置。
每项微测量预热 100 次，主要采样 1,000 次，牌桌刷新采样 200 次；三轮按 A/B、B/A、A/B 顺序运行。
以下采用三轮 P95 的中位数，完整采样见 `build/project-audit/performance.json`。

| 指标 | 基线 P95 | 当前 P95 | 当前/基线 |
| --- | ---: | ---: | ---: |
| 捕获玩家视图 | 187 µs | 122 µs | 0.652 |
| 重复刷新固定牌桌 | 9.240 ms | 6.238 ms | 0.675 |
| 重复设置相同交互属性 | 250 µs | 1 µs | 0.004 |
| 原生合法动作查询 | 84 µs | 82 µs | 0.976 |
| 原生快照查询 | 38 µs | 39 µs | 1.026 |
| Headless 帧间隔 | 6.917 ms | 6.918 ms | 1.000 |

视图捕获三轮 P95 为 `187/187/187 → 118/124/122 µs`，刷新牌桌为
`9.221/9.240/9.329 → 6.720/6.167/6.238 ms`。相同交互输入的测量接近计时器分辨率，不能理解为零成本。

固定牌桌的 CardView 数量为 23，持续处理帧事件的卡牌从 23 降至 0；静止牌桌不再处理拖拽位置。
节点数均为 721；探针结束时静态内存为 `155,568,660 → 155,599,822` 字节，增加约 31 KB，未获得内存下降。
纹理缓存均为 14 项、905 次命中、14 次未命中。
这些结果支持 CPU 路径工作量下降；Headless 帧间隔包含调度等待，**不代表 GPU 耗时或实际 FPS 提升**。

AI 另外对同一条包含 21 个公开请求的 v3 控制器轨迹进行单线程测量，预热一整轮，再交替执行三轮。
三轮 P50 的中位数为 `8.5445 → 8.6750 ms`，P95 为
`575.4851 → 582.5299 ms`（当前/基线 `1.012`）。
三轮行为均一致。本轮没有测得 AI 提速，AI 去重以维护性收益交付；该短轨迹也不能代表所有对局的尾延迟。
十套牌逐决策对比的并行耗时仅保留作诊断，不用于性能结论。

Relay 三轮使用 100 个房间、200 个连接，每轮 24,000 条持续消息和 12,000 条突发消息，合法帧丢失及失败均为 0。
持续消息 P95 为 `5.0507 ms`，突发 P95 为
`1.9197 ms`，突发吞吐中位数约
`61,023 条/秒`。
Relay 源码与冻结快照一致，这里记录当前基线，不将历史机器负载造成的差异记为本轮优化。

## 行为与构建验证

- fast、standard 通过，包含 C++ 规则、109 个战术场景、内容、Godot 和联机检查。
- 研究/控制器/公平性等 61 项测试通过。研究模型导出仍会产生既有 PyTorch TracerWarning，测试结果为 OK。
- Godot 十套牌完整 AI 对局全部结束，无非法动作或选择错误。
- 两个引擎分别覆盖十套牌，在相同公开请求和规则 RNG 上，仅执行基线动作：

| 引擎 | 对局 | 核对动作/选牌 | 差异 | 基线/当前搜索节点 |
| --- | ---: | ---: | ---: | ---: |
| strategic_intent_v3 | 10 | 1,459 | 0 | 522,379 / 522,379 |
| turn_beam_v2 | 10 | 1,498 | 0 | 499,834 / 499,834 |

逐决策审计现在保留实体索引和完整引用，只忽略提交 token，避免同名卡牌的不同实体被误判为相同动作。
以上是固定样本中的一致性结果，不是棋力提升声明。

- LAN 与 Relay 均完成完整对局，验证 heartbeat 与终局确认。
- 补充并通过视图所有权、卡牌处理状态、拖拽陈旧完成回调/取消/resync 检查；完整 Godot 契约再次通过。
- 在 NVIDIA RTX 4070 Ti 的 OpenGL 图形模式中，1600×900 与 900×540 共八张选择界面截图逐像素一致。
- Windows x86_64 与 Android ARM64 的 debug/release 四种原生运行库全部构建通过并同步；发布入口冒烟通过。
- `adb devices` 未发现设备；Android 真机帧率、内存和触控没有在本轮实测。

## 复现与证据

原始日志、源码快照和图片均保留在本机 `build/project-audit/`，精简测量结果另存于本目录的
`project_audit_results.json`。旧工作区包含未提交修改，复现前后对比应使用冻结快照，不能仅 checkout 基线 HEAD。

```powershell
.\tools\test_fast.ps1
.\tools\test_standard.ps1
.\tools\test_godot_ai.ps1
.\research\deep_ai\tools\test_research_smoke.ps1
.\tools\benchmark_project.ps1 -BaselineProject build\project-audit\baseline\godot
```

性能探针脚本应原样复制到冻结 Godot 项目的 tests 目录，使双方运行完全相同的测量代码。
AI 基线与当前构建 sidecar 的路径分别记录在 `baseline-agent-build.log` 和 `candidate-agent-build.log` 最后一行；
逐决策工具为 `compare_challenge_decisions.py`，接受 `--baseline`、`--candidate`、`--engine`、`--output`。
单线程重复测量工具为 `benchmark_challenge_decisions.py`，另外接受 `--trace`、`--rounds`，默认先预热一轮再测三轮。

完整证据包括：`fast.log`、`standard.log`、`godot-final.log`、`godot-ai.log`、`research-tests.log`、
`native-build-all.log`、`export-entry-smoke.log`、`performance.json`、`visual-comparison.json`、
`parity-v3/summary.json`、`parity-v2/summary.json`、`ai-timing/summary.json` 及 Relay 的三轮测量日志。

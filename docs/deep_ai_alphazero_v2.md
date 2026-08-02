# Deep AI：信息集 AlphaZero v2

> 状态（2026-08-02）：v2 的共享原生内核、信息集边界、批量推理和客户端回退
> 合约已实现，但本轮五代训练没有产生可晋升模型。五代候选竞技场得分率依次为
> 32.95%、44.32%、34.09%、44.32% 和 30.68%，接受数为 0，冠军始终是未训练的
> `g000`。最终 6,000 局 league 已取消，运行记录不可续训、不可晋升。
> 因此本文记录的是可复用的 v2 工程基线，不是强度达标或可以发布的 Deep AI；
> `deep_runtime_enabled` 继续保持 `false`。

Deep AI v2 使用一个服务全部十套牌的
`universal_infoset_transformer_v2`。Python 负责 GPU 批量推理、优化器、
checkpoint、replay 和调度；`ptcg_ai_core` 提供 C++17 写时复制状态转换、确定性
xorshift32、信息集哈希、PUCT 和连续张量推理队列，并同时由 pybind11 与
Godot GDExtension 使用。搜索热路径已接入 `CompactState` 元数据与写时复制
apply/undo journal；每次模拟结束都回退到根状态，并校验状态、待处理选择、
continuation、RNG 与 chance 标志完全一致。

模型合约固定为 encoder v7、checkpoint v12、planner v2 和 runtime manifest
format v3。实体 Transformer 为 128 维、4 层、8 头、FFN 512，候选通过一层
交叉注意力读取状态；输出为共享候选策略 logits 和行动方视角 WDL logits。
动作以及动作内部产生的选择/确认均作为候选，强制规则转换自动执行。选择根使用
按对局、状态版本和行动方绑定的一次性 continuation；VM 掷币、混乱判定和隐藏洗牌
均通过显式 chance edge 回传，任何未分类的 RNG 消耗都会使搜索失败关闭。

训练入口只有：

```powershell
.\tools\train_deep_ai_v2.ps1 -Preset smoke -AllowPythonFallback
.\tools\train_deep_ai_v2.ps1 -Preset release
```

冻结 Challenge 教师缓存只生成一次。正式流程预热 5 个 epoch，然后运行 5 代
纯自博弈、候选竞技场、最终 6,000 局 Challenge league，并自动导出暂存
`universal.onnx` 与执行 PyTorch/ONNX 误差校验。正式 preset 必须加载
`ptcg_ai_core`；训练可以在发布门槛尚未完成时生成候选和证据，但只有
`production_ready()` 为真才允许候选进入最终证据聚合；训练阶段生成的暂存清单仍
固定关闭 Deep，只有全部外部发布证据通过后才会启用。Python 全搜索回退
只能用于 smoke。

教师缓存 format 2 按完整对局 RNG seed 分组做确定性的约 90/10
train/validation 隔离；同一 seed 的四种座位/先后手不会跨分片。缓存指纹覆盖卡牌、
牌组、效果、VM 描述、Python 正式规则/命令源码、Challenge 配置和生成器源码。
预热只读取 train 分片并在 validation 分片上记录策略/WDL 损失，任何旧格式、空分片、
样本跨分片或指纹不匹配都会拒绝训练。五代自博弈的 4 局历史对手在 55 个配对之间
轮换最近三名已接受冠军，每个配对内部保持四局闭合；最终 league 也让每个闭合组
复用同一个种子。AdamW 的 2,000 step warmup 与 cosine 共同使用整次正式流程的
全局步数周期，避免新一代候选因局部周期重置而从 0 学习率开始。

客户端保持 `DeepAIRuntime.load_for_deck(deck_key)`，十个 deck route 都指向
`universal`。Windows 使用 32/128/256 次模拟与叶批次 8，Android 使用
16/64/128 与叶批次 4。搜索在 1.95 秒停止扩展，并在 2 秒硬期限前返回访问量
最高且经正式规则引擎复核的动作。

发布采用 fail-closed：

- 总配对得分率至少 53%，每套牌至少 50%；
- 非法动作、隐藏信息泄漏、规则异常、超时、降级和 Deep 回退均为 0；
- 原生规则、Python 与 Godot 的 golden/随机转换一致；
- 固定基准至少提速 10 倍，完整正式流程不超过 24 小时；
- Windows 与 Android ARM64 均通过真实 ONNX、期限和回退测试。

门槛未全部满足时，`deep_runtime_enabled` 必须保持 `false`。晋升脚本会验证证据、
checkpoint、ONNX、路由和原生内核状态，再通过带 journal 与回滚的事务同时更新模型、
运行清单和发布清单。

## 当前实现状态

已完成的原生闭环包括 80 条 VM 指令、33 轮选择 continuation、23 条规则动作
golden、合法动作与选择枚举、信息集投影和隐藏身份拒绝、确定化、encoder v7
精确张量对齐、信息集 PUCT 搜索作业、行动方 WDL 翻转、深度截断回传、取消请求
清理、原生/Godot 动作签名对齐，以及跨多个搜索作业的连续数组 GPU 叶批处理服务。
Godot 动作根节点已经可以驱动 ONNX 搜索，并在返回前与正式合法动作集合逐项复核。
Python 正式自博弈的动作根也已通过隐私遮罩后的 Godot wire 状态接入同一原生作业；
GPU broker 在多个 Python 对局线程之间共享并聚合叶请求。动作产生的原生
continuation 会按状态身份缓存一次，下一次选择根继续由同一原生 PUCT 搜索，并与正式
`ChoiceView` 候选取严格交集。动作或选择根一旦发现原生/正式合法集合差异就立即终止
训练。

开发阶段可用以下命令复查正式 Python 与 C++ 的动作根合法性：

```powershell
.\.tools\python311\python.exe .\python\scripts\verify_native_legality_v2.py `
  --games 30 `
  --max-decisions 64 `
  --seed 1701 `
  --output .\artifacts\native_legality_v2_30_games.json
```

当前发布规模 schema v3 动作审计由 4 个独立的 625 局固定种子分片组成，每条轨迹
最多 64 个决策，共覆盖 120,496 个动作状态、831,010 次动作转换、37,108 个正式
选择状态和 249,286 次选择转换；十套牌分别覆盖 11,435–12,856 个状态。除合法动作、
apply、状态、RNG、pending、选择映射、选择深度和整条轨迹外，审计还逐次比较
Python/C++ 有序规范事件 `events[{event_type,data}]`，共完成 1,080,296 次事件
payload 比较。所有结构与语义差异均为 0，合并原始证据位于
`artifacts/native_action_transition_v2_release_raw.json`。

独立的发布规模隐藏信息审计运行 2,000 局，覆盖 126,868 个动作/选择决策根和
253,736 个观察等价变体，十套牌分别覆盖 12,336–13,340 个状态。替换
11,677,382 个隐藏身份并改变 10,815,070 个隐藏顺序位置后，Python ABI 遮罩、
C++ 观察投影、public/private/tree 哈希、相同种子确定化、合法候选和 encoder v7
全部 NumPy 张量差异均为 0；未遮罩输入全部被原生运行边界拒绝。Godot 另行执行
80 条 VM、23 条原生规则、稳定动作签名、信息集边界和真实 ONNX 搜索契约，并与
最终 C++ 源码及 Windows DLL 哈希绑定。封存证据位于
`artifacts/native_action_transition_v2_release_sealed.json` 和
`artifacts/native_infoset_security_v2_release_sealed.json`，两者的
`release_gate_complete` 均为 `true`。
另有固定种子的连续训练桥回归，使用原生动作/选择根搜索推进 32 个决策、64 次模拟，
并要求每次决策都进入原生推理队列，非法动作、非法选择和规则异常全部为 0。Godot
客户端通过扩展内部的一次性 continuation（按对局、revision、actor 绑定）衔接选择根，
公开边界仍只接收 `ChoiceView`；Windows 真实 ONNX 契约会连续执行 256 次动作根模拟和
256 次选择根模拟，再由正式规则引擎复核并应用选择。
原生搜索现会把 VM 硬币序列、混乱状态的即时判定和隐藏洗牌记录为独立 chance
edge：chance 节点不调用策略头，掷币结果按 `0.5^N` 标注概率；洗牌结果按行动方
信息集等价类合并，不把对手隐藏卡牌 ID 写入边签名。每个采样结果分别累计访问与价值，
并通过 `search_chance_nodes` 和 `search_chance_edges` 暴露训练遥测。测试同时覆盖
固定三次掷币、混乱正反面分支、隐藏洗牌以及运行结果中不得出现对手隐藏卡牌 ID；
未伴随已知掷币/洗牌事件的 RNG 状态变化会直接报错。

搜索状态的 JSON 形态 `Value` 已改为递归写时复制，且相同信息集树键会复用候选及其
稳定签名；审计模式仍会在每次访问时重新枚举并比较签名，发现不同确定化产生不同合法
集合就失败。`CompactState` journal 会记录每次状态应用、重新确定化和 RNG/chance
变化，并在模拟边界执行精确 undo 与根状态等价校验；原生技术门槛
`compact_apply_undo_gate_complete` 与 `native_effect_legality_gate_complete`
均已完成。外部发布门槛仍由独立证据聚合器控制。

训练调度不再用 Python 信号量把整个搜索（包括 GPU 等待）限制为 16 局。64 个原生
作业共享一个容量 16 的 cooperative limiter：CPU 模拟段占用槽位，等待批量推理时
释放。每个搜索又可同时保留最多 8 个待推理叶；在途路径使用独立 virtual visit/loss，
响应回传前先释放虚拟访问，因此训练策略、价值和访问量只包含真实完成的模拟。相同
信息集叶正在等待时不会重复提交，取消、停止和批次关闭会丢弃全部请求并清理虚拟访问。

固定 64 局 × 64 模拟、深度 32、真实 CUDA 模型的服务器门禁中，单叶搜索为
1,046.45 模拟/秒、平均批次 41.37、最大批次 64；8 叶流水线为 2,237.14 模拟/秒、
平均批次 120.47、最大批次 247，端到端提升 2.14 倍。Windows 零网络固定基准中，
同一 cooperative limiter 的中位吞吐由 4,872.55 提升至 21,443.43 模拟/秒（4.40
倍），并观测到完整 256 叶批次。对应证据为
`artifacts/native_gpu_multileaf_benchmark_v2.json`、
`artifacts/native_parallel_singleleaf_v2.json` 与
`artifacts/native_parallel_multileaf_v2.json`。
另一个固定同局面、同 seed、同 128 模拟和深度 32 的基准比较 Python 正式规则
deepcopy PUCT 回退与 C++ 原生 PUCT：当前代码独占复测的中位吞吐分别约 63.85 与
2,673.44 模拟/秒，提升 41.87 倍，证据位于
`artifacts/native_vs_python_puct_benchmark_v2.json`。最终发布基线另从 detached
commit `b0f12b5` 执行已退役的 `DeepRootISMCTS v1`，只应用记录在证据中的
`pending_promotion_player` 兼容别名；在同一根状态、seed 和 64 次模拟下，历史实现
中位吞吐为 92.97 模拟/秒，C++ v2 为 2,190.82 模拟/秒，提升 23.57 倍。
`artifacts/native_vs_retired_deeproot_v2.json` 已标记
`release_baseline_complete=true`。

Windows x86_64 与 Android ARM64 的 debug/release GDExtension 均已用固定
MSVC/NDK 工具链按最终源码完成编译。Godot 全套规则、VM、原生 golden、动作签名、
信息集边界、规范事件结构、真实 ONNX 搜索、事务、性能和 UI 契约通过；Python 全套
802 项测试通过。Windows 原生搜索契约连续完成 256 次动作根和 256 次选择根模拟，
本轮契约记录约 40.99 ms；隔离性能测试的动作查询中位为 319 µs（门槛 353 µs），
apply 中位为 94 µs（门槛 131 µs）。候选运行验证器还会
逐套牌执行真实 CPU
Provider ONNX 推理，并运行
原生动作/选择 PUCT、正式规则复核、最低模拟量、2 秒期限与结构化 Challenge 回退
探针；验证只使用隔离的临时启用清单，训练暂存清单与正式清单不会被提前开启。
Android 会导出正式、phase6 和 candidate-search 三份 ARM64 APK，并在上机前校验
身份、签名、ONNX、ONNX Runtime、原生扩展和运行清单哈希完全一致。物理设备证据由
用户执行下列命令生成：

```powershell
.\tools\test_alphazero_v2_candidate_android.ps1 `
  -RunDir <正式训练运行目录> `
  -RequireDevice `
  -AllowCleanInstall
```

发布证据分为两层，避免原生模块无法读取外部证据造成门禁死锁：
`ptcg_ai_core.production_blockers()` 只报告原生技术阻塞，当前原生技术状态已就绪；
Python 的 fail-closed 证据
聚合器另行校验每套牌 10,000 次 Python/C++/Godot 三方转换与隐藏信息、已归档旧
Deep AI 同硬件 10 倍基线、Windows/Android 真实期限与回退，以及 24 小时训练和
6,000 局 league。聚合器会复制并校验每个输入的 SHA-256；训练完成只进入
`pending_evidence`，只有最终证据完整时才把运行目录内的候选清单标记为可晋升，随后
晋升事务会再次验证所有哈希。训练器写出的暂存清单也固定保持
`deep_runtime_enabled=false`；只有最终证据聚合器可以开启它。Android 物理设备证据
尚未由用户提供时，正式清单与候选清单都继续保持关闭。

# Godot 开发指南

项目使用 Godot 4.7、GDScript 客户端和共享 C++ 规则核心。本文记录当前实现；历次迁移、审计和设计过程可从 Git 历史查看。

## 1. 启动与工程结构

在仓库根目录执行：

```powershell
.\tools\setup_godot_toolchain.ps1
.\tools\setup_native_ai_deps.ps1
.\tools\build_native_ai.ps1 -Target windows -Configuration debug
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --editor --path .\godot
```

工具链与下载缓存位于 `.tools/`。保留其中的 Android SDK、JDK、Godot 导出模板、Python、签名材料和用户设置。版本以工具链锁文件为准。

- F5 从 `main.tscn` 启动完整游戏，F6 运行当前场景，F8 停止。
- `res://` 对应仓库的 `godot/`。`.tscn` 保存场景结构，`.tres` 保存主题等资源，`.gd` 保存脚本。
- Container 决定子节点排版；在 Inspector 调整导出参数。修改 `%NodeName` 前检查唯一节点标记和引用。
- 运行时通过 Remote Scene Tree、Debugger 和 Profiler 检查节点、错误和耗时。
- `res://tools/ui_workbench.tscn` 提供固定种子的 UI 与动画预览，不连接网络或修改正式对局。完整导航、弹窗和安全区仍应通过 F5 验证。

| 子系统 | 职责 |
| --- | --- |
| `native/ptcg_core` | 权威规则、内容编译、快照、选择与事务 |
| `native/challenge_core` | 当前 Challenge AI 和共享搜索策略 |
| `native/relay_server` | 独立 Relay 服务 |
| `godot/native/bindings` | Godot 类型与 C++ 接口转换 |
| `godot/authoring` | 卡牌、牌组、策略、VM 描述符的唯一作者源 |
| `godot/data` | 客户端及研究共用的生成数据与发布清单 |
| `godot/scenes/main` | 页面、弹窗、选择、对局生命周期 |
| `godot/scenes/battle`、`godot/presentation` | 三维牌桌、输入映射和动画队列 |
| `research/deep_ai` | 训练、回放、模型导出及 Challenge Arena 验证 |

产品运行时不依赖 Python。SCons 使用 Python 构建；研究依赖保持独立。

## 2. 页面、主题与交互

![当前首页](images/godot-guide/title-cream.png)

当前视觉为奶油米色、暖白面板、焦糖操作色及浅木／亚麻牌桌，没有主题切换功能。
语义颜色来自 `DesignTokens`，`FrontendPalette` 引用公共定义；前台和对战保留各自的 Theme，以支持编辑器预览和紧凑控件。

| 角色 | 色值 |
| --- | --- |
| 页面／面板 | `#F3EADB`／`#FFF9F0` |
| 正文／辅助文字 | `#45372F`／`#796757` |
| 主操作／合法目标 | `#A35F32`／`#49786B` |
| 成功／危险 | `#4F7153`／`#AD5147` |

- 修改颜色时同步 Theme、场景覆盖与单色 SVG。卡图、卡背和能量图标保留原色；可点击图标使用 `DesignTokens.preserve_art_icon()`。
- 富文本模板通过 `DesignTokens.rich_text()` 格式化，再插入已转义的卡文。徽章文字使用 `TEXT_ON_ACCENT`，特殊状态使用 `STATUS_INK`。
- 按钮各状态保持相同内边距；基础触控目标 48px，弹窗确认按钮 56px。正文／按钮对比度至少 4.5:1，控件边界和选中轮廓至少 3:1。
- `MainShellView` 管理页面与安全区，`ModalHost` 管理弹窗生命周期、主题、遮罩和输入阻断。普通弹窗可逐层返回；本地换手隐私遮罩完全不透明。
- 全游戏以原 1600×900 大屏布局为唯一构图，`UILayoutPolicy` 集中管理画布、连续尺寸插值、留白、弹窗边距和奖赏牌的高度预算。
  1024×768 平板、720p、16:10 和超宽屏保留同一分区；低于 1024×720 的窗口缩放同一横向布局。
  移动端保持横屏，主要支持尺寸内触控目标至少 48×48；桌面窗口跨显示器时不使用显示器边缘裁剪内容。
- 选牌始终为左侧双列卡册、右侧详情，联机始终为左侧说明、右侧完整表单；长内容在原区域内滚动。
  对战选卡自动显示左侧说明，关闭说明仍保留阅读区预算，卡牌、状态栏和操作流程不随分辨率切换。
  三维相机统一保持大屏 55° 角度，取景和投影命中区域随可用尺寸重算。
- 牌组画廊浏览高亮与已分配标签分开；双方可选择同一套牌。可执行卡牌动作来自规则返回的合法动作。
- `ChoiceSelectionModel` 保存选择状态，`ChoicePresenter` 绑定界面。UI 不得生成新的 option ID 或扩大合法选项集合。
- 滚动由明确的 ScrollContainer 或卡文 RichTextLabel 负责；布局改变不能重置用户阅读位置。
  选择弹窗始终将选项和卡牌说明并排显示，标题与确认、取消按钮固定，不再切换到单独的说明页。
- 触屏由 `TouchInput` 统一协调物理触摸与模拟鼠标事件，列表子项将滚动交给原生
  `ScrollContainer`；惯性滚动中的首次轻触只停止滚动。`PointerGesture` 在视口坐标中
  记录最大位移，达到 12px 后本次触摸不能再点击或长按，即使滑回原位也是如此。
  自定义选牌区域使用 `PointerTap`，不得仅在鼠标松开时提交选择。
- 三维卡牌和牌堆松手时复用 `_has_point` 的投影命中区域，不能用二维布局矩形缩小
  可点击牌面。触摸不触发鼠标悬停抬升，模拟鼠标移出也不能取消已捕获的手指。
- 手牌仅通过“选卡 → 操作按钮 → 合法目标”使用，只有一个动作或目标也不跳过按钮。
  横向滑动用于浏览，任何方向的移动都不能出牌；静止长按 350ms 查看详情。设置滑块横向调节、纵向滚动页面，
  轻触轨道在松开后生效。日志使用独立滚动容器，阅读历史时保留位置。
- 动画设置只保存 `animation_mode`：`cinematic`、`standard`、`fast`、`reduced`。`reduced_motion` 是只读派生属性。旧布尔设置不迁移，缺少当前字段时提示并使用标准模式。

## 3. 三维牌桌与表现队列

![当前牌桌](images/godot-guide/battle-cream.png)

实体卡、飞牌与桌面在一个 World3D 中渲染。屏幕上的 Control 是输入、HUD 和布局锚点；不要通过恢复二维卡图或每张卡增加视口来修正三维位置。

- `BattleTable` 连接牌桌组件，`Battle3DPresenter` 与 `BattleLayout3D` 负责投影和实体布局；改牌位应修改布局参数，不能只拖场景中的锚点。
- 卡位以桌布中心镜像排列；手牌允许贴边裁切，但必须保留可点击区域和浏览能力。稀疏备战槽保持原槽位，不能压缩索引。
- 手牌先随数量向两侧展开，到达实体牌堆与屏幕的安全边界后再增加重叠；竖屏使用牌堆下方的横向空间。
  `BattleHandFan3D` 以投影后的距离分配卡牌中心，保持平缓弧度和均匀间距；悬停只让邻牌小幅让位。
  布局、点击检测、抽牌目标与重新起手共用这些三维姿态，不能单独调整二维手牌锚点来扩大视觉范围。
- `BattleInteractionController` 只匹配规则给出的合法动作；同一动作的不同目标合并为一个按钮，点击按钮后才接受目标选择。非法点击保留当前步骤，用「返回操作」或「取消」退出目标选择。
- `BattleGuidanceModel` 从玩家可见状态与 `ChoiceView` 生成任务提示；规则强制选择优先于普通操作，奖励卡按引擎请求逐张选择。
- `CardEntity3D` 接收可使用、选中和合法目标状态，分别显示绿色、焦糖色和青绿色光边；低画质及减少动画模式使用静态轮廓。
- 攻击和撤退需确认，结束回合仅在还有合法赋能、支援者或攻击时提醒。出牌飞行动画由成功提交后的规则事件驱动。
- `BattleViewModel.capture_player_view()` 创建独立且过滤隐藏信息的排队视图。`capture()` 用于显式借入快照；`state_for_render()` 返回消费者自己的副本。
- `BattleTransitionRequest.create()` 在表现入口完成事件规范化、顺序整理和玩家可见性过滤。下游预取、手牌身份匹配、播放共用这一批规范事件，不重复整理。
- `BattleTable.play_presentation()` 接收规范事件和此前的表现快照。独立预览先调用 `PresentationEvent.prepare_for_player()`，完整对局优先提交 transition。
- 每批次只克隆一次用于落地的状态；卡图预取通过视图收集公开牌、己方手牌及附件，不序列化整份状态，也不预取隐藏牌身份。
- 抽牌和飞牌以事件明确的卡牌列表与实体身份为准。同名卡离开又返回时不能用数量净差替代真实移动。
- 动画完成句柄、generation 检查、取消和重同步保护必须保留。预取完成及事件回调后仍需检查批次是否被取消；重复事件不能堵住队列。
- 飞牌落地、来源遮挡和三维姿态在 `frame_pre_draw` 对齐。伤害反馈在接触帧发生；不得为了少一次更新破坏 Tweens 与实体同步。
- 对局动画配置集中在 `res://presentation/default_battle_animation.tres`。在 Inspector 中可调整
  `BattleAnimationProfile` 的标准模式总时长、模式倍率、运动幅度、属性配色和粒子预算；
  `MotionPolicy` 是唯一计时入口。标准档抽牌 360ms、附能 400ms、进化 780ms、攻击蓄力 220ms／
  命中 440ms、击倒 620ms、获胜 800ms；非攻击扣血仍为 320ms。飞牌与落地收尾共享总时长。
  公开展示和重新起手保留单独的阅读下限。
- `PresentationDirector.feedback_requested(event, duration)` 交给 `BattlePresentationRuntime`
  从玩家可见事件与当前展示态生成 `BattleFeedbackCue`。`BattleFeedback3D.play(cue)` 返回
  `MotionHandle`，在 `impact_reached(event_id)` 更新展示态 HP／状态、数值和音效；
  附能与进化在落地后更新。落地句柄在移动组封口前登记，不能在接触后向已封口组追加等待。
- 属性效果使用同一 World3D 中的池化 MultiMesh 与程序化 glyph shader；草叶、火焰、水滴、
  电弧、念力环、冲击碎屑、暗色弧刃、金属切光、龙形旋流和空气环拥有不同形状与轨迹。
  属性按公开来源卡首个 `energy_types` 解析，未知身份保持中性；仅 `attack_damage` 产生
  攻击前冲，反伤、异常状态扣血及伤害指示物使用独立反馈。
- `BattleFeedbackGeometry` 根据进度采样属性主体、轨迹、接触核心与余波，`BattleFeedback3D` 只管理时间、池和生命周期。
  `BattleFeedbackCue.contact_progress()` 将标准档 30ms／50ms 的普通／重击顿挫计入原时长，不改变引擎 time scale。
  公开目标最大 HP 的 50% 为重击阈值；同一序列至多一次重击微震和一次击倒微震，分别限于 2px／3px。
  镜头按逻辑屏幕像素换算，桌面材质局部压暗最多 12%，HUD 不参与压暗。掉帧越过接触点时仍只提交一次，剩余反馈受实际剩余时间约束。
  高／中／低档默认装饰粒子预算为 36／22／10，共用接触时序；减少动画不使用空间运动或聚焦。
- `AudioDirector.play_cue(String)` 使用最多八个 SFX 声部，低优先级声音不能挤掉命中、进化、击倒和硬币落地。
  纸牌瞬态和十属性命中使用确定性的程序化音色，资源只在初始化生成；重同步、退出对局和应用暂停清理 SFX。
- 卡牌反馈通过独立姿态偏移叠加到布局，附件及 HUD 跟随投影。减少动画模式直接提交接触结果，
  保留静态数值与状态；高／中／低画质使用相同时间轴，仅削减装饰数量。回收或取消效果必须
  先清理姿态再完成句柄，池满时仍需完成语义接触回调。
- 落地、训练家和场地光效必须绑定实际卡面的 `surface_pose`，包含牌堆高度、倾斜与校准后的尺寸。
  不使用 ZoneView 的二维控件中心或固定像素宽度画卡牌轮廓；普通落牌使用短促的边角亮光。
- 隐藏页面或应用暂停时停止视口和装饰更新；同一局隐藏后恢复不得重置自动画质。退出场景释放临时实体和句柄。
- 首页三维展示在可见时使用 `UPDATE_WHEN_VISIBLE`；低画质／减少动画仅停止姿态动画，
  不按固定帧数冻结绘图缓冲。全局 `frame_post_draw` 不代表该视口已经画出有效内容，
  冻结会使延迟绘制或缓冲重建后的透明画面无法恢复。弹窗覆盖、页面隐藏和应用暂停时仍停止绘制。

## 4. 卡牌内容、规则与 AI

```powershell
.\tools\content.ps1 lint
.\tools\content.ps1 status -Json
.\tools\content.ps1 test -CardId svi-chim
.\tools\content.ps1 export
.\tools\content.ps1 check
```

修改作者 JSON 后通过内容编译器生成数据，不手改 `godot/data`。新增卡图放入唯一卡图目录；更新审核清单后重新导出映射与哈希。新牌组必须为 60 张，并同步策略作者源。当前内容为 177 张卡、14 套牌、218 个效果、80 个 VM 操作。

全部卡牌统一使用 [PTCG-CHS-Datasets](https://github.com/duanxr/PTCG-CHS-Datasets) 的简中数据。
`godot/authoring/card_source_manifest.json` 固定上游提交、数据集 SHA-256，以及每张卡的收录集合、
来源卡牌 ID、原图路径和 SHA-256。游戏内 ID 是稳定引用，印刷系列及编号分别由 `set_id`、`number` 记录；
同名不同效果的版本必须分别匹配。基本能量使用同一套无额外标志的卡面。

```powershell
.\tools\sync_card_sources.ps1        # 校验下载，统一元数据和卡图，再经原生编译器导出
.\tools\sync_card_sources.ps1 -Check # 核对元数据、无损卡图和生成数据；不改作者源或卡图
```

同步工具使用固定版本的缓存，复核卡名、HP、属性、撤退及招式费用，只更新画师、图鉴文案、系列、编号、
稀有度、规则标记和来源 URL；招式、特性及 VM 指令继续由作者源维护。所有卡图从已校验原图统一导入为
300×419 无损 WebP，不裁切、不重绘、不再次有损压缩。作者 JSON 统一排序并使用相同字段；`image_path`
及 `compiled_*` 只由编译器生成。内容 `lint/test/export/check` 会拒绝遗漏来源、未固定版本、错误图片 URL
或混入生成字段的作者数据。新增卡需先登记准确印刷版本及原图哈希，再运行同一个同步入口。

`CardCatalog.shared()` 发布一份深度只读的卡牌数据和预计算查询；合成测试使用 `CardCatalog.new(true)` 获得可变副本。运行时或工作线程不得修改共享字典。

权威规则只在 C++ 会话执行，流程为 Action V4 → 原子结算 → ChoiceView v2／事件／状态投影。ChoiceResponse 必须携带原请求、revision 和合法选项。失败回滚、RNG、嵌套选择、快照和 journal 由规则核心管理，UI 只提交意图。

当前接口为 Protocol 6、Snapshot 3、Journal 1、RNG 2、Native ABI 2 和 Card IR 4。旧协议和快照明确拒绝；不添加迁移分支。玩法、临时效果及结算顺序见 [规则说明](RULES.md)。

隐私边界包括：对手手牌身份、双方牌库顺序和奖赏身份不可见；开局完成前，对手盖放宝可梦仅显示隐藏占位。事件中的 owner 是卡牌拥有者，可能不同于触发效果的 actor。浏览整副牌库的 `browse_card_refs` 仅提供给该选择的拥有者，不属于合法选择集合。

Challenge 默认使用 `strategic_intent_v3`；`turn_beam_v2` 仍承担比较与低置信度兜底，不能按名称删除。保留确定性种子、预算、取消、公开信息约束及缓存失效规则。研究的训练／导出保留手动入口，Challenge Arena 验证参与常规 CI。详见 [AI 核心](../native/challenge_core/README.md) 和 [研究说明](../research/deep_ai/README.md)。

## 5. 验证、性能与发布

```powershell
.\tools\test_fast.ps1
.\tools\test_standard.ps1
.\tools\test_godot_ai.ps1
.\tools\test_battle3d_graphics.ps1
.\tools\test_frontend_club_graphics.ps1
.\research\deep_ai\tools\test_research_smoke.ps1
```

- fast 验证产品边界、源码清单、VM 完整性、原生核心、Relay、内容和 Godot ABI。
- standard 检查生成数据、UI／交互合同与 LAN／Relay 整局；新增动画还要跑实际图形验证。
- Workbench 侧栏的「属性动画实验台」提供全部动作、十种属性、双方视角、四档动画及三档画质；
  「同名手牌 · 放置左侧／右侧」与「喷射能量 · 附能后换位」使用真实原生动作生成事件，便于核对副本身份和触发顺序。
  现有 0／50／100% 按钮用于暂停关键帧，「保存当前关键帧」写入 `build/animation-preview/`。
  `battle_animation_contract.gd` 验证命中前后展示态、单次提交、取消、池满以及所有动作完成；
  图形脚本 `battle_animation_visual.gd` 输出属性飞行／命中、异常状态、进化及多尺寸降级截图。
  `battle_landing_feedback_contract.gd` 对照实际实体检查落地光效的位置、宽度和法线，覆盖双方视角与三种窗口尺寸；
  图形运行另保存 18 张训练家、弃牌和场地落地截图到 `build/landing-feedback/`。
  `battle_coin_choice_contract.gd` 从 Main 执行原生捕捉器、粉碎之锤和投币招式，验证正反面分支、
  四档动画、双方向、落地音效、禁止提前确认、禁止重复投币及重同步／关闭弹窗时的回收。
  横屏／紧凑屏／竖屏和三档画质截图在 `build/coin-choice/`；实验台新增「实卡 · 捕捉器正面／反面／连续投币」入口。
  `CoinShowcase` 为唯一硬币时间轴，牌桌和弹窗均使用 `CoinEntity3D`；
  弹窗拥有随其销毁的透明 `CoinStage3D`，不再回退到二维缩放硬币。
  开局公开和附件离开仅使用贴合实体卡面的反馈；减少动画使用静态轮廓，禁止额外叠加二维矩形闪白。
  旧的 CardView 闪白／抖动 API、二维公开展示背景／压扁翻面／离场轨迹、通用 burst 转接、
  过期反馈缓存和无效飞牌参数已移除。公开展示统一通过三维卡牌交接，选择界面仍使用其独立 UI 控件。
  卡牌层级测试覆盖新姿态与选中状态隔离，并检查多张卡牌退出时的 MotionGroup 取消。
  `battle_3d_contract.gd` 的手牌布局组检查 1／5／7／10／20／40 张手牌、六种窗口尺寸和三个浏览位置，
  验证均匀间距、边界、居中、密集展开及实体点击，截图输出到 `build/hand-layout/validated/`。
  `battle_animation_motion_review.gd` 录制全部实验台动作的实际渲染过程（含起手、落地接管和双方视角），
  PNG 在动作结束后编码，避免录制阻塞主线程改变动画节奏。输出位于 `build/animation-review/`。
  运行 `./tools/build_animation_review.ps1` 可按实际采样时间生成本地对照播放器 `build/battle-animation-upgrade/review.html`，
  支持暂停、拖动和 0.5×／1×／2× 播放；可通过 `-BeforeDirectory`、`-AfterDirectory`、`-OutputDirectory` 指定目录。
  默认基线目录为 `build/battle-animation-upgrade/before/animation-review/`。录像不含音轨，Workbench 可试听同步音效。
  `battle_animation_contract.gd` 的音频组覆盖声部上限、优先级、属性音色、重同步与应用暂停清理。
  `test_battle3d_graphics.ps1` 包含这些图形检查，性能探针同时播放属性命中、进化和密集飞牌。
  图形测试专用驱动在窗口最小化时继续离屏绘制，避免等待 `frame_post_draw` 阻塞，无需恢复或抢占前台窗口。
- 抽牌、奖励卡、出牌、进化和弃牌在 `BattleCardPath3D.travel()` 中分别编排；到达和落地回弹使用同一个 Tween。
  飞牌先沿手牌平面抽离或从牌堆抬起，再翻面越过牌桌，最后沿目标牌面法线归位。
  `BattleCardClearance3D` 对翻面后的真实三维纸片体积进行分离轴检查；渲染前统一避让桌面、牌堆、手牌及较早的飞牌，
  换位复合牌堆也参与避让。不能用关闭深度测试或仅抬高卡牌中心替代牌角／厚度检查。
  落地光效在避让后重新绑定真实实体，但不重复触发接触或推进时间；附能与进化分别保留总时长的 36%／40% 用于收束。
  进化使用贯穿接触帧的双螺旋与光柱，附能随飞牌汇聚后收拢至能量标记。击倒的失色延续到离场，接近弃牌堆时再恢复。
  `battle_motion_clearance_contract.gd` 覆盖双方视角、横竖屏、连续发牌和 40 张原有手牌的实体体积穿插检查。
  `battle_action_identity_contract.gd` 通过真实规则与玩家视图检查同名手牌选择、能量附件转移，以及喷射能量接触后再换位；
  动作事件必须在实际移牌时记录源索引和当时的目标位置，不能用最终状态的同名卡数量差替代实体身份。
  进化／附能的光效由飞牌时间轴推进，空中开始演出，在实际落地帧提交展示态，避免特效先跑完而卡牌仍未到达。
  洗牌分组共用边界修正，保持薄组在对手牌库和紧凑屏中平行、不穿插；硬币采用减速翻转和落定回摆。
  数值提示在牌面外侧避让连续结果；减少动画只展示静态轮廓和可读数值。
  动作录像可用 `-- --actions=cards_drawn,opening_draw,pokemon_evolved --output=E:/PokemonTCG/build/my-review`
  单独录制指定动作的双方视角；省略参数仍录制完整清单。
- `test_godot.ps1` 中的 `touch_scroll_contract` 使用完整输入分发覆盖触摸、模拟鼠标去重、
  惯性停止、按钮/滑块/选牌/能量分配、日志及按钮出牌、滑动不出牌；同一脚本去掉 `--headless` 可在
  实际图形渲染下运行。桌面注入测试不能替代 Android 手机和平板真机手感验收。
- `battle_touch_resume_contract` 覆盖布局矩形外的三维手牌/奖赏点击、菜单确认退出，
  以及真实规则执行最后一次攻击、领取最后一张奖赏、结算页轻触返回首页的完整流程。
  `test_frontend_club_graphics.ps1` 同时运行该合同：延迟三维绘制、重建绘图缓冲、暂停恢复后
  检查桌布像素，并保存低/中画质、横/竖屏的返回首页截图；无图形模式不做像素验收。
- 真机专用场景为 tests/android_touch_acceptance.tscn。设置与发布包相同的 Android 签名环境变量后，
  运行 tools/build_android_touch_acceptance.ps1，生成 build/android-tablet-test/PokemonTCG-Touch-Acceptance.apk。
  该包使用独立包名 com.pokemontcg.touchtest；构建结束会恢复项目与导出配置，产品包继续排除测试目录。
  通过 adb 的显式设备序列号安装并启动，Logcat 中的 ANDROID_TOUCH_REPORT 给出原生渲染、
  完整输入分发、最后一次攻击／领取奖赏／结算返回和实际分辨率下的帧耗时结果。
  ANDROID_TOUCH_ACCEPTANCE_OK 仅代表交互与绘制断言通过，帧耗时另行评估；测试结束卸载该独立诊断包。
- 统一布局回归覆盖 1024×768、1280×720、1280×800、1600×900、1920×1080、2560×1600、2000×900，
  以及 900×540／640×960 缩放保底、连续缩放、四边安全区、密集手牌、重复卡牌、附件、强制选择及换手。
  `desktop_layout_contract.gd` 同时验证并排页面、自动卡牌说明、区域避让和关闭说明后的几何稳定性；
  `test_godot.ps1` 运行其无图形检查，`test_frontend_club_graphics.ps1` 使用真实渲染生成
  `build/layout-unification/after/` 截图与 `geometry.json`。原大屏对照基线保存在忽略的 `build/layout-unification/before/`。
- CPU 测量使用 `tools/benchmark_project.ps1 -BaselineProject <独立Godot目录> -Runs 3`；比较双方应使用相同版本的探针、硬件、配置和 fixture，并交替执行。
- headless 帧间隔包含调度时间，不代表 GPU 性能。实际图形探针在 1920×1080 各档预热后采样 300 帧，高／中档 P95 ≤ 20 ms，低档 ≤ 36 ms。
- 源码检查关注构建清单、依赖与 VM 操作归属，不使用文件行数或字节数决定架构拆分。

```powershell
.\tools\setup_android_toolchain.ps1
.\tools\package_release.ps1 -AndroidSigning test
.\tools\test_release.ps1
.\tools\package_relay.ps1
```

发布清单是版本、Android versionCode 和 schema 的唯一来源。客户端导出排除作者源、测试、工具、研究及旧 ONNX 运行库；作者源和生成数据仍保留在仓库中。构建脚本清除已知旧导出残留，发布验证检查运行目录、ZIP、APK、签名与校验和。

Relay 独立发布，TLS 由反向代理终止，部署见 [Relay 说明](../deploy/relay/README.md)。`test_release.ps1 -RequireAndroidDevice` 要求真机验证；没有设备时的 APK 静态检查不能证明触控、持续帧率和温升达标。

构建、截图和审计日志写入忽略目录。清理时保留最新通过验证的发布包、签名材料和研究回放／检查点；不能将研究的整个 build 目录视为缓存删除。历史过程文档与旧截图不继续随主分支维护。

### 源码维护边界

卡牌编译与 VM 描述符以 `godot/authoring` 和 `NativeContentCompiler` 为准。研究侧读取
发布数据并调用共享 C++ 核心；旧 Python 命令编译器、公式求值器和未接入入口的观察采样、
效果适配及会话封装已移除，现用 DTO、快照、训练与评测流程继续保留。

Android SDK/JDK 的编辑器导出路径由 `tools/build_godot.ps1` 写入，不再维护独立的
GDScript 配置脚本。无引用资源与对应 `.import` 成对移除，已删除脚本的孤立 `.uid` 也应清理。

清理依据包括运行入口、测试调用链、场景资源、UID 和动态加载引用。引擎回调、信号绑定、
兼容数据与仍被调用的回归测试不能仅凭名称或文件年代删除。测试入口及其子套件继续保留，
本地构建产物、工具链、研究成果和截图基线不属于源码清理范围。

测试按功能套件归组：音频随动画契约、通知文案随卡牌呈现契约、手牌布局随三维契约运行。
三维图形辅助检查集中到公开展示和卡牌移动两组，覆盖现用分辨率、动画档位、双方视角、可读性和拾取。
卡牌详情截图与对战可用性共用预览场景，`--battle-detail-only` 和 `--battle-usability-only` 入口保持有效。

测试维护时区分当前行为与历史改版目标：固定的旧二维透视比例、码放偏移量，以及相对已移除布局的
“放大百分比”不再作为验收条件。Control 布局规划仍保留边界、数量、滚动、准备阶段及升位提示检查；
真实牌桌的对称、可见区域和可点击性由三维与桌面布局契约验证。
复杂选择的换位、宝藏能量、备战席和学习装置截图由共享场景生成，完整预览与专项入口共用同一组夹具。
旧协议拒绝、历史 AI 基线以及隐藏信息保护仍属于有效回归范围。

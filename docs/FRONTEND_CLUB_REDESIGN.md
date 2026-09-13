# PTCG 前台与弹窗视觉重构

2026-09-13 至 2026-09-14。基于 `83334b59e0aaa4a2dd8d6b0e6fb77a916ca2e9cf`，在
`codex/frontend-club-ui` 实现“实体卡牌俱乐部”前台。对战 HUD 的布局、游戏主题、规则数据、
设置存储格式和联机协议保持原有接口。

## 实现

- `FrontendPalette` 与前台 Theme 统一木纹/织物背景、哑光面板、暖白正文、金色主要操作。
  正文默认 18px，紧凑表单与说明至少 16px，主要按钮高 56px。
- 首页使用独立 `FrontendCardShowcase3D`：最多三张公开卡，共享 `CardEntity3D` 与纹理缓存。
  横屏左右分栏，竖屏上下排列；低档与减少动画静态渲染，弹窗覆盖、页面隐藏时停止更新。
  不调用对局自动画质会话接口，过期纹理回调不会重新激活或污染展示。
- 牌组卡册区分浏览与分配。顶部显示玩家槽位及当前分配目标，右侧/详情页显示代表卡和构成，
  底部固定已分配牌组摘要、规则开关与开始按钮。小屏详情返回保留卡册位置，支持双方同牌组。
- 联机宽屏提供概览和表单，小屏分为“方式与牌组”“连接与规则”两步。状态、房间码复制与
  主要操作固定在底部；错误贴近字段，继续保留草稿、房主规则锁定、重连和连接失败状态。
- 结算突出胜者/平局、代表卡和摘要，主按钮按去向显示“重新选牌”或“返回联机大厅”。
- 设置分声音/画面，缓存置于高级折叠项；动画模式为唯一动画入口。已有非预设缓存值会保留。
  恢复默认只更改表单，保存时才提交；取消不会应用表单变化。
- 帮助采用分类导航与正文。检查器使用大图与卡文，窄屏连续阅读；牌区卡图自动换行。
  卡图放大也使用统一 ModalHost，Android 返回逐层恢复卡牌详情、附件来源与牌区位置。
- 所有弹窗统一前台外观，仍由 `ModalSpec` 管理尺寸、遮罩、取消与父弹窗恢复。
  选择进度和确认区固定，列表与说明分别滚动；小屏说明页可返回原选择列表和滚动位置。
  暂停、退出确认与本地交接保留既有动作和完整隐私遮挡。
- 删除旧标题背景、二维展示卡影与轮换实现，以及不可操作的 AI/先后手下拉控件。
  更新节点绑定、Workbench、回归断言及开发手册，没有保留旧节点路径适配层。

## 截图与复现

[新旧对比页](../build/frontend-club/compare.html) 包含首页、卡册、联机、设置、帮助、
卡牌详情、能量分配与结算。新截图来自实际 Compatibility 渲染。

- [五种尺寸的截图](../build/frontend-club/after/)：1600×900、1280×720、900×540、
  2000×900、640×960；同一页面实例连续缩放，不为每个尺寸重新创建页面。
- [桌面首页](images/godot-guide/title-club.png)、[竖屏首页](images/godot-guide/title-club-portrait.png)。
- Workbench：打开 `godot/tools/ui_workbench.tscn`，选择首页、牌组、联机、设置、帮助、
  选择/能量分配、卡牌检查器、牌区检查器与结算。选择预览支持实际选中、取消、撤销和查看说明。

在仓库根目录运行：

```powershell
.\tools\test_frontend_club_graphics.ps1
.\tools\test_frontend_club_graphics.ps1 -SkipPerformance
.\tools\test_godot.ps1
.\tools\test_battle3d_graphics.ps1 -SkipPerformance
.\tools\test_godot_ai.ps1
.\tools\test_godot_network.ps1
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\smoke_godot_build.ps1
```

单独重放检索等语义选择：

```powershell
& .\.tools\godot-4.7\Godot_v4.7-stable_win64_console.exe --path godot `
  --script res://tests/ui_preview.gd -- --semantic-choice-only
```

## 验证记录

| 项目 | 结果 |
| --- | --- |
| 15 项 Godot 合同回归 | 通过；包括规则/网络协议、UI、三维、拖拽、隐私、队列与 Workbench |
| 新前台行为回归 | 保存表单、取消/默认、非预设缓存、浏览/分配、联机四种组合、字段错误与结算去向通过 |
| 安全区与交互 | 四边 48px 安全区、鼠标/触控目标、固定操作区、连续缩放、Android 返回与弹窗历史通过 |
| 选择流程 | 空结果、强制选择、多选上限、同名卡、附件分配、只读浏览与返回恢复通过 |
| 实际图形回归 | `BATTLE_3D_CONTRACT_OK`、`BATTLE_3D_VISUAL_CONTRACT_OK`、`UI_PREVIEWS_OK`、`SEMANTIC_CHOICE_PREVIEWS_OK`、`BATTLE_DETAIL_PREVIEWS_OK` |
| Challenge AI | 10/10 完整对局通过 |
| LAN | 42 回合、111 动作、37 选择；终局确认通过 |
| Relay | 41 回合、114 动作、40 选择；终局确认通过 |
| 内容与源码边界 | 内容指纹未变，源码边界与产品边界检查通过 |
| 调试包 | Windows/Android 导出通过；Windows 启动、原生运行库与网络冒烟通过；Android ARM64 包静态检查通过 |

原始记录：[Godot](../build/frontend-club/godot-regression.log)、
[更新后的前台回归](../build/frontend-club/frontend-final4.log)、
[界面图形回归](../build/frontend-club/ui-preview-final3.log)、
[语义选择](../build/frontend-club/semantic-graphics.log)、
[详情图形回归](../build/frontend-club/battle-detail-graphics.log)、
[AI](../build/frontend-club/ai-regression.log)、[网络](../build/frontend-club/network-regression.log)。

### 首页性能

Godot 4.7 Compatibility，NVIDIA GeForce RTX 4070 Ti，1600×900，标准动画。
每档预热 5 秒，连续采集 5 秒真实渲染帧；高/中档循环运动，低档保留静态三维。
测量不与 AI、网络或构建任务并行。

| 档位 | 目标 | P50 | P95 | 验收上限 | 结果 |
| --- | --- | --- | --- | --- | --- |
| 高 | 60 FPS | 16.666ms | 16.871ms | 20ms | 通过 |
| 中 | 60 FPS | 16.667ms | 16.910ms | 20ms | 通过 |
| 低 | 30 FPS | 33.346ms | 33.629ms | 36ms | 通过 |

首页高/中档三维展示每帧 13 次绘制，场景总节点 97；低档稳定后 SubViewport 停止更新。
连续 8 次“首页 → 选牌”，展示台弱引用全部释放；每次返回选牌后为 282 节点、
35,305,705 字节纹理占用，没有持续累积。
[性能与资源 JSON](../build/frontend-club/validation.json)、
[最终布局与生命周期 JSON](../build/frontend-club/layout-validation.json)。

此记录验收桌面首页，不代替 Android 真机或长时间对局性能。

## 调试包

- [Windows 调试包](../build/PokemonTCG-Frontend-Windows-debug.zip)
- [Android ARM64 调试 APK](../godot/dist/android/PokemonTCG.apk)
- [最终导出记录](../build/frontend-club/export-final.log)
- [启动与包检查记录](../build/frontend-club/build-smoke.log)
- [包体大小与 SHA-256](../build/frontend-club/artifacts.json)；Windows ZIP 仅含程序、控制台启动器、PCK 和当前原生 DLL。

Android 9+ ARM64 的包检查与导出在桌面完成。目前没有连接 Android 设备，真机触控、
持续帧率与温升仍待验收；未用桌面或无图形测试替代这些项目。

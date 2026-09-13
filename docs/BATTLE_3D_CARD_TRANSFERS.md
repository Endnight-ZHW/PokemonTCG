# 检索入手与附能动画修正

公开检索结果现在复用展示中的三维卡牌，直接飞到对应的手牌位。离开展示区时保留当前位置、尺寸和朝向，按屏幕中的大小变化插值深度，避免突然放大或缩小。原有手牌提前让出空间；多张同名卡按各自的视觉身份交接，落地后立即移除运动卡牌。

回收等其他批量入手路径也使用预留位置，避免前一张卡落地时被后一张卡的排布推开。普通逐张抽牌保留原有发牌节奏。

附能与能量转移使用完整卡面及实际附件层的三维姿态，从宝可梦侧边抽出或滑入卡叠。能量卡不再缩成 HUD 图标。过渡卡叠接管卡图和角标，最终能量数量在接触时更新，避免最终局面提前穿过旧卡叠显示。

完成句柄覆盖展示、手牌让位、飞行和落地反馈。重同步会清理展示卡与运动实体；同步完成回调允许释放实体，清理流程避免二次访问。部分卡牌已落地时调整窗口，不再访问已释放的展示卡。

## 验证

`battle_3d_visual_contract.gd` 新增完整事务检查，覆盖我方及对手公开检索、弃牌回收、双方附能、战斗区至备战区能量转移，分别运行标准、快速和减少动画，共 18 组。检查三维实体持续注册、同名卡身份、尺寸变化、准确交接、对手隐私、最终节点清理；另覆盖展示中取消、飞行中取消及部分卡已落地时缩放窗口。

可在 Workbench 的“公开检索结果”“附能”中重复播放。完整检查入口为 `tools/test_battle3d_graphics.ps1`。

Godot 14 项契约、18 组实际渲染事务、取消与缩放、完整 UI 预览、10 套 Challenge 卡组终局及 LAN／Relay 完整对局回归通过。检索与回收入手的投影交接误差最大约 0.000244px。LAN 回归为 42 回合、111 动作、37 次选择；Relay 为 41 回合、114 动作、40 次选择。

RTX 4070 Ti、1920×1080、Compatibility 实际渲染下，各档分别采样 300 帧。独立复测高／中／低档 P95 为 17.199／17.175／37.621ms，绘制调用为 308／308／209。高、中档达到 20ms 目标；低档超过 36ms 目标，性能验收仍未通过。首次低档测量为 37.473ms；单独低档诊断为 36.337ms，300 个样本窗口均有焦点，故未将波动简单归因于后台运行，也未降低门槛。原始记录保存在本次输出目录。

Windows 与 Android 调试包已重新导出。Windows 启动、原生运行库、网络和发布契约检查通过；Android APK 元数据和 ARM64 载荷检查通过，因未连接设备跳过真机启动检查。

- [实际图形检查](../build/battle3d-transfer-fixes/visual-checks.json)
- [性能记录](../build/battle3d-transfer-fixes/performance.json)
- [检索落定](../build/battle3d-transfer-fixes/search-settled.png)
- [附能过程](../build/battle3d-transfer-fixes/energy-flight.png)
- [能量转移](../build/battle3d-transfer-fixes/energy_transfer-flight.png)
- [缩放窗口后的手牌](../build/battle3d-transfer-fixes/search-resized.png)
- [交付校验](../build/battle3d-transfer-fixes/delivery.json)

Android 真机触控、持续帧率与温升仍待连接设备后验收。

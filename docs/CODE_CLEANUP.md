# 三维迁移后的代码清理

以本次清理开始时的工作区为基线，Godot 源码净减少 **1,361 行**，包括新增的公共函数；测试、文档和 UID 不计入这一数字。统计没有把此前尚未提交的三维重构改动算作本次删除。

## 清理内容

- 删除旧 `BattlePlaymat` 节点、脚本和 UID，移除已无人读取的场地导引数据及重复计算。实际三维桌面与牌位由现有三维布局负责。
- 删除二维飞牌曲线、洗牌回退、附件缩成徽章的运动实现，以及二维粒子和冲击环绘制。飞牌统一使用三维姿态；屏幕上的伤害文字继续由原有反馈层显示，完成句柄与取消清理继续推进队列。
- 删除无调用的 UI 查询和别名、旧动作分组哈希、旧能量费用计算、重复的效果类型列表和未使用的自定义 VM 注册器入口。规则结算仍来自原生核心。
- 删除交互索引中无人读取的选中状态、系统动作缓存和整份输入列表副本。
- 将 DTO、动作、修正项和网络中的五份相同整数校验统一到 `WireValue.is_integer()`。保留原有数值边界：原生整数使用 int64，JSON 浮点输入必须是有限、精确且位于 int32 范围内的整数；布尔值、字符串、小数、NaN 和无穷大被拒绝。
- 将 Workbench、卡牌列表、卡牌详情和牌区详情的相同 Label 构建统一到 `DesignTokens.label()`。

调用审计同时检查代码、场景资源和文档中的引用。Godot 的 `_get_tooltip` 回调及显式音频、缓存诊断入口保留。现有用户动画偏好读取、视图隐私、取消／重同步、当前协议校验和仍使用中的 AI 搜索分支均有实际用途，未按名称中的“legacy”或“fallback”直接删除。

## 验证与记录

- Godot 15 项契约通过；整数边界、拖拽生命周期、隐藏信息、动作队列、选择与附件检查通过。
- 实际三维图形回归和完整 UI 预览通过，覆盖多种分辨率、密集手牌、附能／转移、快速插洗、双方视角连续再战和三种动画模式。
- 10 套牌的 Challenge AI 对局全部完成。
- LAN 完整对局 42 回合、111 次动作、37 次选择；Relay 完整对局 41 回合、114 次动作、40 次选择，均正常结束并确认终局。
- 内容检查通过：137 张卡、10 套牌、160 个效果、80 个 VM 操作；内容指纹为 `f49ee62425b37e4c0a23c08f888499d3741a8db41753be64746382023355cf9a`，与清理前一致。
- 产品边界、源码限制和 `git diff --check` 通过。

[清理前清单](../build/code-cleanup/baseline-manifest.json)、[逐文件统计](../build/code-cleanup/source-changes.json) 和 [本次源码差异](../build/code-cleanup/source-changes.diff) 可用于复核；清理前的源码副本保存在 `build/code-cleanup/baseline/`。

验证日志：[Godot](../build/code-cleanup/godot-contracts.log)、[三维图形](../build/code-cleanup/graphics.log)、[图形检查细项](../build/code-cleanup/visual-checks.json)、[AI](../build/code-cleanup/ai.log)、[联机](../build/code-cleanup/network.log)、[内容](../build/code-cleanup/content.log)。

Windows／Android 调试包已重新导出，Windows 启动、原生运行时和网络检查通过，Android ARM64 包静态检查通过。包大小、SHA-256 和交付结果见 [交付记录](../build/code-cleanup/delivery.json)，运行检查见 [打包验证日志](../build/code-cleanup/smoke.log)。

本轮以维护性和行为回归为目标，没有重测性能基准。Android 真机触控、持续帧率和温升仍需连接设备验收。

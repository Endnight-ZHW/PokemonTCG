# 操作提示中文化与对手再战展示

对战中已取消左上角的普通状态提示，包括玩家和 AI 操作完成、选择提交、选择结算及取消成功等通知；操作反馈由卡牌动画和行动记录呈现。操作失败、断线等需要处理的问题仍提供中文提示。切换页面会清除旧提示，避免大厅通知残留在牌桌上。

提示条此前直接显示原生规则的 `message_key`，因此出现 `action_applied`、`choice_applied` 等内部标识。`PlayerFacingText` 在界面显示时转换中文，同时覆盖常见规则错误、选择禁用原因、能量分配提示、联机状态及纯消息键形式的行动记录。原生结果和协议里的标识保持原值，未知消息键使用中文提示，现有中文、玩家名字和地址不被改写。

对手开局再战时，抽到的卡牌继续使用原有三维手牌实体。进入公开阶段后，同一批卡牌移到中央并朝向镜头完整展开：宽屏一行七张，小屏分为两行，卡面下方显示中文名称。1600×900 下卡面约 180px 宽，900×540 下约 108px 宽，卡图互不遮挡。标准和快速模式的公开阶段至少 3.3 秒，减少动画保留 2.8 秒结果阅读时间。

公开结束后平滑洗回牌库，已到达的卡牌立即移交显示，避免多张回收卡重叠停留。私有抽牌阶段仍只显示对手卡背；取消、重同步、视角切换及结束时清理临时实体和展示文字。

## 验证

Godot 15 项契约及完整图形回归通过。新增通知检查直接验证显示后的中文，并确认原生 `match_created` 消息键不变。实际渲染检查覆盖双方视角各三次连续再战、常规及小屏的标准／快速／减少动画模式、取消清理和返回牌库的交接。

Windows 与 Android 调试导出完成。打包后的 Windows 启动、原生规则和网络能力检查通过；Android ARM64 包元数据与资源静态检查通过。交付记录包含安装包大小、SHA-256 及验证日志。

取消普通通知后，已复跑 Godot 15 项契约和实际 UI 预览，均通过；记录见 [Godot 回归](../build/battle3d-quiet-notifications/godot-contracts.log)、[界面预览](../build/battle3d-quiet-notifications/ui-previews.log) 和 [更新后的交付包](../build/battle3d-quiet-notifications/delivery.json)。

- [实际图形回归记录](../build/battle3d-localization-mulligan-fixes/visual-checks.json)
- [展示与返回交接的定向复测](../build/battle3d-localization-mulligan-fixes/readability.json)
- [宽屏展示](../build/battle3d-localization-mulligan-fixes/opponent-reveal-1600x900.png)
- [小屏展示](../build/battle3d-localization-mulligan-fixes/opponent-reveal-900x540.png)
- [交付校验](../build/battle3d-localization-mulligan-fixes/delivery.json)

Android 真机触控和持续运行仍待连接设备后验收。本轮未重复性能基准，此前低画质帧时间的待优化记录见 [入手与附能修正](BATTLE_3D_CARD_TRANSFERS.md)。

# 对战界面与交互更新

采用奶油米色与浅木质感，保留现有卡图、规则和鼠标／触控输入方式。公共颜色和控件样式见[暖色 UI 说明](WARM_UI_REDESIGN.md)，网络协议和存档格式保持兼容。

## 界面与操作

- 牌桌减少金属描边和重复光效；回合主按钮、当前行动方、选中卡与合法目标使用一致的视觉层级。
- 安全区达到 1180×650 时将卡牌详情放在左侧，选择放置、进化、附能或道具目标时继续显示来源卡效果；较小窗口默认显示卡名和动作，通过“详情”或长按进入完整检查器。
- 操作说明集中在顶部任务栏；卡面和卡牌下方不再重复显示无法操作／目标提示。动作浮层只在存在可执行动作时打开，已使用特性在卡牌详情中查看。
- 卡牌长按 350ms 即显示详情；滑动、失焦、触控取消和卡牌被重新绑定时不会误触。第二根手指与模拟输入不会重复操作卡牌。
- 再次点击来源卡、点击空白处或按“取消”可退出未提交的操作。非法场上目标不会替换来源卡，另一张手牌仍可直接切换选择。
- Android 返回按弹窗、详情、日志、拖拽／选择、对局菜单逐层处理。强制规则选择不能被取消；查看详情后恢复原来的卡牌和动作选择。
- 退出增加确认；结束回合只提醒仍可附能、使用支援者或攻击。确认动作保留原始局面版本，过期确认不执行。
- 抽牌或出牌后按卡牌视觉身份保留手牌浏览位置；修复对手手牌刷新后尺寸跳变及数量徽章被卡背盖住的问题。
- 紧凑选择弹窗优先展示目标，压缩来源预览，固定底部确认区域；展开详情后返回时保留选择和滚动位置。

## 验证

```powershell
.\tools\test_godot.ps1
.\tools\test_godot_ai.ps1
.\tools\test_godot_network.ps1

.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --path godot --script res://tests/ui_preview.gd
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --path godot --script res://tests/ui_preview.gd -- --battle-usability-only
.\.tools\godot-4.7\Godot_v4.7-stable_win64.exe --path godot --script res://tests/ui_preview.gd -- --semantic-choice-only
```

新增 `battle_usability_contract.gd`，覆盖长按与点击互斥、多指、取消事件、失焦、卡牌重绑、非法目标、逐层返回、空白取消、浏览位置、详情恢复、强制选择、退出确认及过期确认。

截图覆盖 1600×900、1280×720、900×540、2000×900、四边 48px 安全区，以及低画质／减少动画。AI 回归覆盖 10 套牌组；LAN 与 Relay 各完成一场同牌组对局并确认终局。

Android：已运行模拟触控和系统返回事件回归。当前 ADB 未连接设备，尚未进行真机测试；本次没有生成或安装新的 APK。

## 截图对照

原始截图保存在 `build/ui-preview/before/`，更新后的截图由预览脚本生成。

| 场景 | 更新前 | 更新后 |
| --- | --- | --- |
| 宽屏牌桌与详情 | [原图](../build/ui-preview/before/battle-card-detail-redesign.png) | [新图](../build/ui-preview/battle-ui-1600x900.png) |
| 紧凑牌桌 | [原图](../build/ui-preview/before/battle-card-detail-redesign-compact.png) | [新图](../build/ui-preview/battle-ui-900x540.png) |
| 紧凑目标选择 | [原图](../build/ui-preview/before/choice-treasure-energy-compact.png) | [新图](../build/ui-preview/choice-treasure-energy-compact.png) |

[完整卡牌检查器](../build/ui-preview/battle-ui-inspector-compact.png) · [退出确认](../build/ui-preview/battle-ui-exit-confirm.png) · [安全区与目标提示](../build/ui-preview/battle-ui-target-safe-compact.png)

测试日志：`build/battle-ui-godot-tests.log`、`build/battle-ui-ai-tests.log`、`build/battle-ui-network-tests.log`。截图及日志属于本地验证产物，不进入游戏发布资源。

# 三维重构提交前审核

审核范围为 `3129e3d` 之后尚未提交的三维对战、交互修正和代码清理改动。

## 审核中修复的问题

1. **隐藏牌桌后自动画质回升。** 页面隐藏时原先结束了本局画质状态，重新显示后会重新选择默认档位。现改为隐藏时停止三维更新并清空帧样本，本局有效画质保留到场景退出。
2. **开始回调取消后仍应用旧局面。** `transition_started` 的监听者取消或重同步时，同步完成的卡图预取没有再次检查批次版本，随后仍会写入已取消的目标局面。现增加回调后及预取后的批次版本检查。

新增 `battle_3d_lifecycle_review_checks.gd`，在修复前分别复现上述问题，修复后通过。检查同时验证取消完成句柄、取消后的队列恢复、隐藏页面停止渲染和用户保存的画质选项。

## 验证

- Godot 15 项契约通过，新增检查同时纳入三维契约。
- 完整三维图形回归和 UI 预览通过；源码与产品边界、暂存差异格式检查通过。
- Windows 与 Android 调试导出通过；Windows 启动、原生运行库与网络冒烟检查通过，Android ARM64 包静态检查通过。
- 本轮代码清理后的 10 套 Challenge AI 对局与 LAN／Relay 完整对局已通过，记录见 [清理说明](CODE_CLEANUP.md)。
- 实际图形压力场景复测：Godot 4.7 Compatibility、RTX 4070 Ti、1920×1080，各档预热后采样 300 帧。

| 档位 | P95 帧时间 | 目标 | 绘制调用 |
| --- | ---: | ---: | ---: |
| 高 | 17.184 ms | ≤ 20 ms | 308 |
| 中 | 17.081 ms | ≤ 20 ms | 308 |
| 低 | 33.834 ms | ≤ 36 ms | 209 |

本次固定压力场景的三档均达标。此前低档超时记录保留在历史修正文档中；此次复测不能替代 Android 真机或长时间连续对局测量，也不将改善归因于某一项代码删除。

可重跑命令：

```powershell
.\tools\test_godot.ps1
.\tools\test_battle3d_graphics.ps1
.\tools\test_godot_ai.ps1
.\tools\test_godot_network.ps1
```

本地原始记录：[修复前复现](../build/main-review/lifecycle-before.log)、[修复后复测](../build/main-review/lifecycle-after.log)、[Godot 回归](../build/main-review/godot.log)、[图形回归](../build/main-review/graphics.log)、[性能采样](../build/main-review/performance.json)。

Android 真机触控、持续帧率与温升仍待连接设备后验收。

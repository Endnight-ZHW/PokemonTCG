# 抽牌、清晰度与扇形布局修正 · 2026-09-13

本轮处理四项实际截图反馈，保留现有规则、卡图、玩家视角过滤、视觉身份和动作完成句柄。

| 问题 | 修正 |
| --- | --- |
| 抽牌时牌堆上出现交叉卡背 | 延迟出发的飞牌保持隐藏；出发前直接保存牌堆顶牌的完整三维姿态。抽牌使用更快离开源牌堆、缓慢落入手牌的曲线。渲染在 Tween 更新之后同步，避免源牌、飞牌与落点相差一帧 |
| 手牌和场上卡图模糊 | 三维 SubViewport 按最终屏幕像素尺寸分配，覆盖窗口拉伸、UI 缩放和高 DPI。显示控件只负责合成；高档按原生像素渲染，中低档仍使用各自的三维比例，HUD 独立显示 |
| 手牌没有共同圆心，两端截断 | 使用一个倾斜的三维圆弧，所有卡牌的朝向指向玩家侧圆心；统一缩放和定位整副手牌。密集手牌保留按视觉身份维护的浏览位置，两端通过角度压缩始终完整显示，选中卡牌抬起 |
| 对方战斗区、备战区不对称 | 按可见牌区镜像放置双方，统一对应卡牌的屏幕宽度，补偿远侧缩小与列向内收拢；远侧卡图更大。牌堆列同步对齐，小屏侧牌堆向外让出备战空间 |

关联修复：洗牌改为两个完整、有厚度的牌包，先抬起上半包，再分开、旋转和合拢，避免六个独立分片互相穿插；多附件仅露出紧凑纸边，防止覆盖下一排宝可梦。隐藏卡继续只绑定通用背面。

手牌暂存同时保存语义排布中心与三维姿态。插入、移出和收拢时从原有实体姿态插值到目标扇形，避免把投影中心再次解释成排布坐标；完成、取消与重同步清理临时姿态。回归检查覆盖“抽牌开始前已有手牌保持原位”及“收拢结束后没有冻结姿态”。

分辨率处理参考 [Godot SubViewportContainer 的尺寸约束](https://docs.godotengine.org/en/stable/classes/class_subviewportcontainer.html)。原来的 stretch 容器使子视口停留在逻辑尺寸；新的 TextureRect 显示独立 SubViewport，投影接口仍使用 BattleTable 局部坐标。mipmap 保留，未使用 Compatibility 不支持的 `Viewport.texture_mipmap_bias` 调节项（[Godot Viewport 说明](https://docs.godotengine.org/en/stable/classes/class_viewport.html#class-viewport-property-texture-mipmap-bias)）。

## 重放与检查

运行 `godot/tools/ui_workbench.tscn`：

- “连续抽 7 张”重放从 60 张牌库依次抽取的过程，支持现有 0%、50%、100% 检查点。
- “三维开局洗牌”检查完整牌包的抬起、分开与回落。
- “三维细节检查”覆盖满备战、20 张手牌、多附件与复合状态。

图形契约检查 1600×900、1280×720、900×540、2000×900、2560×1392；最高尺寸同时启用逻辑画布缩放，直接验证实际渲染缓冲大于逻辑尺寸。逐帧检查连续抽牌的延迟可见性、源姿态、单张厚度、渲染同步与动作结束清理；镜像布局还检查侧牌堆碰撞和手牌浏览边界。

[高分辨率实拍](../build/battle3d-sharp-2560.png) · [抽牌中途](../build/battle3d-draw-12.png) · [洗牌](../build/battle3d-startup-shuffle.png) · [图形检查记录](../build/battle3d-visual-contract.json)

验证命令：`tools/test_godot.ps1`、`tools/test_battle3d_graphics.ps1`、`tools/test_godot_ai.ps1`、`tools/test_godot_network.ps1`、`tools/build_godot.ps1 -Target all -Configuration debug`。Android 真机触控、持续帧率与温升仍需连接设备后验收。

## 验证结果

Godot 全部 14 项契约、实际图形契约和完整 UI 预览通过；10 套 Challenge 卡组均完成终局，LAN 42 回合与 Relay 41 回合完整对局通过。原生协议和存档格式未变。

RTX 4070 Ti、1920×1080 实际图形采样：高/中/低档 P95 分别为 16.730 / 16.741 / 33.458ms，绘制调用分别为 308 / 308 / 209。中档最大单帧 52.219ms，P95 在 60 帧档预算内。高档按原生像素渲染后的纹理统计约 112.8MB；重复进出对局节点回收检查通过。[性能原始记录](../build/battle3d-performance.json)。

Windows 和 Android 调试导出已更新，Windows 图形启动、原生 AI、网络及发布契约检查通过，APK ARM64 内容和静态检查通过；设备运行检查明确跳过，原因是没有连接 ARM64 真机。交付为 `build/PokemonTCG-3D-Windows-debug.zip` 与 `godot/dist/android/PokemonTCG.apk`，[文件校验记录](../build/battle3d-draw-layout/delivery.json)。

# 拖拽倾角、中央闪卡与手牌圆弧修正

本次修正用户反馈的拖拽倾斜过大、中央仍闪卡，以及手牌圆弧需要稍放缓的问题。

## 中央闪卡的另一条路径

此前已修复对手手牌暂存代理使用默认姿态的问题。本次在真实 OpenGL 渲染中仍复现了对象池复用后的首帧闪卡：CPU 侧的三维姿态已经正确，画面中的网格却仍出现在世界原点。连续拖拽与延迟飞行探针共记录到 4 帧异常，因此仅检查 `Node3D.transform` 无法覆盖这条路径。

表现层在 `frame_pre_draw` 中复制 Tween 的最新姿态，而网格的变换通知还可能留在延迟队列。现在卡面、描边和接触阴影在绘制前显式调用 `force_update_transform()`，把本帧姿态送到对应渲染实例；空牌位描边同样同步。硬币的网格和文字也使用相同的同步时机。相关引擎接口见 [Node3D 文档](https://docs.godotengine.org/en/stable/classes/class_node3d.html#class-node3d-method-force-update-transform)。

新增 `battle_3d_render_lifecycle_checks.gd`，逐帧读取实际三维视口的像素，使用特征色检查首帧显示、拖拽、松手、提交、延迟飞行、对象池复用和重同步。既检查中央没有异常像素，也确认测试卡牌确实被绘制。覆盖演出、标准、快速、减少动画四种模式。

## 拖拽与圆弧

- 拖拽使用独立的 4° 轻微倾角，两侧起手时的横向旋转限制为 ±3°。先确定旋转，再计算抓取偏移。
- 取消拖拽时插值三维位置、朝向和尺寸，完整回到手牌扇形，消除最后一帧突然切换角度的问题。
- 静止手牌的基础圆弧半径从 8 增至 9.5 个卡宽单位，增加约 19%。密集手牌继续按可用宽度收拢，两端完整显示，居中排列保持均匀间距。

## 验证与交付

运行 `tools/test_godot.ps1`、`tools/test_battle3d_graphics.ps1` 和 `tools/test_source_boundaries.ps1`。图形契约覆盖 1600×900、1280×720、900×540、2000×900、2560×1392，以及密集手牌、双方牌区尺寸和间隙、连续抽牌和洗牌。

14 项 Godot 契约、图形契约和 UI 预览全部通过。新增生命周期检查共采集 369 个实际渲染帧，其中 255 帧绘制了特征色卡牌，中央异常像素为 0；回位目标与最终手牌包围区域的最大偏差约 0.000061px。5、7、10、20 张手牌的相邻中心间距最大/最小比值均低于 1.046。

RTX 4070 Ti、1920×1080、Compatibility 渲染下，高/中/低档各采集 300 个实际渲染帧，P95 分别为 17.031/16.918/33.587ms，绘制调用分别为 308/308/209，均满足对应帧时间目标。10 套 Challenge 卡组终局回归，以及 LAN 42 回合、Relay 41 回合完整对局回归通过。

Windows 与 Android 调试导出已更新。导出包的 Windows 启动、原生运行库、网络和发布契约检查，以及 Android APK 元数据和 ARM64 载荷检查全部通过。Windows 压缩包仅包含当前可执行文件、控制台入口、PCK 和原生规则 DLL，并已核对文件条目和长度。

- [逐帧画面和布局检查记录](../build/battle3d-drag-fixes/visual-checks.json)
- [实际图形性能采样](../build/battle3d-drag-fixes/performance.json)
- [拖拽效果](../build/battle3d-drag-fixes/drag-after.png)
- [牌桌与手牌效果](../build/battle3d-drag-fixes/after.png)
- [构建文件校验](../build/battle3d-drag-fixes/delivery.json)

Android 真机触控、持续帧率和温升仍待设备验收，桌面图形测试与 APK 静态检查不替代真机测试。

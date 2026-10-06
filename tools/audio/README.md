# 音频制作与验证

运行时素材位于 `godot/assets/audio`，由 `AudioCatalog` 引用：87 个声音事件、每个 3 个实际 WAV 变体、7 首 Ogg Vorbis 音乐。音效为 48 kHz / 16-bit / mono；音乐为 48 kHz / stereo / Vorbis q5。运行时不生成波形、不下载素材。

## 重建

仓库本地工具位置：`.tools/audio/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe`。使用 FFmpeg 7.1.1 essentials build，原始素材缓存位于 `.cache/audio-sources`。可以从 [Gyan 历史构建](https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-7.1.1-essentials_build.zip) 解压至该目录。

```powershell
./tools/build_audio.ps1             # 重建音效、音乐、Resource 目录和制作清单
./tools/build_audio.ps1 -SfxOnly    # 只重建音效，保留既有音乐
./tools/build_audio.ps1 -MusicOnly  # 只重建音乐，保留既有音效
./tools/build_audio.ps1 -Check      # 检查所有发布音频与 Resource 的 SHA-256
./tools/test_godot.ps1              # 包含音频系统、战斗动画与界面契约
```

`source_packages.json` 固定 Kenney 包的 SHA-256。`music.json` 固定每首原声的无损下载地址、来源页、SHA-256、曲名和循环点。缓存缺失时制作脚本下载素材；校验失败立即停止。`fetch_music.ps1` 仅用于显式重新发现源文件，不会覆盖已审核的 `music.json`。

音频 `.tres` 固定使用 UTF-8／LF；Git 检出与制作脚本使用同样的换行格式，避免资源哈希随平台改变。客户端回归入口会先执行 `build_audio.ps1 -Check`，无需下载素材或安装 FFmpeg。

`manifest.json` 记录输入素材路径与 SHA-256、每个变体的 FFmpeg 处理链以及输出文件哈希。音效由不同实体采样叠层、滤波、回声、轻微变速、瞬态控制与首尾淡化制作，并按分类统一峰值、确保首尾样本归零；洗牌和开盒还叠加不同纸张滑动素材。音乐使用固定增益对齐至 -20 LUFS 或受 -2 dBTP 峰值限制的更低响度，在循环结束前 40 ms 混合循环点前的对应片段，避免音乐结束后的淡出／静音进入循环。

## 来源

- Kenney Casino Audio、Impact Sounds、Interface Sounds：CC0。原文许可证随资源保存在 `godot/assets/audio/licenses`。
- 音乐来自《宝可梦 红宝石／蓝宝石》《宝可梦 火红／叶绿》和《宝可梦 心金／魂银》原声；作品归 Nintendo / Creatures / GAME FREAK 等原权利方所有，不属于 CC0。具体原作、专辑、曲目页、源文件和处理参数见 `music.json`。

## 战斗混音打磨

首页使用 GBA《红宝石／蓝宝石》的未白镇（Littleroot Town），保留完整旋律周期与原生循环。其它场景的配乐映射保持现有选择。

蓄力先截取真实瞬态，再倒放形成 220 ms 的短渐强，避免截到源文件尾部静音。普通命中按属性使用 280～500 ms 的不同衰减；重击保留同属性的细节层，叠加延后 32 ms、低通 550 Hz 的实体冲击，长度为 480～780 ms。水、雷、钢等高频层分别滤波；异常状态、检查和回合结束降低存在感。

命中或攻击失败会结束同一作用域内尚在播放的蓄力。160 ms 内的多个命中仍逐个播放，后续声音每层衰减 2 dB、最多 6 dB；连续纸张动作每层衰减 1 dB。相同事件仍去重，不同目标不再被全局冷却吞掉。普通命中压低音乐 2.5 dB，重击压低 4.5 dB，日常状态提示不再频繁压低音乐。固定变体试听保持固定音高与音量。

## 运行时接口

- `AudioDirector.play(AudioCueRequest)`：播放带事件、阶段、子动作序号和归属范围的音效。`play_ui`、`play_cue` 为简单调用入口。
- `cancel_scope`：只取消所属声音。牌桌为 `battle`，每个硬币展示有独立 `coin:<instance_id>`，首页为 `home`，结算为 `result`。
- `GameMusicDirector`：准备、两首普通对战曲、高潮、胜负结算。两首普通曲逐局轮换；高潮仅根据演出完成后公开的奖励卡数量进入，并保持至结算。
- `AudioVoicePool`：16 个 SFX 声部、4 个 UI 声部，独立随机源、避免连续重复、按声音的优先级／并发数／冷却调度。
- Master 保留 -1 dB 限幅；重要音效通过音乐播放器增益压低音乐，不修改用户音量。界面和音效仍共用现有音效滑杆。

新声音应增加 Resource 和制作配方，并绑定真实的表现节点。不要修改 native 规则或将音频随机数写入网络、快照、journal。

## 试听

打开 `godot/tools/ui_workbench.tscn`，侧栏底部「声音实验台」可以选择分类、声音、固定变体、音乐，以及连续战斗演出。停止按钮同时取消动画与声音；其它动画选项仍可检查十属性、双视角及四档动画。

```powershell
. ./tools/godot_test_common.ps1
$paths = Initialize-GodotTestEnvironment -RepoRoot (Get-Location).Path
& $paths.Console --headless --path godot --script res://tools/audio_review.gd
```

会将真实 Godot 混音（含压低音乐、交叉淡化和自然变体）录制到 `build/audio-review/after.wav`。本次升级同时保留 `before.wav`；`--baseline` 需要该目录中预先保存、去掉 `class_name` 的旧 `legacy_audio.gd`。这些对照文件属于构建产物，不进入发布包。

导出烟雾检查会实际加载全部音效和音乐，检查变体数量、时长和循环点。Android 后台恢复仍需要连接设备执行真机验收。

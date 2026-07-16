# PokemonTCG Godot 0.4.0

Godot 4.7 是唯一发布客户端。本版以中国大陆官方玩法规则和《进阶玩家向规则指南
Ver.3.1.0》为裁决依据，同时更新 Godot 客户端、Python 参考引擎、联机协议、AI 和现有
137 张卡牌数据。

## 规则对齐

- 开局硬币获胜者在查看初始手牌前选择先攻或后攻；先攻玩家第一回合照常抽牌，但不能使用
  支援者、攻击或通常进化。
- 再战按同一轮双方次数相抵，设置奖赏卡后由奖励方选择额外抽 `0..N` 张；奖励抽到的基础
  宝可梦只能追加到备战区。双方设置完成前，对手只看到 `{"hidden":true}` 卡背占位。
- 攻击伤害固定按“基础伤害 → 攻击方修正 → 弱点 → 抗性 → 防守方修正/防止”计算；备战区
  目标只跳过弱点和抗性。伤害、伤害指示物和直接昏厥使用独立语义。
- 多目标伤害先全部计算再同时落伤。效果完成后批量处理昏厥、实体触发、弃置和逐张奖赏卡，
  之后才判定胜负；需要双方晋升时，由下一回合玩家先选择。
- 同批次双方达成相同数量且大于 0 的胜利条件时记录 `DRAW`，`winner=-1`，不产生软胜者。
- 进化、撤退和强制换位统一清除特殊状态与该宝可梦受到的临时招式效果，同时保留伤害、能量、
  道具和进化链。
- 竞技场记录所有者并按名称判重。引擎/网络入口检查 60 张、基础宝可梦、未知 ID、同名 4 张、
  基本能量例外以及特殊卡数量限制。

## 卡牌与结算基础设施

- 新增统一有效能量视图：双重涡轮提供两个无色单位；夜光能量只有在不存在其他特殊能量时
  提供任意类型，第二张夜光也会令其降为无色。
- 可暂停结算使用可序列化 continuation/resolution 数据；snapshot v2 能在选择、伤害、触发、
  昏厥、奖赏卡和晋升等暂停点往返，不保存回调或场景对象。
- 修复宝藏能量、每张幸运能量、多个学习装置、帝王拿波“紧急上浮”及同名实体索引。
- 甲贺忍蛙 ex、帝王拿波、阿勃梭鲁、拖拖蚓等多目标伤害进入统一伤害管线；苍响与海星星按
  各自卡文分别忽略弱点、抗性或防守伤害效果，且不会关闭受到伤害后触发。
- 修正梅洛可、古玉鱼、藏玛然特、拉普拉斯的上个对手回合昏厥事实，以及大奶罐按自身实际
  回复 HP 判定的语义。
- 勾帕路翁、摔跤鹰人、玛俐的自尊先选择具体能量实体再分配；嘉德丽雅保留玩家指定的牌库底
  顺序。劈斧螳螂直接昏厥不伪装为伤害；路卡利欧、嘟嘟利等自昏厥特性仍可合法发动。

## 联机、UI 与 AI

- Protocol v4 携带 `CN_MAINLAND_3_1_0`、锁定的规则选项、开局阶段、平局结果和竞技场所有者。
  Protocol v3 房间及 snapshot v0/v1 只提供明确不兼容诊断，不执行猜测性迁移。
- 联机弱点/抗性由房主开局前设置，挑战者只读确认；默认关闭属于项目自定义特例，不是官方规则。
- UI 增加先后攻、再战奖励数、暗置卡背、奖赏卡位置选择、触发顺序和平局结果；本地热座也使用
  玩家视图隔离暗置信息。
- Challenge AI 对新增选择采用确定策略，并且只读取当前玩家视图。旧 Deep v10 模型仍绑定
  Python rules v2 / Godot rules v3，未重新盖章；发布版记录 `deep_runtime_enabled=false`、
  `deep_fallback=challenge`、0 个兼容模型和 10 个历史模型。

## 发布合同

- 产品版本 `0.4.0`；Android `versionCode=6`、`versionName=0.4.0`。
- Manifest format 2；Protocol 4；Godot rules/actions 4/3；Python rules/actions 3/2；
  snapshot 2；VM IR 2；encoder/checkpoint 3/10；planner 1；portable RNG 1。
- 保留 10 套休闲预组：fire、water、psychic、lightning、fighting、colorless、dragon、
  grass、steel、darkness。本版不强制标准赛 G/H/I 轮换标记。
- 基本能量为草、火、水、雷、超、斗、恶、钢；无色不是基本能量，也不存在龙基本能量。

## 验证顺序

```powershell
.\tools\test_fast.ps1
.\tools\test_standard.ps1
.\tools\test_godot_network.ps1
.\tools\build_native_ai.ps1 -Target all -Configuration debug
.\tools\build_godot.ps1 -Target all -Configuration debug
.\tools\smoke_godot_build.ps1
.\tools\test_release.ps1
```

Android 正式商店签名和目标真机矩阵仍需在发布环境中执行。本版不发布 Python 客户端，也不支持
旧协议房间恢复、房主迁移或一奖赏卡抢分赛。

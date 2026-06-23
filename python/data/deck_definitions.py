"""Pre-built starter deck card-ID lists.
Each deck is a list of (api_id, count) tuples. Each deck has exactly 60 cards.
Card IDs are from pokemontcg.io API v2 format (e.g., 'sv3-26').

Deck themes:
    FIRE DECK: 烈焰猴核心 — 进化快攻，螺旋业火翻顶输出
    WATER DECK: Greninja — Consistency, bench damage, card draw
    PSYCHIC DECK: 天然雀/天然鸟 — Hand energy acceleration, multi-core basics
    LIGHTNING DECK: Pikachu ex — High-damage core with energy recycling
    FIGHTING DECK: Koraidon ex — Fighting energy acceleration
    COLORLESS DECK: 一家鼠ex核心 — 手牌增伤，特殊能量灵活战术
"""
import random

# ============================================================
# 🔥 FIRE DECK — Charizard ex / Pidgeot ex (60 cards)
# Strategy: Use Rare Candy to evolve Charmander -> Charizard ex,
# trigger Infernal Reign to attach 3 Fire Energy, attack immediately.
# Pidgeot ex provides consistency with Quick Search.
# ============================================================

FIRE_DECK = [
    # Pokemon (15)
    ("svi-ente", 1),     # 炎帝 - 130 HP, Basic (压迫感减伤 / 火焰之球: 60+)
    ("svi-chim", 4),     # 小火焰猴 - 50 HP, Basic (火花: 30→丢1能)
    ("svi-monf", 3),     # 猛火猴 - 80 HP, Stage 1 (火焰: 30 / 喷射火焰: 50→丢1能)
    ("svi-infr", 4),     # 烈焰猴 - 150 HP, Stage 2 (螺旋业火: 80× / 燃烧踢: 160→丢全能)
    ("svi-hrot", 1),     # 加热洛托姆 - 90 HP, Basic (高温冲撞: 100→自伤40)
    ("svi-chiy", 1),     # 古玉鱼 - 110 HP, Basic (闪焰生成: 附2火能 / 嫉妒业火: 50+90)
    ("svi-sqwk", 1),     # 怒鹦哥 - 70 HP, Basic (呼朋引伴: 找2基础 / 飞翔: 60→免疫)

    # Trainer (30)
    ("svi-erec", 2),     # 能量再利用 - 弃牌区最多5张基本能量→回牌库
    ("sv3-134", 2),      # 厉害钓竿 - 弃牌区3张回牌库
    ("sv1-151", 4),      # 巢穴球 - 牌库找基础宝可梦→备战区
    ("sv1-153", 4),      # 高级球 - 丢2手牌→牌库找宝可梦
    ("sv1-152", 2),      # 神奇糖果 - 基础直接进化2阶
    ("sv1-150", 2),      # 宝可梦交替 - 出战与备战互换
    ("sv2-catch", 2),    # 宝可梦捕捉器 - 硬币正面→抓对手备战
    ("sv1-176", 1),      # 裁判 - 双方洗手牌→抽4
    ("sv2-young", 3),    # 短裤小子 - 洗手牌→抽5
    ("sv1-180", 4),      # 妮莫 - 抽3
    ("sv1-189", 2),      # 博士的研究 - 丢手牌→抽7
    ("svi-mela", 2),     # 梅洛可 - 上回被击倒→弃牌区附1火能+抽到6张

    # Energy (15)
    ("sv1-ener-2", 15),  # 基本火能量
]

# ============================================================
# 💧 WATER DECK — Greninja ex / Starmie (60 cards)
# Strategy: Greninja ex as main attacker with 隐蔽手里剑 to
# target any Pokemon and 激流斩 for conditional burst.
# Starmie provides 神秘彗星 for snipe + self-KO.
# ============================================================

WATER_DECK = [
    # Pokemon (18)
    ("sv2-38", 3),      # 呱呱泡蛙 - 70 HP, Basic
    ("sv2-39", 2),      # 呱头蛙 - 90 HP, Stage 1
    ("sv2-grex", 2),    # 甲贺忍蛙ex - 300 HP, Stage 2 ex
    ("sv1-49", 1),      # 拉普拉斯 - 130 HP, Basic (Freeze Beam: Paralyze)
    ("sv2-keldeo", 1),  # 凯路迪欧 - 110 HP, Basic
    ("sv2-glast", 1),   # 雪暴马 - 130 HP, Basic
    ("sv2-tatsu", 1),   # 米立龙 - 70 HP, Basic
    ("sv2-delib", 1),   # 信使鸟 - 60 HP, Basic
    ("sv2-staryu", 3),  # 海星星 - 60 HP, Basic
    ("sv2-starm", 3),   # 宝石海星 - 90 HP, Stage 1

    # Trainer (27)
    ("sv2-young", 3),   # 短裤小子 - 洗手牌，抽5
    ("sv2-cand", 2),    # 小菘 - 看牌库顶7张，拿水宝可梦+水能量
    ("sv1-180", 4),     # 妮莫 - 抽3
    ("sv1-189", 2),     # 博士的研究 - 丢手牌，抽7
    ("sv1-176", 1),     # 裁判 - 双方洗手牌，抽4
    ("sv3-134", 1),     # 厉害钓竿 - 弃牌区3张回牌库
    ("sv1-151", 4),     # 巢穴球 - 找基础宝可梦
    ("sv1-153", 4),     # 高级球 - 丢2，找宝可梦
    ("sv1-152", 2),     # 神奇糖果 - 基础→2阶进化
    ("sv1-150", 2),     # 宝可梦交替 - 换位
    ("sv2-catch", 2),   # 宝可梦捕捉器 - 硬币→抓对手备战

    # Energy (15)
    ("sv1-ener-3", 15), # 水能量
]

# ============================================================
# 🔮 PSYCHIC DECK — 天然雀/天然鸟核心 (60 cards)
# Strategy: 天然鸟「以太感知」手牌充能+过牌。月石循环过牌，
# 代欧奇希斯能量转附，克雷色利亚加速充能。拉帝欧斯高伤核。
# ============================================================

PSYCHIC_DECK_NATU = [
    # Pokemon (16)
    ("sv1-107", 3),       # 天然雀 - 50 HP, Basic (三连突刺: 3硬币×10)
    ("sv1-108", 2),       # 天然鸟 - 100 HP, Stage 1 (以太感知: 手牌充能+抽2 / 超念力: 80)
    ("sv1-109", 1),       # 月石 - 90 HP, Basic (循环抽取: 弃1抽3 / 月亮强念: 30+超能量×30)
    ("sv1-110", 1),       # 拉帝亚斯 - 110 HP, Basic (薄雾飘浮: 条件0撤退 / 念动弹: 100)
    ("sv1-111", 2),       # 拉帝欧斯 - 110 HP, Basic (滑翔: 20 / 洁净光芒: 180→弃3能)
    ("sv1-112", 1),       # 代欧奇希斯 - 120 HP, Basic (精神拳: 30 / 基因螺旋: 120→能量全转备战)
    ("sv1-113", 1),       # 克雷色利亚 - 120 HP, Basic (新月生长: 牌库充能 / 光子镭射: 30+90)
    ("sv1-114", 1),       # 咚咚鼠 - 70 HP, Basic (小使者: 找2基本能量 / 旋转折返: 50+换位)
    ("sv1-104", 2),       # 墓仔狗 - 70 HP, Basic (啃咬: 10 / 幽魂射击: 20)
    ("sv1-106", 1),       # 墓扬犬 - 140 HP, Stage 1 (扫墓: 80+弃牌区超宝可梦×10)

    # Trainer (29)
    ("sv1-171", 1),       # 能量回收 - 弃牌区最多2张基本能量→手牌
    ("sv1-151", 3),       # 巢穴球 - 牌库找基础宝可梦→备战区
    ("sv1-153", 4),       # 高级球 - 丢2手→牌库找宝可梦
    ("sv1-150", 4),       # 宝可梦交替 - 出战与备战互换
    ("sv2-catch", 2),     # 宝可梦捕捉器 - 硬币正面→抓对手备战
    ("sv1-201", 1),       # 不服输头带 - 落后时伤害+30
    ("sv1-202", 2),       # 勇气护符 - 基础宝可梦HP+50
    ("sv1-203", 1),       # 克拉拉 - 弃牌区回收2宝可梦+2基本能量
    ("sv1-176", 1),       # 裁判 - 双方洗手牌→抽4
    ("sv2-young", 3),     # 短裤小子 - 洗手牌→抽5
    ("sv1-180", 4),       # 妮莫 - 抽3
    ("sv1-189", 2),       # 博士的研究 - 丢手牌→抽7
    ("sv1-204", 2),       # 派帕 - 牌库找1物品+1道具

    # Energy (15)
    ("sv1-ener-5", 15),   # 基本超能量
]

# ============================================================
# ⚡ LIGHTNING DECK — Pikachu ex (60 cards)
# Strategy: Pikachu ex as main attacker with 强劲伏特 (220 damage).
# Flaaffy's 电气发电机 ability recycles Lightning energy from discard.
# Multiple basic Lightning attackers for flexibility. Fast, aggressive deck.
# ============================================================

LIGHTNING_DECK = [
    # Pokemon (15)
    ("svl-pikaex", 2),  # 皮卡丘ex - 190 HP, Basic ex (皮卡拳: 30 / 强劲伏特: 220→硬币反面弃全能)
    ("svl-chin", 2),    # 灯笼鱼 - 70 HP, Basic (电球: 10)
    ("svl-lant", 2),    # 电灯怪 - 120 HP, Stage 1 (炫目光束: 40+炫目 / 电球: 120)
    ("svl-mare2", 3),   # 咩利羊 - 60 HP, Basic (后踢: 10 / 电球: 30)
    ("svl-flaa2", 2),   # 茸茸羊 - 90 HP, Stage 1 (特性: 电气发电机 / 电球: 50)
    ("svl-emol", 1),    # 电飞鼠 - 70 HP, Basic (电击: 30+硬币麻痹 / 0撤)
    ("svl-thun", 1),    # 雷电云 - 120 HP, Basic (辅助电光: 30+手牌充能 / 打雷: 130→自伤30)
    ("svl-zera", 1),    # 捷拉奥拉 - 120 HP, Basic (疯狂伏特: 70→自伤20)
    ("svl-chat", 1),    # 聒噪鸟 - 70 HP, Basic (循环抽取: 弃1抽2 / 振翅: 10)

    # Trainer (30)
    ("svl-ensw", 1),    # 能量输送 - 牌库找1基本能量→手牌
    ("sv1-170", 2),     # 电气发生器 - 看牌库顶5，最多2张L能量→备战L宝可梦
    ("svl-trks", 2),    # 健行鞋 - 看牌库顶1，加入手牌 或 弃置+抽1
    ("sv1-151", 2),     # 巢穴球 - 牌库找基础宝可梦→备战区
    ("sv1-153", 4),     # 高级球 - 丢2手→牌库找宝可梦
    ("sv1-150", 2),     # 宝可梦交替 - 出战与备战互换
    ("sv2-catch", 2),   # 宝可梦捕捉器 - 硬币正面→抓对手备战
    ("svl-vitb", 2),    # 活力头带 - 宝可梦道具: 招式伤害+10
    ("sv1-176", 1),     # 裁判 - 双方洗手牌→抽4
    ("sv2-young", 3),   # 短裤小子 - 洗手牌→抽5
    ("sv1-180", 4),     # 妮莫 - 抽3
    ("sv1-189", 3),     # 博士的研究 - 丢手牌→抽7
    ("svl-zinn", 2),    # 希嘉娜的决心 - 弃2手牌→抽对手场上宝可梦数量

    # Energy (15)
    ("sv1-ener-4", 15), # 基本雷能量
]


# ============================================================
# ⚡👊 FIGHTING DECK — 路卡利欧核心 (60 cards)
# Strategy: 路卡利欧的「旺盛斗气」自我充能 + 「连续波导弹」高爆发。
# 劈斧螳螂「大树切割」双硬币KO。代拉基翁「岩窟冲撞」攻防一体。
# 大葱鸭/摔跤鹰人抽滤充能，多核灵活站场。
# ============================================================

FIGHTING_DECK = [
    # Pokemon (15)
    ("svf-rio", 4),     # 利欧路 - 70 HP, Basic (重拳: 10 / 突击: 50→自伤20)
    ("svf-luca", 3),    # 路卡利欧 - 120 HP, Stage 1 (特性: 旺盛斗气 / 连续波导弹: 10+弃斗能×60)
    ("svf-scyt", 2),    # 飞天螳螂 - 90 HP, Basic Grass (高速镰刀: 20)
    ("svf-klea", 2),    # 劈斧螳螂 - 140 HP, Stage 1 (大树切割: 双硬币KO / 暴走冲撞: 120→自伤30)
    ("svf-pass", 1),    # 投掷猴 - 110 HP, Basic (辅助传递: 70+转附能量)
    ("svf-farf", 1),    # 大葱鸭 - 90 HP, Basic Colorless (背来: 抽2 / 甩葱殴打: 30)
    ("svf-terr", 1),    # 代拉基翁 - 130 HP, Basic (岩窟冲撞: 120+免疫+无法连发)
    ("svf-hawl", 1),    # 摔跤鹰人 - 70 HP, Basic Colorless (展示姿态: 弃牌区充能 / 挥落: 30+进化追加30)

    # Trainer (30)
    ("sv1-153", 4),     # 高级球 - 丢2手→牌库找宝可梦
    ("sv1-151", 4),     # 巢穴球 - 牌库找基础→备战区
    ("sv1-150", 2),     # 宝可梦交替 - 换位
    ("sv2-catch", 2),   # 宝可梦捕捉器 - 硬币→抓对手备战
    ("svf-potion", 2),  # 伤药 - 回复30HP
    ("svf-ensw2", 2),   # 能量转移 - 场上能量转附
    ("sv3-134", 1),     # 厉害钓竿 - 弃牌区3张回牌库
    ("svi-erec", 1),    # 能量再利用 - 弃牌区5张基本能量回牌库
    ("sv1-180", 4),     # 妮莫 - 抽3
    ("sv1-176", 1),     # 裁判 - 双方洗手牌→抽4
    ("sv2-young", 3),   # 短裤小子 - 洗手牌→抽5
    ("sv1-189", 2),     # 博士的研究 - 丢手牌→抽7
    ("svf-houb", 2),    # 凰檗 - 1手牌回牌库底→抽到5张

    # Energy (15)
    ("sv1-ener-6", 15), # 基本斗能量
]


# ============================================================
# ⚪ COLORLESS DECK — 一家鼠ex (60 cards)
# Strategy: 一家鼠ex as main attacker with 团结一致 reactive thorns.
# 双尾怪手/爱管侍 scale damage with hand size. Special energy
# provide flexible tactics (Jet switch, DTE double energy, etc.)
# ============================================================

COLORLESS_DECK = [
    # Pokemon (15)
    ("svi-aipo", 2),     # 长尾怪手 - 60 HP, Basic (骗取: 抽1 / 掌击: 20)
    ("svi-ambi", 2),     # 双尾怪手 - 100 HP, Stage 1 (招来: 抽2 / 长手抛掷: 手牌×20)
    ("svi-stan", 1),     # 惊角鹿 - 110 HP, Basic (后踢: 20 / 疯狂俯冲: 对手能量×30)
    ("svi-skwv", 2),     # 贪心栗鼠 - 60 HP, Basic (啃咬: 20)
    ("svi-gree", 1),     # 藏饱栗鼠 - 130 HP, Stage 1 (招来: 抽2 / 倾倒一空: 60+150)
    ("svi-inde", 1),     # 爱管侍 - 90 HP, Basic (招来: 抽2 / 妙手强念: 手牌×10)
    ("svi-tand", 3),     # 一对鼠 - 40 HP, Basic (紧贴: 10 / 踢飞: 20)
    ("svi-maus", 2),     # 一家鼠ex - 230 HP, Stage 1 ex (团结一致反伤 / 贪婪门牙: 120+抽2)
    ("svi-flam", 1),     # 缠红鹤 - 110 HP, Basic (振翅: 30 / 俯冲: 110→自伤20)

    # Trainer - Items (17)
    ("svi-enst", 2),     # 能量签 - 翻顶7→拿1张能量
    ("sv3-134", 1),      # 厉害钓竿 - 弃牌区3张回牌库
    ("sv1-151", 4),      # 巢穴球 - 牌库找基础→备战区
    ("svi-nemb", 2),     # 妮莫的背包 - 弃牌区找最多2张妮莫
    ("sv1-153", 4),      # 高级球 - 丢2手→牌库找宝可梦
    ("sv1-150", 2),      # 宝可梦交替 - 出战与备战互换
    ("sv2-catch", 2),    # 宝可梦捕捉器 - 硬币正面→抓对手备战

    # Trainer - Supporters (13)
    ("svi-cait", 2),     # 嘉德丽雅 - 任意手牌→牌库底→抽等量
    ("sv1-176", 1),      # 裁判 - 双方洗手牌→抽4
    ("sv2-young", 3),    # 短裤小子 - 洗手牌→抽5
    ("sv1-180", 4),      # 妮莫 - 抽3
    ("sv1-189", 2),      # 博士的研究 - 丢手牌→抽7
    ("svi-popp", 1),     # 波琵 - 1只→最多2能量转附另1只

    # Special Energy (15)
    ("svi-jete", 3),     # 喷射能量 - 1C, 附于备战→切换战斗区
    ("svi-dtur", 4),     # 双重涡轮能量 - 2C, 伤害-20
    ("svi-trea", 4),     # 宝藏能量 - 1C
    ("svi-mirc", 4),     # 奇迹能量 - 1C, 受伤→抽1
]

# ============================================================
# Energy card ID mapping for basic energies
# ============================================================

BASIC_ENERGY_IDS = {
    "Fire": "sv1-ener-2",
    "Water": "sv1-ener-3",
    "Grass": "sv1-ener-1",
    "Lightning": "sv1-ener-4",
    "Psychic": "sv1-ener-5",
    "Fighting": "sv1-ener-6",
    "Darkness": "sv1-ener-7",
    "Metal": "sv1-ener-8",
}

# ============================================================
# 🐉 DRAGON DECK — 七夕青鸟ex核心 (60 cards)
# Strategy: 七夕青鸟ex「哼唱治愈」群体回复 +「光之波动」高伤免疫。
# 老翁龙「逆鳞」伤害指示物增伤。大奶罐「活泼冲撞」配合回复追加伤害。
# 浩大鲸「扫除冲撞」高威力终结技。米立龙「生存战略」万能检索。
# ============================================================

DRAGON_DECK = [
    # Pokemon (15)
    ("svg-alt", 2),     # 七夕青鸟ex - 260 HP, Stage 1 ex
    ("svg-dram", 2),    # 老翁龙 - 120 HP, Basic
    ("svg-tatsu", 1),   # 米立龙 - 70 HP, Basic (Dragon型)
    ("svg-milt", 1),    # 大奶罐 - 120 HP, Basic
    ("svg-swa", 3),     # 青绵鸟 - 50 HP, Basic
    ("svg-cast", 1),    # 飘浮泡泡 - 70 HP, Basic
    ("svf-hawl", 1),    # 摔角鹰人 - 70 HP, Basic Colorless
    ("svg-ceto", 2),    # 走鲸 - 80 HP, Basic
    ("svg-ceti", 2),    # 浩大鲸 - 180 HP, Stage 1

    # Trainer (30)
    ("svl-ensw", 2),    # 能量输送 - 牌库找1基本能量
    ("svf-potion", 2),  # 伤药 - 回复30HP
    ("sv3-134", 1),     # 厉害钓竿 - 弃牌区3张回牌库
    ("sv1-151", 4),     # 巢穴球 - 找基础宝可梦
    ("sv1-153", 4),     # 高级球 - 丢2找宝可梦
    ("sv1-150", 2),     # 宝可梦交替 - 换位
    ("sv2-catch", 2),   # 宝可梦捕捉器 - 硬币抓对手
    ("svg-chef", 1),    # 西餐厨师 - 回70HP
    ("sv1-176", 1),     # 裁判 - 洗手牌抽4
    ("sv2-young", 3),   # 短裤小子 - 洗手牌抽5
    ("sv1-180", 4),     # 妮莫 - 抽3
    ("sv1-189", 2),     # 博士的研究 - 丢手牌抽7
    ("svg-beri", 2),    # 贝里菈 - 抽至比对手多1张

    # Energy (15)
    ("sv1-ener-3", 8),  # 基本水能量
    ("sv1-ener-8", 7),  # 基本钢能量
]

# ============================================================
# 🌿 GRASS DECK — 土台龟核心 (60 cards)
# Strategy: 土台龟「进化压制」进化增伤。萨戮德「唤群之歌」检索G宝可梦。
# 帝王拿波「紧急上浮」弃牌区复活 +「水之矢」狙击。
# 菜种的活力加速充能，学习装置回收能量。
# ============================================================

GRASS_DECK = [
    # Pokemon (16)
    ("svg2-tort", 3),   # 土台龟 - 190 HP, Stage 2
    ("svg2-turt", 4),   # 草苗龟 - 80 HP, Basic
    ("svg2-grot", 3),   # 树林龟 - 100 HP, Stage 1
    ("svg2-shro", 2),   # 蘑蘑菇 - 60 HP, Basic
    ("svg2-brel", 2),   # 斗笠菇 - 110 HP, Stage 1
    ("svg2-zaru", 1),   # 萨戮德 - 130 HP, Basic
    ("svg2-empo", 1),   # 帝王拿波 - 160 HP, Stage 2

    # Trainer (30)
    ("svg2-hamm", 2),   # 粉碎之锤 - 硬币弃对手能量
    ("sv3-134", 1),     # 厉害钓竿 - 弃牌区3张回牌库
    ("sv1-151", 3),     # 巢穴球 - 找基础宝可梦
    ("sv1-153", 4),     # 高级球 - 丢2找宝可梦
    ("sv1-152", 2),     # 神奇糖果 - 基础→2阶进化
    ("sv1-150", 2),     # 宝可梦交替 - 换位
    ("sv2-catch", 2),   # 宝可梦捕捉器 - 硬币抓对手
    ("svg2-exps", 1),   # 学习装置 - 击倒时能量转附
    ("sv1-176", 1),     # 裁判 - 洗手牌抽4
    ("sv2-young", 4),   # 短裤小子 - 洗手牌抽5
    ("svg2-gard", 2),   # 菜种的活力 - 抽2+附最多2G能量
    ("sv1-180", 4),     # 妮莫 - 抽3
    ("sv1-189", 2),     # 博士的研究 - 丢手牌抽7

    # Energy (14)
    ("svg2-lume", 2),   # 夜光能量 - 全属性能量
    ("sv1-ener-1", 12), # 基本草能量
]

# Collect all unique card IDs needed for all decks
ALL_CARD_IDS = list(set(
    card_id
    for deck in [FIRE_DECK, WATER_DECK, PSYCHIC_DECK_NATU, LIGHTNING_DECK, FIGHTING_DECK, COLORLESS_DECK, DRAGON_DECK, GRASS_DECK]
    for card_id, _ in deck
))


def expand_deck(deck_spec: list[tuple[str, int]]) -> list[str]:
    """Expand a deck spec [(id, count), ...] into a 60-card list of IDs."""
    cards = []
    for card_id, count in deck_spec:
        cards.extend([card_id] * count)
    return cards


def verify_deck_size(deck: list[str]) -> bool:
    """Check that a deck has exactly 60 cards."""
    return len(deck) == 60


def shuffle_deck(deck: list[str]) -> list[str]:
    """Shuffle a deck of card IDs."""
    shuffled = list(deck)
    random.shuffle(shuffled)
    return shuffled

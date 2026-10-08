class_name CardPresentation
extends RefCounted

enum DetailLevel {
	COMPACT,
	FULL,
}

const SUPERTYPE_NAMES := {
	"pokemon": "宝可梦",
	"pokémon": "宝可梦",
	"trainer": "训练家",
	"energy": "能量",
}
const SUBTYPE_NAMES := {
	"ancient": "古代",
	"future": "未来",
	"stage 1": "1阶进化",
	"stage1": "1阶进化",
	"stage 2": "2阶进化",
	"stage2": "2阶进化",
	"item": "物品",
	"supporter": "支援者",
	"stadium": "竞技场",
	"tool": "宝可梦道具",
	"pokemon tool": "宝可梦道具",
	"pokémon tool": "宝可梦道具",
	"special": "特殊能量",
	"ex": "宝可梦 ex",
}
const STATUS_NAMES := {
	"POISONED": "中毒",
	"BURNED": "灼伤",
	"ASLEEP": "睡眠",
	"PARALYZED": "麻痹",
	"CONFUSED": "混乱",
}
const TRAINER_USAGE_RULES := [
	"在自己的回合可以使用任意张物品卡。",
	"在自己的回合只可以使用1张支援者卡。",
	"在自己的回合可以将任意张宝可梦道具卡，放于自己的宝可梦身上。每只宝可梦身上只可以放1张宝可梦道具卡，并保持附加状态。",
]


static func meta_text(card: Dictionary) -> String:
	var supertype := str(card.get("supertype", ""))
	var labels: Array[String] = [_localize_supertype(supertype)]
	for subtype_value in card.get("subtypes", []):
		var subtype := _localize_subtype(str(subtype_value), supertype)
		if not subtype.is_empty() and subtype not in labels:
			labels.append(subtype)
	var energy_types: Array[String] = []
	for type_value in card.get("energy_types", []):
		energy_types.append(EnergyIconCatalog.type_display_name_for(str(type_value)))
	if not energy_types.is_empty():
		labels.append("属性：%s" % "／".join(energy_types))
	return " · ".join(labels.filter(func(value: String) -> bool:
		return not value.is_empty()
	))


static func detail_bbcode(
	card: Dictionary,
	catalog: CardCatalog = null,
	pokemon: PokemonState = null,
	detail_level: DetailLevel = DetailLevel.FULL,
) -> String:
	if detail_level == DetailLevel.COMPACT:
		return _compact_rule_bbcode(card)
	var sections: Array[String] = []
	for group in detail_groups(card, catalog, pokemon):
		sections.append(str(group["bbcode"]))
	return "\n\n".join(sections)


## Structured sections share the same rule text as the legacy battle inspector.
static func detail_groups(card: Dictionary, catalog: CardCatalog = null, pokemon: PokemonState = null) -> Array[Dictionary]:
	var sections: Array[Dictionary] = []
	var maximum_hp := int(card.get("hp", 0))
	var card_rows: Array[String] = []
	if maximum_hp > 0:
		card_rows.append(DesignTokens.rich_text("[color=#{text}][b]卡面 HP %d[/b][/color]") % maximum_hp)
	var evolves_from := str(card.get("evolves_from", "")).strip_edges()
	if not evolves_from.is_empty():
		card_rows.append(DesignTokens.rich_text("[color=#{muted}]进化自[/color]  %s") % _safe_text(evolves_from))
	if not card_rows.is_empty():
		sections.append({"kind": "basic", "title": "卡面信息", "bbcode": DesignTokens.rich_text("[color=#{muted}][b]卡面信息[/b][/color]\n%s") % "\n".join(card_rows)})


	for ability_value in card.get("abilities", []):
		var ability := Dictionary(ability_value)
		var ability_text := str(ability.get("text", "")).strip_edges()
		var rows: Array[String] = [DesignTokens.rich_text("[color=#{target}][b]特性 · %s[/b][/color]") % (
			_safe_text(str(ability.get("name", "")))
		)]
		if not ability_text.is_empty():
			rows.append(_safe_text(ability_text))
		sections.append({"kind": "ability", "title": str(ability.get("name", "")), "text": ability_text, "bbcode": "\n".join(rows)})

	for attack_value in card.get("attacks", []):
		var attack := Dictionary(attack_value)
		var damage_text := attack_damage_text(attack)
		var heading := "招式 · %s" % _safe_text(str(attack.get("name", "")))
		if not damage_text.is_empty():
			heading += "　%s" % _safe_text(damage_text)
		var attack_rows: Array[String] = [DesignTokens.rich_text("[color=#{accent}][b]%s[/b][/color]") % heading]
		var cost_text := energy_cost_text(attack.get("cost", []))
		if not cost_text.is_empty():
			attack_rows.append(DesignTokens.rich_text("[color=#{muted}]费用：%s[/color]") % cost_text)
		var attack_text := str(attack.get("text", "")).strip_edges()
		if not attack_text.is_empty():
			attack_rows.append(_safe_text(attack_text))
		sections.append({"kind": "attack", "title": heading, "name": str(attack.get("name", "")),
			"cost": Array(attack.get("cost", [])).duplicate(), "damage_text": damage_text,
			"text": attack_text, "bbcode": "\n".join(attack_rows)})

	var provides := energy_cost_text(card.get("provides_energy", []))
	if not provides.is_empty():
		sections.append({"kind": "energy", "title": "提供能量", "bbcode": DesignTokens.rich_text("[color=#{success}][b]提供能量[/b][/color]\n%s") % provides})

	for rule_group in _printed_rule_groups(card):
		sections.append({"kind": "rules", "title": rule_group.title, "bbcode": DesignTokens.rich_text("[color=#{target}][b]%s[/b][/color]\n%s") % [
			rule_group.title,
			_safe_text(str(rule_group.text)),
		]})

	if maximum_hp > 0:
		var footer: Array[String] = ["撤退费用：%d" % int(card.get("retreat_cost", 0))]
		var weakness := matchup_text(card.get("weaknesses", []))
		footer.append("弱点：%s" % (weakness if not weakness.is_empty() else "无"))
		var resistance := matchup_text(card.get("resistances", []))
		footer.append("抗性：%s" % (resistance if not resistance.is_empty() else "无"))
		sections.append({"kind": "matchup", "title": "弱点 / 抗性 / 撤退", "bbcode": DesignTokens.rich_text("[color=#{muted}]%s[/color]") % "　·　".join(footer)})

	if pokemon != null:
		sections.append({"kind": "state", "title": "当前状态", "bbcode": _current_state_bbcode(pokemon, catalog, maximum_hp)})
	if sections.is_empty():
		sections.append({"kind": "rules", "title": "规则", "bbcode": DesignTokens.rich_text("[color=#{muted}]这张卡没有额外说明。[/color]")})
	return sections


static func battle_state(pokemon: PokemonState, catalog: CardCatalog, printed_hp: int) -> Dictionary:
	if pokemon == null:
		return {}
	var states: Array[String] = []
	for status in pokemon.status_conditions:
		states.append(str(STATUS_NAMES.get(str(status).to_upper(), status)))
	if pokemon.attack_is_locked():
		states.append("无法攻击")
	if pokemon.has_attack_gate("dazzled"):
		states.append("受幻惑影响")
	return {"printed_hp": printed_hp,
		"maximum_hp": pokemon.max_hp(catalog) if catalog != null else printed_hp,
		"current_hp": pokemon.current_hp(catalog) if catalog != null else maxi(0, printed_hp - pokemon.damage_counters * 10),
		"damage": pokemon.damage_counters * 10, "statuses": states,
		"used_abilities": pokemon.used_abilities.duplicate()}


static func attachment_groups(pokemon: PokemonState) -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	if pokemon == null:
		return groups
	if not pokemon.evolution_stack_ids.is_empty():
		var chain: Array[Dictionary] = []
		for id in pokemon.evolution_stack_ids:
			chain.append({"card_id": id, "count": 1, "hint": "进化前"})
		chain.append({"card_id": pokemon.card_id, "count": 1, "hint": "当前"})
		groups.append({"kind": "evolution", "title": "进化链", "rows": chain})
	if not pokemon.energy_card_ids.is_empty():
		var counts := energy_card_counts(pokemon.energy_card_ids)
		var energies: Array[Dictionary] = []
		for id in counts:
			energies.append({"card_id": id, "count": counts[id], "hint": ""})
		groups.append({"kind": "energy", "title": "附着能量  ·  %d 张" % pokemon.energy_card_ids.size(), "rows": energies})
	if not pokemon.attached_tool_id.is_empty():
		groups.append({"kind": "tool", "title": "宝可梦道具", "rows": [
			{"card_id": pokemon.attached_tool_id, "count": 1, "hint": "已附着"}]})
	return groups


static func energy_card_counts(ids: Array) -> Dictionary:
	var counts: Dictionary = {}
	for id in ids:
		counts[id] = int(counts.get(id, 0)) + 1
	return counts


static func battle_state_bbcode(
	pokemon: PokemonState,
	catalog: CardCatalog,
	printed_maximum: int,
) -> String:
	if pokemon == null:
		return ""
	var state := battle_state(pokemon, catalog, printed_maximum)
	var states: Array = state.statuses
	var tool_name := "无"
	if not pokemon.attached_tool_id.is_empty():
		tool_name = (
			catalog.card_name(pokemon.attached_tool_id)
			if catalog != null
			else pokemon.attached_tool_id
		)
	return (
		DesignTokens.rich_text("[font_size=12][color=#{success}][b]当前状态[/b][/color][/font_size]  ")
		+ DesignTokens.rich_text("[color=#{text}][b]HP %d／%d[/b][/color]  ") % [
			state.current_hp,
			maxi(1, int(state.maximum_hp)),
		]
		+ DesignTokens.rich_text("[color=#{muted}]伤害 %d[/color]\n") % (pokemon.damage_counters * 10)
		+ DesignTokens.rich_text("[color=#{muted}]状态[/color] %s　") % (
			"、".join(states) if not states.is_empty() else "无"
		)
		+ DesignTokens.rich_text("[color=#{muted}]能量[/color] %d　[color=#{muted}]道具[/color] %s") % [
			pokemon.energy_card_ids.size(),
			_safe_text(tool_name),
		]
	)


static func _compact_rule_bbcode(card: Dictionary) -> String:
	var sections: Array[String] = []
	var maximum_hp := int(card.get("hp", 0))
	if maximum_hp > 0:
		var summary := DesignTokens.rich_text("[color=#{muted}][font_size=11]卡面数据[/font_size][/color]\n")
		summary += DesignTokens.rich_text("[font_size=18][color=#{text}][b]HP %d[/b][/color][/font_size]") % maximum_hp
		var evolves_from := str(card.get("evolves_from", "")).strip_edges()
		if not evolves_from.is_empty():
			summary += DesignTokens.rich_text("  [color=#{muted}]进化自 %s[/color]") % _safe_text(evolves_from)
		sections.append(summary)

	for ability_value in card.get("abilities", []):
		var ability := Dictionary(ability_value)
		var rows: Array[String] = [
			DesignTokens.rich_text("[color=#{target}][font_size=15][b]特性　%s[/b][/font_size][/color]") % _safe_text(
				str(ability.get("name", ""))
			),
		]
		var ability_text := str(ability.get("text", "")).strip_edges()
		if not ability_text.is_empty():
			rows.append(_safe_text(ability_text))
		sections.append("\n".join(rows))

	for attack_value in card.get("attacks", []):
		var attack := Dictionary(attack_value)
		var damage_text := attack_damage_text(attack)
		var heading := DesignTokens.rich_text("[color=#{accent}][font_size=16][b]%s[/b][/font_size][/color]") % _safe_text(
			str(attack.get("name", ""))
		)
		if not damage_text.is_empty():
			heading += DesignTokens.rich_text("  [color=#{accent}][font_size=16][b]%s[/b][/font_size][/color]") % _safe_text(
				damage_text
			)
		var rows: Array[String] = [heading]
		var cost_text := energy_cost_text(attack.get("cost", []))
		if not cost_text.is_empty():
			rows.append(DesignTokens.rich_text("[color=#{target}]费用[/color]  %s") % cost_text)
		var attack_text := str(attack.get("text", "")).strip_edges()
		if not attack_text.is_empty():
			rows.append(_safe_text(attack_text))
		sections.append("\n".join(rows))

	var provides := energy_cost_text(card.get("provides_energy", []))
	if not provides.is_empty():
		sections.append(DesignTokens.rich_text("[color=#{success}][font_size=15][b]提供能量[/b][/font_size][/color]\n%s") % provides)

	for rule_group in _printed_rule_groups(card):
		sections.append(DesignTokens.rich_text("[color=#{target}][font_size=14][b]%s[/b][/font_size][/color]\n%s") % [
			rule_group.title,
			_safe_text(str(rule_group.text)),
		])

	if maximum_hp > 0:
		var weakness := matchup_text(card.get("weaknesses", []))
		var resistance := matchup_text(card.get("resistances", []))
		sections.append(
			(
				DesignTokens.rich_text("[color=#{muted}]撤退[/color] %d　[color=#{muted}]弱点[/color] %s\n")
				+ DesignTokens.rich_text("[color=#{muted}]抗性[/color] %s")
			) % [
				int(card.get("retreat_cost", 0)),
				weakness if not weakness.is_empty() else "无",
				resistance if not resistance.is_empty() else "无",
			]
		)
	if sections.is_empty():
		return DesignTokens.rich_text("[color=#{muted}]这张卡没有额外说明。[/color]")
	return "\n\n".join(sections)


static func accessibility_text(
	card: Dictionary,
	catalog: CardCatalog = null,
	pokemon: PokemonState = null,
) -> String:
	var value := "%s。%s。%s" % [
		str(card.get("name", "卡牌")),
		meta_text(card),
		detail_bbcode(card, catalog, pokemon, DetailLevel.FULL),
	]
	var tags := RegEx.new()
	tags.compile("\\[[^\\]]+\\]")
	return tags.sub(value, "", true).replace("\n", "；")


## An explicit blank is printed without a number, even if the engine uses base
## damage for its effect (e.g. Absol's damage to every opposing Pokemon).
static func attack_damage_text(attack: Dictionary) -> String:
	if attack.has("damage_text"):
		return str(attack["damage_text"]).strip_edges()
	var damage := int(attack.get("damage", 0))
	return str(damage) if damage > 0 else ""


static func energy_cost_text(values: Array) -> String:
	var counts: Dictionary = {}
	var order: Array[String] = []
	for value in values:
		var energy_type := str(value)
		var label := EnergyIconCatalog.display_name_for(energy_type, energy_type)
		if not counts.has(label):
			order.append(label)
		counts[label] = int(counts.get(label, 0)) + 1
	var parts: Array[String] = []
	for label in order:
		var count := int(counts[label])
		parts.append("%s ×%d" % [_safe_text(label), count] if count > 1 else _safe_text(label))
	return "、".join(parts)


static func matchup_text(values: Array) -> String:
	var parts: Array[String] = []
	for value in values:
		var row := Dictionary(value)
		parts.append("%s %s" % [
			EnergyIconCatalog.type_display_name_for(str(row.get("energy_type", ""))),
			_safe_text(str(row.get("value", ""))),
		])
	return "、".join(parts)


static func _current_state_bbcode(
	pokemon: PokemonState,
	catalog: CardCatalog,
	printed_maximum: int,
) -> String:
	var rows: Array[String] = []
	var state := battle_state(pokemon, catalog, printed_maximum)
	rows.append("HP %d／%d　·　伤害 %d" % [
		state.current_hp,
		maxi(1, int(state.maximum_hp)) if catalog != null else printed_maximum,
		state.damage,
	])
	var states: Array = state.statuses
	rows.append("特殊状态：%s" % ("、".join(states) if not states.is_empty() else "无"))

	var energy_counts: Dictionary = {}
	for energy_id in pokemon.energy_card_ids:
		var energy_name := (
			catalog.card_name(energy_id)
			if catalog != null
			else str(energy_id)
		)
		energy_counts[energy_name] = int(energy_counts.get(energy_name, 0)) + 1
	var energy_labels: Array[String] = []
	for energy_name_value in energy_counts:
		var energy_name := str(energy_name_value)
		var count := int(energy_counts[energy_name_value])
		energy_labels.append("%s ×%d" % [_safe_text(energy_name), count] if count > 1 else _safe_text(energy_name))
	rows.append("附着能量（%d）：%s" % [
		pokemon.energy_card_ids.size(),
		"、".join(energy_labels) if not energy_labels.is_empty() else "无",
	])
	var tool_name := "无"
	if not pokemon.attached_tool_id.is_empty():
		tool_name = (
			catalog.card_name(pokemon.attached_tool_id)
			if catalog != null
			else pokemon.attached_tool_id
		)
	rows.append("宝可梦道具：%s" % _safe_text(tool_name))
	if not pokemon.used_abilities.is_empty():
		rows.append("本回合已使用特性：%s" % "、".join(pokemon.used_abilities))
	return DesignTokens.rich_text("[color=#{success}][b]当前对战状态[/b][/color]\n%s") % "\n".join(rows)


static func _printed_rule_groups(card: Dictionary) -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	var effects: Array[String] = []
	var usage: Array[String] = []
	var seen: Dictionary = {}
	var is_trainer := str(card.get("supertype", "")).to_lower() == "trainer"
	for value in [card.get("trainer_text", "")] + Array(card.get("rules", [])):
		var rule := str(value).strip_edges()
		if rule.is_empty() or seen.has(rule):
			continue
		seen[rule] = true
		if is_trainer and rule in TRAINER_USAGE_RULES:
			usage.append(rule)
		else:
			effects.append(rule)
	if not effects.is_empty():
		groups.append({"title": _rule_section_title(str(card.get("supertype", ""))), "text": "\n".join(effects)})
	if not usage.is_empty():
		groups.append({"title": "使用规则", "text": "\n".join(usage)})
	return groups


static func _rule_section_title(supertype: String) -> String:
	match supertype.to_lower():
		"trainer":
			return "卡牌效果"
		"energy":
			return "能量效果"
	return "特殊规则"


static func _localize_supertype(value: String) -> String:
	return str(SUPERTYPE_NAMES.get(value.to_lower(), value))


static func _localize_subtype(value: String, supertype: String) -> String:
	var key := value.to_lower().replace("_", " ")
	if key == "basic":
		return "基本能量" if supertype.to_lower() == "energy" else "基础"
	return str(SUBTYPE_NAMES.get(key, value))


static func _safe_text(value: String) -> String:
	return value.replace("[", "［").replace("]", "］")

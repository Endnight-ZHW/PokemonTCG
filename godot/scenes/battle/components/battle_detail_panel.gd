class_name BattleDetailPanel
extends PanelContainer

signal close_requested

const SUPERTYPE_NAMES := {
	"pokemon": "宝可梦",
	"pokémon": "宝可梦",
	"trainer": "训练家",
	"energy": "能量",
}
const SUBTYPE_NAMES := {
	"stage 1": "一阶进化",
	"stage 2": "二阶进化",
	"item": "物品",
	"supporter": "支援者",
	"stadium": "竞技场",
	"tool": "宝可梦道具",
	"pokemon tool": "宝可梦道具",
	"pokémon tool": "宝可梦道具",
	"special": "特殊",
	"ex": "宝可梦 ex",
}
const ENERGY_TYPE_NAMES := {
	"grass": "草",
	"fire": "火",
	"water": "水",
	"lightning": "雷",
	"psychic": "超能力",
	"fighting": "斗",
	"darkness": "恶",
	"metal": "钢",
	"dragon": "龙",
	"colorless": "无色",
	"rainbow": "全属性",
}
const STATUS_NAMES := {
	"POISONED": "中毒",
	"BURNED": "灼伤",
	"ASLEEP": "睡眠",
	"PARALYZED": "麻痹",
	"CONFUSED": "混乱",
}
const NORMAL_PANEL_SIZE := Vector2(372.0, 312.0)
const COMPACT_PANEL_SIZE := Vector2(560.0, 240.0)

@onready var detail_image: TextureRect = %DetailImage
@onready var detail_title: Label = %DetailTitle
@onready var detail_meta: Label = %DetailMeta
@onready var detail_text: RichTextLabel = %DetailText
@onready var context_label: Label = %ContextLabel
@onready var close_button: Button = %CloseButton

var current_card_id := ""
var current_context: Dictionary = {}
var _catalog: CardCatalog
var _compact_layout := false
var _visibility_tween: Tween


func _ready() -> void:
	_resolve_nodes()
	if detail_text:
		detail_text.focus_mode = Control.FOCUS_NONE
	if close_button and not close_button.pressed.is_connected(_on_close_pressed):
		close_button.pressed.connect(_on_close_pressed)
	clear()


func show_card(
	card_id: String,
	pokemon: PokemonState = null,
	context: Variant = {},
) -> void:
	_resolve_nodes()
	var was_visible := visible
	if card_id.is_empty():
		clear()
		return
	var normalized_context: Dictionary = {}
	if context is CardCatalog:
		_catalog = context as CardCatalog
	elif context is Dictionary:
		normalized_context = Dictionary(context)
		_catalog = normalized_context.get("catalog") as CardCatalog
	else:
		_catalog = null
	if _catalog == null:
		_catalog = CardCatalog.shared()
	var card := Dictionary(normalized_context.get("card_data", {}))
	if card.is_empty():
		card = _catalog.get_card(card_id)
	if card.is_empty():
		clear()
		return

	current_card_id = card_id
	current_context = normalized_context.duplicate(true)
	detail_image.texture = _card_texture(str(card.get("image_path", "")))
	detail_image.tooltip_text = str(card.get("name", card_id))
	detail_title.text = str(card.get("name", card_id))
	detail_title.tooltip_text = detail_title.text
	detail_meta.text = _card_meta_text(card)
	detail_text.text = _card_detail_bbcode(card, pokemon)
	detail_text.scroll_to_line(0)
	var location := str(normalized_context.get(
		"location",
		normalized_context.get("source_label", ""),
	)).strip_edges()
	context_label.text = location
	context_label.visible = not location.is_empty()
	visible = true
	if not was_visible:
		_play_present_motion()


func clear() -> void:
	_resolve_nodes()
	_kill_visibility_tween()
	modulate.a = 1.0
	current_card_id = ""
	current_context.clear()
	_catalog = null
	visible = false
	if detail_image:
		detail_image.texture = null
		detail_image.tooltip_text = ""
	if detail_title:
		detail_title.text = "卡牌预览"
		detail_title.tooltip_text = ""
	if detail_meta:
		detail_meta.text = ""
	if detail_text:
		detail_text.text = ""
	if context_label:
		context_label.text = ""
		context_label.visible = false


func hide_card() -> void:
	clear()


func hide_preview() -> void:
	clear()


func is_showing_card() -> bool:
	return visible and not current_card_id.is_empty()


func _play_present_motion() -> void:
	_kill_visibility_tween()
	var duration := MotionPolicy.duration("panel")
	if duration <= 0.0 or MotionPolicy.reduced():
		modulate.a = 1.0
		return
	modulate.a = 0.0
	_visibility_tween = create_tween()
	_visibility_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	_visibility_tween.tween_property(self, "modulate:a", 1.0, duration)
	_visibility_tween.finished.connect(func() -> void:
		_visibility_tween = null
	)


func _kill_visibility_tween() -> void:
	if _visibility_tween and _visibility_tween.is_valid():
		_visibility_tween.kill()
	_visibility_tween = null


func set_compact_layout(value: bool) -> void:
	_resolve_nodes()
	_compact_layout = value
	var target_size := COMPACT_PANEL_SIZE if value else NORMAL_PANEL_SIZE
	custom_minimum_size = target_size
	size = target_size

	var header := get_node_or_null("Content/Header") as Control
	var content := get_node_or_null("Content") as VBoxContainer
	var body := get_node_or_null("Content/Body") as HBoxContainer
	var image_column := get_node_or_null("Content/Body/ImageColumn") as Control
	var image_frame := get_node_or_null(
		"Content/Body/ImageColumn/ImageFrame"
	) as Control
	if header:
		header.custom_minimum_size.y = 48.0
	if content:
		content.add_theme_constant_override("separation", 4 if value else 6)
	if body:
		body.add_theme_constant_override("separation", 6 if value else 10)
	if image_column:
		image_column.custom_minimum_size.x = 96.0 if value else 126.0
	if image_frame:
		image_frame.custom_minimum_size = (
			Vector2(96.0, 134.0) if value else Vector2(126.0, 176.0)
		)
	if detail_text:
		detail_text.custom_minimum_size.x = 340.0 if value else 212.0
		detail_text.add_theme_font_size_override("normal_font_size", 12)
	if detail_title:
		detail_title.add_theme_font_size_override("font_size", 17)
	if detail_meta:
		detail_meta.add_theme_font_size_override("font_size", 11)
	if context_label:
		context_label.add_theme_font_size_override("font_size", 12)
	if close_button:
		close_button.custom_minimum_size = Vector2(48.0, 48.0)


func is_compact_layout() -> bool:
	return _compact_layout


func layout_size() -> Vector2:
	return COMPACT_PANEL_SIZE if _compact_layout else NORMAL_PANEL_SIZE


func _on_close_pressed() -> void:
	clear()
	close_requested.emit()


func _resolve_nodes() -> void:
	if detail_image == null:
		detail_image = get_node_or_null("Content/Body/ImageColumn/ImageFrame/ImageMargin/DetailImage") as TextureRect
	if detail_title == null:
		detail_title = get_node_or_null("Content/Header/TitleColumn/DetailTitle") as Label
	if detail_meta == null:
		detail_meta = get_node_or_null("Content/Header/TitleColumn/DetailMeta") as Label
	if detail_text == null:
		detail_text = get_node_or_null("Content/Body/DetailText") as RichTextLabel
	if context_label == null:
		context_label = get_node_or_null("Content/Body/ImageColumn/ContextLabel") as Label
	if close_button == null:
		close_button = get_node_or_null("Content/Header/CloseButton") as Button


func _card_meta_text(card: Dictionary) -> String:
	var supertype := str(card.get("supertype", ""))
	var labels: Array[String] = [_localize_supertype(supertype)]
	for subtype_value in card.get("subtypes", []):
		var subtype := _localize_subtype(str(subtype_value), supertype)
		if not subtype.is_empty() and subtype not in labels:
			labels.append(subtype)
	var energy_types: Array[String] = []
	for type_value in card.get("energy_types", []):
		energy_types.append(_localize_energy_type(str(type_value)))
	if not energy_types.is_empty():
		labels.append("属性：%s" % "／".join(energy_types))
	return " · ".join(labels.filter(func(value: String) -> bool: return not value.is_empty()))


func _card_detail_bbcode(card: Dictionary, pokemon: PokemonState) -> String:
	var rows: Array[String] = []
	var maximum_hp := int(card.get("hp", 0))
	if maximum_hp > 0:
		var hp_text := "[color=#f2f6ff][b]HP %d[/b][/color]" % maximum_hp
		if pokemon:
			var current_hp := pokemon.current_hp(_catalog)
			var damage := pokemon.damage_counters * 10
			if current_hp + damage == maximum_hp:
				hp_text = "[color=#f2f6ff][b]HP %d／%d[/b][/color]  ·  伤害 %d" % [
					current_hp,
					maximum_hp,
					damage,
				]
			else:
				# Effects such as Bravery Charm alter maximum HP. PokemonState
				# exposes the effective remaining HP but not the effective maximum;
				# label the printed value explicitly instead of showing a false ratio.
				hp_text = (
					"[color=#f2f6ff][b]剩余 HP %d[/b][/color]"
					+ "  ·  卡面 HP %d\n伤害 %d"
				) % [current_hp, maximum_hp, damage]
		rows.append(hp_text)

	var evolves_from := str(card.get("evolves_from", "")).strip_edges()
	if not evolves_from.is_empty():
		rows.append("[color=#9eb0ca]进化自[/color]  %s" % _safe_text(evolves_from))
	if pokemon:
		_append_pokemon_state(rows, pokemon)

	for ability_value in card.get("abilities", []):
		var ability := Dictionary(ability_value)
		var ability_name := str(ability.get("name", ""))
		var state_label := ""
		if pokemon and ability_name in pokemon.used_abilities:
			state_label = "  [color=#8494aa]（本回合已使用）[/color]"
		rows.append("[color=#62d7ff][b]特性 · %s[/b][/color]%s\n%s" % [
			_safe_text(ability_name),
			state_label,
			_safe_text(str(ability.get("text", ""))),
		])

	for attack_value in card.get("attacks", []):
		var attack := Dictionary(attack_value)
		var cost_text := _energy_cost_text(attack.get("cost", []))
		var damage_text := str(attack.get("damage_text", "")).strip_edges()
		if damage_text.is_empty() and int(attack.get("damage", 0)) > 0:
			damage_text = str(attack.get("damage", 0))
		var heading := "招式 · %s" % _safe_text(str(attack.get("name", "")))
		if not damage_text.is_empty():
			heading += "　%s" % _safe_text(damage_text)
		var attack_rows: Array[String] = ["[color=#f4c84a][b]%s[/b][/color]" % heading]
		if not cost_text.is_empty():
			attack_rows.append("[color=#9eb0ca]费用：%s[/color]" % cost_text)
		var attack_text := str(attack.get("text", "")).strip_edges()
		if not attack_text.is_empty():
			attack_rows.append(_safe_text(attack_text))
		rows.append("\n".join(attack_rows))

	var provides := _energy_cost_text(card.get("provides_energy", []))
	if not provides.is_empty():
		rows.append("[color=#7de6b2][b]提供能量[/b][/color]\n%s" % provides)

	var seen_rules: Dictionary = {}
	var trainer_text := str(card.get("trainer_text", "")).strip_edges()
	if not trainer_text.is_empty():
		seen_rules[trainer_text] = true
		rows.append("[color=#62d7ff][b]卡牌效果[/b][/color]\n%s" % _safe_text(trainer_text))
	for rule_value in card.get("rules", []):
		var rule := str(rule_value).strip_edges()
		if rule.is_empty() or seen_rules.has(rule):
			continue
		seen_rules[rule] = true
		rows.append("[color=#62d7ff][b]规则说明[/b][/color]\n%s" % _safe_text(rule))

	var footer: Array[String] = []
	var retreat := int(card.get("retreat_cost", 0))
	if maximum_hp > 0:
		footer.append("撤退费用：%d" % retreat)
	var weakness := _matchup_text(card.get("weaknesses", []))
	if not weakness.is_empty():
		footer.append("弱点：%s" % weakness)
	var resistance := _matchup_text(card.get("resistances", []))
	if not resistance.is_empty():
		footer.append("抗性：%s" % resistance)
	if not footer.is_empty():
		rows.append("[color=#9eb0ca]%s[/color]" % "　·　".join(footer))
	if rows.is_empty():
		rows.append("[color=#9eb0ca]这张卡没有额外说明。[/color]")
	return "\n\n".join(rows)


func _append_pokemon_state(rows: Array[String], pokemon: PokemonState) -> void:
	var states: Array[String] = []
	for status in pokemon.status_conditions:
		states.append(str(STATUS_NAMES.get(str(status).to_upper(), status)))
	if pokemon.attack_is_locked():
		states.append("无法攻击")
	if pokemon.has_attack_gate("dazzled"):
		states.append("受幻惑影响")
	rows.append("[color=#9eb0ca]特殊状态[/color]  %s" % (
		"、".join(states) if not states.is_empty() else "无"
	))

	var energy_counts: Dictionary = {}
	for energy_id in pokemon.energy_card_ids:
		var energy_name := _catalog.card_name(energy_id)
		energy_counts[energy_name] = int(energy_counts.get(energy_name, 0)) + 1
	var energy_labels: Array[String] = []
	for energy_name_value in energy_counts:
		var energy_name := str(energy_name_value)
		var count := int(energy_counts[energy_name_value])
		energy_labels.append("%s ×%d" % [_safe_text(energy_name), count] if count > 1 else _safe_text(energy_name))
	rows.append("[color=#9eb0ca]附着能量（%d）[/color]  %s" % [
		pokemon.energy_card_ids.size(),
		"、".join(energy_labels) if not energy_labels.is_empty() else "无",
	])
	var tool_name := "无"
	if not pokemon.attached_tool_id.is_empty():
		tool_name = _safe_text(_catalog.card_name(pokemon.attached_tool_id))
	rows.append("[color=#9eb0ca]宝可梦道具[/color]  %s" % tool_name)


func _energy_cost_text(values: Array) -> String:
	var counts: Dictionary = {}
	var order: Array[String] = []
	for value in values:
		var label := _localize_energy_type(str(value))
		if not counts.has(label):
			order.append(label)
		counts[label] = int(counts.get(label, 0)) + 1
	var parts: Array[String] = []
	for label in order:
		var count := int(counts[label])
		parts.append("%s ×%d" % [_safe_text(label), count] if count > 1 else _safe_text(label))
	return "、".join(parts)


func _matchup_text(values: Array) -> String:
	var parts: Array[String] = []
	for value in values:
		var row := Dictionary(value)
		parts.append("%s %s" % [
			_localize_energy_type(str(row.get("energy_type", ""))),
			_safe_text(str(row.get("value", ""))),
		])
	return "、".join(parts)


func _localize_supertype(value: String) -> String:
	return str(SUPERTYPE_NAMES.get(value.to_lower(), value))


func _localize_subtype(value: String, supertype: String) -> String:
	var key := value.to_lower()
	if key == "basic":
		return "基本" if supertype.to_lower() == "energy" else "基础"
	return str(SUBTYPE_NAMES.get(key, value))


func _localize_energy_type(value: String) -> String:
	return str(ENERGY_TYPE_NAMES.get(value.to_lower(), value))


func _safe_text(value: String) -> String:
	return value.replace("[", "［").replace("]", "］")


func _card_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	var texture_cache := (
		tree.root.get_node_or_null("CardTextureCache")
		if tree and tree.root
		else null
	)
	if texture_cache and texture_cache.has_method("get_texture"):
		return texture_cache.call("get_texture", path) as Texture2D
	return load(path) as Texture2D if ResourceLoader.exists(path, "Texture2D") else null

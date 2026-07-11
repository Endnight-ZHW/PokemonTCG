class_name DeckDetailPanel
extends VBoxContainer

signal card_requested(context: Dictionary)

const CATEGORY_ORDER: Array[String] = ["Pokémon", "Trainer", "Energy"]
const CATEGORY_LABELS := {
	"Pokémon": "宝可梦",
	"Trainer": "训练家",
	"Energy": "能量",
}

var catalog: CardCatalog
var _deck_key := ""
var _category_grids: Array[GridContainer] = []

@onready var deck_name_label: Label = %DeckName
@onready var deck_meta_label: Label = %DeckMeta
@onready var deck_summary_label: Label = %DeckSummary
@onready var deck_accent: ColorRect = %DeckAccent
@onready var core_grid: GridContainer = %CoreGrid
@onready var categories: VBoxContainer = %Categories


func _ready() -> void:
	_resolve_nodes()
	resized.connect(_apply_responsive_columns)
	call_deferred("_apply_responsive_columns")


func configure(p_catalog: CardCatalog, deck_key: String) -> bool:
	_resolve_nodes()
	catalog = p_catalog
	_deck_key = deck_key
	_clear_dynamic_content()
	var deck := catalog.get_deck(deck_key)
	if deck.is_empty():
		deck_name_label.text = "找不到牌组"
		deck_meta_label.text = deck_key
		deck_summary_label.text = "请关闭详情并重新选择一个有效牌组。"
		return false
	var grouped := _group_rows(deck)
	var counts := _category_counts(grouped)
	var energy_type := str(deck.get("energy_type", "Colorless"))
	deck_accent.color = DesignTokens.type_color(energy_type)
	deck_name_label.text = str(deck.get("name", deck_key))
	deck_meta_label.text = "%s · %s · 共 %d 张" % [
		deck_key,
		_energy_display_name(energy_type),
		int(deck.get("card_count", 0)),
	]
	deck_summary_label.text = "宝可梦 %d　 训练家 %d　 能量 %d" % [
		int(counts.get("Pokémon", 0)),
		int(counts.get("Trainer", 0)),
		int(counts.get("Energy", 0)),
	]
	for card_id in DeckVisualCatalog.preview_cards(catalog, deck_key, 4):
		_add_core_card(card_id)
	for supertype in CATEGORY_ORDER:
		var rows: Array = grouped.get(supertype, [])
		if not rows.is_empty():
			_add_category(supertype, rows, int(counts.get(supertype, 0)))
	call_deferred("_apply_responsive_columns")
	return true


func _resolve_nodes() -> void:
	deck_name_label = get_node("HeaderPanel/HeaderMargin/HeaderContent/DeckName") as Label
	deck_meta_label = get_node("HeaderPanel/HeaderMargin/HeaderContent/DeckMeta") as Label
	deck_summary_label = get_node(
		"HeaderPanel/HeaderMargin/HeaderContent/DeckSummary"
	) as Label
	deck_accent = get_node("HeaderPanel/HeaderMargin/HeaderContent/DeckAccent") as ColorRect
	core_grid = get_node("CoreGrid") as GridContainer
	categories = get_node("Categories") as VBoxContainer


func _group_rows(deck: Dictionary) -> Dictionary:
	var grouped := {"Pokémon": [], "Trainer": [], "Energy": []}
	for row_value in deck.get("cards", []):
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var card := catalog.get_card(card_id)
		var supertype := str(card.get("supertype", ""))
		if not grouped.has(supertype):
			grouped[supertype] = []
		(grouped[supertype] as Array).append({
			"card_id": card_id,
			"count": int(row.get("count", 0)),
			"name": str(card.get("name", card_id)),
		})
	return grouped


func _category_counts(grouped: Dictionary) -> Dictionary:
	var result := {"Pokémon": 0, "Trainer": 0, "Energy": 0}
	for supertype in grouped.keys():
		var total := 0
		for row_value in grouped[supertype]:
			total += int((row_value as Dictionary).get("count", 0))
		result[supertype] = total
	return result


func _add_core_card(card_id: String) -> void:
	var card := catalog.get_card(card_id)
	var button := Button.new()
	button.custom_minimum_size = Vector2(112, 148)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_NONE
	button.theme_type_variation = &"FrontGhostButton"
	button.tooltip_text = catalog.card_name(card_id)
	button.accessibility_name = "查看卡牌：%s" % catalog.card_name(card_id)
	button.pressed.connect(_on_core_card_pressed.bind(card_id))
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.add_child(center)
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(94, 132)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.theme_type_variation = &"FrontCardFrame"
	center.add_child(frame)
	var image := TextureRect.new()
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture = _card_texture(str(card.get("image_path", "")))
	frame.add_child(image)
	core_grid.add_child(button)


func _on_core_card_pressed(card_id: String) -> void:
	card_requested.emit({"card_id": card_id, "location": "核心卡牌"})


func _add_category(supertype: String, rows: Array, total_count: int) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.theme_type_variation = &"FrontSectionPanel"
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)
	var title := Label.new()
	title.theme_type_variation = &"FrontSectionLabel"
	title.text = "%s · %d 张 · %d 种" % [
		str(CATEGORY_LABELS.get(supertype, supertype)),
		total_count,
		rows.size(),
	]
	content.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	content.add_child(grid)
	_category_grids.append(grid)
	for row_value in rows:
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var item := Button.new()
		item.custom_minimum_size = Vector2(0, 58)
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.focus_mode = Control.FOCUS_NONE
		item.theme_type_variation = &"FrontGhostButton"
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.clip_text = true
		item.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		item.text = "%2d × %s\n%s" % [
			int(row.get("count", 0)),
			str(row.get("name", card_id)),
			card_id,
		]
		item.tooltip_text = "查看卡牌 · %s" % str(row.get("name", card_id))
		item.accessibility_name = "%d 张 %s" % [
			int(row.get("count", 0)),
			str(row.get("name", card_id)),
		]
		item.pressed.connect(_on_list_card_pressed.bind(card_id, supertype))
		grid.add_child(item)
	categories.add_child(panel)


func _on_list_card_pressed(card_id: String, supertype: String) -> void:
	card_requested.emit({
		"card_id": card_id,
		"location": str(CATEGORY_LABELS.get(supertype, supertype)),
	})


func _apply_responsive_columns() -> void:
	var available := size.x
	if available <= 0.0:
		return
	core_grid.columns = clampi(int(floor(available / 116.0)), 1, 4)
	var list_columns := 3 if available >= 1080.0 else 2 if available >= 620.0 else 1
	for grid in _category_grids:
		if is_instance_valid(grid):
			grid.columns = list_columns


func _clear_dynamic_content() -> void:
	for child in core_grid.get_children():
		core_grid.remove_child(child)
		child.queue_free()
	for child in categories.get_children():
		categories.remove_child(child)
		child.queue_free()
	_category_grids.clear()


func _energy_display_name(energy_type: String) -> String:
	return {
		"Grass": "草属性",
		"Fire": "火属性",
		"Water": "水属性",
		"Lightning": "雷属性",
		"Psychic": "超能力",
		"Fighting": "斗属性",
		"Darkness": "恶属性",
		"Metal": "钢属性",
		"Dragon": "龙属性",
		"Colorless": "无色",
	}.get(energy_type, energy_type)


func _card_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	var cache := (
		tree.root.get_node_or_null("CardTextureCache")
		if tree and tree.root
		else null
	)
	if cache and cache.has_method("get_texture"):
		return cache.call("get_texture", path) as Texture2D
	return load(path) as Texture2D if ResourceLoader.exists(path) else null

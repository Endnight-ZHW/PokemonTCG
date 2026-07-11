class_name DeckGalleryTile
extends Button

var deck_key := ""

@onready var artwork: TextureRect = %Artwork
@onready var accent: ColorRect = %Accent
@onready var deck_name_label: Label = %DeckName
@onready var energy_label: Label = %EnergyLabel
@onready var tagline_label: Label = %TaglineLabel
@onready var assignment_label: Label = %AssignmentLabel


func configure(
	catalog: CardCatalog,
	p_deck_key: String,
	representative_card_id: String,
) -> void:
	_resolve_nodes()
	deck_key = p_deck_key
	var deck := catalog.get_deck(deck_key)
	var card := catalog.get_card(representative_card_id)
	deck_name_label.text = str(deck.get("name", deck_key))
	var energy_type := str(deck.get("energy_type", "Colorless"))
	energy_label.text = "%s · %d 张" % [
		_energy_display_name(energy_type),
		int(deck.get("card_count", 0)),
	]
	tagline_label.text = DeckVisualCatalog.tagline(deck_key)
	accent.color = DesignTokens.type_color(energy_type)
	artwork.texture = _card_texture(str(card.get("image_path", "")))
	artwork.tooltip_text = str(card.get("name", representative_card_id))
	tooltip_text = "%s\n%s" % [deck_name_label.text, tagline_label.text]
	accessibility_name = "牌组：%s，%s" % [deck_name_label.text, energy_label.text]


func _resolve_nodes() -> void:
	artwork = get_node("Margin/Content/ArtworkFrame/Artwork") as TextureRect
	accent = get_node("Accent") as ColorRect
	deck_name_label = get_node("Margin/Content/Info/DeckName") as Label
	energy_label = get_node("Margin/Content/Info/EnergyLabel") as Label
	tagline_label = get_node("Margin/Content/Info/TaglineLabel") as Label
	assignment_label = get_node("Margin/Content/Info/AssignmentLabel") as Label


func set_assignment_state(
	active_player_idx: int,
	selected_keys: Array[String],
	second_slot_name: String,
) -> void:
	var assignments: Array[String] = []
	if selected_keys.size() > 0 and selected_keys[0] == deck_key:
		assignments.append("玩家 1")
	if selected_keys.size() > 1 and selected_keys[1] == deck_key:
		assignments.append(second_slot_name)
	assignment_label.text = " / ".join(assignments)
	assignment_label.visible = not assignments.is_empty()
	set_pressed_no_signal(
		active_player_idx >= 0
		and active_player_idx < selected_keys.size()
		and selected_keys[active_player_idx] == deck_key
	)
	accessibility_description = (
		"已分配给%s" % "、".join(assignments)
		if not assignments.is_empty()
		else "尚未分配"
	)


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

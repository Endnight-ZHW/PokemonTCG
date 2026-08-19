class_name DeckGalleryTile
extends Button

const EnergyIconCatalog = preload("res://ui/energy_icon_catalog.gd")

var deck_key := ""

@onready var artwork: TextureRect = %Artwork
@onready var artwork_frame: PanelContainer = %ArtworkFrame
@onready var deck_name_label: Label = %DeckName
@onready var energy_badge: PanelContainer = %EnergyBadge
@onready var energy_icon: TextureRect = %EnergyIcon
@onready var energy_label: Label = %EnergyLabel
@onready var card_count_label: Label = %CardCountLabel
@onready var tagline_label: Label = %TaglineLabel
@onready var assignment_badge: PanelContainer = %AssignmentBadge
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
	_configure_energy_badge(energy_type)
	card_count_label.text = "· %d 张" % int(deck.get("card_count", 0))
	tagline_label.text = DeckVisualCatalog.tagline(deck_key)
	_apply_energy_style(DesignTokens.type_color(energy_type))
	var tree := Engine.get_main_loop() as SceneTree
	var texture_cache := (
		tree.root.get_node_or_null("CardTextureCache")
		if tree and tree.root
		else null
	)
	artwork.texture = (
		texture_cache.call("get_texture", str(card.get("image_path", ""))) as Texture2D
		if texture_cache
		else null
	)
	artwork.tooltip_text = str(card.get("name", representative_card_id))
	tooltip_text = "%s\n%s" % [deck_name_label.text, tagline_label.text]
	accessibility_name = "牌组：%s，%s，%s" % [
		deck_name_label.text,
		energy_label.text,
		card_count_label.text,
	]


func _resolve_nodes() -> void:
	artwork = get_node("Margin/Content/ArtworkFrame/Artwork") as TextureRect
	artwork_frame = get_node("Margin/Content/ArtworkFrame") as PanelContainer
	deck_name_label = get_node("Margin/Content/Info/TitleRow/DeckName") as Label
	assignment_badge = get_node("Margin/Content/Info/TitleRow/AssignmentBadge") as PanelContainer
	assignment_label = assignment_badge.get_node("AssignmentLabel") as Label
	energy_badge = get_node("Margin/Content/Info/MetaRow/EnergyBadge") as PanelContainer
	energy_icon = energy_badge.get_node("EnergyContent/EnergyIcon") as TextureRect
	energy_label = energy_badge.get_node("EnergyContent/EnergyLabel") as Label
	card_count_label = get_node("Margin/Content/Info/MetaRow/CardCountLabel") as Label
	tagline_label = get_node("Margin/Content/Info/TaglineLabel") as Label


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
	var compact_assignments: Array[String] = []
	for assignment in assignments:
		if assignment == "玩家 1":
			compact_assignments.append("P1")
		elif assignment.contains("AI"):
			compact_assignments.append("AI")
		else:
			compact_assignments.append("P2")
	assignment_label.text = " · ".join(compact_assignments)
	assignment_label.tooltip_text = " / ".join(assignments)
	assignment_badge.custom_minimum_size.x = 46.0 if assignments.size() <= 1 else 72.0
	assignment_badge.visible = not assignments.is_empty()
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


func _configure_energy_badge(energy_type: String) -> void:
	var display_name := EnergyIconCatalog.type_display_name_for(energy_type)
	var icon_texture := EnergyIconCatalog.texture_for(energy_type)
	energy_label.text = display_name
	energy_icon.texture = icon_texture
	energy_icon.visible = icon_texture != null
	energy_icon.tooltip_text = display_name if icon_texture != null else ""
	energy_badge.tooltip_text = display_name
	energy_badge.accessibility_name = "牌组属性：%s" % display_name


func _apply_energy_style(type_color: Color) -> void:
	energy_label.add_theme_color_override("font_color", Color("#e3f0ff"))
	energy_badge.add_theme_stylebox_override(
		"panel",
		_badge_style(type_color, 0.13, 0.62, 8.0, Vector4(7, 3, 7, 3)),
	)
	var base_artwork_style := artwork_frame.get_theme_stylebox("panel")
	var artwork_style := (
		base_artwork_style.duplicate() as StyleBoxFlat
		if base_artwork_style != null
		else null
	)
	if artwork_style:
		artwork_style.border_color = Color(type_color.r, type_color.g, type_color.b, 0.72)
		artwork_style.bg_color = artwork_style.bg_color.lerp(type_color, 0.045)
		artwork_frame.add_theme_stylebox_override("panel", artwork_style)
	assignment_badge.add_theme_stylebox_override(
		"panel",
		_badge_style(DesignTokens.GOLD, 0.1, 0.5, 8.0, Vector4(7, 3, 7, 3)),
	)


func _badge_style(
	color: Color,
	background_alpha: float,
	border_alpha: float,
	radius: float,
	margins: Vector4,
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color.r, color.g, color.b, background_alpha)
	style.border_color = Color(color.r, color.g, color.b, border_alpha)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(round(radius)))
	style.content_margin_left = margins.x
	style.content_margin_top = margins.y
	style.content_margin_right = margins.z
	style.content_margin_bottom = margins.w
	return style

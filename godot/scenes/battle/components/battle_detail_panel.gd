class_name BattleDetailPanel
extends PanelContainer

signal close_requested

const NORMAL_PANEL_SIZE := Vector2(420.0, 336.0)
const COMPACT_PANEL_SIZE := Vector2(440.0, 220.0)

@onready var detail_image: TextureRect = %DetailImage
@onready var detail_title: Label = %DetailTitle
@onready var detail_meta: Label = %DetailMeta
@onready var detail_text: RichTextLabel = %DetailText
@onready var state_panel: PanelContainer = %StatePanel
@onready var state_text: RichTextLabel = %StateText
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
	if state_text:
		state_text.focus_mode = Control.FOCUS_NONE
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
	var tree := Engine.get_main_loop() as SceneTree
	var texture_cache := (
		tree.root.get_node_or_null("CardTextureCache")
		if tree and tree.root
		else null
	)
	detail_image.texture = (
		texture_cache.call("get_texture", str(card.get("image_path", ""))) as Texture2D
		if texture_cache
		else null
	)
	detail_image.tooltip_text = ""
	detail_image.accessibility_name = str(card.get("name", card_id))
	detail_title.text = str(card.get("name", card_id))
	detail_title.tooltip_text = ""
	detail_title.accessibility_name = detail_title.text
	detail_meta.text = _card_meta_text(card)
	detail_text.text = _card_detail_bbcode(card)
	detail_text.tooltip_text = ""
	detail_text.accessibility_description = CardPresentation.accessibility_text(
		card,
		_catalog,
		pokemon,
	)
	detail_text.scroll_to_line(0)
	state_panel.visible = pokemon != null
	state_text.text = CardPresentation.battle_state_bbcode(
		pokemon,
		_catalog,
		int(card.get("hp", 0)),
	) if pokemon != null else ""
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
		detail_text.tooltip_text = ""
		detail_text.accessibility_description = ""
	if state_panel:
		state_panel.visible = false
	if state_text:
		state_text.text = ""
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
	var state_surface := get_node_or_null(
		"Content/Body/DetailColumn/StatePanel"
	) as Control
	if header:
		header.custom_minimum_size.y = 48.0
	if content:
		content.add_theme_constant_override("separation", 4 if value else 6)
	if body:
		body.add_theme_constant_override("separation", 6 if value else 10)
	if image_column:
		image_column.custom_minimum_size.x = 84.0 if value else 112.0
	if image_frame:
		image_frame.custom_minimum_size = (
			Vector2(84.0, 117.0) if value else Vector2(112.0, 157.0)
		)
	if detail_text:
		detail_text.custom_minimum_size.x = 0.0
		detail_text.add_theme_font_size_override(
			"normal_font_size",
			11 if value else 12,
		)
	if state_surface:
		state_surface.custom_minimum_size.y = 52.0 if value else 62.0
	if state_text:
		state_text.add_theme_font_size_override(
			"normal_font_size",
			10 if value else 11,
		)
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
		detail_text = get_node_or_null(
			"Content/Body/DetailColumn/DetailText"
		) as RichTextLabel
	if state_panel == null:
		state_panel = get_node_or_null(
			"Content/Body/DetailColumn/StatePanel"
		) as PanelContainer
	if state_text == null:
		state_text = get_node_or_null(
			"Content/Body/DetailColumn/StatePanel/StateMargin/StateText"
		) as RichTextLabel
	if context_label == null:
		context_label = get_node_or_null("Content/Body/ImageColumn/ContextLabel") as Label
	if close_button == null:
		close_button = get_node_or_null("Content/Header/CloseButton") as Button


func _card_meta_text(card: Dictionary) -> String:
	return CardPresentation.meta_text(card)


func _card_detail_bbcode(card: Dictionary) -> String:
	return CardPresentation.detail_bbcode(
		card,
		_catalog,
		null,
		CardPresentation.DetailLevel.COMPACT,
	)

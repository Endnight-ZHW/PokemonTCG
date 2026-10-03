class_name BattleDetailPanel
extends PanelContainer

signal close_requested

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

	var changed_card := current_card_id != card_id
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
	if changed_card:
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


func fit_available_size(available: Vector2) -> void:
	_resolve_nodes()
	var image_width := clampf(available.x * 0.267, 56.0, 112.0)
	get_node("Content/Body/ImageColumn").custom_minimum_size.x = image_width
	get_node("Content/Body/ImageColumn/ImageFrame").custom_minimum_size = Vector2(
		image_width, minf(image_width * 1.4, maxf(72.0, available.y - 100.0)))
	get_node("Content/Body").add_theme_constant_override("separation", 8 if available.x < 340 else 12)
	get_node("Content").add_theme_constant_override("separation", 4 if available.y < 220.0 else 6)
	detail_text.add_theme_font_size_override("normal_font_size", 14)
	state_text.add_theme_font_size_override("normal_font_size", 12)
	state_panel.custom_minimum_size.y = clampf(available.y - 152.0, 48.0, 68.0)
	state_text.scroll_active = true
	state_text.mouse_filter = Control.MOUSE_FILTER_STOP
	close_button.custom_minimum_size = Vector2(UILayoutPolicy.TOUCH_MIN, UILayoutPolicy.TOUCH_MIN)
	custom_minimum_size = available
	size = available


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

class_name CardArtPanel
extends TextureRect

## Full artwork inside the existing ModalHost; no independent popup window.
var _scroll: ScrollContainer


func _ready() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ancestor := get_parent()
	while ancestor:
		if ancestor is ScrollContainer:
			_scroll = ancestor as ScrollContainer
			_scroll.resized.connect(_fit_viewport)
			break
		ancestor = ancestor.get_parent()
	_fit_viewport.call_deferred()


func _fit_viewport() -> void:
	if is_instance_valid(_scroll):
		custom_minimum_size = Vector2(0, maxf(1, _scroll.size.y))

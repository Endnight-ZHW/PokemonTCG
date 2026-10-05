class_name FrontendReadingPane
extends RefCounted

static func wrap(content: Control) -> ScrollContainer:
	var layout := content.get_parent() as Control
	var index := content.get_index()
	var scroll := ScrollContainer.new()
	scroll.name = "ReadingScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	layout.move_child(scroll, index)
	content.reparent(scroll)
	content.custom_minimum_size = Vector2.ZERO
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	FrontendPalette.style_scrollbar(scroll.get_v_scroll_bar())
	return scroll

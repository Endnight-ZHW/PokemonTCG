@tool
extends Control

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)

func _draw() -> void:
	var label := get_parent() as Label
	if label == null:
		return
	var font_size := label.get_theme_font_size("font_size")
	var y := label.size.y - font_size * 0.35
	draw_style_box(HomePalette.surface(HomePalette.SUNLIGHT, 5), Rect2(2, y, font_size * 2.45, font_size * 0.31))

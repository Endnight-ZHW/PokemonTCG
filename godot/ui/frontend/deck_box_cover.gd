@tool
class_name DeckBoxCover
extends PanelContainer

@export var energy_color := Color("55b96a"):
	set(value):
		energy_color = value
		queue_redraw()

func _ready() -> void:
	var inset := StyleBoxEmpty.new()
	inset.content_margin_top = 12
	inset.content_margin_bottom = 10
	add_theme_stylebox_override("panel", inset)
	resized.connect(queue_redraw)

func _draw() -> void:
	var box_width := (size.y - 22) * 63.0 / 88.0 + 16
	var left := (size.x - box_width) * 0.5
	var cover := Rect2(left, 4, box_width, size.y - 7)
	# A light card pocket: paper edges and a small attribute tab, without a
	# dark slab behind the original card artwork.
	draw_style_box(FrontendPalette.panel(Color("e4dfd3"), 5, Color.TRANSPARENT, 0, 0), Rect2(cover.position + Vector2(3, 2), cover.size))
	draw_style_box(FrontendPalette.panel(FrontendPalette.CARD_PAPER, 5, Color("c7c2b5"), 1, 0), cover)
	draw_rect(Rect2(left + 10, 4, 30, 3), energy_color)

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
	var glow := FrontendPalette.BACKGROUND.lerp(energy_color, 0.06)
	draw_style_box(FrontendPalette.panel(glow, 16, Color.TRANSPARENT, 0, 0), Rect2(Vector2.ZERO, size))

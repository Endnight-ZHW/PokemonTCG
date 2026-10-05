class_name ResultCelebration
extends Control

var elapsed := 1.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)

func play() -> void:
	if not FrontendMotion.decorative_motion_enabled():
		return
	elapsed = 0.0
	set_process(true)
	queue_redraw()

func finish() -> void:
	elapsed = 1.0
	set_process(false)
	queue_redraw()

func _process(delta: float) -> void:
	elapsed = minf(1.0, elapsed + delta)
	queue_redraw()
	if elapsed >= 1.0 or not FrontendMotion.decorative_motion_enabled() or not is_visible_in_tree():
		finish()

func _draw() -> void:
	if elapsed >= 1.0:
		return
	var colors := [Color("df6655"), Color("477fbd"), Color("dfb85b")]
	for index in range(28):
		var angle := float(index) * 2.39996
		var spread := 70.0 + float(index % 7) * 24.0
		var origin := Vector2(size.x * 0.5, size.y * 0.3)
		var at := origin + Vector2(cos(angle), sin(angle)) * spread * elapsed + Vector2(0, 130.0 * elapsed * elapsed)
		var tint: Color = colors[index % 3]
		tint.a = (1.0 - elapsed) * 0.8
		if index % 3 == 0:
			draw_circle(at, 3.0, tint, true, -1, true)
		else:
			draw_set_transform(at, angle + elapsed * 3.0)
			draw_rect(Rect2(-3, -5, 6, 10), tint)
			draw_set_transform(Vector2.ZERO)

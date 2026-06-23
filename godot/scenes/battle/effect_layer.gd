class_name BattleEffectLayer
extends Control

var particles: Array[Dictionary] = []
var floating_texts: Array[Dictionary] = []
var quality_profile := "high"
const MAX_PARTICLES := 220
const MAX_FLOATING_TEXTS := 18


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func burst(position_value: Vector2, color: Color, kind: String) -> void:
	var count := 10 if quality_profile == "low" else 18 if quality_profile == "medium" else 28
	if kind in ["evolution", "ko"]:
		count = int(count * 1.5)
	var available := maxi(0, MAX_PARTICLES - particles.size())
	count = mini(count, available)
	for index in range(count):
		var angle := TAU * float(index) / float(maxi(1, count))
		angle += randf_range(-0.22, 0.22)
		var speed := randf_range(55.0, 150.0)
		particles.append({
			"position": position_value,
			"velocity": Vector2.from_angle(angle) * speed,
			"color": color.lightened(randf_range(-0.08, 0.2)),
			"life": randf_range(0.38, 0.76),
			"total": 0.76,
			"size": randf_range(2.0, 6.0),
			"gravity": Vector2(0, 65.0),
		})


func floating_text(
	text: String,
	position_value: Vector2,
	color: Color,
) -> void:
	while floating_texts.size() >= MAX_FLOATING_TEXTS:
		floating_texts.pop_front()
	floating_texts.append({
		"text": text,
		"position": position_value,
		"color": color,
		"life": 1.05,
		"total": 1.05,
	})


func clear_transients() -> void:
	particles.clear()
	floating_texts.clear()
	queue_redraw()


func _process(delta: float) -> void:
	var live_particles: Array[Dictionary] = []
	for row in particles:
		row["life"] = float(row["life"]) - delta
		if float(row["life"]) <= 0.0:
			continue
		row["velocity"] = Vector2(row["velocity"]) + Vector2(row["gravity"]) * delta
		row["position"] = Vector2(row["position"]) + Vector2(row["velocity"]) * delta
		live_particles.append(row)
	particles = live_particles
	var live_texts: Array[Dictionary] = []
	for row in floating_texts:
		row["life"] = float(row["life"]) - delta
		if float(row["life"]) <= 0.0:
			continue
		row["position"] = Vector2(row["position"]) + Vector2(0, -38.0) * delta
		live_texts.append(row)
	floating_texts = live_texts
	if not particles.is_empty() or not floating_texts.is_empty():
		queue_redraw()


func _draw() -> void:
	for row in particles:
		var alpha := clampf(float(row["life"]) / float(row["total"]), 0.0, 1.0)
		var color: Color = row["color"]
		color.a = alpha
		draw_circle(
			Vector2(row["position"]),
			float(row["size"]) * (0.55 + alpha * 0.45),
			color,
		)
	for row in floating_texts:
		var alpha := clampf(float(row["life"]) / float(row["total"]), 0.0, 1.0)
		var color: Color = row["color"]
		color.a = alpha
		var font := ThemeDB.fallback_font
		var text := str(row["text"])
		var position_value: Vector2 = row["position"]
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
		draw_string(
			font,
			position_value - Vector2(width * 0.5, 0),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			28,
			color,
		)

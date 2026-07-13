class_name BattleEffectLayer
extends Control

var particles: Array[Dictionary] = []
var floating_texts: Array[Dictionary] = []
var impact_rings: Array[Dictionary] = []
var quality_profile := "high"
const MAX_PARTICLES := 220
const MAX_FLOATING_TEXTS := 18
const MAX_IMPACT_RINGS := 24
const FLOATING_TEXT_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


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
			"shape": "streak" if index % 3 == 0 else "spark" if index % 3 == 1 else "orb",
		})
	var ring_count_before := impact_rings.size()
	_add_impact_rings(position_value, color, kind)
	if count > 0 or impact_rings.size() > ring_count_before:
		_update_processing()
		queue_redraw()


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
	_update_processing()
	queue_redraw()


func clear_transients() -> void:
	particles.clear()
	floating_texts.clear()
	impact_rings.clear()
	set_process(false)
	queue_redraw()


func _process(delta: float) -> void:
	var had_transients := (
		not particles.is_empty()
		or not floating_texts.is_empty()
		or not impact_rings.is_empty()
	)
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
	var live_rings: Array[Dictionary] = []
	for row in impact_rings:
		row["life"] = float(row["life"]) - delta
		if float(row["life"]) > 0.0:
			live_rings.append(row)
	impact_rings = live_rings
	if had_transients:
		queue_redraw()
	_update_processing()


func _update_processing() -> void:
	set_process(
		not particles.is_empty()
		or not floating_texts.is_empty()
		or not impact_rings.is_empty()
	)


func _draw() -> void:
	for row in impact_rings:
		var progress := 1.0 - clampf(float(row["life"]) / float(row["total"]), 0.0, 1.0)
		var ring_color: Color = row["color"]
		ring_color.a = (1.0 - progress) * float(row["alpha"])
		var radius := lerpf(float(row["start_radius"]), float(row["end_radius"]), progress)
		draw_arc(
			Vector2(row["position"]),
			radius,
			0.0,
			TAU,
			64 if quality_profile == "high" else 36,
			ring_color,
			lerpf(float(row["width"]), 1.0, progress),
			true,
		)
	for row in particles:
		var alpha := clampf(float(row["life"]) / float(row["total"]), 0.0, 1.0)
		var color: Color = row["color"]
		color.a = alpha
		var particle_position := Vector2(row["position"])
		var particle_size := float(row["size"]) * (0.55 + alpha * 0.45)
		match str(row.get("shape", "orb")):
			"streak":
				var direction := Vector2(row["velocity"]).normalized()
				draw_line(
					particle_position - direction * particle_size * 2.6,
					particle_position + direction * particle_size * 0.8,
					color,
					maxf(1.0, particle_size * 0.72),
					true,
				)
			"spark":
				draw_set_transform(particle_position, PI * 0.25, Vector2.ONE)
				draw_rect(
					Rect2(Vector2(-particle_size, -particle_size), Vector2.ONE * particle_size * 2.0),
					color,
					true,
				)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			_:
				draw_circle(particle_position, particle_size, color)
	for row in floating_texts:
		var alpha := clampf(float(row["life"]) / float(row["total"]), 0.0, 1.0)
		var color: Color = row["color"]
		color.a = alpha
		var font := FLOATING_TEXT_FONT
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


func _add_impact_rings(position_value: Vector2, color: Color, kind: String) -> void:
	if quality_profile == "low" and kind not in ["impact", "ko", "evolution"]:
		return
	var ring_count := 1
	if quality_profile == "high" and kind in ["impact", "ko", "evolution", "charge"]:
		ring_count = 3
	elif quality_profile != "low" and kind in ["impact", "ko", "evolution"]:
		ring_count = 2
	while impact_rings.size() + ring_count > MAX_IMPACT_RINGS:
		impact_rings.pop_front()
	for index in range(ring_count):
		var duration := 0.42 + float(index) * 0.10
		impact_rings.append({
			"position": position_value,
			"color": color.lightened(0.12 * float(index)),
			"life": duration,
			"total": duration,
			"start_radius": 10.0 + float(index) * 8.0,
			"end_radius": 78.0 + float(index) * 26.0,
			"width": 4.0 - minf(1.5, float(index) * 0.5),
			"alpha": 0.72 - float(index) * 0.12,
		})

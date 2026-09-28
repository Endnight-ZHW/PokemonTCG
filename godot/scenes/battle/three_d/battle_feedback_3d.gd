class_name BattleFeedback3D
extends Node3D

signal impact_reached(event_id: String)
signal sampled(cue: BattleFeedbackCue, progress: float)
signal released(cue: BattleFeedbackCue)

const LIMIT := 6
const GLYPH_SHADER: Shader = preload("res://scenes/battle/three_d/battle_glyph.gdshader")
var _bursts: Array[Dictionary] = []
var _pool: Array[MultiMeshInstance3D] = []
var _mesh: QuadMesh
var _material: ShaderMaterial
var _cursor := 0


func _ready() -> void:
	set_process(false)
	_mesh = QuadMesh.new()
	_mesh.orientation = PlaneMesh.FACE_Y
	_mesh.size = Vector2.ONE
	_material = ShaderMaterial.new()
	_material.shader = GLYPH_SHADER


func play(cue: BattleFeedbackCue) -> MotionHandle:
	var handle := MotionHandle.new()
	if not cue.spatial or cue.duration <= 0.0:
		impact_reached.emit(cue.event_id)
		released.emit(cue)
		handle.finish()
		return handle
	var node: MultiMeshInstance3D
	# A full decorative pool must never drop an event or its contact callback.
	# Logical timelines continue even when their optional glyphs cannot allocate.
	if _bursts.size() < LIMIT:
		node = _acquire()
	var count := clampi(int(MotionPolicy.PROFILE.particle_counts.get(cue.quality, 16)), 4, 32)
	if node != null:
		node.multimesh.instance_count = count + 20
	var row := {"node": node, "time": 0.0, "count": count, "handle": handle,
		"cue": cue, "impacted": false}
	_bursts.append(row)
	handle.completed.connect(_on_handle_completed.bind(row), CONNECT_ONE_SHOT)
	_sample(row, 0.0)
	set_process(not _bursts.is_empty())
	return handle


func clear() -> void:
	var removed := _bursts.duplicate()
	_bursts.clear()
	set_process(false)
	for row in removed:
		_recycle(row)
		(row.handle as MotionHandle).cancel()


func _process(delta: float) -> void:
	for row in _bursts.duplicate():
		if row not in _bursts:
			continue
		var cue := row.cue as BattleFeedbackCue
		if cue.motion_driven:
			continue
		row.time = minf(float(row.time) + delta, cue.duration)
		var progress := float(row.time) / maxf(0.001, cue.duration)
		_sample(row, progress)
		if row in _bursts and progress >= 1.0:
			_bursts.erase(row)
			_recycle(row)
			(row.handle as MotionHandle).finish()
	set_process(not _bursts.is_empty())


func advance(event_id: String, progress: float) -> void:
	for row in _bursts.duplicate():
		var cue := row.cue as BattleFeedbackCue
		if cue.event_id != event_id or not cue.motion_driven:
			continue
		var t := clampf(progress, 0.0, 1.0)
		row.time = t * cue.duration
		_sample(row, t)
		if row in _bursts and t >= 1.0:
			_bursts.erase(row)
			_recycle(row)
			(row.handle as MotionHandle).finish()
		break
	set_process(not _bursts.is_empty())


func _sample(row: Dictionary, t: float) -> void:
	var cue := row.cue as BattleFeedbackCue
	if not bool(row.impacted) and t >= cue.impact_fraction:
		row.impacted = true
		impact_reached.emit(cue.event_id)
		if row not in _bursts:
			return
	# The runtime refreshes endpoints and card-relative dimensions every sample.
	sampled.emit(cue, t)
	var node := row.node as MultiMeshInstance3D
	if node == null:
		return
	_cursor = 0
	if cue.kind == "attack" and t < cue.impact_fraction:
		_travel(node, cue, t / maxf(0.01, cue.impact_fraction), int(row.count))
	elif cue.motion_driven and t < cue.impact_fraction:
		_prepare_arrival(node, cue, t / maxf(0.01, cue.impact_fraction), int(row.count))
	else:
		var p := clampf((t - cue.impact_fraction) / maxf(0.01, 1.0 - cue.impact_fraction), 0.0, 1.0)
		_contact(node, cue, p, int(row.count))
	node.multimesh.visible_instance_count = _cursor
	node.force_update_transform()


func _prepare_arrival(node: MultiMeshInstance3D, cue: BattleFeedbackCue, p: float, count: int) -> void:
	var w := cue.width
	var alpha := smoothstep(0.15, 0.50, p) * 0.70
	if cue.kind == "evolution":
		var rings := 1 if cue.quality == "low" else 3
		for i in range(rings):
			var phase := clampf(p + i * 0.11, 0.0, 1.0)
			var center := cue.target + Vector3.UP * w * (0.08 + phase * 0.40 + i * 0.05)
			_put(node, center, Vector2(1.80, 2.40) * w * (1.15 - phase * 0.18 + i * 0.06), 0, 0, cue.color.lightened(0.12 * i), alpha * (1.0 - i * 0.15))
		for i in range(mini(count, 8)):
			var a := float(i) * TAU / mini(count, 8) + p * 1.6
			var point := cue.target + Vector3(cos(a) * 0.60, 0.06 + p * 0.3, sin(a) * 0.72) * w
			_put(node, point, Vector2(w * 0.045, w * 0.16), a, 18, cue.color.lightened(0.3), alpha * 0.6)
	elif cue.kind == "energy":
		# Short streams travel with the actual energy card, then wrap the target.
		_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26), 0, 17, cue.color, alpha * smoothstep(0.35, 0.85, p))
		var n := mini(count, 10)
		for i in range(n):
			var f := float(i) / n
			var angle := p * TAU + f * TAU
			var wrap := cue.target + Vector3(cos(angle) * 0.54, 0.05, sin(angle) * 0.72) * w
			var point := cue.source.lerp(wrap, smoothstep(0.25, 0.94, p) * (0.35 + f * 0.65))
			_put(node, point, Vector2.ONE * w * (0.08 + f * 0.025), -angle, _element_glyph(cue.element), cue.color.lightened(f * 0.25), alpha * (0.5 + f * 0.5))


func _acquire() -> MultiMeshInstance3D:
	var node: MultiMeshInstance3D
	if not _pool.is_empty():
		node = _pool.pop_back()
	else:
		node = MultiMeshInstance3D.new()
		node.name = "AttributeGlyphs"
		node.multimesh = MultiMesh.new()
		node.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		node.multimesh.use_colors = true
		node.multimesh.use_custom_data = true
		node.multimesh.mesh = _mesh
		node.material_override = _material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Whole-table effects have moving endpoints; don't cull on the last frame's bounds.
		node.custom_aabb = AABB(Vector3(-45, -5, -45), Vector3(90, 20, 90))
		add_child(node)
	node.visible = true
	return node


func _put(node: MultiMeshInstance3D, at: Vector3, size_value: Vector2, angle: float, glyph: int, color: Color, alpha: float) -> void:
	var basis := Basis(Vector3.UP, angle).scaled(Vector3(maxf(0.001, size_value.x), 1.0, maxf(0.001, size_value.y)))
	_put_pose(node, Transform3D(basis, at), glyph, color, alpha)


func _put_surface(node: MultiMeshInstance3D, cue: BattleFeedbackCue, offset: Vector3, size_value: Vector2, angle: float, glyph: int, color: Color, alpha: float) -> void:
	# A card-shaped effect is only meaningful with an actual physical surface.
	# Preserve that card's tilt, nonuniform dimensions and paper height.
	if not cue.has_surface_pose: return
	var local := Transform3D(Basis(Vector3.UP, angle) * Basis.from_scale(Vector3(size_value.x, 1, size_value.y)), offset + Vector3.UP * 0.006)
	_put_pose(node, cue.surface_pose * local, glyph, color, alpha)


func _put_pose(node: MultiMeshInstance3D, pose: Transform3D, glyph: int, color: Color, alpha: float) -> void:
	if alpha <= 0.001 or _cursor >= node.multimesh.instance_count:
		return
	node.multimesh.set_instance_transform(_cursor, pose)
	node.multimesh.set_instance_color(_cursor, Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0)))
	node.multimesh.set_instance_custom_data(_cursor, Color(float(glyph), 0, 0, 0))
	_cursor += 1


func _element_glyph(element: String) -> int:
	return int({"Grass": 4, "Fire": 1, "Water": 2, "Lightning": 3, "Psychic": 5,
		"Fighting": 6, "Darkness": 7, "Metal": 8, "Dragon": 9, "Colorless": 10}.get(element, 11))


func _travel(node: MultiMeshInstance3D, cue: BattleFeedbackCue, p: float, count: int) -> void:
	var span := cue.target - cue.source
	var side := Vector3(-span.z, 0, span.x).normalized()
	var n := mini(count, 12)
	for i in range(n):
		var f := clampf(p - float(i) * 0.035, 0.0, 1.0)
		var at := cue.source.lerp(cue.target, f)
		at.y += sin(f * PI) * cue.width * 0.20 + 0.06
		var wobble := sin(f * TAU * 2.0 + i * 1.7)
		if cue.element == "Lightning":
			at += side * wobble * cue.width * 0.10
		elif cue.element == "Dragon":
			at += side * sin(f * TAU * 2.0 + float(i % 2) * PI) * cue.width * 0.13
		elif cue.element in ["Grass", "Psychic", "Darkness"]:
			at += side * wobble * cue.width * 0.06
		var scale_value := cue.width * lerpf(0.26, 0.065, float(i) / n)
		var angle := atan2(-span.z, span.x) + PI * 0.5
		if cue.element in ["Grass", "Psychic", "Dragon"]:
			angle += p * TAU + i
		_put(node, at, Vector2(scale_value, scale_value * 1.8), angle,
			_element_glyph(cue.element), cue.color.lightened(float(i % 3) * 0.10), (1.0 - float(i) / (n + 1)) * 0.85)
	# A fine stream joins the moving head to its wake without obscuring card art.
	if cue.element in ["Water", "Fire", "Metal", "Colorless"] and p > 0.05:
		var tail := cue.source.lerp(cue.target, maxf(0.0, p - 0.32))
		var head := cue.source.lerp(cue.target, p)
		var at := (head + tail) * 0.5 + Vector3.UP * cue.width * 0.15
		_put(node, at, Vector2(head.distance_to(tail), cue.width * 0.09),
			atan2(-(head - tail).z, (head - tail).x), 18, cue.color.lightened(0.25), 0.6)


func _contact(node: MultiMeshInstance3D, cue: BattleFeedbackCue, p: float, count: int) -> void:
	var at := cue.target + Vector3.UP * 0.045
	var w := cue.width
	var alpha := (1.0 - smoothstep(0.55, 1.0, p))
	var ease := 1.0 - pow(1.0 - p, 3.0)
	var ring_size := w * lerpf(0.65, 1.75, ease)
	var glyph := _element_glyph(cue.element)
	match cue.kind:
		"attachment_release":
			for side in [-1.0, 1.0]:
				_put_surface(node, cue, Vector3(side * (0.44 + p * 0.07), 0, 0), Vector2(CardEntity3D.ASPECT * 0.55, 0.03), PI * 0.5, 18, cue.color, alpha * 0.65)
			return
		"land", "card_land", "card_place", "setup_reveal":
			_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26) * (1.0 + p * 0.025), 0, 19, cue.color, alpha * 0.55)
			for side in [-1.0, 1.0]:
				_put_surface(node, cue, Vector3(float(side) * 0.42, 0, CardEntity3D.ASPECT * 0.5), Vector2(0.16, 0.035), 0, 18, cue.color.lightened(0.3), alpha)
			return
		"prize":
			for i in range(4):
				var a := float(i) * PI * 0.5 + PI * 0.25
				_put(node, at + Vector3(cos(a), p * 0.10, sin(a)) * w * (0.35 + p * 0.18), Vector2.ONE * w * 0.18, a, 11, Color("d2a550"), alpha)
			return
		"trainer":
			_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26), 0, 19, Color("c9a15d"), alpha * 0.45)
			_put_surface(node, cue, Vector3(0, 0.004, (p - 0.5) * CardEntity3D.ASPECT), Vector2(1.02, 0.05), 0, 18, Color("efd6a1"), sin(p * PI))
			return
		"tool":
			var center := cue.badge_target + Vector3.UP * 0.03
			_put(node, center, Vector2(w * 0.46, w * 0.32) * (1.20 - p * 0.20), 0, 17, cue.color, alpha)
			_put(node, center, Vector2(w * 0.12, w * 0.045), 0, 18, cue.color.lightened(0.35), sin(p * PI))
			return
		"stadium":
			_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26), 0, 19, cue.color, alpha * 0.45)
			_put_surface(node, cue, Vector3(p - 0.5, 0.004, 0), Vector2(CardEntity3D.ASPECT, 0.055), PI * 0.5, 18, cue.color.lightened(0.25), sin(p * PI))
			return
		"charge", "energy":
			var radius := lerpf(0.76, 0.35, p) * w
			_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26), 0, 17, cue.color, sin(p * PI) * 0.8)
			for i in range(mini(count, 12)):
				var a := float(i) * TAU / mini(count, 12) + p * TAU * 0.65
				var offset := Vector3(cos(a) * radius, sin(p * PI) * w * 0.10, sin(a) * radius * 1.3)
				var point := at + offset
				if cue.kind == "energy": point = point.lerp(cue.badge_target, smoothstep(0.52, 0.94, p))
				_put(node, point, Vector2.ONE * w * 0.12, -a, glyph, cue.color, sin(p * PI))
			if cue.kind == "energy":
				_put(node, cue.badge_target + Vector3.UP * 0.03, Vector2.ONE * w * 0.32, 0, 0, cue.color.lightened(0.30), sin(smoothstep(0.55, 1.0, p) * PI))
			return
		"victory":
			var halo := w * (1.5 + ease * 0.9)
			_put(node, at, Vector2(halo, halo * 1.35), 0, 0, cue.color, alpha * 0.55)
			for i in range(8 if cue.quality == "low" else 12):
				var a := float(i) * TAU / (8 if cue.quality == "low" else 12)
				var point := at + Vector3(cos(a), p * 0.20, sin(a) * 1.3) * w * (0.60 + ease * 0.4)
				_put(node, point, Vector2(w * 0.07, w * 0.34), -a + PI * 0.5, 18, cue.color.lightened(0.25), alpha * sin(p * PI))
			return
		"evolution":
			for i in range(3 if cue.quality != "low" else 1):
				var y := w * (0.04 + (1.0 - p) * 0.20 + i * 0.045)
				_put(node, at + Vector3.UP * y, Vector2(1.75, 2.30) * w * (1.0 + p * 0.18 + i * 0.05), p * 0.12, 0, cue.color.lightened(i * 0.12), alpha * 0.65)
			glyph = 11
		"heal", "cleanse":
			glyph = 12 if cue.kind == "heal" else 11
			_put(node, at, Vector2.ONE * ring_size, 0, 0, cue.color, alpha * 0.7)
		"shield":
			_put(node, at, Vector2(w * 1.45, w * 1.9), p * 0.08, 16, cue.color, alpha)
			_put(node, at + Vector3.UP * 0.02, Vector2(w * 1.1, w * 1.45), -p * 0.08, 16, cue.color.lightened(0.35), alpha * 0.65)
			return
		"ko", "direct_ko":
			_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26) * (1.0 - p * 0.20), 0, 17, cue.color, alpha)
			glyph = 7
		"status", "status_damage":
			glyph = int({"POISONED": 13, "BURNED": 1, "ASLEEP": 14, "PARALYZED": 3, "CONFUSED": 15}.get(cue.status, 5))
		"counters":
			glyph = 6
			_put(node, at, Vector2.ONE * ring_size, 0, 5, cue.color, alpha * 0.65)
		_:
			_attribute_contact(node, cue, at, p, ring_size, alpha)
	for i in range(count):
		var f := float(i) / count
		var angle := f * TAU + float(i % 3) * 0.14
		var radius := w * (0.28 + ease * (0.28 + float(i % 4) * 0.095))
		var height := w * sin(p * PI) * 0.14
		var size_value := Vector2.ONE * w * (0.10 + float(i % 3) * 0.035) * (1.0 - p * 0.45)
		var rotation_value := -angle
		if cue.kind in ["heal", "cleanse", "evolution", "victory"]:
			angle += p * 1.4
			height += w * p * (0.25 + f * 0.3)
		elif cue.kind in ["status", "status_damage"]:
			if cue.status == "ASLEEP":
				radius = w * (0.4 + f * 0.22)
				height += w * p * 0.5
				size_value *= 1.3
			elif cue.status == "CONFUSED":
				angle += p * TAU
			elif cue.status == "POISONED":
				height += w * p * 0.36
		elif cue.element == "Grass":
			angle += p * 2.4
			rotation_value += p * 4.0
			size_value *= 1.6
		elif cue.element == "Fire":
			height += w * p * (0.25 + f * 0.55)
			size_value.y *= 1.8
		elif cue.element == "Lightning":
			radius *= 1.0 + sin(p * TAU * 2.0 + i) * 0.12
			size_value *= Vector2(1.2, 2.4)
		elif cue.element == "Darkness":
			angle -= p * 2.8
			radius *= 1.25 - p * 0.5
			size_value *= 1.4
		elif cue.element == "Metal":
			rotation_value = PI * 0.25
			size_value.y *= 2.6
		elif cue.element == "Dragon":
			angle = p * TAU * 1.3 + f * PI + float(i % 2) * PI
			height += w * f * 0.3
			size_value.y *= 1.7
		elif cue.element == "Colorless":
			size_value.y *= 1.8
		var offset := Vector3(cos(angle) * radius, height, sin(angle) * radius)
		var particle_point := at + offset
		if cue.kind in ["status", "status_damage"]:
			particle_point = particle_point.lerp(cue.badge_target, smoothstep(0.52, 0.96, p))
			alpha = 1.0 - smoothstep(0.80, 1.0, p)
		_put(node, particle_point, size_value, rotation_value, glyph,
			cue.color.lightened(float(i % 3) * 0.12), alpha * (0.95 - f * 0.30))


func _attribute_contact(node: MultiMeshInstance3D, cue: BattleFeedbackCue, at: Vector3, p: float, ring_size: float, alpha: float) -> void:
	var w := cue.width
	match cue.element:
		"Fire":
			for i in range(5):
				var a := float(i) * TAU / 5.0 + p * 0.4
				var offset := Vector3(cos(a), p * 0.4, sin(a)) * w * 0.48
				_put(node, at + offset, Vector2(w * 0.35, w * 0.8) * (1.0 - p * 0.3), -a + PI * 0.5, 1, cue.color, alpha * 0.85)
		"Water", "Psychic", "Colorless":
			var glyph := 5 if cue.element == "Psychic" else 10 if cue.element == "Colorless" else 0
			_put(node, at, Vector2.ONE * ring_size, p * 0.2, glyph, cue.color, alpha * 0.7)
			if cue.quality != "low":
				_put(node, at + Vector3.UP * 0.03, Vector2.ONE * ring_size * 0.7, 0, glyph, cue.color.lightened(0.25), alpha * 0.6)
		"Lightning":
			for i in range(4):
				var a := float(i) * PI * 0.5 + PI * 0.25
				_put(node, at + Vector3(cos(a), 0.06, sin(a)) * w * 0.50,
					Vector2(w * 0.25, w * 0.90), -a + PI * 0.5, 3, cue.color, alpha)
		"Fighting":
			for i in range(5):
				var a := float(i) * TAU / 5.0
				_put(node, at + Vector3(cos(a), 0.01, sin(a)) * w * (0.4 + p * 0.2),
					Vector2(w * 0.28, w * 0.65), -a + PI * 0.5, 6, cue.color, alpha * 0.85)
		"Darkness":
			for i in range(2):
				var a := float(i) * PI + p * 2.0
				_put(node, at + Vector3(cos(a), 0.04, sin(a)) * w * 0.28,
					Vector2(w * 0.90, w * 1.35), -a, 7, cue.color, alpha * 0.85)
		"Metal":
			for i in range(3):
				_put(node, at + Vector3((i - 1) * w * 0.26, 0.04, 0),
					Vector2(w * 0.32, w * 1.65), 0.50 if i % 2 == 0 else -0.50, 8, cue.color.darkened(0.10), alpha * 0.9)
		"Dragon":
			for i in range(2):
				var side := 1.0 if i == 0 else -1.0
				_put(node, at + Vector3(side * w * 0.30, w * p * 0.1, 0),
					Vector2(w * 0.55, w * 1.85), side * p * 0.6, 9,
					cue.color if i == 0 else cue.color.lerp(Color("7467bb"), 0.6), alpha * 0.9)
		"Grass":
			pass # The orbiting leaves are the silhouette, without an unrelated ring.
		_:
			_put(node, at, Vector2.ONE * ring_size, 0, 0, cue.color, alpha * 0.6)


func _recycle(row: Dictionary) -> void:
	var node := row.node as MultiMeshInstance3D
	if node != null:
		node.visible = false
		node.multimesh.visible_instance_count = 0
		if _pool.size() < LIMIT:
			_pool.append(node)
		else:
			node.queue_free()
		row.node = null
	released.emit(row.cue as BattleFeedbackCue)


func _on_handle_completed(_handle: MotionHandle, row: Dictionary) -> void:
	if row in _bursts:
		_bursts.erase(row)
		_recycle(row)
	set_process(not _bursts.is_empty())


func _exit_tree() -> void:
	clear()

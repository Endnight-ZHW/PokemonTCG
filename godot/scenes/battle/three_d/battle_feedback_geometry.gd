class_name BattleFeedbackGeometry
extends RefCounted

## Stateless-in-time recipes. The renderer owns clocks, handles and pooled meshes.
## Every value is sampled from normalized progress, including frozen previews.
var _cursor := 0
var _phase := 0.0
var _brightness := 1.0
var _tail_alpha := 1.0


func sample(node: MultiMeshInstance3D, cue: BattleFeedbackCue, t: float, count: int) -> int:
	_cursor = 0
	_phase = t
	_brightness = cue.profile.core_brightness
	_tail_alpha = 1.0 - smoothstep(cue.profile.tail_fade_start, 1.0, t)
	if cue.kind == "evolution":
		_evolution(node, cue, t, count)
	elif cue.kind == "energy":
		_energy(node, cue, t, count)
	elif cue.kind == "attack" and t < cue.impact_fraction:
		_travel(node, cue, t / maxf(0.01, cue.impact_fraction), count)
	else:
		_contact(node, cue, cue.contact_progress(t), count)
	return _cursor


func _evolution(node: MultiMeshInstance3D, cue: BattleFeedbackCue, t: float, count: int) -> void:
	var w := cue.width
	var contact := cue.impact_fraction
	var release := cue.contact_progress(t)
	var charging := clampf(t / maxf(0.001, contact), 0.0, 1.0) if contact > 0.0 else 1.0
	var envelope := smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.40, 1.0, release))
	if contact <= 0.0: envelope = 1.0 - smoothstep(0.40, 1.0, release)
	var radius := lerpf(0.86, 0.55, charging) + release * 0.40
	var steps := mini(count, 14)
	# Two continuous strands form a rising, compressing shell; they keep the
	# same topology at contact, then open and shed light instead of swapping rings.
	for strand in range(2):
		var last := Vector3.ZERO
		for i in range(steps):
			var f := float(i) / maxi(1, steps - 1)
			var angle := t * TAU * 1.25 + f * TAU * 0.85 + strand * PI
			var at := cue.target + Vector3(cos(angle) * radius, 0.06 + f * (0.80 + release * 0.45), sin(angle) * radius * 1.28) * w
			if i > 0: _beam(node, last, at, w * (0.075 + charging * 0.040), cue.color.lightened(strand * 0.50), envelope * 0.90)
			last = at
	_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26), 0, 17, cue.color.lightened(0.25), envelope)
	var pulse := (1.0 - smoothstep(0.0, 0.60, release)) * charging
	for i in range(1 if cue.quality == "low" else 3):
		var at := cue.target + Vector3((i - 1) * w * 0.35, w * 0.72, w * -0.20)
		var basis := Basis(Vector3.RIGHT, PI * 0.5) * Basis.from_scale(Vector3(w * 0.58, 1.0, w * 1.65))
		_put_pose(node, Transform3D(basis, at), 24, cue.color.lightened(0.5), pulse * envelope * 0.30)
	if t >= contact:
		_impact_core(node, cue, cue.target + Vector3.UP * w * 0.08, release)
		for i in range(mini(count, 10)):
			var f := float(i) / mini(count, 10)
			var a := f * TAU + release * 1.6
			var point := cue.target + Vector3(cos(a) * (0.52 + release * 0.25), (0.10 + f * 0.45) * (1.0 - release), sin(a) * (0.80 + release * 0.20)) * w
			_put(node, point, Vector2.ONE * w * 0.13 * (1.0 - release * 0.6), a, 11, cue.color.lightened(0.4), envelope)


func _energy(node: MultiMeshInstance3D, cue: BattleFeedbackCue, t: float, count: int) -> void:
	var w := cue.width
	var contact := cue.impact_fraction
	var arrived := t >= contact
	var p := cue.contact_progress(t)
	var envelope := smoothstep(0.0, 0.14, t) * (1.0 - smoothstep(0.35, 1.0, p))
	if contact <= 0.0: envelope = 1.0 - smoothstep(0.35, 1.0, p)
	var gather := smoothstep(0.0, 0.78, p)
	var center := cue.target.lerp(cue.badge_target, gather) if arrived else cue.source
	center += Vector3.UP * w * 0.08
	var radius := w * (lerpf(0.60, 0.075, gather) if arrived else 0.22)
	_put(node, center, Vector2.ONE * radius * 2.0, 0, 22, cue.color.lightened(0.3), envelope * 0.62)
	var n := mini(count, 8)
	for i in range(n):
		var angle := float(i) * TAU / n + t * TAU * 1.4
		var point := center + Vector3(cos(angle), 0.08 * sin(angle * 2.0), sin(angle)) * radius
		_put(node, point, Vector2.ONE * w * 0.10 * (1.0 - p * 0.6), -angle, _element_glyph(cue.element), cue.color, envelope)
		if not arrived:
			var tail := point.lerp(cue.target, 0.30)
			_beam(node, point, tail, w * 0.028, cue.color.lightened(0.25), envelope * 0.65)
	if arrived:
		_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26), 0, 17, cue.color, envelope * (1.0 - gather))
		_put(node, cue.badge_target + Vector3.UP * w * 0.04, Vector2.ONE * w * lerpf(0.28, 0.50, p), 0, 23, cue.color.lightened(0.3), sin(p * PI) * envelope)


func _put(node: MultiMeshInstance3D, at: Vector3, size_value: Vector2, angle: float, glyph: int, color: Color, alpha: float) -> void:
	var basis := Basis(Vector3.UP, angle) * Basis.from_scale(Vector3(maxf(0.001, size_value.x), 1.0, maxf(0.001, size_value.y)))
	_put_pose(node, Transform3D(basis, at), glyph, color, alpha)


func _put_surface(node: MultiMeshInstance3D, cue: BattleFeedbackCue, offset: Vector3, size_value: Vector2, angle: float, glyph: int, color: Color, alpha: float) -> void:
	# A card-shaped effect is only meaningful with an actual physical surface.
	# Preserve that card's tilt, nonuniform dimensions and paper height.
	if not cue.has_surface_pose: return
	var local := Transform3D(Basis(Vector3.UP, angle) * Basis.from_scale(Vector3(size_value.x, 1, size_value.y)), offset + Vector3.UP * 0.006)
	_put_pose(node, cue.surface_pose * local, glyph, color, alpha)


func _put_pose(node: MultiMeshInstance3D, pose: Transform3D, glyph: int, color: Color, alpha: float) -> void:
	alpha *= _tail_alpha
	if alpha <= 0.001 or _cursor >= node.multimesh.instance_count:
		return
	node.multimesh.set_instance_transform(_cursor, pose)
	node.multimesh.set_instance_color(_cursor, Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0)))
	node.multimesh.set_instance_custom_data(_cursor, Color(float(glyph), _phase, _brightness, 0))
	_cursor += 1


func _element_glyph(element: String) -> int:
	return int({"Grass": 4, "Fire": 1, "Water": 2, "Lightning": 3, "Psychic": 5,
		"Fighting": 6, "Darkness": 7, "Metal": 8, "Dragon": 9, "Colorless": 10}.get(element, 11))


func _beam(node: MultiMeshInstance3D, a: Vector3, b: Vector3, width: float, color: Color, alpha: float, glyph: int = 18) -> void:
	var span := b - a
	if span.length_squared() < 0.000001: return
	var direction := span.normalized()
	var side := Vector3.UP.cross(direction).normalized()
	if side.length_squared() < 0.01: side = Vector3.RIGHT
	var normal := side.cross(direction).normalized()
	var basis := Basis(direction, normal, side) * Basis.from_scale(Vector3(span.length(), 1.0, width))
	_put_pose(node, Transform3D(basis, (a + b) * 0.5), glyph, color, alpha)


func _travel(node: MultiMeshInstance3D, cue: BattleFeedbackCue, p: float, count: int) -> void:
	var span := cue.target - cue.source
	var side := Vector3(-span.z, 0, span.x).normalized()
	var w := cue.width
	var u := pow(p, 1.45)
	var head := cue.source.lerp(cue.target, u) + Vector3.UP * (sin(p * PI) * w * 0.24 + 0.055)
	var angle := atan2(-span.z, span.x) + PI * 0.5
	var n := mini(count, 18)
	var head_color := cue.color.lightened(0.18)
	if cue.element == "Lightning":
		var last := cue.source + Vector3.UP * 0.06
		for i in range(1, 7):
			var f := float(i) / 6.0
			var point := cue.source.lerp(head, f) + side * sin(i * 5.7 + floor(p * 9.0)) * w * 0.16 * sin(f * PI)
			_beam(node, last, point, w * 0.075, cue.color, 0.95)
			_beam(node, last + Vector3.UP * 0.004, point + Vector3.UP * 0.004, w * 0.026, Color("fff7d0"), 0.95)
			if i % 2 == 0 and cue.quality != "low":
				_beam(node, point, point + side * w * 0.25 + span.normalized() * w * 0.14, w * 0.04, cue.color, 0.65)
			last = point
	elif cue.element in ["Fire", "Water", "Metal", "Colorless"]:
		var tail := cue.source.lerp(cue.target, maxf(0.0, u - 0.42)) + Vector3.UP * w * 0.12
		_beam(node, tail, head, w * 0.27, cue.color, 0.85, 21)
		_beam(node, tail.lerp(head, 0.25) + Vector3.UP * 0.01, head + Vector3.UP * 0.01, w * 0.085, head_color.lightened(0.55), 0.9)
	for i in range(n):
		var f := float(i) / n
		var v := maxf(0.0, u - f * 0.46)
		var at := cue.source.lerp(cue.target, v) + Vector3.UP * (sin(v * PI) * w * 0.22 + 0.06)
		var orbit := p * TAU * 1.6 + i * 2.4
		var size_value := w * lerpf(0.34, 0.07, f)
		var rotation_value := angle
		var tint := cue.color.lightened(float(i % 3) * 0.13)
		match cue.element:
			"Grass":
				at += side * sin(orbit) * w * 0.24
				rotation_value += orbit
			"Psychic":
				at += side * sin(orbit) * w * 0.12
				size_value *= 1.6
			"Darkness":
				at += side * sin(orbit) * w * 0.18
				rotation_value -= orbit
			"Dragon":
				at += side * sin(p * TAU * 2.0 - f * TAU + float(i % 2) * PI) * w * 0.24
				if i % 2 == 0: tint = Color("8271d4")
			"Fighting":
				at.y = cue.target.y + 0.025
				at += side * sin(i * 4.2) * w * f * 0.3
				rotation_value += i
			"Water": at += side * sin(orbit) * w * f * 0.11
			"Fire": at.y += w * f * 0.18
		_put(node, at, Vector2(size_value, size_value * 1.65), rotation_value, _element_glyph(cue.element), tint, (1.0 - f) * 0.88)
	# A readable projectile silhouette leads the wake, even at low quality.
	_put(node, head, Vector2(w * 0.43, w * 0.65) * cue.intensity, angle, _element_glyph(cue.element), head_color, 0.95)
	if cue.element in ["Fire", "Lightning", "Dragon"]:
		_put(node, head + Vector3.UP * 0.012, Vector2.ONE * w * 0.28, angle, 22, Color("fff0c9"), 0.8)


func _impact_core(node: MultiMeshInstance3D, cue: BattleFeedbackCue, at: Vector3, p: float) -> void:
	var burst := 1.0 - smoothstep(0.02, cue.profile.impact_core_decay, p)
	var w := cue.width * cue.intensity
	var size_value := w * (0.85 + p * 1.5)
	_put(node, at + Vector3.UP * 0.022, Vector2.ONE * size_value, p * 0.25, 20, cue.color.lightened(0.35), burst * 0.95)
	_put(node, at + Vector3.UP * 0.028, Vector2.ONE * w * 0.42, 0, 22, Color("fff8e0"), burst * 0.95)
	if cue.quality != "low":
		for i in range(6):
			var a := float(i) * TAU / 6.0 + 0.2
			var direction := Vector3(cos(a), 0, sin(a))
			_beam(node, at + direction * w * (0.25 + p * 0.45), at + direction * w * (0.7 + p * 0.8), w * 0.05 * (1.0 - p), cue.color.lightened(0.3), burst * 0.7)


func _rising_light(node: MultiMeshInstance3D, cue: BattleFeedbackCue, p: float, alpha: float) -> void:
	var n := 4 if cue.quality == "low" else 8
	for i in range(n):
		var a := float(i) * TAU / n + p * 0.35
		var height := cue.width * (0.5 + sin(p * PI) * 0.65 + float(i % 3) * 0.12)
		var at := cue.target + Vector3(cos(a) * 0.67, 0.0, sin(a) * 0.88) * cue.width
		at.y = cue.target.y + height * 0.5
		var basis := Basis(Vector3.RIGHT, PI * 0.5) * Basis.from_scale(Vector3(cue.width * 0.15, 1.0, height))
		_put_pose(node, Transform3D(basis, at), 8, cue.color.lightened(0.35), alpha * 0.7)


func _contact(node: MultiMeshInstance3D, cue: BattleFeedbackCue, p: float, count: int) -> void:
	var at := cue.target + Vector3.UP * 0.045
	var w := cue.width * (cue.intensity if cue.kind == "attack" else 1.0)
	var alpha := (1.0 - smoothstep(0.55, 1.0, p))
	var ease := 1.0 - pow(1.0 - p, 3.0)
	var ring_size := w * lerpf(0.65, 1.75, ease)
	var glyph := _element_glyph(cue.element)
	if cue.kind == "attack":
		_impact_core(node, cue, at, p)
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
		"charge":
			var radius := lerpf(0.96, 0.24, pow(p, 0.65)) * w
			_put_surface(node, cue, Vector3.ZERO, Vector2(1.48, CardEntity3D.ASPECT * 1.26), 0, 17, cue.color, sin(p * PI) * 0.8)
			for i in range(mini(count, 12)):
				var a := float(i) * TAU / mini(count, 12) + p * TAU * 0.65
				var offset := Vector3(cos(a) * radius, sin(p * PI) * w * 0.10, sin(a) * radius * 1.3)
				var point := at + offset
				_put(node, point, Vector2.ONE * w * (0.17 - p * 0.055), -a, glyph, cue.color, sin(p * PI))
			return
		"victory":
			_rising_light(node, cue, p, alpha)
			var halo := w * (1.5 + ease * 0.9)
			_put(node, at, Vector2(halo, halo * 1.35), 0, 0, cue.color, alpha * 0.55)
			for i in range(8 if cue.quality == "low" else 12):
				var a := float(i) * TAU / (8 if cue.quality == "low" else 12)
				var point := at + Vector3(cos(a), p * 0.20, sin(a) * 1.3) * w * (0.60 + ease * 0.4)
				_put(node, point, Vector2(w * 0.07, w * 0.34), -a + PI * 0.5, 18, cue.color.lightened(0.25), alpha * sin(p * PI))
			return
		"heal", "cleanse":
			glyph = 12 if cue.kind == "heal" else 11
			_put(node, at, Vector2.ONE * ring_size, 0, 0, cue.color, alpha * 0.7)
		"shield":
			_put(node, at, Vector2(w * 1.45, w * 1.9), p * 0.08, 16, cue.color, alpha)
			_put(node, at + Vector3.UP * 0.02, Vector2(w * 1.1, w * 1.45), -p * 0.08, 16, cue.color.lightened(0.35), alpha * 0.65)
			return
		"ko", "direct_ko":
			_put(node, at, Vector2(w * 1.45, w * 1.8) * (1.0 - p * 0.6), p * -0.8, 7, cue.color.darkened(0.2), alpha * 0.7)
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
		var radius := w * (0.16 + float(i % 5) * 0.055 + ease * (0.38 + float(i % 4) * 0.12))
		var height := w * sin(p * PI) * 0.14
		var size_value := Vector2.ONE * w * (0.11 + float(i % 3) * 0.04) * (1.0 - p * 0.45)
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
		elif cue.element == "Water":
			radius *= 1.18
			height += w * sin(p * PI) * (0.2 + f * 0.25)
			rotation_value += p * 1.3
		elif cue.element == "Fighting":
			height = maxf(0.0, sin(p * PI) * (0.22 + f * 0.12) - p * 0.08) * w
			rotation_value += p * (2.0 + f * 4.0)
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
				_put(node, at + offset, Vector2(w * 0.44, w * 0.95) * (1.0 - p * 0.55), -a + PI * 0.5, 1, cue.color, alpha * 0.85)
		"Water", "Psychic", "Colorless":
			var glyph := 5 if cue.element == "Psychic" else 10 if cue.element == "Colorless" else 0
			_put(node, at, Vector2.ONE * ring_size, p * 0.2, glyph, cue.color, alpha * 0.7)
			if cue.quality != "low":
				_put(node, at + Vector3.UP * 0.03, Vector2.ONE * ring_size * 0.7, 0, glyph, cue.color.lightened(0.25), alpha * 0.75)
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
			for i in range(3):
				_put(node, at + Vector3.UP * (0.025 + i * 0.018), Vector2(w * 0.7, w * 1.5) * (1.0 + p * 0.25), float(i) * PI / 3.0 + p * 2.4, 7, cue.color.lightened(0.16), alpha * 0.65)
		_:
			_put(node, at, Vector2.ONE * ring_size, 0, 0, cue.color, alpha * 0.75)



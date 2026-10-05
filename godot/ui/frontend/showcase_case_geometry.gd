class_name ShowcaseCaseGeometry
extends RefCounted

## Dimensions shared by the hollow body, flexible rear joint and folded lid.
const WIDTH := 1.50
const DEPTH := 1.12
const HEIGHT := 2.06
const WALL := 0.028
const CORNER := 0.035
const LID_WIDTH := WIDTH + 0.02
const LID_THICKNESS := 0.026
const HINGE_Y := 2.045
const HINGE_RADIUS := 0.041
const HINGE_LENGTH := HINGE_RADIUS * PI * 0.5
const FRONT := DEPTH * 0.5 + 0.037
const FLAP_BOTTOM := 0.78
const FOLD_RADIUS := 0.036
const FLAP_CORNER := 0.075
const CLOSED_ORIGIN := Vector3(0, HINGE_Y + HINGE_RADIUS, -DEPTH * 0.5 + HINGE_RADIUS)
const LID_RUN := FRONT - CLOSED_ORIGIN.z
const FLAP_DROP := CLOSED_ORIGIN.y - FLAP_BOTTOM


static func _surface() -> SurfaceTool:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	return surface


static func _quad(surface: SurfaceTool, points: Array, normals: Array) -> void:
	var reversed: bool = (points[1] - points[0]).cross(points[2] - points[0]).dot(normals[0] + normals[2]) > 0
	for i in ([0, 2, 1, 0, 3, 2] if reversed else [0, 1, 2, 0, 2, 3]):
		surface.set_normal(normals[i])
		surface.set_uv(Vector2(points[i].x + points[i].z, points[i].y))
		surface.add_vertex(points[i])


static func _flat_quad(surface: SurfaceTool, points: Array, normal: Vector3) -> void:
	_quad(surface, points, [normal, normal, normal, normal])


static func _finish(surfaces: Array[SurfaceTool]) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for surface in surfaces:
		surface.index()
		surface.commit(mesh)
	return mesh


static func _rim() -> Array[Vector3]:
	var points: Array[Vector3] = []
	var centers := [Vector2(WIDTH * 0.5 - CORNER, DEPTH * 0.5 - CORNER),
		Vector2(-WIDTH * 0.5 + CORNER, DEPTH * 0.5 - CORNER),
		Vector2(-WIDTH * 0.5 + CORNER, -DEPTH * 0.5 + CORNER),
		Vector2(WIDTH * 0.5 - CORNER, -DEPTH * 0.5 + CORNER)]
	for corner in range(4):
		var center: Vector2 = centers[corner]
		for step in range(9):
			var angle := float(corner) * PI * 0.5 + float(step) * PI / 16.0
			points.append(Vector3(center.x + cos(angle) * CORNER, 0, center.y + sin(angle) * CORNER))
		if corner == 0:
			# Dense front samples preserve the semicircular thumb cut-out.
			for step in range(1, 65):
				points.append(Vector3(lerpf(WIDTH * 0.5 - CORNER, -WIDTH * 0.5 + CORNER, float(step) / 65.0), 0, DEPTH * 0.5))
	return points


static func _rim_normal(point: Vector3) -> Vector3:
	var core := Vector3(clampf(point.x, -WIDTH * 0.5 + CORNER, WIDTH * 0.5 - CORNER), 0,
		clampf(point.z, -DEPTH * 0.5 + CORNER, DEPTH * 0.5 - CORNER))
	return (point - core).normalized()


static func _height(point: Vector3) -> float:
	if point.z > DEPTH * 0.5 - 0.001 and absf(point.x) < 0.25:
		return HEIGHT - 0.31 * sqrt(maxf(0, 1.0 - pow(point.x / 0.25, 2)))
	return HEIGHT


## An actual open cup: outer leather, dark inner walls/floor, and thin rim.
static func cup() -> ArrayMesh:
	var outer := _surface()
	var inner := _surface()
	var edge := _surface()
	var rim := _rim()
	for i in range(rim.size()):
		var a := rim[i]
		var b := rim[(i + 1) % rim.size()]
		var na := _rim_normal(a)
		var nb := _rim_normal(b)
		var ia := a - na * WALL
		var ib := b - nb * WALL
		var at := a + Vector3.UP * _height(a)
		var bt := b + Vector3.UP * _height(b)
		var iat := ia + Vector3.UP * _height(a)
		var ibt := ib + Vector3.UP * _height(b)
		_quad(outer, [a, b, bt, at], [na, nb, nb, na])
		_quad(inner, [ia + Vector3.UP * WALL, ib + Vector3.UP * WALL, ibt, iat], [-na, -nb, -nb, -na])
		var lip_normal := (bt - at).cross(iat - at).normalized()
		if lip_normal.y < 0:
			lip_normal = -lip_normal
		_flat_quad(edge, [at, bt, ibt, iat], lip_normal)
		_flat_quad(inner, [Vector3(0, WALL, 0), ia + Vector3.UP * WALL, ib + Vector3.UP * WALL, Vector3(0, WALL, 0)], Vector3.UP)
		_flat_quad(outer, [Vector3.ZERO, a, b, Vector3.ZERO], Vector3.DOWN)
	return _finish([outer, inner, edge])


static func lid_profile(x: float, inset: float = 0.0) -> PackedVector3Array:
	var half := LID_WIDTH * 0.5 - inset
	var radius := FLAP_CORNER - inset * 0.4
	var dx := maxf(0, absf(x) - half + radius)
	var bottom_round := radius - sqrt(maxf(0, radius * radius - dx * dx))
	var points := PackedVector3Array([Vector3(x, 0, 0), Vector3(x, 0, LID_RUN - FOLD_RADIUS)])
	for step in range(1, 13):
		var angle := float(step) * PI / 24.0
		points.append(Vector3(x, -FOLD_RADIUS + cos(angle) * FOLD_RADIUS, LID_RUN - FOLD_RADIUS + sin(angle) * FOLD_RADIUS))
	points.append(Vector3(x, -FLAP_DROP + inset + bottom_round, LID_RUN))
	return points


static func lid_normal(index: int) -> Vector3:
	var angle := clampf(float(index - 1) / 12.0, 0.0, 1.0) * PI * 0.5
	return Vector3(0, cos(angle), sin(angle))


static func lid() -> ArrayMesh:
	var profiles: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	for step in range(41):
		var x := LID_WIDTH * 0.5 * sin(lerpf(-PI * 0.5, PI * 0.5, float(step) / 40.0))
		var profile := lid_profile(x)
		var ns := PackedVector3Array()
		for i in range(profile.size()):
			ns.append(lid_normal(i))
		profiles.append(profile)
		normals.append(ns)
	return _sheet(profiles, normals, false, true)


static func hinge_end(open_degrees: float) -> Vector3:
	var bend := PI * 0.5 - deg_to_rad(clampf(open_degrees, 0, 90))
	var endpoint := Vector3(0, HINGE_Y + HINGE_LENGTH, -DEPTH * 0.5)
	if bend > 0.00001:
		var radius := HINGE_LENGTH / bend
		endpoint = Vector3(0, HINGE_Y + radius * sin(bend), -DEPTH * 0.5 + radius * (1.0 - cos(bend)))
	return endpoint


## Constant arc length; at 90 degrees the joint unfolds into the back wall.
static func hinge(open_degrees: float) -> ArrayMesh:
	var bend := PI * 0.5 - deg_to_rad(clampf(open_degrees, 0, 90))
	var profiles: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	for side in [-1.0, 1.0]:
		var path := PackedVector3Array()
		var ns := PackedVector3Array()
		for step in range(17):
			var t := float(step) / 16.0
			var angle := bend * t
			var y := HINGE_Y + HINGE_LENGTH * t
			var z := -DEPTH * 0.5
			if bend > 0.00001:
				y = HINGE_Y + HINGE_LENGTH / bend * sin(angle)
				z += HINGE_LENGTH / bend * (1.0 - cos(angle))
			path.append(Vector3(side * lerpf(WIDTH - 0.07, LID_WIDTH, smoothstep(0, 1, t)) * 0.5, y, z))
			ns.append(Vector3(0, sin(angle), -cos(angle)))
		profiles.append(path)
		normals.append(ns)
	return _sheet(profiles, normals, false, false)


static func _sheet(profiles: Array[PackedVector3Array], normals: Array[PackedVector3Array], cap_start: bool, cap_end: bool) -> ArrayMesh:
	var outer := _surface()
	var inner := _surface()
	var edge := _surface()
	for column in range(profiles.size() - 1):
		var a := profiles[column]
		var b := profiles[column + 1]
		var an := normals[column]
		var bn := normals[column + 1]
		for row in range(a.size() - 1):
			_quad(outer, [a[row], b[row], b[row + 1], a[row + 1]], [an[row], bn[row], bn[row + 1], an[row + 1]])
			_quad(inner, [a[row] - an[row] * LID_THICKNESS, b[row] - bn[row] * LID_THICKNESS,
				b[row + 1] - bn[row + 1] * LID_THICKNESS, a[row + 1] - an[row + 1] * LID_THICKNESS], [-an[row], -bn[row], -bn[row + 1], -an[row + 1]])
			if column == 0:
				_flat_quad(edge, [a[row], a[row + 1], a[row + 1] - an[row + 1] * LID_THICKNESS, a[row] - an[row] * LID_THICKNESS], Vector3.LEFT)
			if column == profiles.size() - 2:
				_flat_quad(edge, [b[row], b[row + 1], b[row + 1] - bn[row + 1] * LID_THICKNESS, b[row] - bn[row] * LID_THICKNESS], Vector3.RIGHT)
		for end in [0, a.size() - 1]:
			if (end == 0 and not cap_start) or (end != 0 and not cap_end):
				continue
			var n := (b[end] - a[end]).cross(an[end]).normalized() * (-1 if end == 0 else 1)
			_flat_quad(edge, [a[end], b[end], b[end] - bn[end] * LID_THICKNESS, a[end] - an[end] * LID_THICKNESS], n)
	return _finish([outer, inner, edge])

class_name BattleCardClearance3D
extends RefCounted

## The rendered, flipped paper volume is the source of truth for clearance.
## Resolve along the table normal, never by disabling depth or hiding cards.
const GAP := 0.003


static func lowest_y(pose: Transform3D, half_height: float = CardEntity3D.THICKNESS * 0.5) -> float:
	return pose.origin.y - absf(pose.basis.x.y) * 0.5 - absf(pose.basis.y.y) * half_height - absf(pose.basis.z.y) * CardEntity3D.ASPECT * 0.5


static func separation(a: Transform3D, height_a: float, b: Transform3D, height_b: float) -> float:
	var half_a := Vector3(0.5, height_a, CardEntity3D.ASPECT * 0.5)
	var half_b := Vector3(0.5, height_b, CardEntity3D.ASPECT * 0.5)
	# Cheap broad phase before testing the oriented boxes.
	for axis in [Vector3.RIGHT, Vector3.FORWARD, Vector3.UP]:
		var radius := _radius(a, half_a, axis) + _radius(b, half_b, axis)
		if absf(axis.dot(a.origin - b.origin)) > radius + GAP: return 0.0
	var axes: Array[Vector3] = [a.basis.x, a.basis.y, a.basis.z, b.basis.x, b.basis.y, b.basis.z]
	for i in range(3):
		for j in range(3): axes.append(a.basis[i].cross(b.basis[j]))
	var lift := INF
	for value in axes:
		if value.length_squared() < 0.000001: continue
		var axis := value.normalized()
		var radius := _radius(a, half_a, axis) + _radius(b, half_b, axis)
		var distance := axis.dot(a.origin - b.origin)
		if absf(distance) >= radius - 0.0001: return 0.0
		if absf(axis.y) > 0.0001:
			lift = minf(lift, (radius + GAP - signf(axis.y) * distance) / absf(axis.y))
	return 0.0 if is_inf(lift) else maxf(0.0, lift)


static func _radius(pose: Transform3D, half: Vector3, axis: Vector3) -> float:
	return absf(axis.dot(pose.basis.x)) * half.x + absf(axis.dot(pose.basis.y)) * half.y + absf(axis.dot(pose.basis.z)) * half.z

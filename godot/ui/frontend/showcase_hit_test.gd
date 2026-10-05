class_name ShowcaseHitTest
extends RefCounted

## Ray tests follow world transforms, including the hinged lid. No screen-fixed hitboxes.
static func pick(stage: Control, point: Vector2) -> String:
	var view: Variant = stage
	var camera: Camera3D = view.camera
	var pixel := point * Vector2(view.viewport.size) / stage.size
	var origin := camera.project_ray_origin(pixel)
	var end := origin + camera.project_ray_normal(pixel) * camera.far
	var targets: Array = [
		["case", view._stage],
		["case", view._lid_root.get_node("ContinuousLeatherFlap")],
	]
	for card: CardEntity3D in view.cards:
		if card.visible:
			targets.append(["card", card.body])
	var closest := INF
	var result := ""
	for target: Array in targets:
		var mesh := target[1] as MeshInstance3D
		var pose := mesh.global_transform
		var a := pose.affine_inverse() * origin
		var b := pose.affine_inverse() * end
		if mesh.mesh.get_aabb().grow(0.012).intersects_segment(a, b) == null:
			continue
		if not mesh.mesh.has_meta(&"showcase_hit_faces"):
			mesh.mesh.set_meta(&"showcase_hit_faces", mesh.mesh.get_faces())
		var faces: PackedVector3Array = mesh.mesh.get_meta(&"showcase_hit_faces")
		for index in range(0, faces.size(), 3):
			var hit: Variant = Geometry3D.segment_intersects_triangle(a, b, faces[index], faces[index + 1], faces[index + 2])
			if hit == null:
				continue
			var distance := origin.distance_squared_to(pose * hit)
			if distance < closest:
				closest = distance
				result = str(target[0])
	var coin: Node3D = view._coin
	var inverse := coin.global_transform.affine_inverse()
	var coin_hit: Variant = AABB(Vector3(-0.33, -0.04, -0.33), Vector3(0.66, 0.08, 0.66)).intersects_segment(inverse * origin, inverse * end)
	if coin_hit != null and origin.distance_squared_to(coin.global_transform * coin_hit) < closest:
		return "coin"
	# The small coin also gets a minimum 48px target, in physical canvas pixels.
	if result.is_empty():
		var center := camera.unproject_position(coin.global_position) * stage.size / Vector2(view.viewport.size)
		var canvas := stage.get_viewport().get_final_transform() * stage.get_global_transform_with_canvas()
		var scale := Vector2(canvas.x.length(), canvas.y.length())
		var radius := Vector2(24, 24) / scale
		if Rect2(center - radius, radius * 2).has_point(point):
			return "coin"
	return result

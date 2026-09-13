class_name BattleProjection3D
extends RefCounted

## All public screen coordinates are BattleTable-local, independent of render scale.
var camera: Camera3D
var viewport: SubViewport
var screen_size := Vector2(1600, 900)


func configure(p_camera: Camera3D, p_viewport: SubViewport, size_value: Vector2) -> void:
	camera = p_camera
	viewport = p_viewport
	screen_size = size_value.max(Vector2.ONE)


func screen_to_world(point: Vector2, height: float = 0.0) -> Vector3:
	var pixel := point * Vector2(viewport.size) / screen_size
	var origin := camera.project_ray_origin(pixel)
	var direction := camera.project_ray_normal(pixel)
	if absf(direction.y) < 0.0001:
		return Vector3.ZERO
	return origin + direction * ((height - origin.y) / direction.y)


func world_to_screen(point: Vector3) -> Vector2:
	return camera.unproject_position(point) * screen_size / Vector2(viewport.size)

func camera_plane_point(point: Vector2, depth: float) -> Vector3:
	var direction := camera.project_ray_normal(point * Vector2(viewport.size) / screen_size)
	return camera.global_position + direction * depth / maxf(0.001, direction.dot(-camera.global_basis.z))

func camera_plane_pose(center: Vector2, width: float, depth: float, yaw: float = 0.0) -> Transform3D:
	var left := camera_plane_point(center - Vector2(width * 0.5, 0), depth)
	var right := camera_plane_point(center + Vector2(width * 0.5, 0), depth)
	var facing := Basis(camera.global_basis.x, camera.global_basis.z, -camera.global_basis.y) * Basis(Vector3.UP, -yaw)
	return Transform3D(facing.scaled(Vector3.ONE * left.distance_to(right)), camera_plane_point(center, depth))


func pose_for_screen(center: Vector2, width: float, yaw: float = 0.0, height: float = 0.03, tilt: float = 0.0) -> Transform3D:
	var origin := screen_to_world(center, height)
	var left := screen_to_world(center - Vector2(width * 0.5, 0), height)
	var right := screen_to_world(center + Vector2(width * 0.5, 0), height)
	var scale_value := maxf(0.001, left.distance_to(right))
	var basis := Basis(Vector3.RIGHT, tilt) * Basis(Vector3.UP, -yaw)
	return Transform3D(basis.scaled(Vector3.ONE * scale_value), origin)


func project_bounds(entity: CardEntity3D) -> Rect2:
	return project_pose_bounds(entity.global_transform, entity.half_height()).merge(project_pose_bounds(entity.global_transform, -entity.half_height()))


func project_pose_bounds(pose: Transform3D, surface_height: float = CardEntity3D.THICKNESS * 0.5) -> Rect2:
	var result := Rect2()
	var first := true
	for corner in [Vector3(-0.5, surface_height, -CardEntity3D.ASPECT * 0.5), Vector3(0.5, surface_height, -CardEntity3D.ASPECT * 0.5),
		Vector3(0.5, surface_height, CardEntity3D.ASPECT * 0.5), Vector3(-0.5, surface_height, CardEntity3D.ASPECT * 0.5)]:
		var point := world_to_screen(pose * corner)
		if first:
			result = Rect2(point, Vector2.ZERO)
			first = false
		else:
			result = result.expand(point)
	return result


func fit_pose_rect(pose: Transform3D, rect: Rect2, surface_height: float = CardEntity3D.THICKNESS * 0.5) -> Transform3D:
	# Compensate both projected axes. Equal widths alone left far cards shorter
	# and changed the visible gap between the active and bench rows.
	for iteration in range(4):
		var bounds := project_pose_bounds(pose, surface_height)
		pose.basis.x *= rect.size.x / maxf(0.001, bounds.size.x)
		bounds = project_pose_bounds(pose, surface_height)
		pose.basis.z *= rect.size.y / maxf(0.001, bounds.size.y)
		bounds = project_pose_bounds(pose, surface_height)
		pose.origin = screen_to_world(world_to_screen(pose.origin) + rect.get_center() - bounds.get_center(), pose.origin.y)
	return pose


func paper_axis_for_pixels(pose: Transform3D, pixels_per_layer: float) -> Vector3:
	var delta := world_to_screen(pose.origin + Vector3.UP * 0.1) - world_to_screen(pose.origin)
	return Vector3.UP * pixels_per_layer / maxf(0.001, absf(delta.y) * 10.0 * CardEntity3D.THICKNESS)


static func rotate_card_basis(value: Basis, turn: Basis) -> Basis:
	# Rotate the rigid card before applying its calibrated dimensions. Multiplying
	# a nonuniform scale by a rotation bends the silhouette during flips and rolls.
	return value.orthonormalized() * turn * Basis.from_scale(value.get_scale())


func ray_distance(entity: CardEntity3D, point: Vector2) -> float:
	var pixel := point * Vector2(viewport.size) / screen_size
	var inverse := entity.global_transform.affine_inverse()
	var origin := inverse * camera.project_ray_origin(pixel)
	var direction := inverse.basis * camera.project_ray_normal(pixel)
	if absf(direction.y) < 0.00001:
		return -1.0
	var distance := (entity.half_height() - origin.y) / direction.y
	if distance < 0.0:
		return -1.0
	var hit := origin + direction * distance
	if absf(hit.x) > 0.5 or absf(hit.z) > CardEntity3D.ASPECT * 0.5:
		return -1.0
	return distance

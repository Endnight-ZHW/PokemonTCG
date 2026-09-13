class_name BattleFeedback3D
extends Node3D

const LIMIT := 6
var _bursts: Array[Dictionary] = []
var _pool: Array[MultiMeshInstance3D] = []
var _mesh: SphereMesh
var _material: StandardMaterial3D


func _ready() -> void:
	set_process(false)
	_mesh = SphereMesh.new()
	_mesh.radius = 0.025
	_mesh.height = 0.05
	_mesh.radial_segments = 6
	_mesh.rings = 3
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true


func burst(at: Vector3, color: Color, kind: String, quality: String) -> MotionHandle:
	var handle := MotionHandle.new()
	if MotionPolicy.reduced():
		handle.finish()
		return handle
	if _bursts.size() >= LIMIT:
		_recycle(_bursts.pop_front(), true)
	var node: MultiMeshInstance3D
	if _pool.is_empty():
		node = MultiMeshInstance3D.new()
		node.multimesh = MultiMesh.new()
		node.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		node.multimesh.use_colors = true
		node.multimesh.mesh = _mesh
		node.material_override = _material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
	else:
		node = _pool.pop_back()
	node.visible = true
	node.position = at
	var count := 8 if quality == "low" else 14 if quality == "medium" else 22
	node.multimesh.instance_count = count
	for i in range(count):
		node.multimesh.set_instance_color(i, color.lightened(float(i % 3) * 0.08))
	var row := {"node": node, "time": 0.0, "count": count, "handle": handle,
		"duration": maxf(0.06, MotionPolicy.duration("card_place")),
		"radius": 0.7 if kind in ["impact", "ko", "evolution"] else 0.36}
	_bursts.append(row)
	_update_burst(row)
	set_process(true)
	return handle


func clear() -> void:
	var removed := _bursts.duplicate()
	_bursts.clear()
	set_process(false)
	for row in removed:
		_recycle(row, true)


func _process(delta: float) -> void:
	for row in _bursts.duplicate():
		if row not in _bursts:
			continue
		row.time += delta
		if float(row.time) >= float(row.duration):
			_bursts.erase(row)
			_recycle(row)
		else:
			_update_burst(row)
	set_process(not _bursts.is_empty())


func _update_burst(row: Dictionary) -> void:
	var node := row.node as MultiMeshInstance3D
	var t := clampf(float(row.time) / float(row.duration), 0.0, 1.0)
	for i in range(int(row.count)):
		var angle := float(i) * TAU / float(row.count) + float(i % 3) * 0.11
		var radius := float(row.radius) * (1.0 - pow(1.0 - t, 2.0))
		var position_value := Vector3(cos(angle) * radius, sin(t * PI) * 0.25 + 0.035, sin(angle) * radius)
		var pose := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * (1.0 - t) * 1.5), position_value)
		node.multimesh.set_instance_transform(i, pose)


func _recycle(row: Dictionary, cancelled: bool = false) -> void:
	var node := row.node as MultiMeshInstance3D
	node.visible = false
	_pool.append(node)
	var handle := row.handle as MotionHandle
	if cancelled:
		handle.cancel()
	else:
		handle.finish()


func _exit_tree() -> void:
	clear()

class_name BattleFeedback3D
extends Node3D

signal impact_reached(event_id: String)
signal sampled(cue: BattleFeedbackCue, progress: float)
signal released(cue: BattleFeedbackCue)
signal geometry_requested(cue: BattleFeedbackCue)

const LIMIT := 6
const GLYPH_SHADER: Shader = preload("res://scenes/battle/three_d/battle_glyph.gdshader")
var _bursts: Array[Dictionary] = []
var _pool: Array[MultiMeshInstance3D] = []
var _mesh: QuadMesh
var _material: ShaderMaterial
var _geometry := BattleFeedbackGeometry.new()


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
	var count := clampi(int(MotionPolicy.PROFILE.particle_counts.get(cue.quality, 22)), 4, 48)
	if node != null:
		node.multimesh.instance_count = count + 40
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
	cue.sample_progress = t
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
	node.multimesh.visible_instance_count = _geometry.sample(node, cue, t, int(row.count))
	node.force_update_transform()


func refresh_geometry() -> void:
	# Late physical clearance has now resolved the actually rendered flyer.
	# Rebind visual endpoints only: no contact callback, pose writes or clock tick.
	for row in _bursts:
		var cue := row.cue as BattleFeedbackCue
		geometry_requested.emit(cue)
		var node := row.node as MultiMeshInstance3D
		if node != null:
			node.multimesh.visible_instance_count = _geometry.sample(node, cue, cue.sample_progress, int(row.count))
			node.force_update_transform()


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

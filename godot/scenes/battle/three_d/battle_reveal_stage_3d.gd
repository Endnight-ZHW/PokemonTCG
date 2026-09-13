class_name BattleRevealStage3D
extends Node3D

const SHADER := preload("res://scenes/battle/three_d/reveal_backdrop.gdshader")
var _dimmer: MeshInstance3D
var _panel: MeshInstance3D

func _ready() -> void:
	_dimmer = _surface()
	_panel = _surface()
	var dim := _dimmer.material_override as ShaderMaterial
	dim.set_shader_parameter("fill", Color(0.008, 0.015, 0.024, 0.58))
	dim.set_shader_parameter("radius", 0.0)
	visible = false

func _surface() -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.orientation = PlaneMesh.FACE_Y
	mesh.size = Vector2(1, CardEntity3D.ASPECT)
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = SHADER
	node.material_override = material
	add_child(node)
	return node

func apply(projection: BattleProjection3D, frame: Dictionary) -> void:
	visible = not frame.is_empty()
	if not visible: return
	_place(_dimmer, projection, Rect2(Vector2(-2, -2), projection.screen_size + Vector2(4, 4)), 22.0, float(frame.alpha))
	_place(_panel, projection, frame.panel_rect, 20.0, float(frame.alpha))

func _place(surface: MeshInstance3D, projection: BattleProjection3D, rect: Rect2, depth: float, alpha: float) -> void:
	var pose := projection.camera_plane_pose(rect.get_center(), rect.size.x, depth)
	pose.basis.z *= rect.size.y / maxf(1, rect.size.x * CardEntity3D.ASPECT)
	surface.transform = pose
	var material := surface.material_override as ShaderMaterial
	material.set_shader_parameter("rect_pixels", rect.size)
	material.set_shader_parameter("opacity", alpha)
	surface.force_update_transform()

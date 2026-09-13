class_name CardEntity3D
extends Node3D

## A physical card. No game state, input, timers or rule RNG live in this node.
const ASPECT := 88.0 / 63.0
const THICKNESS := 0.010
const BACK: Texture2D = preload("res://assets/cards/card_back.webp")
const SHADOW: Shader = preload("res://scenes/battle/three_d/contact_shadow.gdshader")
static var _card_mesh: ArrayMesh
static var _ring_mesh: ArrayMesh
const SURFACE: Shader = preload("res://scenes/battle/three_d/card_surface.gdshader")

var visual_id := ""
var face_down := false
var face_texture: Texture2D
var body: MeshInstance3D
var outline: MeshInstance3D
var _front: ShaderMaterial
var _outline_material: ShaderMaterial
var _outline_tint := Color.TRANSPARENT
var contact_shadow: MeshInstance3D
var _current_front: Texture2D
var _current_reverse: Texture2D
var clip_enabled := false
var screen_clip := Rect2(0, 0, 1, 1)
var paper_layers := 1.0


func _init() -> void:
	if _card_mesh == null:
		_card_mesh = _make_mesh(false)
		_ring_mesh = _make_mesh(true)
	body = MeshInstance3D.new()
	body.mesh = _card_mesh
	_front = ShaderMaterial.new()
	_front.shader = SURFACE
	_front.set_shader_parameter("reverse_image", BACK)
	_current_reverse = BACK
	body.material_override = _front
	add_child(body)
	outline = MeshInstance3D.new()
	outline.mesh = _ring_mesh
	outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_outline_material = ShaderMaterial.new()
	_outline_material.shader = preload("res://scenes/battle/three_d/card_outline.gdshader")
	outline.material_override = _outline_material
	outline.visible = false
	add_child(outline)
	contact_shadow = MeshInstance3D.new()
	var shadow_mesh := QuadMesh.new()
	shadow_mesh.orientation = PlaneMesh.FACE_Y
	shadow_mesh.size = Vector2(1.16, ASPECT * 1.14)
	contact_shadow.mesh = shadow_mesh
	contact_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = SHADOW
	contact_shadow.material_override = shadow_material
	add_child(contact_shadow)


func update_contact_shadow() -> void:
	contact_shadow.visible = visible and body.visible
	if not is_inside_tree():
		return
	if contact_shadow.visible:
		var width := global_transform.basis.x.length()
		var ground := global_position
		ground.y = 0.004
		var spread := 1.0 + clampf(global_position.y, 0.0, 2.0) * 0.14
		var pose := Transform3D(Basis(Vector3.UP, rotation.y).scaled(Vector3.ONE * width * spread), ground)
		contact_shadow.global_transform = pose
		(contact_shadow.material_override as ShaderMaterial).set_shader_parameter("strength", 0.25 / (1.0 + global_position.y * 1.7))
	# The presenter applies Tween poses in frame_pre_draw, after SceneTree's
	# deferred transform notifications. Flush the actual rendering instances:
	# reading the parent transform alone leaves new/pooled meshes at the origin
	# for one frame even though CPU-side pose checks already report the endpoint.
	body.force_update_transform()
	outline.force_update_transform()
	contact_shadow.force_update_transform()


func set_surface(texture: Texture2D, hidden: bool = false) -> void:
	face_down = hidden
	face_texture = null if hidden else texture
	var displayed: Texture2D = BACK if hidden else texture
	if _current_front != displayed:
		_current_front = displayed
		_front.set_shader_parameter("face_image", displayed)
		_front.set_shader_parameter("has_image", displayed != null)
	set_reverse_surface(BACK)


func set_packet_layers(value: float) -> void:
	value = maxf(1.0, value)
	if is_equal_approx(value, paper_layers):
		return
	paper_layers = value
	_front.set_shader_parameter("paper_layers", value)
	body.custom_aabb = AABB(Vector3(-0.54, -half_height(), -ASPECT * 0.54), Vector3(1.08, half_height() * 2.0, ASPECT * 1.08))
	outline.position.y = half_height()


func half_height() -> float:
	return THICKNESS * paper_layers * 0.5


func set_reverse_surface(texture: Texture2D) -> void:
	if _current_reverse != texture:
		_current_reverse = texture
		_front.set_shader_parameter("reverse_image", texture)


func set_screen_clip(rect: Rect2, enabled: bool) -> void:
	if clip_enabled == enabled and screen_clip == rect:
		return
	clip_enabled = enabled
	screen_clip = rect
	var normalized := Vector4(rect.position.x, rect.position.y, rect.end.x, rect.end.y)
	_front.set_shader_parameter("clip_enabled", enabled)
	_front.set_shader_parameter("screen_clip", normalized)
	_outline_material.set_shader_parameter("clip_enabled", enabled)
	_outline_material.set_shader_parameter("screen_clip", normalized)
	var shadow_material := contact_shadow.material_override as ShaderMaterial
	shadow_material.set_shader_parameter("clip_enabled", enabled)
	shadow_material.set_shader_parameter("screen_clip", normalized)
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func set_feedback(color: Color, strength: float) -> void:
	_front.set_shader_parameter("feedback_color", Vector3(color.r, color.g, color.b))
	_front.set_shader_parameter("feedback_strength", strength)


func set_highlight(selected: bool, targetable: bool, hovered: bool, empty: bool = false) -> void:
	body.visible = not empty
	outline.visible = selected or targetable or hovered or empty
	var tint := Color("dbb766") if selected else Color("62baa4") if targetable else Color("a7c4c0")
	if empty and not selected and not targetable and not hovered:
		tint = Color("385a66")
	if _outline_tint != tint:
		_outline_tint = tint
		_outline_material.set_shader_parameter("tint", tint)


func release() -> void:
	visible = false
	visual_id = ""
	face_texture = null
	_current_front = null
	_front.set_shader_parameter("face_image", null)
	_front.set_shader_parameter("has_image", false)
	set_reverse_surface(BACK)
	set_screen_clip(Rect2(0, 0, 1, 1), false)
	set_feedback(Color.BLACK, 0.0)
	set_packet_layers(1.0)
	outline.visible = false
	transform = Transform3D.IDENTITY


func corners() -> PackedVector3Array:
	return PackedVector3Array([
		global_transform * Vector3(-0.5, half_height(), -ASPECT * 0.5),
		global_transform * Vector3(0.5, half_height(), -ASPECT * 0.5),
		global_transform * Vector3(0.5, half_height(), ASPECT * 0.5),
		global_transform * Vector3(-0.5, half_height(), ASPECT * 0.5),
	])


static func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = roughness
	result.metallic_specular = 0.28
	result.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return result


static func _perimeter(expansion: float = 0.0) -> PackedVector2Array:
	var result := PackedVector2Array()
	var radius := 0.055 + expansion
	for corner in range(4):
		var center := Vector2(
			(0.5 + expansion - radius) * (1.0 if corner in [0, 1] else -1.0),
			(ASPECT * 0.5 + expansion - radius) * (-1.0 if corner in [0, 3] else 1.0))
		for segment in range(7):
			var angle := -PI * 0.5 + float(corner) * PI * 0.5 + float(segment) * PI / 12.0
			result.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return result


static func _make_mesh(ring: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var perimeter := _perimeter()
	if ring:
		var outer := _perimeter(0.030)
		var inner := _perimeter(0.012)
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in range(outer.size()):
			var j := (i + 1) % outer.size()
			for p in [outer[i], outer[j], inner[i], outer[j], inner[j], inner[i]]:
				surface.set_normal(Vector3.UP)
				surface.add_vertex(Vector3(p.x, 0.002, p.y))
		surface.commit(mesh)
		return mesh
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in range(2):
		var height := THICKNESS * (1.0 if face == 0 else -1.0) * 0.5
		for i in range(perimeter.size()):
			var j := (i + 1) % perimeter.size()
			var triangle: Array[Vector2] = [Vector2.ZERO, perimeter[i], perimeter[j]]
			if face == 1:
				triangle.reverse()
			for p in triangle:
				surface.set_normal(Vector3.UP if face == 0 else Vector3.DOWN)
				surface.set_color(Color.RED if face == 0 else Color.GREEN)
				surface.set_uv(Vector2((p.x if face == 0 else -p.x) + 0.5, p.y / ASPECT + 0.5))
				surface.add_vertex(Vector3(p.x, height, p.y))
	for i in range(perimeter.size()):
		var j := (i + 1) % perimeter.size()
		var a := Vector3(perimeter[i].x, THICKNESS * 0.5, perimeter[i].y)
		var b := Vector3(perimeter[j].x, THICKNESS * 0.5, perimeter[j].y)
		var c := b - Vector3.UP * THICKNESS
		var d := a - Vector3.UP * THICKNESS
		for p in [a, d, b, b, d, c]:
			surface.set_normal(Vector3(p.x, 0.0, p.z).normalized())
			surface.set_color(Color.BLUE)
			surface.set_uv(Vector2(float(i) / perimeter.size(), p.y / THICKNESS + 0.5))
			surface.add_vertex(p)
	surface.commit(mesh)
	return mesh

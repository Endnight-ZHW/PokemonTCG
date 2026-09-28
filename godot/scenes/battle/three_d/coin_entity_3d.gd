class_name CoinEntity3D
extends Node3D

const FONT: Font = preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")
const SHADOW: Shader = preload("res://scenes/battle/three_d/contact_shadow.gdshader")
var result_heads := true
var _shadow: MeshInstance3D


func _ready() -> void:
	var gold := _metal(Color("d7ae57"), 0.72, 0.27)
	var edge := _metal(Color("937044"), 0.55, 0.40)
	var stamp := _metal(Color("715236"), 0.35, 0.45)
	_disk(0.49, 0.065, Vector3.ZERO, edge)
	_ring(0.445, 0.497, Vector3.ZERO, gold)
	# Reeding gives the spinning edge a readable sense of thickness.
	var reeds := MultiMeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.012, 0.048, 0.025)
	reeds.multimesh = MultiMesh.new()
	reeds.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	reeds.multimesh.mesh = mesh
	reeds.multimesh.instance_count = 40
	reeds.material_override = gold
	add_child(reeds)
	for i in range(40):
		var angle := float(i) * TAU / 40.0
		reeds.multimesh.set_instance_transform(i, Transform3D(Basis(Vector3.UP, -angle), Vector3(cos(angle), 0, sin(angle)) * 0.486))
	for side in [1.0, -1.0]:
		var face := _metal(Color("edce85") if side > 0 else Color("6d9591"), 0.45, 0.38)
		var ink := stamp if side > 0 else _metal(Color("f7e7ba"), 0.25, 0.45)
		_disk(0.444, 0.004, Vector3(0, side * 0.035, 0), face)
		_ring(0.415, 0.437, Vector3(0, side * 0.037, 0), gold)
		# Embossed ball mark and a separate, high-contrast result character.
		var center := Vector3(0, side * 0.041, -side * 0.10)
		_ring(0.150, 0.175, center, ink)
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = Vector3(0.32, 0.005, 0.022)
		bar.mesh = bar_mesh
		bar.position = center
		bar.material_override = ink
		add_child(bar)
		_disk(0.061, 0.007, center + Vector3(0, side * 0.003, 0), face)
		_ring(0.041, 0.059, center + Vector3(0, side * 0.008, 0), ink)
		var label := Label3D.new()
		label.text = "正" if side > 0 else "反"
		label.font = FONT
		label.font_size = 80
		label.pixel_size = 0.0045
		label.outline_size = 0
		label.modulate = Color("614832") if side > 0 else Color("fff4d7")
		label.shaded = false
		label.position = Vector3(0, side * 0.045, side * 0.235)
		label.rotation.x = -PI * 0.5 * side
		add_child(label)
	_shadow = MeshInstance3D.new()
	var plane := QuadMesh.new()
	plane.orientation = PlaneMesh.FACE_Y
	plane.size = Vector2(1.25, 1.25)
	_shadow.mesh = plane
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = SHADOW
	shadow_material.set_shader_parameter("round_shadow", true)
	_shadow.material_override = shadow_material
	add_child(_shadow)


func _metal(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	return material


func _disk(radius: float, thickness: float, at: Vector3, material: Material) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = thickness
	mesh.radial_segments = 48
	var surface := MeshInstance3D.new()
	surface.mesh = mesh
	surface.material_override = material
	surface.position = at
	add_child(surface)


func _ring(inner: float, outer: float, at: Vector3, material: Material) -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner
	mesh.outer_radius = outer
	mesh.rings = 48
	mesh.ring_segments = 8
	var surface := MeshInstance3D.new()
	surface.mesh = mesh
	surface.material_override = material
	surface.position = at
	add_child(surface)


func pose_for_toss(projection: BattleProjection3D, screen_center: Vector2, pixel_width: float,
	progress: float, heads: bool, start_heads: bool, reduced: bool) -> void:
	result_heads = heads
	var t := 1.0 if reduced else clampf(progress, 0.0, 1.0)
	var start_angle := 0.0 if start_heads else PI
	var end_angle := TAU * MotionPolicy.PROFILE.coin_turns + (0.0 if heads else PI)
	var contact := MotionPolicy.PROFILE.coin_contact_fraction
	var airborne := clampf(t / contact, 0.0, 1.0)
	var angular := 1.0 - pow(1.0 - airborne, 1.5)
	var flip := lerpf(start_angle, end_angle, angular)
	var settle := clampf((t - contact) / (1.0 - contact), 0.0, 1.0)
	var rock := sin(settle * TAU * 1.5) * pow(1.0 - settle, 2.0) * 0.11
	var rise := sin(airborne * PI) * MotionPolicy.PROFILE.coin_lift
	rise += sin(settle * PI) * (1.0 - settle) * 0.07
	var drift := Vector2(sin(t * PI) * 7.0, -sin(t * PI) * 10.0)
	var pose := projection.pose_for_screen(screen_center + drift, pixel_width, sin(t * PI) * 0.08, 0.8, 0.18)
	var resting_origin := pose.origin
	pose.origin.y += rise
	pose.basis = BattleProjection3D.rotate_card_basis(pose.basis, Basis(Vector3.RIGHT, flip + rock))
	transform = pose
	if _shadow != null:
		var scale_value := pose.basis.x.length() * (1.0 + rise * 0.16)
		resting_origin.y = 0.006
		_shadow.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale_value), resting_origin)
		(_shadow.material_override as ShaderMaterial).set_shader_parameter("strength", 0.24 / (1.0 + rise * 1.5))
	for surface in get_children():
		(surface as Node3D).force_update_transform()

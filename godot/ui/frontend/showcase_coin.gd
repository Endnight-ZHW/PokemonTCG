class_name ShowcaseCoin
extends Node3D

## Small decorative coin; no battle projection, rules state, or battle RNG.
const RADIUS := 0.32
const HALF_HEIGHT := 0.049 # Includes both embossed faces and raised rims.
const GROUND_CLEARANCE := 0.004
const REST_HEIGHT := HALF_HEIGHT + GROUND_CLEARANCE
const LIFT := 0.72
const SPIN_START := 0.18
const SPIN_END := 0.82
var heads := true
var tossing := false
var origin := Vector3(0.38, REST_HEIGHT, 1.34)
var progress := 1.0
var _start_angle := 0.0
var _target_angle := 0.0
var _gold: StandardMaterial3D
var _shadow: MeshInstance3D

func _ready() -> void:
	_gold = _metal(Color("e3be68"), 0.55, 0.34)
	var rim := _metal(Color("ac843e"), 0.5, 0.43)
	_disk(0.32, 0.052, Vector3.ZERO, rim)
	for side in [1.0, -1.0]:
		var face := _metal(Color("f0d99a") if side > 0 else Color("547b9f"), 0.35, 0.48)
		var ink := _metal(Color("ad813b") if side > 0 else Color("f1d38a"), 0.3, 0.48)
		_disk(0.294, 0.004, Vector3(0, side * 0.028, 0), face)
		_ring(0.279, 0.316, Vector3(0, side * 0.029, 0), _gold)
		if side > 0:
			_ring(0.137, 0.159, Vector3(0, 0.034, 0), ink)
			var bar := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(0.295, 0.004, 0.022)
			bar.mesh = mesh
			bar.position.y = 0.035
			bar.material_override = ink
			add_child(bar)
			_disk(0.058, 0.006, Vector3(0, 0.038, 0), face)
			_ring(0.035, 0.050, Vector3(0, 0.041, 0), ink)
		else:
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			for i in range(10):
				var a := float(i) * TAU / 10.0
				var b := float(i + 1) * TAU / 10.0
				var ra := 0.165 if i % 2 == 0 else 0.078
				var rb := 0.165 if (i + 1) % 2 == 0 else 0.078
				for point in [Vector3(0, -0.033, 0), Vector3(sin(b) * rb, -0.033, cos(b) * rb), Vector3(sin(a) * ra, -0.033, cos(a) * ra)]:
					surface.set_normal(Vector3.DOWN)
					surface.add_vertex(point)
			var star := MeshInstance3D.new()
			star.mesh = surface.commit()
			star.material_override = ink
			add_child(star)
	_shadow = MeshInstance3D.new()
	var plane := QuadMesh.new()
	plane.orientation = PlaneMesh.FACE_Y
	plane.size = Vector2(0.9, 0.9)
	_shadow.mesh = plane
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = preload("res://scenes/battle/three_d/contact_shadow.gdshader")
	shadow_material.set_shader_parameter("round_shadow", true)
	_shadow.material_override = shadow_material
	add_child(_shadow)
	pose(1.0)

func begin_toss(result: bool) -> void:
	_start_angle = 0.0 if heads else PI
	var changes_face := heads != result
	heads = result
	_target_angle = _start_angle + TAU * 2.0 + (PI if changes_face else 0.0)
	tossing = true
	pose(0.0)

func pose(value: float) -> void:
	progress = clampf(value, 0.0, 1.0)
	var air := minf(1.0, progress / 0.85)
	# Lift clear before spinning, and become flat before approaching the mat.
	rotation.x = lerpf(_start_angle, _target_angle, smoothstep(SPIN_START, SPIN_END, air))
	if progress >= 1.0:
		tossing = false
		rotation.x = 0.0 if heads else PI
	var support := RADIUS * absf(sin(rotation.x)) + HALF_HEIGHT * absf(cos(rotation.x))
	position = origin + Vector3.UP * sin(air * PI) * LIFT
	position.y = maxf(position.y, origin.y - REST_HEIGHT + support + GROUND_CLEARANCE)
	if is_instance_valid(_shadow) and is_inside_tree():
		_shadow.global_transform = Transform3D(Basis.IDENTITY, Vector3(origin.x, 0.005, origin.z))
		(_shadow.material_override as ShaderMaterial).set_shader_parameter("strength", 0.25 / (1.0 + (position.y - origin.y) * 2.0))
	if is_inside_tree():
		for surface: Node3D in get_children():
			surface.force_update_transform()

func highlight(value: float) -> void:
	_gold.albedo_color = Color("e3be68").lightened(value * 0.24)

func _metal(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _disk(radius: float, thickness: float, at: Vector3, material: Material) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = thickness
	mesh.radial_segments = 48
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	node.material_override = material
	add_child(node)

func _ring(inner: float, outer: float, at: Vector3, material: Material) -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner
	mesh.outer_radius = outer
	mesh.rings = 48
	mesh.ring_segments = 8
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	node.material_override = material
	add_child(node)

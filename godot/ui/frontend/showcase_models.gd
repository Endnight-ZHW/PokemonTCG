class_name ShowcaseModels
extends RefCounted

var stage: Variant

func build(owner: Control) -> void:
	stage = owner
	_build_case()
	_build_plinth()

func _material(color: Color, roughness: float = 0.56, metal: float = 0.05) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = stage.CASE_SHADER
	material.set_shader_parameter("base_color", color)
	material.set_shader_parameter("roughness_value", roughness)
	material.set_shader_parameter("metallic_value", metal)
	return material

func _solid(parent: Node3D, label: String, dimensions: Vector3, origin: Vector3, material: Material, radius: float = 0.05) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = ShowcaseGeometry.rounded_box(dimensions, minf(radius, minf(dimensions.x, minf(dimensions.y, dimensions.z)) * 0.45))
	node.material_override = material
	node.position = origin
	parent.add_child(node)
	return node

func _build_case() -> void:
	stage._case_root = Node3D.new()
	stage._case_root.name = "DeckCase"
	stage._case_root.position = Vector3(-1.15, 0, -0.25)
	stage._case_root.rotation_degrees.y = -18
	stage._world.add_child(stage._case_root)
	stage._case_material = ShaderMaterial.new()
	stage._case_material.shader = stage.LEATHER_SHADER
	stage._flap_material = ShaderMaterial.new()
	stage._flap_material.shader = stage.LEATHER_SHADER
	stage._flap_material.set_shader_parameter("edge_paint", true)
	stage._trim_material = _material(Color("6c9980"), 0.63, 0.0)
	stage._thread_material = _material(Color("98c6bc"), 0.90, 0.0)
	stage._lining_material = _material(Color("20282c"), 0.91, 0.0)
	stage._edge_material = _material(Color("263c40"), 0.76, 0.0)
	stage._stage = MeshInstance3D.new()
	stage._stage.name = "OpenCaseBody"
	stage._stage.mesh = ShowcaseCaseGeometry.cup()
	stage._case_root.add_child(stage._stage)
	_set_case_surfaces(stage._stage, stage._case_material)
	stage._lid_root = Node3D.new()
	stage._lid_root.name = "LidAssembly"
	stage._case_root.add_child(stage._lid_root)
	var cover := MeshInstance3D.new()
	cover.name = "ContinuousLeatherFlap"
	cover.mesh = ShowcaseCaseGeometry.lid()
	stage._lid_root.add_child(cover)
	_set_case_surfaces(cover, stage._flap_material)
	stage._case_hinge = MeshInstance3D.new()
	stage._case_hinge.name = "FlexibleRearHinge"
	stage._case_root.add_child(stage._case_hinge)
	set_case_open(0)
	_build_case_stitching()
	# A small sewn colour tab, without another label or large metal nameplate.
	_solid(stage._case_root, "SideTab", Vector3(0.018, 0.20, 0.30), Vector3(ShowcaseCaseGeometry.WIDTH * 0.5 + 0.005, 1.18, 0.29), stage._trim_material, 0.007)
	var badge := MeshInstance3D.new()
	badge.name = "EnamelBadge"
	var enamel := CylinderMesh.new()
	enamel.top_radius = 0.122
	enamel.bottom_radius = 0.122
	enamel.height = 0.014
	enamel.radial_segments = 32
	badge.mesh = enamel
	badge.material_override = _material(Color("d9cfaf"), 0.39, 0.24)
	badge.position = Vector3(-ShowcaseCaseGeometry.WIDTH * 0.30, 1.79, ShowcaseCaseGeometry.FRONT + 0.009) - ShowcaseCaseGeometry.CLOSED_ORIGIN
	badge.rotation_degrees.x = 90
	stage._lid_root.add_child(badge)
	var mark := MeshInstance3D.new()
	mark.name = "EnergyMark"
	var quad := QuadMesh.new()
	quad.size = Vector2(0.205, 0.205)
	mark.mesh = quad
	stage._energy_material = StandardMaterial3D.new()
	stage._energy_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	stage._energy_material.albedo_texture = ShowcaseFinishes.badge_for(stage._energy_type)
	if stage._energy_material.albedo_texture == null:
		stage._energy_material.albedo_texture = stage.BOX_MARK
	stage._energy_material.roughness = 0.65
	mark.material_override = stage._energy_material
	mark.position = Vector3(-ShowcaseCaseGeometry.WIDTH * 0.30, 1.79, ShowcaseCaseGeometry.FRONT + 0.018) - ShowcaseCaseGeometry.CLOSED_ORIGIN
	stage._lid_root.add_child(mark)
	var packet := CardEntity3D.new()
	packet.name = "InnerCardPacket"
	stage._case_root.add_child(packet)
	packet.set_surface(null, true)
	packet.set_packet_layers(60)
	packet.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5).scaled(Vector3.ONE * 1.34), Vector3(0, 1.01, 0))
	packet.contact_shadow.visible = false
	stage._apply_deck_materials()


func _build_case_stitching() -> void:
	var paths: Array[PackedVector3Array] = []
	var lid_paths: Array[PackedVector3Array] = []
	for x in [-ShowcaseCaseGeometry.WIDTH * 0.5 + 0.05, ShowcaseCaseGeometry.WIDTH * 0.5 - 0.05]:
		var path := ShowcaseCaseGeometry.lid_profile(x, 0.06)
		for i in range(path.size()):
			path[i] += ShowcaseCaseGeometry.lid_normal(i) * 0.0015
		lid_paths.append(path)
	var hem := PackedVector3Array()
	for step in range(49):
		var x := lerpf(-ShowcaseCaseGeometry.WIDTH * 0.5 + 0.05, ShowcaseCaseGeometry.WIDTH * 0.5 - 0.05, float(step) / 48.0)
		var point := ShowcaseCaseGeometry.lid_profile(x, 0.06)[-1]
		hem.append(point + Vector3(0, 0, 0.0015))
	lid_paths.append(hem)
	var lid_seams := ShowcaseGeometry.stitches(lid_paths, stage._thread_material)
	lid_seams.name = "LidStitching"
	stage._lid_root.add_child(lid_seams)
	var half_width := ShowcaseCaseGeometry.WIDTH * 0.5
	var half_depth := ShowcaseCaseGeometry.DEPTH * 0.5
	var height := ShowcaseCaseGeometry.HEIGHT
	var rear_x := half_width - 0.062
	var front_x := half_width - 0.065
	var seam_z := half_depth + 0.0015
	paths.append(PackedVector3Array([Vector3(-rear_x, height - 0.042, -seam_z), Vector3(-rear_x, 0.075, -seam_z),
		Vector3(rear_x, 0.075, -seam_z), Vector3(rear_x, height - 0.042, -seam_z)]))
	paths.append(PackedVector3Array([Vector3(-front_x, ShowcaseCaseGeometry.FLAP_BOTTOM - 0.01, seam_z), Vector3(-front_x, 0.075, seam_z),
		Vector3(front_x, 0.075, seam_z), Vector3(front_x, ShowcaseCaseGeometry.FLAP_BOTTOM - 0.01, seam_z)]))
	for x in [-half_width - 0.0015, half_width + 0.0015]:
		paths.append(PackedVector3Array([Vector3(x, height - 0.07, -half_depth + 0.09), Vector3(x, 0.12, -half_depth + 0.09),
			Vector3(x, 0.12, half_depth - 0.09), Vector3(x, height - 0.07, half_depth - 0.09)]))
	var tab_x := half_width + 0.0155
	paths.append(PackedVector3Array([Vector3(tab_x, 1.105, 0.17), Vector3(tab_x, 1.255, 0.17),
		Vector3(tab_x, 1.255, 0.41), Vector3(tab_x, 1.105, 0.41), Vector3(tab_x, 1.105, 0.17)]))
	var seams := ShowcaseGeometry.stitches(paths, stage._thread_material)
	seams.name = "SewnEdges"
	stage._case_root.add_child(seams)


func _set_case_surfaces(mesh_node: MeshInstance3D, outside: Material) -> void:
	mesh_node.set_surface_override_material(0, outside)
	mesh_node.set_surface_override_material(1, stage._lining_material)
	mesh_node.set_surface_override_material(2, stage._edge_material)


## Geometry shared by animated and inspection poses.
func set_case_open(degrees: float) -> void:
	degrees = clampf(degrees, 0, 90)
	stage._lid_root.position = ShowcaseCaseGeometry.hinge_end(degrees)
	stage._lid_root.rotation_degrees.x = -degrees
	stage._case_hinge.mesh = ShowcaseCaseGeometry.hinge(degrees)
	_set_case_surfaces(stage._case_hinge, stage._flap_material)
	stage._request_frame()

func _build_plinth() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "DisplayMat"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 2.52
	mesh.bottom_radius = 2.55
	mesh.height = 0.045
	mesh.radial_segments = 96
	ground.mesh = mesh
	ground.scale.z = 0.80
	ground.position = Vector3(0, -0.0225, 0.15)
	ground.material_override = _material(Color("e9e3d5"), 0.88, 0)
	stage._world.add_child(ground)
	var shadow := MeshInstance3D.new()
	shadow.name = "CaseContactShadow"
	var shadow_mesh := QuadMesh.new()
	shadow_mesh.orientation = PlaneMesh.FACE_Y
	shadow_mesh.size = Vector2(1.97, 1.47)
	shadow.mesh = shadow_mesh
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = preload("res://scenes/battle/three_d/contact_shadow.gdshader")
	shadow_material.set_shader_parameter("strength", 0.32)
	shadow.material_override = shadow_material
	shadow.position = Vector3(-1.12, 0.004, -0.20)
	shadow.rotation_degrees.y = -18
	stage._world.add_child(shadow)
	_build_card_stand()


func _build_card_stand() -> void:
	var stand := Node3D.new()
	stand.name = "CardCradle"
	stand.position = Vector3(1.35, 0, 0.40)
	stand.rotation_degrees.y = -7
	stand.scale = Vector3.ONE * (1.65 / 1.55)
	stage._world.add_child(stand)
	var porcelain := _material(Color("f1eee4"), 0.74, 0.0)
	var inset := _material(Color("354a50"), 0.84, 0.0)
	_solid(stand, "Seat", Vector3(1.636, 0.064, 0.11), Vector3(0, 0.100, 0.402), porcelain, 0.018)
	_solid(stand, "SeatLiner", Vector3(1.48, 0.006, 0.09), Vector3(0, 0.132, 0.402), inset, 0.002)
	_solid(stand, "FrontLip", Vector3(1.69, 0.075, 0.064), Vector3(0, 0.161, 0.492), porcelain, 0.021)
	_solid(stand, "ColourInlay", Vector3(0.39, 0.016, 0.012), Vector3(0, 0.148, 0.529), stage._trim_material, 0.004)
	for x in [-0.818, 0.818]:
		_solid(stand, "Runner", Vector3(0.09, 0.075, 0.86), Vector3(x, 0.045, 0.10), porcelain, 0.030)
		_stand_bar(stand, "BackRail", Vector3(x, 0.075, 0.409), Vector3(x, 0.86, 0.073), 0.058, porcelain)
		_stand_bar(stand, "RearLeg", Vector3(x, 0.077, -0.27), Vector3(x, 0.85, 0.074), 0.044, porcelain)
		_stand_bar(stand, "FrontToe", Vector3(x, 0.08, 0.478), Vector3(x, 0.173, 0.478), 0.065, porcelain)
		for z in [-0.24, 0.43]:
			_solid(stand, "RubberFoot", Vector3(0.083, 0.018, 0.13), Vector3(x, 0.011, z), inset, 0.008)
		_stand_joint(stand, Vector3(x, 0.853, 0.074), x > 0)
	_stand_bar(stand, "BackCrossbar", Vector3(-0.818, 0.82, 0.089), Vector3(0.818, 0.82, 0.089), 0.045, porcelain)
	var pad := _solid(stand, "CardBackPad", Vector3(1.34, 0.075, 0.010), Vector3(0, 0.82, 0.119), inset, 0.004)
	pad.rotation_degrees.x = -23


func _stand_joint(parent: Node3D, origin: Vector3, right: bool) -> void:
	var joint := MeshInstance3D.new()
	joint.name = "Pivot"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.046
	cylinder.bottom_radius = 0.046
	cylinder.height = 0.074
	cylinder.radial_segments = 24
	joint.mesh = cylinder
	joint.material_override = _material(Color("d0cbbc"), 0.61, 0.12)
	joint.rotation_degrees.z = 90
	joint.position = origin
	parent.add_child(joint)
	_solid(parent, "PivotSlot", Vector3(0.003, 0.027, 0.004), origin + Vector3(0.038 if right else -0.038, 0, 0), stage._trim_material, 0.001)


func _stand_bar(parent: Node3D, label: String, a: Vector3, b: Vector3, width: float, material: Material) -> void:
	var delta := b - a
	var bar := _solid(parent, label, Vector3(width, delta.length(), width), (a + b) * 0.5, material, width * 0.3)
	bar.basis = Basis(Quaternion(Vector3.UP, delta.normalized()))

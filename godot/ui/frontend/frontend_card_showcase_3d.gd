class_name FrontendCardShowcase3D
extends Control

signal interaction_changed(active: bool)

## Public catalog art only. This viewport never owns a battle quality session.
const CARD_IDS: Array[String] = ["svg2-tort"]
const CASE_SHADER := preload("res://ui/frontend/showcase_case.gdshader")
const LEATHER_SHADER := preload("res://ui/frontend/showcase_leather.gdshader")
const CARD_SHADER := preload("res://ui/frontend/showcase_card.gdshader")
const BOX_MARK := preload("res://assets/ui/frontend/club_mark.svg")
var viewport: SubViewport
var camera: Camera3D
var cards: Array[CardEntity3D] = []
var card_ids: Array[String] = []
var _surface: TextureRect
var _world: Node3D
var _light: DirectionalLight3D
var _active := true
var _suspended := false
var _animated := false
var _quality := ""
var _dragging := false
var _touch_id := -1
var _camera_yaw := 0.0
var _camera_pitch := 0.0
var _case_root: Node3D
var _lid_root: Node3D
var _case_hinge: MeshInstance3D
var _lining_material: ShaderMaterial
var _edge_material: ShaderMaterial
var _case_material: ShaderMaterial
var _flap_material: ShaderMaterial
var _thread_material: ShaderMaterial
var _trim_material: ShaderMaterial
var _name_plate: Label3D
var _energy_material: StandardMaterial3D
var _deck_name := "土台龟"
var _energy_type := "Grass"
var _card_count := 60
var _dirty := true
var _paths: Dictionary = {}
var _pixel_size := Vector2i.ZERO
var _stage: MeshInstance3D
var _backs: Array[CardEntity3D] = []
var _settings: Node
var _texture_cache: Node
var _cards_set := false


func _ready() -> void:
	_settings = get_node("/root/AppSettings")
	_texture_cache = get_node("/root/CardTextureCache")
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	accessibility_name = "牌组展示，拖动调整视角"
	clip_contents = true
	_surface = TextureRect.new()
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surface.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_surface.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_surface)
	_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport = SubViewport.new()
	viewport.name = "ShowcaseViewport"
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.gui_disable_input = true
	viewport.handle_input_locally = false
	_surface.add_child(viewport)
	_surface.texture = viewport.get_texture()
	_world = Node3D.new()
	viewport.add_child(_world)
	camera = Camera3D.new()
	camera.fov = 32.0
	camera.near = 0.1
	camera.far = 40.0
	_world.add_child(camera)
	camera.make_current()
	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-48, -28, 0)
	_light.light_energy = 0.80
	_light.light_color = Color.WHITE
	_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_light.directional_shadow_max_distance = 30.0
	_world.add_child(_light)
	for light_data in [[Vector3(-25, 65, 0), 0.30, Color("e0eaff")], [Vector3(-55, -150, 0), 0.30, Color("fff0d4")]]:
		var fill := DirectionalLight3D.new()
		fill.rotation_degrees = light_data[0]
		fill.light_energy = light_data[1]
		fill.light_color = light_data[2]
		_world.add_child(fill)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.TRANSPARENT
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("dbe5ed")
	environment.environment.ambient_light_energy = 0.16
	_world.add_child(environment)
	_build_case()
	_build_plinth()
	for index in range(2):
		var back := CardEntity3D.new()
		back.name = "CardBack%d" % index
		_world.add_child(back)
		(back.body.material_override as ShaderMaterial).shader = CARD_SHADER
		back.set_surface(null, true)
		back.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-16 + index * 11)).scaled(Vector3.ONE * 0.90), Vector3(-0.70 + index * 0.13, 0.008 + index * 0.012, 1.40 + index * 0.05))
		back.update_contact_shadow()
		_backs.append(back)
	for index in range(3):
		var card := CardEntity3D.new()
		(card.body.material_override as ShaderMaterial).shader = CARD_SHADER
		card.name = "ShowcaseCard%d" % index
		card.visual_id = "catalog_showcase:%d" % index
		_world.add_child(card)
		cards.append(card)
	visibility_changed.connect(_refresh_activity)
	resized.connect(_request_frame)
	resized.connect(_cancel_drag)
	_settings.changed.connect(_on_settings_changed)
	_settings.runtime_quality_changed.connect(_on_settings_changed)
	_texture_cache.texture_ready.connect(_on_texture_ready)
	RenderingServer.frame_pre_draw.connect(_prepare_frame)
	set_cards(card_ids if _cards_set else CARD_IDS)
	_on_settings_changed()
	_request_frame()


func set_cards(values: Array[String]) -> void:
	_cards_set = true
	var requested := values.duplicate()
	card_ids.clear()
	_paths.clear()
	for id in requested:
		if card_ids.size() == 3:
			break
		if id in card_ids:
			continue
		var path := str(CardCatalog.shared().get_card(id).get("image_path", ""))
		if not path.is_empty():
			card_ids.append(id)
			_paths[path] = card_ids.size() - 1
	if not is_node_ready():
		return
	for index in range(cards.size()):
		cards[index].visible = index < card_ids.size()
		cards[index].set_surface(null)
	if _active and is_visible_in_tree():
		_load_cards()
	_request_frame()


func set_active(value: bool) -> void:
	if _active == value:
		return
	_active = value
	_set_dragging(false)
	_touch_id = -1
	_refresh_activity()


func _load_cards() -> void:
	for path in _paths:
		var texture := _texture_cache.get_cached_or_request(path) as Texture2D
		if texture != null:
			cards[int(_paths[path])].set_surface(texture)


func _on_texture_ready(path: String, texture: Texture2D) -> void:
	if not _paths.has(path) or not _active or _suspended or not is_visible_in_tree():
		return
	cards[int(_paths[path])].set_surface(texture)
	_request_frame()


func _on_settings_changed() -> void:
	_quality = _settings.resolved_quality_profile()
	_animated = false # Stable still-life; entrance motion belongs to the page.
	viewport.msaa_3d = SubViewport.MSAA_4X if _quality == "high" else SubViewport.MSAA_2X if _quality == "medium" else SubViewport.MSAA_DISABLED
	viewport.scaling_3d_scale = 1.0 if _quality == "high" else 0.85 if _quality == "medium" else 0.75
	_light.shadow_enabled = false # Soft contact shadows remain stable in Compatibility on every tier.
	_refresh_activity()


func _refresh_activity() -> void:
	if not is_node_ready():
		return
	var enabled := _active and not _suspended and is_visible_in_tree()
	if enabled:
		_load_cards()
		_request_frame()
	else:
		set_process(false)
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _request_frame() -> void:
	_dirty = true
	if is_node_ready() and _active and not _suspended and is_visible_in_tree():
		# A static pose still needs a live render target. A few global draw
		# notifications cannot prove this viewport is ready, and freezing it can
		# retain transparent pixels after delayed drawing or target recreation.
		viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		set_process(_animated)
		if DisplayServer.get_name() == "headless":
			call_deferred("_prepare_frame")


func _prepare_frame() -> void:
	if not is_node_ready() or not _active or _suspended or not is_visible_in_tree():
		return
	var canvas := get_viewport().get_final_transform() * get_global_transform_with_canvas()
	var pixels := Vector2i((size * Vector2(canvas.x.length(), canvas.y.length())).ceil()).max(Vector2i(2, 2))
	if pixels != _pixel_size:
		_pixel_size = pixels
		viewport.size = pixels
		_request_frame()
	if not _dirty:
		return
	_dirty = false
	var aspect := size.x / maxf(1.0, size.y)
	var distance := maxf(8.6, 9.4 / maxf(0.1, aspect))
	camera.far = maxf(40.0, distance + 10.0)
	camera.position = Basis(Vector3.UP, deg_to_rad(_camera_yaw)) * Vector3(0, 0.43 + _camera_pitch * 0.008, 0.90).normalized() * distance + Vector3(0, 0.85, 0)
	camera.look_at(Vector3(0, 0.85, 0))
	for index in range(cards.size()):
		cards[index].transform = Transform3D(
			Basis(Vector3.UP, deg_to_rad(-7)) * Basis(Vector3.RIGHT, deg_to_rad(67)).scaled(Vector3.ONE * 1.55),
			Vector3(1.35 + index * 0.10, 1.135 + index * 0.09, 0.40 - index * 0.16))
		cards[index].set_highlight(false, false, false)
		cards[index].update_contact_shadow()
	for back in _backs:
		back.update_contact_shadow()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_suspended = true
		_set_dragging(false)
		_touch_id = -1
		_refresh_activity()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_suspended = false
		_refresh_activity()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_drag()


func _material(color: Color, roughness: float = 0.56, metal: float = 0.05) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = CASE_SHADER
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
	_case_root = Node3D.new()
	_case_root.name = "DeckCase"
	_case_root.position = Vector3(-1.15, 0, -0.25)
	_case_root.rotation_degrees.y = -18
	_world.add_child(_case_root)
	_case_material = ShaderMaterial.new()
	_case_material.shader = LEATHER_SHADER
	_flap_material = ShaderMaterial.new()
	_flap_material.shader = LEATHER_SHADER
	_flap_material.set_shader_parameter("edge_paint", true)
	_trim_material = _material(Color("6c9980"), 0.63, 0.0)
	_thread_material = _material(Color("98c6bc"), 0.90, 0.0)
	_lining_material = _material(Color("20282c"), 0.91, 0.0)
	_edge_material = _material(Color("263c40"), 0.76, 0.0)
	_stage = MeshInstance3D.new()
	_stage.name = "OpenCaseBody"
	_stage.mesh = ShowcaseCaseGeometry.cup()
	_case_root.add_child(_stage)
	_set_case_surfaces(_stage, _case_material)
	_lid_root = Node3D.new()
	_lid_root.name = "LidAssembly"
	_case_root.add_child(_lid_root)
	var cover := MeshInstance3D.new()
	cover.name = "ContinuousLeatherFlap"
	cover.mesh = ShowcaseCaseGeometry.lid()
	_lid_root.add_child(cover)
	_set_case_surfaces(cover, _flap_material)
	_case_hinge = MeshInstance3D.new()
	_case_hinge.name = "FlexibleRearHinge"
	_case_root.add_child(_case_hinge)
	_set_case_open(0)
	_build_case_stitching()
	# A small sewn colour tab, without another label or large metal nameplate.
	_solid(_case_root, "SideTab", Vector3(0.018, 0.20, 0.30), Vector3(0.905, 1.18, 0.38), _trim_material, 0.007)
	var badge := MeshInstance3D.new()
	badge.name = "EnamelBadge"
	var enamel := CylinderMesh.new()
	enamel.top_radius = 0.122
	enamel.bottom_radius = 0.122
	enamel.height = 0.014
	enamel.radial_segments = 32
	badge.mesh = enamel
	badge.material_override = _material(Color("d9cfaf"), 0.39, 0.24)
	badge.position = Vector3(-0.59, 1.79, 0.716) - ShowcaseCaseGeometry.CLOSED_ORIGIN
	badge.rotation_degrees.x = 90
	_lid_root.add_child(badge)
	var mark := MeshInstance3D.new()
	mark.name = "EnergyMark"
	var quad := QuadMesh.new()
	quad.size = Vector2(0.205, 0.205)
	mark.mesh = quad
	_energy_material = StandardMaterial3D.new()
	_energy_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_energy_material.albedo_texture = EnergyIconCatalog.texture_for(_energy_type)
	if _energy_material.albedo_texture == null:
		_energy_material.albedo_texture = BOX_MARK
	_energy_material.roughness = 0.65
	mark.material_override = _energy_material
	mark.position = Vector3(-0.59, 1.79, 0.725) - ShowcaseCaseGeometry.CLOSED_ORIGIN
	_lid_root.add_child(mark)
	_name_plate = _plate(_deck_name, Vector3(0, 1.015, 0.711) - ShowcaseCaseGeometry.CLOSED_ORIGIN, 34)
	_apply_deck_materials()


func _build_case_stitching() -> void:
	var paths: Array[PackedVector3Array] = []
	var lid_paths: Array[PackedVector3Array] = []
	for x in [-0.85, 0.85]:
		var path := ShowcaseCaseGeometry.lid_profile(x, 0.06)
		for i in range(path.size()):
			path[i] += ShowcaseCaseGeometry.lid_normal(i) * 0.0015
		lid_paths.append(path)
	var hem := PackedVector3Array()
	for step in range(49):
		var x := lerpf(-0.85, 0.85, float(step) / 48.0)
		var point := ShowcaseCaseGeometry.lid_profile(x, 0.06)[-1]
		hem.append(point + Vector3(0, 0, 0.0015))
	lid_paths.append(hem)
	var lid_seams := ShowcaseGeometry.stitches(lid_paths, _thread_material)
	lid_seams.name = "LidStitching"
	_lid_root.add_child(lid_seams)
	paths.append(PackedVector3Array([Vector3(-0.838, 2.018, -0.6715), Vector3(-0.838, 0.075, -0.6715),
		Vector3(0.838, 0.075, -0.6715), Vector3(0.838, 2.018, -0.6715)]))
	# The uncovered lower front and both gussets have their own stitched seam.
	paths.append(PackedVector3Array([Vector3(-0.835, 0.77, 0.6715), Vector3(-0.835, 0.075, 0.6715),
		Vector3(0.835, 0.075, 0.6715), Vector3(0.835, 0.77, 0.6715)]))
	for x in [-0.9015, 0.9015]:
		paths.append(PackedVector3Array([Vector3(x, 1.99, -0.58), Vector3(x, 0.12, -0.58),
			Vector3(x, 0.12, 0.58), Vector3(x, 1.99, 0.58)]))
	paths.append(PackedVector3Array([Vector3(0.9155, 1.105, 0.26), Vector3(0.9155, 1.255, 0.26),
		Vector3(0.9155, 1.255, 0.50), Vector3(0.9155, 1.105, 0.50), Vector3(0.9155, 1.105, 0.26)]))
	var seams := ShowcaseGeometry.stitches(paths, _thread_material)
	seams.name = "SewnEdges"
	_case_root.add_child(seams)


func _set_case_surfaces(mesh_node: MeshInstance3D, outside: Material) -> void:
	mesh_node.set_surface_override_material(0, outside)
	mesh_node.set_surface_override_material(1, _lining_material)
	mesh_node.set_surface_override_material(2, _edge_material)


## Inspection pose only; the title keeps the lid closed and has no new controls.
func _set_case_open(degrees: float) -> void:
	degrees = clampf(degrees, 0, 90)
	_lid_root.position = ShowcaseCaseGeometry.hinge_end(degrees)
	_lid_root.rotation_degrees.x = -degrees
	_case_hinge.mesh = ShowcaseCaseGeometry.hinge(degrees)
	_set_case_surfaces(_case_hinge, _flap_material)
	_request_frame()

func _plate(text_value: String, origin: Vector3, font_size_value: int) -> Label3D:
	var label := Label3D.new()
	label.font = preload("res://assets/ui/fonts/noto_sans_cjk_sc_semibold.tres")
	label.font_size = font_size_value
	label.pixel_size = 0.004
	label.outline_size = 0
	label.modulate = Color("e8e9df")
	label.text = text_value
	label.width = 310
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.position = origin
	_lid_root.add_child(label)
	return label

func _build_plinth() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "DisplayMat"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 2.52
	mesh.bottom_radius = 2.55
	mesh.height = 0.08
	mesh.radial_segments = 96
	ground.mesh = mesh
	ground.scale.z = 0.80
	ground.position = Vector3(0, -0.04, 0.15)
	ground.material_override = _material(Color("cdd4d0"), 0.88, 0)
	_world.add_child(ground)
	var shadow := MeshInstance3D.new()
	shadow.name = "CaseContactShadow"
	var shadow_mesh := QuadMesh.new()
	shadow_mesh.orientation = PlaneMesh.FACE_Y
	shadow_mesh.size = Vector2(2.35, 1.70)
	shadow.mesh = shadow_mesh
	var shadow_material := ShaderMaterial.new()
	shadow_material.shader = preload("res://scenes/battle/three_d/contact_shadow.gdshader")
	shadow_material.set_shader_parameter("strength", 0.32)
	shadow.material_override = shadow_material
	shadow.position = Vector3(-1.12, 0.004, -0.20)
	shadow.rotation_degrees.y = -18
	_world.add_child(shadow)
	_build_card_stand()


func _build_card_stand() -> void:
	var stand := Node3D.new()
	stand.name = "CardCradle"
	stand.position = Vector3(1.35, 0, 0.40)
	stand.rotation_degrees.y = -7
	_world.add_child(stand)
	var porcelain := _material(Color("e3e1d5"), 0.48, 0.04)
	var inset := _material(Color("354a50"), 0.84, 0.0)
	_solid(stand, "Seat", Vector3(1.636, 0.064, 0.11), Vector3(0, 0.100, 0.402), porcelain, 0.018)
	_solid(stand, "SeatLiner", Vector3(1.48, 0.006, 0.09), Vector3(0, 0.132, 0.402), inset, 0.002)
	_solid(stand, "FrontLip", Vector3(1.69, 0.075, 0.064), Vector3(0, 0.161, 0.492), porcelain, 0.021)
	_solid(stand, "ColourInlay", Vector3(0.39, 0.016, 0.012), Vector3(0, 0.148, 0.529), _trim_material, 0.004)
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
	joint.material_override = _material(Color("b0aba0"), 0.36, 0.45)
	joint.rotation_degrees.z = 90
	joint.position = origin
	parent.add_child(joint)
	_solid(parent, "PivotSlot", Vector3(0.003, 0.027, 0.004), origin + Vector3(0.038 if right else -0.038, 0, 0), _trim_material, 0.001)


func _stand_bar(parent: Node3D, label: String, a: Vector3, b: Vector3, width: float, material: Material) -> void:
	var delta := b - a
	var bar := _solid(parent, label, Vector3(width, delta.length(), width), (a + b) * 0.5, material, width * 0.3)
	bar.basis = Basis(Quaternion(Vector3.UP, delta.normalized()))

func set_deck(name_value: String, energy_type: String, count_value: int) -> void:
	_deck_name = name_value
	_energy_type = energy_type
	_card_count = count_value
	if is_node_ready():
		_apply_deck_materials()

func _apply_deck_materials() -> void:
	# Product colours are intentionally quieter than battle energy colours.
	var finishes := {
		"Water": Color("409a9d"), "Grass": Color("719777"),
		"Fire": Color("bb6c50"), "Lightning": Color("b89842"),
		"Psychic": Color("876890"), "Fighting": Color("ae805c"),
		"Darkness": Color("45576b"), "Metal": Color("71868a"),
		"Dragon": Color("948263"), "Fairy": Color("b07d8b"),
	}
	var leather: Color = finishes.get(_energy_type, Color("788491"))
	_case_material.set_shader_parameter("base_color", leather)
	_flap_material.set_shader_parameter("base_color", leather)
	_thread_material.set_shader_parameter("base_color", leather.lerp(Color("efe6cb"), 0.38))
	_trim_material.set_shader_parameter("base_color", leather.darkened(0.35))
	_edge_material.set_shader_parameter("base_color", leather.darkened(0.48))
	_energy_material.albedo_texture = EnergyIconCatalog.texture_for(_energy_type)
	if _energy_material.albedo_texture == null:
		_energy_material.albedo_texture = BOX_MARK
	_name_plate.text = _deck_name
	_request_frame()

func stats() -> Dictionary:
	return {"cards": card_ids.size(), "quality": _quality, "animated": _animated,
		"updating": viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED,
		"draw_calls": viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)}


func _exit_tree() -> void:
	_paths.clear()
	for card in cards + _backs:
		if is_instance_valid(card):
			card.release()


func is_interacting() -> bool:
	return _dragging

## Deliberately separate from tap cancellation: moving past tap slop is a valid view drag.
func _cancel_drag() -> void:
	_set_dragging(false)
	_touch_id = -1

func _set_dragging(value: bool) -> void:
	if _dragging == value:
		return
	_dragging = value
	interaction_changed.emit(value)

func _gui_input(event: InputEvent) -> void:
	if not _active or _suspended:
		return
	if event is InputEventScreenTouch:
		if event.pressed and _touch_id == -1:
			_touch_id = event.index
			_set_dragging(true)
		elif event.index == _touch_id:
			_touch_id = -1
			_set_dragging(false)
		accept_event()
	elif event is InputEventScreenDrag and event.index == _touch_id:
		_drag_view(event.relative)
		accept_event()
	elif event is InputEventMouseButton and _touch_id == -1 and event.button_index == MOUSE_BUTTON_LEFT:
		_set_dragging(event.pressed)
		accept_event()
	elif event is InputEventMouseMotion and _touch_id == -1 and _dragging:
		_drag_view(event.relative)
		accept_event()

func _drag_view(delta: Vector2) -> void:
	_camera_yaw = clampf(_camera_yaw - delta.x * 0.10, -16.0, 16.0)
	_camera_pitch = clampf(_camera_pitch + delta.y * 0.08, -6.0, 6.0)
	_request_frame()

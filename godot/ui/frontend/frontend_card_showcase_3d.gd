class_name FrontendCardShowcase3D
extends Control

## Public catalog art only. This viewport never owns a battle quality session.
const CARD_IDS: Array[String] = ["svg2-tort", "sv2-grex", "svi-ente"]
const SURFACE := preload("res://scenes/battle/three_d/table_surface.gdshader")
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
var _elapsed := 0.0
var _dirty := true
var _settle_frames := 0
var _paths: Dictionary = {}
var _pixel_size := Vector2i.ZERO
var _stage: MeshInstance3D
var _mat: MeshInstance3D
var _settings: Node
var _texture_cache: Node
var _cards_set := false


func _ready() -> void:
	_settings = get_node("/root/AppSettings")
	_texture_cache = get_node("/root/CardTextureCache")
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_surface = TextureRect.new()
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surface.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_surface.stretch_mode = TextureRect.STRETCH_SCALE
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
	camera.fov = 30.0
	camera.near = 0.1
	camera.far = 40.0
	_world.add_child(camera)
	camera.make_current()
	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-62, -18, 0)
	_light.light_energy = 1.10
	_light.light_color = Color("fffaf4")
	_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_light.directional_shadow_max_distance = 30.0
	_world.add_child(_light)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.TRANSPARENT
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("dbe5ed")
	environment.environment.ambient_light_energy = 0.0
	_world.add_child(environment)
	_stage = _box("DisplayTray", Vector3(5.3, 0.16, 3.4), Vector3(0, -0.12, 0.1), true, FrontendPalette.WOOD)
	_mat = _box("DisplayCloth", Vector3(5.12, 0.04, 3.22), Vector3(0, -0.02, 0.1), false, FrontendPalette.PANEL)
	for index in range(3):
		var card := CardEntity3D.new()
		card.name = "ShowcaseCard%d" % index
		card.visual_id = "catalog_showcase:%d" % index
		_world.add_child(card)
		cards.append(card)
	visibility_changed.connect(_refresh_activity)
	resized.connect(_request_frame)
	_settings.changed.connect(_on_settings_changed)
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
	_animated = FrontendMotion.decorative_motion_enabled()
	viewport.msaa_3d = SubViewport.MSAA_4X if _quality == "high" else SubViewport.MSAA_2X if _quality == "medium" else SubViewport.MSAA_DISABLED
	viewport.scaling_3d_scale = 1.0 if _quality == "high" else 0.85 if _quality == "medium" else 0.75
	_light.shadow_enabled = _quality != "low"
	_elapsed = 0.0
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
	_settle_frames = 3
	if is_node_ready() and _active and not _suspended and is_visible_in_tree():
		set_process(true)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _process(delta: float) -> void:
	if _animated:
		_elapsed += delta
		_dirty = true
	else:
		_settle_frames -= 1
		if _settle_frames < 0:
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			set_process(false)
	if DisplayServer.get_name() == "headless":
		_prepare_frame()


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
	var distance := maxf(6.7, 11.4 / maxf(0.65, aspect))
	camera.position = Vector3(0, 0.87, 0.49).normalized() * distance
	camera.look_at(Vector3(0, 0, 0.1))
	for index in range(cards.size()):
		var x := float(index) - float(card_ids.size() - 1) * 0.5
		var bob := (sin(_elapsed * 0.7 + index * 0.8) + 1.0) * 0.008 if _animated else 0.0
		cards[index].transform = Transform3D(
			Basis(Vector3.UP, deg_to_rad(-x * 12.0)).scaled(Vector3.ONE * 1.6),
			Vector3(x * 1.29, 0.014 + index * 0.018 + bob, absf(x) * 0.16),
		)
		cards[index].set_highlight(false, false, false)
		cards[index].update_contact_shadow()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_suspended = true
		_refresh_activity()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_suspended = false
		_refresh_activity()


func _box(label: String, dimensions: Vector3, origin: Vector3, wood: bool, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	node.mesh = mesh
	var material := ShaderMaterial.new()
	material.shader = SURFACE
	material.set_shader_parameter("wood", wood)
	material.set_shader_parameter("base_color", color)
	node.material_override = material
	node.position = origin
	_world.add_child(node)
	return node


func stats() -> Dictionary:
	return {"cards": card_ids.size(), "quality": _quality, "animated": _animated,
		"updating": viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED,
		"draw_calls": viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)}


func _exit_tree() -> void:
	_paths.clear()
	for card in cards:
		if is_instance_valid(card):
			card.release()

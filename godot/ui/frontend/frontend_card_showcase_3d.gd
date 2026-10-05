class_name FrontendCardShowcase3D
extends Control

signal interaction_changed(active: bool)
signal card_activated(card_id: String)
signal sound_requested(cue: String)

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
var _models: ShowcaseModels
var _coin: ShowcaseCoin
var _lid_angle := 0.0
var _lid_target := 0.0
var _lid_tween: Tween
var _coin_tween: Tween
var _cosmetic_rng := RandomNumberGenerator.new()
var _gesture := PointerGesture.new()
var _press_target := ""
var _hover_target := ""
var _reported_interaction := false



func _ready() -> void:
	_cosmetic_rng.randomize()
	mouse_exited.connect(_clear_hover)
	_settings = get_node("/root/AppSettings")
	_texture_cache = get_node("/root/CardTextureCache")
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	accessibility_name = "牌组展示：拖动调整视角，点按牌盒开合、卡牌放大或硬币翻转"
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
	_models = ShowcaseModels.new()
	_models.build(self)
	_coin = ShowcaseCoin.new()
	_world.add_child(_coin)
	for index in range(2):
		var back := CardEntity3D.new()
		back.name = "CardBack%d" % index
		_world.add_child(back)
		(back.body.material_override as ShaderMaterial).shader = CARD_SHADER
		back.set_surface(null, true)
		back.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-16 + index * 11)).scaled(Vector3.ONE * 0.90), Vector3(-1.13 + index * 0.13, 0.008 + index * 0.012, 1.30 + index * 0.05))
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
	resized.connect(_cancel_interaction)
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
	_cancel_interaction()
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
	if not FrontendMotion.decorative_motion_enabled():
		_cancel_interaction()
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
		_cancel_interaction()
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
	var distance := maxf(9.1, 9.4 / maxf(0.1, aspect))
	camera.far = maxf(40.0, distance + 10.0)
	camera.position = Basis(Vector3.UP, deg_to_rad(_camera_yaw)) * Vector3(0, 0.43 + _camera_pitch * 0.008, 0.90).normalized() * distance + Vector3(0, 1.12, 0)
	camera.look_at(Vector3(0, 1.12, 0))
	for index in range(cards.size()):
		cards[index].transform = Transform3D(
			Basis(Vector3.UP, deg_to_rad(-7)) * Basis(Vector3.RIGHT, deg_to_rad(67)).scaled(Vector3.ONE * 1.65),
			Vector3(1.35 + index * 0.10, 1.135 * (1.65 / 1.55) + index * 0.09, 0.40 - index * 0.16))
		cards[index].set_highlight(false, false, false)
		cards[index].update_contact_shadow()
	for back in _backs:
		back.update_contact_shadow()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		_suspended = true
		if is_node_ready():
			_cancel_interaction()
			_refresh_activity()
	elif what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN]:
		_suspended = false
		if is_node_ready():
			_refresh_activity()

func _set_case_open(degrees: float) -> void:
	_lid_angle = clampf(degrees, 0, 90)
	_models.set_case_open(_lid_angle)
	_notify_interaction()

func set_deck(name_value: String, energy_type: String, count_value: int) -> void:
	_deck_name = name_value
	_energy_type = energy_type
	_card_count = count_value
	if is_node_ready():
		_apply_deck_materials()

func _apply_deck_materials() -> void:
	var leather := ShowcaseFinishes.color_for(_energy_type)
	ShowcaseFinishes.apply(_case_material, _energy_type)
	ShowcaseFinishes.apply(_flap_material, _energy_type)
	_thread_material.set_shader_parameter("base_color", leather.lerp(Color("fff0ca"), 0.48))
	_trim_material.set_shader_parameter("base_color", leather.darkened(0.24))
	_edge_material.set_shader_parameter("base_color", leather.darkened(0.40))
	_energy_material.albedo_texture = ShowcaseFinishes.badge_for(_energy_type)
	_request_frame()


func stats() -> Dictionary:
	return {"cards": card_ids.size(), "quality": _quality, "animated": _animated,
		"updating": viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED,
		"draw_calls": viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)}


func _exit_tree() -> void:
	_cancel_interaction()


func is_interacting() -> bool:
	return _dragging or not _hover_target.is_empty() or _lid_angle > 0.01 or _lid_target > 0.01 or (is_instance_valid(_coin) and _coin.tossing)

func _notify_interaction() -> void:
	var current := is_interacting()
	if current != _reported_interaction:
		_reported_interaction = current
		interaction_changed.emit(current)

func _set_dragging(value: bool) -> void:
	_dragging = value
	_notify_interaction()

func _cancel_drag() -> void:
	_gesture.clear()
	_press_target = ""
	_touch_id = -1
	_set_dragging(false)

func _clear_hover() -> void:
	_hover_target = ""
	_apply_highlight()
	_notify_interaction()

func _cancel_interaction() -> void:
	_cancel_drag()
	_clear_hover()
	if _lid_tween and _lid_tween.is_valid():
		_lid_tween.kill()
	if _models:
		_set_case_open(_lid_target)
	if _coin_tween and _coin_tween.is_valid():
		_coin_tween.kill()
	if is_instance_valid(_coin):
		_coin.pose(1.0)
	_notify_interaction()

func _apply_highlight() -> void:
	if not is_node_ready() or _case_material == null:
		return
	var target := _press_target if _dragging else _hover_target
	var amount := 0.55 if _dragging else 1.0
	for material: ShaderMaterial in [_case_material, _flap_material]:
		material.set_shader_parameter("highlight", amount if target == "case" else 0.0)
	for card in cards:
		card.set_feedback(HomePalette.SUNLIGHT, 0.12 * amount if target == "card" else 0.0)
	if is_instance_valid(_coin):
		_coin.highlight(amount if target == "coin" else 0.0)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not _hover_target.is_empty() else Control.CURSOR_DRAG
	_request_frame()

func _toggle_case() -> void:
	_lid_target = 0.0 if _lid_target > 0 else 90.0
	if _lid_tween and _lid_tween.is_valid():
		_lid_tween.kill()
	sound_requested.emit("click")
	if not FrontendMotion.decorative_motion_enabled():
		_set_case_open(_lid_target)
	else:
		_lid_tween = create_tween()
		_lid_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		var seconds := 0.35 * absf(_lid_target - _lid_angle) / 90.0
		_lid_tween.tween_method(_set_case_open, _lid_angle, _lid_target, maxf(0.08, seconds))
		_lid_tween.finished.connect(_notify_interaction)
	_notify_interaction()

func _toss_coin() -> void:
	if _coin.tossing:
		return
	_coin.begin_toss(_cosmetic_rng.randf() < 0.5)
	sound_requested.emit("coin_toss")
	if not FrontendMotion.decorative_motion_enabled():
		_coin.pose(1.0)
		_request_frame()
		sound_requested.emit("coin_land")
	else:
		_coin_tween = create_tween()
		_coin_tween.tween_method(_pose_coin, 0.0, 1.0, 0.75)
		_coin_tween.finished.connect(func() -> void:
			sound_requested.emit("coin_land")
			_notify_interaction()
		)
	_notify_interaction()

func _pose_coin(value: float) -> void:
	_coin.pose(value)
	_request_frame()

func _activate(target: String) -> void:
	match target:
		"case": _toggle_case()
		"coin": _toss_coin()
		"card":
			if not card_ids.is_empty():
				card_activated.emit(card_ids[0])

func _pointer_begin(point: Vector2, index: int) -> void:
	_touch_id = index
	_gesture.begin(PointerGesture.viewport_point(self, point), index)
	_press_target = ShowcaseHitTest.pick(self, point)
	_set_dragging(true)
	_apply_highlight()

func _pointer_move(point: Vector2, relative: Vector2) -> void:
	_gesture.move(PointerGesture.viewport_point(self, point))
	if not _gesture.can_tap():
		_drag_view(relative)
		_press_target = ""
		_apply_highlight()

func _pointer_end(point: Vector2, cancelled: bool) -> void:
	_gesture.move(PointerGesture.viewport_point(self, point))
	var target := _press_target
	var tap := _gesture.can_tap() and not cancelled and Rect2(Vector2.ZERO, size).has_point(point)
	if _touch_id >= 0:
		tap = tap and PointerGesture.tap_allowed(self)
	tap = tap and target == ShowcaseHitTest.pick(self, point)
	_cancel_drag()
	_apply_highlight()
	if tap:
		_activate(target)

func _gui_input(event: InputEvent) -> void:
	if not _active or _suspended or event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventScreenTouch:
		if event.pressed and _touch_id == -1:
			_clear_hover()
			_pointer_begin(event.position, event.index)
		elif not event.pressed and event.index == _touch_id:
			_pointer_end(event.position, event.canceled)
		accept_event()
	elif event is InputEventScreenDrag and event.index == _touch_id:
		_pointer_move(event.position, event.relative)
		accept_event()
	elif event is InputEventMouseButton and _touch_id == -1 and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pointer_begin(event.position, -1)
		elif _gesture.active:
			_pointer_end(event.position, event.canceled)
		accept_event()
	elif event is InputEventMouseMotion and _touch_id == -1:
		if _gesture.active:
			_pointer_move(event.position, event.relative)
		else:
			var target := ShowcaseHitTest.pick(self, event.position)
			if target != _hover_target:
				_hover_target = target
				_apply_highlight()
				_notify_interaction()
		accept_event()

func _drag_view(delta: Vector2) -> void:
	_camera_yaw = clampf(_camera_yaw - delta.x * 0.10, -16.0, 16.0)
	_camera_pitch = clampf(_camera_pitch + delta.y * 0.08, -6.0, 6.0)
	_request_frame()

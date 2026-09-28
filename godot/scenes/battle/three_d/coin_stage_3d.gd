class_name CoinStage3D
extends TextureRect

## A transparent stage for a modal coin. It uses the table's physical coin and
## the showcase's timeline; there is no separate modal animation implementation.
var sample_pose: Callable
var viewport: SubViewport
var coin: CoinEntity3D
var camera: Camera3D
var projection := BattleProjection3D.new()
var _suspended := false
var _quality := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	viewport = SubViewport.new()
	viewport.name = "CoinViewport"
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.gui_disable_input = true
	viewport.handle_input_locally = false
	add_child(viewport)
	texture = viewport.get_texture()
	camera = Camera3D.new()
	camera.fov = 14.0
	viewport.add_child(camera)
	camera.make_current()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-58, -28, 0)
	light.light_color = Color("fffaf4")
	light.light_energy = 1.10
	viewport.add_child(light)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.TRANSPARENT
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_energy = 0.0
	viewport.add_child(environment)
	coin = CoinEntity3D.new()
	coin.name = "PhysicalCoin"
	viewport.add_child(coin)
	visibility_changed.connect(_sync_frame)
	RenderingServer.frame_pre_draw.connect(_sync_frame)
	set_process(DisplayServer.get_name() == "headless")
	_sync_frame()


func _process(_delta: float) -> void:
	_sync_frame()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_suspended = true
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_suspended = false
	else:
		return
	_sync_frame()


func _sync_frame() -> void:
	if viewport == null or coin == null or not is_inside_tree():
		return
	var active := is_visible_in_tree() and not _suspended
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE if active else SubViewport.UPDATE_DISABLED
	if not active or size.x < 1.0 or size.y < 1.0:
		return
	var canvas := get_viewport().get_final_transform() * get_global_transform_with_canvas()
	var pixels := Vector2i((size * Vector2(canvas.x.length(), canvas.y.length())).ceil()).max(Vector2i(2, 2))
	if viewport.size != pixels:
		viewport.size = pixels
	var settings := get_node_or_null("/root/AppSettings")
	var quality := str(settings.resolved_quality_profile()) if settings != null else "high"
	if quality != _quality:
		_quality = quality
		viewport.msaa_3d = Viewport.MSAA_4X if quality == "high" else Viewport.MSAA_2X if quality == "medium" else Viewport.MSAA_DISABLED
		viewport.scaling_3d_scale = 1.0 if quality == "high" else 0.85 if quality == "medium" else 0.75
	# Keep the same pixels per world unit as the table. Resizing the modal must
	# not shrink the toss height relative to the coin or crop its airborne edge.
	var distance := 24.0 * tan(deg_to_rad(17.5)) / tan(deg_to_rad(7.0)) * size.y / 900.0
	camera.position = Vector3(0, sin(deg_to_rad(55)), cos(deg_to_rad(55))) * distance
	camera.look_at(Vector3.ZERO)
	projection.configure(camera, viewport, size)
	if sample_pose.is_valid():
		sample_pose.call(coin, projection)

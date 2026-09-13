class_name BattleWorld3D
extends Node3D

const SURFACE_SHADER: Shader = preload("res://scenes/battle/three_d/table_surface.gdshader")
const POOL_LIMIT := 48
var camera: Camera3D
var key_light: DirectionalLight3D
var environment: WorldEnvironment
var projection := BattleProjection3D.new()
var entities: Dictionary = {}
var _pool: Array[CardEntity3D] = []
var _mat: MeshInstance3D
var _trim: MeshInstance3D
var _base_camera_transform := Transform3D.IDENTITY
var quality := "high"
var coin: CoinEntity3D
var feedback: BattleFeedback3D
var reveal_stage: BattleRevealStage3D


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "TableCamera"
	camera.fov = 14.0
	camera.near = 0.1
	camera.far = 100.0
	add_child(camera)
	camera.make_current()
	key_light = DirectionalLight3D.new()
	key_light.name = "Softbox"
	key_light.rotation_degrees = Vector3(-58, -28, 0)
	key_light.light_color = Color("fffaf4")
	key_light.light_energy = 1.10
	key_light.shadow_enabled = true
	key_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	key_light.directional_shadow_max_distance = 90.0
	key_light.shadow_bias = 0.1
	key_light.shadow_normal_bias = 1.0
	add_child(key_light)
	environment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("302b29")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("dbe5ed")
	# Compatibility composites shadowed lights in a separate sRGB pass. Ambient
	# plus that pass washed 50% gray up to 63%. One neutral key preserves ink values.
	environment.environment.ambient_light_energy = 0.0
	add_child(environment)
	var wood := ShaderMaterial.new()
	wood.shader = SURFACE_SHADER
	wood.set_shader_parameter("wood", true)
	wood.set_shader_parameter("base_color", Color("866248"))
	_box("Table", Vector3(85, 0.4, 85), Vector3(0, -0.30, 0), wood)
	var trim_material := StandardMaterial3D.new()
	trim_material.albedo_color = Color("b1986a")
	trim_material.roughness = 0.86
	_trim = _box("MatStitching", Vector3(20, 0.03, 14), Vector3(0, -0.070, 0), trim_material)
	var cloth := ShaderMaterial.new()
	cloth.shader = SURFACE_SHADER
	cloth.set_shader_parameter("base_color", Color("233f4b"))
	_mat = _box("WovenPlaymat", Vector3(19.9, 0.06, 13.9), Vector3(0, -0.043, 0), cloth)
	coin = CoinEntity3D.new()
	coin.name = "PhysicalCoin"
	coin.visible = false
	add_child(coin)
	feedback = BattleFeedback3D.new()
	feedback.name = "ContactFeedback"
	add_child(feedback)
	reveal_stage = BattleRevealStage3D.new()
	reveal_stage.name = "RevealStage"
	add_child(reveal_stage)


func resize(viewport: SubViewport, size_value: Vector2) -> void:
	if camera == null:
		return
	projection.configure(camera, viewport, size_value)
	var compact := size_value.x < 1180.0 or size_value.y < 650.0
	var angle := deg_to_rad(65.0 if compact else 55.0)
	# A longer lens keeps the tabletop framing while reducing the side-card
	# shear and near/far scale changes that worked against a balanced layout.
	var distance := 24.0 * tan(deg_to_rad(35.0 * 0.5)) / tan(deg_to_rad(camera.fov * 0.5))
	camera.position = Vector3(0, sin(angle) * distance, cos(angle) * distance)
	camera.look_at(Vector3.ZERO)
	_base_camera_transform = camera.transform
	var a := projection.screen_to_world(Vector2(size_value.x * 0.025, size_value.y * 0.08))
	var b := projection.screen_to_world(Vector2(size_value.x * 0.975, size_value.y * 0.97))
	var depth := absf(b.z - a.z)
	var width := maxf(absf(a.x), absf(b.x)) * 2.0
	_mat.mesh = _box_mesh(Vector3(width, 0.06, depth))
	_trim.mesh = _box_mesh(Vector3(width + 0.06, 0.035, depth + 0.06))
	_mat.position.z = (a.z + b.z) * 0.5
	_trim.position.z = _mat.position.z


func acquire(key: String) -> CardEntity3D:
	if entities.has(key):
		return entities[key] as CardEntity3D
	var entity: CardEntity3D = _pool.pop_back() if not _pool.is_empty() else CardEntity3D.new()
	if entity.get_parent() == null:
		add_child(entity)
	entity.visual_id = key
	entity.visible = true
	entities[key] = entity
	return entity


func release_entity(key: String) -> void:
	var entity := entities.get(key) as CardEntity3D
	if entity == null:
		return
	entities.erase(key)
	entity.release()
	if _pool.size() < POOL_LIMIT:
		_pool.append(entity)
	else:
		entity.queue_free()


func clear_entities() -> void:
	for key in entities.keys():
		release_entity(str(key))
	if feedback != null:
		feedback.clear()


func apply_quality(profile: String, viewport: SubViewport) -> void:
	quality = profile
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = 1.0 if profile == "high" else 0.85 if profile == "medium" else 0.75
	viewport.msaa_3d = Viewport.MSAA_4X if profile == "high" else Viewport.MSAA_2X if profile == "medium" else Viewport.MSAA_DISABLED
	viewport.positional_shadow_atlas_size = 2048 if profile == "high" else 1024
	key_light.shadow_enabled = profile != "low"
	RenderingServer.directional_shadow_atlas_set_size(2048 if profile == "high" else 1024, true)


func camera_offset(offset: Vector2) -> void:
	if camera == null:
		return
	camera.transform = _base_camera_transform
	camera.position += camera.basis.x * offset.x * 0.002 + camera.basis.y * offset.y * 0.002


func stats() -> Dictionary:
	return {"entities": entities.size(), "pooled": _pool.size(), "quality": quality}


func _box(label: String, dimensions: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var result := MeshInstance3D.new()
	result.name = label
	result.mesh = _box_mesh(dimensions)
	result.material_override = material
	result.position = at
	add_child(result)
	return result


func _box_mesh(dimensions: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	return mesh

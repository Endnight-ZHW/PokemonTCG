class_name CoinEntity3D
extends Node3D

const FONT: Font = preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")
var result_heads := true


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("e2b958")
	material.metallic = 0.45
	material.roughness = 0.38
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.5
	cylinder.bottom_radius = 0.5
	cylinder.height = 0.07
	cylinder.radial_segments = 64
	var body := MeshInstance3D.new()
	body.mesh = cylinder
	body.material_override = material
	add_child(body)
	for side in [1.0, -1.0]:
		var rim := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.444
		torus.outer_radius = 0.471
		torus.rings = 48
		torus.ring_segments = 8
		rim.mesh = torus
		rim.position.y = side * 0.033
		rim.material_override = material
		add_child(rim)
		var label := Label3D.new()
		label.text = "正" if side > 0 else "反"
		label.font = FONT
		label.font_size = 96
		label.pixel_size = 0.006
		label.outline_size = 0
		label.modulate = Color("674b1f")
		label.no_depth_test = false
		label.shaded = true
		label.position.y = side * 0.039
		label.rotation.x = -PI * 0.5 * side
		add_child(label)


func pose_for_toss(projection: BattleProjection3D, screen_center: Vector2, pixel_width: float,
	progress: float, heads: bool, start_heads: bool, reduced: bool) -> void:
	result_heads = heads
	var angle_start := 0.0 if start_heads else PI
	var angle_end := TAU * 8.0 + (0.0 if heads else PI)
	var flip := angle_end if reduced else lerpf(angle_start, angle_end, progress)
	var pose := projection.pose_for_screen(screen_center, pixel_width, 0.0, 0.8, 0.18)
	var rise := sin(minf(progress / 0.82, 1.0) * PI) * 1.1 if not reduced else 0.0
	if progress > 0.82 and not reduced:
		var bounce := (progress - 0.82) / 0.18
		rise = sin(bounce * PI) * (1.0 - bounce) * 0.10
	pose.origin.y += rise
	pose.basis = pose.basis * Basis(Vector3.RIGHT, flip)
	transform = pose
	# Toss poses share the card presenter's late render update.
	for surface in get_children():
		(surface as Node3D).force_update_transform()

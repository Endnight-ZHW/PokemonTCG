extends SceneTree

## Consistent badge presentation and swept-volume clearance, including takeoff/landing.
const OUTPUT := "res://../build/home-fixes"
var failures: Array[String] = []
var minimum_height := INF
var pose_count := 0
var capture_enabled := false

func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok and message not in failures:
		failures.append(message)

func settle() -> void:
	for frame in range(8):
		await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw

func run() -> void:
	capture_enabled = "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1600, 900)
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "reduced"
	settings.quality_profile = "high"
	settings.muted = true
	var main: Variant = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	root.size = Vector2i(1600, 900)
	await settle()
	main.audio_director.play_music("")
	var page := main.screen_host.get_child(0) as TitlePage
	page.showcase_timer.stop()
	var stage := page.card_stage
	for deck_key in ["dragon", "happy4_koraidon", "happy4_miraidon"]:
		page._deck_index = page._deck_keys.find(deck_key)
		page._refresh_featured_deck()
		await settle()
		check(stage._energy_material.albedo_texture == ShowcaseFinishes.badge_for("Dragon"), "Dragon deck did not share the printed badge: " + deck_key)
		capture(deck_key)
	check_dragon_style()
	var obstacles: Array[MeshInstance3D] = [stage._stage, stage.cards[0].body,
		stage._lid_root.get_node("ContinuousLeatherFlap")]
	for part in stage._world.get_node("CardCradle").get_children():
		if part is MeshInstance3D:
			obstacles.append(part)
	for back in stage._backs:
		obstacles.append(back.body)
	var coin := stage._coin
	for opening in [0.0, 35.0, 90.0]:
		stage._set_case_open(opening)
		for start_heads in [true, false]:
			for result_heads in [true, false]:
				coin.heads = start_heads
				coin.begin_toss(result_heads)
				for frame in range(241):
					coin.pose(float(frame) / 240.0)
					pose_count += 1
					for part in coin.get_children():
						if not part is MeshInstance3D or part == coin._shadow:
							continue
						var bounds: AABB = part.global_transform * part.mesh.get_aabb()
						minimum_height = minf(minimum_height, bounds.position.y)
						check(bounds.position.y >= ShowcaseCoin.GROUND_CLEARANCE - 0.0001, "Coin geometry penetrated display mat during toss")
						for obstacle in obstacles:
							var other := obstacle.global_transform * obstacle.mesh.get_aabb()
							if bounds.intersects(other):
								check(not boxes_intersect(part, obstacle), "Coin intersects " + str(obstacle.name))
				check(coin.heads == result_heads and not coin.tossing, "Coin failed to settle to requested face")
	stage._set_case_open(0)
	if capture_enabled:
		for result_heads in [true, false]:
			coin.heads = true
			coin.begin_toss(result_heads)
			for percent in [0, 3, 6, 12, 20, 35, 50, 65, 75, 85, 100]:
				coin.pose(float(percent) / 100.0)
				await settle()
				capture("coin-%s-%03d" % ["heads" if result_heads else "tails", percent])
		coin.pose(1.0)
		await capture_badge_closeup(stage)
	var report := {"poses": pose_count, "minimum_coin_height": minimum_height, "failures": failures}
	var file := FileAccess.open(OUTPUT.path_join("clearance.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("HOME_PROP_CLEARANCE_OK poses=", pose_count, " min_height=", minimum_height)
	main.free()
	# Allow the audio mixer to release its stopped stream before engine teardown.
	await create_timer(0.06).timeout
	quit(0 if failures.is_empty() else 1)

func check_dragon_style() -> void:
	var badge := ShowcaseFinishes.badge_for("Dragon").get_image()
	check(badge.get_size() == Vector2i(256, 256), "Dragon badge must have the same native resolution as other attributes")
	var bounds := badge.get_used_rect()
	var water_bounds := EnergyIconCatalog.texture_for("Water").get_image().get_used_rect()
	check(Vector2(bounds.position).distance_to(Vector2(water_bounds.position)) <= 3.0
		and Vector2(bounds.size).distance_to(Vector2(water_bounds.size)) <= 4.0,
		"Dragon badge padding/diameter differs from the other attribute globes")
	for corner in [Vector2i.ZERO, Vector2i(255, 0), Vector2i(0, 255), Vector2i(255, 255)]:
		check(badge.get_pixelv(corner).a == 0, "Dragon badge has an opaque rectangular background")
	var dark_pixels := 0
	for y in range(256):
		for x in range(256):
			var pixel := badge.get_pixel(x, y)
			if pixel.a > 0.9 and maxf(pixel.r, maxf(pixel.g, pixel.b)) < 0.1:
				dark_pixels += 1
	check(dark_pixels > 9000 and dark_pixels < 20000, "Dragon symbol scale/contrast changed substantially")

func capture(label: String) -> void:
	if capture_enabled:
		check(root.get_texture().get_image().save_png(OUTPUT.path_join(label + ".png")) == OK, "Could not capture " + label)

func capture_badge_closeup(stage: FrontendCardShowcase3D) -> void:
	var target := stage._case_root.to_global(Vector3(-0.45, 1.79, ShowcaseCaseGeometry.FRONT))
	stage.camera.position = target + stage._case_root.basis * Vector3(0, 0.12, 1.3)
	stage.camera.look_at(target)
	await settle()
	capture("dragon-badge-closeup")

func boxes_intersect(a: MeshInstance3D, b: MeshInstance3D) -> bool:
	var box_a := a.mesh.get_aabb()
	var box_b := b.mesh.get_aabb()
	var pose_a := a.global_transform
	var pose_b := b.global_transform
	var axes_a := [pose_a.basis.x, pose_a.basis.y, pose_a.basis.z]
	var axes_b := [pose_b.basis.x, pose_b.basis.y, pose_b.basis.z]
	var axes: Array = axes_a + axes_b
	for x: Vector3 in axes_a:
		for y: Vector3 in axes_b:
			axes.append(x.cross(y))
	var delta := pose_b * box_b.get_center() - pose_a * box_a.get_center()
	for axis: Vector3 in axes:
		if axis.length_squared() < 0.000001:
			continue
		axis = axis.normalized()
		var radius := 0.0
		for index in range(3):
			radius += absf(axis.dot(axes_a[index])) * box_a.size[index] * 0.5
			radius += absf(axis.dot(axes_b[index])) * box_b.size[index] * 0.5
		if absf(axis.dot(delta)) >= radius - 0.0001:
			return false
	return true

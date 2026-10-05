extends SceneTree

## Real pointer routes, interruption boundaries, and review captures for the title.
const OUTPUT := "res://../build/home-redesign/after"
var failures: Array[String] = []
var main: Variant
var page: TitlePage
var stage: FrontendCardShowcase3D
var settings: Node
var capture_enabled := false

func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value and message not in failures:
		failures.append(message)

func settle(frames: int = 8) -> void:
	for frame in range(frames):
		await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw

func screen_point(local: Vector2) -> Vector2:
	return root.get_final_transform() * stage.get_global_transform_with_canvas() * local

func project(world: Vector3) -> Vector2:
	return stage.camera.unproject_position(world) * stage.size / Vector2(stage.viewport.size)

func target_point(target: String) -> Vector2:
	match target:
		"case": return project(stage._case_root.to_global(Vector3(0, 1.2, ShowcaseCaseGeometry.DEPTH * 0.5)))
		"card": return project(stage.cards[0].global_position)
		"coin": return project(stage._coin.global_position)
	return Vector2(15, 15)

func mouse_button(at: Vector2, pressed: bool, cancelled: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = at
	event.global_position = at
	event.pressed = pressed
	event.canceled = cancelled
	root.push_input(event)

func move_mouse(at: Vector2, relative: Vector2 = Vector2.ZERO, down: bool = false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	root.push_input(event)

func tap(target: String, touch: bool = false) -> void:
	var local := target_point(target)
	check(ShowcaseHitTest.pick(stage, local) == target, "Ray missed visible " + target)
	var at := screen_point(local)
	if touch:
		var press := InputEventScreenTouch.new()
		press.position = at
		press.pressed = true
		Input.parse_input_event(press)
		await settle(2)
		var release := InputEventScreenTouch.new()
		release.position = at
		Input.parse_input_event(release)
	else:
		mouse_button(at, true)
		await settle(2)
		mouse_button(at, false)
	await settle(3)

func capture(label: String) -> void:
	if not capture_enabled:
		return
	await settle(4)
	check(root.get_texture().get_image().save_png(OUTPUT.path_join(label + ".png")) == OK, "Failed capture " + label)

func run() -> void:
	Input.use_accumulated_input = false
	capture_enabled = "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1600, 900)
	settings = root.get_node("AppSettings")
	settings.animation_mode = "reduced"
	settings.quality_profile = "high"
	settings.muted = true
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	root.size = Vector2i(1600, 900)
	await settle(12)
	main.audio_director.play_music("")
	page = main.screen_host.get_child(0)
	stage = page.card_stage
	page._deck_index = page._deck_keys.find("water")
	page._refresh_featured_deck()
	await settle(12)
	check(is_equal_approx(page.showcase_timer.wait_time, 12.0), "Rotation interval changed")
	await capture("title")
	# A paused decorative scene must retain the artwork and pose through a direct lightbox.
	for yaw in [-16.0, 0.0, 16.0]:
		stage._camera_yaw = yaw
		stage._request_frame()
		await settle()
		for target in ["case", "card", "coin"]:
			check(ShowcaseHitTest.pick(stage, target_point(target)) == target, "Projected target lost at yaw " + str(yaw) + ": " + target)
	stage._camera_yaw = 0
	stage._request_frame()
	await settle()
	await tap("case")
	check(stage._lid_angle == 90 and page.showcase_timer.paused, "Click did not open the case and pause rotation")
	await capture("case-open")
	for angle in [0.0, 35.0, 90.0]:
		stage._set_case_open(angle)
		stage._lid_target = angle
		await settle()
		check_open_framing()
		await capture("case-angle-" + str(int(angle)))
	await tap("case", true)
	check(stage._lid_angle == 0, "Touch did not close the case exactly once")
	var before_yaw := stage._camera_yaw
	await tap("card")
	check(main.modal_layer.visible and main.modal_body.get_child(0) is CardArtPanel, "Card did not open direct artwork")
	check(stage.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Lightbox did not suspend scene rendering")
	await capture("card-art")
	main.modal_host_controller.handle_back()
	await settle()
	check(not main.modal_layer.visible and stage._camera_yaw == before_yaw, "Back changed title pose")
	await tap("card", true)
	check(main.modal_layer.visible, "Touch did not open artwork")
	mouse_button(Vector2(8, 8), true)
	mouse_button(Vector2(8, 8), false)
	await settle()
	check(not main.modal_layer.visible, "Shade click did not close direct artwork")
	await tap("card")
	main.modal_confirm.pressed.emit()
	await settle()
	check(not main.modal_layer.visible, "Close button did not close artwork")
	# A gesture starting on a card/box becomes a view drag, never a delayed tap.
	for target in ["case", "card"]:
		var start := screen_point(target_point(target))
		mouse_button(start, true)
		move_mouse(start + Vector2(80, 0), Vector2(80, 0), true)
		mouse_button(start + Vector2(80, 0), false)
		await settle()
		check(stage._lid_angle == 0 and not main.modal_layer.visible, "Drag activated " + target)
	stage._camera_yaw = 0
	stage._request_frame()
	await settle()
	move_mouse(screen_point(target_point("case")))
	await settle()
	check(page.showcase_timer.paused, "Hover did not hold the current deck")
	move_mouse(Vector2(5, 5))
	await settle()
	check(not page.showcase_timer.paused and page.showcase_timer.time_left > 11, "Leaving hover did not restart idle timer")
	# Real-time action interruption, reversal, and duplicate-activation suppression.
	settings.animation_mode = "standard"
	settings.changed.emit()
	await tap("case")
	await create_timer(0.09).timeout
	var partial := stage._lid_angle
	check(partial > 0 and partial < 90, "Opening did not animate")
	await tap("case")
	await create_timer(0.4).timeout
	check(is_zero_approx(stage._lid_angle), "Mid-animation reversal did not close")
	await tap("coin")
	var rng_state := stage._cosmetic_rng.state
	check(stage._coin.tossing and page.showcase_timer.paused, "Coin toss did not hold rotation")
	await tap("coin")
	check(stage._cosmetic_rng.state == rng_state, "Repeated toss consumed RNG while already tossing")
	await capture("coin-toss")
	await create_timer(0.85).timeout
	check(not stage._coin.tossing, "Coin did not settle")
	await tap("coin")
	stage.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	page.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(not stage._coin.tossing and not stage._gesture.active, "Focus loss retained transient action")
	check(stage.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Focus loss retained rendering")
	stage.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	page.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	await settle()
	await tap("case")
	main._show_settings()
	await settle()
	check(stage._lid_angle == 90 and stage.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Modal interruption did not settle open case")
	main.modal_host_controller.close()
	await create_timer(0.2).timeout
	check(stage._lid_angle == 90 and page.showcase_timer.paused, "Closing settings reset open case")
	stage._toggle_case()
	await create_timer(0.4).timeout
	stage._clear_hover()
	await settle()
	var key := page.featured_deck_key()
	await page._rotate_random_deck()
	await create_timer(0.5).timeout
	check(page.featured_deck_key() != key and not page._transitioning, "Prepared texture transition did not finish")
	check(stage.cards[0].face_texture != null, "Deck transition left blank art")
	# Visibility alone must cancel a pending swap, including independent previews.
	var before_hidden := page.featured_deck_key()
	await page._rotate_random_deck()
	check(page._transitioning, "Hidden-page fixture did not begin a transition")
	page.hide()
	check(not page._transitioning and is_equal_approx(stage.modulate.a, 1.0),
		"Hiding the title retained its pending deck transition")
	await create_timer(0.4).timeout
	check(page.featured_deck_key() == before_hidden, "Hidden title rotated to a different deck")
	page.show()
	await settle()
	check(not page.showcase_timer.paused and page.showcase_timer.time_left > 11,
		"Showing the title did not restart its idle interval")
	await page._rotate_random_deck()
	main._show_help()
	await create_timer(0.4).timeout
	check(not page._transitioning and is_equal_approx(stage.modulate.a, 1), "Covered transition retained partial opacity")
	main.modal_host_controller.close()
	await create_timer(0.2).timeout
	# Reduced/low retain functional actions without time-dependent geometry.
	for quality in ["high", "low"]:
		settings.animation_mode = "reduced" if quality == "high" else "standard"
		settings.quality_profile = quality
		settings.changed.emit()
		await tap("case")
		check(stage._lid_angle == 90, "Reduced/low open not immediate")
		await tap("case")
		check(stage._lid_angle == 0, "Reduced/low close not immediate")
		await tap("coin")
		check(not stage._coin.tossing, "Reduced/low retained flying coin")
	await capture("title-low")
	settings.quality_profile = "high"
	settings.animation_mode = "reduced"
	settings.changed.emit()
	page._deck_index = page._deck_keys.find("water")
	page._refresh_featured_deck()
	await settle()
	# Genuine pointer down state plus a normal/hover/pressed visual fixture.
	settings.animation_mode = "standard"
	settings.changed.emit()
	var button := page.get_node("%AIButton") as Button
	var point := root.get_final_transform() * button.get_global_rect().get_center()
	move_mouse(point)
	await capture("button-hover")
	mouse_button(point, true)
	await settle(2)
	check(button.get_draw_mode() in [BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED], "Menu did not enter pressed state")
	await capture("button-pressed")
	move_mouse(Vector2(5, 5), Vector2(5, 5) - point, true)
	mouse_button(Vector2(5, 5), false)
	await settle()
	if main.screen_host.get_child(0) != page:
		check(false, "Cancelled menu press navigated")
		finish()
		return
	settings.animation_mode = "reduced"
	settings.changed.emit()
	for dimensions in [Vector2i(1024, 768), Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2000, 900), Vector2i(640, 540)]:
		root.size = dimensions
		await settle(12)
		var coin_canvas := root.get_final_transform() * stage.get_global_transform_with_canvas()
		var coin_screen := screen_point(target_point("coin"))
		var minimum_target_point := coin_canvas.affine_inverse() * (coin_screen + Vector2(22, 22))
		check(ShowcaseHitTest.pick(stage, minimum_target_point) == "coin",
			"Coin target shrank below 48 physical pixels at " + str(dimensions))
		await capture("title-%dx%d" % [dimensions.x, dimensions.y])
		stage._set_case_open(90)
		stage._lid_target = 90
		await settle()
		for yaw in [-16.0, 16.0]:
			for pitch in [-6.0, 6.0]:
				stage._camera_yaw = yaw
				stage._camera_pitch = pitch
				stage._request_frame()
				await settle(2)
				check_open_framing()
		stage._camera_yaw = 0
		stage._camera_pitch = 0
		stage._request_frame()
		await capture("open-%dx%d" % [dimensions.x, dimensions.y])
		stage._lid_target = 0
		stage._set_case_open(0)
	root.size = Vector2i(1600, 900)
	await settle()
	for index in range(page._deck_keys.size()):
		page._deck_index = index
		page._refresh_featured_deck()
		await settle(12)
		await capture("deck-" + page.featured_deck_key())
	finish()

func check_open_framing() -> void:
	var mesh := stage._lid_root.get_node("ContinuousLeatherFlap") as MeshInstance3D
	var bounds := Rect2(Vector2(1, 1), stage.size - Vector2(2, 2))
	for vertex in mesh.mesh.get_faces():
		check(bounds.has_point(project(mesh.global_transform * vertex)), "Open lid escaped viewport at " + str(root.size))
	var packet := stage._case_root.get_node("InnerCardPacket") as CardEntity3D
	check(packet.paper_layers == 60, "Case interior is missing its combined card packet")
	check(packet.transform.origin.y - CardEntity3D.ASPECT * 1.34 * 0.5 > ShowcaseCaseGeometry.WALL, "Interior cards pierce case floor")

func finish() -> void:
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("HOME_INTERACTION_CONTRACT_OK")
	main.free()
	# Stopped audio playback is released on the mixer thread, not synchronously.
	await create_timer(0.06).timeout
	quit(0 if failures.is_empty() else 1)

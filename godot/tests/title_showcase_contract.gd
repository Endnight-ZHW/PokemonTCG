extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func settle() -> void:
	for frame in range(8):
		await process_frame

func run() -> void:
	Input.use_accumulated_input = false
	root.size = Vector2i(1600, 900)
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "reduced"
	var main: Variant = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await settle()
	var page: Variant = main.screen_host.get_child(0)
	var catalog := CardCatalog.shared()
	var keys := DeckVisualCatalog.ordered_deck_keys(catalog)
	var initial_key: String = page.featured_deck_key()
	page.showcase_timer.stop()
	check(page.find_child("BrandSubtitle", true, false) == null, "Removed brand subtitle returned")
	for index in range(keys.size()):
		page._deck_index = index
		page._refresh_featured_deck()
		var key: String = page.featured_deck_key()
		check(key in keys, "Showcase used an unpublished deck")
		var stage: Variant = page.card_stage
		check(stage.card_ids == [DeckVisualCatalog.representative_card(catalog, key)], "Featured art did not follow the selected deck")
		check(page.card_stage._name_plate.text == str(catalog.get_deck(key).name), "Deck name did not follow the artwork")
		for yaw in [-16.0, 0.0, 16.0]:
			stage._camera_yaw = yaw
			stage._request_frame()
			await settle()
			var body: AABB = stage._stage.global_transform * stage._stage.mesh.get_aabb()
			var hero: AABB = stage.cards[0].body.global_transform * stage.cards[0].body.mesh.get_aabb()
			check(not body.grow(0.02).intersects(hero), "Featured card intersects the case: " + key)
			check(hero.position.y >= 0.12, "Featured card penetrates its support")
			for back in stage._backs:
				var bounds: AABB = back.body.global_transform * back.body.mesh.get_aabb()
				check(not body.intersects(bounds) and not hero.intersects(bounds), "Loose cards intersect the display solids")
			for part in stage._world.get_node("CardCradle").get_children():
				if part is MeshInstance3D:
					check(not oriented_boxes_intersect(stage.cards[0].body, part),
						"Card penetrates cradle part: " + str(part.name))
			var flap: MeshInstance3D = stage._lid_root.get_node("ContinuousLeatherFlap")
			check(not (flap.global_transform * flap.mesh.get_aabb()).intersects(hero),
				"Card intersects the folded cover")
	check_case_construction(page.card_stage)
	page._deck_index = keys.find(initial_key)
	page._refresh_featured_deck()
	for attempt in range(30):
		var previous_key: String = page.featured_deck_key()
		page._rotate_random_deck()
		check(page.featured_deck_key() != previous_key, "Random rotation repeated the same deck")
	check(page.find_child("PreviousDeckButton", true, false) == null
		and page.find_child("NextDeckButton", true, false) == null, "Manual deck switching controls returned")
	check(page.find_child("InspectDeckButton", true, false) == null
		and page.find_child("RotateViewButton", true, false) == null
		and page.find_child("HeroCaption", true, false) == null
		and page.card_stage.mouse_filter == Control.MOUSE_FILTER_STOP,
		"The simplified display retained buttons or duplicate copy")
	var displayed_key: String = page.featured_deck_key()
	page.showcase_timer.start()
	(page.get_node("%SettingsButton") as Button).pressed.emit()
	await settle()
	check(main.modal_layer.visible and page.showcase_timer.paused,
		"Opening a modal did not pause random rotation")
	page._rotate_random_deck()
	check(page.featured_deck_key() == displayed_key, "Covered showcase changed decks")
	check(page.card_stage.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"Covered showcase kept rendering")
	main.modal_host_controller.close()
	await settle()
	check(page.featured_deck_key() == displayed_key and not page.showcase_timer.paused,
		"Closing a modal reset the display or left rotation paused")
	page._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	page._rotate_random_deck()
	check(page.showcase_timer.paused and page.featured_deck_key() == displayed_key,
		"Background application kept rotating decks")
	page._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	check(not page.showcase_timer.paused, "Returning to the app left rotation paused")
	page.card_stage._set_dragging(true)
	var drag_key: String = page.featured_deck_key()
	page._rotate_random_deck()
	check(page.showcase_timer.paused and page.featured_deck_key() == drag_key, "Dragging did not pause random rotation")
	page.card_stage._drag_view(Vector2(-10000, 10000))
	check(is_equal_approx(page.card_stage._camera_yaw, 16.0) and is_equal_approx(page.card_stage._camera_pitch, 6.0), "Drag exceeded the framing bounds")
	page.card_stage._set_dragging(false)
	check(not page.showcase_timer.paused and page.showcase_timer.time_left > 7.5, "Releasing drag did not restart the rotation interval")
	await check_pointer_drag(page)
	main.free()
	await settle()
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("TITLE_SHOWCASE_CONTRACT_OK decks=", keys.size(), " views=3")
	quit(0 if failures.is_empty() else 1)


func check_case_construction(stage: Variant) -> void:
	# Cast through the actual body triangles. A closed solid masquerading as a
	# box must fail: the first surface under the mouth is the interior floor.
	var faces: PackedVector3Array = stage._stage.mesh.get_faces()
	var highest := -INF
	for i in range(0, faces.size(), 3):
		var hit: Variant = Geometry3D.segment_intersects_triangle(Vector3(0.07, 2.4, 0.05), Vector3(0.07, -0.1, 0.05), faces[i], faces[i + 1], faces[i + 2])
		if hit != null:
			highest = maxf(highest, hit.y)
	check(is_equal_approx(highest, ShowcaseCaseGeometry.WALL), "Case mouth is capped or its interior floor is missing")
	for opening in [0.0, 35.0, 90.0]:
		stage._set_case_open(opening)
		var vertices: PackedVector3Array = stage._case_hinge.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for side in [-1.0, 1.0]:
			var lid_endpoint: Vector3 = stage._lid_root.to_global(Vector3(side * ShowcaseCaseGeometry.LID_WIDTH * 0.5, 0, 0))
			var distance := INF
			for vertex in vertices:
				distance = minf(distance, lid_endpoint.distance_to(stage._case_hinge.to_global(vertex)))
			check(distance < 0.00005, "Lid separated from the rear hinge at %d degrees" % int(opening))
	stage._set_case_open(0)
	var lid: MeshInstance3D = stage._lid_root.get_node("ContinuousLeatherFlap")
	var lid_faces := lid.mesh.get_faces()
	for rim_point in [Vector3(0.885, 0, 0), Vector3(0.50, 0, 0.669)]:
		var lowest := INF
		for i in range(0, lid_faces.size(), 3):
			var a: Vector3 = stage._lid_root.transform * lid_faces[i]
			var b: Vector3 = stage._lid_root.transform * lid_faces[i + 1]
			var c: Vector3 = stage._lid_root.transform * lid_faces[i + 2]
			var hit: Variant = Geometry3D.segment_intersects_triangle(rim_point, rim_point + Vector3.UP * 2.4, a, b, c)
			if hit != null:
				lowest = minf(lowest, hit.y)
		check(lowest >= ShowcaseCaseGeometry.HEIGHT - 0.0001 and lowest <= ShowcaseCaseGeometry.HEIGHT + 0.003,
			"Closed lid penetrates or floats above the case rim")


## Separating-axis test in mesh space: world AABBs alone falsely overlap the
## inclined card and its supporting rails. These solids have orthogonal bases.
func oriented_boxes_intersect(a: MeshInstance3D, b: MeshInstance3D) -> bool:
	var box_a := a.mesh.get_aabb()
	var box_b := b.mesh.get_aabb()
	var pose_a := a.global_transform
	var pose_b := b.global_transform
	var axes_a := [pose_a.basis.x, pose_a.basis.y, pose_a.basis.z]
	var axes_b := [pose_b.basis.x, pose_b.basis.y, pose_b.basis.z]
	var axes: Array = axes_a + axes_b
	for axis_a: Vector3 in axes_a:
		for axis_b: Vector3 in axes_b:
			axes.append(axis_a.cross(axis_b))
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


func check_pointer_drag(page: Variant) -> void:
	var stage: Control = page.card_stage
	var point := root.get_final_transform() * stage.get_global_rect().get_center()
	for touch_mode in [false, true]:
		page.card_stage._camera_yaw = 0.0
		page.card_stage._camera_pitch = 0.0
		if touch_mode:
			var touch := InputEventScreenTouch.new()
			touch.pressed = true
			touch.position = point
			Input.parse_input_event(touch)
		var press := InputEventMouseButton.new()
		press.device = InputEvent.DEVICE_ID_EMULATION if touch_mode else 0
		press.button_index = MOUSE_BUTTON_LEFT
		press.button_mask = MOUSE_BUTTON_MASK_LEFT
		press.pressed = true
		press.position = point
		root.push_input(press)
		await settle()
		check(page.card_stage.is_interacting() and page.showcase_timer.paused, "Pointer press did not capture the showcase")
		if touch_mode:
			var drag := InputEventScreenDrag.new()
			drag.position = point + Vector2(90, 0)
			drag.relative = Vector2(90, 0)
			Input.parse_input_event(drag)
		var move := InputEventMouseMotion.new()
		move.device = InputEvent.DEVICE_ID_EMULATION if touch_mode else 0
		move.position = point + Vector2(90, 0)
		move.relative = Vector2(90, 0)
		move.button_mask = MOUSE_BUTTON_MASK_LEFT
		root.push_input(move)
		await settle()
		check(is_equal_approx(page.card_stage._camera_yaw, -9.0) and page.showcase_timer.paused,
			"Mouse/touch drag was cancelled or applied twice")
		if touch_mode:
			var release := InputEventScreenTouch.new()
			release.pressed = false
			release.position = point + Vector2(90, 0)
			Input.parse_input_event(release)
		press.pressed = false
		press.button_mask = 0
		press.position = point + Vector2(90, 0)
		root.push_input(press)
		await settle()
		check(not page.card_stage.is_interacting() and not page.showcase_timer.paused,
			"Pointer release left showcase rotation suspended")

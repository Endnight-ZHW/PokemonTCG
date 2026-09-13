extends RefCounted

static func run(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var report := {"shuffle_samples": 0, "hand_action_cases": 0, "max_handoff_gap_px": 0.0}
	var old_size := tree.root.size
	var old_scale := tree.root.content_scale_size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../build/battle3d-shuffle-hand-fixes"))
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540), Vector2i(2000, 900)]:
		tree.root.size = dimensions
		tree.root.content_scale_size = dimensions
		await _hand_actions(tree, table, check, report, dimensions)
		if dimensions.x in [900, 1600]: await _shuffle(tree, table, check, report, dimensions)
		if dimensions.x == 900:
			table.offset_left = 32
			table.offset_top = 32
			table.offset_right = -32
			table.offset_bottom = -32
			await _hand_actions(tree, table, check, report, Vector2i(836, 476))
			table.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tree.root.size = old_size
	tree.root.content_scale_size = old_scale
	table.update_view(UIPreviewStateFactory.battle_state(), 0, [], "", false, "local")
	for frame in range(4): await tree.process_frame
	return report

static func _hand_actions(tree: SceneTree, table: BattleTable, check: Callable, report: Dictionary, dimensions: Vector2i) -> void:
	for count in [5, 20]:
		var state := UIPreviewStateFactory.battle_stress_state()
		state.players[0].hand.clear()
		var rows: Array[Dictionary] = []
		for index in range(count):
			state.players[0].hand.append("sv1-151")
			rows.append({"action": GameAction.create("PLAY_TRAINER", {}, 0, EntityRef.new("card", 0, "hand", "", index, "", "sv1-151")), "label": "使用"})
		for index in [0, count / 2, count - 1]:
			table.update_view(state, 0, rows, "hand:%d" % index, false, "local")
			for frame in range(14): await tree.process_frame
			await RenderingServer.frame_post_draw
			var popover := table.action_popover
			var card := table.hand_views[index]
			var bounds := card.visual_global_bounds()
			var panel := popover.panel_global_rect()
			check.call(popover.visible and popover.current_placement == "compact_above", "Hand actions moved to the side of the selected card")
			check.call(absf(panel.end.y + popover.anchor_gap - bounds.position.y) < 1.0, "Hand actions do not follow the selected card's top edge")
			check.call(popover._safe_rect.encloses(panel), "Hand actions are clipped at the safe-area edge")
			check.call(not panel.intersects(bounds) and panel.size.y <= 72, "Hand toolbar covers the card or includes the old oversized title block")
			var button := popover.compact_action_buttons.get_child(0) as Button
			check.call(button != null and button.size.y >= 48 and button.size.x >= 48, "Hand use button is smaller than the touch target")
			var expected_x := clampf(bounds.get_center().x - panel.size.x * 0.5, popover._safe_rect.position.x, popover._safe_rect.end.x - panel.size.x)
			check.call(absf(panel.position.x - expected_x) < 1.0, "Hand action anchor drifts as occupied bench slots change")
			if count == 5 and index == count / 2:
				tree.root.get_texture().get_image().save_png("res://../build/battle3d-shuffle-hand-fixes/hand-actions-%dx%d.png" % [dimensions.x, dimensions.y])
				var chosen: Array[GameAction] = []
				popover.action_chosen.connect(func(action: GameAction) -> void: chosen.append(action), CONNECT_ONE_SHOT)
				var point := button.get_global_rect().get_center()
				var move := InputEventMouseMotion.new()
				move.position = point
				tree.root.push_input(move, true)
				await tree.process_frame
				check.call(tree.root.gui_get_hovered_control() == button, "A hand use button cannot be reached through the overlay")
				for pressed in [true, false]:
					var click := InputEventMouseButton.new()
					click.position = point
					click.button_index = MOUSE_BUTTON_LEFT
					click.pressed = pressed
					tree.root.push_input(click, true)
				await tree.process_frame
				check.call(chosen.size() == 1 and chosen[0].hand_index() == index, "Hand use button loses or duplicates its selected-card action")
			report.hand_action_cases += 1
	# Moving from a hand card to the field must restore the full action panel.
	table.update_view(UIPreviewStateFactory.battle_state(), 0, UIPreviewStateFactory.action_rows(UIPreviewStateFactory.battle_state()), "pokemon:0:active", false, "local")
	for frame in range(4): await tree.process_frame
	check.call(table.action_popover.title_label.get_parent().visible, "Hand toolbar mode leaked into a field-card action panel")
	table.action_popover.dismiss(false)

static func _shuffle(tree: SceneTree, table: BattleTable, check: Callable, report: Dictionary, dimensions: Vector2i) -> void:
	table.update_view(UIPreviewStateFactory.battle_state(), 0, [], "", false, "local")
	for frame in range(5): await tree.process_frame
	for card_count in [1, 2, 7, 60]:
		for side in ["own_deck", "opponent_deck"]:
			var zone := table.zones[side] as ZoneView
			zone.configure("牌库", "", card_count, true)
			var packets: Array[CardMotionEntity] = []
			var count := mini(6, card_count)
			for index in range(count):
				var packet := table.motion_entities._create_paper_card_token(CardEntity3D.BACK, Vector2(100, 140), "CardMotionEntity", 110 + index) as CardMotionEntity
				packet.set_meta("shuffle_source_zone", zone)
				table.card_motion_layer.add(packet)
				table.card_motion_layer._retain_shuffle_source_zone(zone, packet)
				packets.append(packet)
			for frame in range(61):
				var progress := float(frame) / 60.0
				for index in range(count): BattleShuffle3D.apply(progress, packets[index], table.render3d, index, count)
				# Sample every pose for geometry; rasterize the key contacts too.
				# Full animation timing is covered by the startup visual contract.
				if frame % 10 == 0:
					await tree.process_frame
					await RenderingServer.frame_post_draw
				else: table.render3d.sync_surfaces()
				var layers := 0.0
				for packet in packets:
					var physical := packet.physical_entity
					check.call(physical != null and physical.visible and physical.face_down and physical.face_texture == null, "Shuffle exposes a face or loses its physical packet")
					if physical == null: continue
					layers += physical.paper_layers
					check.call(Rect2(Vector2.ZERO, table.size).encloses(table.render3d.world.projection.project_bounds(physical)), "Shuffle packet leaves the rendered viewport")
					var dock := table.render3d.global_bounds(zone)
					var to_global := table.get_global_transform_with_canvas()
					check.call(dock.grow(dock.size.x * 0.22).encloses(to_global * table.render3d.world.projection.project_bounds(physical)), "Quick shuffle moves too far outside its deck dock")
				check.call(is_equal_approx(layers, card_count), "Shuffle creates or loses visible paper thickness")
				for first in range(count):
					for second in range(first + 1, count):
						check.call(not _intersects(packets[first], packets[second]), "Shuffle packets intersect during insertion")
				if dimensions.x == 1600 and card_count == 60 and side == "own_deck" and frame in [0, 20, 30, 40, 48, 60]:
					tree.root.get_texture().get_image().save_png("res://../build/battle3d-shuffle-hand-fixes/shuffle-%02d.png" % frame)
				report.shuffle_samples += 1
			# The interleaved slices fill the full volume at contact.
			var volume := Rect2()
			for index in range(count):
				var bounds := table.render3d.world.projection.project_bounds(packets[index].physical_entity)
				volume = bounds if index == 0 else volume.merge(bounds)
				table.card_motion_layer._finish_shuffle_card(packets[index], Vector2.ZERO)
			for packet in packets: table.motion_entities._dispose_flyer(packet)
			await tree.process_frame
			await RenderingServer.frame_post_draw
			var settled := table.render3d.global_bounds(zone)
			var gap := maxf(volume.position.distance_to(settled.position), volume.end.distance_to(settled.end))
			report.max_handoff_gap_px = maxf(report.max_handoff_gap_px, gap)
			check.call(gap < 2.0 and table._shuffle_source_masks.is_empty(), "Shuffle changes volume or leaves the deck hidden at handoff")
	table.clear_presentation_for_resync()

static func _intersects(first: CardMotionEntity, second: CardMotionEntity) -> bool:
	var a := first.world_pose
	var b := second.world_pose
	var half_a := Vector3(0.5, CardEntity3D.THICKNESS * float(first.get_meta("shuffle_paper_layers")) * 0.5, CardEntity3D.ASPECT * 0.5)
	var half_b := Vector3(0.5, CardEntity3D.THICKNESS * float(second.get_meta("shuffle_paper_layers")) * 0.5, CardEntity3D.ASPECT * 0.5)
	var axes: Array[Vector3] = [a.basis.x, a.basis.y, a.basis.z, b.basis.x, b.basis.y, b.basis.z]
	for i in range(3):
		for j in range(3): axes.append(a.basis[i].cross(b.basis[j]))
	for value in axes:
		if value.length_squared() < 0.000001: continue
		var axis := value.normalized()
		var radius := 0.0
		for i in range(3): radius += absf(axis.dot(a.basis[i])) * half_a[i] + absf(axis.dot(b.basis[i])) * half_b[i]
		if absf(axis.dot(b.origin - a.origin)) >= radius - 0.002: return false
	return true

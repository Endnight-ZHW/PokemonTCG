extends RefCounted


static func run(table: BattleTable, expect: Callable) -> void:
	var presenter := table.render3d
	var projection := presenter.world.projection
	var active := table.own_active
	var center := active.global_center()
	active.set_presentation_hidden(true)
	presenter.sync_surfaces()
	expect.call(not active.contains_visual_global_point(center), "Masked card still accepts input through the touch fallback")
	active.set_presentation_hidden(false)
	active.set_drag_masked(true)
	presenter.sync_surfaces()
	expect.call(not active.contains_visual_global_point(center), "Drag source remains clickable after visual ownership transfers")
	active.set_drag_masked(false)
	presenter.sync_surfaces()
	var prizes := table.zones["own_prizes"] as ZoneView
	var top := presenter.world.entities[presenter._key(prizes, str(prizes.count - 1))] as CardEntity3D
	var top_center := table.get_global_transform_with_canvas() * projection.world_to_screen(top.global_position)
	var local_point := prizes.get_global_transform_with_canvas().affine_inverse() * top_center
	expect.call(prizes._prize_index_at_point(local_point) == prizes.count - 1, "Prize click selects a covered card instead of the visible physical layer")
	var prize_bounds := presenter.global_bounds(prizes)
	var capacity_width := prizes.get_global_transform_with_canvas().basis_xform(Vector2(prizes.size.x, 0)).length()
	expect.call(prize_bounds.has_point(top_center) and prize_bounds.size.x < capacity_width,
		"Prize input bounds still reserve missing cards: %s / %s" % [prize_bounds, capacity_width])
	prizes.set_stack_presentation_hidden(true)
	presenter.sync_surfaces()
	expect.call(not prizes._has_point(local_point), "Masked prize stack still accepts input")
	prizes.set_stack_presentation_hidden(false)
	presenter.sync_surfaces()
	var hand := table.hand_views[0] as CardView
	var original_position := hand.position
	hand.position.x = -hand.size.x * 2.0
	presenter.sync_surfaces()
	var fan_bounds := hand.visual_global_bounds()
	var allowed_fan := table.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, table.size)
	expect.call(allowed_fan.encloses(fan_bounds), "Browsing clips the end card instead of fitting the circular fan")
	expect.call(hand.contains_visual_global_point(hand.global_center()), "Visible fan end cannot be selected after browsing")
	hand.position = original_position
	presenter.sync_surfaces()
	# Public presentation must also mask badge nodes created by a state refresh.
	presenter._mask_hud(active, true)
	var late_badge := Label.new()
	late_badge.text = "new status"
	active.content_root.add_child(late_badge)
	presenter._mask_hud(active, true)
	expect.call(late_badge.self_modulate.a == 0.0, "A rebuilt HUD badge leaks over the public showcase")
	presenter._mask_hud(active, false)
	expect.call(late_badge.self_modulate.a == 1.0, "Showcase mask does not restore newly created HUD badges")
	late_badge.queue_free()
	# A cancelled press must not inspect a zone when its captured release arrives.
	var activations: Array[int] = []
	var on_prize := func(index: int) -> void: activations.append(index)
	prizes.stack_index_activated.connect(on_prize)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = local_point
	prizes._on_gui_input(press)
	table.cancel_pointer_gestures()
	press.pressed = false
	prizes._on_gui_input(press)
	expect.call(activations.is_empty(), "Cancelled zone press activates on a late release")
	prizes.stack_index_activated.disconnect(on_prize)
	_check_zone_motion(table, expect)


static func _check_zone_motion(table: BattleTable, expect: Callable) -> void:
	var presenter := table.render3d
	var projection := presenter.world.projection
	var from_table := table.effects.get_global_transform_with_canvas().affine_inverse() * table.get_global_transform_with_canvas()
	var deck := table.zones["own_deck"] as ZoneView
	var deck_entity := presenter.world.entities[presenter._key(deck, str(mini(deck.count, 6) - 1))] as CardEntity3D
	var start := from_table * projection.world_to_screen(deck_entity.global_position)
	var prizes := table.zones["own_prizes"] as ZoneView
	var finishes: Array[Vector3] = []
	for index in range(prizes.count):
		var target := presenter.world.entities[presenter._key(prizes, str(index))] as CardEntity3D
		var finish := from_table * projection.world_to_screen(target.global_position)
		var flyer := table.card_motion_layer._spawn_card_motion_spec({
			"texture": CardEntity3D.BACK, "start": start, "finish": finish,
			"duration": 10.0, "event_type": "cards_drawn", "source_zone": deck,
			"start_size": deck.get_stack_face_size(), "finish_size": prizes.get_stack_face_size(),
			"landing_view": prizes,
		}, "", "") as CardMotionEntity
		table.motion_entities._update_physical_flyer(0.0, flyer, start, finish, flyer.size, flyer.size, 0.0, 0.0, 0.0)
		expect.call(flyer.source_pose.is_equal_approx(deck_entity.transform), "Draw starts at a different pose from its visible pile")
		table.motion_entities._update_physical_flyer(1.0, flyer, start, finish, flyer.size, flyer.size, 0.0, 0.0, 0.0)
		expect.call(flyer.world_pose.is_equal_approx(target.transform), "Prize flight snaps at contact with its physical destination")
		for previous in finishes:
			expect.call(previous.distance_to(flyer.world_pose.origin) > 0.01, "Incoming prize cards collapse into the same landing slot")
		finishes.append(flyer.world_pose.origin)
	table.motion_entities._clear_active_flyers()


static func check_layouts(table: BattleTable, expect: Callable) -> void:
	var tree := table.get_tree()
	var fixture := UIPreviewStateFactory.battle_stress_state()
	table.update_view(fixture, 0, UIPreviewStateFactory.action_rows(fixture), "", false, "local")
	var presenter := table.render3d
	for resolution in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540), Vector2i(2000, 900)]:
		tree.root.size = resolution
		for frame in range(5):
			await tree.process_frame
		presenter.sync_surfaces()
		for card in [table.own_active, table.opponent_active]:
			var overlay := card.battle_overlay as CardBattleOverlay
			var hud: Array[Control] = [overlay.hp_pill, overlay.damage_badge, overlay.tool_badge]
			for child in overlay.energy_row.get_children() + card.status_row.get_children():
				if child.visible:
					hud.append(child)
			for i in range(hud.size()):
				for j in range(i + 1, hud.size()):
					var a := overlay._control_visual_global_rect(hud[i]).grow(-0.5)
					var b := overlay._control_visual_global_rect(hud[j]).grow(-0.5)
					expect.call(not a.intersects(b), "Projected HUD overlaps at %s: %s / %s" % [resolution, hud[i].name, hud[j].name])
			var tool_visible := false
			var attachment_count := 0
			for key in presenter._anchors[card.get_instance_id()].keys:
				if ":attachment:" not in str(key):
					continue
				var entity := presenter.world.entities[key] as CardEntity3D
				if not entity.visible:
					continue
				attachment_count += 1
				tool_visible = tool_visible or entity.visual_id == card.pokemon.attached_tool_id
				var bounds := table.get_global_transform_with_canvas() * presenter.world.projection.project_bounds(entity)
				for bench in table.slot_views.values():
					if (bench as CardView).slot.begins_with("bench"):
						expect.call(not bounds.intersects((bench as CardView).visual_global_bounds()), "Attachment geometry covers a bench card at %s" % resolution)
			expect.call(attachment_count <= 6 and tool_visible, "Dense attachments omitted the tool or exceeded their budget")
		var allowed := table.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, table.size)
		for zone in table.zones.values():
			expect.call(allowed.grow(2).encloses(presenter.global_bounds(zone)), "A physical pile leaves the table at %s" % resolution)
		var prizes := table.zones["own_prizes"] as ZoneView
		for index in range(prizes.count):
			var entity := presenter.world.entities[presenter._key(prizes, str(index))] as CardEntity3D
			var point := presenter.world.projection.world_to_screen(entity.global_transform * Vector3(-0.43, CardEntity3D.THICKNESS * 0.5, 0))
			var global_point := table.get_global_transform_with_canvas() * point
			expect.call(presenter.prize_index_at_global_point(prizes, global_point) == index, "Exposed prize edge selects the wrong physical index at %s" % resolution)
	var stadium := table.zones["stadium"] as ZoneView
	stadium.configure("竞技场", "", 0)
	stadium.set_drop_highlight(true)
	presenter.sync_surfaces()
	var empty_surface := presenter.world.entities[presenter._key(stadium, "0")] as CardEntity3D
	expect.call(empty_surface.visible and not empty_surface.body.visible and empty_surface.outline.visible, "Empty stadium has no physical drop outline")
	var empty_center := presenter.global_bounds(stadium).get_center()
	expect.call(presenter.contains_global_point(stadium, empty_center), "Empty physical stadium does not accept its drop target")

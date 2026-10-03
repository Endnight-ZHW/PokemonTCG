extends RefCounted

## Exercise complete presentation transactions, including the handoff frame.
## A close-up card must remain registered after leaving its showcase parent.
static func check_transfers(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var settings := tree.root.get_node("AppSettings")
	var report := {"cases": [], "cancelled_cases": 0}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../build/battle3d-transfer-fixes"))
	for mode in ["standard", "fast", "reduced"]:
		settings.animation_mode = mode
		for kind in ["search", "opponent_search", "recover", "energy", "energy_opponent", "energy_transfer"]:
			report.cases.append(await _transaction(tree, table, check, kind, mode))
	settings.animation_mode = "standard"
	for phase in ["display", "flight"]:
		await _cancel(tree, table, check, phase)
		report.cancelled_cases += 1
	await _resize_transfer(tree, table, check)
	report["resized_in_flight"] = true
	return report

static func _fixture(kind: String) -> Dictionary:
	var before := UIPreviewStateFactory.battle_state()
	before.revision = 800
	var actor := 1 if kind in ["opponent_search", "energy_opponent"] else 0
	before.players[actor].hand.assign(["sv1-151", "sv1-170", "svf-potion", "svi-chim", "sv1-ener-1"])
	var after := before.clone_state()
	after.revision += 1
	var event: Dictionary
	if kind in ["energy", "energy_opponent"]:
		after.players[actor].hand.pop_back()
		after.players[actor].active.energy_card_ids.append("sv1-ener-1")
		event = {"event_type": "energy_attached", "actor": actor, "card_id": "sv1-ener-1",
			"source": {"player": actor, "zone": "hand", "index": 4},
			"target": {"player": actor, "slot": "active", "attachment_type": "energy"},
			"data": {"player": actor, "card_id": "sv1-ener-1"}}
	elif kind == "energy_transfer":
		var card_id: String = after.players[0].active.energy_card_ids.pop_back()
		var source_index := after.players[0].active.energy_card_ids.size()
		after.players[0].bench[0].energy_card_ids.append(card_id)
		event = {"event_type": "energy_attached", "actor": 0, "card_id": card_id, "amount": 1,
			"source": {"player": 0, "slot": "active", "attachment_type": "energy", "index": source_index, "attachment_card_id": card_id},
			"target": {"player": 0, "slot": "bench_0", "attachment_type": "energy"},
			"data": {"player": 0, "card_id": card_id}}
	else:
		var cards: Array[String] = ["sv1-ener-1", "sv1-ener-1", "svi-chim"]
		if kind == "recover": before.players[actor].discard.append_array(cards)
		after.players[actor].hand.append_array(cards)
		event = {"event_type": "card_moved" if kind == "recover" else "cards_selected", "actor": actor, "visibility": "public", "amount": cards.size(),
			"source": {"player": actor, "zone": "discard" if kind == "recover" else "deck"}, "target": {"player": actor, "zone": "hand"},
			"data": {"player": actor, "count": cards.size(), "card_ids": cards}}
	return {"before": before, "after": after, "event": event, "actor": actor}

static func _transaction(tree: SceneTree, table: BattleTable, check: Callable, kind: String, mode: String) -> Dictionary:
	var fixture := _fixture(kind)
	var event: Dictionary = fixture.event
	event.event_id = "transfer:%s:%s" % [kind, mode]
	table.update_view(fixture.before, 0, [], "", false, "local")
	for frame in range(5): await tree.process_frame
	var old_ids: Array[String] = []
	for card in table.hand_views:
		if card.visible: old_ids.append(card.local_visual_id)
	var request := BattleTransitionRequest.create(BattleViewModel.capture(fixture.after, 0, [], "", false, "local"), [event], fixture.actor, BattleTransitionRequest.CAUSE_REFRESH, event.event_id)
	var handle := table.submit_transition(request)
	var report := {"kind": kind, "mode": mode, "frames": 0, "moving_samples": 0, "handoffs": 0, "max_landing_gap_px": 0.0}
	var landings: Dictionary = {}
	var photographed := false
	var projection := table.render3d.world.projection
	while not handle.is_completed() and report.frames < 360:
		await tree.process_frame
		await RenderingServer.frame_post_draw
		report.frames += 1
		for token in table.card_motion_layer.entities:
			var flyer := token as CardMotionEntity
			if flyer == null or not flyer.has_world_pose: continue
			var landing := flyer.get_meta("motion_landing_view") as Control if flyer.has_meta("motion_landing_view") else null
			var complete := bool(flyer.get_meta("motion_completed", false))
			if complete:
				check.call(not flyer.visible and flyer.modulate.a == 0, "%s: a completed flyer overlaps its permanent card" % kind)
				if not landings.has(flyer.get_instance_id()):
					if landing is CardView and (landing as CardView).hand_index >= 0:
						var contact := projection.project_pose_bounds(flyer.world_pose)
						var receiver := projection.project_pose_bounds(table.render3d.card_pose(landing as CardView))
						var gap := maxf(contact.position.distance_to(receiver.position), contact.end.distance_to(receiver.end))
						report.max_landing_gap_px = maxf(report.max_landing_gap_px, gap)
						check.call(gap < 2.0, "%s: flyer does not meet its hand card on the contact frame" % kind)
					landings[flyer.get_instance_id()] = {"pose": flyer.world_pose, "index": (landing as CardView).hand_index if landing is CardView else int(landing.get_meta("snapshot_opponent_hand_index", -1)) if landing != null else -1}
					report.handoffs += 1
				continue
			if not flyer.visible: continue
			report.moving_samples += 1
			check.call(table.render3d._anchors.has(flyer.get_instance_id()), "%s: moving card lost its render registration" % kind)
			var physical := flyer.physical_entity
			check.call(physical != null and physical.visible and physical.body.visible, "%s: moving card has no visible 3D mesh" % kind)
			if physical == null: continue
			check.call(physical.position.distance_to(flyer.world_pose.origin) < 0.001, "%s: rendered card lags behind its animation" % kind)
			if flyer.target_pose == Transform3D.IDENTITY: continue # Reserved showcase card waiting for launch.
			var bounds := projection.project_pose_bounds(flyer.world_pose)
			var start_bounds := projection.project_pose_bounds(flyer.source_pose)
			var end_bounds := projection.project_pose_bounds(flyer.target_pose)
			check.call(bounds.size.x >= minf(start_bounds.size.x, end_bounds.size.x) * 0.85, "%s: card collapses into an icon during flight" % kind)
			check.call(bounds.size.x <= maxf(start_bounds.size.x, end_bounds.size.x) * 1.15, "%s: card balloons during depth interpolation" % kind)
			if kind.begins_with("energy"):
				check.call(not bool(flyer.get_meta("motion_flip_to_attachment_badge", false)), "3D energy still morphs into a HUD badge")
				check.call(flyer.texture == CardEntity3D.BACK or flyer.texture == table.card_motion_layer._texture_for_card_id(str(event.card_id)), "Energy flight replaced the printed card with an icon")
				check.call(landing != null and table.render3d._shown(landing), "Attaching energy makes the destination Pokemon disappear")
				if landing is CardView and landing in table.presentation_runtime.slot_covers.values():
					var original := table.get_slot_view((landing as CardView).owner_player, (landing as CardView).slot)
					var underlying := table.render3d.world.entities.get(table.render3d._key(original)) as CardEntity3D
					check.call(underlying != null and not underlying.visible, "Final attached energy is rendered before its flyer lands")
					check.call(original.battle_overlay.energy_row.self_modulate.a == 0, "Final energy counter appears before contact")
			if not photographed and mode == "standard" and report.moving_samples >= 8:
				tree.root.get_texture().get_image().save_png("res://../build/battle3d-transfer-fixes/%s-flight.png" % kind)
				photographed = true
	check.call(handle.is_completed(), "%s/%s: transaction did not finish" % [kind, mode])
	check.call(table.card_motion_layer.active_motion_count() == 0, "%s: completion leaves motion entities behind" % kind)
	check.call(not table.reveal_layer.is_presenting(), "%s: completion leaves the reveal panel active" % kind)
	if mode != "reduced":
		check.call(report.moving_samples > 0 and report.handoffs > 0, "%s: contract did not observe flight and contact" % kind)
	for frame in range(3): await tree.process_frame
	var hands := table.hand_views if fixture.actor == 0 else table.opponent_hand_views
	var visible_hands: Array = hands.filter(func(card: CardView) -> bool: return card.visible)
	check.call(visible_hands.size() == fixture.after.players[fixture.actor].hand.size(), "%s: final hand count differs from the rules" % kind)
	if not kind.begins_with("energy"):
		for row in landings.values():
			if int(row.index) < 0 or int(row.index) >= hands.size(): continue
			var finish := projection.project_pose_bounds(table.render3d.card_pose(hands[row.index]))
			var contact := projection.project_pose_bounds(row.pose)
			var gap := maxf(finish.position.distance_to(contact.position), finish.end.distance_to(contact.end))
			report.max_landing_gap_px = maxf(report.max_landing_gap_px, gap)
			check.call(gap < 2.0, "%s: arrival jumps from its landing pose into the hand" % kind)
		for old_id in old_ids:
			check.call(table.hand_views.any(func(card: CardView) -> bool: return card.visible and card.local_visual_id == old_id), "%s: duplicate incoming cards replace an existing visual identity" % kind)
	if fixture.actor == 1:
		for card in visible_hands:
			var physical := table.render3d.world.entities.get(table.render3d._key(card)) as CardEntity3D
			check.call(card.is_hidden_card and physical != null and physical.face_down and physical.face_texture == null, "Public opponent search leaves a private hand face exposed")
	if mode == "standard":
		await RenderingServer.frame_post_draw
		tree.root.get_texture().get_image().save_png("res://../build/battle3d-transfer-fixes/%s-settled.png" % kind)
	table.clear_presentation_for_resync()
	return report

static func _cancel(tree: SceneTree, table: BattleTable, check: Callable, phase: String) -> void:
	var fixture := _fixture("search")
	fixture.event.event_id = "transfer:cancel:" + phase
	table.update_view(fixture.before, 0, [], "", false, "local")
	for frame in range(5): await tree.process_frame
	var handle := table.submit_transition(BattleTransitionRequest.create(BattleViewModel.capture(fixture.after, 0, [], "", false, "local"), [fixture.event], 0, BattleTransitionRequest.CAUSE_REFRESH, fixture.event.event_id))
	var reached := false
	for frame in range(240):
		await tree.process_frame
		await RenderingServer.frame_post_draw
		if phase == "display": reached = table.reveal_layer.is_presenting() and frame >= 12
		else: reached = table.card_motion_layer.entities.any(func(card: Control) -> bool: return card.has_meta("reveal_transferred") and card.visible)
		if reached: break
	check.call(reached, "Cancellation check did not reach reveal " + phase)
	table.clear_presentation_for_resync()
	table.update_view(fixture.after, 0, [], "", false, "local")
	for frame in range(6): await tree.process_frame
	await RenderingServer.frame_post_draw
	check.call(handle.is_completed(), "Resync leaves a reveal transaction pending")
	check.call(table.card_motion_layer.active_motion_count() == 0 and not table.reveal_layer.is_presenting(), "Cancelling reveal " + phase + " leaks a flight or panel")
	for card in table.hand_views:
		check.call(not card.is_presentation_hidden() and card.modulate.a > 0.99, "Cancelling reveal leaves a hand card masked")

static func _resize_transfer(tree: SceneTree, table: BattleTable, check: Callable) -> void:
	var fixture := _fixture("search")
	fixture.event.event_id = "transfer:resize"
	table.update_view(fixture.before, 0, [], "", false, "local")
	for frame in range(5): await tree.process_frame
	var old_size := tree.root.size
	var old_scale := tree.root.content_scale_size
	var handle := table.submit_transition(BattleTransitionRequest.create(BattleViewModel.capture(fixture.after, 0, [], "", false, "local"), [fixture.event], 0, BattleTransitionRequest.CAUSE_REFRESH, fixture.event.event_id))
	var resized := false
	for frame in range(300):
		await tree.process_frame
		await RenderingServer.frame_post_draw
		if not resized and table.card_motion_layer.entities.any(func(card: Control) -> bool: return bool(card.get_meta("motion_completed", false))):
			tree.root.size = Vector2i(900, 540)
			tree.root.content_scale_size = Vector2i(900, 540)
			resized = true
		if handle.is_completed(): break
	check.call(resized and handle.is_completed(), "Resizing a partially landed reveal prevents completion")
	check.call(table.card_motion_layer.active_motion_count() == 0, "Resizing the reveal leaves motion cards behind")
	for frame in range(5): await tree.process_frame
	await RenderingServer.frame_post_draw
	tree.root.get_texture().get_image().save_png("res://../build/battle3d-transfer-fixes/search-resized.png")
	tree.root.size = old_size
	tree.root.content_scale_size = old_scale
	for frame in range(5): await tree.process_frame


static func check_shuffle_actions(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
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
					var inside_dock := dock.grow(dock.size.x * 0.22).encloses(to_global * table.render3d.world.projection.project_bounds(physical))
					if not inside_dock and not report.has("first_dock_overflow"):
						report["first_dock_overflow"] = {"screen": str(dimensions), "count": card_count, "side": side, "progress": progress, "packet": packet.get_meta("shuffle_packet_index"), "dock": str(dock), "bounds": str(to_global * table.render3d.world.projection.project_bounds(physical))}
					check.call(inside_dock, "Quick shuffle moves too far outside its deck dock")
				check.call(is_equal_approx(layers, card_count), "Shuffle creates or loses visible paper thickness")
				for first in range(count):
					for second in range(first + 1, count):
						var overlap := _intersects(packets[first], packets[second])
						if overlap and not report.has("first_overlap"):
							report["first_overlap"] = {"screen": str(dimensions), "count": card_count, "side": side, "progress": progress, "pair": [first, second]}
						check.call(not overlap, "Shuffle packets intersect during insertion")
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

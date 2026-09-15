extends RefCounted

## Exercise complete presentation transactions, including the handoff frame.
## A close-up card must remain registered after leaving its showcase parent.
static func run(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
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

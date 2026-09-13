extends RefCounted

static func run(tree: SceneTree, table: BattleTable, check: Callable, actor: int = 0) -> Dictionary:
	if actor == 0: await _check_retained_hand(tree, table, check)
	var before := UIPreviewStateFactory.battle_state()
	before.revision = 700
	before.players[actor].hand.clear()
	before.players[actor].deck.clear()
	for index in range(60): before.players[actor].deck.append("sv1-151")
	var after := before.clone_state()
	after.revision += 1
	var drawn: Array[String] = []
	for index in range(7):
		drawn.append(after.players[actor].deck.pop_back())
		after.players[actor].hand.append(drawn[-1])
	table.update_view(before, 0, [], "", false, "local")
	for frame in range(5): await tree.process_frame
	var target := BattleViewModel.capture(after, 0, [], "", false, "local")
	var event_id := "seven-card-draw:%d" % actor
	var event := {"event_type": "cards_drawn", "event_id": event_id, "actor": actor,
		"visibility": "owner", "source": {"player": actor, "zone": "deck"}, "target": {"player": actor, "zone": "hand"},
		"data": {"player": actor, "visibility_owner": actor, "count": 7, "card_ids": drawn, "purpose": "opening_hand", "final_opening_hand": true}}
	var handle := table.submit_transition(BattleTransitionRequest.create(target, [event], actor,
		BattleTransitionRequest.CAUSE_REFRESH, event_id))
	var frames := 0
	var moving := 0
	var delayed := 0
	var max_start_gap := 0.0
	while not handle.is_completed() and frames < 240:
		await tree.process_frame
		await RenderingServer.frame_post_draw
		frames += 1
		for control in table.card_motion_layer.entities:
			var flyer := control as CardMotionEntity
			if flyer == null or not flyer.has_meta("physical_start_pose"): continue
			if not flyer.visible:
				delayed += 1
				continue
			if bool(flyer.get_meta("motion_completed", false)): continue
			moving += 1
			check.call(flyer.has_world_pose and flyer.physical_entity != null, "A drawing card has no physical pose")
			if flyer.physical_entity == null: continue
			check.call(flyer.physical_entity.position.distance_to(flyer.world_pose.origin) < 0.001,
				"Rendered flight lags behind the current animation frame")
			check.call(flyer.physical_entity.paper_layers == 1.0, "Drawing lifts an entire decorative deck packet")
			var source: Transform3D = flyer.get_meta("physical_start_pose")
			var deck_pose := table.render3d.zone_pose(table.zones["own_deck" if actor == 0 else "opponent_deck"])
			max_start_gap = maxf(max_start_gap, source.origin.distance_to(deck_pose.origin))
		for proxy in table.hand_presentation._presentation_opponent_hand_proxies:
			var card := proxy as CardMotionEntity
			check.call(card.has_world_pose, "Opponent hand adoption discards the physical landing pose")
			check.call(card.world_pose.origin.length() > 0.5, "An opponent hand proxy travels through the table origin")
		if frames in [1, 6, 12, 18, 24, 36]:
			var prefix := "battle3d-draw" if actor == 0 else "battle3d-opponent-draw"
			tree.root.get_texture().get_image().save_png("res://../build/%s-%02d.png" % [prefix, frames])
	check.call(handle.is_completed() and moving > 0 and delayed > 0, "Seven-card draw did not exercise staggered physical flights")
	check.call(max_start_gap < 0.05, "Drawing starts away from the visible deck top")
	check.call(table.card_motion_layer.active_motion_count() == 0, "Draw completion leaves a motion entity alive")
	var hands := table.hand_views if actor == 0 else table.opponent_hand_views
	check.call(hands.filter(func(card: CardView) -> bool: return card.visible).size() == 7, "Opening draw loses a hand card")
	return {"frames": frames, "moving_samples": moving, "queued_samples": delayed, "max_start_gap": max_start_gap}

static func _check_retained_hand(tree: SceneTree, table: BattleTable, check: Callable) -> void:
	var before := UIPreviewStateFactory.battle_state()
	table.update_view(before, 0, [], "", false, "local")
	for frame in range(4): await tree.process_frame
	var snapshot := table.capture_presentation_snapshot()
	var after := before.clone_state()
	after.players[0].hand.append("sv1-151")
	table.update_view(after, 0, [], "", false, "local")
	table.hand_presentation._stage_hand_transition_geometry(snapshot)
	for row in snapshot.hand:
		for card in table.hand_views:
			if card.visible and card.local_visual_id == str(row.visual_id):
				check.call(table.render3d.card_pose(card).is_equal_approx(row.world_pose),
					"Staging an incoming card changes a retained hand card's pose")
	table.hand_presentation._tween_hand_to_stage_count(after.players[0].hand.size(), 0.12)
	await tree.create_timer(0.16).timeout
	for card in table.hand_views:
		check.call(not card.has_meta("physical_pose"), "Hand reflow leaves a frozen physical pose")
	table.clear_presentation_for_resync()

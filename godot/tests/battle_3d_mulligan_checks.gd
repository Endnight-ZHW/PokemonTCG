extends RefCounted

static func run(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var session := AuthoritativeSession.new("3d-mulligan-contract")
	var started := session.start_match("fire", "water", 2026071608, 0)
	check.call(started.success and session.state.mulligan_count[0] == 3, "Repeated mulligan fixture is unavailable")
	var report := {"rounds": 3, "perspectives": 2, "frames": 0, "pose_gap_px": 0.0, "reveals": 0, "opponent_card_width": 1000.0}
	var settings := tree.root.get_node("AppSettings")
	for viewer in [0, 1]:
		table.clear_presentation_for_resync()
		settings.animation_mode = "standard"
		var before := GameState.new()
		for player in before.players:
			for index in range(60): player.deck.append("sv1-151")
		table.update_view(before, viewer, [], "", false, "challenge")
		for frame in range(4): await tree.process_frame
		var target := BattleViewModel.capture(session.state, viewer, [], "", false, "challenge")
		var events := started.events.duplicate(true)
		for index in range(events.size()): events[index]["event_id"] = "mulligan-view:%d:%d" % [viewer, index]
		var handle := table.submit_transition(BattleTransitionRequest.create(target, events, 0, BattleTransitionRequest.CAUSE_REFRESH, "mulligan:%d" % viewer))
		var frames := 0
		var captured: Array[Transform3D] = []
		var identities: Array = []
		var last_phase := ""
		while not handle.is_completed() and frames < 1600:
			await tree.process_frame
			await RenderingServer.frame_post_draw
			frames += 1
			var row: Dictionary = table.render3d.mulligan.hands.get(0, {})
			if row.is_empty(): continue
			if row.phase != last_phase:
				if row.phase == "cards_revealed":
					report.reveals += 1
					check.call(identities == row.cards.map(func(card: CardMotionEntity) -> int: return card.get_instance_id()), "Mulligan reveal replaces the drawn hand's visual identities")
				if row.phase == "cards_drawn": identities = row.cards.map(func(card: CardMotionEntity) -> int: return card.get_instance_id())
				last_phase = row.phase
			for card in row.cards:
				if viewer == 1 and row.phase == "cards_drawn":
					check.call(card.texture == CardEntity3D.BACK, "Opponent mulligan exposes a private face before the public reveal")
				if not card.visible: continue
				check.call(card.has_world_pose and card.physical_entity != null, "Mulligan falls back to a 2D hand surface")
			if row.phase == "cards_revealed" and row.progress > 0.45:
				captured.assign(row.cards.map(func(card: CardMotionEntity) -> Transform3D: return card.world_pose))
				if row.progress < 0.49:
					tree.root.get_texture().get_image().save_png("res://../build/battle3d-mulligan-view%d.png" % viewer)
		report.frames += frames
		check.call(handle.is_completed() and table.render3d.mulligan.hands.is_empty(), "Repeated mulligan leaves its presentation or private entities alive")
		check.call(table.render3d.mulligan.public_reveal.labels == null, "Mulligan leaves its public display labels alive")
		check.call(not table.header._task_hint_override.begins_with("再战"), "Mulligan hint remains after the opening hand settles")
		var final_cards := table.hand_views if viewer == 0 else table.opponent_hand_views
		check.call(captured.size() == 7, "Mulligan never displayed all seven cards")
		for index in range(captured.size()):
			var projection := table.render3d.world.projection
			var a := projection.project_pose_bounds(captured[index])
			if viewer == 1:
				report.opponent_card_width = minf(report.opponent_card_width, a.size.x)
				check.call(a.size.x >= 150, "Opponent mulligan still reveals unreadable hand-sized thumbnails")
				for other in range(index):
					check.call(not a.intersects(projection.project_pose_bounds(captured[other])), "Opponent mulligan hides one revealed card behind another")
				continue
			var b := projection.project_pose_bounds(table.render3d.card_pose(final_cards[index]))
			var gap := maxf(a.position.distance_to(b.position), a.end.distance_to(b.end))
			report.pose_gap_px = maxf(report.pose_gap_px, gap)
			check.call(gap < 1.0, "Mulligan hand size, curvature or orientation differs from the normal hand")
	# Interrupt while private temporary cards exist, including reduced mode.
	table.update_view(session.state, 0, [], "", false, "local")
	for frame in range(4): await tree.process_frame
	for reduced in [false, true]:
		settings.animation_mode = "reduced" if reduced else "standard"
		var event: Dictionary = started.events.filter(func(value: Dictionary) -> bool: return BattleMulligan3D.handles(value) and value.event_type == "cards_drawn")[0]
		var motion := table.render3d.mulligan.play(PresentationEvent.for_player(event, table.view_player), 0.4)
		await tree.process_frame
		table.set_local_hand_privacy_hidden(true)
		table.render3d.sync_surfaces()
		for actor in table.render3d.mulligan.hands:
			if actor != table.view_player: continue
			for card in table.render3d.mulligan.hands[actor].cards:
				check.call(not card.visible, "Handoff privacy curtain does not hide the intermediate hand")
		table.clear_presentation_for_resync()
		table.set_local_hand_privacy_hidden(false)
		check.call(motion.is_finished() and table.render3d.mulligan.hands.is_empty(), "Resync does not cancel the intermediate opening hand")
	settings.animation_mode = "standard"
	return report

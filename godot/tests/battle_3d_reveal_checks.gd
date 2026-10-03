extends RefCounted

## Opening hands and public reveals share the same table fixtures.

static func check_draw(tree: SceneTree, table: BattleTable, check: Callable, actor: int = 0) -> Dictionary:
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


static func check_mulligan(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
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


static func check_mulligan_readability(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var report := {"cases": 0, "min_card_width": 1000.0, "return_handoffs": 0}
	var old_size := tree.root.size
	var old_scale := tree.root.content_scale_size
	var settings := tree.root.get_node("AppSettings")
	var ids: Array[String] = ["sv1-ener-2", "sv1-151", "sv1-189", "svf-potion", "sv1-ener-2", "sv1-170", "sv1-ener-3"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../build/battle3d-localization-mulligan-fixes"))
	for dimensions in [Vector2i(1600, 900), Vector2i(900, 540)]:
		tree.root.size = dimensions
		tree.root.content_scale_size = dimensions
		for mode in ["standard", "fast", "reduced"]:
			settings.animation_mode = mode
			table.update_view(UIPreviewStateFactory.battle_state(), 1, [], "", false, "local")
			for frame in range(5): await tree.process_frame
			var draw := table.render3d.mulligan.play({"event_type": "cards_drawn", "actor": 0, "data": {"count": 7, "purpose": "mulligan_redraw", "card_ids": ids}}, 0.25)
			while not draw.is_finished(): await tree.process_frame
			var before: Dictionary = table.render3d.mulligan.hands[0]
			for card in before.cards:
				check.call(card.texture == CardEntity3D.BACK, "Opponent redraw exposes private faces before the reveal")
			var identity: Array = before.cards.map(func(card: CardMotionEntity) -> int: return card.get_instance_id())
			var reveal := table.render3d.mulligan.play({"event_type": "cards_revealed", "actor": 0, "visibility": "public", "data": {"purpose": "mulligan", "cards": ids}}, 0.5)
			await tree.create_timer(0.65).timeout
			await RenderingServer.frame_post_draw
			var row: Dictionary = table.render3d.mulligan.hands[0]
			check.call(not reveal.is_finished() and float(row.duration) >= 2.8, "Seven public cards have no readable hold")
			check.call(identity == row.cards.map(func(card: CardMotionEntity) -> int: return card.get_instance_id()), "Public mulligan replaces its existing 3D hand entities")
			var display := table.render3d.mulligan.public_reveal
			check.call(Rect2(Vector2.ZERO, table.size).encloses(display.panel_rect), "Mulligan reveal panel is clipped")
			var bounds: Array[Rect2] = []
			for index in range(row.cards.size()):
				var card := row.cards[index] as CardMotionEntity
				var rect := table.render3d.world.projection.project_pose_bounds(card.world_pose)
				report.min_card_width = minf(report.min_card_width, rect.size.x)
				check.call(rect.size.x >= 100.0 and display.panel_rect.encloses(rect), "Opponent revealed cards are too small or leave the display")
				for previous in bounds: check.call(not previous.intersects(rect), "Public mulligan cards overlap")
				bounds.append(rect)
				check.call(card.texture == table.card_motion_layer._texture_for_card_id(ids[index]), "Public mulligan displays the wrong face")
				check.call(display.captions[index].text == table.catalog.card_name(ids[index]), "Public card caption does not match its face")
				check.call(display.captions[index].position.y >= rect.end.y + 1, "Public card caption covers its artwork")
			if mode == "standard": tree.root.get_texture().get_image().save_png("res://../build/battle3d-localization-mulligan-fixes/opponent-reveal-%dx%d.png" % [dimensions.x, dimensions.y])
			if mode == "standard" and dimensions.x == 1600:
				while not reveal.is_finished(): await tree.process_frame
				var returning := table.render3d.mulligan.play({"event_type": "card_moved", "actor": 0, "data": {"purpose": "mulligan_return", "card_ids": ids}}, 0.3)
				while not returning.is_finished():
					await tree.process_frame
					await RenderingServer.frame_post_draw
					var current: Dictionary = table.render3d.mulligan.hands.get(0, {})
					for card in current.get("cards", []):
						if not card.visible: report.return_handoffs += 1
				check.call(report.return_handoffs > 0, "Returned mulligan cards keep overlapping the deck during later arrivals")
			# Cancellation during the public display must release labels, faces,
			# backdrop and queue barriers, including reduced-motion presentations.
			table.clear_presentation_for_resync()
			for frame in range(3): await tree.process_frame
			check.call(reveal.is_finished() and table.render3d.mulligan.hands.is_empty() and display.labels == null, "Cancelled mulligan leaves public/private presentation objects alive")
			check.call(not table.render3d.world.reveal_stage.visible, "Cancelled mulligan leaves its backdrop visible")
			report.cases += 1
	settings.animation_mode = "standard"
	tree.root.size = old_size
	tree.root.content_scale_size = old_scale
	for frame in range(4): await tree.process_frame
	return report


static func check_search_reveal(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var report := {"cases": 0, "min_card_width": 1000.0}
	var original_size := tree.root.size
	var original_scale := tree.root.content_scale_size
	var state := UIPreviewStateFactory.battle_state()
	table.header.set_task_hint("")
	table.update_view(state, 0, UIPreviewStateFactory.action_rows(state), "", false, "local")
	for frame in range(4): await tree.process_frame
	for count in [0, 1, 2, 7]:
		var rows: Array[Dictionary] = []
		var faces: Array[Texture2D] = []
		for index in range(count):
			var card_id := "sv1-151" if index % 2 == 0 else "svi-chim"
			rows.append({"card_id": card_id, "matched": true, "outcome_label": "加入手牌"})
			faces.append(table.card_motion_layer._texture_for_card_id(card_id))
		table.reveal_layer.present(rows, CardEntity3D.BACK, faces, table.size * Vector2(0.8, 0.8),
			Rect2(Vector2.ZERO, table.size), {"kind": "public_selection", "title": "公开检索结果"}, 10.0, true)
		for resolution in [Vector2i(1600, 900), Vector2i(900, 540), Vector2i(2000, 900)]:
			tree.root.content_scale_size = resolution
			tree.root.size = resolution
			for frame in range(10): await tree.process_frame
			await RenderingServer.frame_post_draw
			var frame := table.reveal_layer.presentation_frame()
			check.call(table.render3d.world.reveal_stage.visible, "Public reveal has no unified physical backdrop")
			var to_table := table.get_global_transform_with_canvas().affine_inverse() * table.reveal_layer.get_global_transform_with_canvas()
			var panel_rect: Rect2 = to_table * Rect2(frame.panel_rect)
			check.call(Rect2(Vector2.ZERO, table.size).encloses(panel_rect), "Search result panel is cropped after resizing")
			for hud in [table.opponent_info, table.opponent_hand_count_badge]:
				var hud_rect: Rect2 = table.get_global_transform_with_canvas().affine_inverse() * hud.get_global_rect()
				check.call(not panel_rect.intersects(hud_rect) or hud.self_modulate.a == 0, "Opponent HUD overlaps the search result panel")
			var showcase := table.reveal_layer._showcase
			for token in showcase.get_meta("reveal_cards", []):
				var entity := table.render3d.world.entities.get(table.render3d._key(token)) as CardEntity3D
				check.call(entity != null and entity.visible and entity.body.visible, "Reveal card was lost behind its backdrop")
				if entity == null: continue
				var bounds := table.render3d.world.projection.project_bounds(entity)
				check.call(panel_rect.encloses(bounds), "Reveal card exceeds its display panel")
				var badge := token.get_node("OutcomeBadge") as Control
				var badge_rect := table.get_global_transform_with_canvas().affine_inverse() * badge.get_global_rect()
				check.call(badge_rect.position.y >= bounds.end.y + 6, "Search outcome badge obscures the card artwork")
				if count <= 2:
					report.min_card_width = minf(report.min_card_width, bounds.size.x)
					check.call(bounds.size.x >= 155, "Search results still use undersized cards")
			if count == 2:
				tree.root.get_texture().get_image().save_png("res://../build/battle3d-search-%dx%d.png" % [resolution.x, resolution.y])
			report.cases += 1
		table.reveal_layer.clear()
		await tree.process_frame
		await RenderingServer.frame_post_draw
		check.call(not table.render3d.world.reveal_stage.visible, "Reveal backdrop remains after completion or cancellation")
		tree.root.size = original_size
		tree.root.content_scale_size = original_scale
		for frame in range(3): await tree.process_frame
	return report

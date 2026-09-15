extends RefCounted

static func run(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
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

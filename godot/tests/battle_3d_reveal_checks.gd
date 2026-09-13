extends RefCounted

static func run(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
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
		var destinations: Array[Vector2] = []
		for index in range(count):
			var card_id := "sv1-151" if index % 2 == 0 else "svi-chim"
			rows.append({"card_id": card_id, "matched": true, "outcome_label": "加入手牌"})
			faces.append(table.card_motion_layer._texture_for_card_id(card_id))
			destinations.append(table.size * Vector2(0.5, 0.9))
		table.reveal_layer.present(rows, CardEntity3D.BACK, faces, table.size * Vector2(0.8, 0.8), destinations,
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

class_name Battle3DPresenter
extends Control

## Screen Controls are semantic input/HUD anchors only. All physical surfaces live
## in one World3D; no per-card viewport or rasterized UI texture is rendered.
var table: BattleTable
var viewport: SubViewport
var world: BattleWorld3D
var _container: TextureRect
var _anchors: Dictionary = {}
var _last_size := Vector2.ZERO
var _last_pixel_size := Vector2i.ZERO
var _quality := ""
var _paused := false
var _hud_masks: Dictionary = {}
var _warmup_frames := 3
var layout: BattleLayout3D
var hand_fan: BattleHandFan3D
var mulligan: BattleMulligan3D
var _hand_top := 0.0


static func attach(battle: BattleTable) -> Battle3DPresenter:
	var renderer := Battle3DPresenter.new()
	renderer.name = "PhysicalTable"
	renderer.configure(battle)
	battle.render3d = renderer
	battle.board_canvas.add_child(renderer)
	battle.board_canvas.move_child(renderer, 0)
	return renderer


func prefetch_transition_assets(view: BattleViewModel, events: Array) -> MotionHandle:
	var paths: Array[String] = ["res://assets/cards/card_back.webp"]
	var visible_state := BattleViewModel.player_view_state(view.state_for_render(), view.view_player)
	if visible_state != null:
		_collect_visible_texture_paths(StateSerializer.for_player(visible_state, view.view_player), paths)
	for event in PresentationEvent.normalize_all(events, view.revision()):
		_collect_visible_texture_paths(PresentationEvent.for_player(event, view.view_player), paths)
	var cache := get_node_or_null("/root/CardTextureCache")
	if cache != null:
		return cache.prefetch(paths)
	var handle := MotionHandle.new()
	handle.finish()
	return handle


func _collect_visible_texture_paths(value: Variant, paths: Array[String]) -> void:
	if value is String:
		var card := table.catalog.get_card(value)
		var path := str(card.get("image_path", ""))
		if not path.is_empty() and path not in paths:
			paths.append(path)
	elif value is Array:
		for item in value:
			_collect_visible_texture_paths(item, paths)
	elif value is Dictionary:
		for item in value.values():
			_collect_visible_texture_paths(item, paths)


func configure(value: BattleTable) -> void:
	table = value
	layout = BattleLayout3D.new(self)
	hand_fan = BattleHandFan3D.new(self)
	mulligan = BattleMulligan3D.new(self)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_container = TextureRect.new()
	_container.name = "WorldSurface"
	_container.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_container.stretch_mode = TextureRect.STRETCH_SCALE
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.focus_mode = Control.FOCUS_NONE
	add_child(_container)
	_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport = SubViewport.new()
	viewport.name = "BattleViewport"
	viewport.own_world_3d = true
	viewport.gui_disable_input = true
	viewport.handle_input_locally = false
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_container.add_child(viewport)
	_container.texture = viewport.get_texture()
	world = BattleWorld3D.new()
	world.name = "BattleWorld3D"
	viewport.add_child(world)
	table.camera_rig.configure(world)
	modulate.a = 0.0
	visibility_changed.connect(_on_visibility_changed)
	RenderingServer.frame_pre_draw.connect(_sync_render_frame)
	for node in table.find_children("*", "CardView", true, false):
		register_surface(node as Control)
	for node in table.find_children("*", "ZoneView", true, false):
		register_surface(node as Control)
	_resize_world()
	_on_visibility_changed()
	process_priority = 100


func _exit_tree() -> void:
	_anchors.clear()
	var settings := get_node_or_null("/root/AppSettings")
	if settings != null:
		settings.end_battle_quality(get_instance_id())


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_paused = true
		set_process(false)
		if viewport != null:
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_paused = false
		_on_visibility_changed()
		var settings := get_node_or_null("/root/AppSettings")
		if settings != null:
			settings.reset_battle_frame_samples()


func _on_visibility_changed() -> void:
	var active := is_visible_in_tree() and not _paused
	set_process(active)
	if viewport != null:
		viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE if active else SubViewport.UPDATE_DISABLED
	var settings := get_node_or_null("/root/AppSettings")
	if settings != null:
		if active:
			settings.begin_battle_quality(get_instance_id())
		else:
			# A hidden page still belongs to the same match. Retain its effective
			# quality until _exit_tree(), while discarding inactive frame samples.
			settings.reset_battle_frame_samples()
	if not active and world != null:
		mulligan.clear()
		world.clear_entities()


func register_surface(anchor: Control) -> void:
	if anchor == null or _anchors.has(anchor.get_instance_id()):
		return
	var id := anchor.get_instance_id()
	_anchors[id] = {"ref": weakref(anchor), "keys": []}
	anchor.set_meta("physical_presenter", weakref(self))
	anchor.tree_exiting.connect(_release_anchor.bind(id), CONNECT_ONE_SHOT)
	_suppress_art(anchor)


func _release_anchor(id: int) -> void:
	if not _anchors.has(id):
		return
	var anchor := (_anchors[id].ref as WeakRef).get_ref() as Control
	if anchor != null: layout.release(anchor)
	if is_instance_valid(world):
		for key in _anchors[id].keys:
			world.release_entity(str(key))
	_anchors.erase(id)
	_hud_masks.erase(id)


func _process(delta: float) -> void:
	if _paused or table == null:
		return
	if size != _last_size or render_pixel_size() != _last_pixel_size:
		_resize_world()
	var settings := get_node_or_null("/root/AppSettings")
	if settings != null:
		var next_quality: String = settings.resolved_quality_profile()
		if next_quality != _quality:
			_quality = next_quality
			world.apply_quality(_quality, viewport)
		var preflight := table.presentation_coordinator._preflight
		if table.state_ref == null or table._startup_input_blocked or (preflight != null and not preflight.is_finished()) or not DisplayServer.window_is_focused():
			settings.reset_battle_frame_samples()
		else:
			settings.record_battle_frame(delta, not table.is_presentation_busy() and table.active_drag_context().is_empty())
	if DisplayServer.get_name() == "headless":
		_sync_render_frame()


func _sync_render_frame() -> void:
	# SceneTree advances Tweens after Node._process. Copy their final poses just
	# before rendering, so source masks, flights and landing cards share one frame.
	if not is_inside_tree() or not is_visible_in_tree() or _paused:
		return
	sync_surfaces()
	_sync_coin()
	_warmup_rendering()


func _resize_world() -> void:
	if size.x < 2.0 or size.y < 2.0 or world == null:
		return
	_last_size = size
	_last_pixel_size = render_pixel_size()
	viewport.size = _last_pixel_size
	world.resize(viewport, size)
	var settings := get_node_or_null("/root/AppSettings")
	if settings != null:
		settings.reset_battle_frame_samples()


func render_pixel_size() -> Vector2i:
	# Canvas stretch/UI scale can change without changing the logical table size.
	# Render at the final display footprint; quality scales only the 3D buffer.
	var to_window := get_viewport().get_final_transform() * get_global_transform_with_canvas()
	return Vector2i((size * Vector2(to_window.x.length(), to_window.y.length())).ceil()).max(Vector2i(2, 2))


func sync_surfaces() -> void:
	if not is_projection_ready():
		return
	_hand_top = 0.0
	for bench in table.own_bench:
		var pose := layout.field_pose(bench, bench.feedback_root, 0.035)
		_hand_top = maxf(_hand_top, world.projection.project_pose_bounds(pose).end.y + 10.0)
	mulligan.sync()
	var mulligan_frame := mulligan.presentation_frame()
	var showcase := (table.coin_showcase != null and table.coin_showcase.is_visible_in_tree()) or (table.reveal_layer != null and table.reveal_layer.is_presenting()) or not mulligan_frame.is_empty()
	var reveal_frame := table.reveal_layer.presentation_frame() if table.reveal_layer != null else {}
	if not reveal_frame.is_empty():
		var to_table := table.get_global_transform_with_canvas().affine_inverse() * table.reveal_layer.get_global_transform_with_canvas()
		reveal_frame.panel_rect = to_table * Rect2(reveal_frame.panel_rect)
	elif not mulligan_frame.is_empty(): reveal_frame = mulligan_frame
	world.reveal_stage.apply(world.projection, reveal_frame)
	for id in _anchors.keys():
		var anchor := (_anchors[id].ref as WeakRef).get_ref() as Control
		if anchor == null:
			_release_anchor(int(id))
			continue
		if not anchor.is_inside_tree():
			continue
		_suppress_art(anchor)
		if anchor is CardView:
			_mask_hud(anchor, showcase or _covered_card(anchor as CardView))
			_sync_card(anchor as CardView)
		elif anchor is ZoneView:
			_mask_hud(anchor, showcase)
			_sync_zone(anchor as ZoneView)
		else:
			_sync_token(anchor)
	for hud in [table.own_info, table.own_allowance_row, table.opponent_info, table.opponent_hand_count_badge]:
		if hud != null:
			_mask_hud(hud, showcase)
	_layout_opponent_info()


func _layout_opponent_info() -> void:
	var left := INF
	for hand in table.opponent_hand_views:
		var entity := world.entities.get(_key(hand)) as CardEntity3D
		if entity != null and entity.visible:
			left = minf(left, world.projection.project_bounds(entity).position.x)
	if is_inf(left):
		table.opponent_info.size.x = 304.0
		return
	var to_parent := (table.opponent_info.get_parent() as CanvasItem).get_global_transform_with_canvas().affine_inverse() * table.get_global_transform_with_canvas()
	var limit := (to_parent * Vector2(left, 0)).x - table.opponent_info.position.x - 10.0
	table.opponent_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	table.opponent_info.clip_text = true
	table.opponent_info.size.x = clampf(limit, 140.0, 304.0)


func _mask_hud(anchor: CanvasItem, hidden: bool) -> void:
	var id := anchor.get_instance_id()
	if hidden:
		var entries: Dictionary = _hud_masks.get(id, {})
		for item_id in entries.keys():
			if (entries[item_id].ref as WeakRef).get_ref() == null:
				entries.erase(item_id)
		var nodes: Array[Node] = [anchor]
		nodes.append_array(anchor.find_children("*", "CanvasItem", true, false))
		for node in nodes:
			var item := node as CanvasItem
			if item != null:
				if not entries.has(item.get_instance_id()):
					entries[item.get_instance_id()] = {"ref": weakref(item), "color": item.self_modulate}
				item.self_modulate.a = 0.0
		_hud_masks[id] = entries
	elif not hidden and _hud_masks.has(id):
		var entries: Dictionary = _hud_masks[id]
		_hud_masks.erase(id)
		for entry in entries.values():
			var item := (entry.ref as WeakRef).get_ref() as CanvasItem
			if item != null:
				item.self_modulate = entry.color


func _warmup_rendering() -> void:
	if _warmup_frames <= 0 or not is_projection_ready():
		return
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _warmup_frames == 3:
		world.feedback.burst(Vector3.ZERO, Color.WHITE, "impact", _quality)
		world.reveal_stage.apply(world.projection, {"panel_rect": Rect2(size * 0.4, size * 0.2), "alpha": 0.01})
		world.coin.visible = true
		world.coin.position = Vector3(0, 1, 0)
	elif _warmup_frames == 1:
		world.feedback.clear()
		_sync_coin()
		modulate.a = 1.0
		viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_warmup_frames -= 1


func _suppress_art(anchor: Control) -> void:
	if anchor is CardView:
		var card := anchor as CardView
		card.self_modulate.a = 0.0
		for art in [card.image, card.frame, card.shadow, card.depth_edge, card.top_gloss, card.selection_ring, card.target_glow, card.actionable_marker]:
			if art != null:
				art.self_modulate.a = 0.0
		# The phase HUD names the action and the physical outline marks legal
		# targets. Inline target text cannot share a compact card with its counters.
		if card.interaction_hint != null:
			card.interaction_hint.self_modulate.a = 0.0 if card.targetable and card.hand_index < 0 else 1.0
		for overlay in card._flash_overlays:
			if is_instance_valid(overlay):
				overlay.self_modulate.a = 0.0
	elif anchor is ZoneView:
		var zone := anchor as ZoneView
		zone.self_modulate.a = 0.0
		if not zone.has_meta("physical_caption_style"):
			zone.set_meta("physical_caption_style", true)
			zone.title_label.add_theme_stylebox_override("normal", DesignTokens.panel_style(Color("14222b"), 3, Color.TRANSPARENT, 0, 2))
		for art in [zone.frame, zone.image, zone.fallback_back_panel, zone.fallback_back_label]:
			if art != null:
				art.self_modulate.a = 0.0
	else:
		for label in ["PaperImage", "PaperShadow", "PaperFace", "PaperEdge", "PaperGloss", "Image", "Shadow", "OutcomeOutline"]:
			var art := anchor.get_node_or_null(label) as CanvasItem
			if art != null:
				art.self_modulate.a = 0.0


func _key(anchor: Control, suffix: String = "") -> String:
	return "surface:%d:%s" % [anchor.get_instance_id(), suffix]


func _entity(anchor: Control, suffix: String = "") -> CardEntity3D:
	var key := _key(anchor, suffix)
	var row: Dictionary = _anchors[anchor.get_instance_id()]
	if key not in row.keys:
		row.keys.append(key)
	return world.acquire(key)


func _surface_pose(anchor: Control, width: float, height: float, tilt: float = 0.0, center_override: Vector2 = Vector2.INF) -> Transform3D:
	var canvas_transform := anchor.get_global_transform_with_canvas()
	var inverse := table.get_global_transform_with_canvas().affine_inverse()
	var center := inverse * (canvas_transform * (anchor.size * 0.5)) if center_override == Vector2.INF else center_override
	var width_pixels := (inverse.basis_xform(canvas_transform.basis_xform(Vector2(width, 0)))).length()
	var yaw := canvas_transform.get_rotation() - table.get_global_transform_with_canvas().get_rotation()
	return world.projection.pose_for_screen(center, width_pixels, yaw, height, tilt)


func _sync_card(card: CardView) -> void:
	var entity := _entity(card)
	var shown := _shown(card) and not card.is_presentation_hidden() and not card.is_drag_masked() and not _covered_card(card)
	entity.visible = shown
	var hand := card.hand_index >= 0 or card.get_parent() == table.opponent_hand_surface
	var root: Control = card.feedback_root if card.feedback_root != null else card
	var raised := 0.36 if hand else 0.035
	raised += float(card.get_meta("physical_lift", 0.0))
	if hand:
		raised += float(maxi(card.hand_index, card.get_index())) * 0.025
	if card.pokemon != null and not hand:
		raised += mini(card.pokemon.energy_card_ids.size() + card.pokemon.evolution_stack_ids.size() + (0 if card.pokemon.attached_tool_id.is_empty() else 1), 6) * 0.03
	if card.selected or card._hovered:
		raised += 0.60 if hand else 0.10
	entity.set_packet_layers(1.0)
	if hand:
		entity.transform = _hand_pose(card, root, raised)
	else:
		entity.transform = layout.field_pose(card, root, raised)
	if card.has_meta("physical_pose"):
		entity.transform = card.get_meta("physical_pose") as Transform3D
	if card.pokemon != null and card.battle_overlay != null and card.content_root != null:
		var to_content := card.content_root.get_global_transform_with_canvas().affine_inverse() * table.get_global_transform_with_canvas()
		card.battle_overlay.set_physical_rect(to_content * world.projection.project_bounds(entity))
	entity.visual_id = card.local_visual_id if not card.local_visual_id.is_empty() else "pokemon:%d:%s" % [card.owner_player, card.slot]
	# A masked destination still owns its landing geometry, including a newly
	# allocated hand card that has never been drawn. Only its surface is hidden.
	if not shown:
		entity.set_surface(null, true)
		_hide_children(card)
		return
	entity.set_surface(card.image.texture, card.is_hidden_card)
	entity.set_highlight(card.selected, card.targetable, card._hovered, card.empty and not card.is_hidden_card)
	var flash_color := Color.BLACK
	var flash_strength := 0.0
	for overlay in card._flash_overlays:
		if is_instance_valid(overlay) and overlay.color.a > flash_strength:
			flash_strength = overlay.color.a
			flash_color = overlay.color
	entity.set_feedback(flash_color, flash_strength)
	_apply_hand_clip(entity, card.hand_index >= 0)
	entity.update_contact_shadow()
	_sync_attachments(card, entity)


func _covered_card(card: CardView) -> bool:
	if card.hand_index >= 0 or card.slot.is_empty(): return false
	var cover := table.presentation_runtime.slot_covers.get("%d:%s" % [card.owner_player, card.slot]) as CardView
	# A 2D opaque cover used to conceal the authoritative post-action card.
	# In 3D its mesh can sit above the old stack, and its screen badges ignore
	# depth entirely. Let the staged stack own both until contact/reconciliation.
	return is_instance_valid(cover) and cover != card and _shown(cover)


func _sync_attachments(card: CardView, owner: CardEntity3D) -> void:
	var expected: Array[String] = []
	if card.pokemon != null and not card.is_hidden_card and not card.empty:
		var ids: Array[String] = card.pokemon.evolution_stack_ids.slice(0, 2)
		var has_tool := not card.pokemon.attached_tool_id.is_empty()
		ids.append_array(card.pokemon.energy_card_ids.slice(0, 3 if has_tool else 4))
		if not card.pokemon.attached_tool_id.is_empty():
			ids.append(card.pokemon.attached_tool_id)
		# The HUD preserves exact physical indices and counts. Only the exposed
		# edges need geometry, keeping pathological energy stacks bounded.
		for i in range(mini(ids.size(), 6)):
			var suffix := "attachment:%d" % i
			expected.append(_key(card, suffix))
			var entity := _entity(card, suffix)
			entity.set_packet_layers(1.0)
			entity.visible = owner.visible
			entity.transform = _attachment_layer_pose(owner.transform, i)
			entity.visual_id = ids[i]
			var cache := get_node_or_null("/root/CardTextureCache")
			var path := str(table.catalog.get_card(ids[i]).get("image_path", ""))
			var texture: Texture2D = cache.get_cached_or_request(path) if cache != null else null
			entity.set_surface(texture, false)
			entity.set_highlight(false, false, false)
			entity.update_contact_shadow()
	var row: Dictionary = _anchors[card.get_instance_id()]
	for key in row.keys:
		if ":attachment:" in str(key) and str(key) not in expected:
			var stale := world.entities.get(key) as CardEntity3D
			if stale != null:
				stale.visible = false
				stale.set_surface(null, true)


func attachment_pose(card: CardView, kind: String, index: int = -1) -> Transform3D:
	var owner := card_pose(card)
	var state := card.pokemon
	var layer := 0
	if state != null:
		var evolution_count := mini(2, state.evolution_stack_ids.size())
		var energy_limit := 3 if not state.attached_tool_id.is_empty() or kind == "tool" else 4
		if kind == "energy": layer = evolution_count + clampi(index if index >= 0 else state.energy_card_ids.size(), 0, energy_limit - 1)
		elif kind == "tool": layer = evolution_count + mini(state.energy_card_ids.size(), energy_limit)
		else: layer = clampi(index, 0, 1)
	return _attachment_layer_pose(owner, mini(layer, 5))

func _attachment_layer_pose(owner: Transform3D, index: int) -> Transform3D:
	var pose := owner
	pose.origin += pose.basis * Vector3(0.009, -0.011, 0.009) * float(index + 1)
	return pose

func _hide_children(anchor: Control) -> void:
	for key in _anchors[anchor.get_instance_id()].keys:
		var entity := world.entities.get(key) as CardEntity3D
		if entity != null:
			entity.visible = false
			entity.set_surface(null, true)


func _sync_zone(zone: ZoneView) -> void:
	var count := mini(zone.count, 6)
	var shown := _shown(zone) and not zone.is_stack_presentation_hidden()
	var top_hidden := zone.is_presentation_hidden()
	for i in range(maxi(1, count)):
		var entity := _entity(zone, str(i))
		var span := BattleLayout3D.packet_span(zone.count, i)
		entity.set_packet_layers(1.0 if zone.stack_visual_mode == "prizes" else maxf(1, span.y - span.x))
		entity.visible = shown and (i < count or count == 0) and not (top_hidden and i == maxi(0, count - 1))
		entity.transform = zone_pose(zone, i)
		if not entity.visible:
			entity.set_surface(null, true)
			continue
		entity.set_surface(zone.image.texture, zone.is_hidden_zone or i != count - 1)
		entity.set_highlight(zone.actionable, zone._drop_highlighted, false, count == 0)
		entity.update_contact_shadow()
	for i in range(maxi(1, count), 6):
		var entity := world.entities.get(_key(zone, str(i))) as CardEntity3D
		if entity != null:
			entity.visible = false
			entity.set_surface(null, true)
	if zone.count_label != null:
		var top := world.entities.get(_key(zone, str(maxi(0, count - 1)))) as CardEntity3D
		var to_zone := zone.get_global_transform_with_canvas().affine_inverse() * table.get_global_transform_with_canvas()
		var bounds := to_zone * world.projection.project_bounds(top)
		var badge := zone.count_label
		badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
		badge.position = Vector2(bounds.position.x if zone.stack_visual_mode == "deck" else bounds.end.x - badge.size.x, bounds.end.y - badge.size.y * 0.4)
		zone.empty_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
		zone.empty_label.position = bounds.position
		zone.empty_label.size = bounds.size
		zone.title_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
		zone.title_label.position = bounds.position + Vector2(0, -20)
		zone.title_label.size = Vector2(bounds.size.x, 18)


func _sync_token(anchor: Control) -> void:
	var entity := _entity(anchor)
	entity.set_packet_layers(float(anchor.get_meta("shuffle_paper_layers", 1.0)))
	entity.visible = _shown(anchor)
	if not entity.visible:
		entity.set_surface(null, true)
		return
	var surface := anchor as CardMotionEntity
	var texture: Texture2D = surface.texture if surface != null else null
	var hidden := texture == CardEntity3D.BACK
	entity.set_surface(texture, hidden)
	entity.set_highlight(false, false, false)
	if anchor is CardMotionEntity and (anchor as CardMotionEntity).has_world_pose:
		entity.transform = (anchor as CardMotionEntity).world_pose
		if anchor.has_meta("snapshot_world_pose") and not anchor.has_meta("motion_event_id") and not anchor.has_meta("physical_reflow"):
			var original: Transform3D = anchor.get_meta("snapshot_world_pose")
			var original_center: Vector2 = anchor.get_meta("snapshot_screen_center")
			var to_table := table.get_global_transform_with_canvas().affine_inverse() * (anchor.get_parent() as CanvasItem).get_global_transform_with_canvas()
			var displacement := to_table.basis_xform(anchor.position + anchor.size * 0.5 - original_center)
			entity.transform = original
			entity.position = world.projection.screen_to_world(world.projection.world_to_screen(original.origin) + displacement, original.origin.y)
			(surface as CardMotionEntity).world_pose = entity.transform
	elif anchor.has_meta("snapshot_opponent_hand_index"):
		var ordinal := int(anchor.get_meta("snapshot_opponent_hand_index"))
		var count := maxi(1, table.hand_presentation._presentation_opponent_hand_stage_count)
		entity.transform = _hand_surface_pose(anchor, anchor.size.x * 0.72, ordinal, count, 0.36 + ordinal * 0.025, false, false)
	else:
		var reveal := anchor.has_meta("face_texture")
		var dragging := anchor.has_meta("drag_session_id")
		var height := 2.0 if reveal else 0.30 if dragging else 0.12
		var tilt := 35.0 if reveal else 4.0 if dragging else -12.0
		entity.transform = _surface_pose(anchor, anchor.size.x, height, deg_to_rad(tilt))
		if reveal:
			var to_table := table.get_global_transform_with_canvas().affine_inverse() * anchor.get_global_transform_with_canvas()
			entity.transform = world.projection.camera_plane_pose(to_table * (anchor.size * 0.5), anchor.size.x * to_table.x.length(), 18.0, to_table.get_rotation())
	if surface != null:
		surface.resolved_world_pose = entity.transform
		surface.has_resolved_world_pose = true
	if anchor.has_meta("physical_flip_progress"):
		var target: Texture2D
		if anchor.has_meta("motion_flip_texture"):
			target = anchor.get_meta("motion_flip_texture") as Texture2D
		elif anchor.has_meta("face_texture"):
			target = anchor.get_meta("face_texture") as Texture2D
		if target != null:
			entity.set_surface(anchor.get_meta("physical_flip_source") as Texture2D, false)
			entity.set_reverse_surface(target)
			entity.transform.basis = BattleProjection3D.rotate_card_basis(entity.transform.basis, Basis(Vector3.FORWARD, float(anchor.get_meta("physical_flip_progress")) * PI))
	if anchor is CardMotionEntity:
		entity.visual_id = (anchor as CardMotionEntity).visual_id
		(anchor as CardMotionEntity).physical_entity = entity
	_apply_hand_clip(entity, anchor.has_meta("face_texture") or anchor.has_meta("reveal_transferred") or anchor.has_meta("mulligan_hand") or (anchor.has_meta("snapshot_hand_key") and not anchor.has_meta("motion_event_id") and not anchor.has_meta("drag_session_id")))
	entity.update_contact_shadow()
	if anchor.has_meta("face_texture"):
		entity.contact_shadow.visible = false


func _apply_hand_clip(entity: CardEntity3D, enabled: bool) -> void:
	# The fan fits its entire silhouette. Keep only the viewport boundary and the
	# inexpensive hand contact shadows; the old scroll-rectangle cut off end cards.
	entity.set_screen_clip(Rect2(0, 0, 1, 1), enabled)


func _sync_coin() -> void:
	if not is_projection_ready():
		return
	var showcase := table.coin_showcase
	world.coin.visible = showcase != null and showcase.is_visible_in_tree() and not showcase.results.is_empty()
	if not world.coin.visible:
		return
	showcase.set_physical_rendering(true)
	var index := clampi(showcase._current_index, 0, showcase.results.size() - 1)
	var result_heads: bool = showcase.results[index]
	var start_heads: bool = showcase.results[index - 1] if index > 0 else not result_heads
	var local_center := Vector2(showcase.size.x * 0.5, minf(118.0, showcase.size.y * 0.43))
	var to_table := table.get_global_transform_with_canvas().affine_inverse() * showcase.get_global_transform_with_canvas()
	world.coin.pose_for_toss(world.projection, to_table * local_center, CoinShowcase.COIN_SIZE * 1.12,
		showcase._toss_progress, result_heads, start_heads, MotionPolicy.reduced())


func burst_from(layer: Control, point: Vector2, color: Color, kind: String) -> MotionHandle:
	if not is_projection_ready():
		var finished := MotionHandle.new()
		finished.finish()
		return finished
	var to_table := table.get_global_transform_with_canvas().affine_inverse() * layer.get_global_transform_with_canvas()
	return world.feedback.burst(world.projection.screen_to_world(to_table * point, 0.08), color, kind, _quality)


func _shown(anchor: CanvasItem) -> bool:
	if not anchor.is_visible_in_tree():
		return false
	var item: Node = anchor
	var alpha := 1.0
	while item != null and item != table:
		if item is CanvasItem:
			alpha *= (item as CanvasItem).modulate.a
		item = item.get_parent()
	return alpha > 0.02


func global_bounds(anchor: Control) -> Rect2:
	if not is_projection_ready() or not _anchors.has(anchor.get_instance_id()):
		return anchor.get_global_rect()
	if anchor is CardView:
		_sync_card(anchor as CardView)
	elif anchor is ZoneView:
		_sync_zone(anchor as ZoneView)
	var bounds := Rect2()
	var found := false
	var keys: Array = [_key(anchor)]
	if anchor is ZoneView:
		keys.clear()
		for index in range(maxi(1, mini((anchor as ZoneView).count, 6))):
			keys.append(_key(anchor, str(index)))
	for key in keys:
		var entity := world.entities.get(key) as CardEntity3D
		if entity != null:
			var projected := world.projection.project_bounds(entity)
			bounds = bounds.merge(projected) if found else projected
			found = true
	if not found:
		return anchor.get_global_rect()
	var transform_to_global := table.get_global_transform_with_canvas()
	return transform_to_global * bounds


func pick(screen_position: Vector2) -> Control:
	return _pick_surface(screen_position).get("anchor") as Control


func _pick_surface(screen_position: Vector2, expand_touch: bool = false) -> Dictionary:
	if not is_projection_ready() or not is_visible_in_tree() or _paused:
		return {}
	var winner: Dictionary = {}
	var touch_winner: Dictionary = {}
	var nearest := INF
	var nearest_touch := INF
	var to_window := get_viewport().get_final_transform() * table.get_global_transform_with_canvas()
	var touch_size := Vector2(48.0 / to_window.x.length(), 48.0 / to_window.y.length())
	for row in _anchors.values():
		var anchor := (row.ref as WeakRef).get_ref() as Control
		if anchor == null or not _shown(anchor) or not (anchor is CardView or anchor is ZoneView):
			continue
		if anchor is CardView and ((anchor as CardView).is_presentation_hidden() or (anchor as CardView).is_drag_masked()):
			continue
		if anchor is ZoneView and (anchor as ZoneView).is_stack_presentation_hidden():
			continue
		for key in row.keys:
			if ":attachment:" in str(key):
				continue
			var entity := world.entities.get(key) as CardEntity3D
			if entity == null or not entity.visible:
				continue
			if entity.clip_enabled and not entity.screen_clip.has_point(screen_position / size):
				continue
			var bounds := world.projection.project_bounds(entity)
			if entity.clip_enabled:
				bounds = bounds.intersection(Rect2(entity.screen_clip.position * size, entity.screen_clip.size * size))
			if not bounds.has_area():
				continue
			var hit := {"anchor": anchor, "index": str(key).get_slice(":", 2).to_int()}
			var distance := world.projection.ray_distance(entity, screen_position) if bounds.grow(1.0).has_point(screen_position) else -1.0
			if distance >= 0.0 and distance < nearest:
				nearest = distance
				winner = hit
			elif expand_touch:
				var extra := (touch_size - bounds.size).max(Vector2.ZERO) * 0.5
				if bounds.grow_individual(extra.x, extra.y, extra.x, extra.y).has_point(screen_position):
					var gap := screen_position.distance_squared_to(screen_position.clamp(bounds.position, bounds.end))
					if gap < nearest_touch:
						nearest_touch = gap
						touch_winner = hit
	return winner if not winner.is_empty() else touch_winner


func contains_global_point(anchor: Control, point: Vector2) -> bool:
	var local_point := table.get_global_transform_with_canvas().affine_inverse() * point
	return _pick_surface(local_point, true).get("anchor") == anchor


func prize_index_at_global_point(zone: ZoneView, point: Vector2) -> int:
	var local_point := table.get_global_transform_with_canvas().affine_inverse() * point
	var hit := _pick_surface(local_point, true)
	return int(hit.get("index", -1)) if hit.get("anchor") == zone else -1


func capture_world_poses(snapshot: Dictionary) -> void:
	for row in snapshot.get("hand", []):
		var index := int(row.get("hand_index", -1))
		if index >= 0 and index < table.hand_views.size():
			var card := table.hand_views[index]
			row["world_pose"] = card_pose(card)
			row["anchor_center"] = table._effects_local(card.get_global_transform_with_canvas() * (card.size * 0.5))
	var visible_opponent := table.opponent_hand_views.filter(func(view: CardView) -> bool: return view.visible)
	var opponent_rows: Array = snapshot.get("opponent_hand", [])
	for index in range(mini(opponent_rows.size(), visible_opponent.size())):
		opponent_rows[index]["world_pose"] = card_pose(visible_opponent[index])
	for key in snapshot.get("slots", {}):
		if table.slot_views.has(key): snapshot.slots[key]["world_pose"] = card_pose(table.slot_views[key])


func card_pose(card: CardView) -> Transform3D:
	_sync_card(card)
	return (world.entities[_key(card)] as CardEntity3D).transform


func zone_pose(zone: ZoneView, index: int = -1) -> Transform3D:
	var layer := clampi(index, 0, 5) if index >= 0 else maxi(0, mini(zone.count, 6) - 1)
	var pose := layout.zone_base(zone)
	if zone.stack_visual_mode == "prizes":
		pose.origin += pose.basis * Vector3(0.18 * layer, CardEntity3D.THICKNESS * (layer + 0.5), 0)
	else:
		var span := BattleLayout3D.packet_span(zone.count, layer)
		pose.origin += pose.basis.y * (CardEntity3D.THICKNESS * (span.x + span.y) * 0.5)
	return pose


func zone_pose_at_screen_point(zone: ZoneView, point: Vector2) -> Transform3D:
	var index := -1
	if zone.stack_visual_mode == "prizes":
		var nearest := INF
		for candidate in range(6):
			var distance := world.projection.world_to_screen(zone_pose(zone, candidate).origin).distance_to(point)
			if distance < nearest:
				nearest = distance
				index = candidate
	return zone_pose(zone, index)


func _hand_pose(card: CardView, root: Control, height: float) -> Transform3D:
	var own := card.hand_index >= 0
	var cards := table.hand_views if own else table.opponent_hand_views
	var ordinal := card.hand_index if own else card.get_index()
	var count := maxi(1, cards.filter(func(view: CardView) -> bool: return view.visible).size())
	var width := card.size.x * (1.0 if own else 0.72)
	return _hand_surface_pose(root, width, ordinal, count, height, own, card.selected or card._hovered)


func _hand_surface_pose(root: Control, width: float, ordinal: int, count: int, height: float, own: bool, highlighted: bool) -> Transform3D:
	if own:
		return hand_fan.pose(root, width, ordinal, count, height, highlighted)
	var fan := clampf(float(ordinal) / maxi(1, count - 1) - 0.5, -0.5, 0.5)
	var pose := _surface_pose(root, width, 0.0, deg_to_rad(-12.0))
	pose.origin.y = height + absf(fan) * 0.08
	pose.basis = pose.basis * Basis(Vector3.UP, fan * deg_to_rad(24.0))
	var bounds := world.projection.project_pose_bounds(pose)
	var correction := 0.0
	if own:
		var top := _hand_top - (20.0 if highlighted else 0.0)
		var available := maxf(48.0, size.y - 16.0 - top)
		if bounds.size.y > available:
			pose.basis = pose.basis.scaled(Vector3.ONE * available / bounds.size.y)
			bounds = world.projection.project_pose_bounds(pose)
		correction = maxf(0.0, top - bounds.position.y)
		if bounds.end.y + correction > size.y - 16.0:
			correction = size.y - 16.0 - bounds.end.y
	else:
		var info_top := table.get_global_transform_with_canvas().affine_inverse() * table.opponent_info.get_global_transform_with_canvas().origin
		correction = maxf(0.0, info_top.y - 6.0 - bounds.position.y)
	if absf(correction) > 0.01:
		pose.origin = world.projection.screen_to_world(world.projection.world_to_screen(pose.origin) + Vector2(0, correction), pose.origin.y)
	return pose


func clear_private_faces() -> void:
	if world != null:
		world.clear_entities()


func is_projection_ready() -> bool:
	return is_instance_valid(world) and world.projection.camera != null and world.projection.viewport != null and _last_size.x > 1.0


func stats() -> Dictionary:
	var result := world.stats()
	result["anchors"] = _anchors.size()
	result["draw_calls"] = viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	result["primitives"] = viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	return result

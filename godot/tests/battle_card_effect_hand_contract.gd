extends SceneTree

const ENERGY := "sv1-ener-4"
const GENERATOR := "sv1-170"
const TRAINERS := {
	"retrieval": "sv1-171", "ultra_ball": "sv1-153",
	"nest_ball": "sv1-151", "energy_switch": "svf-ensw2",
	"research": "sv1-189",
}

var failures: Array[String] = []
var report: Array[Dictionary] = []
var table: BattleTable
var graphics := false


func _initialize() -> void:
	call_deferred("_run")


func _check(value: bool, message: String) -> void:
	if not value and message not in failures:
		failures.append(message)


func _run() -> void:
	graphics = DisplayServer.get_name() != "headless"
	Engine.max_fps = 60
	root.size = Vector2i(1600, 900)
	root.content_scale_size = root.size
	create_timer(240).timeout.connect(func() -> void:
		push_error("Card effect hand contract timed out")
		quit(1))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../build/generator-hand"))
	table = load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	if graphics: Input.warp_mouse(Vector2(8, 8))
	_check_event_addresses()
	for mode in ["standard", "fast", "reduced"]:
		root.get_node("AppSettings").animation_mode = mode
		for kind in ["generator", "generator_split", "generator_one", "generator_zero", "generator_cancel", "generator_duplicate", "generator_last", "retrieval", "ultra_ball", "nest_ball", "energy_switch", "dynamotor", "research"]:
			await _run_effect(kind, mode, 0)
		await _run_effect("generator", mode, 1)
	var path := "res://../build/generator-hand/validation-%s.json" % ("graphics" if graphics else "headless")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"cases": report, "failures": failures}, "\t"))
	file.close()
	table.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("BATTLE_CARD_EFFECT_HAND_OK cases=%d graphics=%s" % [report.size(), graphics])
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check_event_addresses() -> void:
	for type in ["energy_attached", "tool_attached", "pokemon_played", "pokemon_evolved", "trainer_played", "stadium_changed"]:
		var event := PresentationEvent.normalize({"event_type": type, "actor": 0, "data": {}}, 4)
		for pass_index in range(4):
			var again := PresentationEvent.normalize(event, 4)
			_check(again == event, "%s: normalization invents a hand source on a repeated pass" % type)
			event = PresentationEvent.for_player(again, pass_index % 2)
		_check(str(event.source.zone).is_empty(), "%s: bare notification has a physical hand source" % type)
		_check(table.motion_geometry._event_amount(event, []) == 0, "%s: bare notification claims one card" % type)
	var transfer := PresentationEvent.normalize({"event_type": "energy_attached", "actor": 0, "card_id": ENERGY,
		"source": {"player": 0, "slot": "active", "index": 0}, "target": {"player": 0, "slot": "bench_0"}}, 5)
	_check(transfer.source.zone == "" and transfer.source.attachment_type == "energy", "Slot energy transfer was converted to a hand movement")
	_check(PresentationEvent.normalize(transfer, 5) == transfer, "Slot energy transfer changes after normalization")
	var rows: Array[Dictionary] = [
		{"card_id": ENERGY, "snapshot_key": "a"},
		{"card_id": ENERGY, "snapshot_key": "b"},
		{"card_id": "sv1-151", "snapshot_key": "c"},
	]
	var missing := PresentationEvent.normalize({"event_type": "trainer_played", "actor": 0, "card_id": GENERATOR, "amount": 1, "source": {"zone": "hand", "index": 0}}, 5)
	_check(table.hand_presentation._select_virtual_hand_source_rows(missing, rows).is_empty(), "A missing trainer steals an unrelated hand card")
	var mixed := PresentationEvent.normalize({"event_type": "cards_discarded", "actor": 0, "amount": 2,
		"data": {"card_ids": [ENERGY, "sv1-151"], "source_indices": [0, 99]}}, 5)
	var selected := table.hand_presentation._select_virtual_hand_source_rows(mixed, rows)
	_check(selected.size() == 2 and selected[0].snapshot_key == "a" and selected[1].snapshot_key == "c", "Partial index matches duplicate the first card instead of matching the next identity")


func _fixture(kind: String) -> GameState:
	var state := GameState.new()
	state.revision = 100 + report.size() * 100
	state.setup_stage = GameState.SETUP_COMPLETE
	state.active_player_idx = 0
	state.first_player_idx = 1
	state.turn_number = 4
	state.phase = "MAIN"
	for player in state.players:
		player.active = PokemonState.new("svl-emol")
		player.prizes.assign([ENERGY, ENERGY])
		player.deck.assign([ENERGY, "svl-chin", "sv1-151", "svf-potion", "sv1-189", ENERGY, ENERGY])
	state.players[1].hand.assign([ENERGY, "sv1-189", "sv1-153"])
	var own := state.players[0]
	own.bench[0] = PokemonState.new("svl-chin")
	own.bench[1] = PokemonState.new("svl-flaa2")
	own.discard.assign([ENERGY, ENERGY])
	own.active.energy_card_ids.append(ENERGY)
	own.hand.assign([str(TRAINERS.get(kind, GENERATOR)), ENERGY, ENERGY, "svl-flaa2", ENERGY, "sv1-151"])
	if kind == "generator_duplicate": own.hand[1] = GENERATOR
	if kind == "generator_last": own.hand.assign([GENERATOR])
	if kind == "dynamotor": own.hand.pop_front()
	return state


func _choose(request: ChoiceView, kind: String) -> ChoiceResponse:
	var ids: Array[String] = []
	if kind == "generator_cancel": return ChoiceResponse.new(request.request_id, ids, true)
	if request.request_type == "distribute_energy" and kind != "energy_switch":
		for ordinal in range(request.max_select):
			var target_slot := "bench_%d" % (ordinal % 2 if kind == "generator_split" else 0)
			for option in request.options:
				if str(option.option_id).begins_with("energy:%d:" % ordinal) and str(option.ref.slot) == target_slot:
					ids.append(option.option_id)
					break
	else:
		var amount := mini(request.max_select, request.options.size())
		if request.request_type == "look_top":
			if kind == "generator_zero": amount = 0
			if kind == "generator_one": amount = 1
		for option in request.options.slice(0, amount): ids.append(option.option_id)
	return ChoiceResponse.new(request.request_id, ids)


func _run_effect(kind: String, mode: String, viewer: int) -> void:
	var tag := "%s-%s-view%d" % [kind, mode, viewer]
	var adapter := NativeRulesSessionAdapter.new(CardCatalog.shared())
	_check(adapter.restore(_fixture(kind).snapshot(), 9123), tag + ": native fixture restore failed")
	table.clear_presentation_for_resync()
	table.update_view(BattleViewModel.player_view_state(adapter.state, viewer), viewer, [], "", false, "local")
	await _settle(5)
	var action: Dictionary = {}
	for candidate in adapter.legal_actions(0).concrete_actions():
		var row: Dictionary = candidate.to_dict()
		if (kind == "dynamotor" and row.kind == "USE_ABILITY" and str(row.source.card_id) == "svl-flaa2") or (kind != "dynamotor" and row.kind == "PLAY_TRAINER" and str(row.source.card_id) == str(TRAINERS.get(kind, GENERATOR))):
			action = row
			break
	_check(not action.is_empty(), tag + ": real card has no legal action")
	if action.is_empty(): return
	action["action_id"] = tag
	var before := adapter.state.clone_state()
	var step := adapter.apply_action(action)
	var record := {"kind": kind, "mode": mode, "viewer": viewer, "choices": 0, "frames": 0, "motion_cards": 0}
	while true:
		_check(step.success, tag + ": native step failed: " + step.message)
		if not step.success: break
		if mode == "standard" and viewer == 0 and not step.events.is_empty():
			record["events"] = step.events.duplicate(true)
		await _present(before, adapter.state, step.events, tag, record)
		if step.pending_choice == null: break
		record.choices += 1
		_check(record.choices <= 6, tag + ": choice chain did not terminate")
		if record.choices > 6: break
		before = adapter.state.clone_state()
		step = adapter.apply_choice(_choose(step.pending_choice, kind).to_dict())
	# A redelivered final packet must not retire the newly drawn same-ID cards
	# before the director gets a chance to reject duplicate event IDs.
	if step.success and not step.events.is_empty():
		var old_motions := int(record.motion_cards)
		await _present(adapter.state, adapter.state, step.events, tag, record)
		_check(record.motion_cards == old_motions, tag + ": duplicate packet replays card movement")
	_check(table.card_motion_layer.active_motion_count() == 0 and table.hand_presentation._presentation_hand_source_proxies.is_empty(), tag + ": completed effect retains motion cards")
	_check(not table.reveal_layer.is_presenting(), tag + ": completed effect retains its reveal panel")
	if mode != "reduced": _check(record.motion_cards > 0, tag + ": regression did not exercise card animation")
	if graphics and mode == "standard" and kind in ["generator", "generator_duplicate", "retrieval", "ultra_ball"]:
		root.get_texture().get_image().save_png("res://../build/generator-hand/%s-settled.png" % tag)
	report.append(record)
	var summary := record.duplicate()
	summary.erase("events")
	print("CARD_EFFECT_CASE ", JSON.stringify(summary))


func _present(before: GameState, after: GameState, raw_events: Array, tag: String, record: Dictionary) -> void:
	var viewer := table.view_player
	var stable_hand := before.players[viewer].hand == after.players[viewer].hand
	var identities: Array[String] = []
	var poses: Array[Transform3D] = []
	for card in table.hand_views:
		if card.visible:
			identities.append(card.local_visual_id)
			poses.append(table.render3d.card_pose(card))
	# Network delivery normalizes and redacts before BattleTable normalizes again.
	# Exercise both the raw local path and that transported representation.
	var events: Array = []
	for event in PresentationEvent.normalize_all(raw_events, after.revision, 0):
		var visible_event := PresentationEvent.for_player(event, viewer)
		if not visible_event.is_empty(): events.append(visible_event)
	var handle := table.submit_transition(BattleTransitionRequest.create(
		BattleViewModel.capture_player_view(after, viewer, [], "", false, "local"),
		events if record.mode != "fast" else raw_events, 0, BattleTransitionRequest.CAUSE_CHOICE, tag))
	var seen_flyers: Dictionary = {}
	var frames := 0
	while not handle.is_completed() and frames < 600:
		await _settle(1)
		frames += 1
		if stable_hand:
			_check_stable_hand(identities, poses, tag)
		if table.presentation_runtime.hud_state != null:
			for player in range(2):
				if before.players[player].hand == after.players[player].hand:
					_check(table.presentation_runtime.hud_state.players[player].hand.size() == after.players[player].hand.size(), tag + ": unchanged hand counter is deducted again")
			if tag.begins_with("generator"):
				var hud := table.presentation_runtime.hud_state
				_check(hud.players[0].deck.size() >= mini(before.players[0].deck.size(), after.players[0].deck.size()), tag + ": selected energies are deducted from the deck twice")
				_check(hud.players[0].discard.size() <= maxi(before.players[0].discard.size(), after.players[0].discard.size()), tag + ": trainer is counted twice in discard")
		for token in table.card_motion_layer.entities:
			if token is CardMotionEntity and token.visible: seen_flyers[token.get_instance_id()] = true
		if graphics and record.mode == "standard" and tag.begins_with("generator-standard") and frames == 18:
			root.get_texture().get_image().save_png("res://../build/generator-hand/%s-flight.png" % tag)
	_check(handle.is_completed(), tag + ": presentation barrier did not finish")
	await _settle(3)
	var hand := table.hand_views.filter(func(card: CardView) -> bool: return card.visible)
	_check(hand.size() == after.players[viewer].hand.size(), tag + ": hand count disagrees with rules")
	for index in range(mini(hand.size(), after.players[viewer].hand.size())):
		var card := hand[index] as CardView
		_check(card.card_id == after.players[viewer].hand[index] and card.hand_index == index, tag + ": hand face or input index changed")
		var entity := table.render3d.world.entities.get(table.render3d._key(card)) as CardEntity3D
		_check(entity != null and entity.visible and not card.is_presentation_hidden(), tag + ": settled hand is masked or missing its 3D entity")
	for card in table.opponent_hand_views:
		if not card.visible: continue
		var entity := table.render3d.world.entities.get(table.render3d._key(card)) as CardEntity3D
		_check(entity != null and entity.face_down and entity.face_texture == null, tag + ": hidden opponent hand exposes a face")
	if stable_hand: _check_stable_hand(identities, poses, tag)
	record.frames += frames
	record.motion_cards += seen_flyers.size()


func _check_stable_hand(identities: Array[String], poses: Array[Transform3D], tag: String) -> void:
	var visible := table.hand_views.filter(func(card: CardView) -> bool: return card.visible)
	_check(visible.size() == identities.size(), tag + ": unrelated effect changes visible hand count")
	for index in range(mini(visible.size(), identities.size())):
		var card := visible[index] as CardView
		_check(card.local_visual_id == identities[index], tag + ": unrelated effect replaces a retained hand identity")
		var bounds := table.render3d.world.projection.project_pose_bounds(table.render3d.card_pose(card))
		var previous := table.render3d.world.projection.project_pose_bounds(poses[index])
		_check(bounds.position.distance_to(previous.position) < 2.0, tag + ": unchanged hand jumps or reflows during effect")
		var copies := 0
		for entity: CardEntity3D in table.render3d.world.entities.values():
			if entity.visible and entity.visual_id == identities[index]: copies += 1
		_check(copies == 1, tag + ": retained card has missing or duplicate rendered copies")


func _settle(frames: int) -> void:
	for frame in range(frames):
		await process_frame
		if graphics: await RenderingServer.frame_post_draw
		else: table.render3d.sync_surfaces()

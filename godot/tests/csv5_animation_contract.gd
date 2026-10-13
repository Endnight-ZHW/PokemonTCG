extends "res://tests/csv5_rules_contract.gd"

## Actual native transitions through the renderer, with both players' projections.
var table: BattleTable
var graphics := false
var records: Array[Dictionary] = []
const OUTPUT := "res://../build/csv5-animation-review"

func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)

func run() -> void:
	graphics = DisplayServer.get_name() != "headless"
	Engine.max_fps = 60
	root.size = Vector2i(1280, 768)
	root.content_scale_size = root.size
	cards = CardCatalog.shared().cards.duplicate(true)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	create_timer(240).timeout.connect(func() -> void:
		push_error("CSV5 animation review timed out")
		quit(1))
	table = load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	for mode in ["standard", "reduced"]:
		for viewer in 2:
			for kind in ["devolution", "devolution_ko", "tm_evolution", "named_energy", "bench_limit", "doll"]:
				await run_case(kind, mode, viewer)
	for mode in ["cinematic", "fast"]:
		for viewer in 2: await run_case("named_energy", mode, viewer)
	FileAccess.open(OUTPUT.path_join("validation.json"), FileAccess.WRITE).store_string(JSON.stringify({"graphics": graphics, "cases": records, "failures": failures}, "\t"))
	table.queue_free()
	await process_frame
	if failures.is_empty(): print("CSV5_ANIMATION_CONTRACT_OK cases=%d graphics=%s" % [records.size(), graphics])
	quit(0 if failures.is_empty() else 1)

func fixture(kind: String) -> GameState:
	var state := base_state("csv5-014", "csv5-028")
	state.revision = 40000 + records.size() * 100
	for player in state.players: player.hand.assign(["sv1-151", "sv1-ener-2"])
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	match kind:
		"devolution", "devolution_ko":
			state.players[0].active.attached_tool_id = "csv5-120"
			state.players[1].active = pokemon("csv5-002")
			state.players[1].active.evolution_stack_ids.assign(["csv5-001"])
			if kind == "devolution_ko":
				state.players[1].active.damage_counters = int(cards["csv5-001"].hp) / 10
				state.players[1].bench[0] = pokemon("csv5-028")
		"tm_evolution":
			state.players[0].active.attached_tool_id = "csv5-119"
			state.players[0].bench[0] = pokemon("csv5-001")
			state.players[0].deck.assign(["csv5-002", "sv1-ener-2"])
		"named_energy":
			state.players[0].active = pokemon("csv5-081", ["sv1-ener-7"])
			state.players[0].bench[0] = pokemon("csv5-081")
			state.players[0].deck.assign(["sv1-ener-7", "sv1-ener-2"])
		"bench_limit":
			state.players[0].bench[0] = pokemon("csv5-073")
			for index in 5: state.players[1].bench[index] = pokemon("csv5-001", ["sv1-ener-1"])
		"doll":
			state.players[0].active = pokemon("csv5-115", ["sv1-ener-2"])
			state.players[0].bench[0] = pokemon("csv5-014")
	return state

func run_case(kind: String, mode: String, viewer: int) -> void:
	root.get_node("AppSettings").animation_mode = mode
	var before := fixture(kind)
	var native: Variant = session(before)
	table.clear_presentation_for_resync()
	table.update_view(BattleViewModel.player_view_state(before, viewer), viewer, [], "", false, "local")
	await rendered(4)
	if kind == "doll":
		var doll := table.presentation_runtime._feedback_card({"player": 0, "slot": "active"})
		var entity: CardEntity3D = table.render3d.world.entities.get(table.render3d._key(doll))
		check(entity != null and entity.face_down, "Doll must display its back while in play")
	var step: Dictionary
	if kind == "bench_limit": step = act(native, "RETREAT", -1, "bench_0")
	elif kind == "doll": step = act(native, "USE_ABILITY")
	else: step = act(native, "DECLARE_ATTACK", 0 if kind == "named_energy" else 1)
	var record := {"key": "%s-%s-p%d" % [kind, mode, viewer], "kind": kind, "mode": mode,
		"viewer": viewer, "frames": 0, "moving_cards": 0, "steps": 0}
	for index in 10:
		var after := GameState.from_snapshot(native.snapshot())
		await animate_step(after, step, record, index)
		var owner := 0
		var pending: Variant = native.pending_choice(owner)
		if not pending is Dictionary or pending.is_empty():
			owner = 1
			pending = native.pending_choice(owner)
		if not pending is Dictionary or pending.is_empty(): break
		var indices: Array = []
		for choice_index in mini(int(pending.max_select), pending.options.size()): indices.append(choice_index)
		step = choose(native, owner, indices)
	check(table.card_motion_layer.active_motion_count() == 0 and table.presentation_runtime.slot_covers.is_empty(), record.key + ": animation left stale cards")
	if mode != "reduced": check(record.moving_cards > 0, record.key + ": rule changes had no card flight")
	records.append(record)

func animate_step(after: GameState, step: Dictionary, record: Dictionary, index: int) -> void:
	var events: Array[Dictionary] = []
	for event in PresentationEvent.normalize_all(step.get("events", []), after.revision, 0):
		var visible := PresentationEvent.for_player(event, record.viewer)
		if not visible.is_empty(): events.append(visible)
	var started_ids: Dictionary = {}
	var started := func(event: Dictionary) -> void:
		var id := str(event.event_id)
		check(not started_ids.has(id), record.key + ": event replayed twice")
		started_ids[id] = true
		if event.event_type == "pokemon_evolved" and record.mode != "reduced":
			var cover := table.presentation_runtime._feedback_card({"player": 0, "slot": "bench_0"})
			check(cover != null and cover.card_id == "csv5-001", record.key + ": evolution face changed before card landing")
		if event.event_type == "pokemon_ko" and record.kind == "devolution_ko":
			check(event.target.player == 1 and event.target.slot == "active" and event.card_id == "csv5-001", record.key + ": knockout targets the wrong physical Pokemon")
			if record.mode != "reduced":
				var cover := table.presentation_runtime._feedback_card({"player": 1, "slot": "active"})
				check(cover != null and cover.card_id == "csv5-001", record.key + ": knockout did not show the devolved form")
	table.director.event_started.connect(started)
	var handle := table.submit_transition(BattleTransitionRequest.create(
		BattleViewModel.capture_player_view(after, record.viewer, [], "", false, "local"),
		events, 0, BattleTransitionRequest.CAUSE_CHOICE, "%s-%d" % [record.key, index]))
	var seen: Dictionary = {}
	var frames := 0
	while not handle.is_completed() and frames < 600:
		await rendered(1)
		frames += 1
		for token in table.card_motion_layer.entities:
			if is_instance_valid(token) and token.visible: seen[token.get_instance_id()] = true
		if graphics and record.mode == "standard" and record.viewer == 0 and frames == 15:
			root.get_texture().get_image().save_png(OUTPUT.path_join("%s-%d-flight.png" % [record.key, index]))
	table.director.event_started.disconnect(started)
	check(handle.is_completed(), record.key + ": transition never completed")
	await rendered(3)
	for owner in 2:
		for slot in ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]:
			var expected: PokemonState = after.get_player(owner).active if slot == "active" else after.get_player(owner).bench[int(slot.trim_prefix("bench_"))]
			var card := table.presentation_runtime._feedback_card({"player": owner, "slot": slot})
			if expected != null: check(card != null and card.card_id == expected.card_id, record.key + ": board face does not match rules at " + slot)
	for card in table.opponent_hand_views:
		if not card.visible: continue
		var entity: CardEntity3D = table.render3d.world.entities.get(table.render3d._key(card))
		check(entity != null and entity.face_down and entity.face_texture == null, record.key + ": animation exposed opponent hand")
	record.frames += frames
	record.moving_cards += seen.size()
	record.steps += 1
	if graphics and record.mode == "standard" and record.viewer == 0:
		root.get_texture().get_image().save_png(OUTPUT.path_join("%s-%d-settled.png" % [record.key, index]))

func rendered(frames: int) -> void:
	for _frame in frames:
		await process_frame
		if graphics: await RenderingServer.frame_post_draw
		else: table.render3d.sync_surfaces()

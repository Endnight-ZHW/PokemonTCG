extends SceneTree

var failures: Array[String] = []
var cards: Dictionary

func _init() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func base_state(attacker: String, defender: String) -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 3
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	for player in state.players:
		player.deck.assign(["sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "sv1-ener-2"])
		player.prizes.assign(["sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "sv1-ener-2"])
	state.players[0].active = pokemon(attacker)
	state.players[1].active = pokemon(defender)
	return state

func pokemon(id: String, energy: Array = []) -> PokemonState:
	var value := PokemonState.new(id)
	value.energy_card_ids.assign(energy)
	value.placed_this_turn = false
	return value

func session(state: GameState) -> Variant:
	var result: Variant = ClassDB.instantiate("NativeRulesSession")
	if not result.set_catalog(cards):
		check(false, "CSV5 native catalog rejected: " + str(result.get_catalog_error()))
		quit(1)
		return result
	var loaded: Dictionary = result.load_scenario(state.snapshot(), 24681, {})
	check(loaded.get("success", false), "CSV5 scenario rejected: " + str(loaded.get("error_code")))
	return result

func action(native: Variant, kind: String, attack_index: int = -1, target_slot: String = "") -> Dictionary:
	var query: Dictionary = native.legal_actions(0)
	for group in query.get("groups", []):
		if group.kind != kind: continue
		if attack_index >= 0 and group.payload.get("attack_index", -1) != attack_index: continue
		var targets: Array = group.get("targets", [])
		var target: Variant = targets[0] if not targets.is_empty() else null
		if not target_slot.is_empty():
			var found := false
			for candidate in targets:
				if candidate.get("slot") == target_slot:
					target = candidate
					found = true
			if not found: continue
		return {"schema_version": 4, "action_id": "csv5-test-%d" % int(query.base_revision),
			"base_revision": query.base_revision, "actor": 0, "kind": kind,
			"source": group.source, "target": target, "payload": group.payload}
	return {}

func act(native: Variant, kind: String, index: int = -1, target: String = "") -> Dictionary:
	var selected := action(native, kind, index, target)
	check(not selected.is_empty(), "Missing legal action: " + kind)
	if selected.is_empty(): return {"success": false}
	var result: Dictionary = native.apply_action(selected)
	check(result.get("success", false), "Action failed: " + str(result.get("error_code")))
	return result

func choose(native: Variant, player: int, indices: Array) -> Dictionary:
	var view: Variant = native.pending_choice(player)
	check(view is Dictionary and not view.is_empty(), "Expected choice missing")
	if not view is Dictionary or view.is_empty(): return {"success": false}
	var selected: Array = []
	for index in indices:
		if index >= view.options.size():
			check(false, "Missing choice option")
			return {"success": false}
		selected.append(view.options[index].option_id)
	var result: Dictionary = native.apply_choice({"request_id": view.request_id, "option_ids": selected, "cancelled": false})
	check(result.get("success", false), "Choice failed: " + str(result.get("error_code")))
	return result

func run() -> void:
	cards = CardCatalog.shared().cards.duplicate(true)
	if "--staged" in OS.get_cmdline_user_args():
		var staged: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://../.cache/csv5_authoring.json"))
		for id in staged.cards:
			var card: Dictionary = staged.cards[id]
			card["compiled_trainer_effects"] = card.get("commands", [])
			for block in card.get("attacks", []) + card.get("abilities", []):
				block["compiled_effects"] = block.get("commands", [])
			cards[id] = card
	check(cards.size() == 341, "CSV5 release must contain 341 cards")
	if not cards.has("csv5-075"):
		quit(1)
		return
	var state := base_state("csv5-075", "csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2"])
	state.players[1].prizes.resize(4)
	var native: Variant = session(state)
	act(native, "DECLARE_ATTACK", 0)
	check(native.snapshot().players[1].active.damage_counters == 24, "Charizard did not scale with opponent prizes")
	state = base_state("csv5-015", "csv5-028")
	state.players[0].hand.assign(["csv5-075"])
	native = session(state)
	act(native, "EVOLVE", -1, "active")
	var choice: Variant = native.pending_choice(0)
	check(choice is Dictionary and choice.get("request_type") == "confirm_trigger", "Evolution ability did not offer optional activation")
	check(native.pending_choice(1) == null or native.pending_choice(1).is_empty(), "Opponent received private evolution choice")
	choose(native, 0, [1])
	state = base_state("csv5-014", "csv5-015")
	state.players[0].active.attached_tool_id = "csv5-120"
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[1].active.evolution_stack_ids.assign(["csv5-014"])
	native = session(state)
	act(native, "DECLARE_ATTACK", 1)
	# Charmeleon's printed ability prevents the devolution effect.
	check(native.snapshot().players[1].active.card_id == "csv5-015", "Devolution bypassed Charmeleon protection")
	check(native.snapshot().players[0].active.attached_tool_id == "", "Technical Machine was not discarded at end of turn")
	state = base_state("csv5-014", "csv5-002")
	state.players[0].active.attached_tool_id = "csv5-120"
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[1].active.evolution_stack_ids.assign(["csv5-001"])
	native = session(state)
	act(native, "DECLARE_ATTACK", 1)
	check(native.snapshot().players[1].active.card_id == "csv5-001" and "csv5-002" in native.snapshot().players[1].hand, "Devolution did not return top evolution to hand")
	state = base_state("csv5-014", "csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[0].bench[0] = pokemon("csv5-073")
	for index in 5: state.players[1].bench[index] = pokemon("csv5-001")
	native = session(state)
	act(native, "RETREAT", -1, "bench_0")
	choose(native, 0, [0])
	choice = native.pending_choice(1)
	check(choice is Dictionary and choice.get("min_select") == 2, "Glimmora did not require opponent to discard excess bench")
	choose(native, 1, [0, 1])
	var occupied := 0
	for entry in native.snapshot().players[1].bench:
		if entry is Dictionary: occupied += 1
	check(occupied == 3, "Bench limit choice did not leave three Pokemon")
	run_trigger_cases()
	run_selection_cases()
	run_all_printed_attacks()
	run_abilities_and_trainers()
	run_doll_opening()
	run_protection_cases()
	run_conditional_cases()
	if failures.is_empty(): print("CSV5_RULES_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)

func settle(native: Variant, label: String, select_max: bool = true) -> void:
	for step in 40:
		var pending: Variant = native.pending_choice(0)
		var owner := 0
		if not pending is Dictionary or pending.is_empty():
			owner = 1
			pending = native.pending_choice(1)
		if not pending is Dictionary or pending.is_empty(): return
		var count := int(pending.max_select if select_max else pending.min_select)
		var indices: Array = []
		var energy_indices: Array = []
		for index in pending.options.size():
			if indices.size() >= count: break
			var option: Dictionary = pending.options[index]
			var energy_index: Variant = int(str(option.option_id).get_slice(":", 1)) if str(option.option_id).begins_with("energy:") else null
			if energy_index != null and energy_index in energy_indices: continue
			energy_indices.append(energy_index)
			indices.append(index)
		if pending.allow_duplicates and not pending.options.is_empty():
			while indices.size() < count: indices.append(0)
		var before := failures.size()
		choose(native, owner, indices)
		if failures.size() > before:
			check(false, "Resolution scenario: " + label + " / " + str(pending.request_type))
			return
	check(false, "Choice loop did not finish: " + label)

func run_trigger_cases() -> void:
	var state := base_state("csv5-028", "csv5-043")
	state.players[1].bench[0] = pokemon("csv5-042") # Plusle enables Minun, once per attachment.
	state.players[1].bench[1] = pokemon("csv5-043")
	state.players[0].active.damage_counters = 5
	state.players[0].hand.assign(["csv5-129"])
	var native: Variant = session(state)
	act(native, "ATTACH_ENERGY", -1, "active")
	check(native.snapshot().players[0].active.damage_counters == 4, "Medical Energy must heal 30 before nonstacking Minun counters")
	state = base_state("csv5-028", "csv5-043")
	state.players[0].hand.assign(["sv1-ener-2"])
	state.players[0].bench[0] = pokemon("csv5-070")
	native = session(state)
	act(native, "ATTACH_ENERGY", -1, "bench_0")
	choose(native, 0, [0])
	check(native.snapshot().players[0].active.card_id == "csv5-070", "Minior did not switch after hand attachment")
	for activate in [false,true]:
		state = base_state("csv5-028", "csv5-043")
		state.players[1].bench[0] = pokemon("csv5-042")
		state.players[0].bench[0] = pokemon("csv5-070")
		state.players[0].hand.assign(["sv1-ener-2"])
		native = session(state)
		act(native,"ATTACH_ENERGY",-1,"bench_0")
		check(native.snapshot().players[0].bench[0].damage_counters == 0, "Opponent trigger resolved before own Minior choice")
		choose(native,0,[0 if activate else 1])
		var recipient: Dictionary = native.snapshot().players[0].active if activate else native.snapshot().players[0].bench[0]
		check(recipient.card_id == "csv5-070" and recipient.damage_counters == 2, "Minun trigger lost the attachment recipient after optional switch")
	state = base_state("csv5-115", "csv5-028")
	state.players[0].bench[0] = pokemon("csv5-014")
	native = session(state)
	check(action(native, "RETREAT").is_empty(), "Doll must not retreat")
	act(native, "USE_ABILITY")
	settle(native, "doll discard")
	check("csv5-115" in native.snapshot().players[0].discard, "Doll did not discard itself")
	check(native.snapshot().players[1].prizes.size() == 6, "Doll self-discard awarded prizes")
	state = base_state("csv5-075", "csv5-115")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2"])
	state.players[1].bench[0] = pokemon("csv5-028")
	native = session(state)
	act(native, "DECLARE_ATTACK", 0)
	settle(native, "doll KO")
	check(native.snapshot().players[0].prizes.size() == 6, "Doll KO awarded prizes")
	check("csv5-115" in native.snapshot().players[1].discard, "Doll failed to reach KO at 120 HP")
	state = base_state("csv5-112", "csv5-068")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2", "sv1-ener-2"])
	state.players[1].active.attached_tool_id = "csv5-118"
	native = session(state)
	act(native, "DECLARE_ATTACK", 0)
	check(native.snapshot().players[0].active.damage_counters == 6, "Stunfisk did not add five reactive counters alongside recoil")
	state = base_state("csv5-007", "csv5-028")
	native = session(state)
	act(native, "END_TURN")
	check(native.snapshot().players[1].active.damage_counters == 1, "Trevenant checkup counters missing")
	state = base_state("csv5-098", "csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-8", "sv1-ener-8"])
	state.players[1].active.damage_counters = 4
	state.players[1].bench[0] = pokemon("csv5-014")
	native = session(state)
	act(native, "DECLARE_ATTACK", 0)
	settle(native, "Kingambit direct KO")
	check("csv5-028" in native.snapshot().players[1].discard, "Direct KO failed")
	state = base_state("csv5-075", "csv5-014")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2"])
	state.players[0].hand.assign(["csv5-001", "csv5-002"])
	state.players[1].active.attached_tool_id = "csv5-117"
	state.players[1].bench[0] = pokemon("csv5-028")
	native = session(state)
	act(native, "DECLARE_ATTACK", 0)
	var pending: Variant = native.pending_choice(1)
	check(pending is Dictionary and not pending.is_empty(), "Curse Duster did not offer blind choice")
	if pending is Dictionary:
		for option in pending.get("options", []):
			check(not option.has("card_id"), "Blind discard leaked hand identity")
	settle(native, "Curse Duster")
	check(native.snapshot().players[0].hand.size() == 2, "Curse Duster discard or subsequent prize draw incorrect")

func run_selection_cases() -> void:
	var state := base_state("csv5-015", "csv5-028")
	state.players[0].hand.assign(["csv5-075"])
	state.players[0].bench[0] = pokemon("csv5-014")
	var native: Variant = session(state)
	act(native, "EVOLVE", -1, "active")
	choose(native, 0, [0])
	var pending: Dictionary = native.pending_choice(0)
	var energy_options: Array = []
	for i in pending.options.size():
		var option: Dictionary = pending.options[i]
		var ref: Dictionary = option.get("ref", {})
		if (energy_options.is_empty() and ref.get("slot") == "active") or (energy_options.size() == 1 and ref.get("slot") == "bench_0" and str(option.option_id).begins_with("energy:1:")): energy_options.append(i)
	choose(native, 0, energy_options)
	check(native.snapshot().players[0].active.energy_card_ids.size() == 1 and native.snapshot().players[0].bench[0].energy_card_ids.size() == 1, "Charizard must allow splitting Fire Energy across Pokemon")
	state = base_state("csv5-083", "csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-7"])
	state.players[0].hand.assign(["csv5-001", "csv5-002"])
	native = session(state)
	act(native, "DECLARE_ATTACK", 0)
	choose(native, 0, [])
	check(native.snapshot().players[0].hand.size() == 5, "Absol zero discard must still draw to five")
	state = base_state("csv5-014", "csv5-028")
	state.players[0].hand.assign(["csv5-124"])
	state.players[0].discard.assign(["csv5-125", "csv5-124"])
	state.players[0].deck.assign(["csv5-001", "csv5-014", "csv5-107", "csv5-075"])
	native = session(state)
	act(native, "PLAY_TRAINER")
	pending = native.pending_choice(0)
	check(pending.max_select == 3, "Paldean Student must count both earlier same-name Supporters")
	for option in pending.options: check(option.get("card_id") != "csv5-075", "Rule Box Pokemon entered Student search")
	settle(native, "Paldean Student")
	state = base_state("csv5-014", "csv5-009")
	state.players[0].hand.assign(["csv5-116"])
	state.players[0].active.damage_counters = 1
	native = session(state)
	check(action(native, "PLAY_TRAINER").is_empty(), "Counter Catch-up Milk allowed without prize deficit")

func run_all_printed_attacks() -> void:
	var tested := 0
	for id in cards:
		if not str(id).begins_with("csv5-") or cards[id].supertype != "Pokémon": continue
		for attack_index in cards[id].attacks.size():
			var state := base_state(id, "csv5-028")
			state.players[0].active.damage_counters = 1
			state.players[1].active.damage_counters = 1
			state.players[0].bench[0] = pokemon("csv5-081")
			state.players[0].bench[1] = pokemon("csv5-028")
			state.players[1].bench[0] = pokemon("csv5-001")
			state.players[1].bench[0].damage_counters = 1
			state.players[0].bench[1].damage_counters = 1
			state.players[0].active.attached_tool_id = "csv5-118"
			state.players[1].active.attached_tool_id = "csv5-118"
			state.players[0].hand.assign(["csv5-001", "sv1-ener-1", "sv1-ener-2", "sv1-ener-6", "sv1-ener-5"])
			state.players[1].hand.assign(["csv5-001", "sv1-ener-1", "csv5-123"])
			for energy in range(1, 9):
				for copy_index in 4:
					state.players[0].active.energy_card_ids.append("sv1-ener-%d" % energy)
					state.players[0].deck.append("sv1-ener-%d" % energy)
					state.players[0].discard.append("sv1-ener-%d" % energy)
			state.players[0].deck.append_array(["csv5-001", "csv5-002", "csv5-121"])
			var native: Variant = session(state)
			var label := "%s attack %d" % [id, attack_index]
			var before := failures.size()
			act(native, "DECLARE_ATTACK", attack_index)
			if failures.size() == before: settle(native, label)
			if failures.size() != before: check(false, label)
			tested += 1
	print("CSV5_PRINTED_ATTACK_SCENARIOS ", tested)

func run_abilities_and_trainers() -> void:
	for id in cards:
		if not str(id).begins_with("csv5-"): continue
		var card: Dictionary = cards[id]
		if card.supertype == "Pokémon":
			for ability in card.abilities:
				if ability.trigger == "passive": continue
				var state := base_state(id, "csv5-028")
				state.players[0].active.damage_counters = 4
				state.players[0].bench[0] = pokemon("csv5-070")
				state.players[0].hand.assign(["sv1-ener-5"])
				state.players[1].hand.assign(["sv1-ener-2", "csv5-129", "csv5-123"])
				if ability.trigger == "on_evolve":
					for prior in cards:
						if cards[prior].name == card.evolves_from:
							state.players[0].active.card_id = prior
							break
					state.players[0].hand.append(id)
				var native: Variant = session(state)
				act(native, "EVOLVE" if ability.trigger == "on_evolve" else "USE_ABILITY")
				settle(native, id + " ability " + ability.name)
		elif card.supertype == "Trainer" and id != "csv5-115":
			var state := base_state("csv5-014", "csv5-028")
			state.players[0].hand.assign([id, "csv5-075"])
			state.players[0].active.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2"])
			state.players[0].active.damage_counters = 2
			state.players[0].bench[0] = pokemon("csv5-070")
			state.players[1].bench[0] = pokemon("csv5-014")
			state.players[0].discard.assign(["sv1-ener-2"])
			state.players[1].prizes.resize(3)
			state.players[0].was_ko_by_attack = true
			state.players[0].deck.assign(["csv5-001", "csv5-014", "csv5-119", "csv5-014"])
			state.players[1].hand.assign(["csv5-124", "csv5-125", "csv5-001"])
			var native: Variant = session(state)
			act(native, "PLAY_TRAINER")
			settle(native, id + " Trainer")
			if card.trainer_type == "Stadium":
				check(native.snapshot().stadium_card_id == id, "Stadium was not placed")
				check(native.snapshot().players[0].hand.size() == 1, "Stadium incorrectly searched on placement")
				act(native, "USE_STADIUM")
				settle(native, "Town Store activation")
				check("csv5-119" in native.snapshot().players[0].hand, "Town Store failed to search Tool")
				check(action(native,"USE_STADIUM").is_empty(), "Stadium reused in same turn")

func run_doll_opening() -> void:
	var deck: Array[String] = []
	for i in 4: deck.append_array(["csv5-115", "csv5-014"])
	for i in 52: deck.append("sv1-ener-2")
	var native: Variant = ClassDB.instantiate("NativeRulesSession")
	check(native.set_catalog(cards), "Doll opening catalog failed")
	var covered := false
	for seed_value in 100:
		native = ClassDB.instantiate("NativeRulesSession")
		var started: Dictionary = native.create(cards, [deck, deck], {"forced_first": 0}, seed_value + 1)
		check(started.get("success", false), "Doll opening failed: " + str(started.get("error_code")))
		var pending: Variant = native.pending_choice(0)
		var owner := 0
		if not pending is Dictionary or pending.is_empty():
			owner = 1
			pending = native.pending_choice(1)
		if not pending is Dictionary or pending.is_empty(): continue
		check(pending.request_type == "confirm", "Unexpected doll-only opening choice")
		choose(native, owner, [1]) # Exercise voluntary mulligan and its persisted continuation.
		settle(native, "Doll voluntary opening mulligan")
		check(native.snapshot().mulligan_count[owner] >= 1, "Doll voluntary mulligan count missing")
		covered = true
		break
	check(covered, "Did not exercise a doll-only opening")

func run_protection_cases() -> void:
	var state := base_state("csv5-072","csv5-015")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-6","sv1-ener-6"])
	var native: Variant = session(state)
	act(native,"DECLARE_ATTACK",0)
	check("POISONED" not in native.snapshot().players[1].active.status_conditions, "Charmeleon did not block poison effect")
	state = base_state("csv5-028","csv5-014")
	state.players[0].active.attached_tool_id = "csv5-120"
	native = session(state)
	check(action(native,"DECLARE_ATTACK",2).is_empty(), "Unfunded TM became a free attack")
	state = base_state("csv5-014","csv5-028")
	state.players[0].hand.assign(["csv5-115"])
	native = session(state)
	check(action(native,"PLAY_TRAINER").is_empty(), "Doll was playable after setup")
	state = base_state("sv2-tatsu","csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-3"])
	state.players[0].deck.assign(["sv1-ener-3","sv1-ener-3","sv1-ener-3"])
	state.players[0].bench[0] = pokemon("csv5-115")
	native = session(state)
	act(native,"DECLARE_ATTACK",0)
	var doll_target := false
	var doll_choice: Variant = native.pending_choice(0)
	if doll_choice is Dictionary:
		for option in doll_choice.options:
			if option.get("ref",{}).get("card_id") == "csv5-115": doll_target = true
	check(doll_target, "Doll was not treated as a Basic Pokemon for in-play energy targeting")
	settle(native,"Doll Basic targeting")
	for protected in [false,true]:
		state = base_state("csv5-062","csv5-028")
		state.players[0].active.energy_card_ids.assign(["sv1-ener-6","sv1-ener-6"])
		if protected: state.players[1].active.attached_tool_id = "csv5-118"
		native = session(state)
		act(native,"DECLARE_ATTACK",0)
		check(native.snapshot().players[1].discard.size() == (0 if protected else 2), "Backpack mill protection incorrect")
		state = base_state("csv5-014","csv5-002")
		state.players[0].active.attached_tool_id = "csv5-120"
		state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
		state.players[1].active.evolution_stack_ids.assign(["csv5-001"])
		state.players[1].active.damage_counters = 5
		state.players[1].bench[0] = pokemon("csv5-010")
		if protected: state.players[1].active.energy_card_ids.assign(["sv1-ener-1"])
		native = session(state)
		act(native,"DECLARE_ATTACK",1)
		settle(native,"Toedscruel protection and devolution KO")
		check(("csv5-001" in native.snapshot().players[1].discard) != protected, "Devolution HP knockout or energized protection incorrect")
	for hp_full in [false,true]:
		state = base_state("csv5-049","csv5-021")
		state.players[0].active.energy_card_ids.assign(["sv1-ener-4","sv1-ener-4","sv1-ener-4"])
		if not hp_full: state.players[1].active.damage_counters = 1
		native = session(state)
		var step := act(native,"DECLARE_ATTACK",0)
		var amount := attack_damage_from(step)
		check(amount == maxi(0,int(cards["csv5-049"].attacks[0].damage) - (80 if hp_full else 0)), "Armarouge full-HP reduction incorrect")
	state = base_state("csv5-052","csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-5","sv1-ener-5","svi-dtur"])
	native = session(state)
	act(native,"DECLARE_ATTACK",1)
	var pending: Variant = native.pending_choice(0)
	if pending is Dictionary:
		for index in pending.options.size():
			if pending.options[index].get("ref",{}).get("card_id") == "svi-dtur":
				choose(native,0,[index])
				break
	check("svi-dtur" in native.snapshot().players[0].hand, "Returning two energy units did not allow one Double Turbo Energy")
	state = base_state("csv5-088","csv5-028")
	native = session(state)
	act(native,"USE_ABILITY")
	pending = native.pending_choice(0)
	check(pending is Dictionary and pending.presentation.get("revealed_card_ids",[]).size() == 1, "Top-deck inspection did not expose a readable card")
	check(native.pending_choice(1) == null, "Opponent received private inspection")
	settle(native,"Malamar two private inspections")
	state = base_state("csv5-037","csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-3","sv1-ener-3","sv1-ener-3"])
	state.players[1].bench[0] = pokemon("csv5-039")
	state.players[1].bench[1] = pokemon("csv5-014")
	native = session(state)
	act(native,"DECLARE_ATTACK",0)
	check(native.snapshot().players[1].bench[0].damage_counters == 0 and native.snapshot().players[1].bench[1].damage_counters == 1, "Tera bench damage prevention incorrect")
	var original: Dictionary = cards["csv5-014"].duplicate(true)
	var counter_effect := {"op":"place_counters", "args":{"amount":3,"player":"opponent","target":"damaged_bench"},"branches":{}}
	cards["csv5-014"].attacks = [{"name":"counter fixture","text":"","cost":[],"damage":0,"compiled_effects":[counter_effect]}]
	cards["csv5-014"].abilities = [{"name":"ability fixture","trigger":"once_per_turn","text":"","compiled_effects":[counter_effect]}]
	for from_attack in [false,true]:
		state = base_state("csv5-014","csv5-028")
		state.players[1].bench[0] = pokemon("csv5-092")
		state.players[1].bench[1] = pokemon("csv5-001")
		state.players[1].bench[1].damage_counters = 1
		native = session(state)
		act(native,"DECLARE_ATTACK" if from_attack else "USE_ABILITY",0 if from_attack else -1)
		check(native.snapshot().players[1].bench[1].damage_counters == (1 if from_attack else 4), "Jirachi must block Basic attack counters but not Ability counters")
	cards["csv5-014"] = original
	for id in cards:
		if not str(id).begins_with("csv5-"): continue
		var base: String = str(cards[id].get("gameplay_identity",id))
		check(cards[id].attacks == cards[base].attacks and cards[id].abilities == cards[base].abilities and cards[id].compiled_trainer_effects == cards[base].compiled_trainer_effects, "Alternative printing changed rules: " + id)

func attack_damage_from(step: Dictionary) -> int:
	for event in step.get("events",[]):
		if event.get("event_type") == "damage_dealt" and event.get("data",{}).get("target_player") == 1 and event.get("data",{}).get("target_slot") == "active":
			return int(event.data.get("amount",0))
	return 0

func run_conditional_cases() -> void:
	for id in cards:
		if not str(id).begins_with("csv5-") or cards[id].get("gameplay_identity",id) != id: continue
		for index in cards[id].attacks.size():
			var attack: Dictionary = cards[id].attacks[index]
			for command in attack.compiled_effects:
				if command.op != "conditional_damage": continue
				for fulfilled in [false,true]:
					var state := base_state(id,"csv5-028")
					for energy in [1,2,4,5,6,7,8]:
						for copy_index in 4: state.players[0].active.energy_card_ids.append("sv1-ener-%d" % energy)
					if command.args.condition != "self_has_water": state.players[0].active.energy_card_ids.append_array(["sv1-ener-3","sv1-ener-3","sv1-ener-3"])
					match str(command.args.condition):
						"self_damaged": state.players[0].active.damage_counters = 1 if fulfilled else 0
						"behind_on_prizes": state.players[1].prizes.resize(5 if fulfilled else 6)
						"ko_by_attack_damage_last_turn": state.players[0].was_ko_by_attack = fulfilled
						"self_has_water":
							if fulfilled: state.players[0].active.energy_card_ids.append("sv1-ener-3")
						"opponent_prizes_2_or_4": state.players[1].prizes.resize(2 if fulfilled else 6)
						"opponent_poisoned": state.players[1].active.status_conditions.assign(["POISONED"] if fulfilled else [])
						"opponent_active_evolved": state.players[1].active.card_id = "csv5-028" if fulfilled else "csv5-039"
						"self_has_tool": state.players[0].active.attached_tool_id = "csv5-118" if fulfilled else ""
						"own_deck_le_3": state.players[0].deck.resize(3 if fulfilled else 5)
					var native: Variant = session(state)
					var step := act(native,"DECLARE_ATTACK",index)
					check(attack_damage_from(step) == int(attack.damage) + (int(command.args.bonus) if fulfilled else 0), "%s conditional damage %s=%s incorrect" % [id,command.args.condition,fulfilled])

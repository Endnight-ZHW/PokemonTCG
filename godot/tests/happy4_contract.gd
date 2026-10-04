extends SceneTree

var failures: Array[String] = []
var cases := 0
var catalog: CardCatalog


func _initialize() -> void:
	catalog = CardCatalog.shared()
	_check_catalog()
	_check_attacks()
	_check_metal_maker()
	_check_trainers()
	_check_tools()
	_check_edge_cases()
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("HAPPY4_CONTRACT_OK cases=%d" % cases)
	quit(0 if failures.is_empty() else 1)


func check(ok: bool, message: String) -> void:
	cases += 1
	if not ok: failures.append(message)


func fixture(id: String = "csvh4-022") -> GameState:
	var s := GameState.new()
	s.revision = 100
	s.setup_stage = GameState.SETUP_COMPLETE
	s.active_player_idx = 0
	s.first_player_idx = 1
	s.turn_number = 4
	s.phase = "MAIN"
	for p in s.players:
		p.active = PokemonState.new("csvh4-020")
		p.prizes.assign(["sv1-ener-1", "sv1-ener-1", "sv1-ener-1"])
		p.deck.assign(["sv1-151", "sv1-153", "sv1-ener-1", "sv1-ener-8", "sv1-ener-4", "sv1-ener-5"])
	s.players[0].active = PokemonState.new(id)
	s.players[1].bench[0] = PokemonState.new("csvh4-020")
	return s


func session(s: GameState) -> NativeRulesSessionAdapter:
	var a := NativeRulesSessionAdapter.new(catalog)
	check(a.restore(s.snapshot(), 9123), "fixture restore: " + s.players[0].active.card_id)
	return a


func action(a: NativeRulesSessionAdapter, kind: String, id: String, attack: int = -1, actor: int = 0) -> StepResult:
	for candidate in a.legal_actions(actor).concrete_actions():
		var row: Dictionary = candidate.to_dict()
		if candidate.kind == kind and (id.is_empty() or str(row.source.card_id) == id) and (attack < 0 or candidate.attack_index() == attack):
			row["action_id"] = "happy4_%d_%d" % [cases, a.state.revision]
			var result := a.apply_action(row)
			check(result.success, "%s %s: %s" % [kind, id, result.message])
			return result
	check(false, "Missing legal action %s %s attack %d" % [kind, id, attack])
	return StepResult.new(false, "missing_action")


func choose(a: NativeRulesSessionAdapter, step: StepResult, slots: Array = [], zero: bool = false) -> StepResult:
	var guard := 0
	while step.success and step.pending_choice != null:
		guard += 1
		if guard > 12:
			check(false, "Choice chain loop")
			break
		var request := step.pending_choice
		var ids: Array[String] = []
		if request.request_type == "distribute_energy":
			var used: Dictionary = {}
			var per_slot: Dictionary = {}
			for option in request.options:
				var energy := str(option.option_id).get_slice(":", 1)
				var slot := str(option.ref.slot)
				if used.has(energy): continue
				if not slots.is_empty() and slot != str(slots[ids.size() % slots.size()]): continue
				var cap := int(request.presentation.get("max_per_target", 99))
				if int(per_slot.get(slot, 0)) >= cap: continue
				ids.append(option.option_id)
				used[energy] = true
				per_slot[slot] = int(per_slot.get(slot, 0)) + 1
				if ids.size() >= request.max_select: break
		elif not zero or request.min_select > 0:
			for option in request.options.slice(0, mini(request.max_select, request.options.size())):
				ids.append(option.option_id)
		check(a.pending_choice(1 - request.player) == null, "Choice leaked to opponent")
		step = a.apply_choice(ChoiceResponse.new(request.request_id, ids).to_dict())
		check(step.success, "Choice %s: %s" % [request.request_type, step.message])
	return step


func _check_catalog() -> void:
	check(catalog.cards.size() == 177 and catalog.decks.size() == 14, "Catalog inventory")
	var expected := {
		"decidueye": {"csvh4-001":4,"csvh4-002":3,"csvh4-003":4,"csvh4-027":1,"csvh4-025":1,"csvh4-004":1,"sv1-153":3,"sv1-152":2,"csvh4-041":2,"sv1-201":1,"csvh4-049":2,"csvh4-056":1,"sv1-ener-1":16},
		"melmetal": {"csvh4-020":2,"csvh4-015":1,"csvh4-016":2,"csvh4-017":1,"csvh4-018":1,"csvh4-019":3,"csvh4-021":2,"svl-chat":1,"svi-sqwk":1,"sv1-153":4,"csvh4-032":2,"svl-vitb":2,"svf-houb":2,"csvh4-058":1,"sv1-ener-8":16},
		"koraidon": {"csvh4-005":2,"csvh4-009":2,"csvh4-012":1,"csvh4-013":2,"csvh4-014":2,"csvh4-022":4,"svf-hawl":1,"sv1-153":4,"csvh4-034":2,"csvh4-043":2,"csvh4-046":2,"csvh4-059":1,"sv1-ener-2":6,"sv1-ener-6":10},
		"miraidon": {"csvh4-024":2,"csvh4-006":2,"csvh4-007":1,"csvh4-008":1,"csvh4-010":3,"csvh4-011":1,"csvh4-023":2,"csvh4-030":2,"sv1-153":2,"svl-ensw":2,"csvh4-035":2,"csvh4-044":2,"csvh4-051":2,"csvh4-057":1,"sv1-ener-4":8,"sv1-ener-5":8},
	}
	for suffix in expected:
		var counts: Dictionary = expected[suffix].duplicate()
		counts.merge({"sv3-134":1,"sv1-151":4,"sv1-150":2,"sv2-catch":2,"sv1-176":1,"sv2-young":3,"sv1-180":4,"sv1-189":2})
		var actual: Dictionary = {}
		for row in catalog.get_deck("happy4_" + suffix).cards: actual[row.card_id] = int(row.count)
		check(actual == counts, "Screenshot list mismatch: " + suffix)
		check(catalog.expand_deck("happy4_" + suffix).size() == 60, "Deck size: " + suffix)
		check(not DeckVisualCatalog.representative_card(catalog,"happy4_" + suffix).is_empty(), "Representative: " + suffix)
	for id in ["csvh4-022", "csvh4-023", "csvh4-024"]:
		check(catalog.get_card(id).energy_types == ["Dragon"], "Dragon typing: " + id)
	check(catalog.get_card("csvh4-025").hp == 80 and catalog.get_card("svf-farf").hp == 90, "Farfetch'd versions conflated")
	check(catalog.get_card("csvh4-021").hp == 120 and catalog.get_card("svm-zacian").hp == 130, "Zacian versions conflated")


func _check_attacks() -> void:
	for paid in [false, true]:
		var s := fixture("csvh4-003")
		s.players[0].active.energy_card_ids.assign(["sv1-ener-1"])
		if paid: s.players[0].hand.assign(["sv1-ener-1"])
		var a := session(s)
		choose(a, action(a,"DECLARE_ATTACK","csvh4-003",1))
		check(a.state.players[1].active.damage_counters == (17 if paid else 0), "Power Shot payment")
		check(a.state.active_player_idx == 1, "Failed attack must end turn")
	var s := fixture()
	s.players[0].active.energy_card_ids.assign(["sv1-ener-6","sv1-ener-2"])
	s.players[0].bench[0] = PokemonState.new("csvh4-005")
	s.players[0].bench[1] = PokemonState.new("csvh4-012")
	var a := session(s)
	choose(a,action(a,"DECLARE_ATTACK","csvh4-022",0))
	check(a.state.players[1].active.damage_counters == 6,"Ancient count includes active and excludes ordinary Pokemon")
	s = fixture("csvh4-020")
	s.players[0].active.energy_card_ids.assign(["sv1-ener-8","sv1-ener-8","sv1-ener-8","sv1-ener-8"])
	a = session(s)
	choose(a,action(a,"DECLARE_ATTACK","csvh4-020",1))
	check(a.state.players[1].active.damage_counters == 21,"Metal energy damage formula")
	for equal in [false,true]:
		s = fixture("csvh4-011")
		s.players[0].active.energy_card_ids.assign(["sv1-ener-5","sv1-ener-4"])
		if not equal: s.players[1].hand.assign(["sv1-151"])
		a = session(s)
		choose(a,action(a,"DECLARE_ATTACK","csvh4-011",0))
		check(a.state.players[1].active.damage_counters == (17 if equal else 0),"Iron Boulder hand equality")
	s = fixture("csvh4-023")
	s.players[0].active.energy_card_ids.assign(["sv1-ener-4"])
	s.players[0].bench[0] = PokemonState.new("csvh4-024")
	s.players[0].bench[1] = PokemonState.new("csvh4-010")
	a = session(s)
	choose(a,action(a,"DECLARE_ATTACK","csvh4-023",0),["bench_0","bench_1"])
	check(a.state.players[0].bench[0].energy_card_ids.size() == 1 and a.state.players[0].bench[1].energy_card_ids.size() == 1,"Miraidon split attachment")


func _check_metal_maker() -> void:
	for zero in [false,true]:
		var s := fixture("csvh4-017")
		s.players[0].bench[0] = PokemonState.new("csvh4-020")
		s.players[0].deck.assign(["sv1-151","sv1-153","sv1-ener-1","sv1-ener-8","sv1-ener-8","sv1-189"])
		var a := session(s)
		var step := action(a,"USE_ABILITY","csvh4-017")
		check(not step.pending_choice.can_cancel,"Cannot undo Metal Maker after seeing the deck")
		choose(a,step,["active","bench_0"],zero)
		check(a.state.players[0].active.energy_card_ids.size() == (0 if zero else 1),"Metal Maker active target")
		check(a.state.players[0].bench[0].energy_card_ids.size() == (0 if zero else 1),"Metal Maker bench target")
		check(a.state.players[0].deck.slice(-2) == ["sv1-151","sv1-153"],"Metal Maker preserves unviewed deck order")
		check(a.state.players[0].active.used_abilities == ["金属制造者"],"Metal Maker once per turn")


func _check_trainers() -> void:
	for id in ["csvh4-032","csvh4-034","csvh4-035","csvh4-041","csvh4-051","csvh4-056","csvh4-058","csvh4-059"]:
		var s := fixture()
		s.players[0].hand.assign([id,"sv1-ener-1"])
		s.players[0].deck.assign(["sv1-151","csvh4-024","csvh4-003","csvh4-002","sv1-ener-1","sv1-ener-8"])
		var a := session(s)
		var step := action(a,"PLAY_TRAINER",id)
		if id in ["csvh4-032","csvh4-041","csvh4-051","csvh4-058"]:
			check(not step.pending_choice.can_cancel,"Cannot undo a Trainer after inspecting the deck: " + id)
		choose(a,step)
		check(a.pending_choice(0) == null,"Trainer choices finish: " + id)
	var s := fixture()
	s.players[0].bench[0] = PokemonState.new("csvh4-005")
	s.players[0].hand.assign(["csvh4-046"])
	s.players[0].discard.assign(["sv1-ener-2","sv1-ener-6"])
	var a := session(s)
	choose(a,action(a,"PLAY_TRAINER","csvh4-046"),["active","bench_0"])
	check(a.state.players[0].active.energy_card_ids.size() == 1 and a.state.players[0].bench[0].energy_card_ids.size() == 1,"Sada distinct targets")
	check(a.state.players[0].hand.size() == 3,"Sada draws after attachments")
	s = fixture()
	s.players[0].hand.assign(["csvh4-049"])
	s.players[0].discard.assign(["csvh4-024","csvh4-003","sv1-ener-1","sv1-ener-2"])
	a = session(s)
	choose(a,action(a,"PLAY_TRAINER","csvh4-049"))
	check(a.state.players[0].hand.size() == 3 and not "csvh4-024" in a.state.players[0].hand,"Lana excludes rule-box Pokemon")
	s = fixture("csvh4-020")
	s.players[0].active.evolution_stack_ids.assign(["csvh4-019"])
	s.players[0].active.energy_card_ids.assign(["sv1-ener-8"])
	s.players[0].active.attached_tool_id = "svl-vitb"
	s.players[0].bench[0] = PokemonState.new("csvh4-021")
	s.players[0].hand.assign(["csvh4-057"])
	a = session(s)
	choose(a,action(a,"PLAY_TRAINER","csvh4-057"))
	check("csvh4-020" in a.state.players[0].hand and "csvh4-019" in a.state.players[0].hand,"Turo returns entire evolution")
	check("sv1-ener-8" in a.state.players[0].discard and "svl-vitb" in a.state.players[0].discard,"Turo discards attachments")
	check(a.state.pending_promotions == [0], "Turo queues the owner's replacement")
	for candidate in a.legal_actions(0).concrete_actions():
		if candidate.kind == "PROMOTE":
			var promote: Dictionary = candidate.to_dict()
			promote["action_id"] = "happy4_promote"
			check(a.apply_action(promote).success, "Turo replacement selection")
			break
	check(a.state.players[0].active != null,"Turo promotes replacement active")


func _check_tools() -> void:
	for id in ["csvh4-022","csvh4-012"]:
		var s := fixture(id)
		s.players[0].active.status_conditions.assign(["POISONED","PARALYZED"])
		s.players[0].hand.assign(["csvh4-043"])
		var a := session(s)
		choose(a,action(a,"PLAY_TRAINER","csvh4-043"))
		var expected := int(catalog.get_card(id).hp) + (60 if id == "csvh4-022" else 0)
		check(a.state.players[0].active.max_hp(catalog) == expected,"Ancient capsule HP condition")
		check(a.state.players[0].active.status_conditions.is_empty() == (id == "csvh4-022"),"Ancient capsule clears statuses only on Ancient")
	var s := fixture("csvh4-024")
	s.players[0].hand.assign(["csvh4-044"])
	s.players[0].active.energy_card_ids.assign(["sv1-ener-4","sv1-ener-5"])
	s.players[1].active.damage_counters = 1
	var a := session(s)
	choose(a,action(a,"PLAY_TRAINER","csvh4-044"))
	choose(a,action(a,"DECLARE_ATTACK","csvh4-024",0))
	check(a.state.players[1].active.damage_counters == 19,"Future capsule plus damaged target bonus")
	s = fixture("csvh4-001")
	s.players[0].active.energy_card_ids.assign(["sv1-ener-1"])
	s.players[0].hand.assign(["csvh4-044"])
	a = session(s)
	choose(a,action(a,"PLAY_TRAINER","csvh4-044"))
	choose(a,action(a,"DECLARE_ATTACK","csvh4-001",1))
	check(a.state.players[1].active.damage_counters == 1,"Future capsule gives no bonus to an ordinary Pokemon")


func _check_edge_cases() -> void:
	# Required costs must remain payable even when later effects have targets.
	for id in ["csvh4-034", "csvh4-035", "csvh4-059"]:
		var s := fixture()
		s.players[0].hand.assign([id])
		var a := session(s)
		check(not a.legal_actions(0).concrete_actions().any(func(c: GameAction) -> bool: return c.kind == "PLAY_TRAINER"), "Unpayable Trainer: " + id)
	var s := fixture()
	s.players[1].bench[0] = null
	s.players[0].hand.assign(["csvh4-059", "sv1-ener-1"])
	var a := session(s)
	check(not a.legal_actions(0).concrete_actions().any(func(c: GameAction) -> bool: return c.kind == "PLAY_TRAINER"), "Morty cannot pay a cost merely to draw zero")
	# Sada's per-target cap also applies to forged responses, with full rollback.
	s = fixture()
	s.players[0].hand.assign(["csvh4-046"])
	s.players[0].discard.assign(["sv1-ener-2", "sv1-ener-6"])
	s.players[0].bench[0] = PokemonState.new("csvh4-005")
	a = session(s)
	var step := action(a,"PLAY_TRAINER","csvh4-046")
	var ids: Array[String] = []
	for option in step.pending_choice.options:
		if str(option.ref.slot) == "active": ids.append(option.option_id)
	var before_hash := a.state_hash()
	var before_rng := a.rng_state
	var rejected := a.apply_choice(ChoiceResponse.new(step.pending_choice.request_id, ids).to_dict())
	check(not rejected.success and a.state_hash() == before_hash and a.rng_state == before_rng, "Sada rejects two energies on one target atomically")
	choose(a,step,["active","bench_0"])
	# Saving during a private look must preserve its continuation and privacy.
	s = fixture()
	s.players[0].hand.assign(["csvh4-051"])
	s.players[0].deck.assign(["csvh4-002"])
	a = session(s)
	step = action(a,"PLAY_TRAINER","csvh4-051")
	check(step.pending_choice.min_select == 1 and step.pending_choice.max_select == 1,"Rika resolves a one-card deck")
	check(not JSON.stringify(a.view_for(1)).contains("csvh4-002"),"Rika private top card leaks")
	var restored := NativeRulesSessionAdapter.new(catalog)
	check(restored.restore(a.native.snapshot(),a.rng_state),"Restore private look continuation")
	var original_hash := a.state_hash()
	check(restored.state_hash() == original_hash,"Pending restore hash")
	var response := ChoiceResponse.new(step.pending_choice.request_id,[str(step.pending_choice.options[0].option_id)])
	check(a.apply_choice(response.to_dict()).success and restored.apply_choice(response.to_dict()).success,"Resume saved Rika choice")
	check(a.state_hash() == restored.state_hash() and a.rng_state == restored.rng_state,"Resumed choice deterministic")
	# Healing is limited to Ancient Pokemon on the Bench.
	s = fixture("csvh4-009")
	s.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	s.players[0].bench[0] = PokemonState.new("csvh4-022")
	s.players[0].bench[0].damage_counters = 9
	s.players[0].bench[1] = PokemonState.new("csvh4-012")
	s.players[0].bench[1].damage_counters = 9
	a = session(s)
	choose(a,action(a,"DECLARE_ATTACK","csvh4-009",0))
	check(a.state.players[0].bench[0].damage_counters == 0 and a.state.players[0].bench[1].damage_counters == 9,"Ancient-only bench healing")
	# Mawile switches before applying the attack damage to the new Active.
	s = fixture("csvh4-015")
	s.players[0].active.energy_card_ids.assign(["sv1-ener-8","sv1-ener-8"])
	s.players[1].active.damage_counters = 1
	a = session(s)
	choose(a,action(a,"DECLARE_ATTACK","csvh4-015",0))
	check(a.state.players[1].active.damage_counters == 3 and a.state.players[1].bench[0].damage_counters == 1,"Mawile switch before damage")
	# Reactive counters are fixed, rather than scaled by the defending Bench.
	s = fixture("csvh4-001")
	s.players[0].active.energy_card_ids.assign(["sv1-ener-1"])
	s.players[1].active = PokemonState.new("csvh4-030")
	a = session(s)
	choose(a,action(a,"DECLARE_ATTACK","csvh4-001",1))
	check(a.state.players[0].active.damage_counters == 3,"Iron Jugulis reactive counters")
	# A Future capsule permits retreat with no attached Energy.
	s = fixture("csvh4-024")
	s.players[0].hand.assign(["csvh4-044"])
	s.players[0].bench[0] = PokemonState.new("csvh4-010")
	a = session(s)
	choose(a,action(a,"PLAY_TRAINER","csvh4-044"))
	choose(a,action(a,"RETREAT","csvh4-024"))
	check(a.state.players[0].active.card_id == "csvh4-010","Future capsule free retreat")
	# Named attack locks survive one opponent turn and clear on leaving Active.
	s = fixture("csvh4-010")
	s.players[0].active.energy_card_ids.assign(["sv1-ener-5","sv1-ener-5","sv1-ener-4"])
	s.players[0].bench[0] = PokemonState.new("csvh4-008")
	s.players[0].hand.assign(["sv1-150","sv1-150"])
	a = session(s)
	choose(a,action(a,"DECLARE_ATTACK","csvh4-010",1))
	choose(a,action(a,"END_TURN","",-1,1))
	check(not a.legal_actions(0).concrete_actions().any(func(c: GameAction) -> bool: return c.kind == "DECLARE_ATTACK" and c.attack_index() == 1),"Named attack lock next turn")
	choose(a,action(a,"PLAY_TRAINER","sv1-150"))
	choose(a,action(a,"PLAY_TRAINER","sv1-150"))
	check(a.legal_actions(0).concrete_actions().any(func(c: GameAction) -> bool: return c.kind == "DECLARE_ATTACK" and c.attack_index() == 1),"Switch clears named attack lock")

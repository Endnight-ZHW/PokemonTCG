extends SceneTree

const Audit = preload("res://tools/card_printing_audit.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := CardCatalog.shared()
	var cards: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/cards.json"))
	for id in cards:
		var card: Dictionary = cards[id]
		for level in [CardPresentation.DetailLevel.FULL, CardPresentation.DetailLevel.COMPACT]:
			var output := CardPresentation.detail_bbcode(card, catalog, null, level)
			for block in Array(card.attacks) + Array(card.abilities):
				_check(str(block.name) in output and (str(block.text).is_empty() or str(block.text) in output), "%s: truncated or changed ability/attack copy" % id)
			for rule in card.rules:
				_check(str(rule) in output, "%s: missing printed rule" % id)
			_check("【" not in output and "［" not in output, "%s: unnormalized printing markup" % id)
			if card.supertype == "Trainer":
				_check("卡牌效果" in output and "使用规则" in output, "%s: trainer effect/usage grouping missing" % id)
		if card.supertype == "Energy" and "Basic" in card.subtypes:
			_check(str(card.name).begins_with("基本"), "%s: basic Energy printed name missing prefix" % id)
	_check(CardPresentation.attack_damage_text({"damage": 40}) == "40", "Legacy attacks without damage_text lost their fallback")
	_check(CardPresentation.attack_damage_text(cards["svd-absol"].attacks[0]).is_empty(), "Absol invents an unprinted damage number")
	_check(int(cards["svd-absol"].attacks[0].damage) == 10, "Absol's mechanical damage was erased")
	_check("拿取2张奖赏卡" in CardPresentation.detail_bbcode(cards["svd-mabosstiff-ex"], catalog), "Mabosstiff ex prize rule missing")
	_check(cards["svg2-exps"].trainer_type == "Tool", "Source transcription error changed Exp. Share into an Item")
	_check_source_guard(cards["sv1-49"])
	_check_native_corrections()
	if failures.is_empty():
		print("CARD_PRINTING_CONTRACT_OK cards=%d native_cases=5" % cards.size())
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check_source_guard(card: Dictionary) -> void:
	var source := {"name": "拉普拉斯", "details": {
		"cardType": "1", "hp": 130, "attribute": "3", "evolveText": "基础", "retreatCost": 2,
		"weaknessType": "4", "weaknessFormula": "×2",
		"abilityItemList": [{"abilityName": "愤怒冷冻", "abilityCost": "3,3,11", "abilityDamage": "110", "abilityText": card.attacks[0].text}],
	}}
	_check(Audit.mismatches(card, source).is_empty(), "Source audit rejects corrected printing")
	var wrong := card.duplicate(true)
	wrong.weaknesses[0].energy_type = "Metal"
	wrong.attacks[0].damage_text = "110+"
	wrong.attacks[0].text = ""
	wrong.rules = ["unexpected rule"]
	var errors := Audit.mismatches(wrong, source)
	for field in ["weakness", "attacks.0.damage_text", "attacks.0.text", "rules"]:
		_check(field in errors, "Source guard missed field: " + field)
	_check(Audit.printed_text("【无】能量。[说明。]") == "无色能量。（说明。）", "Printing normalization changed icon/note semantics")


func _fixture(attacker: String, defender: String) -> GameState:
	var state := GameState.new()
	state.revision = 100
	state.setup_stage = GameState.SETUP_COMPLETE
	state.active_player_idx = 0
	state.first_player_idx = 1
	state.turn_number = 4
	state.phase = "MAIN"
	state.apply_type_matchups = true
	state.rules_options = {"apply_type_matchups": true}
	for player in state.players:
		player.prizes.assign(["sv1-ener-1", "sv1-ener-2"])
		player.deck.assign(["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"])
	state.players[0].active = PokemonState.new(attacker)
	state.players[1].active = PokemonState.new(defender)
	state.players[0].active.energy_card_ids.assign(["sv1-ener-4", "sv1-ener-5", "sv1-ener-6", "sv1-ener-7"])
	return state


func _attack(adapter: NativeRulesSessionAdapter, fixture: GameState, index: int) -> StepResult:
	_check(adapter.restore(fixture.snapshot(), 9123), "Native printing fixture restore failed")
	for action in adapter.legal_actions(0).concrete_actions():
		if action.kind == "DECLARE_ATTACK" and action.attack_index() == index:
			action.action_id = "printing-audit-attack"
			return adapter.apply_action(action.to_dict())
	_check(false, "No legal attack for " + fixture.players[0].active.card_id)
	return StepResult.new()


func _check_native_corrections() -> void:
	for case in [{"attacker": "svl-chin", "defender": "sv1-49", "counters": 2},
			{"attacker": "svf-rio", "defender": "svg-dram", "counters": 1}]:
		var session := NativeRulesSessionAdapter.new()
		var step := _attack(session, _fixture(case.attacker, case.defender), 0)
		_check(step.success, "Corrected matchup attack failed")
		_check(session.state.players[1].active.damage_counters == case.counters, "Incorrect printed weakness in native damage: %s actual=%d events=%s" % [case.defender, session.state.players[1].active.damage_counters, JSON.stringify(step.events)])
	var absol := NativeRulesSessionAdapter.new()
	var spread := _fixture("svd-absol", "sv1-49")
	spread.players[1].bench[0] = PokemonState.new("svg-dram")
	spread.players[1].bench[1] = PokemonState.new("svf-rio")
	var damage_step := _attack(absol, spread, 0)
	_check(damage_step.success and damage_step.pending_choice == null, "Absol spread attack did not finish")
	for pokemon in [absol.state.players[1].active, absol.state.players[1].bench[0], absol.state.players[1].bench[1]]:
		_check(pokemon.damage_counters == 1, "Absol must damage active and every benched Pokemon for 10")
	for has_bench in [true, false]:
		var session := NativeRulesSessionAdapter.new()
		var fixture := _fixture("sv1-114", "sv1-49")
		if has_bench:
			fixture.players[0].bench[0] = PokemonState.new("svl-chin")
			fixture.players[0].bench[1] = PokemonState.new("svl-emol")
		var step := _attack(session, fixture, 1)
		_check(step.success, "Dedenne attack failed")
		if has_bench:
			var request := step.pending_choice
			_check(request != null, "Dedenne must choose a bench Pokemon after attacking")
			if request == null: continue
			_check(not request.can_cancel and request.min_select == 1, "Dedenne's switch must be mandatory")
			var rejected := session.apply_choice(ChoiceResponse.new(request.request_id, [], true).to_dict())
			_check(not rejected.success, "Native session accepted skipping Dedenne's mandatory switch")
			var response := ChoiceResponse.new(request.request_id, [str(request.options[0].option_id)])
			var switched := session.apply_choice(response.to_dict())
			_check(switched.success and switched.pending_choice == null and session.state.players[0].active.card_id != "sv1-114", "Required switch did not complete")
		else:
			_check(step.pending_choice == null and session.state.players[0].active.card_id == "sv1-114", "Dedenne must finish safely when no bench exists")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

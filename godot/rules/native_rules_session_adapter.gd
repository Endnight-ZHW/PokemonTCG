class_name NativeRulesSessionAdapter
extends RefCounted

var catalog: CardCatalog
var native: Variant
var state: GameState
var rng_state := 0


func _init(p_catalog: CardCatalog = null) -> void:
	catalog = p_catalog if p_catalog != null else CardCatalog.shared()
	if ClassDB.class_exists("NativeRulesSession"):
		native = ClassDB.instantiate("NativeRulesSession")


func is_available() -> bool:
	return native != null and int(native.get_contract().get(
		"native_abi_version", 0)) == 2


func start_match(
	host_deck: String,
	client_deck: String,
	seed: int,
	forced_first: int = -1,
	rules_options: Dictionary = {"apply_type_matchups": false},
	player_names: Array[String] = ["房主", "挑战者"],
) -> StepResult:
	if not is_available():
		return _failure("native_rules_unavailable")
	if not catalog.decks.has(host_deck) or not catalog.decks.has(client_deck):
		return _failure("invalid_deck")
	var result: Dictionary = native.create(
		catalog.native_rules_catalog(),
		[
			catalog.expand_deck(host_deck),
			catalog.expand_deck(client_deck),
		],
		{
			"forced_first": forced_first,
			"public_deck_keys": [host_deck, client_deck],
			"player_names": player_names.duplicate(),
			"rules_profile_id": GameState.RULES_PROFILE_ID,
			"rules_options": rules_options.duplicate(true),
		},
		seed,
	)
	return _adopt(result)


func start_match_from_decks(
	deck_one: Array[String],
	deck_two: Array[String],
	seed: int,
	forced_first: int = -1,
	match_config: Dictionary = {},
) -> StepResult:
	if not is_available():
		return _failure("native_rules_unavailable")
	var config := match_config.duplicate(true)
	config["forced_first"] = forced_first
	config["rules_profile_id"] = GameState.RULES_PROFILE_ID
	if not config.has("rules_options"):
		config["rules_options"] = {"apply_type_matchups": false}
	return _adopt(native.create(
		catalog.native_rules_catalog(),
		[deck_one.duplicate(), deck_two.duplicate()],
		config,
		seed,
	))


func legal_actions(actor: int) -> LegalActionQueryResult:
	if not is_available():
		return LegalActionQueryResult.failure(
			state.revision if state != null else -1,
			"native_rules_unavailable",
			"原生规则会话不可用。",
		)
	return LegalActionQueryResult.from_dict(native.legal_actions(actor))


func pending_choice(viewer: int) -> ChoiceView:
	if not is_available():
		return null
	var value: Variant = native.pending_choice(viewer)
	return ChoiceView.from_dict(value) if value is Dictionary else null


func apply_action(action: Dictionary) -> StepResult:
	if not is_available():
		return _failure("native_rules_unavailable")
	return _adopt(native.apply_action(action))


func apply_choice(response: Dictionary) -> StepResult:
	if not is_available():
		return _failure("native_rules_unavailable")
	return _adopt(native.apply_choice(response))


func surrender(actor: int) -> StepResult:
	if not is_available():
		return _failure("native_rules_unavailable")
	return _adopt(native.surrender(actor))


func view_for(viewer: int) -> Dictionary:
	return native.view_for(viewer) if is_available() else {}


func snapshot() -> Dictionary:
	return native.snapshot() if is_available() else {}


func restore(snapshot_value: Dictionary, p_rng_state: int) -> bool:
	if not ClassDB.class_exists("NativeRulesSession"):
		return false
	var replacement: Variant = ClassDB.instantiate("NativeRulesSession")
	if replacement == null or not replacement.set_catalog(
		catalog.native_rules_catalog()
	):
		return false
	if not replacement.restore(snapshot_value, p_rng_state):
		return false
	native = replacement
	rng_state = native.rng_state()
	state = GameState.from_snapshot(native.snapshot())
	return state != null


func journal() -> Dictionary:
	return native.journal() if is_available() else {}


func state_hash() -> String:
	return str(native.state_hash()) if is_available() else ""


func _adopt(result: Dictionary) -> StepResult:
	if bool(result.get("success", false)):
		var state_value: Variant = result.get("state")
		if not state_value is Dictionary:
			return _failure("invalid_native_state")
		state = GameState.from_dict(Dictionary(state_value))
		if state == null:
			return _failure("invalid_native_state")
		rng_state = int(result.get("rng_state", 0))
	var pending: ChoiceView = null
	if result.get("pending") is Dictionary:
		pending = ChoiceView.from_dict(Dictionary(result["pending"]))
	var events: Array[Dictionary] = []
	for event_value in result.get("events", []):
		if event_value is Dictionary:
			events.append(Dictionary(event_value).duplicate(true))
	return StepResult.new(
		bool(result.get("success", false)),
		str(result.get("message_key", "")),
		pending,
		events,
		int(result.get("winner", state.winner if state != null else -1)),
		bool(result.get("terminal", false)),
		str(result.get("error_code", "")),
	)


func _failure(error_code: String) -> StepResult:
	return StepResult.new(
		false,
		error_code,
		null,
		[],
		state.winner if state != null else -1,
		state.is_terminal() if state != null else false,
		error_code,
	)

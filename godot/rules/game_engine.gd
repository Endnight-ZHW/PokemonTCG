class_name GameEngine
extends RefCounted

## State-projection adapter. All legality, action, choice, RNG and settlement
## semantics live in ptcg_core; this class serves Challenge AI and tools
## without implementing a second rules path.

var catalog: CardCatalog


func _init(p_catalog: CardCatalog = null) -> void:
	catalog = p_catalog if p_catalog != null else CardCatalog.shared()


func setup_game(
	state: GameState,
	deck_one: Array[String],
	deck_two: Array[String],
	rng: PortableRandomSource,
	forced_first: int = -1,
) -> StepResult:
	if state == null or rng == null:
		return _failure(state, "invalid_setup")
	var adapter := NativeRulesSessionAdapter.new(catalog)
	var result := adapter.start_match_from_decks(
		deck_one,
		deck_two,
		rng.get_state(),
		forced_first,
		{
			"public_deck_keys": state.public_deck_keys.duplicate(),
			"player_names": [state.players[0].name, state.players[1].name],
			"rules_options": state.rules_options.merged({
				"apply_type_matchups": state.apply_type_matchups,
			}, true),
		},
	)
	return _adopt_step(state, rng, adapter, result)


func query_legal_action_groups(
	state: GameState,
	actor: int,
) -> LegalActionQueryResult:
	if state == null or actor not in [0, 1]:
		return LegalActionQueryResult.failure(
			state.revision if state != null else -1,
			"invalid_actor",
			"合法动作查询玩家无效。",
		)
	var adapter := _restore_adapter(state, 1)
	if adapter == null:
		return LegalActionQueryResult.failure(
			state.revision, "native_restore_failed", "原生局面恢复失败。")
	return adapter.legal_actions(actor)


func query_legal_action_groups_ephemeral(
	state: GameState,
	actor: int,
) -> LegalActionQueryResult:
	return query_legal_action_groups(state, actor)


func apply_action(
	state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> StepResult:
	if state == null or action == null or rng == null:
		return _failure(state, "invalid_action")
	var adapter := _restore_adapter(state, rng.get_state())
	if adapter == null:
		return _failure(state, "native_restore_failed")
	var strict := _matching_legal_action(state, action, action.actor)
	if strict == null:
		return _failure(state, "illegal_action")
	if strict.action_id.is_empty():
		var fingerprint := JSON.stringify(strict.to_dict()).sha256_text().left(16)
		strict.action_id = "native-facade:%d:%s" % [
			state.revision, fingerprint]
	var result := adapter.apply_action(strict.to_dict())
	return _adopt_step(state, rng, adapter, result)


func apply_search_action_ephemeral(
	parent_state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> Dictionary:
	if parent_state == null:
		return {"state": null, "step": null}
	var child := parent_state.clone_state()
	var step := apply_action(child, action, rng)
	return {"state": child, "step": step}


func apply_choice_response(
	state: GameState,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	if state == null or response == null or rng == null:
		return _failure(state, "invalid_choice")
	var adapter := _restore_adapter(state, rng.get_state())
	if adapter == null:
		return _failure(state, "native_restore_failed")
	var result := adapter.apply_choice(response.to_dict())
	return _adopt_step(state, rng, adapter, result)


func query_pending_choice(state: GameState, viewer: int) -> ChoiceView:
	if state == null or viewer not in [0, 1]:
		return null
	var adapter := _restore_adapter(state, 1)
	return adapter.pending_choice(viewer) if adapter != null else null


func estimate_public_damage(
	state: GameState,
	actor: int,
	attacker: PokemonState,
	defender: PokemonState,
	base_damage: int,
) -> int:
	if (
		state == null
		or attacker == null
		or defender == null
		or actor not in [0, 1]
	):
		return 0
	var adapter := _restore_adapter(state, 1)
	if adapter == null:
		return 0
	return int(adapter.native.estimate_public_damage(
		actor,
		attacker.to_dict(),
		defender.to_dict(),
		base_damage,
	))


func _matching_legal_action(
	state: GameState,
	candidate: GameAction,
	actor: int,
) -> GameAction:
	if state == null or candidate == null or actor not in [0, 1]:
		return null
	if (
		candidate.schema_version != GameAction.SCHEMA_VERSION
		or candidate.base_revision != state.revision
		or candidate.actor != actor
	):
		return null
	var candidate_wire := candidate.to_dict()
	candidate_wire.erase("action_id")
	var query := query_legal_action_groups(state, actor)
	if not query.success:
		return null
	for legal in query.concrete_actions():
		var legal_wire := legal.to_dict()
		legal_wire.erase("action_id")
		if legal_wire != candidate_wire:
			continue
		legal.action_id = candidate.action_id
		return legal
	return null


func _restore_adapter(
	state: GameState,
	rng_state: int,
) -> NativeRulesSessionAdapter:
	var adapter := NativeRulesSessionAdapter.new(catalog)
	if not adapter.is_available() or not adapter.restore(
		state.snapshot(), rng_state):
		return null
	return adapter


func _adopt_step(
	state: GameState,
	rng: PortableRandomSource,
	adapter: NativeRulesSessionAdapter,
	result: StepResult,
) -> StepResult:
	if result != null and result.success:
		if adapter.state == null or not state.adopt_state(adapter.state):
			return _failure(state, "invalid_native_state")
		rng.set_state(adapter.rng_state)
	return result


static func _failure(state: GameState, code: String) -> StepResult:
	return StepResult.new(
		false,
		code,
		null,
		[],
		state.winner if state != null else -1,
		state.is_terminal() if state != null else false,
		code,
	)

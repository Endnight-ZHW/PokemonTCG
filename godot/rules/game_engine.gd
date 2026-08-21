class_name GameEngine
extends RefCounted

## State-projection adapter. All legality, action, choice, RNG and settlement
## semantics live in ptcg_core; this class serves Challenge AI and tools
## without implementing a second rules path.

var catalog: CardCatalog
var _native_template: Variant = null
var _search_epoch := 0
var _search_sessions: Dictionary = {}

const SEARCH_SESSION_CACHE_LIMIT := 4096


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
	if state == null or actor not in [0, 1]:
		return LegalActionQueryResult.failure(
			state.revision if state != null else -1,
			"invalid_actor",
			"合法动作查询玩家无效。",
		)
	var adapter := _search_adapter_for_state(state, 1)
	if adapter == null:
		return LegalActionQueryResult.failure(
			state.revision, "native_restore_failed", "原生局面恢复失败。")
	return adapter.legal_actions(actor)


func begin_search_epoch() -> void:
	_search_epoch += 1
	if _search_epoch <= 0:
		_search_epoch = 1
	_search_sessions.clear()


func end_search_epoch() -> void:
	_search_sessions.clear()
	_search_epoch = 0


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
	var strict := _matching_legal_action_with_adapter(
		state, action, action.actor, adapter)
	if strict == null:
		return _failure(state, "illegal_action")
	if strict.action_id.is_empty():
		strict.action_id = _internal_action_id(
			strict.to_dict(), state.revision)
	var result := adapter.apply_action(strict.to_dict())
	return _adopt_step(state, rng, adapter, result)


func apply_search_action_ephemeral(
	parent_state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> Dictionary:
	if parent_state == null or action == null or rng == null:
		return {"state": null, "step": null}
	var parent_adapter := _search_adapter_for_state(
		parent_state, rng.get_state())
	if parent_adapter == null:
		return {
			"state": parent_state.clone_state(),
			"step": _failure(parent_state, "native_restore_failed"),
		}
	if (
		action.schema_version != GameAction.SCHEMA_VERSION
		or action.actor not in [0, 1]
		or action.base_revision != parent_state.revision
	):
		return {
			"state": parent_state.clone_state(),
			"step": _failure(parent_state, "illegal_action"),
		}
	var strict_wire := action.to_dict()
	if str(strict_wire.get("action_id", "")).is_empty():
		strict_wire["action_id"] = _internal_action_id(
			strict_wire, parent_state.revision)
	var applied := parent_adapter.fork_apply_action_for_search(
		strict_wire, rng.get_state())
	var branch: NativeRulesSessionAdapter = applied.get("adapter")
	var step: StepResult = applied.get("step")
	if branch == null:
		return {
			"state": parent_state.clone_state(),
			"step": _failure(parent_state, "native_search_fork_failed"),
		}
	if step == null or not step.success or branch.state == null:
		return {"state": parent_state.clone_state(), "step": step}
	var child := branch.state
	rng.set_state(branch.rng_state)
	_register_search_adapter(child, branch)
	return {"state": child, "step": step}


func apply_choice_response(
	state: GameState,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	if state == null or response == null or rng == null:
		return _failure(state, "invalid_choice")
	var adapter := _cached_search_adapter(state)
	if adapter == null:
		adapter = _restore_adapter(state, rng.get_state())
	if adapter == null:
		return _failure(state, "native_restore_failed")
	var result := adapter.apply_choice(response.to_dict())
	var adopted := _adopt_step(state, rng, adapter, result)
	if adopted != null and adopted.success and _search_epoch > 0:
		_register_search_adapter(state, adapter)
	return adopted


func query_pending_choice(state: GameState, viewer: int) -> ChoiceView:
	if state == null or viewer not in [0, 1]:
		return null
	var adapter := _cached_search_adapter(state)
	if adapter == null:
		adapter = _restore_adapter(state, 1)
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
	var adapter := _restore_adapter(state, 1) if state != null else null
	return _matching_legal_action_with_adapter(
		state, candidate, actor, adapter)


func _matching_legal_action_with_adapter(
	state: GameState,
	candidate: GameAction,
	actor: int,
	adapter: NativeRulesSessionAdapter,
) -> GameAction:
	if state == null or candidate == null or actor not in [0, 1]:
		return null
	if adapter == null:
		return null
	if (
		candidate.schema_version != GameAction.SCHEMA_VERSION
		or candidate.base_revision != state.revision
		or candidate.actor != actor
	):
		return null
	var candidate_wire := candidate.to_dict()
	candidate_wire.erase("action_id")
	var query := adapter.legal_actions(actor)
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
	var adapter := _fresh_adapter()
	if adapter == null or not adapter.is_available() or not adapter.restore(
		state.snapshot(), rng_state, false):
		return null
	return adapter


func _fresh_adapter() -> NativeRulesSessionAdapter:
	if _native_template == null:
		var template := NativeRulesSessionAdapter.new(catalog)
		if not template.is_available() or not template.prepare_catalog():
			return null
		_native_template = template.native
	if _native_template == null or not _native_template.has_method("fork"):
		return null
	var forked: Variant = _native_template.call("fork")
	var search_methods_ready: bool = bool(
		forked != null
		and forked.has_method("fork_for_search")
		and forked.has_method("fork_apply_action_for_search")
	)
	return (
		NativeRulesSessionAdapter.new(
			catalog, forked, true, search_methods_ready)
		if forked != null
		else null
	)


func _search_adapter_for_state(
	state: GameState,
	rng_state: int,
) -> NativeRulesSessionAdapter:
	var cached := _cached_search_adapter(state)
	if cached != null:
		return cached
	var restored := _restore_adapter(state, rng_state)
	if restored != null and _search_epoch > 0:
		_register_search_adapter(state, restored)
	return restored


func _cached_search_adapter(state: GameState) -> NativeRulesSessionAdapter:
	if state == null or _search_epoch <= 0:
		return null
	var key := int(state.get_instance_id())
	if not _search_sessions.has(key):
		return null
	var entry: Dictionary = _search_sessions[key]
	if (
		int(entry.get("epoch", 0)) != _search_epoch
		or int(entry.get("revision", -1)) != state.revision
	):
		_search_sessions.erase(key)
		return null
	# Search states are immutable after registration. Validate content on first
	# reuse, then retain that proof for sibling candidates in the same epoch.
	if not bool(entry.get("fingerprint_verified", false)):
		if str(entry.get("fingerprint", "")) != _search_state_fingerprint(state):
			_search_sessions.erase(key)
			return null
		entry["fingerprint_verified"] = true
		_search_sessions[key] = entry
	var adapter: Variant = entry.get("adapter")
	if not adapter is NativeRulesSessionAdapter:
		_search_sessions.erase(key)
		return null
	# Every authoritative mutation advances revision and re-registers the same
	# GameState instance. Avoid crossing the GDExtension boundary merely to read
	# the revision that is already part of this cache entry.
	return adapter


func _register_search_adapter(
	state: GameState,
	adapter: NativeRulesSessionAdapter,
) -> void:
	if state == null or adapter == null or _search_epoch <= 0:
		return
	if _search_sessions.size() >= SEARCH_SESSION_CACHE_LIMIT:
		var oldest_keys := _search_sessions.keys()
		if not oldest_keys.is_empty():
			_search_sessions.erase(oldest_keys[0])
	_search_sessions[int(state.get_instance_id())] = {
		"epoch": _search_epoch,
		"revision": state.revision,
		"fingerprint": _search_state_fingerprint(state),
		"fingerprint_verified": false,
		"adapter": adapter,
	}


static func _search_state_fingerprint(state: GameState) -> String:
	# A non-cryptographic content fingerprint is enough for an in-process cache.
	# Native authoritative mutations always advance revision. The bounded
	# resolution summary avoids recursively hashing Trainer rollback checkpoints;
	# the rest of the mutable game content is hashed by Godot's native Variant
	# implementation rather than by hundreds of GDScript helper calls per node.
	var resolution := state.resolution_stack
	var pending_value: Variant = resolution.get("pending_request")
	var pending_fingerprint := 0
	if pending_value is Dictionary:
		var pending: Dictionary = pending_value
		pending_fingerprint = [
			str(pending.get("request_id", "")).hash(),
			int(pending.get("base_revision", -1)),
			int(pending.get("player", -1)),
			str(pending.get("request_type", "")).hash(),
		].hash()
	var action_log_tail := (
		state.action_log[-1].hash() if not state.action_log.is_empty() else 0)
	var processed_tail := (
		state.processed_action_ids[-1].hash()
		if not state.processed_action_ids.is_empty()
		else 0
	)
	var header_fingerprint := [
		state.active_player_idx,
		state.phase.hash(),
		state.turn_number,
		state.first_player_idx,
		state.stadium_card_id.hash(),
		state.stadium_owner_idx,
		state.winner,
		state.result_status.hash(),
		state.result_reason.hash(),
		state.result_conditions.hash(),
		state.revision,
		state.choice_sequence,
		state.public_deck_keys.hash(),
		int(state.apply_type_matchups),
		state.rules_profile_id.hash(),
		state.rules_options.hash(),
		state.action_log.size(),
		action_log_tail,
		state.mulligan_count.hash(),
		state.extra_draws.hash(),
		state.setup_ready.hash(),
		state.setup_stage.hash(),
		state.setup_actor_idx,
		state.opening_coin_winner_idx,
		state.mulligan_bonus_max,
		state.setup_bonus_card_ids.hash(),
		state.pending_promotions.hash(),
		state.processed_action_ids.size(),
		processed_tail,
		state.turn_fact_book.hash(),
		int(resolution.get("sequence", 0)),
		Array(resolution.get("frames", [])).size(),
		pending_fingerprint,
	].hash()
	var player_fingerprints: Array[int] = []
	for player in state.players:
		var pokemon_fingerprints: Array[int] = [
			_pokemon_search_fingerprint(player.active)]
		for pokemon in player.bench:
			pokemon_fingerprints.append(_pokemon_search_fingerprint(pokemon))
		player_fingerprints.append([
			player.name.hash(),
			player.deck.hash(),
			player.hand.hash(),
			player.discard.hash(),
			player.prizes.hash(),
			int(player.supporter_played_this_turn),
			int(player.energy_attached_this_turn),
			int(player.retreated_this_turn),
			int(player.stadium_played_this_turn),
			int(player.stadium_used_this_turn),
			int(player.healed_this_turn),
			int(player.vstar_power_used),
			int(player.was_ko_by_attack),
			player.attack_locked_names.hash(),
			pokemon_fingerprints.hash(),
		].hash())
	return "%d:%d" % [header_fingerprint, player_fingerprints.hash()]


static func _pokemon_search_fingerprint(value: Variant) -> int:
	if not value is PokemonState:
		return 0
	var pokemon: PokemonState = value
	return [
		pokemon.card_id.hash(),
		pokemon.damage_counters,
		pokemon.energy_card_ids.hash(),
		pokemon.attached_tool_id.hash(),
		pokemon.status_conditions.hash(),
		pokemon.evolution_stack_ids.hash(),
		int(pokemon.can_evolve_this_turn),
		int(pokemon.placed_this_turn),
		pokemon.used_abilities.hash(),
		int(pokemon.healed_this_turn),
		pokemon.modifiers.hash(),
		pokemon.paralyzed_since_turn,
	].hash()


static func _internal_action_id(action_wire: Dictionary, revision: int) -> String:
	var canonical := JSON.stringify(action_wire)
	return "native-facade:%d:%08x%08x" % [
		revision,
		canonical.hash(),
		canonical.reverse().hash(),
	]


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

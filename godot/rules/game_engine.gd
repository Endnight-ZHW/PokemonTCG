class_name GameEngine
extends RefCounted

const MAX_ACTION_QUERY_CACHE_ENTRIES := 64
const MAX_SEARCH_PREFLIGHT_PROOFS := 4096

var catalog: CardCatalog
var _runtime: RulesRuntime
var _action_group_cache: Dictionary = {}
var _search_preflight_epoch := 0
var _search_preflight_proofs: Dictionary = {}
var _search_preflight_proof_count := 0


func _init(p_catalog: CardCatalog = null) -> void:
	catalog = p_catalog if p_catalog else CardCatalog.shared()
	_runtime = RulesRuntime.new(catalog, Callable(self, "_preflight_action"))
	if not _runtime.is_ready():
		# Registry incompleteness is a corrupted release artifact, not a recoverable
		# match error. OS.crash is intentionally used because release builds may
		# compile out assertions and must still fail before accepting any action.
		OS.crash("RulesRuntime failed frozen registry initialization")


func setup_game(
	state: GameState,
	deck_one: Array[String],
	deck_two: Array[String],
	rng: PortableRandomSource,
	forced_first: int = -1,
) -> StepResult:
	return _publicize_result(
		state,
		_setup_game_internal(state, deck_one, deck_two, rng, forced_first),
	)


func _setup_game_internal(
	state: GameState,
	deck_one: Array[String],
	deck_two: Array[String],
	rng: PortableRandomSource,
	forced_first: int = -1,
) -> StepResult:
	# A new match may reuse the same GameState instance and reset its revision to
	# zero.  Clear revision-keyed query results before touching that instance so a
	# pre-setup revision-zero query cannot survive into the new match.
	_invalidate_action_cache()
	for deck in [deck_one, deck_two]:
		var deck_error := _deck_validation_error(deck)
		if not deck_error.is_empty():
			return _error(
				str(deck_error.get("message", "牌组不合法。")),
				str(deck_error.get("code", "invalid_deck")),
				state,
			)

	state.mulligan_count = [0, 0]
	state.extra_draws = [0, 0]
	state.setup_ready = [false, false]
	state.action_log.clear()
	state.setup_game(deck_one, deck_two, rng, forced_first)
	var setup_events: Array[Dictionary] = []
	if forced_first not in [0, 1]:
		# The setup coin is authoritative: every peer consumes the same result,
		# while forced-first debug/test matches do not pretend a toss occurred.
		setup_events.append({
			"event_id": "setup:first-player",
			"event_type": "coin_flip",
			"actor": 0,
			"visibility": "public",
			"source": {"player": 0},
			"target": {"player": state.first_player_idx},
			"data": {
				"purpose": "setup_turn_order",
				"results": [state.first_player_idx == 0],
				"coin_winner": state.opening_coin_winner_idx,
			},
		})
	if forced_first not in [0, 1]:
		var request := _request_turn_order_choice(state)
		return StepResult.new(
			true,
			"硬币胜者请选择先后攻。",
			request,
			setup_events,
			state.winner,
			false,
		)
	state.first_player_idx = forced_first
	state.active_player_idx = forced_first
	var opening := _prepare_opening_hands(state, rng)
	if not str(opening.get("error", "")).is_empty():
		return _error(str(opening["error"]), "mulligan_guard", state)
	setup_events.append_array(opening.get("events", []))
	return StepResult.new(
		true,
		"游戏准备完成。",
		null,
		setup_events,
		state.winner,
		false,
	)


func query_legal_action_groups(
	state: GameState,
	actor: int,
) -> LegalActionQueryResult:
	return _query_legal_action_groups(state, actor, true)


func query_legal_action_groups_ephemeral(
	state: GameState,
	actor: int,
) -> LegalActionQueryResult:
	## Search clones advance once and are then discarded. Avoid retaining their
	## one-use legal-action results in the shared engine cache.
	var result := _query_legal_action_groups(state, actor, false)
	if result.success and _search_preflight_epoch > 0:
		_register_search_preflight_proofs(state, actor, result)
	return result


func begin_search_decision() -> void:
	## Proofs are intentionally scoped to one synchronous beam decision. Starting
	## another sample/decision invalidates every unused proof from the prior one.
	_search_preflight_epoch += 1
	if _search_preflight_epoch <= 0:
		_search_preflight_epoch = 1
	_search_preflight_proofs.clear()
	_search_preflight_proof_count = 0


func _query_legal_action_groups(
	state: GameState,
	actor: int,
	use_cache: bool,
) -> LegalActionQueryResult:
	if state == null or actor not in [0, 1]:
		return LegalActionQueryResult.failure(
			state.revision if state != null else -1,
			"invalid_actor",
			"合法动作查询玩家无效。",
		)
	var pending_value: Variant = state.resolution_stack.get("pending_request")
	var pending_id := (
		str(Dictionary(pending_value).get("request_id", ""))
		if pending_value is Dictionary
		else ""
	)
	var cache_key := "%d:%d:%d:%s" % [
		state.get_instance_id(), state.revision, actor, pending_id,
	]
	if use_cache and _action_group_cache.has(cache_key):
		var cached_result: LegalActionQueryResult = _action_group_cache[cache_key]
		return cached_result.immutable_copy()
	var grouped: Dictionary = {}
	var order: Array[String] = []
	var generated := _runtime._action_registry.generate_candidates(state, actor)
	if not bool(generated.get("ok", false)):
		var error_code := str(generated.get("code", "action_registry_error"))
		return LegalActionQueryResult.failure(
			state.revision,
			error_code,
			str(generated.get("message", "动作候选生成失败。")),
		)
	var candidates: Array[GameAction] = generated.get("actions", [])
	for candidate in candidates:
		var action := _canonicalize_action(state, candidate, actor)
		var shape := _runtime._action_registry.validate_action(action, true)
		if not bool(shape.get("ok", false)):
			var error_code := str(shape.get("code", "invalid_schema"))
			return LegalActionQueryResult.failure(
				state.revision,
				error_code,
				str(shape.get("message", "动作注册表生成了无效候选。")),
			)
		var preflight := _runtime._action_registry.preflight(state, action, actor)
		if not bool(preflight.get("ok", false)):
			if _is_query_contract_error(preflight):
				var error_code := str(preflight.get("code", "vm_error"))
				return LegalActionQueryResult.failure(
					state.revision,
					error_code,
					str(preflight.get("message", "VM 预检合同错误。")),
				)
			continue
		var group_id := LegalActionGroup.group_id_for_action(action)
		if not grouped.has(group_id):
			grouped[group_id] = LegalActionGroup.from_action(action, group_id)
			order.append(group_id)
		elif action.target != null:
			var existing_group: LegalActionGroup = grouped[group_id]
			existing_group.add_target(action.target)
	if order.size() > 256:
		push_error("Legal action groups exceed Protocol v6 limit: %d" % order.size())
		return LegalActionQueryResult.failure(
			state.revision,
			"legal_action_overflow",
			"合法动作分组超过协议上限。",
		)
	var result: Array[LegalActionGroup] = []
	for group_id in order:
		var group: LegalActionGroup = grouped[group_id]
		result.append(group)
	var query_result := LegalActionQueryResult.ok(state.revision, result)
	if use_cache:
		if _action_group_cache.size() >= MAX_ACTION_QUERY_CACHE_ENTRIES:
			# Cold-revision queries naturally fill this small cache. Building the
			# full Dictionary.keys() array merely to evict one arbitrary entry made
			# every subsequent query pay an allocation proportional to cache size.
			_action_group_cache.clear()
		# Keep an isolated immutable-by-convention copy in the cache. Returning the
		# freshly built result avoids two full serialization round trips on a miss.
		_action_group_cache[cache_key] = query_result.immutable_copy()
	return query_result


func apply_action(
	state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> StepResult:
	return _publicize_result(state, _apply_action_internal(state, action, rng))


func apply_search_action_ephemeral(
	parent_state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> Dictionary:
	## Internal fixed-search path. The engine owns the clone so a caller cannot
	## pair a proof from one queried parent with a different same-revision state.
	## Missing/stale proofs merely disable the optimization; legality then follows
	## the complete public preflight path.
	if parent_state == null:
		return {"state": null, "step": null}
	var state := parent_state.clone_state()
	state.set_type_matchups_enabled(false)
	var step := _apply_action_internal(
		state,
		action,
		rng,
		true,
		false,
		parent_state,
	)
	return {
		"state": state,
		"step": _publicize_result(state, step),
	}


func _register_search_preflight_proofs(
	state: GameState,
	actor: int,
	result: LegalActionQueryResult,
) -> void:
	if state == null or result == null or not result.success:
		return
	var actions: Array[GameAction] = []
	actions.assign(result.concrete_actions())
	if _search_preflight_proof_count + actions.size() > MAX_SEARCH_PREFLIGHT_PROOFS:
		_search_preflight_proofs.clear()
		_search_preflight_proof_count = 0
	var parent_key := _search_preflight_parent_key(state, actor)
	var parent_proofs: Dictionary = _search_preflight_proofs.get(parent_key, {})
	for action in actions:
		if action == null or action.actor != actor:
			continue
		var action_key := LegalActionGroup.group_id_for_action(action)
		var wires: Array = parent_proofs.get(action_key, [])
		wires.append(action.to_dict())
		parent_proofs[action_key] = wires
		_search_preflight_proof_count += 1
	_search_preflight_proofs[parent_key] = parent_proofs


func _consume_search_preflight_proof(
	parent_state: GameState,
	action: GameAction,
) -> bool:
	if (
		_search_preflight_epoch <= 0
		or parent_state == null
		or action == null
	):
		return false
	var parent_key := _search_preflight_parent_key(parent_state, action.actor)
	var parent_value: Variant = _search_preflight_proofs.get(parent_key)
	if not parent_value is Dictionary:
		return false
	var parent_proofs: Dictionary = parent_value
	var action_key := LegalActionGroup.group_id_for_action(action)
	var wire_values: Variant = parent_proofs.get(action_key)
	if not wire_values is Array:
		return false
	var wires: Array = wire_values
	var submitted_wire := action.to_dict()
	for index in range(wires.size()):
		if wires[index] != submitted_wire:
			continue
		wires.remove_at(index)
		_search_preflight_proof_count = maxi(
			0, _search_preflight_proof_count - 1)
		if wires.is_empty():
			parent_proofs.erase(action_key)
		else:
			parent_proofs[action_key] = wires
		if parent_proofs.is_empty():
			_search_preflight_proofs.erase(parent_key)
		else:
			_search_preflight_proofs[parent_key] = parent_proofs
		return true
	return false


static func _search_preflight_parent_key(
	parent_state: GameState,
	actor: int,
) -> String:
	if parent_state == null or actor not in [0, 1]:
		return ""
	return "%d:%d:%d" % [
		parent_state.get_instance_id(),
		parent_state.revision,
		actor,
	]


func _apply_action_internal(
	state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
	disposable_state: bool = false,
	invalidate_shared_cache: bool = true,
	preflight_proof_parent: GameState = null,
) -> StepResult:
	if action == null or action.is_legacy_constructed():
		return _error(
			"动作不是 Actions v4 严格信封；旧 Actions v3 不兼容。",
			"invalid_schema",
			state,
		)
	var actor := action.actor
	if actor not in [0, 1]:
		return _error("动作玩家无效。", "unauthorized_actor", state)
	# Shape validation is never bypassed, even for an engine-issued proof.
	var schema_result := _runtime._action_registry.validate_action(action, true)
	if not bool(schema_result.get("ok", false)):
		return _error(
			str(schema_result.get("message", "动作结构无效。")),
			str(schema_result.get("code", "invalid_schema")),
			state,
		)
	if not action.action_id.is_empty() and action.action_id in state.processed_action_ids:
		return _error("动作已处理。", "duplicate_action", state)
	if action.base_revision != state.revision:
		return _error("动作基于过期局面。", "stale_revision", state)
	if state.resolution_stack.get("pending_request") is Dictionary:
		return _error("必须先完成当前选择。", "pending_choice", state)
	var skip_preflight_with_proof := _consume_search_preflight_proof(
		preflight_proof_parent, action)
	if not skip_preflight_with_proof:
		var preflight := _runtime._action_registry.preflight(state, action, actor)
		if not bool(preflight.get("ok", false)):
			return _error(
				str(preflight.get("message", "动作当前不合法。")),
				str(preflight.get("code", "illegal_action")),
				state,
			)
	var result := _runtime._action_settlement.apply_action(
		state,
		action,
		actor,
		rng,
		Callable(_runtime._action_registry, "execute"),
		disposable_state,
	)
	if invalidate_shared_cache:
		_invalidate_action_cache()
	return result


func apply_choice_response(
	state: GameState,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	return _publicize_result(
		state, _apply_choice_response_internal(state, response, rng))


func _apply_choice_response_internal(
	state: GameState,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	var stored_stack := ResolutionStack.from_dict(state.resolution_stack)
	var request := stored_stack.pending_request
	if request == null:
		return _error("当前没有待处理选择。", "invalid_choice", state)
	if response.request_id != request.request_id:
		return _error("选择请求已过期。", "invalid_choice", state)
	if (
		str(request.metadata.get("domain", "")) == "setup"
	):
		var setup_result := _apply_setup_choice(
			state, request, response, rng, stored_stack)
		_invalidate_action_cache()
		return setup_result
	if (
		str(request.metadata.get("domain", "")) == "knockout"
	):
		var knockout_result := _apply_knockout_choice(
			state, request, response, rng, stored_stack)
		_invalidate_action_cache()
		return knockout_result
	if (
		str(request.metadata.get("domain", "")) == "action"
		and str(request.metadata.get("purpose", "")) == "retreat_payment"
	):
		var retreat_result := _apply_retreat_payment_choice(
			state, request, response, rng, stored_stack)
		_invalidate_action_cache()
		return retreat_result
	var result := _runtime._choice_settlement.apply_choice_response(state, response, rng)
	_invalidate_action_cache()
	return result


func query_pending_choice(state: GameState, viewer: int) -> ChoiceView:
	if state == null or viewer not in [0, 1]:
		return null
	var request := ResolutionStack.from_dict(state.resolution_stack).pending_request
	if request == null or request.player != viewer:
		return null
	return _choice_view_from_state(state, request)


func _publicize_result(state: GameState, result: StepResult) -> StepResult:
	if result == null:
		return result
	if result.pending_choice != null:
		result.pending_choice = _choice_view_from_state(state, result.pending_choice)
	return result


func _choice_view_from_state(
	state: GameState,
	request: ChoiceRequest,
) -> ChoiceView:
	var public_metadata := request.metadata.duplicate(true)
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	# ChoiceRequest.metadata is the only author-controlled presentation source.
	# Continuation frames may contain hidden hand/deck/Prize identities and VM
	# commands, so even nominally whitelisted field names must never be copied
	# out of the authoritative stack.
	if (
		stack.context.get("cancel_action_checkpoint") is Dictionary
		or stack.context.get("cancel_action_snapshot") is Dictionary
	):
		public_metadata["cancels_action"] = true
	var projection_source := ChoiceRequest.new(
		request.request_id,
		request.request_type,
		request.player,
		request.prompt,
		request.options,
		request.min_select,
		request.max_select,
		request.allow_duplicates,
		request.can_cancel,
		public_metadata,
	)
	return ChoiceView.from_request(projection_source, state.revision)


func query_state_view(state: GameState, viewer: int) -> Dictionary:
	if state == null or viewer not in [0, 1]:
		return {}
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	var request := stack.pending_request
	var render_state := state
	var hides_provisional_action := false
	if request != null and request.player != viewer:
		var checkpoint: Variant = stack.context.get("cancel_action_checkpoint")
		if checkpoint is Dictionary and Dictionary(checkpoint).get("state") is Dictionary:
			render_state = GameState.from_dict(Dictionary(checkpoint)["state"])
			render_state.revision = state.revision
			render_state.choice_sequence = state.choice_sequence
			hides_provisional_action = true
	var choice := query_pending_choice(state, viewer)
	return {
		"state": StateSerializer.for_player(render_state, viewer),
		"choice_request": choice.to_dict() if choice != null else null,
		"wait_context": (
			{
				"waiting_for_player": request.player,
				"choice_kind": _coarse_choice_kind(request),
			}
			if request != null and request.player != viewer
			else null
		),
		"hides_provisional_action": hides_provisional_action,
	}


static func _coarse_choice_kind(request: ChoiceRequest) -> String:
	if request == null:
		return ""
	if request.request_type == "select_attachment":
		return "attachment"
	if request.request_type in [
		"distribute_energy", "select_energy_source", "select_energy_target",
		"select_own_bench_energy",
	]:
		return "energy"
	if request.request_type == "coin_flip":
		return "coin"
	if "trigger" in request.request_type:
		return "trigger"
	if request.request_type == "select_prize":
		return "prize"
	if request.request_type in ["choose_turn_order", "choose_mulligan_draw_count"]:
		return "setup"
	return "choice"


func _hand_has_basic(player: PlayerState) -> bool:
	for card_id in player.hand:
		if catalog.is_basic_pokemon(card_id):
			return true
	return false


func _request_turn_order_choice(state: GameState) -> ChoiceRequest:
	var chooser := state.opening_coin_winner_idx
	var stack := ResolutionStack.new()
	var frame_id := "setup:turn_order:%d" % state.choice_sequence
	stack.push_continuation("setup_turn_order", {
		"kind": "setup_turn_order",
		"frame_id": frame_id,
		"chooser": chooser,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, chooser, "choose_turn_order"),
		"choose_turn_order",
		chooser,
		"请选择先攻或后攻。",
		[
			{"option_id": "turn:first", "label": "先攻", "value": {"goes_first": true}},
			{"option_id": "turn:second", "label": "后攻", "value": {"goes_first": false}},
		],
		1,
		1,
		false,
		false,
		{
			"domain": "setup",
			"purpose": "choose_turn_order",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
		},
	)
	state.resolution_stack = stack.to_dict()
	return stack.pending_request


func _apply_setup_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
	stack: ResolutionStack,
) -> StepResult:
	var pending := stack.pending_request
	if pending == null or request.request_id != pending.request_id or response.request_id != pending.request_id:
		return _error("选择请求已过期。", "stale_choice", state)
	if int(pending.metadata.get("revision", state.revision)) != state.revision:
		return _error("局面已变化，选择请求已过期。", "stale_choice", state)
	if response.cancelled or response.option_ids.size() != 1:
		return _error("必须选择一个选项。", "choice_count", state)
	var selected_id := response.option_ids[0]
	var valid_ids: Array[String] = []
	for option in pending.options:
		valid_ids.append(str(option.get("option_id", "")))
	if selected_id not in valid_ids:
		return _error("包含无效选择项。", "invalid_choice", state)
	var checkpoint := _runtime._transaction_manager.capture_choice_transaction(state, rng)
	state.revision += 1
	stack.pending_request = null
	stack.frames.clear()
	state.resolution_stack = stack.to_dict()
	match str(pending.metadata.get("purpose", "")):
		"choose_turn_order":
			if selected_id not in ["turn:first", "turn:second"]:
				return _runtime._transaction_manager.rollback_choice_failure(
					state, rng, checkpoint, "先后攻选择无效。", "invalid_choice")
			state.first_player_idx = (
				state.opening_coin_winner_idx
				if selected_id == "turn:first"
				else 1 - state.opening_coin_winner_idx
			)
			state.active_player_idx = state.first_player_idx
			var opening := _prepare_opening_hands(state, rng)
			if not str(opening.get("error", "")).is_empty():
				return _runtime._transaction_manager.rollback_choice_failure(
					state, rng, checkpoint, str(opening["error"]), "mulligan_guard")
			var events: Array[Dictionary] = [{
				"event_type": "turn_order_chosen",
				"actor": state.opening_coin_winner_idx,
				"target": {"player": state.first_player_idx},
				"data": {
					"coin_winner": state.opening_coin_winner_idx,
					"first_player": state.first_player_idx,
				},
			}]
			events.append_array(opening.get("events", []))
			return StepResult.new(true, "先后攻已确定。", null, events)
		"choose_mulligan_draw_count":
			var bonus_result := _apply_mulligan_bonus_choice(
				state, pending.player, selected_id, rng)
			if not bonus_result.success:
				return _runtime._transaction_manager.rollback_failed_step(
					state, rng, checkpoint, bonus_result)
			return bonus_result
	return _runtime._transaction_manager.rollback_choice_failure(
		state, rng, checkpoint, "未知准备阶段选择。", "unknown_setup_choice")


func _prepare_opening_hands(state: GameState, rng: PortableRandomSource) -> Dictionary:
	var events: Array[Dictionary] = []
	state.turn_number = 1
	state.mulligan_count = [0, 0]
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		var drawn := player.draw_cards(7)
		events.append(_opening_hand_draw_event(
			player_idx,
			drawn,
			"opening_hand",
			0,
			_hand_has_basic(player),
		))
	var guard := 0
	while (
		not _hand_has_basic(state.get_player(0))
		or not _hand_has_basic(state.get_player(1))
	):
		guard += 1
		if guard > 64:
			return {"error": "连续再战仍未抽到基础宝可梦。", "events": events}
		var needs_redraw := [
			not _hand_has_basic(state.get_player(0)),
			not _hand_has_basic(state.get_player(1)),
		]
		for player_idx in [0, 1]:
			if not needs_redraw[player_idx]:
				continue
			var revealed: Array[String] = state.get_player(player_idx).hand.duplicate()
			events.append({
				"event_type": "cards_revealed",
				"actor": player_idx,
				"visibility": "public",
				"source": {"player": player_idx, "zone": "hand"},
				"data": {
					"player": player_idx,
					"purpose": "mulligan",
					"round": guard,
					"card_ids": revealed,
					"cards": revealed,
				},
			})
		for player_idx in [0, 1]:
			if not needs_redraw[player_idx]:
				continue
			var player := state.get_player(player_idx)
			var returned: Array[String] = player.hand.duplicate()
			state.mulligan_count[player_idx] += 1
			events.append({
				"event_type": "card_moved",
				"actor": player_idx,
				"visibility": "public",
				"source": {"player": player_idx, "zone": "hand"},
				"target": {"player": player_idx, "zone": "deck"},
				"amount": returned.size(),
				"data": {
					"player": player_idx,
					"purpose": "mulligan_return",
					"round": guard,
					"count": returned.size(),
					"card_ids": returned,
				},
			})
			player.deck.append_array(player.hand)
			player.hand.clear()
			rng.shuffle(player.deck)
			events.append({
				"event_type": "deck_shuffled",
				"actor": player_idx,
				"visibility": "public",
				"source": {"player": player_idx, "zone": "deck"},
				"target": {"player": player_idx, "zone": "deck"},
				"data": {
					"player": player_idx,
					"purpose": "mulligan",
					"round": guard,
				},
			})
		for player_idx in [0, 1]:
			if not needs_redraw[player_idx]:
				continue
			var player := state.get_player(player_idx)
			var redrawn := player.draw_cards(7)
			events.append(_opening_hand_draw_event(
				player_idx,
				redrawn,
				"mulligan_redraw",
				guard,
				_hand_has_basic(player),
			))
	var bonus_for_zero := maxi(0, state.mulligan_count[1] - state.mulligan_count[0])
	var bonus_for_one := maxi(0, state.mulligan_count[0] - state.mulligan_count[1])
	state.mulligan_bonus_max = maxi(bonus_for_zero, bonus_for_one)
	state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	state.setup_actor_idx = state.first_player_idx
	state.setup_ready = [false, false]
	state.log_action("起始手牌已准备。")
	return {"error": "", "events": events}


func _opening_hand_draw_event(
	player_idx: int,
	cards: Array[String],
	purpose: String,
	round_number: int,
	final_opening_hand: bool,
) -> Dictionary:
	return {
		"event_type": "cards_drawn",
		"actor": player_idx,
		"visibility": "owner",
		"source": {"player": player_idx, "zone": "deck"},
		"target": {"player": player_idx, "zone": "hand"},
		"amount": cards.size(),
		"data": {
			"player": player_idx,
			"purpose": purpose,
			"round": round_number,
			"count": cards.size(),
			"card_ids": cards.duplicate(),
			"final_opening_hand": final_opening_hand,
		},
	}


func _apply_mulligan_bonus_choice(
	state: GameState,
	player_idx: int,
	option_id: String,
	rng: PortableRandomSource,
) -> StepResult:
	if not option_id.begins_with("draw:"):
		return _error("再战奖励选择无效。", "invalid_choice", state)
	var amount := option_id.trim_prefix("draw:").to_int()
	if amount < 0 or amount > state.mulligan_bonus_max:
		return _error("再战奖励抽牌数无效。", "invalid_choice", state)
	var player := state.get_player(player_idx)
	var drawn := player.draw_cards(amount)
	state.extra_draws[player_idx] = drawn.size()
	state.setup_bonus_card_ids[player_idx] = drawn.duplicate()
	var has_placeable_basic := false
	if player.find_empty_bench_slot() >= 0:
		for card_id in drawn:
			if catalog.is_basic_pokemon(card_id):
				has_placeable_basic = true
				break
	var events: Array[Dictionary] = []
	if not drawn.is_empty():
		events.append({
			"event_type": "cards_drawn",
			"actor": player_idx,
			"visibility": "owner",
			"source": {"player": player_idx, "zone": "deck"},
			"target": {"player": player_idx, "zone": "hand"},
			"data": {
				"player": player_idx,
				"count": drawn.size(),
				"card_ids": drawn.duplicate(),
				"purpose": "mulligan_bonus",
			},
		})
	if has_placeable_basic:
		state.setup_stage = GameState.SETUP_BONUS_PLACEMENT
		state.setup_actor_idx = player_idx
		return StepResult.new(true, "可以将奖励抽到的基础宝可梦放入备战区。", null, events)
	var completed := _runtime._action_executor.complete_setup(state, rng)
	completed.events = events + completed.events
	return completed


func _apply_retreat_payment_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
	stack: ResolutionStack,
) -> StepResult:
	if int(request.metadata.get("revision", -1)) != state.revision:
		return _error("局面已变化，撤退支付已过期。", "invalid_choice", state)
	var cancel_checkpoint := _runtime._transaction_manager.cancel_action_checkpoint(stack)
	if response.cancelled:
		if not request.can_cancel or cancel_checkpoint.is_empty():
			return _error("该选择不能取消。", "invalid_choice", state)
		var cancelled := _runtime._transaction_manager.restore_cancelled_action(
			state, rng, cancel_checkpoint)
		_invalidate_action_cache()
		return cancelled
	if response.option_ids.is_empty():
		return _error("必须选择至少一张能量。", "invalid_choice", state)
	var option_by_id: Dictionary = {}
	for option_value in request.options:
		var option: Dictionary = option_value
		option_by_id[str(option.get("option_id", ""))] = option
	var indices: Array = []
	var seen: Dictionary = {}
	for option_id in response.option_ids:
		if seen.has(option_id) or not option_by_id.has(option_id):
			return _error("撤退支付包含重复或无效选项。", "invalid_choice", state)
		seen[option_id] = true
		var ref_value: Variant = Dictionary(option_by_id[option_id]).get("ref")
		if not ref_value is Dictionary:
			return _error("撤退支付缺少附件引用。", "invalid_choice", state)
		var ref := EntityRef.from_dict(ref_value)
		if ref.kind != "attachment" or ref.attachment_type != "energy":
			return _error("撤退支付附件类型无效。", "invalid_choice", state)
		var ref_error := _runtime._action_availability.validate_action_references(
			state,
			GameAction.create(
				"RETREAT",
				{},
				request.player,
				_pokemon_ref(state, request.player, "active"),
				_pokemon_ref(
					state,
					request.player,
					"bench_%d" % int(_retreat_frame(stack).get("bench_idx", -1)),
				),
				"",
				state.revision,
			),
		)
		if not ref_error.is_empty():
			return _error(ref_error, "invalid_ref", state)
		# Validate the attachment itself as well as the destination action ref.
		var attachment_probe := GameAction.create(
			"NOOP", {},
			request.player, ref, null, "", state.revision)
		ref_error = _runtime._action_availability.validate_action_references(
			state, attachment_probe)
		if not ref_error.is_empty():
			return _error(ref_error, "invalid_ref", state)
		indices.append(ref.index)
	var frame := _retreat_frame(stack)
	if frame.is_empty():
		return _error("撤退续体已损坏。", "invalid_choice", state)
	var actor := int(frame.get("actor", -1))
	var bench_idx := int(frame.get("bench_idx", -1))
	var payment_error := _runtime._validator.can_retreat(state, actor, bench_idx, indices)
	if not payment_error.is_empty():
		return _error(payment_error, "invalid_choice", state)
	var checkpoint := _runtime._transaction_manager.capture_choice_transaction(state, rng)
	state.revision += 1
	state.resolution_stack = ResolutionStack.new().to_dict()
	var result := _runtime._action_executor.retreat(state, actor, bench_idx, indices)
	if not result.success:
		result = _runtime._transaction_manager.rollback_failed_step(
			state, rng, checkpoint, result)
	_invalidate_action_cache()
	result.winner = state.winner
	result.terminal = state.is_terminal()
	return result


static func _retreat_frame(stack: ResolutionStack) -> Dictionary:
	for index in range(stack.frames.size() - 1, -1, -1):
		var frame: Dictionary = stack.frames[index]
		if (
			str(frame.get("kind", "")) == "continuation"
			and str(frame.get("operation", "")) == "retreat_payment"
		):
			return Dictionary(frame.get("data", {}))
	return {}


func _apply_knockout_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
	stack: ResolutionStack,
) -> StepResult:
	var pending := stack.pending_request
	if pending == null or pending.request_id != request.request_id or pending.request_id != response.request_id:
		return _error("选择请求已过期。", "stale_choice", state)
	if int(pending.metadata.get("revision", state.revision)) != state.revision:
		return _error("局面已变化，选择请求已过期。", "stale_choice", state)
	var checkpoint := _runtime._transaction_manager.capture_choice_transaction(state, rng)
	state.revision += 1
	var purpose := str(pending.metadata.get("purpose", ""))
	var outcome: Dictionary
	if purpose == "select_prize":
		outcome = _runtime._knockout_settlement.apply_prize_choice(
			state, pending, response, stack, rng)
	else:
		outcome = _runtime._knockout_settlement.apply_ko_trigger_choice(
			state, response, stack, rng)
	if not bool(outcome.get("success", false)):
		return _runtime._transaction_manager.rollback_choice_failure(
			state,
			rng,
			checkpoint,
			str(outcome.get("message", "奖赏卡选择失败。")),
			str(outcome.get("error_code", "invalid_choice")),
		)
	var events: Array[Dictionary] = []
	events.append_array(outcome.get("events", []))
	var next_request: Variant = outcome.get("pending_choice", null)
	if next_request is ChoiceRequest:
		return StepResult.new(
			true, str(outcome.get("message", "")), next_request, events, state.winner, false)
	stack.context.erase("prize_awards")
	stack.context.erase("ko_batch")
	if bool(stack.context.get("finish_end_turn_after_knockouts", false)):
		var end_turn_actor := int(stack.context.get("end_turn_actor", state.active_player_idx))
		stack.context.erase("finish_end_turn_after_knockouts")
		stack.context.erase("end_turn_actor")
		state.resolution_stack = stack.to_dict()
		var end_turn_result := _runtime._turn_settlement.finish_end_turn_after_knockouts(
			state, end_turn_actor, rng, events)
		if not end_turn_result.success:
			return _runtime._transaction_manager.rollback_failed_step(
				state, rng, checkpoint, end_turn_result)
		return end_turn_result
	stack.pending_request = null
	if bool(stack.context.get("finish_attack_after_prizes", false)):
		var actor := int(stack.context.get("actor", state.active_player_idx))
		# The KO/prize pipeline owns this serialized finalization frame. Popping is
		# deliberately idempotent so GameEngine does not duplicate the generic
		# choice-settlement frame inspection policy.
		stack.pop_finalize_attack()
		var attack_result := _runtime._attack_settlement.finish_attack_after_prizes(
			state, stack, actor, rng, events)
		if not attack_result.success:
			return _runtime._transaction_manager.rollback_failed_step(
				state, rng, checkpoint, attack_result)
		return attack_result
	state.resolution_stack = stack.to_dict()
	_runtime._knockout_settlement.resolve_empty_boards_and_promotions(state)
	if state.is_terminal():
		_runtime._knockout_settlement.append_game_over_event(events, state)
		state.resolution_stack = ResolutionStack.new().to_dict()
	return StepResult.new(
		true,
		str(outcome.get("message", "")),
		null,
		events,
		state.winner,
		state.is_terminal(),
	)


func _canonicalize_action(
	state: GameState,
	action: GameAction,
	actor: int,
) -> GameAction:
	if action != null and not action.is_legacy_constructed():
		return action
	if action == null:
		return GameAction.create("", {}, actor, null, null, "", state.revision)
	var kind := action.kind
	var params := action.params
	var source := action.source
	var target := action.target
	var payload: Dictionary = {}
	match kind:
		"PLAY_BASIC":
			source = _hand_card_ref(state, actor, int(params.get("hand_idx", -1)), source)
			var target_slot := str(params.get("target", target.slot if target else ""))
			target = EntityRef.new("slot", actor, "", target_slot)
		"EVOLVE":
			source = _hand_card_ref(state, actor, int(params.get("hand_idx", -1)), source)
			var evolve_slot := str(params.get("slot", target.slot if target else ""))
			target = _pokemon_ref(state, actor, evolve_slot)
		"ATTACH_ENERGY":
			source = _hand_card_ref(state, actor, int(params.get("hand_idx", -1)), source)
			var energy_slot := str(params.get("target_slot", target.slot if target else ""))
			target = _pokemon_ref(state, actor, energy_slot)
		"PLAY_TRAINER":
			source = _hand_card_ref(state, actor, int(params.get("hand_idx", -1)), source)
			var trainer_slot := str(params.get("target_slot", target.slot if target else ""))
			target = _pokemon_ref(state, actor, trainer_slot) if not trainer_slot.is_empty() else null
		"USE_ABILITY":
			var ability_slot := str(params.get("slot", source.slot if source else ""))
			payload = {"ability_name": str(params.get("ability_name", ""))}
			if ability_slot.begins_with("discard_"):
				var discard_index := ability_slot.trim_prefix("discard_").to_int()
				source = _zone_card_ref(
					state, actor, "discard", discard_index, source)
			else:
				source = _pokemon_ref(state, actor, ability_slot)
			target = null
		"USE_STADIUM":
			source = EntityRef.new(
				"card", actor, "stadium", "", 0, "",
				state.stadium_card_id)
			target = null
		"RETREAT", "PROMOTE":
			var bench_idx := int(params.get("bench_idx", -1))
			var bench_slot := target.slot if target else "bench_%d" % bench_idx
			target = _pokemon_ref(state, actor, bench_slot)
			source = _pokemon_ref(state, actor, "active") if kind == "RETREAT" else null
		"DECLARE_ATTACK":
			payload = {"attack_index": int(params.get(
				"attack_index", params.get("attack_idx", -1)))}
			source = _pokemon_ref(state, actor, "active")
			target = null
		"SETUP_DONE", "END_TURN", "NOOP":
			source = null
			target = null
		_:
			payload = action.payload.duplicate(true)
	return GameAction.create(
		kind,
		payload,
		actor,
		source,
		target,
		action.action_id,
		state.revision,
	)


func _hand_card_ref(
	state: GameState,
	actor: int,
	index: int,
	existing: EntityRef,
) -> EntityRef:
	return _zone_card_ref(state, actor, "hand", index, existing)


func _zone_card_ref(
	state: GameState,
	actor: int,
	zone_name: String,
	index: int,
	existing: EntityRef,
) -> EntityRef:
	if (
		existing != null
		and existing.kind == "card"
		and existing.player == actor
		and existing.zone == zone_name
		and existing.index == index
	):
		return existing
	var cards: Array[String]
	match zone_name:
		"hand":
			cards = state.get_player(actor).hand
		"discard":
			cards = state.get_player(actor).discard
		"deck":
			cards = state.get_player(actor).deck
		"prizes":
			cards = state.get_player(actor).prizes
		_:
			cards = []
	var card_id := str(cards[index]) if index >= 0 and index < cards.size() else ""
	return EntityRef.new("card", actor, zone_name, "", index, "", card_id)


func _pokemon_ref(state: GameState, actor: int, slot: String) -> EntityRef:
	var pokemon := state.get_player(actor).get_pokemon(slot)
	return EntityRef.new(
		"pokemon", actor, "", slot, -1, "", pokemon.card_id if pokemon else "")


func _preflight_action(
	state: GameState,
	action: GameAction,
	actor: int,
) -> Dictionary:
	if state.is_terminal():
		return _preflight_error("illegal_action", "对局已经结束。")
	if action.actor != actor:
		return _preflight_error("unauthorized_actor", "动作玩家不一致。")
	# ActionDefinitionRegistry has already validated the tagged-union shape on
	# both query and submit paths.  This pass only checks revision-bound identity
	# against the authoritative state, avoiding duplicate union validation for
	# every generated candidate.
	var reference_error := _runtime._action_availability.validate_action_references(
		state, action, false)
	if not reference_error.is_empty():
		return _preflight_error("invalid_ref", reference_error)
	if state.phase != "SETUP" and action.kind != "PROMOTE" and actor != state.active_player_idx:
		return _preflight_error("unauthorized_actor", "不是你的回合。")
	var reason := ""
	var error_code := "illegal_action"
	match action.kind:
		"PLAY_BASIC":
			reason = _runtime._validator.can_play_basic(
				state, actor, action.source.card_id, action.target.slot)
		"EVOLVE":
			reason = _runtime._validator.can_evolve(
				state, actor, action.target.slot, action.source.card_id)
		"ATTACH_ENERGY":
			reason = _runtime._validator.can_attach_energy(
				state, actor, action.source.card_id, action.target.slot)
		"PLAY_TRAINER":
			reason = _runtime._validator.can_play_trainer(
				state,
				actor,
				action.source.card_id,
				action.target.slot if action.target else "",
			)
			if reason.is_empty():
				var target_preflight := _runtime._action_availability.action_target_preflight(
					state, action, actor)
				if not bool(target_preflight.get("ok", false)):
					return _vm_preflight_error(target_preflight)
				if not bool(target_preflight.get("legal", false)):
					reason = str(target_preflight.get("message", "没有合法目标。"))
					error_code = "no_legal_target"
			if reason.is_empty():
				var cost_preflight := _runtime._action_availability.action_cost_preflight(
					state, action, actor)
				if not bool(cost_preflight.get("ok", false)):
					return _vm_preflight_error(cost_preflight)
				if not bool(cost_preflight.get("legal", false)):
					reason = str(cost_preflight.get("message", "无法支付代价。"))
					error_code = "cost_not_payable"
		"USE_ABILITY":
			if action.source.kind == "card" and action.source.zone == "discard":
				reason = ""
			else:
				reason = _runtime._validator.can_use_ability(
					state, actor, action.source.slot,
					str(action.payload.get("ability_name", "")))
			if reason.is_empty():
				var target_preflight := _runtime._action_availability.action_target_preflight(
					state, action, actor)
				if not bool(target_preflight.get("ok", false)):
					return _vm_preflight_error(target_preflight)
				if not bool(target_preflight.get("legal", false)):
					reason = str(target_preflight.get("message", "没有合法目标。"))
					error_code = "no_legal_target"
		"USE_STADIUM":
			if state.phase != "MAIN" or actor != state.active_player_idx:
				reason = "只能在自己的主要阶段使用竞技场。"
			elif state.get_player(actor).stadium_used_this_turn:
				reason = "本回合已使用过竞技场效果。"
			else:
				var activation_preflight := _runtime._availability.preflight_stadium_activation(state)
				if not bool(activation_preflight.get("ok", false)):
					return _vm_preflight_error(activation_preflight)
				if not bool(activation_preflight.get("legal", false)):
					reason = "场上竞技场没有可发动效果。"
				else:
					var target_preflight := _runtime._action_availability.action_target_preflight(
						state, action, actor)
					if not bool(target_preflight.get("ok", false)):
						return _vm_preflight_error(target_preflight)
					if not bool(target_preflight.get("legal", false)):
						reason = str(target_preflight.get("message", "没有合法目标。"))
						error_code = "no_legal_target"
		"RETREAT":
			error_code = "illegal_retreat"
			var retreat_bench_idx := (
				action.target.slot.trim_prefix("bench_").to_int()
				if action.target != null and action.target.slot.begins_with("bench_")
				else -1
			)
			reason = _runtime._validator.can_start_retreat(
				state, actor, retreat_bench_idx)
		"DECLARE_ATTACK":
			error_code = "illegal_attack"
			reason = _runtime._validator.can_attack(
				state, actor, int(action.payload.get("attack_index", -1)))
			if reason.is_empty():
				var target_preflight := _runtime._action_availability.action_target_preflight(
					state, action, actor)
				if not bool(target_preflight.get("ok", false)):
					return _vm_preflight_error(target_preflight)
				if not bool(target_preflight.get("legal", false)):
					reason = str(target_preflight.get("message", "没有合法目标。"))
					error_code = "no_legal_target"
		"PROMOTE":
			var bench_idx := (
				action.target.slot.trim_prefix("bench_").to_int()
				if action.target != null and action.target.slot.begins_with("bench_")
				else -1
			)
			if state.pending_promotions.is_empty() or int(state.pending_promotions[0]) != actor:
				reason = "当前没有待处理晋升。"
			elif bench_idx < 0 or bench_idx >= state.get_player(actor).bench.size():
				reason = "晋升目标无效。"
		"SETUP_DONE":
			var found := false
			for candidate in _runtime._action_availability.setup_actions(state, actor):
				if candidate.kind == "SETUP_DONE":
					found = true
					break
			if not found:
				reason = "当前不能完成准备。"
		"END_TURN":
			if state.phase not in ["MAIN", "ATTACK"]:
				reason = "当前阶段不能结束回合。"
		"NOOP":
			reason = "NOOP 仅供内部使用。"
		_:
			reason = "未知动作。"
	if not reason.is_empty():
		return _preflight_error(error_code, reason)
	return {"ok": true, "code": "", "message": ""}


static func _preflight_error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}


static func _vm_preflight_error(result: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"code": str(result.get("error_code", result.get("code", "vm_error"))),
		"error_code": str(result.get("error_code", result.get("code", "vm_error"))),
		"message": str(result.get("message", "VM 预检合同错误。")),
		"contract_error": true,
	}


static func _is_query_contract_error(preflight: Dictionary) -> bool:
	if bool(preflight.get("contract_error", false)):
		return true
	var code := str(preflight.get("error_code", preflight.get("code", "")))
	return (
		code.begins_with("vm_")
		or code in [
			"invalid_descriptor",
			"invalid_effect",
			"invalid_args",
			"invalid_branch",
			"unknown_op",
			"unknown_evaluator",
			"unsupported_context",
			"internal_op_exposed",
		]
	)


func _invalidate_action_cache() -> void:
	_action_group_cache.clear()


func _deck_validation_error(deck: Array[String]) -> Dictionary:
	if deck.size() != 60:
		return {"message": "双方牌组都必须正好包含60张卡。", "code": "invalid_deck_size"}
	var has_basic := false
	var counts_by_name: Dictionary = {}
	var ace_spec_count := 0
	var radiant_count := 0
	for card_id in deck:
		if not catalog.cards.has(card_id):
			return {"message": "牌组包含未知卡牌：%s。" % card_id, "code": "unknown_card"}
		has_basic = has_basic or catalog.is_basic_pokemon(card_id)
		var card := catalog.get_card(card_id)
		var card_name := catalog.card_name(card_id)
		if not catalog.is_basic_energy(card_id):
			counts_by_name[card_name] = int(counts_by_name.get(card_name, 0)) + 1
			if int(counts_by_name[card_name]) > 4:
				return {"message": "同名卡牌最多放入4张：%s。" % card_name, "code": "too_many_copies"}
		var rules_text := " ".join(card.get("rules", []))
		var subtypes_text := " ".join(card.get("subtypes", []))
		if "ACE SPEC" in rules_text or "ACE SPEC" in subtypes_text:
			ace_spec_count += 1
		if "Radiant" in subtypes_text or card_name.begins_with("光辉"):
			radiant_count += 1
	if not has_basic:
		return {"message": "牌组至少需要1张基础宝可梦。", "code": "deck_without_basic"}
	if ace_spec_count > 1:
		return {"message": "牌组最多放入1张ACE SPEC卡。", "code": "too_many_ace_spec"}
	if radiant_count > 1:
		return {"message": "牌组最多放入1张光辉宝可梦。", "code": "too_many_radiant"}
	return {}


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)

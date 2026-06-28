class_name GameEngine
extends RefCounted

const FULL_DAMAGE_EFFECT_TYPES: Array[String] = [
	"damage_per_self_damage",
	"damage_per_self_energy",
	"damage_per_self_energy_type",
	"damage_plus_bench",
	"damage_per_hand_size",
	"damage_per_energy",
	"damage_per_evolved",
	"damage_self_penalty",
	"damage_per_discard_psychic",
	"conditional_damage_heal",
	"mill_and_damage_per_energy",
	"attack_damage_formula",
]

const TARGET_DAMAGE_EFFECT_TYPES: Array[String] = [
	"damage",
	"conditional_damage_bonus",
	"damage_per_discard_psychic",
	"damage_per_energy",
	"damage_per_evolved",
	"damage_per_hand_size",
	"damage_per_self_damage",
	"damage_per_self_energy",
	"damage_per_self_energy_type",
	"damage_plus_bench",
	"damage_self_penalty",
	"discard_fighting_energy_damage",
	"discard_hand_conditional_bonus",
	"mill_and_damage_per_energy",
	"attack_damage_formula",
]

var catalog: CardCatalog
var validator: RulesValidator
var effect_engine: EffectEngine


func _init(p_catalog: CardCatalog = null) -> void:
	catalog = p_catalog if p_catalog else CardCatalog.new()
	validator = RulesValidator.new(catalog)
	effect_engine = EffectEngine.new(catalog)


func setup_game(
	state: GameState,
	deck_one: Array[String],
	deck_two: Array[String],
	rng: PortableRandomSource,
	forced_first: int = -1,
) -> StepResult:
	if deck_one.size() != 60 or deck_two.size() != 60:
		return _error("双方牌组都必须正好包含60张卡。", "invalid_deck_size", state)
	for deck in [deck_one, deck_two]:
		var has_basic := false
		for card_id in deck:
			if catalog.is_basic_pokemon(card_id):
				has_basic = true
				break
		if not has_basic:
			return _error("牌组至少需要1张基础宝可梦。", "deck_without_basic", state)

	state.mulligan_count = [0, 0]
	state.extra_draws = [0, 0]
	state.setup_ready = [false, false]
	state.action_log.clear()
	state.setup_game(deck_one, deck_two, rng, forced_first)
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		var guard := 0
		while not _hand_has_basic(player) and guard < 32:
			guard += 1
			state.mulligan_count[player_idx] += 1
			player.deck.append_array(player.hand)
			player.hand.clear()
			rng.shuffle(player.deck)
			player.draw_cards(7)
		if not _hand_has_basic(player):
			return _error("连续再战仍未抽到基础宝可梦。", "mulligan_guard", state)

	for player_idx in [0, 1]:
		if state.mulligan_count[player_idx] > 0:
			var opponent_idx: int = 1 - int(player_idx)
			state.extra_draws[opponent_idx] += 1
			state.get_player(opponent_idx).draw_cards(1)
	state.log_action("起始手牌已准备。")
	return StepResult.new(true, "游戏准备完成。", null, [], state.winner, false)


func legal_actions(
	state: GameState,
	actor: int,
	validate_effects: bool = true,
) -> Array[GameAction]:
	var actions: Array[GameAction] = []
	if actor not in [0, 1]:
		return actions
	var stored_stack := ResolutionStack.from_dict(state.resolution_stack)
	if stored_stack.pending_request != null:
		return actions
	if not state.pending_promotions.is_empty():
		if actor != int(state.pending_promotions[0]):
			return actions
		var promote_player := state.get_player(actor)
		for bench_idx in range(promote_player.bench.size()):
			var pokemon: PokemonState = promote_player.bench[bench_idx]
			if pokemon:
				actions.append(GameAction.new(
					"PROMOTE",
					{"bench_idx": bench_idx},
					false,
					actor,
					null,
					EntityRef.new(
						"pokemon", actor, "", "bench_%d" % bench_idx,
						-1, "", pokemon.card_id),
				))
		return actions
	if state.phase == "SETUP":
		return _setup_actions(state, actor)
	if state.phase == "ATTACK":
		if state.active_player_idx == actor:
			actions.append(GameAction.new("END_TURN", {}, true, actor))
		return actions
	if state.phase != "MAIN" or state.active_player_idx != actor:
		return actions

	var player := state.get_player(actor)
	var seen: Dictionary = {}
	var empty_slots: Array[String] = []
	for index in range(player.bench.size()):
		if player.bench[index] == null:
			empty_slots.append("bench_%d" % index)

	for hand_idx in range(player.hand.size()):
		var card_id := player.hand[hand_idx]
		var source := EntityRef.new("card", actor, "hand", "", hand_idx, "", card_id)
		if catalog.is_basic_pokemon(card_id):
			for target_slot in empty_slots:
				_add_action(actions, seen, GameAction.new(
					"PLAY_BASIC",
					{"hand_idx": hand_idx, "target": target_slot},
					false,
					actor,
					source,
					EntityRef.new("pokemon", actor, "", target_slot),
				))
		elif catalog.is_stage1(card_id) or catalog.is_stage2(card_id):
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon and validator.can_evolve(state, actor, slot, card_id).is_empty():
					_add_action(actions, seen, GameAction.new(
						"EVOLVE",
						{"hand_idx": hand_idx, "slot": slot},
						false,
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
					))
		elif catalog.is_energy(card_id):
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon and validator.can_attach_energy(state, actor, card_id, slot).is_empty():
					_add_action(actions, seen, GameAction.new(
						"ATTACH_ENERGY",
						{"hand_idx": hand_idx, "target_slot": slot},
						false,
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
					))
		elif catalog.is_tool(card_id):
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon and validator.can_play_trainer(state, actor, card_id, slot).is_empty():
					_add_action(actions, seen, GameAction.new(
						"PLAY_TRAINER",
						{"hand_idx": hand_idx, "target_slot": slot},
						false,
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
					))
		elif catalog.is_trainer(card_id):
			if validator.can_play_trainer(state, actor, card_id).is_empty():
				var trainer_action := GameAction.new(
					"PLAY_TRAINER", {"hand_idx": hand_idx}, false, actor, source)
				if (
					_action_cost_error(state, trainer_action, actor).is_empty()
					and _action_target_availability_error(state, trainer_action, actor).is_empty()
					and (not validate_effects or _simulated_action_succeeds(state, trainer_action))
				):
					_add_action(actions, seen, trainer_action)

	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot := str(row["slot"])
		for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			var ability_name := str(ability.get("name", ""))
			if validator.can_use_ability(state, actor, slot, ability_name).is_empty():
				var ability_action := GameAction.new(
					"USE_ABILITY",
					{"slot": slot, "ability_name": ability_name},
					false,
					actor,
					EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
				)
				if (
					_action_target_availability_error(state, ability_action, actor).is_empty()
					and (not validate_effects or _simulated_action_succeeds(state, ability_action))
				):
					_add_action(actions, seen, ability_action)

	if _stadium_is_activatable(state) and not player.stadium_used_this_turn:
		var stadium_action := GameAction.new("USE_STADIUM", {}, false, actor)
		if (
			_action_target_availability_error(state, stadium_action, actor).is_empty()
			and (not validate_effects or _simulated_action_succeeds(state, stadium_action))
		):
			_add_action(actions, seen, stadium_action)

	for bench_idx in range(player.bench.size()):
		var bench_pokemon: PokemonState = player.bench[bench_idx]
		if bench_pokemon == null:
			continue
		for payment in _retreat_payments(state, actor, bench_idx):
			_add_action(actions, seen, GameAction.new(
				"RETREAT",
				{"bench_idx": bench_idx, "energy_indices": payment},
				false,
				actor,
				null,
				EntityRef.new(
					"pokemon", actor, "", "bench_%d" % bench_idx,
					-1, "", bench_pokemon.card_id),
			))

	if player.active:
		var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
		for attack_idx in range(attacks.size()):
			if validator.can_attack(state, actor, attack_idx).is_empty():
				var attack_action := GameAction.new(
					"DECLARE_ATTACK",
					{"attack_idx": attack_idx},
					true,
					actor,
					EntityRef.new("pokemon", actor, "", "active", -1, "", player.active.card_id),
				)
				if _action_target_availability_error(state, attack_action, actor).is_empty():
					_add_action(actions, seen, attack_action)
	_add_action(actions, seen, GameAction.new("END_TURN", {}, true, actor))
	return actions


func apply_action(
	state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> StepResult:
	var actor := state.active_player_idx if action.actor < 0 else action.actor
	if actor not in [0, 1]:
		return _error("动作玩家无效。", "invalid_actor", state)
	if not action.action_id.is_empty() and action.action_id in state.processed_action_ids:
		return _error("动作已处理。", "duplicate_action", state)
	var pending_stack := ResolutionStack.from_dict(state.resolution_stack)
	if pending_stack.pending_request != null:
		return _error("必须先完成当前选择。", "pending_choice", state)
	var reference_error := _validate_action_references(state, action)
	if not reference_error.is_empty():
		return _error(reference_error, "stale_action_reference", state)
	var cost_error := _action_cost_error(state, action, actor)
	if not cost_error.is_empty():
		return _error(cost_error, "cost_not_payable", state)
	var target_error := _action_target_availability_error(state, action, actor)
	if not target_error.is_empty():
		return _error(target_error, "no_legal_target", state)

	var snapshot := state.snapshot()
	state.revision += 1
	var result := _dispatch_action(state, action, actor, rng)
	if not result.success:
		_restore_state(state, snapshot)
		return result
	if (
		result.pending_choice == null
		and action.action not in ["DECLARE_ATTACK", "END_TURN"]
		and str(snapshot.get("phase", "SETUP")) != "SETUP"
	):
		_resolve_knockouts(state, actor, result.events, false)
	if (
		result.pending_choice
		and result.pending_choice.can_cancel
		and action.action == "PLAY_TRAINER"
	):
		var cancellable_stack := ResolutionStack.from_dict(state.resolution_stack)
		cancellable_stack.context["cancel_action_snapshot"] = snapshot
		state.resolution_stack = cancellable_stack.to_dict()
	if not action.action_id.is_empty():
		state.processed_action_ids.append(action.action_id)
		if state.processed_action_ids.size() > 256:
			state.processed_action_ids.pop_front()
	result.winner = state.winner
	result.terminal = state.winner >= 0 or state.phase == "GAME_OVER"
	return result


func apply_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	if stack.pending_request == null:
		return _error("当前没有待处理选择。", "stale_choice", state)
	if stack.pending_request.request_id != request.request_id:
		return _error("选择请求已过期。", "stale_choice", state)
	if int(request.metadata.get("revision", state.revision)) != state.revision:
		return _error("局面已变化，选择请求已过期。", "stale_choice", state)
	if (
		response.cancelled
		and request.can_cancel
		and stack.context.get("cancel_action_snapshot") is Dictionary
	):
		var restored_revision := state.revision + 1
		_restore_state(state, stack.context["cancel_action_snapshot"])
		state.revision = restored_revision
		return StepResult.new(true, "操作已取消。", null, [], state.winner, false)
	var snapshot := state.snapshot()
	state.revision += 1
	var step := effect_engine.apply_choice(state, stack, response, rng)
	if not step.success:
		_restore_state(state, snapshot)
		return step
	if step.pending_choice == null and bool(stack.context.get("finish_attack", false)):
		step = _merge_steps(step, _complete_attack_context(state, stack, rng))
	elif step.pending_choice == null:
		_resolve_knockouts(state, request.player, step.events, false)
	step.winner = state.winner
	step.terminal = state.winner >= 0 or state.phase == "GAME_OVER"
	return step


func _dispatch_action(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.phase != "SETUP" and action.action != "PROMOTE" and actor != state.active_player_idx:
		return _error("不是你的回合。", "wrong_actor", state)
	match action.action:
		"NOOP":
			return StepResult.new(true, "", null, [], state.winner, false)
		"SETUP_DONE":
			return _setup_done(state, actor, rng)
		"PROMOTE":
			return _promote(state, actor, int(action.params.get("bench_idx", -1)), rng)
		"PLAY_BASIC":
			return _play_basic(
				state, actor, int(action.params.get("hand_idx", -1)),
				str(action.params.get("target", "")), rng)
		"EVOLVE":
			return _evolve(
				state, actor, int(action.params.get("hand_idx", -1)),
				str(action.params.get("slot", "")), rng)
		"ATTACH_ENERGY":
			return _attach_energy(
				state, actor, int(action.params.get("hand_idx", -1)),
				str(action.params.get("target_slot", "")))
		"PLAY_TRAINER":
			return _play_trainer(
				state, actor, int(action.params.get("hand_idx", -1)),
				str(action.params.get("target_slot", "")), rng)
		"USE_ABILITY":
			return _use_ability(
				state, actor, str(action.params.get("slot", "")),
				str(action.params.get("ability_name", "")), rng)
		"USE_STADIUM":
			return _use_stadium(state, actor, rng)
		"RETREAT":
			return _retreat(
				state, actor, int(action.params.get("bench_idx", -1)),
				Array(action.params.get("energy_indices", [])))
		"DECLARE_ATTACK":
			return _declare_attack(
				state, actor, int(action.params.get("attack_idx", -1)), rng)
		"END_TURN":
			return _end_turn(state, actor, rng)
		_:
			return _error("未知动作: %s" % action.action, "unknown_action", state)


func _setup_actions(state: GameState, actor: int) -> Array[GameAction]:
	var actions: Array[GameAction] = []
	if state.setup_ready[actor]:
		return actions
	var player := state.get_player(actor)
	for hand_idx in range(player.hand.size()):
		var card_id := player.hand[hand_idx]
		if not catalog.is_basic_pokemon(card_id):
			continue
		var source := EntityRef.new("card", actor, "hand", "", hand_idx, "", card_id)
		if player.active == null:
			actions.append(GameAction.new(
				"PLAY_BASIC",
				{"hand_idx": hand_idx, "target": "active"},
				false,
				actor,
				source,
				EntityRef.new("pokemon", actor, "", "active"),
			))
		else:
			for bench_idx in range(player.bench.size()):
				if player.bench[bench_idx] == null:
					var slot := "bench_%d" % bench_idx
					actions.append(GameAction.new(
						"PLAY_BASIC",
						{"hand_idx": hand_idx, "target": slot},
						false,
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot),
					))
	if player.active:
		actions.append(GameAction.new("SETUP_DONE", {}, true, actor))
	return actions


func _setup_done(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.phase != "SETUP":
		return _error("当前不在准备阶段。", "invalid_phase", state)
	if state.get_player(actor).active == null:
		return _error("必须先放置战斗宝可梦。", "missing_active", state)
	state.setup_ready[actor] = true
	if not state.setup_ready[0] or not state.setup_ready[1]:
		return StepResult.new(true, "玩家%d已完成准备。" % (actor + 1))
	state.set_prizes()
	state.active_player_idx = state.first_player_idx
	state.phase = "DRAW"
	state.log_action("准备完成。")
	return _begin_turn(state, rng)


func _play_basic(
	state: GameState,
	actor: int,
	hand_idx: int,
	target: String,
	rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(actor)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _error("无效的手牌序号。", "invalid_hand_index", state)
	var card_id := player.hand[hand_idx]
	var reason := validator.can_play_basic(state, actor, card_id, target)
	if not reason.is_empty():
		return _error(reason, "illegal_basic", state)
	player.hand.remove_at(hand_idx)
	var pokemon := (
		player.place_active(card_id)
		if target == "active"
		else player.place_bench(card_id, target.trim_prefix("bench_").to_int())
	)
	if pokemon == null:
		return _error("无法放置宝可梦。", "placement_failed", state)
	pokemon.placed_this_turn = true
	state.log_action("%s将%s放置到%s。" % [player.name, catalog.card_name(card_id), target])
	var placement_event := {
		"event_type": "pokemon_played",
		"actor": actor,
		"card_id": card_id,
		"source": {
			"player": actor,
			"zone": "hand",
			"index": hand_idx,
		},
		"target": {
			"player": actor,
			"slot": target,
		},
		"data": {
			"player": actor,
			"slot": target,
			"card_id": card_id,
		},
	}
	var effects: Array = []
	for ability_value in catalog.get_card(card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("trigger", "")) == "on_enter_play":
			effects.append_array(ability.get("effects", []))
	if effects.is_empty():
		return StepResult.new(true, "宝可梦已放置。", null, [placement_event])
	var step := _run_effects(state, effects, actor, target, rng)
	step.events.push_front(placement_event)
	return step


func _evolve(
	state: GameState,
	actor: int,
	hand_idx: int,
	slot: String,
	rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(actor)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _error("无效的手牌序号。", "invalid_hand_index", state)
	var card_id := player.hand[hand_idx]
	var reason := validator.can_evolve(state, actor, slot, card_id)
	if not reason.is_empty():
		return _error(reason, "illegal_evolution", state)
	var pokemon := player.get_pokemon(slot)
	player.hand.remove_at(hand_idx)
	pokemon.evolution_stack_ids.append(pokemon.card_id)
	pokemon.card_id = card_id
	pokemon.status_conditions.clear()
	pokemon.can_evolve_this_turn = false
	state.log_action("%s进化为%s。" % [player.name, catalog.card_name(card_id)])
	var evolution_event := {
		"event_type": "pokemon_evolved",
		"actor": actor,
		"card_id": card_id,
		"source": {
			"player": actor,
			"zone": "hand",
			"index": hand_idx,
		},
		"target": {
			"player": actor,
			"slot": slot,
		},
		"data": {
			"player": actor,
			"slot": slot,
			"card_id": card_id,
		},
	}
	var effects: Array = []
	for ability_value in catalog.get_card(card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("trigger", "")) == "on_enter_play":
			effects.append_array(ability.get("effects", []))
	if effects.is_empty():
		return StepResult.new(true, "进化完成。", null, [evolution_event])
	var step := _run_effects(state, effects, actor, slot, rng)
	step.events.push_front(evolution_event)
	return step


func _attach_energy(
	state: GameState,
	actor: int,
	hand_idx: int,
	target_slot: String,
) -> StepResult:
	var player := state.get_player(actor)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _error("无效的手牌序号。", "invalid_hand_index", state)
	var card_id := player.hand[hand_idx]
	var reason := validator.can_attach_energy(state, actor, card_id, target_slot)
	if not reason.is_empty():
		return _error(reason, "illegal_energy_attachment", state)
	var target := player.get_pokemon(target_slot)
	player.hand.remove_at(hand_idx)
	target.energy_card_ids.append(card_id)
	player.energy_attached_this_turn = true
	var events: Array[Dictionary] = [{
		"event_type": "energy_attached",
		"actor": actor,
		"card_id": card_id,
		"source": {"player": actor, "zone": "hand", "index": hand_idx},
		"target": {"player": actor, "slot": target_slot},
		"data": {"player": actor, "slot": target_slot, "card_id": card_id},
	}]
	if card_id == "svi-jete" and target_slot != "active" and player.active:
		player.switch_active_to_bench(target_slot.trim_prefix("bench_").to_int())
		events.append({"event_type": "switched", "data": {"player": actor, "slot": target_slot}})
	state.log_action("%s附着了%s。" % [player.name, catalog.card_name(card_id)])
	return StepResult.new(true, "能量已附着。", null, events)


func _play_trainer(
	state: GameState,
	actor: int,
	hand_idx: int,
	target_slot: String,
	rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(actor)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _error("无效的手牌序号。", "invalid_hand_index", state)
	var card_id := player.hand[hand_idx]
	if not catalog.is_trainer(card_id):
		return _error("该卡不是训练家卡。", "not_trainer", state)
	var reason := validator.can_play_trainer(state, actor, card_id, target_slot)
	if not reason.is_empty():
		return _error(reason, "illegal_trainer", state)
	if card_id == "sv1-153" and player.hand.size() - 1 < 2:
		return _error("高级球需要丢弃2张其他手牌。", "cost_not_payable", state)
	player.hand.remove_at(hand_idx)
	if catalog.is_tool(card_id):
		var tool_target := player.get_pokemon(target_slot)
		tool_target.attached_tool_id = card_id
		return StepResult.new(true, "宝可梦道具已附着。", null, [{
			"event_type": "tool_attached",
			"actor": actor,
			"card_id": card_id,
			"source": {"player": actor, "zone": "hand", "index": hand_idx},
			"target": {"player": actor, "slot": target_slot},
			"data": {
				"player": actor,
				"slot": target_slot,
				"card_id": card_id,
			},
		}])
	var play_event := {
		"event_type": "trainer_played",
		"actor": actor,
		"card_id": card_id,
		"source": {"player": actor, "zone": "hand", "index": hand_idx},
		"target": {"player": actor, "zone": "discard"},
		"data": {"player": actor, "card_id": card_id},
	}
	if catalog.is_stadium(card_id):
		if not state.stadium_card_id.is_empty():
			player.discard.append(state.stadium_card_id)
		state.stadium_card_id = card_id
		player.stadium_played_this_turn = true
		play_event["event_type"] = "stadium_changed"
		play_event["target"] = {"player": actor, "zone": "stadium"}
	else:
		player.discard.append(card_id)
		if catalog.is_supporter(card_id):
			player.supporter_played_this_turn = true
	state.log_action("%s使用了%s。" % [player.name, catalog.card_name(card_id)])
	var effects: Array = catalog.get_card(card_id).get("trainer_effects", [])
	if effects.is_empty():
		return StepResult.new(true, "训练家卡已使用。", null, [play_event])
	var step := _run_effects(state, effects, actor, "active", rng)
	step.events.push_front(play_event)
	return step


func _use_ability(
	state: GameState,
	actor: int,
	slot: String,
	ability_name: String,
	rng: PortableRandomSource,
) -> StepResult:
	var reason := validator.can_use_ability(state, actor, slot, ability_name)
	if not reason.is_empty():
		return _error(reason, "illegal_ability", state)
	var pokemon := state.get_player(actor).get_pokemon(slot)
	for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("name", "")).to_lower() != ability_name.to_lower():
			continue
		if str(ability.get("trigger", "")) != "repeatable":
			pokemon.used_abilities.append(ability_name)
		state.log_action("%s使用特性%s。" % [catalog.card_name(pokemon.card_id), ability_name])
		return _run_effects(state, ability.get("effects", []), actor, slot, rng)
	return _error("没有找到该特性。", "ability_not_found", state)


func _use_stadium(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if not _stadium_is_activatable(state):
		return _error("场上竞技场没有可发动效果。", "stadium_not_activatable", state)
	var player := state.get_player(actor)
	if player.stadium_used_this_turn:
		return _error("本回合已使用过竞技场效果。", "stadium_already_used", state)
	player.stadium_used_this_turn = true
	var effects: Array = catalog.get_card(state.stadium_card_id).get("trainer_effects", [])
	return _run_effects(state, effects, actor, "active", rng)


func _retreat(
	state: GameState,
	actor: int,
	bench_idx: int,
	energy_indices: Array,
) -> StepResult:
	var reason := validator.can_retreat(state, actor, bench_idx, energy_indices)
	if not reason.is_empty():
		return _error(reason, "illegal_retreat", state)
	var player := state.get_player(actor)
	var indices: Array[int] = []
	for value in energy_indices:
		indices.append(int(value))
	indices.sort()
	indices.reverse()
	for index in indices:
		player.discard.append(player.active.energy_card_ids.pop_at(index))
	player.switch_active_to_bench(bench_idx)
	player.retreated_this_turn = true
	state.log_action("%s完成撤退。" % player.name)
	return StepResult.new(true, "撤退完成。", null, [{
		"event_type": "retreat",
		"data": {"player": actor, "bench_idx": bench_idx},
	}])


func _declare_attack(
	state: GameState,
	actor: int,
	attack_idx: int,
	rng: PortableRandomSource,
) -> StepResult:
	var reason := validator.can_attack(state, actor, attack_idx)
	if not reason.is_empty():
		return _error(reason, "illegal_attack", state)
	var attacker := state.get_player(actor).active
	var attack: Dictionary = catalog.get_card(attacker.card_id).get("attacks", [])[attack_idx]
	state.phase = "ATTACK"
	state.log_action("%s使用了%s。" % [catalog.card_name(attacker.card_id), attack.get("name", "")])
	var attack_event := {
		"event_type": "attack_declared",
		"actor": actor,
		"card_id": attacker.card_id,
		"source": {"player": actor, "slot": "active"},
		"target": {"player": 1 - actor, "slot": "active"},
		"data": {
			"player": actor,
			"attack_idx": attack_idx,
			"attack_name": str(attack.get("name", "")),
			"card_id": attacker.card_id,
		},
	}

	if "CONFUSED" in attacker.status_conditions and not rng.coin():
		attacker.damage_counters += 3
		var confused_events: Array[Dictionary] = [attack_event, {
			"event_type": "confusion_failed",
			"data": {"player": actor, "self_damage": 30},
		}]
		_resolve_knockouts(state, actor, confused_events, false)
		return _merge_steps(
			StepResult.new(true, "混乱判定失败，攻击未生效。", null, confused_events),
			_end_turn(state, actor, rng),
		)
	if attacker.dazzled:
		attacker.dazzled = false
		if not rng.coin():
			return _merge_steps(
				StepResult.new(true, "炫目判定失败，攻击未生效。"),
				_end_turn(state, actor, rng),
			)

	var replace_base := false
	for effect_value in attack.get("effects", []):
		var effect: Dictionary = effect_value
		if str(effect.get("effect_type", "")) in FULL_DAMAGE_EFFECT_TYPES:
			replace_base = true
			break
	var card := catalog.get_card(attacker.card_id)
	var attacking_type := "Colorless"
	if not card.get("energy_types", []).is_empty():
		attacking_type = str(card.get("energy_types", [])[0])
	var context := {
		"finish_attack": true,
		"actor": actor,
		"base_damage": 0 if replace_base else int(attack.get("damage", 0)),
		"attacking_type": attacking_type,
	}
	var step := _run_effects(
		state, attack.get("effects", []), actor, "active", rng, context)
	if not step.success or step.pending_choice:
		step.events.push_front(attack_event)
		return step
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	step.events.push_front(attack_event)
	return _merge_steps(step, _complete_attack_context(state, stack, rng))


func _run_effects(
	state: GameState,
	effects: Array,
	actor: int,
	source_slot: String,
	rng: PortableRandomSource,
	context: Dictionary = {},
) -> StepResult:
	var stack := ResolutionStack.new()
	stack.context = context.duplicate(true)
	stack.push_effects(effects, actor, source_slot)
	return effect_engine.resolve(state, stack, rng)


func _complete_attack_context(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	if not bool(stack.context.get("finish_attack", false)):
		return StepResult.new(true)
	var actor := int(stack.context.get("actor", state.active_player_idx))
	var events: Array[Dictionary] = []
	if not bool(stack.context.get("attack_failed", false)):
		_apply_attack_damage(
			state,
			actor,
			int(stack.context.get("base_damage", 0)),
			str(stack.context.get("attacking_type", "Colorless")),
			bool(stack.context.get("piercing", false)),
			bool(stack.context.get("ignore_defender_effects", false)),
			events,
		)
	_resolve_knockouts(state, actor, events, true)
	state.resolution_stack = ResolutionStack.new().to_dict()
	var damage_step := StepResult.new(true, "", null, events, state.winner, state.winner >= 0)
	if state.winner >= 0:
		return damage_step
	return _merge_steps(damage_step, _end_turn(state, actor, rng))


func _apply_attack_damage(
	state: GameState,
	actor: int,
	base_damage: int,
	attacking_type: String,
	piercing: bool,
	ignore_defender_effects: bool,
	events: Array[Dictionary],
) -> void:
	var attacker := state.get_player(actor).active
	var defender := state.get_player(1 - actor).active
	if attacker == null or defender == null or base_damage <= 0:
		return
	if defender.damage_prevented_next_turn and not ignore_defender_effects:
		defender.damage_prevented_next_turn = false
		defender.all_prevented_next_turn = false
		events.append({"event_type": "damage_prevented", "data": {"player": 1 - actor}})
		return
	var damage := base_damage
	if not ignore_defender_effects:
		for ability_value in catalog.get_card(defender.card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			for effect_value in ability.get("effects", []):
				var effect: Dictionary = effect_value
				if str(effect.get("effect_type", "")) == "aura_damage_reduction":
					var params: Dictionary = effect.get("params", {})
					if bool(params.get("requires_attached_energy", false)) and defender.energy_card_ids.is_empty():
						continue
					damage -= int(params.get("reduction", 20))
	for row in state.get_player(actor).get_all_pokemon():
		var aura_source: PokemonState = row["pokemon"]
		if aura_source == null:
			continue
		for ability_value in catalog.get_card(aura_source.card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			for effect_value in ability.get("effects", []):
				var effect: Dictionary = effect_value
				if str(effect.get("effect_type", "")) != "aura_damage_boost":
					continue
				var params: Dictionary = effect.get("params", {})
				var attacker_subtype := str(params.get("attacker_subtype", ""))
				var defender_type := str(params.get("defender_type", ""))
				if (
					not attacker_subtype.is_empty()
					and attacker_subtype not in catalog.get_card(attacker.card_id).get("subtypes", [])
				):
					continue
				if (
					not defender_type.is_empty()
					and defender_type not in catalog.get_card(defender.card_id).get("energy_types", [])
				):
					continue
				damage += int(params.get("amount", 0))
	for energy_id in attacker.energy_card_ids:
		if energy_id == "svi-dtur":
			damage -= 20
	if attacker.outgoing_damage_reduction_next_turn > 0:
		damage -= attacker.outgoing_damage_reduction_next_turn
		attacker.outgoing_damage_reduction_next_turn = 0
	if not attacker.attached_tool_id.is_empty():
		for effect_value in catalog.get_card(attacker.attached_tool_id).get("trainer_effects", []):
			var effect: Dictionary = effect_value
			if str(effect.get("effect_type", "")) != "tool":
				continue
			var modifier := str(effect.get("params", {}).get("effect", ""))
			if modifier == "damage_boost_10":
				damage += 10
			elif (
				modifier == "damage_boost_when_behind"
				and state.get_player(actor).prizes.size() > state.get_player(1 - actor).prizes.size()
			):
				damage += 30
	if not ignore_defender_effects and not defender.attached_tool_id.is_empty():
		for effect_value in catalog.get_card(defender.attached_tool_id).get("trainer_effects", []):
			var effect: Dictionary = effect_value
			if str(effect.get("effect_type", "")) != "tool":
				continue
			var modifier := str(effect.get("params", {}).get("effect", ""))
			if modifier == "damage_reduction_stage1" and catalog.is_stage1(defender.card_id):
				damage -= int(effect.get("params", {}).get("amount", 30))
	damage = max(0, damage)
	if state.apply_type_matchups and not piercing:
		var defending_card := catalog.get_card(defender.card_id)
		for weakness_value in defending_card.get("weaknesses", []):
			var weakness: Dictionary = weakness_value
			if str(weakness.get("energy_type", "")) == attacking_type:
				var value := str(weakness.get("value", ""))
				if value in ["×2", "x2"]:
					damage *= 2
				break
		for resistance_value in defending_card.get("resistances", []):
			var resistance: Dictionary = resistance_value
			if str(resistance.get("energy_type", "")) == attacking_type:
				damage -= abs(int(str(resistance.get("value", "0")).replace("-", "")))
				break
	damage = max(0, damage)
	defender.damage_counters += int(float(damage) / 10.0)
	events.append({"event_type": "damage_dealt", "data": {
		"player": 1 - actor, "slot": "active", "amount": damage,
	}})
	if damage > 0 and not ignore_defender_effects and "svi-mirc" in defender.energy_card_ids:
		var drawn := state.get_player(1 - actor).draw_cards(1)
		if not drawn.is_empty():
			events.append({"event_type": "cards_drawn", "data": {
				"player": 1 - actor, "cards": drawn,
			}})
	if damage > 0 and not ignore_defender_effects:
		_apply_reactive_thorns(state, actor, defender, events)


func _apply_reactive_thorns(
	state: GameState,
	actor: int,
	defender: PokemonState,
	events: Array[Dictionary],
) -> void:
	for ability_value in catalog.get_card(defender.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		for effect_value in ability.get("effects", []):
			var effect: Dictionary = effect_value
			if str(effect.get("effect_type", "")) != "reactive_thorns":
				continue
			var names: Array = effect.get("params", {}).get("filter_names", [])
			var count := 0
			for row in state.get_player(1 - actor).get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon and catalog.card_name(pokemon.card_id) in names:
					count += 1
			var counters := count * int(effect.get("params", {}).get("per_pokemon", 3))
			var attacker := state.get_player(actor).active
			if attacker and counters > 0:
				attacker.damage_counters += counters
				events.append({"event_type": "damage_counters_placed", "data": {
					"player": actor, "slot": "active", "count": counters,
				}})


func _end_turn(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.winner >= 0:
		return StepResult.new(true, "", null, [], state.winner, true)
	if actor != state.active_player_idx:
		return _error("不是你的回合。", "wrong_actor", state)
	var events: Array[Dictionary] = [{
		"event_type": "turn_end",
		"data": {"player": actor, "turn": state.turn_number},
	}]
	state.phase = "POKEMON_CHECKUP"
	_resolve_checkup(state, rng, events)
	_resolve_knockouts(state, actor, events, false)
	if state.winner >= 0:
		return StepResult.new(true, "对局结束。", null, events, state.winner, true)
	var outgoing := state.get_player(actor)
	for row in outgoing.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon:
			pokemon.outgoing_damage_reduction_next_turn = 0
			pokemon.dazzled = false
			pokemon.attack_locked = false
			var expired: Array[String] = []
			for attack_name in pokemon.attack_locked_names:
				if state.turn_number >= int(pokemon.attack_locked_names[attack_name]) + 2:
					expired.append(str(attack_name))
			for attack_name in expired:
				pokemon.attack_locked_names.erase(attack_name)
	outgoing.was_ko_by_attack = false
	state.active_player_idx = 1 - actor
	state.turn_number += 1
	state.get_player(state.active_player_idx).reset_turn_flags()
	state.phase = "DRAW"
	var incoming := state.get_player(state.active_player_idx)
	if incoming.active == null and incoming.bench_count() > 0:
		if state.active_player_idx not in state.pending_promotions:
			state.pending_promotions.append(state.active_player_idx)
		return StepResult.new(true, "需要选择新的战斗宝可梦。", null, events)
	var begin := _begin_turn(state, rng)
	begin.events = events + begin.events
	return begin


func _begin_turn(
	state: GameState,
	_rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(state.active_player_idx)
	var events: Array[Dictionary] = []
	if state.turn_number != 1:
		var drawn := player.draw_cards(1)
		if drawn.is_empty():
			state.winner = 1 - state.active_player_idx
			state.phase = "GAME_OVER"
			return StepResult.new(
				true, "牌库耗尽。", null, [], state.winner, true)
		events.append({
			"event_type": "cards_drawn",
			"actor": state.active_player_idx,
			"visibility": "owner",
			"card_id": drawn[0] if not drawn.is_empty() else "",
			"source": {"player": state.active_player_idx, "zone": "deck"},
			"target": {"player": state.active_player_idx, "zone": "hand"},
			"data": {
				"player": state.active_player_idx,
				"count": drawn.size(),
				"card_ids": drawn.duplicate(),
			},
		})
	state.phase = "MAIN"
	state.log_action("—— %s的第%d回合 ——" % [player.name, state.turn_number])
	events.append({
		"event_type": "turn_start",
		"actor": state.active_player_idx,
		"data": {"player": state.active_player_idx, "turn": state.turn_number},
	})
	return StepResult.new(true, "回合开始。", null, events)


func _promote(
	state: GameState,
	actor: int,
	bench_idx: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.pending_promotions.is_empty() or int(state.pending_promotions[0]) != actor:
		return _error("当前没有该玩家的晋升请求。", "invalid_promotion", state)
	var player := state.get_player(actor)
	if not player.promote_from_bench(bench_idx):
		return _error("晋升目标无效。", "invalid_promotion_target", state)
	state.pending_promotions.pop_front()
	var events: Array[Dictionary] = [{
		"event_type": "promoted",
		"data": {"player": actor, "bench_idx": bench_idx},
	}]
	if state.pending_promotions.is_empty() and state.phase == "DRAW":
		var begin := _begin_turn(state, rng)
		begin.events = events + begin.events
		return begin
	return StepResult.new(true, "晋升完成。", null, events)


func _resolve_checkup(
	state: GameState,
	rng: PortableRandomSource,
	events: Array[Dictionary],
) -> void:
	for player_idx in [0, 1]:
		var pokemon := state.get_player(player_idx).active
		if pokemon == null:
			continue
		if "POISONED" in pokemon.status_conditions:
			pokemon.damage_counters += 1
		if "BURNED" in pokemon.status_conditions:
			pokemon.damage_counters += 2
			if rng.coin():
				pokemon.status_conditions.erase("BURNED")
		if "ASLEEP" in pokemon.status_conditions and rng.coin():
			pokemon.status_conditions.erase("ASLEEP")
		if (
			"PARALYZED" in pokemon.status_conditions
			and state.turn_number > pokemon.paralyzed_since_turn
		):
			pokemon.status_conditions.erase("PARALYZED")
	events.append({"event_type": "checkup", "data": {"turn": state.turn_number}})


func _resolve_knockouts(
	state: GameState,
	attack_actor: int,
	events: Array[Dictionary],
	from_attack: bool,
) -> void:
	var knockouts: Array[Dictionary] = []
	for player_idx in [0, 1]:
		for row in state.get_player(player_idx).get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon and pokemon.is_knocked_out(catalog):
				knockouts.append({
					"player": player_idx,
					"slot": str(row["slot"]),
					"card_id": pokemon.card_id,
					"prizes": catalog.prize_value(pokemon.card_id),
				})
	if knockouts.is_empty():
		return
	for knockout in knockouts:
		var defeated_idx := int(knockout["player"])
		var defeated_player := state.get_player(defeated_idx)
		var knocked_out := defeated_player.get_pokemon(str(knockout["slot"]))
		if knocked_out == null:
			continue
		if from_attack and defeated_idx != attack_actor:
			_apply_exp_share(
				state,
				defeated_idx,
				str(knockout["slot"]),
				knocked_out,
				events,
			)
		state.discard_pokemon(defeated_idx, str(knockout["slot"]))
		var winner_idx := 1 - defeated_idx
		for _index in range(int(knockout["prizes"])):
			var prize_card_id := state.get_player(winner_idx).take_prize()
			events.append({
				"event_type": "prize_taken",
				"actor": winner_idx,
				"visibility": "owner",
				"card_id": prize_card_id,
				"source": {"player": winner_idx, "zone": "prizes"},
				"target": {"player": winner_idx, "zone": "hand"},
				"data": {
					"player": winner_idx,
					"count": 1,
					"card_id": prize_card_id,
				},
			})
		if from_attack and defeated_idx != attack_actor:
			defeated_player.was_ko_by_attack = true
		events.append({"event_type": "pokemon_ko", "data": knockout.duplicate(true)})
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		if player.active == null and player.bench_count() > 0 and player_idx not in state.pending_promotions:
			state.pending_promotions.append(player_idx)
	var rules_winner := validator.check_winner(state)
	if rules_winner >= 0:
		state.winner = rules_winner
	if state.winner >= 0:
		state.phase = "GAME_OVER"


func _apply_exp_share(
	state: GameState,
	defeated_idx: int,
	source_slot: String,
	knocked_out: PokemonState,
	events: Array[Dictionary],
) -> void:
	var player := state.get_player(defeated_idx)
	var basic_energy_index := -1
	for index in range(knocked_out.energy_card_ids.size()):
		if catalog.is_basic_energy(knocked_out.energy_card_ids[index]):
			basic_energy_index = index
			break
	if basic_energy_index < 0:
		return
	for bench_index in range(player.bench.size()):
		var bench_pokemon: PokemonState = player.bench[bench_index]
		if (
			bench_pokemon is PokemonState
			and not bench_pokemon.attached_tool_id.is_empty()
			and _tool_has_effect(bench_pokemon.attached_tool_id, "tool_exp_share")
		):
			var energy_id: String = knocked_out.energy_card_ids.pop_at(basic_energy_index)
			bench_pokemon.energy_card_ids.append(energy_id)
			var target_slot := "bench_%d" % bench_index
			events.append({
				"event_type": "energy_attached",
				"actor": defeated_idx,
				"card_id": energy_id,
				"source": {"player": defeated_idx, "slot": source_slot},
				"target": {"player": defeated_idx, "slot": target_slot},
				"data": {
					"player": defeated_idx,
					"slot": target_slot,
					"card_id": energy_id,
					"source": "exp_share",
					"source_slot": source_slot,
				},
			})
			return


func _tool_has_effect(tool_id: String, effect_type: String) -> bool:
	for effect_value in catalog.get_card(tool_id).get("trainer_effects", []):
		if str(effect_value.get("effect_type", "")) == effect_type:
			return true
	return false


func _retreat_payments(
	state: GameState,
	actor: int,
	bench_idx: int,
) -> Array[Array]:
	var result: Array[Array] = []
	var player := state.get_player(actor)
	if player.active == null or player.bench[bench_idx] == null:
		return result
	var cost := validator.effective_retreat_cost(state, player)
	if cost <= 0:
		if validator.can_retreat(state, actor, bench_idx, []).is_empty():
			result.append([])
		return result
	var count := player.active.energy_card_ids.size()
	if count > 12:
		return result
	for mask in range(1, 1 << count):
		var indices: Array[int] = []
		var units := 0
		for index in range(count):
			if mask & (1 << index):
				indices.append(index)
				units += max(1, catalog.provides_energy(
					player.active.energy_card_ids[index]).size())
		if units < cost:
			continue
		var minimal := true
		for index in indices:
			var reduced: int = units - max(1, catalog.provides_energy(
				player.active.energy_card_ids[index]).size())
			if reduced >= cost:
				minimal = false
				break
		if minimal and validator.can_retreat(state, actor, bench_idx, indices).is_empty():
			result.append(indices)
	return result


func _simulated_action_succeeds(state: GameState, action: GameAction) -> bool:
	var simulation := GameState.from_dict(state.snapshot())
	var result := apply_action(simulation, action, PortableRandomSource.new(1))
	return result.success


func _action_cost_error(
	state: GameState,
	action: GameAction,
	actor: int,
) -> String:
	if action.action != "PLAY_TRAINER":
		return ""
	var player := state.get_player(actor)
	var hand_idx := int(action.params.get("hand_idx", -1))
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return ""
	var effects: Array = catalog.get_card(str(player.hand[hand_idx])).get("trainer_effects", [])
	if effects.is_empty() or _effects_cost_is_payable(state, actor, effects, hand_idx):
		return ""
	return "无法支付代价。"


func _action_target_availability_error(
	state: GameState,
	action: GameAction,
	actor: int,
) -> String:
	match action.action:
		"PLAY_TRAINER":
			var player := state.get_player(actor)
			var hand_idx := int(action.params.get("hand_idx", -1))
			if hand_idx < 0 or hand_idx >= player.hand.size():
				return ""
			var card_id := str(player.hand[hand_idx])
			var effects: Array = catalog.get_card(card_id).get("trainer_effects", [])
			if effects.is_empty():
				return ""
			var source_slot := str(action.params.get("target_slot", "active"))
			if source_slot.is_empty():
				source_slot = "active"
			if not _effects_have_legal_target(state, actor, effects, source_slot, hand_idx):
				return "没有合法目标，不能使用。"
		"USE_ABILITY":
			var slot := str(action.params.get("slot", ""))
			var pokemon := state.get_player(actor).get_pokemon(slot)
			if pokemon == null:
				return ""
			var ability_name := str(action.params.get("ability_name", "")).to_lower()
			for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
				var ability: Dictionary = ability_value
				if str(ability.get("name", "")).to_lower() != ability_name:
					continue
				var ability_effects: Array = ability.get("effects", [])
				if (
					not ability_effects.is_empty()
					and not _effects_have_legal_target(state, actor, ability_effects, slot)
				):
					return "没有合法目标，不能使用该特性。"
				break
		"USE_STADIUM":
			if state.stadium_card_id.is_empty():
				return ""
			var stadium_effects: Array = catalog.get_card(state.stadium_card_id).get("trainer_effects", [])
			if (
				not stadium_effects.is_empty()
				and not _effects_have_legal_target(state, actor, stadium_effects, "active")
			):
				return "没有合法目标，不能使用竞技场。"
		"DECLARE_ATTACK":
			var attacker := state.get_player(actor).active
			if attacker == null:
				return ""
			var attack_idx := int(action.params.get("attack_idx", -1))
			var attacks: Array = catalog.get_card(attacker.card_id).get("attacks", [])
			if attack_idx < 0 or attack_idx >= attacks.size():
				return ""
			var attack: Dictionary = attacks[attack_idx]
			if int(attack.get("damage", 0)) > 0 and state.get_player(1 - actor).active != null:
				return ""
			if not _effects_have_legal_target(state, actor, attack.get("effects", []), "active"):
				return "没有合法目标，不能使用该招式。"
	return ""


func _effects_have_legal_target(
	state: GameState,
	player_idx: int,
	effects: Variant,
	source_slot: String = "active",
	exclude_hand_index: int = -1,
	depth: int = 0,
) -> bool:
	if depth > 8:
		return false
	var effect_list := _effect_list(effects)
	if effect_list.is_empty():
		return true
	var player := state.get_player(player_idx)
	var opponent := state.get_player(1 - player_idx)
	var saw_checked_effect := false
	for effect_value in effect_list:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value
		var effect_type := str(effect.get("effect_type", ""))
		if effect_type.is_empty():
			continue
		var raw_params: Variant = effect.get("params", {})
		var params: Dictionary = {}
		if raw_params is Dictionary:
			params = Dictionary(raw_params)
		if effect_type in TARGET_DAMAGE_EFFECT_TYPES:
			return opponent.active != null
		if _effect_is_always_usable(effect_type):
			return true
		match effect_type:
			"hand_to_bottom_draw", "houb":
				saw_checked_effect = true
				if _available_hand_count(player, exclude_hand_index) > 0:
					return true
			"zinnia_resolve":
				saw_checked_effect = true
				if _available_hand_count(player, exclude_hand_index) >= 2:
					return true
			"search":
				saw_checked_effect = true
				if _search_has_target(state, player_idx, params, exclude_hand_index):
					return true
			"look_top_deck":
				saw_checked_effect = true
				if _look_top_has_target(state, player_idx, params):
					return true
			"conditional_search_extra", "search_any_and_switch":
				saw_checked_effect = true
				var search_params := params.duplicate(true)
				search_params["from_zone"] = str(search_params.get("from_zone", "deck"))
				search_params["destination"] = str(search_params.get("destination", "hand"))
				if not search_params.has("filter"):
					search_params["filter"] = "grass_pokemon" if effect_type == "conditional_search_extra" else "any"
				if _search_has_target(state, player_idx, search_params, exclude_hand_index):
					return true
			"look_top_attach_energy":
				saw_checked_effect = true
				if _look_top_attach_has_target(state, player_idx, params):
					return true
			"arven":
				saw_checked_effect = true
				for card_id in player.deck:
					if catalog.is_item(card_id) or catalog.is_tool(card_id):
						return true
			"shuffle_from_discard":
				saw_checked_effect = true
				if _zone_has_matching_cards(player.discard, params):
					return true
			"clara":
				saw_checked_effect = true
				for card_id in player.discard:
					if catalog.is_pokemon(card_id) or catalog.is_basic_energy(card_id):
						return true
			"energy_attach":
				saw_checked_effect = true
				if _energy_attach_has_target(state, player_idx, params, source_slot, exclude_hand_index):
					return true
			"attach_from_discard":
				saw_checked_effect = true
				var attach_params := params.duplicate(true)
				attach_params["from_zone"] = "discard"
				if _energy_attach_has_target(state, player_idx, attach_params, source_slot, exclude_hand_index):
					return true
			"draw_and_attach_energy":
				saw_checked_effect = true
				var draw_attach_params := {
					"from_zone": "hand",
					"filter": str(params.get("energy_type", "Grass")),
					"amount": int(params.get("energy_count", 2)),
					"to": "bench",
				}
				if _energy_attach_has_target(
					state, player_idx, draw_attach_params, source_slot, exclude_hand_index, true
				):
					return true
			"energy_relocate":
				saw_checked_effect = true
				if _energy_relocate_has_target(state, player_idx, params, source_slot):
					return true
			"switch_self":
				saw_checked_effect = true
				if player.active != null and player.bench_count() > 0:
					return true
			"switch_opponent":
				saw_checked_effect = true
				if (
					opponent.active != null
					and opponent.bench_count() > 0
					and not opponent.active.all_prevented_next_turn
				):
					return true
			"heal":
				saw_checked_effect = true
				if _heal_has_target(player, params, source_slot):
					return true
			"heal_all", "potion_heal", "damage_and_self_heal", "conditional_damage_heal":
				saw_checked_effect = true
				if _player_has_damaged_pokemon(player):
					return true
				if effect_type in ["damage_and_self_heal", "conditional_damage_heal"] and opponent.active != null:
					return true
			"energy_discard":
				saw_checked_effect = true
				if _energy_discard_has_target(state, player_idx, params, source_slot):
					return true
			"coin_flip_energy_discard":
				saw_checked_effect = true
				if _player_has_attached_energy(opponent):
					return true
			"any_pokemon_damage", "place_counters_and_self_ko":
				saw_checked_effect = true
				if _player_has_effect_target_pokemon(opponent):
					return true
			"bench_damage":
				saw_checked_effect = true
				if opponent.bench_count() > 0:
					return true
			"status", "conditional_status", "attack_lock_basic", "dazzling_beam":
				saw_checked_effect = true
				if opponent.active != null and not opponent.active.all_prevented_next_turn:
					return true
			"damage_counter_self":
				saw_checked_effect = true
				var source := player.get_pokemon(source_slot)
				if source != null and source.current_hp(catalog) > int(params.get("amount", 0)):
					return true
			"evolve_skip_stage":
				saw_checked_effect = true
				if _rare_candy_has_target(state, player_idx, exclude_hand_index):
					return true
			"ability_discard_revive":
				saw_checked_effect = true
				var revive_id := str(params.get("card_id", ""))
				if (
					not revive_id.is_empty()
					and player.discard.has(revive_id)
					and player.hand.is_empty()
					and player.find_empty_bench_slot() >= 0
				):
					return true
			"conditional":
				saw_checked_effect = true
				if _conditional_has_target(
					state, player_idx, params, source_slot, exclude_hand_index, depth
				):
					return true
			"coin_flip", "coin_flip_triple", "coin_flip_double_ko", "coin_flip_until_tails":
				saw_checked_effect = true
				if _coin_has_target(state, player_idx, params, source_slot, exclude_hand_index, depth):
					return true
			_:
				return true
	return not saw_checked_effect


func _effect_list(effects: Variant) -> Array:
	var result: Array = []
	if effects is Array:
		result = effects
	elif effects is Dictionary:
		result.append(effects)
	return result


func _effect_is_always_usable(effect_type: String) -> bool:
	return effect_type in [
		"draw",
		"shuffle_draw",
		"discard_draw",
		"discard_then_draw",
		"draw_until",
		"draw_until_more",
		"judge",
		"trekking_shoes",
		"return_to_hand",
		"self_attack_lock",
		"prevent_all",
		"prevent_damage",
		"prevent_effects",
		"piercing_marker",
		"tool",
		"tool_exp_share",
		"aura_damage_reduction",
		"aura_damage_boost",
		"conditional_hp_boost",
		"conditional_zero_retreat",
		"reactive_thorns",
		"apply_outgoing_damage_reduction",
	]


func _effects_cost_is_payable(
	state: GameState,
	player_idx: int,
	effects: Variant,
	exclude_hand_index: int,
) -> bool:
	for effect_value in _effect_list(effects):
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value
		var effect_type := str(effect.get("effect_type", ""))
		if effect_type == "discard":
			if not _cost_is_payable(state, player_idx, effect, exclude_hand_index):
				return false
		elif effect_type == "conditional":
			var raw_params: Variant = effect.get("params", {})
			if not (raw_params is Dictionary):
				continue
			var cost: Variant = Dictionary(raw_params).get("cost")
			if cost != null and not _cost_is_payable(state, player_idx, cost, exclude_hand_index):
				return false
	return true


func _available_hand_count(player: PlayerState, exclude_hand_index: int) -> int:
	if exclude_hand_index < 0:
		return player.hand.size()
	return max(0, player.hand.size() - 1)


func _zone_cards(
	state: GameState,
	player_idx: int,
	zone: String,
	exclude_hand_index: int = -1,
) -> Array[String]:
	var player := state.get_player(player_idx)
	var result: Array[String] = []
	match zone:
		"discard":
			result.assign(player.discard)
		"hand":
			for index in range(player.hand.size()):
				if index != exclude_hand_index:
					result.append(player.hand[index])
		_:
			result.assign(player.deck)
	return result


func _search_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	exclude_hand_index: int,
) -> bool:
	var player := state.get_player(player_idx)
	var destination := str(params.get("destination", "hand"))
	if destination == "bench" and player.find_empty_bench_slot() < 0:
		return false
	if destination == "bench_energy" and _energy_effect_target_slots(state, player_idx, params, "active").is_empty():
		return false
	var from_zone := str(params.get("from_zone", "deck"))
	var pool := _zone_cards(state, player_idx, from_zone, exclude_hand_index)
	return _zone_has_matching_cards(pool, params)


func _look_top_has_target(state: GameState, player_idx: int, params: Dictionary) -> bool:
	var player := state.get_player(player_idx)
	if str(params.get("destination", "hand")) == "bench_energy":
		if _energy_effect_target_slots(state, player_idx, params, "active").is_empty():
			return false
	var count: int = min(int(params.get("count", 1)), player.deck.size())
	var pool: Array[String] = []
	for offset in range(count):
		pool.append(player.deck[player.deck.size() - 1 - offset])
	return _zone_has_matching_cards(pool, params)


func _look_top_attach_has_target(state: GameState, player_idx: int, params: Dictionary) -> bool:
	var player := state.get_player(player_idx)
	if not player.has_any_pokemon_in_play():
		return false
	var count: int = min(int(params.get("count", 5)), player.deck.size())
	var filter_type := str(params.get("filter", "basic_energy"))
	for offset in range(count):
		var card_id := str(player.deck[player.deck.size() - 1 - offset])
		if _energy_matches(card_id, filter_type):
			return true
	return false


func _zone_has_matching_cards(card_ids: Array, params: Dictionary) -> bool:
	var filter_type := str(params.get("filter", "any"))
	var filter_name := str(params.get("filter_name", ""))
	for card_id_value in card_ids:
		if _card_matches_filter(str(card_id_value), filter_type, filter_name):
			return true
	return false


func _card_matches_filter(card_id: String, filter_type: String, filter_name: String = "") -> bool:
	if not filter_name.is_empty() and catalog.card_name(card_id) != filter_name:
		return false
	var normalized := filter_type.to_lower()
	match normalized:
		"", "any":
			return true
		"basic_pokemon":
			return catalog.is_basic_pokemon(card_id)
		"pokemon":
			return catalog.is_pokemon(card_id)
		"basic", "basic_energy", "basic_energy_card":
			return catalog.is_basic_energy(card_id)
		"energy", "energy_card":
			return catalog.is_energy(card_id)
		"supporter":
			return catalog.is_supporter(card_id)
		"item":
			return catalog.is_item(card_id)
		"item_or_tool":
			return catalog.is_item(card_id) or catalog.is_tool(card_id)
		"pokemon_and_energy":
			return catalog.is_pokemon(card_id) or catalog.is_basic_energy(card_id)
		"grass_pokemon":
			return catalog.is_pokemon(card_id) and "Grass" in catalog.get_card(card_id).get("energy_types", [])
		"water_pokemon_and_energy":
			return (
				(catalog.is_pokemon(card_id) and "Water" in catalog.get_card(card_id).get("energy_types", []))
				or _energy_matches(card_id, "water")
			)
	if normalized.ends_with("_energy"):
		return _energy_matches(card_id, normalized)
	return true


func _energy_matches(card_id: String, filter_type: String) -> bool:
	if not catalog.is_energy(card_id):
		return false
	var normalized := filter_type.to_lower()
	if normalized in ["", "any", "energy"]:
		return true
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	if normalized.ends_with("_energy"):
		normalized = normalized.trim_suffix("_energy")
	if normalized == "basic":
		return catalog.is_basic_energy(card_id)
	for provided in catalog.provides_energy(card_id):
		if str(provided).to_lower() == normalized:
			return true
	return false


func _energy_attach_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
	exclude_hand_index: int,
	include_deck: bool = false,
) -> bool:
	var player := state.get_player(player_idx)
	var from_zone := str(params.get("from_zone", "deck"))
	var filter_type := str(params.get("filter", params.get("energy_type", "any")))
	var source_cards: Array[String] = []
	match from_zone:
		"discard":
			source_cards.assign(player.discard)
		"hand":
			source_cards = _zone_cards(state, player_idx, "hand", exclude_hand_index)
			if include_deck:
				source_cards.append_array(player.deck)
		_:
			source_cards.assign(player.deck)
	var has_energy := false
	for card_id in source_cards:
		if _energy_matches(card_id, filter_type):
			has_energy = true
			break
	if not has_energy:
		return false
	return not _energy_effect_target_slots(state, player_idx, params, source_slot).is_empty()


func _energy_effect_target_slots(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
) -> Array[String]:
	var player := state.get_player(player_idx)
	var target_spec := str(params.get("to", params.get("target", "self")))
	var target_type := str(params.get("target_pokemon_type", ""))
	if str(params.get("destination", "")) == "bench_energy":
		target_spec = "bench"
		if target_type.is_empty():
			target_type = "Lightning"
	var slots: Array[String] = []
	match target_spec:
		"self":
			var pokemon := player.get_pokemon(source_slot)
			if pokemon != null and _pokemon_matches_target_type(pokemon, target_type):
				slots.append(source_slot)
		"bench":
			for index in range(player.bench.size()):
				var bench_pokemon: PokemonState = player.bench[index]
				if bench_pokemon != null and _pokemon_matches_target_type(bench_pokemon, target_type):
					slots.append("bench_%d" % index)
		"self_basic":
			for row in player.get_all_pokemon():
				var own_pokemon: PokemonState = row["pokemon"]
				if (
					own_pokemon != null
					and catalog.is_basic_pokemon(own_pokemon.card_id)
					and _pokemon_matches_target_type(own_pokemon, target_type)
				):
					slots.append(str(row["slot"]))
		"any", "self_or_bench":
			for row in player.get_all_pokemon():
				var any_pokemon: PokemonState = row["pokemon"]
				if any_pokemon != null and _pokemon_matches_target_type(any_pokemon, target_type):
					slots.append(str(row["slot"]))
		_:
			var explicit_pokemon := player.get_pokemon(target_spec)
			if explicit_pokemon != null and _pokemon_matches_target_type(explicit_pokemon, target_type):
				slots.append(target_spec)
	return slots


func _pokemon_matches_target_type(pokemon: PokemonState, target_type: String) -> bool:
	if target_type.is_empty():
		return true
	var normalized := target_type.to_lower()
	for card_type in catalog.get_card(pokemon.card_id).get("energy_types", []):
		if str(card_type).to_lower() == normalized:
			return true
	return false


func _energy_relocate_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
) -> bool:
	var player := state.get_player(player_idx)
	var energy_type := str(params.get("energy_type", params.get("filter", "any")))
	var candidates: Array[Dictionary] = []
	if bool(params.get("from_self", false)):
		candidates.append({"slot": source_slot, "pokemon": player.get_pokemon(source_slot)})
	else:
		candidates = player.get_all_pokemon()
	var target_slots: Array[String] = []
	for row in player.get_all_pokemon():
		if row["pokemon"] != null:
			target_slots.append(str(row["slot"]))
	if target_slots.size() < 2:
		return false
	for row in candidates:
		var pokemon: PokemonState = row["pokemon"]
		var slot := str(row["slot"])
		if pokemon == null:
			continue
		var has_matching_energy := false
		for energy_id in pokemon.energy_card_ids:
			if _energy_matches(energy_id, energy_type):
				has_matching_energy = true
				break
		if not has_matching_energy:
			continue
		for target_slot in target_slots:
			if target_slot != slot:
				return true
	return false


func _heal_has_target(player: PlayerState, params: Dictionary, source_slot: String) -> bool:
	var target := str(params.get("target", "self"))
	if target == "all":
		return _player_has_damaged_pokemon(player)
	var pokemon := player.get_pokemon(source_slot if target == "self" else target)
	return pokemon != null and pokemon.damage_counters > 0


func _energy_discard_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
) -> bool:
	var from_target := str(params.get("from", "self"))
	var owner := state.get_player(player_idx if from_target == "self" else 1 - player_idx)
	var pokemon := owner.get_pokemon(source_slot) if from_target == "self" else owner.active
	if pokemon == null:
		return false
	if from_target != "self" and pokemon.all_prevented_next_turn:
		return false
	var energy_type := str(params.get("filter", params.get("energy_type", "any")))
	for energy_id in pokemon.energy_card_ids:
		if _energy_matches(energy_id, energy_type):
			return true
	return false


func _rare_candy_has_target(
	state: GameState,
	player_idx: int,
	exclude_hand_index: int,
) -> bool:
	if state.is_player_first_turn(player_idx):
		return false
	var player := state.get_player(player_idx)
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null or not catalog.is_basic_pokemon(pokemon.card_id):
			continue
		if pokemon.placed_this_turn or not pokemon.can_evolve_this_turn:
			continue
		var basic_name := catalog.card_name(pokemon.card_id)
		for hand_index in range(player.hand.size()):
			if hand_index == exclude_hand_index:
				continue
			var stage2_id := str(player.hand[hand_index])
			if catalog.is_stage2(stage2_id) and _stage2_can_evolve_from_basic(stage2_id, basic_name):
				return true
	return false


func _stage2_can_evolve_from_basic(stage2_id: String, basic_name: String) -> bool:
	var stage1_name := str(catalog.get_card(stage2_id).get("evolves_from", ""))
	if stage1_name.is_empty():
		return false
	for candidate_id_value in catalog.cards:
		var candidate_id := str(candidate_id_value)
		if catalog.card_name(candidate_id) != stage1_name:
			continue
		if str(catalog.get_card(candidate_id).get("evolves_from", "")).to_lower() == basic_name.to_lower():
			return true
	return false


func _conditional_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
	exclude_hand_index: int,
	depth: int,
) -> bool:
	var player := state.get_player(player_idx)
	if str(params.get("condition", "")) == "ko_by_attack_last_turn" and not player.was_ko_by_attack:
		return false
	var cost: Variant = params.get("cost")
	if cost != null and not _cost_is_payable(state, player_idx, cost, exclude_hand_index):
		return false
	var on_pay: Variant = params.get("on_pay", [])
	return _effects_have_legal_target(
		state, player_idx, on_pay, source_slot, exclude_hand_index, depth + 1
	)


func _coin_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
	exclude_hand_index: int,
	depth: int,
) -> bool:
	var branch_found := false
	for key in ["on_heads", "on_tails", "on_success", "on_fail"]:
		var branch: Variant = params.get(key, [])
		if _effect_list(branch).is_empty():
			continue
		branch_found = true
		if _effects_have_legal_target(
			state, player_idx, branch, source_slot, exclude_hand_index, depth + 1
		):
			return true
	return not branch_found


func _cost_is_payable(
	state: GameState,
	player_idx: int,
	cost: Variant,
	exclude_hand_index: int,
) -> bool:
	var player := state.get_player(player_idx)
	for cost_value in _effect_list(cost):
		if not (cost_value is Dictionary):
			continue
		var cost_effect: Dictionary = cost_value
		if str(cost_effect.get("effect_type", "")) != "discard":
			continue
		var raw_params: Variant = cost_effect.get("params", {})
		var params: Dictionary = {}
		if raw_params is Dictionary:
			params = Dictionary(raw_params)
		var from_zone := str(params.get("from", params.get("from_zone", "hand")))
		var amount := int(params.get("amount", 1))
		if from_zone == "hand" and _available_hand_count(player, exclude_hand_index) < amount:
			return false
		if from_zone == "discard" and player.discard.size() < amount:
			return false
	return true


func _player_has_damaged_pokemon(player: PlayerState) -> bool:
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null and pokemon.damage_counters > 0:
			return true
	return false


func _player_has_attached_energy(player: PlayerState) -> bool:
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null and not pokemon.energy_card_ids.is_empty():
			return true
	return false


func _player_has_effect_target_pokemon(player: PlayerState) -> bool:
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null and not pokemon.all_prevented_next_turn:
			return true
	return false


func _stadium_is_activatable(state: GameState) -> bool:
	if state.stadium_card_id.is_empty():
		return false
	for effect_value in catalog.get_card(state.stadium_card_id).get("trainer_effects", []):
		if str(effect_value.get("params", {}).get("stadium_type", "")) == "activatable":
			return true
	return false


func _validate_action_references(state: GameState, action: GameAction) -> String:
	for ref in [action.source, action.target]:
		if ref == null:
			continue
		if ref.player not in [0, 1]:
			return "实体引用玩家无效。"
		if ref.kind == "card":
			var zone := _zone(state.get_player(ref.player), ref.zone)
			if ref.index < 0 or ref.index >= zone.size():
				return "卡牌引用位置已变化。"
			if not ref.card_id.is_empty() and zone[ref.index] != ref.card_id:
				return "卡牌引用内容已变化。"
		elif ref.kind == "pokemon":
			var pokemon := state.get_player(ref.player).get_pokemon(ref.slot)
			if pokemon == null:
				if ref.card_id.is_empty():
					continue
				return "宝可梦引用位置已变化。"
			if not ref.card_id.is_empty() and pokemon.card_id != ref.card_id:
				return "宝可梦引用内容已变化。"
	return ""


func _zone(player: PlayerState, zone_name: String) -> Array[String]:
	match zone_name:
		"hand":
			return player.hand
		"discard":
			return player.discard
		"prizes":
			return player.prizes
		_:
			return player.deck


func _hand_has_basic(player: PlayerState) -> bool:
	for card_id in player.hand:
		if catalog.is_basic_pokemon(card_id):
			return true
	return false


func _add_action(
	actions: Array[GameAction],
	seen: Dictionary,
	action: GameAction,
) -> void:
	var signature := "%s:%s" % [action.action, JSON.stringify(action.params)]
	if seen.has(signature):
		return
	seen[signature] = true
	actions.append(action)


func _merge_steps(first: StepResult, second: StepResult) -> StepResult:
	var message := first.message
	if not second.message.is_empty():
		message = ("%s %s" % [message, second.message]).strip_edges()
	return StepResult.new(
		first.success and second.success,
		message,
		second.pending_choice if second.pending_choice else first.pending_choice,
		first.events + second.events,
		second.winner if second.winner >= 0 else first.winner,
		first.terminal or second.terminal,
		second.error_code if not second.error_code.is_empty() else first.error_code,
	)


func _restore_state(state: GameState, snapshot: Dictionary) -> void:
	var restored := GameState.from_dict(snapshot)
	state.players = restored.players
	state.active_player_idx = restored.active_player_idx
	state.phase = restored.phase
	state.turn_number = restored.turn_number
	state.first_player_idx = restored.first_player_idx
	state.stadium_card_id = restored.stadium_card_id
	state.winner = restored.winner
	state.revision = restored.revision
	state.choice_sequence = restored.choice_sequence
	state.public_deck_keys = restored.public_deck_keys
	state.apply_type_matchups = restored.apply_type_matchups
	state.action_log = restored.action_log
	state.mulligan_count = restored.mulligan_count
	state.extra_draws = restored.extra_draws
	state.setup_ready = restored.setup_ready
	state.pending_promotions = restored.pending_promotions
	state.processed_action_ids = restored.processed_action_ids
	state.resolution_stack = restored.resolution_stack
	state.event_stream = GameEventStream.new()


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)

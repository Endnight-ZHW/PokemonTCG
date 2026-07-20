class_name VMActionExecutor
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var availability: VMAvailability
var effect_engine: EffectEngine
var turn_settlement: VMTurnSettlement


func _init(
	p_catalog: CardCatalog,
	p_validator: RulesValidator,
	p_availability: VMAvailability,
	p_effect_engine: EffectEngine,
	p_turn_settlement: VMTurnSettlement,
) -> void:
	catalog = p_catalog
	validator = p_validator
	availability = p_availability
	effect_engine = p_effect_engine
	turn_settlement = p_turn_settlement


func setup_done(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.phase != "SETUP":
		return _error("当前不在准备阶段。", "invalid_phase", state)
	if actor != state.setup_actor_idx:
		return _error("尚未轮到该玩家完成准备。", "wrong_setup_actor", state)
	if state.setup_stage == GameState.SETUP_BONUS_PLACEMENT:
		return complete_setup(state, rng)
	if state.setup_stage != GameState.SETUP_INITIAL_PLACEMENT:
		return _error("当前准备阶段不能确认完成。", "invalid_setup_stage", state)
	if state.get_player(actor).active == null:
		return _error("必须先放置战斗宝可梦。", "missing_active", state)
	state.setup_ready[actor] = true
	if not state.setup_ready[0] or not state.setup_ready[1]:
		state.setup_actor_idx = 1 - actor
		return StepResult.new(true, "玩家%d已完成准备。" % (actor + 1))
	state.set_prizes()
	var bonus_player := -1
	if state.mulligan_count[1] > state.mulligan_count[0]:
		bonus_player = 0
	elif state.mulligan_count[0] > state.mulligan_count[1]:
		bonus_player = 1
	if bonus_player >= 0 and state.mulligan_bonus_max > 0:
		state.setup_stage = GameState.SETUP_BONUS_DRAW
		state.setup_actor_idx = bonus_player
		return _mulligan_draw_request(state, bonus_player)
	return complete_setup(state, rng)


func complete_setup(
	state: GameState,
	rng: PortableRandomSource,
) -> StepResult:
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_actor_idx = -1
	state.setup_bonus_card_ids = [[], []]
	state.active_player_idx = state.first_player_idx
	state.phase = "DRAW"
	state.log_action("准备完成，双方同时翻开宝可梦。")
	var reveal_event := {
		"event_type": "setup_revealed",
		"visibility": "public",
		"data": {
			"first_player": state.first_player_idx,
			"players": [
				_setup_board_payload(state.get_player(0)),
				_setup_board_payload(state.get_player(1)),
			],
		},
	}
	var step := turn_settlement.begin_turn(state, rng)
	step.events.push_front(reveal_event)
	return step


func _mulligan_draw_request(state: GameState, player_idx: int) -> StepResult:
	var stack := ResolutionStack.new()
	var frame_id := "setup:mulligan_bonus:%d" % state.choice_sequence
	stack.push_continuation("setup_mulligan_draw", {
		"kind": "setup_mulligan_draw",
		"frame_id": frame_id,
		"player_idx": player_idx,
		"max_draw": state.mulligan_bonus_max,
	})
	var options: Array[Dictionary] = []
	for amount in range(state.mulligan_bonus_max + 1):
		options.append({
			"option_id": "draw:%d" % amount,
			"label": "抽%d张" % amount,
			"value": {"count": amount},
		})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "choose_mulligan_draw_count"),
		"choose_mulligan_draw_count",
		player_idx,
		"可以抽取至多%d张再战奖励卡。" % state.mulligan_bonus_max,
		options,
		1,
		1,
		false,
		false,
		{
			"domain": "setup",
			"purpose": "choose_mulligan_draw_count",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"max_draw": state.mulligan_bonus_max,
		},
	)
	state.resolution_stack = stack.to_dict()
	return StepResult.new(
		true, "请选择再战奖励抽牌数。", stack.pending_request, [], state.winner, false)


func _setup_board_payload(player: PlayerState) -> Dictionary:
	var bench_ids: Array[String] = []
	for pokemon in player.bench:
		if pokemon is PokemonState:
			bench_ids.append(pokemon.card_id)
	return {
		"active": player.active.card_id if player.active else "",
		"bench": bench_ids,
	}


func play_basic(
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
	if state.setup_stage == GameState.SETUP_BONUS_PLACEMENT:
		var bonus_cards: Array = state.setup_bonus_card_ids[actor]
		var bonus_index := bonus_cards.find(card_id)
		if bonus_index >= 0:
			bonus_cards.remove_at(bonus_index)
		state.setup_bonus_card_ids[actor] = bonus_cards
	if state.phase == "SETUP":
		state.log_action("%s放置了一只暗置宝可梦。" % player.name)
	else:
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
	if state.phase == "SETUP":
		placement_event["visibility"] = "owner"
	var effects: Array = []
	if state.phase == "MAIN":
		for ability_value in catalog.get_card(card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			if str(ability.get("trigger", "")) == "on_enter_play":
				effects.append_array(_ability_runtime_effects(ability))
	if effects.is_empty():
		return StepResult.new(true, "宝可梦已放置。", null, [placement_event])
	var step := run_effects(state, effects, actor, target, rng, {
		"effect_source_kind": "ability",
	})
	step.events.push_front(placement_event)
	return step


func evolve(
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
	pokemon.clear_special_conditions_and_attack_effects()
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
			effects.append_array(_ability_runtime_effects(ability))
	if effects.is_empty():
		return StepResult.new(true, "进化完成。", null, [evolution_event])
	var step := run_effects(state, effects, actor, slot, rng, {
		"effect_source_kind": "ability",
	})
	step.events.push_front(evolution_event)
	return step


func attach_energy(
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
	var reason := validator.can_attach_energy(state, actor, card_id, target_slot)
	if not reason.is_empty():
		return _error(reason, "illegal_energy_attachment", state)
	var target := player.get_pokemon(target_slot)
	player.hand.remove_at(hand_idx)
	target.energy_card_ids.append(card_id)
	var attachment_index := target.energy_card_ids.size() - 1
	player.energy_attached_this_turn = true
	var events: Array[Dictionary] = [{
		"event_type": "energy_attached",
		"actor": actor,
		"card_id": card_id,
		"source": {"player": actor, "zone": "hand", "index": hand_idx},
		"target": {"player": actor, "slot": target_slot},
		"data": {"player": actor, "slot": target_slot, "card_id": card_id},
	}]
	var trigger_candidates: Array[Dictionary] = []
	effect_engine.trigger_commands().collect_on_attach_triggers(
		card_id,
		actor,
		target_slot,
		"hand",
		trigger_candidates,
		attachment_index,
	)
	if not trigger_candidates.is_empty():
		var stack := ResolutionStack.new()
		var queued := effect_engine.trigger_commands().queue_candidates(
			stack,
			trigger_candidates,
			VMModifierManager.ON_ATTACH,
			state.active_player_idx,
			"apnap",
			"effect",
		)
		if not bool(queued.get("success", false)):
			return _error(
				str(queued.get("message", "触发批无效。")),
				str(queued.get("error_code", "invalid_trigger_batch")),
				state,
			)
		var trigger_step := effect_engine.resolve(state, stack, rng)
		trigger_step.events = events + trigger_step.events
		if not trigger_step.success:
			return trigger_step
		state.log_action("%s附着了%s。" % [player.name, catalog.card_name(card_id)])
		return trigger_step
	state.log_action("%s附着了%s。" % [player.name, catalog.card_name(card_id)])
	return StepResult.new(true, "能量已附着。", null, events)


func play_trainer(
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
	var runtime_effects := _trainer_runtime_effects(card_id)
	var cost_preflight := availability.preflight_costs(
		state, actor, runtime_effects, hand_idx, "trainer")
	if not bool(cost_preflight.get("ok", false)):
		return _error(
			str(cost_preflight.get("message", "VM代价预检失败。")),
			str(cost_preflight.get("error_code", "vm_error")),
			state,
		)
	if not bool(cost_preflight.get("legal", false)):
		return _error("无法支付训练家卡代价。", "cost_not_payable", state)
	player.hand.remove_at(hand_idx)
	if catalog.is_tool(card_id):
		var tool_target := player.get_pokemon(target_slot)
		tool_target.attached_tool_id = card_id
		var tool_events: Array[Dictionary] = [{
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
		}]
		if runtime_effects.is_empty():
			return StepResult.new(true, "宝可梦道具已附着。", null, tool_events)
		var tool_step := run_effects(
			state,
			runtime_effects,
			actor,
			target_slot,
			rng,
			{"effect_source_kind": "trainer"},
		)
		tool_step.events = tool_events + tool_step.events
		return tool_step
	var play_event := {
		"event_type": "trainer_played",
		"actor": actor,
		"card_id": card_id,
		"source": {"player": actor, "zone": "hand", "index": hand_idx},
		"target": {"player": actor, "zone": "discard"},
		"data": {"player": actor, "card_id": card_id},
	}
	var play_events: Array[Dictionary] = []
	if catalog.is_stadium(card_id):
		if not state.stadium_card_id.is_empty():
			var replaced_stadium_id := state.stadium_card_id
			var replaced_owner_idx := state.stadium_owner_idx
			if replaced_owner_idx not in [0, 1]:
				replaced_owner_idx = actor
			var replaced_owner := state.get_player(replaced_owner_idx)
			var discard_index := replaced_owner.discard.size()
			replaced_owner.discard.append(replaced_stadium_id)
			play_events.append(VMZoneHelpers.card_moved_event(
				actor,
				[replaced_stadium_id],
				{"player": replaced_owner_idx, "zone": "stadium", "index": 0},
				{"player": replaced_owner_idx, "zone": "discard", "index": discard_index},
			))
		state.stadium_card_id = card_id
		state.stadium_owner_idx = actor
		player.stadium_played_this_turn = true
		play_event["event_type"] = "stadium_changed"
		play_event["target"] = {"player": actor, "zone": "stadium"}
	else:
		player.discard.append(card_id)
		if catalog.is_supporter(card_id):
			player.supporter_played_this_turn = true
	play_events.append(play_event)
	state.log_action("%s使用了%s。" % [player.name, catalog.card_name(card_id)])
	var effects: Array = _trainer_runtime_effects(card_id)
	if effects.is_empty():
		return StepResult.new(true, "训练家卡已使用。", null, play_events)
	var step := run_effects(state, effects, actor, "active", rng, {
		"effect_source_kind": "stadium" if catalog.is_stadium(card_id) else "trainer",
	})
	step.events = play_events + step.events
	return step


func use_ability(
	state: GameState,
	actor: int,
	slot: String,
	ability_name: String,
	rng: PortableRandomSource,
) -> StepResult:
	var reason := validator.can_use_ability(state, actor, slot, ability_name)
	if not reason.is_empty():
		return _error(reason, "illegal_ability", state)
	var player := state.get_player(actor)
	var pokemon := player.get_pokemon(slot)
	var source_card_id := pokemon.card_id if pokemon else ""
	if slot.begins_with("discard_"):
		var discard_index := slot.trim_prefix("discard_").to_int()
		source_card_id = str(player.discard[discard_index])
	for ability_value in catalog.get_card(source_card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("name", "")).to_lower() != ability_name.to_lower():
			continue
		if pokemon != null and str(ability.get("trigger", "")) != "repeatable":
			pokemon.used_abilities.append(ability_name)
		state.log_action("%s使用特性%s。" % [catalog.card_name(source_card_id), ability_name])
		return run_effects(
			state, _ability_runtime_effects(ability), actor, slot, rng,
			{"effect_source_kind": "ability"})
	return _error("没有找到该特性。", "ability_not_found", state)


func use_stadium(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if not availability.stadium_is_activatable(state):
		return _error("场上竞技场没有可发动效果。", "stadium_not_activatable", state)
	var player := state.get_player(actor)
	if player.stadium_used_this_turn:
		return _error("本回合已使用过竞技场效果。", "stadium_already_used", state)
	player.stadium_used_this_turn = true
	var effects: Array = _trainer_runtime_effects(state.stadium_card_id)
	return run_effects(
		state, effects, actor, "active", rng,
		{"effect_source_kind": "stadium"})


func retreat(
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
	var source_indices := indices.duplicate()
	source_indices.sort()
	var paid_energy_ids: Array[String] = []
	for index in source_indices:
		if index >= 0 and index < player.active.energy_card_ids.size():
			paid_energy_ids.append(player.active.energy_card_ids[index])
	var discard_start := player.discard.size()
	indices.sort()
	indices.reverse()
	for index in indices:
		player.discard.append(player.active.energy_card_ids.pop_at(index))
	player.switch_active_to_bench(bench_idx)
	player.retreated_this_turn = true
	state.log_action("%s完成撤退。" % player.name)
	var events: Array[Dictionary] = []
	if not paid_energy_ids.is_empty():
		var discard_event := VMZoneHelpers.discard_event(
			actor,
			"",
			paid_energy_ids,
			paid_energy_ids.size(),
			source_indices,
			"active",
			discard_start,
		)
		discard_event["source"]["attachment_type"] = "energy"
		events.append(discard_event)
	events.append({
		"event_type": "retreat",
		"data": {"player": actor, "bench_idx": bench_idx},
	})
	return StepResult.new(true, "撤退完成。", null, events)


func request_retreat_payment(
	state: GameState,
	actor: int,
	bench_idx: int,
) -> StepResult:
	var reason := validator.can_start_retreat(state, actor, bench_idx)
	if not reason.is_empty():
		return _error(reason, "illegal_retreat", state)
	var player := state.get_player(actor)
	var cost := validator.effective_retreat_cost(state, player)
	if cost <= 0:
		return retreat(state, actor, bench_idx, [])
	var stack := ResolutionStack.new()
	var frame_id := "retreat:%d:%d:%d" % [state.revision, actor, bench_idx]
	stack.push_continuation("retreat_payment", {
		"kind": "retreat_payment",
		"frame_id": frame_id,
		"actor": actor,
		"bench_idx": bench_idx,
		"required_units": cost,
	})
	var options: Array[Dictionary] = []
	for index in range(player.active.energy_card_ids.size()):
		var card_id := player.active.energy_card_ids[index]
		var ref := EntityRef.new(
			"attachment", actor, "", "active", index, "energy", card_id)
		options.append({
			"option_id": "retreat:energy:%d" % index,
			"label": catalog.card_name(card_id),
			"ref": ref.to_dict(),
		})
	var request := ChoiceRequest.new(
		stack.next_request_id(state, actor, "select_retreat_payment"),
		"select_retreat_payment",
		actor,
		"请选择用于支付撤退费用的能量。",
		options,
		1,
		options.size(),
		false,
		true,
		{
			"domain": "action",
			"purpose": "retreat_payment",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"required_units": cost,
			"cancels_action": true,
		},
	)
	stack.pending_request = request
	state.resolution_stack = stack.to_dict()
	return StepResult.new(true, "请选择撤退费用。", request, [], state.winner, false)


func run_effects(
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


func _ability_runtime_effects(ability: Dictionary) -> Array:
	return VMRuntimeEffects.strict_ability_effects(ability)


func _trainer_runtime_effects(card_id: String) -> Array:
	return VMRuntimeEffects.strict_trainer_effects(catalog.get_card(card_id), "trainer:%s" % card_id)


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)

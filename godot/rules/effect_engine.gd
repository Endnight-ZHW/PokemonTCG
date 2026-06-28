class_name EffectEngine
extends RefCounted

const DAMAGE_PER_COUNTER := 10
const SUPPORTED_EFFECT_TYPES: Array[String] = [
	"ability_discard_revive",
	"any_pokemon_damage",
	"arven",
	"apply_outgoing_damage_reduction",
	"attach_from_discard",
	"attack_fail",
	"attack_damage_formula",
	"attack_lock_basic",
	"aura_damage_reduction",
	"aura_damage_boost",
	"bench_damage",
	"clara",
	"coin_flip",
	"coin_flip_double_ko",
	"coin_flip_energy_discard",
	"coin_flip_triple",
	"coin_flip_until_tails",
	"conditional",
	"conditional_damage_bonus",
	"conditional_damage_heal",
	"conditional_hp_boost",
	"conditional_search_extra",
	"conditional_status",
	"conditional_zero_retreat",
	"damage",
	"damage_and_self_heal",
	"damage_counter_self",
	"damage_per_discard_psychic",
	"damage_per_energy",
	"damage_per_evolved",
	"damage_per_hand_size",
	"damage_per_self_damage",
	"damage_per_self_energy",
	"damage_per_self_energy_type",
	"damage_plus_bench",
	"damage_self_penalty",
	"dazzling_beam",
	"discard",
	"discard_draw",
	"discard_fighting_energy_damage",
	"discard_hand_conditional_bonus",
	"discard_then_draw",
	"draw",
	"draw_and_attach_energy",
	"draw_until",
	"draw_until_more",
	"energy_attach",
	"energy_discard",
	"energy_relocate",
	"evolve_skip_stage",
	"hand_to_bottom_draw",
	"heal",
	"heal_all",
	"houb",
	"judge",
	"look_top_deck",
	"look_top_attach_energy",
	"mill_and_damage_per_energy",
	"piercing_marker",
	"place_counters_and_self_ko",
	"potion_heal",
	"prevent_all",
	"prevent_damage",
	"prevent_effects",
	"reactive_thorns",
	"return_to_hand",
	"search",
	"search_any_and_switch",
	"self_attack_lock",
	"shuffle_draw",
	"shuffle_from_discard",
	"status",
	"switch_opponent",
	"switch_self",
	"tool",
	"tool_exp_share",
	"trekking_shoes",
	"zinnia_resolve",
]

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func supports_effect_type(effect_type: String) -> bool:
	return effect_type in SUPPORTED_EFFECT_TYPES


func resolve(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	var events: Array[Dictionary] = []
	var messages: Array[String] = []
	while not stack.frames.is_empty():
		var frame := stack.pop_frame()
		if frame.get("kind", "") == "continuation":
			return StepResult.new(false, "结算栈包含未响应的选择。", null, events, state.winner, false, "missing_choice")
		var effect: Dictionary = frame.get("effect", {})
		var player_idx := int(frame.get("player_idx", state.active_player_idx))
		var source_slot := str(frame.get("source_slot", "active"))
		var outcome := _execute_effect(state, stack, rng, effect, player_idx, source_slot, events)
		var message := str(outcome.get("message", ""))
		if not message.is_empty():
			messages.append(message)
		if not bool(outcome.get("success", true)):
			state.resolution_stack = stack.to_dict()
			return StepResult.new(
				false,
				" ".join(messages),
				null,
				events,
				state.winner,
				state.winner >= 0,
				str(outcome.get("error_code", "effect_failed")),
			)
		if bool(outcome.get("attack_failed", false)):
			stack.context["attack_failed"] = true
		if stack.pending_request:
			state.resolution_stack = stack.to_dict()
			return StepResult.new(
				true,
				" ".join(messages),
				stack.pending_request,
				events,
				state.winner,
				state.winner >= 0,
			)
	state.resolution_stack = stack.to_dict()
	return StepResult.new(
		true,
		" ".join(messages),
		null,
		events,
		state.winner,
		state.winner >= 0,
	)


func apply_choice(
	state: GameState,
	stack: ResolutionStack,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	var request := stack.pending_request
	if request == null or request.request_id != response.request_id:
		return StepResult.new(false, "选择请求已过期。", null, [], state.winner, false, "stale_choice")
	if response.cancelled and not request.can_cancel:
		return StepResult.new(false, "该选择不可取消。", null, [], state.winner, false, "choice_not_cancellable")
	if stack.frames.is_empty() or stack.frames[-1].get("kind", "") != "continuation":
		return StepResult.new(false, "选择请求缺少续执行帧。", null, [], state.winner, false, "missing_continuation")

	var option_map: Dictionary = {}
	for option in request.options:
		option_map[str(option.get("option_id", ""))] = option
	var selected: Array[Dictionary] = []
	for option_id in response.option_ids:
		if not option_map.has(option_id):
			return StepResult.new(false, "包含无效选择项。", null, [], state.winner, false, "invalid_choice")
		selected.append(option_map[option_id])
	if not request.allow_duplicates:
		var unique: Dictionary = {}
		for option_id in response.option_ids:
			if unique.has(option_id):
				return StepResult.new(false, "该选择不允许重复。", null, [], state.winner, false, "duplicate_choice")
			unique[option_id] = true
	if not response.cancelled and (
		selected.size() < request.min_select or selected.size() > request.max_select
	):
		return StepResult.new(false, "选择数量不符合要求。", null, [], state.winner, false, "choice_count")

	var continuation := stack.pop_frame()
	stack.pending_request = null
	var events: Array[Dictionary] = []
	var outcome := _execute_continuation(
		state,
		stack,
		rng,
		str(continuation.get("operation", "")),
		Dictionary(continuation.get("data", {})),
		selected,
		response.cancelled,
		events,
	)
	if not bool(outcome.get("success", true)):
		state.resolution_stack = stack.to_dict()
		return StepResult.new(
			false,
			str(outcome.get("message", "")),
			null,
			events,
			state.winner,
			false,
			str(outcome.get("error_code", "choice_failed")),
		)
	if stack.pending_request:
		state.resolution_stack = stack.to_dict()
		return StepResult.new(
			true,
			str(outcome.get("message", "")),
			stack.pending_request,
			events,
			state.winner,
			state.winner >= 0,
		)
	var resumed := resolve(state, stack, rng)
	resumed.events = events + resumed.events
	var prefix := str(outcome.get("message", ""))
	if not prefix.is_empty():
		resumed.message = "%s %s" % [prefix, resumed.message]
	return resumed


func _execute_effect(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	effect: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var effect_type := str(effect.get("effect_type", ""))
	var params: Dictionary = effect.get("params", {})
	var player := state.get_player(player_idx)
	var opponent := state.get_player(1 - player_idx)

	match effect_type:
		"damage":
			if str(params.get("target", "opponent_active")) == "self":
				return _deal_damage(
					state, player_idx, source_slot,
					int(params.get("amount", 0)), events, false)
			return _deal_damage(
				state, 1 - player_idx, "active",
				int(params.get("amount", 0)), events)
		"damage_counter_self":
			return _deal_damage(state, player_idx, source_slot, int(params.get("amount", 0)), events, false)
		"attack_damage_formula":
			return _attack_damage_formula(state, stack, player_idx, source_slot, params)
		"damage_per_energy":
			var count := 0
			match str(params.get("count_from", "self")):
				"opponent_active":
					count = opponent.active.energy_card_ids.size() if opponent.active else 0
				"all_opponent":
					for row in opponent.get_all_pokemon():
						var target_pokemon: PokemonState = row["pokemon"]
						if target_pokemon:
							count += target_pokemon.energy_card_ids.size()
				_:
					var count_source := player.get_pokemon(source_slot)
					count = count_source.energy_card_ids.size() if count_source else 0
			return _deal_damage(
				state,
				1 - player_idx,
				"active",
				int(params.get("base", 0)) + count * int(params.get("per_energy", 0)),
				events,
			)
		"damage_per_hand_size":
			return _deal_damage(
				state, 1 - player_idx, "active",
				player.hand.size() * int(params.get("per", 0)), events)
		"damage_per_self_energy", "damage_per_self_energy_type":
			var source := player.get_pokemon(source_slot)
			if source == null:
				return _fail("没有攻击来源。")
			var filter := str(params.get("energy_filter", params.get("energy_type", ""))).to_lower()
			var energy_count := 0
			for energy_id in source.energy_card_ids:
				if filter.is_empty() or filter == "any":
					energy_count += 1
				else:
					for provided in catalog.provides_energy(energy_id):
						if provided.to_lower() == filter:
							energy_count += 1
							break
			return _deal_damage(
				state, 1 - player_idx, "active",
				int(params.get("base", 0)) + energy_count * int(params.get("per_energy", 0)),
				events)
		"damage_per_discard_psychic":
			var psychic_count := 0
			for card_id in player.discard:
				if catalog.is_pokemon(card_id) and "Psychic" in catalog.get_card(card_id).get("energy_types", []):
					psychic_count += 1
			return _deal_damage(
				state, 1 - player_idx, "active",
				int(params.get("base", 0)) + psychic_count * int(params.get("per_card", 0)),
				events)
		"damage_plus_bench":
			return _deal_damage(
				state, 1 - player_idx, "active",
				int(params.get("base", 0)) + player.bench_count() * int(params.get("per_bench", 0)),
				events)
		"damage_per_self_damage":
			var self_pokemon := player.get_pokemon(source_slot)
			var self_counters := self_pokemon.damage_counters if self_pokemon else 0
			return _deal_damage(
				state, 1 - player_idx, "active",
				int(params.get("base", 0)) + self_counters * int(params.get("per_counter", 0)),
				events)
		"damage_self_penalty":
			var penalty_source := player.get_pokemon(source_slot)
			var penalty_count := penalty_source.damage_counters if penalty_source else 0
			return _deal_damage(
				state, 1 - player_idx, "active",
				max(0, int(params.get("base", 0)) - penalty_count * int(params.get("per_counter", 0))),
				events)
		"damage_per_evolved":
			var evolved := 0
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon and not catalog.is_basic_pokemon(pokemon.card_id):
					evolved += 1
			return _deal_damage(
				state, 1 - player_idx, "active",
				evolved * int(params.get("per_evolved", 0)), events)
		"conditional_damage_bonus":
			return _conditional_damage_bonus(state, player_idx, params, events)
		"conditional_damage_heal":
			var total := int(params.get("base", 0))
			if player.healed_this_turn:
				total += int(params.get("bonus", 0))
			return _deal_damage(state, 1 - player_idx, "active", total, events)
		"damage_and_self_heal":
			var damage_outcome := _deal_damage(
				state, 1 - player_idx, "active", int(params.get("damage", 0)), events)
			_heal_pokemon(state, player_idx, source_slot, int(params.get("heal", 0)), events)
			return damage_outcome
		"discard_hand_conditional_bonus":
			var total_damage := int(params.get("base_damage", 0))
			if player.hand.size() >= int(params.get("threshold", 5)):
				total_damage += int(params.get("bonus", 0))
				var discarded_cards := player.hand.duplicate()
				var count := player.discard_entire_hand()
				events.append(_discard_event(
					player_idx, "hand", discarded_cards, count))
			return _deal_damage(state, 1 - player_idx, "active", total_damage, events)
		"discard_fighting_energy_damage":
			var fighting_source := player.get_pokemon(source_slot)
			if fighting_source == null:
				return _fail("没有攻击来源。")
			var kept: Array[String] = []
			var discarded := 0
			for energy_id in fighting_source.energy_card_ids:
				if "Fighting" in catalog.provides_energy(energy_id):
					player.discard.append(energy_id)
					discarded += 1
				else:
					kept.append(energy_id)
			fighting_source.energy_card_ids = kept
			return _deal_damage(
				state, 1 - player_idx, "active",
				int(params.get("base", 0)) + discarded * int(params.get("per_energy", 0)),
				events)
		"mill_and_damage_per_energy":
			var exposed: Array[String] = []
			for _index in range(min(int(params.get("mill_count", 0)), player.deck.size())):
				exposed.append(player.deck.pop_back())
			var energies := 0
			for card_id in exposed:
				if catalog.is_energy(card_id):
					player.discard.append(card_id)
					energies += 1
				else:
					player.deck.append(card_id)
			rng.shuffle(player.deck)
			events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
			return _deal_damage(
				state, 1 - player_idx, "active",
				energies * int(params.get("damage_per", 0)), events)
		"any_pokemon_damage":
			return _request_board_target(
				state, stack, player_idx, 1 - player_idx, "damage_target",
				{"amount": int(params.get("amount", 0)), "target_player": 1 - player_idx},
				"选择1只对手宝可梦作为伤害目标。")
		"bench_damage":
			if not bool(params.get("choose_targets", true)):
				var target_idx := 1 - player_idx
				var applied := 0
				for index in range(state.get_player(target_idx).bench.size()):
					if applied >= int(params.get("count", 1)):
						break
					var bench_pokemon: PokemonState = state.get_player(target_idx).bench[index]
					if bench_pokemon:
						_deal_damage(
							state,
							target_idx,
							"bench_%d" % index,
							int(params.get("amount", 0)),
							events,
						)
						applied += 1
				return _ok("备战伤害已结算。")
			return _request_bench_target(
				state, stack, player_idx, 1 - player_idx, "bench_damage_target",
				{"amount": int(params.get("amount", 0)), "target_player": 1 - player_idx},
				"选择1只对手备战宝可梦作为伤害目标。",
				int(params.get("count", 1)))
		"place_counters_and_self_ko":
			return _request_board_target(
				state, stack, player_idx, 1 - player_idx, "place_counters_self_ko",
				{
					"counters": int(params.get("counters", 0)),
					"source_player": player_idx,
					"source_slot": source_slot,
					"target_player": 1 - player_idx,
				},
				"选择1只对手宝可梦放置伤害指示物。")
		"coin_flip", "coin_flip_triple", "coin_flip_double_ko", "coin_flip_until_tails", "coin_flip_energy_discard":
			return _coin_request(state, stack, rng, effect_type, params, player_idx, source_slot)
		"status", "conditional_status":
			if effect_type == "conditional_status" and params.get("condition", "") == "ko_by_attack_last_turn":
				if not player.was_ko_by_attack:
					return _ok("条件未满足。")
				player.was_ko_by_attack = false
			return _apply_status(
				state,
				1 - player_idx if params.get("target", "opponent_active") == "opponent_active" else player_idx,
				"active" if params.get("target", "opponent_active") == "opponent_active" else source_slot,
				str(params.get("status", "")),
				events)
		"dazzling_beam":
			if opponent.active:
				if opponent.active.all_prevented_next_turn:
					opponent.active.all_prevented_next_turn = false
					return _ok("炫目效果被免疫。")
				opponent.active.dazzled = true
			return _ok("目标被施加炫目效果。")
		"attack_lock_basic":
			if opponent.active:
				if opponent.active.all_prevented_next_turn:
					opponent.active.all_prevented_next_turn = false
					return _ok("攻击封锁被免疫。")
				if catalog.is_basic_pokemon(opponent.active.card_id):
					opponent.active.attack_locked = true
			return _ok()
		"apply_outgoing_damage_reduction":
			var reduction_target := (
				opponent.active
				if str(params.get("target", "opponent_active")) == "opponent_active"
				else player.get_pokemon(source_slot)
			)
			if reduction_target:
				if reduction_target.all_prevented_next_turn:
					reduction_target.all_prevented_next_turn = false
					return _ok("恫吓效果被免疫。")
				reduction_target.outgoing_damage_reduction_next_turn = maxi(
					reduction_target.outgoing_damage_reduction_next_turn,
					int(params.get("amount", 0)),
				)
			return _ok()
		"self_attack_lock":
			var lock_target := player.get_pokemon(source_slot)
			if lock_target:
				lock_target.attack_locked_names[str(params.get("attack_name", ""))] = state.turn_number
			return _ok()
		"prevent_damage":
			var damage_target := player.get_pokemon(source_slot)
			if damage_target:
				damage_target.damage_prevented_next_turn = true
			return _ok()
		"prevent_effects":
			var effect_target := player.get_pokemon(source_slot)
			if effect_target:
				effect_target.all_prevented_next_turn = true
			return _ok()
		"prevent_all":
			var all_target := player.get_pokemon(source_slot)
			if all_target:
				all_target.damage_prevented_next_turn = true
				all_target.all_prevented_next_turn = true
			return _ok()
		"attack_fail":
			return {"success": true, "message": "招式失败。", "attack_failed": true}
		"draw":
			var draw_player_idx := (
				1 - player_idx
				if str(params.get("player", "self")) == "opponent"
				else player_idx
			)
			return _draw(state, draw_player_idx, int(params.get("amount", 1)), events)
		"draw_until":
			return _draw_available(
				state, player_idx,
				max(0, int(params.get("target_hand_size", 5)) - player.hand.size()), events)
		"draw_until_more":
			return _draw_available(
				state, player_idx,
				max(0, opponent.hand.size() + 1 - player.hand.size()), events)
		"discard_draw":
			if bool(params.get("discard_hand", false)):
				var discarded_cards := player.hand.duplicate()
				var discarded_count := player.discard_entire_hand()
				events.append(_discard_event(
					player_idx, "hand", discarded_cards, discarded_count))
			return _draw_available(state, player_idx, int(params.get("draw", 7)), events)
		"shuffle_draw":
			player.deck.append_array(player.hand)
			player.hand.clear()
			rng.shuffle(player.deck)
			events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
			return _draw_available(state, player_idx, int(params.get("draw", 5)), events)
		"judge":
			for index in [0, 1]:
				var target_player := state.get_player(index)
				target_player.deck.append_array(target_player.hand)
				target_player.hand.clear()
				rng.shuffle(target_player.deck)
				events.append({"event_type": "deck_shuffled", "data": {"player": index}})
				_draw_available(state, index, int(params.get("draw", 4)), events)
			return _ok()
		"discard_then_draw":
			return _request_cards(
				state, stack, player_idx, "hand", player.hand, "discard_then_draw",
				{
					"player_idx": player_idx,
					"draw_amount": int(params.get("draw_amount", 3)),
				},
				int(params.get("discard_amount", 1)),
				int(params.get("discard_amount", 1)),
				"选择要丢弃的手牌。")
		"discard":
			var discard_zone := str(params.get("from", "hand"))
			var discard_source: Array[String] = _zone(player, discard_zone)
			var requested_discard_amount := int(params.get("amount", 1))
			if discard_source.size() < requested_discard_amount:
				return _fail("手牌不足，无法支付丢弃代价。", "cost_not_payable")
			var discard_amount: int = requested_discard_amount
			if discard_amount <= 0:
				return _fail("没有可丢弃的卡。")
			return _request_cards(
				state, stack, player_idx, discard_zone, discard_source, "discard_cards",
				{"player_idx": player_idx, "zone": discard_zone},
				discard_amount, discard_amount, "选择要丢弃的卡。")
		"hand_to_bottom_draw":
			return _request_cards(
				state, stack, player_idx, "hand", player.hand, "hand_bottom_draw",
				{"player_idx": player_idx},
				0, player.hand.size(), "选择任意张手牌放回牌库底。", true)
		"houb":
			if player.hand.is_empty():
				return _fail("没有其他手牌可以放回牌库底。")
			return _request_cards(
				state, stack, player_idx, "hand", player.hand, "houb",
				{"player_idx": player_idx, "target": int(params.get("target_hand_size", 5))},
				1, 1, "选择1张手牌放回牌库底。")
		"zinnia_resolve":
			if player.hand.size() < 2:
				return _fail("手牌不足2张。")
			return _request_cards(
				state, stack, player_idx, "hand", player.hand, "zinnia",
				{"player_idx": player_idx, "draw_amount": opponent.bench_count() + (1 if opponent.active else 0)},
				2, 2, "选择2张手牌丢弃。")
		"search":
			return _search_request(state, stack, player_idx, params)
		"shuffle_from_discard":
			var available := catalog.filter_cards(
				player.discard,
				str(params.get("filter", "any")),
			)
			return _request_cards(
				state, stack, player_idx, "discard", available, "shuffle_from_discard",
				{"player_idx": player_idx},
				0, min(int(params.get("count", 1)), available.size()),
				"选择要洗回牌库的卡。", true)
		"clara":
			var clara_available: Array[String] = []
			for card_id in player.discard:
				if catalog.is_pokemon(card_id) or catalog.is_basic_energy(card_id):
					clara_available.append(card_id)
			return _request_cards(
				state, stack, player_idx, "discard", clara_available, "clara",
				{
					"player_idx": player_idx,
					"pokemon_count": int(params.get("pokemon_count", 2)),
					"energy_count": int(params.get("energy_count", 2)),
				},
				0, min(clara_available.size(), int(params.get("pokemon_count", 2)) + int(params.get("energy_count", 2))),
				"选择弃牌区中的宝可梦和基本能量。", true)
		"arven":
			var arven_available: Array[String] = []
			for card_id in player.deck:
				if catalog.is_item(card_id) or catalog.is_tool(card_id):
					arven_available.append(card_id)
			return _request_cards(
				state, stack, player_idx, "deck", arven_available, "arven",
				{"player_idx": player_idx},
				1, min(2, arven_available.size()),
				"选择1张物品和1张宝可梦道具。")
		"look_top_deck":
			return _look_top_request(state, stack, player_idx, params)
		"look_top_attach_energy":
			return _look_top_attach_request(state, stack, rng, player_idx, params)
		"trekking_shoes":
			if player.deck.is_empty():
				return _ok("牌库为空。")
			return _confirm_request(
				state, stack, player_idx, "trekking_shoes",
				{"player_idx": player_idx, "card_id": player.deck[-1]},
				"是否将牌库顶卡加入手牌？")
		"energy_discard":
			var from_opponent := str(params.get("from", "self")) != "self"
			var discard_owner := opponent if from_opponent else player
			var discard_source := (
				discard_owner.active
				if from_opponent
				else player.get_pokemon(source_slot)
			)
			if discard_source == null:
				return _fail("没有能量来源。")
			if from_opponent and discard_source.all_prevented_next_turn:
				discard_source.all_prevented_next_turn = false
				return _ok("能量丢弃效果被免疫。")
			var filter_type := str(params.get("filter", "any")).to_lower()
			var kept_energy: Array[String] = []
			var discarded_energy := 0
			for energy_id in discard_source.energy_card_ids:
				var matches := _energy_matches(energy_id, filter_type)
				if matches and discarded_energy < int(params.get("amount", 1)):
					discard_owner.discard.append(energy_id)
					discarded_energy += 1
				else:
					kept_energy.append(energy_id)
			discard_source.energy_card_ids = kept_energy
			return _ok("丢弃了%d张能量。" % discarded_energy)
		"energy_attach":
			return _energy_attach(state, stack, player_idx, source_slot, params)
		"attach_from_discard":
			return _attach_from_discard(state, stack, player_idx, source_slot, params)
		"energy_relocate":
			return _energy_relocate_request(state, stack, player_idx, params)
		"draw_and_attach_energy":
			_draw_available(state, player_idx, 2, events)
			return _attach_from_hand_to_bench(
				state, stack, player_idx,
				int(params.get("energy_count", 2)),
				str(params.get("energy_type", "Grass")),
				int(params.get("min_select", int(params.get("energy_count", 2)))))
		"switch_self":
			return _switch_request(
				state, stack, player_idx, player_idx, bool(params.get("optional", false)), false)
		"switch_opponent":
			return _switch_request(
				state, stack, player_idx, 1 - player_idx, false, bool(params.get("you_choose", false)))
		"heal":
			_heal_pokemon(state, player_idx, source_slot, int(params.get("amount", 0)), events)
			return _ok()
		"potion_heal":
			return _request_injured_target(
				state, stack, player_idx, int(params.get("amount", 30)))
		"heal_all":
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon:
					_heal_pokemon(state, player_idx, str(row["slot"]), int(params.get("amount", 20)), events)
			return _ok()
		"return_to_hand":
			_deal_damage(state, 1 - player_idx, "active", 30, events)
			var return_source := player.get_pokemon(source_slot)
			if return_source:
				player.hand.append(return_source.card_id)
				player.hand.append_array(return_source.evolution_stack_ids)
				player.hand.append_array(return_source.energy_card_ids)
				if not return_source.attached_tool_id.is_empty():
					player.hand.append(return_source.attached_tool_id)
				if source_slot == "active":
					player.active = null
				else:
					player.bench[source_slot.trim_prefix("bench_").to_int()] = null
			return _ok()
		"evolve_skip_stage":
			return _rare_candy(state, player_idx, events)
		"conditional":
			return _conditional_effect(state, stack, player_idx, source_slot, params)
		"conditional_search_extra":
			var count := int(params.get("default_count", 1))
			if (
				player_idx != state.first_player_idx
				and player_idx == state.active_player_idx
				and state.is_player_first_turn(player_idx)
			):
				count = int(params.get("max_count", count))
			return _search_request(state, stack, player_idx, {
				"from_zone": "deck",
				"filter": params.get("filter", "pokemon"),
				"destination": "hand",
				"count": count,
				"min_select": 0 if count == int(params.get("max_count", count)) else 1,
			})
		"search_any_and_switch":
			stack.push_effect({"effect_type": "switch_self", "params": {"optional": true}}, player_idx, source_slot)
			stack.push_effect({"effect_type": "search", "params": {
				"from_zone": "deck", "filter": "any", "destination": "hand",
				"count": int(params.get("count", 2)),
				"min_select": int(params.get("min_select", 0)),
			}}, player_idx, source_slot)
			return _ok()
		"ability_discard_revive":
			var revive_id := str(params.get("card_id", ""))
			var discard_index := player.discard.find(revive_id)
			var bench_slot := player.find_empty_bench_slot()
			if discard_index < 0 or not player.hand.is_empty() or bench_slot < 0:
				return _fail("紧急上浮条件不满足。")
			player.discard.remove_at(discard_index)
			player.place_bench(revive_id, bench_slot)
			_draw(state, player_idx, 3, events)
			return _ok()
		"piercing_marker":
			stack.context["piercing"] = true
			return _ok()
		"tool", "tool_exp_share", "aura_damage_reduction", "aura_damage_boost", "conditional_hp_boost", "conditional_zero_retreat", "reactive_thorns":
			return _ok()
		_:
			return _fail("未知效果类型: %s" % effect_type, "unknown_effect")


func _execute_continuation(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	operation: String,
	data: Dictionary,
	selected: Array[Dictionary],
	cancelled: bool,
	events: Array[Dictionary],
) -> Dictionary:
	if cancelled:
		return _ok("操作已取消。")
	match operation:
		"search_move":
			return _move_selected_cards(state, rng, data, selected, events)
		"discard_then_draw":
			var discard_player_idx := int(data["player_idx"])
			var discarded := _remove_selected_from_zone(
				state.get_player(discard_player_idx), "hand", selected, true)
			events.append(_discard_event(
				discard_player_idx, "hand", discarded, discarded.size()))
			return _draw_available(
				state, discard_player_idx, int(data["draw_amount"]), events)
		"discard_cards":
			var discard_player_idx := int(data["player_idx"])
			var discard_zone := str(data["zone"])
			var discarded := _remove_selected_from_zone(
				state.get_player(discard_player_idx),
				discard_zone,
				selected,
				true,
			)
			events.append(_discard_event(
				discard_player_idx, discard_zone, discarded, discarded.size()))
			return _ok()
		"hand_bottom_draw":
			var player := state.get_player(int(data["player_idx"]))
			var moved := _remove_selected_from_zone(player, "hand", selected, false)
			for card_id in moved:
				player.deck.push_front(card_id)
			return _draw_available(state, int(data["player_idx"]), moved.size(), events)
		"houb":
			var houb_player := state.get_player(int(data["player_idx"]))
			var bottom := _remove_selected_from_zone(houb_player, "hand", selected, false)
			for card_id in bottom:
				houb_player.deck.push_front(card_id)
			return _draw_available(
				state, int(data["player_idx"]),
				max(0, int(data["target"]) - houb_player.hand.size()), events)
		"zinnia":
			var zinnia_player := state.get_player(int(data["player_idx"]))
			var discarded := _remove_selected_from_zone(
				zinnia_player, "hand", selected, true)
			events.append(_discard_event(
				int(data["player_idx"]), "hand", discarded, discarded.size()))
			return _draw_available(
				state, int(data["player_idx"]), int(data["draw_amount"]), events)
		"shuffle_from_discard":
			var shuffle_player := state.get_player(int(data["player_idx"]))
			var shuffled := _remove_selected_from_zone(shuffle_player, "discard", selected, false)
			shuffle_player.deck.append_array(shuffled)
			rng.shuffle(shuffle_player.deck)
			events.append({"event_type": "deck_shuffled", "data": {
				"player": int(data["player_idx"]),
			}})
			return _ok()
		"clara":
			var clara_player := state.get_player(int(data["player_idx"]))
			var pokemon_left := int(data["pokemon_count"])
			var energy_left := int(data["energy_count"])
			var accepted: Array[Dictionary] = []
			for option in selected:
				var card_id := str(option.get("value", {}).get("card_id", ""))
				if catalog.is_pokemon(card_id) and pokemon_left > 0:
					accepted.append(option)
					pokemon_left -= 1
				elif catalog.is_basic_energy(card_id) and energy_left > 0:
					accepted.append(option)
					energy_left -= 1
			var recovered := _remove_selected_from_zone(clara_player, "discard", accepted, false)
			clara_player.hand.append_array(recovered)
			return _ok()
		"arven":
			var arven_player := state.get_player(int(data["player_idx"]))
			var item_taken := false
			var tool_taken := false
			var accepted_arven: Array[Dictionary] = []
			for option in selected:
				var card_id := str(option.get("value", {}).get("card_id", ""))
				if catalog.is_item(card_id) and not item_taken:
					accepted_arven.append(option)
					item_taken = true
				elif catalog.is_tool(card_id) and not tool_taken:
					accepted_arven.append(option)
					tool_taken = true
			var arven_cards := _remove_selected_from_zone(arven_player, "deck", accepted_arven, false)
			arven_player.hand.append_array(arven_cards)
			rng.shuffle(arven_player.deck)
			events.append({"event_type": "deck_shuffled", "data": {
				"player": int(data["player_idx"]),
			}})
			return _ok()
		"switch":
			var target_player := state.get_player(int(data["target_player"]))
			if selected.is_empty():
				return _ok()
			var slot := str(selected[0].get("value", {}).get("slot", ""))
			target_player.switch_active_to_bench(slot.trim_prefix("bench_").to_int())
			events.append({"event_type": "switched", "data": {"player": int(data["target_player"]), "slot": slot}})
			return _ok()
		"confirm_switch":
			if selected.is_empty() or selected[0].get("value", false) == false:
				return _ok()
			return _switch_request(
				state, stack, int(data["chooser"]), int(data["target_player"]), false, false)
		"coin":
			return _resolve_coin(state, stack, data, events)
		"damage_target":
			return _selected_target_damage(state, selected, int(data["target_player"]), int(data["amount"]), events)
		"bench_damage_target":
			return _selected_bench_damage(state, selected, int(data["target_player"]), int(data["amount"]), events)
		"place_counters_self_ko":
			if selected.is_empty():
				return _fail("没有选择目标。")
			var target_slot := str(selected[0].get("value", {}).get("slot", ""))
			var target := state.get_player(int(data["target_player"])).get_pokemon(target_slot)
			if target:
				target.damage_counters += int(data["counters"])
				events.append({"event_type": "damage_counters_placed", "data": {
					"player": int(data["target_player"]), "slot": target_slot,
					"count": int(data["counters"]),
				}})
			var source_player := int(data["source_player"])
			var source_slot := str(data["source_slot"])
			var self_target := state.get_player(source_player).get_pokemon(source_slot)
			if self_target:
				self_target.damage_counters += max(
					1, ceili(float(self_target.current_hp(catalog)) / 10.0))
			return _ok()
		"heal_target":
			if selected.is_empty():
				return _fail("没有选择回复目标。")
			return _heal_pokemon(
				state, int(data["player_idx"]),
				str(selected[0].get("value", {}).get("slot", "")),
				int(data["amount"]), events)
		"energy_attach_target":
			if selected.is_empty():
				return _ok("未选择附能目标。")
			return _attach_cards(
				state,
				int(data["player_idx"]),
				str(data["source_zone"]),
				Array(data["card_ids"]),
				str(selected[0].get("value", {}).get("slot", "")),
				events,
				rng)
		"energy_attach_distribution":
			var attach_player := state.get_player(int(data["player_idx"]))
			var attach_zone := str(data["source_zone"])
			var attach_source: Array[String] = _zone(attach_player, attach_zone)
			var attach_cards: Array = data["card_ids"]
			var max_per_target := int(data.get("max_per_target", 99))
			var forced_attach_slot := ""
			if bool(data.get("same_target", false)) and not selected.is_empty():
				forced_attach_slot = str(selected[0].get("value", {}).get("slot", ""))
			var per_target: Dictionary = {}
			for index in range(min(attach_cards.size(), selected.size())):
				var energy_id := str(attach_cards[index])
				var source_index := attach_source.find(energy_id)
				var target_slot := str(
					selected[index].get("value", {}).get("slot", ""))
				if not forced_attach_slot.is_empty():
					target_slot = forced_attach_slot
				if int(per_target.get(target_slot, 0)) >= max_per_target:
					continue
				var attach_target := attach_player.get_pokemon(target_slot)
				if source_index >= 0 and attach_target:
					attach_source.remove_at(source_index)
					attach_target.energy_card_ids.append(energy_id)
					per_target[target_slot] = int(per_target.get(target_slot, 0)) + 1
					events.append({
						"event_type": "energy_attached",
						"actor": int(data["player_idx"]),
						"card_id": energy_id,
						"source": {
							"player": int(data["player_idx"]),
							"zone": attach_zone,
							"index": source_index,
						},
						"target": {
							"player": int(data["player_idx"]),
							"slot": target_slot,
						},
						"data": {
							"player": int(data["player_idx"]),
							"slot": target_slot,
							"card_id": energy_id,
							"source_zone": attach_zone,
							"source_index": source_index,
						},
					})
			if attach_zone == "deck":
				rng.shuffle(attach_player.deck)
				events.append({"event_type": "deck_shuffled", "data": {
					"player": int(data["player_idx"]),
				}})
			return _ok()
		"energy_relocate_source":
			if selected.is_empty():
				return _fail("没有选择能量来源。")
			return _request_relocation_targets(
				state,
				stack,
				int(data["player_idx"]),
				str(selected[0].get("value", {}).get("slot", "")),
				int(data["amount"]),
				str(data.get("energy_type", "any")),
				int(data.get("min_select", -1)),
				bool(data.get("same_target", false)),
			)
		"energy_relocate_target":
			if selected.is_empty():
				return _ok("未选择能量目标。")
			var relocate_player := state.get_player(int(data["player_idx"]))
			var source := relocate_player.get_pokemon(str(data["source_slot"]))
			var target_relocate := relocate_player.get_pokemon(str(selected[0].get("value", {}).get("slot", "")))
			if source == null or target_relocate == null:
				return _fail("能量转移目标无效。")
			var moved_ids: Array = data.get("card_ids", [])
			var amount: int = min(int(data["amount"]), moved_ids.size())
			for index in range(amount):
				var energy_id := str(moved_ids[index])
				var source_index := source.energy_card_ids.find(energy_id)
				if source_index >= 0:
					source.energy_card_ids.remove_at(source_index)
					target_relocate.energy_card_ids.append(energy_id)
			return _ok()
		"energy_relocate_distribution":
			var distribution_player := state.get_player(int(data["player_idx"]))
			var distribution_source := distribution_player.get_pokemon(
				str(data["source_slot"]))
			if distribution_source == null:
				return _fail("能量来源已失效。")
			var distribution_ids: Array = data.get("card_ids", [])
			var move_count: int = min(
				int(data["amount"]),
				min(distribution_ids.size(), selected.size()),
			)
			var forced_relocate_slot := ""
			if bool(data.get("same_target", false)) and not selected.is_empty():
				forced_relocate_slot = str(selected[0].get("value", {}).get("slot", ""))
			for index in range(move_count):
				var target_slot := str(
					selected[index].get("value", {}).get("slot", ""))
				if not forced_relocate_slot.is_empty():
					target_slot = forced_relocate_slot
				var distribution_target := distribution_player.get_pokemon(target_slot)
				if distribution_target:
					var energy_id := str(distribution_ids[index])
					var source_index := distribution_source.energy_card_ids.find(energy_id)
					if source_index >= 0:
						distribution_source.energy_card_ids.remove_at(source_index)
						distribution_target.energy_card_ids.append(energy_id)
			return _ok()
		"look_top":
			return _resolve_look_top(state, stack, rng, data, selected, events)
		"look_top_attach_energy":
			return _resolve_look_top_attach_energy(state, stack, rng, data, selected, events)
		"look_top_attach_target":
			return _resolve_look_top_attach_target(state, data, selected, events)
		"detached_energy_distribution":
			return _resolve_detached_energy_distribution(state, data, selected, events)
		"discard_attachment":
			return _resolve_discard_attachment(state, data, selected, events)
		"trekking_shoes":
			var trekking_player := state.get_player(int(data["player_idx"]))
			var keep := not selected.is_empty() and bool(selected[0].get("value", false))
			if trekking_player.deck.is_empty():
				return _ok()
			var top: String = trekking_player.deck.pop_back()
			if keep:
				trekking_player.hand.append(top)
			else:
				trekking_player.discard.append(top)
				_draw_available(state, int(data["player_idx"]), 1, events)
			return _ok()
		_:
			return _fail("未知续执行操作: %s" % operation, "unknown_continuation")


func _resolve_detached_energy_distribution(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var card_ids: Array = data.get("card_ids", [])
	var max_per_target := int(data.get("max_per_target", 99))
	var per_target: Dictionary = {}
	for index in range(min(card_ids.size(), selected.size())):
		var target_slot := str(selected[index].get("value", {}).get("slot", ""))
		if int(per_target.get(target_slot, 0)) >= max_per_target:
			continue
		var target := player.get_pokemon(target_slot)
		if target == null:
			continue
		var card_id := str(card_ids[index])
		target.energy_card_ids.append(card_id)
		per_target[target_slot] = int(per_target.get(target_slot, 0)) + 1
		events.append({
			"event_type": "energy_attached",
			"actor": player_idx,
			"card_id": card_id,
			"source": {"player": player_idx, "zone": "deck", "index": -1},
			"target": {"player": player_idx, "slot": target_slot},
			"data": {
				"player": player_idx,
				"slot": target_slot,
				"card_id": card_id,
				"source_zone": "deck",
				"source_index": -1,
			},
		})
	return _ok()


func _resolve_discard_attachment(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return _fail("没有选择要丢弃的能量。")
	var value: Dictionary = selected[0].get("value", {})
	var target_player := int(value.get("player", -1))
	var target_slot := str(value.get("slot", ""))
	var energy_index := int(value.get("index", -1))
	var card_id := str(value.get("card_id", ""))
	if target_player < 0:
		return _fail("能量引用无效。")
	var target := state.get_player(target_player).get_pokemon(target_slot)
	if (
		target == null
		or energy_index < 0
		or energy_index >= target.energy_card_ids.size()
		or str(target.energy_card_ids[energy_index]) != card_id
	):
		return _fail("选择的能量已不存在。")
	state.get_player(target_player).discard.append(target.energy_card_ids.pop_at(energy_index))
	events.append({
		"event_type": "card_discarded",
		"actor": int(data.get("player_idx", state.active_player_idx)),
		"card_id": card_id,
		"source": {
			"player": target_player,
			"slot": target_slot,
			"attachment_type": "energy",
			"index": energy_index,
		},
		"target": {"player": target_player, "zone": "discard"},
		"data": {"player": target_player, "slot": target_slot, "card_id": card_id},
	})
	return _ok()


func _search_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var zone := str(params.get("from_zone", "deck"))
	var source: Array[String] = player.deck if zone == "deck" else player.discard
	var available := catalog.filter_cards(
		source,
		str(params.get("filter", "any")),
		str(params.get("filter_name", "")),
	)
	if available.is_empty():
		return _ok("没有符合条件的卡。")
	var requested_count := int(params.get("count", 1))
	var min_select: int = min(
		int(params.get("min_select", min(1, requested_count))),
		min(requested_count, available.size())
	)
	return _request_cards(
		state, stack, player_idx, zone, available, "search_move",
		{
			"player_idx": player_idx,
			"source_zone": zone,
			"destination": str(params.get("destination", "hand")),
			"shuffle": zone == "deck",
		},
		min_select,
		min(requested_count, available.size()),
		"选择符合条件的卡。",
		min_select <= 0)


func _request_cards(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	zone: String,
	available: Array[String],
	operation: String,
	data: Dictionary,
	min_select: int,
	max_select: int,
	prompt: String,
	can_cancel: bool = false,
) -> Dictionary:
	var source: Array[String] = _zone(state.get_player(player_idx), zone)
	var occurrence: Dictionary = {}
	var options: Array[Dictionary] = []
	for card_id in available:
		var start := int(occurrence.get(card_id, 0))
		var index := source.find(card_id, start)
		if index < 0:
			continue
		occurrence[card_id] = index + 1
		options.append({
			"option_id": "card:%s:%d:%s" % [zone, index, card_id],
			"label": catalog.card_name(card_id),
			"ref": EntityRef.new("card", player_idx, zone, "", index, "", card_id).to_dict(),
			"value": {"index": index, "card_id": card_id},
		})
	if options.is_empty():
		return _ok("没有可选卡牌。")
	stack.push_continuation(operation, data)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, operation),
		operation,
		player_idx,
		prompt,
		options,
		min_select,
		max_select,
		false,
		can_cancel,
		{"revision": state.revision, "zone": zone},
	)
	return _ok()


func _request_board_target(
	state: GameState,
	stack: ResolutionStack,
	chooser: int,
	target_player: int,
	operation: String,
	data: Dictionary,
	prompt: String,
) -> Dictionary:
	var options: Array[Dictionary] = []
	for row in state.get_player(target_player).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot := str(row["slot"])
		options.append({
			"option_id": "pokemon:%d:%s:%s" % [target_player, slot, pokemon.card_id],
			"label": catalog.card_name(pokemon.card_id),
			"ref": EntityRef.new("pokemon", target_player, "", slot, -1, "", pokemon.card_id).to_dict(),
			"value": {"slot": slot, "card_id": pokemon.card_id},
		})
	if options.is_empty():
		return _ok("没有可选目标。")
	if options.size() == 1:
		stack.push_continuation(operation, data)
		var synthetic := ChoiceRequest.new(
			stack.next_request_id(state, chooser, operation), operation, chooser, prompt,
			options, 1, 1)
		stack.pending_request = synthetic
		return _ok()
	stack.push_continuation(operation, data)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, chooser, operation), operation, chooser, prompt,
		options, 1, 1, false, false, {"revision": state.revision})
	return _ok()


func _request_bench_target(
	state: GameState,
	stack: ResolutionStack,
	chooser: int,
	target_player: int,
	operation: String,
	data: Dictionary,
	prompt: String,
	count: int = 1,
) -> Dictionary:
	var options: Array[Dictionary] = []
	var target_state := state.get_player(target_player)
	for index in range(target_state.bench.size()):
		var pokemon: PokemonState = target_state.bench[index]
		if pokemon == null:
			continue
		var slot := "bench_%d" % index
		options.append({
			"option_id": "pokemon:%d:%s:%s" % [target_player, slot, pokemon.card_id],
			"label": catalog.card_name(pokemon.card_id),
			"ref": EntityRef.new("pokemon", target_player, "", slot, -1, "", pokemon.card_id).to_dict(),
			"value": {"slot": slot, "card_id": pokemon.card_id},
		})
	if options.is_empty():
		return _ok("没有可选备战目标。")
	var actual_count: int = min(max(1, count), options.size())
	stack.push_continuation(operation, data)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, chooser, operation),
		operation,
		chooser,
		prompt,
		options,
		actual_count,
		actual_count,
		false,
		false,
		{"revision": state.revision},
	)
	return _ok()


func _switch_request(
	state: GameState,
	stack: ResolutionStack,
	chooser: int,
	target_player_idx: int,
	optional: bool,
	you_choose: bool,
) -> Dictionary:
	var target_player := state.get_player(target_player_idx)
	if (
		target_player_idx != chooser
		and target_player.active
		and target_player.active.all_prevented_next_turn
	):
		target_player.active.all_prevented_next_turn = false
		return _ok("替换效果被免疫。")
	var options: Array[Dictionary] = []
	for index in range(target_player.bench.size()):
		var pokemon: PokemonState = target_player.bench[index]
		if pokemon:
			var slot := "bench_%d" % index
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [target_player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	if options.is_empty():
		return _ok("没有可替换的备战宝可梦。")
	if optional:
		return _confirm_request(
			state, stack, chooser, "confirm_switch",
			{"chooser": chooser, "target_player": target_player_idx},
			"是否替换战斗宝可梦？")
	stack.push_continuation("switch", {"target_player": target_player_idx})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, chooser, "switch"),
		"select_opponent_bench" if target_player_idx != chooser else "select_bench",
		chooser if you_choose or target_player_idx == chooser else target_player_idx,
		"选择替换上场的宝可梦。",
		options, 1, 1, false, false, {"revision": state.revision})
	return _ok()


func _confirm_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	operation: String,
	data: Dictionary,
	prompt: String,
) -> Dictionary:
	var options: Array[Dictionary] = [
		{"option_id": "confirm:yes", "label": "是", "value": true},
		{"option_id": "confirm:no", "label": "否", "value": false},
	]
	stack.push_continuation(operation, data)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "confirm"),
		"confirm", player_idx, prompt, options, 1, 1)
	return _ok()


func _coin_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	effect_type: String,
	params: Dictionary,
	player_idx: int,
	source_slot: String,
) -> Dictionary:
	var results: Array[bool] = []
	if effect_type == "coin_flip_until_tails":
		while true:
			var result := rng.coin()
			results.append(result)
			if not result or results.size() >= 32:
				break
	else:
		var count := int(params.get("flips", 1))
		if effect_type == "coin_flip_triple":
			count = int(params.get("flips", 3))
		elif effect_type == "coin_flip_double_ko":
			count = 2
		for _index in range(max(1, count)):
			results.append(rng.coin())
	stack.push_continuation("coin", {
		"effect_type": effect_type,
		"params": params.duplicate(true),
		"player_idx": player_idx,
		"source_slot": source_slot,
		"results": results,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "coin_flip"),
		"coin_flip", player_idx, "硬币结果",
		[], 0, 0, false, false,
		{"revision": state.revision, "predetermined_flips": results})
	return _ok("正在掷硬币。")


func _resolve_coin(
	state: GameState,
	stack: ResolutionStack,
	data: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var results: Array = data["results"]
	var effect_type := str(data["effect_type"])
	var params: Dictionary = data["params"]
	var player_idx := int(data["player_idx"])
	var source_slot := str(data["source_slot"])
	var heads := 0
	for result in results:
		if result:
			heads += 1
	events.append({"event_type": "coin_flip", "data": {"results": results.duplicate()}})
	match effect_type:
		"coin_flip":
			var branch: Variant = params.get("on_heads", []) if bool(results[0]) else params.get("on_tails", [])
			if branch is Dictionary:
				stack.push_effect(branch, player_idx, source_slot)
			elif branch is Array:
				stack.push_effects(branch, player_idx, source_slot)
		"coin_flip_triple":
			return _deal_damage(
				state, 1 - player_idx, "active",
				heads * int(params.get("damage_per_head", 10)), events)
		"coin_flip_double_ko":
			if heads == 2:
				var target := state.get_player(1 - player_idx).active
				if target:
					target.damage_counters += max(1, ceili(float(target.current_hp(catalog)) / 10.0))
		"coin_flip_until_tails":
			return _deal_damage(
				state, 1 - player_idx, "active",
				heads * int(params.get("per_head", 20)), events)
		"coin_flip_energy_discard":
			if bool(results[0]):
				var opponent := state.get_player(1 - player_idx)
				var options: Array[Dictionary] = []
				for row in opponent.get_all_pokemon():
					var pokemon: PokemonState = row["pokemon"]
					if pokemon == null:
						continue
					var slot := str(row["slot"])
					for index in range(pokemon.energy_card_ids.size()):
						var energy_id := str(pokemon.energy_card_ids[index])
						options.append({
							"option_id": "attachment:%d:%s:energy:%d:%s" % [1 - player_idx, slot, index, energy_id],
							"label": "%s - %s" % [catalog.card_name(pokemon.card_id), catalog.card_name(energy_id)],
							"ref": EntityRef.new("attachment", 1 - player_idx, "", slot, index, "energy", energy_id).to_dict(),
							"value": {
								"player": 1 - player_idx,
								"slot": slot,
								"index": index,
								"card_id": energy_id,
							},
						})
				if options.is_empty():
					return _ok("对手场上没有能量。")
				stack.push_continuation("discard_attachment", {"player_idx": player_idx})
				stack.pending_request = ChoiceRequest.new(
					stack.next_request_id(state, player_idx, "discard_attachment"),
					"select_attachment",
					player_idx,
					"选择对手场上的1个能量丢弃。",
					options,
					1,
					1,
					false,
					false,
					{"revision": state.revision},
				)
	return _ok()


func _energy_attach(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var zone := str(params.get("from_zone", "deck"))
	var source: Array[String] = player.deck if zone == "deck" else player.hand
	var filter := str(params.get("filter", "any")).to_lower()
	var matching: Array[String] = []
	for card_id in source:
		if _energy_matches(card_id, filter):
			matching.append(card_id)
	var amount := int(params.get("amount", 1))
	var base_amount := amount
	var bonus_applied := false
	if state.active_player_idx != state.first_player_idx and state.is_player_first_turn(player_idx):
		amount = max(amount, int(params.get("going_second_bonus", amount)))
		bonus_applied = amount > base_amount
	if matching.is_empty():
		return _ok("没有符合条件的能量。")
	var optional_count := bool(params.has("min_select") or params.get("optional", false) or bonus_applied)
	var min_select := int(params.get("min_select", 0 if optional_count else -1))
	var target_spec := str(params.get("to", "self"))
	var target_slots: Array[String] = []
	if target_spec == "self":
		target_slots.append(source_slot)
	elif target_spec == "self_basic":
		for row in player.get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon and catalog.is_basic_pokemon(pokemon.card_id):
				target_slots.append(str(row["slot"]))
	elif target_spec == "bench":
		for index in range(player.bench.size()):
			if player.bench[index]:
				target_slots.append("bench_%d" % index)
	else:
		for row in player.get_all_pokemon():
			if row["pokemon"]:
				target_slots.append(str(row["slot"]))
	return _request_energy_target(
		state, stack, player_idx, zone, matching.slice(0, min(amount, matching.size())),
		target_slots, int(params.get("max_per_target", 99)),
		min_select,
		min(amount, matching.size()) if optional_count else -1,
		target_spec in ["self_basic", "any"])


func _attach_from_discard(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var energy_type := str(params.get("energy_type", "any")).to_lower()
	var target_pokemon_type := str(params.get("target_pokemon_type", ""))
	var matching: Array[String] = []
	for card_id in player.discard:
		if not catalog.is_basic_energy(card_id):
			continue
		if energy_type in ["any", "basic", "basic_energy"]:
			matching.append(card_id)
		else:
			for provided in catalog.provides_energy(card_id):
				if provided.to_lower() == energy_type:
					matching.append(card_id)
					break
	if matching.is_empty():
		return _ok("弃牌区没有符合条件的能量。")
	var amount: int = min(int(params.get("amount", 1)), matching.size())
	var optional_count := bool(params.has("min_select") or params.get("optional", false))
	var min_select := int(params.get("min_select", 0 if optional_count else -1))
	var slots: Array[String] = []
	match str(params.get("target", "self")):
		"self":
			var source_pokemon := player.get_pokemon(source_slot)
			if source_pokemon and _pokemon_matches_type(source_pokemon, target_pokemon_type):
				slots.append(source_slot)
		"bench":
			for index in range(player.bench.size()):
				if player.bench[index] and _pokemon_matches_type(player.bench[index], target_pokemon_type):
					slots.append("bench_%d" % index)
		_:
			for row in player.get_all_pokemon():
				if row["pokemon"] and _pokemon_matches_type(row["pokemon"], target_pokemon_type):
					slots.append(str(row["slot"]))
	return _request_energy_target(
		state, stack, player_idx, "discard",
		matching.slice(0, amount),
		slots,
		99,
		min_select,
		amount if optional_count else -1,
		str(params.get("target", "self")) == "self_or_bench")


func _pokemon_matches_type(pokemon: PokemonState, target_type: String) -> bool:
	if target_type.is_empty():
		return true
	var normalized := target_type.to_lower()
	for card_type in catalog.get_card(pokemon.card_id).get("energy_types", []):
		if str(card_type).to_lower() == normalized:
			return true
	return false


func _request_energy_target(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_zone: String,
	card_ids: Array,
	target_slots: Array[String],
	max_per_target: int = 99,
	min_select: int = -1,
	max_select: int = -1,
	same_target: bool = false,
) -> Dictionary:
	if target_slots.is_empty():
		return _ok("没有附能目标。")
	var capped_card_ids: Array = card_ids.duplicate()
	var target_capacity: int = max(0, target_slots.size() * max_per_target)
	if capped_card_ids.size() > target_capacity:
		capped_card_ids = capped_card_ids.slice(0, target_capacity)
	if capped_card_ids.is_empty():
		return _ok("没有可附着的能量。")
	var options: Array[Dictionary] = []
	for slot in target_slots:
		var pokemon := state.get_player(player_idx).get_pokemon(slot)
		if pokemon:
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	var operation := (
		"energy_attach_distribution"
		if capped_card_ids.size() > 1
		else "energy_attach_target"
	)
	var request_min := capped_card_ids.size() if capped_card_ids.size() > 1 else 1
	var request_max := request_min
	if max_select >= 0:
		request_max = min(max_select, capped_card_ids.size())
		request_min = min(request_max, max(0, min_select))
	stack.push_continuation(operation, {
		"player_idx": player_idx,
		"source_zone": source_zone,
		"card_ids": capped_card_ids,
		"max_per_target": max_per_target,
		"same_target": same_target,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, operation),
		"distribute_energy" if capped_card_ids.size() > 1 else "select_energy_target",
		player_idx,
		"为每张能量选择附着目标。" if capped_card_ids.size() > 1 else "选择附着能量的宝可梦。",
		options,
		request_min,
		request_max,
		capped_card_ids.size() > 1,
		request_min <= 0,
		{"revision": state.revision, "max_per_target": max_per_target},
	)
	return _ok()


func _attach_cards(
	state: GameState,
	player_idx: int,
	source_zone: String,
	card_ids: Array,
	target_slot: String,
	events: Array[Dictionary],
	rng: PortableRandomSource,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source: Array[String] = _zone(player, source_zone)
	var target := player.get_pokemon(target_slot)
	if target == null:
		return _fail("附能目标不存在。")
	for card_value in card_ids:
		var card_id := str(card_value)
		var index := source.find(card_id)
		if index >= 0:
			source.remove_at(index)
			target.energy_card_ids.append(card_id)
			events.append({
				"event_type": "energy_attached",
				"actor": player_idx,
				"card_id": card_id,
				"source": {
					"player": player_idx,
					"zone": source_zone,
					"index": index,
				},
				"target": {"player": player_idx, "slot": target_slot},
				"data": {
					"player": player_idx,
					"slot": target_slot,
					"card_id": card_id,
					"source_zone": source_zone,
					"source_index": index,
				},
			})
	if source_zone == "deck":
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
	return _ok()


func _energy_relocate_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var energy_type := str(params.get("energy_type", params.get("filter", "any")))
	var source_options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		var slot := str(row["slot"])
		if (
			pokemon
			and _matching_energy_ids(pokemon.energy_card_ids, energy_type).size() > 0
			and (not bool(params.get("from_self", false)) or slot == "active")
		):
			source_options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	if source_options.is_empty():
		return _ok("场上没有可移动的能量。")
	if source_options.size() == 1:
		return _request_relocation_targets(
			state,
			stack,
			player_idx,
			str(source_options[0].get("value", {}).get("slot", "")),
			int(params.get("amount", 1)),
			energy_type,
			int(params.get("min_select", -1)),
			bool(params.get("same_target", false)),
		)
	stack.push_continuation("energy_relocate_source", {
		"player_idx": player_idx,
		"amount": int(params.get("amount", 1)),
		"energy_type": energy_type,
		"min_select": int(params.get("min_select", -1)),
		"same_target": bool(params.get("same_target", false)),
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "energy_relocate_source"),
		"select_energy_source",
		player_idx,
		"选择能量来源宝可梦。",
		source_options,
		1,
		1,
	)
	return _ok()


func _request_relocation_targets(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	amount: int,
	energy_type: String = "any",
	min_select: int = -1,
	same_target: bool = false,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source := player.get_pokemon(source_slot)
	if source == null:
		return _ok("能量来源没有可移动的能量。")
	var matching_energy := _matching_energy_ids(source.energy_card_ids, energy_type)
	if matching_energy.is_empty():
		return _ok("能量来源没有可移动的能量。")
	var options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		var slot := str(row["slot"])
		if pokemon and slot != source_slot:
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	if options.is_empty():
		return _ok("没有能量转移目标。")
	var move_count: int = min(amount, matching_energy.size())
	var request_min := move_count if move_count > 1 else 1
	var request_max := request_min
	if min_select >= 0:
		request_min = min(move_count, max(0, min_select))
		request_max = move_count
	var operation := (
		"energy_relocate_distribution"
		if move_count > 1
		else "energy_relocate_target"
	)
	stack.push_continuation(operation, {
		"player_idx": player_idx,
		"source_slot": source_slot,
		"amount": move_count,
		"energy_type": energy_type,
		"card_ids": matching_energy.slice(0, move_count),
		"same_target": same_target,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, operation),
		"distribute_energy" if move_count > 1 else "select_energy_target",
		player_idx,
		"为每张能量选择转移目标。" if move_count > 1 else "选择能量转移目标。",
		options,
		request_min,
		request_max,
		move_count > 1,
		request_min <= 0,
	)
	return _ok()


func _attach_from_hand_to_bench(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	amount: int,
	energy_type: String,
	min_select: int = -1,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var matching: Array[String] = []
	for card_id in player.hand:
		if catalog.is_basic_energy(card_id) and energy_type in catalog.provides_energy(card_id):
			matching.append(card_id)
	var slots: Array[String] = []
	for index in range(player.bench.size()):
		if player.bench[index]:
			slots.append("bench_%d" % index)
	if matching.is_empty() or slots.is_empty():
		return _ok()
	return _request_energy_target(
		state, stack, player_idx, "hand",
		matching.slice(0, min(amount, matching.size())), slots, 99,
		min_select,
		min(amount, matching.size()) if min_select >= 0 else -1,
		true)


func _look_top_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var count: int = min(int(params.get("count", 1)), player.deck.size())
	var top_cards: Array[String] = []
	for offset in range(count):
		top_cards.append(player.deck[player.deck.size() - 1 - offset])
	var available := catalog.filter_cards(top_cards, str(params.get("filter", "any")))
	var take: int = min(int(params.get("take", 1)), available.size())
	if available.is_empty():
		return _ok("查看的卡中没有符合条件的卡。")
	return _request_cards(
		state, stack, player_idx, "deck", available, "look_top",
		{
			"player_idx": player_idx,
			"top_cards": top_cards,
			"destination": str(params.get("destination", "hand")),
			"rest_bottom": bool(params.get("rest_bottom", false)),
			"shuffle_rest": bool(params.get("shuffle_rest", false)),
		},
		0, take, "选择查看到的卡。", true)


func _look_top_attach_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var count: int = min(int(params.get("count", 5)), player.deck.size())
	var take := int(params.get("take", 99))
	var filter_type := str(params.get("filter", "basic_energy"))
	var options: Array[Dictionary] = []
	var top_indices: Array[int] = []
	for offset in range(count):
		var deck_index := player.deck.size() - 1 - offset
		top_indices.append(deck_index)
		var card_id := player.deck[deck_index]
		if not _energy_matches(card_id, filter_type):
			continue
		options.append({
			"option_id": "card:deck:%d:%s" % [deck_index, card_id],
			"label": catalog.card_name(card_id),
			"ref": EntityRef.new("card", player_idx, "deck", "", deck_index, "", card_id).to_dict(),
			"value": {"index": deck_index, "card_id": card_id},
		})
	if options.is_empty():
		rng.shuffle(player.deck)
		return _ok("查看的卡中没有可附着的能量。")
	stack.push_continuation("look_top_attach_energy", {
		"player_idx": player_idx,
		"top_indices": top_indices,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "look_top_attach_energy"),
		"look_top_attach_energy",
		player_idx,
		"选择任意数量的基本能量。",
		options,
		0,
		min(take, options.size()),
		false,
		true,
		{"revision": state.revision},
	)
	return _ok()


func _resolve_look_top(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var selected_cards := _remove_selected_from_zone(player, "deck", selected, false)
	var top_cards: Array = data["top_cards"]
	var remaining: Array[String] = []
	for card_value in top_cards:
		var card_id := str(card_value)
		var index := player.deck.find(card_id)
		if index >= 0:
			player.deck.remove_at(index)
			remaining.append(card_id)
	var destination := str(data["destination"])
	if destination == "bench_energy":
		if bool(data["shuffle_rest"]):
			player.deck.append_array(remaining)
			rng.shuffle(player.deck)
			events.append({"event_type": "deck_shuffled", "data": {
				"player": int(data["player_idx"]),
			}})
		elif bool(data["rest_bottom"]):
			for card_id in remaining:
				player.deck.push_front(card_id)
		else:
			player.deck.append_array(remaining)
		if selected_cards.is_empty():
			events.append({"event_type": "cards_selected", "data": {
				"player": int(data["player_idx"]), "count": 0,
			}})
			return _ok("未选择能量。")
		var options: Array[Dictionary] = []
		for index in range(player.bench.size()):
			var pokemon: PokemonState = player.bench[index]
			if pokemon == null:
				continue
			var card_data := catalog.get_card(pokemon.card_id)
			if not ("Lightning" in card_data.get("energy_types", [])):
				continue
			var slot := "bench_%d" % index
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [int(data["player_idx"]), slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"ref": EntityRef.new("pokemon", int(data["player_idx"]), "", slot, -1, "", pokemon.card_id).to_dict(),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
		if options.is_empty():
			player.deck.append_array(selected_cards)
			rng.shuffle(player.deck)
			events.append({"event_type": "deck_shuffled", "data": {
				"player": int(data["player_idx"]),
			}})
			return _ok("没有备战雷宝可梦。")
		if options.size() == 1:
			for energy_id in selected_cards:
				player.get_pokemon(str(options[0].get("value", {}).get("slot", ""))).energy_card_ids.append(energy_id)
			return _ok()
		stack.push_continuation("detached_energy_distribution", {
			"player_idx": int(data["player_idx"]),
			"card_ids": selected_cards,
			"max_per_target": 99,
		})
		stack.pending_request = ChoiceRequest.new(
			stack.next_request_id(state, int(data["player_idx"]), "detached_energy_distribution"),
			"distribute_energy",
			int(data["player_idx"]),
			"为电气发生器选择附着目标。",
			options,
			selected_cards.size(),
			selected_cards.size(),
			true,
			false,
			{"revision": state.revision, "max_per_target": 99},
		)
		events.append({"event_type": "cards_selected", "data": {
			"player": int(data["player_idx"]), "count": selected_cards.size(),
		}})
		return _ok()
	else:
		player.hand.append_array(selected_cards)
	if bool(data["shuffle_rest"]):
		player.deck.append_array(remaining)
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {
			"player": int(data["player_idx"]),
		}})
	elif bool(data["rest_bottom"]):
		for card_id in remaining:
			player.deck.push_front(card_id)
	else:
		player.deck.append_array(remaining)
	events.append({"event_type": "cards_selected", "data": {
		"player": int(data["player_idx"]), "count": selected_cards.size(),
	}})
	return _ok()


func _resolve_look_top_attach_energy(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var selected_indices: Dictionary = {}
	for option in selected:
		selected_indices[int(option.get("value", {}).get("index", -1))] = true
	var indices: Array = data.get("top_indices", [])
	indices.sort()
	indices.reverse()
	var selected_cards: Array[String] = []
	var remaining: Array[String] = []
	for raw_index in indices:
		var deck_index := int(raw_index)
		if deck_index < 0 or deck_index >= player.deck.size():
			continue
		var card_id: String = player.deck.pop_at(deck_index)
		if selected_indices.has(deck_index):
			selected_cards.append(card_id)
		else:
			remaining.append(card_id)
	player.deck.append_array(remaining)
	rng.shuffle(player.deck)
	events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
	if selected_cards.is_empty():
		return _ok("未选择能量。")
	var options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot := str(row["slot"])
		options.append({
			"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
			"label": catalog.card_name(pokemon.card_id),
			"ref": EntityRef.new("pokemon", player_idx, "", slot, -1, "", pokemon.card_id).to_dict(),
			"value": {"slot": slot, "card_id": pokemon.card_id},
		})
	if options.is_empty():
		return _fail("没有附能目标。")
	if options.size() == 1:
		return _attach_selected_energy_to_slot(
			state, player_idx, selected_cards, str(options[0].get("value", {}).get("slot", "")), events)
	stack.push_continuation("look_top_attach_target", {
		"player_idx": player_idx,
		"card_ids": selected_cards,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "look_top_attach_target"),
		"select_energy_target",
		player_idx,
		"选择1只宝可梦附着能量。",
		options,
		1,
		1,
		false,
		false,
		{"revision": state.revision},
	)
	return _ok()


func _resolve_look_top_attach_target(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return _fail("没有选择附能目标。")
	return _attach_selected_energy_to_slot(
		state,
		int(data["player_idx"]),
		Array(data["card_ids"]),
		str(selected[0].get("value", {}).get("slot", "")),
		events,
	)


func _attach_selected_energy_to_slot(
	state: GameState,
	player_idx: int,
	card_ids: Array,
	target_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var target := state.get_player(player_idx).get_pokemon(target_slot)
	if target == null:
		return _fail("附能目标不存在。")
	for card_value in card_ids:
		var card_id := str(card_value)
		target.energy_card_ids.append(card_id)
		events.append({
			"event_type": "energy_attached",
			"actor": player_idx,
			"card_id": card_id,
			"source": {"player": player_idx, "zone": "deck"},
			"target": {"player": player_idx, "slot": target_slot},
			"data": {"player": player_idx, "slot": target_slot, "card_id": card_id},
		})
	return _ok("附着了%d张能量。" % card_ids.size())


func _rare_candy(state: GameState, player_idx: int, events: Array[Dictionary]) -> Dictionary:
	var player := state.get_player(player_idx)
	if state.is_player_first_turn(player_idx):
		return _fail("第一回合不能使用神奇糖果。")
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null or not catalog.is_basic_pokemon(pokemon.card_id):
			continue
		if pokemon.placed_this_turn or not pokemon.can_evolve_this_turn:
			continue
		for hand_index in range(player.hand.size()):
			var stage2_id := player.hand[hand_index]
			if not catalog.is_stage2(stage2_id):
				continue
			var evolves_from := str(catalog.get_card(stage2_id).get("evolves_from", ""))
			var stage1_name := evolves_from
			var basic_matches := false
			for candidate_id in catalog.cards:
				if catalog.card_name(candidate_id) == stage1_name:
					basic_matches = (
						str(catalog.get_card(candidate_id).get("evolves_from", "")).to_lower()
						== catalog.card_name(pokemon.card_id).to_lower()
					)
					if basic_matches:
						break
			if not basic_matches:
				continue
			player.hand.remove_at(hand_index)
			pokemon.evolution_stack_ids.append(pokemon.card_id)
			pokemon.card_id = stage2_id
			pokemon.status_conditions.clear()
			pokemon.can_evolve_this_turn = false
			var target_slot := str(row["slot"])
			events.append({
				"event_type": "pokemon_evolved",
				"actor": player_idx,
				"card_id": stage2_id,
				"source": {"player": player_idx, "zone": "hand", "index": hand_index},
				"target": {"player": player_idx, "slot": target_slot},
				"data": {
					"player": player_idx,
					"slot": target_slot,
					"card_id": stage2_id,
					"source_zone": "hand",
					"source_index": hand_index,
				},
			})
			return _ok()
	return _fail("没有可用神奇糖果进化的目标。")


func _conditional_effect(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	if params.get("condition", "") == "ko_by_attack_last_turn":
		if not player.was_ko_by_attack:
			return _fail("条件未满足。")
		player.was_ko_by_attack = false
	var on_pay: Variant = params.get("on_pay")
	if on_pay is Dictionary:
		stack.push_effect(on_pay, player_idx, source_slot)
	elif on_pay is Array:
		stack.push_effects(on_pay, player_idx, source_slot)
	var cost: Variant = params.get("cost")
	if cost is Dictionary:
		stack.push_effect(cost, player_idx, source_slot)
	return _ok()


func _attack_damage_formula(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source := player.get_pokemon(source_slot)
	if source == null:
		return _fail("没有攻击来源。")
	var total := int(params.get("base", 0))
	var per_own_bench := int(params.get("per_own_bench", 0))
	if per_own_bench > 0:
		total += player.bench_count() * per_own_bench
	var per_self_energy_type := str(params.get("per_self_energy_type", ""))
	if not per_self_energy_type.is_empty():
		var energy_count := 0
		for energy_id in source.energy_card_ids:
			if _energy_matches(energy_id, per_self_energy_type):
				energy_count += 1
		total += energy_count * int(params.get("per_energy", 0))
	var per_self_damage_counter := int(params.get("per_self_damage_counter", 0))
	if per_self_damage_counter > 0:
		total += source.damage_counters * per_self_damage_counter
	var condition_bonus: Dictionary = params.get("condition_bonus", {})
	var condition := str(condition_bonus.get("condition", ""))
	var applies := false
	var formula_opponent := state.get_player(1 - player_idx)
	match condition:
		"ko_by_attack_last_turn":
			applies = player.was_ko_by_attack
		"own_bench_damaged":
			for bench_pokemon in player.bench:
				if bench_pokemon and bench_pokemon.damage_counters > 0:
					applies = true
					break
		"opponent_active_evolved":
			applies = formula_opponent.active != null and not catalog.is_basic_pokemon(formula_opponent.active.card_id)
		"opponent_active_damaged":
			applies = formula_opponent.active != null and formula_opponent.active.damage_counters > 0
		"own_hand_empty":
			applies = player.hand.is_empty()
	if applies:
		total += int(condition_bonus.get("bonus", 0))
		if condition == "ko_by_attack_last_turn" and bool(condition_bonus.get("consume", true)):
			player.was_ko_by_attack = false
	stack.context["base_damage"] = total
	if bool(params.get("piercing", false)):
		stack.context["piercing"] = true
	if bool(params.get("ignore_defender_effects", false)):
		stack.context["ignore_defender_effects"] = true
	return _ok()


func _request_injured_target(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	amount: int,
) -> Dictionary:
	var options: Array[Dictionary] = []
	for row in state.get_player(player_idx).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon and pokemon.damage_counters > 0:
			var slot := str(row["slot"])
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	if options.is_empty():
		return _fail("没有受伤的宝可梦。")
	stack.push_continuation("heal_target", {"player_idx": player_idx, "amount": amount})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "heal_target"),
		"select_heal_target", player_idx, "选择回复目标。",
		options, 1, 1)
	return _ok()


func _energy_matches(card_id: String, energy_type: String) -> bool:
	var normalized := energy_type.to_lower()
	if not catalog.is_energy(card_id):
		return false
	if normalized in ["any", "energy", ""]:
		return true
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	for provided in catalog.provides_energy(card_id):
		if str(provided).to_lower() == normalized:
			return true
	return false


func _matching_energy_ids(card_ids: Array, energy_type: String) -> Array[String]:
	var result: Array[String] = []
	for card_value in card_ids:
		var card_id := str(card_value)
		if _energy_matches(card_id, energy_type):
			result.append(card_id)
	return result


func _conditional_damage_bonus(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var opponent := state.get_player(1 - player_idx)
	var condition := str(params.get("condition", ""))
	var applies := false
	match condition:
		"opponent_active_damaged":
			applies = opponent.active != null and opponent.active.damage_counters > 0
		"ko_by_attack_last_turn":
			applies = player.was_ko_by_attack
			player.was_ko_by_attack = false
		"opponent_active_evolved":
			applies = opponent.active != null and not catalog.is_basic_pokemon(opponent.active.card_id)
		"field_energy_ge_5":
			var count := 0
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon:
					count += pokemon.energy_card_ids.size()
			applies = count >= 5
	if not applies:
		return _ok("追加伤害条件未满足。")
	return _deal_damage(
		state, 1 - player_idx, "active", int(params.get("bonus", 0)), events)


func _deal_damage(
	state: GameState,
	player_idx: int,
	slot: String,
	amount: int,
	events: Array[Dictionary],
	consume_effect_immunity: bool = true,
) -> Dictionary:
	var pokemon := state.get_player(player_idx).get_pokemon(slot)
	if pokemon == null or amount <= 0:
		return _ok()
	if pokemon.damage_prevented_next_turn:
		pokemon.damage_prevented_next_turn = false
		if pokemon.all_prevented_next_turn:
			pokemon.all_prevented_next_turn = false
		return _ok("伤害被免疫。")
	if consume_effect_immunity and pokemon.all_prevented_next_turn:
		pokemon.all_prevented_next_turn = false
		return _ok("附加效果伤害被免疫。")
	pokemon.damage_counters += int(amount / DAMAGE_PER_COUNTER)
	events.append({"event_type": "damage_dealt", "data": {
		"player": player_idx, "slot": slot, "amount": amount,
	}})
	return _ok("造成%d点伤害。" % amount)


func _apply_status(
	state: GameState,
	player_idx: int,
	slot: String,
	status: String,
	events: Array[Dictionary],
) -> Dictionary:
	var pokemon := state.get_player(player_idx).get_pokemon(slot)
	if pokemon == null:
		return _fail("没有状态目标。")
	if pokemon.all_prevented_next_turn:
		pokemon.all_prevented_next_turn = false
		return _ok("状态效果被免疫。")
	var normalized := status.to_upper()
	if normalized not in ["POISONED", "BURNED", "ASLEEP", "PARALYZED", "CONFUSED"]:
		return _fail("未知状态: %s" % status)
	if normalized in ["ASLEEP", "PARALYZED", "CONFUSED"]:
		for exclusive in ["ASLEEP", "PARALYZED", "CONFUSED"]:
			pokemon.status_conditions.erase(exclusive)
	if normalized not in pokemon.status_conditions:
		pokemon.status_conditions.append(normalized)
	if normalized == "PARALYZED":
		pokemon.paralyzed_since_turn = state.turn_number
	events.append({"event_type": "status_applied", "data": {
		"player": player_idx, "slot": slot, "status": normalized,
	}})
	return _ok()


func _heal_pokemon(
	state: GameState,
	player_idx: int,
	slot: String,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var pokemon := player.get_pokemon(slot)
	if pokemon == null:
		return _fail("没有回复目标。")
	var counters := int(amount / DAMAGE_PER_COUNTER)
	var healed: int = min(pokemon.damage_counters, counters)
	pokemon.damage_counters -= healed
	if healed > 0:
		player.healed_this_turn = true
		events.append({"event_type": "healed", "data": {
			"player": player_idx, "slot": slot, "amount": healed * DAMAGE_PER_COUNTER,
		}})
	return _ok()


func _draw(
	state: GameState,
	player_idx: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	if amount <= 0:
		return _ok()
	var player := state.get_player(player_idx)
	if player.deck.size() < amount:
		state.winner = 1 - player_idx
		state.phase = "GAME_OVER"
		return _ok("%s牌库耗尽。" % player.name)
	var cards := player.draw_cards(amount)
	events.append({"event_type": "cards_drawn", "data": {
		"player": player_idx, "cards": cards.duplicate(),
	}})
	return _ok("抽取了%d张卡。" % cards.size())


func _draw_available(
	state: GameState,
	player_idx: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	if amount <= 0:
		return _ok()
	var player := state.get_player(player_idx)
	var cards := player.draw_cards(min(amount, player.deck.size()))
	events.append({"event_type": "cards_drawn", "data": {
		"player": player_idx, "cards": cards.duplicate(),
	}})
	return _ok("抽取了%d张卡。" % cards.size())


func _move_selected_cards(
	state: GameState,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var source_zone := str(data["source_zone"])
	var moved := _remove_selected_from_zone(player, source_zone, selected, false)
	match str(data["destination"]):
		"hand":
			player.hand.append_array(moved)
		"bench":
			for card_id in moved:
				var slot := player.find_empty_bench_slot()
				if slot >= 0:
					player.place_bench(card_id, slot)
				else:
					player.hand.append(card_id)
		_:
			player.hand.append_array(moved)
	if bool(data.get("shuffle", false)):
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
	events.append({"event_type": "cards_selected", "data": {
		"player": player_idx, "cards": moved.duplicate(),
	}})
	return _ok()


func _remove_selected_from_zone(
	player: PlayerState,
	zone_name: String,
	selected: Array[Dictionary],
	to_discard: bool,
) -> Array[String]:
	var zone := _zone(player, zone_name)
	var indices: Array[int] = []
	for option in selected:
		indices.append(int(option.get("value", {}).get("index", -1)))
	indices.sort()
	indices.reverse()
	var removed_reversed: Array[String] = []
	for index in indices:
		if index >= 0 and index < zone.size():
			var card_id: String = zone.pop_at(index)
			removed_reversed.append(card_id)
			if to_discard:
				player.discard.append(card_id)
	removed_reversed.reverse()
	return removed_reversed


func _discard_event(
	player_idx: int,
	source_zone: String,
	card_ids: Array,
	count: int,
) -> Dictionary:
	return {
		"event_type": "cards_discarded",
		"actor": player_idx,
		"source": {"player": player_idx, "zone": source_zone},
		"target": {"player": player_idx, "zone": "discard"},
		"amount": count,
		"data": {
			"player": player_idx,
			"count": count,
			"card_ids": card_ids.duplicate(),
		},
	}


func _selected_target_damage(
	state: GameState,
	selected: Array[Dictionary],
	target_player: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return _fail("没有选择目标。")
	return _deal_damage(
		state, target_player,
		str(selected[0].get("value", {}).get("slot", "")),
		amount, events)


func _selected_bench_damage(
	state: GameState,
	selected: Array[Dictionary],
	target_player: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return _fail("没有选择目标。")
	for option in selected:
		var slot := str(option.get("value", {}).get("slot", ""))
		if slot.begins_with("bench_"):
			_deal_damage(state, target_player, slot, amount, events)
	return _ok("备战伤害已结算。")


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


func _ok(message: String = "") -> Dictionary:
	return {"success": true, "message": message}


func _fail(message: String, error_code: String = "effect_failed") -> Dictionary:
	return {"success": false, "message": message, "error_code": error_code}

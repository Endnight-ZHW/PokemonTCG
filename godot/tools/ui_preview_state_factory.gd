class_name UIPreviewStateFactory
extends RefCounted

const DEFAULT_SEED := 20260623


static func battle_state(seed: int = DEFAULT_SEED) -> GameState:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = rng.randi_range(3, 5)
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.stadium_card_id = "sv1-171"
	state.players[0].name = "预览玩家"
	state.players[1].name = "预览对手"
	state.players[0].active = PokemonState.new("svi-hrot")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.energy_card_ids = ["sv1-ener-2", "sv1-ener-2"]
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[1] = PokemonState.new("svi-ente")
	state.players[1].active = PokemonState.new("sv2-keldeo")
	state.players[1].active.placed_this_turn = false
	state.players[1].active.damage_counters = rng.randi_range(3, 5)
	state.players[1].active.status_conditions = ["BURNED"]
	state.players[1].bench[0] = PokemonState.new("sv2-starm")
	state.players[0].hand = [
		"sv1-ener-2",
		"sv1-189",
		"svf-potion",
		"sv1-151",
		"svi-jete",
	]
	state.players[0].deck = []
	for index in range(43):
		state.players[0].deck.append([
			"sv1-ener-2",
			"svi-chim",
			"sv1-189",
			"svf-potion",
		][index % 4])
	state.players[0].discard = ["sv1-104"]
	state.players[0].prizes = [
		"svi-flam", "svi-ente", "sv1-ener-2", "sv1-151",
	]
	state.players[1].hand = ["", "", "", "", "", ""]
	for _index in range(43):
		state.players[1].deck.append("")
	state.players[1].discard = ["sv2-38"]
	for _index in range(6):
		state.players[1].prizes.append("")
	state.action_log = [
		"预览玩家抽了一张卡。",
		"预览玩家为战斗宝可梦附加了能量。",
		"预览对手的战斗宝可梦受到了 40 点伤害。",
	]
	return state


static func setup_state(seed: int = DEFAULT_SEED) -> GameState:
	var state := battle_state(seed)
	state.phase = "SETUP"
	state.turn_number = 0
	state.stadium_card_id = ""
	state.setup_ready.assign([false, false])
	state.players[0].hand = [
		"svi-chim",
		"sv1-ener-2",
		"sv1-189",
		"svf-potion",
	]
	state.players[0].bench = [null, null, null, null, null]
	state.players[0].active = PokemonState.new("svi-hrot")
	state.players[1].bench = [null, null, null, null, null]
	state.action_log = [
		"预览玩家将加热洛托姆放到了战斗场。",
		"请选择手牌中的基础宝可梦，或完成准备。",
	]
	return state


static func promotion_state(seed: int = DEFAULT_SEED) -> GameState:
	var state := battle_state(seed)
	state.players[0].active = null
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].energy_card_ids.assign(["sv1-ener-2"])
	state.players[0].bench[1] = PokemonState.new("svi-ente")
	state.action_log.append("战斗宝可梦气绝了，请从备战区选择新的战斗宝可梦。")
	return state


static func setup_action_rows(state: GameState) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	rows.append({
		"action": GameAction.new("SETUP_DONE", {}, false, 0),
		"label": "完成准备",
	})
	for bench_index in range(3):
		var slot := "bench_%d" % bench_index
		rows.append({
			"action": GameAction.new(
				"PLAY_BASIC",
				{"hand_idx": 0, "target": slot},
				false,
				0,
				_hand_ref(state, 0),
				_pokemon_ref(0, slot, ""),
			),
			"label": "放置到备战区",
		})
	return rows


static func action_rows(state: GameState) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	rows.append({
		"action": GameAction.new("END_TURN", {}, true, 0),
		"label": "结束回合",
	})
	rows.append({
		"action": GameAction.new(
			"ATTACH_ENERGY",
			{"hand_idx": 0, "target_slot": "active"},
			false,
			0,
			_hand_ref(state, 0),
			_pokemon_ref(0, "active", state.players[0].active.card_id),
		),
		"label": "附能到战斗宝可梦",
	})
	rows.append({
		"action": GameAction.new(
			"PLAY_TRAINER",
			{"hand_idx": 1},
			false,
			0,
			_hand_ref(state, 1),
		),
		"label": "使用 博士的研究",
	})
	rows.append({
		"action": GameAction.new(
			"DECLARE_ATTACK",
			{"attack_idx": 0},
			false,
			0,
			_pokemon_ref(0, "active", state.players[0].active.card_id),
			_pokemon_ref(1, "active", state.players[1].active.card_id),
		),
		"label": "高温冲撞 · 100",
	})
	for bench_index in range(2):
		var slot := "bench_%d" % bench_index
		var target := state.players[0].bench[bench_index] as PokemonState
		if target == null:
			continue
		rows.append({
			"action": GameAction.new(
				"RETREAT",
				{"bench_idx": bench_index},
				false,
				0,
				_pokemon_ref(0, "active", state.players[0].active.card_id),
				_pokemon_ref(0, slot, target.card_id),
			),
			"label": "撤退",
		})
	return rows


static func promotion_action_rows(state: GameState) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for bench_index in range(state.players[0].bench.size()):
		var pokemon := state.players[0].bench[bench_index] as PokemonState
		if pokemon == null:
			continue
		var slot := "bench_%d" % bench_index
		rows.append({
			"action": GameAction.new(
				"PROMOTE",
				{"bench_idx": bench_index},
				false,
				0,
				_pokemon_ref(0, slot, pokemon.card_id),
				_pokemon_ref(0, "active", ""),
			),
			"label": "晋升为战斗宝可梦",
		})
	return rows


static func _hand_ref(state: GameState, hand_index: int) -> EntityRef:
	var card_id := ""
	if hand_index >= 0 and hand_index < state.players[0].hand.size():
		card_id = state.players[0].hand[hand_index]
	return EntityRef.new("card", 0, "hand", "", hand_index, "", card_id)


static func _pokemon_ref(player: int, slot: String, card_id: String) -> EntityRef:
	return EntityRef.new("pokemon", player, "field", slot, -1, "", card_id)

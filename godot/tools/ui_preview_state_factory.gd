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
			EntityRef.new("card", 0, "hand", "", 0, "", state.players[0].hand[0]),
			EntityRef.new(
				"pokemon",
				0,
				"field",
				"active",
				-1,
				"",
				state.players[0].active.card_id,
			),
		),
		"label": "附能到战斗宝可梦",
	})
	rows.append({
		"action": GameAction.new(
			"PLAY_TRAINER",
			{"hand_idx": 2},
			false,
			0,
			EntityRef.new("card", 0, "hand", "", 2, "", state.players[0].hand[2]),
		),
		"label": "使用训练家卡",
	})
	rows.append({
		"action": GameAction.new(
			"DECLARE_ATTACK",
			{"attack_idx": 0},
			false,
			0,
			EntityRef.new(
				"pokemon",
				0,
				"field",
				"active",
				-1,
				"",
				state.players[0].active.card_id,
			),
			EntityRef.new(
				"pokemon",
				1,
				"field",
				"active",
				-1,
				"",
				state.players[1].active.card_id,
			),
		),
		"label": "使用第一个招式",
	})
	return rows

class_name BattleViewModel
extends RefCounted

## Immutable-by-convention render input.  The authoritative GameState may keep
## advancing while a presentation batch is queued, so every batch owns a clone.

var _state: GameState
var view_player := 0
var action_rows: Array[Dictionary] = []
var selected_entity_key := ""
var ai_thinking := false
var game_mode := "local"


static func capture(
	state: GameState,
	p_view_player: int,
	p_action_rows: Array[Dictionary],
	p_selected_entity_key: String,
	p_ai_thinking: bool,
	p_game_mode: String,
) -> BattleViewModel:
	var result := BattleViewModel.new()
	result._state = state.clone_state() if state != null else null
	result.view_player = p_view_player
	result.action_rows = p_action_rows.duplicate(true)
	result.selected_entity_key = p_selected_entity_key
	result.ai_thinking = p_ai_thinking
	result.game_mode = p_game_mode
	return result


static func capture_player_view(
	state: GameState,
	p_view_player: int,
	p_action_rows: Array[Dictionary],
	p_selected_entity_key: String,
	p_ai_thinking: bool,
	p_game_mode: String,
) -> BattleViewModel:
	var visible_state := player_view_state(state, p_view_player)
	return capture(
		visible_state,
		p_view_player,
		p_action_rows,
		p_selected_entity_key,
		p_ai_thinking,
		p_game_mode,
	)


static func player_view_state(state: GameState, player_idx: int) -> GameState:
	if state == null or player_idx not in [0, 1]:
		return null
	# Local and AI matches keep a fully authoritative state in Main. Cross the
	# presentation boundary through the same player-view contract as network play
	# so hidden hands, decks, prizes and face-down setup Pokemon never enter UI
	# objects merely because both players share one process.
	return StateSerializer.from_player_view(
		StateSerializer.for_player(state, player_idx),
		player_idx,
	)


func state_for_render() -> GameState:
	return _state.clone_state() if _state != null else null


func revision() -> int:
	return _state.revision if _state != null else -1

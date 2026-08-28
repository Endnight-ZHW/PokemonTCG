extends "res://tests/network_contract_support.gd"

func _run_direct_knockout_protocol_contract() -> void:
	var session := AuthoritativeSession.new("direct-ko-contract")
	var direct_state := GameState.new()
	direct_state.setup_stage = GameState.SETUP_COMPLETE
	direct_state.phase = "MAIN"
	direct_state.turn_number = 2
	direct_state.first_player_idx = 0
	direct_state.active_player_idx = 0
	direct_state.players[0].active = PokemonState.new("svf-klea")
	direct_state.players[0].active.placed_this_turn = false
	direct_state.players[0].active.energy_card_ids = [
		"sv1-ener-1", "sv1-ener-2",
	]
	direct_state.players[0].prizes = ["sv1-ener-3"]
	direct_state.players[1].active = PokemonState.new("sv1-104")
	direct_state.players[1].active.placed_this_turn = false
	# Lucky Energy is an AFTER_DAMAGE hook. A direct-KO effect must discard it
	# with the Pokemon without ever drawing the defender a card.
	direct_state.players[1].active.energy_card_ids = ["svi-mirc"]
	direct_state.players[1].deck = ["sv1-ener-4"]
	direct_state.players[1].prizes = ["sv1-ener-5"]
	_expect(
		session.native_rules.restore(direct_state.snapshot(), 2),
		"direct-KO fixture could not load into Native ABI 2",
	)
	session.state = session.native_rules.state
	session.rng = PortableRandomSource.new(
		session.native_rules.rng_state) # First two flips are both heads.

	var attack_action: GameAction = null
	var legal_query := session.native_rules.legal_actions(0)
	for candidate in legal_query.concrete_actions():
		if (
			candidate.kind == "DECLARE_ATTACK"
			and candidate.attack_index() == 0
		):
			attack_action = candidate
			break
	_expect(attack_action != null, "direct-KO fixture has no legal first attack")
	if attack_action == null:
		return
	attack_action.action_id = "direct-ko:attack"
	var attack_step := session.submit_action(0, attack_action.to_dict())
	var causal_types_by_player := {0: [], 1: []}
	_collect_direct_ko_view_events(
		session, attack_step, causal_types_by_player)
	var coin_request := attack_step.pending_choice
	_expect(
		attack_step.success
		and coin_request != null
		and coin_request.request_type == "coin_flip"
		and coin_request.presentation.get("predetermined_flips", []) == [true, true],
		"direct-KO attack did not pause on the fixed double-heads result",
	)
	if coin_request == null:
		return

	var coin_step := session.submit_choice(
		0,
		ChoiceResponse.new(coin_request.request_id, []).to_dict(),
	)
	_collect_direct_ko_view_events(
		session, coin_step, causal_types_by_player)
	var prize_request := coin_step.pending_choice
	_expect(
		coin_step.success
		and prize_request != null
		and prize_request.request_type == "select_prize",
		"direct-KO settlement did not pause for an explicit prize position",
	)
	if prize_request == null:
		return
	var prize_step := session.submit_choice(
		0,
		ChoiceResponse.new(prize_request.request_id, ["prize:0"]).to_dict(),
	)
	_collect_direct_ko_view_events(
		session, prize_step, causal_types_by_player)
	_expect(
		prize_step.success and prize_step.pending_choice == null,
		"direct-KO prize settlement did not finish",
	)

	var expected_causal_order := [
		"coin_flip",
		"direct_knockout_applied",
		"pokemon_ko",
		"ko_card_moved",
		"prize_taken",
	]
	for player_idx in [0, 1]:
		var actual: Array = causal_types_by_player[player_idx]
		var cursor := -1
		var causal := true
		for expected_type in expected_causal_order:
			var found := actual.find(expected_type, cursor + 1)
			if found < 0:
				causal = false
				break
			cursor = found
		_expect(
			causal,
			"direct-KO presentation order was not causal for player %d: %s"
			% [player_idx, actual],
		)
		_expect(
			"damage_dealt" not in actual and "cards_drawn" not in actual,
			"direct-KO incorrectly entered damage/AFTER_DAMAGE presentation for player %d"
			% player_idx,
		)
	_expect(
		session.state.players[1].hand.is_empty()
		and session.state.players[1].deck == ["sv1-ener-4"],
		"Lucky Energy drew a card after a direct-KO effect",
	)


func _collect_direct_ko_view_events(
	session: AuthoritativeSession,
	step: StepResult,
	causal_types_by_player: Dictionary,
) -> void:
	for player_idx in [0, 1]:
		var view := session.view_for(player_idx, step.events)
		_expect(
			bool(ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE, view
			).get("ok", false)),
			"direct-KO state update was not Protocol v6-valid for player %d"
			% player_idx,
		)
		var actual: Array = causal_types_by_player[player_idx]
		for event_value in view.get("presentation_events", []):
			var event: Dictionary = event_value
			var event_type := PresentationEvent.canonical_event_type(
				str(event.get("event_type", "")),
			)
			if (
				event_type == "card_moved"
				and bool(event.get("data", {}).get("ko_leave_play", false))
			):
				event_type = "ko_card_moved"
			actual.append(event_type)
		causal_types_by_player[player_idx] = actual


func _run_setup_hidden_information_contract() -> void:
	var session := AuthoritativeSession.new("setup-hidden-contract")
	var started := session.start_match("fire", "water", 20260716)
	_expect(started.success, "hidden setup fixture did not start")
	if not started.success:
		return
	var chooser := session.state.opening_coin_winner_idx
	var choice_value: Variant = session.view_for(chooser).get("choice_request")
	_expect(choice_value is Dictionary, "coin winner did not receive turn-order choice")
	if not choice_value is Dictionary:
		return
	var request := ChoiceView.from_dict(choice_value)
	var turn_order := session.submit_choice(
		chooser,
		ChoiceResponse.new(request.request_id, ["turn:first"]).to_dict(),
	)
	_expect(turn_order.success, "turn-order choice failed in hidden setup fixture")
	if not turn_order.success:
		return
	var actor := session.state.first_player_idx
	var actor_actions := _concrete_actions(
		session.view_for(actor).get("legal_action_groups", []))
	var placement: GameAction = null
	for action_row in actor_actions:
		if (
			action_row.kind == "PLAY_BASIC"
			and action_row.target != null
			and action_row.target.slot == "active"
		):
			placement = action_row
			break
	_expect(placement != null, "setup fixture had no active Basic placement")
	if placement == null:
		return
	placement.action_id = "setup-hidden-placement"
	var placed := session.submit_action(actor, placement.to_dict())
	_expect(placed.success, "setup Basic placement failed")
	if not placed.success:
		return
	var hidden_card_id := session.state.get_player(actor).active.card_id
	var opponent_view := session.view_for(1 - actor, placed.events)
	var opponent_payload: Dictionary = opponent_view.get("state", {}).get(
		"opponent", {})
	_expect(
		opponent_payload.get("active") == {"hidden": true},
		"opponent setup Pokemon was not serialized as the strict placeholder",
	)
	_expect(
		bool(ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, opponent_view
		).get("ok", false)),
		"actual hidden setup view was not Protocol v6 valid",
	)
	_expect(
		not JSON.stringify(opponent_view.get("presentation_events", [])).contains(
			hidden_card_id
		)
		and not JSON.stringify(opponent_view["state"].get("action_log", [])).contains(
			hidden_card_id
		)
		and opponent_view["state"].get("action_log", []).any(
			func(line: String) -> bool: return line.contains("暗置宝可梦")
		),
		"setup event or log leaked the hidden Pokemon identity",
	)
	var reconnect_view := session.view_for(1 - actor)
	_expect(
		Dictionary(reconnect_view["state"]["opponent"]).get("active")
		== {"hidden": true},
		"reconnection view leaked a setup Pokemon identity",
	)


func _run_mulligan_presentation_contract() -> void:
	var session: AuthoritativeSession
	var started: StepResult
	for seed_offset in range(1, 513):
		var candidate := AuthoritativeSession.new("mulligan-presentation-contract")
		var candidate_started := candidate.start_match(
			"fire",
			"water",
			2026071600 + seed_offset,
			0,
		)
		if (
			candidate_started.success
			and maxi(candidate.state.mulligan_count[0], candidate.state.mulligan_count[1]) > 0
		):
			session = candidate
			started = candidate_started
			break
	_expect(session != null, "could not find a deterministic mulligan fixture")
	if session == null:
		return

	var sequence_is_causal := true
	for actor in [0, 1]:
		var actor_events: Array[Dictionary] = []
		for event_value in started.events:
			var event: Dictionary = event_value
			if (
				int(event.get("actor", -1)) == actor
				and str(event.get("event_type", "")) in [
					"cards_drawn", "cards_revealed", "card_moved", "deck_shuffled",
				]
			):
				actor_events.append(event)
		var mulligan_count := session.state.mulligan_count[actor]
		sequence_is_causal = (
			sequence_is_causal
			and actor_events.size() == 1 + mulligan_count * 4
		)
		if actor_events.is_empty():
			sequence_is_causal = false
			continue
		var opening_data: Dictionary = actor_events[0].get("data", {})
		sequence_is_causal = (
			sequence_is_causal
			and str(actor_events[0].get("event_type", "")) == "cards_drawn"
			and str(opening_data.get("purpose", "")) == "opening_hand"
			and int(opening_data.get("round", -1)) == 0
			and Array(opening_data.get("card_ids", [])).size() == 7
			and bool(opening_data.get("final_opening_hand", false))
			== (mulligan_count == 0)
		)
		for round_number in range(1, mulligan_count + 1):
			var base := 1 + (round_number - 1) * 4
			if base + 3 >= actor_events.size():
				sequence_is_causal = false
				break
			var reveal: Dictionary = actor_events[base]
			var returned: Dictionary = actor_events[base + 1]
			var shuffled: Dictionary = actor_events[base + 2]
			var redrawn: Dictionary = actor_events[base + 3]
			var reveal_data: Dictionary = reveal.get("data", {})
			var return_data: Dictionary = returned.get("data", {})
			var shuffle_data: Dictionary = shuffled.get("data", {})
			var redraw_data: Dictionary = redrawn.get("data", {})
			sequence_is_causal = (
				sequence_is_causal
				and str(reveal.get("event_type", "")) == "cards_revealed"
				and str(reveal_data.get("purpose", "")) == "mulligan"
				and int(reveal_data.get("round", -1)) == round_number
				and Array(reveal_data.get("cards", [])).size() == 7
				and Array(reveal_data.get("cards", []))
				== Array(return_data.get("card_ids", []))
				and str(returned.get("event_type", "")) == "card_moved"
				and str(return_data.get("purpose", "")) == "mulligan_return"
				and int(return_data.get("round", -1)) == round_number
				and str(shuffled.get("event_type", "")) == "deck_shuffled"
				and str(shuffle_data.get("purpose", "")) == "mulligan"
				and int(shuffle_data.get("round", -1)) == round_number
				and str(redrawn.get("event_type", "")) == "cards_drawn"
				and str(redraw_data.get("purpose", "")) == "mulligan_redraw"
				and int(redraw_data.get("round", -1)) == round_number
				and Array(redraw_data.get("card_ids", [])).size() == 7
				and bool(redraw_data.get("final_opening_hand", false))
				== (round_number == mulligan_count)
			)
	_expect(
		sequence_is_causal,
		"mulligan events did not serialize draw -> reveal -> return -> shuffle -> redraw causally",
	)

	for perspective in [0, 1]:
		var view := session.view_for(perspective, started.events)
		_expect(
			bool(ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE,
				view,
			).get("ok", false)),
			"mulligan presentation view was not Protocol v6-valid for player %d"
			% perspective,
		)
		var privacy_is_correct := true
		for event_value in view.get("presentation_events", []):
			var event: Dictionary = event_value
			var event_type := str(event.get("event_type", ""))
			var data: Dictionary = event.get("data", {})
			if event_type == "cards_drawn" and str(data.get("purpose", "")) in [
				"opening_hand", "mulligan_redraw",
			]:
				privacy_is_correct = (
					privacy_is_correct
					and int(event.get("amount", 0)) == 7
					and Array(data.get("card_ids", [])).size()
					== (7 if int(event.get("actor", -1)) == perspective else 0)
				)
			elif event_type == "cards_revealed":
				privacy_is_correct = (
					privacy_is_correct
					and Array(data.get("cards", [])).size() == 7
					and Array(data.get("card_ids", [])).size() == 7
				)
		_expect(
			privacy_is_correct,
			"mulligan owner redraw or public old-hand visibility leaked for player %d"
			% perspective,
		)


func _run_setup_stage_recovery_contract() -> void:
	for stage in [
		GameState.SETUP_TURN_ORDER,
		GameState.SETUP_INITIAL_PLACEMENT,
		GameState.SETUP_BONUS_DRAW,
		GameState.SETUP_BONUS_PLACEMENT,
	]:
		var state := _setup_recovery_state(stage)
		for perspective in [0, 1]:
			var view := _state_update_payload(state, perspective)
			var opponent: Dictionary = view["state"]["opponent"]
			var opponent_card_id := (
				"sv1-104" if perspective == 0 else "svi-chim"
			)
			var has_board := state.get_player(1 - perspective).active != null
			_expect(
				bool(ProtocolV6.validate_payload(
					ProtocolV6.STATE_UPDATE,
					view,
				).get("ok", false))
				and (
					opponent.get("active") == {"hidden": true}
					if has_board
					else opponent.get("active") == null
				)
				and not view["state"].has("setup_bonus_card_ids")
				and (
					not JSON.stringify(view).contains(opponent_card_id)
					if has_board
					else true
				),
				"%s recovery snapshot leaked setup authority for player %d"
				% [stage, perspective],
			)

	var complete_state := _setup_recovery_state(GameState.SETUP_COMPLETE)
	complete_state.phase = "MAIN"
	for perspective in [0, 1]:
		var complete_view := _state_update_payload(complete_state, perspective)
		var opponent: Dictionary = complete_view["state"]["opponent"]
		_expect(
			bool(ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE,
				complete_view,
			).get("ok", false))
			and opponent.get("active") is Dictionary
			and not bool(Dictionary(opponent["active"]).get("hidden", false)),
			"COMPLETE recovery snapshot did not publish the opponent board",
		)


func _setup_recovery_state(stage: String) -> GameState:
	var state := GameState.new()
	state.phase = "SETUP"
	state.turn_number = 1
	state.first_player_idx = 0
	state.active_player_idx = 0
	state.revision = 17
	state.public_deck_keys = ["fire", "water"]
	state.setup_stage = stage
	state.setup_actor_idx = 0 if stage != GameState.SETUP_COMPLETE else -1
	state.opening_coin_winner_idx = 0
	state.mulligan_bonus_max = 2
	state.mulligan_count = [0, 2]
	state.setup_bonus_card_ids = [["sv1-ener-1"], []]
	for player_idx in [0, 1]:
		state.get_player(player_idx).deck = [
			"sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4",
		]
		state.get_player(player_idx).hand = ["svf-potion"]
	if stage != GameState.SETUP_TURN_ORDER:
		state.get_player(0).active = PokemonState.new("svi-chim")
		state.get_player(1).active = PokemonState.new("sv1-104")
	return state


func _state_update_payload(state: GameState, perspective: int) -> Dictionary:
	return {
		"state": StateSerializer.for_player(state, perspective),
		"legal_action_groups": [],
		"legal_action_error": "",
		"presentation_events": [],
		"choice_request": null,
		"wait_context": null,
	}


func _run_final_setup_publication_contract() -> void:
	var session := AuthoritativeSession.new("final-setup-publication-contract")
	session.state = GameState.new()
	session.state.phase = "SETUP"
	session.state.turn_number = 1
	session.state.first_player_idx = 0
	session.state.active_player_idx = 0
	session.state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	session.state.setup_actor_idx = 0
	session.state.opening_coin_winner_idx = 0
	session.state.public_deck_keys = ["fire", "water"]
	session.state.get_player(0).hand = ["svi-chim"]
	session.state.get_player(1).hand = ["svi-chim"]
	for player_idx in [0, 1]:
		for _index in range(10):
			session.state.get_player(player_idx).deck.append("sv1-ener-1")
	_expect(
		session.native_rules.restore(session.state.snapshot(), 99117),
		"final setup fixture could not load into Native ABI 2",
	)
	session.state = session.native_rules.state
	session.rng = PortableRandomSource.new(session.native_rules.rng_state)

	var steps: Array[StepResult] = []
	for row in [
		{"actor": 0, "action": "PLAY_BASIC", "params": {"hand_idx": 0, "target": "active"}},
		{"actor": 0, "action": "SETUP_DONE", "params": {}},
		{"actor": 1, "action": "PLAY_BASIC", "params": {"hand_idx": 0, "target": "active"}},
		{"actor": 1, "action": "SETUP_DONE", "params": {}},
	]:
		var action: GameAction = null
		for candidate in _concrete_actions(
			session.view_for(int(row["actor"])).get("legal_action_groups", [])
		):
			if candidate.kind != str(row["action"]):
				continue
			if (
				candidate.kind == "PLAY_BASIC"
				and (candidate.target == null or candidate.target.slot != "active")
			):
				continue
			action = candidate
			break
		if action == null:
			steps.append(StepResult.new(false, "missing legal setup action"))
			continue
		action.action_id = "final-setup:%d" % steps.size()
		steps.append(session.submit_action(int(row["actor"]), action.to_dict()))
	var all_steps_succeeded := steps.all(
		func(step: StepResult) -> bool: return step.success,
	)
	_expect(all_steps_succeeded, "final setup publication fixture failed")
	if not all_steps_succeeded:
		return
	var final_step: StepResult = steps[-1]
	for perspective in [0, 1]:
		var view := session.view_for(perspective, final_step.events)
		var event_types: Array[String] = []
		var draw_event: Dictionary = {}
		for event_value in view.get("presentation_events", []):
			var event: Dictionary = event_value
			event_types.append(str(event.get("event_type", "")))
			if str(event.get("event_type", "")) == "cards_drawn":
				draw_event = event
		var draw_ids: Array = Dictionary(draw_event.get("data", {})).get(
			"card_ids", [])
		_expect(
			bool(ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE,
				view,
			).get("ok", false))
			and session.state.setup_stage == GameState.SETUP_COMPLETE
			and view["state"]["opponent"].get("active") is Dictionary
			and event_types == ["setup_revealed", "turn_start", "cards_drawn"]
			and int(draw_event.get("actor", -1)) == 0
			and draw_ids.size() == (1 if perspective == 0 else 0),
			"final setup reveal/start/draw publication was invalid for player %d"
			% perspective,
		)

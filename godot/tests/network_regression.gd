extends SceneTree

const ACTION_GUARD := 1200
const POLL_GUARD := 30000

var failures: Array[String] = []


func _initialize() -> void:
	var summaries: Array[Dictionary] = []
	summaries.append(_play_network_game("lan", ""))
	var relay_url := _argument_value("--relay-url")
	if not relay_url.is_empty():
		summaries.append(_play_network_game("relay", relay_url))
	for summary in summaries:
		if not bool(summary.get("success", false)):
			failures.append("%s: %s" % [
				summary.get("transport", "network"),
				summary.get("error", "unknown"),
			])
	if failures.is_empty():
		print("NETWORK_REGRESSION_OK ", JSON.stringify(summaries))
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _play_network_game(transport_kind: String, relay_url: String) -> Dictionary:
	var host := NetworkMatchController.new()
	var client := NetworkMatchController.new()
	var port := 20000 + int(Time.get_ticks_msec() % 1000)
	var error := OK
	var deck_key := "fire" if transport_kind == "lan" else "steel"
	if transport_kind == "lan":
		error = host.host_lan(port, deck_key, 20260621)
		if error == OK:
			error = client.join_lan("127.0.0.1", port, deck_key)
	else:
		error = host.host_relay(relay_url, deck_key, 20260621, true)
		if error == OK:
			var room_id := ""
			for _poll in range(10000):
				for event in host.poll():
					if event.get("type", "") == "room_created":
						room_id = str(event.get("room_id", ""))
					elif event.get("type", "") in [
						"error", "connection_failed", "transport_error",
					]:
						host.close()
						return _failed(transport_kind, str(event))
				if not room_id.is_empty():
					break
				OS.delay_msec(1)
			if room_id.is_empty():
				host.close()
				return _failed(transport_kind, "relay room was not created")
			error = client.join_relay(relay_url, room_id, deck_key)
	if error != OK:
		host.close()
		client.close()
		return _failed(transport_kind, error_string(error))

	var latest_views: Array[Dictionary] = [{}, {}]
	var actions := 0
	var choices := 0
	var loops := 0
	var last_revision := -1
	var same_deck_verified := false
	var action_counts := {}
	while actions < ACTION_GUARD and loops < POLL_GUARD:
		loops += 1
		var submitted := false
		for event in host.poll():
			var processed := _capture_event(event, latest_views, 0)
			if processed.has("error"):
				var diagnostic := _board_contract_diagnostic(host)
				host.close()
				client.close()
				return _failed(transport_kind, "%s board=%s" % [
					processed["error"], diagnostic,
				])
			if event.get("type", "") == "state" and not same_deck_verified:
				var state_view: Dictionary = event.get("view", {}).get("state", {})
				if state_view.get("public_deck_keys", []) != [deck_key, deck_key]:
					host.close()
					client.close()
					return _failed(transport_kind, "equal deck keys were not preserved")
				if (
					host.session == null
					or host.session.state == null
					or host.session.state.players[0].deck
					== host.session.state.players[1].deck
				):
					host.close()
					client.close()
					return _failed(transport_kind, "equal decks were not shuffled independently")
				same_deck_verified = true
		for event in client.poll():
			var processed := _capture_event(event, latest_views, 1)
			if processed.has("error"):
				var diagnostic := _board_contract_diagnostic(host)
				host.close()
				client.close()
				return _failed(transport_kind, "%s board=%s" % [
					processed["error"], diagnostic,
				])

		for player_idx in [0, 1]:
			var view: Dictionary = latest_views[player_idx]
			if view.is_empty():
				continue
			var state_payload: Dictionary = view.get("state", {})
			var winner := int(state_payload.get("winner", -1))
			var result_status := str(state_payload.get("result_status", "ONGOING"))
			if result_status != "ONGOING":
				if not same_deck_verified:
					host.close()
					client.close()
					return _failed(transport_kind, "same-deck contract was not verified")
				var summary := {
					"success": true,
					"transport": transport_kind,
					"winner": winner,
					"result_status": result_status,
					"turns": int(state_payload.get("turn_number", 0)),
					"actions": actions,
					"choices": choices,
					"revision": int(state_payload.get("revision", 0)),
					"deck_key": deck_key,
					"same_deck": true,
				}
				host.close()
				client.close()
				return summary
			var revision := int(state_payload.get("revision", -1))
			var choice_data: Variant = view.get("choice_request")
			var controller := host if player_idx == 0 else client
			if choice_data is Dictionary:
				if controller.submit_choice(_automatic_choice(
					ChoiceRequest.from_dict(choice_data)
				)):
					choices += 1
					submitted = true
					last_revision = revision
					break
			var legal_groups: Array = view.get("legal_action_groups", [])
			if not legal_groups.is_empty() and revision != last_revision:
				var candidates: Array[GameAction] = []
				for row in legal_groups:
					if not row is Dictionary:
						continue
					for action in LegalActionGroup.from_dict(row).concrete_actions():
						candidates.append(action)
				if candidates.is_empty():
					continue
				var action := _automatic_action(candidates)
				if controller.submit_action(action):
					actions += 1
					action_counts[action.action] = int(action_counts.get(action.action, 0)) + 1
					submitted = true
					last_revision = revision
					break
		OS.delay_msec(20 if submitted else 1)
	host.close()
	client.close()
	return _failed(
		transport_kind,
		"game guard exceeded actions=%d loops=%d counts=%s" % [
			actions,
			loops,
			JSON.stringify(action_counts),
		],
	)


func _capture_event(
	event: Dictionary,
	latest_views: Array[Dictionary],
	player_idx: int,
) -> Dictionary:
	match str(event.get("type", "")):
		"state":
			var view: Dictionary = event.get("view", {})
			var protocol_validation := ProtocolV6.validate_payload(
				ProtocolV6.STATE_UPDATE, view
			)
			if not bool(protocol_validation.get("ok", false)):
				return {"error": "received a state outside the protocol v6 contract: %s groups=%s events=%s" % [
					JSON.stringify(protocol_validation),
					JSON.stringify(view.get("legal_action_groups", [])),
					JSON.stringify(view.get("presentation_events", [])),
				]}
			var state_payload: Dictionary = view.get("state", {})
			var own: Dictionary = state_payload.get("your", {})
			var opponent: Dictionary = state_payload.get("opponent", {})
			if (
				own.has("deck")
				or own.has("prizes")
				or opponent.has("hand")
				or opponent.has("deck")
				or opponent.has("prizes")
			):
				return {"error": "hidden information leaked to player %d" % player_idx}
			if (
				str(state_payload.get("rules_profile_id", ""))
				!= GameState.RULES_PROFILE_ID
				or not state_payload.get("rules_options") is Dictionary
				or Dictionary(state_payload["rules_options"]).keys()
				!= ["apply_type_matchups"]
			):
				return {"error": "rules profile/options were not locked in the player view"}
			if str(state_payload.get("setup_stage", "")) != GameState.SETUP_COMPLETE:
				for pokemon_value in [opponent.get("active")] + Array(opponent.get("bench", [])):
					if pokemon_value != null and pokemon_value != {"hidden": true}:
						return {"error": "setup Pokemon identity leaked before reveal"}
			latest_views[player_idx] = view
		"error", "connection_failed", "transport_error", "disconnected":
			return {"error": JSON.stringify(event)}
	return {}


func _automatic_action(actions: Array[GameAction]) -> GameAction:
	var priority := [
		"PROMOTE", "PLAY_BASIC", "EVOLVE", "ATTACH_ENERGY", "DECLARE_ATTACK",
		"PLAY_TRAINER", "SETUP_DONE", "END_TURN", "USE_ABILITY",
		"USE_STADIUM", "RETREAT",
	]
	for action_name in priority:
		for action in actions:
			if action.action == action_name:
				return action
	return actions[0]


func _board_contract_diagnostic(host: NetworkMatchController) -> String:
	if host == null or host.session == null or host.session.state == null:
		return "unavailable"
	var board: Array[Dictionary] = []
	for player_idx in [0, 1]:
		var player := host.session.state.players[player_idx]
		var slots: Array[Dictionary] = []
		if player.active != null:
			slots.append({"slot": "active", "pokemon": player.active.to_dict()})
		for bench_idx in range(player.bench.size()):
			if player.bench[bench_idx] != null:
				slots.append({
					"slot": "bench_%d" % bench_idx,
					"pokemon": player.bench[bench_idx].to_dict(),
				})
		board.append({"player": player_idx, "slots": slots})
	return JSON.stringify(board)


func _automatic_choice(request: ChoiceRequest) -> ChoiceResponse:
	if request.options.is_empty():
		return ChoiceResponse.new(request.request_id, [])
	var count := mini(
		request.options.size(),
		maxi(request.min_select, request.max_select),
	)
	var selected: Array[String] = []
	for index in range(count):
		var option_index := 0 if request.allow_duplicates else index
		selected.append(str(request.options[option_index]["option_id"]))
	return ChoiceResponse.new(request.request_id, selected)


func _argument_value(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix + "="):
			return argument.trim_prefix(prefix + "=")
	return ""


func _failed(transport_kind: String, message: String) -> Dictionary:
	return {
		"success": false,
		"transport": transport_kind,
		"error": message,
	}

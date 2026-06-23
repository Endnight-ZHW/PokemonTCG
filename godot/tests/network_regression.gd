extends SceneTree

const ACTION_GUARD := 1200

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
	if transport_kind == "lan":
		error = host.host_lan(port, "fire", 20260621)
		if error == OK:
			error = client.join_lan("127.0.0.1", port, "water")
	else:
		error = host.host_relay(relay_url, "fire", 20260621)
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
			error = client.join_relay(relay_url, room_id, "water")
	if error != OK:
		host.close()
		client.close()
		return _failed(transport_kind, error_string(error))

	var latest_views: Array[Dictionary] = [{}, {}]
	var actions := 0
	var choices := 0
	var loops := 0
	var last_revision := -1
	while actions < ACTION_GUARD and loops < 120000:
		loops += 1
		var submitted := false
		for event in host.poll():
			var processed := _capture_event(event, latest_views, 0)
			if processed.has("error"):
				host.close()
				client.close()
				return _failed(transport_kind, processed["error"])
		for event in client.poll():
			var processed := _capture_event(event, latest_views, 1)
			if processed.has("error"):
				host.close()
				client.close()
				return _failed(transport_kind, processed["error"])

		for player_idx in [0, 1]:
			var view: Dictionary = latest_views[player_idx]
			if view.is_empty():
				continue
			var state_payload: Dictionary = view.get("state", {})
			var winner := int(state_payload.get("winner", -1))
			if winner >= 0:
				var summary := {
					"success": true,
					"transport": transport_kind,
					"winner": winner,
					"turns": int(state_payload.get("turn_number", 0)),
					"actions": actions,
					"choices": choices,
					"revision": int(state_payload.get("revision", 0)),
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
			var legal: Array = view.get("legal_actions", [])
			if not legal.is_empty() and revision != last_revision:
				var candidates: Array[GameAction] = []
				for row in legal:
					candidates.append(GameAction.from_dict(row))
				var action := _automatic_action(candidates)
				if controller.submit_action(action):
					actions += 1
					submitted = true
					last_revision = revision
					break
		OS.delay_msec(20 if submitted else 1)
	host.close()
	client.close()
	return _failed(
		transport_kind,
		"game guard exceeded actions=%d loops=%d" % [actions, loops],
	)


func _capture_event(
	event: Dictionary,
	latest_views: Array[Dictionary],
	player_idx: int,
) -> Dictionary:
	match str(event.get("type", "")):
		"state":
			var view: Dictionary = event.get("view", {})
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
			latest_views[player_idx] = view
		"error", "connection_failed", "transport_error", "disconnected":
			return {"error": JSON.stringify(event)}
	return {}


func _automatic_action(actions: Array[GameAction]) -> GameAction:
	var priority := [
		"PROMOTE", "PLAY_BASIC", "EVOLVE", "ATTACH_ENERGY", "PLAY_TRAINER",
		"USE_ABILITY", "USE_STADIUM", "RETREAT", "DECLARE_ATTACK",
		"SETUP_DONE", "END_TURN",
	]
	for action_name in priority:
		for action in actions:
			if action.action == action_name:
				return action
	return actions[0]


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

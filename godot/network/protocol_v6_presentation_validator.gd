extends "res://network/protocol_v6_limits.gd"

static func _validate_entity_ref(value: Variant) -> bool:
	return EntityRef.validate_dict(value).is_empty()


static func _validate_choice_response(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_payload", "选择响应必须是对象。")
	var response: Dictionary = value
	if response.size() != 3 or not (
		response.has("request_id")
		and response.has("option_ids")
		and response.has("cancelled")
	):
		return _invalid("invalid_payload", "选择响应包含缺失或多余字段。")
	if (
		not _bounded_string(response.get("request_id"), MAX_IDENTIFIER_BYTES)
		or str(response.get("request_id", "")).is_empty()
		or not _bounded_string_array(
			response.get("option_ids"), MAX_CHOICE_OPTIONS, MAX_IDENTIFIER_BYTES)
		or not response.get("cancelled") is bool
	):
		return _invalid("invalid_payload", "选择响应字段无效。")
	return {"ok": true}


static func _validate_choice_view(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_payload", "选择请求必须是对象。")
	var request: Dictionary = value
	var required_fields: Array[String] = [
		"schema_version", "request_id", "base_revision", "player",
		"request_type", "prompt", "options", "min_select", "max_select",
		"allow_duplicates", "can_cancel", "presentation",
	]
	if request.size() != required_fields.size():
		return _invalid("invalid_payload", "ChoiceView 包含缺失或多余字段。")
	for field in required_fields:
		if not request.has(field):
			return _invalid("invalid_payload", "ChoiceView 缺少字段：%s" % field)
	if (
		not _bounded_int(request, "schema_version", ChoiceView.SCHEMA_VERSION, ChoiceView.SCHEMA_VERSION)
		or not _bounded_string(request.get("request_id"), MAX_IDENTIFIER_BYTES)
		or str(request.get("request_id", "")).is_empty()
		or not _bounded_int(request, "base_revision", 0, 2147483647)
		or not _bounded_string(request.get("request_type"), 64)
		or str(request.get("request_type", "")).is_empty()
		or not _bounded_int(request, "player", 0, 1)
		or not _bounded_string(request.get("prompt", ""), MAX_TEXT_BYTES)
		or not _bounded_int(request, "min_select", 0, MAX_CHOICE_OPTIONS)
		or not _bounded_int(request, "max_select", 0, MAX_CHOICE_OPTIONS)
		or not request.get("allow_duplicates") is bool
		or not request.get("can_cancel") is bool
		or not request.get("options") is Array
		or not request.get("presentation") is Dictionary
	):
		return _invalid("invalid_payload", "ChoiceView 字段无效。")
	if int(request["min_select"]) > int(request["max_select"]):
		return _invalid("invalid_payload", "选择数量范围无效。")
	if not _validate_choice_presentation(
		request["presentation"], int(request["player"]), str(request["request_type"])
	):
		return _invalid("invalid_payload", "ChoiceView presentation 字段无效。")
	var is_hidden_prize_choice := str(request["request_type"]) == "select_prize"
	if is_hidden_prize_choice:
		var prize_presentation: Dictionary = request["presentation"]
		for identity_field in [
			"card_ids", "revealed_card_ids", "top_card_id", "attachment_refs",
			"browse_card_refs", "source_card_id", "card_id", "labels",
		]:
			if prize_presentation.has(identity_field):
				return _invalid(
					"invalid_payload",
					"Prize ChoiceView 不得公开卡牌身份。",
				)
	var options: Array = request["options"]
	if options.size() > MAX_CHOICE_OPTIONS:
		return _invalid("invalid_payload", "选择项数量超过限制。")
	for option_value in options:
		if not option_value is Dictionary:
			return _invalid("invalid_payload", "选择项必须是对象。")
		var option: Dictionary = option_value
		if option.size() not in [2, 3] or not option.has("option_id") or not option.has("label"):
			return _invalid("invalid_payload", "选择项包含缺失或多余字段。")
		for option_field in option:
			if option_field not in ["option_id", "label", "ref"]:
				return _invalid("invalid_payload", "选择项包含非公开字段。")
		if (
			not _bounded_string(option.get("option_id"), MAX_IDENTIFIER_BYTES)
			or str(option.get("option_id", "")).is_empty()
			or not _bounded_string(option.get("label", ""), MAX_TEXT_BYTES)
			or not _json_tree_is_bounded(option)
		):
			return _invalid("invalid_payload", "选择项字段无效。")
		if option.has("ref") and option["ref"] != null:
			if is_hidden_prize_choice:
				return _invalid(
					"invalid_payload",
					"Prize ChoiceView 不得公开实体引用。",
				)
			if not _validate_entity_ref(option["ref"]):
				return _invalid("invalid_payload", "选择项实体引用无效。")
	return {"ok": true}


static func _validate_choice_presentation(
	presentation: Dictionary,
	request_player: int,
	request_type: String,
) -> bool:
	if not _json_tree_is_bounded(presentation):
		return false
	for field in presentation:
		if not field is String or str(field) not in ChoiceView.PRESENTATION_FIELDS:
			return false
	if presentation.has("max_per_target") and not _bounded_int(
		presentation, "max_per_target", 0, 2147483647
	):
		return false
	for field in ["domain", "purpose", "decision_mode", "cancel_mode", "hook"]:
		if presentation.has(field) and not _bounded_string(
			presentation[field], 64
		):
			return false
	for field in ["source_player", "target_player", "owner"]:
		if presentation.has(field) and not _bounded_int(
			presentation, field, -1, 1
		):
			return false
	for source_field in ["source_slot", "source_zone", "target_slot", "energy_type"]:
		if presentation.has(source_field) and not _bounded_string(
			presentation[source_field], MAX_IDENTIFIER_BYTES
		):
			return false
	for flag in ["same_source", "same_target", "cancels_action"]:
		if presentation.has(flag) and not presentation[flag] is bool:
			return false
	for count_field in [
		"required_units", "pokemon_count", "energy_count", "amount", "count",
	]:
		if presentation.has(count_field) and not _bounded_int(
			presentation, count_field, 0, 2147483647
		):
			return false
	for id_field in ["top_card_id", "source_card_id", "card_id", "trigger_id"]:
		if presentation.has(id_field) and not _bounded_string(
			presentation[id_field], MAX_IDENTIFIER_BYTES
		):
			return false
	for ids_field in [
		"card_ids", "revealed_card_ids", "target_slots", "trigger_ids", "labels",
	]:
		if presentation.has(ids_field) and not _bounded_string_array(
			presentation[ids_field], MAX_CHOICE_OPTIONS, MAX_TEXT_BYTES
		):
			return false
	if presentation.has("attachment_refs"):
		var refs: Variant = presentation["attachment_refs"]
		if not refs is Array or Array(refs).size() > MAX_CHOICE_OPTIONS:
			return false
		for ref in refs:
			if not _validate_entity_ref(ref) and not _validate_attachment_unit_ref(ref):
				return false
	if presentation.has("browse_card_refs"):
		if (
			request_type == "select_prize"
			or str(presentation.get("domain", "")) != "search"
			or int(presentation.get("source_player", -1)) != request_player
			or str(presentation.get("source_zone", "")) != "deck"
		):
			return false
		var browse_refs: Variant = presentation["browse_card_refs"]
		if not browse_refs is Array or Array(browse_refs).size() > MAX_DECK_CARDS:
			return false
		var seen_indices: Dictionary = {}
		for ref_value in Array(browse_refs):
			if not _validate_entity_ref(ref_value):
				return false
			var ref: Dictionary = ref_value
			var browse_index := int(ref.get("index", -1))
			if (
				str(ref.get("kind", "")) != "card"
				or int(ref.get("player", -1)) != request_player
				or str(ref.get("zone", "")) != "deck"
				or browse_index < 0
				or browse_index >= MAX_DECK_CARDS
				or seen_indices.has(browse_index)
				or not _bounded_string(
					ref.get("card_id", ""), MAX_IDENTIFIER_BYTES)
			):
				return false
			seen_indices[browse_index] = true
	if presentation.has("predetermined_flips"):
		var flips: Variant = presentation["predetermined_flips"]
		if not flips is Array or Array(flips).size() > MAX_CHOICE_OPTIONS:
			return false
		for flip in flips:
			if not flip is bool:
				return false
	if presentation.has("category_limits"):
		if not presentation["category_limits"] is Dictionary:
			return false
		var limits: Dictionary = presentation["category_limits"]
		if limits.size() > MAX_CHOICE_OPTIONS:
			return false
		for category in limits:
			if (
				not category is String
				or not _bounded_string(category, MAX_IDENTIFIER_BYTES)
				or not _is_integer_number(limits[category])
				or int(limits[category]) < 0
				or int(limits[category]) > MAX_CHOICE_OPTIONS
			):
				return false
	if presentation.has("selection_mode") and not _bounded_string(
		presentation["selection_mode"], 64
	):
		return false
	return true


static func _validate_attachment_unit_ref(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	return (
		row.size() == 2
		and _bounded_string(row.get("option_id"), MAX_IDENTIFIER_BYTES)
		and not str(row.get("option_id", "")).is_empty()
		and _bounded_int(row, "units", 1, 64)
	)
static func _validate_presentation_event(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var event: Dictionary = value
	if (
		not _bounded_string(event.get("event_id", ""), MAX_IDENTIFIER_BYTES)
		or not _bounded_string(event.get("event_type", ""), MAX_IDENTIFIER_BYTES)
		or not PresentationEvent.is_supported_event_type(str(event.get("event_type", "")))
		or not _bounded_int(event, "revision", 0, 2147483647)
		or not _bounded_int(event, "actor", -1, 1)
		or not _bounded_string(event.get("card_id", ""), MAX_IDENTIFIER_BYTES)
		or not _bounded_int(event, "amount", 0, 2147483647)
		or not _bounded_string(event.get("visibility", "public"), 16)
		or str(event.get("visibility", "public")) not in ["public", "owner", "private"]
		or not event.get("data", {}) is Dictionary
		or not event.get("source", {}) is Dictionary
		or not event.get("target", {}) is Dictionary
	):
		return false
	if (
		str(event.get("event_type", "")) == "cards_revealed"
		and not _validate_cards_revealed_data(event["data"])
	):
		return false
	if (
		str(event.get("event_type", "")) == "turn_order_chosen"
		and not _validate_turn_order_chosen_data(event["data"])
	):
		return false
	if (
		str(event.get("event_type", "")) == "setup_revealed"
		and not _validate_setup_revealed_data(event["data"])
	):
		return false
	return (
		_validate_presentation_endpoint(event["source"])
		and _validate_presentation_endpoint(event["target"])
		and _validate_presentation_data(event["data"])
		and _json_tree_is_bounded(event)
	)


static func _validate_cards_revealed_data(data: Dictionary) -> bool:
	if not data.has("cards") or not _validate_presentation_cards(data["cards"]):
		return false
	if str(data.get("purpose", "")) == "mulligan":
		return (
			_bounded_int(data, "player", 0, 1)
			and _bounded_int(data, "round", 1, 64)
			and _bounded_string_array(
				data.get("card_ids", []), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES)
			and Array(data["cards"]) == Array(data["card_ids"])
			and Array(data["cards"]).size() == 7
		)
	var summary_value: Variant = data.get("summary")
	if not summary_value is Dictionary:
		return false
	var summary: Dictionary = summary_value
	if (
		not _bounded_string(summary.get("kind"), 64)
		or str(summary.get("kind", "")).is_empty()
		or not _bounded_int(summary, "matched_count", 0, MAX_DECK_CARDS)
		or not _bounded_int(summary, "amount", 0, 2147483647)
	):
		return false
	return int(summary["matched_count"]) <= Array(data["cards"]).size()


static func _validate_turn_order_chosen_data(data: Dictionary) -> bool:
	return (
		data.size() == 2
		and _bounded_int(data, "coin_winner", 0, 1)
		and _bounded_int(data, "first_player", 0, 1)
	)


static func _validate_setup_revealed_data(data: Dictionary) -> bool:
	if not _bounded_int(data, "first_player", 0, 1):
		return false
	var players_value: Variant = data.get("players")
	if not players_value is Array or Array(players_value).size() != 2:
		return false
	for player_value in Array(players_value):
		if not player_value is Dictionary:
			return false
		var player: Dictionary = player_value
		if (
			player.size() != 2
			or not _bounded_string(player.get("active", ""), MAX_IDENTIFIER_BYTES)
			or str(player.get("active", "")).is_empty()
			or not _bounded_string_array(
				player.get("bench", []), MAX_BENCH_SIZE, MAX_IDENTIFIER_BYTES)
		):
			return false
	return true


static func _validate_presentation_endpoint(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var endpoint: Dictionary = value
	if not _bounded_int(endpoint, "player", -1, 1):
		return false
	for field in ["zone", "slot"]:
		if endpoint.has(field) and not _bounded_string(
			endpoint[field], MAX_IDENTIFIER_BYTES
		):
			return false
	if endpoint.has("index") and not _bounded_int(
		endpoint, "index", -1, MAX_DECK_CARDS
	):
		return false
	return true


static func _validate_presentation_data(data: Dictionary) -> bool:
	for field in [
		"player", "actor", "source_player", "target_player", "winner",
		"loser", "first_player", "coin_winner", "visibility_owner",
	]:
		if data.has(field) and not _bounded_int(data, field, -1, 1):
			return false
	for field_and_bounds in [
		["bench_idx", -1, MAX_BENCH_SIZE - 1],
		["source_index", -1, MAX_DECK_CARDS],
		["target_index", -1, MAX_DECK_CARDS],
		["count", 0, MAX_DECK_CARDS],
		["amount", 0, 2147483647],
		["turn", 0, 2147483647],
		["round", 0, 64],
	]:
		var field := str(field_and_bounds[0])
		if data.has(field) and not _bounded_int(
			data, field, int(field_and_bounds[1]), int(field_and_bounds[2])
		):
			return false
	for field in [
		"slot", "source_slot", "target_slot", "source_zone", "target_zone",
		"card_id", "source_card_id", "target_card_id", "status", "purpose",
		"reason",
	]:
		if data.has(field) and not _bounded_string(data[field], MAX_TEXT_BYTES):
			return false
	for field in ["card_ids", "selected_card_ids"]:
		if data.has(field) and not _bounded_string_array(
			data[field], MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES
		):
			return false
	for field in ["source_indices", "target_indices"]:
		if data.has(field) and not _bounded_integer_array(
			data[field], MAX_DECK_CARDS, -1, MAX_DECK_CARDS
		):
			return false
	if data.has("cards") and not _validate_presentation_cards(data["cards"]):
		return false
	if data.has("results"):
		var results: Variant = data["results"]
		if not results is Array or Array(results).size() > MAX_CHOICE_OPTIONS:
			return false
		for result in results:
			if not result is bool:
				return false
	return true



static func _validate_presentation_cards(value: Variant) -> bool:
	if _bounded_string_array(value, MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES):
		return true
	if not value is Array or Array(value).size() > MAX_DECK_CARDS:
		return false
	for row_value in Array(value):
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if (
			row.size() != 3
			or not _bounded_string(row.get("card_id", ""), MAX_IDENTIFIER_BYTES)
			or not row.get("matched") is bool
			or not _validate_presentation_endpoint(row.get("destination", {}))
		):
			return false
	return true

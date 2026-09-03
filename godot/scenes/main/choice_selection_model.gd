class_name ChoiceSelectionModel
extends RefCounted

const MODE_LOCAL := "local"

var owner: Node
var request: ChoiceView
var state: GameState
var catalog: CardCatalog
var view_player := 0
var selected_ids: Array[String] = []


func bind_owner(p_owner: Node) -> void:
	owner = p_owner
	if owner != null:
		catalog = owner.get("catalog") as CardCatalog


func configure(
	p_request: ChoiceView,
	p_state: GameState,
	p_catalog: CardCatalog,
	p_view_player: int,
) -> void:
	request = p_request
	state = p_state
	catalog = p_catalog
	view_player = p_view_player
	selected_ids.clear()


func clear() -> void:
	selected_ids.clear()


func replace(values: Array[String]) -> void:
	selected_ids.assign(values)


func response(cancelled: bool = false) -> ChoiceResponse:
	if request == null:
		return null
	return ChoiceResponse.new(request.request_id, selected_ids.duplicate(), cancelled)


func toggle(option_id: String, blocked_reason: String = "") -> String:
	if request == null:
		return "当前选择请求已失效"
	var existing := selected_ids.find(option_id)
	if not request.allow_duplicates and existing >= 0:
		selected_ids.remove_at(existing)
		return ""
	if not blocked_reason.is_empty():
		return blocked_reason
	if request.allow_duplicates:
		selected_ids.append(option_id)
	elif request.max_select == 1:
		selected_ids.assign([option_id])
	else:
		selected_ids.append(option_id)
	return ""


func rewind(index: int) -> bool:
	if index < 0 or index >= selected_ids.size():
		return false
	while selected_ids.size() > index:
		selected_ids.pop_back()
	return true


func undo() -> bool:
	if selected_ids.is_empty():
		return false
	selected_ids.pop_back()
	return true

func _choice_distribution_energy_card_id(option: Dictionary) -> String:
	var option_id := str(option.get("option_id", ""))
	if not option_id.begins_with("energy:"):
		return ""
	var index_separator := option_id.find(":", "energy:".length())
	var target_separator := option_id.find("->", index_separator + 1)
	if index_separator < 0 or target_separator <= index_separator + 1:
		return ""
	return option_id.substr(
		index_separator + 1,
		target_separator - index_separator - 1,
	)

func _choice_distribution_energy_index(option: Dictionary) -> int:
	var option_id := str(option.get("option_id", ""))
	if not option_id.begins_with("energy:"):
		return -1
	var index_separator := option_id.find(":", "energy:".length())
	if index_separator < 0:
		return -1
	var index_text := option_id.substr(
		"energy:".length(),
		index_separator - "energy:".length(),
	)
	return index_text.to_int() if index_text.is_valid_int() else -1

func _choice_option_card_id(option: Dictionary) -> String:
	var distribution_energy := _choice_distribution_energy_card_id(option)
	if not distribution_energy.is_empty():
		return distribution_energy
	var ref_variant: Variant = option.get("ref")
	if ref_variant is Dictionary:
		return str(Dictionary(ref_variant).get("card_id", ""))
	return ""

func _choice_option_target_card_id(option: Dictionary) -> String:
	var ref_variant: Variant = option.get("ref")
	if ref_variant is Dictionary:
		return str(Dictionary(ref_variant).get("card_id", ""))
	return ""

func _choice_option_display_card_id(
	option: Dictionary,
	request: ChoiceView = null,
) -> String:
	if request != null and request.request_type == "distribute_energy":
		var target_card_id := _choice_option_target_card_id(option)
		if not target_card_id.is_empty():
			return target_card_id
	return _choice_option_card_id(option)

func _choice_card_ref_key(ref: Dictionary) -> String:
	if (
		str(ref.get("kind", "")) != "card"
		or int(ref.get("player", -1)) not in [0, 1]
		or str(ref.get("zone", "")) != "deck"
		or int(ref.get("index", -1)) < 0
		or str(ref.get("card_id", "")).is_empty()
	):
		return ""
	return "%d|deck|%d|%s" % [
		int(ref.get("player", -1)),
		int(ref.get("index", -1)),
		str(ref.get("card_id", "")),
	]

func _choice_deck_browse_refs(request: ChoiceView) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if request == null:
		return result
	for ref_value in _choice_presentation(request).get("browse_card_refs", []):
		if not ref_value is Dictionary:
			continue
		var ref := Dictionary(ref_value)
		if (
			_choice_card_ref_key(ref).is_empty()
			or int(ref.get("player", -1)) != request.player
		):
			continue
		result.append(ref.duplicate(true))
	return result

func _choice_has_deck_browse(request: ChoiceView) -> bool:
	return not _choice_deck_browse_refs(request).is_empty()

func _choice_browse_category_rank(card_id: String) -> int:
	if catalog == null:
		return 3
	match str(catalog.get_card(card_id).get("supertype", "")):
		"Pokémon":
			return 0
		"Trainer":
			return 1
		"Energy":
			return 2
	return 3

func _choice_deck_browse_rows(request: ChoiceView) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if request == null:
		return rows
	var legal_by_ref: Dictionary = {}
	for option_value in request.options:
		var option := Dictionary(option_value)
		var ref_value: Variant = option.get("ref")
		if not ref_value is Dictionary:
			continue
		var key := _choice_card_ref_key(Dictionary(ref_value))
		if not key.is_empty():
			legal_by_ref[key] = option.duplicate(true)
	for ref in _choice_deck_browse_refs(request):
		var key := _choice_card_ref_key(ref)
		var legal_option: Dictionary = Dictionary(legal_by_ref.get(key, {}))
		var selectable := not legal_option.is_empty()
		var card_id := str(ref.get("card_id", ""))
		var card_name := catalog.card_name(card_id) if catalog != null else card_id
		var caption := (
			_choice_option_caption(legal_option)
			if selectable
			else "%s · 仅查看" % card_name
		)
		rows.append({
			"row_id": "browse:%s" % key,
			"option_id": str(legal_option.get("option_id", "")),
			"card_id": card_id,
			"player": int(ref.get("player", request.player)),
			"index": int(ref.get("index", -1)),
			"selectable": selectable,
			"caption": caption,
		})
	rows.sort_custom(func(left_value: Dictionary, right_value: Dictionary) -> bool:
		var left_selectable := bool(left_value.get("selectable", false))
		var right_selectable := bool(right_value.get("selectable", false))
		if left_selectable != right_selectable:
			return left_selectable
		var left_id := str(left_value.get("card_id", ""))
		var right_id := str(right_value.get("card_id", ""))
		var left_category := _choice_browse_category_rank(left_id)
		var right_category := _choice_browse_category_rank(right_id)
		if left_category != right_category:
			return left_category < right_category
		var left_name := catalog.card_name(left_id) if catalog != null else left_id
		var right_name := catalog.card_name(right_id) if catalog != null else right_id
		var name_order := left_name.naturalnocasecmp_to(right_name)
		if name_order != 0:
			return name_order < 0
		return int(left_value.get("index", -1)) < int(right_value.get("index", -1))
	)
	return rows

func _choice_energy_distribution_view(
	request: ChoiceView,
	presentation_card_ids: Array[String],
) -> Dictionary:
	if request == null or request.request_type != "distribute_energy":
		return {}
	var source_card_ids: Array[String] = []
	source_card_ids.assign(presentation_card_ids)
	var targets_by_key: Dictionary = {}
	var target_order: Array[String] = []
	for option_value in request.options:
		var option := Dictionary(option_value)
		var option_id := str(option.get("option_id", ""))
		var ref_value: Variant = option.get("ref")
		if option_id.is_empty() or not ref_value is Dictionary:
			continue
		var ref := Dictionary(ref_value)
		if str(ref.get("kind", "")) != "pokemon":
			continue
		var player_idx := int(ref.get("player", request.player))
		var slot := str(ref.get("slot", ""))
		if player_idx not in [0, 1] or slot.is_empty() or state == null:
			continue
		var pokemon := state.get_player(player_idx).get_pokemon(slot)
		if pokemon == null:
			continue
		var target_key := "%d:%s" % [player_idx, slot]
		if not targets_by_key.has(target_key):
			var pokemon_name := (
				catalog.card_name(pokemon.card_id)
				if catalog != null
				else pokemon.card_id
			)
			var owner_text := "己方" if player_idx == view_player else "对手"
			targets_by_key[target_key] = {
				"target_key": target_key,
				"player": player_idx,
				"slot": slot,
				"card_id": pokemon.card_id,
				"pokemon": pokemon.clone_state(),
				"name": pokemon_name,
				"location": "%s · %s" % [owner_text, _slot_name(slot)],
				"label": "%s · %s · %s" % [
					owner_text,
					_slot_name(slot),
					pokemon_name,
				],
				"assignment_label": "%s · %s" % [
					_slot_name(slot),
					pokemon_name,
				],
				"option_ids_by_energy_index": {},
				"fallback_option_id": "",
			}
			target_order.append(target_key)
		var model: Dictionary = targets_by_key[target_key]
		var energy_index := _choice_distribution_energy_index(option)
		if energy_index >= 0:
			var source_card_id := _choice_distribution_energy_card_id(option)
			while source_card_ids.size() <= energy_index:
				source_card_ids.append("")
			if source_card_ids[energy_index].is_empty():
				source_card_ids[energy_index] = source_card_id
			var option_ids: Dictionary = model.get(
				"option_ids_by_energy_index", {})
			option_ids[energy_index] = option_id
			model["option_ids_by_energy_index"] = option_ids
		elif str(model.get("fallback_option_id", "")).is_empty():
			model["fallback_option_id"] = option_id
		targets_by_key[target_key] = model
	if target_order.is_empty():
		return {}
	while source_card_ids.size() < request.max_select:
		source_card_ids.append("")
	var targets: Array[Dictionary] = []
	for target_key in target_order:
		targets.append(Dictionary(targets_by_key[target_key]))
	return {
		"card_ids": source_card_ids,
		"targets": targets,
	}

func _choice_option_owner(option: Dictionary, fallback_player: int) -> int:
	var ref_value: Variant = option.get("ref")
	if ref_value is Dictionary:
		return int(Dictionary(ref_value).get("player", fallback_player))
	return fallback_player

func _choice_attachment_ref(option: Dictionary) -> Dictionary:
	var ref_value: Variant = option.get("ref")
	if ref_value is Dictionary:
		var ref := Dictionary(ref_value)
		if (
			str(ref.get("kind", "")) == "attachment"
			or not str(ref.get("attachment_type", "")).is_empty()
		):
			return ref
	return {}

func _choice_option_caption(option: Dictionary) -> String:
	var label_text := str(option.get("label", ""))
	var ref_variant: Variant = option.get("ref")
	var ref_data: Dictionary = {}
	if ref_variant is Dictionary:
		ref_data = ref_variant
	var is_attachment := (
		str(ref_data.get("kind", "")) == "attachment"
		or str(option.get("option_id", "")).begins_with("attachment:")
	)
	if is_attachment:
		var attachment_player := int(ref_data.get(
			"player", request.player if request else view_player))
		var attachment_slot := str(ref_data.get("slot", ""))
		var attachment_index := int(ref_data.get("index", -1))
		var attachment_label := label_text.replace(" - ", " · ")
		if attachment_label.is_empty() and catalog != null:
			attachment_label = catalog.card_name(_choice_option_card_id(option))
		var attachment_parts: Array[String] = []
		attachment_parts.append("己方" if attachment_player == view_player else "对手")
		if not attachment_slot.is_empty():
			attachment_parts.append(_slot_name(attachment_slot))
		if not attachment_label.is_empty():
			attachment_parts.append(attachment_label)
		if attachment_index >= 0:
			attachment_parts.append("第%d张" % (attachment_index + 1))
		if (
			request != null
			and request.request_type == "select_retreat_payment"
		):
			var provided_units := _retreat_payment_option_units(
				request, str(option.get("option_id", "")))
			if provided_units > 0:
				attachment_parts.append("提供%d点" % provided_units)
		return " · ".join(attachment_parts)
	var option_id := str(option.get("option_id", ""))
	if option_id.begins_with("energy:"):
		var energy_id := _choice_distribution_energy_card_id(option)
		if not energy_id.is_empty():
			var energy_name := (
				catalog.card_name(energy_id)
				if catalog != null
				else energy_id
			)
			var target_slot := str(ref_data.get("slot", ""))
			if not target_slot.is_empty():
				return "%s → %s" % [energy_name, _slot_name(target_slot)]
	if option_id.begins_with("rare_candy:"):
		var parts := option_id.split(":")
		if parts.size() >= 2:
			return "%s · %s" % [_slot_name(str(parts[1])), label_text]
	if not ref_data.is_empty():
		var ref: Dictionary = ref_data
		var ref_slot := str(ref.get("slot", ""))
		if not ref_slot.is_empty():
			return _slot_name(ref_slot)
		var zone := str(ref.get("zone", ""))
		if not zone.is_empty():
			var zone_text := _zone_name(zone)
			var index := int(ref.get("index", -1))
			if index >= 0:
				return "%s %d" % [zone_text, index + 1]
			return zone_text
	return label_text

func _choice_field_target_options(request: ChoiceView) -> Dictionary:
	var result: Dictionary = {}
	if request != null and request.request_type == "select_prize":
		for option_value in request.options:
			var option := Dictionary(option_value)
			var option_id := str(option.get("option_id", ""))
			if not option_id.begins_with("prize:"):
				return {}
			var prize_index := int(option_id.trim_prefix("prize:"))
			result["prize:%d:%d" % [request.player, prize_index]] = option_id
		return result
	if request != null and request.request_type == "select_attachment":
		return _choice_attachment_target_groups(request)
	if (
		request == null
		or request.min_select != 1
		or request.max_select != 1
		or request.allow_duplicates
		or request.can_cancel
	):
		return result
	for option in request.options:
		var option_id := str(option.get("option_id", ""))
		var player_idx := request.player
		var slot := ""
		var ref_kind := ""
		var ref_value: Variant = option.get("ref")
		if ref_value is Dictionary:
			var ref := ref_value as Dictionary
			ref_kind = str(ref.get("kind", ""))
			if ref_kind in ["pokemon", "slot"]:
				player_idx = int(ref.get("player", player_idx))
				slot = str(ref.get("slot", ""))
		var target_pokemon := (
			state.get_player(player_idx).get_pokemon(slot)
			if state != null and player_idx in [0, 1] and not slot.is_empty()
			else null
		)
		var target_matches_ref := (
			(ref_kind == "pokemon" and target_pokemon != null)
			or (ref_kind == "slot" and target_pokemon == null)
		)
		if (
			option_id.is_empty()
			or player_idx not in [0, 1]
			or slot.is_empty()
			or state == null
			or not target_matches_ref
		):
			return {}
		var key := BattleInteractionController.pokemon_key(player_idx, slot)
		# Attachment choices may expose several energies on one Pokémon; in that
		# case the card alone is not a unique option, so keep the card grid panel.
		if result.has(key):
			return {}
		result[key] = option_id
	return result

func _choice_attachment_target_groups(request: ChoiceView) -> Dictionary:
	var result: Dictionary = {}
	if request == null or request.options.is_empty() or state == null:
		return result
	var disabled_reasons := _choice_option_disabled_reasons(request)
	for option_value in request.options:
		var option := Dictionary(option_value)
		var option_id := str(option.get("option_id", ""))
		var ref := _choice_attachment_ref(option)
		var player_idx := int(ref.get("player", request.player))
		var slot := str(ref.get("slot", ""))
		if (
			option_id.is_empty()
			or player_idx not in [0, 1]
			or slot.is_empty()
			or state.get_player(player_idx).get_pokemon(slot) == null
		):
			return {}
		var key := BattleInteractionController.pokemon_key(player_idx, slot)
		if not result.has(key):
			result[key] = {
				"kind": "attachment_group",
				"player": player_idx,
				"slot": slot,
				"source_label": _choice_attachment_source_label(player_idx, slot),
				"options": [],
				"selected_ids": selected_ids.duplicate(),
				"disabled_reasons": disabled_reasons.duplicate(true),
				"min_select": request.min_select,
				"max_select": request.max_select,
				"can_cancel": request.can_cancel,
			}
		var group: Dictionary = result[key]
		var group_options: Array = group.get("options", [])
		group_options.append(option.duplicate(true))
		group["options"] = group_options
		result[key] = group
	return result

func _choice_attachment_source_label(player_idx: int, slot: String) -> String:
	var pokemon := state.get_player(player_idx).get_pokemon(slot) if state != null else null
	var owner_text := "己方" if player_idx == view_player else "对手"
	var pokemon_name := (
		catalog.card_name(pokemon.card_id)
		if pokemon != null and catalog != null
		else "宝可梦"
	)
	return "%s · %s · %s" % [owner_text, _slot_name(slot), pokemon_name]

func _choice_field_prompt(request: ChoiceView) -> String:
	if request == null:
		return "请选择目标"
	if request.request_type not in ["select_energy_target", "distribute_energy"]:
		return request.prompt
	var presentation := _choice_presentation(request)
	var source_slot := str(presentation.get("source_slot", ""))
	var source_player := int(presentation.get("source_player", request.player))
	var card_names: Array[String] = []
	for value in presentation.get("card_ids", []):
		var card_name := catalog.card_name(str(value)) if catalog != null else str(value)
		if not card_name.is_empty() and card_name not in card_names:
			card_names.append(card_name)
	if source_slot.is_empty() or card_names.is_empty():
		return request.prompt
	return "从「%s」移动「%s」；请选择目标" % [
		_choice_attachment_source_label(source_player, source_slot),
		"、".join(card_names),
	]

func _choice_energy_cards(request: ChoiceView) -> Array[String]:
	var result: Array[String] = []
	if request == null or request.request_type not in ["distribute_energy", "select_energy_target"]:
		return result
	var presentation := _choice_presentation(request)
	for value in presentation.get("card_ids", []):
		var metadata_card_id := str(value)
		if not metadata_card_id.is_empty():
			result.append(metadata_card_id)
	if result.is_empty():
		for ref_value in presentation.get("attachment_refs", []):
			if not ref_value is Dictionary:
				continue
			var ref_card_id := str(Dictionary(ref_value).get("card_id", ""))
			if not ref_card_id.is_empty():
				result.append(ref_card_id)
	if not result.is_empty():
		return result
	return result

func _choice_revealed_cards(request: ChoiceView) -> Array[String]:
	var result: Array[String] = []
	if request == null:
		return result
	var presentation := _choice_presentation(request)
	for value in presentation.get("revealed_card_ids", []):
		var card_id := str(value)
		if not card_id.is_empty():
			result.append(card_id)
	if result.is_empty():
		var top_card_id := str(presentation.get("top_card_id", ""))
		if not top_card_id.is_empty():
			result.append(top_card_id)
	if (
		result.is_empty()
		and str(presentation.get("purpose", "")) in [
			"switch_confirm",
			"search_any_switch_confirm",
		]
	):
		var source_card_id := str(presentation.get("source_card_id", ""))
		if not source_card_id.is_empty():
			result.append(source_card_id)
	return result

func _choice_option_by_id(request: ChoiceView, option_id: String) -> Dictionary:
	if request == null or option_id.is_empty():
		return {}
	for option_value in request.options:
		var option: Dictionary = option_value
		if str(option.get("option_id", "")) == option_id:
			return option
	return {}

func _choice_presentation(request: ChoiceView = null) -> Dictionary:
	# Production UI consumes only ChoiceView v2. A raw authoritative
	# ChoiceView intentionally carries no presentation contract here.
	var source := request if request != null else request
	if source is ChoiceView:
		return (source as ChoiceView).presentation.duplicate(true)
	return {}

func _choice_has_cancel_action_checkpoint(request: ChoiceView = null) -> bool:
	# Player views deliberately omit the private resolution stack. The request
	# metadata is the authoritative, protocol-safe way to describe whether
	# cancelling rewinds the enclosing card/action.
	if request != null and bool(_choice_presentation(request).get(
		"cancels_action", false)):
		return true
	return false

func _choice_cancel_cta(request: ChoiceView) -> String:
	if request == null or not request.can_cancel:
		return ""
	return "取消使用此卡" if _choice_has_cancel_action_checkpoint(request) else "取消"

func _choice_confirm_cta(request: ChoiceView, selected_count: int) -> String:
	if request == null:
		return "确认选择"
	if request.max_select == 0:
		return (
			"检查完毕并继续"
			if _choice_has_deck_browse(request)
			else "继续结算"
		)
	if request.min_select == 0 and selected_count == 0:
		return "不选择并继续"
	if request.request_type == "select_retreat_payment":
		var required_units := int(_choice_presentation(request).get(
			"required_units", 0))
		var paid_units := _retreat_payment_selected_units(
			request, selected_ids)
		return "确认支付（%d/%d 点）" % [paid_units, required_units]
	if request.request_type in ["confirm", "confirm_trigger"]:
		if selected_count == 1:
			var selected_option := _choice_option_by_id(
				request,
				selected_ids[0] if not selected_ids.is_empty() else "",
			)
			var selected_label: String = _choice_text_option_label(
				selected_option,
				request,
			)
			if not selected_label.is_empty():
				return "确认“%s”" % selected_label
		return "确认决定"
	if request.request_type == "distribute_energy":
		return "确认能量分配（%d/%d）" % [selected_count, request.max_select]
	return "确认选择（%d/%d）" % [selected_count, request.max_select]

func _choice_option_category(option: Dictionary) -> String:
	if option.is_empty() or catalog == null:
		return ""
	var card_id := _choice_option_card_id(option)
	if card_id.is_empty():
		return ""
	if catalog.is_tool(card_id):
		return "tool"
	if catalog.is_item(card_id):
		return "item"
	if catalog.is_pokemon(card_id):
		return "pokemon"
	if catalog.is_basic_energy(card_id):
		return "energy"
	return ""

func _choice_selected_category_count(request: ChoiceView, category: String) -> int:
	var count := 0
	for selected_id in selected_ids:
		if _choice_option_category(_choice_option_by_id(request, selected_id)) == category:
			count += 1
	return count

func _choice_option_target_key(option: Dictionary) -> String:
	var ref_value: Variant = option.get("ref")
	if ref_value is Dictionary:
		var ref := Dictionary(ref_value)
		var slot := str(ref.get("slot", ""))
		if not slot.is_empty():
			return "%d:%s" % [int(ref.get("player", -1)), slot]
	return "option:%s" % str(option.get("option_id", ""))

func _choice_selected_target_count(
	request: ChoiceView,
	target_key: String,
) -> int:
	var count := 0
	for selected_id in selected_ids:
		var selected_option := _choice_option_by_id(request, selected_id)
		if _choice_option_target_key(selected_option) == target_key:
			count += 1
	return count

func _retreat_payment_option_units(
	request: ChoiceView,
	option_id: String,
) -> int:
	if (
		request == null
		or request.request_type != "select_retreat_payment"
		or state == null
		or request.player not in [0, 1]
		or catalog == null
	):
		return 0
	var option := _choice_option_by_id(request, option_id)
	var ref_value: Variant = option.get("ref")
	if not ref_value is Dictionary:
		return 0
	var ref := Dictionary(ref_value)
	var active := state.get_player(request.player).active
	var attachment_index := int(ref.get("index", -1))
	if (
		active == null
		or str(ref.get("kind", "")) != "attachment"
		or str(ref.get("attachment_type", "")) != "energy"
		or int(ref.get("player", -1)) != request.player
		or str(ref.get("slot", "")) != "active"
		or attachment_index < 0
		or attachment_index >= active.energy_card_ids.size()
	):
		return 0
	var card_id := str(active.energy_card_ids[attachment_index])
	var ref_card_id := str(ref.get("card_id", ""))
	if not ref_card_id.is_empty() and ref_card_id != card_id:
		return 0
	return catalog.provides_energy(card_id).size()

func _retreat_payment_selected_units(
	request: ChoiceView,
	selected_ids: Array[String],
) -> int:
	var result := 0
	for option_id in selected_ids:
		result += _retreat_payment_option_units(request, option_id)
	return result

func _retreat_payment_selection_is_minimal(
	request: ChoiceView,
	selected_ids: Array[String],
) -> bool:
	var required_units := int(_choice_presentation(request).get(
		"required_units", 0))
	if required_units <= 0:
		return selected_ids.is_empty()
	var paid_units := _retreat_payment_selected_units(request, selected_ids)
	if paid_units < required_units:
		return false
	for option_id in selected_ids:
		var units := _retreat_payment_option_units(request, option_id)
		if units <= 0 or paid_units - units >= required_units:
			return false
	return true

func _choice_selection_is_complete(
	request: ChoiceView,
	selected_ids: Array[String],
) -> bool:
	if request == null:
		return false
	if (
		selected_ids.size() < request.min_select
		or selected_ids.size() > request.max_select
	):
		return false
	if request.request_type == "select_retreat_payment":
		return _retreat_payment_selection_is_minimal(request, selected_ids)
	return true

func _choice_category_label(category: String) -> String:
	return str({
		"energy": "基本能量",
		"item": "物品",
		"pokemon": "宝可梦",
		"tool": "宝可梦道具",
	}.get(category, category))

func _choice_addition_blocked_reason(request: ChoiceView, option_id: String) -> String:
	var option := _choice_option_by_id(request, option_id)
	if option.is_empty():
		return "该选择项已失效，请重新选择"
	var already_selected := selected_ids.find(option_id) >= 0
	if already_selected and not request.allow_duplicates:
		# Existing exclusive selections must always remain available so they can
		# be removed, even while every unselected option is at capacity.
		return ""
	if not request.allow_duplicates and request.max_select == 1:
		# A radio-style request replaces the old selection atomically. It is not
		# blocked merely because the one available slot is already occupied.
		return ""

	var category := _choice_option_category(option)
	var presentation := _choice_presentation(request)
	if request.request_type == "select_retreat_payment":
		var candidate_units := _retreat_payment_option_units(request, option_id)
		if candidate_units <= 0:
			return "无法读取这张附着能量提供的点数"
		var projected_ids: Array[String] = []
		projected_ids.assign(selected_ids)
		projected_ids.append(option_id)
		var required_units := int(presentation.get("required_units", 0))
		var projected_units := _retreat_payment_selected_units(
			request, projected_ids)
		if (
			required_units > 0
			and projected_units >= required_units
			and not _retreat_payment_selection_is_minimal(
				request, projected_ids)
		):
			return "该组合会多丢弃能量，请先取消不必要的能量"
	var category_limits_value: Variant = presentation.get("category_limits", {})
	var category_limits := (
		Dictionary(category_limits_value)
		if category_limits_value is Dictionary
		else {}
	)
	if category_limits.has(category):
		var category_limit := maxi(0, int(category_limits.get(category, 0)))
		if _choice_selected_category_count(request, category) >= category_limit:
			return "%s最多选择%d张，请先取消一张" % [
				_choice_category_label(category),
				category_limit,
			]
	elif request.request_type == "arven" and category_limits.is_empty():
		if category == "item" and _choice_selected_category_count(request, "item") >= 1:
			return "物品和宝可梦道具各最多选择1张，请先取消已选物品卡"
		if category == "tool" and _choice_selected_category_count(request, "tool") >= 1:
			return "物品和宝可梦道具各最多选择1张，请先取消已选宝可梦道具"
	elif request.request_type == "clara" and category_limits.is_empty():
		var pokemon_limit := int(presentation.get(
			"pokemon_count", request.max_select))
		var energy_limit := int(presentation.get(
			"energy_count", request.max_select))
		if (
			category == "pokemon"
			and _choice_selected_category_count(request, "pokemon") >= pokemon_limit
		):
			return "宝可梦最多选择%d张，请先取消一张宝可梦" % pokemon_limit
		if (
			category == "energy"
			and _choice_selected_category_count(request, "energy") >= energy_limit
		):
			return "基本能量最多选择%d张，请先取消一张基本能量" % energy_limit
	elif request.request_type == "distribute_energy":
		var target_key := _choice_option_target_key(option)
		if (
			bool(presentation.get("same_target", false))
			and not selected_ids.is_empty()
			and target_key != _choice_option_target_key(
				_choice_option_by_id(request, selected_ids[0]),
			)
		):
			return "此效果要求所有能量分配到同一目标"
		var max_per_target := int(presentation.get("max_per_target", 99))
		if _choice_selected_target_count(request, target_key) >= max_per_target:
			return "该目标最多可分配 %d张能量" % max_per_target
	elif request.request_type == "select_attachment":
		var same_source := bool(presentation.get("same_source", false))
		if same_source and not selected_ids.is_empty():
			var candidate_ref := _choice_attachment_ref(option)
			var selected_ref := _choice_attachment_ref(
				_choice_option_by_id(request, selected_ids[0]),
			)
			if (
				int(candidate_ref.get("player", -1))
				!= int(selected_ref.get("player", -1))
				or str(candidate_ref.get("slot", ""))
				!= str(selected_ref.get("slot", ""))
			):
				return "此效果要求所选能量来自同一只宝可梦"

	if selected_ids.size() >= request.max_select:
		return "已达到选择上限，请先取消一张"
	return ""

func _choice_option_disabled_reasons(request: ChoiceView) -> Dictionary:
	var reasons: Dictionary = {}
	if request == null:
		return reasons
	for option_value in request.options:
		var option: Dictionary = option_value
		var option_id := str(option.get("option_id", ""))
		if option_id.is_empty():
			continue
		var reason := _choice_addition_blocked_reason(request, option_id)
		if not reason.is_empty():
			reasons[option_id] = reason
	return reasons


func _slot_name(slot: String) -> String:
	if slot == "active":
		return "战斗区"
	if slot.begins_with("bench_"):
		return "备战区 %d" % (slot.trim_prefix("bench_").to_int() + 1)
	return slot


func _zone_name(zone: String) -> String:
	return {
		"hand": "手牌",
		"deck": "牌库",
		"discard": "弃牌区",
		"prizes": "奖赏卡区",
		"lost_zone": "放逐区",
	}.get(zone, zone)


func _retreat_confirmation_lines(action: GameAction) -> Array[String]:
	var actor: int = action.actor if action.actor != null else owner._current_actor()
	var current_state := _current_state()
	if current_state == null or actor not in [0, 1]:
		return []
	var player := current_state.get_player(actor)
	var bench_idx := action.bench_index()
	var target_name := "备战宝可梦"
	if bench_idx >= 0 and bench_idx < player.bench.size() and player.bench[bench_idx]:
		target_name = catalog.card_name(player.bench[bench_idx].card_id)
	var energy_names := _retreat_energy_names(action)
	var active_name := catalog.card_name(player.active.card_id) if player.active else "战斗宝可梦"
	var cost_text := ""
	if not energy_names.is_empty():
		cost_text = "将丢弃：%s" % "、".join(energy_names)
	elif _retreat_explicitly_requires_no_energy(action):
		cost_text = "无需丢弃能量"
	else:
		var printed_cost := _retreat_printed_cost(action)
		cost_text = (
			"卡面撤退费用：%d 点。确认后按当前效果结算；如需支付，下一步选择要丢弃的附着能量。"
			% printed_cost
			if printed_cost > 0
			else "确认后按当前效果结算撤退费用；如需支付，下一步选择要丢弃的附着能量。"
		)
	return [
		"%s 将撤退，%s 将进入战斗区。" % [active_name, target_name],
		cost_text,
	]

func _retreat_energy_names(action: GameAction) -> Array[String]:
	var result: Array[String] = []
	var actor: int = action.actor if action.actor != null else owner._current_actor()
	var current_state := _current_state()
	if current_state == null or actor not in [0, 1]:
		return result
	var active := current_state.get_player(actor).active
	if active == null:
		return result
	for raw_index in action.payload.get("energy_indices", []):
		var index := int(raw_index)
		if index >= 0 and index < active.energy_card_ids.size():
			result.append(catalog.card_name(str(active.energy_card_ids[index])))
	return result

func _retreat_explicitly_requires_no_energy(action: GameAction) -> bool:
	if action == null or not action.payload.has("energy_indices"):
		return false
	var indices: Variant = action.payload.get("energy_indices")
	return indices is Array and Array(indices).is_empty()

func _retreat_printed_cost(action: GameAction) -> int:
	var actor: int = action.actor if action.actor != null else owner._current_actor()
	var current_state := _current_state()
	if current_state == null or actor not in [0, 1]:
		return -1
	var active := current_state.get_player(actor).active
	if active == null:
		return -1
	return maxi(0, int(catalog.get_card(active.card_id).get("retreat_cost", 0)))

func _retreat_energy_suffix(action: GameAction) -> String:
	var names := _retreat_energy_names(action)
	if not names.is_empty():
		return "（丢弃：%s）" % "、".join(names)
	if _retreat_explicitly_requires_no_energy(action):
		return "（无需丢弃能量）"
	var printed_cost := _retreat_printed_cost(action)
	return (
		"（撤退费 %d，确认后结算）" % printed_cost
		if printed_cost > 0
		else "（确认后结算撤退费用）"
	)

func _action_label(action: GameAction) -> String:
	var current_state := _current_state()
	match action.kind:
		"PLAY_BASIC":
			return "上场 · %s → %s" % [
				_source_card_name(action), owner._slot_name(str(action.target_slot()))]
		"EVOLVE":
			return "进化 · %s → %s" % [
				_source_card_name(action), owner._slot_name(str(action.primary_slot()))]
		"ATTACH_ENERGY":
			return "附能 · %s → %s" % [
				_source_card_name(action), owner._slot_name(str(action.target_slot()))]
		"PLAY_TRAINER":
			var target := str(action.target_slot())
			return "使用 · %s%s" % [
				_source_card_name(action),
				" → %s" % owner._slot_name(target) if not target.is_empty() else "",
			]
		"USE_ABILITY":
			return "特性 · %s · %s" % [
				action.ability_name(),
				owner._slot_name(str(action.primary_slot())),
			]
		"USE_STADIUM":
			return "发动竞技场"
		"RETREAT":
			return "撤退 → 备战区 %d%s" % [
				action.bench_index(0) + 1,
				_retreat_energy_suffix(action),
			]
		"DECLARE_ATTACK":
			var active := current_state.get_player(action.actor).active if current_state else null
			var attacks: Array = catalog.get_card(active.card_id).get("attacks", []) if active else []
			var attack_idx := action.attack_index(0)
			var attack_name := "招式 %d" % (attack_idx + 1)
			if attack_idx >= 0 and attack_idx < attacks.size():
				attack_name = str(attacks[attack_idx].get("name", attack_name))
			return "攻击 · %s" % attack_name
		"END_TURN":
			return "结束回合"
		"SETUP_DONE":
			return "完成准备"
		"PROMOTE":
			return "晋升 · 备战区 %d" % (action.bench_index(0) + 1)
		_:
			return action.kind

func _source_card_name(action: GameAction) -> String:
	if action.source:
		return catalog.card_name(action.source.card_id)
	var hand_idx := action.hand_index()
	var current_state := _current_state()
	if current_state == null or action.actor not in [0, 1]:
		return "卡牌"
	var player := current_state.get_player(action.actor)
	if hand_idx >= 0 and hand_idx < player.hand.size():
		return catalog.card_name(player.hand[hand_idx])
	return "卡牌"


func _current_state() -> GameState:
	if owner:
		var owner_state := owner.get("state") as GameState
		if owner_state:
			return owner_state
	return state

func _choice_title(request: ChoiceView) -> String:
	var presentation := _choice_presentation(request)
	var purpose := str(presentation.get("purpose", ""))
	if purpose == "trekking_shoes":
		return "健行鞋"
	if purpose in ["switch_confirm", "search_any_switch_confirm"]:
		return "确认换位"
	if purpose == "confirm_exp_share_trigger":
		return "学习装置"
	if purpose == "exp_share_order":
		return "选择学习装置结算顺序"
	if purpose == "treasure_energy_target":
		return "宝藏能量"
	if purpose in ["discard_hand_then_draw", "discard_cards", "zinnia"]:
		return "选择要弃置的手牌"
	if purpose in ["discard_energy", "discard_energy_attachments", "discard_attachment"]:
		return "选择要弃置的附着能量"
	if purpose in ["energy_relocate_attachments", "relocate_energy_attachments"]:
		return "选择要转附的能量"
	if purpose in ["energy_relocate_target", "relocate_energy_target"]:
		return "选择能量转附目标"
	return {
		"coin_flip": "硬币结算",
		"choose_turn_order": "选择先后攻",
		"choose_mulligan_draw_count": "选择再战奖励抽牌数",
		"select_prize": "选择奖赏卡",
		"choose_trigger_order": "选择效果结算顺序",
		"confirm_trigger": "确认是否使用效果",
		"confirm": "确认操作",
		"discard_cards": "选择要丢弃的卡",
		"discard_then_draw": "丢弃手牌后抽牌",
		"zinnia": "选择要丢弃的手牌",
		"houb": "选择放回牌库底的卡",
		"hand_bottom_draw": "整理手牌",
		"search_move": "搜寻卡牌",
		"arven": "搜寻物品与宝可梦道具",
		"look_top": "查看牌库顶",
		"look_top_attach_energy": "选择基本能量",
		"clara": "从弃牌区回收卡牌",
		"shuffle_from_discard": "将卡牌洗回牌库",
		"distribute_energy": "分配能量",
		"select_energy_target": "选择附能目标",
		"select_energy_source": "选择能量来源",
		"select_own_bench_energy": "选择能量附着目标",
		"select_prize_energy_target": "选择宝藏能量附着目标",
		"select_attachment": "选择附着能量",
		"select_retreat_payment": "支付撤退费用",
		"evolve_skip_stage": "选择进化目标",
		"select_heal_target": "选择回复目标",
		"damage_target": "选择伤害目标",
		"bench_damage_target": "选择备战区伤害目标",
		"place_counters_self_discard": "选择伤害指示物目标",
		"select_bench": "选择替换上场的宝可梦",
		"select_bench_slot": "选择备战席",
		"select_opponent_bench": "选择对手替换上场的宝可梦",
	}.get(
		request.request_type,
		"选择卡牌" if _choice_view_has_card_options(request) else "选择",
	)

func _choice_prompt_text(request: ChoiceView) -> String:
	if request == null:
		return "请选择。"
	var purpose := str(_choice_presentation(request).get("purpose", ""))
	if purpose == "trekking_shoes":
		var prompt := request.prompt.strip_edges()
		if prompt.is_empty() or prompt == "请选择。":
			return "查看了牌库顶的卡牌。请选择处理方式。"
	if request.prompt.strip_edges() in ["", "请选择。"]:
		return {
			"switch_confirm": "是否将这只宝可梦与备战宝可梦互换？",
			"search_any_switch_confirm": "是否将这只宝可梦与备战宝可梦互换？",
			"confirm_exp_share_trigger": "是否发动学习装置，将基本能量转附到备战宝可梦？",
			"exp_share_order": "请选择先发动哪只备战宝可梦的学习装置。",
			"treasure_energy_target": "请选择宝藏能量的附着目标，或不发动效果。",
		}.get(purpose, "请选择要执行的操作。")
	return request.prompt

func _choice_text_option_label(option: Dictionary, request: ChoiceView) -> String:
	var option_id := str(option.get("option_id", ""))
	if (
		request != null
		and str(_choice_presentation(request).get("purpose", ""))
		== "trekking_shoes"
	):
		if option_id == "confirm:yes":
			return "将这张卡牌加入手牌"
		if option_id == "confirm:no":
			return "丢弃这张卡牌，再抽1张卡牌"
	var purpose := (
		str(_choice_presentation(request).get("purpose", ""))
		if request != null
		else ""
	)
	if purpose in ["switch_confirm", "search_any_switch_confirm"]:
		if option_id == "confirm:yes":
			return "进行换位"
		if option_id == "confirm:no":
			return "不进行换位"
	if purpose == "confirm_exp_share_trigger":
		if option_id == "confirm:yes":
			return "发动学习装置"
		if option_id == "confirm:no":
			return "不发动"
	var label := str(option.get("label", "")).strip_edges()
	if label.begins_with("option "):
		if option_id.begins_with("trigger:"):
			return "效果 %d" % (int(option_id.trim_prefix("trigger:")) + 1)
		if option_id == "confirm:yes":
			return (
				"发动效果"
				if request != null and request.request_type == "confirm_trigger"
				else "是"
			)
		if option_id == "confirm:no":
			return (
				"不发动"
				if request != null and request.request_type == "confirm_trigger"
				else "否"
			)
		return label.replace("option ", "选项 ")
	return label if not label.is_empty() else option_id

func _choice_metadata_text(request: ChoiceView) -> String:
	var presentation := _choice_presentation(request)
	if request.max_select == 0 and _choice_has_deck_browse(request):
		return "牌库中没有符合条件的卡牌；你仍可检查全部剩余牌库，然后继续结算。"
	if str(presentation.get("purpose", "")) == "trekking_shoes":
		# The prompt, revealed-card preview and live selection hint already carry
		# the full decision. Repeating "请选择 1 项" here adds no information.
		return ""
	if request.request_type == "coin_flip":
		var results: Array = presentation.get("predetermined_flips", [])
		var labels: Array[String] = []
		for result in results:
			labels.append("正面" if bool(result) else "反面")
		return "结果：" + "、".join(labels)
	if request.request_type == "select_retreat_payment":
		var required_units := int(presentation.get("required_units", 0))
		return (
			"需要支付 %d 点撤退费用。请选择要丢弃的附着能量；特殊能量按实际提供点数计算，界面不会允许多丢弃。"
			% required_units
		)
	if request.max_select == 0:
		return "本次无需选择，点击继续结算。"
	if request.request_type == "distribute_energy":
		var distribution_lines: Array[String] = []
		if request.min_select == request.max_select:
			distribution_lines.append("需要分配 %d 张能量。" % request.max_select)
		elif request.min_select == 0:
			distribution_lines.append(
				"最多可分配 %d 张能量，也可以不分配。" % request.max_select
			)
		else:
			distribution_lines.append("请分配 %d 至 %d 张能量。" % [
				request.min_select,
				request.max_select,
			])
		if bool(presentation.get("same_target", false)):
			distribution_lines.append("所有能量必须分配到同一目标。")
		var max_per_target := int(presentation.get("max_per_target", 99))
		if max_per_target < 99:
			distribution_lines.append(
				"每个目标最多可分配 %d 张能量。" % max_per_target
			)
		return " ".join(distribution_lines)
	if request.max_select == 1 and request.min_select in [0, 1]:
		return ""
	var unit := _choice_count_unit(request)
	if request.min_select == request.max_select:
		return "请选择 %d %s。" % [request.max_select, unit]
	if request.min_select == 0:
		return "最多选择 %d %s，也可以不选择。" % [request.max_select, unit]
	return "请选择 %d 至 %d %s。" % [
		request.min_select,
		request.max_select,
		unit,
	]

func _choice_view_has_card_options(request: ChoiceView) -> bool:
	if request == null:
		return false
	if _choice_has_deck_browse(request):
		return true
	for option_value in request.options:
		if not _choice_option_card_id(Dictionary(option_value)).is_empty():
			return true
	return false

func _choice_count_unit(request: ChoiceView) -> String:
	if request.request_type == "select_prize":
		return "张奖赏卡"
	if request.request_type == "select_attachment":
		return "个附着物"
	if request.request_type in [
		"distribute_energy",
		"select_energy_target",
		"select_energy_source",
		"select_own_bench_energy",
		"select_prize_energy_target",
		"evolve_skip_stage",
		"select_heal_target",
		"damage_target",
		"bench_damage_target",
		"place_counters_self_discard",
		"select_bench",
		"select_bench_slot",
		"select_opponent_bench",
	]:
		return "个目标"
	return "张卡牌" if _choice_view_has_card_options(request) else "项"


func _build_local_handoff_plan(
	raw_events: Array,
	previous_active: int,
	previous_phase: String = "",
) -> Dictionary:
	var opening_turn_after_setup: bool = (
		previous_phase == "SETUP"
		and owner.state != null
		and owner.state.phase == "MAIN"
	)
	if (
		owner.game_mode != MODE_LOCAL
		or owner.state == null
		or owner.state.is_terminal()
	):
		return {}
	var incoming_player: int = owner.state.active_player_idx
	var presents_incoming_turn := false
	for event_value in raw_events:
		if not event_value is Dictionary:
			continue
		var event: Dictionary = event_value
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if event_type == "turn_start" and actor == incoming_player:
			presents_incoming_turn = true
			break
	var returning_view_to_incoming: bool = (
		presents_incoming_turn
		and owner.current_view_player != incoming_player
	)
	if (
		owner.state.active_player_idx == previous_active
		and not opening_turn_after_setup
		and not returning_view_to_incoming
	):
		return {}
	var events: Array[Dictionary] = []
	for index in range(raw_events.size()):
		if not raw_events[index] is Dictionary:
			continue
		var event: Dictionary = Dictionary(raw_events[index]).duplicate(true)
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		if str(event.get("event_id", "")).is_empty():
			event["event_id"] = "presentation:%d:%d:%s" % [
				owner.state.revision,
				index,
				event_type,
			]
		events.append(event)
	events = PresentationEvent.order_for_presentation(events)
	var boundary := -1
	for index in range(events.size()):
		var event: Dictionary = events[index]
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if actor == incoming_player and event_type == "turn_start":
			boundary = index
			break
	if boundary < 0:
		for index in range(events.size()):
			var event: Dictionary = events[index]
			var event_type := PresentationEvent.canonical_event_type(
				str(event.get("event_type", "")),
			)
			var data: Dictionary = event.get("data", {})
			var actor := int(event.get("actor", data.get("player", -1)))
			if actor == incoming_player and event_type == "cards_drawn":
				boundary = index
				break
	if boundary < 0:
		return {}
	var prefix_events: Array[Dictionary] = []
	var suffix_events: Array[Dictionary] = []
	for index in range(events.size()):
		if index < boundary:
			prefix_events.append(events[index])
		else:
			suffix_events.append(events[index])
	var pre_draw_state := _state_before_handoff_draw(suffix_events, incoming_player)
	if pre_draw_state == null:
		return {}
	var outgoing_view := BattleViewModel.capture_player_view(
		pre_draw_state,
		owner.current_view_player,
		[],
		"",
		owner.ai_thinking,
		owner.game_mode,
	)
	var incoming_view := BattleViewModel.capture_player_view(
		pre_draw_state,
		incoming_player,
		[],
		"",
		owner.ai_thinking,
		owner.game_mode,
	)
	return {
		"incoming_player": incoming_player,
		"prefix_events": prefix_events,
		"suffix_events": suffix_events,
		"outgoing_view": outgoing_view,
		"incoming_view": incoming_view,
	}

func _state_before_handoff_draw(
	suffix_events: Array[Dictionary],
	incoming_player: int,
) -> GameState:
	if owner.state == null or incoming_player not in [0, 1]:
		return null
	var result: GameState = owner.state.clone_state()
	var player: PlayerState = result.get_player(incoming_player)
	for event_index in range(suffix_events.size() - 1, -1, -1):
		var event: Dictionary = suffix_events[event_index]
		if PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		) != "cards_drawn":
			continue
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if actor != incoming_player:
			continue
		var raw_card_ids: Variant = data.get("card_ids", data.get("cards", []))
		var card_ids: Array[String] = []
		if raw_card_ids is Array:
			for value in raw_card_ids:
				card_ids.append(str(value))
		var amount := maxi(0, int(event.get(
			"amount",
			data.get("count", card_ids.size()),
		)))
		for offset in range(amount):
			var expected_id := (
				card_ids[card_ids.size() - 1 - offset]
				if offset < card_ids.size()
				else ""
			)
			var restored_id := _pop_last_matching_card(player.hand, expected_id)
			if not restored_id.is_empty():
				player.deck.append(restored_id)
	result.phase = "DRAW"
	if (
		not result.action_log.is_empty()
		and str(result.action_log[-1]).begins_with("—— ")
	):
		result.action_log.pop_back()
	return result

func _pop_last_matching_card(cards: Array[String], card_id: String) -> String:
	if cards.is_empty():
		return ""
	if card_id.is_empty() or cards[-1] == card_id:
		return cards.pop_back()
	for index in range(cards.size() - 1, -1, -1):
		if cards[index] == card_id:
			return cards.pop_at(index)
	return cards.pop_back()

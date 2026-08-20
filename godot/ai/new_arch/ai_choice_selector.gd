class_name AIChoiceSelector
extends RefCounted

## Shared, rules-shaped choice cardinality policy for every traditional-AI path.
##
## Scoring stays with the caller. This class only converts a ranked option list
## into a response that respects the public ChoiceView's cardinality contract.


static func select_ranked_option_ids(
	request: ChoiceView,
	ranked_indices: Array,
	desired_count: int,
	catalog: CardCatalog = null,
) -> Array[String]:
	var selected: Array[String] = []
	if request == null or request.options.is_empty():
		return selected
	var minimum := maxi(0, request.min_select)
	var maximum := maxi(0, request.max_select)
	var target_count := clampi(maxi(minimum, desired_count), 0, maximum)
	if target_count <= 0:
		return selected
	var ranked := _valid_ranked_indices(request, ranked_indices)
	if ranked.is_empty():
		return selected
	var max_per_target := maxi(
		0, int(request.presentation.get("max_per_target", 2147483647)))
	var per_target: Dictionary = {}
	var per_category: Dictionary = {}
	var category_limits := _category_limits(request)
	var same_target := bool(request.presentation.get("same_target", false))
	var selected_target := ""
	var used_option_ids: Dictionary = {}
	if not request.allow_duplicates:
		for index in ranked:
			if selected.size() >= target_count:
				break
			var option: Dictionary = request.options[index]
			var option_id := str(option.get("option_id", ""))
			if option_id.is_empty() or used_option_ids.has(option_id):
				continue
			var target_key := _target_key(option)
			if same_target and not selected_target.is_empty() and target_key != selected_target:
				continue
			if int(per_target.get(target_key, 0)) >= max_per_target:
				continue
			var category := _category_key(option, catalog)
			if _category_is_full(category, per_category, category_limits):
				continue
			selected.append(option_id)
			if selected_target.is_empty():
				selected_target = target_key
			used_option_ids[option_id] = true
			per_target[target_key] = int(per_target.get(target_key, 0)) + 1
			if not category.is_empty():
				per_category[category] = int(per_category.get(category, 0)) + 1
		return selected

	# Repeated selections always re-run the same target-capacity check. If the
	# ranked set has insufficient capacity, return the largest legal prefix; do
	# not fill the response by bypassing max_per_target.
	while selected.size() < target_count:
		var appended := false
		for index in ranked:
			var option: Dictionary = request.options[index]
			var option_id := str(option.get("option_id", ""))
			if option_id.is_empty():
				continue
			var target_key := _target_key(option)
			if same_target and not selected_target.is_empty() and target_key != selected_target:
				continue
			if int(per_target.get(target_key, 0)) >= max_per_target:
				continue
			var category := _category_key(option, catalog)
			if _category_is_full(category, per_category, category_limits):
				continue
			selected.append(option_id)
			if selected_target.is_empty():
				selected_target = target_key
			per_target[target_key] = int(per_target.get(target_key, 0)) + 1
			if not category.is_empty():
				per_category[category] = int(per_category.get(category, 0)) + 1
			appended = true
			break
		if not appended:
			break
	return selected


static func response_from_ranked_scores(
	request: ChoiceView,
	ranked_rows: Array,
	catalog: CardCatalog = null,
) -> ChoiceResponse:
	if request == null:
		return ChoiceResponse.new("", [], false)
	var ranked_indices: Array[int] = []
	var positive_indices: Array[int] = []
	for row_value in ranked_rows:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var index := int(row.get("index", -1))
		if index < 0 or index >= request.options.size():
			continue
		ranked_indices.append(index)
		if float(row.get("score", 0.0)) > 0.0:
			positive_indices.append(index)
	var minimum := maxi(0, request.min_select)
	var maximum := maxi(0, request.max_select)
	if not request.allow_duplicates:
		maximum = mini(maximum, request.options.size())
	if minimum <= 0:
		if positive_indices.is_empty():
			return ChoiceResponse.new(request.request_id, [], request.can_cancel)
		var optional_count := maximum if request.allow_duplicates else positive_indices.size()
		return ChoiceResponse.new(
			request.request_id,
			select_ranked_option_ids(
				request, positive_indices, optional_count, catalog),
			false,
		)
	return ChoiceResponse.new(
		request.request_id,
		select_ranked_option_ids(request, ranked_indices, maximum, catalog),
		false,
	)


static func response_is_shape_legal(
	request: ChoiceView,
	option_ids: Array[String],
	catalog: CardCatalog = null,
	cancelled: bool = false,
) -> bool:
	if request == null:
		return false
	if cancelled:
		return request.can_cancel and option_ids.is_empty()
	var minimum := maxi(0, request.min_select)
	var maximum := maxi(0, request.max_select)
	if option_ids.size() < minimum or option_ids.size() > maximum:
		return false
	var options_by_id: Dictionary = {}
	for option_value in request.options:
		var option: Dictionary = option_value
		var option_id := str(option.get("option_id", ""))
		if not option_id.is_empty() and not options_by_id.has(option_id):
			options_by_id[option_id] = option
	var used_option_ids: Dictionary = {}
	var per_target: Dictionary = {}
	var per_category: Dictionary = {}
	var category_limits := _category_limits(request)
	var same_target := bool(request.presentation.get("same_target", false))
	var selected_target := ""
	var max_per_target := maxi(
		0, int(request.presentation.get("max_per_target", 2147483647)))
	for option_id in option_ids:
		if not options_by_id.has(option_id):
			return false
		if not request.allow_duplicates and used_option_ids.has(option_id):
			return false
		used_option_ids[option_id] = true
		var target_key := _target_key(options_by_id[option_id])
		if same_target and not selected_target.is_empty() and target_key != selected_target:
			return false
		if selected_target.is_empty():
			selected_target = target_key
		var count := int(per_target.get(target_key, 0)) + 1
		if count > max_per_target:
			return false
		per_target[target_key] = count
		var category := _category_key(options_by_id[option_id], catalog)
		if _category_is_full(category, per_category, category_limits):
			return false
		if not category.is_empty():
			per_category[category] = int(per_category.get(category, 0)) + 1
	return true


static func _valid_ranked_indices(request: ChoiceView, values: Array) -> Array[int]:
	var result: Array[int] = []
	var seen: Dictionary = {}
	for value in values:
		var index := int(value)
		if index < 0 or index >= request.options.size() or seen.has(index):
			continue
		seen[index] = true
		result.append(index)
	return result


static func _target_key(option: Dictionary) -> String:
	var player := -1
	var slot := ""
	var ref_value: Variant = option.get("ref")
	if ref_value is Dictionary:
		var ref: Dictionary = ref_value
		player = int(ref.get("player", -1))
		slot = str(ref.get("slot", ""))
	if slot.is_empty():
		# ChoiceView deliberately strips private `value` payloads. Public target
		# choices without an EntityRef still use their option id as a stable target.
		return "option:%s" % str(option.get("option_id", ""))
	return "%d:%s" % [player, slot]


static func _category_limits(request: ChoiceView) -> Dictionary:
	var result: Dictionary = {}
	var explicit: Variant = request.presentation.get("category_limits", {})
	if explicit is Dictionary:
		for key_value in Dictionary(explicit):
			result[str(key_value)] = maxi(0, int(Dictionary(explicit)[key_value]))
	for category in ["pokemon", "energy"]:
		var field := "%s_count" % category
		if request.presentation.get(field) is int:
			result[category] = maxi(0, int(request.presentation[field]))
	return result


static func _category_key(option: Dictionary, catalog: CardCatalog) -> String:
	if catalog == null:
		return ""
	var ref_value: Variant = option.get("ref")
	if not ref_value is Dictionary:
		return ""
	var card_id := str(Dictionary(ref_value).get("card_id", ""))
	if card_id.is_empty():
		return ""
	if catalog.is_pokemon(card_id):
		return "pokemon"
	if catalog.is_basic_energy(card_id) or catalog.is_energy(card_id):
		return "energy"
	if catalog.is_item(card_id):
		return "item"
	if catalog.is_tool(card_id):
		return "tool"
	if catalog.is_trainer(card_id):
		return "trainer"
	return ""


static func _category_is_full(
	category: String,
	counts: Dictionary,
	limits: Dictionary,
) -> bool:
	return (
		not category.is_empty()
		and limits.has(category)
		and int(counts.get(category, 0)) >= int(limits[category])
	)

class_name EnergyView
extends RefCounted

static func units_for_cards(card_ids: Array[String], catalog: CardCatalog) -> Array[String]:
	var result: Array[String] = []
	for card_index in range(card_ids.size()):
		result.append_array(units_for_card_at(card_ids, card_index, catalog))
	return result


static func units_for_card_at(
	card_ids: Array[String],
	card_index: int,
	catalog: CardCatalog,
) -> Array[String]:
	if card_index < 0 or card_index >= card_ids.size():
		return []
	var card_id := card_ids[card_index]
	var provided: Array[String] = []
	provided.assign(catalog.provides_energy(card_id))
	var downgrade_if_other_special := false
	for effect_value in catalog.get_card(card_id).get("energy_effects", []):
		var effect: Dictionary = effect_value
		if (
			str(effect.get("kind", "")) == "provide_energy"
			and bool(effect.get("downgrade_if_other_special", false))
		):
			downgrade_if_other_special = true
			break
	if not downgrade_if_other_special:
		return provided
	# Data-defined wildcard providers can downgrade when another Special Energy
	# is attached. Compare attachment positions so duplicate physical cards are
	# handled independently.
	for other_index in range(card_ids.size()):
		if other_index == card_index:
			continue
		if catalog.is_special_energy(card_ids[other_index]):
			var downgraded: Array[String] = []
			for energy_type in provided:
				downgraded.append("Colorless" if energy_type == "Rainbow" else energy_type)
			return downgraded
	return provided


static func can_pay_cost(
	card_ids: Array[String],
	cost: Array,
	catalog: CardCatalog,
) -> bool:
	var available := units_for_cards(card_ids, catalog)
	for required_value in cost:
		var required := str(required_value)
		if required == "Colorless":
			continue
		var index := available.find(required)
		if index < 0:
			index = available.find("Rainbow")
		if index < 0:
			return false
		available.remove_at(index)
	var colorless_count := 0
	for required_value in cost:
		if str(required_value) == "Colorless":
			colorless_count += 1
	return available.size() >= colorless_count


static func units_provided_by_card(
	card_ids: Array[String],
	card_index: int,
	catalog: CardCatalog,
) -> int:
	if card_index < 0 or card_index >= card_ids.size():
		return 0
	return units_for_card_at(card_ids, card_index, catalog).size()

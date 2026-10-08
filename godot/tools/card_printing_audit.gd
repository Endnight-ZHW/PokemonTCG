extends RefCounted
## Compare authored/display fields with the pinned printing transcription.
## Mechanical base damage is deliberately independent of printed damage_text.

const ENERGY_TYPES := {
	"1": "Grass", "2": "Fire", "3": "Water", "4": "Lightning", "5": "Psychic",
	"6": "Fighting", "7": "Darkness", "8": "Metal", "9": "Fairy", "10": "Dragon",
	"11": "Colorless",
}
const TRAINER_TYPES := {"1": "Item", "2": "Supporter", "3": "Stadium", "4": "Tool"}
const SUPERTYPES := {"1": "Pokémon", "2": "Trainer", "3": "Energy"}
const STAGES := {"基础": "Basic", "1阶进化": "Stage 1", "2阶进化": "Stage 2"}


static func printed_text(value: Variant) -> String:
	var text := str(value) if value != null else ""
	if text == "none":
		return ""
	text = text.replace("【无】", "无色").replace("【", "").replace("】", "")
	for token in ["[", "(", "［"]:
		text = text.replace(token, "（")
	for token in ["]", ")", "］"]:
		text = text.replace(token, "）")
	return text.replace("\r", "").strip_edges()


static func rule_paragraphs(value: Variant) -> Array[String]:
	var rows: Array[String] = []
	for row in printed_text(value).replace("|", "\n").split("\n", false):
		if not row.strip_edges().is_empty():
			rows.append(row.strip_edges())
	return rows


static func mismatches(card: Dictionary, row: Dictionary, overrides: Dictionary = {}) -> Array[String]:
	var errors: Array[String] = []
	var source: Dictionary = row["details"]
	_compare(errors, "name", card.get("name"), row.get("name"))
	_compare(errors, "supertype", card.get("supertype"), SUPERTYPES.get(str(source.get("cardType", "")), "unknown"))
	_compare(errors, "hp", int(card.get("hp", 0)), int(source.get("hp", 0)))
	var attacks: Array = card.get("attacks", [])
	var source_attacks: Array = source.get("abilityItemList", [])
	_compare(errors, "attacks.count", attacks.size(), source_attacks.size())
	for index in mini(attacks.size(), source_attacks.size()):
		var attack: Dictionary = attacks[index]
		var source_attack: Dictionary = source_attacks[index]
		var prefix := "attacks.%d." % index
		var cost: Array = []
		for type_id in str(source_attack.get("abilityCost", "")).split(",", false):
			cost.append(ENERGY_TYPES.get(type_id, "unknown"))
		cost.sort()
		var authored_cost: Array = Array(attack.get("cost", [])).duplicate()
		authored_cost.sort()
		_compare(errors, prefix + "cost", authored_cost, cost)
		_compare(errors, prefix + "name", attack.get("name", ""), source_attack.get("abilityName", ""))
		_compare(errors, prefix + "damage_text", attack.get("damage_text"), printed_text(source_attack.get("abilityDamage", "")))
		_compare(errors, prefix + "text", printed_text(attack.get("text", "")), printed_text(source_attack.get("abilityText", "")))
	var abilities: Array = card.get("abilities", [])
	var source_abilities: Array = source.get("cardFeatureItemList", [])
	_compare(errors, "abilities.count", abilities.size(), source_abilities.size())
	for index in mini(abilities.size(), source_abilities.size()):
		_compare(errors, "abilities.%d.name" % index, abilities[index].get("name", ""), source_abilities[index].get("featureName", ""))
		_compare(errors, "abilities.%d.text" % index, printed_text(abilities[index].get("text", "")), printed_text(source_abilities[index].get("featureDesc", "")))
	var rules: Array[String] = rule_paragraphs(card.get("trainer_text", ""))
	for rule in card.get("rules", []):
		rules.append_array(rule_paragraphs(rule))
	_compare(errors, "rules", rules, rule_paragraphs(source.get("ruleText", "")))
	if str(card.get("supertype", "")) == "Pokémon":
		_compare(errors, "energy_types", card.get("energy_types", []), [ENERGY_TYPES.get(str(source.get("attribute", "")))])
		_compare(errors, "retreat_cost", int(card.get("retreat_cost", 0)), int(source.get("retreatCost", 0)))
		_compare(errors, "stage", true, STAGES.get(str(source.get("evolveText", "")), "unknown") in card.get("subtypes", []))
		for field in ["weakness", "resistance"]:
			var expected: Array = []
			var type_id := str(source.get(field + "Type", ""))
			if not type_id.is_empty():
				expected.append({"energy_type": ENERGY_TYPES.get(type_id), "value": source.get(field + "Formula", "")})
			_compare(errors, field, card.get(field + ("es" if field == "weakness" else "s"), []), expected)
	elif str(card.get("supertype", "")) == "Trainer":
		var type_id := str(overrides.get("trainerType", source.get("trainerType", "")))
		_compare(errors, "trainer_type", card.get("trainer_type", ""), TRAINER_TYPES.get(type_id, "unknown"))
		_compare(errors, "trainer_subtype", true, TRAINER_TYPES.get(type_id, "unknown") in card.get("subtypes", []))
	elif str(card.get("supertype", "")) == "Energy":
		var subtype := "Basic" if str(source.get("energyType", "")) == "1" else "Special"
		_compare(errors, "energy_subtype", true, subtype in card.get("subtypes", []))
		if subtype == "Basic":
			_compare(errors, "provides_energy", card.get("provides_energy", []), [ENERGY_TYPES.get(str(source.get("attribute", "")))])
	return errors


static func _compare(errors: Array[String], field: String, actual: Variant, expected: Variant) -> void:
	if actual != expected:
		errors.append(field)

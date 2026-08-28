extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_run_contract()
	if failures.is_empty():
		print("CARD_PRESENTATION_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_contract() -> void:
	var cards := _load_json("res://data/cards.json")
	var images := _load_json("res://data/card_images.json")
	var hashes := _load_json("res://data/card_image_hashes.json")
	var audit := _load_json("res://authoring/card_review_manifest.json")
	var reviewed: Array = audit.get("reviewed_card_ids", [])
	var reviewed_set: Dictionary = {}
	for value in reviewed:
		var card_id := str(value)
		_check(not reviewed_set.has(card_id), "audit contains duplicate card id: %s" % card_id)
		reviewed_set[card_id] = true
	_check(int(audit.get("card_count", 0)) == 137, "audit card_count must remain 137")
	_check(cards.size() == 137, "runtime catalog must contain all 137 reviewed cards")
	_check(reviewed.size() == cards.size(), "audit must cover every runtime card exactly once")
	_check(images.size() == cards.size(), "image mapping must cover every runtime card")
	_check(hashes.size() == cards.size(), "image hash mapping must cover every runtime card")
	for card_id_value in cards:
		var card_id := str(card_id_value)
		_check(reviewed_set.has(card_id), "card is missing from visual audit: %s" % card_id)
		_check(images.has(card_id), "card is missing image mapping: %s" % card_id)
		_check(hashes.has(card_id), "card is missing image hash: %s" % card_id)
		_check(str(hashes.get(card_id, "")).length() == 64, "card image hash is not SHA-256: %s" % card_id)
		_check(FileAccess.file_exists(str(images.get(card_id, ""))), "card image file is missing: %s" % card_id)
	var corrected: Dictionary = audit.get("corrected_cards", {})
	for card_id_value in corrected:
		_check(cards.has(str(card_id_value)), "audit correction references unknown card: %s" % card_id_value)

	var serialized_cards := JSON.stringify(cards)
	for token in ["[C]", "G能量", "G宝可梦", "M能量", "D宝可梦"]:
		_check(token not in serialized_cards, "runtime card copy retained internal energy token: %s" % token)
	_check(int(Dictionary(cards["sv2-delib"]).get("hp", 0)) == 90, "Delibird HP must match the printed 90 HP")
	_check(str(Dictionary(Dictionary(cards["sv2-grex"])["attacks"][0]).get("name", "")) == "隐秘手里剑", "Greninja ex attack name must match card art")
	_check(str(Dictionary(cards["svf-hawl"]).get("name", "")) == "摔角鹰人", "Hawlucha name must match card art")
	_check(str(Dictionary(cards["svm-marnie-pride"]).get("name", "")) == "玛俐的骄傲", "Marnie card name must match card art")
	var dedenne_first_attack := Dictionary(Array(Dictionary(cards["sv1-114"]).get("attacks", []))[0])
	_check(Array(dedenne_first_attack.get("cost", [])) == ["Psychic"], "Dedenne's first attack must use its printed Psychic cost")
	var delibird_first_attack := Dictionary(Array(Dictionary(cards["sv2-delib"]).get("attacks", []))[0])
	_check(Array(delibird_first_attack.get("cost", [])) == ["Colorless"] and int(delibird_first_attack.get("converted_energy_cost", 0)) == 1, "Delibird's first attack must use its printed Colorless cost")
	_check("包含「宝可梦ex」" in str(Dictionary(Array(Dictionary(cards["svi-maus"]).get("abilities", []))[0]).get("text", "")), "Maushold ex ability copy must include Pokemon ex as printed")
	_check("普通能量" not in JSON.stringify(cards) and "无色能量" in str(Array(Dictionary(cards["svg2-lume"]).get("rules", []))[1]), "Luminous Energy must use the localized Colorless Energy term")
	_check(_matchup_value(Dictionary(cards["svd-absol"]), "weaknesses", "Grass") == "×2", "Darkness Pokemon must retain printed Grass weakness")
	_check(_matchup_value(Dictionary(cards["svd-doduo"]), "weaknesses", "Lightning") == "×2", "Doduo must retain printed Lightning weakness")
	_check(_matchup_value(Dictionary(cards["svd-doduo"]), "resistances", "Fighting") == "-30", "Doduo must retain printed Fighting resistance")
	_check(_matchup_value(Dictionary(cards["sv2-delib"]), "weaknesses", "Metal") == "×2", "Delibird must use its printed Metal weakness")
	_check(_matchup_value(Dictionary(cards["svd-seviper"]), "weaknesses", "Fighting") == "×2", "Seviper must use its printed Fighting weakness")
	_check(_matchup_value(Dictionary(cards["svf-klea"]), "weaknesses", "Grass") == "×2", "Kleavor must use its printed Grass weakness")
	_check(Array(Dictionary(cards["svg-tatsu"]).get("weaknesses", [])).is_empty(), "Dragon Tatsugiri must not gain a weakness absent from its card art")
	_check(_matchup_value(Dictionary(cards["svm-bronzor"]), "weaknesses", "Fire") == "×2", "Metal Pokemon must retain printed Fire weakness")
	_check(_matchup_value(Dictionary(cards["svm-bronzor"]), "resistances", "Grass") == "-30", "Metal Pokemon must retain printed Grass resistance")
	_check(_matchup_value(Dictionary(cards["svm-smeargle"]), "weaknesses", "Fighting") == "×2", "Smeargle must retain printed Fighting weakness")
	_check(Dictionary(cards["svm-smeargle"]).get("resistances", []).is_empty(), "Smeargle must not gain a resistance absent from its card art")
	_check(_matchup_value(Dictionary(cards["svm-skarmory"]), "weaknesses", "Lightning") == "×2", "Skarmory must use its printed Lightning weakness")
	_check(_matchup_value(Dictionary(cards["svm-skarmory"]), "resistances", "Fighting") == "-30", "Skarmory must use its printed Fighting resistance")
	_check(_matchup_value(Dictionary(cards["svg-cast"]), "weaknesses", "Fighting") == "×2", "Castform must use its printed Fighting weakness")
	_check(Dictionary(cards["svg-cast"]).get("resistances", []).is_empty(), "Castform must not retain a resistance absent from its card art")

	var catalog := CardCatalog.shared()
	var delibird_state := PokemonState.new("sv2-delib")
	delibird_state.damage_counters = 8
	_check(delibird_state.max_hp(catalog) == 90, "runtime HP projection must use Delibird's printed 90 HP")
	_check(delibird_state.current_hp(catalog) == 10, "runtime damage calculation must use corrected Delibird HP")
	var pokemon := catalog.get_card("sv1-104")
	var pokemon_meta := CardPresentation.meta_text(pokemon)
	var pokemon_text := CardPresentation.detail_bbcode(
		pokemon,
		catalog,
		null,
		CardPresentation.DetailLevel.FULL,
	)
	_check("宝可梦 · 基础 · 属性：超能力" in pokemon_meta, "Pokemon metadata must be fully localized")
	_check("卡面 HP 70" in pokemon_text, "Pokemon detail must identify printed HP")
	_check("费用：超能量" in pokemon_text, "attack detail must include localized energy cost")
	_check("撤退费用：2" in pokemon_text, "Pokemon detail must include retreat cost")
	_check("弱点：恶属性 ×2" in pokemon_text, "Pokemon detail must include weakness")
	_check("抗性：斗属性 -30" in pokemon_text, "Pokemon detail must include resistance")
	var compact_pokemon_text := CardPresentation.detail_bbcode(
		pokemon,
		catalog,
		null,
		CardPresentation.DetailLevel.COMPACT,
	)
	_check(
		"卡面数据" in compact_pokemon_text
		and "HP 70" in compact_pokemon_text
		and "费用" in compact_pokemon_text,
		"Compact Pokemon detail must retain the printed headline and attack cost",
	)
	_check(
		"当前状态" not in compact_pokemon_text,
		"Compact printed rules must not mix in live battle state",
	)
	var battle_pokemon := PokemonState.new("sv1-104")
	battle_pokemon.damage_counters = 2
	battle_pokemon.status_conditions.assign(["POISONED"])
	battle_pokemon.energy_card_ids.assign(["sv1-ener-7", "sv1-ener-7"])
	battle_pokemon.attached_tool_id = "sv1-159"
	var battle_state_text := CardPresentation.battle_state_bbcode(
		battle_pokemon,
		catalog,
		70,
	)
	_check(
		"当前状态" in battle_state_text
		and "HP 50／70" in battle_state_text
		and "伤害 20" in battle_state_text
		and "中毒" in battle_state_text
		and "能量" in battle_state_text
		and "道具" in battle_state_text,
		"Battle state surface must summarize live HP, damage, status and attachments",
	)

	var trainer := catalog.get_card("sv1-189")
	var trainer_text := CardPresentation.detail_bbcode(trainer, catalog)
	_check(CardPresentation.meta_text(trainer) == "训练家 · 支援者", "Trainer metadata must be localized")
	_check("卡牌效果" in trainer_text, "Trainer rules must use the card-effect section")
	_check("规则说明" not in trainer_text, "Trainer rules must not use a generic section title")

	var energy := catalog.get_card("svi-dtur")
	var energy_text := CardPresentation.detail_bbcode(energy, catalog)
	_check(CardPresentation.meta_text(energy) == "能量 · 特殊能量", "Special Energy metadata must be localized")
	_check("提供能量" in energy_text and "无色能量 ×2" in energy_text, "Special Energy must expose provided units")
	_check("能量效果" in energy_text, "Special Energy rules must use the energy-effect section")
	_check("[C]" not in energy_text and "［C］" not in energy_text, "Special Energy must not expose raw cost tokens")

	var ex_text := CardPresentation.detail_bbcode(catalog.get_card("sv2-grex"), catalog)
	_check("特殊规则" in ex_text, "Pokemon ex must expose its prize rule as a special rule")
	var free_retreat_text := CardPresentation.detail_bbcode(catalog.get_card("svl-chat"), catalog)
	_check("撤退费用：0" in free_retreat_text, "zero retreat cost must remain visible")


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		failures.append("missing JSON fixture: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		failures.append("invalid JSON fixture: %s" % path)
		return {}
	return Dictionary(parsed)


func _matchup_value(card: Dictionary, field: String, energy_type: String) -> String:
	for value in card.get(field, []):
		var row := Dictionary(value)
		if str(row.get("energy_type", "")) == energy_type:
			return str(row.get("value", ""))
	return ""


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

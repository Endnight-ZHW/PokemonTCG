class_name DeckVisualCatalog
extends RefCounted

## Front-end-only presentation metadata. Gameplay data continues to come from
## CardCatalog; this file only decides which artwork represents a published deck.
const PUBLISHED_ORDER: Array[String] = [
	"grass",
	"fire",
	"water",
	"lightning",
	"psychic",
	"fighting",
	"darkness",
	"steel",
	"dragon",
	"colorless",
]

const PUBLISHED_VISUALS := {
	"grass": {"representative": "svg2-tort", "tagline": "稳健成长，厚实收束"},
	"fire": {"representative": "svi-infr", "tagline": "积蓄火力，连续进攻"},
	"water": {"representative": "sv2-grex", "tagline": "灵活调度，伺机爆发"},
	"lightning": {"representative": "svl-pikaex", "tagline": "快速充能，抢占节奏"},
	"psychic": {"representative": "sv1-108", "tagline": "精密展开，掌控资源"},
	"fighting": {"representative": "svf-luca", "tagline": "正面压制，稳步推进"},
	"darkness": {"representative": "svd-mabosstiff-ex", "tagline": "耐心布局，反击制胜"},
	"steel": {"representative": "svm-zacian", "tagline": "攻守兼备，持续施压"},
	"dragon": {"representative": "svg-alt", "tagline": "多属性协作，后程发力"},
	"colorless": {"representative": "svi-maus", "tagline": "伙伴联动，灵活适配"},
}


static func ordered_deck_keys(catalog: CardCatalog) -> Array[String]:
	var result: Array[String] = []
	for key in PUBLISHED_ORDER:
		if not catalog.get_deck(key).is_empty():
			result.append(key)
	var remaining: Array[String] = []
	for key_value in catalog.decks.keys():
		var key := str(key_value)
		if key not in result:
			remaining.append(key)
	remaining.sort()
	result.append_array(remaining)
	return result


static func representative_card(catalog: CardCatalog, deck_key: String) -> String:
	var deck := catalog.get_deck(deck_key)
	if deck.is_empty():
		return ""
	var configured := str(
		PUBLISHED_VISUALS.get(deck_key, {}).get("representative", "")
	)
	if not configured.is_empty() and _deck_contains(deck, configured):
		var configured_card := catalog.get_card(configured)
		if not configured_card.is_empty():
			return configured
	var ranked := _ranked_cards(catalog, deck)
	return str(ranked[0].get("card_id", "")) if not ranked.is_empty() else ""


static func preview_cards(
	catalog: CardCatalog,
	deck_key: String,
	limit: int = 4,
) -> Array[String]:
	var result: Array[String] = []
	if limit <= 0:
		return result
	var deck := catalog.get_deck(deck_key)
	if deck.is_empty():
		return result
	var representative := representative_card(catalog, deck_key)
	if not representative.is_empty():
		result.append(representative)
	for row in _ranked_cards(catalog, deck):
		var card_id := str(row.get("card_id", ""))
		if card_id.is_empty() or card_id in result:
			continue
		result.append(card_id)
		if result.size() >= limit:
			break
	return result


static func tagline(deck_key: String) -> String:
	return str(PUBLISHED_VISUALS.get(deck_key, {}).get(
		"tagline",
		"规则清晰，随时可以开局",
	))


static func _ranked_cards(catalog: CardCatalog, deck: Dictionary) -> Array[Dictionary]:
	var pokemon_rows: Array[Dictionary] = []
	var other_rows: Array[Dictionary] = []
	var deck_name := str(deck.get("name", "")).strip_edges()
	var source_index := 0
	for row_value in deck.get("cards", []):
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var card := catalog.get_card(card_id)
		if card.is_empty():
			source_index += 1
			continue
		var candidate := {
			"card_id": card_id,
			"name_rank": _name_rank(deck_name, str(card.get("name", ""))),
			"hp": int(card.get("hp", 0)),
			"source_index": source_index,
		}
		if str(card.get("supertype", "")) == "Pokémon":
			pokemon_rows.append(candidate)
		else:
			other_rows.append(candidate)
		source_index += 1
	var ranked := pokemon_rows if not pokemon_rows.is_empty() else other_rows
	ranked.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_rank := int(left.get("name_rank", 2))
		var right_rank := int(right.get("name_rank", 2))
		if left_rank != right_rank:
			return left_rank < right_rank
		var left_hp := int(left.get("hp", 0))
		var right_hp := int(right.get("hp", 0))
		if left_hp != right_hp:
			return left_hp > right_hp
		return int(left.get("source_index", 0)) < int(right.get("source_index", 0))
	)
	return ranked


static func _name_rank(deck_name: String, card_name: String) -> int:
	if deck_name.is_empty() or card_name.is_empty():
		return 2
	if card_name == deck_name:
		return 0
	if deck_name.contains(card_name) or card_name.contains(deck_name):
		return 1
	return 2


static func _deck_contains(deck: Dictionary, card_id: String) -> bool:
	for row_value in deck.get("cards", []):
		if str((row_value as Dictionary).get("card_id", "")) == card_id:
			return true
	return false

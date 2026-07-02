class_name AIDeckProfiles
extends RefCounted

const PROFILES := {
	"fire": {
		"core": ["svi-infr"],
		"engine": ["svi-chim", "svi-monf", "svi-chiy", "svi-erec", "sv3-134"],
		"setup": ["svi-chim", "svi-ente", "svi-hrot"],
		"bench": ["svi-chim", "svi-sqwk", "svi-chiy"],
		"evolution": ["svi-monf", "svi-infr"],
		"trainer": ["sv1-152", "sv1-153", "svi-erec", "svi-mela"],
		"energy": ["Fire"],
	},
	"water": {
		"core": ["sv2-grex", "sv2-starm"],
		"engine": ["sv2-38", "sv2-39", "sv2-staryu", "sv2-cand"],
		"setup": ["sv2-38", "sv2-staryu", "sv2-keldeo", "sv1-49"],
		"bench": ["sv2-38", "sv2-staryu", "sv2-tatsu", "sv2-delib"],
		"evolution": ["sv2-39", "sv2-grex", "sv2-starm"],
		"trainer": ["sv2-cand", "sv1-152", "sv1-153", "sv2-catch"],
		"energy": ["Water"],
	},
	"psychic": {
		"core": ["sv1-106", "sv1-111", "sv1-112", "sv1-113"],
		"engine": ["sv1-107", "sv1-108", "sv1-109", "sv1-110", "sv1-114", "sv1-171"],
		"setup": ["sv1-109", "sv1-110", "sv1-113", "sv1-114", "sv1-104"],
		"bench": ["sv1-107", "sv1-110", "sv1-111", "sv1-112", "sv1-113", "sv1-114"],
		"evolution": ["sv1-108", "sv1-106"],
		"trainer": ["sv1-171", "sv1-204", "sv1-153"],
		"energy": ["Psychic"],
	},
	"lightning": {
		"core": ["svl-pikaex"],
		"engine": ["svl-mare2", "svl-flaa2", "svl-thun", "svl-chat", "svl-ensw", "sv1-170", "svl-trks"],
		"setup": ["svl-thun", "svl-emol", "svl-chat", "svl-mare2", "svl-chin"],
		"bench": ["svl-pikaex", "svl-mare2", "svl-chin"],
		"evolution": ["svl-flaa2", "svl-lant"],
		"trainer": ["sv1-170", "svl-ensw", "svl-vitb", "svl-zinn"],
		"energy": ["Lightning"],
	},
	"fighting": {
		"core": ["svf-luca", "svf-klea"],
		"engine": ["svf-rio", "svf-pass", "svf-farf", "svf-hawl", "svf-ensw2"],
		"setup": ["svf-farf", "svf-hawl", "svf-pass", "svf-terr", "svf-scyt"],
		"bench": ["svf-rio", "svf-scyt", "svf-farf"],
		"evolution": ["svf-luca", "svf-klea"],
		"trainer": ["svf-ensw2", "svf-potion", "svi-erec", "svf-houb"],
		"energy": ["Fighting"],
	},
	"colorless": {
		"core": ["svi-tand", "svi-maus", "svi-ambi", "svi-gree"],
		"engine": ["svi-aipo", "svi-skwv", "svi-inde", "svi-cait"],
		"setup": ["svi-tand", "svi-aipo", "svi-skwv", "svi-inde"],
		"bench": ["svi-tand", "svi-aipo", "svi-skwv", "svi-inde"],
		"evolution": ["svi-maus", "svi-ambi", "svi-gree"],
		"trainer": ["svi-enst", "svi-nemb", "svi-cait", "svi-popp"],
		"energy": ["Colorless"],
	},
	"dragon": {
		"core": ["svg-alt", "svg-ceti"],
		"engine": ["svg-swa", "svg-dram", "svg-milt", "svg-beri", "svg-chef"],
		"setup": ["svg-swa", "svg-dram", "svg-milt", "svg-ceto"],
		"bench": ["svg-swa", "svg-ceto", "svg-milt", "svg-tatsu"],
		"evolution": ["svg-alt", "svg-ceti"],
		"trainer": ["svg-chef", "svg-beri", "svf-potion", "svl-ensw"],
		"energy": ["Water", "Metal"],
	},
	"grass": {
		"core": ["svg2-tort", "svg2-brel", "svg2-empo"],
		"engine": ["svg2-turt", "svg2-grot", "svg2-shro", "svg2-zaru", "svg2-gard"],
		"setup": ["svg2-turt", "svg2-shro", "svg2-zaru"],
		"bench": ["svg2-turt", "svg2-shro", "svg2-zaru"],
		"evolution": ["svg2-grot", "svg2-tort", "svg2-brel", "svg2-empo"],
		"trainer": ["sv1-152", "svg2-gard", "svg2-exps", "sv1-153"],
		"energy": ["Grass", "Rainbow"],
	},
	"steel": {
		"core": ["svm-zacian", "svm-zamazenta", "svm-orthworm"],
		"engine": ["svm-bronzor", "svm-bronzong", "svm-smeargle", "svm-cobalion", "svm-dialga"],
		"setup": ["svm-smeargle", "svm-zamazenta", "svm-zacian", "svm-cobalion"],
		"bench": ["svm-bronzor", "svm-smeargle", "svm-cobalion", "svm-orthworm"],
		"evolution": ["svm-bronzong"],
		"trainer": ["sv1-151", "sv1-153", "svm-marnie-pride", "svg2-exps", "svl-vitb"],
		"energy": ["Metal"],
		"high_impact_damage_floor": 100,
	},
	"darkness": {
		"core": ["svd-mabosstiff-ex", "svd-dodrio"],
		"engine": ["svd-maschiff", "svd-doduo", "svd-dark-patch", "svl-chat"],
		"setup": ["svd-maschiff", "svd-doduo", "svd-absol", "svd-morpeko", "svl-chat"],
		"bench": ["svd-maschiff", "svd-doduo", "svd-mabosstiff-ex"],
		"evolution": ["svd-mabosstiff-ex", "svd-dodrio"],
		"trainer": ["sv1-151", "sv1-153", "svd-dark-patch", "svd-hard-belt", "sv1-204"],
		"energy": ["Darkness"],
	},
}

static var _membership_cache: Dictionary = {}


static func get_profile(deck_key: String) -> Dictionary:
	return Dictionary(PROFILES.get(deck_key, {}))


static func contains(deck_key: String, group: String, card_id: String) -> bool:
	var profile_membership := _membership_for_deck(deck_key)
	var group_membership: Dictionary = profile_membership.get(group, {})
	return group_membership.has(card_id)


static func high_impact_damage_floor(deck_key: String) -> int:
	return int(get_profile(deck_key).get("high_impact_damage_floor", 110))


static func _membership_for_deck(deck_key: String) -> Dictionary:
	if _membership_cache.has(deck_key):
		return _membership_cache[deck_key]
	var profile := get_profile(deck_key)
	var membership := {}
	for group in ["core", "engine", "setup", "bench", "evolution", "trainer", "energy"]:
		var group_membership := {}
		for value in profile.get(group, []):
			group_membership[str(value)] = true
		membership[group] = group_membership
	_membership_cache[deck_key] = membership
	return membership

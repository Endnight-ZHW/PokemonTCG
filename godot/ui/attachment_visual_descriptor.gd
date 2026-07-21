class_name AttachmentVisualDescriptor
extends RefCounted

const ENERGY_ICONS := preload("res://ui/energy_icon_catalog.gd")

var attachment_type := ""
var card_id := ""
var display_name := ""
var icon: Texture2D
var fallback_label := "?"
var marker := ""
var group_key := ""
var energy_type := "Unknown"
var provided_energy_units: Array[String] = []
var physical_indices: Array[int] = []
var card_ids: Array[String] = []
var count := 1
var is_basic_energy := false
var is_special_energy := false
var has_known_identity := false


static func resolve(
	p_attachment_type: String,
	p_card_id: String,
	p_index: int,
	catalog: CardCatalog,
) -> AttachmentVisualDescriptor:
	var descriptor := AttachmentVisualDescriptor.new()
	descriptor.attachment_type = p_attachment_type
	descriptor.card_id = p_card_id
	descriptor.physical_indices.append(p_index)
	descriptor.card_ids.append(p_card_id)
	var card := catalog.get_card(p_card_id) if catalog != null else {}
	descriptor.has_known_identity = not card.is_empty()
	descriptor.display_name = str(card.get("name", p_card_id))
	if descriptor.display_name.is_empty():
		descriptor.display_name = "未知附件"

	if p_attachment_type != "energy":
		descriptor.group_key = "%s:card:%s" % [
			p_attachment_type,
			p_card_id if not p_card_id.is_empty() else "index:%d" % p_index,
		]
		descriptor.fallback_label = "道" if p_attachment_type == "tool" else "?"
		return descriptor

	if catalog != null:
		descriptor.provided_energy_units.assign(catalog.provides_energy(p_card_id))
		descriptor.is_basic_energy = catalog.is_basic_energy(p_card_id)
		descriptor.is_special_energy = catalog.is_special_energy(p_card_id)
	if not descriptor.provided_energy_units.is_empty():
		descriptor.energy_type = descriptor.provided_energy_units[0]

	if descriptor.is_basic_energy:
		# Basic energy is visually interchangeable by the energy type it provides.
		descriptor.group_key = "energy:type:%s" % descriptor.energy_type
		descriptor.display_name = ENERGY_ICONS.display_name_for(
			descriptor.energy_type,
			descriptor.display_name,
		)
		descriptor.icon = ENERGY_ICONS.texture_for(descriptor.energy_type)
		descriptor.fallback_label = ENERGY_ICONS.short_label_for(descriptor.energy_type)
		return descriptor

	# Every special or unknown energy keeps its exact identity. A known special
	# energy without dedicated art can borrow its provided-type symbol, but the
	# card-specific marker prevents it from masquerading as basic energy.
	descriptor.group_key = "energy:card:%s" % (
		p_card_id if not p_card_id.is_empty() else "unknown:%d" % p_index
	)
	descriptor.icon = ENERGY_ICONS.texture_for_card_id(p_card_id)
	var has_dedicated_icon := descriptor.icon != null
	if descriptor.icon == null and descriptor.has_known_identity:
		descriptor.icon = ENERGY_ICONS.texture_for(descriptor.energy_type)
	if descriptor.has_known_identity:
		descriptor.marker = (
			"" if has_dedicated_icon else _short_card_marker(descriptor.display_name)
		)
		descriptor.fallback_label = (
			descriptor.marker if not descriptor.marker.is_empty() else "特"
		)
	else:
		descriptor.energy_type = "Unknown"
		descriptor.icon = null
		descriptor.marker = ""
		descriptor.fallback_label = "?"
	return descriptor


static func grouped_energy(card_id_values: Array, catalog: CardCatalog) -> Array:
	var grouped_by_key: Dictionary = {}
	for index in range(card_id_values.size()):
		var descriptor := resolve("energy", str(card_id_values[index]), index, catalog)
		if grouped_by_key.has(descriptor.group_key):
			var existing := grouped_by_key[descriptor.group_key] as AttachmentVisualDescriptor
			existing.count += 1
			existing.card_ids.append(descriptor.card_id)
			existing.physical_indices.append(index)
			continue
		grouped_by_key[descriptor.group_key] = descriptor
	var result: Array = grouped_by_key.values()
	result.sort_custom(func(left: AttachmentVisualDescriptor, right: AttachmentVisualDescriptor) -> bool:
		return left.first_physical_index() < right.first_physical_index()
	)
	return result


static func canonical_ref(ref_value: Variant) -> Dictionary:
	if not ref_value is Dictionary:
		return {}
	var result := Dictionary(ref_value).duplicate(true)
	var index := int(result.get("index", -1))
	if index < 0 and result.has("attachment_index"):
		index = int(result.get("attachment_index", -1))
	if result.has("index") or result.has("attachment_index"):
		result["index"] = index
	result.erase("attachment_index")
	return result


func first_physical_index() -> int:
	return physical_indices[0] if not physical_indices.is_empty() else -1


func provided_unit_count() -> int:
	return provided_energy_units.size() * count


func to_dictionary() -> Dictionary:
	return {
		"kind": attachment_type,
		"attachment_type": attachment_type,
		"card_id": card_id,
		"card_ids": card_ids.duplicate(),
		"index": first_physical_index(),
		"indices": physical_indices.duplicate(),
		"display_name": display_name,
		"icon": icon,
		"icon_card_id": (
			card_id if not ENERGY_ICONS.path_for_card_id(card_id).is_empty() else ""
		),
		"fallback_label": fallback_label,
		"marker": marker,
		"group_key": group_key,
		"type": energy_type,
		"provided_energy_units": provided_energy_units.duplicate(),
		"provided_unit_count": provided_unit_count(),
		"count": count,
		"is_basic_energy": is_basic_energy,
		"is_special_energy": is_special_energy,
		"has_known_identity": has_known_identity,
	}


static func _short_card_marker(card_name: String) -> String:
	var normalized := card_name.strip_edges().replace("能量", "").strip_edges()
	if normalized.is_empty():
		return "特"
	return normalized.left(1).to_upper()

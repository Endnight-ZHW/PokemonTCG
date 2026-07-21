class_name AttachmentVisualDescriptor
extends RefCounted

const ENERGY_ICONS := preload("res://ui/energy_icon_catalog.gd")
const ENERGY_VIEW := preload("res://rules/energy_view.gd")

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
	_configure_energy_visual(descriptor, p_index)
	return descriptor


static func resolve_energy_at(
	card_id_values: Array,
	p_index: int,
	catalog: CardCatalog,
) -> AttachmentVisualDescriptor:
	var card_ids: Array[String] = []
	for card_id_value in card_id_values:
		card_ids.append(str(card_id_value))
	var card_id := card_ids[p_index] if p_index >= 0 and p_index < card_ids.size() else ""
	var descriptor := resolve("energy", card_id, p_index, catalog)
	if catalog == null or p_index < 0 or p_index >= card_ids.size():
		return descriptor
	# Some Special Energy changes what it provides according to its neighbours
	# (for example Luminous Energy downgrades to Colorless beside another Special
	# Energy). The badge must describe the effective board state, not only the
	# static card catalog entry.
	descriptor.provided_energy_units.assign(
		ENERGY_VIEW.units_for_card_at(card_ids, p_index, catalog)
	)
	if not descriptor.provided_energy_units.is_empty():
		descriptor.energy_type = descriptor.provided_energy_units[0]
	_configure_energy_visual(descriptor, p_index)
	return descriptor


static func grouped_energy(card_id_values: Array, catalog: CardCatalog) -> Array:
	var grouped_by_key: Dictionary = {}
	for index in range(card_id_values.size()):
		var descriptor := resolve_energy_at(card_id_values, index, catalog)
		if grouped_by_key.has(descriptor.group_key):
			var existing := grouped_by_key[descriptor.group_key] as AttachmentVisualDescriptor
			existing.count += 1
			existing.card_ids.append(descriptor.card_id)
			existing.physical_indices.append(index)
			existing.provided_energy_units.append_array(
				descriptor.provided_energy_units
			)
			continue
		grouped_by_key[descriptor.group_key] = descriptor
	var result: Array = grouped_by_key.values()
	result.sort_custom(func(left: AttachmentVisualDescriptor, right: AttachmentVisualDescriptor) -> bool:
		return left.first_physical_index() < right.first_physical_index()
	)
	for descriptor_value in result:
		var descriptor := descriptor_value as AttachmentVisualDescriptor
		if descriptor != null and descriptor.group_key == "energy:type:Colorless":
			# Several Colorless-providing Special Energy cards are intentionally
			# indistinguishable on the compact board badge. Their exact identities
			# remain available through card_ids/physical_indices for selections.
			descriptor.display_name = ENERGY_ICONS.display_name_for("Colorless")
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
	# Grouped descriptors append the effective units of every physical card, so
	# this is an energy-unit count rather than an attachment-card count.
	return provided_energy_units.size()


func visual_count() -> int:
	var unit_count := provided_unit_count()
	return unit_count if unit_count > 0 else count


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
			card_id
			if (
				group_key.begins_with("energy:card:")
				and not ENERGY_ICONS.path_for_card_id(card_id).is_empty()
			)
			else ""
		),
		"fallback_label": fallback_label,
		"marker": marker,
		"group_key": group_key,
		"type": energy_type,
		"provided_energy_units": provided_energy_units.duplicate(),
		"provided_unit_count": provided_unit_count(),
		"visual_count": visual_count(),
		"count": count,
		"is_basic_energy": is_basic_energy,
		"is_special_energy": is_special_energy,
		"has_known_identity": has_known_identity,
	}


static func _configure_energy_visual(
	descriptor: AttachmentVisualDescriptor,
	p_index: int,
) -> void:
	if descriptor.is_basic_energy:
		# Basic energy is visually interchangeable by the energy type it provides.
		descriptor.group_key = "energy:type:%s" % descriptor.energy_type
		descriptor.display_name = ENERGY_ICONS.display_name_for(
			descriptor.energy_type,
			descriptor.display_name,
		)
		descriptor.icon = ENERGY_ICONS.texture_for(descriptor.energy_type)
		descriptor.marker = ""
		descriptor.fallback_label = ENERGY_ICONS.short_label_for(descriptor.energy_type)
		return

	if descriptor.is_special_energy and _provides_only_colorless(
		descriptor.provided_energy_units
	):
		# A Colorless-providing Special Energy keeps all of its card rules, but its
		# compact attachment visual joins the shared Colorless unit stack. Do not
		# add a card-specific marker: the count communicates provided units.
		descriptor.energy_type = "Colorless"
		descriptor.group_key = "energy:type:Colorless"
		descriptor.icon = ENERGY_ICONS.texture_for("Colorless")
		descriptor.marker = ""
		descriptor.fallback_label = ENERGY_ICONS.short_label_for("Colorless")
		return

	# Other Special or unknown energy keeps its exact visual identity. A known
	# Special Energy without dedicated art borrows its provided-type symbol and a
	# short marker so it cannot masquerade as a basic typed energy.
	descriptor.group_key = "energy:card:%s" % (
		descriptor.card_id
		if not descriptor.card_id.is_empty()
		else "unknown:%d" % p_index
	)
	descriptor.icon = ENERGY_ICONS.texture_for_card_id(descriptor.card_id)
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


static func _provides_only_colorless(units: Array[String]) -> bool:
	if units.is_empty():
		return false
	for unit in units:
		if unit != "Colorless":
			return false
	return true


static func _short_card_marker(card_name: String) -> String:
	var normalized := card_name.strip_edges().replace("能量", "").strip_edges()
	if normalized.is_empty():
		return "特"
	return normalized.left(1).to_upper()

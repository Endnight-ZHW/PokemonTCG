class_name BattlePresentationState
extends RefCounted

## Mutable registries used while a presentation batch is in flight. Keeping
## these together makes cancellation/resync state explicit and prevents visual
## bookkeeping from being confused with the authoritative GameState.

var reveals: Dictionary = {}
var mask_counts: Dictionary = {}
var feedbacks: Dictionary = {}
var landing_feedbacks: Dictionary = {}
var covers: Dictionary = {}
var cover_tweens: Dictionary = {}
var slot_covers: Dictionary = {}
var slot_cover_states: Dictionary = {}
var slot_event_queues: Dictionary = {}
var slot_event_plans: Dictionary = {}
var deferred_ko_slots: Dictionary = {}
var event_hand_targets: Dictionary = {}
var hand_target_cursor: Dictionary = {}
var hand_removed_counts: Dictionary = {}
var event_hand_sources: Dictionary = {}
var hand_proxy_by_key: Dictionary = {}
var hand_snapshot_rows: Dictionary = {}
var attachment_source_proxies: Dictionary = {}
var attachment_source_specs: Dictionary = {}
var zone_states: Dictionary = {}


func clear() -> void:
	for registry in _registries():
		registry.clear()


func _registries() -> Array[Dictionary]:
	return [
		reveals,
		mask_counts,
		feedbacks,
		landing_feedbacks,
		covers,
		cover_tweens,
		slot_covers,
		slot_cover_states,
		slot_event_queues,
		slot_event_plans,
		deferred_ko_slots,
		event_hand_targets,
		hand_target_cursor,
		hand_removed_counts,
		event_hand_sources,
		hand_proxy_by_key,
		hand_snapshot_rows,
		attachment_source_proxies,
		attachment_source_specs,
		zone_states,
	]

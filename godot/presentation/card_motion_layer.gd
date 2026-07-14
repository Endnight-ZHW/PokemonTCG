class_name CardMotionLayer
extends RefCounted

var _root_ref: WeakRef
var _entities: Array[Control]
var _tweens: Dictionary


func configure(
	root: Control,
	entity_registry: Array[Control],
	tween_registry: Dictionary,
) -> void:
	_root_ref = weakref(root) if root != null else null
	_entities = entity_registry
	_tweens = tween_registry


func add(entity: Control) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	var root := _root()
	if entity.get_parent() == null and root != null:
		root.add_child(entity)
	if entity not in _entities:
		_entities.append(entity)


func bind_tween(entity: Control, tween: Tween) -> void:
	if entity == null or not is_instance_valid(entity) or tween == null:
		return
	_tweens[entity.get_instance_id()] = tween


func forget(entity: Control) -> void:
	if entity == null:
		return
	_entities.erase(entity)
	if is_instance_valid(entity):
		_tweens.erase(entity.get_instance_id())


func prune() -> void:
	var live: Array[Control] = []
	for entity in _entities:
		if is_instance_valid(entity) and not entity.is_queued_for_deletion():
			live.append(entity)
	_entities.assign(live)


func _root() -> Control:
	if _root_ref == null:
		return null
	var value: Variant = _root_ref.get_ref()
	return value as Control if is_instance_valid(value) else null

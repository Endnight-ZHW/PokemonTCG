class_name BattleMulligan3D
extends RefCounted

## Intermediate opening hands are not the authoritative final hand. Keep their
## own identities through draw -> public reveal -> return, using the normal fan.
var presenter: Battle3DPresenter
var hands: Dictionary = {}
var _handles: Array[MotionHandle] = []
var _hint_before: Variant = null
var _viewer := -1
var public_reveal: BattleMulliganReveal3D

func _init(value: Battle3DPresenter) -> void:
	presenter = value
	public_reveal = BattleMulliganReveal3D.new(presenter)

static func handles(event: Dictionary) -> bool:
	var data: Dictionary = event.get("data", {})
	var kind := str(event.get("event_type", ""))
	var purpose := str(data.get("purpose", ""))
	return (kind == "cards_drawn" and purpose in ["opening_hand", "mulligan_redraw"] and not bool(data.get("final_opening_hand", false))) \
		or (kind == "cards_revealed" and purpose == "mulligan") \
		or (kind == "card_moved" and purpose == "mulligan_return")

func play(event: Dictionary, duration: float) -> MotionHandle:
	var table := presenter.table
	if not hands.is_empty() and _viewer != table.view_player: clear()
	_viewer = table.view_player
	var actor := int(event.get("actor", table.view_player))
	var data: Dictionary = event.get("data", {})
	var kind := str(event.event_type)
	var ids := table.motion_geometry._event_card_ids(event)
	if kind == "cards_drawn":
		_clear_hand(actor)
		var cards: Array[CardMotionEntity] = []
		var faces: Array[Texture2D] = []
		for index in range(clampi(int(data.get("count", ids.size())), 0, 7)):
			var card := table.motion_entities._create_paper_card_token(CardEntity3D.BACK, table.hand_view._current_hand_card_size(), "MulliganHand", 90 + index) as CardMotionEntity
			card.visual_id = "%s:%d" % [str(event.get("event_id", "mulligan")), index]
			card.set_meta("mulligan_hand", true)
			card.visible = false
			table.effects.add_child(card)
			cards.append(card)
			faces.append(table.card_motion_layer._texture_for_card_id(str(ids[index])) if actor == table.view_player and index < ids.size() else CardEntity3D.BACK)
		hands[actor] = {"cards": cards, "faces": faces, "phase": "rest", "progress": 0.0}
	var handle := MotionHandle.new()
	if not hands.has(actor):
		handle.finish()
		return handle
	var row: Dictionary = hands[actor]
	if actor != table.view_player and kind == "cards_revealed":
		public_reveal.begin(actor, ids)
		row.public = true
		duration = maxf(duration, 2.8 if MotionPolicy.reduced() else 3.3)
	elif bool(row.get("public", false)) and kind == "card_moved":
		duration = maxf(duration, 0.55)
	row.phase = kind
	row.progress = 0.0
	row.duration = maxf(0.01, duration)
	row.starts = []
	for card in row.cards: row.starts.append((card as CardMotionEntity).texture)
	if kind == "cards_revealed":
		# Only this public event may bind the opponent's revealed faces.
		for index in range(mini(ids.size(), row.faces.size())):
			row.faces[index] = table.card_motion_layer._texture_for_card_id(str(ids[index]))
		if _hint_before == null: _hint_before = table.header._task_hint_override
		table.header.set_task_hint("再战：没有基础宝可梦，展示手牌后重新抽牌")
	var zone := table.zones["own_deck" if actor == table.view_player else "opponent_deck"] as ZoneView
	row.deck_pose = presenter.zone_pose(zone)
	_handles.append(handle)
	var tween := table.create_tween()
	if MotionPolicy.reduced():
		row.progress = 1.0
		sync()
		tween.tween_interval(maxf(0.9, duration) if kind == "cards_revealed" else 0.01)
	else:
		tween.tween_method(func(progress: float) -> void: row.progress = progress, 0.0, 1.0, maxf(0.9, duration) if kind == "cards_revealed" else row.duration)
	tween.tween_callback(_finish_phase.bind(actor, row))
	handle.bind_tween(tween)
	handle.completed.connect(func(_value: MotionHandle) -> void: _handles.erase(handle), CONNECT_ONE_SHOT)
	sync()
	return handle

func sync() -> void:
	if not presenter.is_projection_ready(): return
	if not hands.is_empty() and _viewer != presenter.table.view_player:
		clear()
		return
	for actor in hands:
		var row: Dictionary = hands[actor]
		var cards: Array = row.cards
		for index in range(cards.size()):
			var card := cards[index] as CardMotionEntity
			card.visible = true
			var pose := hand_pose(card, actor, index, cards.size())
			var phase := str(row.phase)
			var progress := float(row.progress)
			var public := bool(row.get("public", false))
			if public:
				var display_pose := public_reveal.pose(index)
				if phase == "cards_revealed":
					var entry := smoothstep(0.0, 0.32, progress * float(row.duration))
					pose = BattleCardPath3D.transfer(presenter.world.projection, pose, display_pose, entry, 12.0)
				else: pose = display_pose
			if phase in ["cards_drawn", "card_moved"]:
				var fade_delay := 0.10 if public else 0.0
				var flight_duration := float(row.duration) - fade_delay
				var delay := minf(0.09, maxf(0.0, flight_duration - 0.24) / maxi(1, cards.size() - 1))
				progress = clampf((progress * float(row.duration) - fade_delay - index * delay) / maxf(0.12, flight_duration - (cards.size() - 1) * delay), 0.0, 1.0)
				progress = sin(progress * PI * 0.5)
				if public: pose = BattleCardPath3D.transfer(presenter.world.projection, pose, row.deck_pose, progress, 12.0)
				else:
					pose = (row.deck_pose as Transform3D).interpolate_with(pose, progress) if phase == "cards_drawn" else pose.interpolate_with(row.deck_pose, progress)
					pose.origin.y += sin(progress * PI) * 0.55
				card.visible = progress < 0.9999 if phase == "card_moved" else progress > 0.0001
				_flip(card, row.starts[index], CardEntity3D.BACK if phase == "card_moved" else row.faces[index], progress)
			elif phase == "cards_revealed":
				_flip(card, row.starts[index], row.faces[index], minf(1.0, progress * float(row.duration) / 0.32) if public else minf(1.0, progress * 4.0))
			card.world_pose = pose
			card.has_world_pose = true
			if actor == presenter.table.view_player and presenter.table._local_hand_privacy_hidden:
				card.visible = false

func presentation_frame() -> Dictionary:
	var row: Dictionary = hands.get(public_reveal.actor, {})
	return public_reveal.frame(row) if not row.is_empty() else {}

func hand_pose(card: CardMotionEntity, actor: int, index: int, count: int) -> Transform3D:
	var table := presenter.table
	var own := actor == table.view_player
	var card_size := table.hand_view._current_hand_card_size() if own else table.hand_view._current_opponent_hand_card_size()
	var surface := table.hand_surface if own else table.opponent_hand_surface
	var plan := BattleTableLayout.own_hand_plan(count, table.hand_scroll.size.x, card_size, table.hand_minimum_spacing, table.hand_rotation_degrees) if own else BattleTableLayout.opponent_hand_plan(count, surface.size.x, card_size, table.opponent_hand_minimum_spacing, table.opponent_hand_rotation_degrees)
	var item: Dictionary = plan.items[index]
	card.custom_minimum_size = card_size
	card.size = card_size
	card.pivot_offset = card_size * 0.5
	card.position = table._effects_local(surface.get_global_transform_with_canvas() * (Vector2(item.position) + card_size * 0.5)) - card_size * 0.5
	card.rotation_degrees = float(item.rotation_degrees)
	return presenter._hand_surface_pose(card, card_size.x * (1.0 if own else 0.72), index, count, 0.36 + index * 0.025, own, false)

func _flip(card: CardMotionEntity, source: Texture2D, target: Texture2D, progress: float) -> void:
	card.texture = target if progress >= 0.5 else source
	if source != target and progress < 1.0:
		card.set_meta("physical_flip_source", source)
		card.set_meta("motion_flip_texture", target)
		card.set_meta("physical_flip_progress", clampf((progress - 0.25) / 0.5, 0.0, 1.0))
	elif card.has_meta("physical_flip_progress"):
		card.remove_meta("physical_flip_progress")

func _finish_phase(actor: int, expected: Dictionary) -> void:
	if not hands.has(actor) or not is_same(hands[actor], expected): return
	expected.progress = 1.0
	sync()
	if str(expected.phase) == "card_moved":
		_clear_hand(actor)
	else:
		expected.phase = "rest"

func _clear_hand(actor: int) -> void:
	if not hands.has(actor): return
	var row: Dictionary = hands[actor]
	hands.erase(actor)
	if public_reveal.actor == actor: public_reveal.clear()
	for card in row.cards:
		if is_instance_valid(card): card.free()
	if hands.is_empty() and _hint_before != null:
		presenter.table.header.set_task_hint(str(_hint_before))
		_hint_before = null
		presenter.table.board_view._refresh_header()

func clear() -> void:
	for handle in _handles.duplicate(): handle.cancel()
	_handles.clear()
	for actor in hands.keys(): _clear_hand(actor)

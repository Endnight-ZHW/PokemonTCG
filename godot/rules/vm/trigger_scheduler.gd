class_name VMTriggerScheduler
extends RefCounted


func queue_batch(
	stack: ResolutionStack,
	candidates: Array[Dictionary],
	hook: String,
	active_player: int,
	order_policy: String = "apnap",
	choice_domain: String = "effect",
) -> Dictionary:
	if candidates.is_empty():
		return VMResult.ok()
	if candidates.size() > VMResolutionFrameCodec.MAX_TRIGGER_CANDIDATES:
		return VMResult.fail(
			"同批触发超过上限%d。" % VMResolutionFrameCodec.MAX_TRIGGER_CANDIDATES,
			"trigger_batch_limit",
		)
	if active_player not in [0, 1]:
		return VMResult.fail("触发批当前玩家无效。", "invalid_trigger_batch")
	if order_policy not in ["apnap", "incoming_first"]:
		return VMResult.fail("未知触发排序策略。", "invalid_trigger_batch")
	var parent_trigger_id := stack.current_trigger_id()
	var depth := stack.current_trigger_depth() + 1
	if depth > VMResolutionFrameCodec.MAX_TRIGGER_DEPTH:
		return VMResult.fail("触发嵌套超过64层。", "trigger_depth_limit")
	var normalized: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	for candidate_value in candidates:
		var candidate := Dictionary(candidate_value).duplicate(true)
		candidate["parent_trigger_id"] = parent_trigger_id
		candidate["depth"] = depth
		var error := VMResolutionFrameCodec.validate_trigger_candidate(candidate)
		if not error.is_empty():
			return error
		var trigger_id := str(candidate.get("trigger_id", ""))
		if seen_ids.has(trigger_id):
			return VMResult.fail("同批触发ID重复。", "duplicate_trigger_id")
		seen_ids[trigger_id] = true
		normalized.append(candidate)
	var batch_id := "trigger-batch:%d:%s:%d" % [
		stack.sequence,
		hook.to_lower(),
		depth,
	]
	stack.sequence += 1
	var frame := VMResolutionFrameCodec.trigger_batch_frame(
		batch_id,
		hook,
		active_player,
		order_policy,
		normalized,
		parent_trigger_id,
		depth,
		choice_domain,
	)
	if not stack.push_trigger_batch(frame):
		return stack.validation_result()
	var domains: Dictionary = stack.context.get("trigger_choice_domains", {})
	for candidate in normalized:
		domains[str(candidate.get("trigger_id", ""))] = choice_domain
	stack.context["trigger_choice_domains"] = domains
	return VMResult.ok()


func advance_batch(
	state: GameState,
	stack: ResolutionStack,
	frame: Dictionary,
) -> Dictionary:
	var candidates: Array = frame.get("candidates", [])
	if candidates.is_empty():
		return VMResult.ok()
	var eligible := _eligible_indices(frame)
	if eligible.is_empty():
		return VMResult.fail("触发批无法确定下一项。", "invalid_trigger_batch")
	if eligible.size() > 1:
		if not stack.push_trigger_batch(frame):
			return stack.validation_result()
		return _request_order_choice(state, stack, frame, eligible)
	return _select_candidate(state, stack, frame, int(eligible[0]))


func apply_trigger_choice(
	state: GameState,
	stack: ResolutionStack,
	operation: String,
	data: Dictionary,
	selected: Array[Dictionary],
	cancelled: bool,
) -> Dictionary:
	if operation == "trigger_order":
		if cancelled or selected.size() != 1:
			return VMResult.fail("必须选择一个触发。", "choice_count")
		if stack.frames.is_empty() or str(stack.frames[-1].get("kind", "")) != "trigger_batch":
			return VMResult.fail("触发排序批已丢失。", "stale_choice")
		var batch := stack.pop_frame()
		if str(batch.get("batch_id", "")) != str(data.get("batch_id", "")):
			return VMResult.fail("触发排序批已变化。", "stale_choice")
		var trigger_id := str(selected[0].get("value", {}).get("trigger_id", ""))
		var candidates: Array = batch.get("candidates", [])
		for index in range(candidates.size()):
			if str(candidates[index].get("trigger_id", "")) == trigger_id:
				return _select_candidate(state, stack, batch, index)
		return VMResult.fail("触发排序选择无效。", "invalid_choice")
	if operation == "trigger_confirm":
		var candidate_value: Variant = data.get("candidate")
		if not candidate_value is Dictionary:
			return VMResult.fail("确认触发已丢失。", "stale_choice")
		var candidate: Dictionary = candidate_value
		if cancelled or selected.is_empty():
			_cleanup_trigger_domain(stack, str(candidate.get("trigger_id", "")))
			return VMResult.ok("已跳过可选触发。")
		if selected.size() != 1 or str(selected[0].get("value", {}).get(
			"trigger_id", "")) != str(candidate.get("trigger_id", "")):
			return VMResult.fail("确认触发选择无效。", "invalid_choice")
		if not stack.push_trigger(candidate):
			return stack.validation_result()
		return VMResult.ok("已确认触发。")
	return VMResult.fail("未知触发续体。", "unknown_continuation")


func expand_trigger(
	state: GameState,
	stack: ResolutionStack,
	frame: Dictionary,
) -> Dictionary:
	var candidate: Dictionary = frame.get("candidate", {})
	var error := VMResolutionFrameCodec.validate_trigger_candidate(candidate)
	if not error.is_empty():
		return error
	var live := _candidate_is_live(state, candidate)
	if not bool(live.get("ok", false)):
		return VMResult.fail(
			str(live.get("message", "触发存活规则无效。")),
			str(live.get("error_code", "invalid_trigger_liveness")),
		)
	if not bool(live.get("live", false)):
		_cleanup_trigger_domain(stack, str(candidate.get("trigger_id", "")))
		return VMResult.ok("触发来源已失效。")
	var guard_result := _guards_pass(state, candidate)
	if not bool(guard_result.get("ok", false)):
		return VMResult.fail(
			str(guard_result.get("message", "触发条件无效。")),
			str(guard_result.get("error_code", "invalid_trigger_guard")),
		)
	if not bool(guard_result.get("pass", false)):
		_cleanup_trigger_domain(stack, str(candidate.get("trigger_id", "")))
		return VMResult.ok("触发条件不满足。")
	var trigger_id := str(candidate.get("trigger_id", ""))
	var sources: Dictionary = stack.context.get("trigger_source_refs", {})
	sources[trigger_id] = Dictionary(candidate.get("source_ref", {})).duplicate(true)
	stack.context["trigger_source_refs"] = sources
	error = stack.begin_trigger(trigger_id)
	if not error.is_empty():
		return error
	if not stack.push_barrier("trigger_complete", {
		"trigger_id": trigger_id,
		"depth": int(candidate.get("depth", 1)),
	}):
		return stack.validation_result()
	var commands: Array = candidate.get("commands", [])
	for index in range(commands.size() - 1, -1, -1):
		var command_value: Variant = commands[index]
		if not command_value is Dictionary:
			return VMResult.fail("触发命令必须是对象。", "invalid_trigger_payload")
		stack.push_command(
			command_value,
			int(candidate.get("controller", -1)),
			_source_slot(candidate),
			{
				"trigger_id": trigger_id,
				"hook": str(candidate.get("hook", "")),
				"depth": int(candidate.get("depth", 1)),
			},
		)
		if not stack.validation_error.is_empty():
			return stack.validation_result()
	return VMResult.ok()


func complete_trigger(stack: ResolutionStack, data: Dictionary) -> Dictionary:
	var trigger_id := str(data.get("trigger_id", ""))
	var outcome := stack.end_trigger(trigger_id)
	if not outcome.is_empty():
		return outcome
	_cleanup_trigger_domain(stack, trigger_id)
	return VMResult.ok()


func choice_domain_for_current_trigger(stack: ResolutionStack) -> String:
	var domains: Dictionary = stack.context.get("trigger_choice_domains", {})
	return str(domains.get(stack.current_trigger_id(), "effect"))


func source_ref_for_current_trigger(stack: ResolutionStack) -> Dictionary:
	var sources: Dictionary = stack.context.get("trigger_source_refs", {})
	var value: Variant = sources.get(stack.current_trigger_id(), {})
	return Dictionary(value).duplicate(true) if value is Dictionary else {}


func _select_candidate(
	state: GameState,
	stack: ResolutionStack,
	batch: Dictionary,
	index: int,
) -> Dictionary:
	var candidates: Array = batch.get("candidates", [])
	if index < 0 or index >= candidates.size():
		return VMResult.fail("触发索引无效。", "invalid_trigger_batch")
	var candidate := Dictionary(candidates[index]).duplicate(true)
	candidates.remove_at(index)
	batch["candidates"] = candidates
	if not candidates.is_empty():
		if not stack.push_trigger_batch(batch):
			return stack.validation_result()
	if bool(candidate.get("optional", false)):
		return _request_confirmation(state, stack, candidate, str(batch.get(
			"choice_domain", "effect")))
	if not stack.push_trigger(candidate):
		return stack.validation_result()
	return VMResult.ok()


func _request_order_choice(
	state: GameState,
	stack: ResolutionStack,
	batch: Dictionary,
	indices: Array[int],
) -> Dictionary:
	var candidates: Array = batch.get("candidates", [])
	var controller := int(candidates[indices[0]].get("controller", -1))
	var options: Array[Dictionary] = []
	for index in indices:
		var candidate: Dictionary = candidates[index]
		var trigger_id := str(candidate.get("trigger_id", ""))
		options.append({
			"option_id": "trigger:%s" % trigger_id,
			"label": trigger_id,
			"value": {"trigger_id": trigger_id},
			"ref": Dictionary(candidate.get("source_ref", {})).duplicate(true),
		})
	var frame_id := "trigger:order:%d" % stack.sequence
	stack.push_continuation("trigger_order", {
		"kind": "trigger_order",
		"frame_id": frame_id,
		"batch_id": str(batch.get("batch_id", "")),
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, controller, "choose_trigger_order"),
		"choose_trigger_order",
		controller,
		"请选择下一个要结算的触发。",
		options,
		1,
		1,
		false,
		false,
		{
			"domain": str(batch.get("choice_domain", "effect")),
			"purpose": "trigger_order",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"trigger_batch_id": str(batch.get("batch_id", "")),
		},
	)
	var result := VMResult.ok()
	result["pending_choice"] = stack.pending_request
	return result


func _request_confirmation(
	state: GameState,
	stack: ResolutionStack,
	candidate: Dictionary,
	choice_domain: String,
) -> Dictionary:
	var controller := int(candidate.get("controller", -1))
	var trigger_id := str(candidate.get("trigger_id", ""))
	var frame_id := "trigger:confirm:%d" % stack.sequence
	stack.push_continuation("trigger_confirm", {
		"kind": "trigger_confirm",
		"frame_id": frame_id,
		"candidate": candidate.duplicate(true),
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, controller, "confirm_trigger"),
		"confirm_trigger",
		controller,
		"要发动这个触发吗？",
		[{
			"option_id": "trigger:%s" % trigger_id,
			"label": trigger_id,
			"value": {"trigger_id": trigger_id},
			"ref": Dictionary(candidate.get("source_ref", {})).duplicate(true),
		}],
		0,
		1,
		false,
		true,
		{
			"domain": choice_domain,
			"purpose": "trigger_confirm",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"trigger_id": trigger_id,
		},
	)
	var result := VMResult.ok()
	result["pending_choice"] = stack.pending_request
	return result


func _eligible_indices(batch: Dictionary) -> Array[int]:
	var candidates: Array = batch.get("candidates", [])
	var active_player := int(batch.get("active_player", 0))
	var player_order: Array[int] = [active_player, 1 - active_player]
	var controller := -1
	for player_idx in player_order:
		for candidate_value in candidates:
			if int(candidate_value.get("controller", -1)) == player_idx:
				controller = player_idx
				break
		if controller >= 0:
			break
	if controller < 0:
		return []
	var priority := -2147483648
	for candidate_value in candidates:
		if int(candidate_value.get("controller", -1)) == controller:
			priority = maxi(priority, int(candidate_value.get("priority", 0)))
	var result: Array[int] = []
	for index in range(candidates.size()):
		var candidate: Dictionary = candidates[index]
		if (
			int(candidate.get("controller", -1)) == controller
			and int(candidate.get("priority", 0)) == priority
		):
			result.append(index)
	return result


func _candidate_is_live(state: GameState, candidate: Dictionary) -> Dictionary:
	var liveness: Dictionary = candidate.get("liveness", {})
	var mode := str(liveness.get("kind", "source_exists"))
	if mode == "always":
		return {"ok": true, "live": true}
	if mode != "source_exists":
		return {
			"ok": false,
			"message": "未知触发存活规则: %s" % mode,
			"error_code": "invalid_trigger_liveness",
		}
	return {
		"ok": true,
		"live": _ref_is_live(state, Dictionary(candidate.get("source_ref", {}))),
	}


func _guards_pass(state: GameState, candidate: Dictionary) -> Dictionary:
	for guard_value in candidate.get("guards", []):
		if not guard_value is Dictionary:
			return {"ok": false, "error_code": "invalid_trigger_guard"}
		var guard: Dictionary = guard_value
		match str(guard.get("kind", "")):
			"always":
				pass
			"ref_exists":
				if not _ref_is_live(state, Dictionary(guard.get("ref", {}))):
					return {"ok": true, "pass": false}
			_:
				return {
					"ok": false,
					"message": "未知触发条件。",
					"error_code": "invalid_trigger_guard",
				}
	return {"ok": true, "pass": true}


func _ref_is_live(state: GameState, ref: Dictionary) -> bool:
	var kind := str(ref.get("kind", ""))
	var player_idx := int(ref.get("player", -1))
	if player_idx not in [0, 1]:
		return false
	var player := state.get_player(player_idx)
	if kind in ["pokemon", "slot"]:
		var pokemon := player.get_pokemon(str(ref.get("slot", "")))
		return pokemon != null and (
			kind == "slot" or pokemon.card_id == str(ref.get("card_id", "")))
	if kind == "attachment":
		var pokemon := player.get_pokemon(str(ref.get("slot", "")))
		if pokemon == null:
			return false
		var attachment_type := str(ref.get("attachment_type", ""))
		var index := int(ref.get("index", -1))
		if attachment_type == "energy":
			return (
				index >= 0
				and index < pokemon.energy_card_ids.size()
				and str(pokemon.energy_card_ids[index]) == str(ref.get("card_id", ""))
			)
		if attachment_type == "tool":
			return index == 0 and pokemon.attached_tool_id == str(ref.get("card_id", ""))
		return false
	if kind == "card":
		var zone := str(ref.get("zone", ""))
		var cards: Array[String]
		match zone:
			"hand": cards = player.hand
			"deck": cards = player.deck
			"discard": cards = player.discard
			"prizes": cards = player.prizes
			_: return false
		var index := int(ref.get("index", -1))
		return (
			index >= 0
			and index < cards.size()
			and str(cards[index]) == str(ref.get("card_id", ""))
		)
	return false


func _source_slot(candidate: Dictionary) -> String:
	var source_ref: Dictionary = candidate.get("source_ref", {})
	return str(source_ref.get("slot", "active"))


func _cleanup_trigger_domain(stack: ResolutionStack, trigger_id: String) -> void:
	var domains: Dictionary = stack.context.get("trigger_choice_domains", {})
	domains.erase(trigger_id)
	stack.context["trigger_choice_domains"] = domains
	var sources: Dictionary = stack.context.get("trigger_source_refs", {})
	sources.erase(trigger_id)
	if sources.is_empty():
		stack.context.erase("trigger_source_refs")
	else:
		stack.context["trigger_source_refs"] = sources

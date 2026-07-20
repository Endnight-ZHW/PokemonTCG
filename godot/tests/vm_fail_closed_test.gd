extends SceneTree

var failures: Array[String] = []


class HandlerFixture:
	extends RefCounted

	func command_ok(
		_state: GameState,
		_stack: ResolutionStack,
		_rng: PortableRandomSource,
		_args: Dictionary,
		_branches: Dictionary,
		_player_idx: int,
		_source_slot: String,
		_events: Array[Dictionary],
	) -> Dictionary:
		var result := VMResult.ok()
		result["marker"] = "original"
		return result

	func command_duplicate(
		_state: GameState,
		_stack: ResolutionStack,
		_rng: PortableRandomSource,
		_args: Dictionary,
		_branches: Dictionary,
		_player_idx: int,
		_source_slot: String,
		_events: Array[Dictionary],
	) -> Dictionary:
		var result := VMResult.ok()
		result["marker"] = "duplicate"
		return result

	func command_non_dictionary(
		_state: GameState,
		_stack: ResolutionStack,
		_rng: PortableRandomSource,
		_args: Dictionary,
		_branches: Dictionary,
		_player_idx: int,
		_source_slot: String,
		_events: Array[Dictionary],
	) -> Variant:
		return 1

	func command_implicit_success(
		_state: GameState,
		_stack: ResolutionStack,
		_rng: PortableRandomSource,
		_args: Dictionary,
		_branches: Dictionary,
		_player_idx: int,
		_source_slot: String,
		_events: Array[Dictionary],
	) -> Dictionary:
		return {"message": "missing success"}

	func command_non_boolean_success(
		_state: GameState,
		_stack: ResolutionStack,
		_rng: PortableRandomSource,
		_args: Dictionary,
		_branches: Dictionary,
		_player_idx: int,
		_source_slot: String,
		_events: Array[Dictionary],
	) -> Dictionary:
		return {"success": 1, "message": "wrong success type"}

	func command_loop(
		_state: GameState,
		stack: ResolutionStack,
		_rng: PortableRandomSource,
		_args: Dictionary,
		_branches: Dictionary,
		player_idx: int,
		source_slot: String,
		_events: Array[Dictionary],
	) -> Dictionary:
		stack.push_effect(
			{"op": "loop", "args": {}, "branches": {}},
			player_idx,
			source_slot,
		)
		return VMResult.ok()

	func command_overflow_depth(
		_state: GameState,
		stack: ResolutionStack,
		_rng: PortableRandomSource,
		_args: Dictionary,
		_branches: Dictionary,
		player_idx: int,
		source_slot: String,
		_events: Array[Dictionary],
	) -> Dictionary:
		for _index in range(VMContract.MAX_FRAME_DEPTH + 1):
			stack.push_effect(
				{"op": "ok", "args": {}, "branches": {}},
				player_idx,
				source_slot,
			)
		return VMResult.ok()

	func command_mutate_invalid(
		state: GameState,
		_stack: ResolutionStack,
		rng: PortableRandomSource,
		_args: Dictionary,
		_branches: Dictionary,
		_player_idx: int,
		_source_slot: String,
		events: Array[Dictionary],
	) -> Dictionary:
		state.turn_number += 10
		rng.next_u32()
		events.append({"event_type": "must_rollback"})
		return {"message": "missing success"}

	func continuation_ok(
		_state: GameState,
		_stack: ResolutionStack,
		_rng: PortableRandomSource,
		_data: Dictionary,
		_selected: Array[Dictionary],
		_events: Array[Dictionary],
	) -> Dictionary:
		return VMResult.ok()

	func continuation_non_dictionary(
		_state: GameState,
		_stack: ResolutionStack,
		_rng: PortableRandomSource,
		_data: Dictionary,
		_selected: Array[Dictionary],
		_events: Array[Dictionary],
	) -> Variant:
		return null

	func continuation_implicit_success(
		_state: GameState,
		_stack: ResolutionStack,
		_rng: PortableRandomSource,
		_data: Dictionary,
		_selected: Array[Dictionary],
		_events: Array[Dictionary],
	) -> Dictionary:
		return {"message": "missing success"}


func _initialize() -> void:
	_run_tests()
	if failures.is_empty():
		print("VM_FAIL_CLOSED_TESTS_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_tests() -> void:
	var fixture := HandlerFixture.new()
	var interpreter := VMInterpreter.new()
	var command_handlers := {
		"ok": Callable(fixture, "command_ok"),
		"non_dictionary": Callable(fixture, "command_non_dictionary"),
		"implicit_success": Callable(fixture, "command_implicit_success"),
		"non_boolean_success": Callable(fixture, "command_non_boolean_success"),
		"loop": Callable(fixture, "command_loop"),
		"overflow_depth": Callable(fixture, "command_overflow_depth"),
		"mutate_invalid": Callable(fixture, "command_mutate_invalid"),
	}
	var descriptors: Dictionary = {}
	for op in command_handlers:
		descriptors[op] = VMContract.command_descriptor(str(op))
	_check(interpreter.register_command_descriptors(descriptors), "descriptor registration failed")
	for op in command_handlers:
		_check(
			interpreter.register_command_handler(str(op), command_handlers[op]),
			"handler registration failed: %s" % op,
		)
	_check(
		interpreter.register_continuation("ok", Callable(fixture, "continuation_ok")),
		"continuation registration failed",
	)
	_check(
		interpreter.register_continuation(
			"non_dictionary", Callable(fixture, "continuation_non_dictionary")),
		"non-dictionary continuation registration failed",
	)
	_check(
		interpreter.register_continuation(
			"implicit_success", Callable(fixture, "continuation_implicit_success")),
		"implicit continuation registration failed",
	)
	_check(
		interpreter.freeze(command_handlers.keys()).is_empty() and interpreter.is_ready(),
		"complete interpreter registry did not freeze",
	)
	_check(
		not interpreter.register_command_handler("ok", Callable(fixture, "command_ok")),
		"frozen command registry accepted a handler",
	)
	_check(
		not interpreter.register_continuation("late", Callable(fixture, "continuation_ok")),
		"frozen continuation registry accepted a handler",
	)
	var duplicate_command := VMInterpreter.new()
	duplicate_command.register_command_descriptors({
		"ok": VMContract.command_descriptor("ok"),
	})
	duplicate_command.register_command_handler("ok", Callable(fixture, "command_ok"))
	_check(
		not duplicate_command.register_command_handler(
			"ok", Callable(fixture, "command_duplicate")),
		"duplicate command handler was accepted",
	)
	var duplicate_command_errors := duplicate_command.freeze(["ok"])
	_check(
		not duplicate_command.is_ready()
		and "Duplicate VM command handler registration: ok" in duplicate_command_errors,
		"duplicate command registration did not prevent registry startup",
	)
	var duplicate_continuation := VMInterpreter.new()
	duplicate_continuation.register_command_descriptors({
		"ok": VMContract.command_descriptor("ok"),
	})
	duplicate_continuation.register_command_handler("ok", Callable(fixture, "command_ok"))
	duplicate_continuation.register_continuation(
		"ok", Callable(fixture, "continuation_ok"))
	_check(
		not duplicate_continuation.register_continuation(
			"ok", Callable(fixture, "continuation_ok")),
		"duplicate continuation handler was accepted",
	)
	var duplicate_continuation_errors := duplicate_continuation.freeze(["ok"])
	_check(
		not duplicate_continuation.is_ready()
		and "Duplicate VM continuation registration: ok" in duplicate_continuation_errors,
		"duplicate continuation registration did not prevent registry startup",
	)

	var state := GameState.new()
	var rng := PortableRandomSource.new(12345)
	var stack := ResolutionStack.new()
	var original := interpreter.execute_effect(
		state, stack, rng, _spec("ok"), 0, "active", [])
	_check(
		bool(original.get("success", false)) and original.get("marker") == "original",
		"duplicate registration replaced the original command handler",
	)
	_assert_error(
		interpreter.execute_effect(state, stack, rng, _spec("__unknown__"), 0, "active", []),
		"unsupported_vm_op",
		"unknown command",
	)
	for invalid_op in ["non_dictionary", "implicit_success", "non_boolean_success"]:
		_assert_error(
			interpreter.execute_effect(
				state, stack, rng, _spec(invalid_op), 0, "active", []),
			"invalid_vm_result",
			"invalid command result %s" % invalid_op,
		)
	_assert_error(
		interpreter.execute_continuation(
			state, stack, rng, "__unknown__", {}, [], []),
		"unknown_continuation",
		"unknown continuation",
	)
	for operation in ["non_dictionary", "implicit_success"]:
		_assert_error(
			interpreter.execute_continuation(
				state, stack, rng, operation, {}, [], []),
			"invalid_vm_result",
			"invalid continuation result %s" % operation,
		)

	var deep_stack := ResolutionStack.new()
	for _index in range(VMContract.MAX_FRAME_DEPTH + 1):
		deep_stack.push_effect(_spec("ok"), 0, "active")
	var deep_step := interpreter.resolve(state, deep_stack, rng)
	_check(
		not deep_step.success and deep_step.error_code == "vm_frame_depth_limit",
		"pre-existing frame depth overflow was not rejected",
	)

	var pushed_deep_stack := ResolutionStack.new()
	pushed_deep_stack.push_effect(_spec("overflow_depth"), 0, "active")
	var pushed_deep_step := interpreter.resolve(state, pushed_deep_stack, rng)
	_check(
		not pushed_deep_step.success and pushed_deep_step.error_code == "vm_frame_depth_limit",
		"handler-created frame depth overflow was not rejected",
	)

	var loop_stack := ResolutionStack.new()
	loop_stack.push_effect(_spec("loop"), 0, "active")
	var loop_step := interpreter.resolve(state, loop_stack, rng)
	_check(
		not loop_step.success and loop_step.error_code == "vm_step_limit",
		"VM step budget did not stop a self-extending command",
	)

	var rollback_state := GameState.new()
	rollback_state.turn_number = 3
	var rollback_rng := PortableRandomSource.new(9876)
	var transaction_manager := VMTransactionManager.new()
	var checkpoint := transaction_manager.capture_transaction(rollback_state, rollback_rng)
	var rollback_stack := ResolutionStack.new()
	rollback_stack.push_effect(_spec("mutate_invalid"), 0, "active")
	var failed_step := interpreter.resolve(rollback_state, rollback_stack, rollback_rng)
	var rolled_back := transaction_manager.rollback_failed_step(
		rollback_state, rollback_rng, checkpoint, failed_step)
	_check(
		not rolled_back.success
		and rolled_back.error_code == "invalid_vm_result"
		and rollback_state.turn_number == 3
		and rollback_rng.get_state() == int(checkpoint["rng_state"])
		and rollback_state.event_stream._events == checkpoint["events"]
		and rollback_state.resolution_stack == Dictionary(checkpoint["state"])["resolution_stack"],
		"invalid VM result was not rollback-compatible",
	)

	var incomplete := VMInterpreter.new()
	incomplete.register_command_descriptors({
		"missing": VMContract.command_descriptor("missing"),
	})
	var completeness_errors := incomplete.freeze(["missing"])
	_check(
		not completeness_errors.is_empty()
		and not incomplete.is_ready()
		and "VM command descriptor is missing a handler: missing" in completeness_errors,
		"registry completeness did not reject a missing command handler",
	)

	var native_descriptors := VMContract.native_command_descriptors()
	_check(
		native_descriptors.size() == VMContract.native_command_ops().size(),
		"native command descriptor inventory is incomplete",
	)
	var runtime := VMRuntime.new(CardCatalog.shared())
	_check(
		runtime.is_ready()
		and runtime.vm_interpreter.command_registry.descriptors().size()
		== VMContract.native_command_ops().size(),
		"release VM runtime did not freeze a complete native descriptor registry",
	)


func _spec(op: String) -> Dictionary:
	return {"op": op, "args": {}, "branches": {}}


func _assert_error(result: Dictionary, error_code: String, label: String) -> void:
	_check(
		not bool(result.get("success", true))
		and str(result.get("error_code", "")) == error_code,
		"%s did not fail with %s: %s" % [label, error_code, JSON.stringify(result)],
	)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

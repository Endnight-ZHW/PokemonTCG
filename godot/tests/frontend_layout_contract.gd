extends SceneTree

const FrontendContractContextScript = preload("res://tests/frontend_contract_context.gd")
const ShellChoiceSuite = preload("res://tests/frontend_shell_choice_contract_suite.gd")
const ResponsiveSuite = preload("res://tests/frontend_responsive_contract_suite.gd")
const ThemeAccessibilitySuite = preload("res://tests/frontend_theme_accessibility_contract_suite.gd")


func _initialize() -> void:
	call_deferred("_run_contract")


func _run_contract() -> void:
	var context := FrontendContractContextScript.new(self)
	context._settings_node = root.get_node_or_null("AppSettings")
	if context._settings_node == null:
		context.failures.append("AppSettings autoload is unavailable")
		quit(1)
		return
	context._settings_snapshot = context._capture_settings()
	context._apply_reduced_motion()
	var theme_suite := ThemeAccessibilitySuite.new()
	theme_suite.configure(context)
	theme_suite._check_theme_contract()
	theme_suite._check_frontend_font_coverage()
	theme_suite._check_battle_theme_isolation()
	for failure in BattleTableLayoutContract.run():
		context.failures.append("Battle table layout: %s" % failure)
	var catalog := CardCatalog.shared()
	var shell_suite := ShellChoiceSuite.new()
	shell_suite.configure(context)
	await shell_suite._check_main_shell_contract()
	var responsive_suite := ResponsiveSuite.new()
	responsive_suite.configure(context)
	await responsive_suite._check_shared_backdrop_contract()
	await responsive_suite._check_network_intro_contract(catalog)
	await responsive_suite._check_network_scrollbar_width_contract(catalog)
	await responsive_suite._check_deck_tile_visual_contract(catalog)
	await responsive_suite._check_same_instance_resize(catalog)
	await responsive_suite._check_battle_canvas_resize()
	await responsive_suite._check_compact_battle_detail_layout()
	await responsive_suite._check_workbench_compact()
	for viewport_size in context.VIEWPORT_CASES:
		await responsive_suite._check_viewport(viewport_size, catalog)
	for viewport_size in context.TITLE_PORTRAIT_CASES:
		root.size = viewport_size
		await process_frame
		await responsive_suite._check_title(viewport_size)
	context._restore_settings()
	if context.failures.is_empty():
		print("FRONTEND_LAYOUT_CONTRACT_OK sizes=%d safe_inset=%d" % [
			context.VIEWPORT_CASES.size() + context.TITLE_PORTRAIT_CASES.size(),
			context.SAFE_INSET,
		])
		quit(0)
		return
	for failure in context.failures:
		push_error(failure)
	quit(1)

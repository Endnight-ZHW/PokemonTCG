# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['main.py'],
    pathex=[],
    binaries=[],
    datas=[('data/images', 'data/images'), ('data/card_image_mapping.json', 'data'), ('card_data', 'card_data'), ('../docs/RULES.md', '.')],
    hiddenimports=['engine.enums', 'engine.game_state', 'engine.player_state', 'engine.turn_manager', 'engine.action_resolver', 'engine.damage_calculator', 'engine.rules_constants', 'engine.rules_validator', 'engine.effects', 'engine.effects.event_bus', 'engine.effects.damage_effects', 'engine.effects.draw_effects', 'engine.effects.energy_effects', 'engine.effects.modifier_registry', 'engine.effects.search_effects', 'engine.effects.special_effects', 'engine.effects.status_effects', 'network.network_manager', 'network.state_serializer', 'network.message_protocol', 'ui.game_app', 'ui.screen_manager', 'ui.image_manager', 'ui.font_manager', 'ui.audio_manager', 'ui.animation', 'ui.particles', 'ui.transitions', 'ui.coin_flip', 'ui.render_helpers', 'ui.colors', 'ui.screens.title_screen', 'ui.screens.lobby_screen', 'ui.screens.deck_select', 'ui.screens.game_screen', 'ui.screens.game_screen_ai', 'ui.screens.game_screen_network', 'ui.screens.game_screen_rendering', 'ui.screens.end_screen', 'ui.screens.card_image_screen', 'ui.screens.search_screen', 'ui.screens.pass_screen', 'ui.components.game_layout', 'ui.components.board_renderer', 'ui.components.hand_display', 'ui.components.action_menu', 'ui.components.log_panel', 'ui.components.card_detail', 'data.card_registry', 'data.card_models', 'data.deck_definitions', 'card_data.templates', 'card_data.effects', 'engine.ai.challenge', 'engine.ai.challenge.types', 'engine.ai.challenge.layers', 'utils.logger', 'config', 'websockets.sync.server', 'websockets.sync.client', 'PIL.Image'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tests', 'scripts'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='PokemonTCG',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='PokemonTCG',
)

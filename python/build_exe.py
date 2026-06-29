"""Build standalone Windows executable using PyInstaller.

Usage:
    python build_exe.py              # Build with --onedir (recommended)
    python build_exe.py --onefile    # Build single exe (image cache lost on exit)
    python build_exe.py --clean      # Clean before building

Output:
    dist/PokemonTCG/PokemonTCG.exe   (--onedir folder containing exe + data)
    dist/PokemonTCG.exe              (--onefile single self-extracting exe)
"""
import os
import sys
import shutil
import subprocess
import argparse

APP_NAME = "宝可梦卡牌对战"
EXE_NAME = "PokemonTCG"
MAIN_SCRIPT = "main.py"

# (source_path, dest_dir_in_bundle)
DATA_BUNDLES = [
    ("data/images", "data/images"),
    ("data/card_image_mapping.json", "data"),
    ("card_data", "card_data"),
    ("../docs/RULES.md", "."),
]

HIDDEN_IMPORTS = [
    "engine.enums", "engine.game_state", "engine.player_state",
    "engine.turn_manager", "engine.action_resolver", "engine.damage_calculator",
    "engine.rules_constants",
    "engine.rules_validator",
    "engine.effects", "engine.effects.event_bus", "engine.effects.damage_effects",
    "engine.effects.draw_effects", "engine.effects.energy_effects",
    "engine.effects.search_effects",
    "engine.effects.special_effects", "engine.effects.status_effects",
    "network.network_manager", "network.state_serializer", "network.message_protocol",
    "ui.game_app", "ui.screen_manager", "ui.image_manager", "ui.font_manager",
    "ui.audio_manager", "ui.animation", "ui.particles", "ui.transitions",
    "ui.coin_flip", "ui.render_helpers", "ui.colors",
    "ui.screens.title_screen", "ui.screens.lobby_screen",
    "ui.screens.deck_select", "ui.screens.game_screen",
    "ui.screens.game_screen_ai", "ui.screens.game_screen_network",
    "ui.screens.game_screen_rendering",
    "ui.screens.end_screen", "ui.screens.card_image_screen",
    "ui.screens.search_screen", "ui.screens.pass_screen",
    "ui.components.game_layout", "ui.components.board_renderer",
    "ui.components.hand_display", "ui.components.action_menu",
    "ui.components.log_panel", "ui.components.card_detail",
    "data.card_registry", "data.card_models", "data.deck_definitions",
    "card_data.templates", "card_data.effects",
    "engine.ai.challenge", "engine.ai.challenge.types", "engine.ai.challenge.layers",
    "utils.logger", "config",
    "websockets.sync.server", "websockets.sync.client",
    "PIL.Image",
]


def sep():
    return ";" if sys.platform == "win32" else ":"


def check_pyinstaller():
    try:
        import PyInstaller
        print(f"PyInstaller version: {PyInstaller.__version__}")
    except ImportError:
        print("PyInstaller not found. Installing...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "pyinstaller"])
        print("Done.")


def clean():
    for d in ["build", "dist"]:
        if os.path.exists(d):
            shutil.rmtree(d)
            print(f"Removed {d}/")
    for f in os.listdir("."):
        if f.endswith(".spec"):
            os.remove(f)
            print(f"Removed {f}")


def build(onefile=False):
    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--name", EXE_NAME,
        "--console",
        "--clean",
        "--noconfirm",
    ]

    if onefile:
        cmd.append("--onefile")
    else:
        cmd.append("--onedir")

    s = sep()
    for src, dest in DATA_BUNDLES:
        if not os.path.exists(src):
            print(f"WARNING: Data source not found, skipping: {src}")
            continue
        cmd.extend(["--add-data", f"{src}{s}{dest}"])

    for imp in HIDDEN_IMPORTS:
        cmd.extend(["--hidden-import", imp])

    # Exclude __pycache__ / test / scripts from the bundle
    cmd.extend(["--exclude-module", "tests"])
    cmd.extend(["--exclude-module", "scripts"])

    # Exclude DL / conda packages — these are only for AI training,
    # not needed at runtime, and would bloat the exe by several GB.
    dl_excludes = [
        "torch", "torchvision", "torchaudio", "torchtext",
        "numpy", "numpy._core", "numpy.linalg", "numpy.random",
        "matplotlib", "matplotlib.pyplot", "matplotlib.backends",
        "scipy", "pandas", "sklearn", "tensorflow", "keras",
        "jax", "onnx", "onnxruntime",
    ]
    for mod in dl_excludes:
        cmd.extend(["--exclude-module", mod])

    cmd.append(MAIN_SCRIPT)

    print("=" * 60)
    print(f"  Building {APP_NAME} ({EXE_NAME})")
    print(f"  Mode: {'--onefile' if onefile else '--onedir'}")
    print("=" * 60)
    print(f"\n  {' '.join(cmd)}\n")

    result = subprocess.run(cmd)

    if result.returncode == 0:
        dist = os.path.join("dist", EXE_NAME)
        if onefile:
            print(f"\n  Build successful: {dist}.exe")
        else:
            exe = os.path.join(dist, f"{EXE_NAME}.exe")
            print(f"\n  Build successful!")
            print(f"  Folder: {dist}/")
            print(f"  Exe:    {exe}")
    else:
        print(f"\n  Build FAILED (exit code {result.returncode})")
        sys.exit(result.returncode)


def main():
    parser = argparse.ArgumentParser(
        description=f"Build {APP_NAME} into a standalone exe"
    )
    parser.add_argument("--onefile", action="store_true",
                        help="Bundle into a single .exe (image cache lost on exit)")
    parser.add_argument("--clean", action="store_true",
                        help="Remove build/ and dist/ before building")
    args = parser.parse_args()

    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    check_pyinstaller()

    if args.clean:
        clean()

    build(onefile=args.onefile)


if __name__ == "__main__":
    main()

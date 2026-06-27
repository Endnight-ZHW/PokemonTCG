"""Pokemon TCG Battle - UI entrypoint."""
import os
import sys

os.chdir(os.path.dirname(os.path.abspath(__file__)))

# Ask SDL/Pygame to show the platform IME candidate UI when text input is active.
# This must be set before pygame is imported by ui.game_app.
os.environ.setdefault("SDL_IME_SHOW_UI", "1")

# Force UTF-8 encoding for Windows console (safe method)
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass
from utils.logger import setup_logging
setup_logging()

from ui.game_app import GameApp


def main():
    GameApp().run()


if __name__ == '__main__':
    main()

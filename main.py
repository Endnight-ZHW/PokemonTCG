"""Pokemon TCG Battle - UI entrypoint."""
import sys

# Force UTF-8 encoding for Windows console (safe method)
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

sys.path.insert(0, '.')

from utils.logger import setup_logging
setup_logging()

from ui.game_app import GameApp


def main():
    GameApp().run()


if __name__ == '__main__':
    main()

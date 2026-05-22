"""Cache manager for card data and images."""
import json
import os
from utils.logger import get_logger

logger = get_logger(__name__)
from config import CARD_CACHE_FILE, IMAGE_CACHE_DIR


class CacheManager:
    """Manages local JSON cache of card data and downloaded images."""

    def __init__(self, cache_file: str = None):
        self.cache_file = cache_file or CARD_CACHE_FILE
        self.image_dir = IMAGE_CACHE_DIR

    def load_cached_cards(self) -> dict[str, dict]:
        """Load all cached card data from JSON. Returns {id: raw_json_data}."""
        if not os.path.exists(self.cache_file):
            return {}
        try:
            with open(self.cache_file, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            logger.error("cache load error: %s", e)
            return {}

    def save_cards_to_cache(self, cards: dict[str, dict]):
        """Write card data to cache JSON file."""
        os.makedirs(os.path.dirname(self.cache_file), exist_ok=True)
        with open(self.cache_file, "w", encoding="utf-8") as f:
            json.dump(cards, f, ensure_ascii=False, indent=2)

    def is_cache_populated(self) -> bool:
        """Check if the cache has at least some cards."""
        cards = self.load_cached_cards()
        return len(cards) >= 20

    def get_cached_image_path(self, api_id: str) -> str | None:
        """Return local image path if cached, else None."""
        candidates = [
            os.path.join(self.image_dir, f"{api_id}.png"),
            os.path.join(self.image_dir, f"{api_id}.jpg"),
            os.path.join(self.image_dir, f"{api_id}.webp"),
        ]
        for path in candidates:
            if os.path.exists(path):
                return path
        return None

    def cache_size(self) -> int:
        """Number of cards in cache."""
        return len(self.load_cached_cards())

    def clear_cache(self):
        """Remove all cached data."""
        if os.path.exists(self.cache_file):
            os.remove(self.cache_file)
        if os.path.exists(self.image_dir):
            import shutil
            shutil.rmtree(self.image_dir)

    def get_missing_ids(self, needed_ids: list[str]) -> list[str]:
        """Return list of IDs not in cache."""
        cached = self.load_cached_cards()
        return [cid for cid in needed_ids if cid not in cached]

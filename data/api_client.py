"""API client for fetching card data from pokemontcg.io."""
import os
import requests
import time
from utils.logger import get_logger

logger = get_logger(__name__)
from config import POKEMON_TCG_API_KEY, POKEMON_TCG_API_URL, IMAGE_CACHE_DIR


class ApiClient:
    """Wrapper for pokemontcg.io v2 API."""

    def __init__(self, api_key: str = None):
        self.api_key = api_key or POKEMON_TCG_API_KEY
        self.session = requests.Session()
        if self.api_key:
            self.session.headers.update({"X-Api-Key": self.api_key})
        self._last_request = 0
        self._min_interval = 0.05  # 50ms between requests (safe for free tier)

    def _rate_limit(self):
        """Ensure minimum interval between requests."""
        elapsed = time.time() - self._last_request
        if elapsed < self._min_interval:
            time.sleep(self._min_interval - elapsed)
        self._last_request = time.time()

    def fetch_card(self, card_id: str) -> dict | None:
        """Fetch a single card by API ID (e.g. 'sv3-26')."""
        self._rate_limit()
        try:
            resp = self.session.get(
                f"{POKEMON_TCG_API_URL}/cards/{card_id}",
                timeout=10
            )
            if resp.status_code == 200:
                data = resp.json()
                return data.get("data", data)
            logger.warning("API warning for %s: HTTP %s", card_id, resp.status_code)
            return None
        except Exception as e:
            logger.error("API error fetching %s: %s", card_id, e)
            return None

    def fetch_cards_batch(self, card_ids: list[str]) -> dict[str, dict]:
        """Fetch multiple cards. Returns dict of {id: card_data}."""
        results = {}
        # Fetch in chunks of 20 to keep queries manageable
        chunk_size = 20
        for i in range(0, len(card_ids), chunk_size):
            chunk = card_ids[i:i + chunk_size]
            query = " OR ".join(f"id:{cid}" for cid in chunk)
            self._rate_limit()
            try:
                resp = self.session.get(
                    f"{POKEMON_TCG_API_URL}/cards",
                    params={"q": query, "pageSize": 250},
                    timeout=15
                )
                if resp.status_code == 200:
                    data = resp.json()
                    for card in data.get("data", []):
                        results[card["id"]] = card
                else:
                    logger.warning("batch API error: HTTP %s", resp.status_code)
            except Exception as e:
                logger.error("batch API error: %s", e)
            time.sleep(0.1)
        return results

    def download_image(self, url: str, save_path: str) -> bool:
        """Download a card image to local cache. Returns success."""
        if os.path.exists(save_path):
            return True
        os.makedirs(os.path.dirname(save_path), exist_ok=True)
        try:
            resp = self.session.get(url, timeout=15)
            if resp.status_code == 200:
                with open(save_path, "wb") as f:
                    f.write(resp.content)
                return True
        except Exception as e:
            logger.error("image download error: %s", e)
        return False

    def download_card_image(self, card_data: dict) -> str | None:
        """Download card image and return local path, or None on failure."""
        images = card_data.get("images", {})
        url = images.get("small") or images.get("large")
        if not url:
            return None
        card_id = card_data["id"]
        ext = os.path.splitext(url.split("?")[0])[1] or ".png"
        save_path = os.path.join(IMAGE_CACHE_DIR, f"{card_id}{ext}")
        if self.download_image(url, save_path):
            return save_path
        return None

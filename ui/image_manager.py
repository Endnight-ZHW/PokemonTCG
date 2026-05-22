"""Card image manager - discovers, caches, and serves card face images."""
import json
import os
import shutil
from typing import Optional
from utils.logger import get_logger

logger = get_logger(__name__)

import pygame

from config import IMAGE_CACHE_DIR, CARD_IMAGE_MAPPING_FILE

_IMAGE_SUBDIRS = ["宝可梦", "支援者", "物品", "竞技场", "宝可梦道具", "能量"]
_IMAGE_EXTS = (".webp", ".png", ".jpg", ".jpeg")


def _try_convert_alpha(surface: pygame.Surface) -> pygame.Surface:
    """Call convert_alpha() for optimal blit performance.
    Only suppressed when no display is initialized (shouldn't happen in normal flow)."""
    try:
        return surface.convert_alpha()
    except pygame.error:
        # Display not initialized yet — surface format will be suboptimal
        return surface


def _load_image_surface(path: str) -> Optional[pygame.Surface]:
    """Load an image as a pygame Surface.
    Tries pygame's native loader first; falls back to Pillow for WebP."""
    try:
        surface = pygame.image.load(path)
        return _try_convert_alpha(surface)
    except pygame.error:
        pass

    try:
        from PIL import Image
        pil_img = Image.open(path).convert("RGBA")
        raw = pil_img.tobytes("raw", "RGBA")
        surface = pygame.image.frombuffer(raw, pil_img.size, "RGBA")
        return _try_convert_alpha(surface)
    except Exception:
        return None


class ImageManager:
    """Singleton that discovers, caches, and serves card face images."""

    def __init__(self):
        self._image_map: dict[str, str] = {}  # card_name -> absolute path
        self._custom_map: dict[str, str] = {}  # card_name -> relative path
        self._surface_cache: dict[str, Optional[pygame.Surface]] = {}
        self._initialized = False
        self.initialize()

    def initialize(self):
        """Scan images and load custom mappings."""
        self._image_map = self._scan_images()
        self._load_custom_mappings()
        self._initialized = True
        auto_count = len(self._image_map)
        custom_count = len(self._custom_map)
        logger.info("images auto-discovered: %s, custom mappings: %s", auto_count, custom_count)

    def _scan_images(self) -> dict[str, str]:
        """Walk subdirectories under IMAGE_CACHE_DIR and map card names to file paths."""
        mapping: dict[str, str] = {}
        base = IMAGE_CACHE_DIR
        if not os.path.isdir(base):
            return mapping

        for subdir in _IMAGE_SUBDIRS:
            dirpath = os.path.join(base, subdir)
            if not os.path.isdir(dirpath):
                continue
            for filename in os.listdir(dirpath):
                name, ext = os.path.splitext(filename)
                if ext.lower() in _IMAGE_EXTS and name not in mapping:
                    mapping[name] = os.path.join(dirpath, filename)
        return mapping

    def _load_custom_mappings(self):
        """Load custom card-to-image mappings from JSON."""
        path = CARD_IMAGE_MAPPING_FILE
        if not os.path.exists(path):
            return
        try:
            with open(path, "r", encoding="utf-8") as f:
                self._custom_map = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            logger.error("failed to load custom mappings: %s", e)
            self._custom_map = {}

    def _save_custom_mappings(self):
        """Persist custom mappings to JSON."""
        os.makedirs(os.path.dirname(CARD_IMAGE_MAPPING_FILE), exist_ok=True)
        with open(CARD_IMAGE_MAPPING_FILE, "w", encoding="utf-8") as f:
            json.dump(self._custom_map, f, ensure_ascii=False, indent=2)

    def _load_image(self, path: str) -> Optional[pygame.Surface]:
        """Load and cache a single image surface."""
        surface = _load_image_surface(path)
        if surface is None:
            logger.warning("failed to load image: %s", path)
        return surface

    # ── Public API ──

    def get_card_image(self, card_name: str, card_id: str = "") -> Optional[pygame.Surface]:
        """Return the pygame Surface for a card, or None if no image exists.
        Results are cached after first load.
        Looks up by card_id first (for same-name disambiguation), then by card_name."""
        lookup_key = card_id or card_name
        cache_key = lookup_key

        if cache_key in self._surface_cache:
            return self._surface_cache[cache_key]

        # Check custom mappings: try card_id first, then card_name
        path = None
        if card_id:
            rel = self._custom_map.get(card_id)
            if rel:
                path = rel if os.path.isabs(rel) else os.path.join(
                    os.path.dirname(CARD_IMAGE_MAPPING_FILE), "..", rel)
                path = os.path.normpath(path)

        if not path:
            rel = self._custom_map.get(card_name)
            if rel:
                path = rel if os.path.isabs(rel) else os.path.join(
                    os.path.dirname(CARD_IMAGE_MAPPING_FILE), "..", rel)
                path = os.path.normpath(path)

        if not path:
            # Auto-discovered: try card_id first, then card_name
            if card_id:
                path = self._image_map.get(card_id)
            if not path:
                path = self._image_map.get(card_name)

        if path and os.path.exists(path):
            surface = self._load_image(path)
        else:
            surface = None

        self._surface_cache[cache_key] = surface
        return surface

    def has_image(self, card_name_or_id: str) -> bool:
        """Check whether an image actually exists for the given card name or ID."""
        # Check custom mappings first
        rel = self._custom_map.get(card_name_or_id)
        if rel:
            path = rel if os.path.isabs(rel) else os.path.join(
                os.path.dirname(CARD_IMAGE_MAPPING_FILE), "..", rel)
            return os.path.exists(os.path.normpath(path))
        # Then auto-discovered
        path = self._image_map.get(card_name_or_id)
        return path is not None and os.path.exists(path)

    def get_image_path(self, card_name_or_id: str) -> Optional[str]:
        """Return the file path for a card's image, if it actually exists."""
        rel = self._custom_map.get(card_name_or_id)
        if rel:
            path = rel if os.path.isabs(rel) else os.path.join(
                os.path.dirname(CARD_IMAGE_MAPPING_FILE), "..", rel)
            path = os.path.normpath(path)
            return path if os.path.exists(path) else None
        path = self._image_map.get(card_name_or_id)
        if path and os.path.exists(path):
            return path
        return None

    def get_available_images(self) -> list[str]:
        """Return sorted list of all discovered image names."""
        return sorted(self._image_map.keys())

    def get_available_image_path(self, image_name: str) -> Optional[str]:
        """Return the full path for a discovered image by name."""
        return self._image_map.get(image_name)

    def set_card_image(self, card_name: str, image_path: str) -> bool:
        """Assign an image to a card. Persists to JSON.
        image_path can be absolute, or relative to project root."""
        abs_path = os.path.normpath(image_path)
        try:
            rel_path = os.path.relpath(abs_path)
        except ValueError:
            rel_path = abs_path

        self._custom_map[card_name] = rel_path
        self._surface_cache.pop(card_name, None)
        self._save_custom_mappings()
        return True

    def remove_card_image(self, card_name: str, delete_file: bool = False):
        """Remove custom image assignment for a card.
        If delete_file is True, also delete the image file from disk."""
        rel = self._custom_map.pop(card_name, None)
        self._surface_cache.pop(card_name, None)
        self._save_custom_mappings()

        if delete_file and rel:
            abs_path = rel if os.path.isabs(rel) else os.path.join(
                os.path.dirname(CARD_IMAGE_MAPPING_FILE), "..", rel)
            abs_path = os.path.normpath(abs_path)
            try:
                os.remove(abs_path)
            except OSError as e:
                logger.error("failed to delete file: %s", e)

    def bind_card_image(self, card_name: str, source_path: str, target_subdir: str,
                        card_id: str = "") -> bool:
        """Rename/move an image file to data/images/{target_subdir}/{card_name}.{ext}.
        If the target file already exists and belongs to a different card, appends _card_id.
        Saves both card_name and card_id mappings for disambiguation."""
        _, ext = os.path.splitext(source_path)
        if not ext:
            ext = ".webp"
        target_dir = os.path.join(IMAGE_CACHE_DIR, target_subdir)
        os.makedirs(target_dir, exist_ok=True)
        target_path = os.path.join(target_dir, card_name + ext.lower())

        # If target exists and owned by a different card, use {name}_{id}.{ext}
        if os.path.exists(target_path) and card_id:
            existing_owner = None
            for k, v in self._custom_map.items():
                if v == self._rel_path(target_path):
                    existing_owner = k
                    break
            if existing_owner and existing_owner != card_id and existing_owner != card_name:
                target_path = os.path.join(target_dir, f"{card_name}_{card_id}{ext.lower()}")

        try:
            shutil.move(source_path, target_path)
        except OSError as e:
            logger.error("failed to move image: %s", e)
            return False

        try:
            rel_path = os.path.relpath(target_path)
        except ValueError:
            rel_path = target_path

        # Save both name and id mappings
        self._custom_map[card_name] = rel_path
        if card_id:
            self._custom_map[card_id] = rel_path
        self._surface_cache.pop(card_name, None)
        if card_id:
            self._surface_cache.pop(card_id, None)
        self._save_custom_mappings()

        # Re-scan to pick up the new file
        self._image_map = self._scan_images()
        logger.info("bound '%s' (id=%s) -> %s", card_name, card_id, target_path)
        return True

    @staticmethod
    def _rel_path(path: str) -> str:
        try:
            return os.path.relpath(path)
        except ValueError:
            return path

    def get_card_back(self, filename: str = "卡背.webp") -> Optional[pygame.Surface]:
        """Load and cache the card back image from data/images/.
        Falls back to a procedural blue gradient surface if the file is missing."""
        cache_key = "__CARD_BACK__"
        if cache_key in self._surface_cache:
            return self._surface_cache[cache_key]

        base = IMAGE_CACHE_DIR
        path = os.path.join(base, filename)
        if os.path.exists(path):
            surface = self._load_image(path)
            if surface is not None:
                self._surface_cache[cache_key] = surface
                return surface

        # Procedural fallback: blue gradient with border
        w, h = 110, 155
        surf = pygame.Surface((w, h))
        for gy in range(h):
            t = gy / h
            r = int(30 + 15 * (1 - t))
            g = int(45 + 20 * (1 - t))
            b = int(120 + 30 * (1 - t))
            pygame.draw.line(surf, (r, g, b), (0, gy), (w, gy))
        pygame.draw.rect(surf, (200, 180, 60), surf.get_rect(), 2, border_radius=8)
        # Simple Pokeball-like circle
        cx, cy = w // 2, h // 2
        pygame.draw.circle(surf, (220, 220, 240), (cx, cy), 20, 2)
        pygame.draw.circle(surf, (220, 220, 240), (cx, cy), 8, 2)
        pygame.draw.line(surf, (180, 180, 200), (0, cy), (w, cy), 1)
        surf = _try_convert_alpha(surf)
        self._surface_cache[cache_key] = surf
        return surf

    def reload(self):
        """Clear caches and re-scan disk. Useful after adding images at runtime."""
        self._surface_cache.clear()
        self._image_map = self._scan_images()
        self._load_custom_mappings()
        logger.info("reloaded: %s images, %s custom mappings.", len(self._image_map), len(self._custom_map))

    # ── Properties ──

    @property
    def mapped_count(self) -> int:
        """Return how many unique card names have actual existing images (auto + custom)."""
        count = 0
        seen = set()
        # Custom mappings: check file existence
        for key in self._custom_map:
            if key not in seen and self.has_image(key):
                seen.add(key)
                count += 1
        # Auto-discovered: files should exist (verified during scan)
        for key in self._image_map:
            if key not in seen and os.path.exists(self._image_map[key]):
                seen.add(key)
                count += 1
        return count

    @property
    def custom_count(self) -> int:
        """Return how many custom mappings have existing files."""
        return sum(1 for k in self._custom_map if self.has_image(k))

    @property
    def auto_count(self) -> int:
        """Return how many auto-discovered images exist."""
        return sum(1 for path in self._image_map.values() if os.path.exists(path))

    # ── Smart assignment ──

    def assign_card_image(self, card_name: str, source_path: str, target_subdir: str,
                          card_id: str = "") -> bool:
        """Assign an image to a card, always moving/renaming to the target directory."""
        return self.bind_card_image(card_name, source_path, target_subdir, card_id)

    def clear_all_custom_mappings(self) -> int:
        """Remove all custom image bindings. Returns count of removed mappings."""
        count = len(self._custom_map)
        self._custom_map.clear()
        self._surface_cache.clear()
        self._save_custom_mappings()
        return count

# ── Module-level singleton ──

_image_manager_instance: Optional[ImageManager] = None


def get_image_manager() -> ImageManager:
    global _image_manager_instance
    if _image_manager_instance is None:
        _image_manager_instance = ImageManager()
    return _image_manager_instance

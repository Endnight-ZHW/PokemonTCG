"""Card image manager - discovers, normalizes, and serves card face images."""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
import re
import shutil
from typing import Optional

import pygame

from config import IMAGE_CACHE_DIR, CARD_IMAGE_MAPPING_FILE
from utils.logger import get_logger

logger = get_logger(__name__)

_IMAGE_SUBDIRS = ["宝可梦", "支援者", "物品", "竞技场", "宝可梦道具", "能量"]
_IMAGE_EXTS = (".webp", ".png", ".jpg", ".jpeg")
_IMPORT_IMAGE_EXTS = _IMAGE_EXTS + (".bmp", ".gif", ".tif", ".tiff")
_INVALID_FILENAME_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]+')


@dataclass(frozen=True)
class CardImageRecord:
    """Resolved card image information."""

    card_id: str
    card_name: str
    path: str
    rel_path: str
    filename: str
    group: str
    exists: bool


@dataclass(frozen=True)
class ImageCandidate:
    """Image file shown as a bindable candidate in the manager UI."""

    name: str
    path: str
    rel_path: str
    group: str
    assigned: bool = False
    size_bytes: int = 0


@dataclass(frozen=True)
class MigrationReport:
    """Summary of a card image normalization pass."""

    normalized_count: int = 0
    copied_count: int = 0
    already_normalized_count: int = 0
    skipped_count: int = 0
    removed_legacy_keys: int = 0
    removed_legacy_files_count: int = 0
    message: str = ""


@dataclass(frozen=True)
class DeleteResult:
    """Result of deleting a card image file."""

    deleted: bool
    message: str
    path: str = ""


def _try_convert_alpha(surface: pygame.Surface) -> pygame.Surface:
    """Call convert_alpha() for optimal blit performance when possible."""
    try:
        return surface.convert_alpha()
    except pygame.error:
        return surface


def _load_image_surface(path: str) -> Optional[pygame.Surface]:
    """Load an image as a pygame Surface. Falls back to Pillow for WebP."""
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


def _subdir_for_card(card) -> str:
    if getattr(card, "is_pokemon", False):
        return "宝可梦"
    if getattr(card, "is_trainer", False):
        trainer_type = getattr(card, "trainer_type", "") or (
            card.subtypes[0] if getattr(card, "subtypes", None) else ""
        )
        return {
            "Item": "物品",
            "Supporter": "支援者",
            "Stadium": "竞技场",
            "Tool": "宝可梦道具",
        }.get(trainer_type, "物品")
    if getattr(card, "is_energy", False):
        return "能量"
    return "物品"


class ImageManager:
    """Discovers, normalizes, caches, and serves card face images."""

    def __init__(
        self,
        image_cache_dir: str | None = None,
        mapping_file: str | None = None,
        *,
        initialize: bool = True,
    ):
        self.image_cache_dir = os.path.normpath(image_cache_dir or IMAGE_CACHE_DIR)
        self.mapping_file = os.path.normpath(mapping_file or CARD_IMAGE_MAPPING_FILE)
        self.project_root = os.path.normpath(os.path.join(os.path.dirname(self.mapping_file), ".."))
        self._image_map: dict[str, str] = {}     # image stem -> absolute path
        self._custom_map: dict[str, str] = {}    # api_id/name -> project-root relative path
        self._surface_cache: dict[str, Optional[pygame.Surface]] = {}
        self._initialized = False
        if initialize:
            self.initialize()

    def initialize(self):
        """Scan images and load custom mappings."""
        self._image_map = self._scan_images()
        self._load_custom_mappings()
        self._initialized = True
        logger.info(
            "images auto-discovered: %s, custom mappings: %s",
            len(self._image_map),
            len(self._custom_map),
        )

    # ── Path helpers ──

    def _scan_images(self) -> dict[str, str]:
        """Walk subdirectories under image_cache_dir and map stems to file paths."""
        mapping: dict[str, str] = {}
        base = self.image_cache_dir
        if not os.path.isdir(base):
            return mapping

        for root, _dirs, files in os.walk(base):
            if os.path.normpath(root) == os.path.normpath(base):
                # Only card backs live directly under data/images; card faces are grouped.
                files = [f for f in files if f != "卡背.webp"]
            for filename in files:
                name, ext = os.path.splitext(filename)
                if ext.lower() in _IMPORT_IMAGE_EXTS and name not in mapping:
                    mapping[name] = os.path.join(root, filename)
        return mapping

    def _load_custom_mappings(self):
        """Load custom card-to-image mappings from JSON."""
        if not os.path.exists(self.mapping_file):
            self._custom_map = {}
            return
        try:
            with open(self.mapping_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            self._custom_map = data if isinstance(data, dict) else {}
        except (json.JSONDecodeError, IOError) as e:
            logger.error("failed to load custom mappings: %s", e)
            self._custom_map = {}

    def _save_custom_mappings(self):
        """Persist custom mappings to JSON."""
        os.makedirs(os.path.dirname(self.mapping_file), exist_ok=True)
        with open(self.mapping_file, "w", encoding="utf-8") as f:
            json.dump(self._custom_map, f, ensure_ascii=False, indent=2)

    def _abs_path(self, raw_path: str) -> str:
        path = raw_path if os.path.isabs(raw_path) else os.path.join(self.project_root, raw_path)
        return os.path.normpath(path)

    def _rel_path(self, path: str) -> str:
        abs_path = os.path.normpath(path)
        try:
            return os.path.normpath(os.path.relpath(abs_path, self.project_root))
        except ValueError:
            return abs_path

    def _mapping_path(self, key: str) -> Optional[str]:
        """Resolve a custom mapping key to an existing absolute path."""
        rel = self._custom_map.get(key)
        if not rel:
            return None
        path = self._abs_path(rel)
        return path if os.path.exists(path) else None

    @staticmethod
    def _sanitize_filename_part(value: str, fallback: str) -> str:
        value = str(value or "").strip()

        def _replace(match: re.Match[str]) -> str:
            return "__" if len(match.group(0)) > 1 else "_"

        value = _INVALID_FILENAME_CHARS.sub(_replace, value)
        value = value.rstrip(" .")
        return value or fallback

    def generate_card_filename(self, card, ext: str = ".webp") -> str:
        """Return the canonical file name: card name + api_id, Windows-safe."""
        raw_ext = ext or ".webp"
        if not raw_ext.startswith("."):
            raw_ext = "." + raw_ext
        name = self._sanitize_filename_part(getattr(card, "name", ""), "card")
        card_id = self._sanitize_filename_part(getattr(card, "api_id", ""), "unknown")
        return f"{name}__{card_id}{raw_ext.lower()}"

    def _target_path_for_card(self, card, ext: str) -> str:
        subdir = _subdir_for_card(card)
        target_dir = os.path.join(self.image_cache_dir, subdir)
        return os.path.join(target_dir, self.generate_card_filename(card, ext))

    def _normalized_existing_path(self, card) -> Optional[str]:
        target_dir = os.path.join(self.image_cache_dir, _subdir_for_card(card))
        for ext in _IMPORT_IMAGE_EXTS:
            candidate = os.path.join(target_dir, self.generate_card_filename(card, ext))
            if os.path.exists(candidate):
                return os.path.normpath(candidate)
        return None

    def _ambiguous_card_name(self, card_name: str, card_id: str = "") -> bool:
        """Return True when a name points to multiple distinct card IDs."""
        if not card_name:
            return False
        try:
            from data.card_registry import CardRegistry
            matches = CardRegistry.get_by_name(card_name)
        except Exception:
            return False
        ids = {getattr(card, "api_id", "") for card in matches if getattr(card, "api_id", "")}
        if card_id:
            return len(ids) > 1 and card_id in ids
        return len(ids) > 1

    def _load_image(self, path: str) -> Optional[pygame.Surface]:
        surface = _load_image_surface(path)
        if surface is None:
            logger.warning("failed to load image: %s", path)
        return surface

    def _write_webp_image(self, source_path: str, target_path: str) -> bool:
        """Write source image to target_path as WebP, copying directly for WebP input."""
        source_norm = os.path.normcase(os.path.normpath(source_path))
        target_norm = os.path.normcase(os.path.normpath(target_path))
        if source_norm == target_norm:
            return True
        try:
            if os.path.splitext(source_path)[1].lower() == ".webp":
                shutil.copy2(source_path, target_path)
                return True
            from PIL import Image
            with Image.open(source_path) as img:
                if img.mode not in ("RGB", "RGBA"):
                    img = img.convert("RGBA" if "A" in img.getbands() else "RGB")
                img.save(target_path, format="WEBP", quality=95, method=6)
            return True
        except Exception as e:
            logger.error("failed to convert image to WebP %s -> %s: %s", source_path, target_path, e)
            return False

    def _path_is_under_image_cache(self, path: str) -> bool:
        try:
            return os.path.commonpath([os.path.normpath(path), self.image_cache_dir]) == self.image_cache_dir
        except ValueError:
            return False

    def is_card_back_path(self, path: str | None) -> bool:
        """Return True when a path points at the source card-back placeholder."""
        if not path:
            return False
        card_back = os.path.normcase(os.path.normpath(os.path.join(self.image_cache_dir, "卡背.webp")))
        return os.path.normcase(os.path.normpath(self._abs_path(path))) == card_back

    # ── Public resource API ──

    def resolve_card_image(self, card) -> Optional[str]:
        """Return the exact image path for a Card, using api_id as authority."""
        if card is None:
            return None

        card_id = getattr(card, "api_id", "") or ""
        card_name = getattr(card, "name", "") or ""

        if card_id:
            path = self._mapping_path(card_id)
            if path:
                return path

        path = self._normalized_existing_path(card)
        if path:
            return path

        if not self._ambiguous_card_name(card_name, card_id):
            path = self._mapping_path(card_name)
            if path:
                return path
            path = self._image_map.get(card_name)
            if path and os.path.exists(path):
                return os.path.normpath(path)

        return None

    def get_card_image_record(self, card) -> Optional[CardImageRecord]:
        """Return rich image info for a card, or None if no image resolves."""
        path = self.resolve_card_image(card)
        if not path:
            return None
        rel = self._rel_path(path)
        return CardImageRecord(
            card_id=getattr(card, "api_id", ""),
            card_name=getattr(card, "name", ""),
            path=path,
            rel_path=rel,
            filename=os.path.basename(path),
            group=os.path.basename(os.path.dirname(path)),
            exists=os.path.exists(path),
        )

    def has_card_image(self, card) -> bool:
        """Check whether the given Card has an exact resolvable image."""
        return self.resolve_card_image(card) is not None

    def card_uses_card_back(self, card) -> bool:
        """Check whether the given Card is explicitly mapped to the card back."""
        return self.is_card_back_path(self.resolve_card_image(card))

    def has_real_card_image(self, card) -> bool:
        """Check whether a Card has an image that is not the card-back placeholder."""
        path = self.resolve_card_image(card)
        return path is not None and not self.is_card_back_path(path)

    def assign_card_image_for_card(self, card, source_path: str) -> bool:
        """Copy an image into the canonical WebP location and map it by api_id."""
        if card is None or not getattr(card, "api_id", ""):
            return False
        if not source_path or not os.path.exists(source_path):
            return False
        target_path = self._target_path_for_card(card, ".webp")
        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        if not self._write_webp_image(source_path, target_path):
            return False

        self._custom_map[getattr(card, "api_id")] = self._rel_path(target_path)
        self._surface_cache.pop(getattr(card, "api_id"), None)
        self._surface_cache.pop(getattr(card, "name", ""), None)
        self._save_custom_mappings()
        self._image_map = self._scan_images()
        return True

    def normalize_card_image_library(self, cards: list) -> MigrationReport:
        """Normalize mappings and filenames to api_id -> card_name__api_id.webp."""
        old_map = dict(self._custom_map)
        new_map: dict[str, str] = {}
        legacy_sources: set[str] = set()
        new_targets: set[str] = set()
        normalized = copied = already = skipped = 0

        for card in cards:
            if card is None or not getattr(card, "api_id", ""):
                skipped += 1
                continue
            source = self._mapping_path(card.api_id)
            if not source and not self._ambiguous_card_name(card.name, card.api_id):
                source = self._mapping_path(card.name) or self._image_map.get(card.name)
            if not source:
                source = self._normalized_existing_path(card)
            if not source or not os.path.exists(source):
                skipped += 1
                continue
            if self.is_card_back_path(source):
                new_map[card.api_id] = self._rel_path(source)
                already += 1
                continue

            target = self._target_path_for_card(card, ".webp")
            os.makedirs(os.path.dirname(target), exist_ok=True)
            source_norm = os.path.normcase(os.path.normpath(source))
            target_norm = os.path.normcase(os.path.normpath(target))
            if source_norm != target_norm:
                if not self._write_webp_image(source, target):
                    skipped += 1
                    continue
                copied += 1
                normalized += 1
                legacy_sources.add(os.path.normpath(source))
            else:
                already += 1
            new_targets.add(os.path.normpath(target))
            new_map[card.api_id] = self._rel_path(target)

        removed_files = 0
        new_target_keys = {os.path.normcase(path) for path in new_targets}
        for source in sorted(legacy_sources):
            if os.path.normcase(source) in new_target_keys:
                continue
            if os.path.basename(source) == "卡背.webp" or not self._path_is_under_image_cache(source):
                continue
            try:
                if os.path.exists(source):
                    os.remove(source)
                    removed_files += 1
            except OSError as e:
                logger.warning("failed to remove legacy image after normalization: %s", e)

        removed_legacy = len([key for key in old_map if key not in new_map])
        self._custom_map = dict(sorted(new_map.items(), key=lambda item: item[0]))
        self._surface_cache.clear()
        self._save_custom_mappings()
        self._image_map = self._scan_images()
        return MigrationReport(
            normalized_count=normalized,
            copied_count=copied,
            already_normalized_count=already,
            skipped_count=skipped,
            removed_legacy_keys=removed_legacy,
            removed_legacy_files_count=removed_files,
            message=(
                f"规范化 {len(new_map)} 张卡图，复制 {copied} 个文件，"
                f"移除旧文件 {removed_files} 个，跳过 {skipped} 张"
            ),
        )

    def delete_card_image_for_card(self, card) -> DeleteResult:
        """Delete the current card image file and remove its api_id mapping."""
        if card is None or not getattr(card, "api_id", ""):
            return DeleteResult(False, "没有可删除的卡牌图像")

        path = self.resolve_card_image(card)
        if not path:
            self._custom_map.pop(card.api_id, None)
            self._save_custom_mappings()
            return DeleteResult(False, "当前卡牌没有已绑定图像")
        if self.is_card_back_path(path):
            self._custom_map.pop(card.api_id, None)
            self._surface_cache.pop(card.api_id, None)
            self._surface_cache.pop(card.name, None)
            self._save_custom_mappings()
            self._image_map = self._scan_images()
            return DeleteResult(True, "已移除卡背占位绑定", path)

        if not self._path_is_under_image_cache(path):
            return DeleteResult(False, "只能删除 data/images 内的卡图文件", path)

        owners = [
            key for key, raw in self._custom_map.items()
            if os.path.normcase(self._abs_path(raw)) == os.path.normcase(path)
        ]
        other_owners = [key for key in owners if key != card.api_id]
        if other_owners:
            return DeleteResult(False, f"该文件仍被 {len(other_owners)} 个映射引用，未删除", path)

        try:
            if os.path.exists(path):
                os.remove(path)
        except OSError as e:
            return DeleteResult(False, f"删除失败: {e}", path)

        self._custom_map.pop(card.api_id, None)
        self._surface_cache.pop(card.api_id, None)
        self._surface_cache.pop(card.name, None)
        self._save_custom_mappings()
        self._image_map = self._scan_images()
        return DeleteResult(True, "已删除当前卡图", path)

    def get_unreferenced_images(self) -> list[ImageCandidate]:
        """Return image files under image_cache_dir that no api_id mapping references."""
        referenced = {
            os.path.normcase(self._abs_path(raw))
            for key, raw in self._custom_map.items()
            if raw and key != "__CARD_BACK__"
        }
        candidates: list[ImageCandidate] = []
        if not os.path.isdir(self.image_cache_dir):
            return candidates

        for root, _dirs, files in os.walk(self.image_cache_dir):
            for filename in files:
                stem, ext = os.path.splitext(filename)
                if filename == "卡背.webp" or ext.lower() not in _IMPORT_IMAGE_EXTS:
                    continue
                path = os.path.normpath(os.path.join(root, filename))
                assigned = os.path.normcase(path) in referenced
                if assigned:
                    continue
                candidates.append(ImageCandidate(
                    name=stem,
                    path=path,
                    rel_path=self._rel_path(path),
                    group=os.path.basename(os.path.dirname(path)),
                    assigned=False,
                    size_bytes=os.path.getsize(path) if os.path.exists(path) else 0,
                ))
        return sorted(candidates, key=lambda c: (c.group, c.name))

    def delete_unreferenced_image(self, path: str) -> DeleteResult:
        """Delete an unreferenced image file after verifying no mapping uses it."""
        abs_path = os.path.normpath(path)
        if not self._path_is_under_image_cache(abs_path):
            return DeleteResult(False, "只能删除 data/images 内的图片", abs_path)
        for raw in self._custom_map.values():
            if os.path.normcase(self._abs_path(raw)) == os.path.normcase(abs_path):
                return DeleteResult(False, "该图片仍被卡牌引用，未删除", abs_path)
        try:
            os.remove(abs_path)
        except OSError as e:
            return DeleteResult(False, f"删除失败: {e}", abs_path)
        self._image_map = self._scan_images()
        return DeleteResult(True, "已删除未引用图片", abs_path)

    # ── Backward-compatible API ──

    def get_card_image(self, card_name: str, card_id: str = "") -> Optional[pygame.Surface]:
        """Return the pygame Surface for a card, or None if no image exists."""
        lookup_key = card_id or card_name
        if lookup_key in self._surface_cache:
            return self._surface_cache[lookup_key]

        path = None
        if card_id:
            try:
                from data.card_registry import CardRegistry
                card = CardRegistry.get(card_id)
            except Exception:
                card = None
            path = self.resolve_card_image(card) if card is not None else self._mapping_path(card_id)

        if not path:
            ambiguous_name = self._ambiguous_card_name(card_name, card_id)
            if not ambiguous_name:
                path = self._mapping_path(card_name) or self._image_map.get(card_name)

        surface = self._load_image(path) if path and os.path.exists(path) else None
        self._surface_cache[lookup_key] = surface
        return surface

    def has_image(self, card_name_or_id: str) -> bool:
        """Check whether an image exists for a legacy key or api_id."""
        try:
            from data.card_registry import CardRegistry
            card = CardRegistry.get(card_name_or_id)
        except Exception:
            card = None
        if card is not None:
            return self.has_card_image(card)

        path = self._mapping_path(card_name_or_id) or self._image_map.get(card_name_or_id)
        return path is not None and os.path.exists(path)

    def get_image_path(self, card_name_or_id: str) -> Optional[str]:
        """Return the file path for a legacy key or api_id, if it exists."""
        try:
            from data.card_registry import CardRegistry
            card = CardRegistry.get(card_name_or_id)
        except Exception:
            card = None
        if card is not None:
            return self.resolve_card_image(card)
        path = self._mapping_path(card_name_or_id) or self._image_map.get(card_name_or_id)
        return path if path and os.path.exists(path) else None

    def get_available_images(self) -> list[str]:
        """Return sorted list of all discovered image stems."""
        return sorted(self._image_map.keys())

    def get_available_image_path(self, image_name: str) -> Optional[str]:
        """Return the full path for a discovered image by stem."""
        return self._image_map.get(image_name)

    def set_card_image(self, card_name: str, image_path: str) -> bool:
        """Assign an image to a legacy key. Prefer assign_card_image_for_card."""
        abs_path = os.path.normpath(image_path)
        self._custom_map[card_name] = self._rel_path(abs_path)
        self._surface_cache.pop(card_name, None)
        self._save_custom_mappings()
        return True

    def remove_card_image(self, card_name: str, delete_file: bool = False):
        """Remove a legacy image assignment. Prefer delete_card_image_for_card."""
        rel = self._custom_map.pop(card_name, None)
        self._surface_cache.pop(card_name, None)
        self._save_custom_mappings()
        if delete_file and rel:
            abs_path = self._abs_path(rel)
            try:
                os.remove(abs_path)
            except OSError as e:
                logger.error("failed to delete file: %s", e)

    def bind_card_image(self, card_name: str, source_path: str, target_subdir: str,
                        card_id: str = "") -> bool:
        """Bind an image, using api_id as authority when available."""
        if card_id:
            try:
                from data.card_registry import CardRegistry
                card = CardRegistry.get(card_id)
            except Exception:
                card = None
            if card is not None:
                return self.assign_card_image_for_card(card, source_path)

        fake_card = type("ImageBindCard", (), {
            "api_id": card_id or card_name,
            "name": card_name,
            "is_pokemon": target_subdir == "宝可梦",
            "is_trainer": target_subdir in ("物品", "支援者", "竞技场", "宝可梦道具"),
            "is_energy": target_subdir == "能量",
            "trainer_type": "",
            "subtypes": [],
        })()
        return self.assign_card_image_for_card(fake_card, source_path)

    def assign_card_image(self, card_name: str, source_path: str, target_subdir: str,
                          card_id: str = "") -> bool:
        """Assign an image to a card; compatibility wrapper for old UI code."""
        return self.bind_card_image(card_name, source_path, target_subdir, card_id)

    def clear_all_custom_mappings(self) -> int:
        """Remove all custom image bindings. Returns count of removed mappings."""
        count = len(self._custom_map)
        self._custom_map.clear()
        self._surface_cache.clear()
        self._save_custom_mappings()
        return count

    def reload(self):
        """Clear caches and re-scan disk. Useful after adding images at runtime."""
        self._surface_cache.clear()
        self._image_map = self._scan_images()
        self._load_custom_mappings()
        logger.info("reloaded: %s images, %s custom mappings.", len(self._image_map), len(self._custom_map))

    # ── Card back ──

    def get_card_back(self, filename: str = "卡背.webp") -> Optional[pygame.Surface]:
        """Load and cache the card back image; draw a procedural fallback if missing."""
        cache_key = "__CARD_BACK__"
        if cache_key in self._surface_cache:
            return self._surface_cache[cache_key]

        path = os.path.join(self.image_cache_dir, filename)
        if os.path.exists(path):
            surface = self._load_image(path)
            if surface is not None:
                self._surface_cache[cache_key] = surface
                return surface

        w, h = 110, 155
        surf = pygame.Surface((w, h))
        for gy in range(h):
            t = gy / h
            r = int(30 + 15 * (1 - t))
            g = int(45 + 20 * (1 - t))
            b = int(120 + 30 * (1 - t))
            pygame.draw.line(surf, (r, g, b), (0, gy), (w, gy))
        pygame.draw.rect(surf, (200, 180, 60), surf.get_rect(), 2, border_radius=8)
        cx, cy = w // 2, h // 2
        pygame.draw.circle(surf, (220, 220, 240), (cx, cy), 20, 2)
        pygame.draw.circle(surf, (220, 220, 240), (cx, cy), 8, 2)
        pygame.draw.line(surf, (180, 180, 200), (0, cy), (w, cy), 1)
        surf = _try_convert_alpha(surf)
        self._surface_cache[cache_key] = surf
        return surf

    # ── Properties ──

    @property
    def mapped_count(self) -> int:
        """Return how many mapping keys have existing images."""
        return sum(1 for key in self._custom_map if self.has_image(key))

    @property
    def custom_count(self) -> int:
        """Return how many custom mappings have existing files."""
        return sum(1 for key in self._custom_map if self.has_image(key))

    @property
    def auto_count(self) -> int:
        """Return how many auto-discovered images exist."""
        return sum(1 for path in self._image_map.values() if os.path.exists(path))


_image_manager_instance: Optional[ImageManager] = None


def get_image_manager() -> ImageManager:
    global _image_manager_instance
    if _image_manager_instance is None:
        _image_manager_instance = ImageManager()
    return _image_manager_instance

"""Card detail rendering — tooltips, magnified card preview."""
import pygame
from config import (
    SCREEN_WIDTH, SCREEN_HEIGHT,
    STATUS_SHORT_CN, ENERGY_NAME_CN as ENERGY_CN,
)
from ui.colors import (
    UI_BORDER, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY, UI_HIGHLIGHT,
)
from ui.render_helpers import draw_rect_alpha
from ui.layout_model import DEFAULT_GAME_LAYOUT
from ui.ui_theme import draw_panel, draw_text_fit, draw_badge
from ui.components.game_layout import (
    LOG_W, PLAY_AREA_W,
    FIELD_ACTIVE_W, FIELD_ACTIVE_H, FIELD_BENCH_W, FIELD_BENCH_H,
)


def _wrap_text(text: str, chars_per_line: int) -> list[str]:
    """Split long text into lines of at most chars_per_line characters."""
    if len(text) <= chars_per_line:
        return [text]
    return [text[i:i + chars_per_line] for i in range(0, len(text), chars_per_line)]


# Adapter: StatusType enum -> short Chinese status name
def _build_status_cn():
    from engine.enums import StatusType
    KEY_MAP = {
        StatusType.POISONED: "poisoned",
        StatusType.BURNED: "burned",
        StatusType.ASLEEP: "asleep",
        StatusType.PARALYZED: "paralyzed",
        StatusType.CONFUSED: "confused",
    }
    return {k: STATUS_SHORT_CN[v] for k, v in KEY_MAP.items()}

STATUS_CN = _build_status_cn()


def _has_card_image(gs, card) -> bool:
    return gs.image_mgr.has_card_image(card)


def get_hovered_card_with_image(gs):
    """Return the Card object if a card with a real image is being hovered, else None."""
    player = gs._get_display_player()
    opponent = gs._get_opponent()

    # Hand card hover
    if gs.hovered_hand is not None and gs.hovered_hand < len(player.hand):
        card = player.hand[gs.hovered_hand]
        if _has_card_image(gs, card):
            return card

    # Player active
    if gs.hovered_active and player.active:
        card = player.active.card
        if _has_card_image(gs, card):
            return card

    # Player bench
    if gs.hovered_bench is not None:
        poke = player.bench[gs.hovered_bench]
        if poke and _has_card_image(gs, poke.card):
            return poke.card

    # Opponent active
    if gs.hovered_opp_active and opponent.active:
        card = opponent.active.card
        if _has_card_image(gs, card):
            return card

    # Opponent bench
    if gs.hovered_opp_bench is not None:
        poke = opponent.bench[gs.hovered_opp_bench]
        if poke and _has_card_image(gs, poke.card):
            return poke.card

    return None


def get_hovered_card_context(gs):
    """Return (card, extra_info, label) for the current hover target."""
    player = gs._get_display_player()
    opponent = gs._get_opponent()

    if gs.hovered_hand is not None and gs.hovered_hand < len(player.hand):
        return player.hand[gs.hovered_hand], None, "手牌"
    if gs.hovered_active and player.active:
        return player.active.card, pokemon_extra_info(gs, player.active), "我方战斗区"
    if gs.hovered_bench is not None:
        poke = player.bench[gs.hovered_bench]
        if poke:
            return poke.card, pokemon_extra_info(gs, poke), f"我方备战区 {gs.hovered_bench + 1}"
    if gs.hovered_opp_active and opponent.active:
        return opponent.active.card, pokemon_extra_info(gs, opponent.active), "对手战斗区"
    if gs.hovered_opp_bench is not None:
        poke = opponent.bench[gs.hovered_opp_bench]
        if poke:
            return poke.card, pokemon_extra_info(gs, poke), f"对手备战区 {gs.hovered_opp_bench + 1}"
    return None, None, ""


def _card_detail_lines(card, extra_info=None) -> list[str]:
    if card is None:
        return []
    lines: list[str] = []
    if card.is_pokemon:
        if not extra_info:
            lines.append(f"HP: {card.hp}")
        if card.evolves_from:
            lines.append(f"进化自: {card.evolves_from}")
        if card.abilities:
            for ab in card.abilities[:2]:
                lines.append(f"特性: {ab.name}")
                if ab.text:
                    lines.extend(_wrap_text(ab.text, 24)[:2])
        if card.attacks:
            for atk in card.attacks[:3]:
                cost = "".join(ENERGY_CN.get(c, c[:1]) for c in atk.cost)
                damage_label = getattr(atk, "damage_text", "") or (
                    str(atk.damage) if atk.damage else ""
                )
                dmg = f" {damage_label}" if damage_label else ""
                lines.append(f"[{cost or '无'}] {atk.name}{dmg}")
                if atk.text:
                    lines.extend(_wrap_text(atk.text, 24)[:2])
        if card.weaknesses:
            w = card.weaknesses[0]
            lines.append(f"弱点: {ENERGY_CN.get(w.energy_type, w.energy_type)}{w.value}")
        if card.resistances:
            r = card.resistances[0]
            lines.append(f"抗性: {ENERGY_CN.get(r.energy_type, r.energy_type)}{r.value}")
        lines.append(f"撤退费用: {card.retreat_cost}")
        if extra_info:
            lines.insert(0, "— 场上状态 —")
            lines = list(extra_info) + ["— 卡牌文本 —"] + lines
    elif card.is_trainer:
        trainer_type = card.trainer_type or (card.subtypes[0] if card.subtypes else "训练家")
        lines.append(f"类型: {trainer_type}")
        for rule_text in (card.rules if card.rules else [card.trainer_text])[:4]:
            lines.extend(_wrap_text(rule_text or "", 24))
    elif card.is_energy:
        lines.append("特殊能量" if card.is_special_energy else "基本能量")
        lines.append(f"提供: {'/'.join(card.provides_energy)}")
        for rule_text in (card.rules or [])[:3]:
            lines.extend(_wrap_text(rule_text, 24))
    return lines


def draw_hover_detail_panel(gs, surface):
    """Draw the right-side card detail panel for the current hover target."""
    layout = getattr(gs, "layout", DEFAULT_GAME_LAYOUT)
    card, extra, label = get_hovered_card_context(gs)
    inner = draw_panel(surface, layout.detail_panel, "卡牌详情", gs.font_small)

    if card is None:
        msg = "悬停卡牌查看详情"
        draw_text_fit(surface, gs.font_body, msg, UI_TEXT_SECONDARY,
                      pygame.Rect(inner.x, inner.y + 92, inner.w, 24),
                      align="center")
        return

    img = gs.image_mgr.get_card_image(card.name, card.api_id)
    preview_rect = pygame.Rect(inner.x, inner.y, 86, 122)
    if img:
        scaled = pygame.transform.smoothscale(img, preview_rect.size)
        surface.blit(scaled, preview_rect.topleft)
    else:
        pygame.draw.rect(surface, (42, 48, 70), preview_rect, border_radius=7)
        name = gs.font_card_tiny.render(card.name[:6], True, UI_TEXT_PRIMARY)
        surface.blit(name, name.get_rect(center=preview_rect.center))
    pygame.draw.rect(surface, UI_BORDER, preview_rect, 1, border_radius=7)

    title_rect = pygame.Rect(preview_rect.right + 10, inner.y, inner.right - preview_rect.right - 10, 24)
    draw_text_fit(surface, gs.font_info, card.name, UI_HIGHLIGHT, title_rect)
    subtypes = "/".join(card.subtypes) if getattr(card, "subtypes", None) else card.supertype
    draw_text_fit(surface, gs.font_card_tiny, subtypes, UI_TEXT_SECONDARY,
                  pygame.Rect(title_rect.x, title_rect.y + 28, title_rect.w, 16))
    if label:
        badge = pygame.Rect(title_rect.x, title_rect.y + 52, min(128, title_rect.w), 22)
        draw_badge(surface, badge, label, gs.font_card_tiny,
                   fill=(38, 48, 72), border=UI_BORDER)

    y = preview_rect.bottom + 12
    line_h = 16
    for line in _card_detail_lines(card, extra):
        if y + line_h > inner.bottom:
            break
        if line.startswith("—"):
            pygame.draw.line(surface, UI_BORDER, (inner.x, y + 8),
                             (inner.right, y + 8), 1)
        else:
            draw_text_fit(surface, gs.font_card_tiny, line, UI_TEXT_SECONDARY,
                          pygame.Rect(inner.x, y, inner.w, line_h))
        y += line_h


def draw_magnified_card(gs, surface):
    """Show magnified card image in top-left when hovering a card with a real image."""
    card = get_hovered_card_with_image(gs)
    if card is None:
        return

    img = gs.image_mgr.get_card_image(card.name, card.api_id)
    if img is None:
        return

    MAGNIFY_H = 340
    MAGNIFY_X = 10
    MAGNIFY_Y = 26

    # Scale up maintaining aspect ratio
    iw, ih = img.get_size()
    scale = MAGNIFY_H / ih
    mw, mh = int(iw * scale), MAGNIFY_H

    try:
        scaled = pygame.transform.smoothscale(img, (mw, mh))
    except Exception:
        return

    # Draw dark backdrop to prevent board bleed-through
    pygame.draw.rect(surface, (20, 20, 30),
                     (MAGNIFY_X, MAGNIFY_Y, mw, mh), border_radius=8)

    # Draw shadow behind magnified card
    shadow_rect = pygame.Rect(MAGNIFY_X + 3, MAGNIFY_Y + 3, mw, mh)
    draw_rect_alpha(surface, (0, 0, 0, 80), shadow_rect, border_radius=8)

    # Draw magnified image
    surface.blit(scaled, (MAGNIFY_X, MAGNIFY_Y))

    # White border
    pygame.draw.rect(surface, (255, 255, 255),
                     (MAGNIFY_X, MAGNIFY_Y, mw, mh), 2, border_radius=8)

    # Card name below
    name_txt = gs.font_small.render(card.name, True, (255, 255, 255))
    name_bg = pygame.Rect(MAGNIFY_X, MAGNIFY_Y + mh + 2,
                          name_txt.get_width() + 8, 18)
    draw_rect_alpha(surface, (0, 0, 0, 160), name_bg, border_radius=3)
    surface.blit(name_txt, (MAGNIFY_X + 4, MAGNIFY_Y + mh + 3))


def pokemon_extra_info(gs, pokemon) -> list[str]:
    """Build extra info lines for a Pokemon in play."""
    lines = []
    lines.append(f"HP: {pokemon.current_hp}/{pokemon.card.hp}")
    if pokemon.damage_counters > 0:
        lines.append(f"伤害指示物: {pokemon.damage_counters * 10}")
    if pokemon.energy_cards:
        names = "/".join(c.name for c in pokemon.energy_cards[:4])
        if len(pokemon.energy_cards) > 4:
            names += f"/+{len(pokemon.energy_cards) - 4}"
        lines.append(f"能量: {len(pokemon.energy_cards)}个 ({names})")
        specials = [sc for sc in pokemon.energy_cards if sc.is_special_energy]
        if specials:
            sp_names = "/".join(sc.name for sc in specials)
            lines.append(f"特殊能量: {sp_names}")
    if pokemon.attached_tool:
        lines.append(f"道具: {pokemon.attached_tool.name}")
    if pokemon.status_conditions:
        sc = [STATUS_CN.get(s, s.name) for s in pokemon.status_conditions]
        lines.append(f"状态: {', '.join(sc)}")
    if pokemon.card.abilities:
        lines.append("───")
        for ab in pokemon.card.abilities:
            lines.append(f"特性: {ab.name}")
            if ab.text:
                for wrapped in _wrap_text(f"  {ab.text}", 26):
                    lines.append(wrapped)
    if pokemon.card.attacks:
        lines.append("───")
        for atk in pokemon.card.attacks:
            cost_str = "".join(ENERGY_CN.get(c, c[:1]) for c in atk.cost)
            damage_label = getattr(atk, "damage_text", "") or (
                str(atk.damage) if atk.damage else ""
            )
            damage_text = f"  伤害:{damage_label}" if damage_label else ""
            lines.append(f"招式: [{cost_str}] {atk.name}{damage_text}")
            if atk.text:
                for wrapped in _wrap_text(atk.text, 26):
                    lines.append(f"  {wrapped}")
    return lines


def draw_tooltip_box(gs, surface, card, tx, ty, extra_info=None):
    """Draw a detailed card tooltip at the given position."""
    # Tooltip constants
    tw = 310
    line_h = 16
    max_chars_per_line = 28  # for 10px Chinese font in 310px width

    # Build content lines
    if card.is_pokemon:
        # When extra_info is provided (Pokemon in play), it already contains the active HP.
        # Only show base card HP when there's no extra_info.
        if extra_info:
            lines = []
        else:
            lines = [f"HP: {card.hp}"]
        if card.evolves_from:
            lines.append(f"进化自: {card.evolves_from}")
        if card.weaknesses:
            w = card.weaknesses[0]
            lines.append(f"弱点: {ENERGY_CN.get(w.energy_type, w.energy_type)}{w.value}")
        if card.resistances:
            r = card.resistances[0]
            lines.append(f"抵抗: {ENERGY_CN.get(r.energy_type, r.energy_type)}{r.value}")
        lines.append(f"撤退费用: {card.retreat_cost}")
        if extra_info:
            lines.append("───")
            lines.extend(extra_info)
    elif card.is_trainer:
        trainer_type = card.trainer_type or (card.subtypes[0] if card.subtypes else '训练家')
        lines = [f"类型: {trainer_type}"]
        rules = card.rules if card.rules else [card.trainer_text]
        for rule_text in rules[:4]:
            for wrapped in _wrap_text(rule_text, max_chars_per_line):
                lines.append(wrapped)
    elif card.is_energy:
        energy_count = len(card.provides_energy)
        lines = [f"提供: {'/'.join(card.provides_energy)} ({energy_count}个)"]
        # Special energy: also show rules
        if card.is_special_energy and card.rules:
            for rule_text in card.rules[:3]:
                for wrapped in _wrap_text(rule_text, max_chars_per_line):
                    lines.append(wrapped)

    # Calculate size
    th = 52 + len(lines) * line_h + 12

    # Clamp position so it stays on screen
    if tx + tw > SCREEN_WIDTH - LOG_W - 8:
        tx = SCREEN_WIDTH - LOG_W - tw - 16
    if ty + th > SCREEN_HEIGHT:
        ty = SCREEN_HEIGHT - th - 8
    if tx < 4:
        tx = 4
    if ty < 4:
        ty = 4
    # Also clamp if too close to bottom (for hand cards)
    max_ty = SCREEN_HEIGHT - th - 8
    if ty > max_ty:
        ty = max_ty

    # Draw background
    tip_rect = pygame.Rect(tx, ty, tw, th)
    pygame.draw.rect(surface, (20, 20, 48), tip_rect, border_radius=8)
    pygame.draw.rect(surface, UI_HIGHLIGHT, tip_rect, 2, border_radius=8)

    # Card name
    name_txt = gs.font_info.render(card.name, True, (255, 255, 255))
    surface.blit(name_txt, (tx + 8, ty + 6))

    # Subtype
    subtype_str = "/".join(card.subtypes) if card.subtypes else card.supertype
    sub_txt = gs.font_small.render(subtype_str, True, UI_TEXT_SECONDARY)
    surface.blit(sub_txt, (tx + 8, ty + 30))

    # Lines
    y_off = ty + 52
    for line in lines:
        # Render "───" as a faint separator
        if line == "───":
            pygame.draw.line(surface, UI_BORDER, (tx + 12, y_off + 8),
                             (tx + tw - 12, y_off + 8), 1)
        else:
            # Truncate only if still too long for one line (shouldn't happen with wrapping)
            display = line[:max_chars_per_line + 2]
            lt = gs.font_card_tiny.render(display, True, UI_TEXT_SECONDARY)
            surface.blit(lt, (tx + 8, y_off))
        y_off += line_h


def draw_card_tooltip(gs, surface):
    """Deprecated: tooltips are now handled by draw_field_tooltips."""
    pass

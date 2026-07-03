"""Hand card display functions."""
import math
import pygame
from config import CARD_WIDTH, CARD_HEIGHT
from ui.colors import (
    UI_BORDER, UI_HIGHLIGHT, CARD_HOVER_LIFT,
    TYPE_COLORS,
)
from ui.layout_model import DEFAULT_GAME_LAYOUT
from ui.components.board_renderer import get_card_image_surface, _draw_card_shadow
from ui.energy_icons import draw_energy_icon


def get_hand_layout(gs):
    """Calculate hand card positions at the bottom of the screen."""
    player = gs._get_display_player()
    hand = player.hand
    if not hand:
        return []

    n = len(hand)
    layout = getattr(gs, "layout", DEFAULT_GAME_LAYOUT)
    hand_rect = layout.hand
    margin = 16
    available = hand_rect.w - margin * 2
    max_overlap = 54
    if n <= 1:
        spacing = CARD_WIDTH
    else:
        spacing = min(CARD_WIDTH - max_overlap, (available - CARD_WIDTH) // max(n - 1, 1))

    total_width = CARD_WIDTH + (n - 1) * spacing
    start_x = hand_rect.x + max(margin, (hand_rect.w - total_width) // 2)
    base_y = hand_rect.y + 12

    # Smooth lift animation: use _card_lift_offset dict if available
    lift_offsets = getattr(gs, '_card_lift_offset', {})

    result = []
    for i in range(n):
        x = int(start_x + i * spacing)
        center_bias = 0 if n <= 1 else abs(i - (n - 1) / 2) / max((n - 1) / 2, 1)
        fan_drop = int(center_bias * 6)
        # Use smooth animated lift offset, or fall back to binary hover lift
        if lift_offsets and i in lift_offsets:
            lift = lift_offsets[i]
        else:
            hovered = gs.hovered_hand == i
            lift = CARD_HOVER_LIFT if hovered else 0
        y = base_y + fan_drop - lift
        rect = pygame.Rect(x, y, CARD_WIDTH, CARD_HEIGHT)
        result.append((x, y, rect))
    return result


def draw_hand(gs, surface, player):
    """Draw hand cards at the bottom of the screen."""
    layout = get_hand_layout(gs)
    hand = player.hand
    if hasattr(gs, "_get_display_player_idx"):
        display_player_idx = gs._get_display_player_idx()
    else:
        display_player_idx = 0 if player is getattr(gs.state, "p1", None) else 1
    animating_idx = getattr(gs, '_animating_hand_idx', None)
    animating_idx_player = getattr(gs, '_animating_hand_idx_player', display_player_idx)
    if animating_idx_player is not None and animating_idx_player != display_player_idx:
        animating_idx = None
    hidden_idx = getattr(gs, '_hidden_hand_idx', None)
    hidden_idx_player = getattr(gs, '_hidden_hand_idx_player', display_player_idx)
    if hidden_idx_player is not None and hidden_idx_player != display_player_idx:
        hidden_idx = None
    hidden_by_player = getattr(gs, '_hidden_hand_indices_by_player', None)
    if isinstance(hidden_by_player, dict):
        hidden_set = hidden_by_player.get(display_player_idx, set())
    else:
        hidden_set = getattr(gs, '_hidden_hand_indices', set())
    for i, (card_x, card_y, rect) in enumerate(layout):
        if i < len(hand):
            if i == animating_idx:
                continue  # Card is being animated (fly away), skip it
            if i == hidden_idx or i in hidden_set:
                continue  # Card hidden during draw animation
            highlight = (i == gs.selected_hand_idx or i == gs.hovered_hand)
            draw_hand_card(gs, surface, card_x, card_y, hand[i], highlight=highlight)


def draw_hand_card(gs, surface, x, y, card, highlight=False):
    """Draw a single hand card."""
    rect = pygame.Rect(x, y, CARD_WIDTH, CARD_HEIGHT)

    img = get_card_image_surface(gs, card.name, CARD_WIDTH, CARD_HEIGHT, card.api_id)
    if img is not None:
        _draw_card_shadow(surface, rect)
        pygame.draw.rect(surface, (20, 20, 30), rect, border_radius=8)
        surface.blit(img, (x, y))
        border_color = UI_HIGHLIGHT if highlight else UI_BORDER
        border_width = 2 if highlight else 1
        pygame.draw.rect(surface, border_color, rect, border_width, border_radius=8)
        if highlight:
            glow_alpha = int(40 + 20 * abs(math.sin(pygame.time.get_ticks() * 0.003)))
            glow_surf = pygame.Surface((rect.w + 8, rect.h + 8), pygame.SRCALPHA)
            pygame.draw.rect(glow_surf, (255, 215, 0, glow_alpha),
                           glow_surf.get_rect(), border_radius=10)
            surface.blit(glow_surf, (rect.x - 4, rect.y - 4))
        return

    if card.is_pokemon and card.energy_types:
        bg = TYPE_COLORS.get(card.energy_types[0], TYPE_COLORS["Colorless"])
    elif card.is_trainer:
        bg = TYPE_COLORS["Trainer"]
    else:
        bg = TYPE_COLORS["Energy"]

    # Drop shadow
    _draw_card_shadow(surface, rect)

    # Gradient fill
    r_bg, g_bg, b_bg = bg
    for gy in range(rect.h):
        t = gy / rect.h
        gr = min(255, int(r_bg + 20 * (1 - t)))
        gg = min(255, int(g_bg + 20 * (1 - t)))
        gb = min(255, int(b_bg + 20 * (1 - t)))
        pygame.draw.line(surface, (gr, gg, gb),
                        (rect.x, rect.y + gy), (rect.x + rect.w, rect.y + gy))

    pygame.draw.rect(surface, bg, rect, border_radius=8)
    border_color = UI_HIGHLIGHT if highlight else UI_BORDER
    border_width = 3 if highlight else 1
    pygame.draw.rect(surface, border_color, rect, border_width, border_radius=8)

    # Hover glow
    if highlight:
        glow_alpha = int(40 + 20 * abs(math.sin(pygame.time.get_ticks() * 0.003)))
        glow_surf = pygame.Surface((rect.w + 8, rect.h + 8), pygame.SRCALPHA)
        pygame.draw.rect(glow_surf, (255, 215, 0, glow_alpha),
                       glow_surf.get_rect(), border_radius=10)
        surface.blit(glow_surf, (rect.x - 4, rect.y - 4))

    inner = pygame.Rect(x + 3, y + 3, CARD_WIDTH - 6, CARD_HEIGHT - 6)
    surface.set_clip(inner)

    name = card.name[:8]
    name_txt = gs.font_card_name.render(name, True, (255, 255, 255))
    surface.blit(name_txt, (x + 5, y + 5))

    if card.is_pokemon:
        hp_txt = gs.font_card_tiny.render(f"HP{card.hp}", True, (255, 255, 255))
        surface.blit(hp_txt, (x + CARD_WIDTH - 48, y + 6))

        subtype_str = "/".join(card.subtypes[:2]) if card.subtypes else ""
        if subtype_str:
            st_txt = gs.font_card_tiny.render(subtype_str, True, (200, 200, 220))
            surface.blit(st_txt, (x + 4, y + 22))

        # Attacks
        atk_start_y = y + 38
        atk_count = min(3, len(card.attacks))
        atk_h = (CARD_HEIGHT - 54) // max(atk_count, 1)
        for ai, attack in enumerate(card.attacks[:atk_count]):
            atk_y = atk_start_y + ai * atk_h
            cost_x = x + 4
            for energy_type in attack.cost[:4]:
                draw_energy_icon(surface, gs.image_mgr, energy_type,
                                 (cost_x + 6, atk_y + 6), 12,
                                 gs.font_card_tiny)
                cost_x += 14

            dmg_str = getattr(attack, "damage_text", "") or (
                str(attack.damage) if attack.damage > 0 else ""
            )
            atk_name = attack.name[:6]
            atk_str = f"{atk_name}{dmg_str}"
            atk_txt = gs.font_card_body.render(atk_str, True, (0, 0, 0))
            surface.blit(atk_txt, (x + 4, atk_y + 13))

        ret_cost = card.retreat_cost
        if ret_cost > 0:
            ret_txt = gs.font_card_tiny.render(f"撤{ret_cost}", True, (50, 50, 50))
            surface.blit(ret_txt, (x + 4, y + CARD_HEIGHT - 16))

    elif card.is_trainer:
        subtype_name = card.subtypes[0] if card.subtypes else "训练家"
        sub_txt = gs.font_card_tiny.render(subtype_name, True, (60, 60, 80))
        surface.blit(sub_txt, (x + 4, y + 22))
        rules = card.rules if card.rules else []
        rule_text = rules[0] if rules else card.trainer_text
        if rule_text:
            for li, line in enumerate([rule_text[i:i+10] for i in range(0, min(len(rule_text), 40), 10)]):
                eff_txt = gs.font_card_tiny.render(line, True, (20, 20, 40))
                surface.blit(eff_txt, (x + 4, y + 38 + li * 14))

    elif card.is_energy:
        draw_energy_icon(surface, gs.image_mgr, card,
                         (x + CARD_WIDTH // 2, y + CARD_HEIGHT // 2),
                         48, gs.font_card_name)

    surface.set_clip(None)

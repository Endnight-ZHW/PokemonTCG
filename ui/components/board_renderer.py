"""Board rendering functions — opponent/player sides, divider, stadium, field pokemon, bench, tooltips."""
import math
import pygame
from config import (
    SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT,
    STATUS_SHORT_CN, PHASE_CN as _PHASE_CN_STR, ENERGY_NAME_CN as ENERGY_CN,
)
from ui.colors import (
    UI_BG_DARK, UI_BORDER, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY,
    UI_HIGHLIGHT, UI_BUTTON, UI_BUTTON_HOVER,
    TYPE_COLORS, ENERGY_COLORS, STATUS_COLORS,
    BOARD_GRADIENT_CENTER, BOARD_GRADIENT_EDGE, BOARD_GRID_COLOR,
    BOARD_OPPONENT_TINT, BOARD_PLAYER_TINT,
    DECK_ZONE_BG, DECK_ZONE_BORDER, DECK_ZONE_HIGHLIGHT, DECK_COUNT_BADGE,
    DISCARD_ZONE_BG, DISCARD_ZONE_EMPTY, DISCARD_ZONE_BORDER, DISCARD_ZONE_HIGHLIGHT,
    ZONE_LABEL_COLOR,
)
from ui.render_helpers import draw_rect_alpha
from engine.enums import TurnPhase
from ui.components.game_layout import (
    LOG_W, LOG_X, PLAY_AREA_W,
    FIELD_ACTIVE_W, FIELD_ACTIVE_H, FIELD_BENCH_W, FIELD_BENCH_H,
    OPP_INFO_Y, OPP_BENCH_Y, OPP_ACTIVE_Y,
    DIVIDER_Y, DIVIDER_H,
    PLAYER_ACTIVE_Y, PLAYER_BENCH_Y, PLAYER_INFO_Y,
    HAND_Y, BTN_W, BTN_H, BTN_GAP, BTN_ROW1_Y, BTN_ROW2_Y,
    DECK_ZONE_W, DECK_ZONE_H, DECK_DISCARD_GAP,
    OPP_DECK_ZONE_X, OPP_DECK_ZONE_Y, OPP_DISCARD_ZONE_X, OPP_DISCARD_ZONE_Y,
    PLAYER_DECK_ZONE_X, PLAYER_DECK_ZONE_Y,
    PLAYER_DISCARD_ZONE_X, PLAYER_DISCARD_ZONE_Y,
    STADIUM_X, STADIUM_Y,
    SLOT_OPP_ACTIVE, SLOT_PLAYER_ACTIVE,
)

# Adapter: StatusType enum -> short Chinese status name
_STATUS_KEY_MAP = {
    "POISONED": "poisoned",
    "BURNED": "burned",
    "ASLEEP": "asleep",
    "PARALYZED": "paralyzed",
    "CONFUSED": "confused",
}

# STATUS_CN maps actual StatusType enum values to Chinese names
def _build_status_cn():
    from engine.enums import StatusType
    _KEY_MAP = {
        StatusType.POISONED: "poisoned",
        StatusType.BURNED: "burned",
        StatusType.ASLEEP: "asleep",
        StatusType.PARALYZED: "paralyzed",
        StatusType.CONFUSED: "confused",
    }
    return {k: STATUS_SHORT_CN[v] for k, v in _KEY_MAP.items()}

STATUS_CN = _build_status_cn()

# Adapter: TurnPhase enum -> Chinese phase name
def _build_phase_cn():
    from engine.enums import TurnPhase
    _KEY_MAP = {
        TurnPhase.SETUP: "SETUP",
        TurnPhase.DRAW: "DRAW",
        TurnPhase.MAIN: "MAIN",
        TurnPhase.ATTACK: "ATTACK",
        TurnPhase.POKEMON_CHECKUP: "POKEMON_CHECKUP",
        TurnPhase.GAME_OVER: "GAME_OVER",
    }
    return {k: _PHASE_CN_STR[v] for k, v in _KEY_MAP.items()}

PHASE_CN = _build_phase_cn()

# Cached background surface
_board_bg_cache = None


def create_board_background():
    """Create a pre-rendered board background with gradient and grid texture.
    Cached globally since it doesn't change per frame.
    """
    global _board_bg_cache
    if _board_bg_cache is not None:
        return _board_bg_cache

    surf = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT)).convert()

    # Radial gradient from center to edges
    cx, cy = SCREEN_WIDTH // 2, SCREEN_HEIGHT // 2
    max_dist = math.sqrt(cx * cx + cy * cy)
    for y in range(0, SCREEN_HEIGHT, 4):
        for x in range(0, SCREEN_WIDTH, 4):
            dx, dy = x - cx, y - cy
            dist = math.sqrt(dx * dx + dy * dy) / max_dist
            t = min(1.0, dist)
            r = int(BOARD_GRADIENT_CENTER[0] + (BOARD_GRADIENT_EDGE[0] - BOARD_GRADIENT_CENTER[0]) * t)
            g = int(BOARD_GRADIENT_CENTER[1] + (BOARD_GRADIENT_EDGE[1] - BOARD_GRADIENT_CENTER[1]) * t)
            b = int(BOARD_GRADIENT_CENTER[2] + (BOARD_GRADIENT_EDGE[2] - BOARD_GRADIENT_CENTER[2]) * t)
            pygame.draw.rect(surf, (r, g, b), (x, y, 4, 4))

    # Subtle grid texture
    grid_surf = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
    grid_spacing = 48
    for gx in range(0, SCREEN_WIDTH, grid_spacing):
        pygame.draw.line(grid_surf, BOARD_GRID_COLOR, (gx, 0), (gx, SCREEN_HEIGHT), 1)
    for gy in range(0, SCREEN_HEIGHT, grid_spacing):
        pygame.draw.line(grid_surf, BOARD_GRID_COLOR, (0, gy), (SCREEN_WIDTH, gy), 1)
    surf.blit(grid_surf, (0, 0))

    # Player zone tinting: opponent half (top) cooler, player half (bottom) warmer
    opponent_tint = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT // 2), pygame.SRCALPHA)
    opponent_tint.fill(BOARD_OPPONENT_TINT)
    surf.blit(opponent_tint, (0, 0))

    player_tint = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT // 2), pygame.SRCALPHA)
    player_tint.fill(BOARD_PLAYER_TINT)
    surf.blit(player_tint, (0, SCREEN_HEIGHT // 2))

    # Divider highlight strip (subtle glow along center divider area)
    div_y = SCREEN_HEIGHT // 2 - 17
    div_strip = pygame.Surface((SCREEN_WIDTH, 34), pygame.SRCALPHA)
    div_strip.fill((15, 25, 15, 30))
    surf.blit(div_strip, (0, div_y))

    # Decorative corner accents (subtle geometric swooshes)
    accent_color = (100, 130, 100, 12)
    # Top-right corner accent
    arc_surf = pygame.Surface((120, 80), pygame.SRCALPHA)
    for r in range(30, 70, 8):
        pygame.draw.arc(arc_surf, accent_color, (60 - r, 40 - r, r * 2, r * 2),
                       0, 1.57, 1)
    surf.blit(arc_surf, (SCREEN_WIDTH - 140, 5))
    # Bottom-left corner accent
    arc_surf2 = pygame.Surface((120, 80), pygame.SRCALPHA)
    for r in range(30, 70, 8):
        pygame.draw.arc(arc_surf2, accent_color, (60 - r, 40 - r, r * 2, r * 2),
                       3.14, 4.71, 1)
    surf.blit(arc_surf2, (20, SCREEN_HEIGHT - 85))

    _board_bg_cache = surf
    return surf


def invalidate_board_background():
    """Clear the cached background so it will be regenerated."""
    global _board_bg_cache
    _board_bg_cache = None


def _draw_card_shadow(surface, rect, alpha=60):
    """Draw a subtle drop shadow behind a card rect."""
    shadow_surf = pygame.Surface((rect.w + 6, rect.h + 6), pygame.SRCALPHA)
    pygame.draw.rect(shadow_surf, (0, 0, 0, alpha), shadow_surf.get_rect(), border_radius=10)
    surface.blit(shadow_surf, (rect.x - 2, rect.y + 2))


def get_card_image_surface(gs, card_name: str, target_w: int, target_h: int, card_id: str = ""):
    """Get scaled card image surface, or None if unavailable."""
    img = gs.image_mgr.get_card_image(card_name, card_id)
    if img is None:
        return None
    return pygame.transform.smoothscale(img, (target_w, target_h))


def stadium_is_activatable(gs) -> bool:
    """Check if the current stadium has an activatable effect."""
    if gs.state.stadium_card is None:
        return False
    if gs.state.phase != TurnPhase.MAIN:
        return False
    for effect in gs.state.stadium_card.trainer_effects:
        if hasattr(effect, 'params') and effect.params.get("stadium_type") == "activatable":
            return True
    return False


def stadium_btn_rect(gs) -> pygame.Rect | None:
    """Return the activation button rect on the stadium card, if applicable."""
    if not stadium_is_activatable(gs):
        return None
    # Button at bottom of stadium card
    return pygame.Rect(STADIUM_X + 8, STADIUM_Y + CARD_HEIGHT - 32, CARD_WIDTH - 16, 26)


def _draw_hidden_card(gs, surface, rect, card_back_img, hovered=False):
    """Draw a card-back placeholder for a hidden opponent card during setup."""
    shadow_rect = pygame.Rect(rect.x + 2, rect.y + 2, rect.w, rect.h)
    _draw_card_shadow(surface, shadow_rect)
    pygame.draw.rect(surface, (20, 20, 30), rect, border_radius=7)
    if card_back_img:
        scaled = pygame.transform.smoothscale(card_back_img, (rect.w, rect.h))
        surface.blit(scaled, (rect.x, rect.y))
    else:
        # Fallback: generic card back
        pygame.draw.rect(surface, (40, 60, 120), rect, border_radius=7)
        label = gs.font_card_tiny.render("宝可梦", True, (200, 200, 220))
        surface.blit(label, label.get_rect(center=rect.center))
    border_color = UI_HIGHLIGHT if hovered else UI_BORDER
    border_w = 2 if hovered else 1
    pygame.draw.rect(surface, border_color, rect, border_w, border_radius=7)
    if hovered:
        glow_alpha = int(40 + 20 * abs(math.sin(pygame.time.get_ticks() * 0.003)))
        glow_surf = pygame.Surface((rect.w + 8, rect.h + 8), pygame.SRCALPHA)
        pygame.draw.rect(glow_surf, (255, 215, 0, glow_alpha),
                       glow_surf.get_rect(), border_radius=9)
        surface.blit(glow_surf, (rect.x - 4, rect.y - 4))


def draw_opponent_side(gs, surface, hide_cards=False):
    opponent = gs._get_opponent()

    # Info bar
    if gs.state.phase != TurnPhase.SETUP:
        info_txt = gs.font_small.render(
            f"{opponent.name} | 牌库:{len(opponent.deck)} | 手牌:{opponent.hand_count} | 奖品:{len(opponent.prizes)}",
            True, UI_TEXT_SECONDARY
        )
        surface.blit(info_txt, (12, OPP_INFO_Y))

    # Battle row: Active Pokemon (centered, large)
    if opponent.active:
        rect = gs._opp_active_rect()
        if rect:
            if hide_cards:
                _draw_hidden_card(gs, surface, rect, gs.card_back_img, hovered=gs.hovered_opp_active)
            else:
                draw_field_pokemon(gs, surface, rect.x, rect.y, opponent.active,
                                   is_opponent=True, hovered=gs.hovered_opp_active)

    # Bench row: 5 bench slots
    visible_bench = [(i, p) for i, p in enumerate(opponent.bench) if p is not None]
    for idx, (i, pokemon) in enumerate(visible_bench):
        rect = gs._opp_bench_rect(i)
        is_selected = (gs._selecting_bench_targets is not None
                       and i in gs._selected_bench_targets)
        if hide_cards:
            _draw_hidden_card(gs, surface, rect, gs.card_back_img,
                            hovered=(gs.hovered_opp_bench == i))
        else:
            draw_bench_card(gs, surface, rect.x, rect.y, pokemon,
                            hovered=(gs.hovered_opp_bench == i),
                            selected=is_selected)
    for i in range(len(visible_bench), 5):
        rect = gs._opp_bench_rect(i)
        is_targetable = (gs._selecting_bench_targets is not None
                         and gs._selecting_bench_targets.target_player == "opponent"
                         and i in gs._selecting_bench_targets.bench_indices)
        if is_targetable:
            empty_color = (100, 130, 100) if gs.hovered_opp_bench == i else (60, 100, 60)
        else:
            empty_color = (55, 75, 55) if gs.hovered_opp_bench == i else (35, 50, 35)
        pygame.draw.rect(surface, empty_color, rect, 1, border_radius=6)


def draw_player_side(gs, surface):
    player = gs._get_display_player()

    # Player info
    info_txt = gs.font_small.render(
        f"{player.name} | 奖品:{len(player.prizes)}",
        True, UI_TEXT_PRIMARY
    )
    surface.blit(info_txt, (12, PLAYER_INFO_Y))

    # Battle row: Active Pokemon (centered, large)
    if player.active:
        rect = gs._player_active_rect()
        if rect:
            draw_field_pokemon(gs, surface, rect.x, rect.y, player.active,
                               is_opponent=False, hovered=gs.hovered_active)

    # Bench row: 5 bench slots
    visible_bench = [(i, p) for i, p in enumerate(player.bench) if p is not None]
    for idx, (i, pokemon) in enumerate(visible_bench):
        rect = gs._player_bench_rect(i)
        is_selected = (gs._selecting_bench_targets is not None
                       and i in gs._selected_bench_targets)
        draw_bench_card(gs, surface, rect.x, rect.y, pokemon,
                        hovered=(gs.hovered_bench == i),
                        selected=is_selected)
    for i in range(len(visible_bench), 5):
        rect = gs._player_bench_rect(i)
        is_targetable = (gs._selecting_bench_targets is not None
                         and gs._selecting_bench_targets.target_player != "opponent"
                         and i in gs._selecting_bench_targets.bench_indices)
        if is_targetable:
            empty_color = (130, 110, 80) if gs.hovered_bench == i else (100, 80, 60)
        else:
            empty_color = (75, 105, 75) if gs.hovered_bench == i else (50, 80, 50)
        pygame.draw.rect(surface, empty_color, rect, 1, border_radius=6)


def draw_divider(gs, surface):
    pygame.draw.rect(surface, UI_BG_DARK, (0, DIVIDER_Y, SCREEN_WIDTH, DIVIDER_H))
    pygame.draw.line(surface, UI_BORDER, (0, DIVIDER_Y), (SCREEN_WIDTH, DIVIDER_Y), 2)
    pygame.draw.line(surface, UI_BORDER, (0, DIVIDER_Y + DIVIDER_H),
                     (SCREEN_WIDTH, DIVIDER_Y + DIVIDER_H), 1)

    if gs.state.phase == TurnPhase.SETUP:
        phase = "准备阶段"
    else:
        phase = PHASE_CN.get(gs.state.phase, str(gs.state.phase))

    info = f"第 {gs.state.turn_number} 回合  |  {phase}  |  {gs._get_display_player().name}"
    txt = gs.font_body.render(info, True, UI_HIGHLIGHT)
    surface.blit(txt, (16, DIVIDER_Y + 8))


def draw_setup_status(gs, surface):
    """Show setup progress (only during SETUP phase)."""
    if gs.state.phase != TurnPhase.SETUP:
        return

    for pi in [0, 1]:
        player = gs.state.get_player(pi)
        active_name = player.active.card.name if player.active else "未放置"
        bench_count = sum(1 for s in player.bench if s is not None)
        status = "准备完成" if gs.setup_pass_done[pi] else "准备中..."
        color = UI_HIGHLIGHT if gs.setup_player_idx == pi else UI_TEXT_SECONDARY
        info = f"玩家{pi+1}: 战斗区={active_name} | 备战区={bench_count}只 | {status}"
        txt = gs.font_small.render(info, True, color)
        surface.blit(txt, (12, OPP_INFO_Y + pi * 20))

    instruct = (
        f">>> 玩家{gs.setup_player_idx + 1}："
        "请从手牌中选择基础宝可梦放置到战斗区（必须）和备战区（可选），然后点击「完成准备」"
    )
    inst_txt = gs.font_small.render(instruct, True, UI_HIGHLIGHT)
    inst_x = (PLAY_AREA_W - inst_txt.get_width()) // 2
    surface.blit(inst_txt, (inst_x, DIVIDER_Y - 20))


def draw_stadium(gs, surface):
    if gs.state.stadium_card is None:
        return
    card = gs.state.stadium_card
    is_activatable = stadium_is_activatable(gs)
    player = gs._get_display_player()

    sx, sy = STADIUM_X, STADIUM_Y
    rect = pygame.Rect(sx, sy, CARD_WIDTH, CARD_HEIGHT)

    img = get_card_image_surface(gs, card.name, CARD_WIDTH, CARD_HEIGHT, card.api_id)
    if img is not None:
        surface.blit(img, (sx, sy))
        if is_activatable:
            border_color = (220, 160, 60)
        else:
            border_color = (120, 200, 120)
        pygame.draw.rect(surface, border_color, rect, 2, border_radius=8)

        if is_activatable:
            btn_rect = stadium_btn_rect(gs)
            if btn_rect:
                btn_bg = UI_BUTTON_HOVER if gs.hovered_stadium_btn else UI_BUTTON
                pygame.draw.rect(surface, btn_bg, btn_rect, border_radius=5)
                pygame.draw.rect(surface, (220, 180, 60), btn_rect, 1, border_radius=5)
                used = player.stadium_used_this_turn
                btn_label = "已使用" if used else "发动效果"
                btn_color = UI_TEXT_SECONDARY if used else UI_HIGHLIGHT
                btn_txt = gs.font_card_tiny.render(btn_label, True, btn_color)
                surface.blit(btn_txt, btn_txt.get_rect(center=btn_rect.center))
        return

    # Stadium card background
    if is_activatable:
        bg_color = (80, 60, 30)  # warm brown for activatable
        border_color = (220, 160, 60)  # gold border
    else:
        bg_color = (60, 100, 60)  # green for passive
        border_color = (120, 200, 120)

    pygame.draw.rect(surface, bg_color, rect, border_radius=8)
    pygame.draw.rect(surface, border_color, rect, 2, border_radius=8)

    # Stadium name
    name_txt = gs.font_card_name.render(card.name[:8], True, (255, 255, 255))
    surface.blit(name_txt, (sx + 4, sy + 4))

    # Type label
    type_label = "竞技场·可发动" if is_activatable else "竞技场·持续"
    type_color = (255, 200, 100) if is_activatable else (180, 255, 180)
    sub_txt = gs.font_card_tiny.render(type_label, True, type_color)
    surface.blit(sub_txt, (sx + 4, sy + 22))

    # Rules text
    if card.rules:
        rule = card.rules[0] if card.rules else ""
        for li, line in enumerate([rule[i:i+9] for i in range(0, min(len(rule), 36), 9)]):
            eff_txt = gs.font_card_tiny.render(line, True, (200, 240, 200))
            surface.blit(eff_txt, (sx + 4, sy + 38 + li * 14))

    # Activation button for activatable stadiums
    if is_activatable:
        btn_rect = stadium_btn_rect(gs)
        if btn_rect:
            # Button background
            btn_bg = UI_BUTTON_HOVER if gs.hovered_stadium_btn else UI_BUTTON
            pygame.draw.rect(surface, btn_bg, btn_rect, border_radius=5)
            pygame.draw.rect(surface, (220, 180, 60), btn_rect, 1, border_radius=5)

            # Button text
            used = player.stadium_used_this_turn
            btn_label = "已使用" if used else "发动效果"
            btn_color = UI_TEXT_SECONDARY if used else UI_HIGHLIGHT
            btn_txt = gs.font_card_tiny.render(btn_label, True, btn_color)
            surface.blit(btn_txt, btn_txt.get_rect(center=btn_rect.center))


# ── Deck / Discard Zone Rendering ───────────────────────────────

def _draw_card_stack_with_count(gs, surface, x, y, w, h, card_surface, count,
                                  label, is_discard=False, hovered=False,
                                  top_card_name=None, top_card_image=None,
                                  zone_key: str = None):
    """Draw a card stack (deck) or discard pile with count badge and label.

    If zone_key is provided and an active shuffle animation exists for it,
    the deck layers will shake in-place.
    """
    rect = pygame.Rect(x, y, w, h)

    # Drop shadow
    shadow_surf = pygame.Surface((w + 6, h + 6), pygame.SRCALPHA)
    pygame.draw.rect(shadow_surf, (0, 0, 0, 60), shadow_surf.get_rect(), border_radius=10)
    surface.blit(shadow_surf, (x - 2, y + 2))

    # Get shuffle offsets for deck layers
    shuffle_anim = getattr(gs, 'shuffle_anim', None)
    get_offset = None
    if zone_key and shuffle_anim and shuffle_anim.is_zone_active(zone_key):
        get_offset = lambda layer: shuffle_anim.get_offsets(zone_key, layer)

    if is_discard and count <= 0:
        # Empty discard pile: show empty zone outline
        empty_rect = pygame.Rect(x, y, w, h)
        pygame.draw.rect(surface, DISCARD_ZONE_EMPTY, empty_rect, border_radius=8)
        pygame.draw.rect(surface, DISCARD_ZONE_BORDER, empty_rect, 1, border_radius=8)
    elif is_discard and top_card_image is not None:
        # Discard pile: show top card image
        surface.blit(top_card_image, (x, y))
        if count > 1:
            # Show a hint of the card beneath (slightly offset)
            offset_img = pygame.Surface((w, h), pygame.SRCALPHA)
            offset_img.fill((0, 0, 0, 0))
            sub = pygame.transform.smoothscale(top_card_image, (w - 4, h - 4))
            offset_img.blit(sub, (3, 0))
            surface.blit(offset_img, (x + 1, y - 1))
    elif is_discard:
        # Discard pile: procedural card (type-colored if we have top card info)
        if top_card_name and hasattr(gs, 'image_mgr'):
            img = gs.image_mgr.get_card_image(top_card_name)
            if img is not None:
                img = pygame.transform.smoothscale(img, (w, h))
                surface.blit(img, (x, y))
            else:
                _draw_zone_card_fallback(surface, x, y, w, h, top_card_name)
        else:
            _draw_zone_card_fallback(surface, x, y, w, h, None)
    else:
        # Deck: show card back stack (layers vary by card count)
        if count <= 0:
            num_layers = 0
        elif count <= 10:
            num_layers = 1
        elif count <= 30:
            num_layers = 2
        else:
            num_layers = 3
        for layer in range(num_layers):
            lx = x + layer * 3
            ly = y - layer * 3

            # Apply shuffle offset to animate the deck itself
            dx, dy, rot_deg = 0.0, 0.0, 0.0
            if get_offset:
                dx, dy, rot_deg = get_offset(layer)

            lx += int(dx)
            ly += int(dy)

            if card_surface:
                scaled = pygame.transform.smoothscale(card_surface, (w, h))
                if abs(rot_deg) > 0.5:
                    scaled = pygame.transform.rotate(scaled, rot_deg)
                surface.blit(scaled, (lx, ly))
            else:
                bg_rect = pygame.Rect(lx, ly, w, h)
                pygame.draw.rect(surface, DECK_ZONE_BG, bg_rect, border_radius=8)
                pygame.draw.rect(surface, DECK_ZONE_BORDER, bg_rect, 1, border_radius=8)
            if layer == 0:
                pygame.draw.rect(surface, DECK_ZONE_BORDER,
                               pygame.Rect(lx, ly, w, h), 1, border_radius=8)
        # Empty deck: show empty outline
        if num_layers == 0 and not is_discard:
            empty_rect = pygame.Rect(x, y, w, h)
            pygame.draw.rect(surface, DECK_ZONE_BG, empty_rect, border_radius=8)
            pygame.draw.rect(surface, DECK_ZONE_BORDER, empty_rect, 1, border_radius=8)

    # Hover glow
    if hovered:
        glow_alpha = int(40 + 20 * abs(math.sin(pygame.time.get_ticks() * 0.003)))
        glow_surf = pygame.Surface((w + 8, h + 8), pygame.SRCALPHA)
        if is_discard:
            glow_color = (DISCARD_ZONE_HIGHLIGHT[0], DISCARD_ZONE_HIGHLIGHT[1],
                         DISCARD_ZONE_HIGHLIGHT[2], glow_alpha)
        else:
            glow_color = (DECK_ZONE_HIGHLIGHT[0], DECK_ZONE_HIGHLIGHT[1],
                         DECK_ZONE_HIGHLIGHT[2], glow_alpha)
        pygame.draw.rect(glow_surf, glow_color, glow_surf.get_rect(), border_radius=10)
        surface.blit(glow_surf, (x - 4, y - 4))

    # Zone label at top
    label_txt = gs.font_card_tiny.render(label, True, ZONE_LABEL_COLOR)
    label_sk = gs.font_card_tiny.render(label, True, (0, 0, 0))
    label_x = x + 4
    label_y = y - 14 if not is_discard else y + 4
    if is_discard:
        # Label inside card top area
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            surface.blit(label_sk, (label_x + dx, label_y + dy))
        surface.blit(label_txt, (label_x, label_y))

    # Count badge (bottom-right corner)
    badge_r = 14
    badge_cx = x + w - badge_r - 2
    badge_cy = y + h - badge_r - 2
    badge_color = DECK_COUNT_BADGE if not is_discard else (80, 40, 80)
    pygame.draw.circle(surface, badge_color, (badge_cx, badge_cy), badge_r)
    pygame.draw.circle(surface, UI_HIGHLIGHT, (badge_cx, badge_cy), badge_r, 1)

    count_str = str(count) if count <= 99 else "99+"
    cnt_txt = gs.font_card_tiny.render(count_str, True, (255, 255, 255))
    surface.blit(cnt_txt, cnt_txt.get_rect(center=(badge_cx, badge_cy)))

    # Top card label for discard
    if is_discard and top_card_name and hovered:
        top_label = gs.font_card_tiny.render(top_card_name[:5], True, UI_HIGHLIGHT)
        top_x = x + (w - top_label.get_width()) // 2
        top_y = y + h - badge_r - 16
        surface.blit(top_label, (top_x, top_y))


def _draw_zone_card_fallback(surface, x, y, w, h, card_name=None):
    """Draw a procedural card for zone (deck fallback or discard fallback)."""
    bg_rect = pygame.Rect(x, y, w, h)
    # Gradient fill
    for gy in range(h):
        t = gy / h
        r = int(30 + 10 * (1 - t))
        g = int(28 + 10 * (1 - t))
        b = int(40 + 10 * (1 - t))
        pygame.draw.line(surface, (r, g, b), (x, y + gy), (x + w, y + gy))
    pygame.draw.rect(surface, (50, 45, 60), bg_rect, border_radius=8)
    pygame.draw.rect(surface, DISCARD_ZONE_BORDER, bg_rect, 1, border_radius=8)
    if card_name:
        name_short = card_name[:4]
        n_txt = pygame.font.SysFont("simhei", 10).render(name_short, True, (200, 200, 220))
        surface.blit(n_txt, (x + 4, y + h // 2 - 6))


def draw_opponent_deck(gs, surface):
    """Draw opponent's deck as a card-back stack."""
    opponent = gs._get_opponent()
    count = len(opponent.deck)
    if count <= 0 and gs.state.phase == TurnPhase.GAME_OVER:
        return
    card_back = gs.card_back_img if hasattr(gs, 'card_back_img') else None
    o_idx = 0 if opponent is gs.state.p1 else 1
    _draw_card_stack_with_count(gs, surface,
        OPP_DECK_ZONE_X, OPP_DECK_ZONE_Y, DECK_ZONE_W, DECK_ZONE_H,
        card_back, max(0, count),
        "对手牌库", is_discard=False,
        hovered=getattr(gs, 'hovered_opp_deck', False),
        zone_key=f"shuffle_{o_idx}")


def _get_visible_top(disc, hidden_idx):
    """Get the top card name and effective count, skipping the hidden index."""
    if hidden_idx is not None and 0 <= hidden_idx < len(disc):
        visible = disc[:hidden_idx] + disc[hidden_idx + 1:]
    else:
        visible = disc
    count = len(visible)
    top = visible[-1] if visible else None
    return count, top.name if top else None, top

def draw_opponent_discard(gs, surface):
    """Draw opponent's discard pile showing top card."""
    opponent = gs._get_opponent()
    disc = opponent.discard
    hidden_discard = getattr(gs, '_hidden_discard_idx', None)
    count, top_card_name, top_card_obj = _get_visible_top(disc, hidden_discard)
    top_card_id = top_card_obj.api_id if top_card_obj else ""
    top_card_img = None
    if top_card_name and hasattr(gs, 'image_mgr'):
        raw = gs.image_mgr.get_card_image(top_card_name, top_card_id)
        if raw:
            top_card_img = pygame.transform.smoothscale(raw, (DECK_ZONE_W, DECK_ZONE_H))
    _draw_card_stack_with_count(gs, surface,
        OPP_DISCARD_ZONE_X, OPP_DISCARD_ZONE_Y, DECK_ZONE_W, DECK_ZONE_H,
        None, max(0, count),
        "弃牌区", is_discard=True,
        hovered=getattr(gs, 'hovered_opp_discard_zone', False),
        top_card_name=top_card_name,
        top_card_image=top_card_img)


def draw_player_deck(gs, surface):
    """Draw player's deck as a card-back stack."""
    player = gs._get_display_player()
    count = len(player.deck)
    card_back = gs.card_back_img if hasattr(gs, 'card_back_img') else None
    p_idx = 0 if player is gs.state.p1 else 1
    _draw_card_stack_with_count(gs, surface,
        PLAYER_DECK_ZONE_X, PLAYER_DECK_ZONE_Y, DECK_ZONE_W, DECK_ZONE_H,
        card_back, max(0, count),
        "牌库", is_discard=False,
        hovered=getattr(gs, 'hovered_player_deck', False),
        zone_key=f"shuffle_{p_idx}")


def draw_player_discard(gs, surface):
    """Draw player's discard pile showing top card."""
    player = gs._get_display_player()
    disc = player.discard
    hidden_discard = getattr(gs, '_hidden_discard_idx', None)
    count, top_card_name, top_card_obj = _get_visible_top(disc, hidden_discard)
    top_card_id = top_card_obj.api_id if top_card_obj else ""
    top_card_img = None
    if top_card_name and hasattr(gs, 'image_mgr'):
        raw = gs.image_mgr.get_card_image(top_card_name, top_card_id)
        if raw:
            top_card_img = pygame.transform.smoothscale(raw, (DECK_ZONE_W, DECK_ZONE_H))
    _draw_card_stack_with_count(gs, surface,
        PLAYER_DISCARD_ZONE_X, PLAYER_DISCARD_ZONE_Y, DECK_ZONE_W, DECK_ZONE_H,
        None, max(0, count),
        "弃牌区", is_discard=True,
        hovered=getattr(gs, 'hovered_player_discard_zone', False),
        top_card_name=top_card_name,
        top_card_image=top_card_img)


def _draw_flash_overlay(gs, surface, rect, flash_alpha, ko_alpha, slot_key=None):
    """Draw damage flash, KO fade, heal flash, and ripple overlays on a card rect."""
    if flash_alpha > 0:
        flash_surf = pygame.Surface((rect.w, rect.h), pygame.SRCALPHA)
        flash_surf.fill((255, 60, 40, flash_alpha))
        surface.blit(flash_surf, rect.topleft)

    # Heal flash (green)
    if slot_key:
        heal_alpha = gs.heal_flash.get_alpha(slot_key)
        if heal_alpha > 0:
            heal_surf = pygame.Surface((rect.w, rect.h), pygame.SRCALPHA)
            heal_surf.fill((80, 255, 100, heal_alpha))
            surface.blit(heal_surf, rect.topleft)

        # Damage ripple (expanding ring)
        ripple_ratio, ripple_alpha = gs.damage_ripple.get_ring_state(slot_key)
        if ripple_alpha > 0:
            cx = rect.x + rect.w // 2
            cy = rect.y + rect.h // 2
            max_radius = max(rect.w, rect.h) // 2
            radius = int(max_radius * ripple_ratio)
            ripple_surf = pygame.Surface((radius * 2 + 4, radius * 2 + 4), pygame.SRCALPHA)
            pygame.draw.circle(ripple_surf, (255, 200, 60, ripple_alpha),
                             (radius + 2, radius + 2), radius, 3)
            surface.blit(ripple_surf, (cx - radius - 2, cy - radius - 2))

    if ko_alpha < 255:
        ko_surf = pygame.Surface((rect.w, rect.h), pygame.SRCALPHA)
        ko_surf.fill((0, 0, 0, 255 - ko_alpha))
        surface.blit(ko_surf, rect.topleft)


def draw_field_pokemon(gs, surface, x, y, pokemon, is_opponent=False, hovered=False):
    """Draw a Pokemon in the battle zone with detailed info."""
    card = pokemon.card
    w, h = FIELD_ACTIVE_W, FIELD_ACTIVE_H

    # Apply attack shake offset for this pokemon's slot
    shake_slot = SLOT_OPP_ACTIVE if is_opponent else SLOT_PLAYER_ACTIVE
    shake_dx, _ = gs.attack_shake.get_offset(shake_slot)
    x += shake_dx

    # Determine slot key for damage flash
    flash_key = SLOT_OPP_ACTIVE if is_opponent else SLOT_PLAYER_ACTIVE
    flash_alpha = gs.damage_flash.get_alpha(flash_key)
    ko_alpha = gs.ko_fade.get_alpha(flash_key)

    img = get_card_image_surface(gs, card.name, w, h, card.api_id)
    rect = pygame.Rect(x, y, w, h)
    if img is not None:
        # Drop shadow for image-backed cards
        _draw_card_shadow(surface, rect)
        pygame.draw.rect(surface, (20, 20, 30), rect, border_radius=10)
        surface.blit(img, (x, y))
        border_color = UI_HIGHLIGHT if hovered else UI_BORDER
        border_w = 2 if hovered else 1
        pygame.draw.rect(surface, border_color, rect, border_w, border_radius=10)

        # Hover outer glow (subtle gold halo)
        if hovered:
            glow_alpha = int(40 + 20 * abs(math.sin(pygame.time.get_ticks() * 0.003)))
            glow_surf = pygame.Surface((rect.w + 8, rect.h + 8), pygame.SRCALPHA)
            pygame.draw.rect(glow_surf, (255, 215, 0, glow_alpha),
                           glow_surf.get_rect(), border_radius=12)
            surface.blit(glow_surf, (rect.x - 4, rect.y - 4))

        # Clip all overlays to card interior
        interior = pygame.Rect(x + 1, y + 1, w - 2, h - 2)
        surface.set_clip(interior)

        cur_hp = pokemon.current_hp
        ratio = cur_hp / max(card.hp, 1)

        # Damage badge (red bg, white text)
        if pokemon.damage_counters > 0:
            dmg = pokemon.damage_counters * 10
            dmg_txt = gs.font_card_tiny.render(f"伤:{dmg}", True, (255, 255, 255))
            dmg_bg = pygame.Rect(x + w - 52, y + 3, 48, 12)
            pygame.draw.rect(surface, (200, 40, 40), dmg_bg, border_radius=3)
            surface.blit(dmg_txt, (x + w - 50, y + 4))

        # Status badges (status color bg, white text)
        status_x = x + 4
        status_y = y + 4
        for status in pokemon.status_conditions:
            cn = STATUS_CN.get(status, status.name)
            sc = STATUS_COLORS.get(status.name.lower(), (200, 200, 200))
            # Darken status color for background
            bg_c = tuple(max(0, c - 40) for c in sc)
            s_bg = pygame.Rect(status_x, status_y, 18, 14)
            pygame.draw.rect(surface, bg_c, s_bg, border_radius=3)
            s_txt = gs.font_card_tiny.render(cn, True, (255, 255, 255))
            surface.blit(s_txt, (status_x + 3, status_y + 1))
            status_x += 19

        # Energy / tool indicators — bottom-center above HP bar
        info_y = y + h - 38
        has_info = False

        # Energy attachments (centered row of circles at bottom)
        if pokemon.energy_cards:
            has_info = True
            nrg = pokemon.available_energy[:7]
            total_w_e = len(nrg) * 16
            en_x = x + (w - total_w_e) // 2
            for etype in nrg:
                ec = ENERGY_COLORS.get(etype, (200, 200, 200))
                pygame.draw.circle(surface, ec, (en_x + 7, info_y + 6), 6)
                pygame.draw.circle(surface, (0, 0, 0), (en_x + 7, info_y + 6), 6, 1)
                cn = ENERGY_CN.get(etype, etype[:1])
                e_txt = gs.font_card_tiny.render(cn, True, (255, 255, 255))
                # Black outline for readability
                e_sk = gs.font_card_tiny.render(cn, True, (0, 0, 0))
                for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                    surface.blit(e_sk, e_sk.get_rect(center=(en_x + 7 + dx, info_y + 6 + dy)))
                surface.blit(e_txt, e_txt.get_rect(center=(en_x + 7, info_y + 6)))
                en_x += 16
            if len(pokemon.energy_cards) > 7:
                more = gs.font_card_tiny.render(f"+{len(pokemon.energy_cards) - 7}", True, (220, 220, 120))
                surface.blit(more, (en_x, info_y + 3))
            info_y -= 14

        # Special energy
        if pokemon.energy_cards:
            specials = [c for c in pokemon.energy_cards if c.is_special_energy]
            if specials:
                has_info = True
                sp_names = "/".join(sc.name for sc in specials)
                sp_txt = gs.font_card_tiny.render(f"特能:{sp_names}", True, (255, 255, 255))
                sp_sk = gs.font_card_tiny.render(f"特能:{sp_names}", True, (0, 0, 0))
                tw = sp_txt.get_width() + 8
                sp_bg = pygame.Rect(x + (w - tw) // 2, info_y, tw, 12)
                pygame.draw.rect(surface, (40, 100, 40), sp_bg, border_radius=3)
                for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                    surface.blit(sp_sk, (x + (w - tw) // 2 + 4 + dx, info_y + dy))
                surface.blit(sp_txt, (x + (w - tw) // 2 + 4, info_y))
                info_y -= 14

        # Tool badge (centered)
        if pokemon.attached_tool:
            tool_txt = gs.font_card_tiny.render(f"道具:{pokemon.attached_tool.name}", True, (255, 255, 255))
            tool_sk = gs.font_card_tiny.render(f"道具:{pokemon.attached_tool.name}", True, (0, 0, 0))
            tw = tool_txt.get_width() + 8
            tool_bg = pygame.Rect(x + (w - tw) // 2, info_y, tw, 12)
            pygame.draw.rect(surface, (140, 100, 30), tool_bg, border_radius=3)
            for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                surface.blit(tool_sk, (x + (w - tw) // 2 + 4 + dx, info_y + dy))
            surface.blit(tool_txt, (x + (w - tw) // 2 + 4, info_y))

        surface.set_clip(None)
        area_key = SLOT_OPP_ACTIVE if is_opponent else SLOT_PLAYER_ACTIVE
        _draw_flash_overlay(gs, surface, rect, flash_alpha, ko_alpha, area_key)
        return

    # Card background with type color
    bg = TYPE_COLORS.get(card.energy_types[0], TYPE_COLORS["Colorless"]) if card.energy_types else TYPE_COLORS["Colorless"]
    rect = pygame.Rect(x, y, w, h)

    # Drop shadow
    _draw_card_shadow(surface, rect)

    # Gradient fill (top slightly lighter than bottom)
    r_bg, g_bg, b_bg = bg
    for gy in range(rect.h):
        t = gy / rect.h
        gr = min(255, int(r_bg + 20 * (1 - t)))
        gg = min(255, int(g_bg + 20 * (1 - t)))
        gb = min(255, int(b_bg + 20 * (1 - t)))
        pygame.draw.line(surface, (gr, gg, gb),
                        (rect.x, rect.y + gy), (rect.x + rect.w, rect.y + gy))

    pygame.draw.rect(surface, bg, rect, border_radius=10)
    border_color = UI_HIGHLIGHT if hovered else UI_BORDER
    border_w = 3 if hovered else 2
    pygame.draw.rect(surface, border_color, rect, border_w, border_radius=10)

    # Hover glow
    if hovered:
        glow_alpha = int(40 + 20 * abs(math.sin(pygame.time.get_ticks() * 0.003)))
        glow_surf = pygame.Surface((rect.w + 8, rect.h + 8), pygame.SRCALPHA)
        pygame.draw.rect(glow_surf, (255, 215, 0, glow_alpha),
                       glow_surf.get_rect(), border_radius=12)
        surface.blit(glow_surf, (rect.x - 4, rect.y - 4))

    # Clip to card bounds
    inner = pygame.Rect(x + 4, y + 4, w - 8, h - 8)
    surface.set_clip(inner)

    # ── Name bar ──
    name = card.name[:6]
    name_txt = gs.font_body.render(name, True, (255, 255, 255))
    surface.blit(name_txt, (x + 8, y + 6))

    # Stage indicator
    if card.subtypes:
        stage_cn = {"Basic": "基础", "Stage 1": "1阶", "Stage 2": "2阶"}
        st = stage_cn.get(card.subtypes[0], card.subtypes[0][:3])
        stage_txt = gs.font_card_tiny.render(st, True, (220, 220, 255))
        surface.blit(stage_txt, (x + w - 38, y + 8))

    # ── HP (with dark outline for readability on all backgrounds) ──
    cur_hp = pokemon.current_hp
    ratio = cur_hp / max(card.hp, 1)
    if ratio > 0.5:
        hp_color = (255, 255, 255)
    elif ratio > 0.25:
        hp_color = (255, 220, 60)
    else:
        hp_color = (255, 80, 80)
    hp_text = f"HP {cur_hp}/{card.hp}"
    # Render dark outline first for contrast
    hp_shadow = gs.font_body.render(hp_text, True, (0, 0, 0))
    for dx, dy in [(-1, -1), (1, -1), (-1, 1), (1, 1)]:
        surface.blit(hp_shadow, (x + 8 + dx, y + 26 + dy))
    hp_txt = gs.font_body.render(hp_text, True, hp_color)
    surface.blit(hp_txt, (x + 8, y + 26))

    # Damage counters
    if pokemon.damage_counters > 0:
        dmg = pokemon.damage_counters * 10
        dmg_txt = gs.font_card_tiny.render(f"伤害:{dmg}", True, (255, 120, 120))
        surface.blit(dmg_txt, (x + w - 58, y + 28))

    # ── Status conditions ──
    status_x = x + 8
    status_y = y + 46
    for status in pokemon.status_conditions:
        cn = STATUS_CN.get(status, status.name)
        sc = STATUS_COLORS.get(status.name.lower(), (200, 200, 200))
        s_txt = gs.font_card_tiny.render(cn, True, sc)
        surface.blit(s_txt, (status_x, status_y))
        status_x += 20

    # ── Energy row ──
    if pokemon.energy_cards:
        en_x = x + 8
        en_y = y + 62 if not pokemon.status_conditions else y + 64
        for etype in pokemon.available_energy[:7]:
            ec = ENERGY_COLORS.get(etype, (200, 200, 200))
            pygame.draw.circle(surface, ec, (en_x + 8, en_y + 8), 9)
            pygame.draw.circle(surface, (0, 0, 0), (en_x + 8, en_y + 8), 9, 1)
            cn = ENERGY_CN.get(etype, etype[:1])
            e_txt = gs.font_card_tiny.render(cn, True, (0, 0, 0))
            surface.blit(e_txt, e_txt.get_rect(center=(en_x + 8, en_y + 8)))
            en_x += 20
        if len(pokemon.energy_cards) > 7:
            more = gs.font_card_tiny.render(f"+{len(pokemon.energy_cards) - 7}", True, (200, 200, 100))
            surface.blit(more, (en_x, en_y + 4))

    # ── Special energy display ──
    sp_en_y = y + 86 if pokemon.energy_cards else y + 62
    if pokemon.energy_cards:
        specials = [c for c in pokemon.energy_cards if c.is_special_energy]
        if specials:
            sp_names = "/".join(sc.name for sc in specials)
            sp_txt = gs.font_card_tiny.render(f"特能:{sp_names}", True, (180, 220, 180))
            surface.blit(sp_txt, (x + 8, sp_en_y))
            sp_en_y += 16

    # ── Tool ──
    tool_y = sp_en_y
    if pokemon.attached_tool:
        tool_txt = gs.font_card_tiny.render(f"道具:{pokemon.attached_tool.name}", True, (180, 180, 80))
        surface.blit(tool_txt, (x + 8, tool_y))

    # ── Abilities ──
    ability_y = tool_y + 18 if pokemon.attached_tool else tool_y + 4
    ab_row_h = 28  # name (13px) + text (13px) + gap
    if card.abilities:
        for ai, ab in enumerate(card.abilities):
            ab_y = ability_y + ai * ab_row_h
            # Name bar
            ab_bg = pygame.Rect(x + 4, ab_y, w - 8, 13)
            pygame.draw.rect(surface, (100, 25, 25), ab_bg, border_radius=3)
            ab_name = ab.name[:10]
            ab_txt = gs.font_card_tiny.render(ab_name, True, (255, 210, 140))
            surface.blit(ab_txt, (x + 7, ab_y + 1))
            # Ability text (wrap to 2 lines)
            if ab.text:
                max_chars = 11
                ab_lines = [ab.text[i:i+max_chars] for i in range(0, len(ab.text), max_chars)]
                for li, line in enumerate(ab_lines[:2]):
                    ab_body = gs.font_card_tiny.render(line, True, (200, 160, 180))
                    surface.blit(ab_body, (x + 7, ab_y + 14 + li * 12))

    # ── Attacks ──
    ability_offset = len(card.abilities) * ab_row_h
    atk_start_y = ability_y + ability_offset + 4 if card.abilities else tool_y + 20 if pokemon.attached_tool else y + 82
    max_atks = min(3, len(card.attacks))
    remaining_h = (y + h - 24) - atk_start_y
    atk_row_h = max(36, remaining_h // max(max_atks, 1)) if max_atks > 0 else 36

    atk_y = atk_start_y
    for attack in card.attacks[:max_atks]:
        # Cost circles
        cost_x = x + 8
        for etype in attack.cost[:5]:
            ec = ENERGY_COLORS.get(etype, (200, 200, 200))
            pygame.draw.circle(surface, ec, (cost_x + 6, atk_y + 7), 6)
            pygame.draw.circle(surface, (0, 0, 0), (cost_x + 6, atk_y + 7), 6, 1)
            if etype in ENERGY_CN:
                e_txt = gs.font_card_tiny.render(ENERGY_CN[etype], True, (0, 0, 0))
                surface.blit(e_txt, e_txt.get_rect(center=(cost_x + 6, atk_y + 7)))
            cost_x += 14

        # Attack name + damage
        dmg_str = str(attack.damage) if attack.damage > 0 else ""
        atk_name = attack.name[:8]
        atk_str = f"{atk_name}  {dmg_str}"
        atk_txt = gs.font_card_body.render(atk_str, True, (0, 0, 0))
        surface.blit(atk_txt, (x + 8, atk_y + 16))

        # Effect text (wrap to 2 lines to fit within card width ~104px)
        if attack.text:
            max_chars = 11  # ~10px per char, 104px available
            text_lines = [attack.text[i:i+max_chars] for i in range(0, len(attack.text), max_chars)]
            for li, line in enumerate(text_lines[:2]):
                eff_txt = gs.font_card_tiny.render(line, True, (40, 40, 60))
                surface.blit(eff_txt, (x + 8, atk_y + 30 + li * 12))

        atk_y += atk_row_h

    # ── Bottom row: weakness / resistance / retreat ──
    bottom_y = y + h - 16
    bx = x + 6
    if card.weaknesses:
        w_type = ENERGY_CN.get(card.weaknesses[0].energy_type, card.weaknesses[0].energy_type)
        w_txt = gs.font_card_tiny.render(f"弱:{w_type}{card.weaknesses[0].value}", True, (220, 80, 80))
        surface.blit(w_txt, (bx, bottom_y))
        bx += 48
    if card.resistances:
        r_type = ENERGY_CN.get(card.resistances[0].energy_type, card.resistances[0].energy_type)
        r_txt = gs.font_card_tiny.render(f"抗:{r_type}{card.resistances[0].value}", True, (80, 80, 220))
        surface.blit(r_txt, (bx, bottom_y))
        bx += 48
    ret_txt = gs.font_card_body.render(f"撤{card.retreat_cost}", True, (60, 60, 60))
    surface.blit(ret_txt, (x + w - 36, bottom_y))

    # HP bar with background track
    bar_y = y + h - 3
    bar_w = int(w * ratio)
    bar_color = (80, 200, 80) if ratio > 0.5 else (220, 180, 40) if ratio > 0.25 else (220, 60, 60)
    # Background track (empty portion)
    pygame.draw.rect(surface, (40, 40, 40), (x, bar_y, w, 3))
    # Filled HP bar
    if ratio <= 0.25:
        pulse = int(80 + 60 * abs(math.sin(pygame.time.get_ticks() * 0.005)))
        bar_color = (220, pulse, pulse)
    pygame.draw.rect(surface, bar_color, (x, bar_y, bar_w, 3))

    surface.set_clip(None)

    _draw_flash_overlay(gs, surface, rect, 0, 255)


def draw_bench_card(gs, surface, x, y, pokemon, hovered=False, selected=False):
    """Draw a compact bench Pokemon card with key info."""
    card = pokemon.card
    w, h = FIELD_BENCH_W, FIELD_BENCH_H

    img = get_card_image_surface(gs, card.name, w, h, card.api_id)
    rect = pygame.Rect(x, y, w, h)
    if img is not None:
        _draw_card_shadow(surface, rect)
        pygame.draw.rect(surface, (20, 20, 30), rect, border_radius=7)
        surface.blit(img, (x, y))
        if selected:
            border_color = (255, 200, 60)
            border_w = 2
        elif hovered:
            border_color = UI_HIGHLIGHT
            border_w = 2
        else:
            border_color = UI_BORDER
            border_w = 1
        pygame.draw.rect(surface, border_color, rect, border_w, border_radius=7)

        # Hover glow
        if hovered:
            glow_alpha = int(40 + 20 * abs(math.sin(pygame.time.get_ticks() * 0.003)))
            glow_surf = pygame.Surface((rect.w + 8, rect.h + 8), pygame.SRCALPHA)
            pygame.draw.rect(glow_surf, (255, 215, 0, glow_alpha),
                           glow_surf.get_rect(), border_radius=9)
            surface.blit(glow_surf, (rect.x - 4, rect.y - 4))

        # Clip overlays to card interior
        interior = pygame.Rect(x + 1, y + 1, w - 2, h - 2)
        surface.set_clip(interior)

        cur_hp = pokemon.current_hp

        # Damage badge
        if pokemon.damage_counters > 0:
            dmg_txt = gs.font_card_tiny.render(f"伤:{pokemon.damage_counters * 10}", True, (255, 255, 255))
            dmg_bg = pygame.Rect(x + 2, y + 2, 44, 11)
            pygame.draw.rect(surface, (200, 40, 40), dmg_bg, border_radius=2)
            surface.blit(dmg_txt, (x + 4, y + 3))

        # Bottom info row: energy count + tool + status
        info_y = y + h - 28

        # Energy count badge (bottom-left)
        if pokemon.energy_cards:
            en_count = len(pokemon.energy_cards)
            en_txt = gs.font_card_tiny.render(f"能:{en_count}", True, (255, 255, 255))
            en_sk = gs.font_card_tiny.render(f"能:{en_count}", True, (0, 0, 0))
            en_bg = pygame.Rect(x + 2, info_y, 34, 11)
            pygame.draw.rect(surface, (40, 80, 40), en_bg, border_radius=2)
            for ddx, ddy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                surface.blit(en_sk, (x + 4 + ddx, info_y + ddy))
            surface.blit(en_txt, (x + 4, info_y))
            info_y -= 13

        # Tool indicator (bottom-left, below energy)
        if pokemon.attached_tool:
            tool_txt = gs.font_card_tiny.render("道具", True, (255, 255, 255))
            tool_sk = gs.font_card_tiny.render("道具", True, (0, 0, 0))
            tool_bg = pygame.Rect(x + 2, info_y, 26, 11)
            pygame.draw.rect(surface, (140, 100, 30), tool_bg, border_radius=2)
            for ddx, ddy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                surface.blit(tool_sk, (x + 4 + ddx, info_y + ddy))
            surface.blit(tool_txt, (x + 4, info_y))

        # Status at bottom-right
        status_y = y + h - 14
        status_avail = x + w - 4
        for status in pokemon.status_conditions:
            cn = STATUS_CN.get(status, status.name[:2])
            sc = STATUS_COLORS.get(status.name.lower(), (200, 200, 200))
            bg_c = tuple(max(0, c - 40) for c in sc)
            s_txt = gs.font_card_tiny.render(cn, True, (255, 255, 255))
            s_sk = gs.font_card_tiny.render(cn, True, (0, 0, 0))
            s_bg = pygame.Rect(status_avail - 17, status_y, 17, 12)
            pygame.draw.rect(surface, bg_c, s_bg, border_radius=2)
            for ddx, ddy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                surface.blit(s_sk, (status_avail - 14 + ddx, status_y + 1 + ddy))
            surface.blit(s_txt, (status_avail - 14, status_y + 1))
            status_avail -= 19

        surface.set_clip(None)
        return

    # Background
    bg = TYPE_COLORS.get(card.energy_types[0], TYPE_COLORS["Colorless"]) if card.energy_types else (100, 120, 100)
    rect = pygame.Rect(x, y, w, h)

    # Drop shadow
    _draw_card_shadow(surface, rect)

    # Gradient fill
    r_bg, g_bg, b_bg = bg
    for gy in range(rect.h):
        t = gy / rect.h
        gr = min(255, int(r_bg + 15 * (1 - t)))
        gg = min(255, int(g_bg + 15 * (1 - t)))
        gb = min(255, int(b_bg + 15 * (1 - t)))
        pygame.draw.line(surface, (gr, gg, gb),
                        (rect.x, rect.y + gy), (rect.x + rect.w, rect.y + gy))

    pygame.draw.rect(surface, bg, rect, border_radius=7)
    if selected:
        border_color = (255, 200, 60)  # gold highlight for selected
        border_w = 3
    elif hovered:
        border_color = UI_HIGHLIGHT
        border_w = 3
    else:
        border_color = UI_BORDER
        border_w = 1
    pygame.draw.rect(surface, border_color, rect, border_w, border_radius=7)

    # Hover glow
    if hovered:
        glow_alpha = int(40 + 20 * abs(math.sin(pygame.time.get_ticks() * 0.003)))
        glow_surf = pygame.Surface((rect.w + 8, rect.h + 8), pygame.SRCALPHA)
        pygame.draw.rect(glow_surf, (255, 215, 0, glow_alpha),
                       glow_surf.get_rect(), border_radius=9)
        surface.blit(glow_surf, (rect.x - 4, rect.y - 4))

    inner = pygame.Rect(x + 3, y + 3, w - 6, h - 6)
    surface.set_clip(inner)

    # Name
    name = card.name[:5]
    name_txt = gs.font_card_tiny.render(name, True, (255, 255, 255))
    surface.blit(name_txt, (x + 4, y + 4))

    # HP (with dark outline for readability)
    cur_hp = pokemon.current_hp
    if cur_hp > card.hp // 2:
        hp_color = (255, 255, 255)
    elif cur_hp > card.hp // 4:
        hp_color = (255, 220, 60)
    else:
        hp_color = (255, 100, 100)
    hp_text = f"HP{cur_hp}/{card.hp}"
    hp_shadow = gs.font_card_tiny.render(hp_text, True, (0, 0, 0))
    for ddx, ddy in [(-1, -1), (1, 1)]:
        surface.blit(hp_shadow, (x + w - 52 + ddx, y + 4 + ddy))
    hp_txt = gs.font_card_tiny.render(hp_text, True, hp_color)
    surface.blit(hp_txt, (x + w - 52, y + 4))

    row_y = y + 20

    # Stage
    if card.subtypes:
        stage_cn = {"Basic": "基础", "Stage 1": "1阶", "Stage 2": "2阶"}
        st = stage_cn.get(card.subtypes[0], card.subtypes[0][:3])
        stage_txt = gs.font_card_tiny.render(st, True, (200, 210, 240))
        surface.blit(stage_txt, (x + 4, row_y))
        row_y += 14

    # Damage counters
    if pokemon.damage_counters > 0:
        dmg_txt = gs.font_card_tiny.render(f"伤:{pokemon.damage_counters * 10}", True, (255, 110, 110))
        surface.blit(dmg_txt, (x + 4, row_y))
        row_y += 14

    # Energy count
    if pokemon.energy_cards:
        en_txt = gs.font_card_tiny.render(f"能:{len(pokemon.energy_cards)}", True, (210, 210, 100))
        surface.blit(en_txt, (x + 4, row_y))
        row_y += 14

    # First attack (abbreviated)
    if card.attacks:
        atk = card.attacks[0]
        cost_str = "".join(ENERGY_CN.get(e, e[:1]) for e in atk.cost[:3])
        dmg_str = str(atk.damage) if atk.damage > 0 else ""
        atk_name = atk.name[:4]
        atk_str = f"{cost_str} {atk_name}{dmg_str}"
        atk_txt = gs.font_card_tiny.render(atk_str, True, (10, 10, 10))
        surface.blit(atk_txt, (x + 4, row_y))
        row_y += 14

    # Tool indicator
    if pokemon.attached_tool:
        tool_txt = gs.font_card_tiny.render("道具", True, (160, 160, 60))
        surface.blit(tool_txt, (x + 4, row_y))
        row_y += 14

    # Abilities indicator
    if card.abilities:
        ab = card.abilities[0]
        ab_name = ab.name[:6]
        ab_txt = gs.font_card_tiny.render(f"特:{ab_name}", True, (255, 200, 140))
        surface.blit(ab_txt, (x + 4, row_y))
        if ab.text:
            row_y += 13
            ab_desc = gs.font_card_tiny.render(ab.text[:18], True, (180, 140, 160))
            surface.blit(ab_desc, (x + 4, row_y))

    # Status at bottom
    status_y = y + h - 14
    sx = x + 3
    for status in pokemon.status_conditions:
        cn = STATUS_CN.get(status, status.name[:2])
        sc = STATUS_COLORS.get(status.name.lower(), (200, 200, 200))
        s_txt = gs.font_card_tiny.render(cn, True, sc)
        surface.blit(s_txt, (sx, status_y))
        sx += 18

    # HP bar with background track
    ratio = cur_hp / max(card.hp, 1)
    bar_y = y + h - 2
    bar_w = int(w * ratio)
    pygame.draw.rect(surface, (40, 40, 40), (x, bar_y, w, 2))  # track
    if ratio > 0.5:
        bar_color = (80, 200, 80)
    elif ratio > 0.25:
        bar_color = (220, 180, 40)
    else:
        pulse = int(80 + 60 * abs(math.sin(pygame.time.get_ticks() * 0.005)))
        bar_color = (220, pulse, pulse)
    pygame.draw.rect(surface, bar_color, (x, bar_y, bar_w, 2))

    surface.set_clip(None)


def draw_field_tooltips(gs, surface):
    """Show detailed tooltips when hovering over field Pokemon or hand cards."""
    from ui.components.card_detail import draw_tooltip_box, pokemon_extra_info

    player = gs._get_display_player()
    opponent = gs._get_opponent()

    # Hand card tooltip
    if gs.hovered_hand is not None and gs.hovered_hand < len(player.hand):
        card = player.hand[gs.hovered_hand]
        draw_tooltip_box(gs, surface, card, 10, SCREEN_HEIGHT - 260)

    # Player active tooltip
    if gs.hovered_active and player.active:
        rect = gs._player_active_rect()
        if rect:
            draw_tooltip_box(gs, surface, player.active.card,
                             rect.x + FIELD_ACTIVE_W + 10, rect.y,
                             extra_info=pokemon_extra_info(gs, player.active))

    # Player bench tooltip
    if gs.hovered_bench is not None and player.bench[gs.hovered_bench]:
        rect = gs._player_bench_rect(gs.hovered_bench)
        poke = player.bench[gs.hovered_bench]
        draw_tooltip_box(gs, surface, poke.card,
                         rect.x + FIELD_BENCH_W + 8, rect.y,
                         extra_info=pokemon_extra_info(gs, poke))

    # Opponent active tooltip
    if gs.hovered_opp_active and opponent.active:
        rect = gs._opp_active_rect()
        if rect:
            draw_tooltip_box(gs, surface, opponent.active.card,
                             rect.x + FIELD_ACTIVE_W + 10, rect.y,
                             extra_info=pokemon_extra_info(gs, opponent.active))

    # Opponent bench tooltip
    if gs.hovered_opp_bench is not None and opponent.bench[gs.hovered_opp_bench]:
        rect = gs._opp_bench_rect(gs.hovered_opp_bench)
        poke = opponent.bench[gs.hovered_opp_bench]
        draw_tooltip_box(gs, surface, poke.card,
                         rect.x + FIELD_BENCH_W + 8, rect.y,
                         extra_info=pokemon_extra_info(gs, poke))

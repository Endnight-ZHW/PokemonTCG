"""Action buttons, attack menu, and ability menu rendering."""
import pygame
from config import SCREEN_WIDTH, SCREEN_HEIGHT
from ui.colors import (
    UI_BORDER, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY, UI_HIGHLIGHT,
)
from ui.layout_model import DEFAULT_GAME_LAYOUT
from ui.energy_icons import draw_energy_icon
from ui.ui_theme import draw_panel, draw_button, draw_text_fit
from engine.enums import TurnPhase, PlayerAction
from engine.rules_validator import can_declare_attack
from engine.game_engine import DEFAULT_GAME_ENGINE


def _display_player(gs):
    return gs._get_display_player() if hasattr(gs, "_get_display_player") else None


def _display_player_idx(gs, player) -> int:
    state = getattr(gs, "state", None)
    if state is None or player is None:
        return -1
    if player is state.p1:
        return 0
    if player is state.p2:
        return 1
    return getattr(state, "active_player_idx", -1)


def _manual_ability_exists(gs, player) -> bool:
    if not player:
        return False
    checker = getattr(gs, "_has_manual_ability", None)
    if player.active and checker and checker(player.active):
        return True
    if player.active and not checker and player.active.card.abilities:
        return True
    for poke in player.bench:
        if not poke:
            continue
        if checker and checker(poke):
            return True
        if not checker and poke.card.abilities:
            return True
    return False


def _draw_menu_item_border(surface, rect, is_hover):
    """Draw a border with animated pulse for hovered menu items."""
    if is_hover:
        pulse = int(40 + 30 * abs(pygame.time.get_ticks() * 0.003 % (2 * 3.14159)))
        border_c = (255, min(255, 180 + pulse), 0)
        border_w = 2
    else:
        border_c = UI_BORDER
        border_w = 1
    pygame.draw.rect(surface, border_c, rect, border_w, border_radius=6)


def draw_attack_menu(gs, surface):
    """Draw attack selection overlay with effect descriptions."""
    if not gs._attack_menu_open:
        return

    overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
    overlay.fill((10, 10, 20, 180))
    surface.blit(overlay, (0, 0))

    num_atks = len(gs._attack_menu_attacks)
    item_h = 56
    total_h = num_atks * (item_h + 10) - 10
    my = SCREEN_HEIGHT // 2 - total_h // 2 - 20
    mx = SCREEN_WIDTH // 2 - 240
    btn_w = 480

    title = gs.font_info.render("选择招式", True, UI_HIGHLIGHT)
    surface.blit(title, title.get_rect(center=(SCREEN_WIDTH // 2, my - 30)))

    for i, (atk_idx, attack) in enumerate(gs._attack_menu_attacks):
        item_y = my + i * (item_h + 10)
        rect = pygame.Rect(mx, item_y, btn_w, item_h)
        is_hover = i == gs._attack_menu_hover

        # Gradient background for menu items
        if is_hover:
            top_c, bot_c = (90, 110, 180), (60, 75, 140)
        else:
            top_c, bot_c = (60, 75, 130), (45, 55, 100)
        for gy in range(rect.height):
            t = gy / rect.height
            r = int(top_c[0] + (bot_c[0] - top_c[0]) * t)
            g = int(top_c[1] + (bot_c[1] - top_c[1]) * t)
            b = int(top_c[2] + (bot_c[2] - top_c[2]) * t)
            pygame.draw.line(surface, (r, g, b), (rect.x, rect.y + gy), (rect.x + rect.w, rect.y + gy))

        _draw_menu_item_border(surface, rect, is_hover)

        # Row 1: energy cost circles + attack name + damage
        cost_x = mx + 14
        row1_y = item_y + 6
        for etype in attack.cost:
            draw_energy_icon(surface, gs.image_mgr, etype,
                             (cost_x + 9, row1_y + 10), 18,
                             gs.font_card_tiny)
            cost_x += 22

        dmg_part = f"伤害:{attack.damage}" if attack.damage > 0 else ""
        atk_str = f"{attack.name}  {dmg_part}"
        atk_txt = gs.font_action.render(atk_str, True, UI_TEXT_PRIMARY)
        surface.blit(atk_txt, (cost_x + 10, row1_y + 4))

        # Damage preview against opponent's active
        preview = getattr(gs, '_attack_menu_damage_previews', {}).get(atk_idx, None)
        if preview and preview.get("damage", 0) > 0:
            preview_dmg = preview["damage"]
            # Color based on outcome
            if preview.get("will_ko"):
                prev_color = (100, 255, 100)  # Green: will KO
            elif preview_dmg >= 50:
                prev_color = (255, 255, 100)  # Yellow: significant
            else:
                prev_color = (200, 200, 200)  # White: normal

            prev_str = f" 预计:{preview_dmg}"
            if preview.get("weakness"):
                prev_str += " 弱!"
            if preview.get("resistance"):
                prev_str += " 抗"
            prev_txt = gs.font_card_body.render(prev_str, True, prev_color)
            surface.blit(prev_txt, (cost_x + 10 + atk_txt.get_width() + 8, row1_y + 5))

        # Row 2: effect description text (wrap to 2 lines)
        if attack.text:
            max_chars = 42  # ~10px per char, ~420px available
            text_lines = [attack.text[i:i+max_chars] for i in range(0, len(attack.text), max_chars)]
            for li, line in enumerate(text_lines[:2]):
                eff_txt = gs.font_card_tiny.render(line, True, UI_TEXT_SECONDARY)
                surface.blit(eff_txt, (mx + 14, row1_y + 24 + li * 12))
        else:
            no_eff = gs.font_card_tiny.render("（无特殊效果）", True, (100, 100, 120))
            surface.blit(no_eff, (mx + 14, row1_y + 24))


def draw_ability_menu(gs, surface):
    """Draw ability selection overlay when Pokemon has multiple abilities."""
    if not gs._ability_menu_open:
        return

    overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
    overlay.fill((10, 10, 20, 180))
    surface.blit(overlay, (0, 0))

    num_abs = len(gs._ability_menu_abilities)
    item_h = 48
    total_h = num_abs * (item_h + 8) - 8
    my = SCREEN_HEIGHT // 2 - total_h // 2 - 20
    mx = SCREEN_WIDTH // 2 - 240
    btn_w = 480

    title = gs.font_info.render("选择特性", True, UI_HIGHLIGHT)
    surface.blit(title, title.get_rect(center=(SCREEN_WIDTH // 2, my - 30)))

    for i, ab in enumerate(gs._ability_menu_abilities):
        item_y = my + i * (item_h + 8)
        rect = pygame.Rect(mx, item_y, btn_w, item_h)
        is_hover = i == gs._ability_menu_hover

        # Gradient background
        if is_hover:
            top_c, bot_c = (90, 110, 180), (60, 75, 140)
        else:
            top_c, bot_c = (60, 75, 130), (45, 55, 100)
        for gy in range(rect.height):
            t = gy / rect.height
            r = int(top_c[0] + (bot_c[0] - top_c[0]) * t)
            g = int(top_c[1] + (bot_c[1] - top_c[1]) * t)
            b = int(top_c[2] + (bot_c[2] - top_c[2]) * t)
            pygame.draw.line(surface, (r, g, b), (rect.x, rect.y + gy), (rect.x + rect.w, rect.y + gy))

        _draw_menu_item_border(surface, rect, is_hover)

        # Ability name
        type_str = {"Ability": "特性", "Poke-Power": "特殊能力",
                    "Poke-Body": "特殊体质", "VSTAR Power": "VSTAR力量"}
        ab_type = type_str.get(ab.ability_type, ab.ability_type)
        name_str = f"[{ab_type}] {ab.name}"
        name_txt = gs.font_action.render(name_str, True, UI_TEXT_PRIMARY)
        surface.blit(name_txt, (mx + 12, item_y + 4))

        # Ability text
        if ab.text:
            effect_str = ab.text[:55]
            eff_txt = gs.font_card_tiny.render(effect_str, True, UI_TEXT_SECONDARY)
            surface.blit(eff_txt, (mx + 12, item_y + 24))


# Phase controls replace the old catch-all action button panel.  These
# definitions intentionally come last so older helper names keep working for
# GameScreen imports while producing the new UI.
def _action_state(gs, action) -> tuple[bool, str, str]:
    state = getattr(gs, "state", None)
    player = _display_player(gs)
    if state is None or player is None:
        return False, "没有游戏状态", "normal"

    if action == "SETUP_DONE":
        return player.active is not None, "请先设置战斗宝可梦", "primary"

    if action == "ENTER_ATTACK":
        if state.phase != TurnPhase.MAIN:
            return False, "只能从主要阶段进入攻击", "attack"
        player_idx = _display_player_idx(gs, player)
        if player_idx < 0 or not player.active:
            return False, "没有可攻击的战斗宝可梦", "attack"
        reasons: list[str] = []
        if any(
            candidate.action == PlayerAction.DECLARE_ATTACK
            for candidate in DEFAULT_GAME_ENGINE.legal_actions(
                state,
                player_idx,
                validate_effects=False,
            )
        ):
            return True, "", "attack"
        for attack_idx, _ in enumerate(player.active.card.attacks):
            ok, reason = can_declare_attack(state, player_idx, attack_idx)
            if ok:
                return True, "", "attack"
            if reason:
                reasons.append(reason)
        return False, reasons[0] if reasons else "没有可用招式", "attack"

    if action == PlayerAction.END_TURN:
        return state.phase in (TurnPhase.MAIN, TurnPhase.ATTACK), "", "danger"

    return False, "", "normal"


def build_action_buttons(gs):
    """Build the right-side phase controls."""
    gs.action_buttons.clear()

    if gs.state and gs.state.phase == TurnPhase.SETUP:
        actions = [("完成准备", "SETUP_DONE")]
    elif gs.state and gs.state.phase == TurnPhase.MAIN:
        actions = [
            ("攻击阶段", "ENTER_ATTACK"),
            ("结束回合", PlayerAction.END_TURN),
        ]
    elif gs.state and gs.state.phase == TurnPhase.ATTACK:
        actions = [("结束回合", PlayerAction.END_TURN)]
    else:
        actions = []

    layout = getattr(gs, "layout", DEFAULT_GAME_LAYOUT)
    panel = pygame.Rect(layout.action_panel.x + 12, layout.action_panel.y + 92,
                        layout.action_panel.w - 24, layout.action_panel.h - 104)
    gap = 8
    btn_h = 38
    btn_w = panel.w
    for i, (label, action) in enumerate(actions):
        rect = pygame.Rect(panel.x, panel.y + i * (btn_h + gap), btn_w, btn_h)
        enabled, reason, style = _action_state(gs, action)
        gs.action_buttons.append({
            "rect": rect,
            "label": label,
            "action": action,
            "enabled": enabled,
            "reason": reason,
            "style": style,
        })
    gs.phase_buttons = gs.action_buttons


def draw_action_buttons(gs, surface):
    layout = getattr(gs, "layout", DEFAULT_GAME_LAYOUT)
    inner = draw_panel(surface, layout.action_panel, "回合阶段", gs.font_small)
    state = getattr(gs, "state", None)
    if state:
        player = gs._get_display_player()
        info_rect = pygame.Rect(inner.x, inner.y - 4, inner.w, 18)
        turn_txt = f"第{state.turn_number}回合 · {player.name}"
        draw_text_fit(surface, gs.font_card_tiny, turn_txt,
                      UI_TEXT_SECONDARY, info_rect)

        steps = [
            (TurnPhase.DRAW, "抽牌"),
            (TurnPhase.MAIN, "主要"),
            (TurnPhase.ATTACK, "攻击"),
            (TurnPhase.POKEMON_CHECKUP, "检查"),
        ]
        step_y = inner.y + 24
        step_gap = 6
        step_w = max(48, (inner.w - step_gap * (len(steps) - 1)) // len(steps))
        for idx, (phase_key, label) in enumerate(steps):
            rect = pygame.Rect(inner.x + idx * (step_w + step_gap), step_y,
                               step_w, 24)
            active = state.phase == phase_key
            bg = (70, 95, 130) if active else (34, 40, 58)
            border = UI_HIGHLIGHT if active else UI_BORDER
            pygame.draw.rect(surface, bg, rect, border_radius=6)
            pygame.draw.rect(surface, border, rect, 1, border_radius=6)
            color = UI_TEXT_PRIMARY if active else UI_TEXT_SECONDARY
            draw_text_fit(surface, gs.font_card_tiny, label, color,
                          rect.inflate(-6, 0))

    disabled_reason = ""
    for i, item in enumerate(gs.action_buttons):
        rect = item["rect"]
        enabled = item.get("enabled", True)
        style = item.get("style", "normal")
        is_hover = i == gs.hovered_button
        if is_hover and not enabled:
            disabled_reason = item.get("reason", "")
        draw_button(
            surface, rect, item["label"], gs.font_action,
            hovered=is_hover, selected=False, enabled=enabled,
            danger=(style == "danger"), attack=(style == "attack"),
        )

    if disabled_reason:
        hint_rect = pygame.Rect(inner.x, layout.action_panel.bottom - 28,
                                inner.w, 18)
        draw_text_fit(surface, gs.font_card_tiny, disabled_reason,
                      UI_TEXT_SECONDARY, hint_rect)

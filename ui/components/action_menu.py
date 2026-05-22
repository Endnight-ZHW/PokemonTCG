"""Action buttons, attack menu, and ability menu rendering."""
import pygame
from config import SCREEN_WIDTH, SCREEN_HEIGHT, ENERGY_NAME_CN as ENERGY_CN
from ui.colors import (
    UI_BORDER, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY,
    UI_HIGHLIGHT, UI_BUTTON, UI_BUTTON_HOVER, UI_BUTTON_ACTIVE,
    ENERGY_COLORS,
    BTN_GRADIENT_TOP, BTN_GRADIENT_BOT, BTN_ATTACK_GRADIENT_TOP, BTN_ATTACK_GRADIENT_BOT,
)
from engine.enums import TurnPhase, PlayerAction
from ui.components.game_layout import (
    BTN_W, BTN_H, BTN_GAP, BTN_ROW1_Y, BTN_ROW2_Y, PLAY_AREA_W,
)


def build_action_buttons(gs):
    """Build action buttons in 2 rows below player info."""
    gs.action_buttons.clear()

    if gs.state and gs.state.phase == TurnPhase.SETUP:
        actions = [
            ("放到战斗区", "PLACE_ACTIVE"),
            ("放到备战区", "PLACE_BENCH"),
            ("完成准备", "SETUP_DONE"),
        ]
    elif gs.state and gs.state.phase == TurnPhase.ATTACK:
        # After declaring an attack, only End Turn is available
        actions = [("结束回合", PlayerAction.END_TURN)]
    else:
        actions = [
            ("打出基础", PlayerAction.PLAY_BASIC),
            ("进化", PlayerAction.EVOLVE),
            ("附着能量", PlayerAction.ATTACH_ENERGY),
            ("训练家", PlayerAction.PLAY_TRAINER),
            ("特性", PlayerAction.USE_ABILITY),
            ("撤退", PlayerAction.RETREAT),
            ("攻击!", PlayerAction.DECLARE_ATTACK),
        ]
        if gs.state and gs.state.stadium_card and gs.state.phase == TurnPhase.MAIN:
            # Only show button for activatable stadiums
            for effect in gs.state.stadium_card.trainer_effects:
                if hasattr(effect, 'params') and effect.params.get("stadium_type") == "activatable":
                    stadium_name = gs.state.stadium_card.name[:6]
                    actions.append((f"竞技场:{stadium_name}", PlayerAction.USE_STADIUM))
                    break
        actions.append(("结束回合", PlayerAction.END_TURN))

    per_row = 5
    rows = (len(actions) + per_row - 1) // per_row
    for i, (label, action) in enumerate(actions):
        row = i // per_row
        col = i % per_row
        row_count = min(per_row, len(actions) - row * per_row)
        row_w = row_count * BTN_W + (row_count - 1) * BTN_GAP
        row_x = (PLAY_AREA_W - row_w) // 2
        x = row_x + col * (BTN_W + BTN_GAP)
        y = BTN_ROW1_Y + row * (BTN_H + 4)
        rect = pygame.Rect(x, y, BTN_W, BTN_H)
        gs.action_buttons.append((rect, label, action))


def _draw_button_gradient(surface, rect, is_hover, is_selected, is_attack=False):
    """Draw a button with gradient fill, top highlight, and state-aware colors."""
    if is_selected:
        top_color, bot_color = (50, 120, 80), (40, 90, 60)
    elif is_hover:
        if is_attack:
            top_color, bot_color = BTN_ATTACK_GRADIENT_TOP, BTN_ATTACK_GRADIENT_BOT
        else:
            top_color, bot_color = BTN_GRADIENT_TOP, BTN_GRADIENT_BOT
    else:
        if is_attack:
            top_color, bot_color = (180, 60, 40), (140, 30, 20)
        else:
            # Subtle gradient for normal state too, adding depth
            top_color = (70, 90, 150)
            bot_color = (50, 65, 120)

    # Gradient fill
    for gy in range(rect.height):
        t = gy / rect.height
        r = int(top_color[0] + (bot_color[0] - top_color[0]) * t)
        g = int(top_color[1] + (bot_color[1] - top_color[1]) * t)
        b = int(top_color[2] + (bot_color[2] - top_color[2]) * t)
        pygame.draw.line(surface, (r, g, b),
                       (rect.x, rect.y + gy), (rect.x + rect.w, rect.y + gy))

    pygame.draw.rect(surface, UI_BORDER, rect, 1, border_radius=6)

    # Top highlight line
    hl_color = (min(255, top_color[0] + 60), min(255, top_color[1] + 60), min(255, top_color[2] + 60))
    pygame.draw.line(surface, hl_color, (rect.x + 4, rect.y + 1), (rect.x + rect.w - 4, rect.y + 1), 1)


def draw_action_buttons(gs, surface):
    for i, (rect, label, action) in enumerate(gs.action_buttons):
        is_hover = i == gs.hovered_button
        is_selected = (
            gs.selected_action is not None
            and gs.selected_action == action
        )
        is_attack = action == PlayerAction.DECLARE_ATTACK

        _draw_button_gradient(surface, rect, is_hover, is_selected, is_attack)

        txt = gs.font_action.render(label, True, UI_TEXT_PRIMARY)
        surface.blit(txt, txt.get_rect(center=rect.center))


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
        cost_x = mx + 10
        row1_y = item_y + 6
        for etype in attack.cost:
            ec = ENERGY_COLORS.get(etype, (200, 200, 200))
            pygame.draw.circle(surface, ec, (cost_x + 8, row1_y + 8), 8)
            if etype in ENERGY_CN:
                etxt = gs.font_card_tiny.render(ENERGY_CN[etype], True, (0, 0, 0))
                surface.blit(etxt, etxt.get_rect(center=(cost_x + 8, row1_y + 8)))
            cost_x += 20

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

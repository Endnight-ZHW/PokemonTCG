"""卡组选择画面 - 双方各选自己的卡组."""
import pygame
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_TEXT_PRIMARY,
    PLAYER1_COLOR, PLAYER2_COLOR, UI_HIGHLIGHT
)
from ui.font_manager import get_font, get_font_size
from ui.ui_theme import draw_panel, draw_button, draw_text_fit
from config import SCREEN_WIDTH, SCREEN_HEIGHT


# Deck definitions with metadata
DECK_OPTIONS = [
    {
        "name": "火系卡组 — 烈焰猴",
        "color": (220, 80, 60),
        "type_icon": "🔥",
        "strategy": "以小火焰猴快速进化烈焰猴，「螺旋业火」翻顶爆发、「燃烧踢」高伤收割。炎帝压迫感减伤，古玉鱼弃牌区充能续航。",
        "ace": "烈焰猴 — 螺旋业火 (翻顶5张，能量×80) / 燃烧踢 (160丢弃全能)",
        "support": "炎帝(压迫感减伤)、古玉鱼(闪焰生成充能)、加热洛托姆",
        "difficulty": "中等 — 需要规划进化时机与能量分配",
    },
    {
        "name": "水系卡组 — 甲贺忍蛙ex",
        "color": (60, 120, 220),
        "type_icon": "💧",
        "strategy": "甲贺忍蛙ex「隐蔽手里剑」狙击任意宝可梦，「激流斩」对受伤宝可梦追加伤害。宝石海星「神秘彗星」点伤自爆。",
        "ace": "甲贺忍蛙ex — 激流斩 (120+120追加)",
        "support": "宝石海星(点伤)、拉普拉斯(麻痹)、凯路迪欧、雪暴马",
        "difficulty": "中等 — 需要规划进化链与资源分配",
    },
    {
        "name": "超系卡组 — 天然鸟",
        "color": (160, 100, 220),
        "type_icon": "🔮",
        "strategy": "天然鸟「以太感知」手牌充能+过牌，多只强力基础超宝可梦灵活站场。月石循环过牌，代欧奇希斯能量转附，克雷色利亚加速充能。",
        "ace": "拉帝欧斯 — 洁净光芒 (180伤害) / 代欧奇希斯 — 基因螺旋 (120+能量全转)",
        "support": "天然鸟(充能过牌)、克雷色利亚(充能加速)、月石(抽滤)、拉帝亚斯(条件0撤)、咚咚鼠(能量检索+换位)",
        "difficulty": "中等 — 多核心灵活运作，需要管理能量分配",
    },
    {
        "name": "雷系卡组 — 皮卡丘ex",
        "color": (220, 220, 40),
        "type_icon": "⚡",
        "strategy": "皮卡丘ex「强劲伏特」高伤核心，茸茸羊「电气发电机」从弃牌区回收能量，电灯怪/捷拉奥拉/雷电云多核灵活站场。",
        "ace": "皮卡丘ex — 强劲伏特 (220伤害) / 皮卡拳 (30伤害)",
        "support": "电灯怪(炫目光束)、茸茸羊(弃牌区充能)、聒噪鸟(抽滤)、雷电云(手牌充能)",
        "difficulty": "中等 — 需要管理能量资源与弃牌区",
    },
    {
        "name": "斗系卡组 — 路卡利欧",
        "color": (180, 120, 60),
        "type_icon": "👊",
        "strategy": "路卡利欧「旺盛斗气」自我充能，「连续波导弹」弃斗能爆发。劈斧螳螂「大树切割」双硬币即死，代拉基翁「岩窟冲撞」攻防一体。",
        "ace": "路卡利欧 — 连续波导弹 (10+弃斗能×60) / 劈斧螳螂 — 大树切割 (双硬币KO)",
        "support": "代拉基翁(免疫+高伤)、投掷猴(转附)、大葱鸭(抽滤)、摔跤鹰人(弃牌充能)",
        "difficulty": "中等 — 需要管理弃牌区能量与进化节奏",
    },
    {
        "name": "无色卡组 — 一家鼠ex",
        "color": (180, 180, 180),
        "type_icon": "⚪",
        "strategy": "一家鼠ex「团结一致」反伤防守，「贪婪门牙」抽滤。双尾怪手/爱管侍手牌增伤，特殊能量提供灵活战术。",
        "ace": "一家鼠ex — 贪婪门牙 (120伤害+抽2) / 团结一致 (反伤)",
        "support": "双尾怪手(手牌×20)、藏饱栗鼠(倾倒一空150追加)、特殊能量体系",
        "difficulty": "困难 — 需要管理手牌资源与特殊能量配合",
    },
    {
        "name": "龙系卡组 — 七夕青鸟ex",
        "color": (80, 160, 200),
        "type_icon": "🐉",
        "strategy": "七夕青鸟ex「哼唱治愈」群体回复，「光之波动」高伤+免疫效果。老翁龙「逆鳞」自伤增伤，浩大鲸「扫除冲撞」高威力终结。",
        "ace": "七夕青鸟ex — 光之波动 (140伤害+免疫) / 哼唱治愈 (全场回20HP)",
        "support": "大奶罐(回复增伤)、米立龙(万能检索)、飘浮泡泡(抽滤转能)、浩大鲸(终结)",
        "difficulty": "中等 — 需要管理双属性能量与回复时机",
    },
    {
        "name": "草系卡组 — 土台龟",
        "color": (80, 180, 80),
        "type_icon": "🌿",
        "strategy": "土台龟「进化压制」进化宝可梦增伤。树林龟「日光甲壳」检索G宝可梦。萨戮德「唤群之歌」快速铺场，帝王拿波「紧急上浮」弃牌区复活。",
        "ace": "土台龟 — 进化压制 (50×进化宝可梦数) / 头突 (160)",
        "support": "萨戮德(检索铺场)、帝王拿波(弃牌复活+狙击)、菜种的活力(充能加速)、学习装置(能量回收)",
        "difficulty": "中等 — 需要规划进化链与能量管理",
    },
]


class DeckSelectScreen(Screen):
    """卡组选择——双方各选择自己的卡组后开始对战."""

    def __init__(self, manager: ScreenManager, available_decks: dict[str, list[tuple]],
                 is_remote: bool = False, network_manager=None,
                 my_player_idx: int = 0, mode: str = "local"):
        super().__init__(manager)
        self.available_decks = available_decks  # {deck_key: deck_spec}
        self.deck_keys = list(available_decks.keys())
        self.font_title = get_font("title_sm")
        self.font_body = get_font("body_md")
        self.font_small = get_font("smaller")

        self.p1_idx = 0
        self.p2_idx = 1

        self.mode = mode
        self.is_challenge = mode == "challenge"

        # Remote mode fields
        self.is_remote = is_remote
        self.network_manager = network_manager
        self._my_player_idx = my_player_idx
        self._opponent_deck_idx: int | None = None
        self._opponent_deck_key: str | None = None
        self._remote_deck_sent: bool = False
        self._remote_game_started: bool = False
        self._remote_status: str = ""

        # Start button
        btn_w, btn_h = 280, 55
        btn_x = (SCREEN_WIDTH - btn_w) // 2
        btn_y = SCREEN_HEIGHT - 80
        self.start_button = pygame.Rect(btn_x, btn_y, btn_w, btn_h)
        self.start_hover = False

        # Deck selection buttons for each player
        self.p1_buttons = []
        self.p2_buttons = []

    def handle_event(self, event: pygame.event.Event):
        if event.type == pygame.MOUSEMOTION:
            self.start_hover = self.start_button.collidepoint(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self.start_hover:
                self._start_battle()
                return

            # Check player 1 deck selection
            for i, btn in enumerate(self.p1_buttons):
                if btn.collidepoint(event.pos):
                    self.p1_idx = i
                    return

            # Check player 2 deck selection
            for i, btn in enumerate(self.p2_buttons):
                if btn.collidepoint(event.pos):
                    self.p2_idx = i
                    return

    def _start_battle(self):
        from engine.game_state import GameState
        from engine.turn_manager import TurnManager
        from ui.screens.game_screen import GameScreen
        from data.deck_definitions import expand_deck

        if self.is_remote:
            self._start_remote_battle()
            return

        deck_key1 = self.deck_keys[self.p1_idx]
        deck_key2 = self.deck_keys[self.p2_idx]
        p1_deck = expand_deck(self.available_decks[deck_key1])
        p2_deck = expand_deck(self.available_decks[deck_key2])

        game_state = GameState()
        app = getattr(self.manager, "_app", None)
        game_state.apply_type_matchups = (
            False if self.is_challenge else bool(getattr(app, "apply_type_matchups", False))
        )
        game_state.setup_game(p1_deck, p2_deck)
        turn_manager = TurnManager(game_state)
        game_screen = GameScreen(
            self.manager,
            game_state,
            turn_manager,
            challenge_mode=self.is_challenge,
            human_player_idx=0,
            ai_player_idx=1,
        )
        self.manager.replace_top(game_screen)

    def _start_remote_battle(self):
        """Start or coordinate remote battle based on role."""
        from engine.game_state import GameState
        from engine.turn_manager import TurnManager
        from ui.screens.game_screen import GameScreen
        from data.deck_definitions import expand_deck
        from network.state_serializer import serialize_game_state

        my_key = self.deck_keys[self.p1_idx]  # Remote uses single selection
        my_deck_ids = expand_deck(self.available_decks[my_key])

        if self._my_player_idx == 0:
            # Host: wait for client deck, then create game
            opp_key = self._opponent_deck_key
            if not opp_key:
                self._remote_status = "等待对手选择卡组..."
                return
            opp_deck_ids = expand_deck(self.available_decks[opp_key])

            game_state = GameState()
            app = getattr(self.manager, "_app", None)
            game_state.apply_type_matchups = bool(getattr(app, "apply_type_matchups", False))
            game_state.setup_game(my_deck_ids, opp_deck_ids)
            turn_manager = TurnManager(game_state)

            # Send game starting with opponent deck info
            self.network_manager.send({
                "type": "game_starting",
                "opponent_deck_key": my_key,
            })

            # Send initial state from CLIENT's perspective (player 1)
            state_data = serialize_game_state(game_state, for_player_idx=1)
            self.network_manager.send({
                "type": "state_update",
                "state": state_data,
            })

            game_screen = GameScreen(
                self.manager, game_state, turn_manager,
                network_manager=self.network_manager,
                my_player_idx=0,
            )
            self.manager.replace_top(game_screen)
        else:
            # Client: send deck selection to host
            if not self._remote_deck_sent:
                self.network_manager.send({
                    "type": "deck_selected",
                    "deck_key": my_key,
                })
                self._remote_deck_sent = True
                self._remote_status = "已选择卡组，等待对手确认..."

    def update(self, dt: float):
        if not self.is_remote or not self.network_manager:
            return

        for msg in self.network_manager.poll():
            msg_type = msg.get("type", "")

            if msg_type == "deck_selected":
                # Host receives client's deck selection
                self._opponent_deck_key = msg["deck_key"]
                # Find the index for this deck key
                for i, key in enumerate(self.deck_keys):
                    if key == self._opponent_deck_key:
                        self._opponent_deck_idx = i
                        break
                self._remote_status = f"对手已选择卡组！点击「开始对战」开始游戏。"

            elif msg_type == "game_starting":
                # Client receives game start signal
                self._opponent_deck_key = msg.get("opponent_deck_key", "")
                for i, key in enumerate(self.deck_keys):
                    if key == self._opponent_deck_key:
                        self._opponent_deck_idx = i
                        break
                self._remote_game_started = True
                self._remote_status = "对手已确认，准备进入对战..."

            elif msg_type == "state_update":
                # Client receives initial game state
                if not self._remote_game_started:
                    continue
                from network.state_serializer import deserialize_game_state
                from ui.screens.game_screen import GameScreen

                client_state = deserialize_game_state(
                    msg["state"], for_player_idx=self._my_player_idx
                )
                game_screen = GameScreen(
                    self.manager, None, None,
                    network_manager=self.network_manager,
                    my_player_idx=self._my_player_idx,
                    initial_state=client_state,
                )
                self.manager.replace_top(game_screen)

            elif msg_type in ("opponent_disconnected", "connection_failed"):
                self._remote_status = "连接断开，请返回标题画面。"
                self.is_remote = False

    def draw(self, surface: pygame.Surface):
        surface.fill((13, 16, 27))

        if self.is_remote:
            self._draw_remote(surface)
            return

        if self.is_challenge:
            title_txt = self.font_title.render("挑战模式：选择卡组", True, UI_TEXT_PRIMARY)
            title_rect = title_txt.get_rect(center=(SCREEN_WIDTH // 2, 30))
            surface.blit(title_txt, title_rect)

            self._draw_player_selection(surface, "玩家", self.p1_idx, self.p1_buttons,
                                        86, PLAYER1_COLOR, "left")
            self._draw_player_selection(surface, "AI", self.p2_idx, self.p2_buttons,
                                        86, PLAYER2_COLOR, "right")

            vs_txt = self.font_title.render("VS", True, UI_TEXT_PRIMARY)
            vs_rect = vs_txt.get_rect(center=(SCREEN_WIDTH // 2, 76))
            surface.blit(vs_txt, vs_rect)

            self._draw_challenge_deck_detail(surface)
            draw_button(surface, self.start_button, "开始挑战", self.font_body,
                        hovered=self.start_hover, attack=True)
            return

        title_txt = self.font_title.render("选择你的卡组", True, UI_TEXT_PRIMARY)
        title_rect = title_txt.get_rect(center=(SCREEN_WIDTH // 2, 30))
        surface.blit(title_txt, title_rect)

        # Player deck lists flank a compact comparison panel.
        self._draw_player_selection(surface, "玩家 1", self.p1_idx, self.p1_buttons,
                                    86, PLAYER1_COLOR, "left")
        self._draw_player_selection(surface, "玩家 2", self.p2_idx, self.p2_buttons,
                                    86, PLAYER2_COLOR, "right")

        # VS divider
        vs_txt = self.font_title.render("VS", True, UI_TEXT_PRIMARY)
        vs_rect = vs_txt.get_rect(center=(SCREEN_WIDTH // 2, 76))
        surface.blit(vs_txt, vs_rect)

        self._draw_deck_detail(surface)

        draw_button(surface, self.start_button, "开始对战", self.font_body,
                    hovered=self.start_hover, attack=True)

    def _draw_remote(self, surface):
        """Draw remote mode deck selection (single player)."""
        my_color = PLAYER1_COLOR if self._my_player_idx == 0 else PLAYER2_COLOR
        label = f"玩家{self._my_player_idx + 1}" if self._my_player_idx == 0 else "你"

        title_txt = self.font_title.render("选择你的卡组", True, UI_HIGHLIGHT)
        title_rect = title_txt.get_rect(center=(SCREEN_WIDTH // 2, 30))
        surface.blit(title_txt, title_rect)

        # Show role
        role_txt = self.font_body.render(
            f"{label} - {'房主' if self._my_player_idx == 0 else '挑战者'}",
            True, my_color
        )
        surface.blit(role_txt, role_txt.get_rect(center=(SCREEN_WIDTH // 2, 70)))

        # Single selection (centered)
        self._draw_player_selection(surface, "你的卡组", self.p1_idx, self.p1_buttons,
                                     100, my_color, "center")

        # Show opponent selection if known
        if self._opponent_deck_idx is not None:
            opp_color = PLAYER2_COLOR if self._my_player_idx == 0 else PLAYER1_COLOR
            opp_deck = DECK_OPTIONS[self._opponent_deck_idx]
            opp_txt = self.font_body.render(
                f"对手卡组: {opp_deck['name']}",
                True, opp_color
            )
            opp_rect = opp_txt.get_rect(center=(SCREEN_WIDTH // 2, 500))
            surface.blit(opp_txt, opp_rect)

        # Status text
        if self._remote_status:
            status_txt = self.font_body.render(self._remote_status, True, UI_HIGHLIGHT)
            status_rect = status_txt.get_rect(center=(SCREEN_WIDTH // 2, 540))
            surface.blit(status_txt, status_rect)

        # Start button (only for host after client deck received, or client before sending)
        can_start = (
            self._my_player_idx == 0 or  # Host can always click (triggers wait / start)
            (self._my_player_idx == 1 and not self._remote_deck_sent)
        )
        if can_start:
            draw_button(surface, self.start_button, "开始对战", self.font_body,
                        hovered=self.start_hover, attack=True)

    def _draw_player_selection(self, surface, label, selected_idx, buttons_list,
                                 y_start, player_color, side):
        label_txt = self.font_body.render(label, True, player_color)

        if side == "left":
            start_x = 54
            panel_w = 500
            label_x = start_x
        elif side == "right":
            panel_w = 500
            start_x = SCREEN_WIDTH - panel_w - 54
            label_x = start_x + panel_w - label_txt.get_width()
        else:  # center
            panel_w = min(600, SCREEN_WIDTH - 200)
            start_x = (SCREEN_WIDTH - panel_w) // 2
            label_x = start_x

        num_decks = len(DECK_OPTIONS)
        btn_h = 36 if num_decks <= 8 else 32
        gap = 6 if num_decks <= 8 else 4
        panel_h = 54 + num_decks * (btn_h + gap)
        panel_rect = pygame.Rect(start_x - 14, y_start - 14, panel_w + 28, panel_h)
        draw_panel(surface, panel_rect)
        surface.blit(label_txt, (label_x, y_start))

        buttons_list.clear()
        btn_w = panel_w
        for i, deck in enumerate(DECK_OPTIONS):
            btn_x = start_x
            btn_y = y_start + 36 + i * (btn_h + gap)
            btn_rect = pygame.Rect(btn_x, btn_y, btn_w, btn_h)
            buttons_list.append(btn_rect)

            is_selected = (i == selected_idx)
            bg = deck["color"] if is_selected else (40, 40, 50)
            border = player_color if is_selected else (80, 80, 90)
            border_w = 3 if is_selected else 1

            pygame.draw.rect(surface, bg, btn_rect, border_radius=6)
            pygame.draw.rect(surface, border, btn_rect, border_w, border_radius=6)

            swatch = pygame.Rect(btn_x + 10, btn_y + btn_h // 2 - 6, 12, 12)
            pygame.draw.rect(surface, deck["color"], swatch, border_radius=3)
            pygame.draw.rect(surface, (230, 230, 240), swatch, 1, border_radius=3)

            deck_label = deck["name"]
            draw_text_fit(surface, self.font_small, deck_label, UI_TEXT_PRIMARY,
                          pygame.Rect(btn_x + 30, btn_y, btn_w - 40, btn_h))

        # Return the bottom y of the last button
        return y_start + 36 + num_decks * (btn_h + gap)

    def _draw_challenge_deck_detail(self, surface):
        """Draw challenge-mode deck comparison with player/AI labels."""
        panel = pygame.Rect(SCREEN_WIDTH // 2 - 220, 112, 440, 708)
        inner = draw_panel(surface, panel, "卡组比较", self.font_body)

        blocks = [
            (self.p1_idx, PLAYER1_COLOR, "玩家"),
            (self.p2_idx, PLAYER2_COLOR, "AI"),
        ]
        y = inner.y + 4
        for idx, color, label in blocks:
            deck = DECK_OPTIONS[idx]
            header_rect = pygame.Rect(inner.x, y, inner.w, 28)
            pygame.draw.rect(surface, (28, 34, 52), header_rect, border_radius=6)
            pygame.draw.rect(surface, color, header_rect, 1, border_radius=6)
            swatch = pygame.Rect(header_rect.x + 8, header_rect.y + 8, 12, 12)
            pygame.draw.rect(surface, deck["color"], swatch, border_radius=3)
            pygame.draw.rect(surface, (230, 230, 240), swatch, 1, border_radius=3)
            draw_text_fit(surface, self.font_small,
                          f"{label}: {deck['name']}",
                          UI_TEXT_PRIMARY,
                          pygame.Rect(header_rect.x + 28, header_rect.y,
                                      header_rect.w - 36, header_rect.h))
            y += 38

            strategy_lines = self._wrap_text(deck["strategy"], self.font_small, inner.w - 12)
            for line in strategy_lines[:3]:
                draw_text_fit(surface, self.font_small, line, (180, 184, 198),
                              pygame.Rect(inner.x + 6, y, inner.w - 12, 18))
                y += 19
            y += 4

            draw_text_fit(surface, self.font_small, f"核心: {deck['ace']}",
                          UI_HIGHLIGHT, pygame.Rect(inner.x + 6, y, inner.w - 12, 20))
            y += 24
            draw_text_fit(surface, self.font_small, f"支援: {deck['support']}",
                          (170, 176, 192), pygame.Rect(inner.x + 6, y, inner.w - 12, 20))
            y += 24
            draw_text_fit(surface, self.font_small, f"难度: {deck['difficulty']}",
                          (150, 158, 176), pygame.Rect(inner.x + 6, y, inner.w - 12, 20))
            y += 44

    def _draw_deck_detail(self, surface):
        """Draw compact side-by-side deck comparison in the center column."""
        panel = pygame.Rect(SCREEN_WIDTH // 2 - 220, 112, 440, 708)
        inner = draw_panel(surface, panel, "卡组比较", self.font_body)

        blocks = [
            (self.p1_idx, PLAYER1_COLOR, "玩家1"),
            (self.p2_idx, PLAYER2_COLOR, "玩家2"),
        ]
        y = inner.y + 4
        for idx, color, label in blocks:
            deck = DECK_OPTIONS[idx]
            header_rect = pygame.Rect(inner.x, y, inner.w, 28)
            pygame.draw.rect(surface, (28, 34, 52), header_rect, border_radius=6)
            pygame.draw.rect(surface, color, header_rect, 1, border_radius=6)
            swatch = pygame.Rect(header_rect.x + 8, header_rect.y + 8, 12, 12)
            pygame.draw.rect(surface, deck["color"], swatch, border_radius=3)
            pygame.draw.rect(surface, (230, 230, 240), swatch, 1, border_radius=3)
            draw_text_fit(surface, self.font_small,
                          f"{label}: {deck['name']}",
                          UI_TEXT_PRIMARY,
                          pygame.Rect(header_rect.x + 28, header_rect.y,
                                      header_rect.w - 36, header_rect.h))
            y += 38

            strategy_lines = self._wrap_text(deck["strategy"], self.font_small, inner.w - 12)
            for line in strategy_lines[:3]:
                draw_text_fit(surface, self.font_small, line, (180, 184, 198),
                              pygame.Rect(inner.x + 6, y, inner.w - 12, 18))
                y += 19
            y += 4

            draw_text_fit(surface, self.font_small, f"核心: {deck['ace']}",
                          UI_HIGHLIGHT, pygame.Rect(inner.x + 6, y, inner.w - 12, 20))
            y += 24
            draw_text_fit(surface, self.font_small, f"支援: {deck['support']}",
                          (170, 176, 192), pygame.Rect(inner.x + 6, y, inner.w - 12, 20))
            y += 24
            draw_text_fit(surface, self.font_small, f"难度: {deck['difficulty']}",
                          (150, 158, 176), pygame.Rect(inner.x + 6, y, inner.w - 12, 20))
            y += 44

    def _wrap_text(self, text, font, max_width):
        """Simple text wrapping for Chinese text."""
        words = list(text)
        lines = []
        current = ""
        for ch in words:
            test = current + ch
            if font.size(test)[0] <= max_width:
                current = test
            else:
                lines.append(current)
                current = ch
        if current:
            lines.append(current)
        return lines[:3]  # max 3 lines

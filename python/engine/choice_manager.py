"""Choice request construction and legacy choice payload adaptation."""
from __future__ import annotations

from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    ChoiceRequest,
    ChoiceResponse,
    PokemonRef,
)
from engine.game_state import ActionRequest, GameState
from engine.random_source import RandomSource


class VMChoiceManager:
    """Builds serializable choice requests and bridges legacy callbacks."""

    def choice_request(self, state: GameState, request: ActionRequest) -> ChoiceRequest:
        if request.request_id:
            request_id = request.request_id
        else:
            sequence = int(getattr(state, "choice_sequence", 0))
            state.choice_sequence = sequence + 1
            request_id = (
                f"choice:{getattr(state, 'revision', 0)}:{request.player}:"
                f"{request.request_type}:{sequence}"
            )
        request.request_id = request_id
        options = tuple(self._choice_options(state, request))
        min_select = max(0, int(request.min_select))
        max_select = max(0, int(request.max_select))
        allow_duplicates = bool(request.allow_duplicates)
        if request.request_type == "coin_flip":
            if request.until_tails:
                min_select, max_select = 1, 32
            else:
                min_select = max_select = max(1, int(request.flip_count or 1))
            allow_duplicates = True
        elif request.request_type == "distribute_energy":
            if request.distribute_mode == "source_select":
                min_select = max_select = 1
            else:
                amount = max(0, len(request.card_list))
                if amount > 1 and request.min_select == 1 and request.max_select == 1:
                    # Backward compatibility for older handlers that meant
                    # "assign every listed energy" but did not set bounds.
                    min_select = max_select = amount
                else:
                    max_select = min(amount, max_select if max_select > 0 else amount)
                    min_select = min(max_select, min_select)
                allow_duplicates = True
        can_cancel = min_select <= 0 or bool(getattr(request, "can_cancel", False))
        continuation = dict(getattr(request, "continuation", {}) or {})
        metadata = {
            "from_zone": request.from_zone,
            "target_player": request.target_player,
            "distribute_mode": request.distribute_mode,
            "max_per_target": request.max_per_target,
            "flip_count": request.flip_count,
            "until_tails": request.until_tails,
            "revision": getattr(state, "revision", 0),
            "continuation": continuation,
        }
        top_card_id = str(
            continuation.get("top_card_id", continuation.get("card_id", "")) or ""
        )
        if request.request_type == "confirm" and top_card_id:
            metadata["top_card_id"] = top_card_id
            metadata["revealed_card_ids"] = [top_card_id]
        return ChoiceRequest(
            request_id=request_id,
            request_type=request.request_type,
            player=request.player,
            prompt=request.prompt,
            options=options,
            min_select=min_select,
            max_select=max_select,
            allow_duplicates=allow_duplicates,
            can_cancel=can_cancel,
            metadata=metadata,
            legacy_request=request,
        )

    def choice_response_from_legacy(
        self,
        request: ChoiceRequest,
        payload,
        *,
        cancelled: bool = False,
    ) -> ChoiceResponse:
        """Map transitional UI payloads to stable option IDs."""
        if cancelled:
            return ChoiceResponse(request.request_id, (), True)
        if request.request_type == "coin_flip":
            return ChoiceResponse(
                request.request_id,
                tuple("coin:heads" if value else "coin:tails" for value in payload or []),
            )
        if request.request_type == "confirm":
            return ChoiceResponse(
                request.request_id,
                ("confirm:yes" if payload else "confirm:no",),
            )
        if request.request_type == "evolve_skip_stage":
            selected_payload = (
                payload[0]
                if isinstance(payload, (list, tuple)) and payload
                else payload
            )
            if isinstance(selected_payload, dict):
                match = next(
                    (
                        option for option in request.options
                        if isinstance(option.value, dict)
                        and int(option.value.get("hand_index", -1))
                        == int(selected_payload.get("hand_index", -2))
                        and str(option.value.get("slot", ""))
                        == str(selected_payload.get("slot", ""))
                        and str(option.value.get("card_id", ""))
                        == str(selected_payload.get("card_id", ""))
                    ),
                    None,
                )
                return ChoiceResponse(
                    request.request_id,
                    (match.option_id,) if match is not None else (),
                )
        if request.request_type in {
            "select_bench",
            "select_opponent_bench",
            "select_own_bench_energy",
        }:
            option = next(
                (option for option in request.options if option.value == payload),
                None,
            )
            return ChoiceResponse(
                request.request_id,
                (option.option_id,) if option is not None else (),
            )
        if request.request_type == "select_bench_targets":
            option_ids = []
            for target in payload or []:
                match = next(
                    (option for option in request.options if option.value == target),
                    None,
                )
                if match is not None:
                    option_ids.append(match.option_id)
            return ChoiceResponse(request.request_id, tuple(option_ids))
        if request.request_type == "distribute_energy":
            option_ids = []
            for _energy_idx, slot in payload or []:
                match = next(
                    (
                        option for option in request.options
                        if isinstance(option.value, dict)
                        and str(option.value.get("slot", "")) == str(slot)
                    ),
                    None,
                )
                if match is not None:
                    option_ids.append(match.option_id)
            return ChoiceResponse(request.request_id, tuple(option_ids))
        if request.request_type == "select_attachment":
            option_ids = []
            for selected in payload or []:
                selected_id = getattr(selected, "ref_id", str(selected))
                match = next(
                    (
                        option for option in request.options
                        if option.option_id == selected_id
                        or getattr(option.ref, "ref_id", "") == selected_id
                    ),
                    None,
                )
                if match is not None:
                    option_ids.append(match.option_id)
            return ChoiceResponse(request.request_id, tuple(option_ids))

        unused = list(request.options)
        option_ids = []
        for selected in payload or []:
            match = next(
                (
                    option for option in unused
                    if option.value is selected
                    or getattr(option.value, "api_id", None)
                    == getattr(selected, "api_id", None)
                ),
                None,
            )
            if match is not None:
                option_ids.append(match.option_id)
                unused.remove(match)
        return ChoiceResponse(request.request_id, tuple(option_ids))

    def default_choice_response(
        self,
        request: ChoiceRequest,
        rng: RandomSource,
    ) -> ChoiceResponse:
        if request.request_type == "coin_flip":
            flip_count = int(request.metadata.get("flip_count", 1) or 1)
            until_tails = bool(request.metadata.get("until_tails", False))
            results: list[str] = []
            if until_tails:
                for _ in range(32):
                    option_id = "coin:heads" if rng.coin() else "coin:tails"
                    results.append(option_id)
                    if option_id.endswith("tails"):
                        break
            else:
                results = [
                    "coin:heads" if rng.coin() else "coin:tails"
                    for _ in range(max(1, flip_count))
                ]
            return ChoiceResponse(request.request_id, tuple(results))
        if request.request_type == "distribute_energy" and request.allow_duplicates and request.options:
            count = max(request.min_select, request.max_select)
            max_per_target = int(request.metadata.get("max_per_target", 99) or 99)
            selected: list[str] = []
            if max_per_target == 1:
                selected = [option.option_id for option in request.options[:count]]
            else:
                selected = [request.options[0].option_id for _ in range(count)]
            return ChoiceResponse(request.request_id, tuple(selected))
        count = min(len(request.options), max(request.min_select, min(request.max_select, len(request.options))))
        return ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:count]))

    @staticmethod
    def legacy_choice_payload(
        request: ActionRequest,
        selected: list[ChoiceOption],
        response: ChoiceResponse,
    ):
        if request.request_type == "coin_flip":
            return [option_id == "coin:heads" for option_id in response.option_ids]
        if request.request_type == "confirm":
            return bool(selected and selected[0].value)
        if request.request_type == "evolve_skip_stage":
            return selected[0].value if selected else None
        if request.request_type in {"select_bench", "select_opponent_bench", "select_own_bench_energy"}:
            return int(selected[0].value) if selected else None
        if request.request_type == "select_bench_targets":
            return [int(option.value) for option in selected]
        if request.request_type == "distribute_energy":
            if request.distribute_mode == "source_select":
                return [(0, str(selected[0].value.get("slot", "")))] if selected else []
            return [
                (energy_idx, str(option.value.get("slot", "")))
                for energy_idx, option in enumerate(selected)
            ]
        if request.request_type == "select_attachment":
            return [option.ref for option in selected if isinstance(option.ref, AttachmentRef)]
        pokemon_refs = [option.ref for option in selected if isinstance(option.ref, PokemonRef)]
        if pokemon_refs:
            return pokemon_refs
        return [option.value for option in selected]

    @staticmethod
    def consume_pending_card(state: GameState, request: ActionRequest) -> None:
        card = request.pending_card
        if card is None:
            return
        player_idx = request.player if request.player in (0, 1) else state.active_player_idx
        player = state.get_player(player_idx)
        if all(existing is not card for existing in player.discard) and card not in player.hand:
            if card.is_trainer_supporter or card.is_trainer_item:
                player.discard.append(card)
        request.pending_card = None

    @staticmethod
    def cancel_pending_card(state: GameState, request: ActionRequest | None) -> None:
        if request is None or request.pending_card is None:
            return
        card = request.pending_card
        player_idx = request.player if request.player in (0, 1) else state.active_player_idx
        player = state.get_player(player_idx)
        if all(existing is not card for existing in player.hand):
            player.hand.append(card)
        if getattr(card, "is_trainer_supporter", False):
            player.supporter_played_this_turn = False
        request.pending_card = None

    def _choice_options(self, state: GameState, request: ActionRequest) -> list[ChoiceOption]:
        if request.request_type == "coin_flip":
            return [
                ChoiceOption("coin:heads", "正面", value=True),
                ChoiceOption("coin:tails", "反面", value=False),
            ]
        if request.request_type in {"select_bench", "select_opponent_bench", "select_own_bench_energy"}:
            target_idx = self._choice_target_player_idx(state, request)
            player = state.get_player(target_idx)
            allowed = request.bench_indices or list(range(len(player.bench)))
            return [
                ChoiceOption(
                    PokemonRef(target_idx, f"bench_{idx}", pokemon.card.api_id).ref_id,
                    pokemon.card.name,
                    PokemonRef(target_idx, f"bench_{idx}", pokemon.card.api_id),
                    idx,
                )
                for idx in allowed
                if 0 <= idx < len(player.bench) and (pokemon := player.bench[idx]) is not None
            ]
        if request.request_type == "select_bench_targets":
            target_idx = self._choice_target_player_idx(state, request)
            player = state.get_player(target_idx)
            allowed = request.bench_indices or list(range(len(player.bench)))
            return [
                ChoiceOption(
                    PokemonRef(target_idx, f"bench_{idx}", pokemon.card.api_id).ref_id,
                    pokemon.card.name,
                    PokemonRef(target_idx, f"bench_{idx}", pokemon.card.api_id),
                    idx,
                )
                for idx in allowed
                if 0 <= idx < len(player.bench) and (pokemon := player.bench[idx]) is not None
            ]
        if request.request_type == "confirm":
            return [
                ChoiceOption("confirm:yes", "是", value=True),
                ChoiceOption("confirm:no", "否", value=False),
            ]
        if request.request_type == "evolve_skip_stage":
            options = []
            for target in request.target_info or []:
                if not isinstance(target, dict):
                    continue
                hand_index = int(target.get("hand_index", -1))
                card_id = str(target.get("card_id", ""))
                ref = CardRef(request.player, "hand", hand_index, card_id)
                option_id = (
                    f'rare_candy:{target.get("slot", "")}:{hand_index}:{card_id}'
                )
                label = str(
                    target.get("name")
                    or f'{target.get("base_name", "")} → {target.get("evolution_name", "")}'
                )
                options.append(ChoiceOption(option_id, label, ref, target))
            return options
        if request.request_type == "distribute_energy":
            options = []
            for target in request.target_info or []:
                slot = str(target.get("slot", ""))
                player_idx = int(target.get("player", request.player if request.player in (0, 1) else state.active_player_idx))
                pokemon = state.get_player(player_idx).get_pokemon(slot)
                ref = PokemonRef(player_idx, slot, pokemon.card.api_id if pokemon else "")
                options.append(ChoiceOption(ref.ref_id, target.get("name", slot), ref, target))
            return options
        if request.request_type == "select_attachment":
            options = []
            for target in request.target_info or []:
                player_idx = int(target.get("player", request.player))
                slot = str(target.get("slot", ""))
                attachment_type = str(target.get("attachment_type", "energy"))
                index = int(target.get("index", 0))
                card_id = str(target.get("card_id", ""))
                ref = AttachmentRef(player_idx, slot, attachment_type, index, card_id)
                label = str(target.get("label") or target.get("name") or card_id)
                options.append(ChoiceOption(ref.ref_id, label, ref, target))
            return options

        refs = self._card_list_refs(state, request)
        return [
            ChoiceOption(ref.ref_id, getattr(card, "name", str(card)), ref, card)
            for ref, card in refs
        ]

    def _card_list_refs(self, state: GameState, request: ActionRequest):
        if request.from_zone in {"board", "bench"}:
            return self._board_card_refs(state, request)
        player_idx = request.player if request.player in (0, 1) else state.active_player_idx
        zone = request.from_zone or "choices"
        return [
            (CardRef(player_idx, zone, idx, getattr(card, "api_id", "")), card)
            for idx, card in enumerate(request.card_list)
        ]

    def _board_card_refs(self, state: GameState, request: ActionRequest):
        candidate_ids = [getattr(card, "api_id", "") for card in request.card_list]
        refs = []
        player_order = [self._choice_target_player_idx(state, request)]
        if request.target_player == "" and request.from_zone == "board":
            player_order = [1 - request.player, request.player] if request.player in (0, 1) else [0, 1]
        remaining = list(candidate_ids)
        for player_idx in player_order:
            for slot, pokemon in state.get_player(player_idx).get_all_pokemon():
                if pokemon is None or pokemon.card.api_id not in remaining:
                    continue
                remaining.remove(pokemon.card.api_id)
                refs.append((PokemonRef(player_idx, slot, pokemon.card.api_id), pokemon.card))
        while len(refs) < len(request.card_list):
            idx = len(refs)
            card = request.card_list[idx]
            refs.append((CardRef(request.player, request.from_zone or "choices", idx, card.api_id), card))
        return refs

    @staticmethod
    def _choice_target_player_idx(state: GameState, request: ActionRequest) -> int:
        owner = request.player if request.player in (0, 1) else state.active_player_idx
        if request.target_player == "opponent" or request.request_type == "select_opponent_bench":
            return 1 - owner
        return owner

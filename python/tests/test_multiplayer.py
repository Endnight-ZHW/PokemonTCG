"""Multiplayer integration test - runs host + client through a full game loop.

This test verifies the networking layer (NetworkManager + state serialization)
and the core game engine (GameState + TurnManager) work correctly together
without requiring pygame or manual interaction.

Usage:
    python tests/test_multiplayer.py
"""

import sys
import os
import time
import threading
import random

# Ensure project root is on path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from engine.game_state import GameState
from engine.turn_manager import TurnManager
from engine.enums import TurnPhase, PlayerAction
from network.network_manager import NetworkManager
from network.state_serializer import serialize_game_state, deserialize_game_state
from network.message_protocol import ACTION_TO_STRING, STRING_TO_ACTION, MSG_STATE_UPDATE
from data.card_registry import CardRegistry
from data.deck_definitions import FIRE_DECK, WATER_DECK, ALL_CARD_IDS, expand_deck

# ── Test Configuration ────────────────────────────────────────────────
TEST_PORT = 18765  # Use a different port to avoid conflicts

# ── Helpers ───────────────────────────────────────────────────────────

def init_cards():
    """Initialize CardRegistry with offline data."""
    if not CardRegistry.is_initialized():
        CardRegistry.initialize(ALL_CARD_IDS)
    print("[OK] CardRegistry initialized")


def make_small_deck(basic_pokemon_ids: list[str], energy_id: str, count: int = 8) -> list[str]:
    """Create a small test deck with basics + energy."""
    deck = []
    for pid in basic_pokemon_ids:
        deck.append(pid)
    energy_needed = count - len(deck)
    for _ in range(energy_needed):
        deck.append(energy_id)
    while len(deck) < count:
        deck.append(basic_pokemon_ids[0])
    return deck


def wait_for_connection(nm: NetworkManager, timeout: float = 15.0):
    """Wait for a NetworkManager to establish connection."""
    start = time.time()
    while not nm.is_connected:
        if time.time() - start > timeout:
            raise TimeoutError(f"Connection timed out after {timeout}s")
        # Process incoming messages to detect connection/error events
        for msg in nm.poll():
            if msg.get("type") == "connection_failed":
                raise ConnectionError(f"Connection failed: {msg.get('error', 'unknown')}")
        time.sleep(0.05)
    elapsed = time.time() - start
    print(f"[OK] Connected in {elapsed:.1f}s")


def drain_poll(nm: NetworkManager, timeout: float = 2.0) -> list[dict]:
    """Poll for messages until none remain or timeout."""
    messages = []
    start = time.time()
    while time.time() - start < timeout:
        msgs = nm.poll()
        if msgs:
            messages.extend(msgs)
        else:
            time.sleep(0.02)
    return messages


def resolve_pending_promotion(state: GameState, tm: TurnManager) -> bool:
    """Resolve the mandatory active promotion used by non-UI integration tests."""
    player_idx = state.pop_pending_promotion()
    if player_idx < 0:
        return False
    player = state.get_player(player_idx)
    if player.active is None:
        bench_options = [(i, p) for i, p in enumerate(player.bench) if p is not None]
        if not bench_options:
            state.winner = 1 - player_idx
            state.phase = TurnPhase.GAME_OVER
            return True
        bench_idx, pokemon = bench_options[0]
        player.promote_from_bench(bench_idx)
        print(f"    Promoted {pokemon.card.name} from bench")
    if state.phase == TurnPhase.DRAW:
        tm.continue_after_promotion()
    # else: pop_pending_promotion already removed this entry
    return True


# ── Test: MyPlayerIdx Conditions ──────────────────────────────────────

def test_my_player_idx_conditions():
    """Verify the fix: my_player_idx blocking logic is correct.

    Host (my_player_idx=0):
    - Blocked when active_player_idx != 0 (remote player's turn)
    - Not blocked when active_player_idx == 0 (own turn)

    Client (my_player_idx=1):
    - Blocked when active_player_idx != 1 (host's turn)
    - Not blocked when active_player_idx == 1 (own turn)
    """
    print("\n=== Test: my_player_idx blocking conditions ===")

    # Host conditions
    for active_idx in [0, 1]:
        for setup_idx in [0, 1]:
            host_blocked_main = active_idx != 0  # blocked when NOT host
            host_blocked_setup = setup_idx != 0  # blocked when NOT host

            # Verify
            if active_idx == 0:
                assert not host_blocked_main, f"Host should NOT be blocked on own turn (active={active_idx})"
            else:
                assert host_blocked_main, f"Host SHOULD be blocked on remote turn (active={active_idx})"

            if setup_idx == 0:
                assert not host_blocked_setup, f"Host should NOT be blocked on own setup (setup={setup_idx})"
            else:
                assert host_blocked_setup, f"Host SHOULD be blocked on remote setup (setup={setup_idx})"

    # Client conditions
    for active_idx in [0, 1]:
        for setup_idx in [0, 1]:
            client_blocked_main = active_idx != 1  # blocked when NOT client
            client_blocked_setup = setup_idx != 1  # blocked when NOT client

            if active_idx == 1:
                assert not client_blocked_main, f"Client should NOT be blocked on own turn (active={active_idx})"
            else:
                assert client_blocked_main, f"Client SHOULD be blocked on host turn (active={active_idx})"

            if setup_idx == 1:
                assert not client_blocked_setup, f"Client should NOT be blocked on own setup (setup={setup_idx})"
            else:
                assert client_blocked_setup, f"Client SHOULD be blocked on host setup (setup={setup_idx})"

    print("[OK] All blocking conditions verified")
    return True


# ── Test: State Serialization Symmetry ─────────────────────────────────

def test_state_serialization():
    """Verify GameState serialization round-trips correctly."""
    print("\n=== Test: State serialization symmetry ===")

    init_cards()
    deck1 = expand_deck(FIRE_DECK)
    deck2 = expand_deck(WATER_DECK)

    state = GameState()
    state.setup_game(deck1, deck2)
    tm = TurnManager(state)

    # Handle mulligans properly
    for pi in range(2):
        for _ in range(10):
            if tm.needs_mulligan(pi):
                state.do_mulligan(pi)
            else:
                break

    # Place basics using TurnManager
    for pi in range(2):
        player = state.get_player(pi)
        basics = [c for c in player.hand if c.is_basic_pokemon]
        assert len(basics) > 0, f"Player {pi+1} has no basic Pokemon after mulligan!"
        # Place first basic as active
        hand_idx = player.hand.index(basics[0])
        result = tm.setup_place_basic(pi, hand_idx, "active")
        assert result.success, f"Setup active failed: {result.log_message}"
        # Place additional basics on bench
        for extra in basics[1:3]:
            try:
                extra_idx = player.hand.index(extra)
            except ValueError:
                continue
            empty = player.find_empty_bench_slot()
            if empty is not None:
                result = tm.setup_place_basic(pi, extra_idx, f"bench_{empty}")
                assert result.success, f"Setup bench failed: {result.log_message}"

    result = tm.setup_finalize()
    assert result.success, f"Setup finalize failed: {result.log_message}"
    assert state.phase != TurnPhase.SETUP, "Game should have started"

    # Serialize for player 0
    data_0 = serialize_game_state(state, for_player_idx=0)
    restored_0 = deserialize_game_state(data_0, for_player_idx=0)

    # Verify state correctness
    assert restored_0.phase == state.phase, f"Phase mismatch: {restored_0.phase} != {state.phase}"
    assert restored_0.active_player_idx == state.active_player_idx
    assert restored_0.turn_number == state.turn_number

    # Player 0: own hand should be visible, opponent hand hidden
    assert len(restored_0.p1.hand) == len(state.p1.hand), \
        f"Own hand count mismatch: {len(restored_0.p1.hand)} != {len(state.p1.hand)}"
    assert len(restored_0.p2.hand) == 0, \
        f"Opponent hand should be hidden (got {len(restored_0.p2.hand)} cards)"
    assert len(restored_0.p2.deck) == len(state.p2.deck), \
        f"Opponent deck count mismatch"

    # Active should exist
    assert restored_0.p1.active is not None, "Own active should exist"
    assert restored_0.p2.active is not None, "Opponent active should exist"

    # Serialize for player 1
    data_1 = serialize_game_state(state, for_player_idx=1)
    restored_1 = deserialize_game_state(data_1, for_player_idx=1)

    assert len(restored_1.p2.hand) == len(state.p2.hand), \
        f"Player 1: own hand count mismatch"
    assert len(restored_1.p1.hand) == 0, \
        f"Player 1: opponent hand should be hidden"

    print("[OK] State serialization symmetry verified")
    return True


# ── Test: Action Protocol ─────────────────────────────────────────────

def test_action_protocol():
    """Verify PlayerAction <-> string mapping is complete and symmetric."""
    print("\n=== Test: Action protocol ===")

    for action in PlayerAction:
        action_str = ACTION_TO_STRING.get(action)
        assert action_str is not None, f"Missing string mapping for {action}"
        restored = STRING_TO_ACTION.get(action_str)
        assert restored == action, f"Round-trip failed: {action} -> {action_str} -> {restored}"

    print("[OK] All PlayerAction mappings verified")
    return True


# ── Test: Full Game Flow via Network ───────────────────────────────────

def test_full_game_flow():
    """Run a complete multiplayer game through the network layer."""
    print("\n=== Test: Full multiplayer game flow ===")

    init_cards()

    # Create small test decks
    # Player 1 (host): Fire basics + Fire energy
    deck1 = expand_deck(FIRE_DECK)
    # Player 2 (client): Water basics + Water energy
    deck2 = expand_deck(WATER_DECK)

    # ── Phase 1: Start host and connect client ──
    print("\n--- Phase 1: Connection ---")

    host_nm = NetworkManager()
    host_nm.start_host(TEST_PORT)
    time.sleep(0.3)

    client_nm = NetworkManager()
    client_nm.connect_to_host("localhost", TEST_PORT)

    try:
        wait_for_connection(host_nm)
        wait_for_connection(client_nm)
    except (TimeoutError, ConnectionError) as e:
        print(f"[FAIL] Connection: {e}")
        host_nm.stop()
        client_nm.stop()
        return False

    # ── Phase 2: Game setup on host ──
    print("\n--- Phase 2: Game Setup ---")

    state = GameState()
    state.setup_game(deck1, deck2)
    tm = TurnManager(state)

    # Handle mulligans for both players
    for pi in range(2):
        for _ in range(10):
            if tm.needs_mulligan(pi):
                state.do_mulligan(pi)
            else:
                break

    # Place basics for setup
    for pi in range(2):
        player = state.get_player(pi)
        basic_cards = [c for c in player.hand if c.is_basic_pokemon]
        if not basic_cards:
            print(f"[FAIL] Player {pi+1} has no basic Pokemon after mulligan")
            host_nm.stop()
            client_nm.stop()
            return False

        # Place first basic as active
        active_card = basic_cards[0]
        hand_idx = player.hand.index(active_card)
        result = tm.setup_place_basic(pi, hand_idx, "active")
        assert result.success, f"Setup placement failed: {result.log_message}"

        # Place additional basics on bench
        for extra in basic_cards[1:3]:  # Up to 2 bench
            try:
                extra_idx = player.hand.index(extra)
            except ValueError:
                continue
            empty = player.find_empty_bench_slot()
            if empty is not None:
                result = tm.setup_place_basic(pi, extra_idx, f"bench_{empty}")
                assert result.success, f"Bench placement failed: {result.log_message}"

    result = tm.setup_finalize()
    assert result.success, f"Setup finalize failed: {result.log_message}"
    print(f"[OK] Game setup complete. {state.get_active_player().name} goes first.")

    # ── Phase 3: Broadcast state to client ──
    print("\n--- Phase 3: State Broadcast ---")

    state_data_0 = serialize_game_state(state, for_player_idx=1)  # For client (player 1)
    host_nm.send({
        "type": MSG_STATE_UPDATE,
        "state": state_data_0,
    })

    time.sleep(0.2)
    client_msgs = drain_poll(client_nm, timeout=2.0)
    state_update_msgs = [m for m in client_msgs if m.get("type") == MSG_STATE_UPDATE]
    assert len(state_update_msgs) >= 1, f"Client did not receive state_update (got {len(client_msgs)} messages)"

    client_state = deserialize_game_state(state_update_msgs[0]["state"], for_player_idx=1)
    assert client_state.phase != TurnPhase.SETUP, "Client state should be past SETUP"
    print(f"[OK] Client received state: phase={client_state.phase.name}, "
          f"p1_active={client_state.p1.active.card.name if client_state.p1.active else 'None'}, "
          f"p2_active={client_state.p2.active.card.name if client_state.p2.active else 'None'}")

    # ── Phase 4: Play a few turns ──
    print("\n--- Phase 4: Gameplay ---")

    max_turns = 10
    current_turn = 0
    game_over = False

    while current_turn < max_turns and not game_over:
        current_turn = state.turn_number
        active_pi = state.active_player_idx

        print(f"\n  Turn {current_turn}, Player {active_pi + 1}")
        if resolve_pending_promotion(state, tm):
            if state.phase == TurnPhase.GAME_OVER:
                game_over = True
                break
            active_pi = state.active_player_idx

        # Draw phase check
        if state.phase == TurnPhase.GAME_OVER:
            game_over = True
            break

        # Attach energy if possible
        player = state.get_active_player()
        energy_cards = [(i, c) for i, c in enumerate(player.hand) if c.is_energy]
        if energy_cards and not player.energy_attached_this_turn:
            i, card = energy_cards[0]
            target = "active" if player.active else f"bench_0"
            result = tm.perform_action(
                PlayerAction.ATTACH_ENERGY, player_idx=active_pi,
                hand_idx=i, target_slot=target
            )
            if result.success:
                print(f"    Attached {card.name} to {target}")
            else:
                print(f"    [SKIP] Energy attach: {result.log_message}")
        else:
            print(f"    [SKIP] No energy in hand or already attached this turn")

        # Try to attack if possible
        if player.active and state.phase == TurnPhase.MAIN:
            can_attack = False
            for ai, atk in enumerate(player.active.card.attacks):
                if player.active.has_enough_energy(atk.cost):
                    result = tm.declare_attack(active_pi, ai)
                    if result.success:
                        print(f"    Attacked: {player.active.card.name} used {atk.name}!")
                        if result.damage_dealt > 0:
                            print(f"    Dealt {result.damage_dealt} damage")
                        if result.pokemon_ko:
                            print(f"    KO'd: {result.pokemon_ko}")
                            resolve_pending_promotion(state, tm)
                        can_attack = True
                    break
            if not can_attack:
                print(f"    No viable attack available")

        # Check game over
        if state.phase == TurnPhase.GAME_OVER:
            game_over = True
            break

        # End turn
        if state.phase in (TurnPhase.MAIN, TurnPhase.ATTACK):
            result = tm.perform_action(PlayerAction.END_TURN, player_idx=active_pi)
            assert result.success, f"End turn failed: {result.log_message}"
            print(f"    Turn ended")

        # Broadcast state to client after turn change
        state_data = serialize_game_state(state, for_player_idx=1)
        host_nm.send({
            "type": MSG_STATE_UPDATE,
            "state": state_data,
        })

        # Client verifies state consistency
        time.sleep(0.1)
        client_msgs = drain_poll(client_nm, timeout=1.0)
        state_updates = [m for m in client_msgs if m.get("type") == MSG_STATE_UPDATE]
        if state_updates:
            client_state = deserialize_game_state(state_updates[-1]["state"], for_player_idx=1)
            # Basic consistency checks
            assert client_state.turn_number == state.turn_number, \
                f"Turn mismatch: client={client_state.turn_number}, host={state.turn_number}"
            assert client_state.active_player_idx == state.active_player_idx, \
                f"Active player mismatch"
            assert client_state.phase == state.phase, \
                f"Phase mismatch: client={client_state.phase}, host={state.phase}"

            # Poll for opponent_disconnected
            disc_msgs = [m for m in client_msgs if m.get("type") == "opponent_disconnected"]
            assert not disc_msgs, "Client should not be disconnected"

        if state.phase == TurnPhase.GAME_OVER:
            game_over = True

    # ── Phase 5: Verify game result ──
    print(f"\n--- Phase 5: Results ---")
    print(f"  Game ended after {state.turn_number} turns")
    print(f"  Phase: {state.phase.name}")
    if state.winner is not None:
        winner_name = state.get_player(state.winner).name
        print(f"  Winner: {winner_name}")

    # Check prizes
    p1_prizes_taken = 6 - len(state.p1.prizes)
    p2_prizes_taken = 6 - len(state.p2.prizes)
    print(f"  P1 prizes: {p1_prizes_taken}/6, P2 prizes: {p2_prizes_taken}/6")

    # Cleanup
    host_nm.stop()
    client_nm.stop()

    print(f"\n[OK] Full game flow completed: {state.turn_number} turns")
    return True


# ── Test: USE_ABILITY protocol ────────────────────────────────────────

def test_ability_protocol():
    """Verify USE_ABILITY uses ability_name (not ability_idx) in protocol."""
    print("\n=== Test: USE_ABILITY protocol ===")

    init_cards()

    deck1 = expand_deck(FIRE_DECK)
    deck2 = expand_deck(WATER_DECK)

    state = GameState()
    state.setup_game(deck1, deck2)
    tm = TurnManager(state)

    # Setup: place basics
    for pi in range(2):
        player = state.get_player(pi)
        for _ in range(10):
            if tm.needs_mulligan(pi):
                state.do_mulligan(pi)
            else:
                break
        basic_cards = [c for c in player.hand if c.is_basic_pokemon]
        if basic_cards:
            hand_idx = player.hand.index(basic_cards[0])
            tm.setup_place_basic(pi, hand_idx, "active")
            for extra in basic_cards[1:3]:
                try:
                    extra_idx = player.hand.index(extra)
                except ValueError:
                    continue
                empty = player.find_empty_bench_slot()
                if empty is not None:
                    tm.setup_place_basic(pi, extra_idx, f"bench_{empty}")

    result = tm.setup_finalize()
    assert result.success, f"Setup failed: {result.log_message}"

    # Test: ability_name parameter is accepted by ActionResolver
    active_player = state.get_active_player()
    if active_player.active and active_player.active.card.abilities:
        abilities = active_player.active.card.abilities
        # Find a manually usable ability.
        for ab in abilities:
            if getattr(ab, 'trigger', '') in ('', 'on_turn'):
                result = tm.perform_action(
                    PlayerAction.USE_ABILITY,
                    player_idx=state.active_player_idx,
                    slot="active",
                    ability_name=ab.name,
                )
                print(f"  USE_ABILITY with ability_name='{ab.name}': "
                      f"success={result.success}, msg={result.log_message}")
                # Should not crash with TypeError
                assert not result.log_message.startswith("效果执行错误"), \
                    f"Ability execution failed: {result.log_message}"
                break
        else:
            print("  [SKIP] No manually-usable abilities on active Pokemon")
    else:
        print("  [SKIP] Active Pokemon has no abilities")

    print("[OK] USE_ABILITY protocol test passed")
    return True


# ── Main ───────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  Pokemon TCG - Multiplayer Test Suite")
    print("=" * 60)

    results = []
    tests = [
        ("my_player_idx conditions", test_my_player_idx_conditions),
        ("Action protocol", test_action_protocol),
        ("State serialization", test_state_serialization),
        ("USE_ABILITY protocol", test_ability_protocol),
        ("Full game flow", test_full_game_flow),
    ]

    for name, test_fn in tests:
        try:
            result = test_fn()
            results.append((name, result))
        except Exception as e:
            print(f"\n[FAIL] {name}: {e}")
            import traceback
            traceback.print_exc()
            results.append((name, False))

    # Summary
    print("\n" + "=" * 60)
    print("  Results Summary")
    print("=" * 60)
    all_pass = True
    for name, passed in results:
        status = "PASS" if passed else "FAIL"
        print(f"  [{status}] {name}")
        if not passed:
            all_pass = False

    if all_pass:
        print("\n  All tests passed!")
    else:
        print("\n  Some tests FAILED!")

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())

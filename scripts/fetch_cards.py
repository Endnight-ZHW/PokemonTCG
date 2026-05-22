"""Utility script to fetch and cache card data from the API.

Usage:
    python scripts/fetch_cards.py
    python scripts/fetch_cards.py --card-id sv3-26
    python scripts/fetch_cards.py --all-deck-cards
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from data.cache_manager import CacheManager
from data.api_client import ApiClient
from data.deck_definitions import ALL_CARD_IDS


def fetch_all_deck_cards():
    """Fetch all cards needed for both starter decks."""
    print(f"Fetching {len(ALL_CARD_IDS)} cards...")
    cache = CacheManager()
    api = ApiClient()

    missing = cache.get_missing_ids(ALL_CARD_IDS)
    if not missing:
        print("All cards already cached!")
        return

    print(f"{len(missing)} cards need to be fetched: {missing}")

    fetched = api.fetch_cards_batch(missing)
    print(f"Fetched {len(fetched)} cards from API.")

    # Merge with existing cache
    cached = cache.load_cached_cards()
    cached.update(fetched)
    cache.save_cards_to_cache(cached)
    print(f"Cache updated: {len(cached)} total cards.")


def fetch_single_card(card_id: str):
    """Fetch and display a single card."""
    api = ApiClient()
    cache = CacheManager()

    data = api.fetch_card(card_id)
    if data:
        print(f"Card: {data['name']} ({data['id']})")
        print(f"  Supertype: {data['supertype']}")
        print(f"  Subtypes: {data.get('subtypes', [])}")
        if data['supertype'] == 'Pokémon':
            print(f"  HP: {data['hp']}")
            print(f"  Types: {data.get('types', [])}")
            print(f"  Evolves from: {data.get('evolvesFrom', 'Basic')}")
            print(f"  Attacks: {len(data.get('attacks', []))}")
            for atk in data.get('attacks', []):
                print(f"    - {atk['name']}: {atk.get('damage', 0)} "
                      f"[{', '.join(atk.get('cost', []))}]")
            print(f"  Weakness: {data.get('weaknesses', [])}")
            print(f"  Resistance: {data.get('resistances', [])}")
            print(f"  Retreat: {data.get('convertedRetreatCost', 0)}")
        elif data['supertype'] == 'Trainer':
            print(f"  Rules: {data.get('rules', [])}")

        # Also cache it
        cached = cache.load_cached_cards()
        cached[card_id] = data
        cache.save_cards_to_cache(cached)
        print("  [Cached]")
    else:
        print(f"Failed to fetch card: {card_id}")


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description="Fetch Pokemon TCG card data")
    parser.add_argument("--card-id", type=str, help="Fetch a single card by ID")
    parser.add_argument("--all-deck-cards", action="store_true",
                        help="Fetch all cards needed for starter decks")
    parser.add_argument("--image", type=str, help="Download image for a card ID")

    args = parser.parse_args()

    if args.card_id:
        fetch_single_card(args.card_id)
    elif args.image:
        api = ApiClient()
        card_data = api.fetch_card(args.image)
        if card_data:
            path = api.download_card_image(card_data)
            print(f"Image saved to: {path}")
    elif args.all_deck_cards:
        fetch_all_deck_cards()
    else:
        # Default: try to fetch all deck cards
        print("No args specified. Fetching all deck cards...")
        fetch_all_deck_cards()

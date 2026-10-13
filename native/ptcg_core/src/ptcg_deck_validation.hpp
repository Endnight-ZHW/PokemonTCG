#pragma once

#include "ptcg_value.hpp"

namespace ptcg::ai {
// Accept either compact {card_id,count} rows or an expanded array of card IDs.
// Shared by authoring, the editor, and every authoritative match entry point.
Value validate_deck(const Value &cards, const Value &entries);
}

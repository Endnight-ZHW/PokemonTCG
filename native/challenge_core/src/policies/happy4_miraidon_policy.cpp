#include "deck_policy.hpp"

namespace ptcg::ai {
std::shared_ptr<const DeckPolicy> make_happy4_miraidon_policy() {
    return make_happy4_policy("miraidon");
}
}

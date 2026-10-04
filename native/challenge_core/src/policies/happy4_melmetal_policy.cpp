#include "deck_policy.hpp"

namespace ptcg::ai {
std::shared_ptr<const DeckPolicy> make_happy4_melmetal_policy() {
    return make_happy4_policy("melmetal");
}
}

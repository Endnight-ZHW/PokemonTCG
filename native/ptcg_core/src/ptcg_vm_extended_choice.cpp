#include "ptcg_vm_extended.hpp"
#include "ptcg_rules_internal.hpp"
#include "ptcg_game_internal.hpp"
#include "ptcg_card_runtime.hpp"
#include <algorithm>
#include <set>

namespace ptcg::ai::rules_detail {
namespace {
void adopt(VmExecutionResult &result, VmExecutionResult &next, XorShift32 &rng) {
    if (!next.success) throw std::invalid_argument(next.error_code);
    result.state=std::move(next.state);result.context=std::move(next.context);rng.set_state(next.rng_state);
    result.event_types.insert(result.event_types.end(),next.event_types.begin(),next.event_types.end());
    append_events(result.events,next.events);
    result.pending=std::move(next.pending);result.continuation=std::move(next.continuation);
}
}

bool resume_vm_extended(const NativeRulesKernel &kernel,const Value &cards,
    const Value &continuation,const Value &selected,bool cancelled,
    const std::string &op,const Value &args,int actor,const std::string &slot,
    std::int64_t stage,XorShift32 &rng,VmExecutionResult &result) {
    static const std::set<std::string> ops{"select_opponent_cards","inspect_cards","return_attached_energy",
        "discard_field_energy","select_top_outcome","evolve_from_deck","optional_effects",
        "resolve_bench_limit","attach_named_bench","flip_recover_cards"};
    if (!ops.count(op)) return false;
    auto suspend=[&](Value request,Value next) {
        increment_integer(result.state,"choice_sequence");
        next["context_mode"]=Value(string_arg(continuation,"context_mode"));
        result.pending=std::move(request);result.continuation=std::move(next);
    };
    Value &self=player(result.state,actor);Value &opponent=player(result.state,1-actor);
    const auto &choices=selected.as_array();
    if (op=="select_opponent_cards") {
        const auto zone=string_arg(args,"from_zone","hand");const auto destination=string_arg(args,"destination","discard");
        auto &source=required(opponent,zone).as_array();std::vector<std::size_t> indices;
        for (const Value &choice:choices) {
            const auto i=integer_arg(choice,"index",-1);
            if (i<0 || static_cast<std::size_t>(i)>=source.size()) throw std::invalid_argument("selected_opponent_card_stale");
            indices.push_back(i);
        }
        std::sort(indices.rbegin(),indices.rend());
        if (std::adjacent_find(indices.begin(),indices.end())!=indices.end()) throw std::invalid_argument("duplicate_card_selection");
        Array moved;
        for (auto i:indices) { moved.push_back(source[i]);required(opponent,destination).as_array().push_back(source[i]);source.erase(source.begin()+i); }
        if (destination=="deck") shuffle_array(required(opponent,"deck").as_array(),rng);
        if (!moved.empty()) append_card_zone_event(result,destination=="discard"?"cards_discarded":"card_moved",1-actor,
            std::move(moved),zone,destination,"public");
    } else if (op=="inspect_cards") {
        const int viewed=integer_arg(continuation,"viewed_player",actor);
        if (!choices.empty() && string_arg(choices.front(),"id")=="bottom") {
            auto &deck=required(player(result.state,viewed),"deck").as_array();
            if (!deck.empty()) {Value top=deck.back();deck.pop_back();deck.insert(deck.begin(),std::move(top));}
        }
        if (string_arg(args,"player")=="both") {
            auto next_spec=required(continuation,"command_spec").deep_clone();next_spec["args"]["player"]=Value("self");
            execute_vm_extended(cards,next_spec,op,required(next_spec,"args"),actor,slot,string_arg(continuation,"context_mode"),rng,result);
        }
    } else if (op=="select_top_outcome") {
        const bool discard=!choices.empty() && string_arg(choices.front(),"id")=="discard";
        auto &deck=required(self,"deck").as_array();Array moved;
        for (std::int64_t i=0;i<integer_arg(args,"count",3) && !deck.empty();++i) {
            moved.push_back(deck.back());required(self,discard?"discard":"hand").as_array().push_back(deck.back());deck.pop_back();
        }
        append_card_zone_event(result,discard?"cards_discarded":"cards_drawn",actor,std::move(moved),"deck",discard?"discard":"hand",discard?"public":"owner");
        if (discard) append_cards_drawn_event(result,actor,draw_cards(self,3),op);
    } else if (op=="return_attached_energy" || op=="discard_field_energy") {
        if (op=="return_attached_energy") {
            const auto *holder=pokemon(self,slot);
            if (!holder) throw std::invalid_argument("energy_holder_missing");
            const auto required_units=std::min<std::int64_t>(integer_arg(args,"amount"),game_detail::energy_units(cards,*holder).size());
            std::vector<std::int64_t> units;std::int64_t total=0;
            for (const auto &choice:choices) {
                const auto count=card_runtime::attachment_units(cards,*holder,integer_arg(choice,"index"));units.push_back(count);total+=count;
            }
            if (total<required_units || std::any_of(units.begin(),units.end(),[&](auto n){return total-n>=required_units;}))
                throw std::invalid_argument("energy_return_amount_invalid");
        }
        std::map<std::string,std::vector<std::size_t>> indices;
        for (const auto &choice:choices) indices[string_arg(choice,"slot")].push_back(integer_arg(choice,"index"));
        std::int64_t count=0;
        for (auto &[target_slot,removed]:indices) {
            Value *target=pokemon(self,target_slot);
            if (!target) throw std::invalid_argument("energy_holder_missing");
            auto &energies=required(*target,"energy_card_ids").as_array();
            std::sort(removed.rbegin(),removed.rend());
            if (std::adjacent_find(removed.begin(),removed.end())!=removed.end()) throw std::invalid_argument("duplicate_energy_selection");
            Array moved;
            for (auto index:removed) {
                if (index>=energies.size()) throw std::invalid_argument("energy_selection_stale");
                moved.push_back(energies[index]);required(self,op=="return_attached_energy"?"hand":"discard").as_array().push_back(energies[index]);
                energies.erase(energies.begin()+index);++count;
            }
            append_card_zone_event(result,"card_moved",actor,std::move(moved),target_slot,op=="return_attached_energy"?"hand":"discard","public");
        }
        if (args.find("per_energy")) set_attack_damage(result.context,count*integer_arg(args,"per_energy"),false);
    } else if (op=="resolve_bench_limit") {
        const int owner=integer_arg(continuation,"target_player",actor);
        for (const auto &choice:choices) discard_pokemon_with_event(result,owner,string_arg(choice,"slot"));
        execute_vm_extended(cards,required(continuation,"command_spec"),op,args,actor,slot,string_arg(continuation,"context_mode"),rng,result);
    } else if (op=="evolve_from_deck") {
        auto next=continuation.deep_clone();
        if (stage==0) {next["targets"]=selected.deep_clone();next["target_cursor"]=Value(0);}
        const auto cursor=integer_arg(next,"target_cursor");
        const auto &targets=required(next,"targets").as_array();
        if (stage==1) {
            const auto target_slot=string_arg(targets.at(cursor),"slot");Value *target=pokemon(self,target_slot);
            if (target && !choices.empty()) {
                const auto removed=remove_selected(self,"deck",selected);
                if (removed.size()!=1) throw std::invalid_argument("evolution_selection_invalid");
                const auto *current=cards.find(card_id(*target));const auto *evolution=cards.find(removed[0].string_or());
                if (!current || !evolution || string_arg(*evolution,"evolves_from")!=string_arg(*current,"name")) throw std::invalid_argument("evolution_target_invalid");
                required(*target,"evolution_stack_ids").as_array().emplace_back(card_id(*target));
                (*target)["card_id"]=removed[0];(*target)["can_evolve_this_turn"]=Value(false);
                game_detail::clear_attack_effects_on_leave(*target);(*target)["status_conditions"]=Value::make_array();
                (*target)["used_abilities"]=Value::make_array();
                append_card_zone_event(result,"pokemon_evolved",actor,Array{removed[0]},"deck",target_slot,"public");
            }
            next["target_cursor"]=Value(cursor+1);
        }
        for (auto i=integer_arg(next,"target_cursor");i<static_cast<std::int64_t>(targets.size());++i) {
            const auto target_slot=string_arg(targets[i],"slot");const auto *target=pokemon(self,target_slot);
            if (!target) continue;
            const auto *definition=cards.find(card_id(*target));if (!definition) continue;
            Array options=zone_options(cards,self,actor,"deck","pokemon");
            options.erase(std::remove_if(options.begin(),options.end(),[&](const Value &option){
                const auto *candidate=cards.find(string_arg(option,"card_id"));
                return !candidate || string_arg(*candidate,"evolves_from")!=string_arg(*definition,"name");
            }),options.end());
            next["target_cursor"]=Value(i);next["stage"]=Value(1);
            const std::int64_t maximum = options.empty() ? 0 : 1;
            auto request=pending_request("search_move",actor,0,maximum,false,false,std::move(options),op);
            decorate_deck_search_request(request,cards,self,actor);
            suspend(std::move(request),std::move(next));return true;
        }
        shuffle_array(required(self,"deck").as_array(),rng);result.event_types.emplace_back("deck_shuffled");
    } else if (op=="attach_named_bench") {
        auto next=continuation.deep_clone();const auto cursor=integer_arg(next,"target_cursor");
        const auto &targets=required(next,"targets").as_array();
        if (!choices.empty()) {
            const auto removed=remove_selected(self,"deck",selected);auto target_slot=string_arg(targets.at(cursor),"slot");
            Value *target=pokemon(self,target_slot);if (!target) throw std::invalid_argument("energy_target_missing");
            for (std::size_t index=0;index<removed.size();++index) {
                auto &energies=required(*target,"energy_card_ids").as_array();
                const auto destination=static_cast<std::int64_t>(energies.size());
                energies.push_back(removed[index]);
                append_energy_attachment_event(result,actor,removed[index].string_or(),
                    Object{{"zone",Value("deck")},{"index",Value(integer_arg(choices[index],"index"))}},
                    target_slot,destination);
            }
        }
        if (cursor+1<static_cast<std::int64_t>(targets.size())) {
            next["target_cursor"]=Value(cursor+1);
            auto options=zone_options(cards,self,actor,"deck","basic_"+game_detail::lower_ascii(string_arg(args,"energy_type")));
            const std::int64_t maximum = options.empty() ? 0 : 1;
            auto request=pending_request("search_move",actor,0,maximum,false,false,std::move(options),op);
            decorate_deck_search_request(request,cards,self,actor);suspend(std::move(request),std::move(next));
        } else {shuffle_array(required(self,"deck").as_array(),rng);result.event_types.emplace_back("deck_shuffled");}
    } else if (op=="flip_recover_cards") {
        if (stage==0) {
            const auto &flips=required(continuation,"flips").as_array();
            const auto heads=std::count_if(flips.begin(),flips.end(),[](const Value &value){return value.as_bool();});
            append_event(result,"coin_flip",Object{{"results",Value(flips)}});result.event_types.emplace_back("coin_flip");
            auto options=zone_options(cards,self,actor,"discard","any");
            const auto count=std::min<std::int64_t>(heads,options.size());
            if (count>0) {
                auto next=continuation.deep_clone();next["stage"]=Value(1);
                suspend(pending_request("select_cards",actor,0,count,false,false,std::move(options),op),std::move(next));
            }
        } else {
            const auto recovered=remove_selected(self,"discard",selected);
            for (const auto &id:recovered) required(self,"hand").as_array().push_back(id);
            append_card_zone_event(result,"card_moved",actor,recovered,"discard","hand","public");
        }
    } else if (op=="optional_effects") {
        Value::Array remaining;
        if (stage==0) {
            const auto *branches=required(continuation,"command_spec").find("branches");
            const auto *branch=branches?branches->find(selected_confirmation(selected)?"on_success":"on_failure"):nullptr;
            if (branch && branch->is_array()) remaining=branch->as_array();
        } else {
            auto nested=kernel.resume(std::move(result.state),result.context,required(continuation,"nested"),selected,cancelled,rng.state());
            adopt(result,nested,rng);remaining=required(continuation,"remaining").as_array();
            if (!result.pending.as_object().empty()) {
                auto next=continuation.deep_clone();next["nested"]=result.continuation;result.continuation=std::move(next);return true;
            }
        }
        while (!remaining.empty()) {
            const Value next_spec=remaining.front();remaining.erase(remaining.begin());
            auto nested=kernel.execute(std::move(result.state),next_spec,actor,slot,rng.state(),"ability",result.context);
            adopt(result,nested,rng);
            if (!result.pending.as_object().empty()) {
                auto next=continuation.deep_clone();next["stage"]=Value(1);next["nested"]=result.continuation;next["remaining"]=Value(remaining);
                result.continuation=std::move(next);break;
            }
        }
    }
    return true;
}
}

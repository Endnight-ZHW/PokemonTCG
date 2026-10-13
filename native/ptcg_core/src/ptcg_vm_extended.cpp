#include "ptcg_vm_extended.hpp"
#include "ptcg_rules_internal.hpp"
#include "ptcg_card_runtime.hpp"
#include "ptcg_game_internal.hpp"
#include <algorithm>
#include <set>

namespace ptcg::ai::rules_detail {
namespace {
const std::set<std::string> extended_ops{
    "register_rule", "set_temporary_rule", "mill_cards", "select_opponent_cards",
    "inspect_cards", "discard_opponent_tool", "return_attached_energy", "discard_field_energy",
    "place_counters", "attach_named_bench", "knockout_if_damaged", "select_top_outcome",
    "flip_recover_cards", "require_condition", "evolve_from_deck", "devolve_pokemon",
    "optional_effects", "discard_from_play", "resolve_bench_limit",
};

Value browse_presentation(const Value &cards, const Value &owner, int actor, int viewed,
    const std::string &zone, std::int64_t count) {
    const auto &values = required(owner, zone).as_array();
    const auto first = zone == "deck" ? std::max<std::int64_t>(0, values.size() - count) : 0;
    Array revealed;
    for (auto index=first;index<static_cast<std::int64_t>(values.size());++index) revealed.push_back(values[index]);
    return Value(Object{{"domain",Value("effect")},{"purpose",Value("inspect_cards")},
        {"source_player",Value(viewed)},{"source_zone",Value(zone)},
        {"revealed_card_ids",Value(std::move(revealed))}});
}
}

bool execute_vm_extended(const Value &cards, const Value &spec, const std::string &op,
    const Value &args, int actor, const std::string &slot, const std::string &mode,
    XorShift32 &rng, VmExecutionResult &result) {
    if (!extended_ops.count(op)) return false;
    auto suspend = [&](Value request, Value continuation) {
        increment_integer(result.state,"choice_sequence");
        continuation["context_mode"] = Value(mode);
        result.pending=std::move(request); result.continuation=std::move(continuation);
    };
    Value &self=player(result.state,actor);
    Value &opponent=player(result.state,1-actor);
    Value *source=pokemon(self,slot);
    Value *defender=pokemon(opponent,"active");
    const auto turn=integer_arg(result.state,"turn_number");
    if (op=="register_rule") {
        // Declarative continuous rules are queried from the source definitions.
        return true;
    } else if (op=="require_condition") {
        if (!condition_applies(cards,result.state,actor,string_arg(args,"condition")))
            throw std::invalid_argument("card_condition_not_met");
    } else if (op=="set_temporary_rule") {
        const bool own=string_arg(args,"target")=="self";
        Value *target=own?source:defender;
        if (target && source && (own || mode!="attack" || (!prevents_attack_effects(*target)
            && !card_runtime::protects_effect(cards,result.state,1-actor,"active")))) {
            const auto effect=string_arg(args,"effect");
            card_runtime::add_temporary_rule(*target,effect,integer_arg(args,"amount",1),actor,*source,slot,
                turn+(effect=="next_attack_bonus"?2:1),effect=="next_attack_bonus"?turn+2:0,string_arg(args,"attack_name"));
        }
    } else if (op=="mill_cards") {
        const int owner=string_arg(args,"player","opponent")=="opponent"?1-actor:actor;
        Value &victim=player(result.state,owner);
        const Value *active=pokemon(victim,"active");
        if (owner!=actor && active && card_runtime::rule(cards,string_arg(*active,"attached_tool_id"),"protect_deck_from_mill")) return true;
        auto &deck=required(victim,"deck").as_array(); Array moved;
        for (std::int64_t i=0;i<integer_arg(args,"amount") && !deck.empty();++i) {
            moved.push_back(deck.back()); required(victim,"discard").as_array().push_back(deck.back());deck.pop_back();
        }
        if (!moved.empty()) append_card_zone_event(result,"cards_discarded",owner,std::move(moved),"deck","discard","public");
    } else if (op=="discard_opponent_tool") {
        if (defender && (mode!="attack" || (!prevents_attack_effects(*defender) && !card_runtime::protects_effect(cards,result.state,1-actor,"active")))) {
            const auto tool=string_arg(*defender,"attached_tool_id");
            if (!tool.empty()) {
                required(opponent,"discard").as_array().emplace_back(tool);(*defender)["attached_tool_id"]=Value("");
                if (!defender->find("modifiers")) (*defender)["modifiers"]=Value::make_array();
                auto &modifiers=required(*defender,"modifiers").as_array();
                modifiers.erase(std::remove_if(modifiers.begin(),modifiers.end(),[](const Value &m) {
                    const auto scope=string_arg(m,"scope");
                    return string_arg(m,"duration")=="until_leave_play"
                        && (scope=="attached_attacker" || scope=="attached_defender" || string_arg(m,"hook")=="MAX_HP");
                }),modifiers.end());
                append_card_zone_event(result,"cards_discarded",1-actor,Array{Value(tool)},"active","discard","public");
            }
        }
    } else if (op=="select_opponent_cards") {
        const auto zone=string_arg(args,"from_zone","hand");
        Array options;
        if (bool_arg(args,"reveal")) options=zone_options(cards,opponent,1-actor,zone,string_arg(args,"filter","any"));
        else for (std::size_t i=0;i<required(opponent,zone).as_array().size();++i)
            options.emplace_back(Object{{"kind",Value("hidden_card")},{"index",Value(static_cast<std::int64_t>(i))},
                {"label",Value("对手手牌 "+std::to_string(i+1))}});
        const auto count=std::min<std::int64_t>(integer_arg(args,"amount",1),options.size());
        if (!count && !bool_arg(args,"reveal")) return true;
        auto request=pending_request("select_cards",actor,count,count,false,false,std::move(options),op);
        if (bool_arg(args,"reveal")) request["presentation"]=browse_presentation(cards,opponent,actor,1-actor,zone,60);
        suspend(std::move(request),make_continuation(op,spec,actor,slot));
    } else if (op=="inspect_cards" || op=="select_top_outcome") {
        const int viewed=string_arg(args,"player","self")=="self"?actor:1-actor;
        const auto zone=string_arg(args,"from_zone","deck");
        const auto count=integer_arg(args,"count",1);
        Array options;
        if (op=="select_top_outcome") {
            options.emplace_back(Object{{"kind",Value("id")},{"id",Value("hand")},{"label",Value("将查看的卡牌加入手牌")}});
            options.emplace_back(Object{{"kind",Value("id")},{"id",Value("discard")},{"label",Value("弃置查看的卡牌，再抽3张")}});
        } else if (bool_arg(args,"rest_bottom") && !required(player(result.state,viewed),zone).as_array().empty()) {
            options.emplace_back(Object{{"kind",Value("id")},{"id",Value("keep")},{"label",Value("放回原处")}});
            options.emplace_back(Object{{"kind",Value("id")},{"id",Value("bottom")},{"label",Value("放至牌库底部")}});
        } else options.emplace_back(Object{{"kind",Value("confirmation")},{"value",Value(true)},{"label",Value("查看完毕")}});
        auto request=pending_request("confirm",actor,1,1,false,false,std::move(options),op);
        request["presentation"]=browse_presentation(cards,player(result.state,viewed),actor,viewed,zone,count);
        auto continued=make_continuation(op,spec,actor,slot);continued["viewed_player"]=Value(viewed);
        suspend(std::move(request),std::move(continued));
    } else if (op=="return_attached_energy" || op=="discard_field_energy") {
        Array options;
        for (const Value &target: pokemon_options(self,actor,true,op=="discard_field_energy")) {
            const auto target_slot=string_arg(target,"slot");
            if (op=="return_attached_energy" && target_slot!=slot) continue;
            const auto *holder=pokemon(self,target_slot);
            const auto &energies=required(*holder,"energy_card_ids").as_array();
            for (std::size_t i=0;i<energies.size();++i) {
                const auto filter=string_arg(args,"energy_type","any");
                if (!attached_energy_card_matches(cards,*holder,i,filter)) continue;
                options.push_back(attachment_option(energies[i].string_or(),actor,target_slot,i));
            }
        }
        const auto maximum=std::min<std::int64_t>(integer_arg(args,"amount",1),options.size());
        const auto minimum=op=="return_attached_energy"?std::min<std::int64_t>(1,maximum):std::min(maximum,integer_arg(args,"min_select"));
        if (options.empty()) {
            if (args.find("per_energy")) result.context["attack_damage"]=Value(0);
            return true;
        }
        auto request=pending_request("select_attachment",actor,minimum,maximum,false,false,std::move(options),op);
        if (op=="return_attached_energy" && source) request["presentation"]=Value(Object{
            {"domain",Value("effect")},{"purpose",Value(op)},
            {"required_units",Value(std::min<std::int64_t>(integer_arg(args,"amount"),game_detail::energy_units(cards,*source).size()))}});
        suspend(std::move(request),make_continuation(op,spec,actor,slot));
    } else if (op=="place_counters") {
        const int owner=string_arg(args,"player","opponent")=="opponent"?1-actor:actor;
        for (const Value &entry: pokemon_options(player(result.state,owner),owner,false,true)) {
            const auto target_slot=string_arg(entry,"slot");
            Value *target=pokemon(player(result.state,owner),target_slot);
            if (string_arg(args,"target")=="damaged_bench" && integer_arg(*target,"damage_counters")==0) continue;
            if (mode=="attack" && owner!=actor && (prevents_attack_effects(*target) || card_runtime::protects_effect(cards,result.state,owner,target_slot,true))) continue;
            add_damage(*target,integer_arg(args,"amount")*10);
            if (card_runtime::knocked_out(cards,*target) && !target->find("pending_ko_source_kind")) (*target)["pending_ko_source_kind"]=Value("damage_counters");
            append_damage_feedback_event(result,"damage_counters_placed",actor,owner,target_slot,integer_arg(args,"amount")*10);
        }
    } else if (op=="knockout_if_damaged") {
        if (defender && integer_arg(*defender,"damage_counters")>=integer_arg(args,"amount")
            && !prevents_attack_effects(*defender) && !card_runtime::protects_effect(cards,result.state,1-actor,"active")) {
            (*defender)["pending_ko_source_kind"]=Value("direct_knockout");
        }
    } else if (op=="devolve_pokemon") {
        for (const Value &entry:pokemon_options(opponent,1-actor,true,true)) {
            const auto target_slot=string_arg(entry,"slot");Value *target=pokemon(opponent,target_slot);
            auto &stack=required(*target,"evolution_stack_ids").as_array();
            if (stack.empty() || prevents_attack_effects(*target) || card_runtime::protects_effect(cards,result.state,1-actor,target_slot)) continue;
            const auto old_id=card_id(*target);required(opponent,"hand").as_array().emplace_back(old_id);
            (*target)["card_id"]=stack.back();stack.pop_back();
            game_detail::clear_attack_effects_on_leave(*target);
            (*target)["status_conditions"]=Value::make_array();(*target)["used_abilities"]=Value::make_array();
            append_card_zone_event(result,"card_moved",1-actor,Array{Value(old_id)},target_slot,"hand","public");
            result.events.back()["data"]["reason"] = Value("devolution");
        }
    } else if (op=="evolve_from_deck") {
        auto options=pokemon_options(self,actor,false,true);
        const auto maximum=std::min<std::int64_t>(integer_arg(args,"count",2),options.size());
        if (maximum==0) {shuffle_array(required(self,"deck").as_array(),rng);return true;}
        suspend(pending_request("select_pokemon",actor,0,maximum,false,false,std::move(options),op),make_continuation(op,spec,actor,slot));
    } else if (op=="optional_effects") {
        const bool ability = mode == "ability";
        Array options{Value(Object{{"kind",Value("confirmation")},{"option_id",Value("confirm:yes")},{"value",Value(true)},{"label",Value(ability ? "发动特性" : "使用效果")}}),
            Value(Object{{"kind",Value("confirmation")},{"option_id",Value("confirm:no")},{"value",Value(false)},{"label",Value(ability ? "不发动" : "跳过效果")}})};
        suspend(pending_request("confirm_trigger",actor,1,1,false,false,std::move(options),op),make_continuation(op,spec,actor,slot));
    } else if (op=="discard_from_play") {
        discard_pokemon_with_event(result,actor,slot);
        game_detail::queue_promotion_if_possible(result.state,actor);
    } else if (op=="resolve_bench_limit") {
        for (int owner=0;owner<2;++owner) {
            auto options=pokemon_options(player(result.state,owner),owner,false,true);
            const auto excess=static_cast<std::int64_t>(options.size())-card_runtime::bench_limit(cards,result.state,owner);
            if (excess<=0) continue;
            auto continued=make_continuation(op,spec,actor,slot);continued["target_player"]=Value(owner);
            suspend(pending_request("select_pokemon",owner,excess,excess,false,false,std::move(options),op),std::move(continued));
            break;
        }
    } else if (op=="attach_named_bench") {
        Array targets;
        for (const Value &target:pokemon_options(self,actor,false,true)) {
            const Value *definition=cards.find(string_arg(target,"card_id"));
            if (definition && string_arg(*definition,"name")==string_arg(args,"filter_name")) targets.push_back(target);
        }
        if (targets.empty()) {shuffle_array(required(self,"deck").as_array(),rng);return true;}
        // The continuation visits each eligible bench Pokemon once.
        auto continued=make_continuation(op,spec,actor,slot);
        continued["targets"]=Value(targets);continued["target_cursor"]=Value(0);
        auto options=zone_options(cards,self,actor,"deck","basic_"+game_detail::lower_ascii(string_arg(args,"energy_type")));
        const std::int64_t maximum = options.empty() ? 0 : 1;
        auto request=pending_request("search_move",actor,0,maximum,false,false,std::move(options),op);
        decorate_deck_search_request(request,cards,self,actor);
        suspend(std::move(request),std::move(continued));
    } else if (op=="flip_recover_cards") {
        Array flips;
        for (int i=0;i<integer_arg(args,"flips",3);++i) flips.emplace_back((rng.next_u32()&1U)!=0);
        auto continued=make_continuation(op,spec,actor,slot);continued["flips"]=Value(flips);
        auto request=pending_request("coin_flip",actor,0,0,false,false,{},op);
        request["metadata"]=Value(Object{{"predetermined_flips",Value(flips)}});
        suspend(std::move(request),std::move(continued));
    }
    return true;
}
}

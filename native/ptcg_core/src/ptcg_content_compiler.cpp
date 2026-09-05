#include "../../common/ptcg_json_string.hpp"
#include "ptcg_content_compiler.hpp"

#include "ptcg_typed_ir.hpp"
#include "ptcg_typed_state.hpp"
#include "../../common/ptcg_sha256.hpp"

#include <charconv>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <utility>

namespace ptcg::ai {
namespace {

using typed::CardStringTable;
using typed::VmCatalog;
using typed::VmOp;

void append_canonical_json(std::string &output, const Value &value) {
    switch (value.type()) {
        case Value::Type::null_value: output += "null"; return;
        case Value::Type::boolean: output += value.as_bool() ? "true" : "false"; return;
        case Value::Type::integer: output += std::to_string(value.as_integer()); return;
        case Value::Type::number: {
            const double number = value.as_number();
            if (!std::isfinite(number)) {
                output += "null";
                return;
            }
            char buffer[64]{};
            const auto converted = std::to_chars(
                std::begin(buffer), std::end(buffer), number,
                std::chars_format::general,
                std::numeric_limits<double>::max_digits10);
            output.append(buffer, converted.ptr);
            return;
        }
        case Value::Type::string:
            json_text::append_string(output, value.as_string());
            return;
        case Value::Type::array: {
            output.push_back('[');
            bool first = true;
            for (const Value &entry : value.as_array()) {
                if (!first) output.push_back(',');
                first = false;
                append_canonical_json(output, entry);
            }
            output.push_back(']');
            return;
        }
        case Value::Type::object: {
            output.push_back('{');
            bool first = true;
            for (const auto &[key, entry] : value.as_object()) {
                if (!first) output.push_back(',');
                first = false;
                append_canonical_json(output, Value(key));
                output.push_back(':');
                append_canonical_json(output, entry);
            }
            output.push_back('}');
            return;
        }
    }
}

std::string fingerprint(const Value &value) {
    std::string canonical;
    append_canonical_json(canonical, value);
    return crypto::sha256(canonical);
}

const Value *field(const Value &value, std::string_view key) {
    return value.is_object() ? value.find(std::string(key)) : nullptr;
}

std::string string_field(
    const Value &value,
    std::string_view key,
    std::string fallback = {}
) {
    const Value *entry = field(value, key);
    return entry != nullptr && entry->is_string()
        ? entry->as_string() : std::move(fallback);
}

std::int64_t integer_field(
    const Value &value,
    std::string_view key,
    std::int64_t fallback = 0
) {
    const Value *entry = field(value, key);
    return entry != nullptr && entry->is_number()
        ? entry->as_integer() : fallback;
}

std::string pointer_token(std::string value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (const char character : value) {
        if (character == '~') escaped += "~0";
        else if (character == '/') escaped += "~1";
        else escaped += character;
    }
    return escaped;
}

void diagnostic(
    Value::Array &rows,
    std::string code,
    std::string message,
    std::string source_path = {},
    std::string pointer = {},
    std::string card_id = {}
) {
    rows.emplace_back(Value::Object{
        {"severity", Value("error")},
        {"code", Value(std::move(code))},
        {"message", Value(std::move(message))},
        {"source_path", Value(std::move(source_path))},
        {"pointer", Value(std::move(pointer))},
        {"card_id", Value(std::move(card_id))},
    });
}

Value source_for(const Value &sources, const std::string &card_id) {
    const Value *source = sources.is_object() ? sources.find(card_id) : nullptr;
    return source != nullptr && source->is_object()
        ? source->deep_clone()
        : Value(Value::Object{
            {"path", Value()},
            {"pointer", Value("/cards/" + pointer_token(card_id))},
        });
}

void append_command_sources(
    const Value &commands,
    const Value &source,
    const std::string &pointer,
    Value::Array &target,
    std::int64_t &command_count,
    std::set<std::string> &used_ops
) {
    if (!commands.is_array()) return;
    const auto &rows = commands.as_array();
    for (std::size_t index = 0; index < rows.size(); ++index) {
        const Value &command = rows[index];
        if (!command.is_object()) continue;
        const std::string op = string_field(command, "op");
        if (!op.empty()) used_ops.insert(op);
        const std::string command_pointer = pointer + "/" + std::to_string(index);
        target.emplace_back(Value::Object{
            {"op", Value(op)},
            {"source_path", Value(string_field(source, "path"))},
            {"pointer", Value(command_pointer)},
        });
        ++command_count;
        const Value *branches = field(command, "branches");
        if (branches == nullptr || !branches->is_object()) continue;
        for (const auto &[branch_name, branch] : branches->as_object()) {
            append_command_sources(
                branch,
                source,
                command_pointer + "/branches/" + pointer_token(branch_name),
                target,
                command_count,
                used_ops);
        }
    }
}

bool transform_blocks(
    Value &card,
    const char *field_name,
    const Value &source,
    const std::string &base_pointer,
    Value &ir_blocks,
    Value::Array &diagnostics,
    const std::string &card_id,
    std::int64_t &command_count,
    std::int64_t &source_count,
    std::set<std::string> &used_ops
) {
    Value *blocks = card.find(field_name);
    if (blocks == nullptr) {
        card[field_name] = Value::make_array();
        return true;
    }
    if (!blocks->is_array()) {
        diagnostic(
            diagnostics,
            "content_blocks_not_array",
            std::string(field_name) + " must be an array",
            string_field(source, "path"),
            base_pointer,
            card_id);
        return false;
    }
    std::set<std::string> names;
    for (std::size_t index = 0; index < blocks->as_array().size(); ++index) {
        Value &block = blocks->as_array()[index];
        if (!block.is_object()) {
            diagnostic(
                diagnostics,
                "content_block_not_object",
                std::string(field_name) + " entry must be an object",
                string_field(source, "path"),
                base_pointer + "/" + std::to_string(index),
                card_id);
            continue;
        }
        const std::string name = string_field(block, "name");
        if (name.empty() || !names.insert(name).second) {
            diagnostic(
                diagnostics,
                "content_block_name_invalid",
                std::string(field_name) + " names must be non-empty and unique",
                string_field(source, "path"),
                base_pointer + "/" + std::to_string(index),
                card_id);
            continue;
        }
        const Value *author_commands = field(block, "commands");
        if (author_commands != nullptr && !author_commands->is_array()) {
            diagnostic(
                diagnostics,
                "content_commands_not_array",
                "effect commands must be an array",
                string_field(source, "path"),
                base_pointer + "/" + std::to_string(index) + "/commands",
                card_id);
            continue;
        }
        Value commands = author_commands != nullptr
            ? author_commands->deep_clone() : Value::make_array();
        block["compiled_effects"] = commands.deep_clone();
        block.erase("commands");
        Value::Array source_map;
        std::int64_t before = command_count;
        append_command_sources(
            commands,
            source,
            base_pointer + "/" + std::to_string(index) + "/commands",
            source_map,
            command_count,
            used_ops);
        source_count += command_count - before;
        ir_blocks[name] = Value(Value::Object{
            {"commands", std::move(commands)},
            {"source_map", Value(std::move(source_map))},
            {"text", Value(string_field(block, "text"))},
            {"trigger", Value(string_field(block, "trigger"))},
        });
    }
    return true;
}

void validate_card_schema(
    const std::string &card_id,
    const Value &card,
    const Value &source,
    Value::Array &diagnostics
) {
    const std::string path = string_field(source, "path");
    const std::string pointer = string_field(source, "pointer");
    const auto require_type = [&](const char *key, Value::Type type) {
        const Value *entry = field(card, key);
        if (entry == nullptr || entry->type() != type) {
            diagnostic(
                diagnostics,
                "content_card_field_invalid",
                std::string("card field has the wrong type: ") + key,
                path,
                pointer + "/" + pointer_token(key),
                card_id);
        }
    };
    require_type("api_id", Value::Type::string);
    require_type("name", Value::Type::string);
    require_type("supertype", Value::Type::string);
    require_type("subtypes", Value::Type::array);
    require_type("attacks", Value::Type::array);
    require_type("abilities", Value::Type::array);
    require_type("energy_effects", Value::Type::array);
    const std::string supertype = string_field(card, "supertype");
    if (string_field(card, "name").empty()
        || (supertype != "Pokémon" && supertype != "Trainer" && supertype != "Energy")) {
        diagnostic(
            diagnostics,
            "content_card_identity_invalid",
            "card name and supertype must use the product schema",
            path,
            pointer,
            card_id);
    }
    const Value *commands = field(card, "commands");
    if (commands != nullptr && !commands->is_array()) {
        diagnostic(
            diagnostics,
            "content_commands_not_array",
            "trainer commands must be an array",
            path,
            pointer + "/commands",
            card_id);
    }
}

void validate_sources(
    const Value &cards,
    const Value &sources,
    Value::Array &diagnostics
) {
    if (cards.as_object().size() != sources.as_object().size()) {
        diagnostic(
            diagnostics,
            "content_source_set_mismatch",
            "every authored card must have exactly one source location");
    }
    for (const auto &[card_id, ignored] : cards.as_object()) {
        (void)ignored;
        const Value *source = sources.find(card_id);
        const std::string expected_pointer = "/cards/" + pointer_token(card_id);
        if (source == nullptr || !source->is_object()
            || string_field(*source, "path").empty()
            || string_field(*source, "pointer") != expected_pointer) {
            diagnostic(
                diagnostics,
                "content_source_invalid",
                "card source must contain its author file path and canonical JSON Pointer",
                source != nullptr ? string_field(*source, "path") : std::string{},
                expected_pointer,
                card_id);
        }
    }
}

bool validate_decks(
    const Value &decks,
    const Value &cards,
    Value::Array &diagnostics
) {
    if (!decks.is_object()) {
        diagnostic(diagnostics, "content_decks_not_object", "decks must be an object");
        return false;
    }
    for (const auto &[deck_key, deck] : decks.as_object()) {
        const Value *rows = field(deck, "cards");
        if (!deck.is_object() || rows == nullptr || !rows->is_array()) {
            diagnostic(
                diagnostics,
                "content_deck_invalid",
                "deck cards must be an array",
                "godot/authoring/decks.json",
                "/decks/" + pointer_token(deck_key));
            continue;
        }
        if (string_field(deck, "key") != deck_key
            || integer_field(deck, "card_count", -1) != 60) {
            diagnostic(
                diagnostics,
                "content_deck_metadata_invalid",
                "deck key/card_count metadata must match the release deck",
                "godot/authoring/decks.json",
                "/decks/" + pointer_token(deck_key));
        }
        std::int64_t total = 0;
        std::set<std::string> seen_cards;
        for (const Value &row : rows->as_array()) {
            const std::string card_id = string_field(row, "card_id");
            const Value *count_value = field(row, "count");
            const std::int64_t count = count_value != nullptr && count_value->is_integer()
                ? count_value->as_integer() : -1;
            if (card_id.empty() || cards.find(card_id) == nullptr || count <= 0
                || !seen_cards.insert(card_id).second) {
                diagnostic(
                    diagnostics,
                    "content_deck_card_invalid",
                    "deck entry references an unknown/duplicate card or invalid integer count",
                    "godot/authoring/decks.json",
                    "/decks/" + pointer_token(deck_key),
                    card_id);
                continue;
            }
            total += count;
        }
        if (total != 60) {
            diagnostic(
                diagnostics,
                "content_deck_size_invalid",
                "release deck must contain exactly 60 cards",
                "godot/authoring/decks.json",
                "/decks/" + pointer_token(deck_key));
        }
    }
    return diagnostics.empty();
}

void validate_strategies(
    const Value &strategies,
    const Value &decks,
    const Value &cards,
    Value::Array &diagnostics
) {
    const Value *rows = field(strategies, "strategies");
    if (!strategies.is_object() || rows == nullptr || !rows->is_object()) {
        diagnostic(
            diagnostics,
            "content_strategies_invalid",
            "strategy catalog must contain a strategies object");
        return;
    }
    for (const auto &[deck_key, ignored] : decks.as_object()) {
        const Value *strategy = rows->find(deck_key);
        if (strategy == nullptr || !strategy->is_object()) {
            diagnostic(
                diagnostics,
                "content_strategy_missing",
                "release deck is missing its Challenge strategy",
                "godot/authoring/ai_strategies.json",
                "/strategies/" + pointer_token(deck_key));
            continue;
        }
        if (string_field(*strategy, "deck_key") != deck_key) {
            diagnostic(
                diagnostics,
                "content_strategy_deck_mismatch",
                "strategy deck_key must match its catalog key",
                "godot/authoring/ai_strategies.json",
                "/strategies/" + pointer_token(deck_key) + "/deck_key");
        }
        std::set<std::string> deck_cards;
        const Value *deck_rows = field(ignored, "cards");
        if (deck_rows != nullptr && deck_rows->is_array()) {
            for (const Value &row : deck_rows->as_array()) {
                deck_cards.insert(string_field(row, "card_id"));
            }
        }
        const Value *roles = field(*strategy, "card_roles");
        if (roles == nullptr || !roles->is_object()) {
            diagnostic(
                diagnostics,
                "content_strategy_roles_invalid",
                "strategy card_roles must be an object",
                "godot/authoring/ai_strategies.json",
                "/strategies/" + pointer_token(deck_key) + "/card_roles");
            continue;
        }
        for (const auto &[role, references] : roles->as_object()) {
            if (!references.is_array()) {
                diagnostic(
                    diagnostics,
                    "content_strategy_role_invalid",
                    "strategy role references must be an array",
                    "godot/authoring/ai_strategies.json",
                    "/strategies/" + pointer_token(deck_key) + "/card_roles/" + pointer_token(role));
                continue;
            }
            for (std::size_t index = 0; index < references.as_array().size(); ++index) {
                const std::string card_id = references.as_array()[index].string_or();
                if (card_id.empty() || cards.find(card_id) == nullptr
                    || deck_cards.count(card_id) == 0) {
                    diagnostic(
                        diagnostics,
                        "content_strategy_card_invalid",
                        "strategy role must reference a card in its release deck",
                        "godot/authoring/ai_strategies.json",
                        "/strategies/" + pointer_token(deck_key) + "/card_roles/"
                            + pointer_token(role) + "/" + std::to_string(index),
                        card_id);
                }
            }
        }
    }
    if (rows->as_object().size() != decks.as_object().size()) {
        diagnostic(
            diagnostics,
            "content_strategy_set_mismatch",
            "strategy keys must exactly match release deck keys");
    }
}

} // namespace

Value compile_content_bundle(const Value &bundle) {
    Value::Array diagnostics;
    if (!bundle.is_object()) {
        diagnostic(diagnostics, "content_bundle_not_object", "authoring bundle must be an object");
        return Value(Value::Object{
            {"success", Value(false)},
            {"diagnostics", Value(std::move(diagnostics))},
        });
    }
    const Value *author_cards = field(bundle, "cards");
    const Value *sources = field(bundle, "card_sources");
    const Value *decks = field(bundle, "decks");
    const Value *strategies = field(bundle, "strategies");
    const Value *descriptors = field(bundle, "vm_descriptors");
    if (author_cards == nullptr || !author_cards->is_object()) {
        diagnostic(diagnostics, "content_cards_not_object", "cards must be an object");
    }
    if (sources == nullptr || !sources->is_object()) {
        diagnostic(diagnostics, "content_sources_not_object", "card_sources must be an object");
    }
    if (decks == nullptr || !decks->is_object()) {
        diagnostic(diagnostics, "content_decks_not_object", "decks must be an object");
    }
    if (strategies == nullptr || !strategies->is_object()) {
        diagnostic(diagnostics, "content_strategies_not_object", "strategies must be an object");
    }
    const Value *descriptor_rows = descriptors != nullptr
        ? field(*descriptors, "descriptors") : nullptr;
    if (descriptor_rows == nullptr || !descriptor_rows->is_object()) {
        diagnostic(diagnostics, "content_descriptors_invalid", "VM descriptors must be an object");
    }
    if (!diagnostics.empty()) {
        return Value(Value::Object{
            {"success", Value(false)},
            {"diagnostics", Value(std::move(diagnostics))},
        });
    }

    validate_sources(*author_cards, *sources, diagnostics);

    Value runtime_cards = author_cards->deep_clone();
    Value ir_cards = Value::make_object();
    std::int64_t command_count = 0;
    std::int64_t source_count = 0;
    std::set<std::string> used_ops;
    for (auto &[card_id, card] : runtime_cards.as_object()) {
        const Value source = source_for(*sources, card_id);
        if (!card.is_object() || card_id.empty()) {
            diagnostic(
                diagnostics,
                "content_card_invalid",
                "card entries must be named objects",
                string_field(source, "path"),
                string_field(source, "pointer"),
                card_id);
            continue;
        }
        validate_card_schema(card_id, card, source, diagnostics);
        if (string_field(card, "api_id", card_id) != card_id) {
            diagnostic(
                diagnostics,
                "content_card_id_mismatch",
                "card api_id must match its object key",
                string_field(source, "path"),
                string_field(source, "pointer"),
                card_id);
        }
        card["api_id"] = Value(card_id);
        card["image_path"] = Value("res://assets/cards/" + card_id + ".webp");
        const Value *author_trainer = field(card, "commands");
        Value trainer_commands = author_trainer != nullptr && author_trainer->is_array()
            ? author_trainer->deep_clone() : Value::make_array();
        card["compiled_trainer_effects"] = trainer_commands.deep_clone();
        card.erase("commands");

        Value attacks = Value::make_object();
        Value abilities = Value::make_object();
        const std::string card_pointer = "/cards/" + pointer_token(card_id);
        transform_blocks(
            card, "attacks", source, card_pointer + "/attacks", attacks,
            diagnostics, card_id, command_count, source_count, used_ops);
        transform_blocks(
            card, "abilities", source, card_pointer + "/abilities", abilities,
            diagnostics, card_id, command_count, source_count, used_ops);
        Value::Array trainer_source_map;
        std::int64_t before = command_count;
        append_command_sources(
            trainer_commands,
            source,
            card_pointer + "/commands",
            trainer_source_map,
            command_count,
            used_ops);
        source_count += command_count - before;
        ir_cards[card_id] = Value(Value::Object{
            {"source", source.deep_clone()},
            {"source_map", Value(std::move(trainer_source_map))},
            {"attacks", std::move(attacks)},
            {"abilities", std::move(abilities)},
            {"trainer_commands", std::move(trainer_commands)},
            {"energy_effects", field(card, "energy_effects") != nullptr
                ? field(card, "energy_effects")->deep_clone()
                : Value::make_array()},
        });
    }

    if (runtime_cards.as_object().size() != 137U) {
        diagnostic(diagnostics, "content_card_count_invalid", "release catalog must contain 137 cards");
    }
    auto card_strings = std::make_shared<CardStringTable>(runtime_cards);
    VmCatalog vm_catalog(runtime_cards, card_strings);
    if (!vm_catalog.valid()) {
        diagnostic(diagnostics, "content_vm_compile_failed", vm_catalog.error());
    }
    if (descriptor_rows->as_object().size() != 80U) {
        diagnostic(diagnostics, "content_descriptor_count_invalid", "expected exactly 80 VM descriptors");
    }
    for (const auto &[op, ignored] : descriptor_rows->as_object()) {
        (void)ignored;
        if (typed::vm_op_from_string(op) == VmOp::invalid) {
            diagnostic(diagnostics, "content_descriptor_unknown_op", "descriptor has no native VM op", {}, {}, op);
        }
    }
    const std::string descriptor_digest = string_field(*descriptors, "descriptor_digest");
    const Value *golden_ops = field(*descriptors, "golden_ops");
    if (integer_field(*descriptors, "descriptor_schema_version", -1) != 1
        || integer_field(*descriptors, "vm_ir_version", -1) != 3
        || string_field(*descriptors, "digest_algorithm") != "sha256"
        || golden_ops == nullptr || !golden_ops->is_array()
        || golden_ops->as_array().size() != descriptor_rows->as_object().size()
        || descriptor_digest.empty()
        || descriptor_digest != fingerprint(*descriptor_rows)) {
        diagnostic(
            diagnostics,
            "content_descriptor_contract_invalid",
            "VM descriptor metadata, golden inventory, or SHA-256 digest is invalid");
    } else {
        std::set<std::string> golden_set;
        for (const Value &entry : golden_ops->as_array()) {
            golden_set.insert(entry.string_or());
        }
        for (const auto &[op, ignored] : descriptor_rows->as_object()) {
            (void)ignored;
            if (golden_set.count(op) == 0) {
                diagnostic(
                    diagnostics,
                    "content_descriptor_golden_missing",
                    "every VM descriptor must have exactly one semantic golden",
                    {}, {}, op);
            }
        }
    }
    if (command_count != 160) {
        diagnostic(
            diagnostics,
            "content_effect_count_invalid",
            "release catalog must compile exactly 160 effects");
    }
    validate_decks(*decks, runtime_cards, diagnostics);
    if (decks->as_object().size() != 10U) {
        diagnostic(diagnostics, "content_deck_count_invalid", "expected exactly 10 release decks");
    }
    validate_strategies(*strategies, *decks, runtime_cards, diagnostics);

    const std::string content_fingerprint = fingerprint(Value(Value::Object{
        {"cards", runtime_cards.deep_clone()},
        {"decks", decks->deep_clone()},
        {"strategies", strategies->deep_clone()},
        {"vm_descriptors", descriptor_rows->deep_clone()},
    }));
    const std::string source_fingerprint = fingerprint(sources->deep_clone());
    const std::string contract_fingerprint = fingerprint(Value(Value::Object{
        {"format", Value("ptcg_card_ir/4")},
        {"vm_ir_version", Value(3)},
        {"descriptor_digest", Value(descriptor_digest)},
    }));
    Value::Array used_vm_ops;
    used_vm_ops.reserve(used_ops.size());
    for (const std::string &op : used_ops) used_vm_ops.emplace_back(op);
    Value card_ir(Value::Object{
        {"format", Value("ptcg_card_ir/4")},
        {"vm_ir_version", Value(3)},
        {"cards", std::move(ir_cards)},
        {"card_count", Value(static_cast<std::int64_t>(runtime_cards.as_object().size()))},
        {"authored_card_count", Value(static_cast<std::int64_t>(runtime_cards.as_object().size()))},
        {"effect_count", Value(command_count)},
        {"command_count", Value(command_count)},
        {"source_mapped_effect_count", Value(source_count)},
        {"source_map_coverage", Value(command_count == 0 ? 1.0
            : static_cast<double>(source_count) / static_cast<double>(command_count))},
        {"used_vm_ops", Value(std::move(used_vm_ops))},
        {"descriptor_digest", Value(descriptor_digest)},
        {"content_fingerprint", Value(content_fingerprint)},
        {"source_fingerprint", Value(source_fingerprint)},
        {"contract_fingerprint", Value(contract_fingerprint)},
    });
    Value outputs(Value::Object{
        {"cards", runtime_cards.deep_clone()},
        {"card_ir", std::move(card_ir)},
        {"decks", decks->deep_clone()},
        {"ai_strategies", strategies->deep_clone()},
        {"vm_command_descriptors", descriptors->deep_clone()},
    });
    Value summary(Value::Object{
        {"card_count", Value(static_cast<std::int64_t>(runtime_cards.as_object().size()))},
        {"deck_count", Value(static_cast<std::int64_t>(decks->as_object().size()))},
        {"effect_count", Value(command_count)},
        {"vm_descriptor_count", Value(static_cast<std::int64_t>(descriptor_rows->as_object().size()))},
        {"source_map_coverage", Value(command_count == 0 ? 1.0
            : static_cast<double>(source_count) / static_cast<double>(command_count))},
    });
    return Value(Value::Object{
        {"success", Value(diagnostics.empty())},
        {"diagnostics", Value(std::move(diagnostics))},
        {"outputs", std::move(outputs)},
        {"summary", std::move(summary)},
    });
}

Value content_compiler_contract() {
    return Value(Value::Object{
        {"boundary_id", Value("ptcg.native_content_compiler/1")},
        {"authoring_schema", Value("ptcg_card_source/1")},
        {"card_ir_format", Value("ptcg_card_ir/4")},
        {"vm_ir_version", Value(3)},
        {"diagnostic_location", Value("json_pointer")},
        {"runtime_execution", Value(false)},
        {"fingerprint_algorithm", Value("sha256-canonical-json")},
    });
}

} // namespace ptcg::ai

#pragma once

#include <string>
#include <string_view>

namespace ptcg::json_text {

// JSON byte escaping shared by serializers; number formatting stays with each contract.
inline void append_string(std::string &output, std::string_view value) {
    static constexpr char hex[] = "0123456789abcdef";
    output.push_back('"');
    for (const unsigned char byte : value) {
        switch (byte) {
            case '"': output += "\\\""; break;
            case '\\': output += "\\\\"; break;
            case '\b': output += "\\b"; break;
            case '\f': output += "\\f"; break;
            case '\n': output += "\\n"; break;
            case '\r': output += "\\r"; break;
            case '\t': output += "\\t"; break;
            default:
                if (byte < 0x20U) {
                    output += "\\u00";
                    output.push_back(hex[(byte >> 4U) & 0x0fU]);
                    output.push_back(hex[byte & 0x0fU]);
                } else {
                    output.push_back(static_cast<char>(byte));
                }
                break;
        }
    }
    output.push_back('"');
}

} // namespace ptcg::json_text

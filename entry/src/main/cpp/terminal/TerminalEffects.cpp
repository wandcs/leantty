#include "TerminalRuntime.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <map>

namespace leantty {
namespace {
constexpr size_t ClipboardLimit = 1024*1024;
constexpr size_t SequenceLimit = ((ClipboardLimit+2)/3)*4+16;
bool base64(const std::string& encoded,std::string& decoded) {
    if (encoded.size()%4 || encoded.size() > ((ClipboardLimit+2)/3)*4) return false;
    constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    decoded.clear();
    for (size_t i = 0; i < encoded.size(); i += 4) {
        unsigned value = 0; int padding = 0;
        for (size_t n = 0; n < 4; ++n) {
            const char c = encoded[i+n];
            if (c == '=' && n >= 2 && i+4 == encoded.size()) { ++padding; value <<= 6; }
            else {
                const char* digit = c ? std::strchr(alphabet,c) : nullptr;
                if (!digit || padding) return false;
                value = (value<<6)|static_cast<unsigned>(digit-alphabet);
            }
        }
        decoded += static_cast<char>(value>>16);
        if (padding < 2) decoded += static_cast<char>(value>>8);
        if (!padding) decoded += static_cast<char>(value);
    }
    return decoded.size() <= ClipboardLimit;
}
bool utf8(const std::string& text) {
    size_t i = 0;
    while (i < text.size()) {
        uint32_t c = static_cast<uint8_t>(text[i++]); unsigned remaining = 0,minimum = 0;
        if (c < 128) continue;
        if (c >= 0xc2 && c <= 0xdf) { c &= 31; remaining = 1; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { c &= 15; remaining = 2; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { c &= 7; remaining = 3; minimum = 0x10000; }
        else return false;
        while (remaining--) {
            if (i == text.size()) return false;
            const auto next = static_cast<uint8_t>(text[i++]);
            if ((next&0xc0) != 0x80) return false;
            c = (c<<6)|(next&63);
        }
        if (c < minimum || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return false;
    }
    return true;
}
bool printable(const std::string& text) {
    return utf8(text) && std::none_of(text.begin(),text.end(),[](unsigned char c) { return c < 32 || c == 127; });
}
bool metadataValue(const std::string& value) {
    const std::string punctuation = "-_ /+.,(){}[]*&^%$#@!`~";
    return !value.empty() && std::all_of(value.begin(),value.end(),[&](unsigned char c) {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            (c != ' ' && punctuation.find(c) != std::string::npos);
    });
}
}
void TerminalRuntime::writeOutput(const Command& c) {
    // Ghostty alone decides VT framing. Observe complete control sequences
    // at its ground boundary; never search arbitrary output/DCS text for OSC.
    // Clipboard/notification callbacks stay unset because their merged API
    // loses the original protocol/target required by our security contract.
    size_t offset = 0;
    if (effectOwner_ != c.owner) effectSequence_.clear();
    effectOwner_ = c.owner;
    while (offset < c.bytes.size()) {
        bool ground = false;
        checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_VT_GROUND,&ground));
        if (ground) {
            effectSequence_.clear();
            auto begin = c.bytes.data()+offset;
            auto escape = static_cast<const uint8_t*>(std::memchr(begin,27,c.bytes.size()-offset));
            const size_t length = escape ? static_cast<size_t>(escape-begin)+1 : c.bytes.size()-offset;
            ghostty_terminal_vt_write(active_,begin,length); offset += length;
            if (escape) effectSequence_ = "\x1b";
        } else {
            size_t consumed = 0;
            const auto result = ghostty_terminal_vt_write_until_ground(active_,c.bytes.data()+offset,c.bytes.size()-offset,&consumed);
            if (result != GHOSTTY_NO_VALUE) checkVt(result);
            if (!effectSequence_.empty()) {
                if (effectSequence_.size()+consumed <= SequenceLimit) {
                    effectSequence_.append(reinterpret_cast<const char*>(c.bytes.data()+offset),consumed);
                    if (effectSequence_.size() > 1 && effectSequence_[1] != ']') effectSequence_.clear();
                } else effectSequence_.clear();
            }
            offset += consumed;
            if (result == GHOSTTY_SUCCESS) { effect(effectSequence_); effectSequence_.clear(); refreshSearch(false); }
        }
    }
}
void TerminalRuntime::effect(const std::string& sequence) {
    if (!owner_ || sequence.size() < 4 || sequence.compare(0,2,"\x1b]") != 0) return;
    size_t end = sequence.size();
    if (sequence.back() == '\a') --end;
    else if (end >= 2 && sequence.compare(end-2,2,"\x1b\\") == 0) end -= 2;
    else return; // cancelled or unfinished sequences have no system effect
    const auto separator = sequence.find(';',2);
    if (separator == std::string::npos || separator >= end) return;
    const std::string code = sequence.substr(2,separator-2),payload = sequence.substr(separator+1,end-separator-1);
    if (code == "52") {
        const auto split = payload.find(';');
        if (split == std::string::npos || (split && payload.substr(0,split) != "c")) return;
        std::string decoded;
        if (base64(payload.substr(split+1),decoded) && utf8(decoded)) emit({"clipboard",consuming_,owner_,std::move(decoded)});
        return;
    }
    if (payload.empty() || payload.size() > 1024) return;
    if (code == "9") { if (printable(payload)) bell(active_,this); return; }
    if (code == "777") {
        const auto split = payload.find(';',7);
        if (payload.compare(0,7,"notify;") == 0 && split > 7 && split != std::string::npos &&
            split+1 < payload.size() && printable(payload)) bell(active_,this);
        return;
    }
    if (code != "99") return;
    const auto split = payload.find(';'); if (split == std::string::npos) return;
    std::map<char,std::string> fields;
    for (size_t start = 0; start < split;) {
        auto stop = payload.find(':',start); if (stop == std::string::npos || stop > split) stop = split;
        if (stop-start < 3 || payload[start+1] != '=') return;
        const char key = payload[start]; const auto value = payload.substr(start+2,stop-start-2);
        if (fields.count(key) || std::string("iped").find(key) == std::string::npos ||
            (!metadataValue(value) && !(key == 'p' && value == "?"))) return;
        fields.emplace(key,value); start = stop+1;
    }
    const auto content = payload.substr(split+1);
    if (content.empty()) {
        if (fields.size() == 2 && fields.count('i') && fields['p'] == "?")
            emit({"reply",consuming_,owner_,"\x1b]99;i="+fields['i']+":p=?;p=title,body\x1b\\"});
        return;
    }
    if ((fields.count('p') && fields['p'] != "title" && fields['p'] != "body") ||
        (fields.count('e') && fields['e'] != "1") || (fields.count('d') && fields['d'] != "1")) return;
    std::string decoded;
    if (fields.count('e') ? base64(content,decoded) : printable(content)) bell(active_,this);
}
}

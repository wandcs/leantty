#pragma once
#include <string>

namespace leantty {
// Viewport cell interval derived by the VT worker; invalidated before mutation.
struct TerminalLink {
    std::string url;
    int first = 0, last = -1;
    bool contains(int cell) const { return !url.empty() && cell >= first && cell <= last; }
};
}

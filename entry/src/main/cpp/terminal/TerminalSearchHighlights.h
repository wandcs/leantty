#pragma once
#include <ghostty/vt.h>
#include <algorithm>
#include <cstdint>
#include <vector>

namespace leantty {
void checkVt(GhosttyResult result);

// A paint-local projection of borrowed VT matches, never retained across writes.
// Screen coordinates let a wrapped match be clipped at either viewport edge.
struct TerminalSearchHighlights {
    int cols = 0, rows = 0;
    std::vector<uint8_t> cells;
    // Called only when search results change, not for every blink/paint.
    static std::vector<uint32_t> overview(GhosttyTerminal terminal, GhosttySearch search) {
        if (!search) return {};
        GhosttySelectionBuffer matches{nullptr,0,0};
        const auto status = ghostty_search_get(search,GHOSTTY_SEARCH_DATA_MATCHES,&matches);
        if (status != GHOSTTY_OUT_OF_SPACE) checkVt(status);
        if (!matches.len) return {};
        std::vector<GhosttySelection> selections(matches.len);
        matches.ptr = selections.data(); matches.cap = selections.size();
        checkVt(ghostty_search_get(search,GHOSTTY_SEARCH_DATA_MATCHES,&matches));
        std::vector<uint32_t> lines;
        for (size_t i = 0; i < matches.len; ++i) {
            GhosttyPointCoordinate point{};
            checkVt(ghostty_terminal_point_from_grid_ref(terminal,&selections[i].start,GHOSTTY_POINT_TAG_SCREEN,&point));
            if (lines.empty() || lines.back() != point.y) lines.push_back(point.y);
        }
        // Upstream returns matches newest first; one marker per physical row.
        std::sort(lines.begin(),lines.end());
        lines.erase(std::unique(lines.begin(),lines.end()),lines.end());
        return lines;
    }
    uint8_t at(int x, int y) const {
        return x >= 0 && x < cols && y >= 0 && y < rows && !cells.empty() ? cells[y*cols+x] : 0;
    }
    static TerminalSearchHighlights read(GhosttyTerminal terminal, GhosttySearch search, int cols, int rows) {
        TerminalSearchHighlights result{cols,rows,{}};
        if (!search || cols <= 0 || rows <= 0) return result;
        GhosttySelectionBuffer matches{nullptr,0,0};
        const auto sizeStatus = ghostty_search_get(search,GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES,&matches);
        if (sizeStatus != GHOSTTY_OUT_OF_SPACE) checkVt(sizeStatus);
        if (!matches.len) return result;
        std::vector<GhosttySelection> selections(matches.len);
        matches.ptr = selections.data(); matches.cap = selections.size();
        checkVt(ghostty_search_get(search,GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES,&matches));
        GhosttyTerminalScrollbar viewport{};
        checkVt(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&viewport));
        result.cells.resize(static_cast<size_t>(cols)*rows);
        auto mark = [&](const GhosttySelection& selection, uint8_t kind) {
            GhosttyPointCoordinate start{}, end{};
            checkVt(ghostty_terminal_point_from_grid_ref(terminal,&selection.start,GHOSTTY_POINT_TAG_SCREEN,&start));
            checkVt(ghostty_terminal_point_from_grid_ref(terminal,&selection.end,GHOSTTY_POINT_TAG_SCREEN,&end));
            if (start.y > end.y || (start.y == end.y && start.x > end.x)) std::swap(start,end);
            const int64_t first = static_cast<int64_t>(start.y)-viewport.offset;
            const int64_t last = static_cast<int64_t>(end.y)-viewport.offset;
            for (int64_t y = std::max<int64_t>(0,first); y <= std::min<int64_t>(rows-1,last); ++y) {
                const int left = y == first ? start.x : 0;
                const int right = std::min(cols-1,y == last ? static_cast<int>(end.x) : cols-1);
                for (int x = left; x <= right; ++x) result.cells[y*cols+x] = kind;
            }
        };
        for (size_t i = 0; i < matches.len; ++i) mark(selections[i],1);
        GhosttySelection selected = GHOSTTY_INIT_SIZED(GhosttySelection);
        const auto status = ghostty_search_get(search,GHOSTTY_SEARCH_DATA_SELECTED_MATCH,&selected);
        if (status == GHOSTTY_SUCCESS) mark(selected,2);
        else if (status != GHOSTTY_NO_VALUE) checkVt(status);
        return result;
    }
};
}

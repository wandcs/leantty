#pragma once
#include "TerminalGrid.h"
#include <ghostty/vt.h>
#include <cmath>

namespace leantty {
// A derived view of the VT viewport, shared by paint and pointer hit testing.
// Coordinates are Surface pixels, independent of the centered text origin.
struct TerminalScrollbar {
    double x = 0, y = 0, width = 0, height = 0, thumbY = 0, thumbHeight = 0;
    uint64_t range = 0;
    bool visible() const { return range && height > thumbHeight; }
    bool hit(int px, int py) const {
        return visible() && px >= x && px < x+width && py >= y && py < y+height;
    }
    uint64_t row(double top) const {
        if (!visible()) return 0;
        return static_cast<uint64_t>(std::round(std::clamp((top-y)/(height-thumbHeight),0.0,1.0)*range));
    }
    double markerY(uint32_t row, uint64_t total, double markerHeight) const {
        return y+(total > 1 ? std::min<uint64_t>(row,total-1)*std::max(0.0,height-markerHeight)/(total-1) : 0);
    }
    static TerminalScrollbar fit(const TerminalGrid& grid, const GhosttyTerminalScrollbar& viewport) {
        TerminalScrollbar bar;
        if (grid.inset <= 0 || grid.width < 2*grid.inset || grid.height <= 2*grid.inset ||
            !viewport.len || !viewport.total) return bar;
        bar.x = grid.width-grid.inset; bar.y = grid.inset;
        bar.width = grid.inset; bar.height = grid.height-2*grid.inset;
        bar.range = viewport.total > viewport.len ? viewport.total-viewport.len : 0;
        bar.thumbHeight = std::min(bar.height,std::max(grid.inset*2.5,bar.height*viewport.len/viewport.total));
        bar.thumbY = bar.y;
        if (bar.range) bar.thumbY += (bar.height-bar.thumbHeight)*std::min(viewport.offset,bar.range)/bar.range;
        return bar;
    }
};
}

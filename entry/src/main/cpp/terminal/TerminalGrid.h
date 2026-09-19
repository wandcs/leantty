#pragma once
#include <algorithm>

namespace leantty {
// Physical-pixel geometry, shared by drawing, VT resize and pointer admission.
// The platform supplies the inset in pixels; no font or density estimate lives here.
// Like xterm, the right inset includes the scrollbar; it is not extra padding.
struct TerminalGrid {
    int cols = 0, rows = 0, cellWidth = 0, cellHeight = 0;
    int x = 0, y = 0;
    int width = 0, height = 0, inset = 0;

    static TerminalGrid fit(int width, int height, int cw, int ch, int inset) {
        TerminalGrid grid;
        grid.width = width; grid.height = height; grid.inset = inset;
        grid.cellWidth = cw; grid.cellHeight = ch;
        grid.cols = std::clamp((width - 2*inset) / cw, 1, 512);
        grid.rows = std::clamp((height - 2*inset) / ch, 1, 256);
        // Split only the leftover pixels, preserving the maximum complete grid.
        // A sub-cell Surface clips one cell; never produce a negative origin.
        grid.x = std::max(0, (width - grid.cols*cw) / 2);
        grid.y = std::max(0, (height - grid.rows*ch) / 2);
        return grid;
    }
};
}

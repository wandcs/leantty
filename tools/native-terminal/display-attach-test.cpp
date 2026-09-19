// Executes the production attach method with only platform resources substituted.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>
#include "TerminalGrid.h"
using leantty::TerminalGrid;
struct OHNativeWindow {};
static OHNativeWindow window;
static bool rejectWindow = false;
static int creates = 0, destroys = 0;
int OH_NativeWindow_CreateNativeWindowFromSurfaceId(uint64_t, OHNativeWindow** out) {
    ++creates; *out = rejectWindow ? nullptr : &window; return rejectWindow ? -1 : 0;
}
struct TextLine {
    void* line = &window;
    TextLine(void*, const char*, float, bool, bool) {}
};
double OH_Drawing_TextLineGetTypographicBounds(void*, double* a, double* d, double* l) {
    *a = 14; *d = 4; *l = 0; return 9;
}
class TerminalRenderer {
public:
    ATTACH_RETURN_TYPE attach(uint64_t, int, int, float, int = 8, int = 1);
    int cursorStroke_ = 1;
    void detach() { if (window_) ++destroys; window_ = nullptr; surfaceId_ = 0; unavailable_ = false; }
    OHNativeWindow* window_ = nullptr;
    void* fonts_ = &window;
    uint64_t surfaceId_ = 0;
    int width_ = 0, height_ = 0, cellWidth_ = 0, cellHeight_ = 0;
    int atlasX_ = 0, atlasY_ = 0, atlasRow_ = 0;
    float fontSize_ = 0;
    bool unavailable_ = false;
    TerminalGrid grid_;
    std::vector<int> glyphs_;
};
#include "renderer-attach-under-test.inc"
static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
int main() {
    try {
        TerminalRenderer renderer;
        renderer.attach(1,900,600,16);
        require(renderer.window_ && renderer.cellWidth_ == 9, "initial geometry");
        require(renderer.grid_.cols == 98 && renderer.grid_.rows == 32 &&
            renderer.grid_.x == 9 && renderer.grid_.y == 12, "measured grid preserves and centers minimum inset");
        rejectWindow = true;
        // A platform resource rejection must not escape and kill the VT worker.
        renderer.attach(2,900,600,16);
        require(!renderer.window_ && !renderer.surfaceId_, "rejected Surface owns no window");
        require(destroys == 1, "previous window released exactly once");
        rejectWindow = false;
        renderer.attach(3,900,600,16);
        require(renderer.window_ && renderer.surfaceId_ == 3 && !renderer.unavailable_, "replacement attaches");
        renderer.attach(3,1000,700,16);
        require(creates == 3 && destroys == 1 && renderer.width_ == 1000, "resize keeps current window");
        require(renderer.grid_.cols == 109 && renderer.grid_.rows == 38 &&
            renderer.grid_.x == 9 && renderer.grid_.y == 8, "resize recomputes centered remainder without losing a fitting cell");
        renderer.attach(3,1000,700,16,8,2);
        require(renderer.cursorStroke_ == 2,"cursor stroke follows the supplied display density");
        bool invalidRejected = false;
        try { renderer.attach(0,900,600,16); } catch (const std::runtime_error&) { invalidRejected = true; }
        require(invalidRejected && renderer.surfaceId_ == 3, "invalid arguments remain fatal without replacing resources");
        renderer.detach(); require(destroys == 2, "final resource cleanup");
        std::cout << "PASS production display attach rejection, replacement, resize and cleanup\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

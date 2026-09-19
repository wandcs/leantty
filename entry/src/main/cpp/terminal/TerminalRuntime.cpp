#include "TerminalRuntime.h"
#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <utility>

namespace leantty {
void checkVt(GhosttyResult result) {
    if (result != GHOSTTY_SUCCESS) throw std::runtime_error("terminal_vt_failed");
}

TerminalRuntime::TerminalRuntime(Events events, Paint paint, std::function<void()> releaseDisplay)
    : events_(std::move(events)), paint_(std::move(paint)), releaseDisplay_(std::move(releaseDisplay)),
      worker_([this] { run(); }) {}
TerminalRuntime::~TerminalRuntime() { close(); join(); }
void TerminalRuntime::close() {
    std::lock_guard<std::mutex> lock(mutex_);
    closing_ = true;
    wake_.notify_all();
}
void TerminalRuntime::join() { if (worker_.joinable()) worker_.join(); }
size_t TerminalRuntime::queuedBytes() const { std::lock_guard<std::mutex> lock(mutex_); return bytes_; }
bool TerminalRuntime::failed() const { std::lock_guard<std::mutex> lock(mutex_); return failed_; }

uint64_t TerminalRuntime::admit(Command command) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closing_ || failed_) return 0;
    const bool data = command.kind == Kind::Output;
    const size_t payload = command.bytes.size()+command.text.size();
    if (payload > QueueLimit - bytes_ || (data && commands_.size() >= 4096) ||
        (!data && controls_ >= ControlLimit)) return 0;
    command.sequence = next_;
    // Account only after the deque successfully acquires ownership.
    commands_.push_back(std::move(command));
    bytes_ += payload;
    if (!data) ++controls_;
    ++next_;
    wake_.notify_one();
    return next_ - 1;
}
uint64_t TerminalRuntime::write(const uint8_t* bytes, size_t length, uint32_t owner) {
    if (!bytes || !length || length > ChunkLimit) return 0;
    Command c{Kind::Output}; c.owner = owner; c.bytes.assign(bytes, bytes + length);
    return admit(std::move(c));
}
uint64_t TerminalRuntime::barrier(uint32_t owner) { Command c{Kind::Barrier}; c.owner = owner; return admit(std::move(c)); }
uint64_t TerminalRuntime::positionSessionOutput() { return admit(Command{Kind::PositionSessionOutput}); }
uint64_t TerminalRuntime::resize(uint16_t cols, uint16_t rows, uint16_t cw, uint16_t ch) {
    if (!cols || !rows || cols > 512 || rows > 256 || !cw || !ch) return 0;
    Command c{Kind::Resize}; c.cols = cols; c.rows = rows; c.cellWidth = cw; c.cellHeight = ch;
    return admit(std::move(c));
}
uint64_t TerminalRuntime::beginTemporary(uint32_t owner) { Command c{Kind::BeginTemporary}; c.owner = owner; return admit(std::move(c)); }
uint64_t TerminalRuntime::endTemporary(uint32_t owner) { Command c{Kind::EndTemporary}; c.owner = owner; return admit(std::move(c)); }
uint64_t TerminalRuntime::snapshot() { return admit(Command{Kind::Snapshot}); }
uint64_t TerminalRuntime::key(GhosttyKey key, GhosttyMods modifiers, std::string text, uint32_t owner) {
    if (text.size() > 16384) return 0;
    Command c{Kind::Key}; c.key = key; c.modifiers = modifiers; c.text = std::move(text); c.owner = owner;
    return admit(std::move(c));
}
uint64_t TerminalRuntime::paste(std::string text, uint32_t owner) {
    if (text.size() > QueueLimit) return 0;
    Command c{Kind::Paste}; c.text = std::move(text); c.owner = owner; return admit(std::move(c));
}
uint64_t TerminalRuntime::focus(bool focused) {
    Command c{Kind::Focus}; c.action = focused ? 1 : 0; return admit(std::move(c));
}
uint64_t TerminalRuntime::visibility(bool visible, std::function<void()> applied) {
    Command c{Kind::Visibility}; c.action = visible; c.applied = std::move(applied); return admit(std::move(c));
}
uint64_t TerminalRuntime::pointer(int action, int button, int x, int y, GhosttyMods mods, uint32_t owner) {
    Command c{Kind::Pointer}; c.action = action; c.button = button; c.x = x; c.y = y; c.modifiers = mods; c.owner = owner;
    return admit(std::move(c));
}
uint64_t TerminalRuntime::scroll(int lines, uint32_t owner, bool local) {
    Command c{Kind::Scroll}; c.y = std::clamp(lines,-256,256); c.owner = owner; c.action = local ? 1 : 0; return admit(std::move(c));
}
uint64_t TerminalRuntime::hover(int modifiers, uint32_t owner) {
    Command c{Kind::Hover}; c.action = modifiers; c.owner = owner; return admit(std::move(c));
}
uint64_t TerminalRuntime::copy(int action, uint32_t owner, uint64_t revision) {
    Command c{Kind::Copy}; c.action = action; c.owner = owner; c.revision = revision; return admit(std::move(c));
}
uint64_t TerminalRuntime::search(std::string needle, int direction, uint32_t generation) {
    if (needle.size() > SearchLimit) return 0;
    Command c{Kind::Search}; c.text = std::move(needle); c.action = direction; c.owner = generation; return admit(std::move(c));
}
uint64_t TerminalRuntime::updateDisplay(std::function<Geometry()> update) {
    Command c{Kind::Display}; c.display = std::move(update); return admit(std::move(c));
}
void TerminalRuntime::emit(TerminalEvent event) {
    if (!events_(std::move(event))) throw std::runtime_error("terminal_event_queue_failed");
}
void TerminalRuntime::reply(GhosttyTerminal, void* context, const uint8_t* data, size_t size) noexcept {
    auto& self = *static_cast<TerminalRuntime*>(context);
    // No exception crosses Ghostty's C ABI; failure stops consumption before ACK.
    try {
        if (size > ChunkLimit) throw std::runtime_error("terminal_reply_limit");
        self.emit({"reply", self.consuming_, self.owner_, std::string(reinterpret_cast<const char*>(data), size)});
    } catch (...) { self.callbackFailed_ = true; }
}
void TerminalRuntime::bell(GhosttyTerminal, void* context) noexcept {
    auto& self = *static_cast<TerminalRuntime*>(context);
    try { self.emit({"bell", self.consuming_, self.owner_, {}}); }
    catch (...) { self.callbackFailed_ = true; }
}
GhosttyTerminal TerminalRuntime::create(size_t historyLines) {
    GhosttyTerminal terminal = nullptr;
    checkVt(ghostty_terminal_new(nullptr, &terminal, cols_, rows_));
    try {
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, this));
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void*>(reply)));
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, reinterpret_cast<const void*>(bell)));
        const GhosttyTerminalCursorStyle cursorStyle = GHOSTTY_TERMINAL_CURSOR_STYLE_BAR;
        const bool cursorBlink = true;
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursorStyle));
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &cursorBlink));
        // Retain approximately 10,000 physical lines using the upstream page
        // eviction policy. A byte cap would truncate styled/wide history early.
        // Temporary session pages still use zero bytes to disable all history.
        const size_t noHistory = 0;
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
            historyLines ? nullptr : &noHistory));
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &historyLines));
        GhosttyColorRgb foreground{205, 214, 244}, background{30, 30, 46};
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
        GhosttyColorRgb cursor{245,224,220};
        checkVt(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor));
        GhosttyColorRgb palette[256];
        checkVt(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, palette));
        const GhosttyColorRgb colors[] = {{69,71,90},{243,139,168},{166,227,161},{249,226,175},
            {137,180,250},{245,194,231},{148,226,213},{186,194,222},{88,91,112},{243,139,168},
            {166,227,161},{249,226,175},{137,180,250},{245,194,231},{148,226,213},{166,173,200}};
        std::copy(std::begin(colors),std::end(colors),palette);
        checkVt(ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,palette));
        checkVt(ghostty_terminal_resize(terminal, cols_, rows_, cellWidth_, cellHeight_));
    } catch (...) { ghostty_terminal_free(terminal); throw; }
    return terminal;
}
void TerminalRuntime::resizeGrid(uint16_t cols, uint16_t rows, uint16_t cw, uint16_t ch) {
    const bool gridChanged = cols != cols_ || rows != rows_;
    if (gridChanged || cw != cellWidth_ || ch != cellHeight_) {
        checkVt(ghostty_terminal_resize(active_, cols, rows, cw, ch));
        cols_ = cols; rows_ = rows; cellWidth_ = cw; cellHeight_ = ch;
        if (gridChanged) refreshSearch();
    }
    // Session needs the initial measured grid even when it matches the VT's
    // defaults. Surface pixel changes and reattachment are not PTY resizes.
    if (!gridReported_ || gridChanged) {
        emit({"resize", consuming_, owner_, std::to_string(cols_) + "," + std::to_string(rows_)});
        gridReported_ = true;
    }
}
void TerminalRuntime::anchorSessionOutput() {
    // Match the Web adapter's last nonempty row in the bottom active page.
    // A printed space is content; cleared/background-only cells are not.
    uint16_t anchor = 1;
    for (int row = rows_-1; row >= 0; --row) {
        bool content = false;
        for (uint16_t col = 0; col < cols_; ++col) {
            GhosttyPoint point{}; point.tag = GHOSTTY_POINT_TAG_ACTIVE;
            point.value.coordinate = {col,static_cast<uint32_t>(row)};
            GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
            checkVt(ghostty_terminal_grid_ref(active_,point,&ref));
            GhosttyCell cell; uint32_t codepoint = 0;
            checkVt(ghostty_grid_ref_cell(&ref,&cell));
            checkVt(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_CODEPOINT,&codepoint));
            if (codepoint) { content = true; break; }
        }
        if (content) { anchor = static_cast<uint16_t>(row+1); break; }
    }
    const auto position = "\x1b["+std::to_string(anchor)+";1H";
    ghostty_terminal_vt_write(active_,reinterpret_cast<const uint8_t*>(position.data()),position.size());
    GhosttyTerminalScrollViewport scroll{}; scroll.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
    ghostty_terminal_scroll_viewport(active_,scroll);
}
void TerminalRuntime::run() noexcept {
    using Clock = std::chrono::steady_clock;
    bool dirty = false, visible = true;
    bool focused = false, displayed = false, blinking = false, blinkOn = true;
    constexpr auto blinkInterval = std::chrono::milliseconds(600);
    auto nextBlink = Clock::now()+blinkInterval;
    auto nextScroll = Clock::now();
    auto nextPaint = Clock::now();
    try {
        active_ = regular_ = create(10000);
        checkVt(ghostty_selection_gesture_new(nullptr,&gesture_));
        checkVt(ghostty_mouse_encoder_new(nullptr,&mouse_));
        emit({"ready", 0, 0, {}});
        for (;;) {
            Command c{Kind::Barrier}; bool hasCommand = false;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                if (searchPending_) { /* bounded search slices alternate with admitted commands */ }
                else if (visible && dirty && paint_) wake_.wait_until(lock, nextPaint, [&] { return closing_ || !commands_.empty(); });
                else if (visible && autoscroll_ && displayed && focused) wake_.wait_until(lock,nextScroll,[&] { return closing_ || !commands_.empty(); });
                else if (visible && displayed && focused && blinking && paint_) wake_.wait_until(lock,nextBlink,[&] { return closing_ || !commands_.empty(); });
                else wake_.wait(lock, [&] { return closing_ || !commands_.empty(); });
                if (!commands_.empty()) {
                    c = std::move(commands_.front()); commands_.pop_front(); hasCommand = true;
                    if (c.kind != Kind::Output) --controls_;
                    // In-flight bytes remain within the budget until consumed.
                } else if (closing_) break;
            }
            if (hasCommand) {
                consuming_ = c.sequence;
                switch (c.kind) {
                    case Kind::Output: {
                        clearLink();
                        owner_ = c.owner;
                        writeOutput(c);
                        bool error = false;
                        checkVt(ghostty_terminal_get(active_, GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &error));
                        if (error || callbackFailed_) throw std::runtime_error("terminal_consume_failed");
                        dirty = true;
                        refreshSearch();
                        break;
                    }
                    case Kind::Resize:
                        clearLink(); pointerInside_ = false;
                        scrollbarGrab_ = -2; surfaceGeometry_ = {};
                        pointerX_ += gridX_; pointerY_ += gridY_;
                        gridX_ = gridY_ = 0;
                        resizeGrid(c.cols,c.rows,c.cellWidth,c.cellHeight);
                        dirty = true;
                        break;
                    case Kind::BeginTemporary:
                        if (temporary_) throw std::runtime_error("terminal_page_already_active");
                        resetInteraction();
                        active_ = temporary_ = create(0); owner_ = c.owner; dirty = true;
                        break;
                    case Kind::EndTemporary:
                        if (!temporary_) throw std::runtime_error("terminal_page_not_active");
                        resetInteraction();
                        ghostty_terminal_free(temporary_); temporary_ = nullptr; active_ = regular_; owner_ = c.owner;
                        checkVt(ghostty_terminal_resize(active_, cols_, rows_, cellWidth_, cellHeight_)); dirty = true;
                        break;
                    case Kind::Snapshot: {
                        GhosttyFormatterTerminalOptions options = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
                        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN; options.trim = true;
                        GhosttyFormatter formatter = nullptr; uint8_t* bytes = nullptr; size_t count = 0;
                        checkVt(ghostty_formatter_terminal_new(nullptr, &formatter, active_, options));
                        const auto result = ghostty_formatter_format_alloc(formatter, nullptr, &bytes, &count);
                        ghostty_formatter_free(formatter); checkVt(result);
                        std::string text;
                        try { text.assign(reinterpret_cast<char*>(bytes), count); }
                        catch (...) { ghostty_free(nullptr, bytes, count); throw; }
                        ghostty_free(nullptr, bytes, count);
                        emit({"snapshot", c.sequence, owner_, std::move(text)});
                        break;
                    }
                    case Kind::Display: {
                        clearLink(); pointerInside_ = false;
                        const auto geometry = c.display();
                        scrollbarGrab_ = -2; surfaceGeometry_ = geometry;
                        displayed = geometry.cols && geometry.rows;
                        if (!displayed) autoscroll_ = 0;
                        if (geometry.cols && geometry.rows) {
                            if (geometry.cols < 1 || geometry.cols > 512 || geometry.rows < 1 || geometry.rows > 256 ||
                                geometry.cellWidth < 1 || geometry.cellWidth > 256 || geometry.cellHeight < 1 || geometry.cellHeight > 256 ||
                                geometry.x < 0 || geometry.x > 16384 || geometry.y < 0 || geometry.y > 16384)
                                throw std::runtime_error("terminal_geometry_bounds");
                            // Keep the last Surface position stable when centering changes,
                            // including wheel/autoscroll before the next mouse move.
                            pointerX_ += gridX_-geometry.x; pointerY_ += gridY_-geometry.y;
                            gridX_ = geometry.x; gridY_ = geometry.y;
                            resizeGrid(geometry.cols,geometry.rows,geometry.cellWidth,geometry.cellHeight);
                        }
                        dirty = true; break;
                    }
                    case Kind::Key: encodeKey(c); dirty = true; break;
                    case Kind::Paste: {
                        GhosttyTerminalModeConfig mode{GHOSTTY_MODE_BRACKETED_PASTE,false};
                        checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_MODE,&mode));
                        std::vector<char> encoded(c.text.size()+16); size_t written = 0;
                        checkVt(ghostty_paste_encode(c.text.data(),c.text.size(),mode.value,encoded.data(),encoded.size(),&written));
                        if (written) { followInput(); emit({"input",c.sequence,c.owner,std::string(encoded.data(),written)}); }
                        dirty = true; break;
                    }
                    case Kind::Pointer: {
                        const int first = hoveredLink_.first, last = hoveredLink_.last;
                        if (scrollbarPointer(c)) { clearLink(); pointerInside_ = false; dirty = true; break; }
                        c.x -= gridX_; c.y -= gridY_;
                        pointer(c);
                        if (!focused || !visible) clearLink();
                        dirty = dirty || c.button != 0 || first != hoveredLink_.first || last != hoveredLink_.last;
                        break;
                    }
                    case Kind::Copy: copy(c); dirty = true; break;
                    case Kind::Scroll: {
                        clearLink();
                        bool reported = false;
                        GhosttyTerminalScreen screen;
                        GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
                        checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&screen));
                        const bool selected = ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_SELECTION,&selection) == GHOSTTY_SUCCESS;
                        if (!c.action && !selected && screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE) {
                            bool tracking = false;
                            checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,&tracking));
                            if (!tracking) {
                                Command arrow{Kind::Key}; arrow.sequence = c.sequence; arrow.owner = c.owner;
                                arrow.key = c.y < 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN;
                                for (int n = 0; n < std::abs(c.y); ++n) encodeKey(arrow);
                                reported = true;
                            }
                        }
                        if (!reported && !c.action && c.y) for (int n = 0; n < std::abs(c.y); ++n)
                            reported = mouse(0,c.y < 0 ? 4 : 5,pointerX_,pointerY_,pointerMods_,c.owner) || reported;
                        if (!reported) {
                            GhosttyTerminalScrollViewport scroll{}; scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA; scroll.value.delta = c.y;
                            ghostty_terminal_scroll_viewport(active_,scroll);
                        }
                        dirty = true; break;
                    }
                    case Kind::Hover:
                        if (c.action < 0) { clearLink(); pointerInside_ = false; pressedLink_.clear(); }
                        else { pointerMods_ = static_cast<GhosttyMods>(c.action); if (focused && visible) updateLink(c.owner); }
                        dirty = true; break;
                    case Kind::Search: clearLink(); search(c); dirty = true; break;
                    case Kind::Focus: {
                        const bool changed = focused != static_cast<bool>(c.action);
                        focused = c.action; dirty = true;
                        if (!focused) { clearLink(); pointerInside_ = false; autoscroll_ = 0; scrollbarGrab_ = -2; }
                        GhosttyTerminalModeConfig mode{GHOSTTY_MODE_FOCUS_EVENT,false};
                        checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_MODE,&mode));
                        if (changed && mode.value && owner_) emit({"reply",c.sequence,owner_,focused ? "\x1b[I" : "\x1b[O"});
                        break;
                    }
                    case Kind::Visibility:
                        visible = c.action; dirty = true;
                        if (!visible) { clearLink(); pointerInside_ = false; autoscroll_ = 0; scrollbarGrab_ = -2; }
                        if (c.applied) c.applied();
                        break;
                    case Kind::PositionSessionOutput: anchorSessionOutput(); dirty = true; break;
                    case Kind::Barrier: break;
                }
                if (callbackFailed_) throw std::runtime_error("terminal_callback_failed");
                { std::lock_guard<std::mutex> lock(mutex_); bytes_ -= c.bytes.size()+c.text.size(); }
                emit({"consumed", c.sequence, c.owner, {}});
                if (c.kind == Kind::Output || c.kind == Kind::Key || c.kind == Kind::Focus || c.kind == Kind::Paste) {
                    blinkOn = true; nextBlink = Clock::now()+blinkInterval;
                }
            }
            if (searchPending_) { advanceSearch(); dirty = true; }
            if (visible && autoscroll_ && displayed && focused && Clock::now() >= nextScroll) {
                GhosttyTerminalScrollViewport scroll{}; scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA; scroll.value.delta = autoscroll_;
                ghostty_terminal_scroll_viewport(active_,scroll);
                Command drag{Kind::Pointer}; drag.action = 2; drag.button = 1;
                drag.x = pointerX_; drag.y = pointerY_; drag.modifiers = pointerMods_; drag.owner = pointerOwner_;
                pointer(drag); dirty = true; nextScroll = Clock::now()+std::chrono::milliseconds(50);
            }
            // Consumption and barriers are delivered before any potentially
            // slow GPU submission. Idle terminals have no periodic wakeups.
            if (visible && dirty && paint_ && Clock::now() >= nextPaint) {
                GhosttyTerminalModeConfig mode{GHOSTTY_MODE_CURSOR_BLINKING,false};
                checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_MODE,&mode)); blinking = mode.value;
                // Refresh viewport projections after local scrolling/navigation;
                // search snapshots may not survive any intervening VT mutation.
                if (search_) checkVt(ghostty_search_feed(search_));
                paint_(active_,search_,searchOverview_,hoveredLink_,focused,blinkOn); dirty = false; nextPaint = Clock::now() + std::chrono::milliseconds(16);
            }
            if (visible && displayed && focused && blinking && Clock::now() >= nextBlink) {
                blinkOn = !blinkOn; dirty = true; nextBlink = Clock::now()+blinkInterval;
            }
        }
    } catch (...) {
        { std::lock_guard<std::mutex> lock(mutex_); failed_ = true; closing_ = true; }
        try { events_({"failure", consuming_, owner_, "terminal_runtime_failed"}); } catch (...) {}
    }
    if (releaseDisplay_) { try { releaseDisplay_(); } catch (...) {} }
    resetInteraction();
    if (gesture_) ghostty_selection_gesture_free(gesture_,active_);
    if (mouse_) ghostty_mouse_encoder_free(mouse_);
    if (temporary_) ghostty_terminal_free(temporary_);
    if (regular_) ghostty_terminal_free(regular_);
    temporary_ = regular_ = active_ = nullptr;
    { std::lock_guard<std::mutex> lock(mutex_); commands_.clear(); bytes_ = controls_ = 0; }
    try { events_({"closed", consuming_, owner_, {}}); } catch (...) {}
}
}

#pragma once
#include "TerminalGrid.h"
#include "TerminalLink.h"
#include <ghostty/vt.h>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace leantty {
struct TerminalEvent {
    std::string kind;
    uint64_t sequence = 0;
    uint32_t owner = 0;
    std::string text;
};

// One serial owner for each Pane's VT. Output admission and consumption do not
// depend on a display, and no borrowed Ghostty memory leaves this worker.
class TerminalRuntime final {
public:
    using Geometry = TerminalGrid;
    using Events = std::function<bool(TerminalEvent)>;
    // Both handles are borrowed only for this synchronous worker callback.
    using Paint = std::function<void(GhosttyTerminal,GhosttySearch,const std::vector<uint32_t>&,const TerminalLink&,bool,bool)>;
    static constexpr size_t QueueLimit = 1024 * 1024;
    static constexpr size_t SearchLimit = 1024 * 1024;
    static constexpr size_t ChunkLimit = 256 * 1024;
    static constexpr size_t ControlLimit = 128;

    explicit TerminalRuntime(Events events, Paint paint = {}, std::function<void()> releaseDisplay = {});
    ~TerminalRuntime();
    TerminalRuntime(const TerminalRuntime&) = delete;
    TerminalRuntime& operator=(const TerminalRuntime&) = delete;
    // 0 means not accepted; the caller still owns every byte. Successful
    // admission copies the complete chunk before returning its sequence.
    uint64_t write(const uint8_t* bytes, size_t length, uint32_t owner);
    uint64_t barrier(uint32_t owner);
    uint64_t positionSessionOutput();
    uint64_t resize(uint16_t cols, uint16_t rows, uint16_t cellWidth, uint16_t cellHeight);
    uint64_t beginTemporary(uint32_t owner);
    uint64_t endTemporary(uint32_t owner);
    uint64_t snapshot();
    uint64_t key(GhosttyKey key, GhosttyMods modifiers, std::string text, uint32_t owner, uint32_t unshiftedCodepoint = 0);
    uint64_t paste(std::string text, uint32_t owner);
    uint64_t pointer(int action, int button, int x, int y, GhosttyMods modifiers, uint32_t owner);
    // -1 leaves the Surface; otherwise refresh modifiers at the last pointer.
    uint64_t hover(int modifiers, uint32_t owner);
    uint64_t scroll(int lines, uint32_t owner, bool local = false);
    // Copy actions: 0 copy, 1 copy or Ctrl-C, 2 copy or request paste,
    // 3 clear after a successful copy of the supplied selection revision.
    uint64_t copy(int action, uint32_t owner, uint64_t revision = 0);
    uint64_t search(std::string needle, int direction, uint32_t generation);
    uint64_t focus(bool focused);
    uint64_t visibility(bool visible, std::function<void()> applied = {});
    // Platform operations are internal C++ calls, ordered with VT commands;
    // this is not an exported scripting or transport interface.
    uint64_t updateDisplay(std::function<Geometry()> update);
    void close();
    void join();
    size_t queuedBytes() const;
    bool failed() const;

private:
    enum class Kind { Output, Barrier, PositionSessionOutput, Resize, BeginTemporary, EndTemporary, Snapshot, Display, Key, Paste, Pointer, Hover, Scroll, Copy, Search, Focus, Visibility };
    struct Command {
        explicit Command(Kind value) : kind(value) {}
        Kind kind;
        uint64_t sequence = 0;
        uint32_t owner = 0;
        std::vector<uint8_t> bytes;
        uint16_t cols = 0, rows = 0, cellWidth = 0, cellHeight = 0;
        std::function<Geometry()> display;
        std::function<void()> applied;
        GhosttyKey key = GHOSTTY_KEY_UNIDENTIFIED;
        uint32_t unshiftedCodepoint = 0;
        GhosttyMods modifiers = 0;
        std::string text;
        int action = 0, button = 0, x = 0, y = 0;
        uint64_t revision = 0;
    };
    uint64_t admit(Command command);
    void run() noexcept;
    void emit(TerminalEvent event);
    GhosttyTerminal create(size_t historyLines);
    void resizeGrid(uint16_t cols, uint16_t rows, uint16_t cellWidth, uint16_t cellHeight);
    void anchorSessionOutput();
    static void reply(GhosttyTerminal, void*, const uint8_t*, size_t) noexcept;
    static void bell(GhosttyTerminal, void*) noexcept;
    void resetInteraction();
    void pointer(const Command& command);
    bool scrollbarPointer(const Command& command);
    void copy(const Command& command);
    void search(const Command& command);
    void advanceSearch();
    void refreshSearch(bool feed = true);
    void writeOutput(const Command& command);
    void effect(const std::string& sequence);
    void followInput();
    void encodeKey(const Command& command);
    bool mouse(int action, int button, int x, int y, GhosttyMods modifiers, uint32_t owner, bool continuing = false);
    TerminalLink linkAt(int x, int y);
    bool linkModifier(GhosttyMods modifiers);
    void updateLink(uint32_t owner);
    void clearLink();

    Events events_;
    Paint paint_;
    std::function<void()> releaseDisplay_;
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Command> commands_;
    size_t bytes_ = 0, controls_ = 0;
    uint64_t next_ = 1;
    bool closing_ = false, failed_ = false;
    // Everything below is accessed exclusively by worker_.
    GhosttyTerminal regular_ = nullptr, temporary_ = nullptr, active_ = nullptr;
    uint16_t cols_ = 80, rows_ = 24, cellWidth_ = 8, cellHeight_ = 16;
    bool gridReported_ = false;
    int gridX_ = 0, gridY_ = 0;
    Geometry surfaceGeometry_;
    // -2: idle; -1: held track click; >=0: pixel grab offset inside thumb.
    double scrollbarGrab_ = -2;
    uint32_t owner_ = 0;
    uint64_t consuming_ = 0;
    bool callbackFailed_ = false;
    GhosttySelectionGesture gesture_ = nullptr;
    GhosttyMouseEncoder mouse_ = nullptr;
    GhosttySearch search_ = nullptr;
    std::vector<uint32_t> searchOverview_;
    bool searchPending_ = false, selectSearch_ = false;
    uint32_t searchGeneration_ = 0;
    GhosttyTerminalScreen searchScreen_ = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    int searchDirection_ = 0;
    uint64_t selectionRevision_ = 0;
    // The press chooses who must receive the drag/release, even if modifiers change.
    enum class PointerGesture { None, Selection, Remote, Link };
    PointerGesture pointerGesture_ = PointerGesture::None;
    int pointerX_ = 0, pointerY_ = 0, autoscroll_ = 0;
    GhosttyMods pointerMods_ = 0;
    uint32_t pointerOwner_ = 0;
    std::string effectSequence_;
    uint32_t effectOwner_ = 0;
    std::string pressedLink_;
    TerminalLink hoveredLink_;
    bool pointerInside_ = false;
    int linkX_ = 0, linkY_ = 0;
    // Start only after every field read by run() has been initialized.
    std::thread worker_;
};
void checkVt(GhosttyResult result);
}

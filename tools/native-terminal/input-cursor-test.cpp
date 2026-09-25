// Execute the production cursor method; substitute only platform resources/results.
#include <cstdint>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>

enum InputMethod_ErrorCode { IME_ERR_OK = 0, IME_ERR_PARAMCHECK = 401,
    IME_ERR_IMCLIENT = 12800003, IME_ERR_DETACHED = 12800009 };
struct InputMethod_TextEditorProxy {};
struct InputMethod_InputMethodProxy {};
struct InputMethod_CursorInfo { double x, y, width, height; };
static InputMethod_ErrorCode platformResult = IME_ERR_OK;
static bool createFails = false;
static int created = 0, notified = 0, destroyed = 0;
static InputMethod_CursorInfo lastCursor {};
static InputMethod_InputMethodProxy* lastProxy = nullptr;
static int diagnosticCode = 0;
constexpr int LOG_APP = 0, LOG_ERROR = 0;
void OH_LOG_Print(int, int, int, const char*, const char*, int code) { diagnosticCode = code; }
static std::mutex editorsMutex;
InputMethod_CursorInfo* OH_CursorInfo_Create(double x, double y, double width, double height) {
    if (createFails) return nullptr;
    ++created;
    return new InputMethod_CursorInfo{x, y, width, height};
}
InputMethod_ErrorCode OH_InputMethodProxy_NotifyCursorUpdate(
    InputMethod_InputMethodProxy* proxy, InputMethod_CursorInfo* info) {
    ++notified; lastProxy = proxy; lastCursor = *info;
    return platformResult;
}
void OH_CursorInfo_Destroy(InputMethod_CursorInfo* info) { ++destroyed; delete info; }
struct TerminalInput {
    InputMethod_TextEditorProxy* editor_ = nullptr;
    InputMethod_InputMethodProxy* proxy_ = nullptr;
    uint32_t owner_ = 7;
    double x_ = 0, y_ = 0, height_ = 0;
    void cursor(uint32_t owner, double x, double y, double height);
};
#include "input-cursor-under-test.inc"

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
int main() {
    try {
        InputMethod_TextEditorProxy editor;
        InputMethod_InputMethodProxy proxy;
        TerminalInput input;
        input.editor_ = &editor; input.proxy_ = &proxy;
        for (int code : {0, 12800009, 12800016, 12800016, 0}) {
            platformResult = static_cast<InputMethod_ErrorCode>(code);
            input.cursor(7, 12, 34, 22);
            require(created == destroyed && notified == created, "cursor resource leaked");
            require(input.editor_ == &editor && input.proxy_ == &proxy && input.owner_ == 7,
                "cursor notification changed input ownership");
        }
        require(lastProxy == &proxy && lastCursor.x == 12 && lastCursor.y == 34 &&
            lastCursor.width == 1 && lastCursor.height == 22, "cursor geometry/proxy changed");
        require(diagnosticCode == 0, "normal cursor lifecycle must not log a failure");
        for (int code : {1, 401, 12800003, 12800008, 12802000}) {
            platformResult = static_cast<InputMethod_ErrorCode>(code);
            bool failed = false;
            try { input.cursor(7, 13, 35, 23); }
            catch (const std::runtime_error& error) {
                failed = std::string(error.what()) == "terminal_ime_cursor_update_failed";
            }
            require(failed, "unexpected platform error must remain observable");
            require(diagnosticCode == code, "diagnostic must retain only the numeric platform code");
            require(created == destroyed && notified == created, "error path leaked cursor");
        }
        const int calls = notified;
        input.cursor(6, 1, 1, 1);
        require(notified == calls && input.x_ == 13, "stale owner changed cursor");
        input.editor_ = nullptr;
        input.cursor(7, 1, 1, 1);
        require(notified == calls && input.x_ == 13, "absent editor changed cursor");
        input.editor_ = &editor; input.proxy_ = nullptr;
        input.cursor(7, 20, 30, 40);
        require(notified == calls && input.x_ == 20 && input.y_ == 30 && input.height_ == 40,
            "unbound cursor must retain geometry without notifying platform");
        input.proxy_ = &proxy; createFails = true;
        bool failed = false;
        try { input.cursor(7, 1, 2, 3); }
        catch (const std::runtime_error& error) {
            failed = std::string(error.what()) == "terminal_ime_cursor_create_failed";
        }
        require(failed && notified == calls && created == destroyed, "allocation failure contract changed");
        std::cout << "PASS production IME cursor lifecycle, errors, ownership and resource cleanup\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

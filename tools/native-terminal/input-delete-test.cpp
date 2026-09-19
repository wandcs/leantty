// Execute production IME registrations; substitute only the platform callback store.
#include <ghostty/vt.h>
#include <cstdint>
#include <iostream>
#include <stdexcept>
struct InputMethod_TextEditorProxy {};
using DeleteCallback = void (*)(InputMethod_TextEditorProxy*, int32_t);
static DeleteCallback forwardCallback = nullptr, backwardCallback = nullptr;
static GhosttyKey receivedKey = GHOSTTY_KEY_UNIDENTIFIED;
static int32_t receivedCount = 0;
static InputMethod_TextEditorProxy* receivedEditor = nullptr;
void OH_TextEditorProxy_SetDeleteForwardFunc(InputMethod_TextEditorProxy*, DeleteCallback callback) {
    forwardCallback = callback;
}
void OH_TextEditorProxy_SetDeleteBackwardFunc(InputMethod_TextEditorProxy*, DeleteCallback callback) {
    backwardCallback = callback;
}
struct InputCallbacks {
    static void key(InputMethod_TextEditorProxy* editor, GhosttyKey key, int32_t count) {
        receivedEditor = editor; receivedKey = key; receivedCount = count;
    }
};
int main() {
    try {
        InputMethod_TextEditorProxy editor;
        auto editor_ = &editor;
        #include "input-delete-under-test.inc"
        if (!forwardCallback || !backwardCallback) throw std::runtime_error("both IME deletion callbacks required");
        backwardCallback(editor_, 2);
        if (receivedKey != GHOSTTY_KEY_BACKSPACE || receivedCount != 2 || receivedEditor != editor_)
            throw std::runtime_error("IME backward deletion must dispatch Backspace with editor and count");
        forwardCallback(editor_, 3);
        if (receivedKey != GHOSTTY_KEY_DELETE || receivedCount != 3 || receivedEditor != editor_)
            throw std::runtime_error("IME forward deletion must dispatch Delete with editor and count");
        std::cout << "PASS production IME backward/forward deletion registrations\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

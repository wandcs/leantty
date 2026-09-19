#include "TerminalInput.h"
#include <inputmethod/inputmethod_cursor_info_capi.h>
#include <map>
#include <mutex>
#include <stdexcept>

namespace leantty {
namespace {
std::mutex editorsMutex;
std::map<InputMethod_TextEditorProxy*,TerminalInput*> editors;
std::string utf8(const char16_t* text,size_t length) {
    std::string out;
    for (size_t i = 0; i < length; ++i) {
        uint32_t c = text[i];
        if (c >= 0xd800 && c <= 0xdbff && i+1 < length && text[i+1] >= 0xdc00 && text[i+1] <= 0xdfff)
            c = 0x10000+((c-0xd800)<<10)+(text[++i]-0xdc00);
        else if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
        if (c < 0x80) out += static_cast<char>(c);
        else if (c < 0x800) { out += static_cast<char>(0xc0|(c>>6)); out += static_cast<char>(0x80|(c&63)); }
        else if (c < 0x10000) { out += static_cast<char>(0xe0|(c>>12)); out += static_cast<char>(0x80|((c>>6)&63)); out += static_cast<char>(0x80|(c&63)); }
        else { out += static_cast<char>(0xf0|(c>>18)); out += static_cast<char>(0x80|((c>>12)&63)); out += static_cast<char>(0x80|((c>>6)&63)); out += static_cast<char>(0x80|(c&63)); }
    }
    return out;
}
}
struct InputCallbacks {
    template<typename Fn> static void with(InputMethod_TextEditorProxy* editor,Fn fn) noexcept {
        try { std::lock_guard<std::mutex> lock(editorsMutex); auto found = editors.find(editor); if (found != editors.end()) fn(*found->second); }
        catch (...) { /* submit converts queue failure to an observable event */ }
    }
    static void config(InputMethod_TextEditorProxy* editor,InputMethod_TextConfig* config) {
        with(editor,[&](TerminalInput& self) {
            OH_TextConfig_SetInputType(config,self.masked_ ? IME_TEXT_INPUT_TYPE_VISIBLE_PASSWORD : IME_TEXT_INPUT_TYPE_TEXT);
            OH_TextConfig_SetPreviewTextSupport(config,!self.masked_); OH_TextConfig_SetSelection(config,0,0);
            InputMethod_CursorInfo* cursor = nullptr; OH_TextConfig_GetCursorInfo(config,&cursor);
            OH_CursorInfo_SetRect(cursor,self.x_,self.y_,1,self.height_);
        });
    }
    static void insert(InputMethod_TextEditorProxy* editor,const char16_t* text,size_t length) {
        with(editor,[&](TerminalInput& self) {
            if (!text || length > 4096) { self.submit_(GHOSTTY_KEY_UNIDENTIFIED,{},self.owner_); return; }
            self.preview_.clear(); self.previewChanged_({},self.owner_);
            self.submit_(GHOSTTY_KEY_UNIDENTIFIED,utf8(text,length),self.owner_);
        });
    }
    static void key(InputMethod_TextEditorProxy* editor,GhosttyKey key,int32_t count = 1) {
        with(editor,[&](TerminalInput& self) {
            if (count < 0 || count > 128) { self.submit_(GHOSTTY_KEY_UNIDENTIFIED,{},self.owner_); return; }
            for (int32_t i = 0; i < count; ++i) self.submit_(key,{},self.owner_);
        });
    }
    static int32_t preview(InputMethod_TextEditorProxy* editor,const char16_t* text,size_t length,int32_t start,int32_t end) {
        int32_t result = 401;
        with(editor,[&](TerminalInput& self) {
            if (self.masked_ || !text || length > 4096) return;
            if (start == -1 && end == -1) self.preview_.assign(text,length);
            else if (start >= 0 && end >= start && static_cast<size_t>(end) <= self.preview_.size() && self.preview_.size()-(end-start)+length <= 4096)
                self.preview_.replace(start,end-start,text,length);
            else return;
            self.previewChanged_(utf8(self.preview_.data(),self.preview_.size()),self.owner_);
            result = 0;
        }); return result;
    }
};
void TerminalInput::attach(ArkUI_ContextHandle context,uint32_t owner,double x,double y,double height,bool masked) {
    detach(); owner_ = owner; x_ = x; y_ = y; height_ = height; masked_ = masked;
    editor_ = OH_TextEditorProxy_Create(); if (!editor_) throw std::runtime_error("terminal_ime_create_failed");
    { std::lock_guard<std::mutex> lock(editorsMutex); editors[editor_] = this; }
    OH_TextEditorProxy_SetGetTextConfigFunc(editor_,InputCallbacks::config);
    OH_TextEditorProxy_SetInsertTextFunc(editor_,InputCallbacks::insert);
    OH_TextEditorProxy_SetSetPreviewTextFunc(editor_,InputCallbacks::preview);
    OH_TextEditorProxy_SetFinishTextPreviewFunc(editor_,[](InputMethod_TextEditorProxy* e) { InputCallbacks::with(e,[](TerminalInput& s) {
        s.preview_.clear(); s.previewChanged_({},s.owner_);
    }); });
    OH_TextEditorProxy_SetDeleteForwardFunc(editor_,[](InputMethod_TextEditorProxy* e,int32_t n) { InputCallbacks::key(e,GHOSTTY_KEY_DELETE,n); });
    OH_TextEditorProxy_SetDeleteBackwardFunc(editor_,[](InputMethod_TextEditorProxy* e,int32_t n) { InputCallbacks::key(e,GHOSTTY_KEY_BACKSPACE,n); });
    OH_TextEditorProxy_SetSendEnterKeyFunc(editor_,[](InputMethod_TextEditorProxy* e,InputMethod_EnterKeyType) { InputCallbacks::key(e,GHOSTTY_KEY_ENTER); });
    OH_TextEditorProxy_SetMoveCursorFunc(editor_,[](InputMethod_TextEditorProxy* e,InputMethod_Direction d) {
        if (d == IME_DIRECTION_UP) InputCallbacks::key(e,GHOSTTY_KEY_ARROW_UP);
        if (d == IME_DIRECTION_DOWN) InputCallbacks::key(e,GHOSTTY_KEY_ARROW_DOWN);
        if (d == IME_DIRECTION_LEFT) InputCallbacks::key(e,GHOSTTY_KEY_ARROW_LEFT);
        if (d == IME_DIRECTION_RIGHT) InputCallbacks::key(e,GHOSTTY_KEY_ARROW_RIGHT);
    });
    OH_TextEditorProxy_SetSendKeyboardStatusFunc(editor_,[](InputMethod_TextEditorProxy*,InputMethod_KeyboardStatus) {});
    OH_TextEditorProxy_SetHandleSetSelectionFunc(editor_,[](InputMethod_TextEditorProxy*,int32_t,int32_t) {});
    OH_TextEditorProxy_SetHandleExtendActionFunc(editor_,[](InputMethod_TextEditorProxy*,InputMethod_ExtendAction) {});
    OH_TextEditorProxy_SetGetLeftTextOfCursorFunc(editor_,[](InputMethod_TextEditorProxy*,int32_t,char16_t[],size_t* n) { *n = 0; });
    OH_TextEditorProxy_SetGetRightTextOfCursorFunc(editor_,[](InputMethod_TextEditorProxy*,int32_t,char16_t[],size_t* n) { *n = 0; });
    OH_TextEditorProxy_SetGetTextIndexAtCursorFunc(editor_,[](InputMethod_TextEditorProxy*) -> int32_t { return 0; });
    OH_TextEditorProxy_SetReceivePrivateCommandFunc(editor_,[](InputMethod_TextEditorProxy*,InputMethod_PrivateCommand*[],size_t) -> int32_t { return 0; });
    auto options = OH_AttachOptions_Create(false);
    const auto result = OH_InputMethodController_AttachWithUIContext(context,editor_,options,&proxy_);
    OH_AttachOptions_Destroy(options);
    if (result != 0) { detach(); throw std::runtime_error("terminal_ime_attach_failed"); }
}
void TerminalInput::cursor(uint32_t owner,double x,double y,double height) {
    {
        std::lock_guard<std::mutex> lock(editorsMutex);
        if (!editor_ || owner != owner_) return;
        x_ = x; y_ = y; height_ = height;
    }
    if (!proxy_) return;
    auto info = OH_CursorInfo_Create(x,y,1,height);
    if (!info) throw std::runtime_error("terminal_ime_cursor_create_failed");
    const auto result = OH_InputMethodProxy_NotifyCursorUpdate(proxy_,info);
    OH_CursorInfo_Destroy(info);
    if (result != 0) throw std::runtime_error("terminal_ime_cursor_update_failed");
}
void TerminalInput::detach() {
    // Invalidate dispatch before detaching the platform object. An in-flight
    // callback completes under this mutex before the owner may be destroyed.
    { std::lock_guard<std::mutex> lock(editorsMutex); if (editor_) editors.erase(editor_); }
    if (proxy_) OH_InputMethodController_Detach(proxy_);
    proxy_ = nullptr;
    if (editor_) OH_TextEditorProxy_Destroy(editor_);
    editor_ = nullptr; preview_.clear();
}
}

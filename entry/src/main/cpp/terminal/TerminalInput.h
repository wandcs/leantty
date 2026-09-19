#pragma once
#include <arkui/native_type.h>
#include <inputmethod/inputmethod_controller_capi.h>
#include <ghostty/vt.h>
#include <functional>
#include <string>

namespace leantty {
class TerminalInput final {
public:
    using Submit = std::function<void(GhosttyKey,std::string,uint32_t)>;
    using Preview = std::function<void(std::string,uint32_t)>;
    explicit TerminalInput(Submit submit,Preview preview) : submit_(std::move(submit)),previewChanged_(std::move(preview)) {}
    ~TerminalInput() { detach(); }
    void attach(ArkUI_ContextHandle context,uint32_t owner,double x,double y,double height,bool masked);
    void detach();
    void cursor(uint32_t owner,double x,double y,double height);
private:
    friend struct InputCallbacks;
    Submit submit_;
    Preview previewChanged_;
    InputMethod_TextEditorProxy* editor_ = nullptr;
    InputMethod_InputMethodProxy* proxy_ = nullptr;
    uint32_t owner_ = 0;
    bool masked_ = false;
    std::u16string preview_;
    double x_ = 0,y_ = 0,height_ = 20;
};
}

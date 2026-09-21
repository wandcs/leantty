#include "TerminalRuntime.h"
#include "TerminalRenderer.h"
#include "TerminalInput.h"
#include <arkui/native_node_napi.h>
#include <napi/native_api.h>
#include <memory>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace leantty {
namespace {
void check(napi_status status) { if (status != napi_ok) throw std::runtime_error("terminal_napi_failed"); }
napi_value undefined(napi_env env) { napi_value value; check(napi_get_undefined(env,&value)); return value; }
napi_value number(napi_env env, double value) { napi_value result; check(napi_create_double(env,value,&result)); return result; }
napi_value string(napi_env env, const std::string& value) { napi_value result; check(napi_create_string_utf8(env,value.data(),value.size(),&result)); return result; }
double numeric(napi_env env,napi_value value,double min,double max) {
    double result = 0; check(napi_get_value_double(env,value,&result));
    if (!std::isfinite(result) || result < min || result > max || std::floor(result) != result)
        throw std::runtime_error("terminal_argument_bounds");
    return result;
}
std::vector<uint8_t> bytes(napi_env env,napi_value value,size_t limit) {
    void* data = nullptr; size_t size = 0; check(napi_get_arraybuffer_info(env,value,&data,&size));
    if (!data || !size || size > limit) throw std::runtime_error("terminal_buffer_bounds");
    return {static_cast<uint8_t*>(data),static_cast<uint8_t*>(data)+size};
}
std::string textArgument(napi_env env,napi_value value,size_t limit) {
    size_t size = 0; check(napi_get_value_string_utf8(env,value,nullptr,0,&size));
    if (size > limit) throw std::runtime_error("terminal_text_bounds");
    std::string text(size+1,'\0'); check(napi_get_value_string_utf8(env,value,text.data(),text.size(),&size));
    text.resize(size); return text;
}
struct Binding {
    napi_threadsafe_function sink = nullptr;
    std::unique_ptr<TerminalRenderer> renderer;
    std::unique_ptr<TerminalRuntime> runtime;
    std::unique_ptr<TerminalInput> input;
    bool closing = false;
    uint32_t displayGeneration = 0; // worker-owned, tags queued presentation events
    bool emit(TerminalEvent event) {
        auto owned = std::make_unique<TerminalEvent>(std::move(event));
        if (napi_call_threadsafe_function(sink,owned.get(),napi_tsfn_nonblocking) != napi_ok) return false;
        owned.release(); return true;
    }
    void release() {
        closing = true;
        input.reset();
        if (runtime) { runtime->close(); runtime->join(); runtime.reset(); }
        renderer.reset();
        // The callback retains the controller and its handle. Break this cycle
        // after the worker stops, including when async close admission fails.
        if (sink) { napi_release_threadsafe_function(sink,napi_tsfn_release); sink = nullptr; }
    }
    ~Binding() { release(); }
};
void callJs(napi_env env,napi_value callback,void*,void* data) {
    std::unique_ptr<TerminalEvent> event(static_cast<TerminalEvent*>(data));
    if (!env || !callback) return;
    try {
        napi_value args[] = {string(env,event->kind),number(env,event->sequence),number(env,event->owner),string(env,event->text)};
        napi_value result; check(napi_call_function(env,undefined(env),callback,4,args,&result));
    } catch (...) { /* N-API retains any pending JS exception; never cross C. */ }
}
struct Arguments {
    napi_env env; napi_value values[8]{}; size_t count = 8;
    Arguments(napi_env e,napi_callback_info info,size_t expected) : env(e) {
        check(napi_get_cb_info(env,info,&count,values,nullptr,nullptr));
        if (count != expected) throw std::runtime_error("terminal_argument_count");
    }
    Binding& binding() {
        Binding* result = nullptr; check(napi_unwrap(env,values[0],reinterpret_cast<void**>(&result)));
        if (!result || !result->runtime || result->closing) throw std::runtime_error("terminal_closed");
        return *result;
    }
    uint32_t owner(size_t index) { return static_cast<uint32_t>(numeric(env,values[index],0,UINT32_MAX)); }
};
template<napi_value (*Operation)(napi_env,napi_callback_info)>
napi_value guarded(napi_env env,napi_callback_info info) {
    try { return Operation(env,info); }
    catch (...) { napi_throw_error(env,"TERMINAL_NATIVE","Native terminal operation failed."); return nullptr; }
}
napi_value create(napi_env env,napi_callback_info info) {
    Arguments args(env,info,3);
    auto regular = bytes(env,args.values[0],32*1024*1024), bold = bytes(env,args.values[1],32*1024*1024);
    auto binding = std::make_unique<Binding>(); auto* b = binding.get();
    check(napi_create_threadsafe_function(env,args.values[2],nullptr,string(env,"LeanTTYTerminal"),4096,1,
        nullptr,nullptr,nullptr,callJs,&b->sink));
    b->renderer = std::make_unique<TerminalRenderer>([b](const std::string& state,const std::string& text) { b->emit({state,0,b->displayGeneration,text}); });
    b->runtime = std::make_unique<TerminalRuntime>([b](TerminalEvent e) { return b->emit(std::move(e)); },
        [b](GhosttyTerminal t,GhosttySearch search,const std::vector<uint32_t>& overview,const TerminalLink& link,bool focused,bool blinkOn) {
            b->renderer->draw(t,search,overview,link,focused,blinkOn);
        }, [b] { b->renderer->shutdown(); });
    b->input = std::make_unique<TerminalInput>([b](GhosttyKey key,std::string text,uint32_t owner) {
        if ((key == GHOSTTY_KEY_UNIDENTIFIED && text.empty()) || !b->runtime->key(key,0,std::move(text),owner))
            b->emit({"failure",0,owner,"terminal_input_rejected"});
    },[b](std::string text,uint32_t owner) { b->emit({"preedit",0,owner,std::move(text)}); });
    if (!b->runtime->updateDisplay([b,regular=std::move(regular),bold=std::move(bold)]() mutable {
        b->renderer->fonts(std::move(regular),std::move(bold));
        return TerminalRuntime::Geometry{};
    })) throw std::runtime_error("terminal_font_admission");
    napi_value result; check(napi_create_object(env,&result));
    check(napi_wrap(env,result,b,[](napi_env,void* data,void*) { delete static_cast<Binding*>(data); },nullptr,nullptr));
    binding.release();
    return result;
}
napi_value write(napi_env env,napi_callback_info info) {
    Arguments args(env,info,3); auto& b = args.binding();
    auto data = bytes(env,args.values[1],TerminalRuntime::ChunkLimit);
    return number(env,b.runtime->write(data.data(),data.size(),args.owner(2)));
}
napi_value barrier(napi_env env,napi_callback_info info) {
    Arguments args(env,info,2); return number(env,args.binding().runtime->barrier(args.owner(1)));
}
napi_value positionSessionOutput(napi_env env,napi_callback_info info) {
    Arguments args(env,info,1); return number(env,args.binding().runtime->positionSessionOutput());
}
napi_value page(napi_env env,napi_callback_info info) {
    Arguments args(env,info,3); auto& b = args.binding(); bool begin = false; check(napi_get_value_bool(env,args.values[1],&begin));
    return number(env,begin ? b.runtime->beginTemporary(args.owner(2)) : b.runtime->endTemporary(args.owner(2)));
}
napi_value attach(napi_env env,napi_callback_info info) {
    Arguments args(env,info,8); auto* b = &args.binding();
    size_t count = 0; check(napi_get_value_string_utf8(env,args.values[1],nullptr,0,&count));
    if (!count || count > 20) throw std::runtime_error("terminal_surface_id");
    std::string id(count+1,'\0'); check(napi_get_value_string_utf8(env,args.values[1],id.data(),id.size(),&count)); id.resize(count);
    if (id.find_first_not_of("0123456789") != std::string::npos) throw std::runtime_error("terminal_surface_id");
    uint64_t surface = std::stoull(id);
    const int width = numeric(env,args.values[2],1,16384),height = numeric(env,args.values[3],1,16384);
    const float size = numeric(env,args.values[4],8,96);
    const uint32_t generation = args.owner(5);
    const int inset = numeric(env,args.values[6],0,256);
    const int cursorStroke = numeric(env,args.values[7],1,16);
    auto sequence = b->runtime->updateDisplay([b,surface,width,height,size,generation,inset,cursorStroke] {
        b->displayGeneration = generation;
        if (!b->renderer->attach(surface,width,height,size,inset,cursorStroke)) {
            // A rejected platform Surface is recoverable display state, not a
            // failure of the worker's VT or its connected Session.
            if (!b->emit({"surface-unavailable",0,generation,{}}))
                throw std::runtime_error("terminal_event_queue_failed");
            return TerminalRuntime::Geometry{};
        }
        // Commit dimensions as part of this ordered command, before the first
        // frame or any following bytes. Do not append a resize behind output.
        const auto grid = b->renderer->grid();
        if (!b->emit({"metrics",0,generation,std::to_string(static_cast<int>(size))+","+
            std::to_string(inset)+","+std::to_string(grid.cellWidth)+","+std::to_string(grid.cellHeight)}))
            throw std::runtime_error("terminal_event_queue_failed");
        return grid;
    });
    return number(env,sequence);
}
napi_value detach(napi_env env,napi_callback_info info) {
    Arguments args(env,info,1); auto* b = &args.binding();
    b->input->detach();
    return number(env,b->runtime->updateDisplay([b] { b->renderer->detach(); return TerminalRuntime::Geometry{}; }));
}
GhosttyKey keyCode(uint32_t code) {
    if (code >= 2017 && code <= 2042) return static_cast<GhosttyKey>(GHOSTTY_KEY_A+code-2017);
    if (code >= 2000 && code <= 2009) return static_cast<GhosttyKey>(GHOSTTY_KEY_DIGIT_0+code-2000);
    if (code >= 2090 && code <= 2101) return static_cast<GhosttyKey>(GHOSTTY_KEY_F1+code-2090);
    switch (code) {
        case 2012:return GHOSTTY_KEY_ARROW_UP; case 2013:return GHOSTTY_KEY_ARROW_DOWN;
        case 2014:return GHOSTTY_KEY_ARROW_LEFT; case 2015:return GHOSTTY_KEY_ARROW_RIGHT;
        case 2049:return GHOSTTY_KEY_TAB; case 2054:return GHOSTTY_KEY_ENTER;
        case 2055:return GHOSTTY_KEY_BACKSPACE; case 2070:return GHOSTTY_KEY_ESCAPE;
        case 2071:return GHOSTTY_KEY_DELETE; case 2081:return GHOSTTY_KEY_HOME;
        case 2082:return GHOSTTY_KEY_END; case 2068:return GHOSTTY_KEY_PAGE_UP;
        case 2069:return GHOSTTY_KEY_PAGE_DOWN; case 2083:return GHOSTTY_KEY_INSERT;
        case 2050:return GHOSTTY_KEY_SPACE; case 2043:return GHOSTTY_KEY_COMMA;
        case 2044:return GHOSTTY_KEY_PERIOD; case 2056:return GHOSTTY_KEY_BACKQUOTE;
        case 2057:return GHOSTTY_KEY_MINUS; case 2058:return GHOSTTY_KEY_EQUAL;
        case 2059:return GHOSTTY_KEY_BRACKET_LEFT; case 2060:return GHOSTTY_KEY_BRACKET_RIGHT;
        case 2061:return GHOSTTY_KEY_BACKSLASH; case 2062:return GHOSTTY_KEY_SEMICOLON;
        case 2063:return GHOSTTY_KEY_QUOTE; case 2064:return GHOSTTY_KEY_SLASH;
        default:return GHOSTTY_KEY_UNIDENTIFIED;
    }
}
napi_value key(napi_env env,napi_callback_info info) {
    Arguments args(env,info,6); auto& b = args.binding();
    return number(env,b.runtime->key(keyCode(args.owner(1)),numeric(env,args.values[2],0,15),textArgument(env,args.values[4],16384),args.owner(3),numeric(env,args.values[5],0,0x10ffff)));
}
napi_value paste(napi_env env,napi_callback_info info) {
    Arguments args(env,info,3); return number(env,args.binding().runtime->paste(textArgument(env,args.values[1],TerminalRuntime::QueueLimit),args.owner(2)));
}
napi_value focus(napi_env env,napi_callback_info info) {
    Arguments args(env,info,2); bool focused = false; check(napi_get_value_bool(env,args.values[1],&focused));
    return number(env,args.binding().runtime->focus(focused));
}
napi_value visibility(napi_env env,napi_callback_info info) {
    Arguments args(env,info,3); auto* b = &args.binding(); bool visible = false;
    check(napi_get_value_bool(env,args.values[1],&visible));
    const uint32_t generation = args.owner(2);
    return number(env,b->runtime->visibility(visible,[b,generation] {
        b->displayGeneration = generation;
    }));
}
napi_value pointer(napi_env env,napi_callback_info info) {
    Arguments args(env,info,7); return number(env,args.binding().runtime->pointer(numeric(env,args.values[1],0,2),
        numeric(env,args.values[2],0,3),numeric(env,args.values[3],-16384,32768),numeric(env,args.values[4],-16384,32768),
        numeric(env,args.values[5],0,15),args.owner(6)));
}
napi_value scroll(napi_env env,napi_callback_info info) {
    Arguments args(env,info,4); bool local = false; check(napi_get_value_bool(env,args.values[3],&local));
    return number(env,args.binding().runtime->scroll(numeric(env,args.values[1],-256,256),args.owner(2),local));
}
napi_value hover(napi_env env,napi_callback_info info) {
    Arguments args(env,info,3);
    return number(env,args.binding().runtime->hover(numeric(env,args.values[1],-1,15),args.owner(2)));
}
napi_value copy(napi_env env,napi_callback_info info) {
    Arguments args(env,info,4); return number(env,args.binding().runtime->copy(numeric(env,args.values[1],0,3),args.owner(2),numeric(env,args.values[3],0,9007199254740991.0)));
}
napi_value search(napi_env env,napi_callback_info info) {
    Arguments args(env,info,4); return number(env,args.binding().runtime->search(textArgument(env,args.values[1],TerminalRuntime::SearchLimit),numeric(env,args.values[2],-1,1),args.owner(3)));
}
napi_value cursor(napi_env env,napi_callback_info info) {
    Arguments args(env,info,5); args.binding().input->cursor(args.owner(1),numeric(env,args.values[2],-32768,32768),
        numeric(env,args.values[3],-32768,32768),numeric(env,args.values[4],1,256)); return undefined(env);
}
napi_value ime(napi_env env,napi_callback_info info) {
    Arguments args(env,info,7); auto& b = args.binding();
    bool masked = false; check(napi_get_value_bool(env,args.values[6],&masked));
    ArkUI_ContextHandle context = nullptr;
    if (OH_ArkUI_GetContextFromNapiValue(env,args.values[1],&context) != 0 || !context) throw std::runtime_error("terminal_ui_context");
    b.input->attach(context,args.owner(2),numeric(env,args.values[3],-16384,16384),numeric(env,args.values[4],-16384,16384),numeric(env,args.values[5],1,256),masked);
    return undefined(env);
}
napi_value blur(napi_env env,napi_callback_info info) {
    Arguments args(env,info,1); args.binding().input->detach(); return undefined(env);
}
struct Close {
    napi_env env;
    Binding* binding = nullptr;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    napi_ref retained = nullptr;
    explicit Close(napi_env value) : env(value) {}
    ~Close() {
        if (work) napi_delete_async_work(env,work);
        if (retained) napi_delete_reference(env,retained);
    }
};
napi_value close(napi_env env,napi_callback_info info) {
    Arguments args(env,info,1); auto& b = args.binding();
    try {
        auto job = std::make_unique<Close>(env); job->binding = &b;
        napi_value promise; check(napi_create_promise(env,&job->deferred,&promise));
        check(napi_create_reference(env,args.values[0],1,&job->retained));
        check(napi_create_async_work(env,nullptr,string(env,"CloseLeanTTYTerminal"),
            [](napi_env,void* data) { static_cast<Close*>(data)->binding->runtime->join(); },
            [](napi_env env,napi_status status,void* data) {
                std::unique_ptr<Close> job(static_cast<Close*>(data));
                job->binding->release();
                napi_value value; napi_get_undefined(env,&value);
                if (status == napi_ok) napi_resolve_deferred(env,job->deferred,value);
                else napi_reject_deferred(env,job->deferred,value);
            },job.get(),&job->work));
        b.input->detach(); b.closing = true; b.runtime->close(); check(napi_queue_async_work(env,job->work)); job.release(); return promise;
    } catch (...) {
        // No async owner was admitted. Finish teardown now rather than leave a
        // stopped worker and a callback cycle waiting for an unreachable GC.
        b.release();
        throw;
    }
}
napi_value init(napi_env env,napi_value exports) {
    const napi_property_descriptor properties[] = {
        {"create",nullptr,guarded<create>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"write",nullptr,guarded<write>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"barrier",nullptr,guarded<barrier>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"positionSessionOutput",nullptr,guarded<positionSessionOutput>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"page",nullptr,guarded<page>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"attach",nullptr,guarded<attach>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"detach",nullptr,guarded<detach>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"key",nullptr,guarded<key>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"paste",nullptr,guarded<paste>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"pointer",nullptr,guarded<pointer>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"hover",nullptr,guarded<hover>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"scroll",nullptr,guarded<scroll>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"copy",nullptr,guarded<copy>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"search",nullptr,guarded<search>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"cursor",nullptr,guarded<cursor>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"focus",nullptr,guarded<focus>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"visibility",nullptr,guarded<visibility>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"ime",nullptr,guarded<ime>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"blur",nullptr,guarded<blur>,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"close",nullptr,guarded<close>,nullptr,nullptr,nullptr,napi_default,nullptr}
    };
    if (napi_define_properties(env,exports,sizeof(properties)/sizeof(properties[0]),properties) != napi_ok) return nullptr;
    return exports;
}
}
}
static napi_module terminalModule = {1,0,nullptr,leantty::init,"leantty_terminal",nullptr,{0}};
extern "C" __attribute__((constructor)) void RegisterLeanTTYTerminal() { napi_module_register(&terminalModule); }

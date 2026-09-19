#include <memory>
#include <string>
#include <stdexcept>
#include <cstdio>
#include <vector>

// Compile the production owner and close operation against deterministic N-API
// admission failures. These stubs model ownership, not a second close algorithm.
using napi_env = void*;
using napi_value = void*;
using napi_ref = void*;
using napi_deferred = void*;
using napi_async_work = void*;
using napi_threadsafe_function = void*;
using napi_callback_info = void*;
using napi_status = int;
constexpr int napi_ok = 0, napi_tsfn_release = 0, napi_tsfn_nonblocking = 0;
static int failAt = 0, stage = 0, refs = 0, works = 0, sinks = 0, resolved = 0, rejected = 0;
static void (*executeWork)(napi_env,void*) = nullptr;
static void (*completeWork)(napi_env,napi_status,void*) = nullptr;
static void* workData = nullptr;
static std::vector<std::string> events;
static napi_status admission() { return ++stage == failAt ? 1 : napi_ok; }
static void check(napi_status status) { if (status != napi_ok) throw std::runtime_error("napi failure"); }
static napi_value string(napi_env,const std::string&) { check(admission()); return reinterpret_cast<void*>(1); }
static napi_status napi_create_promise(napi_env,napi_deferred* deferred,napi_value* value) {
    auto status=admission(); if (!status) *deferred=*value=reinterpret_cast<void*>(1); return status;
}
static napi_status napi_create_reference(napi_env,napi_value,int,napi_ref* ref) {
    auto status=admission(); if (!status) { *ref=reinterpret_cast<void*>(1); ++refs; } return status;
}
static napi_status napi_create_async_work(napi_env,napi_value,napi_value,
    void (*execute)(napi_env,void*),void (*complete)(napi_env,napi_status,void*),void* data,napi_async_work* work) {
    auto status=admission(); if (!status) {
        *work=reinterpret_cast<void*>(1); ++works; executeWork=execute; completeWork=complete; workData=data;
    } return status;
}
static napi_status napi_queue_async_work(napi_env,napi_async_work) { return admission(); }
static napi_status napi_delete_async_work(napi_env,napi_async_work) { --works; return 0; }
static napi_status napi_delete_reference(napi_env,napi_ref) { --refs; return 0; }
static napi_status napi_release_threadsafe_function(napi_threadsafe_function,int) { --sinks; events.push_back("sink"); return 0; }
static napi_status napi_call_threadsafe_function(napi_threadsafe_function,void*,int) { return 1; }
static napi_status napi_get_undefined(napi_env,napi_value* value) { *value=nullptr; return 0; }
static napi_status napi_resolve_deferred(napi_env,napi_deferred,napi_value) { ++resolved; return 0; }
static napi_status napi_reject_deferred(napi_env,napi_deferred,napi_value) { ++rejected; return 0; }
struct TerminalEvent {};
struct TerminalInput {
    void detach() { events.push_back("detach"); }
    ~TerminalInput() { events.push_back("input"); }
};
struct TerminalRenderer { ~TerminalRenderer() { events.push_back("renderer"); } };
struct TerminalRuntime {
    bool stopped=false,joined=false;
    void close() { stopped=true; }
    void join() { if (!stopped) throw std::runtime_error("join before close"); joined=true; events.push_back("join"); }
    ~TerminalRuntime() { if (!joined) std::terminate(); events.push_back("runtime"); }
};
#include "binding-owner-under-test.inc"
static Binding* current = nullptr;
struct Arguments {
    napi_value values[1]{};
    Arguments(napi_env,napi_callback_info,size_t) {}
    Binding& binding() { return *current; }
};
#include "binding-close-under-test.inc"
static void require(bool value,const char* message) { if (!value) throw std::runtime_error(message); }
static void run(int failure,int completionStatus=0) {
    failAt=failure; stage=refs=works=sinks=resolved=rejected=0; events.clear();
    Binding binding; current=&binding;
    binding.sink=reinterpret_cast<void*>(1); ++sinks;
    binding.input=std::make_unique<TerminalInput>();
    binding.renderer=std::make_unique<TerminalRenderer>();
    binding.runtime=std::make_unique<TerminalRuntime>();
    bool threw=false;
    try { close(nullptr,nullptr); } catch (...) { threw=true; }
    if (!failure) {
        require(!threw && refs==1 && works==1 && sinks==1,"normal close must retain callback until worker completes");
        // Cancellation can complete without the worker execute callback.
        if (!completionStatus) executeWork(nullptr,workData);
        completeWork(nullptr,completionStatus,workData);
        require(resolved==(completionStatus==0) && rejected==(completionStatus!=0),"completion outcome lost");
    } else { require(threw,"admission failure must stay observable"); }
    require(!binding.runtime && !binding.input && !binding.renderer && !binding.sink,
        "close failure retained Binding resources and callback cycle");
    require(refs==0 && works==0 && sinks==0,"close leaked work/reference/callback");
    auto at=[&](const char* value) { for(size_t i=0;i<events.size();++i) if(events[i]==value) return i; return events.size(); };
    require(at("join")<at("runtime") && at("runtime")<at("renderer") && at("renderer")<at("sink"),"release order violated");
}
int main() {
    try {
        for(int failure=1;failure<=5;++failure) run(failure);
        run(0); run(0,1);
        std::puts("PASS binding close releases resources on five admission failures and both completion outcomes");
        return 0;
    } catch(const std::exception& error) { std::fprintf(stderr,"FAIL %s\n",error.what()); return 1; }
}

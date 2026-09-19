// Execute production draw/releaseGpu with only GPU and paint boundaries replaced.
#include <algorithm>
#include <functional>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
using EGLDisplay = int;
using EGLConfig = void*;
using EGLContext = int;
using EGLSurface = int;
using GhosttyTerminal = void*;
using GhosttySearch = void*;
struct TerminalLink {};
constexpr int EGL_NO_DISPLAY = 0, EGL_NO_CONTEXT = 0, EGL_NO_SURFACE = 0;
constexpr int EGL_SUCCESS = 0x3000, EGL_NOT_INITIALIZED = 0x3001;
constexpr int EGL_BAD_ACCESS = 0x3002, EGL_BAD_NATIVE_WINDOW = 0x300b;
constexpr int EGL_BAD_SURFACE = 0x300d, EGL_CONTEXT_LOST = 0x300e;
static int error = EGL_SUCCESS, nextResource = 0, deletes = 0, swaps = 0;
static std::vector<int> swapErrors, createErrors, destroyedContexts, destroyedSurfaces;
static int eglGetError() { auto result = error; error = EGL_SUCCESS; return result; }
static bool eglMakeCurrent(int, int, int, int) { return true; }
static bool eglSwapBuffers(int, int) {
    ++swaps;
    if (swapErrors.empty()) return true;
    error = swapErrors.front(); swapErrors.erase(swapErrors.begin());
    return error == EGL_SUCCESS;
}
static void eglDestroyContext(int, int value) { destroyedContexts.push_back(value); }
static void eglDestroySurface(int, int value) { destroyedSurfaces.push_back(value); }
static void glDeleteProgram(unsigned) { ++deletes; }
static void glDeleteTextures(int, unsigned*) { ++deletes; }
static void glDeleteBuffers(int, unsigned*) { ++deletes; }
static void glDeleteVertexArrays(int, unsigned*) { ++deletes; }
class TerminalRenderer {
public:
    void draw(GhosttyTerminal, GhosttySearch, const std::vector<uint32_t>&, const TerminalLink&, bool, bool) noexcept;
    void releaseGpu(bool lost = false);
    void createGpu() {
        ++creates;
        initializedFrom.push_back(display_);
        if (!createErrors.empty()) {
            error = createErrors.front(); createErrors.erase(createErrors.begin());
            throw std::runtime_error("driver initialize failed");
        }
        display_ = 1; config_ = this;
        context_ = ++nextResource; surface_ = ++nextResource;
        program_ = texture_ = vao_ = vbo_ = 1;
    }
    void paint(GhosttyTerminal terminal, GhosttySearch, const std::vector<uint32_t>&, const TerminalLink&, bool, bool) {
        if (terminal != expectedTerminal) throw std::runtime_error("VT identity changed");
        ++paints;
        glyphs_[1] = 1; vertices_.push_back(1);
    }
    void* window_ = this;
    bool unavailable_ = false;
    EGLDisplay display_ = 0;
    EGLConfig config_ = nullptr;
    EGLContext context_ = 0;
    EGLSurface surface_ = 0;
    unsigned program_ = 0, texture_ = 0, vao_ = 0, vbo_ = 0;
    std::map<int,int> glyphs_;
    std::vector<int> vertices_, initializedFrom;
    std::string cursorGeometry_ = "10,20,30";
    std::vector<std::string> events;
    std::function<void(const std::string&,const std::string&)> status_ =
        [this](const std::string& kind, const std::string&) { events.push_back(kind); };
    int creates = 0, paints = 0;
    GhosttyTerminal expectedTerminal = this;
};
#include "renderer-recovery-under-test.inc"
static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static void reset() {
    error = EGL_SUCCESS; nextResource = deletes = swaps = 0;
    swapErrors.clear(); createErrors.clear(); destroyedContexts.clear(); destroyedSurfaces.clear();
}
int main() {
    try {
        for (int fault : {EGL_CONTEXT_LOST, EGL_BAD_SURFACE, EGL_NOT_INITIALIZED}) {
            reset(); TerminalRenderer renderer;
            swapErrors = {fault}; renderer.draw(&renderer,nullptr, {}, {}, true, true);
            require(renderer.creates == 2 && renderer.paints == 2 && swaps == 2, "one bounded GPU retry");
            require(renderer.events == std::vector<std::string>{"cursor","presented"}, "only successful swap presents");
            require(!renderer.unavailable_, "transient fault recovered");
            require(destroyedContexts == std::vector<int>{1} && destroyedSurfaces == std::vector<int>{2}, "old GPU handles destroyed");
            require(deletes == (fault == EGL_CONTEXT_LOST ? 0 : 4), "lost context skips GL deletes");
            require(renderer.initializedFrom[1] == (fault == EGL_NOT_INITIALIZED ? 0 : 1), "display invalidation is scoped");
            renderer.releaseGpu();
            require(destroyedContexts == std::vector<int>({1,3}) && destroyedSurfaces == std::vector<int>({2,4}), "replacement handles released once");
            require(renderer.glyphs_.empty() && renderer.vertices_.empty(), "GPU cache discarded");
        }
        reset(); TerminalRenderer renderer;
        swapErrors = {EGL_CONTEXT_LOST,EGL_CONTEXT_LOST}; renderer.draw(&renderer,nullptr,{},{},true,true);
        require(renderer.creates == 2 && renderer.unavailable_ && !renderer.context_, "retry exhaustion releases resources");
        require(renderer.events == std::vector<std::string>{"surface-unavailable"}, "exhaustion cannot report presentation");
        renderer.draw(&renderer,nullptr,{},{},true,true);
        require(renderer.creates == 2 && renderer.events.size() == 1, "unavailable draw cannot spin or repeat events");
        renderer.unavailable_ = false; // A new production attachment admits a new attempt.
        renderer.draw(&renderer,nullptr,{},{},true,true);
        require(renderer.creates == 3 && renderer.events.back() == "presented", "reattachment can recover retained VT");
        renderer.releaseGpu();
        for (int fault : {EGL_BAD_NATIVE_WINDOW,EGL_BAD_ACCESS}) {
            reset(); TerminalRenderer blocked; swapErrors = {fault}; blocked.draw(&blocked,nullptr,{},{},true,true);
            require(blocked.creates == 1 && blocked.unavailable_, "surface/ownership errors require upper-layer recovery");
        }
        reset(); TerminalRenderer initialize;
        createErrors = {EGL_NOT_INITIALIZED,EGL_NOT_INITIALIZED}; initialize.draw(&initialize,nullptr,{},{},true,true);
        require(initialize.creates == 2 && initialize.paints == 0 && initialize.unavailable_, "persistent initialize failure bounded");
        require(!initialize.display_ && !initialize.config_, "failed display is not retained");
        initialize.draw(&initialize,nullptr,{},{},true,true); require(initialize.creates == 2, "persistent failure stays bounded");
        std::cout << "PASS production EGL recovery, exhausted retries, unavailable admission and GPU cleanup\n";
        return 0;
    } catch (const std::exception& failure) { std::cerr << failure.what() << '\n'; return 1; }
}

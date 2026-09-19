#pragma once
#include "TerminalGrid.h"
#include "TerminalLink.h"
#include <ghostty/vt.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <native_window/external_window.h>
#include <native_drawing/drawing_font_collection.h>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace leantty {
// Owned by the terminal worker. A Surface can disappear without destroying VT.
class TerminalRenderer final {
public:
    explicit TerminalRenderer(std::function<void(const std::string&,const std::string&)> status) : status_(std::move(status)) {}
    void fonts(std::vector<uint8_t> regular, std::vector<uint8_t> bold);
    bool attach(uint64_t surfaceId, int width, int height, float fontSize, int inset, int cursorStroke);
    void detach();
    void draw(GhosttyTerminal terminal,GhosttySearch search,const std::vector<uint32_t>& overview,const TerminalLink& link,bool focused,bool blinkOn) noexcept;
    void shutdown();
    int cellWidth() const { return cellWidth_; }
    int cellHeight() const { return cellHeight_; }
    const TerminalGrid& grid() const { return grid_; }
    int cols() const { return grid_.cols; }
    int rows() const { return grid_.rows; }
private:
    int cursorStroke_ = 1;
    struct Glyph { int x, y, width, height; bool colored = false; };
    struct Vertex { float x, y, u, v, r, g, b, a, solid; };
    void createGpu();
    void releaseGpu(bool lost = false);
    void paint(GhosttyTerminal terminal,GhosttySearch search,const std::vector<uint32_t>& overview,const TerminalLink& link,bool focused,bool blinkOn);
    Glyph glyph(const std::string& text, int span, const GhosttyStyle& style);
    void quad(float x, float y, float w, float h, GhosttyColorRgb color, float alpha, const Glyph* glyph = nullptr);
    void flush();
    std::function<void(const std::string&,const std::string&)> status_;
    std::string cursorGeometry_;
    std::vector<uint8_t> regularFont_, boldFont_;
    OH_Drawing_FontCollection* fonts_ = nullptr;
    OHNativeWindow* window_ = nullptr;
    uint64_t surfaceId_ = 0;
    int width_ = 0, height_ = 0, cellWidth_ = 10, cellHeight_ = 20;
    float fontSize_ = 16;
    TerminalGrid grid_;
    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLConfig config_ = nullptr;
    EGLSurface surface_ = EGL_NO_SURFACE;
    EGLContext context_ = EGL_NO_CONTEXT;
    GLuint program_ = 0, texture_ = 0, vao_ = 0, vbo_ = 0;
    std::map<std::string, Glyph> glyphs_;
    std::vector<Vertex> vertices_;
    int atlasX_ = 0, atlasY_ = 0, atlasRow_ = 0;
    bool unavailable_ = false;
};
}

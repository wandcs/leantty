#include "TerminalRenderer.h"
#include "TerminalScrollbar.h"
#include "TerminalSearchHighlights.h"
#include "TerminalRuntime.h"
#include <native_drawing/drawing_bitmap.h>
#include <native_drawing/drawing_canvas.h>
#include <native_drawing/drawing_register_font.h>
#include <native_drawing/drawing_text_typography.h>
#include <native_drawing/drawing_text_line.h>
#include <cmath>
#include <cstddef>
#include <stdexcept>

namespace leantty {
namespace {
constexpr int AtlasSize = 2048;
GLuint shader(GLenum kind, const char* source) {
    auto value = glCreateShader(kind); glShaderSource(value, 1, &source, nullptr); glCompileShader(value);
    GLint compiled = 0; glGetShaderiv(value, GL_COMPILE_STATUS, &compiled);
    if (!compiled) { glDeleteShader(value); throw std::runtime_error("terminal_shader_failed"); }
    return value;
}
// All official text objects are confined to the same worker as the collection.
struct TextLine {
    OH_Drawing_TypographyStyle* paragraph = OH_Drawing_CreateTypographyStyle();
    OH_Drawing_TextStyle* style = OH_Drawing_CreateTextStyle();
    OH_Drawing_TypographyCreate* handler = nullptr;
    OH_Drawing_Typography* typography = nullptr;
    OH_Drawing_Array* lines = nullptr;
    OH_Drawing_TextLine* line = nullptr;
    TextLine(OH_Drawing_FontCollection* fonts, const std::string& text, float size, bool bold, bool italic) {
        const char* family[] = {"LeanTTYTerminal"};
        OH_Drawing_SetTextStyleFontFamilies(style, 1, family);
        OH_Drawing_SetTextStyleFontSize(style, size);
        OH_Drawing_SetTextStyleFontWeight(style, bold ? FONT_WEIGHT_700 : FONT_WEIGHT_400);
        OH_Drawing_SetTextStyleFontStyle(style, italic ? FONT_STYLE_ITALIC : FONT_STYLE_NORMAL);
        OH_Drawing_SetTextStyleColor(style, 0xffffffff);
        handler = OH_Drawing_CreateTypographyHandler(paragraph, fonts);
        OH_Drawing_TypographyHandlerPushTextStyle(handler, style);
        OH_Drawing_TypographyHandlerAddEncodedText(handler, text.data(), text.size(), TEXT_ENCODING_UTF8);
        OH_Drawing_TypographyHandlerPopTextStyle(handler);
        typography = OH_Drawing_CreateTypography(handler); OH_Drawing_TypographyLayout(typography, 4096);
        lines = OH_Drawing_TypographyGetTextLines(typography);
        if (OH_Drawing_GetDrawingArraySize(lines) == 1) line = OH_Drawing_GetTextLineByIndex(lines, 0);
    }
    ~TextLine() {
        OH_Drawing_DestroyTextLines(lines); OH_Drawing_DestroyTypography(typography);
        OH_Drawing_DestroyTypographyHandler(handler); OH_Drawing_DestroyTextStyle(style);
        OH_Drawing_DestroyTypographyStyle(paragraph);
    }
};
}
void TerminalRenderer::fonts(std::vector<uint8_t> regular, std::vector<uint8_t> bold) {
    if (fonts_) throw std::runtime_error("terminal_fonts_already_set");
    regularFont_ = std::move(regular); boldFont_ = std::move(bold);
    fonts_ = OH_Drawing_CreateSharedFontCollection();
    if (!fonts_ || OH_Drawing_RegisterFontBuffer(fonts_, "LeanTTYTerminal", regularFont_.data(), regularFont_.size()) != 0 ||
        OH_Drawing_RegisterFontBuffer(fonts_, "LeanTTYTerminal", boldFont_.data(), boldFont_.size()) != 0)
        throw std::runtime_error("terminal_fonts_failed");
}
bool TerminalRenderer::attach(uint64_t id, int width, int height, float size, int inset, int cursorStroke) {
    // Admit the full 48-vp user range through density four. The fixed atlas and
    // per-glyph bounds remain unchanged; do not silently shrink the user's font.
    if (!id || width < 1 || height < 1 || width > 16384 || height > 16384 || !std::isfinite(size) || size < 8 || size > 192 || inset < 0 || inset > 256 || cursorStroke < 1 || cursorStroke > 16)
        throw std::runtime_error("terminal_surface_bounds");
    if (id != surfaceId_) { detach(); surfaceId_ = id;
        if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(id, &window_) != 0) {
            window_ = nullptr; surfaceId_ = 0; unavailable_ = true; return false;
        }
    }
    width_ = width; height_ = height; cursorStroke_ = cursorStroke;
    if (fontSize_ != size || glyphs_.empty()) {
        fontSize_ = size;
        if (!fonts_) throw std::runtime_error("terminal_fonts_missing");
        TextLine measurement(fonts_, "M", size, false, false);
        if (!measurement.line) throw std::runtime_error("terminal_metrics_failed");
        double ascent = 0, descent = 0, leading = 0;
        cellWidth_ = std::max(1, static_cast<int>(std::ceil(OH_Drawing_TextLineGetTypographicBounds(measurement.line, &ascent, &descent, &leading))));
        cellHeight_ = std::max(1, static_cast<int>(std::ceil(std::abs(ascent) + std::abs(descent) + std::max(0.0, leading))));
        glyphs_.clear(); atlasX_ = atlasY_ = atlasRow_ = 0;
    }
    grid_ = TerminalGrid::fit(width_,height_,cellWidth_,cellHeight_,inset);
    unavailable_ = false;
    return true;
}
void TerminalRenderer::createGpu() {
    if (!window_) return;
    if (display_ == EGL_NO_DISPLAY) {
        auto candidate = eglGetDisplay(EGL_DEFAULT_DISPLAY); EGLint count = 0; EGLConfig config = nullptr;
        const EGLint attributes[] = {EGL_SURFACE_TYPE,EGL_WINDOW_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
        if (candidate == EGL_NO_DISPLAY || !eglInitialize(candidate, nullptr, nullptr) ||
            !eglChooseConfig(candidate, attributes, &config, 1, &count) || count != 1)
            throw std::runtime_error("terminal_egl_initialize_failed");
        display_ = candidate; config_ = config;
    }
    const EGLint attrs[] = {EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT, attrs);
    surface_ = eglCreateWindowSurface(display_, config_, reinterpret_cast<EGLNativeWindowType>(window_), nullptr);
    if (context_ == EGL_NO_CONTEXT || surface_ == EGL_NO_SURFACE || !eglMakeCurrent(display_, surface_, surface_, context_))
        throw std::runtime_error("terminal_egl_create_failed");
    const char* vertex = "#version 300 es\nlayout(location=0) in vec2 pos;layout(location=1) in vec2 texcoord;layout(location=2) in vec4 ink;layout(location=3) in float solid;uniform vec2 screen;out vec2 uv;out vec4 color;out float fill;void main(){gl_Position=vec4(pos.x/screen.x*2.-1.,1.-pos.y/screen.y*2.,0,1);uv=texcoord;color=ink;fill=solid;}";
    const char* fragment = "#version 300 es\nprecision highp float;uniform sampler2D atlas;in vec2 uv;in vec4 color;in float fill;out vec4 outColor;void main(){outColor=fill>.5?color:texture(atlas,uv)*color;}";
    auto vs = shader(GL_VERTEX_SHADER, vertex), fs = shader(GL_FRAGMENT_SHADER, fragment);
    program_ = glCreateProgram(); glAttachShader(program_, vs); glAttachShader(program_, fs); glLinkProgram(program_);
    glDeleteShader(vs); glDeleteShader(fs); GLint linked = 0; glGetProgramiv(program_, GL_LINK_STATUS, &linked);
    if (!linked) throw std::runtime_error("terminal_program_failed");
    glGenVertexArrays(1, &vao_); glBindVertexArray(vao_); glGenBuffers(1, &vbo_); glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    const int sizes[] = {2,2,4,1}; const size_t offsets[] = {offsetof(Vertex,x),offsetof(Vertex,u),offsetof(Vertex,r),offsetof(Vertex,solid)};
    for (GLuint i = 0; i < 4; ++i) { glEnableVertexAttribArray(i); glVertexAttribPointer(i,sizes[i],GL_FLOAT,GL_FALSE,sizeof(Vertex),reinterpret_cast<void*>(offsets[i])); }
    glGenTextures(1, &texture_); glBindTexture(GL_TEXTURE_2D, texture_);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,AtlasSize,AtlasSize,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
    glyphs_.clear(); atlasX_ = atlasY_ = atlasRow_ = 0;
}
void TerminalRenderer::releaseGpu(bool lost) {
    if (!lost && context_ != EGL_NO_CONTEXT && surface_ != EGL_NO_SURFACE && eglMakeCurrent(display_,surface_,surface_,context_)) {
        glDeleteProgram(program_); glDeleteTextures(1,&texture_); glDeleteBuffers(1,&vbo_); glDeleteVertexArrays(1,&vao_);
    }
    if (display_ != EGL_NO_DISPLAY) {
        eglMakeCurrent(display_,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
        if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_,surface_);
        if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_,context_);
    }
    context_ = EGL_NO_CONTEXT; surface_ = EGL_NO_SURFACE; program_ = texture_ = vao_ = vbo_ = 0;
    glyphs_.clear(); vertices_.clear();
}
void TerminalRenderer::detach() {
    releaseGpu(); if (window_) OH_NativeWindow_DestroyNativeWindow(window_);
    window_ = nullptr; surfaceId_ = 0; unavailable_ = false;
}
void TerminalRenderer::shutdown() {
    detach(); if (fonts_) OH_Drawing_DestroyFontCollection(fonts_); fonts_ = nullptr;
    regularFont_.clear(); boldFont_.clear();
    // EGL_DEFAULT_DISPLAY is process shared. Never terminate another Pane's display.
    display_ = EGL_NO_DISPLAY; config_ = nullptr;
}
void TerminalRenderer::quad(float x,float y,float w,float h,GhosttyColorRgb rgb,float alpha,const Glyph* g) {
    x += grid_.x; y += grid_.y;
    if (g && g->colored) rgb = {255,255,255};
    const float points[][2]={{0,0},{1,0},{0,1},{0,1},{1,0},{1,1}};
    for (const auto& p : points) vertices_.push_back({x+p[0]*w,y+p[1]*h,
        g ? (g->x+p[0]*g->width)/AtlasSize : 0,g ? (g->y+p[1]*g->height)/AtlasSize : 0,
        rgb.r/255.f*alpha,rgb.g/255.f*alpha,rgb.b/255.f*alpha,alpha,g ? 0.f : 1.f});
}
void TerminalRenderer::flush() {
    if (vertices_.empty()) return;
    glBufferData(GL_ARRAY_BUFFER,vertices_.size()*sizeof(Vertex),vertices_.data(),GL_STREAM_DRAW);
    glDrawArrays(GL_TRIANGLES,0,static_cast<GLsizei>(vertices_.size())); vertices_.clear();
}
TerminalRenderer::Glyph TerminalRenderer::glyph(const std::string& text,int span,const GhosttyStyle& style) {
    const std::string key = std::to_string(span)+char('0'+style.bold)+char('0'+style.italic)+text;
    auto cached = glyphs_.find(key); if (cached != glyphs_.end()) return cached->second;
    const int width = span*cellWidth_, height = cellHeight_;
    if (width > 256 || height > 256) throw std::runtime_error("terminal_glyph_bounds");
    if (atlasX_+width > AtlasSize) { atlasX_ = 0; atlasY_ += atlasRow_; atlasRow_ = 0; }
    if (atlasY_+height > AtlasSize || glyphs_.size() >= 4096) {
        flush(); glyphs_.clear(); atlasX_ = atlasY_ = atlasRow_ = 0;
    }
    TextLine textLine(fonts_,text,fontSize_,style.bold,style.italic);
    if (!textLine.line) throw std::runtime_error("terminal_glyph_shape_failed");
    double ascent = 0,descent = 0,leading = 0;
    double advance = OH_Drawing_TextLineGetTypographicBounds(textLine.line,&ascent,&descent,&leading);
    std::vector<uint8_t> pixels(static_cast<size_t>(width)*height*4);
    OH_Drawing_Image_Info info{width,height,COLOR_FORMAT_RGBA_8888,ALPHA_FORMAT_PREMUL};
    auto bitmap = OH_Drawing_BitmapCreateFromPixels(&info,pixels.data(),width*4);
    auto canvas = OH_Drawing_CanvasCreate(); OH_Drawing_CanvasBind(canvas,bitmap); OH_Drawing_CanvasClear(canvas,0);
    // Typography owns Unicode shaping/fallback. The terminal owns cluster span.
    OH_Drawing_TextLinePaint(textLine.line,canvas,(width-advance)/2,0);
    OH_Drawing_CanvasDestroy(canvas); OH_Drawing_BitmapDestroy(bitmap);
    Glyph result{atlasX_,atlasY_,width,height};
    for (size_t i = 0; i < pixels.size(); i += 4) {
        if (pixels[i] != pixels[i+1] || pixels[i+1] != pixels[i+2]) { result.colored = true; break; }
    }
    glTexSubImage2D(GL_TEXTURE_2D,0,result.x,result.y,width,height,GL_RGBA,GL_UNSIGNED_BYTE,pixels.data());
    atlasX_ += width; atlasRow_ = std::max(atlasRow_,height); glyphs_.emplace(key,result); return result;
}
void TerminalRenderer::paint(GhosttyTerminal terminal,GhosttySearch search,const std::vector<uint32_t>& overview,const TerminalLink& link,bool focused,bool blinkOn) {
    const auto highlights = TerminalSearchHighlights::read(terminal,search,grid_.cols,grid_.rows);
    GhosttyRenderState state = nullptr; GhosttyRenderStateRowIterator rows = nullptr; GhosttyRenderStateRowCells cells = nullptr;
    try {
        checkVt(ghostty_render_state_new(nullptr,&state)); checkVt(ghostty_render_state_update(state,terminal));
        checkVt(ghostty_render_state_row_iterator_new(nullptr,&rows)); checkVt(ghostty_render_state_row_cells_new(nullptr,&cells));
        auto dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL; checkVt(ghostty_render_state_set(state,GHOSTTY_RENDER_STATE_OPTION_DIRTY,&dirty));
        checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,&rows));
        GhosttyColorRgb foreground{205,214,244},background{30,30,46};
        checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND,&foreground));
        checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND,&background));
        GhosttyColorRgb palette[256];
        checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE,palette));
        bool cursorVisible = false, cursorInViewport = false; uint16_t cursorX = 0, cursorY = 0;
        checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,&cursorVisible));
        checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,&cursorInViewport));
        if (cursorInViewport) {
            checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,&cursorX));
            checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,&cursorY));
        }
        cursorGeometry_ = std::to_string(grid_.x+(cursorInViewport ? cursorX*cellWidth_ : 0))+","+
            std::to_string(grid_.y+(cursorInViewport ? cursorY*cellHeight_ : (this->rows()-1)*cellHeight_))+","+std::to_string(cellHeight_);
        GhosttyRenderStateCursorVisualStyle cursorStyle = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,&cursorStyle));
        bool blinking = false;
        checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING,&blinking));
        if (!focused) cursorStyle = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW;
        else if (blinking && !blinkOn) cursorVisible = false;
        GhosttyColorRgb cursorColor{245,224,220};
        ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR,&cursorColor);
        glViewport(0,0,width_,height_); glClearColor(0,0,0,0); glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_BLEND); glBlendFunc(GL_ONE,GL_ONE_MINUS_SRC_ALPHA); glUseProgram(program_);
        glBindVertexArray(vao_); glBindBuffer(GL_ARRAY_BUFFER,vbo_); glBindTexture(GL_TEXTURE_2D,texture_);
        glUniform2f(glGetUniformLocation(program_,"screen"),static_cast<float>(width_),static_cast<float>(height_));
        uint16_t y = 0;
        while (ghostty_render_state_row_iterator_next_dirty(rows,&y)) {
            GhosttyRenderStateRowSelection selection = GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
            bool selected = ghostty_render_state_row_get(rows,GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION,&selection) == GHOSTTY_SUCCESS;
            checkVt(ghostty_render_state_row_get(rows,GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,&cells)); int x = -1;
            while (ghostty_render_state_row_cells_next(cells)) {
                ++x; GhosttyCell raw = 0; GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
                checkVt(ghostty_render_state_row_cells_get(cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,&raw));
                checkVt(ghostty_cell_get(raw,GHOSTTY_CELL_DATA_WIDE,&wide));
                if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
                GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
                checkVt(ghostty_render_state_row_cells_get(cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,&style));
                GhosttyColorRgb fg = foreground,bg = background;
                ghostty_render_state_row_cells_get(cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,&fg);
                bool explicitBg = ghostty_render_state_row_cells_get(cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,&bg) == GHOSTTY_SUCCESS;
                if (style.inverse) { std::swap(fg,bg); explicitBg = true; }
                const bool cursor = cursorVisible && cursorInViewport && x == cursorX && y == cursorY;
                if (selected && x >= selection.start_x && x <= selection.end_x) { bg = focused ? GhosttyColorRgb{88,91,112} : GhosttyColorRgb{69,71,90}; fg = foreground; explicitBg = true; }
                const auto match = highlights.at(x,y);
                if (match) { bg = match == 2 ? GhosttyColorRgb{88,91,112} : GhosttyColorRgb{69,71,90}; fg = foreground; explicitBg = true; }
                if (cursor && cursorStyle == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK) { bg = cursorColor; fg = background; explicitBg = true; }
                const int span = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1;
                if (explicitBg) quad(x*cellWidth_,y*cellHeight_,span*cellWidth_,cellHeight_,bg,1);
                GhosttyBuffer bytes{nullptr,0,0};
                ghostty_render_state_row_cells_get(cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,&bytes);
                if (bytes.len && !style.invisible) {
                    if (bytes.len > 16384) throw std::runtime_error("terminal_cluster_limit");
                    std::string text(bytes.len,'\0'); bytes.ptr = reinterpret_cast<uint8_t*>(text.data()); bytes.cap = text.size();
                    checkVt(ghostty_render_state_row_cells_get(cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,&bytes));
                    if (text != " ") { auto tile = glyph(text,span,style); quad(x*cellWidth_,y*cellHeight_,tile.width,tile.height,fg,style.faint?.5f:1.f,&tile); }
                }
                const int thickness = std::max(1,cellHeight_/24);
                const float ink = style.faint ? .5f : 1.f;
                GhosttyColorRgb underline = fg;
                if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB) underline = style.underline_color.value.rgb;
                else if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) underline = palette[style.underline_color.value.palette];
                if (style.underline && !style.invisible) {
                    const int left = x*cellWidth_, bottom = (y+1)*cellHeight_-2*thickness, width = span*cellWidth_;
                    if (style.underline == GHOSTTY_SGR_UNDERLINE_CURLY) {
                        for (int dx = 0; dx < width; ++dx) {
                            const float wave = std::sin((left+dx)*6.2831853f/std::max(4,cellWidth_))*thickness;
                            quad(left+dx,bottom+wave,1,thickness,underline,ink);
                        }
                    } else if (style.underline == GHOSTTY_SGR_UNDERLINE_DOTTED || style.underline == GHOSTTY_SGR_UNDERLINE_DASHED) {
                        const int length = style.underline == GHOSTTY_SGR_UNDERLINE_DOTTED ? thickness : 3*thickness;
                        for (int dx = 0; dx < width; dx += 2*length) quad(left+dx,bottom,std::min(length,width-dx),thickness,underline,ink);
                    } else {
                        quad(left,bottom,width,thickness,underline,ink);
                        if (style.underline == GHOSTTY_SGR_UNDERLINE_DOUBLE) quad(left,bottom-2*thickness,width,thickness,underline,ink);
                    }
                }
                if (!style.invisible && style.strikethrough) quad(x*cellWidth_,y*cellHeight_+cellHeight_/2,span*cellWidth_,thickness,fg,ink);
                if (!style.invisible && style.overline) quad(x*cellWidth_,y*cellHeight_,span*cellWidth_,thickness,fg,ink);
                if (cursor && cursorStyle == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR)
                    quad(x*cellWidth_,y*cellHeight_,cursorStroke_,cellHeight_,cursorColor,1);
                if (cursor && cursorStyle == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE)
                    quad(x*cellWidth_,(y+1)*cellHeight_-cursorStroke_,span*cellWidth_,cursorStroke_,cursorColor,1);
                if (cursor && cursorStyle == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW) {
                    quad(x*cellWidth_,y*cellHeight_,span*cellWidth_,cursorStroke_,cursorColor,1);
                    quad(x*cellWidth_,(y+1)*cellHeight_-cursorStroke_,span*cellWidth_,cursorStroke_,cursorColor,1);
                    quad(x*cellWidth_,y*cellHeight_,cursorStroke_,cellHeight_,cursorColor,1);
                    quad((x+span)*cellWidth_-cursorStroke_,y*cellHeight_,cursorStroke_,cellHeight_,cursorColor,1);
                }
                if (!style.invisible && link.contains(y*grid_.cols+x))
                    quad(x*cellWidth_,(y+1)*cellHeight_-thickness,span*cellWidth_,thickness,fg,ink);
                if (match) {
                    const GhosttyColorRgb border = match == 2 ? GhosttyColorRgb{137,180,250} : GhosttyColorRgb{88,91,112};
                    // Border only the outside of each contiguous match region.
                    if (highlights.at(x,y-1) != match) quad(x*cellWidth_,y*cellHeight_,span*cellWidth_,thickness,border,1);
                    if (highlights.at(x,y+1) != match) quad(x*cellWidth_,(y+1)*cellHeight_-thickness,span*cellWidth_,thickness,border,1);
                    if (highlights.at(x-1,y) != match) quad(x*cellWidth_,y*cellHeight_,thickness,cellHeight_,border,1);
                    if (highlights.at(x+span,y) != match) quad((x+span)*cellWidth_-thickness,y*cellHeight_,thickness,cellHeight_,border,1);
                }
                if (vertices_.size() > 32768) flush();
            }
        }
        GhosttyTerminalScrollbar viewport{};
        checkVt(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&viewport));
        const auto bar = TerminalScrollbar::fit(grid_,viewport);
        if (bar.visible()) {
            // Keep the visible grab target on the inner side of the existing
            // gutter, clear of the floating window's outer resize hot zone.
            quad(bar.x-grid_.x,bar.thumbY-grid_.y,bar.width/4,bar.thumbHeight,{127,132,156},.65f);
        }
        const double markerHeight = std::min(bar.height,std::max(1.0,bar.width/4));
        int previousY = -1;
        if (search && bar.height > 0) for (const auto row : overview) {
            const int y = static_cast<int>(bar.markerY(row,viewport.total,markerHeight));
            if (y == previousY) continue;
            previousY = y;
            quad(bar.x-grid_.x,y-grid_.y,bar.width/2,markerHeight,{137,180,250},1);
            if (vertices_.size() > 32768) flush();
        }
        flush();
        if (glGetError() != GL_NO_ERROR) throw std::runtime_error("terminal_gl_draw_failed");
    } catch (...) {
        if (cells) ghostty_render_state_row_cells_free(cells); if (rows) ghostty_render_state_row_iterator_free(rows);
        if (state) ghostty_render_state_free(state); throw;
    }
    ghostty_render_state_row_cells_free(cells); ghostty_render_state_row_iterator_free(rows); ghostty_render_state_free(state);
}
void TerminalRenderer::draw(GhosttyTerminal terminal,GhosttySearch search,const std::vector<uint32_t>& overview,const TerminalLink& link,bool focused,bool blinkOn) noexcept {
    if (!window_ || unavailable_) return;
    // Bounded recovery retains VT. A new Surface attachment allows a new attempt.
    for (int attempt = 0; attempt < 2; ++attempt) {
        try {
            if (context_ == EGL_NO_CONTEXT) createGpu();
            if (!eglMakeCurrent(display_,surface_,surface_,context_)) throw std::runtime_error("terminal_make_current_failed");
            paint(terminal,search,overview,link,focused,blinkOn);
            if (!eglSwapBuffers(display_,surface_)) throw std::runtime_error("terminal_swap_failed");
            eglMakeCurrent(display_,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
            status_("cursor",cursorGeometry_); status_("presented",{}); return;
        } catch (...) {
            const auto error = eglGetError(); releaseGpu(error == EGL_CONTEXT_LOST);
            if (error == EGL_NOT_INITIALIZED) { display_ = EGL_NO_DISPLAY; config_ = nullptr; }
            if (error == EGL_BAD_NATIVE_WINDOW || error == EGL_BAD_ACCESS || error == EGL_SUCCESS) break;
        }
    }
    unavailable_ = true;
    try { status_("surface-unavailable",{}); } catch (...) {}
}
}

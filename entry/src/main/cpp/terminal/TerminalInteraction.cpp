#include "TerminalRuntime.h"
#include "TerminalScrollbar.h"
#include "TerminalSearchHighlights.h"
#include <algorithm>
#include <chrono>
#include <stdexcept>

namespace leantty {
void TerminalRuntime::encodeKey(const Command& c) {
    GhosttyKeyEncoder encoder = nullptr; GhosttyKeyEvent event = nullptr;
    checkVt(ghostty_key_encoder_new(nullptr,&encoder));
    try {
        checkVt(ghostty_key_event_new(nullptr,&event));
        ghostty_key_encoder_setopt_from_terminal(encoder,active_);
        ghostty_key_event_set_action(event,GHOSTTY_KEY_ACTION_PRESS);
        ghostty_key_event_set_key(event,c.key); ghostty_key_event_set_mods(event,c.modifiers);
        // Kitty encoding needs the layout's unshifted character separately from committed text.
        ghostty_key_event_set_unshifted_codepoint(event,c.unshiftedCodepoint);
        // Shift used to produce the mapped printable character is consumed for
        // text dispatch; the encoder still retains all modifiers for shortcuts.
        if ((c.modifiers & GHOSTTY_MODS_SHIFT) && c.unshiftedCodepoint &&
            c.text.size() == 1 && static_cast<unsigned char>(c.text[0]) != c.unshiftedCodepoint)
            ghostty_key_event_set_consumed_mods(event,GHOSTTY_MODS_SHIFT);
        ghostty_key_event_set_utf8(event,c.text.data(),c.text.size());
        std::vector<char> encoded(c.text.size()+128); size_t written = 0;
        checkVt(ghostty_key_encoder_encode(encoder,event,encoded.data(),encoded.size(),&written));
        if (written) { followInput(); emit({"input",c.sequence,c.owner,std::string(encoded.data(),written)}); }
    } catch (...) { if (event) ghostty_key_event_free(event); ghostty_key_encoder_free(encoder); throw; }
    ghostty_key_event_free(event); ghostty_key_encoder_free(encoder);
}
void TerminalRuntime::resetInteraction() {
    clearLink(); pointerInside_ = false;
    if (search_) ghostty_search_free(search_);
    search_ = nullptr; searchPending_ = false; selectSearch_ = false;
    searchOverview_.clear();
    if (gesture_ && active_) ghostty_selection_gesture_reset(gesture_,active_);
    if (mouse_) ghostty_mouse_encoder_reset(mouse_);
    pointerGesture_ = PointerGesture::None; autoscroll_ = 0; scrollbarGrab_ = -2; ++selectionRevision_;
    effectSequence_.clear();
    pressedLink_.clear();
}
void TerminalRuntime::followInput() {
    clearLink();
    autoscroll_ = 0; scrollbarGrab_ = -2;
    checkVt(ghostty_terminal_set(active_,GHOSTTY_TERMINAL_OPT_SELECTION,nullptr)); ++selectionRevision_;
    GhosttyTerminalScrollViewport scroll{}; scroll.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
    ghostty_terminal_scroll_viewport(active_,scroll);
}
bool TerminalRuntime::mouse(int action,int button,int x,int y,GhosttyMods modifiers,uint32_t owner,bool continuing) {
    bool tracking = false;
    checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,&tracking));
    if (!tracking || (!continuing && (modifiers & GHOSTTY_MODS_SHIFT))) return false;
    GhosttyMouseEvent event = nullptr; checkVt(ghostty_mouse_event_new(nullptr,&event));
    ghostty_mouse_encoder_setopt_from_terminal(mouse_,active_);
    GhosttyMouseEncoderSize size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
    size.screen_width = cols_*cellWidth_; size.screen_height = rows_*cellHeight_;
    size.cell_width = cellWidth_; size.cell_height = cellHeight_;
    ghostty_mouse_encoder_setopt(mouse_,GHOSTTY_MOUSE_ENCODER_OPT_SIZE,&size);
    const bool pressed = pointerGesture_ != PointerGesture::None || (action == 0 && button == 1);
    ghostty_mouse_encoder_setopt(mouse_,GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,&pressed);
    ghostty_mouse_event_set_action(event,static_cast<GhosttyMouseAction>(action));
    if (button) ghostty_mouse_event_set_button(event,static_cast<GhosttyMouseButton>(button));
    ghostty_mouse_event_set_mods(event,modifiers);
    ghostty_mouse_event_set_position(event,{static_cast<float>(x),static_cast<float>(y)});
    char encoded[128]; size_t written = 0;
    const auto result = ghostty_mouse_encoder_encode(mouse_,event,encoded,sizeof(encoded),&written);
    ghostty_mouse_event_free(event); checkVt(result);
    if (written) emit({"input",consuming_,owner,std::string(encoded,written)});
    return true;
}
bool TerminalRuntime::scrollbarPointer(const Command& c) {
    GhosttyTerminalScrollbar viewport{};
    checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&viewport));
    const auto bar = TerminalScrollbar::fit(surfaceGeometry_,viewport);
    const bool held = scrollbarGrab_ != -2;
    if (!bar.visible()) { scrollbarGrab_ = -2; return held; }
    if (!held && (!bar.hit(c.x,c.y) || pointerGesture_ != PointerGesture::None)) return false;
    if (c.action == 1) { scrollbarGrab_ = -2; return true; }
    if (c.action == 0 && c.button == 1) {
        autoscroll_ = 0; pressedLink_.clear();
        if (c.y >= bar.thumbY && c.y < bar.thumbY+bar.thumbHeight) scrollbarGrab_ = c.y-bar.thumbY;
        else {
            scrollbarGrab_ = -1;
            GhosttyTerminalScrollViewport scroll{}; scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
            scroll.value.delta = (c.y < bar.thumbY ? -1 : 1)*std::max(1,static_cast<int>(viewport.len)-1);
            ghostty_terminal_scroll_viewport(active_,scroll);
        }
    } else if (c.action == 2 && scrollbarGrab_ >= 0) {
        GhosttyTerminalScrollViewport scroll{}; scroll.tag = GHOSTTY_SCROLL_VIEWPORT_ROW;
        scroll.value.row = bar.row(c.y-scrollbarGrab_);
        ghostty_terminal_scroll_viewport(active_,scroll);
    }
    return true;
}
void TerminalRuntime::pointer(const Command& c) {
    pointerX_ = c.x; pointerY_ = c.y; pointerMods_ = c.modifiers; pointerOwner_ = c.owner;
    pointerInside_ = true;
    if (c.action == 2 && !c.button && pointerGesture_ == PointerGesture::None) updateLink(c.owner);
    else clearLink();
    autoscroll_ = 0;
    // Secondary click belongs to the local clipboard contract, including when
    // a TUI owns the mouse. Consume both phases so no unmatched press reaches it.
    if (c.button == 2) {
        if (c.action == 1) { Command secondary{Kind::Copy}; secondary.action = 2; secondary.owner = c.owner; copy(secondary); }
        return;
    }
    if (c.button != 1) { mouse(c.action,c.button,c.x,c.y,c.modifiers,c.owner); return; }
    if (c.action == 0) {
        pressedLink_.clear();
        if (linkModifier(c.modifiers)) {
            pointerGesture_ = PointerGesture::Link;
            pressedLink_ = linkAt(c.x,c.y).url; linkX_ = c.x; linkY_ = c.y;
        } else if (mouse(c.action,c.button,c.x,c.y,c.modifiers,c.owner)) {
            pointerGesture_ = PointerGesture::Remote;
            return;
        } else { pointerGesture_ = PointerGesture::Selection; }
    }
    // Route the complete gesture by its press, not by the release's modifiers.
    // A late Ctrl must not steal selection cleanup or a remote mouse release.
    if (pointerGesture_ == PointerGesture::Link) {
        if (!linkModifier(c.modifiers) || std::abs(c.x-linkX_) > cellWidth_/2 || std::abs(c.y-linkY_) > cellHeight_/2)
            pressedLink_.clear();
        if (c.action == 1) {
            if (!pressedLink_.empty() && pressedLink_ == linkAt(c.x,c.y).url) emit({"link",consuming_,c.owner,pressedLink_});
            pressedLink_.clear(); pointerGesture_ = PointerGesture::None;
        }
        return;
    }
    if (pointerGesture_ == PointerGesture::Remote) {
        mouse(c.action,c.button,c.x,c.y,c.modifiers,c.owner,true);
        if (c.action == 1) pointerGesture_ = PointerGesture::None;
        return;
    }
    if (pointerGesture_ != PointerGesture::Selection) return;
    if (c.action == 1) pointerGesture_ = PointerGesture::None;
    GhosttyPoint point{}; point.tag = GHOSTTY_POINT_TAG_VIEWPORT;
    point.value.coordinate.x = std::clamp(c.x / cellWidth_,0,static_cast<int>(cols_)-1);
    point.value.coordinate.y = std::clamp(c.y / cellHeight_,0,static_cast<int>(rows_)-1);
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    if (ghostty_terminal_grid_ref(active_,point,&ref) != GHOSTTY_SUCCESS) return;
    auto type = c.action == 0 ? GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS : c.action == 1 ?
        GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE : GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG;
    GhosttySelectionGestureEvent event = nullptr;
    checkVt(ghostty_selection_gesture_event_new(nullptr,&event,type));
    GhosttySelection selected = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result;
    try {
        checkVt(ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF,&ref));
        if (c.action != 1) {
            GhosttySurfacePosition position{static_cast<double>(c.x),static_cast<double>(c.y)};
            checkVt(ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION,&position));
        }
        if (c.action == 0) {
            uint64_t time = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
            uint64_t interval = 500000000; double distance = cellWidth_;
            checkVt(ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS,&time));
            checkVt(ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS,&interval));
            checkVt(ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE,&distance));
        } else if (c.action == 2) {
            GhosttySelectionGestureGeometry geometry{cols_,cellWidth_,0,static_cast<uint32_t>(rows_*cellHeight_)};
            bool rectangle = (c.modifiers & GHOSTTY_MODS_ALT) != 0;
            checkVt(ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY,&geometry));
            checkVt(ghostty_selection_gesture_event_set(event,GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE,&rectangle));
        }
        result = ghostty_selection_gesture_event(gesture_,active_,event,&selected);
    } catch (...) { ghostty_selection_gesture_event_free(event); throw; }
    ghostty_selection_gesture_event_free(event);
    if (c.action != 1) {
        if (result == GHOSTTY_SUCCESS) checkVt(ghostty_terminal_set(active_,GHOSTTY_TERMINAL_OPT_SELECTION,&selected));
        else if (result == GHOSTTY_NO_VALUE) checkVt(ghostty_terminal_set(active_,GHOSTTY_TERMINAL_OPT_SELECTION,nullptr));
        else checkVt(result);
        ++selectionRevision_;
        if (c.action == 2 && pointerGesture_ == PointerGesture::Selection) {
            GhosttySelectionGestureAutoscroll scroll;
            checkVt(ghostty_selection_gesture_get(gesture_,active_,GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL,&scroll));
            autoscroll_ = scroll == GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP ? -1 : scroll == GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN ? 1 : 0;
        }
    }
}
bool TerminalRuntime::linkModifier(GhosttyMods modifiers) {
    bool tracking = false;
    checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,&tracking));
    return (modifiers & GHOSTTY_MODS_CTRL) && !(modifiers & (GHOSTTY_MODS_ALT|GHOSTTY_MODS_SUPER)) &&
        (static_cast<bool>(modifiers & GHOSTTY_MODS_SHIFT) == tracking);
}
void TerminalRuntime::clearLink() {
    if (!hoveredLink_.url.empty()) {
        hoveredLink_ = {};
        emit({"link-hover",consuming_,pointerOwner_,{}});
    }
}
void TerminalRuntime::updateLink(uint32_t owner) {
    TerminalLink link;
    if (pointerInside_ && pointerGesture_ == PointerGesture::None && pressedLink_.empty() && !search_ && linkModifier(pointerMods_))
        link = linkAt(pointerX_,pointerY_);
    const bool changed = link.url != hoveredLink_.url || owner != pointerOwner_;
    hoveredLink_ = std::move(link); pointerOwner_ = owner;
    if (changed) emit({"link-hover",consuming_,owner,hoveredLink_.url});
}
TerminalLink TerminalRuntime::linkAt(int x,int y) {
    if (x < 0 || y < 0 || x >= cols_*cellWidth_ || y >= rows_*cellHeight_) return {};
    GhosttyPoint point{}; point.tag = GHOSTTY_POINT_TAG_VIEWPORT;
    point.value.coordinate = {static_cast<uint16_t>(x/cellWidth_),static_cast<uint32_t>(y/cellHeight_)};
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    if (ghostty_terminal_grid_ref(active_,point,&ref) != GHOSTTY_SUCCESS) return {};
    uint8_t bytes[8192]; size_t length = 0;
    if (ghostty_grid_ref_hyperlink_uri(&ref,bytes,sizeof(bytes),&length) == GHOSTTY_SUCCESS && length) {
        TerminalLink link{std::string(reinterpret_cast<char*>(bytes),length),y/cellHeight_*cols_+x/cellWidth_,0};
        link.last = link.first;
        // OSC 8 labels can contain spaces and span rows. Inspect adjacent visible
        // metadata, never flatten terminal text or retain borrowed grid references.
        auto same = [&](int cell) {
            point.value.coordinate = {static_cast<uint16_t>(cell%cols_),static_cast<uint32_t>(cell/cols_)};
            if (ghostty_terminal_grid_ref(active_,point,&ref) != GHOSTTY_SUCCESS) return false;
            length = 0;
            return ghostty_grid_ref_hyperlink_uri(&ref,bytes,sizeof(bytes),&length) == GHOSTTY_SUCCESS &&
                length == link.url.size() && link.url.compare(0,length,reinterpret_cast<char*>(bytes),length) == 0;
        };
        while (link.first > 0 && same(link.first-1)) --link.first;
        while (link.last+1 < cols_*rows_ && same(link.last+1)) ++link.last;
        return link;
    }
    const uint32_t boundaries[] = {0,9,32,'"','\'','<','>','`','|','\\'};
    GhosttyTerminalSelectWordOptions word = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
    word.ref = ref; word.boundary_codepoints = boundaries; word.boundary_codepoints_len = sizeof(boundaries)/sizeof(boundaries[0]);
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    if (ghostty_terminal_select_word(active_,&word,&selection) != GHOSTTY_SUCCESS) return {};
    GhosttyTerminalSelectionFormatOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN; options.unwrap = true; options.trim = true; options.selection = &selection;
    if (ghostty_terminal_selection_format_buf(active_,options,bytes,sizeof(bytes),&length) != GHOSTTY_SUCCESS) return {};
    std::string url(reinterpret_cast<char*>(bytes),length);
    // Only explicit HTTP(S) tokens are inferred. Accept a surrounding square
    // bracket or an ASCII label such as URL= without splitting query values,
    // parentheses in paths or IPv6 authorities. OSC 8 handles complex labels.
    size_t leading = 0;
    const char wrapper = url.empty() ? 0 : url.front();
    const char closing = wrapper == '(' ? ')' : wrapper == '[' ? ']' : wrapper == '{' ? '}' : 0;
    if (closing) { url.erase(0,1); ++leading; }
    const auto equals = url.find('=');
    if (equals != std::string::npos && equals > 0 &&
        url.substr(0,equals).find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-") == std::string::npos) {
        leading += equals+1; url.erase(0,equals+1);
    }
    while (!url.empty() && std::string(".,;:!?").find(url.back()) != std::string::npos) url.pop_back();
    if (closing && !url.empty() && url.back() == closing) url.pop_back();
    std::string scheme = url.substr(0,8);
    for (auto& ch : scheme) if (ch >= 'A' && ch <= 'Z') ch += 'a'-'A';
    const size_t schemeSize = !scheme.compare(0,7,"http://") ? 7 : !scheme.compare(0,8,"https://") ? 8 : 0;
    if (!schemeSize || url.size() <= schemeSize || url[schemeSize] == '/' || url[schemeSize] == '?' || url[schemeSize] == '#') return {};
    GhosttyPointCoordinate start{}, end{};
    checkVt(ghostty_terminal_point_from_grid_ref(active_,&selection.start,GHOSTTY_POINT_TAG_SCREEN,&start));
    checkVt(ghostty_terminal_point_from_grid_ref(active_,&selection.end,GHOSTTY_POINT_TAG_SCREEN,&end));
    GhosttyTerminalScrollbar viewport{};
    checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&viewport));
    const int64_t first = (static_cast<int64_t>(start.y)-viewport.offset)*cols_+start.x+static_cast<int64_t>(leading);
    const int64_t last = (static_cast<int64_t>(end.y)-viewport.offset)*cols_+end.x-static_cast<int64_t>(length-leading-url.size());
    const int64_t hit = (y/cellHeight_)*cols_+x/cellWidth_;
    if (hit < first || hit > last) return {};
    return {url,static_cast<int>(std::max<int64_t>(0,first)),static_cast<int>(std::min<int64_t>(cols_*rows_-1,last))};
}
void TerminalRuntime::copy(const Command& c) {
    if (c.action == 3) {
        if (!c.revision || c.revision == selectionRevision_) {
            checkVt(ghostty_terminal_set(active_,GHOSTTY_TERMINAL_OPT_SELECTION,nullptr)); ++selectionRevision_;
        }
        return;
    }
    GhosttyTerminalSelectionFormatOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN; options.unwrap = true; options.trim = true;
    size_t length = 0;
    auto result = ghostty_terminal_selection_format_buf(active_,options,nullptr,0,&length);
    if (result != GHOSTTY_NO_VALUE && result != GHOSTTY_OUT_OF_SPACE) checkVt(result);
    if (length > 1024*1024) { emit({"copy-too-large",consuming_,c.owner,{}}); return; }
    if (length) {
        std::string text(length,'\0');
        checkVt(ghostty_terminal_selection_format_buf(active_,options,reinterpret_cast<uint8_t*>(text.data()),text.size(),&length));
        text.resize(length); emit({"copy",selectionRevision_,c.owner,std::move(text)});
    } else if (c.action == 1) { followInput(); emit({"input",consuming_,c.owner,"\x03"}); }
    else if (c.action == 2) emit({"paste-request",consuming_,c.owner,{}});
}
void TerminalRuntime::search(const Command& c) {
    searchGeneration_ = c.owner;
    searchOverview_.clear();
    if (c.text.empty()) {
        if (search_) {
            ghostty_search_free(search_);
            checkVt(ghostty_terminal_set(active_,GHOSTTY_TERMINAL_OPT_SELECTION,nullptr)); ++selectionRevision_;
        }
        search_ = nullptr; searchPending_ = false; selectSearch_ = false;
        emit({"search",0,searchGeneration_,"0,0"}); return;
    }
    if (!search_) checkVt(ghostty_search_new(nullptr,&search_,active_));
    checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&searchScreen_));
    GhosttyString needle{reinterpret_cast<const uint8_t*>(c.text.data()),c.text.size()};
    checkVt(ghostty_search_set(search_,GHOSTTY_SEARCH_OPT_NEEDLE,&needle));
    checkVt(ghostty_search_feed(search_));
    // Queries run in bounded slices. Navigation is applied after the current
    // search catches up, so no borrowed match survives a terminal mutation.
    selectSearch_ = true; searchPending_ = true;
    searchDirection_ = c.action;
}
void TerminalRuntime::refreshSearch(bool feed) {
    GhosttyTerminalScreen screen;
    checkVt(ghostty_terminal_get(active_,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&screen));
    if (screen != searchScreen_) {
        const auto generation = searchGeneration_;
        resetInteraction();
        searchScreen_ = screen;
        checkVt(ghostty_terminal_set(active_,GHOSTTY_TERMINAL_OPT_SELECTION,nullptr));
        // Surface owns whether the panel is open; an empty query has no search object.
        emit({"search-close",0,generation,{}});
    } else if (search_ && feed) {
        searchOverview_.clear(); checkVt(ghostty_search_feed(search_)); searchPending_ = true;
    }
}
void TerminalRuntime::advanceSearch() {
    GhosttySearchStatus status;
    checkVt(ghostty_search_get(search_,GHOSTTY_SEARCH_DATA_STATUS,&status));
    if (status == GHOSTTY_SEARCH_STATUS_FEED_REQUIRED) checkVt(ghostty_search_feed(search_));
    checkVt(ghostty_search_tick(search_,&status));
    if (status != GHOSTTY_SEARCH_STATUS_COMPLETE) return;
    searchPending_ = false;
    searchOverview_ = TerminalSearchHighlights::overview(active_,search_);
    if (selectSearch_) {
        const auto result = ghostty_search_set(search_,searchDirection_ < 0 ? GHOSTTY_SEARCH_OPT_SELECT_NEXT : GHOSTTY_SEARCH_OPT_SELECT_PREV,nullptr);
        if (result != GHOSTTY_NO_VALUE) checkVt(result);
        selectSearch_ = false;
    }
    GhosttySelection match = GHOSTTY_INIT_SIZED(GhosttySelection);
    if (ghostty_search_get(search_,GHOSTTY_SEARCH_DATA_SELECTED_MATCH,&match) == GHOSTTY_SUCCESS) {
        checkVt(ghostty_terminal_set(active_,GHOSTTY_TERMINAL_OPT_SELECTION,&match)); ++selectionRevision_;
    } else { checkVt(ghostty_terminal_set(active_,GHOSTTY_TERMINAL_OPT_SELECTION,nullptr)); ++selectionRevision_; }
    size_t total = 0,index = 0;
    checkVt(ghostty_search_get(search_,GHOSTTY_SEARCH_DATA_TOTAL_MATCHES,&total));
    if (ghostty_search_get(search_,GHOSTTY_SEARCH_DATA_SELECTED_INDEX,&index) != GHOSTTY_SUCCESS) index = total;
    emit({"search",0,searchGeneration_,std::to_string(index < total ? total-index : 0)+","+std::to_string(total)});
}
}

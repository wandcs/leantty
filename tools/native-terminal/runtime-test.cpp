#include "TerminalRuntime.h"
#include "TerminalScrollbar.h"
#include "TerminalSearchHighlights.h"
#include <cstdlib>
#include <iostream>
#include <future>
#include <atomic>
#include <stdexcept>
using namespace leantty;
#include "session-reset-sequence.inc"
static void require(bool condition, const char* label) { if (!condition) throw std::runtime_error(label); }
struct Log {
    std::mutex mutex; std::condition_variable changed; std::vector<TerminalEvent> events;
    bool receive(TerminalEvent e) { std::lock_guard<std::mutex> lock(mutex); events.push_back(std::move(e)); changed.notify_all(); return true; }
    TerminalEvent wait(const std::string& kind, uint64_t sequence = 0, uint32_t owner = 0) {
        std::unique_lock<std::mutex> lock(mutex);
        auto match = [&] { for (auto& e : events) if (e.kind == kind && (!sequence || e.sequence == sequence) && (!owner || owner == e.owner)) return true; return false; };
        if (!changed.wait_for(lock, std::chrono::seconds(10), match)) {
            std::cerr << "Waiting for " << kind << " sequence=" << sequence << " saw:";
            for (const auto& e : events) std::cerr << ' ' << e.kind << ':' << e.sequence;
            throw std::runtime_error("event timeout");
        }
        for (auto& e : events) if (e.kind == kind && (!sequence || e.sequence == sequence) && (!owner || owner == e.owner)) return e;
        throw std::runtime_error("missing event");
    }
};
static uint64_t write(TerminalRuntime& r, const std::string& bytes, uint32_t owner = 7) {
    auto seq = r.write(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), owner);
    require(seq != 0, "write admission"); return seq;
}
static std::string snapshot(TerminalRuntime& r, Log& log) { auto seq = r.snapshot(); require(seq != 0, "snapshot admission"); return log.wait("snapshot", seq).text; }
static std::pair<std::string,std::string> fragmented(const std::string& data, size_t chunk) {
    Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
    for (size_t i = 0; i < data.size(); i += chunk) write(r, data.substr(i, chunk));
    auto text = snapshot(r, log); r.close(); r.join(); require(!r.failed(), "fragment runtime");
    std::string replies; for (auto& e : log.events) if (e.kind == "reply") { require(e.owner == 7, "reply owner"); replies += e.text; }
    return {text, replies};
}
int main() {
    try {
        {
            const std::vector<std::pair<std::string,int>> cases = {
                {"",1}, {"remote-tail",1}, {"one\r\ntwo",2},
                {"one\r\n\r\n ",3}, {std::string(u8"中😀é"),1},
                {"one\x1b[4;1H\x1b[41m\x1b[J\x1b[0m",1},
                {"1\r\n2\r\n3\r\n4\r\n5\r\n6",6},
                {"history\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6\x1b[3;1H\x1b[J",2}
            };
            for (const auto& item : cases) {
                Log log; std::atomic<uint32_t> inspect{0};
                TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                    [&](GhosttyTerminal terminal,GhosttySearch,const std::vector<uint32_t>&,const TerminalLink&,bool,bool) {
                        const auto phase = inspect.load();
                        if (!phase) return;
                        GhosttyTerminalScrollbar bar{};
                        checkVt(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&bar));
                        log.receive({"session-bottom",0,phase,bar.offset+bar.len == bar.total ? "yes" : "no"});
                    });
                r.resize(20,6,8,16);
                if (!item.first.empty()) write(r,item.first);
                write(r,"\x1b[?1049hALT\x1b[?1049l\x1b[999;1H",0);
                if (item.first.find("history") == 0) {
                    log.wait("consumed",r.barrier(0)); inspect = 1;
                    r.scroll(-256,0,true);
                    require(log.wait("session-bottom",0,1).text == "no","precondition: user views historical page");
                    inspect = 0;
                }
                require(r.positionSessionOutput() != 0,"session anchor admission");
                const auto query = write(r,"\x1b[6n",0);
                require(log.wait("reply",query).text == "\x1b["+std::to_string(item.second)+";1R",
                    "anchor follows content including printed spaces, independent of historical viewport");
                write(r,"\r\nclosed\r\nltty> ",0);
                const auto text = snapshot(r,log);
                require(text.find("closed\nltty>") != std::string::npos,"ordered local output remains adjacent");
                if (item.first == "remote-tail") require(text.find("remote-tail\nclosed") != std::string::npos,"short remote output has no injected blank gap");
                if (item.first.find("history") == 0) require(text.find("history\n1\n2\nclosed") != std::string::npos,"history retained while active page is anchored");
                inspect = 2; r.focus(true);
                require(log.wait("session-bottom",0,2).text == "yes","local prompt visible at bottom after output");
                r.close(); r.join(); require(!r.failed(),"session anchor worker");
            }
            std::cout << "PASS session output anchor: empty, short, literal spaces, Unicode, cleared, full and historical pages\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                [&](GhosttyTerminal terminal,GhosttySearch,const std::vector<uint32_t>&,const TerminalLink&,bool,bool) {
                    uint32_t width = 0, height = 0;
                    checkVt(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_WIDTH_PX,&width));
                    checkVt(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_HEIGHT_PX,&height));
                    log.receive({"pixels:"+std::to_string(width)+","+std::to_string(height),0,0,{}});
                });
            r.updateDisplay([] { return TerminalRuntime::Geometry{80,24,8,16}; });
            r.updateDisplay([] { return TerminalRuntime::Geometry{80,24,8,16,12,13}; });
            r.resize(80,24,8,16);
            r.updateDisplay([] { return TerminalRuntime::Geometry{80,24,9,18,12,13}; });
            log.wait("pixels:720,432");
            r.updateDisplay([] { return TerminalRuntime::Geometry{}; });
            r.updateDisplay([] { return TerminalRuntime::Geometry{80,24,9,18}; });
            r.resize(79,24,9,18);
            r.resize(79,25,9,18);
            log.wait("consumed",r.barrier(0));
            r.close(); r.join(); require(!r.failed(),"grid notification worker");
            std::vector<std::string> sizes;
            for (const auto& e : log.events) if (e.kind == "resize") sizes.push_back(e.text);
            require(sizes == std::vector<std::string>{"80,24","79,24","79,25"},
                "notify the initial grid and actual changes only, across pixel updates and Surface replacement");
            std::cout << "PASS initial/grid-change resize notifications with independent pixel geometry\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            for (uint32_t generation : {81u,82u}) {
                std::string query;
                if (generation == 81) query.assign(1024*1024,'a');
                else for (size_t n=0;n<256*1024;++n) query += "\xf0\x9f\x98\x80";
                require(r.search(query,0,generation) != 0,"one MiB UTF-8 query is admitted");
                require(log.wait("search",0,generation).text == "0,0","large query completes without matches");
                query += 'a'; require(r.search(query,0,generation+10) == 0,"over-limit query is rejected before allocation into queue");
            }
            write(r,"still usable"); require(snapshot(r,log).find("still usable") != std::string::npos,"search limit cannot damage VT output");
            r.close(); r.join(); require(!r.failed(),"query length rejection is nonfatal");
            std::cout << "PASS one MiB ASCII/Unicode query boundary and subsequent output\n";
        }
        for (const std::string mode : {"empty", "nonempty", "cleared"}) {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            write(r,"alpha");
            for (uint32_t generation : {71u,72u}) {
                if (mode != "empty") { r.search("alpha",0,generation); log.wait("search",0,generation); }
                if (mode != "nonempty") r.search("",0,generation);
                log.wait("consumed",r.barrier(0));
                write(r,generation == 71 ? "\x1b[?1049hALT" : "\x1b[?1049l");
                log.wait("search-close",0,generation);
            }
            r.close(); r.join(); require(!r.failed(),"screen change closes search regardless of query");
            std::cout << "PASS search screen change: " << mode << " primary and alternate\n";
        }
        for (const int width : {153,512}) {
            Log log; std::atomic<uint32_t> phase{0};
            TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                [&](GhosttyTerminal terminal,GhosttySearch,const std::vector<uint32_t>&,const TerminalLink&,bool,bool) {
                    const auto current = phase.load();
                    if (!current) return;
                    size_t rows = 0;
                    checkVt(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,&rows));
                    log.receive({"history-capacity",0,current,std::to_string(rows)});
                });
            r.updateDisplay([&] { return TerminalRuntime::Geometry{static_cast<uint16_t>(width),46,8,16}; });
            // Distinct cell colors exercise the case where a byte budget loses
            // most history even though the line count is below the contract.
            std::string row;
            for (int col = 0; col < width-2; ++col) {
                row += "\x1b[38;2;"+std::to_string(col%256)+";"+std::to_string(col*7%256)+";"+std::to_string(col*13%256)+"mx";
            }
            row += "\x1b[0m\r\n";
            for (int line = 0; line < 12046; ++line) log.wait("consumed",write(r,row,0));
            phase = 1; r.focus(true);
            const auto retained = std::stoul(log.wait("history-capacity",0,1).text);
            require(retained > 9000 && retained <= 10000,"wide styled history retains approximately ten thousand lines");
            phase = 0;
            write(r,"retained-history-marker\r\n",0);
            r.search("retained-history-marker",0,901);
            require(log.wait("search",0,901).text == "1,1","line-limited history remains searchable");
            r.search("",0,902);
            const auto before = snapshot(r,log);
            r.beginTemporary(11);
            for (int line = 0; line < 100; ++line) write(r,"temporary\r\n",11);
            log.wait("consumed",r.barrier(11));
            phase = 2; r.focus(true);
            require(log.wait("history-capacity",0,2).text == "0","temporary page disables history despite upstream minimum page size");
            phase = 0; r.endTemporary(0);
            require(snapshot(r,log) == before,"temporary page preserves regular history viewport");
            phase = 3; r.focus(true);
            const auto restored = std::stoul(log.wait("history-capacity",0,3).text);
            require(restored > 9000 && restored <= 10000,"regular history capacity survives temporary page");
            r.close(); r.join(); require(!r.failed(),"history capacity runtime");
            std::cout << "PASS approximately 10000 styled history lines, search and temporary isolation at " << width << " columns\n";
        }
        {
            Log log;
            TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                [&](GhosttyTerminal,GhosttySearch,const std::vector<uint32_t>&,const TerminalLink& link,bool,bool) {
                    if (link.url == "https://example.com") require(link.first == 0 && link.last == 18,"plain URL underline excludes punctuation");
                    if (link.url == "https://target.test") require(link.first == 40 && link.last == 46,"OSC 8 underline includes wide character and spaces");
                    if (!link.url.empty()) log.receive({"link-painted:"+link.url,0,0,{}});
                });
            auto geometry = [] { return TerminalGrid::fit(416,136,10,20,8); };
            r.updateDisplay(geometry); r.focus(true);
            write(r,"https://example.com. rest\r\n\x1b]8;;https://target.test\x1b\\"+std::string(u8"中 link")+"\x1b]8;;\x1b\\");
            auto seq = r.pointer(2,0,28,18,0,501); log.wait("consumed",seq);
            seq = r.hover(GHOSTTY_MODS_CTRL,501);
            require(log.wait("link-hover",seq).text == "https://example.com","stationary Ctrl enables plain URL preview");
            log.wait("link-painted:https://example.com");
            // Wait for each actual paint before invalidation so its range assertion
            // cannot be skipped when the worker coalesces queued commands.
            seq = r.hover(0,501); require(log.wait("link-hover",seq).text.empty(),"Ctrl release clears stationary hover");
            seq = r.pointer(2,0,28,38,GHOSTTY_MODS_CTRL,501);
            require(log.wait("link-hover",seq).text == "https://target.test","OSC 8 Unicode label resolves metadata target");
            log.wait("link-painted:https://target.test");
            seq = r.hover(-1,501); require(log.wait("link-hover",seq).text.empty(),"leaving clears hover");
            seq = r.hover(GHOSTTY_MODS_CTRL,501); log.wait("consumed",seq);
            seq = r.pointer(2,0,28,18,GHOSTTY_MODS_CTRL,501); log.wait("link-hover",seq);
            seq = write(r,"\x1b[?1000h"); require(log.wait("link-hover",seq).text.empty(),"output invalidates old target");
            seq = r.pointer(2,0,28,18,GHOSTTY_MODS_CTRL|GHOSTTY_MODS_SHIFT,501);
            require(log.wait("link-hover",seq).text == "https://example.com","mouse tracking requires Ctrl Shift override");
            seq = r.hover(GHOSTTY_MODS_CTRL,501); require(log.wait("link-hover",seq).text.empty(),"tracking rejects Ctrl alone");
            seq = r.hover(GHOSTTY_MODS_CTRL|GHOSTTY_MODS_SHIFT,501); log.wait("link-hover",seq);
            seq = r.scroll(-1,501,true); require(log.wait("link-hover",seq).text.empty(),"scroll invalidates hover");
            seq = r.pointer(2,0,28,18,GHOSTTY_MODS_CTRL|GHOSTTY_MODS_SHIFT,501); log.wait("link-hover",seq);
            seq = r.search("example",0,701); require(log.wait("link-hover",seq).text.empty(),"search clears link decoration");
            r.search("",0,702); r.pointer(2,0,28,18,GHOSTTY_MODS_CTRL|GHOSTTY_MODS_SHIFT,501);
            seq = r.focus(false); require(log.wait("link-hover",seq).text.empty(),"blur clears hover");
            r.close(); r.join(); require(!r.failed(),"hover lifecycle runtime");
            for (const auto& e : log.events) require(e.kind != "link","hover never opens URL");
            std::cout << "PASS link hover target, stationary modifiers, tracking override and invalidation\n";
        }
        {
            GhosttyTerminal vt = nullptr; GhosttySearch search = nullptr;
            checkVt(ghostty_terminal_new(nullptr,&vt,8,3));
            checkVt(ghostty_search_new(nullptr,&search,vt));
            auto output = [&](const std::string& text) {
                ghostty_terminal_vt_write(vt,reinterpret_cast<const uint8_t*>(text.data()),text.size());
            };
            auto query = [&](const std::string& text) {
                GhosttyString needle{reinterpret_cast<const uint8_t*>(text.data()),text.size()};
                checkVt(ghostty_search_set(search,GHOSTTY_SEARCH_OPT_NEEDLE,&needle));
                checkVt(ghostty_search_run(search));
            };
            output("one one\r\n"); query("one");
            checkVt(ghostty_search_set(search,GHOSTTY_SEARCH_OPT_SELECT_NEXT,nullptr));
            checkVt(ghostty_search_feed(search));
            auto mask = TerminalSearchHighlights::read(vt,search,8,3);
            require(TerminalSearchHighlights::overview(vt,search) == std::vector<uint32_t>{0},"overview deduplicates multiple matches on one row");
            require(std::count(mask.cells.begin(),mask.cells.end(),1) == 3 &&
                std::count(mask.cells.begin(),mask.cells.end(),2) == 3,"all matches and current match have distinct paint marks");
            query("absent");
            require(TerminalSearchHighlights::overview(vt,search).empty(),"replacing query clears overview rows");
            require(TerminalSearchHighlights::read(vt,search,8,3).cells.empty(),"replacing query removes old highlights");
            output("\x1b[2J\x1b[H123456" + std::string(u8"中😀") + "XYZ\r\nTAIL\r\nEND");
            query(u8"中😀XYZ");
            GhosttyTerminalScrollViewport scroll{}; scroll.tag = GHOSTTY_SCROLL_VIEWPORT_TOP;
            ghostty_terminal_scroll_viewport(vt,scroll); checkVt(ghostty_search_feed(search));
            mask = TerminalSearchHighlights::read(vt,search,8,3);
            require(mask.at(6,0) == 1 && mask.at(7,0) == 1 && mask.at(0,1) == 1 && mask.at(4,1) == 1 &&
                mask.at(5,1) == 0,"Unicode match spans wide cells and wrapped rows");
            scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA; scroll.value.delta = 1;
            ghostty_terminal_scroll_viewport(vt,scroll); checkVt(ghostty_search_feed(search));
            mask = TerminalSearchHighlights::read(vt,search,8,3);
            require(mask.at(0,0) == 1 && mask.at(4,0) == 1 && mask.at(0,1) == 0,"match crossing top edge is clipped instead of dropped");
            checkVt(ghostty_terminal_resize(vt,6,3,8,16)); checkVt(ghostty_search_run(search));
            mask = TerminalSearchHighlights::read(vt,search,6,3);
            require(std::count(mask.cells.begin(),mask.cells.end(),1) > 0,"reflow uses fresh match references");
            require(TerminalSearchHighlights::read(vt,nullptr,6,3).cells.empty(),"closed search has no decorations");
            ghostty_search_free(search); ghostty_terminal_free(vt);
            std::cout << "PASS search highlights: all/current, query replacement, Unicode wrap, clipping and reflow\n";
        }
        {
            GhosttyTerminal vt = nullptr; GhosttySearch search = nullptr;
            checkVt(ghostty_terminal_new(nullptr,&vt,20,3));
            std::string history;
            for (int n = 0; n < 50; ++n) history += n%10 == 0 ? "hit hit\r\n" : "plain\r\n";
            ghostty_terminal_vt_write(vt,reinterpret_cast<const uint8_t*>(history.data()),history.size());
            checkVt(ghostty_search_new(nullptr,&search,vt));
            const GhosttyString needle{reinterpret_cast<const uint8_t*>("hit"),3};
            checkVt(ghostty_search_set(search,GHOSTTY_SEARCH_OPT_NEEDLE,&needle));
            checkVt(ghostty_search_run(search));
            require(TerminalSearchHighlights::overview(vt,search) == std::vector<uint32_t>({0,10,20,30,40}),"overview includes offscreen history in screen order");
            GhosttyTerminalScrollViewport scroll{}; scroll.tag = GHOSTTY_SCROLL_VIEWPORT_TOP;
            ghostty_terminal_scroll_viewport(vt,scroll); checkVt(ghostty_search_feed(search));
            require(TerminalSearchHighlights::overview(vt,search) == std::vector<uint32_t>({0,10,20,30,40}),"overview positions do not move with viewport");
            ghostty_search_free(search); ghostty_terminal_free(vt);
            std::cout << "PASS search overview offscreen history, row deduplication and viewport independence\n";
        }
        {
            Log log;
            TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                [&](GhosttyTerminal vt,GhosttySearch search,const std::vector<uint32_t>& overview,const TerminalLink&,bool,bool) {
                    auto mask = TerminalSearchHighlights::read(vt,search,20,4);
                    require(search || overview.empty(),"closed search drops overview projection");
                    const auto other = std::count(mask.cells.begin(),mask.cells.end(),1);
                    const auto current = std::count(mask.cells.begin(),mask.cells.end(),2);
                    if (other || current) require(overview == std::vector<uint32_t>{0},"worker publishes completed overview with search results");
                    else require(overview.empty(),"missing query cannot retain overview marks");
                    log.receive({search ? "highlight:"+std::to_string(other)+","+std::to_string(current) : "no-search",0,0,{}});
                });
            r.updateDisplay([] { return TerminalRuntime::Geometry{20,4,8,16}; });
            write(r,"one one"); r.search("one",-1,101);
            log.wait("highlight:3,3");
            write(r," one"); log.wait("highlight:6,3");
            r.search("missing",0,102); log.wait("highlight:0,0");
            write(r,"\x1b[?1049hALT"); log.wait("search-close");
            r.close(); r.join(); require(!r.failed(),"paint borrows only live search state across output and screen changes");
            std::cout << "PASS worker search projection refresh on output, query and alternate screen\n";
        }
        {
            const auto grid = TerminalGrid::fit(816,416,8,16,8);
            for (int inset : {8,15,18,24}) {
                const auto scaled = TerminalGrid::fit(1800,1200,18,40,inset);
                const auto top = TerminalScrollbar::fit(scaled,{10000,0,20});
                const auto end = TerminalScrollbar::fit(scaled,{10000,9980,20});
                require(top.visible() && top.row(top.y) == 0 && end.row(end.thumbY) == 9980,"scrollbar endpoint roundtrip");
                require(top.row(-100) == 0 && top.row(10000) == 9980,"drag clamps outside Surface");
                require(top.hit(1800-inset,100) && !top.hit(1800-inset-1,100) && !top.hit(1800,100),"eight-vp gutter hit bounds");
                require(!TerminalScrollbar::fit(scaled,{20,0,20}).visible(),"no-history scrollbar hidden");
                require(top.markerY(0,10000,4) == top.y && top.markerY(9999,10000,4) == top.y+top.height-4,"overview maps first and last rows inside track");
                const auto shortPage = TerminalScrollbar::fit(scaled,{20,0,20});
                require(std::isfinite(shortPage.thumbY) && shortPage.thumbY == shortPage.y,"unscrollable page retains finite thumb geometry");
                require(shortPage.height > 0 && shortPage.markerY(19,20,4) == shortPage.y+shortPage.height-4,"overview also covers an unscrollable page");
            }
            Log log; GhosttyTerminal observed = nullptr;
            TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                [&](GhosttyTerminal terminal,GhosttySearch,const std::vector<uint32_t>&,const TerminalLink&,bool,bool) { observed = terminal; log.receive({"paint",1,0,{}}); });
            r.updateDisplay([&] { return grid; }); log.wait("paint");
            // Sample only on the VT worker. A display command also ends any old
            // drag, so gesture sequences below are completed before sampling.
            auto sample = [&] {
                GhosttyTerminalScrollbar value{};
                auto seq = r.updateDisplay([&] { checkVt(ghostty_terminal_get(observed,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&value)); return grid; });
                log.wait("consumed",seq); return value;
            };
            std::string history;
            for (int n = 0; n < 300; ++n) history += "ROW-"+std::to_string(n)+"\r\n";
            write(r,history+"\x1b[?1000h\x1b[?1006h");
            auto bottom = sample(); require(bottom.offset == bottom.total-bottom.len && bottom.offset > 200,"real retained VT history");
            auto thumb = TerminalScrollbar::fit(grid,bottom);
            r.pointer(0,1,812,static_cast<int>(thumb.thumbY+3),0,77);
            r.pointer(2,1,300,-100,0,77); r.pointer(1,1,300,-100,0,77);
            auto top = sample(); require(top.offset == 0,"thumb drag reaches oldest history outside gutter");
            r.pointer(0,1,812,400,0,77); r.pointer(1,1,812,400,0,77);
            auto page = sample(); require(page.offset == top.len-1,"track click pages locally despite mouse reporting");
            thumb = TerminalScrollbar::fit(grid,page);
            r.pointer(0,1,812,static_cast<int>(thumb.thumbY+3),0,77);
            write(r,"APPENDED-WHILE-DRAGGING\r\n");
            r.pointer(2,1,812,800,0,77); r.pointer(1,1,812,800,0,77);
            bottom = sample(); require(bottom.offset == bottom.total-bottom.len,"drag uses current range after output growth");
            thumb = TerminalScrollbar::fit(grid,bottom);
            r.pointer(0,1,812,static_cast<int>(thumb.thumbY+3),0,77); r.focus(false);
            r.pointer(2,1,812,10,0,77); r.pointer(1,1,812,10,0,77);
            require(sample().offset == bottom.offset,"blur cancels scrollbar drag");
            r.pointer(0,1,812,static_cast<int>(thumb.thumbY+3),0,77); r.visibility(false); r.visibility(true);
            r.pointer(2,1,812,10,0,77); r.pointer(1,1,812,10,0,77);
            require(sample().offset == bottom.offset,"hidden window cancels scrollbar drag");
            r.pointer(0,1,812,static_cast<int>(thumb.thumbY+3),0,77); r.updateDisplay([&] { return grid; });
            r.pointer(2,1,812,10,0,77); r.pointer(1,1,812,10,0,77);
            require(sample().offset == bottom.offset,"Surface update cancels scrollbar drag");
            write(r,"\x1b[?1049hALT");
            require(!TerminalScrollbar::fit(grid,sample()).visible(),"alternate screen has no scrollbar");
            write(r,"\x1b[?1049l");
            require(TerminalScrollbar::fit(grid,sample()).visible(),"primary history scrollbar returns");
            r.close(); r.join(); require(!r.failed(),"scrollbar runtime");
            for (const auto& e : log.events) require(e.kind != "input" || e.owner != 77,"gutter gestures never leak to PTY mouse reporting");
            std::cout << "PASS scrollbar geometry, real VT drag/page/output, alternate screen and lifecycle cancellation\n";
        }
        {
            for (const int inset : {8,13,16,24}) for (const int cw : {9,13,18}) {
                const int ch = 2*cw;
                for (int width = 250; width < 300; ++width) for (int height = 160; height < 200; ++height) {
                    const auto grid = TerminalGrid::fit(width,height,cw,ch,inset);
                    const int right = width-grid.x-grid.cols*cw, bottom = height-grid.y-grid.rows*ch;
                    require(grid.x >= inset && grid.y >= inset && right >= inset && bottom >= inset,"minimum inset");
                    require(std::abs(grid.x-right) <= 1 && std::abs(grid.y-bottom) <= 1,"opposite edges differ by at most one physical pixel");
                    require((grid.cols+1)*cw+2*inset > width && (grid.rows+1)*ch+2*inset > height,"maximum fitting cells");
                }
            }
            const auto tiny = TerminalGrid::fit(1,1,18,36,16);
            require(tiny.cols == 1 && tiny.rows == 1 && tiny.x == 0 && tiny.y == 0,"tiny surfaces retain a nonnegative clipped cell");
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            r.updateDisplay([] { return TerminalRuntime::Geometry{20,4,8,16,19,23}; });
            write(r,"\x1b]8;;https://example.org\x1b\\link\x1b]8;;\x1b\\");
            r.pointer(0,1,27,24,GHOSTTY_MODS_CTRL,57);
            auto click = r.pointer(1,1,27,24,GHOSTTY_MODS_CTRL,57);
            require(log.wait("link",click).text == "https://example.org","links use grid-relative coordinates");
            write(r,"\x1b[?1000h\x1b[?1006h");
            auto press = r.pointer(0,1,27,40,0,58);
            require(log.wait("input",press).text == "\x1b[<0;2;2M","PTY mouse reports exclude inset and remainder");
            r.pointer(1,1,27,40,0,58);
            r.updateDisplay([] { return TerminalRuntime::Geometry{20,4,8,16,11,15}; });
            auto wheel = r.scroll(1,58);
            require(log.wait("input",wheel).text == "\x1b[<65;3;2M","resize rebases a stationary pointer before wheel reporting");
            r.updateDisplay([] { return TerminalRuntime::Geometry{20,4,8,16,19,23}; });
            write(r,"\x1b[?1000l");
            r.pointer(0,1,19,24,0,59); r.pointer(2,1,51,24,0,59); r.pointer(1,1,51,24,0,59);
            r.copy(0,59); require(log.wait("copy",0,59).text == "link","selection shares the shifted grid");
            r.close(); r.join(); require(!r.failed(),"inset geometry runtime");
            std::cout << "PASS centered measured geometry, resize, scaled insets and shifted input coordinates\n";
        }
        {
            Log log; std::atomic<unsigned> frames{0}; std::atomic<bool> released{false};
            TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                [&](GhosttyTerminal, GhosttySearch, const std::vector<uint32_t>&, const TerminalLink&, bool, bool) { log.receive({"paint",++frames,0,{}}); },
                [&] { released = true; });
            r.updateDisplay([] { return TerminalRuntime::Geometry{80,24,8,16}; });
            r.focus(true); write(r,"VISIBLE\x1b[?12h"); log.wait("paint");
            log.wait("consumed",r.visibility(false)); const auto hiddenFrames = frames.load();
            write(r,"-BACKGROUND\x1b[6n");
            log.wait("consumed",r.barrier(0)); require(log.wait("reply").owner == 7,"hidden terminal still replies");
            require(snapshot(r,log).find("VISIBLE-BACKGROUND") != std::string::npos,"hidden output is retained");
            std::this_thread::sleep_for(std::chrono::milliseconds(650));
            require(frames == hiddenFrames,"hidden output and blinking must not paint");
            bool committed = false;
            r.visibility(true,[&] { committed = true; });
            log.wait("paint",hiddenFrames+1);
            require(committed,"visibility generation commits before resumed paint");
            r.focus(false); log.wait("consumed",r.barrier(0));
            const auto beforeUnfocused = frames.load(); write(r,"-UNFOCUSED");
            log.wait("paint",beforeUnfocused+1);
            require(snapshot(r,log).find("BACKGROUND-UNFOCUSED") != std::string::npos,"visible unfocused Pane still updates");
            log.wait("consumed",r.visibility(false)); const auto closingFrames = frames.load();
            const auto tail = write(r,"-TAIL"); r.close(); r.join();
            log.wait("consumed",tail);
            require(!r.failed() && released && frames == closingFrames,"hidden close drains and releases without painting");
            std::cout << "PASS visibility pauses paint and blink, preserves VT/replies, resumes and closes independently of focus\n";
        }
        {
            Log leftLog, rightLog;
            TerminalRuntime left([&](TerminalEvent e) { return leftLog.receive(std::move(e)); });
            TerminalRuntime right([&](TerminalEvent e) { return rightLog.receive(std::move(e)); });
            write(left,"LEFT-LOCAL",0); write(right,"RIGHT-SSH",22);
            const auto local = snapshot(left,leftLog);
            left.beginTemporary(11); write(left,"LEFT-MOSH\x1b[?1049hLEFT-ALT",11);
            left.updateDisplay([] { return TerminalRuntime::Geometry{}; });
            write(left,"-DETACHED",11); write(right,"-CONTINUES",22);
            left.updateDisplay([] { return TerminalRuntime::Geometry{40,6,8,16}; });
            auto screen = snapshot(left,leftLog);
            require(screen.find("LEFT-ALT-DETACHED") != std::string::npos,"Mosh alternate survives display replacement");
            require(screen.find("RIGHT") == std::string::npos,"no other Pane bytes during rebuild");
            left.endTemporary(0);
            require(snapshot(left,leftLog) == local,"Mosh exit restores original local page after resize");
            left.close(); left.join();
            write(right,"-AFTER-LEFT-CLOSE\x1b[6n",22);
            screen = snapshot(right,rightLog);
            require(screen.find("RIGHT-SSH-CONTINUES-AFTER-LEFT-CLOSE") != std::string::npos,"other Pane stays usable after close");
            require(screen.find("LEFT-LOCAL") == std::string::npos && screen.find("LEFT-MOSH") == std::string::npos &&
                screen.find("LEFT-ALT") == std::string::npos,"closed Pane cannot leak history");
            require(rightLog.wait("reply").owner == 22,"remaining Pane reply owner preserved");
            right.close(); right.join(); require(!left.failed() && !right.failed(),"two Pane lifetimes");
            std::cout << "PASS concurrent Pane isolation, Mosh alternate display replacement and independent close\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            r.resize(20,3,8,16); write(r,"Alpha\r\nbeta\r\nALPHA\r\ntail");
            r.search("alpha",0,61); require(log.wait("search",0,61).text == "1,2","first search selects oldest, ASCII case insensitive");
            r.search("alpha",1,62); require(log.wait("search",0,62).text == "2,2","Enter moves toward newer matches");
            r.search("alpha",1,63); require(log.wait("search",0,63).text == "1,2","forward navigation wraps");
            r.search("absent",0,64); require(log.wait("search",0,64).text == "0,0","missing query reports no results");
            auto ctrl = r.copy(1,65); require(log.wait("input",ctrl).text == "\x03","missing query drops old search selection");
            r.search("alpha",0,66); log.wait("search",0,66);
            write(r,"\x1b[?1049hother\x1b[?1049l"); log.wait("search-close",0,66);
            ctrl = r.copy(1,67); require(log.wait("input",ctrl).text == "\x03","buffer transition clears search selection on both screens");
            write(r,"\x1b[?1049h\x1b[?1h");
            const auto wheel = r.scroll(-1,68); require(log.wait("input",wheel).text == "\x1bOA","alternate wheel uses mode-aware cursor encoding");
            write(r,"\x1b[?1003h\x1b[?1006h");
            const auto hover = r.pointer(2,0,8,16,0,69); require(log.wait("input",hover).text == "\x1b[<35;2;2M","all-motion reporting preserves no-button hover");
            r.close(); r.join(); require(!r.failed(),"search lifecycle runtime");
            std::cout << "PASS search navigation, missing result, screen lifetime and alternate wheel\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            r.resize(20,4,8,16); write(r,"alpha beta");
            r.pointer(0,1,8,8,0,51); r.pointer(1,1,8,8,0,51);
            r.pointer(0,1,8,8,0,51); r.pointer(1,1,8,8,0,51);
            r.search("",0,51); log.wait("search",0,51);
            r.copy(0,51); r.close(); r.join();
            require(!r.failed(),"double-click must not fail the runtime");
            require(log.wait("copy").text == "alpha","double-click selects actual word");
            std::cout << "PASS physical selection gesture double-click\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            r.resize(20,4,8,16); write(r,"alpha beta\r\ngamma delta");
            r.pointer(0,1,1,8,0,52); r.pointer(2,1,39,8,0,52); r.pointer(1,1,39,8,0,52);
            r.copy(0,52); r.close(); r.join();
            require(!r.failed(),"drag must not fail the runtime");
            require(log.wait("copy").text == "alpha","drag selects real cells");
            std::cout << "PASS physical selection gesture drag\n";
        }
        {
            Log log; std::atomic<uint32_t> phase{0};
            TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                [&](GhosttyTerminal terminal,GhosttySearch,const std::vector<uint32_t>&,const TerminalLink&,bool,bool) {
                    GhosttyRenderState state = nullptr;
                    checkVt(ghostty_render_state_new(nullptr,&state));
                    checkVt(ghostty_render_state_update(state,terminal));
                    GhosttyRenderStateCursorVisualStyle style;
                    bool visible = false, inViewport = false, blinking = false;
                    checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,&style));
                    checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,&visible));
                    checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,&inViewport));
                    checkVt(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING,&blinking));
                    ghostty_render_state_free(state);
                    log.receive({"cursor-state",0,phase.load(),std::to_string(style)+","+std::to_string(visible)+","+
                        std::to_string(inViewport)+","+std::to_string(blinking)});
                });
            r.updateDisplay([] { return TerminalRuntime::Geometry{20,3,8,16}; }); r.focus(true);
            auto stateAfter = [&](const std::string& bytes) {
                log.wait("consumed",write(r,bytes)); ++phase; r.focus(true);
                return log.wait("cursor-state",0,phase.load()).text;
            };
            const auto defaultCursor = std::to_string(GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR)+",1,1,1";
            require(stateAfter("initial") == defaultCursor,"new Pane uses visible blinking bar");
            r.beginTemporary(529);
            require(stateAfter("temporary") == defaultCursor,"temporary Mosh page uses same default cursor");
            r.endTemporary(0);
            require(stateAfter("\x1b[2 q\x1b[0 q") == defaultCursor,"DECSCUSR zero restores configured defaults");
            require(stateAfter("\x1b[2 q\x1b" "c") == defaultCursor,"RIS restores configured defaults");
            for (int mode = 1; mode <= 6; ++mode) {
                const auto style = mode <= 2 ? GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK : mode <= 4 ?
                    GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE : GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR;
                require(stateAfter("\x1b["+std::to_string(mode)+" q") ==
                    std::to_string(style)+",1,1,"+std::to_string(mode%2),"DECSCUSR style and blinking reach renderer");
            }
            const auto bar = std::to_string(GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR);
            require(stateAfter("\x1b[?25l") == bar+",0,1,0","DECTCEM hides cursor");
            require(stateAfter("\x1b[?25h") == bar+",1,1,0","DECTCEM restores cursor");
            stateAfter("one\r\ntwo\r\nthree\r\nfour\r\nfive");
            log.wait("consumed",r.scroll(-10,523,true)); ++phase; r.focus(true);
            require(log.wait("cursor-state",0,phase.load()).text == bar+",1,0,0","history viewport excludes live cursor");
            r.close(); r.join(); require(!r.failed(),"cursor state runtime");
            std::cout << "PASS cursor styles, blink, visibility and history viewport\n";
        }
        for (const bool reverse : {false,true}) {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            // Centered Surface coordinates must preserve rectangular Unicode cells.
            r.updateDisplay([] { return TerminalRuntime::Geometry{20,4,8,16,13,9}; });
            write(r,u8"a中bcZ\r\nd😀efZ\r\ng界hiZ");
            const int left = 13+8+1, right = 13+5*8-1, top = 9+8, bottom = 9+40;
            r.pointer(0,1,reverse ? right : left,reverse ? bottom : top,GHOSTTY_MODS_ALT,521);
            r.pointer(2,1,reverse ? left : right,reverse ? top : bottom,GHOSTTY_MODS_ALT,521);
            r.pointer(1,1,reverse ? left : right,reverse ? top : bottom,GHOSTTY_MODS_ALT,521);
            r.copy(0,521); r.close(); r.join();
            require(!r.failed(),"rectangular selection runtime");
            require(log.wait("copy").text == u8"中bc\n😀ef\n界hi","rectangle copies only selected columns in reading order");
            std::cout << "PASS Unicode rectangle " << (reverse ? "reverse" : "forward") << "\n";
        }
        {
            Log log; std::atomic<uint32_t> phase{0};
            TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); },
                [&](GhosttyTerminal terminal,GhosttySearch,const std::vector<uint32_t>&,const TerminalLink&,bool,bool) {
                    GhosttyTerminalScrollbar bar{};
                    checkVt(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&bar));
                    log.receive({"viewport",0,phase.load(),std::to_string(bar.offset)});
                });
            r.updateDisplay([] { return TerminalRuntime::Geometry{20,3,8,16}; }); r.focus(true);
            for (int line = 0; line < 30; ++line) write(r,"line"+std::to_string(line)+"\r\n");
            r.pointer(0,1,1,40,0,522); r.pointer(2,1,1,-16,0,522);
            log.wait("consumed",r.barrier(0));
            const auto released = r.pointer(1,1,1,-16,0,522); log.wait("consumed",released);
            phase = 1; r.focus(true); const auto before = log.wait("viewport",0,1).text;
            std::this_thread::sleep_for(std::chrono::milliseconds(160));
            phase = 2; r.focus(true);
            require(log.wait("viewport",0,2).text == before,"released edge selection stops viewport scrolling");
            r.copy(0,522); r.close(); r.join();
            require(!r.failed() && !log.wait("copy").text.empty(),"edge selection survives release");
            std::cout << "PASS edge selection stops on release\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            r.updateDisplay([] { return TerminalRuntime::Geometry{20,3,8,16}; }); r.focus(true);
            write(r,"oldA\r\noldB\r\noldC\r\noldD\r\noldE");
            r.pointer(0,1,1,40,0,53); r.pointer(2,1,1,-16,0,53);
            log.wait("consumed",r.barrier(0));
            r.focus(false); r.copy(0,53); r.close(); r.join();
            require(!r.failed(),"autoscroll runtime");
            auto selected = log.wait("copy").text;
            require(selected.find("oldB") != std::string::npos && selected.find("oldD") != std::string::npos,
                "held out-of-bounds drag expands into history before focus loss stops scrolling");
            std::cout << "PASS held drag scrolls retained history and stops on blur\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            r.resize(20,4,8,16);
            write(r,u8"alpha 中😀 omega\r\nsecond alpha\r\nthird\r\nfourth\r\nfifth");
            r.search("alpha",-1,91); auto match = log.wait("search");
            require(match.owner == 91 && match.text == "2,2", "search covers scrollback and selects newest");
            auto copied = r.copy(0,43); (void)copied;
            auto selection = log.wait("copy"); require(selection.text == "alpha" && selection.owner == 43,"copy follows real selected match");
            r.search("",0,92); log.wait("consumed",r.barrier(0));
            auto paste = r.paste("a\nb",44); require(log.wait("input",paste).text == "a\rb","plain paste newline encoding");
            write(r,"\x1b[?2004h");
            paste = r.paste("a\nb\x1b[201~",45);
            require(log.wait("input",paste).text == "\x1b[200~a\nb [201~\x1b[201~","bracketed paste preserves newline and cannot inject terminator");
            const auto alt = r.key(GHOSTTY_KEY_B,GHOSTTY_MODS_ALT,"b",46);
            require(log.wait("input",alt).text == "\x1b" "b","Alt letter has text");
            write(r,"\x1b[2J\x1b[Hhttps://example.com\r\n\x1b]8;;https://example.org\x1b\\link\x1b]8;;\x1b\\");
            r.pointer(0,1,8,0,GHOSTTY_MODS_CTRL,47);
            const auto click = r.pointer(1,1,8,0,GHOSTTY_MODS_CTRL,47);
            require(log.wait("link",click).text == "https://example.com","plain URL requires matching local activation");
            r.pointer(0,1,8,16,GHOSTTY_MODS_CTRL,47);
            const auto oscLink = r.pointer(1,1,8,16,GHOSTTY_MODS_CTRL,47);
            require(log.wait("link",oscLink).text == "https://example.org","OSC8 URL follows actual cell metadata");
            write(r,"\x1b[?1000h\x1b[?1006h");
            const auto mouse = r.pointer(0,1,8,16,0,48);
            require(log.wait("input",mouse).text == "\x1b[<0;2;2M","mouse tracking uses current VT modes and physical geometry");
            r.close(); r.join(); require(!r.failed(),"interaction runtime");
            std::cout << "PASS native history search, selection copy, paste, Alt, links and mouse reporting\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            const std::string osc = "\x1b]52;c;aGVsbG8=\x1b\\";
            for (char ch : osc) write(r,std::string(1,ch),17);
            require(log.wait("clipboard").text == "hello","fragmented OSC52 write");
            write(r,"\x1b]52;p;aGVsbG8=\a\x1b]52;c;?\a\x1b]52;c;/w==\a\x1b]52;c;YQ=\a",17);
            write(r,"\x1b]99;i=test:p=?;\x1b\\",17);
            require(log.wait("reply").text == "\x1b]99;i=test:p=?;p=title,body\x1b\\","bounded OSC99 capabilities");
            write(r,"\x1b]99;i=t:p=title:d=1;Ready\a\x1b]777;notify;title;body\a",17);
            write(r,"\x1b]99;i=t:p=title:d=0;partial\a\x1b]99;i=t:p=alive;query\a",17);
            write(r,"\x1b]52;c;",17); write(r,"d3Jvbmc=\a",18);
            r.close(); r.join(); require(!r.failed(),"effect runtime");
            size_t clipboard = 0,bells = 0;
            for (const auto& event : log.events) { if (event.kind == "clipboard") ++clipboard; if (event.kind == "bell") ++bells; }
            require(clipboard == 1,"invalid/read/foreign-selector/cross-owner clipboard rejected");
            require(bells == 2,"only complete permitted notification frames create attention");
            std::cout << "PASS complete OSC framing, strict clipboard and notification boundaries\n";
        }
        const std::string fixture = u8"HEAD\r\n中😀é\x1b[31mRED\x1b[0m\x1b[6n\r\nTAIL";
        const auto whole = fragmented(fixture, fixture.size());
        require(whole == fragmented(fixture, 1), "UTF8/control one-byte splits");
        require(whole == fragmented(fixture, 7), "UTF8/control seven-byte splits");
        require(whole.first.find("TAIL") != std::string::npos && !whole.second.empty(), "content and query response");
        std::cout << "PASS split output and original-owner replies\n";
        for (bool endOnAlternate : {false, true}) {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            write(r,"SESSION_HISTORY\r\n\x1b[>1u\x1b[>3u\x1b[?47h\x1b[>1u\x1b[>9u");
            if (!endOnAlternate) write(r,"\x1b[?47l");
            write(r,sessionResetSequence);
            const auto primary = write(r,"\x1b[?u");
            require(log.wait("reply",primary).text == "\x1b[?0u", "session reset clears primary keyboard stack");
            const auto alternate = write(r,"\x1b[?47h\x1b[?u");
            require(log.wait("reply",alternate).text == "\x1b[?0u", "session reset clears alternate keyboard stack");
            write(r,"\x1b[?47l");
            const auto snapshot = r.snapshot();
            require(log.wait("snapshot",snapshot).text.find("SESSION_HISTORY") != std::string::npos, "session keyboard reset preserves history");
            r.close(); r.join(); require(!r.failed(),"session keyboard reset runtime");
        }
        std::cout << "PASS actual session reset clears both keyboard stacks and preserves history\n";
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            auto key = [&](GhosttyKey code, GhosttyMods mods, const std::string& text, uint32_t base) {
                const auto seq = r.key(code,mods,text,41,base);
                return log.wait("input",seq).text;
            };
            require(key(GHOSTTY_KEY_B,GHOSTTY_MODS_CTRL,"b",'b') == "\x02", "legacy Ctrl-B");
            require(key(GHOSTTY_KEY_B,GHOSTTY_MODS_ALT,"b",'b') == "\x1b" "b", "legacy Alt-B");
            write(r,"\x1b[>1u");
            require(key(GHOSTTY_KEY_B,GHOSTTY_MODS_CTRL,"b",'b') == "\x1b[98;5u", "enhanced Ctrl-B retains modifier");
            require(key(GHOSTTY_KEY_B,GHOSTTY_MODS_ALT,"b",'b') == "\x1b[98;3u", "enhanced Alt-B retains modifier");
            require(key(GHOSTTY_KEY_B,GHOSTTY_MODS_SHIFT,"B",'b') == "B", "enhanced shifted text remains printable");
            require(key(GHOSTTY_KEY_DIGIT_1,GHOSTTY_MODS_SHIFT,"!",'1') == "!", "enhanced shifted punctuation remains printable");
            require(key(GHOSTTY_KEY_SPACE,GHOSTTY_MODS_SHIFT," ",' ') == "\x1b[32;2u", "Shift-Space is not consumed by unchanged text");
            require(key(GHOSTTY_KEY_B,GHOSTTY_MODS_CTRL | GHOSTTY_MODS_SHIFT,"B",'b') == "\x1b[98;6u", "enhanced Ctrl-Shift-B uses unshifted codepoint");
            require(key(GHOSTTY_KEY_DIGIT_1,GHOSTTY_MODS_CTRL | GHOSTTY_MODS_SHIFT,"!",'1') == "\x1b[49;6u", "shifted punctuation retains base key");
            require(key(GHOSTTY_KEY_UNIDENTIFIED,0,u8"中😀",0) == u8"中😀", "enhanced IME text is not a physical key");
            write(r,"\x1b[<1u");
            require(key(GHOSTTY_KEY_B,GHOSTTY_MODS_CTRL,"b",'b') == "\x02", "protocol pop restores legacy Ctrl-B");
            r.close(); r.join(); require(!r.failed(),"enhanced keyboard runtime");
            std::cout << "PASS enhanced keyboard modifiers, shifted keys and IME commits\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            const auto layout = r.updateDisplay([] { return TerminalRuntime::Geometry{100,30,9,18}; });
            require(layout != 0, "display geometry admitted");
            write(r, "\x1b[999;999H\x1b[6n", 23);
            require(log.wait("reply").text == "\x1b[30;100R", "geometry committed before following output");
            const auto ctrl = r.key(GHOSTTY_KEY_C,GHOSTTY_MODS_CTRL,{},41);
            require(log.wait("input",ctrl).text == "\x03" && log.wait("input",ctrl).owner == 41, "Ghostty Ctrl-C owner encoding");
            write(r,"\x1b[?1h",23);
            const auto arrow = r.key(GHOSTTY_KEY_ARROW_UP,0,{},42);
            require(log.wait("input",arrow).text == "\x1bOA", "application cursor encoding follows VT state");
            const auto text = r.key(GHOSTTY_KEY_UNIDENTIFIED,0,u8"中😀",43);
            require(log.wait("input",text).text == u8"中😀", "IME UTF8 commit encoding");
            r.close(); r.join(); require(!r.failed(), "input runtime");
            std::cout << "PASS atomic display geometry and mode-aware original-owner input\n";
        }
        {
            Log log; std::promise<void> release; auto gate = release.get_future().share();
            TerminalRuntime r([&](TerminalEvent e) { if (e.kind == "ready") gate.wait(); return log.receive(std::move(e)); });
            std::string chunk(TerminalRuntime::ChunkLimit, 'a');
            uint64_t last = 0;
            for (int i = 0; i < 4; ++i) last = write(r, chunk);
            require(r.queuedBytes() == TerminalRuntime::QueueLimit, "full queue accounting");
            require(!r.write(reinterpret_cast<const uint8_t*>(chunk.data()), 1, 7), "full rejects whole chunk");
            auto barrier = r.barrier(7); require(barrier > last, "control independent of data capacity");
            r.close(); require(!r.barrier(7), "closed rejects control");
            require(!r.write(reinterpret_cast<const uint8_t*>(chunk.data()), 1, 7), "closed rejects data");
            release.set_value(); r.join(); require(!r.failed(), "close drains accepted bytes");
            log.wait("consumed", barrier); require(r.queuedBytes() == 0, "queue released");
            std::cout << "PASS bounded admission, control reserve and close drain without GPU\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { return log.receive(std::move(e)); });
            std::string original = "PERMANENT-HISTORY"; write(r, original, 0); original.assign(original.size(), 'x');
            auto before = snapshot(r, log); require(before.find("PERMANENT-HISTORY") != std::string::npos, "copy before acceptance");
            require(r.beginTemporary(11) != 0, "temporary admission");
            write(r, "MOSH-NORMAL\x1b[?1049hMOSH-ALT\x1b[?1049l", 11);
            auto temporary = snapshot(r, log);
            require(temporary.find("MOSH-NORMAL") != std::string::npos, "independent alternate buffer");
            require(temporary.find("PERMANENT") == std::string::npos, "temporary isolation");
            require(r.endTemporary(0) != 0, "page-end admission");
            require(snapshot(r, log) == before, "regular history preserved");
            r.close(); r.join(); require(!r.failed(), "page runtime");
            std::cout << "PASS input ownership copy and temporary VT/history isolation\n";
        }
        {
            Log log; TerminalRuntime r([&](TerminalEvent e) { if (e.kind == "reply") return false; return log.receive(std::move(e)); });
            auto seq = write(r, "\x1b[6n"); log.wait("failure"); r.join();
            require(r.failed(), "failed callback stops runtime");
            for (auto& e : log.events) require(e.kind != "consumed" || e.sequence != seq, "no false consumption ACK");
            std::cout << "PASS rejected callback is observable and never acknowledged as consumed\n";
        }
        std::cout << "Terminal runtime contracts passed\n"; return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}

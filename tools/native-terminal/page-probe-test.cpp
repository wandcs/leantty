#include "TerminalRuntime.h"
#include <iostream>
#include <stdexcept>
using namespace leantty;
static void require(bool ok) { if (!ok) throw std::runtime_error("native page probe contract"); }
int main() {
    try {
        std::mutex mutex; std::condition_variable changed; std::vector<TerminalEvent> events;
        TerminalRuntime terminal([&](TerminalEvent e) {
            std::lock_guard<std::mutex> lock(mutex); events.push_back(std::move(e)); changed.notify_all(); return true;
        });
        auto wait = [&](const std::string& kind, uint64_t seq) {
            std::unique_lock<std::mutex> lock(mutex);
            auto find = [&]() -> const TerminalEvent* { for (const auto& e : events) if (e.kind == kind && e.sequence == seq) return &e; return nullptr; };
            require(changed.wait_for(lock,std::chrono::seconds(10),[&] { return find() != nullptr; }));
            return *find();
        };
        auto write = [&](const std::string& s) { auto seq=terminal.write(reinterpret_cast<const uint8_t*>(s.data()),s.size(),17); require(seq!=0); wait("consumed",seq); };
        auto fingerprint = [&](uint64_t seq, const std::string& phase) {
            wait("consumed",seq); std::lock_guard<std::mutex> lock(mutex);
            for (const auto& e : events) if (e.kind=="acceptance-page" && e.sequence==seq && e.text.find("action="+phase+" ")==0) return e.text.substr(e.text.find("cols="));
            throw std::runtime_error("missing native page observation");
        };
        wait("consumed",terminal.resize(60,8,8,16));
        for(int i=0;i<120;i++) write("\x1b[31mPUBLIC-PAGE-"+std::to_string(i)+"\x1b[0m\r\n");
        wait("consumed",terminal.scroll(-24,0,true));
        auto begin=terminal.beginTemporary(0);
        auto saved=fingerprint(begin,"saved"), active=fingerprint(begin,"active");
        require(saved!=active && saved.find("PUBLIC-PAGE")==std::string::npos);
        write("REMOTE\x1b[?1049hALTERNATE\x1b[?25l");
        auto end=terminal.endTemporary(0);
        auto restored=fingerprint(end,"restored");
        require(saved==restored && end>begin);
        // Same text with changed cursor/style must be distinguishable; the probe
        // records the real worker boundary before subsequent local output.
        write("\x1b[32m\x1b[3;7H");
        auto begin2=terminal.beginTemporary(0);
        require(fingerprint(begin2,"saved")!=restored);
        fingerprint(terminal.endTemporary(0),"restored");
        terminal.close(); terminal.join(); require(!terminal.failed());
        std::cout << "PASS native worker page probe: styled history/viewport preserved, temporary alternate isolated, cursor/style detected, no plaintext, before-local-output ordering\n";
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}

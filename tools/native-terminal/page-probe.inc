// Acceptance-only, called on the real VT worker. No terminal content leaves it.
static std::string acceptancePageFingerprint(GhosttyTerminal terminal) {
    GhosttyFormatterTerminalOptions options = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    options.extra = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalExtra);
    options.extra.palette = options.extra.modes = options.extra.scrolling_region = true;
    options.extra.tabstops = options.extra.pwd = options.extra.keyboard = true;
    options.extra.screen = GHOSTTY_INIT_SIZED(GhosttyFormatterScreenExtra);
    options.extra.screen.cursor = options.extra.screen.style = options.extra.screen.hyperlink = true;
    options.extra.screen.protection = options.extra.screen.kitty_keyboard = options.extra.screen.charsets = true;
    GhosttyFormatter formatter = nullptr; uint8_t* bytes = nullptr; size_t count = 0;
    checkVt(ghostty_formatter_terminal_new(nullptr, &formatter, terminal, options));
    const auto result = ghostty_formatter_format_alloc(formatter, nullptr, &bytes, &count);
    ghostty_formatter_free(formatter); checkVt(result);
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < count; ++i) { hash ^= bytes[i]; hash *= UINT64_C(1099511628211); }
    ghostty_free(nullptr, bytes, count);
    std::string hex(16, '0');
    for (size_t i = 0; i < 16; ++i) { hex[15-i] = "0123456789abcdef"[hash & 15]; hash >>= 4; }
    uint16_t cols = 0, rows = 0;
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    GhosttyTerminalScrollbar bar{};
    checkVt(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols));
    checkVt(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows));
    checkVt(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen));
    checkVt(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar));
    return "cols=" + std::to_string(cols) + " rows=" + std::to_string(rows) +
        " screen=" + std::to_string(screen) + " viewport=" + std::to_string(bar.offset) +
        " total=" + std::to_string(bar.total) + " hash=" + hex;
}

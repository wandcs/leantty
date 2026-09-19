# Called within the existing native acceptance wrapper, which owns restoration.
function Add-LeanTTYNativePageAcceptanceSource {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $pageHeaderPath = Join-Path $RepoRoot 'entry/src/main/cpp/terminal/TerminalRuntime.h'
    $pageSourcePath = Join-Path $RepoRoot 'entry/src/main/cpp/terminal/TerminalRuntime.cpp'
    $pageHeader = [IO.File]::ReadAllText($pageHeaderPath)
    $pageSource = [IO.File]::ReadAllText($pageSourcePath)
    $pageHeader = Set-LeanTTYAcceptanceSourceText $pageHeader '    uint64_t consuming_ = 0;' `
        "    uint64_t consuming_ = 0;`n    uint64_t acceptancePageSequence_ = 0;"
    $pageTemplate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'native-terminal/page-probe.inc'))
    $pageSource = Set-LeanTTYAcceptanceSourceText $pageSource 'TerminalRuntime::TerminalRuntime(Events events, Paint paint, std::function<void()> releaseDisplay)' `
        ($pageTemplate + "`nTerminalRuntime::TerminalRuntime(Events events, Paint paint, std::function<void()> releaseDisplay)")
    $pageSource = Set-LeanTTYAcceptanceSourceText $pageSource `
        '                        if (temporary_) throw std::runtime_error("terminal_page_already_active");' @'
                        if (temporary_) throw std::runtime_error("terminal_page_already_active");
                        acceptancePageSequence_ = c.sequence;
                        emit({"acceptance-page",c.sequence,0,"action=saved page=" + std::to_string(acceptancePageSequence_) + " " + acceptancePageFingerprint(regular_)});
'@
    $pageSource = Set-LeanTTYAcceptanceSourceText $pageSource `
        '                        active_ = temporary_ = create(0); owner_ = c.owner; dirty = true;' @'
                        active_ = temporary_ = create(0); owner_ = c.owner; dirty = true;
                        emit({"acceptance-page",c.sequence,0,"action=active page=" + std::to_string(acceptancePageSequence_) + " " + acceptancePageFingerprint(active_)});
'@
    $pageSource = Set-LeanTTYAcceptanceSourceText $pageSource `
        '                        checkVt(ghostty_terminal_resize(active_, cols_, rows_, cellWidth_, cellHeight_)); dirty = true;' @'
                        checkVt(ghostty_terminal_resize(active_, cols_, rows_, cellWidth_, cellHeight_)); dirty = true;
                        emit({"acceptance-page",c.sequence,0,"action=restored page=" + std::to_string(acceptancePageSequence_) + " " + acceptancePageFingerprint(active_)});
'@
    [IO.File]::WriteAllText($pageHeaderPath, $pageHeader, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($pageSourcePath, $pageSource, [Text.UTF8Encoding]::new($false))
}

function Add-LeanTTYNativePageArkTsSource {
    param([Parameter(Mandatory)][hashtable]$Text)
    $Text.surface = Set-LeanTTYAcceptanceSourceText $Text.surface '    this.native = native' `
        "    this.native = native`n    native.acceptancePaneId = this.paneId"
    $Text.nativeController = Set-LeanTTYAcceptanceSourceText $Text.nativeController '  private handle: TerminalHandle' `
        "  acceptancePaneId: string = ''`n  private acceptanceMoshPage: boolean = false`n  private handle: TerminalHandle"
    $Text.nativeController = Set-LeanTTYAcceptanceSourceText $Text.nativeController "    if (kind === 'consumed') {" @'
    if (ACCEPTANCE_TESTS && kind === 'acceptance-page') {
      logger.info('ACCEPTANCE_NATIVE_PAGE pane=' + this.acceptancePaneId + ' sequence=' + sequence + ' ' + text)
      return
    }
    if (kind === 'consumed') {
'@
    $Text.nativeController = Set-LeanTTYAcceptanceSourceText $Text.nativeController '        this.inflight.delete(sequence)' @'
        this.inflight.delete(sequence)
        if (ACCEPTANCE_TESTS) {
          if (command.kind === 'begin') { this.acceptanceMoshPage = true }
          if (command.kind === 'end') { this.acceptanceMoshPage = false }
          if (this.acceptanceMoshPage && command.kind === 'write' && command.owner !== 0) {
            logger.info('ACCEPTANCE_NATIVE_WRITE_CONSUMED pane=' + this.acceptancePaneId +
              ' sequence=' + sequence + ' owner=' + command.owner + ' bytes=' + command.bytes.byteLength)
          }
        }
'@
    $Text.nativeController = Set-LeanTTYAcceptanceSourceText $Text.nativeController `
        "      let result = text.split(','); this.onSearchResult(Number(result[0]), Number(result[1]))" @'
      let result = text.split(','); this.onSearchResult(Number(result[0]), Number(result[1]))
      if (ACCEPTANCE_TESTS) { logger.info('ACCEPTANCE_NATIVE_SEARCH_RESULT pane=' + this.acceptancePaneId + ' generation=' + owner + ' result=' + text) }
'@
    $Text.nativeController = Set-LeanTTYAcceptanceSourceText $Text.nativeController `
        '      let accepted = terminal.search(this.handle, tooLarge ? '''' : needle, direction, this.searchGeneration)' @'
      let accepted = terminal.search(this.handle, tooLarge ? '' : needle, direction, this.searchGeneration)
      if (ACCEPTANCE_TESTS && accepted > 0 && !tooLarge) {
        logger.info('ACCEPTANCE_NATIVE_SEARCH_QUERY pane=' + this.acceptancePaneId + ' generation=' + this.searchGeneration + ' length=' + needle.length)
      }
'@
}

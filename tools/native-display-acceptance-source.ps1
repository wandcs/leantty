# Acceptance builds observe worker/page/display boundaries and can arm a one-shot
# driver fault. Production paths are unchanged; all source files are restored.
function Invoke-WithLeanTTYNativeDisplayAcceptanceSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    if (-not $Enabled) { & $Action; return }
    $nativeDisplayProbeHeaderPath = Join-Path $RepoRoot 'entry/src/main/cpp/terminal/TerminalRenderer.h'
    $nativeDisplayProbeSourcePath = Join-Path $RepoRoot 'entry/src/main/cpp/terminal/TerminalRenderer.cpp'
    $nativeDisplayProbeBindingPath = Join-Path $RepoRoot 'entry/src/main/cpp/terminal/terminal_napi.cpp'
    $nativeDisplayProbePaths = @($nativeDisplayProbeHeaderPath, $nativeDisplayProbeSourcePath, $nativeDisplayProbeBindingPath,
        (Join-Path $RepoRoot 'entry/src/main/cpp/terminal/TerminalRuntime.h'),
        (Join-Path $RepoRoot 'entry/src/main/cpp/terminal/TerminalRuntime.cpp'))
    $nativeDisplayProbeBackups = @{}
    foreach ($nativeDisplayProbePath in $nativeDisplayProbePaths) { $nativeDisplayProbeBackups[$nativeDisplayProbePath] = [IO.File]::ReadAllBytes($nativeDisplayProbePath) }
    try {
        Add-LeanTTYNativePageAcceptanceSource -RepoRoot $RepoRoot
        $nativeDisplayProbeHeader = [IO.File]::ReadAllText($nativeDisplayProbeHeaderPath)
        $nativeDisplayProbeSource = [IO.File]::ReadAllText($nativeDisplayProbeSourcePath)
        $nativeDisplayProbeBinding = [IO.File]::ReadAllText($nativeDisplayProbeBindingPath)
        $nativeDisplayProbeBinding = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeBinding `
            '    bool closing = false;' "    bool closing = false;`n    uint64_t acceptanceFrames = 0; // worker-only successful swaps`n    uint64_t acceptanceConsumed = 0; // worker-only paint watermark"
        $nativeDisplayProbeBinding = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeBinding `
            ' { b->emit({state,0,b->displayGeneration,text}); });' `
            ' { if (state == "presented") ++b->acceptanceFrames; b->emit({state,state == "presented" ? b->acceptanceConsumed : 0,b->displayGeneration,text}); });'
        $nativeDisplayProbeBinding = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeBinding `
            '[b](TerminalEvent e) { return b->emit(std::move(e)); }' `
            '[b](TerminalEvent e) { if (e.kind == "consumed") b->acceptanceConsumed = e.sequence; return b->emit(std::move(e)); }'
        $nativeDisplayProbeBinding = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeBinding `
            'b->runtime->visibility(visible,[b,generation] {' `
            'b->runtime->visibility(visible,[b,generation,visible] {'
        $nativeDisplayProbeBinding = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeBinding `
            "        b->displayGeneration = generation;`n    }));" @'
        b->displayGeneration = generation;
        if (!b->emit({"acceptance-visibility",0,generation,
            std::string(visible ? "visible" : "hidden") + " frames=" + std::to_string(b->acceptanceFrames)}))
            throw std::runtime_error("terminal_event_queue_failed");
    }));
'@
        $nativeDisplayProbeHeader = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeHeader '    bool unavailable_ = false;' `
            "    bool unavailable_ = false;`n    bool acceptanceContextLoss_ = false;`n    bool acceptanceGpuBlocked_ = false;"
        $nativeDisplayProbeSource = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeSource `
            'bool TerminalRenderer::attach(uint64_t id, int width, int height, float size, int inset, int cursorStroke) {' @'
bool TerminalRenderer::attach(uint64_t id, int width, int height, float size, int inset, int cursorStroke) {
    if (id == UINT64_MAX - 2) {
        acceptanceGpuBlocked_ = !acceptanceGpuBlocked_;
        status_("acceptance-gpu", acceptanceGpuBlocked_ ? "blocked" : "unblocked");
        if (acceptanceGpuBlocked_) releaseGpu(false);
        return true;
    }
    if (id == UINT64_MAX - 1) {
        if (!window_ || context_ == EGL_NO_CONTEXT || unavailable_) return false;
        acceptanceContextLoss_ = true;
        status_("acceptance-gpu", "armed");
        return true;
    }
'@
        $nativeDisplayProbeSource = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeSource `
            'void TerminalRenderer::createGpu() {' @'
void TerminalRenderer::createGpu() {
    if (acceptanceGpuBlocked_) {
        status_("acceptance-gpu", "initialize-rejected");
        throw std::runtime_error("acceptance_gpu_initialize_failed");
    }
'@
        $nativeDisplayProbeSource = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeSource `
            '    for (int attempt = 0; attempt < 2; ++attempt) {' `
            "    bool acceptanceRecovering = false;`n    for (int attempt = 0; attempt < 2; ++attempt) {"
        $nativeDisplayProbeSource = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeSource `
            '            if (context_ == EGL_NO_CONTEXT) createGpu();' @'
            if (context_ == EGL_NO_CONTEXT) {
                createGpu();
                if (acceptanceRecovering) status_("acceptance-gpu", "created");
            }
'@
        $nativeDisplayProbeSource = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeSource `
            '            if (!eglSwapBuffers(display_,surface_)) throw std::runtime_error("terminal_swap_failed");' @'
            if (acceptanceContextLoss_) throw std::runtime_error("acceptance_gpu_context_loss");
            if (!eglSwapBuffers(display_,surface_)) throw std::runtime_error("terminal_swap_failed");
            if (acceptanceRecovering) status_("acceptance-gpu", "swap-ok");
'@
        $nativeDisplayProbeSource = Set-LeanTTYAcceptanceSourceText $nativeDisplayProbeSource `
            '            const auto error = eglGetError(); releaseGpu(error == EGL_CONTEXT_LOST);' @'
            const bool injected = acceptanceContextLoss_;
            const auto error = acceptanceGpuBlocked_ ? EGL_NOT_INITIALIZED :
                (injected ? EGL_CONTEXT_LOST : eglGetError());
            acceptanceContextLoss_ = false;
            if (injected) { acceptanceRecovering = true; status_("acceptance-gpu", "context-lost"); }
            releaseGpu(error == EGL_CONTEXT_LOST);
            if (injected) status_("acceptance-gpu", "released");
'@
        [IO.File]::WriteAllText($nativeDisplayProbeHeaderPath, $nativeDisplayProbeHeader, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($nativeDisplayProbeSourcePath, $nativeDisplayProbeSource, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($nativeDisplayProbeBindingPath, $nativeDisplayProbeBinding, [Text.UTF8Encoding]::new($false))
        & $Action
    } finally {
        foreach ($nativeDisplayProbePath in $nativeDisplayProbePaths) {
            Restore-LeanTTYAcceptanceSourceFile -Path $nativeDisplayProbePath -Bytes $nativeDisplayProbeBackups[$nativeDisplayProbePath]
        }
    }
}

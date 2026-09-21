<# Builds the pinned official VT and our API 24 adapter. Downloads persist in
   .cache/native-terminal; generated outputs stay under build/native-terminal. #>
[CmdletBinding()]
param([switch]$Offline, [switch]$HostTests, [switch]$Acceptance, [switch]$PrepareOnly,
    [string]$SdkNativeHome = '')
$ErrorActionPreference = 'Stop'
if ($HostTests -and $Acceptance) { throw 'Host contracts must use production source' }
. (Join-Path $PSScriptRoot 'acceptance-source.ps1')
. (Join-Path $PSScriptRoot 'build-lock.ps1')
. (Join-Path $PSScriptRoot 'native-terminal-inputs.ps1')
. (Join-Path $PSScriptRoot 'formal-build-environment.ps1')
$repoRoot = Split-Path $PSScriptRoot -Parent
Invoke-WithLeanTTYBuildLock -RepoRoot $repoRoot -Operation 'build-terminal-native' -Action {
$root = Join-Path $repoRoot 'build/native-terminal'
$pin = Get-Content (Join-Path $PSScriptRoot 'native-terminal/dependencies.json') -Raw | ConvertFrom-Json
$archives = @{}
foreach ($item in @(
    @{ name = 'ghostty.zip'; url = $pin.ghosttyUrl; sha256 = $pin.ghosttySha256 },
    @{ name = 'zig.zip'; url = $pin.zigUrl; sha256 = $pin.zigSha256 }
) + @($pin.packages)) {
    $archives[$item.name] = Get-LeanTTYNativeArchive -RepoRoot $repoRoot -Name $item.name `
        -Url $item.url -Sha256 $item.sha256 -Offline:$Offline
}
if ($PrepareOnly) { Write-Host 'Pinned native terminal archives ready'; return }
$sourceName = 'ghostty-' + $pin.ghosttyCommit
$source = Join-Path $root $sourceName
$zig = Join-Path $root ('zig-x86_64-windows-' + $pin.zigVersion + '/zig.exe')

# A named install step uses the upstream static artifact. Avoid the
# unrelated shared-library symlink install on Windows; never accept a failed
# default build just because it happened to leave a static archive behind.
$buildEntry = "$sourceName/build.zig"
$build = (Read-LeanTTYPinnedZipText $archives['ghostty.zip'] $buildEntry).Replace("`r`n", "`n")
$anchor = '    // libghostty-vt xcframework (Apple only, universal binary).'
$overlay = @'
    // The final OHOS SDK link supplies the ReleaseFast runtime. Zig 0.16's
    // emutls lacks the OHOS pthread ABI; its UBSan brings non-SDK fp80 helpers.
    if (mod.vt_c.resolved_target.?.result.abi.isOpenHarmony()) {
        libghostty_vt_static.step.cast(std.Build.Step.Compile).?.bundle_compiler_rt = false;
        libghostty_vt_static.step.cast(std.Build.Step.Compile).?.bundle_ubsan_rt = false;
    }
    const leantty_static = b.step("leantty-vt-static", "Install the pinned VT static library only");
    leantty_static.dependOn(&b.addInstallLibFile(libghostty_vt_static.output, "libghostty-vt.a").step);

'@
if ($build.Split($anchor).Count -ne 2) { throw 'Ghostty static install anchor changed' }
$build = $build.Replace($anchor, $overlay + "`n" + $anchor)
# The SDK adapter already links libc. SIMD is disabled independently; tell the
# VT C module about libc so upstream selects its normal C allocator rather than
# retaining a separate Zig SMP heap across short-lived terminal workers.
$libcAnchor = '    const libghostty_vt_static = try buildpkg.GhosttyLibVt.initStatic('
if ($build.Split($libcAnchor).Count -ne 2) { throw 'Ghostty VT libc anchor changed' }
$build = $build.Replace($libcAnchor, "    mod.vt_c.link_libc = true;`n`n" + $libcAnchor)
$dependencyEntry = "$sourceName/src/build/SharedDeps.zig"
$dependency = (Read-LeanTTYPinnedZipText $archives['ghostty.zip'] $dependencyEntry).Replace("`r`n", "`n")
$dependencyAnchor = '    const uucode_mod = b.dependency("uucode", .{'
if ($dependency.Split($dependencyAnchor).Count -ne 2) { throw 'Ghostty Unicode runtime anchor changed' }
# Only the runtime inherits optimization; upstream's host table generator stays Debug.
$dependency = $dependency.Replace($dependencyAnchor, $dependencyAnchor + "`n        .optimize = cfg.optimize,")
Sync-LeanTTYPinnedZip -Archive $archives['ghostty.zip'] -Destination $root `
    -Overrides @{ $buildEntry = $build; $dependencyEntry = $dependency }
Sync-LeanTTYPinnedZip -Archive $archives['zig.zip'] -Destination $root
if ((& $zig version).Trim() -cne $pin.zigVersion) { throw 'Unexpected Zig version' }
$cache = Join-Path $root 'zig-cache'
foreach ($package in $pin.packages) {
    $archive = $archives[$package.name]
    Push-Location $source
    try {
        $actualHash = (& $zig fetch --global-cache-dir $cache $archive)
        if ($LASTEXITCODE -ne 0) { throw "Zig package import failed: $($package.name)" }
        if ($actualHash.Trim() -cne $package.zigHash) { throw "Zig package digest mismatch: $($package.name)" }
    } finally { Pop-Location }
}
$target = if ($HostTests) { 'x86_64-windows-gnu' } else { 'aarch64-linux-ohos' }
$prefix = Join-Path $root $target
$zigArgs = @('build', 'leantty-vt-static', '-Demit-lib-vt', "-Dtarget=$target", '-Doptimize=ReleaseFast',
    '-Dsimd=false', '-Dvt-features=-kitty-graphics', '--global-cache-dir', $cache, '--prefix', $prefix)
Push-Location $source
try { & $zig @zigArgs; if ($LASTEXITCODE -ne 0) { throw 'Pinned Ghostty static build failed' } }
finally { Pop-Location }
$cpp = Join-Path $repoRoot 'entry/src/main/cpp/terminal'
if ($HostTests) {
    $bindingSource = [IO.File]::ReadAllText((Join-Path $cpp 'terminal_napi.cpp'))
    $bindingOwner = [regex]::Match($bindingSource, '(?s)struct Binding \{.*?(?=void callJs\()')
    $bindingClose = [regex]::Match($bindingSource, '(?s)struct Close \{.*?(?=napi_value init\()')
    if (-not $bindingOwner.Success -or -not $bindingClose.Success) { throw 'Binding close test boundary changed' }
    [IO.File]::WriteAllText((Join-Path $prefix 'binding-owner-under-test.inc'), $bindingOwner.Value)
    [IO.File]::WriteAllText((Join-Path $prefix 'binding-close-under-test.inc'), $bindingClose.Value)
    $closeExe = Join-Path $prefix 'terminal-binding-close-tests.exe'
    & $zig c++ -std=c++17 -O1 -Wall -Wextra -Werror "-I$prefix" `
        (Join-Path $PSScriptRoot 'native-terminal/binding-close-test.cpp') -o $closeExe
    if ($LASTEXITCODE -ne 0) { throw 'Binding close test build failed' }
    & $closeExe
    if ($LASTEXITCODE -ne 0) { throw 'Binding close contracts failed' }
    $inputSource = [IO.File]::ReadAllText((Join-Path $cpp 'TerminalInput.cpp'))
    $deleteCallbacks = [regex]::Matches($inputSource, '(?m)^\s*OH_TextEditorProxy_SetDelete(?:Forward|Backward)Func\([^\r\n]+')
    if ($deleteCallbacks.Count -ne 2) { throw 'IME deletion registration test boundary changed' }
    [IO.File]::WriteAllText((Join-Path $prefix 'input-delete-under-test.inc'), (($deleteCallbacks | ForEach-Object { $_.Value }) -join "`n"))
    $deleteExe = Join-Path $prefix 'terminal-input-delete-tests.exe'
    & $zig c++ -std=c++17 -DGHOSTTY_STATIC -O1 -Wall -Wextra -Werror "-I$source/include" "-I$prefix" `
        (Join-Path $PSScriptRoot 'native-terminal/input-delete-test.cpp') -o $deleteExe
    if ($LASTEXITCODE -ne 0) { throw 'IME deletion test build failed' }
    & $deleteExe
    if ($LASTEXITCODE -ne 0) { throw 'IME deletion direction contracts failed' }
    $cursorMethod = [regex]::Match($inputSource, '(?s)void TerminalInput::cursor\(.*?(?=void TerminalInput::detach\()')
    if (-not $cursorMethod.Success) { throw 'IME cursor test boundary changed' }
    [IO.File]::WriteAllText((Join-Path $prefix 'input-cursor-under-test.inc'), $cursorMethod.Value)
    $cursorExe = Join-Path $prefix 'terminal-input-cursor-tests.exe'
    & $zig c++ -std=c++17 -O1 -Wall -Wextra -Werror "-I$prefix" `
        (Join-Path $PSScriptRoot 'native-terminal/input-cursor-test.cpp') -o $cursorExe
    if ($LASTEXITCODE -ne 0) { throw 'IME cursor test build failed' }
    & $cursorExe
    if ($LASTEXITCODE -ne 0) { throw 'IME cursor lifecycle contracts failed' }
    $exe = Join-Path $prefix 'terminal-runtime-tests.exe'
    $surface = [IO.File]::ReadAllText((Join-Path $repoRoot 'entry/src/main/ets/model/terminal/TerminalSurfaceController.ets'))
    $reset = [regex]::Match($surface, "SESSION_BOUNDARY_RESET_SEQUENCE: string = '([^']+)'")
    if (-not $reset.Success) { throw 'Session reset sequence not found' }
    $resetCpp = $reset.Groups[1].Value.Replace('\u001b', '\x1b""').Replace('\u0007', '\x07""')
    [IO.File]::WriteAllText((Join-Path $prefix 'session-reset-sequence.inc'), ('static const char sessionResetSequence[] = "' + $resetCpp + '";'))
    & $zig c++ -std=c++17 -DGHOSTTY_STATIC -O1 -Wall -Wextra -Werror "-I$source/include" "-I$cpp" "-I$prefix" `
        (Join-Path $cpp 'TerminalRuntime.cpp') (Join-Path $cpp 'TerminalInteraction.cpp') (Join-Path $cpp 'TerminalEffects.cpp') (Join-Path $PSScriptRoot 'native-terminal/runtime-test.cpp') `
        (Join-Path $prefix 'lib/libghostty-vt.a') -o $exe
    if ($LASTEXITCODE -ne 0) { throw 'Terminal host test build failed' }
    & $exe
    if ($LASTEXITCODE -ne 0) { throw 'Terminal runtime contracts failed' }
    # Keep the real platform-owning method under test; substitute only resource APIs.
    $renderer = [IO.File]::ReadAllText((Join-Path $cpp 'TerminalRenderer.cpp'))
    $method = [regex]::Match($renderer, '(?s)(void|bool) TerminalRenderer::attach\(.*?(?=void TerminalRenderer::createGpu\()')
    if (-not $method.Success) { throw 'Renderer attach test boundary changed' }
    [IO.File]::WriteAllText((Join-Path $prefix 'renderer-attach-under-test.inc'), $method.Value)
    $attachExe = Join-Path $prefix 'terminal-display-attach-tests.exe'
    & $zig c++ -std=c++17 -O1 -Wall -Wextra -Werror "-DATTACH_RETURN_TYPE=$($method.Groups[1].Value)" "-I$prefix" "-I$cpp" `
        (Join-Path $PSScriptRoot 'native-terminal/display-attach-test.cpp') -o $attachExe
    if ($LASTEXITCODE -ne 0) { throw 'Display attach test build failed' }
    & $attachExe
    if ($LASTEXITCODE -ne 0) { throw 'Display attach contracts failed' }
    $release = [regex]::Match($renderer, '(?s)void TerminalRenderer::releaseGpu\(.*?(?=void TerminalRenderer::detach\()')
    $draw = [regex]::Match($renderer, '(?s)void TerminalRenderer::draw\(.*?\n\}')
    if (-not $release.Success -or -not $draw.Success) { throw 'Renderer recovery test boundary changed' }
    [IO.File]::WriteAllText((Join-Path $prefix 'renderer-recovery-under-test.inc'), $release.Value + "`n" + $draw.Value)
    $recoveryExe = Join-Path $prefix 'terminal-display-recovery-tests.exe'
    & $zig c++ -std=c++17 -O1 -Wall -Wextra -Werror "-I$prefix" `
        (Join-Path $PSScriptRoot 'native-terminal/display-recovery-test.cpp') -o $recoveryExe
    if ($LASTEXITCODE -ne 0) { throw 'Display recovery test build failed' }
    & $recoveryExe
    if ($LASTEXITCODE -ne 0) { throw 'Display recovery contracts failed' }
} else {
    $devEco = (Resolve-LeanTTYDevEcoBuildTools).root
    $sdk = if ($SdkNativeHome) {
        (Resolve-LeanTTYHarmonySdk -DevEcoHome $devEco -NativeHome $SdkNativeHome).native
    } else { (Resolve-LeanTTYHarmonySdk -DevEcoHome $devEco).native }
    $out = Join-Path $repoRoot 'entry/libs/arm64-v8a'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $sources = @(Get-ChildItem -LiteralPath $cpp -Filter '*.cpp' | ForEach-Object FullName)
    Invoke-WithLeanTTYNativeDisplayAcceptanceSource -RepoRoot $repoRoot -Enabled ([bool]$Acceptance) -Action {
      & "$sdk/llvm/bin/clang++.exe" --target=aarch64-linux-ohos24.0.0 "--sysroot=$sdk/sysroot" `
        -std=c++17 -fPIC -shared -O2 -g -Wall -Wextra -Werror -Werror=unguarded-availability `
        "-I$source/include" @sources (Join-Path $prefix 'lib/libghostty-vt.a') `
        -lnative_drawing -lnative_window -lohinputmethod -lEGL -lGLESv3 '-lace_ndk.z' '-lhilog_ndk.z' '-lace_napi.z' `
        '-Wl,--no-undefined' '-Wl,-z,max-page-size=16384' -o (Join-Path $out 'libleantty_terminal.so')
    if ($LASTEXITCODE -ne 0) { throw 'API 24 terminal adapter compile/link failed' }
    }
    Copy-Item -LiteralPath "$sdk/llvm/lib/aarch64-linux-ohos/libc++_shared.so" -Destination $out -Force

    # Zig's package projection excludes some upstream notices. Extract those
    # exact members from the already digest-verified archive for distribution.
    $licenseSource = Join-Path $root 'license-source'
    $licenses = Join-Path $root 'licenses'
    New-Item -ItemType Directory -Path $licenseSource, $licenses -Force | Out-Null
    $uucodeRoot = 'uucode-2826a37a4562284fdacd8fa029d49509cc9bffcd'
    & tar -xf $archives['uucode.tar.gz'] -C $licenseSource --strip-components=1 `
        "$uucodeRoot/LICENSE.md" "$uucodeRoot/licenses"
    if ($LASTEXITCODE -ne 0) { throw 'Pinned uucode notice extraction failed' }
    $noticeSources = [ordered]@{
        'Ghostty-MIT.txt' = (Join-Path $source 'LICENSE')
        'uucode-MIT.md' = (Join-Path $licenseSource 'LICENSE.md')
        'uucode-Hoehrmann.txt' = (Join-Path $licenseSource 'licenses/LICENSE_Bjoern_Hoehrmann')
        'uucode-Unicode.txt' = (Join-Path $licenseSource 'licenses/LICENSE_unicode')
        'zlib.txt' = (Join-Path $source ('zig-pkg/' + $pin.packages[1].zigHash + '/LICENSE'))
        'LLVM-NOTICE.txt' = (Join-Path $sdk 'llvm/NOTICE')
        'Zig-MIT.txt' = (Join-Path (Split-Path $zig -Parent) 'LICENSE')
    }
    foreach ($name in $noticeSources.Keys) {
        Copy-Item -LiteralPath $noticeSources[$name] -Destination (Join-Path $licenses $name) -Force
    }
}
}

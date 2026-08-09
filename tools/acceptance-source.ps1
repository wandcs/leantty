function Set-LeanTTYAcceptanceSourceText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Anchor,
        [Parameter(Mandatory = $true)][string]$Replacement
    )

    $targetNewLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalizedAnchor = $Anchor.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", $targetNewLine)
    $normalizedReplacement = $Replacement.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", $targetNewLine)

    $first = $Text.IndexOf($normalizedAnchor, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Acceptance source anchor is missing: $Anchor" }
    if ($Text.IndexOf(
            $normalizedAnchor,
            $first + $normalizedAnchor.Length,
            [StringComparison]::Ordinal
        ) -ge 0) {
        throw "Acceptance source anchor is ambiguous: $Anchor"
    }
    return $Text.Substring(0, $first) + $normalizedReplacement +
        $Text.Substring($first + $normalizedAnchor.Length)
}

function Add-LeanTTYAcceptanceSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $nativeTypesPath = Join-Path $RepoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
    $includeNativeFileDescriptorProbe = (
        [IO.File]::ReadAllText($nativeTypesPath).Contains('AcceptanceFileDescriptorProbeResult')
    )

    $files = [ordered]@{
        index = Join-Path $RepoRoot 'entry\src\main\ets\pages\Index.ets'
        bridge = Join-Path $RepoRoot 'entry\src\main\ets\model\bridge\TerminalBridge.ets'
        surface = Join-Path $RepoRoot 'entry\src\main\ets\model\terminal\TerminalSurfaceController.ets'
        session = Join-Path $RepoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
    }
    $text = @{}
    foreach ($name in $files.Keys) {
        $text[$name] = [IO.File]::ReadAllText($files[$name])
    }

    $indexImports = "import { BrowserLauncher } from '../model/browser/BrowserLauncher'`n" +
        "import { Environment, fileIo as fs } from '@kit.CoreFileKit'`n" +
        "import { ACCEPTANCE_TESTS } from 'BuildProfile'"
    if ($includeNativeFileDescriptorProbe) {
        $indexImports += "`nimport sshNative from 'libleantty_ssh.so'`n" +
            "import type { AcceptanceFileDescriptorProbeResult } from 'libleantty_ssh.so'"
    }
    $text.index = Set-LeanTTYAcceptanceSourceText $text.index `
        "import { BrowserLauncher } from '../model/browser/BrowserLauncher'" `
        $indexImports
    $transferFixtureMenuIndex = if ($includeNativeFileDescriptorProbe) { 9 } else { 8 }
    $text.index = Set-LeanTTYAcceptanceSourceText $text.index `
        'const MENU_ACTION_COUNT: number = 6' `
        ('const MENU_ACTION_COUNT: number = ACCEPTANCE_TESTS ? ' +
            $(if ($includeNativeFileDescriptorProbe) { '10' } else { '9' }) + ' : 6')
    $selectionAnchor = "    if (selected === 4 || selected === 5) { return }"
    $selectionReplacement = "    if (selected === 6 && ACCEPTANCE_TESTS) {`n" +
        "      this.menuOpen = false`n" +
        "      this.rebuildRendererForAcceptance()`n" +
        "      return`n" +
        "    }`n" +
        "    if (selected === 7 && ACCEPTANCE_TESTS) {`n" +
        "      this.menuOpen = false`n" +
        "      this.runDownloadsNoReplaceProbeForAcceptance()`n" +
        "      return`n" +
        "    }`n"
    if ($includeNativeFileDescriptorProbe) {
        $selectionReplacement += "    if (selected === 8 && ACCEPTANCE_TESTS) {`n" +
            "      this.menuOpen = false`n" +
            "      this.runDownloadsFileDescriptorProbeForAcceptance()`n" +
            "      return`n" +
            "    }`n"
    }
    $selectionReplacement += "    if (selected === $transferFixtureMenuIndex && ACCEPTANCE_TESTS) {`n" +
        "      this.menuOpen = false`n" +
        "      this.toggleDownloadsTransferFixtureForAcceptance()`n" +
        "      return`n" +
        "    }`n"
    $selectionReplacement += $selectionAnchor
    $text.index = Set-LeanTTYAcceptanceSourceText `
        $text.index $selectionAnchor $selectionReplacement
    $keyEventAnchor = @'
    let navigationAction: WorkspaceNavigationAction = InteractionPolicy.workspaceNavigationAction(
'@
    $keyEventReplacement = @'
    if (ACCEPTANCE_TESTS && ctrlKey && altKey && !shiftKey && event.keyCode === 2038) {
      this.pasteClipboardForAcceptance()
      return true
    }

    let navigationAction: WorkspaceNavigationAction = InteractionPolicy.workspaceNavigationAction(
'@
    $text.index = Set-LeanTTYAcceptanceSourceText `
        $text.index $keyEventAnchor $keyEventReplacement
    $rendererMethod = @'
  private rebuildRendererForAcceptance(): void {
    if (!ACCEPTANCE_TESTS) {
      return
    }
    let pane: PaneInfo | null = this.appVm.getActivePane()
    let runtime: PaneRuntime | null = pane === null ? null : this.findPaneRuntime(pane.id)
    if (runtime === null) {
      logger.error('Acceptance renderer rebuild has no active pane')
      return
    }
    let targetRuntime: PaneRuntime = runtime
    targetRuntime.surface.captureSnapshot((captured: boolean) => {
      if (!captured) {
        logger.error('Acceptance renderer rebuild cancelled because checkpoint failed')
        return
      }
      let terminated: boolean = targetRuntime.surface.terminateRendererForAcceptance()
      logger.info('Acceptance renderer rebuild requested=' + terminated.toString() + ',pane=' + targetRuntime.id)
    })
  }

  private pasteClipboardForAcceptance(): void {
    if (!ACCEPTANCE_TESTS) {
      return
    }
    let runtime: PaneRuntime | null = this.activePaneRuntime()
    if (runtime !== null) {
      runtime.surface.handleSecondaryAction()
    }
  }

  private writeAcceptanceProbeFile(path: string, content: Uint8Array): void {
    let file: fs.File | null = null
    try {
      file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY)
      let written: number = fs.writeSync(file.fd, content.buffer)
      if (written !== content.length) {
        throw new Error('short write')
      }
      fs.fsyncSync(file.fd)
    } finally {
      if (file !== null) {
        fs.closeSync(file)
      }
    }
  }

  private acceptanceProbeFileEquals(path: string, expected: Uint8Array): boolean {
    if (!fs.accessSync(path)) {
      return false
    }
    let stat: fs.Stat = fs.lstatSync(path)
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== expected.length) {
      return false
    }
    let file: fs.File | null = null
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW)
      let actual: Uint8Array = new Uint8Array(expected.length)
      let readLength: number = fs.readSync(file.fd, actual.buffer)
      if (readLength !== expected.length) {
        return false
      }
      for (let i: number = 0; i < expected.length; i++) {
        if (actual[i] !== expected[i]) {
          return false
        }
      }
      return true
    } finally {
      if (file !== null) {
        fs.closeSync(file)
      }
    }
  }

  private removeAcceptanceProbeFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path)
      }
    } catch (e) {
      logger.warn('Acceptance Downloads cleanup failed: ' + e)
    }
  }

  private runDownloadsNoReplaceProbeForAcceptance(): void {
    if (!ACCEPTANCE_TESTS) {
      return
    }
    let root: string = Environment.getUserDownloadDir()
    let prefix: string = root + '/.leantty-1-3-move-probe-' + Date.now().toString()
    let successTemp: string = prefix + '-success.part'
    let successFinal: string = prefix + '-success.final'
    let conflictTemp: string = prefix + '-conflict.part'
    let conflictFinal: string = prefix + '-conflict.final'
    let complete: Uint8Array = new Uint8Array([76, 69, 65, 78, 84, 84, 89, 45, 67, 79, 77, 80, 76, 69, 84, 69])
    let incoming: Uint8Array = new Uint8Array([76, 69, 65, 78, 84, 84, 89, 45, 73, 78, 67, 79, 77, 73, 78, 71])
    let existing: Uint8Array = new Uint8Array([76, 69, 65, 78, 84, 84, 89, 45, 69, 88, 73, 83, 84, 73, 78, 71])
    let conflictDetail: string = ''
    let probeError: string = ''
    try {
      this.writeAcceptanceProbeFile(successTemp, complete)
      if (fs.accessSync(successFinal)) {
        throw new Error('unexpected success target before commit')
      }
      fs.moveFileSync(successTemp, successFinal, 1)
      if (fs.accessSync(successTemp) || !this.acceptanceProbeFileEquals(successFinal, complete)) {
        throw new Error('same-directory success commit was not exact')
      }

      this.writeAcceptanceProbeFile(conflictTemp, incoming)
      if (fs.accessSync(conflictFinal)) {
        throw new Error('unexpected conflict target before simulated claim')
      }
      this.writeAcceptanceProbeFile(conflictFinal, existing)
      let rejected: boolean = false
      try {
        fs.moveFileSync(conflictTemp, conflictFinal, 1)
      } catch (e) {
        rejected = true
        conflictDetail = '' + e
      }
      if (!rejected || !this.acceptanceProbeFileEquals(conflictFinal, existing) ||
        !this.acceptanceProbeFileEquals(conflictTemp, incoming)) {
        throw new Error('mode=1 did not preserve both files after commit-time conflict')
      }
    } catch (e) {
      probeError = '' + e
    } finally {
      this.removeAcceptanceProbeFile(successTemp)
      this.removeAcceptanceProbeFile(successFinal)
      this.removeAcceptanceProbeFile(conflictTemp)
      this.removeAcceptanceProbeFile(conflictFinal)
    }
    let cleanupComplete: boolean = !fs.accessSync(successTemp) && !fs.accessSync(successFinal) &&
      !fs.accessSync(conflictTemp) && !fs.accessSync(conflictFinal)
    if (probeError.length === 0 && cleanupComplete) {
      logger.info('ACCEPTANCE_DOWNLOADS_NOREPLACE passed=true,mode=1,sourceClosed=true,' +
        'successExact=true,conflictPreserved=true,cleanupComplete=true,detail=' + conflictDetail)
    } else {
      logger.error('ACCEPTANCE_DOWNLOADS_NOREPLACE passed=false,cleanupComplete=' +
        cleanupComplete.toString() + ',error=' + probeError)
    }
  }

  private removeAcceptanceTransferFixture(root: string, directory: string): void {
    let names: string[] = fs.listFileSync(directory)
    for (let index: number = 0; index < names.length; index++) {
      let name: string = names[index]
      if (name !== 'source.bin' && name !== 'source (1).bin' &&
        !(name.startsWith('.leantty-') && name.endsWith('.part'))) {
        throw new Error('unexpected fixture entry: ' + name)
      }
      this.removeAcceptanceProbeFile(directory + '/' + name)
    }
    fs.rmdirSync(directory)
    let staleNames: string[] = fs.listFileSync(root)
    for (let index: number = 0; index < staleNames.length; index++) {
      let staleName: string = staleNames[index]
      if (/^leantty-transfer-[0-9a-f]{12}$/.test(staleName)) {
        let stalePath: string = root + '/' + staleName
        let stale: fs.Stat = fs.lstatSync(stalePath)
        if (stale.isFile() && !stale.isSymbolicLink()) {
          fs.unlinkSync(stalePath)
        }
      }
    }
  }

  private toggleDownloadsTransferFixtureForAcceptance(): void {
    if (!ACCEPTANCE_TESTS) {
      return
    }
    let root: string = Environment.getUserDownloadDir().replace(/\/+$/, '')
    let directory: string = root + '/.leantty-1-3-transfer-fixture'
    try {
      if (fs.accessSync(directory)) {
        let originalPreserved: boolean = this.acceptanceProbeFileEquals(directory + '/source.bin',
          new Uint8Array([101, 120, 105, 115, 116, 105, 110, 103]))
        let numberedPresent: boolean = fs.accessSync(directory + '/source (1).bin')
        this.removeAcceptanceTransferFixture(root, directory)
        logger.info('ACCEPTANCE_TRANSFER_FIXTURE state=cleaned,originalPreserved=' +
          originalPreserved.toString() + ',numberedPresent=' + numberedPresent.toString())
        return
      }
      fs.mkdirSync(directory)
      this.writeAcceptanceProbeFile(directory + '/source.bin',
        new Uint8Array([101, 120, 105, 115, 116, 105, 110, 103]))
      logger.info('ACCEPTANCE_TRANSFER_FIXTURE state=prepared')
    } catch (e) {
      logger.error('ACCEPTANCE_TRANSFER_FIXTURE state=failed,error=' + e)
    }
  }

  private acceptanceProbeBytesEqual(actual: Uint8Array, expected: Uint8Array): boolean {
    if (actual.length !== expected.length) {
      return false
    }
    for (let index: number = 0; index < expected.length; index++) {
      if (actual[index] !== expected[index]) {
        return false
      }
    }
    return true
  }

  private runDownloadsFileDescriptorProbeForAcceptance(): void {
    if (!ACCEPTANCE_TESTS) {
      return
    }
    let root: string = Environment.getUserDownloadDir()
    let prefix: string = root + '/.leantty-1-3-fd-probe-' + Date.now().toString()
    let openedPath: string = prefix + '-opened.bin'
    let retainedPath: string = prefix + '-retained.bin'
    let symlinkPath: string = prefix + '-link.bin'
    let symlinkTargetPath: string = retainedPath
    let original: Uint8Array = new Uint8Array([76, 69, 65, 78, 84, 84, 89, 45, 70, 68, 45, 79, 82, 73, 71])
    let replacement: Uint8Array = new Uint8Array([76, 69, 65, 78, 84, 84, 89, 45, 70, 68, 45, 78, 69, 87])
    let opened: fs.File | null = null
    let probeError: string = ''
    let symlinkRejected: boolean = false
    let downloadsSymlinkDenied: boolean = false
    let privateSymlinkDenied: boolean = false
    let stage: string = 'create-source'
    try {
      this.writeAcceptanceProbeFile(openedPath, original)
      stage = 'lstat-source'
      let beforeOpen: fs.Stat = fs.lstatSync(openedPath)
      if (!beforeOpen.isFile() || beforeOpen.isSymbolicLink()) {
        throw new Error('source is not a regular no-follow object')
      }
      stage = 'open-nofollow'
      opened = fs.openSync(openedPath, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW)
      stage = 'replace-opened-path'
      fs.moveFileSync(openedPath, retainedPath, 1)
      this.writeAcceptanceProbeFile(openedPath, replacement)
      stage = 'native-duplicate-read'
      let nativeResult: AcceptanceFileDescriptorProbeResult =
        sshNative.sshAcceptanceProbeFileDescriptor(opened.fd)
      if (!nativeResult.regular || nativeResult.size !== original.length ||
        !this.acceptanceProbeBytesEqual(nativeResult.data, original)) {
        throw new Error('native duplicate did not retain the originally opened object')
      }
      fs.closeSync(opened)
      opened = null
      stage = 'create-downloads-symlink'
      try {
        fs.symlinkSync(retainedPath, symlinkPath)
      } catch (e) {
        downloadsSymlinkDenied = true
        let context = this.getUIContext().getHostContext() as common.UIAbilityContext
        let privatePrefix: string = context.cacheDir + '/leantty-1-3-fd-probe-' + Date.now().toString()
        symlinkTargetPath = privatePrefix + '-target.bin'
        symlinkPath = privatePrefix + '-link.bin'
        this.writeAcceptanceProbeFile(symlinkTargetPath, original)
        stage = 'create-private-symlink'
        try {
          fs.symlinkSync(symlinkTargetPath, symlinkPath)
        } catch (privateError) {
          privateSymlinkDenied = true
        }
      }
      if (!privateSymlinkDenied) {
        stage = 'open-symlink-nofollow'
        try {
          let rejected: fs.File = fs.openSync(symlinkPath, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW)
          fs.closeSync(rejected)
        } catch (e) {
          symlinkRejected = true
        }
        if (!symlinkRejected) {
          throw new Error('NOFOLLOW accepted a symbolic link')
        }
      }
    } catch (e) {
      probeError = stage + ': ' + e
    } finally {
      if (opened !== null) {
        fs.closeSync(opened)
      }
      this.removeAcceptanceProbeFile(symlinkPath)
      if (symlinkTargetPath !== retainedPath) {
        this.removeAcceptanceProbeFile(symlinkTargetPath)
      }
      this.removeAcceptanceProbeFile(openedPath)
      this.removeAcceptanceProbeFile(retainedPath)
    }
    let cleanupComplete: boolean = !fs.accessSync(symlinkPath) && !fs.accessSync(openedPath) &&
      !fs.accessSync(retainedPath) &&
      (symlinkTargetPath === retainedPath || !fs.accessSync(symlinkTargetPath))
    let symbolicLinkBoundaryClosed: boolean = symlinkRejected ||
      (downloadsSymlinkDenied && privateSymlinkDenied)
    if (probeError.length === 0 && symbolicLinkBoundaryClosed && cleanupComplete) {
      logger.info('ACCEPTANCE_DOWNLOADS_FD passed=true,arktsNoFollow=true,nativeDup=true,' +
        'pathReplacementIsolated=true,regularFile=true,symlinkRejected=' + symlinkRejected.toString() +
        ',downloadsSymlinkDenied=' + downloadsSymlinkDenied.toString() +
        ',privateSymlinkDenied=' + privateSymlinkDenied.toString() + ',cleanupComplete=true')
    } else {
      logger.error('ACCEPTANCE_DOWNLOADS_FD passed=false,symlinkRejected=' + symlinkRejected.toString() +
        ',cleanupComplete=' + cleanupComplete.toString() + ',error=' + probeError)
    }
  }

'@
    if (-not $includeNativeFileDescriptorProbe) {
        $fdMethodStart = $rendererMethod.IndexOf(
            '  private acceptanceProbeBytesEqual',
            [StringComparison]::Ordinal
        )
        if ($fdMethodStart -lt 0) {
            throw 'Acceptance Downloads FD method anchor is missing'
        }
        $rendererMethod = $rendererMethod.Substring(0, $fdMethodStart)
    }
    $text.index = Set-LeanTTYAcceptanceSourceText $text.index `
        "  @Builder`n  menuPanel() {" `
        ($rendererMethod + "  @Builder`n  menuPanel() {")
    $menuAnchor = "      this.fontSizeMenuRow()"
    $menuAddition = "      this.fontSizeMenuRow()`n" +
        "      if (ACCEPTANCE_TESTS) {`n" +
        "        this.menuDivider()`n" +
        "        this.menuRow(6, '↻', 'Acceptance: Rebuild Renderer', '', true,`n" +
        "          () => { this.rebuildRendererForAcceptance() })`n" +
        "        this.menuRow(7, '✓', 'Acceptance: Downloads No-Replace', '', true,`n" +
        "          () => { this.runDownloadsNoReplaceProbeForAcceptance() })`n"
    if ($includeNativeFileDescriptorProbe) {
        $menuAddition += "        this.menuRow(8, '⊙', 'Acceptance: Downloads FD Boundary', '', true,`n" +
            "          () => { this.runDownloadsFileDescriptorProbeForAcceptance() })`n"
    }
    $menuAddition += "        this.menuRow($transferFixtureMenuIndex, '⇄', " +
        "'Acceptance: Transfer Fixture', '', true,`n" +
        "          () => { this.toggleDownloadsTransferFixtureForAcceptance() })`n"
    $menuAddition += "      }`n"
    $text.index = Set-LeanTTYAcceptanceSourceText $text.index $menuAnchor $menuAddition

    $text.bridge = Set-LeanTTYAcceptanceSourceText $text.bridge `
        "import { Logger } from '../../common/logger/Logger'" `
        "import { Logger } from '../../common/logger/Logger'`nimport { ACCEPTANCE_TESTS } from 'BuildProfile'"
    $bridgeMethod = @'
  terminateRendererForAcceptance(): boolean {
    if (!ACCEPTANCE_TESTS) {
      return false
    }
    try {
      return this.webCtrl.terminateRenderProcess()
    } catch (e) {
      this.logger.error('Acceptance renderer termination failed: ' + e)
      return false
    }
  }

'@
    $text.bridge = Set-LeanTTYAcceptanceSourceText $text.bridge `
        '  private postTerminalPacket(data: Uint8Array): number {' `
        ($bridgeMethod + '  private postTerminalPacket(data: Uint8Array): number {')

    $text.surface = Set-LeanTTYAcceptanceSourceText $text.surface `
        "import util from '@ohos.util'" `
        "import util from '@ohos.util'`nimport { ACCEPTANCE_TESTS } from 'BuildProfile'"
    $surfaceMethod = @'
  terminateRendererForAcceptance(): boolean {
    if (!ACCEPTANCE_TESTS || this.bridge === null) {
      return false
    }
    return this.bridge.terminateRendererForAcceptance()
  }

'@
    $text.surface = Set-LeanTTYAcceptanceSourceText $text.surface `
        '  private handleBridgeMessage(sourceBridge: TerminalBridge, msg: BridgeMessage): void {' `
        ($surfaceMethod + '  private handleBridgeMessage(sourceBridge: TerminalBridge, msg: BridgeMessage): void {')

    $text.session = Set-LeanTTYAcceptanceSourceText $text.session `
        "import { KeyCommandService, KeyCommandContext } from '../model/command/KeyCommandService'" `
        ("import { ACCEPTANCE_TESTS } from 'BuildProfile'`n" +
            "import { KeyCommandService, KeyCommandContext } from '../model/command/KeyCommandService'")
    $text.session = Set-LeanTTYAcceptanceSourceText $text.session `
        '  private perfPingStartedMs: number = 0' `
        "  private perfPingStartedMs: number = 0`n  private acceptanceInputSequence: number = 0"
    foreach ($inputPoint in @(
        @{ anchor = "  private executeCommandBuffer(): void {"; kind = 'command' },
        @{ anchor = "    this.writeTerminal('\r\n')`n    let pw: string = this.passwordBuffer"; kind = 'password' },
        @{ anchor = '    this.authResponses.push(this.authResponseBuffer)'; kind = 'keyboard-interactive' },
        @{ anchor = "    this.writeTerminal('\r\n')`n    let pass: string = this.pendingKeyPassphrase"; kind = 'private-key-passphrase' }
    )) {
        if ($inputPoint.kind -eq 'command') {
            $replacement = $inputPoint.anchor + "`n    this.logAcceptanceInputSubmit('command')"
        } else {
            $replacement = $inputPoint.anchor.Replace(
                "`n    let ",
                "`n    this.logAcceptanceInputSubmit('$($inputPoint.kind)')`n    let "
            )
            if ($inputPoint.kind -eq 'keyboard-interactive') {
                $replacement = "    this.logAcceptanceInputSubmit('keyboard-interactive')`n" + $inputPoint.anchor
            }
        }
        $text.session = Set-LeanTTYAcceptanceSourceText $text.session $inputPoint.anchor $replacement
    }
    $keyChangeAnchor = @'
  private submitKeyPassphraseChangeStage(): void {
    if (this.mode !== TerminalMode.KEY_PASSPHRASE_CHANGE_INPUT) {
      return
    }
'@
    $text.session = Set-LeanTTYAcceptanceSourceText `
        $text.session `
        $keyChangeAnchor `
        ($keyChangeAnchor + "    this.logAcceptanceInputSubmit('key-passphrase-change')`n")
    $sessionMethod = @'
  private logAcceptanceInputSubmit(kind: string): void {
    if (ACCEPTANCE_TESTS) {
      this.acceptanceInputSequence++
      this.logger.info('ACCEPTANCE_INPUT_SUBMIT sequence=' + this.acceptanceInputSequence.toString() +
        ',kind=' + kind)
    }
  }

'@
    $text.session = Set-LeanTTYAcceptanceSourceText $text.session `
        '  private submitKeyPassphrase(): void {' `
        ($sessionMethod + '  private submitKeyPassphrase(): void {')

    foreach ($name in $files.Keys) {
        [IO.File]::WriteAllText($files[$name], $text[$name], [Text.UTF8Encoding]::new($false))
    }
    return @($files.Values)
}

function Invoke-WithLeanTTYAcceptanceSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    if (-not $Enabled) {
        & $Action
        return
    }
    $paths = @(
        Join-Path $RepoRoot 'entry\src\main\ets\pages\Index.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\model\bridge\TerminalBridge.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\model\terminal\TerminalSurfaceController.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\viewmodel\SessionViewModel.ets'
    )
    $backups = @{}
    foreach ($path in $paths) { $backups[$path] = [IO.File]::ReadAllBytes($path) }
    try {
        Add-LeanTTYAcceptanceSource -RepoRoot $RepoRoot | Out-Null
        & $Action
    } finally {
        foreach ($path in $paths) { [IO.File]::WriteAllBytes($path, $backups[$path]) }
    }
}

function Add-LeanTTYNativeAcceptanceSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $nativePath = Join-Path $RepoRoot 'leantty_ssh\src\lib.rs'
    $typesPath = Join-Path $RepoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
    $native = [IO.File]::ReadAllText($nativePath)
    $types = [IO.File]::ReadAllText($typesPath)

    $native = Set-LeanTTYAcceptanceSourceText $native `
        'use std::future::Future;' `
        "use std::future::Future;`nuse std::io::Read;`nuse std::os::fd::BorrowedFd;"
    $nativeProbe = @'
#[napi(object)]
pub struct AcceptanceFileDescriptorProbeResult {
    pub regular: bool,
    pub size: u32,
    pub data: Uint8Array,
}

#[napi]
pub fn ssh_acceptance_probe_file_descriptor(
    descriptor: i32,
) -> Result<AcceptanceFileDescriptorProbeResult> {
    if descriptor < 0 {
        return Err(napi_error("acceptance descriptor must be non-negative"));
    }
    let borrowed = unsafe { BorrowedFd::borrow_raw(descriptor) };
    let duplicated = borrowed
        .try_clone_to_owned()
        .map_err(|error| napi_error(&format!("acceptance descriptor duplicate failed: {error}")))?;
    let mut file = std::fs::File::from(duplicated);
    let metadata = file
        .metadata()
        .map_err(|error| napi_error(&format!("acceptance descriptor fstat failed: {error}")))?;
    if !metadata.is_file() {
        return Err(napi_error("acceptance descriptor is not a regular file"));
    }
    let size = u32::try_from(metadata.len())
        .map_err(|_| napi_error("acceptance descriptor is too large"))?;
    if size > 4096 {
        return Err(napi_error("acceptance descriptor exceeds the bounded probe size"));
    }
    let mut data = Vec::with_capacity(size as usize);
    file.read_to_end(&mut data)
        .map_err(|error| napi_error(&format!("acceptance descriptor read failed: {error}")))?;
    Ok(AcceptanceFileDescriptorProbeResult {
        regular: true,
        size,
        data: data.into(),
    })
}

'@
    $native = Set-LeanTTYAcceptanceSourceText $native `
        "#[napi(object)]`npub struct KnownHostsRemovalResult {" `
        ($nativeProbe + "#[napi(object)]`n" + 'pub struct KnownHostsRemovalResult {')
    $typesProbe = @'
export interface AcceptanceFileDescriptorProbeResult {
  regular: boolean
  size: number
  data: Uint8Array
}
export declare function sshAcceptanceProbeFileDescriptor(
  descriptor: number
): AcceptanceFileDescriptorProbeResult
'@
    $types = Set-LeanTTYAcceptanceSourceText $types `
        'export interface KnownHostsQueryResult {' `
        ($typesProbe + "`n" + 'export interface KnownHostsQueryResult {')

    [IO.File]::WriteAllText($nativePath, $native, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($typesPath, $types, [Text.UTF8Encoding]::new($false))
    return @($nativePath, $typesPath)
}

function Invoke-WithLeanTTYNativeAcceptanceSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $paths = @(
        Join-Path $RepoRoot 'leantty_ssh\src\lib.rs'
        Join-Path $RepoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
    )
    $backups = @{}
    foreach ($path in $paths) { $backups[$path] = [IO.File]::ReadAllBytes($path) }
    try {
        Add-LeanTTYNativeAcceptanceSource -RepoRoot $RepoRoot | Out-Null
        & $Action
    } finally {
        foreach ($path in $paths) { [IO.File]::WriteAllBytes($path, $backups[$path]) }
    }
}

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
        transfer = Join-Path $RepoRoot 'entry\src\main\ets\model\transfer\TransferFileManager.ets'
        client = Join-Path $RepoRoot 'entry\src\main\ets\model\transfer\FileTransferClient.ets'
    }
    $text = @{}
    foreach ($name in $files.Keys) {
        $text[$name] = [IO.File]::ReadAllText($files[$name])
    }

    $indexImports = "import { BrowserLauncher } from '../model/browser/BrowserLauncher'`n" +
        "import { TransferFileManager, TransferLocalFile } from '../model/transfer/TransferFileManager'`n" +
        "import { Environment, fileIo as fs } from '@kit.CoreFileKit'`n" +
        "import { ACCEPTANCE_TESTS } from 'BuildProfile'"
    if ($includeNativeFileDescriptorProbe) {
        $indexImports += "`nimport sshNative from 'libleantty_ssh.so'`n" +
            "import type { AcceptanceFileDescriptorProbeResult } from 'libleantty_ssh.so'"
    }
    $text.index = Set-LeanTTYAcceptanceSourceText $text.index `
        "import { BrowserLauncher } from '../model/browser/BrowserLauncher'" `
        $indexImports
    $downloadsManagerMenuIndex = if ($includeNativeFileDescriptorProbe) { 9 } else { 8 }
    $transferFixtureMenuIndex = if ($includeNativeFileDescriptorProbe) { 10 } else { 9 }
    $text.index = Set-LeanTTYAcceptanceSourceText $text.index `
        'const MENU_ACTION_COUNT: number = 6' `
        ('const MENU_ACTION_COUNT: number = ACCEPTANCE_TESTS ? ' +
            $(if ($includeNativeFileDescriptorProbe) { '11' } else { '10' }) + ' : 6')
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
    $selectionReplacement += "    if (selected === $downloadsManagerMenuIndex && ACCEPTANCE_TESTS) {`n" +
        "      this.menuOpen = false`n" +
        "      this.runDownloadsManagerBoundaryProbeForAcceptance()`n" +
        "      return`n" +
        "    }`n"
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
    if (ACCEPTANCE_TESTS && ctrlKey && altKey && !shiftKey && event.keyCode === 2037) {
      let runtime: PaneRuntime | null = this.activePaneRuntime()
      if (runtime !== null) {
        runtime.viewModel.handleTerminalInput('数据')
      }
      return true
    }
    if (ACCEPTANCE_TESTS && ctrlKey && altKey && !shiftKey && event.keyCode === 2035) {
      let runtime: PaneRuntime | null = this.activePaneRuntime()
      if (runtime !== null) {
        runtime.surface.selectTextForAcceptance()
      }
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
    let longName: string = 'l'.repeat(220) + '.bin'
    let longNumberedName: string = 'l'.repeat(220) + ' (1).bin'
    let names: string[] = fs.listFileSync(directory)
    for (let index: number = 0; index < names.length; index++) {
      let name: string = names[index]
      if (name !== 'source.bin' && name !== 'source (1).bin' &&
        name !== 'backpressure-result.bin' && name !== 'force-get-result.bin' &&
        name !== 'force-put-source.bin' && name !== 'late-cancel-result.bin' &&
        name !== 'late-disconnect-result.bin' && name !== 'report alpha.txt' &&
        name !== 'report beta.txt' && name !== '报告 β.txt' && name !== '.hidden-file' &&
        name !== 'space name.bin' && name !== 'space name (1).bin' &&
        name !== '数据.bin' && name !== '数据 (1).bin' &&
        name !== longName && name !== longNumberedName &&
        name !== 'unsafe\u202Ename.txt' && name !== 'nested space' &&
        name !== 'nested alpha' && name !== 'nested beta' &&
        !(name.startsWith('.leantty-') && name.endsWith('.part'))) {
        throw new Error('unexpected fixture entry: ' + name)
      }
      if (name === 'nested space' || name === 'nested alpha' || name === 'nested beta') {
        let childNames: string[] = fs.listFileSync(directory + '/' + name)
        for (let childIndex: number = 0; childIndex < childNames.length; childIndex++) {
          if (childNames[childIndex] !== 'child.txt') {
            throw new Error('unexpected nested fixture entry: ' + childNames[childIndex])
          }
          this.removeAcceptanceProbeFile(directory + '/' + name + '/' + childNames[childIndex])
        }
        fs.rmdirSync(directory + '/' + name)
      } else {
        this.removeAcceptanceProbeFile(directory + '/' + name)
      }
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
    let directory: string = root + '/.leantty-transfer-fixture'
    try {
      if (fs.accessSync(directory)) {
        let originalPreserved: boolean = this.acceptanceProbeFileEquals(directory + '/source.bin',
          new Uint8Array([101, 120, 105, 115, 116, 105, 110, 103]))
        let numberedPresent: boolean = fs.accessSync(directory + '/source (1).bin')
        let cleanupFailureFinalPresent: boolean = fs.accessSync(directory + '/local-cleanup-failure.bin')
        let backpressureFinalPresent: boolean = fs.accessSync(directory + '/backpressure-result.bin')
        let forceGetFinalPresent: boolean = fs.accessSync(directory + '/force-get-result.bin')
        let forcePutSourcePresent: boolean = fs.accessSync(directory + '/force-put-source.bin')
        let forcePutSourceSize: number = forcePutSourcePresent ?
          fs.lstatSync(directory + '/force-put-source.bin').size : 0
        let lateCancelFinalPresent: boolean = fs.accessSync(directory + '/late-cancel-result.bin')
        let lateDisconnectFinalPresent: boolean = fs.accessSync(directory + '/late-disconnect-result.bin')
        let names: string[] = fs.listFileSync(directory)
        let temporaryCount: number = 0
        for (let index: number = 0; index < names.length; index++) {
          if (names[index].startsWith('.leantty-') && names[index].endsWith('.part')) {
            temporaryCount++
          }
        }
        let temporaryPresent: boolean = temporaryCount > 0
        this.removeAcceptanceTransferFixture(root, directory)
        logger.info('ACCEPTANCE_TRANSFER_FIXTURE state=cleaned,originalPreserved=' +
          originalPreserved.toString() + ',numberedPresent=' + numberedPresent.toString() +
          ',temporaryPresent=' + temporaryPresent.toString() +
          ',cleanupFailureFinalPresent=' + cleanupFailureFinalPresent.toString() +
          ',temporaryCount=' + temporaryCount.toString() +
          ',backpressureFinalPresent=' + backpressureFinalPresent.toString() +
          ',forceGetFinalPresent=' + forceGetFinalPresent.toString() +
          ',forcePutSourcePresent=' + forcePutSourcePresent.toString() +
          ',forcePutSourceSize=' + forcePutSourceSize.toString() +
          ',lateCancelFinalPresent=' + lateCancelFinalPresent.toString() +
          ',lateDisconnectFinalPresent=' + lateDisconnectFinalPresent.toString())
        return
      }
      fs.mkdirSync(directory)
      this.writeAcceptanceProbeFile(directory + '/source.bin',
        new Uint8Array([101, 120, 105, 115, 116, 105, 110, 103]))
      let completionBytes: Uint8Array = new Uint8Array([99, 111, 109, 112, 108, 101, 116, 101])
      this.writeAcceptanceProbeFile(directory + '/report alpha.txt', completionBytes)
      this.writeAcceptanceProbeFile(directory + '/report beta.txt', completionBytes)
      this.writeAcceptanceProbeFile(directory + '/报告 β.txt', completionBytes)
      this.writeAcceptanceProbeFile(directory + '/.hidden-file', completionBytes)
      this.writeAcceptanceProbeFile(directory + '/unsafe\u202Ename.txt', completionBytes)
      this.writeAcceptanceProbeFile(directory + '/space name.bin', completionBytes)
      this.writeAcceptanceProbeFile(directory + '/数据.bin', completionBytes)
      this.writeAcceptanceProbeFile(directory + '/' + 'l'.repeat(220) + '.bin', completionBytes)
      fs.mkdirSync(directory + '/nested space')
      fs.mkdirSync(directory + '/nested alpha')
      fs.mkdirSync(directory + '/nested beta')
      this.writeAcceptanceProbeFile(directory + '/nested alpha/child.txt', completionBytes)
      this.writeAcceptanceProbeFile(directory + '/nested beta/child.txt', completionBytes)
      let forcePutFile: fs.File | null = null
      try {
        forcePutFile = fs.openSync(directory + '/force-put-source.bin',
          fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY)
        let forcePutChunk: Uint8Array = new Uint8Array(65536)
        for (let index: number = 0; index < forcePutChunk.length; index++) {
          forcePutChunk[index] = index % 251
        }
        for (let index: number = 0; index < 32; index++) {
          let written: number = fs.writeSync(forcePutFile.fd, forcePutChunk.buffer)
          if (written !== forcePutChunk.length) {
            throw new Error('short force-termination fixture write')
          }
        }
        fs.fsyncSync(forcePutFile.fd)
      } finally {
        if (forcePutFile !== null) {
          fs.closeSync(forcePutFile)
        }
      }
      logger.info('ACCEPTANCE_TRANSFER_FIXTURE state=prepared')
    } catch (e) {
      logger.error('ACCEPTANCE_TRANSFER_FIXTURE state=failed,error=' + e)
    }
  }

  private async runDownloadsManagerBoundaryProbeForAcceptance(): Promise<void> {
    if (!ACCEPTANCE_TESTS) {
      return
    }
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext
    let root: string = Environment.getUserDownloadDir().replace(/\/+$/, '')
    let relativeRoot: string = '.leantty-1-3-manager-probe-' + Date.now().toString()
    let directory: string = root + '/' + relativeRoot
    let nestedDirectory: string = directory + '/nested'
    let deepDirectory: string = nestedDirectory + '/deep'
    let existingPath: string = directory + '/existing.bin'
    let racePath: string = directory + '/race.bin'
    let automaticPath: string = directory + '/remote.bin'
    let automaticOnePath: string = directory + '/remote (1).bin'
    let automaticTwoPath: string = directory + '/remote (2).bin'
    let exhaustionBasename: string = 'exhaust.bin'
    let putPath: string = deepDirectory + '/source.bin'
    let existing: Uint8Array = new Uint8Array([69, 88, 73, 83, 84, 73, 78, 71])
    let incoming: Uint8Array = new Uint8Array([73, 78, 67, 79, 77, 73, 78, 71])
    let race: TransferLocalFile | null = null
    let automatic: TransferLocalFile | null = null
    let exhaustion: TransferLocalFile | null = null
    let put: TransferLocalFile | null = null
    let raceTempPath: string = ''
    let automaticTempPath: string = ''
    let exhaustionTempPath: string = ''
    let preflightRejected: boolean = false
    let raceRejected: boolean = false
    let automaticCommitted: boolean = false
    let exhaustionRejected: boolean = false
    let exhaustionPreserved: boolean = false
    let temporarySameDirectory: boolean = false
    let nestedPutOpened: boolean = false
    let productCleanupComplete: boolean = false
    let probeError: string = ''
    try {
      fs.mkdirSync(directory)
      fs.mkdirSync(nestedDirectory)
      fs.mkdirSync(deepDirectory)
      this.writeAcceptanceProbeFile(existingPath, existing)
      try {
        await TransferFileManager.prepareGet(
          context, '/existing.bin', relativeRoot + '/existing.bin', false)
      } catch (e) {
        preflightRejected = ('' + e).includes('LOCAL_CONFLICT')
      }
      if (!preflightRejected || !this.acceptanceProbeFileEquals(existingPath, existing)) {
        throw new Error('explicit existing target was not rejected and preserved')
      }

      race = await TransferFileManager.prepareGet(context, '/race.bin', relativeRoot + '/race.bin', false)
      raceTempPath = race.tempPath
      temporarySameDirectory = race.tempPath.startsWith(directory + '/.leantty-') &&
        race.tempPath.endsWith('.part')
      this.writeAcceptanceProbeFile(race.tempPath, incoming)
      this.writeAcceptanceProbeFile(racePath, existing)
      try {
        TransferFileManager.commitGet(race)
      } catch (e) {
        raceRejected = ('' + e).includes('File exists') || ('' + e).includes('LOCAL_COMMIT')
      }
      if (!raceRejected || !this.acceptanceProbeFileEquals(racePath, existing) ||
        !this.acceptanceProbeFileEquals(race.tempPath, incoming)) {
        throw new Error('commit-time explicit conflict did not preserve both objects')
      }
      TransferFileManager.cleanup(race)
      if (fs.accessSync(raceTempPath)) {
        throw new Error('explicit conflict temporary file was not cleaned')
      }

      this.writeAcceptanceProbeFile(automaticPath, existing)
      this.writeAcceptanceProbeFile(automaticOnePath, existing)
      automatic = await TransferFileManager.prepareGet(context, '/remote.bin', relativeRoot + '/', true)
      automaticTempPath = automatic.tempPath
      temporarySameDirectory = temporarySameDirectory &&
        automatic.tempPath.startsWith(directory + '/.leantty-') && automatic.tempPath.endsWith('.part')
      this.writeAcceptanceProbeFile(automatic.tempPath, incoming)
      let committedName: string = TransferFileManager.commitGet(automatic)
      automaticCommitted = committedName === relativeRoot + '/remote (2).bin' &&
        this.acceptanceProbeFileEquals(automaticPath, existing) &&
        this.acceptanceProbeFileEquals(automaticOnePath, existing) &&
        this.acceptanceProbeFileEquals(automaticTwoPath, incoming) && !fs.accessSync(automaticTempPath)
      if (!automaticCommitted) {
        throw new Error('automatic commit did not choose the minimal available name')
      }

      for (let index: number = 0; index < 10000; index++) {
        let occupiedName: string = TransferFileManager.automaticName(exhaustionBasename, index)
        this.writeAcceptanceProbeFile(directory + '/' + occupiedName, existing)
      }
      exhaustion = await TransferFileManager.prepareGet(
        context, '/' + exhaustionBasename, relativeRoot + '/', true)
      exhaustionTempPath = exhaustion.tempPath
      this.writeAcceptanceProbeFile(exhaustion.tempPath, incoming)
      try {
        TransferFileManager.commitGet(exhaustion)
      } catch (e) {
        exhaustionRejected = ('' + e).includes('LOCAL_CONFLICT')
      }
      exhaustionPreserved = exhaustionRejected &&
        this.acceptanceProbeFileEquals(exhaustion.tempPath, incoming)
      for (let index: number = 0; index < 10000 && exhaustionPreserved; index++) {
        let occupiedName: string = TransferFileManager.automaticName(exhaustionBasename, index)
        exhaustionPreserved = this.acceptanceProbeFileEquals(directory + '/' + occupiedName, existing)
      }
      if (!exhaustionPreserved) {
        throw new Error('automatic name exhaustion did not preserve every occupied name and temporary file')
      }
      TransferFileManager.cleanup(exhaustion)
      if (fs.accessSync(exhaustionTempPath)) {
        throw new Error('automatic name exhaustion temporary file was not cleaned')
      }

      this.writeAcceptanceProbeFile(putPath, incoming)
      put = await TransferFileManager.preparePut(context, relativeRoot + '/nested/deep/source.bin')
      if (put.file === null) {
        throw new Error('nested PUT source did not produce an owned file descriptor')
      }
      let actual: Uint8Array = new Uint8Array(incoming.length)
      let readLength: number = fs.readSync(put.file.fd, actual.buffer)
      nestedPutOpened = readLength === incoming.length
      if (nestedPutOpened) {
        for (let index: number = 0; index < incoming.length; index++) {
          if (actual[index] !== incoming[index]) {
            nestedPutOpened = false
            break
          }
        }
      }
      if (!nestedPutOpened) {
        throw new Error('nested PUT source descriptor did not read the expected object')
      }
      TransferFileManager.close(put)
      productCleanupComplete = !fs.accessSync(raceTempPath) && !fs.accessSync(automaticTempPath) &&
        !fs.accessSync(exhaustionTempPath)
      if (!temporarySameDirectory || !productCleanupComplete) {
        throw new Error('temporary-file ownership or cleanup boundary failed')
      }
    } catch (e) {
      probeError = '' + e
    } finally {
      try { TransferFileManager.cleanup(race) } catch (e) { productCleanupComplete = false }
      try { TransferFileManager.cleanup(automatic) } catch (e) { productCleanupComplete = false }
      try { TransferFileManager.cleanup(exhaustion) } catch (e) { productCleanupComplete = false }
      TransferFileManager.close(put)
      this.removeAcceptanceProbeFile(raceTempPath)
      this.removeAcceptanceProbeFile(automaticTempPath)
      this.removeAcceptanceProbeFile(exhaustionTempPath)
      for (let path of [
        existingPath, racePath, automaticPath, automaticOnePath, automaticTwoPath, putPath
      ]) {
        this.removeAcceptanceProbeFile(path)
      }
      for (let index: number = 0; index < 10000; index++) {
        let occupiedName: string = TransferFileManager.automaticName(exhaustionBasename, index)
        this.removeAcceptanceProbeFile(directory + '/' + occupiedName)
      }
      try { if (fs.accessSync(deepDirectory)) { fs.rmdirSync(deepDirectory) } } catch (e) {}
      try { if (fs.accessSync(nestedDirectory)) { fs.rmdirSync(nestedDirectory) } } catch (e) {}
      try { if (fs.accessSync(directory)) { fs.rmdirSync(directory) } } catch (e) {}
    }
    let cleanupComplete: boolean = !fs.accessSync(directory)
    if (probeError.length === 0 && preflightRejected && raceRejected && automaticCommitted &&
      exhaustionRejected && exhaustionPreserved &&
      temporarySameDirectory && nestedPutOpened && productCleanupComplete && cleanupComplete) {
      logger.info('ACCEPTANCE_DOWNLOADS_MANAGER passed=true,preflightConflictPreserved=true,' +
        'commitConflictPreserved=true,automaticMinimalName=true,automaticExhaustion=true,' +
        'allOccupiedContentsPreserved=true,tempSameDirectory=true,' +
        'nestedPutFd=true,productCleanup=true,cleanupComplete=true')
    } else {
      logger.error('ACCEPTANCE_DOWNLOADS_MANAGER passed=false,preflightRejected=' +
        preflightRejected.toString() + ',raceRejected=' + raceRejected.toString() +
        ',automaticCommitted=' + automaticCommitted.toString() +
        ',exhaustionRejected=' + exhaustionRejected.toString() +
        ',exhaustionPreserved=' + exhaustionPreserved.toString() + ',tempSameDirectory=' +
        temporarySameDirectory.toString() + ',nestedPutOpened=' + nestedPutOpened.toString() +
        ',productCleanup=' + productCleanupComplete.toString() + ',cleanupComplete=' +
        cleanupComplete.toString() + ',error=' + probeError)
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
    $menuAddition += "        this.menuRow($downloadsManagerMenuIndex, '◇', " +
        "'Acceptance: Downloads Manager Boundary', '', true,`n" +
        "          () => { this.runDownloadsManagerBoundaryProbeForAcceptance() })`n"
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

  selectTextForAcceptance(): void {
    if (!ACCEPTANCE_TESTS) {
      return
    }
    this.webCtrl.runJavaScript(
      "if (typeof term !== 'undefined' && term) { " +
      "term.select(0, Math.max(0, term.buffer.active.cursorY - 1), 4); term.focus(); " +
      "term.hasSelection() ? 'selected:' + term.getSelection().length : 'empty'; } else { 'missing'; }"
    ).then((result: string) => {
      this.logger.info('ACCEPTANCE_SELECTION result=' + result)
    }).catch((error: Error) => {
      this.logger.error('ACCEPTANCE_SELECTION failed=' + error.message)
    })
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

  selectTextForAcceptance(): void {
    if (ACCEPTANCE_TESTS && this.bridge !== null) {
      this.bridge.selectTextForAcceptance()
    }
  }

'@
    $text.surface = Set-LeanTTYAcceptanceSourceText $text.surface `
        '  private handleBridgeMessage(sourceBridge: TerminalBridge, msg: BridgeMessage): void {' `
        ($surfaceMethod + '  private handleBridgeMessage(sourceBridge: TerminalBridge, msg: BridgeMessage): void {')

    $text.session = Set-LeanTTYAcceptanceSourceText $text.session `
        "import { KeyCommandService, KeyCommandContext } from '../model/command/KeyCommandService'" `
        ("import { ACCEPTANCE_TESTS } from 'BuildProfile'`n" +
            "import { DownloadsAccessManager } from '../model/transfer/DownloadsAccessManager'`n" +
            "import { KeyCommandService, KeyCommandContext } from '../model/command/KeyCommandService'")
    $text.session = Set-LeanTTYAcceptanceSourceText $text.session `
        '  private perfPingStartedMs: number = 0' `
        ("  private perfPingStartedMs: number = 0`n" +
            "  private acceptanceInputSequence: number = 0`n" +
            "  private acceptanceBackpressureStalled: boolean = false`n" +
            "  private acceptanceBackpressureProgressCallbacks: number = 0")
    $preparationAnchor = @'
    let prepared: TransferLocalFile | null = null
    try {
'@
    $preparationReplacement = @'
    let prepared: TransferLocalFile | null = null
    try {
      if (ACCEPTANCE_TESTS &&
        command.remotePath === '/.leantty-acceptance-preparation-wait/source.bin') {
        this.logger.info('ACCEPTANCE_FILE_TRANSFER_PREPARATION waiting=true')
        let stalledPreparation: Promise<void> = new Promise<void>((resolve: () => void) => {})
        await DownloadsAccessManager.waitForRequest(
          stalledPreparation, this.transferPreparationCancellation)
      }
'@
    $text.session = Set-LeanTTYAcceptanceSourceText `
        $text.session $preparationAnchor $preparationReplacement
    $backpressureAnchor = @'
  private onFileTransferProgress(event: FileTransferProgress): void {
'@
    $backpressureReplacement = @'
  private onFileTransferProgress(event: FileTransferProgress): void {
    if (ACCEPTANCE_TESTS && this.transferCommand !== null &&
      this.transferCommand.remotePath.endsWith('backpressure-source.bin')) {
      if (event.kind === 'progress') {
        this.acceptanceBackpressureProgressCallbacks++
        if (!this.acceptanceBackpressureStalled) {
          this.acceptanceBackpressureStalled = true
          this.logger.info('ACCEPTANCE_FILE_TRANSFER_BACKPRESSURE state=stalling')
          let releaseAt: number = Date.now() + 1500
          while (Date.now() < releaseAt) {
          }
          this.logger.info('ACCEPTANCE_FILE_TRANSFER_BACKPRESSURE state=released')
        }
      } else if (event.kind === 'completed') {
        this.logger.info('ACCEPTANCE_FILE_TRANSFER_BACKPRESSURE state=completed,progressCallbacks=' +
          this.acceptanceBackpressureProgressCallbacks.toString() + ',' + event.detail)
      }
    }
'@
    $text.session = Set-LeanTTYAcceptanceSourceText `
        $text.session $backpressureAnchor $backpressureReplacement
    $tabCompletionAnchor = @'
    } else {
      this.redrawLocalCommandLine()
    }
  }

  private cycleCompletion(direction: number): void {
'@
    $tabCompletionReplacement = @'
    } else {
      this.redrawLocalCommandLine()
    }
    if (ACCEPTANCE_TESTS) {
      this.logger.info('ACCEPTANCE_TAB_COMPLETE input=' +
        SessionViewModel.terminalSafeText(this.commandLine.getText()) +
        ',matches=' + set.replacements.length.toString())
    }
  }

  private cycleCompletion(direction: number): void {
'@
    $text.session = Set-LeanTTYAcceptanceSourceText `
        $text.session $tabCompletionAnchor $tabCompletionReplacement
    $idleInterruptAnchor = @'
      } else if (action.kind === TerminalInputActionKind.INTERRUPT) {
        this.dismissCompletion()
        this.commandLine.clear()
        this.completionRenderer.reset()
        this.writeTerminal('^C\r\n')
        this.writePrompt()
'@
    $idleInterruptReplacement = @'
      } else if (action.kind === TerminalInputActionKind.INTERRUPT) {
        this.dismissCompletion()
        this.commandLine.clear()
        this.completionRenderer.reset()
        this.writeTerminal('^C\r\n')
        this.writePrompt()
        if (ACCEPTANCE_TESTS) {
          this.logger.info('ACCEPTANCE_IDLE_INTERRUPT cleared=true')
        }
'@
    $text.session = Set-LeanTTYAcceptanceSourceText `
        $text.session $idleInterruptAnchor $idleInterruptReplacement
    $idleActionAnchor = @'
    let actions: TerminalInputAction[] = TerminalInputParser.parse(data, true)
    for (let i = 0; i < actions.length; i++) {
      let action: TerminalInputAction = actions[i]
      if (action.kind === TerminalInputActionKind.SUBMIT) {
'@
    $idleActionReplacement = @'
    let actions: TerminalInputAction[] = TerminalInputParser.parse(data, true)
    for (let i = 0; i < actions.length; i++) {
      let action: TerminalInputAction = actions[i]
      if (ACCEPTANCE_TESTS) {
        this.logger.info('ACCEPTANCE_IDLE_ACTION kind=' + action.kind.toString() +
          ',completionActive=' + this.completionEngine.isActive().toString() +
          ',menuActive=' + this.completionEngine.isMenuActive().toString())
      }
      if (action.kind === TerminalInputActionKind.SUBMIT) {
'@
    $text.session = Set-LeanTTYAcceptanceSourceText `
        $text.session $idleActionAnchor $idleActionReplacement
    $idleResultAnchor = @'
      } else if (action.kind === TerminalInputActionKind.TEXT) {
        if (!this.descendSelectedDirectory(action.text)) {
          let completionWasActive: boolean = this.restoreCompletionBaseForEditing()
          this.commandLine.insert(action.text)
          if (completionWasActive) {
            this.refreshCompletionAfterEdit()
          } else {
            this.redrawLocalCommandLine()
          }
        }
      }
    }
  }

  private handlePasswordInput(data: string): void {
'@
    $idleResultReplacement = @'
      } else if (action.kind === TerminalInputActionKind.TEXT) {
        if (!this.descendSelectedDirectory(action.text)) {
          let completionWasActive: boolean = this.restoreCompletionBaseForEditing()
          this.commandLine.insert(action.text)
          if (completionWasActive) {
            this.refreshCompletionAfterEdit()
          } else {
            this.redrawLocalCommandLine()
          }
        }
      }
      if (ACCEPTANCE_TESTS) {
        this.logger.info('ACCEPTANCE_IDLE_RESULT kind=' + action.kind.toString() + ',input=' +
          SessionViewModel.terminalSafeText(this.commandLine.getText()) +
          ',completionActive=' + this.completionEngine.isActive().toString() +
          ',menuActive=' + this.completionEngine.isMenuActive().toString())
      }
    }
  }

  private handlePasswordInput(data: string): void {
'@
    $text.session = Set-LeanTTYAcceptanceSourceText `
        $text.session $idleResultAnchor $idleResultReplacement
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
      let commandDetail: string = kind === 'command' ? ',input=' +
        SessionViewModel.terminalSafeText(this.commandLine.getText()) : ''
      this.logger.info('ACCEPTANCE_INPUT_SUBMIT sequence=' + this.acceptanceInputSequence.toString() +
        ',kind=' + kind + commandDetail)
    }
  }

'@
    $text.session = Set-LeanTTYAcceptanceSourceText $text.session `
        '  private submitKeyPassphrase(): void {' `
        ($sessionMethod + '  private submitKeyPassphrase(): void {')

    $text.transfer = Set-LeanTTYAcceptanceSourceText $text.transfer `
        "import { DownloadsAccessManager } from './DownloadsAccessManager'" `
        ("import { ACCEPTANCE_TESTS } from 'BuildProfile'`n" +
            "import { DownloadsAccessManager } from './DownloadsAccessManager'")
    $cleanupAnchor = @'
    TransferFileManager.close(prepared)
    if (prepared.tempPath.length > 0) {
      try {
'@
    $cleanupReplacement = @'
    TransferFileManager.close(prepared)
    if (prepared.tempPath.length > 0) {
      try {
        if (ACCEPTANCE_TESTS &&
          prepared.localName === '.leantty-transfer-fixture/local-cleanup-failure.bin') {
          throw new Error('ACCEPTANCE_LOCAL_CLEANUP_FAILURE')
        }
'@
    $text.transfer = Set-LeanTTYAcceptanceSourceText `
        $text.transfer $cleanupAnchor $cleanupReplacement

    $text.client = Set-LeanTTYAcceptanceSourceText $text.client `
        "import sshNative from 'libleantty_ssh.so'" `
        ("import { ACCEPTANCE_TESTS } from 'BuildProfile'`n" +
            "import sshNative from 'libleantty_ssh.so'")
    $text.client = Set-LeanTTYAcceptanceSourceText $text.client `
        '  private static nextGeneration: number = 1' `
        ("  private static nextGeneration: number = 1`n" +
            "  private static acceptancePendingCancelledLateEvent: NativeFileTransferEvent | null = null`n" +
            "  private acceptanceLateEventScenario: string = ''")
    $lateStartAnchor = @'
    this.paneId = options.paneId
    this.privateKeyPath = options.privateKeyPath
'@
    $lateStartReplacement = @'
    this.paneId = options.paneId
    this.privateKeyPath = options.privateKeyPath
    if (options.remotePath.indexOf('late-cancel-source.bin') >= 0) {
      this.acceptanceLateEventScenario = 'cancel'
      this.logger.warn('ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=cancel,state=armed')
    } else if (options.remotePath.indexOf('late-disconnect-source.bin') >= 0) {
      this.acceptanceLateEventScenario = 'disconnect'
      this.logger.warn('ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=disconnect,state=armed')
    }
'@
    $text.client = Set-LeanTTYAcceptanceSourceText `
        $text.client $lateStartAnchor $lateStartReplacement
    $lateStartDeliveryAnchor = @'
    this.logger.info('File transfer initiated, transferId=' + this.transferId)
'@
    $lateStartDeliveryReplacement = @'
    this.logger.info('File transfer initiated, transferId=' + this.transferId)
    if (FileTransferClient.acceptancePendingCancelledLateEvent !== null) {
      let staleEvent: NativeFileTransferEvent = FileTransferClient.acceptancePendingCancelledLateEvent
      FileTransferClient.acceptancePendingCancelledLateEvent = null
      staleEvent.kind = 'completed'
      staleEvent.code = ''
      staleEvent.detail = ''
      this.logger.warn('ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=cancel,state=injected')
      this.handleNativeTransferEvent(staleEvent)
    } else if (this.acceptanceLateEventScenario === 'disconnect') {
      this.logger.warn('ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=cancel,state=missing')
    }
'@
    $text.client = Set-LeanTTYAcceptanceSourceText `
        $text.client $lateStartDeliveryAnchor $lateStartDeliveryReplacement
    $lateCaptureAnchor = @'
    let event: FileTransferProgress = new FileTransferProgress()
'@
    $lateCaptureReplacement = @'
    if (this.acceptanceLateEventScenario === 'cancel' &&
      FileTransferClient.acceptancePendingCancelledLateEvent === null) {
      FileTransferClient.acceptancePendingCancelledLateEvent = nativeEvent
      this.logger.warn('ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=cancel,state=captured')
    }
    let event: FileTransferProgress = new FileTransferProgress()
'@
    $text.client = Set-LeanTTYAcceptanceSourceText `
        $text.client $lateCaptureAnchor $lateCaptureReplacement
    $lateTerminalAnchor = @'
    if (event.kind === 'completed' || event.kind === 'failed' || event.kind === 'cancelled') {
      this.transferId = ''
'@
    $lateTerminalReplacement = @'
    if (event.kind === 'completed' || event.kind === 'failed' || event.kind === 'cancelled') {
      if (this.acceptanceLateEventScenario === 'cancel' &&
        event.kind === 'cancelled') {
        FileTransferClient.acceptancePendingCancelledLateEvent = nativeEvent
      } else if (this.acceptanceLateEventScenario === 'disconnect' &&
        event.kind === 'failed') {
        let staleEvent: NativeFileTransferEvent = nativeEvent
        setTimeout(() => {
          staleEvent.kind = 'completed'
          staleEvent.code = ''
          staleEvent.detail = ''
          this.logger.warn('ACCEPTANCE_FILE_TRANSFER_LATE_EVENT scenario=disconnect,state=injected')
          this.handleNativeTransferEvent(staleEvent)
        }, 10000)
      }
      this.transferId = ''
'@
    $text.client = Set-LeanTTYAcceptanceSourceText `
        $text.client $lateTerminalAnchor $lateTerminalReplacement

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
        Join-Path $RepoRoot 'entry\src\main\ets\model\transfer\TransferFileManager.ets'
        Join-Path $RepoRoot 'entry\src\main\ets\model\transfer\FileTransferClient.ets'
    )
    $backups = @{}
    foreach ($path in $paths) { $backups[$path] = [IO.File]::ReadAllBytes($path) }
    try {
        Add-LeanTTYAcceptanceSource -RepoRoot $RepoRoot | Out-Null
        & $Action
    } finally {
        foreach ($path in $paths) {
            Restore-LeanTTYAcceptanceSourceFile -Path $path -Bytes $backups[$path]
        }
    }
}

function Restore-LeanTTYAcceptanceSourceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    for ($attempt = 1; $attempt -le 50; $attempt++) {
        try {
            [IO.File]::WriteAllBytes($Path, $Bytes)
            return
        } catch [IO.IOException] {
            if ($attempt -eq 50) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Add-LeanTTYNativeAcceptanceSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $nativePath = Join-Path $RepoRoot 'leantty_ssh\src\lib.rs'
    $typesPath = Join-Path $RepoRoot 'entry\src\main\cpp\types\libleantty_ssh\index.d.ts'
    $native = [IO.File]::ReadAllText($nativePath)
    $types = [IO.File]::ReadAllText($typesPath)

    $nativeImports = "use std::future::Future;`nuse std::io::Read;"
    if (-not $native.Contains('use std::os::fd::BorrowedFd;')) {
        $nativeImports += "`nuse std::os::fd::BorrowedFd;"
    }
    $native = Set-LeanTTYAcceptanceSourceText $native `
        'use std::future::Future;' `
        $nativeImports
    $native = Set-LeanTTYAcceptanceSourceText $native `
        'static NEXT_SESSION_ID: AtomicU32 = AtomicU32::new(1);' `
        ("static NEXT_SESSION_ID: AtomicU32 = AtomicU32::new(1);`n" +
            'static ACCEPTANCE_DROPPED_FILE_TRANSFER_EVENTS: AtomicU32 = AtomicU32::new(0);')
    $native = Set-LeanTTYAcceptanceSourceText $native `
        'Arc<ThreadsafeFunction<FileTransferEvent, (), FileTransferEvent, Status, false, false, 64>>;' `
        'Arc<ThreadsafeFunction<FileTransferEvent, (), FileTransferEvent, Status, false, false, 2>>;'
    $nativeTransferSendAnchor = @'
    if status != Status::Ok {
        eprintln!("[LTTY_SSH] callback=file_transfer status={}", status);
        return false;
    }
'@
    $nativeTransferSendReplacement = @'
    if status != Status::Ok {
        if !final_event {
            ACCEPTANCE_DROPPED_FILE_TRANSFER_EVENTS.fetch_add(1, Ordering::SeqCst);
        }
        eprintln!("[LTTY_SSH] callback=file_transfer status={}", status);
        return false;
    }
'@
    $native = Set-LeanTTYAcceptanceSourceText `
        $native $nativeTransferSendAnchor $nativeTransferSendReplacement
    $nativeCompletedAnchor = @'
            let delivered = send_file_transfer_event(
                &transfer_callback,
                FileTransferEvent::completed(transfer_id, &pane_id, generation, bytes, total_bytes),
                true,
            );
'@
    $nativeCompletedReplacement = @'
            let mut completed =
                FileTransferEvent::completed(transfer_id, &pane_id, generation, bytes, total_bytes);
            let dropped = ACCEPTANCE_DROPPED_FILE_TRANSFER_EVENTS.swap(0, Ordering::SeqCst);
            completed.detail = format!("ACCEPTANCE_FILE_TRANSFER_DROPPED={dropped}");
            let delivered = send_file_transfer_event(&transfer_callback, completed, true);
'@
    $native = Set-LeanTTYAcceptanceSourceText `
        $native $nativeCompletedAnchor $nativeCompletedReplacement
    $nativeTransferBuilderAnchor = @'
    let transfer_callback = Arc::new(
        on_transfer
            .build_threadsafe_function::<FileTransferEvent>()
            .max_queue_size::<64>()
            .build()?,
    );
'@
    $nativeTransferBuilderReplacement = @'
    let transfer_callback = Arc::new(
        on_transfer
            .build_threadsafe_function::<FileTransferEvent>()
            .max_queue_size::<2>()
            .build()?,
    );
'@
    $native = Set-LeanTTYAcceptanceSourceText `
        $native $nativeTransferBuilderAnchor $nativeTransferBuilderReplacement
    $nativeCleanupAnchor = @'
    let mut local_temp_cleanup = LocalTempCleanup(if direction == transfer::Direction::Get {
        Some(PathBuf::from(local_temp_path))
    } else {
        None
    });
'@
    $nativeCleanupReplacement = @'
    let acceptance_local_cleanup_failure = direction == transfer::Direction::Get
        && remote_path.ends_with("missing-local-cleanup-source.bin");
    if acceptance_local_cleanup_failure {
        eprintln!("[LTTY_SSH] ACCEPTANCE_LOCAL_TEMP_CLEANUP_FAILURE armed");
    }
    let mut local_temp_cleanup = LocalTempCleanup(if direction == transfer::Direction::Get
        && !acceptance_local_cleanup_failure
    {
        Some(PathBuf::from(local_temp_path))
    } else {
        None
    });
'@
    $native = Set-LeanTTYAcceptanceSourceText `
        $native $nativeCleanupAnchor $nativeCleanupReplacement
    $nativeDiskFullStartAnchor = @'
    let result = transfer::execute(
'@
    $nativeDiskFullStartReplacement = @'
    let result = if direction == transfer::Direction::Get
        && remote_path.ends_with("disk-full-source.bin")
    {
        eprintln!("[LTTY_SSH] ACCEPTANCE_LOCAL_DISK_FULL armed");
        Err(transfer::TransferFailure::Failed {
            code: "WRITE",
            detail: "file write failed: No space left on device (os error 28)".to_string(),
        })
    } else {
        transfer::execute(
'@
    $native = Set-LeanTTYAcceptanceSourceText `
        $native $nativeDiskFullStartAnchor $nativeDiskFullStartReplacement
    $nativeDiskFullEndAnchor = @'
        },
    )
    .await;
    let _ = transfer::bounded_operation(
        sftp.close(),
'@
    $nativeDiskFullEndReplacement = @'
            },
        )
        .await
    };
    let _ = transfer::bounded_operation(
        sftp.close(),
'@
    $native = Set-LeanTTYAcceptanceSourceText `
        $native $nativeDiskFullEndAnchor $nativeDiskFullEndReplacement
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
        foreach ($path in $paths) {
            Restore-LeanTTYAcceptanceSourceFile -Path $path -Bytes $backups[$path]
        }
    }
}

import { describe, it, expect } from '@ohos/hypium'
import { CommandParser, TransferCommandResult } from '../main/ets/model/command/CommandParser'
import { SshConfig } from '../main/ets/model/ssh/SshConfig'
import { BridgeMessage, BridgeProtocol } from '../main/ets/model/bridge/BridgeProtocol'
import { InteractionPolicy } from '../main/ets/model/ui/InteractionPolicy'
import { KeyCodeMap } from '../main/ets/common/constants/KeyCodeMap'
import { TerminalOutputBuffer } from '../main/ets/model/terminal/TerminalOutputBuffer'
import { TerminalInputAction, TerminalInputActionKind, TerminalInputParser } from '../main/ets/model/terminal/TerminalInputParser'
import { LocalCommandLine } from '../main/ets/model/terminal/LocalCommandLine'
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'
import { BrowserLauncher } from '../main/ets/model/browser/BrowserLauncher'
import { CommandBarViewModel } from '../main/ets/viewmodel/CommandBarViewModel'
import { TerminalTextPolicy } from '../main/ets/common/security/TerminalTextPolicy'
import { LocalCompletionEngine, LocalCompletionSet, LocalCompletionUpdate, LocalCompletionUpdateKind } from '../main/ets/model/terminal/LocalCompletionEngine'
import { LocalCompletionLayout, LocalCompletionNavigation, LocalCompletionRenderer } from '../main/ets/model/terminal/LocalCompletionRenderer'

export default function terminalInteractionTest() {
  describe('TerminalInteraction', () => {
    it('cyclesAndAcceptsAmbiguousCompletionsWithoutRunningTheCommand', 0, () => {
      let vm: CommandBarViewModel = new CommandBarViewModel()
      let engine: LocalCompletionEngine = new LocalCompletionEngine()
      vm.getSshConfig().loadFromText('Host prod production\n  HostName prod.example.com\n  User deploy\n')
      vm.setInputText('get p')
      let set: LocalCompletionSet = vm.completionSet()
      expect(set.replacements.length).assertEqual(2)
      expect(set.displayValues[0]).assertEqual('prod:')
      expect(set.displayValues[1]).assertEqual('production:')
      let listed: LocalCompletionUpdate = engine.complete('get p', set)
      expect(listed.kind).assertEqual(LocalCompletionUpdateKind.LISTED)
      expect(listed.text).assertEqual('get p')
      expect(listed.selectedIndex).assertEqual(-1)
      let selected: LocalCompletionUpdate = engine.complete('get p', set)
      expect(selected.kind).assertEqual(LocalCompletionUpdateKind.SELECTED)
      expect(selected.text).assertEqual('get prod:')
      expect(selected.displayValues.length).assertEqual(2)
      expect(selected.selectedIndex).assertEqual(0)
      expect(engine.isMenuActive()).assertEqual(true)
      let cycled: LocalCompletionUpdate = engine.cycle(1)
      expect(cycled.text).assertEqual('get production:')
      expect(cycled.selectedIndex).assertEqual(1)
      expect(engine.cycle(1).text).assertEqual('get prod:')
      expect(engine.cycle(-1).text).assertEqual('get production:')
      expect(engine.accept().text).assertEqual('get production:')
      expect(engine.isMenuActive()).assertEqual(false)

      listed = engine.complete('get p', set)
      expect(listed.kind).assertEqual(LocalCompletionUpdateKind.LISTED)
      expect(engine.cancel().text).assertEqual('get p')

      let directorySet: LocalCompletionSet = new LocalCompletionSet()
      directorySet.replacements = ['put ./reports/', 'put ./report.txt']
      directorySet.displayValues = ['reports/', 'report.txt']
      let directory: LocalCompletionUpdate = engine.complete('put ./r', directorySet)
      expect(directory.kind).assertEqual(LocalCompletionUpdateKind.LISTED)
      directory = engine.complete('put ./r', directorySet)
      expect(directory.text).assertEqual('put ./reports/')
      expect(engine.selectedCandidate()).assertEqual('put ./reports/')
      expect(engine.accept().text).assertEqual('put ./reports/')
    })

    it('editsTheSelectedCompletionAndUsesRollbackOnlyForCancellation', 0, () => {
      let engine: LocalCompletionEngine = new LocalCompletionEngine()
      let initial: LocalCompletionSet = new LocalCompletionSet()
      initial.replacements = ['put ./alpha.txt', 'put ./alpine.txt']
      initial.displayValues = ['alpha.txt', 'alpine.txt']
      engine.complete('put ./a', initial)
      let selected: LocalCompletionUpdate = engine.complete('put ./a', initial)
      expect(selected.text).assertEqual('put ./alpha.txt')

      let line: LocalCommandLine = new LocalCommandLine()
      line.setText(selected.text)
      line.setText(engine.editingText())
      line.insert(' ')
      expect(line.getText()).assertEqual('put ./alpha.txt ')
      expect(engine.isActive()).assertEqual(false)

      let directorySet: LocalCompletionSet = new LocalCompletionSet()
      directorySet.replacements = ['put ./alpha/', 'put ./archive/']
      directorySet.displayValues = ['alpha/', 'archive/']
      engine.complete('put ./a', directorySet)
      selected = engine.complete('put ./a', directorySet)
      line.setText(selected.text)
      line.setText(engine.editingText())
      line.insert('c')
      expect(line.getText()).assertEqual('put ./alpha/c')
      expect(engine.isActive()).assertEqual(false)

      engine.complete('put ./a', initial)
      selected = engine.complete('put ./a', initial)
      line.setText(selected.text)
      line.setText(engine.editingText())
      line.backspace()
      expect(line.getText()).assertEqual('put ./alpha.tx')
      expect(engine.isActive()).assertEqual(false)

      engine.complete('put ./a', initial)
      engine.complete('put ./a', initial)
      expect(engine.cancel().text).assertEqual('put ./a')

      engine.complete('put ./a', initial)
      expect(engine.editingText()).assertEqual('put ./a')
      expect(engine.isActive()).assertEqual(false)
    })

    it('formatsCompletionCandidatesByTerminalCells', 0, () => {
      expect(CommandBarViewModel.completionDisplayValue(
        'put ./reports/report\\ alpha.txt', 4)).assertEqual('report alpha.txt')
      expect(CommandBarViewModel.completionDisplayValue(
        'put ./reports/', 4)).assertEqual('reports/')
      expect(SessionViewModel.terminalCellWidth('plain')).assertEqual(5)
      expect(SessionViewModel.terminalCellWidth('报告')).assertEqual(4)
      expect(SessionViewModel.terminalCellWidth('😀')).assertEqual(2)
      expect(SessionViewModel.formatCompletionCandidates(['alpha', '报告/', 'beta'], 14))
        .assertEqual('alpha  beta\r\n报告/')
    })

    it('rendersOneTransientCompletionRegionBelowTheCommand', 0, () => {
      let renderer: LocalCompletionRenderer = new LocalCompletionRenderer()
      let first: string = renderer.render('ltty> ', 'put ./a', 7,
        ['alpha/', 'alpine.txt'], -1, false, 40, 24)
      expect(first.indexOf('ltty> put ./a\r\nalpha/')).assertEqual(5)
      expect(first.includes('\u001b[7m')).assertEqual(false)

      let second: string = renderer.render('ltty> ', 'put ./alpha/', 12,
        ['alpha/', 'alpine.txt'], 0, false, 40, 24)
      expect(second.includes('\u001b[1B\r\u001b[2K')).assertEqual(true)
      expect(second.includes('ltty> put ./alpha/\r\n\u001b[7malpha/\u001b[0m')).assertEqual(true)
      expect(second.indexOf('alpine.txt')).assertEqual(second.lastIndexOf('alpine.txt'))
    })

    it('navigatesCompletionColumnsInDisplayedOrder', 0, () => {
      let layout: LocalCompletionLayout = LocalCompletionRenderer.layout(
        ['aaaa', 'bbbb', 'cccc', 'dddd', 'eeee', 'ffff'], 0, false, 14, 8)
      expect(layout.rowCount).assertEqual(3)
      expect(LocalCompletionRenderer.moveSelection(
        0, LocalCompletionNavigation.DOWN, 6, layout)).assertEqual(1)
      expect(LocalCompletionRenderer.moveSelection(
        0, LocalCompletionNavigation.UP, 6, layout)).assertEqual(2)
      expect(LocalCompletionRenderer.moveSelection(
        1, LocalCompletionNavigation.RIGHT, 6, layout)).assertEqual(4)
      expect(LocalCompletionRenderer.moveSelection(
        4, LocalCompletionNavigation.LEFT, 6, layout)).assertEqual(1)
    })

    it('boundsLongCompletionRowsWithoutDroppingTheDirectoryMarker', 0, () => {
      let layout: LocalCompletionLayout = LocalCompletionRenderer.layout(
        ['this-is-a-very-long-directory-name/'], -1, false, 10, 4)
      expect(layout.lines.length).assertEqual(1)
      expect(LocalCompletionRenderer.terminalCellWidth(layout.lines[0]) <= 9).assertEqual(true)
      expect(layout.lines[0].endsWith('.../')).assertEqual(true)
    })

    it('reflowsTheTrackedCommandRegionAfterATerminalResize', 0, () => {
      let renderer: LocalCompletionRenderer = new LocalCompletionRenderer()
      renderer.render('ltty> ', '123456789012345', 15, [], -1, false, 20, 24)
      let resized: string = renderer.render(
        'ltty> ', '123456789012345', 15, [], -1, false, 10, 24)
      expect(resized.startsWith('\r\u001b[2A')).assertEqual(true)
      expect(resized.includes('\u001b[1B\r\u001b[2K')).assertEqual(true)
      expect(resized.endsWith('\r\u001b[1C')).assertEqual(true)
    })

    it('doesNotTreatEscapedOrQuotedTrailingSpacesAsOperandSeparators', 0, () => {
      let vm: CommandBarViewModel = new CommandBarViewModel()
      vm.getSshConfig().loadFromText('Host alpha beta gamma\n  HostName fixture.example\n  User deploy\n')
      vm.setInputText('put missing\\ ')
      expect(vm.tryTabComplete().length).assertEqual(0)
      vm.setInputText('put "missing ')
      expect(vm.tryTabComplete().length).assertEqual(0)
    })

    it('keepsTransferCompletionContextsBoundedAndOffline', 0, () => {
      let vm: CommandBarViewModel = new CommandBarViewModel()
      let configText: string = ''
      for (let index: number = 0; index < 105; index++) {
        configText += 'Host host' + index.toString().padStart(3, '0') + '\n' +
          '  HostName fixture.example\n  User deploy\n'
      }
      configText += 'Host Prod prod 报告\n  HostName fixture.example\n  User deploy\n'
      vm.getSshConfig().loadFromText(configText)
      vm.setInputText('get host')
      let bounded: LocalCompletionSet = vm.completionSet()
      expect(bounded.replacements.length).assertEqual(100)
      expect(bounded.truncated).assertEqual(true)
      vm.setInputText('get P')
      expect(vm.tryTabComplete()[0]).assertEqual('get Prod:')
      vm.setInputText('get 报')
      expect(vm.tryTabComplete()[0]).assertEqual('get 报告:')
      vm.setInputText('get prod:/remote')
      expect(vm.tryTabComplete().length).assertEqual(0)
      vm.setInputText('put -p ')
      expect(vm.tryTabComplete().length).assertEqual(0)
      vm.setInputText('put -i ')
      expect(vm.tryTabComplete().length).assertEqual(0)
      vm.setInputText('put local')
      expect(vm.tryTabComplete().length).assertEqual(0)
      let commandVm: CommandBarViewModel = new CommandBarViewModel()
      commandVm.setInputText('ex')
      expect(commandVm.tryTabComplete()[0]).assertEqual('exit')
    })

    it('rejectsUnsafeCompletionValuesBeforeTheyReachTheTerminal', 0, () => {
      expect(CommandBarViewModel.safeCompletionValue('报告 😀.txt')).assertEqual(true)
      for (let value of [
        'bad\u001b[2J', 'line\nbreak', 'c1\u0085name', 'bidi\u202Ename', 'isolate\u2066name',
        'zero\u200Bwidth', 'bom\uFEFFname', 'tag\uDB40\uDC61name', 'bad\uD800', 'bad\uDC00'
      ]) {
        expect(CommandBarViewModel.safeCompletionValue(value)).assertEqual(false)
      }
      expect(TerminalTextPolicy.escape('报告 😀.txt')).assertEqual('报告 😀.txt')
      expect(TerminalTextPolicy.escape('bidi\u202Ename')).assertEqual('bidi\\u{202e}name')
      let unsafePath = CommandParser.parseInput('put bidi\u202Ename prod:/tmp/name', new SshConfig())
      expect(unsafePath instanceof TransferCommandResult).assertEqual(true)
      if (unsafePath instanceof TransferCommandResult) {
        expect(unsafePath.isValid).assertEqual(false)
      }
      let vm: CommandBarViewModel = new CommandBarViewModel()
      vm.getSshConfig().loadFromText('Host prod bad\u001b[2J\n  HostName prod.example.com\n  User deploy\n')
      vm.setInputText('get ')
      let matches: string[] = vm.tryTabComplete()
      expect(matches.length).assertEqual(1)
      expect(matches[0]).assertEqual('get prod:')
    })

    it('reportsCopySelectionResultsIncludingAnEmptySelection', 0, () => {
      expect(BridgeProtocol.copySelectionResult('copied text').serialize())
        .assertEqual('H2|W2N|CONTROL|copySelection|copied text')
      expect(BridgeProtocol.copySelectionResult('').serialize())
        .assertEqual('H2|W2N|CONTROL|copySelection|')
    })

    it('acceptsOnlyWebToNativeUrlOpenControls', 0, () => {
      let openUrl: BridgeMessage | null =
        BridgeProtocol.parse('H2|W2N|CONTROL|openUrl|https://example.com/path?q=1')
      expect(openUrl !== null).assertEqual(true)
      if (openUrl !== null) {
        expect(openUrl.kind).assertEqual(BridgeProtocol.KIND_OPEN_URL)
        expect(openUrl.payload).assertEqual('https://example.com/path?q=1')
      }
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|openUrl|https://example.com')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|DATA|openUrl|https://example.com')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|openUrl|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|openUrl|' +
        'x'.repeat(BridgeProtocol.MAX_URL_PAYLOAD_LENGTH + 1))).assertEqual(null)
    })

    it('allowsOnlyNormalizedCredentialFreeHttpUrls', 0, () => {
      expect(BrowserLauncher.normalizeHttpUrl('https://example.com/path?q=1'))
        .assertEqual('https://example.com/path?q=1')
      expect(BrowserLauncher.normalizeHttpUrl('HTTP://EXAMPLE.COM'))
        .assertEqual('http://EXAMPLE.COM')
      expect(BrowserLauncher.normalizeHttpUrl('ftp://example.com')).assertEqual(null)
      expect(BrowserLauncher.normalizeHttpUrl('https://user:secret@example.com')).assertEqual(null)
      expect(BrowserLauncher.normalizeHttpUrl(' https://example.com')).assertEqual(null)
      expect(BrowserLauncher.normalizeHttpUrl('https://example.com/\nnext')).assertEqual(null)
    })

    it('encodesTerminalFocusAndBlurAsSeparateBridgeMessages', 0, () => {
      expect(BridgeProtocol.focus().serialize()).assertEqual('H2|N2W|CONTROL|focus|')
      expect(BridgeProtocol.blur().serialize()).assertEqual('H2|N2W|CONTROL|blur|')
      expect(BridgeProtocol.clearSelection().serialize()).assertEqual('H2|N2W|CONTROL|clearSelection|')
    })

    it('routesTerminalSurfaceActionsThroughBridgeControls', 0, () => {
      expect(BridgeProtocol.fit().serialize()).assertEqual('H2|N2W|CONTROL|fit|')
      expect(BridgeProtocol.fontSize(18).serialize()).assertEqual('H2|N2W|CONTROL|fontSize|18')
      expect(BridgeProtocol.inputSecurity(true).serialize())
        .assertEqual('H2|N2W|CONTROL|inputSecurity|masked')
      expect(BridgeProtocol.inputSecurity(false).serialize())
        .assertEqual('H2|N2W|CONTROL|inputSecurity|plain')
      expect(BridgeProtocol.copySelection().serialize()).assertEqual('H2|N2W|CONTROL|copySelection|')
      expect(BridgeProtocol.parse(BridgeProtocol.copySelection().serialize()) !== null).assertEqual(true)
      expect(BridgeProtocol.secondaryAction().serialize()).assertEqual('H2|N2W|CONTROL|secondaryAction|')
      expect(BridgeProtocol.copyOrInterrupt().serialize()).assertEqual('H2|N2W|CONTROL|copyOrInterrupt|')
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|copyOrInterrupt|unexpected') === null).assertEqual(true)
      expect(BridgeProtocol.searchOpen().serialize()).assertEqual('H2|N2W|CONTROL|searchOpen|')
      expect(BridgeProtocol.searchClose().serialize()).assertEqual('H2|N2W|CONTROL|searchClose|')
    })

    it('preservesDirectionalBridgePayloadsWithoutJsonEncoding', 0, () => {
      let raw: string = BridgeProtocol.write('a|b:c\r\n').serialize()
      let parsed: BridgeMessage | null = BridgeProtocol.parse(raw)
      expect(parsed !== null).assertEqual(true)
      if (parsed !== null) {
        expect(parsed.direction).assertEqual(BridgeProtocol.DIRECTION_NATIVE_TO_WEB)
        expect(parsed.channel).assertEqual(BridgeProtocol.CHANNEL_DATA)
        expect(parsed.kind).assertEqual(BridgeProtocol.KIND_TERMINAL)
        expect(parsed.payload).assertEqual('a|b:c\r\n')
      }
      expect(BridgeProtocol.parse('D:legacy')).assertEqual(null)
    })

    it('rejectsUnknownOrMisdirectedBridgeMessages', 0, () => {
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|unknown|payload')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|bell|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|title|remote-title')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|bellAttention|unexpected')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|attentionAcknowledged|unexpected')).assertEqual(null)
      let bellAttention: BridgeMessage | null =
        BridgeProtocol.parse('H2|W2N|CONTROL|bellAttention|')
      expect(bellAttention !== null).assertEqual(true)
      if (bellAttention !== null) {
        expect(bellAttention.kind).assertEqual(BridgeProtocol.KIND_BELL_ATTENTION)
        expect(bellAttention.payload).assertEqual('')
      }
      let attentionAcknowledged: BridgeMessage | null =
        BridgeProtocol.parse('H2|W2N|CONTROL|attentionAcknowledged|')
      expect(attentionAcknowledged !== null).assertEqual(true)
      if (attentionAcknowledged !== null) {
        expect(attentionAcknowledged.kind).assertEqual(BridgeProtocol.KIND_ATTENTION_ACKNOWLEDGED)
        expect(attentionAcknowledged.payload).assertEqual('')
      }
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|ready|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|theme|{}')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|DATA|resize|80,24')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|DATA|terminal|ok') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|DATA|terminal|ok') !== null).assertEqual(true)
      let searchOpen: BridgeMessage | null = BridgeProtocol.parse('H2|N2W|CONTROL|searchOpen|')
      expect(searchOpen !== null).assertEqual(true)
      if (searchOpen !== null) {
        expect(searchOpen.kind).assertEqual(BridgeProtocol.KIND_SEARCH_OPEN)
        expect(searchOpen.payload).assertEqual('')
      }
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|searchOpen|query')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|searchClose|query')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchState|open') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchState|composing') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchState|closed') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchState|unknown')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|inputSecurity|secret')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchOpen|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|DATA|searchOpen|')).assertEqual(null)
    })

    it('routesPhysicalTabToTerminalCompletion', 0, () => {
      let tab: string = KeyCodeMap.toAnsi(KeyCodeMap.TAB, false, false, false)
      let actions: TerminalInputAction[] = TerminalInputParser.parse(tab, true)
      let reverseTab: string = KeyCodeMap.toAnsi(KeyCodeMap.TAB, false, false, true)
      let reverseActions: TerminalInputAction[] = TerminalInputParser.parse(reverseTab, true)
      let escapeActions: TerminalInputAction[] = TerminalInputParser.parse('\u001b', true)
      expect(InteractionPolicy.isTerminalTabKey(KeyCodeMap.TAB, false, false, false)).assertEqual(true)
      expect(InteractionPolicy.isTerminalTabKey(KeyCodeMap.TAB, true, false, false)).assertEqual(false)
      expect(InteractionPolicy.isTerminalTabKey(KeyCodeMap.TAB, false, false, true)).assertEqual(true)
      expect(tab).assertEqual('\t')
      expect(actions.length).assertEqual(1)
      expect(actions[0].kind).assertEqual(TerminalInputActionKind.TAB)
      expect(reverseTab).assertEqual('\u001b[Z')
      expect(reverseActions.length).assertEqual(1)
      expect(reverseActions[0].kind).assertEqual(TerminalInputActionKind.REVERSE_TAB)
      expect(escapeActions.length).assertEqual(1)
      expect(escapeActions[0].kind).assertEqual(TerminalInputActionKind.ESCAPE)
    })

    it('rejectsRemovedReplayMessagesAndKeepsOsc52DirectionBounded', 0, () => {
      expect(BridgeProtocol.clipboardWriteResult('中文').serialize())
        .assertEqual('H2|W2N|CONTROL|clipboardWrite|中文')
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|replayBegin|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|replayBegin|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|releaseBuffers|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|clipboardWrite|text')).assertEqual(null)
    })

    it('allowsOnlyBoundedDirectionalTerminalSnapshotControls', 0, () => {
      expect(BridgeProtocol.snapshotRequest(7).serialize())
        .assertEqual('H2|N2W|CONTROL|snapshotRequest|7')
      expect(BridgeProtocol.restoreSnapshot('\u001b[31mhistory').serialize())
        .assertEqual('H2|N2W|CONTROL|restoreSnapshot|\u001b[31mhistory')
      let snapshot: BridgeMessage | null =
        BridgeProtocol.parse('H2|W2N|CONTROL|snapshot|7|\u001b[31mhistory')
      expect(snapshot !== null).assertEqual(true)
      if (snapshot !== null) {
        expect(snapshot.kind).assertEqual(BridgeProtocol.KIND_SNAPSHOT)
        expect(snapshot.payload).assertEqual('7|\u001b[31mhistory')
      }
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshotRequest|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshotRequest|0')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshotRequest|07')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|restoreComplete|') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|restoreComplete|unexpected')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshot|history')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|restoreSnapshot|history')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshotRequest|unexpected')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|snapshot|' +
        'x'.repeat(BridgeProtocol.MAX_SNAPSHOT_PAYLOAD_LENGTH + 1))).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|restoreSnapshot|' +
        'x'.repeat(BridgeProtocol.MAX_SNAPSHOT_PAYLOAD_LENGTH + 1))).assertEqual(null)
    })

    it('encodesShiftedDigitsAndAltPunctuation', 0, () => {
      expect(KeyCodeMap.toAnsi(KeyCodeMap.NUM_1, false, false, true)).assertEqual('!')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.NUM_0, false, false, true)).assertEqual(')')
      expect(KeyCodeMap.toAnsi(2057, false, true, false)).assertEqual('\u001b-')
    })

    it('encodesCursorKeysForTerminalModeAndModifiers', 0, () => {
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_UP, false, false, false, true)).assertEqual('\u001bOA')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_LEFT, true, false, false, false)).assertEqual('\u001b[1;5D')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_DOWN, false, false, true, false)).assertEqual('\u001b[1;2B')
    })

    it('buffersOnlyOutputProducedWhileTheTerminalSurfaceIsDetached', 0, () => {
      let output: TerminalOutputBuffer = new TerminalOutputBuffer(6)
      output.append(new Uint8Array([1, 2, 3, 4]))
      expect(output.isOutputPaused()).assertEqual(false)
      output.append(new Uint8Array([5, 6]))
      expect(output.isOutputPaused()).assertEqual(true)
      expect(output.getDetachedByteCount()).assertEqual(6)
      let detachedChunks: Uint8Array[] = output.takeDetachedChunks()
      expect(detachedChunks.length).assertEqual(2)
      expect(detachedChunks[0][0]).assertEqual(1)
      expect(detachedChunks[1][1]).assertEqual(6)
      output.markAttached()
      expect(output.isOutputPaused()).assertEqual(false)
      output.append(new Uint8Array([7, 8, 9, 10, 11, 12]))
      expect(output.getDetachedByteCount()).assertEqual(0)
      output.setBridgeBackpressured(true)
      expect(output.isOutputPaused()).assertEqual(true)
      output.releaseDisconnectedFlowControl()
      expect(output.isOutputPaused()).assertEqual(false)
      output.markDetached()
      output.append(new Uint8Array([13, 14]))
      expect(output.getDetachedByteCount()).assertEqual(2)
      expect(output.takeDetachedChunks()[0][1]).assertEqual(14)
    })

    it('keepsTheLatestTerminalSnapshotAcrossSurfaceReplacement', 0, () => {
      let output: TerminalOutputBuffer = new TerminalOutputBuffer(16)
      expect(output.getSnapshot()).assertEqual('')
      output.replaceSnapshot('\u001b[31mold')
      expect(output.getSnapshot()).assertEqual('\u001b[31mold')
      output.markAttached()
      output.append(new Uint8Array([1, 2]))
      output.markDetached()
      expect(output.getSnapshot()).assertEqual('\u001b[31mold')
      output.markSessionReset('\u001b[?25h')
      expect(output.getSnapshot()).assertEqual('\u001b[31mold\u001b[?25h')
      output.append(new Uint8Array([3, 4]))
      expect(output.takeDetachedChunks()[0][1]).assertEqual(4)
      output.replaceSnapshot('\u001b[32mnew')
      expect(output.getSnapshot()).assertEqual('\u001b[32mnew')
      output.replaceSnapshot('')
      expect(output.getSnapshot()).assertEqual('')
    })
  })
}

import { describe, it, expect } from '@ohos/hypium'
import { CommandParser, TransferCommandResult } from '../main/ets/model/command/CommandParser'
import { SshConfig } from '../main/ets/model/ssh/SshConfig'
import { InteractionPolicy } from '../main/ets/model/ui/InteractionPolicy'
import { KeyCodeMap } from '../main/ets/common/constants/KeyCodeMap'
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




    it('encodesShiftedDigitsAndAltPunctuation', 0, () => {
      expect(KeyCodeMap.toAnsi(KeyCodeMap.NUM_1, false, false, true)).assertEqual('!')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.NUM_0, false, false, true)).assertEqual(')')
      expect(KeyCodeMap.toAnsi(2057, false, true, false)).assertEqual('\u001b-')
    })

    it('routesPhysicalControlCaretThroughTheNativeKeyBoundary', 0, () => {
      expect(InteractionPolicy.isTerminalControlCaretKey(2006, true, false, true)).assertEqual(true)
      expect(InteractionPolicy.isTerminalControlCaretKey(2006, false, false, true)).assertEqual(false)
      expect(InteractionPolicy.isTerminalControlCaretKey(2006, true, true, true)).assertEqual(false)
      expect(InteractionPolicy.isTerminalControlCaretKey(2006, true, false, false)).assertEqual(false)
      expect(KeyCodeMap.toAnsi(2006, true, false, true)).assertEqual('\u001e')
    })

    it('encodesCursorKeysForTerminalModeAndModifiers', 0, () => {
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_UP, false, false, false, true)).assertEqual('\u001bOA')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_LEFT, true, false, false, false)).assertEqual('\u001b[1;5D')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_DOWN, false, false, true, false)).assertEqual('\u001b[1;2B')
    })





  })
}

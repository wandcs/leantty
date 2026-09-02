import { describe, it, expect } from '@ohos/hypium'
import { PaneInfo, SshSessionState, TabInfo, TerminalMode } from '../main/ets/common/types/TerminalTypes'
import {
  RecoveryRunState,
  RecoveryTabSnapshot,
  RecoveryWorkspaceSnapshot,
  UnexpectedExitRecoveryCodec,
  UnexpectedExitRecoveryRecord
} from '../main/ets/model/persistence/UnexpectedExitRecoveryRecord'
import { AppViewModel } from '../main/ets/viewmodel/AppViewModel'

function sampleWorkspace(): RecoveryWorkspaceSnapshot {
  let workspace: RecoveryWorkspaceSnapshot = new RecoveryWorkspaceSnapshot()
  workspace.activeTabPosition = 1
  workspace.splitRatio = 0.65
  let first: RecoveryTabSnapshot = new RecoveryTabSnapshot()
  first.paneCount = 2
  first.activePanePosition = 0
  workspace.tabs.push(first)
  let second: RecoveryTabSnapshot = new RecoveryTabSnapshot()
  second.paneCount = 1
  second.activePanePosition = 0
  workspace.tabs.push(second)
  return workspace
}

export default function unexpectedExitRecoveryTest() {
  describe('UnexpectedExitRecovery', () => {
    it('roundTripsOnlyBoundedWorkspaceStructure', 0, () => {
      let record: UnexpectedExitRecoveryRecord = UnexpectedExitRecoveryCodec.create(
        7, RecoveryRunState.RUNNING, sampleWorkspace())
      let encoded: string = UnexpectedExitRecoveryCodec.encode(record)
      let decoded: UnexpectedExitRecoveryRecord | null = UnexpectedExitRecoveryCodec.decode(encoded)

      expect(decoded?.generation).assertEqual(7)
      expect(decoded?.runState).assertEqual(RecoveryRunState.RUNNING)
      expect(decoded?.workspace.tabs.length).assertEqual(2)
      expect(decoded?.workspace.tabs[0].paneCount).assertEqual(2)
      expect(encoded.includes('host')).assertEqual(false)
      expect(encoded.includes('title')).assertEqual(false)
      expect(encoded.includes('terminal')).assertEqual(false)
      expect(encoded.includes('session')).assertEqual(false)
      expect(encoded.includes('secret')).assertEqual(false)
    })

    it('rejectsMalformedFutureAndOutOfRangeRecords', 0, () => {
      expect(UnexpectedExitRecoveryCodec.decode('{broken') === null).assertEqual(true)
      expect(UnexpectedExitRecoveryCodec.decode(
        '{"schemaVersion":99,"generation":1,"runState":"running","workspace":{}}') === null)
        .assertEqual(true)
      let invalid: RecoveryWorkspaceSnapshot = sampleWorkspace()
      invalid.tabs[0].paneCount = 3
      expect(UnexpectedExitRecoveryCodec.isValidWorkspace(invalid)).assertEqual(false)
      invalid = sampleWorkspace()
      invalid.splitRatio = 0.95
      expect(UnexpectedExitRecoveryCodec.isValidWorkspace(invalid)).assertEqual(false)
    })

    it('restoresFreshIdleRuntimeIdentitiesWithoutRemoteState', 0, () => {
      let workspace: AppViewModel = new AppViewModel()
      workspace.setIdentityGeneration(12)
      expect(workspace.restoreRecoverySnapshot(sampleWorkspace())).assertEqual(true)

      let tabs: TabInfo[] = workspace.getTabs()
      expect(tabs.length).assertEqual(2)
      expect(tabs[0].id).assertEqual('tab-12-1')
      expect(tabs[0].panes[0].id).assertEqual('pane-12-1')
      expect(tabs[0].panes[1].id).assertEqual('pane-12-2')
      expect(workspace.getActiveTabIndex()).assertEqual(1)
      for (let tabIndex: number = 0; tabIndex < tabs.length; tabIndex++) {
        for (let paneIndex: number = 0; paneIndex < tabs[tabIndex].panes.length; paneIndex++) {
          let pane: PaneInfo = tabs[tabIndex].panes[paneIndex]
          expect(pane.title).assertEqual('ltty')
          expect(pane.state).assertEqual(SshSessionState.IDLE)
          expect(pane.mode).assertEqual(TerminalMode.IDLE)
          expect(pane.needsAttention).assertEqual(false)
        }
      }
    })

    it('projectsLiveWorkspaceWithoutTitlesOrSessionState', 0, () => {
      let workspace: AppViewModel = new AppViewModel()
      let tab: TabInfo = workspace.addTab('remote-sensitive-title')
      workspace.splitPane(tab.id)
      workspace.updatePaneTitle(tab.panes[0].id, 'remote.example')
      workspace.updatePaneState(tab.panes[0].id, SshSessionState.CONNECTED)
      workspace.updatePaneMode(tab.panes[0].id, TerminalMode.CONNECTED)
      workspace.markPaneAttention(tab.panes[0].id)

      let encoded: string = UnexpectedExitRecoveryCodec.encode(
        UnexpectedExitRecoveryCodec.create(
          2, RecoveryRunState.RUNNING, workspace.createRecoverySnapshot(0.4)))
      expect(encoded.includes('remote')).assertEqual(false)
      expect(encoded.includes('CONNECTED')).assertEqual(false)
      expect(encoded.includes('attention')).assertEqual(false)
      expect(encoded.includes('pane-')).assertEqual(false)
      expect(encoded.includes('tab-')).assertEqual(false)
    })

  })
}

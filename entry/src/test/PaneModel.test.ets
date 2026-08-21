import { describe, it, expect } from '@ohos/hypium'
import { PaneInfo, TabInfo, TerminalMode } from '../main/ets/common/types/TerminalTypes'
import { SshSession } from '../main/ets/model/ssh/SshSession'
import { AppViewModel } from '../main/ets/viewmodel/AppViewModel'

export default function paneModelTest() {
  describe('PaneModel', () => {
    it('splitAddsPaneWithoutAddingTab', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let tab: TabInfo = vm.addTab('one')
      let pane: PaneInfo | null = vm.splitPane(tab.id)
      expect(pane !== null).assertEqual(true)
      expect(vm.getTabs().length).assertEqual(1)
      expect(tab.panes.length).assertEqual(2)
    })

    it('splitDoesNotReuseTheNextTabPane', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let first: TabInfo = vm.addTab('one')
      let second: TabInfo = vm.addTab('two')
      let secondPaneId: string = second.panes[0].id
      let splitPane: PaneInfo | null = vm.splitPane(first.id)
      expect(splitPane !== null).assertEqual(true)
      if (splitPane !== null) {
        expect(splitPane.id !== secondPaneId).assertEqual(true)
      }
      expect(vm.getTabs().length).assertEqual(2)
      expect(second.panes.length).assertEqual(1)
    })

    it('eachTabOwnsItsSplitState', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let first: TabInfo = vm.addTab('one')
      let second: TabInfo = vm.addTab('two')
      vm.splitPane(first.id)
      expect(first.panes.length).assertEqual(2)
      expect(second.panes.length).assertEqual(1)
    })

    it('closingFocusedPanePromotesItsSibling', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let tab: TabInfo = vm.addTab('one')
      let firstPaneId: string = tab.panes[0].id
      let secondPane: PaneInfo | null = vm.splitPane(tab.id)
      if (secondPane !== null) {
        vm.removePane(tab.id, secondPane.id)
      }
      expect(tab.panes.length).assertEqual(1)
      expect(tab.activePaneId).assertEqual(firstPaneId)
    })

    it('closingLeftPanePromotesRightPaneInsideSameTab', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let tab: TabInfo = vm.addTab('one')
      let leftPaneId: string = tab.panes[0].id
      let rightPane: PaneInfo | null = vm.splitPane(tab.id)
      if (rightPane !== null) {
        vm.setActivePane(tab.id, leftPaneId)
        vm.removePane(tab.id, leftPaneId)
        expect(tab.activePaneId).assertEqual(rightPane.id)
      }
      expect(vm.getTabs().length).assertEqual(1)
      expect(tab.panes.length).assertEqual(1)
    })

    it('removesOnlyTheIdlePaneWhileItsSiblingIsConnected', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let tab: TabInfo = vm.addTab('one')
      let leftPane: PaneInfo = tab.panes[0]
      let rightPane: PaneInfo | null = vm.splitPane(tab.id)
      leftPane.mode = TerminalMode.IDLE
      if (rightPane !== null) {
        rightPane.mode = TerminalMode.CONNECTED
      }

      let removed: PaneInfo | null = vm.removePane(tab.id, leftPane.id)
      expect(removed !== null).assertEqual(true)
      expect(vm.getTabs().length).assertEqual(1)
      expect(tab.panes.length).assertEqual(1)
      if (rightPane !== null) {
        expect(tab.panes[0].id).assertEqual(rightPane.id)
        expect(tab.panes[0].mode).assertEqual(TerminalMode.CONNECTED)
      }
    })

    it('doesNotCreateThirdPaneOnRepeatedSplit', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let tab: TabInfo = vm.addTab('one')
      vm.splitPane(tab.id)
      let thirdPane: PaneInfo | null = vm.splitPane(tab.id)
      expect(thirdPane === null).assertEqual(true)
      expect(tab.panes.length).assertEqual(2)
    })

    it('cannotRemoveTheOnlyPaneWithoutClosingItsTab', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let tab: TabInfo = vm.addTab('one')
      let removed: PaneInfo | null = vm.removePane(tab.id, tab.panes[0].id)
      expect(removed === null).assertEqual(true)
      expect(vm.getTabs().length).assertEqual(1)
      expect(tab.panes.length).assertEqual(1)
    })

    it('paneFocusAndTitleStayInsideOwningTab', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let first: TabInfo = vm.addTab('one')
      let second: TabInfo = vm.addTab('two')
      let rightPane: PaneInfo | null = vm.splitPane(first.id)
      if (rightPane !== null) {
        vm.updatePaneTitle(rightPane.id, 'right-host')
        vm.setActivePane(first.id, rightPane.id)
        expect(first.title).assertEqual('right-host')
      }
      expect(second.title).assertEqual('two')
    })

    it('publishesStableObservableTabUpdatesForChrome', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let tab: TabInfo = vm.addTab('ltty')
      let beforePanes: PaneInfo[] = tab.panes

      vm.updatePaneTitle(tab.panes[0].id, 'user@host')

      expect(vm.getTabs()[0] === tab).assertEqual(true)
      expect(tab.panes === beforePanes).assertEqual(false)
      expect(tab.title).assertEqual('user@host')
      expect(tab.panes[0].title).assertEqual('user@host')
    })

    it('usesTheChosenSshHostLabelForTheStableConnectionTitle', 0, () => {
      let session: SshSession = new SshSession()
      session.setHostname('172.16.100.2')
      session.setUsername('user')
      session.setDisplayHost('hsl')
      expect(session.getConnectionTitle()).assertEqual('user@hsl')

      session.setDisplayHost('')
      expect(session.getConnectionTitle()).assertEqual('user@172.16.100.2')
    })

    it('retainsTheResolvedConnectTimeoutForReconnect', 0, () => {
      let session: SshSession = new SshSession()
      expect(session.getConnectTimeoutMs()).assertEqual(15000)
      session.setConnectTimeoutMs(9000)
      expect(session.getConnectTimeoutMs()).assertEqual(9000)
    })

    it('retainsBothResolvedServerAliveLayersForReconnect', 0, () => {
      let session: SshSession = new SshSession()
      expect(session.getServerAliveIntervalSeconds()).assertEqual(30)
      expect(session.getServerAliveCountMax()).assertEqual(3)
      session.setServerAliveIntervalSeconds(0)
      session.setServerAliveCountMax(7)
      session.setJumpServerAliveIntervalSeconds(15)
      session.setJumpServerAliveCountMax(4)
      expect(session.getServerAliveIntervalSeconds()).assertEqual(0)
      expect(session.getServerAliveCountMax()).assertEqual(7)
      expect(session.getJumpServerAliveIntervalSeconds()).assertEqual(15)
      expect(session.getJumpServerAliveCountMax()).assertEqual(4)
    })

    it('activePaneSelectionNeverCrossesTheActiveTab', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let first: TabInfo = vm.addTab('one')
      let firstRight: PaneInfo | null = vm.splitPane(first.id)
      let second: TabInfo = vm.addTab('two')

      expect(vm.getActivePane()?.id).assertEqual(second.activePaneId)
      vm.setActiveTab(0)
      if (firstRight !== null) {
        expect(vm.getActivePane()?.id).assertEqual(firstRight.id)
      }
      vm.setActiveTab(1)
      expect(vm.getActivePane()?.id).assertEqual(second.activePaneId)
    })

    it('bellAttentionClearsOnlyForAnExplicitlyAcknowledgedPane', 0, () => {
      let vm: AppViewModel = new AppViewModel()
      let tab: TabInfo = vm.addTab('one')
      let leftPane: PaneInfo = tab.panes[0]
      let rightPane: PaneInfo | null = vm.splitPane(tab.id)
      expect(leftPane.needsAttention).assertEqual(false)
      if (rightPane !== null) {
        vm.markPaneAttention(leftPane.id)
        vm.markPaneAttention(rightPane.id)
        expect(leftPane.needsAttention).assertEqual(true)
        expect(rightPane.needsAttention).assertEqual(true)
        vm.setActivePane(tab.id, rightPane.id)
        expect(leftPane.needsAttention).assertEqual(true)
        expect(rightPane.needsAttention).assertEqual(true)
        vm.clearPaneAttention(rightPane.id)
        expect(leftPane.needsAttention).assertEqual(true)
        expect(rightPane.needsAttention).assertEqual(false)
      }
    })
  })
}

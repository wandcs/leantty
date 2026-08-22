import { describe, it, expect } from '@ohos/hypium'
import { PaneInfo, TabInfo } from '../main/ets/common/types/TerminalTypes'
import { AppViewModel } from '../main/ets/viewmodel/AppViewModel'
import { PaneRuntime } from '../main/ets/viewmodel/PaneRuntime'
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'

function createWorkspace(): AppViewModel {
  let workspace: AppViewModel = new AppViewModel()
  workspace.setPaneRuntimeFactory((pane: PaneInfo): PaneRuntime => {
    return new PaneRuntime(pane.id, new SessionViewModel())
  })
  return workspace
}

export default function workspaceOwnershipTest() {
  describe('WorkspaceOwnership', () => {
    it('createsEachPaneAndRuntimeUnderOneOwner', 0, () => {
      let workspace: AppViewModel = createWorkspace()
      let tab: TabInfo = workspace.addTab('one')
      let rightPane: PaneInfo | null = workspace.splitPane(tab.id)

      expect(workspace.getTabs().length).assertEqual(1)
      expect(workspace.getPaneRuntimes().length).assertEqual(2)
      expect(workspace.getPaneRuntime(tab.panes[0].id) !== null).assertEqual(true)
      if (rightPane !== null) {
        expect(workspace.getPaneRuntime(rightPane.id) !== null).assertEqual(true)
        expect(workspace.getActivePaneRuntime()?.id).assertEqual(rightPane.id)
      }
    })

    it('removingAPaneUnlinksAndDisposesItsRuntimeTogether', 0, () => {
      let workspace: AppViewModel = createWorkspace()
      let tab: TabInfo = workspace.addTab('one')
      let rightPane: PaneInfo | null = workspace.splitPane(tab.id)
      if (rightPane === null) {
        expect(false).assertTrue()
        return
      }
      let removedRuntime: PaneRuntime | null = workspace.getPaneRuntime(rightPane.id)

      let removedPane: PaneInfo | null = workspace.removePane(tab.id, rightPane.id)

      expect(removedPane?.id).assertEqual(rightPane.id)
      expect(workspace.getPane(rightPane.id) === null).assertEqual(true)
      expect(workspace.getPaneRuntime(rightPane.id) === null).assertEqual(true)
      expect(removedRuntime?.isDisposed()).assertEqual(true)
      expect(workspace.getActivePane()?.id).assertEqual(tab.panes[0].id)
    })

    it('removingATabDisposesOnlyItsPaneRuntimesAndKeepsActiveStateValid', 0, () => {
      let workspace: AppViewModel = createWorkspace()
      let first: TabInfo = workspace.addTab('first')
      let firstRuntime: PaneRuntime | null = workspace.getPaneRuntime(first.panes[0].id)
      let second: TabInfo = workspace.addTab('second')
      let secondRuntime: PaneRuntime | null = workspace.getPaneRuntime(second.panes[0].id)

      workspace.removeTab(0)

      expect(firstRuntime?.isDisposed()).assertEqual(true)
      expect(secondRuntime?.isDisposed()).assertEqual(false)
      expect(workspace.getTabs().length).assertEqual(1)
      expect(workspace.getActiveTab()?.id).assertEqual(second.id)
      expect(workspace.getPaneRuntime(second.panes[0].id) !== null).assertEqual(true)
    })

    it('switchingTabsKeepsEachPaneBoundToItsOriginalRuntime', 0, () => {
      let workspace: AppViewModel = createWorkspace()
      let first: TabInfo = workspace.addTab('first')
      let firstRuntime: PaneRuntime | null = workspace.getActivePaneRuntime()
      let second: TabInfo = workspace.addTab('second')
      let secondRuntime: PaneRuntime | null = workspace.getActivePaneRuntime()

      workspace.setActiveTab(0)
      expect(workspace.getActiveTab()?.id).assertEqual(first.id)
      expect(workspace.getActivePaneRuntime() === firstRuntime).assertEqual(true)
      workspace.setActiveTab(1)
      expect(workspace.getActiveTab()?.id).assertEqual(second.id)
      expect(workspace.getActivePaneRuntime() === secondRuntime).assertEqual(true)
      expect(firstRuntime === secondRuntime).assertEqual(false)
    })

    it('recyclingOnePaneAdvancesOnlyItsRendererGeneration', 0, () => {
      let workspace: AppViewModel = createWorkspace()
      let tab: TabInfo = workspace.addTab('one')
      let rightPane: PaneInfo | null = workspace.splitPane(tab.id)
      let leftRuntime: PaneRuntime | null = workspace.getPaneRuntime(tab.panes[0].id)
      let rightRuntime: PaneRuntime | null = rightPane === null ? null : workspace.getPaneRuntime(rightPane.id)

      leftRuntime?.recycleSurface()

      expect(leftRuntime?.generation).assertEqual(1)
      expect(rightRuntime?.generation).assertEqual(0)
    })

    it('applicationCloseDisconnectKeepsOwnershipUntilPageDisposal', 0, async () => {
      let workspace: AppViewModel = createWorkspace()
      let tab: TabInfo = workspace.addTab('one')
      let runtime: PaneRuntime | null = workspace.getPaneRuntime(tab.panes[0].id)

      await workspace.disconnectAllPaneRuntimes()

      expect(workspace.getPane(tab.panes[0].id) !== null).assertEqual(true)
      expect(workspace.getPaneRuntime(tab.panes[0].id) === runtime).assertEqual(true)
      expect(runtime?.isDisposed()).assertEqual(false)
    })

    it('disposingWorkspaceClearsModelAndRuntimeBeforePageRebuild', 0, async () => {
      let workspace: AppViewModel = createWorkspace()
      let tab: TabInfo = workspace.addTab('one')
      workspace.splitPane(tab.id)
      let runtimes: PaneRuntime[] = workspace.getPaneRuntimes()

      await workspace.disposeWorkspace()

      expect(workspace.getTabs().length).assertEqual(0)
      expect(workspace.getPaneRuntimes().length).assertEqual(0)
      expect(workspace.getActiveTabIndex()).assertEqual(-1)
      expect(runtimes[0].isDisposed()).assertEqual(true)
      expect(runtimes[1].isDisposed()).assertEqual(true)

      let rebuilt: TabInfo = workspace.addTab('rebuilt')
      expect(rebuilt.id).assertEqual('tab-1')
      expect(rebuilt.panes[0].id).assertEqual('pane-1')
      expect(workspace.getPaneRuntimes().length).assertEqual(1)
    })
  })
}

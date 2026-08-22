import { describe, it, expect } from '@ohos/hypium'
import { InteractionPolicy, WorkspaceNavigationAction } from '../main/ets/model/ui/InteractionPolicy'
import { ApplicationCloseCoordinator } from '../main/ets/model/ui/ApplicationCloseCoordinator'

export default function workspaceInteractionTest() {
  describe('WorkspaceInteraction', () => {
    it('routesExactCtrlCBeforeArkWebConsumesSelectionCopy', 0, () => {
      expect(InteractionPolicy.isTerminalCopyOrInterruptKey(2019, true, false)).assertEqual(true)
      expect(InteractionPolicy.isTerminalCopyOrInterruptKey(2019, true, true)).assertEqual(false)
      expect(InteractionPolicy.isTerminalCopyOrInterruptKey(2019, false, false)).assertEqual(false)
      expect(InteractionPolicy.isTerminalCopyOrInterruptKey(2018, true, false)).assertEqual(false)
    })

    it('matchesOnlyExactCtrlTabWorkspaceNavigation', 0, () => {
      expect(InteractionPolicy.workspaceNavigationAction(2049, true, false, false))
        .assertEqual(WorkspaceNavigationAction.NEXT_TAB)
      expect(InteractionPolicy.workspaceNavigationAction(2049, true, false, true))
        .assertEqual(WorkspaceNavigationAction.PREVIOUS_TAB)
      expect(InteractionPolicy.workspaceNavigationAction(2049, false, false, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2049, false, false, true))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2049, true, true, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2015, true, false, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
    })

    it('matchesOnlyExactCtrlAltPaneNavigation', 0, () => {
      expect(InteractionPolicy.workspaceNavigationAction(2014, true, true, false))
        .assertEqual(WorkspaceNavigationAction.FOCUS_LEFT_PANE)
      expect(InteractionPolicy.workspaceNavigationAction(2015, true, true, false))
        .assertEqual(WorkspaceNavigationAction.FOCUS_RIGHT_PANE)
      expect(InteractionPolicy.workspaceNavigationAction(2014, false, true, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2015, true, false, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2014, true, true, true))
        .assertEqual(WorkspaceNavigationAction.NONE)
    })

    it('matchesOnlyExactCtrlAltFTerminalSearch', 0, () => {
      expect(InteractionPolicy.isTerminalSearchShortcut(2022, true, true, false)).assertEqual(true)
      expect(InteractionPolicy.isTerminalSearchShortcut(2022, true, true, true)).assertEqual(false)
      expect(InteractionPolicy.isTerminalSearchShortcut(2022, true, false, false)).assertEqual(false)
      expect(InteractionPolicy.isTerminalSearchShortcut(2022, false, true, false)).assertEqual(false)
      expect(InteractionPolicy.isTerminalSearchShortcut(2019, true, true, false)).assertEqual(false)
    })

    it('separatesTransparencyAndFontSizeAdjustmentShortcuts', 0, () => {
      expect(InteractionPolicy.transparencyShortcutDirection(2057, true, true)).assertEqual(-1)
      expect(InteractionPolicy.transparencyShortcutDirection(2058, true, true)).assertEqual(1)
      expect(InteractionPolicy.transparencyShortcutDirection(2057, true, false)).assertEqual(0)
      expect(InteractionPolicy.transparencyShortcutDirection(2058, false, true)).assertEqual(0)
      expect(InteractionPolicy.fontSizeShortcutDirection(2057, true, false)).assertEqual(-1)
      expect(InteractionPolicy.fontSizeShortcutDirection(2058, true, false)).assertEqual(1)
      expect(InteractionPolicy.fontSizeShortcutDirection(2057, true, true)).assertEqual(0)
      expect(InteractionPolicy.fontSizeShortcutDirection(2058, false, false)).assertEqual(0)
    })

    it('consumesPaneNavigationOnlyForTheFixedTwoPaneLayout', 0, () => {
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.FOCUS_LEFT_PANE, 1))
        .assertEqual(-1)
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.FOCUS_RIGHT_PANE, 1))
        .assertEqual(-1)
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.FOCUS_LEFT_PANE, 2))
        .assertEqual(0)
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.FOCUS_RIGHT_PANE, 2))
        .assertEqual(1)
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.NEXT_TAB, 2))
        .assertEqual(-1)
    })

    it('wrapsWorkspaceTabsInVisualOrder', 0, () => {
      expect(InteractionPolicy.wrappedTabIndex(0, 0, 1)).assertEqual(-1)
      expect(InteractionPolicy.wrappedTabIndex(0, 1, 1)).assertEqual(0)
      expect(InteractionPolicy.wrappedTabIndex(0, 3, 1)).assertEqual(1)
      expect(InteractionPolicy.wrappedTabIndex(2, 3, 1)).assertEqual(0)
      expect(InteractionPolicy.wrappedTabIndex(2, 3, -1)).assertEqual(1)
      expect(InteractionPolicy.wrappedTabIndex(0, 3, -1)).assertEqual(2)
      expect(InteractionPolicy.wrappedTabIndex(-1, 3, 1)).assertEqual(0)
      expect(InteractionPolicy.wrappedTabIndex(-1, 3, -1)).assertEqual(2)
    })

    it('confirmsApplicationCloseOnlyForUnsuppressedActiveSessions', 0, () => {
      expect(InteractionPolicy.shouldConfirmApplicationClose(false, false)).assertEqual(false)
      expect(InteractionPolicy.shouldConfirmApplicationClose(true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldConfirmApplicationClose(true, true)).assertEqual(false)
    })

    it('keepsApplicationClosePreparationSingleFlight', 0, () => {
      let calls: number = 0
      let handler = (): Promise<void> => {
        calls++
        return Promise.resolve()
      }
      ApplicationCloseCoordinator.register(handler)
      let first: Promise<void> = ApplicationCloseCoordinator.prepareTermination()
      let second: Promise<void> = ApplicationCloseCoordinator.prepareTermination()
      expect(calls).assertEqual(1)
      expect(first === second).assertEqual(true)
      ApplicationCloseCoordinator.resetPreparation()
      ApplicationCloseCoordinator.prepareTermination()
      expect(calls).assertEqual(2)
      ApplicationCloseCoordinator.unregister(handler)
    })

    it('keepsBellAttentionPendingOnlyOutsideTheVisibleFocusedPane', 0, () => {
      expect(InteractionPolicy.shouldPersistBellAttention(true, true, true, false)).assertEqual(false)
      expect(InteractionPolicy.shouldPersistBellAttention(false, true, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldPersistBellAttention(true, false, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldPersistBellAttention(true, true, false, false)).assertEqual(true)
      expect(InteractionPolicy.shouldPersistBellAttention(true, true, true, true)).assertEqual(true)
      expect(InteractionPolicy.bellPulseCount(false)).assertEqual(1)
      expect(InteractionPolicy.bellPulseCount(true)).assertEqual(2)
    })

    it('clampsLayoutAndKeepsOnlyOnePreviousTabSurfaceWarm', 0, () => {
      expect(InteractionPolicy.DEFAULT_FONT_SIZE).assertEqual(16)
      expect(InteractionPolicy.clampSplitRatio(0.05)).assertEqual(0.2)
      expect(InteractionPolicy.clampSplitRatio(0.55)).assertEqual(0.55)
      expect(InteractionPolicy.clampSplitRatio(0.95)).assertEqual(0.8)
      expect(InteractionPolicy.clampFontSize(2)).assertEqual(8)
      expect(InteractionPolicy.clampFontSize(60)).assertEqual(48)
      expect(InteractionPolicy.warmTabAfterSwitch('A')).assertEqual('A')
      expect(InteractionPolicy.evictedWarmTab('A', 'B', '')).assertEqual('')
      expect(InteractionPolicy.warmTabAfterSwitch('B')).assertEqual('B')
      expect(InteractionPolicy.evictedWarmTab('B', 'A', 'A')).assertEqual('')
      expect(InteractionPolicy.warmTabAfterSwitch('A')).assertEqual('A')
      expect(InteractionPolicy.evictedWarmTab('A', 'C', 'B')).assertEqual('B')
    })

    it('keepsConnectedTabsMountedOutsideTheWarmSet', 0, () => {
      expect(InteractionPolicy.shouldMountTab(false, false, true)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(true, false, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(false, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(false, false, false)).assertEqual(false)
      expect(InteractionPolicy.shouldMountTab(true, false, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(false, false, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(true, false, false, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(false, true, false, false)).assertEqual(false)
      expect(InteractionPolicy.shouldDetachTabOnEviction(true)).assertEqual(false)
      expect(InteractionPolicy.shouldDetachTabOnEviction(false)).assertEqual(true)
    })

  })
}

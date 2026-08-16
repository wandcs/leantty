export enum WorkspaceNavigationAction {
  NONE,
  NEXT_TAB,
  PREVIOUS_TAB,
  FOCUS_LEFT_PANE,
  FOCUS_RIGHT_PANE
}

export class InteractionPolicy {
  static readonly DEFAULT_FONT_SIZE: number = 16
  static readonly MIN_FONT_SIZE: number = 8
  static readonly MAX_FONT_SIZE: number = 48
  static readonly MIN_SPLIT_RATIO: number = 0.2
  static readonly MAX_SPLIT_RATIO: number = 0.8

  static clampFontSize(value: number): number {
    return Math.max(InteractionPolicy.MIN_FONT_SIZE,
      Math.min(InteractionPolicy.MAX_FONT_SIZE, value))
  }

  static clampSplitRatio(value: number): number {
    return Math.max(InteractionPolicy.MIN_SPLIT_RATIO,
      Math.min(InteractionPolicy.MAX_SPLIT_RATIO, value))
  }

  static isTerminalSearchShortcut(keyCode: number, ctrlKey: boolean,
    altKey: boolean, shiftKey: boolean): boolean {
    return keyCode === 2022 && ctrlKey && altKey && !shiftKey
  }

  static isTerminalTabKey(keyCode: number, ctrlKey: boolean,
    altKey: boolean, shiftKey: boolean): boolean {
    return keyCode === 2049 && !ctrlKey && !altKey
  }

  static isTerminalCopyOrInterruptKey(keyCode: number, ctrlKey: boolean, altKey: boolean): boolean {
    return keyCode === 2019 && ctrlKey && !altKey
  }

  static transparencyShortcutDirection(keyCode: number, ctrlKey: boolean,
    altKey: boolean): number {
    if (!ctrlKey || !altKey) {
      return 0
    }
    if (keyCode === 2057) {
      return -1
    }
    return keyCode === 2058 ? 1 : 0
  }

  static fontSizeShortcutDirection(keyCode: number, ctrlKey: boolean,
    altKey: boolean): number {
    if (!ctrlKey || altKey) {
      return 0
    }
    if (keyCode === 2057) {
      return -1
    }
    return keyCode === 2058 ? 1 : 0
  }

  static warmTabAfterSwitch(currentTabId: string): string {
    return currentTabId
  }

  static evictedWarmTab(currentTabId: string, targetTabId: string,
    previousWarmTabId: string): string {
    if (previousWarmTabId.length > 0 && previousWarmTabId !== targetTabId &&
      previousWarmTabId !== currentTabId) {
      return previousWarmTabId
    }
    return ''
  }

  static shouldMountTab(isActiveTab: boolean, isWarmTab: boolean,
    hasActiveSession: boolean, isWindowVisible: boolean = true): boolean {
    return hasActiveSession || isActiveTab || (isWindowVisible && isWarmTab)
  }

  static shouldDetachTabOnEviction(hasActiveSession: boolean): boolean {
    return !hasActiveSession
  }

  static shouldConfirmApplicationClose(hasActiveSession: boolean,
    confirmationSuppressed: boolean): boolean {
    return hasActiveSession && !confirmationSuppressed
  }

  static shouldPersistBellAttention(isActiveTab: boolean, isFocusedPane: boolean,
    isWindowVisible: boolean, isOverlayOpen: boolean): boolean {
    return !isActiveTab || !isFocusedPane || !isWindowVisible || isOverlayOpen
  }

  static bellPulseCount(persistAttention: boolean): number {
    return persistAttention ? 2 : 1
  }

  static workspaceNavigationAction(keyCode: number, ctrlKey: boolean,
    altKey: boolean, shiftKey: boolean): WorkspaceNavigationAction {
    if (!ctrlKey) {
      return WorkspaceNavigationAction.NONE
    }
    if (keyCode === 2049 && !altKey) {
      return shiftKey ? WorkspaceNavigationAction.PREVIOUS_TAB :
        WorkspaceNavigationAction.NEXT_TAB
    }
    if (altKey && !shiftKey && keyCode === 2014) {
      return WorkspaceNavigationAction.FOCUS_LEFT_PANE
    }
    if (altKey && !shiftKey && keyCode === 2015) {
      return WorkspaceNavigationAction.FOCUS_RIGHT_PANE
    }
    return WorkspaceNavigationAction.NONE
  }

  static wrappedTabIndex(currentIndex: number, tabCount: number,
    direction: number): number {
    if (tabCount <= 0) {
      return -1
    }
    if (currentIndex < 0 || currentIndex >= tabCount) {
      return direction < 0 ? tabCount - 1 : 0
    }
    return (currentIndex + (direction < 0 ? -1 : 1) + tabCount) % tabCount
  }

  static workspacePaneIndex(action: WorkspaceNavigationAction, paneCount: number): number {
    if (paneCount !== 2) {
      return -1
    }
    if (action === WorkspaceNavigationAction.FOCUS_LEFT_PANE) {
      return 0
    }
    if (action === WorkspaceNavigationAction.FOCUS_RIGHT_PANE) {
      return 1
    }
    return -1
  }
}

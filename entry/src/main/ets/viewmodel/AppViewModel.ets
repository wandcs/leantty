import { Logger } from '../common/logger/Logger'
import { PaneInfo, SshSessionState, TabInfo, TerminalMode } from '../common/types/TerminalTypes'

export { PaneInfo, TabInfo }

export class AppViewModel {
  private tabs: TabInfo[] = []
  private activeTabIndex: number = -1
  private nextTabId: number = 1
  private nextPaneId: number = 1
  private logger: Logger = new Logger('AppViewModel')

  getTabs(): TabInfo[] {
    return this.tabs
  }

  getActiveTabIndex(): number {
    return this.activeTabIndex
  }

  getActiveTab(): TabInfo | null {
    if (this.activeTabIndex >= 0 && this.activeTabIndex < this.tabs.length) {
      return this.tabs[this.activeTabIndex]
    }
    return null
  }

  addTab(title: string): TabInfo {
    let id: string = 'tab-' + this.nextTabId.toString()
    this.nextTabId++
    let tab: TabInfo = new TabInfo(id, title)
    let pane: PaneInfo = this.createPane(title)
    tab.panes.push(pane)
    tab.activePaneId = pane.id
    this.tabs.push(tab)
    this.setActiveTab(this.tabs.length - 1)
    this.logger.info('Tab added: ' + id + ' title=' + title)
    return tab
  }

  splitPane(tabId: string): PaneInfo | null {
    let tabIndex: number = this.findTabIndex(tabId)
    if (tabIndex < 0 || this.tabs[tabIndex].panes.length >= 2) {
      return null
    }
    let pane: PaneInfo = this.createPane('ltty')
    this.tabs[tabIndex].panes = this.tabs[tabIndex].panes.concat([pane])
    this.tabs[tabIndex].activePaneId = pane.id
    this.tabs = this.tabs.slice()
    return pane
  }

  removePane(tabId: string, paneId: string): PaneInfo | null {
    let tabIndex: number = this.findTabIndex(tabId)
    if (tabIndex < 0) {
      return null
    }
    let tab: TabInfo = this.tabs[tabIndex]
    if (tab.panes.length <= 1) {
      return null
    }
    let paneIndex: number = this.findPaneIndex(tab, paneId)
    if (paneIndex < 0) {
      return null
    }
    let removed: PaneInfo = tab.panes[paneIndex]
    let panes: PaneInfo[] = tab.panes.slice()
    panes.splice(paneIndex, 1)
    tab.panes = panes
    if (tab.activePaneId === paneId) {
      tab.activePaneId = panes[Math.min(paneIndex, panes.length - 1)].id
    }
    let activePane: PaneInfo | null = this.getPane(tab.activePaneId)
    if (activePane !== null) {
      tab.title = activePane.title
    }
    this.tabs = this.tabs.slice()
    return removed
  }

  setActivePane(tabId: string, paneId: string): void {
    let tabIndex: number = this.findTabIndex(tabId)
    if (tabIndex < 0) {
      return
    }
    let pane: PaneInfo | null = this.getPane(paneId)
    if (pane === null || this.findPaneIndex(this.tabs[tabIndex], paneId) < 0) {
      return
    }
    this.tabs[tabIndex].activePaneId = paneId
    this.tabs[tabIndex].title = pane.title
    this.tabs = this.tabs.slice()
  }

  getActivePane(): PaneInfo | null {
    let tab: TabInfo | null = this.getActiveTab()
    if (tab === null) {
      return null
    }
    return this.getPane(tab.activePaneId)
  }

  getPane(paneId: string): PaneInfo | null {
    for (let i = 0; i < this.tabs.length; i++) {
      for (let j = 0; j < this.tabs[i].panes.length; j++) {
        if (this.tabs[i].panes[j].id === paneId) {
          return this.tabs[i].panes[j]
        }
      }
    }
    return null
  }

  updatePaneState(paneId: string, state: SshSessionState): void {
    let pane: PaneInfo | null = this.getPane(paneId)
    if (pane !== null) {
      pane.state = state
      this.publishPaneOwner(paneId)
    }
  }

  updatePaneMode(paneId: string, mode: TerminalMode): void {
    let pane: PaneInfo | null = this.getPane(paneId)
    if (pane !== null) {
      pane.mode = mode
      this.publishPaneOwner(paneId)
    }
  }

  updatePaneTitle(paneId: string, title: string): void {
    let pane: PaneInfo | null = this.getPane(paneId)
    if (pane === null) {
      return
    }
    pane.title = title
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].activePaneId === paneId) {
        this.tabs[i].title = title
      }
    }
    this.publishPaneOwner(paneId)
  }

  markPaneAttention(paneId: string): void {
    let pane: PaneInfo | null = this.getPane(paneId)
    if (pane === null || pane.needsAttention) {
      return
    }
    pane.needsAttention = true
    this.publishPaneOwner(paneId)
    this.logger.info('Pane attention set: ' + paneId)
  }

  clearPaneAttention(paneId: string): void {
    let pane: PaneInfo | null = this.getPane(paneId)
    if (pane === null || !pane.needsAttention) {
      return
    }
    pane.needsAttention = false
    this.publishPaneOwner(paneId)
    this.logger.info('Pane attention cleared: ' + paneId)
  }

  removeTab(index: number): void {
    if (index < 0 || index >= this.tabs.length) {
      return
    }
    let removedId: string = this.tabs[index].id
    let previousActiveIndex: number = this.activeTabIndex
    this.tabs.splice(index, 1)
    this.tabs = this.tabs.slice()
    if (this.tabs.length === 0) {
      this.activeTabIndex = -1
    } else if (index < previousActiveIndex) {
      this.setActiveTab(previousActiveIndex - 1)
    } else if (index === previousActiveIndex) {
      this.setActiveTab(Math.min(index, this.tabs.length - 1))
    } else {
      this.setActiveTab(previousActiveIndex)
    }
    this.logger.info('Tab removed: ' + removedId)
  }

  setActiveTab(index: number): void {
    if (index < 0 || index >= this.tabs.length) {
      return
    }
    for (let i = 0; i < this.tabs.length; i++) {
      this.tabs[i].isFocused = (i === index)
    }
    this.activeTabIndex = index
    this.tabs = this.tabs.slice()
    this.logger.info('Active tab: ' + this.tabs[index].id)
  }

  updateTabTitle(index: number, title: string): void {
    if (index >= 0 && index < this.tabs.length) {
      this.tabs[index].title = title
      this.tabs = this.tabs.slice()
    }
  }

  private createPane(title: string): PaneInfo {
    let id: string = 'pane-' + this.nextPaneId.toString()
    this.nextPaneId++
    return new PaneInfo(id, title)
  }

  private publishPaneOwner(paneId: string): void {
    for (let tabIndex: number = 0; tabIndex < this.tabs.length; tabIndex++) {
      if (this.findPaneIndex(this.tabs[tabIndex], paneId) >= 0) {
        this.tabs[tabIndex].panes = this.tabs[tabIndex].panes.slice()
        this.tabs = this.tabs.slice()
        return
      }
    }
  }

  private findTabIndex(tabId: string): number {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === tabId) {
        return i
      }
    }
    return -1
  }

  private findPaneIndex(tab: TabInfo, paneId: string): number {
    for (let i = 0; i < tab.panes.length; i++) {
      if (tab.panes[i].id === paneId) {
        return i
      }
    }
    return -1
  }

}

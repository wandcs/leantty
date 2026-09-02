import { InteractionPolicy } from '../ui/InteractionPolicy'

const SCHEMA_VERSION: number = 1
const MAX_TABS: number = 32
const MAX_RECORD_LENGTH: number = 16384

export enum RecoveryRunState {
  RUNNING = 'running',
  CLEAN = 'clean'
}

export class RecoveryTabSnapshot {
  paneCount: number = 1
  activePanePosition: number = 0
}

export class RecoveryWorkspaceSnapshot {
  activeTabPosition: number = 0
  splitRatio: number = 0.5
  tabs: RecoveryTabSnapshot[] = []
}

export class UnexpectedExitRecoveryRecord {
  schemaVersion: number = SCHEMA_VERSION
  generation: number = 1
  runState: string = RecoveryRunState.RUNNING
  workspace: RecoveryWorkspaceSnapshot = new RecoveryWorkspaceSnapshot()
}

export class UnexpectedExitRecoveryCodec {
  static create(generation: number, runState: RecoveryRunState,
    workspace: RecoveryWorkspaceSnapshot): UnexpectedExitRecoveryRecord {
    let record: UnexpectedExitRecoveryRecord = new UnexpectedExitRecoveryRecord()
    record.generation = generation
    record.runState = runState
    record.workspace = UnexpectedExitRecoveryCodec.copyWorkspace(workspace)
    if (!UnexpectedExitRecoveryCodec.isValid(record)) {
      throw new Error('Invalid unexpected-exit recovery record')
    }
    return record
  }

  static encode(record: UnexpectedExitRecoveryRecord): string {
    if (!UnexpectedExitRecoveryCodec.isValid(record)) {
      throw new Error('Invalid unexpected-exit recovery record')
    }
    let encoded: string = JSON.stringify(record)
    if (encoded.length > MAX_RECORD_LENGTH) {
      throw new Error('Unexpected-exit recovery record is too large')
    }
    return encoded
  }

  static decode(encoded: string): UnexpectedExitRecoveryRecord | null {
    if (encoded.length === 0 || encoded.length > MAX_RECORD_LENGTH) {
      return null
    }
    try {
      let record: UnexpectedExitRecoveryRecord = JSON.parse(encoded)
      return UnexpectedExitRecoveryCodec.isValid(record) ?
        UnexpectedExitRecoveryCodec.copyRecord(record) : null
    } catch (e) {
      return null
    }
  }

  static isValidWorkspace(workspace: RecoveryWorkspaceSnapshot): boolean {
    if (workspace === null || !Number.isInteger(workspace.activeTabPosition) ||
      !Number.isFinite(workspace.splitRatio) ||
      workspace.splitRatio < InteractionPolicy.MIN_SPLIT_RATIO ||
      workspace.splitRatio > InteractionPolicy.MAX_SPLIT_RATIO ||
      !Array.isArray(workspace.tabs) || workspace.tabs.length < 1 ||
      workspace.tabs.length > MAX_TABS || workspace.activeTabPosition < 0 ||
      workspace.activeTabPosition >= workspace.tabs.length) {
      return false
    }
    for (let i: number = 0; i < workspace.tabs.length; i++) {
      let tab: RecoveryTabSnapshot = workspace.tabs[i]
      if (tab === null || !Number.isInteger(tab.paneCount) ||
        (tab.paneCount !== 1 && tab.paneCount !== 2) ||
        !Number.isInteger(tab.activePanePosition) || tab.activePanePosition < 0 ||
        tab.activePanePosition >= tab.paneCount) {
        return false
      }
    }
    return true
  }

  static copyWorkspace(workspace: RecoveryWorkspaceSnapshot): RecoveryWorkspaceSnapshot {
    let copied: RecoveryWorkspaceSnapshot = new RecoveryWorkspaceSnapshot()
    copied.activeTabPosition = workspace.activeTabPosition
    copied.splitRatio = workspace.splitRatio
    for (let i: number = 0; i < workspace.tabs.length; i++) {
      let tab: RecoveryTabSnapshot = new RecoveryTabSnapshot()
      tab.paneCount = workspace.tabs[i].paneCount
      tab.activePanePosition = workspace.tabs[i].activePanePosition
      copied.tabs.push(tab)
    }
    return copied
  }

  private static isValid(record: UnexpectedExitRecoveryRecord): boolean {
    return record !== null && record.schemaVersion === SCHEMA_VERSION &&
      Number.isInteger(record.generation) && record.generation > 0 &&
      (record.runState === RecoveryRunState.RUNNING || record.runState === RecoveryRunState.CLEAN) &&
      UnexpectedExitRecoveryCodec.isValidWorkspace(record.workspace)
  }

  private static copyRecord(record: UnexpectedExitRecoveryRecord): UnexpectedExitRecoveryRecord {
    return UnexpectedExitRecoveryCodec.create(
      record.generation,
      record.runState === RecoveryRunState.CLEAN ? RecoveryRunState.CLEAN : RecoveryRunState.RUNNING,
      record.workspace)
  }
}

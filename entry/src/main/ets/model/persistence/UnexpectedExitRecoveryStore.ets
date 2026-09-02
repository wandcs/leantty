import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { Logger } from '../../common/logger/Logger'
import {
  RecoveryRunState,
  RecoveryTabSnapshot,
  RecoveryWorkspaceSnapshot,
  UnexpectedExitRecoveryCodec,
  UnexpectedExitRecoveryRecord
} from './UnexpectedExitRecoveryRecord'

const logger: Logger = new Logger('UnexpectedExitRecoveryStore')
const PREFERENCES_NAME: string = 'leantty_unexpected_exit_recovery'
const RECORD_KEY: string = 'record'

export class UnexpectedExitRecoveryStore {
  private static store: preferences.Preferences | null = null
  private static current: UnexpectedExitRecoveryRecord | null = null
  private static pendingRecovery: RecoveryWorkspaceSnapshot | null = null

  static initialize(context: common.UIAbilityContext): void {
    UnexpectedExitRecoveryStore.store = preferences.getPreferencesSync(
      context, { name: PREFERENCES_NAME })
    let previous: UnexpectedExitRecoveryRecord | null = UnexpectedExitRecoveryStore.readRecord()
    UnexpectedExitRecoveryStore.pendingRecovery = previous !== null &&
      previous.runState === RecoveryRunState.RUNNING ?
      UnexpectedExitRecoveryCodec.copyWorkspace(previous.workspace) : null
    let generation: number = previous === null ? 1 : previous.generation + 1
    let initialWorkspace: RecoveryWorkspaceSnapshot = UnexpectedExitRecoveryStore.pendingRecovery ??
      UnexpectedExitRecoveryStore.defaultWorkspace()
    UnexpectedExitRecoveryStore.current = UnexpectedExitRecoveryCodec.create(
      generation, RecoveryRunState.RUNNING, initialWorkspace)
    UnexpectedExitRecoveryStore.writeCurrent()
    logger.info('Recovery run started: generation=' + generation.toString() +
      ', unexpected=' + (UnexpectedExitRecoveryStore.pendingRecovery !== null).toString())
  }

  static currentGeneration(): number {
    return UnexpectedExitRecoveryStore.current === null ? 0 :
      UnexpectedExitRecoveryStore.current.generation
  }

  static consumeUnexpectedWorkspace(): RecoveryWorkspaceSnapshot | null {
    let workspace: RecoveryWorkspaceSnapshot | null = UnexpectedExitRecoveryStore.pendingRecovery
    UnexpectedExitRecoveryStore.pendingRecovery = null
    return workspace === null ? null : UnexpectedExitRecoveryCodec.copyWorkspace(workspace)
  }

  static checkpoint(workspace: RecoveryWorkspaceSnapshot): void {
    if (UnexpectedExitRecoveryStore.current === null ||
      !UnexpectedExitRecoveryCodec.isValidWorkspace(workspace)) {
      return
    }
    UnexpectedExitRecoveryStore.current.workspace = UnexpectedExitRecoveryCodec.copyWorkspace(workspace)
    try {
      UnexpectedExitRecoveryStore.writeCurrent()
    } catch (e) {
      logger.warn('Failed to checkpoint unexpected-exit workspace: ' + e)
    }
  }

  static flush(): void {
    if (UnexpectedExitRecoveryStore.store !== null) {
      UnexpectedExitRecoveryStore.store.flushSync()
    }
  }

  static markClean(workspace: RecoveryWorkspaceSnapshot): void {
    if (UnexpectedExitRecoveryStore.current === null || UnexpectedExitRecoveryStore.store === null) {
      logger.warn('Recovery store was unavailable while marking the run clean')
      return
    }
    if (!UnexpectedExitRecoveryCodec.isValidWorkspace(workspace)) {
      throw new Error('Cannot mark recovery run clean without a valid workspace')
    }
    UnexpectedExitRecoveryStore.current.workspace = UnexpectedExitRecoveryCodec.copyWorkspace(workspace)
    UnexpectedExitRecoveryStore.current.runState = RecoveryRunState.CLEAN
    UnexpectedExitRecoveryStore.writeCurrent()
    logger.info('Recovery run marked clean: generation=' +
      UnexpectedExitRecoveryStore.current.generation.toString())
  }

  private static readRecord(): UnexpectedExitRecoveryRecord | null {
    if (UnexpectedExitRecoveryStore.store === null) {
      return null
    }
    try {
      let value: preferences.ValueType = UnexpectedExitRecoveryStore.store.getSync(RECORD_KEY, '')
      return typeof value === 'string' ? UnexpectedExitRecoveryCodec.decode(value) : null
    } catch (e) {
      logger.warn('Failed to read unexpected-exit recovery record: ' + e)
      return null
    }
  }

  private static writeCurrent(): void {
    if (UnexpectedExitRecoveryStore.store === null || UnexpectedExitRecoveryStore.current === null) {
      throw new Error('Unexpected-exit recovery store is unavailable')
    }
    UnexpectedExitRecoveryStore.store.putSync(
      RECORD_KEY, UnexpectedExitRecoveryCodec.encode(UnexpectedExitRecoveryStore.current))
    UnexpectedExitRecoveryStore.store.flushSync()
  }

  private static defaultWorkspace(): RecoveryWorkspaceSnapshot {
    let workspace: RecoveryWorkspaceSnapshot = new RecoveryWorkspaceSnapshot()
    let tab: RecoveryTabSnapshot = new RecoveryTabSnapshot()
    workspace.tabs.push(tab)
    return workspace
  }
}

import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit'
import { notificationManager } from '@kit.NotificationKit'
import { BusinessError } from '@ohos.base'
import { Logger } from '../../common/logger/Logger'
import { UserPreferences } from '../settings/UserPreferences'
import { InteractionPolicy } from './InteractionPolicy'
import { UiText } from './UiText'

const logger: Logger = new Logger('BackgroundBellNotification')
const NOTIFICATION_ID: number = 1500
const NOTIFICATION_LABEL: string = 'background-bell-attention'
const WANT_REQUEST_CODE: number = 1500
const WANT_SOURCE_KEY: string = 'leanttyBackgroundBellSource'
const WANT_SOURCE_VALUE: string = 'background-bell-v1'
const WANT_PANE_ID_KEY: string = 'leanttyBackgroundBellPaneId'
const NOTIFICATION_LIFETIME_MS: number = 24 * 60 * 60 * 1000

export class BackgroundBellNotification {
  private static targetPaneId: string = ''
  private static attemptedInBackgroundEpisode: boolean = false
  private static requestVersion: number = 0
  private static operationQueue: Promise<void> = Promise.resolve()

  static publish(context: common.Context, paneId: string): void {
    if (!InteractionPolicy.shouldAttemptBackgroundBellForEpisode(
      BackgroundBellNotification.attemptedInBackgroundEpisode)) {
      logger.info('Background BEL notification suppressed for current background episode: paneId=' + paneId)
      return
    }
    BackgroundBellNotification.attemptedInBackgroundEpisode = true
    BackgroundBellNotification.targetPaneId = paneId
    BackgroundBellNotification.requestVersion++
    let version: number = BackgroundBellNotification.requestVersion
    BackgroundBellNotification.enqueue(async (): Promise<void> => {
      if (!BackgroundBellNotification.isCurrent(version, paneId)) {
        return
      }
      let enabled: boolean = false
      try {
        enabled = await notificationManager.isNotificationEnabled()
      } catch (e) {
        BackgroundBellNotification.logPlatformFailure('enabled-check', e)
        return
      }
      if (!BackgroundBellNotification.isCurrent(version, paneId)) {
        return
      }
      if (!enabled) {
        UserPreferences.scheduleBackgroundBellPermissionRequest()
        logger.info('Background BEL notification deferred because notifications are disabled')
        return
      }
      try {
        let agent: WantAgent = await wantAgent.getWantAgent({
          wants: [{
            bundleName: 'com.leantty.app',
            abilityName: 'EntryAbility',
            parameters: {
              leanttyBackgroundBellSource: WANT_SOURCE_VALUE,
              leanttyBackgroundBellPaneId: paneId
            }
          }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: WANT_REQUEST_CODE,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        })
        if (!BackgroundBellNotification.isCurrent(version, paneId)) {
          return
        }
        await notificationManager.publish({
          id: NOTIFICATION_ID,
          label: NOTIFICATION_LABEL,
          notificationSlotType: notificationManager.SlotType.OTHER_TYPES,
          content: {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: {
              title: 'LeanTTY',
              text: UiText.get(context, 'notification_terminal_attention')
            }
          },
          wantAgent: agent,
          isOngoing: false,
          isUnremovable: false,
          tapDismissed: true,
          autoDeletedTime: new Date().getTime() + NOTIFICATION_LIFETIME_MS
        })
        logger.info('Background BEL notification published: paneId=' + paneId)
      } catch (e) {
        let error: BusinessError = e as BusinessError
        if (error.code === 1600004 || error.code === 1600014 || error.code === 1600020) {
          UserPreferences.scheduleBackgroundBellPermissionRequest()
        }
        BackgroundBellNotification.logPlatformFailure('publish', e)
      }
    })
  }

  static cancel(): void {
    BackgroundBellNotification.targetPaneId = ''
    BackgroundBellNotification.requestVersion++
    BackgroundBellNotification.enqueue(async (): Promise<void> => {
      await BackgroundBellNotification.cancelPlatformNotification()
    })
  }

  static resetForVisibleWindow(): void {
    BackgroundBellNotification.attemptedInBackgroundEpisode = false
    BackgroundBellNotification.cancel()
  }

  static cancelIfTarget(paneId: string): void {
    if (BackgroundBellNotification.targetPaneId !== paneId) {
      return
    }
    BackgroundBellNotification.cancel()
  }

  static async requestPermissionIfScheduled(context: common.UIAbilityContext): Promise<void> {
    if (!UserPreferences.consumeBackgroundBellPermissionRequest()) {
      return
    }
    try {
      await notificationManager.requestEnableNotification(context)
      logger.info('Background BEL notification permission request completed')
    } catch (e) {
      BackgroundBellNotification.logPlatformFailure('permission-request', e)
    }
  }

  static paneIdFromWant(want: Want): string {
    if (want.parameters === undefined) {
      return ''
    }
    let source: Object | undefined = want.parameters[WANT_SOURCE_KEY]
    let paneId: Object | undefined = want.parameters[WANT_PANE_ID_KEY]
    if (typeof source !== 'string' || source !== WANT_SOURCE_VALUE || typeof paneId !== 'string') {
      return ''
    }
    return paneId
  }

  private static enqueue(operation: () => Promise<void>): void {
    BackgroundBellNotification.operationQueue = BackgroundBellNotification.operationQueue
      .then(operation)
      .catch((e: Error) => {
        logger.warn('Notification operation queue recovered: ' + e.message)
      })
  }

  private static isCurrent(version: number, paneId: string): boolean {
    return BackgroundBellNotification.requestVersion === version &&
      BackgroundBellNotification.targetPaneId === paneId
  }

  private static async cancelPlatformNotification(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFICATION_ID, NOTIFICATION_LABEL)
      logger.info('Background BEL notification canceled')
    } catch (e) {
      let error: BusinessError = e as BusinessError
      if (error.code !== 1600007) {
        BackgroundBellNotification.logPlatformFailure('cancel', e)
      }
    }
  }

  private static logPlatformFailure(operation: string, failure: Object): void {
    let error: BusinessError = failure as BusinessError
    logger.warn('Notification ' + operation + ' failed: code=' + error.code.toString())
  }
}

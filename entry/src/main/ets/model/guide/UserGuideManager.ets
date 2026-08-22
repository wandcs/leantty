import { common } from '@kit.AbilityKit'
import { Environment, fileIo as fs, fileUri } from '@kit.CoreFileKit'
import { Logger } from '../../common/logger/Logger'
import { DownloadsAccessManager } from '../transfer/DownloadsAccessManager'
import { UserGuideFileDecision, UserGuidePolicy } from './UserGuidePolicy'

const logger: Logger = new Logger('UserGuideManager')

export class UserGuideResult {
  available: boolean = false
  uri: string = ''
  errorMessage: string = ''
}

export class UserGuideManager {
  private static activeSync: Promise<UserGuideResult> | null = null

  static sync(context: common.Context): Promise<UserGuideResult> {
    if (UserGuideManager.activeSync !== null) {
      return UserGuideManager.activeSync
    }
    let task: Promise<UserGuideResult> = UserGuideManager.performSync(context)
    UserGuideManager.activeSync = task
    task.then(() => {
      UserGuideManager.clearActiveSync(task)
    }).catch(() => {
      UserGuideManager.clearActiveSync(task)
    })
    return task
  }

  static expectedUri(context: common.Context): string {
    let path: string = UserGuideManager.expectedPath(context)
    return fileUri.getUriFromPath(path)
  }

  static expectedPath(context: common.Context): string {
    let downloadDirectory: string = Environment.getUserDownloadDir()
    return UserGuidePolicy.guidePath(downloadDirectory, context.applicationInfo.name)
  }

  private static clearActiveSync(task: Promise<UserGuideResult>): void {
    if (UserGuideManager.activeSync === task) {
      UserGuideManager.activeSync = null
    }
  }

  private static async performSync(context: common.Context): Promise<UserGuideResult> {
    try {
      await DownloadsAccessManager.ensure(context)
      let downloadDirectory: string = Environment.getUserDownloadDir()
      let bundleName: string = context.applicationInfo.name
      let guideDirectory: string = UserGuidePolicy.guideDirectory(downloadDirectory, bundleName)
      let guidePath: string = UserGuidePolicy.guidePath(downloadDirectory, bundleName)
      let tempPath: string = UserGuidePolicy.tempPath(downloadDirectory, bundleName)
      let packaged: Uint8Array = context.resourceManager.getRawFileContentSync(UserGuidePolicy.RAW_FILE_NAME)
      UserGuideManager.validatePackagedGuide(packaged)
      UserGuideManager.ensureGuideDirectory(guideDirectory)

      let existing: Uint8Array | null = UserGuideManager.readExistingGuide(guidePath)
      let decision: UserGuideFileDecision = UserGuidePolicy.decide(existing, packaged)
      if (decision === UserGuideFileDecision.CONFLICT) {
        return UserGuideManager.failure('Downloads already contains a file with this name that is not owned by LeanTTY.')
      }
      if (decision !== UserGuideFileDecision.CURRENT) {
        UserGuideManager.commitGuide(tempPath, guidePath, packaged, decision === UserGuideFileDecision.CREATE)
        logger.info(decision === UserGuideFileDecision.CREATE ? 'Offline user guide created' :
          'Offline user guide updated')
      } else {
        logger.info('Offline user guide is current')
      }
      let result: UserGuideResult = new UserGuideResult()
      result.available = true
      result.uri = fileUri.getUriFromPath(guidePath)
      return result
    } catch (e) {
      logger.warn('Offline user guide unavailable: ' + e)
      return UserGuideManager.failure(UserGuideManager.userFacingError(e))
    }
  }

  private static validatePackagedGuide(content: Uint8Array): void {
    if (content.length === 0 || content.length > UserGuidePolicy.MAX_GUIDE_BYTES ||
      !UserGuidePolicy.hasOwnershipMarker(content)) {
      throw new Error('The packaged user guide is invalid')
    }
  }

  private static ensureGuideDirectory(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path)
      return
    }
    let stat: fs.Stat = fs.lstatSync(path)
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error('The LeanTTY Downloads folder is unavailable')
    }
  }

  private static readExistingGuide(path: string): Uint8Array | null {
    if (!fs.accessSync(path)) {
      return null
    }
    let stat: fs.Stat = fs.lstatSync(path)
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error('The user guide path is not a regular file')
    }
    let readLength: number = Math.min(stat.size, UserGuidePolicy.MAX_GUIDE_BYTES + 1)
    let file: fs.File | null = null
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY)
      let content: Uint8Array = new Uint8Array(readLength)
      let actual: number = fs.readSync(file.fd, content.buffer)
      if (actual !== readLength) {
        throw new Error('The existing user guide could not be read completely')
      }
      return content
    } finally {
      UserGuideManager.closeFile(file)
    }
  }

  private static commitGuide(tempPath: string, guidePath: string, content: Uint8Array, createOnly: boolean): void {
    UserGuideManager.removeTempFile(tempPath)
    let file: fs.File | null = null
    try {
      file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY)
      let written: number = fs.writeSync(file.fd, content.buffer)
      if (written !== content.length) {
        throw new Error('The new user guide could not be written completely')
      }
      fs.fsyncSync(file.fd)
      UserGuideManager.closeFile(file)
      file = null
      fs.moveFileSync(tempPath, guidePath, createOnly ? 1 : 0)
    } catch (e) {
      UserGuideManager.closeFile(file)
      UserGuideManager.removeTempFile(tempPath)
      throw new Error('Failed to commit the user guide: ' + e)
    }
  }

  private static removeTempFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path)
      }
    } catch (e) {
      throw new Error('The previous temporary user guide could not be removed')
    }
  }

  private static closeFile(file: fs.File | null): void {
    if (file !== null) {
      try {
        fs.closeSync(file)
      } catch (e) {
      }
    }
  }

  private static failure(message: string): UserGuideResult {
    let result: UserGuideResult = new UserGuideResult()
    result.errorMessage = message
    return result
  }

  private static userFacingError(error: Object): string {
    let detail: string = '' + error
    if (detail.includes('Downloads access was denied')) {
      return 'Downloads access was denied.'
    }
    if (detail.includes('not owned by LeanTTY')) {
      return 'A same-name file in Downloads is not owned by LeanTTY; it was not overwritten.'
    }
    if (detail.includes('Downloads directory') || detail.includes('Downloads folder')) {
      return 'The Downloads folder is unavailable.'
    }
    return 'LeanTTY could not create or update the guide.'
  }
}

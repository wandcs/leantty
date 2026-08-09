import { common } from '@kit.AbilityKit'
import { Environment, fileIo as fs } from '@kit.CoreFileKit'
import { DownloadsAccessManager } from './DownloadsAccessManager'

export class TransferLocalFile {
  file: fs.File | null = null
  localName: string = ''
  finalPath: string = ''
  tempPath: string = ''
  automaticName: boolean = false
  relativeDirectory: string = ''
  nameConflictExpected: boolean = false
}

export class TransferFileManager {
  private static tempSequence: number = 0
  private static readonly MAX_AUTOMATIC_NAMES: number = 10000
  private static readonly MAX_BASENAME_BYTES: number = 255
  private static readonly MAX_RELATIVE_PATH_BYTES: number = 4096

  static async preparePut(context: common.Context, localName: string): Promise<TransferLocalFile> {
    TransferFileManager.assertRelativePath(localName, false)
    await DownloadsAccessManager.ensure(context)
    let root: string = TransferFileManager.downloadsRoot()
    let directory: string = TransferFileManager.relativeDirectory(localName)
    TransferFileManager.assertDirectoryChain(root, directory)
    let path: string = root + '/' + localName
    if (!fs.accessSync(path)) {
      throw new Error('LOCAL_NOT_FOUND: Downloads does not contain "' + localName + '"')
    }
    let stat: fs.Stat = fs.lstatSync(path)
    if (!stat.isFile() || stat.isSymbolicLink()) {
      let hint: string = stat.isDirectory() ? ' Directories cannot be uploaded recursively.' : ''
      throw new Error('LOCAL_PATH: Downloads source must be a regular file and cannot be a symbolic link.' + hint)
    }
    let prepared: TransferLocalFile = new TransferLocalFile()
    prepared.file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW)
    prepared.localName = localName
    prepared.finalPath = path
    prepared.relativeDirectory = directory
    return prepared
  }

  static async prepareGet(
    context: common.Context,
    remotePath: string,
    requestedLocalName: string,
    automaticName: boolean
  ): Promise<TransferLocalFile> {
    await DownloadsAccessManager.ensure(context)
    let directoryTarget: boolean = requestedLocalName.endsWith('/')
    let directory: string = directoryTarget ? requestedLocalName.substring(0, requestedLocalName.length - 1) :
      TransferFileManager.relativeDirectory(requestedLocalName)
    let basename: string = automaticName ? TransferFileManager.remoteBasename(remotePath) :
      TransferFileManager.relativeBasename(requestedLocalName)
    let localName: string = directory.length > 0 ? directory + '/' + basename : basename
    TransferFileManager.assertRelativePath(localName, false)
    let root: string = TransferFileManager.downloadsRoot()
    TransferFileManager.assertDirectoryChain(root, directory)
    let finalPath: string = root + '/' + localName
    if (!automaticName && fs.accessSync(finalPath)) {
      let existing: fs.Stat = fs.lstatSync(finalPath)
      let hint: string = existing.isDirectory() ? ' Add / to use it as a target directory.' : ''
      throw new Error('LOCAL_CONFLICT: Downloads already contains "' + localName + '".' + hint)
    }
    TransferFileManager.tempSequence++
    if (TransferFileManager.tempSequence > 2147483647) {
      TransferFileManager.tempSequence = 1
    }
    let randomPart: string = Math.floor(Math.random() * 4294967296).toString(16)
    let tempName: string = '.leantty-' + Date.now().toString() + '-' +
      TransferFileManager.tempSequence.toString() + '-' + randomPart + '.part'
    let prepared: TransferLocalFile = new TransferLocalFile()
    prepared.localName = localName
    prepared.finalPath = finalPath
    prepared.tempPath = (directory.length > 0 ? root + '/' + directory : root) + '/' + tempName
    prepared.automaticName = automaticName
    prepared.relativeDirectory = directory
    prepared.nameConflictExpected = automaticName && fs.accessSync(finalPath)
    return prepared
  }

  static commitGet(prepared: TransferLocalFile): string {
    if (prepared.tempPath.length === 0 || prepared.finalPath.length === 0) {
      throw new Error('LOCAL_COMMIT: missing local temporary or final path')
    }
    let root: string = TransferFileManager.downloadsRoot()
    TransferFileManager.assertDirectoryChain(root, prepared.relativeDirectory)
    if (!prepared.automaticName) {
      fs.moveFileSync(prepared.tempPath, prepared.finalPath, 1)
      prepared.tempPath = ''
      return prepared.localName
    }
    let basename: string = TransferFileManager.relativeBasename(prepared.localName)
    for (let index: number = 0; index < TransferFileManager.MAX_AUTOMATIC_NAMES; index++) {
      let candidateName: string = TransferFileManager.automaticName(basename, index)
      let slash: number = prepared.finalPath.lastIndexOf('/')
      let candidatePath: string = prepared.finalPath.substring(0, slash + 1) + candidateName
      try {
        fs.moveFileSync(prepared.tempPath, candidatePath, 1)
        prepared.tempPath = ''
        prepared.finalPath = candidatePath
        return prepared.relativeDirectory.length > 0 ? prepared.relativeDirectory + '/' + candidateName : candidateName
      } catch (e) {
        let detail: string = '' + e
        if (!detail.includes('File exists')) {
          throw new Error('LOCAL_COMMIT: ' + detail)
        }
      }
    }
    throw new Error('LOCAL_CONFLICT: no available automatic Downloads name')
  }

  static cleanup(prepared: TransferLocalFile | null): void {
    if (prepared === null) {
      return
    }
    TransferFileManager.close(prepared)
    if (prepared.tempPath.length > 0) {
      try {
        if (fs.accessSync(prepared.tempPath)) {
          fs.unlinkSync(prepared.tempPath)
        }
      } catch (e) {
        throw new Error('LOCAL_CLEANUP: temporary file cleanup failed')
      } finally {
        prepared.tempPath = ''
      }
    }
  }

  static close(prepared: TransferLocalFile | null): void {
    if (prepared !== null && prepared.file !== null) {
      try {
        fs.closeSync(prepared.file)
      } catch (e) {
      }
      prepared.file = null
    }
  }

  static automaticName(name: string, index: number): string {
    if (index === 0) {
      return name
    }
    let dot: number = name.lastIndexOf('.')
    let hasExtension: boolean = dot > 0
    let stem: string = hasExtension ? name.substring(0, dot) : name
    let extension: string = hasExtension ? name.substring(dot) : ''
    let counter: string = ' (' + index.toString() + ')'
    let stemBudget: number = TransferFileManager.MAX_BASENAME_BYTES -
      TransferFileManager.utf8Length(counter) - TransferFileManager.utf8Length(extension)
    if (stemBudget < 1) {
      throw new Error('LOCAL_PATH: file extension leaves no room for an automatic name')
    }
    return TransferFileManager.truncateUtf8(stem, stemBudget) + counter + extension
  }

  private static downloadsRoot(): string {
    let root: string = Environment.getUserDownloadDir().replace(/\/+$/, '')
    if (root.length === 0) {
      throw new Error('LOCAL_PERMISSION: Downloads directory is unavailable')
    }
    return root
  }

  private static remoteBasename(remotePath: string): string {
    let normalized: string = remotePath.replace(/\\/g, '/')
    let basename: string = normalized.substring(normalized.lastIndexOf('/') + 1)
    if (basename.length === 0) {
      throw new Error('LOCAL_PATH: remote path does not contain a usable basename')
    }
    return basename
  }

  private static assertRelativePath(path: string, directory: boolean): void {
    if (path.length === 0 || path.startsWith('/') || path.startsWith('\\') || /^[A-Za-z]:/.test(path) ||
      path.includes('\\') || TransferFileManager.utf8Length(path) > TransferFileManager.MAX_RELATIVE_PATH_BYTES ||
      (path.endsWith('/') && !directory) || TransferFileManager.hasUnsafePathCharacter(path)) {
      throw new Error('LOCAL_PATH: local path must stay within Downloads')
    }
    let normalized: string = directory ? path.replace(/\/$/, '') : path
    let parts: string[] = normalized.split('/')
    for (let index: number = 0; index < parts.length; index++) {
      if (parts[index].length === 0 || parts[index] === '.' || parts[index] === '..' ||
        TransferFileManager.utf8Length(parts[index]) > TransferFileManager.MAX_BASENAME_BYTES) {
        throw new Error('LOCAL_PATH: local path contains an invalid component')
      }
    }
  }

  private static assertDirectoryChain(root: string, relativeDirectory: string): void {
    if (relativeDirectory.length === 0) { return }
    TransferFileManager.assertRelativePath(relativeDirectory, false)
    let parts: string[] = relativeDirectory.split('/')
    let current: string = root
    for (let index: number = 0; index < parts.length; index++) {
      current += '/' + parts[index]
      if (!fs.accessSync(current)) {
        throw new Error('LOCAL_NOT_FOUND: Downloads directory does not exist: "' +
          parts.slice(0, index + 1).join('/') + '/"')
      }
      let stat: fs.Stat = fs.lstatSync(current)
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new Error('LOCAL_PATH: Downloads path component must be a real directory: "' +
          parts.slice(0, index + 1).join('/') + '"')
      }
      let directoryFile: fs.File | null = null
      try {
        directoryFile = fs.openSync(current, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW)
      } finally {
        if (directoryFile !== null) { fs.closeSync(directoryFile) }
      }
    }
  }

  private static relativeDirectory(path: string): string {
    let slash: number = path.lastIndexOf('/')
    return slash < 0 ? '' : path.substring(0, slash)
  }

  private static relativeBasename(path: string): string {
    let normalized: string = path.replace(/\/$/, '')
    let slash: number = normalized.lastIndexOf('/')
    return normalized.substring(slash + 1)
  }

  private static hasUnsafePathCharacter(path: string): boolean {
    for (let index: number = 0; index < path.length; index++) {
      let code: number = path.charCodeAt(index)
      if (code === 0 || code === 0x1B || code < 0x20 || (code >= 0x7F && code <= 0x9F)) {
        return true
      }
    }
    return false
  }

  private static utf8Length(value: string): number {
    let length: number = 0
    for (let index: number = 0; index < value.length; index++) {
      let code: number = value.charCodeAt(index)
      if (code <= 0x7F) {
        length++
      } else if (code <= 0x7FF) {
        length += 2
      } else if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length) {
        let following: number = value.charCodeAt(index + 1)
        if (following >= 0xDC00 && following <= 0xDFFF) {
          length += 4
          index++
        } else {
          length += 3
        }
      } else {
        length += 3
      }
    }
    return length
  }

  private static truncateUtf8(value: string, maximumBytes: number): string {
    let end: number = value.length
    while (end > 0 && TransferFileManager.utf8Length(value.substring(0, end)) > maximumBytes) {
      let trailing: number = value.charCodeAt(end - 1)
      if (trailing >= 0xDC00 && trailing <= 0xDFFF && end >= 2) {
        let leading: number = value.charCodeAt(end - 2)
        end -= leading >= 0xD800 && leading <= 0xDBFF ? 2 : 1
      } else {
        end--
      }
    }
    if (end === 0) {
      throw new Error('LOCAL_PATH: file name cannot fit the automatic suffix')
    }
    return value.substring(0, end)
  }
}

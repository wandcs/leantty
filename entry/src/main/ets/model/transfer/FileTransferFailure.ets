export enum FileTransferFailureKind {
  PERMISSION = 0,
  LOCAL_CONFLICT = 1,
  REMOTE_CONFLICT = 2,
  PATH = 3,
  NOT_FOUND = 4,
  SFTP_UNAVAILABLE = 5,
  AUTHENTICATION = 6,
  HOST_VERIFICATION = 7,
  SPACE = 8,
  NETWORK = 9,
  COMMIT = 10,
  CLEANUP = 11,
  IO = 12,
  UNKNOWN = 13
}

export class FileTransferFailureInfo {
  kind: FileTransferFailureKind = FileTransferFailureKind.UNKNOWN
  message: string = ''
}

export class FileTransferFailurePresenter {
  static describe(code: string, detail: string, direction: string): FileTransferFailureInfo {
    let normalizedCode: string = FileTransferFailurePresenter.safeCode(code)
    let normalizedDetail: string = detail.toLowerCase()
    normalizedCode = FileTransferFailurePresenter.embeddedCode(normalizedCode, normalizedDetail)
    if (normalizedCode === 'LOCAL_PERMISSION' || normalizedDetail.includes('downloads access was denied')) {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.PERMISSION,
        'File transfer stopped: Downloads access was denied.\r\nRun the same command again to retry permission.')
    }
    if (FileTransferFailurePresenter.isOutOfSpace(normalizedDetail)) {
      let location: string = direction === 'get' ? 'Downloads' : 'the remote server'
      return FileTransferFailurePresenter.info(FileTransferFailureKind.SPACE,
        'File transfer stopped: ' + location + ' ran out of space.\r\nFree space, then run the command again.')
    }
    if (normalizedCode === 'LOCAL_CONFLICT' || normalizedDetail.includes('local_conflict') ||
      normalizedDetail.includes('file exists')) {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.LOCAL_CONFLICT,
        'Download stopped: that Downloads name already exists.\r\nSpecify a different local filename.')
    }
    if (normalizedCode === 'REMOTE_CONFLICT') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.REMOTE_CONFLICT,
        'Upload stopped: the remote target already exists.\r\nChoose a different remote filename.')
    }
    if (normalizedCode === 'LOCAL_NOT_FOUND') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.NOT_FOUND,
        'Upload stopped: the Downloads source does not exist.\r\nCheck the local path, then run put again.')
    }
    if (normalizedCode === 'REMOTE_NOT_FOUND') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.NOT_FOUND,
        'Download stopped: the remote source does not exist.\r\nCheck the remote path, then run get again.')
    }
    if (normalizedCode === 'LOCAL_PATH' || normalizedCode === 'REMOTE_PATH') {
      let side: string = normalizedCode === 'LOCAL_PATH' ? 'Downloads' : 'remote'
      return FileTransferFailurePresenter.info(FileTransferFailureKind.PATH,
        'File transfer stopped: the ' + side + ' path is not an allowed regular file path.\r\n' +
        'Check the path and directory trailing /.')
    }
    if (normalizedCode === 'SFTP_UNAVAILABLE') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.SFTP_UNAVAILABLE,
        'File transfer stopped: this server does not provide SFTP.\r\n' +
        'Enable SFTP on the server or use another Host.')
    }
    if (normalizedCode === 'AUTH') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.AUTHENTICATION,
        'File transfer authentication failed.\r\n' +
        'Check the username, credential and Identity, then run the command again.')
    }
    if (normalizedCode.startsWith('HOST_KEY')) {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.HOST_VERIFICATION,
        'File transfer stopped during host verification.\r\n' +
        'Check the fingerprint or known_hosts entry before retrying.')
    }
    if (normalizedCode === 'NETWORK_TIMEOUT' || normalizedCode === 'SFTP_TIMEOUT') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.NETWORK,
        'File transfer timed out while connecting.\r\n' +
        'Check the network and Host, then run the command again.')
    }
    if (normalizedCode === 'NETWORK') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.NETWORK,
        'File transfer lost the SSH connection.\r\n' +
        'Check the network and Host, then run the command again.')
    }
    if (normalizedCode === 'LOCAL_COMMIT' || normalizedCode === 'REMOTE_COMMIT') {
      let target: string = normalizedCode === 'LOCAL_COMMIT' ? 'Downloads' : 'remote'
      return FileTransferFailurePresenter.info(FileTransferFailureKind.COMMIT,
        'File transfer finished copying but could not commit the ' + target +
        ' final name.\r\nThe existing target was not replaced; choose another name and retry.')
    }
    if (normalizedCode === 'LOCAL_CLEANUP' || normalizedCode === 'REMOTE_CLEANUP') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.CLEANUP,
        FileTransferFailurePresenter.cleanupWarning(normalizedCode === 'LOCAL_CLEANUP'))
    }
    if (normalizedCode === 'SOURCE_CHANGED') {
      if (direction === 'get') {
        return FileTransferFailurePresenter.info(FileTransferFailureKind.NETWORK,
          'Download ended before the remote file\'s advertised size.\r\n' +
          'Check the network or whether the remote source changed, then retry.')
      }
      return FileTransferFailurePresenter.info(FileTransferFailureKind.IO,
        'Upload stopped because the local source changed while it was being read.\r\nCheck the file and retry.')
    }
    if (normalizedDetail.includes('permission denied') || normalizedDetail.includes('permissiondenied')) {
      let target: string = direction === 'get' ? 'remote source' : 'remote target directory'
      return FileTransferFailurePresenter.info(FileTransferFailureKind.PERMISSION,
        'File transfer stopped: the server denied access to the ' + target + '.\r\n' +
        'Check its permissions and retry.')
    }
    if (normalizedCode === 'READ' || normalizedCode === 'WRITE' ||
      normalizedCode === 'LOCAL_OPEN' || normalizedCode === 'LOCAL_METADATA' ||
      normalizedCode === 'LOCAL_FLUSH' || normalizedCode === 'LOCAL_SYNC' ||
      normalizedCode === 'REMOTE_OPEN' || normalizedCode === 'REMOTE_METADATA' ||
      normalizedCode === 'REMOTE_TEMP_CREATE' || normalizedCode === 'REMOTE_CLOSE') {
      return FileTransferFailurePresenter.info(FileTransferFailureKind.IO,
        'File transfer stopped while reading or writing the file.\r\n' +
        'Check both file paths and permissions, then retry.')
    }
    return FileTransferFailurePresenter.info(FileTransferFailureKind.UNKNOWN,
      'File transfer failed [' + normalizedCode + '].\r\nCheck the paths, server and network, then retry.')
  }

  static cleanupWarning(local: boolean): string {
    return local ?
      'Cleanup incomplete: LeanTTY could not remove its Downloads temporary file.\r\n' +
      'Remove the matching .leantty-*.part file before retrying.' :
      'Cleanup incomplete: LeanTTY could not remove its remote temporary file.\r\n' +
      'Remove the matching .leantty-*.part file before retrying.'
  }

  private static info(kind: FileTransferFailureKind, message: string): FileTransferFailureInfo {
    let info: FileTransferFailureInfo = new FileTransferFailureInfo()
    info.kind = kind
    info.message = message
    return info
  }

  private static isOutOfSpace(detail: string): boolean {
    return detail.includes('no space left') || detail.includes('enospc') ||
      detail.includes('disk full') || detail.includes('status code: 28')
  }

  private static safeCode(code: string): string {
    let value: string = code.toUpperCase().replace(/[^A-Z0-9_]/g, '_')
    return value.length > 0 ? value.substring(0, 48) : 'UNKNOWN'
  }

  private static embeddedCode(code: string, detail: string): string {
    for (let candidate of [
      'local_permission', 'local_conflict', 'local_not_found', 'local_path',
      'local_commit', 'local_cleanup'
    ]) {
      if (detail.includes(candidate)) { return candidate.toUpperCase() }
    }
    return code
  }
}

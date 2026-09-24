import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@ohos.base'
import { FileUtils } from '../../common/utils/FileUtils'
import { DurableAssetFormat } from './DurableAssetFormat'

// DurableStateManager serializes this file's complete read/modify/write operation.
// The file is the trust authority, not an Asset Store projection.
export class KnownHostsFile {
  static async read(path: string): Promise<string> {
    try {
      return await fs.readText(path)
    } catch (e) {
      if ((e as BusinessError).code === 13900002) {
        return ''
      }
      throw new Error('Cannot read known_hosts: ' + e)
    }
  }

  static async write(path: string, content: string): Promise<void> {
    let directory: string = path.substring(0, path.lastIndexOf('/'))
    FileUtils.ensureDir(directory)
    let temporary: string = path + '.tmp'
    let file: fs.File | null = null
    try {
      file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY)
      // CoreFileKit creates this in the application's private directory using
      // platform owner/group permissions; no public-storage URI is accepted.
      let bytes: Uint8Array = DurableAssetFormat.encodeText(content)
      let written: number = await fs.write(file.fd, bytes.buffer)
      if (written !== bytes.length) {
        throw new Error('Incomplete known_hosts write')
      }
      await fs.fsync(file.fd)
      await fs.close(file)
      file = null
      await fs.rename(temporary, path)
      // Sync both the replacement and a possibly newly created .ssh directory.
      // A failure after rename is reported; the approved decision may be visible.
      await KnownHostsFile.syncDirectory(directory)
      await KnownHostsFile.syncDirectory(directory.substring(0, directory.lastIndexOf('/')))
    } catch (e) {
      throw new Error('Cannot commit known_hosts: ' + e)
    } finally {
      if (file !== null) {
        try { await fs.close(file) } catch (e) {}
      }
      // A leftover temporary file is never read as trust, including after restart.
      try { await fs.unlink(temporary) } catch (e) {}
    }
  }

  private static async syncDirectory(path: string): Promise<void> {
    try {
      let directory: fs.File = await fs.open(path, fs.OpenMode.READ_ONLY)
      try {
        await fs.fsync(directory.fd)
      } finally {
        await fs.close(directory)
      }
    } catch (e) {
      throw new Error('Cannot sync known_hosts directory: ' + e)
    }
  }
}

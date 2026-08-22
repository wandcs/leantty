import { fileIo as fs } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'

export class FileUtils {
  static getSshDir(context: common.Context): string {
    return context.filesDir + '/.ssh'
  }

  static ensureDir(dirPath: string): void {
    try {
      if (!fs.accessSync(dirPath)) {
        fs.mkdirSync(dirPath)
      }
    } catch (e) {
      throw new Error('Failed to ensure dir: ' + dirPath)
    }
  }

  static readTextFile(filePath: string): string {
    try {
      if (!fs.accessSync(filePath)) {
        return ''
      }
      return fs.readTextSync(filePath)
    } catch (e) {
      throw new Error('Failed to read file: ' + filePath + ', detail=' + e)
    }
  }

  static writeTextFile(filePath: string, content: string): void {
    let tempPath: string = filePath + '.tmp'
    let file: fs.File | null = null
    try {
      let dirPath: string = filePath.substring(0, filePath.lastIndexOf('/'))
      FileUtils.ensureDir(dirPath)
      file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY)
      fs.writeSync(file.fd, content)
    } catch (e) {
      FileUtils.closeFile(file)
      FileUtils.removeIfExists(tempPath)
      throw new Error('Failed to write file: ' + filePath + ', detail=' + e)
    }
    try {
      FileUtils.closeFile(file)
      fs.renameSync(tempPath, filePath)
    } catch (e) {
      FileUtils.removeIfExists(tempPath)
      throw new Error('Failed to commit file: ' + filePath + ', detail=' + e)
    }
  }

  static fileExists(filePath: string): boolean {
    try {
      return fs.accessSync(filePath)
    } catch (e) {
      return false
    }
  }

  static listFiles(dirPath: string): string[] {
    try {
      return fs.listFileSync(dirPath)
    } catch (e) {
      return []
    }
  }

  static copyFile(sourcePath: string, destPath: string): void {
    try {
      let content: string = fs.readTextSync(sourcePath)
      FileUtils.writeTextFile(destPath, content)
    } catch (e) {
      throw new Error('Failed to copy file: ' + sourcePath + ' -> ' + destPath)
    }
  }

  static removeFile(filePath: string): void {
    FileUtils.removeIfExists(filePath)
  }

  static removeFileRequired(filePath: string): void {
    try {
      if (!fs.accessSync(filePath)) {
        return
      }
      fs.unlinkSync(filePath)
      if (fs.accessSync(filePath)) {
        throw new Error('file remains after unlink')
      }
    } catch (e) {
      throw new Error('Failed to remove file: ' + filePath + ', detail=' + e)
    }
  }

  static fileNameFromPath(filePath: string): string {
    let lastSlash: number = filePath.lastIndexOf('/')
    if (lastSlash >= 0) { return filePath.substring(lastSlash + 1) }
    return filePath
  }

  private static closeFile(file: fs.File | null): void {
    if (file !== null) {
      try {
        fs.closeSync(file)
      } catch (e) {
      }
    }
  }

  private static removeIfExists(filePath: string): void {
    try {
      if (fs.accessSync(filePath)) {
        fs.unlinkSync(filePath)
      }
    } catch (e) {
    }
  }
}

import { FileUtils } from '../../common/utils/FileUtils'
import { common } from '@kit.AbilityKit'
import { Environment, fileIo as fs } from '@kit.CoreFileKit'
import { DurableAssetFormat } from '../persistence/DurableAssetFormat'
import { DurableStateManager } from '../persistence/DurableStateManager'
import { DownloadsAccessManager } from '../transfer/DownloadsAccessManager'
import {
  DEFAULT_SSH_CONNECT_TIMEOUT_MS,
  MAX_SSH_CONNECT_TIMEOUT_SECONDS,
  DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS,
  DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX,
  MAX_SSH_SERVER_ALIVE_INTERVAL_SECONDS,
  MAX_SSH_SERVER_ALIVE_COUNT_MAX
} from '../../common/types/SshTypes'

const MANAGED_BEGIN: string = '# >>> LeanTTY managed hosts >>>'
const MANAGED_END: string = '# <<< LeanTTY managed hosts <<<'
const MAX_CONFIG_BYTES: number = 1024 * 1024
const DEFAULT_EXPORT_NAME: string = 'leantty-ssh-config'
const VALID_CONFIG_FILE_NAME: RegExp = /^[A-Za-z0-9._-]+$/

export class SshConfigHost {
  alias: string
  hostname: string
  port: number
  user: string
  identityFile: string
  proxyJump: string
  connectTimeoutMs: number
  serverAliveIntervalSeconds: number
  serverAliveCountMax: number
  errorMessage: string

  constructor(alias: string) {
    this.alias = alias
    this.hostname = ''
    this.port = 22
    this.user = ''
    this.identityFile = ''
    this.proxyJump = ''
    this.connectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
    this.serverAliveIntervalSeconds = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
    this.serverAliveCountMax = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
    this.errorMessage = ''
  }
}

export class SshConfig {
  private hosts: SshConfigHost[] = []
  private loaded: boolean = false
  private sourceText: string = ''
  private pendingUpserts: string[] = []
  private pendingRemovals: string[] = []
  private managedAliases: string[] = []

  load(context: common.Context): void {
    this.hosts = []
    let sshDir: string = FileUtils.getSshDir(context)
    let configPath: string = sshDir + '/config'
    let content: string = FileUtils.readTextFile(configPath)
    if (content.length === 0) {
      this.sourceText = ''
      this.pendingUpserts = []
      this.pendingRemovals = []
      this.managedAliases = []
      this.loaded = true
      return
    }
    this.loadFromText(content)
  }

  loadFromText(content: string): void {
    this.hosts = []
    this.sourceText = content
    this.pendingUpserts = []
    this.pendingRemovals = []
    this.managedAliases = this.readManagedAliases(content)
    this.parseConfig(content)
    this.loaded = true
  }

  getHosts(): SshConfigHost[] {
    return this.hosts
  }

  getHostAliases(): string[] {
    let aliases: string[] = []
    for (let i = 0; i < this.hosts.length; i++) {
      aliases.push(this.hosts[i].alias)
    }
    return aliases
  }

  findHost(alias: string): SshConfigHost | null {
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hosts[i].alias === alias) {
        if (this.pendingUpserts.indexOf(alias) >= 0 || this.sourceText.length === 0) {
          return this.hosts[i]
        }
        return this.resolveSourceHost(alias)
      }
    }
    return null
  }

  isLoaded(): boolean {
    return this.loaded
  }

  getConfigText(): string {
    return this.sourceText
  }

  static defaultExportName(): string {
    return DEFAULT_EXPORT_NAME
  }

  previewImportedText(content: string, replaceExisting: boolean = false): string {
    this.validateImportedText(content, replaceExisting)
    let unmanaged: string = this.removeManagedRegion(this.sourceText)
    if (unmanaged.trim().length > 0 && !replaceExisting) {
      throw new Error('The current config already contains non-LeanTTY text; export it before importing another file')
    }
    let managed: string = this.renderManagedRegion()
    if (managed.length === 0) {
      return content
    }
    let newline: string = content.includes('\r\n') ? '\r\n' : '\n'
    return managed + newline + content
  }

  async importFromDownloads(
    context: common.Context,
    fileName: string,
    replaceExisting: boolean = false
  ): Promise<void> {
    SshConfig.validateTransferFileName(fileName)
    await DownloadsAccessManager.ensure(context)
    let content: string = SshConfig.readDownloadsText(fileName, replaceExisting)
    let merged: string = this.previewImportedText(content, replaceExisting)
    this.commitConfigText(context, merged)
  }

  async exportToDownloads(context: common.Context, fileName: string): Promise<void> {
    SshConfig.validateTransferFileName(fileName)
    await DownloadsAccessManager.ensure(context)
    SshConfig.writeDownloadsText(fileName, this.sourceText)
  }

  isManagedHost(alias: string): boolean {
    return this.managedAliases.indexOf(alias) >= 0
  }

  resolveHost(alias: string): SshConfigHost {
    return this.resolveSourceHost(alias)
  }

  addAlias(alias: string, hostname: string, port: number, user: string, proxyJump: string | null = null,
    connectTimeoutMs: number | null = null, serverAliveIntervalSeconds: number | null = null,
    serverAliveCountMax: number | null = null, identityFile: string | null = null): void {
    let existing: SshConfigHost | null = null
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hosts[i].alias === alias) {
        existing = this.hosts[i]
        break
      }
    }
    if (existing !== null) {
      existing.hostname = hostname
      existing.port = port
      existing.user = user
      if (identityFile !== null) { existing.identityFile = identityFile }
      if (proxyJump !== null) { existing.proxyJump = proxyJump }
      if (connectTimeoutMs !== null) { existing.connectTimeoutMs = connectTimeoutMs }
      if (serverAliveIntervalSeconds !== null) { existing.serverAliveIntervalSeconds = serverAliveIntervalSeconds }
      if (serverAliveCountMax !== null) { existing.serverAliveCountMax = serverAliveCountMax }
    } else {
      let host: SshConfigHost = new SshConfigHost(alias)
      host.hostname = hostname
      host.port = port
      host.user = user
      if (identityFile !== null) { host.identityFile = identityFile }
      if (proxyJump !== null) { host.proxyJump = proxyJump }
      if (connectTimeoutMs !== null) { host.connectTimeoutMs = connectTimeoutMs }
      if (serverAliveIntervalSeconds !== null) { host.serverAliveIntervalSeconds = serverAliveIntervalSeconds }
      if (serverAliveCountMax !== null) { host.serverAliveCountMax = serverAliveCountMax }
      this.hosts.push(host)
    }
    this.removePending(this.pendingRemovals, alias)
    this.addPending(this.pendingUpserts, alias)
    this.addPending(this.managedAliases, alias)
  }

  removeAlias(alias: string): boolean {
    if (this.managedAliases.indexOf(alias) < 0) { return false }
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hosts[i].alias === alias) {
        this.hosts.splice(i, 1)
        this.removePending(this.pendingUpserts, alias)
        this.addPending(this.pendingRemovals, alias)
        this.removePending(this.managedAliases, alias)
        return true
      }
    }
    return false
  }

  saveConfig(context: common.Context): void {
    let sshDir: string = FileUtils.getSshDir(context)
    FileUtils.ensureDir(sshDir)
    let configPath: string = sshDir + '/config'
    let content: string = this.previewConfigText()
    if (this.sourceText.length > 0) {
      FileUtils.writeTextFile(configPath + '.leantty.bak', this.sourceText)
    }
    DurableStateManager.commitSshConfig(context, content)
    this.loadFromText(content)
  }

  previewConfigText(): string {
    let unmanaged: string = this.removeManagedRegion(this.sourceText)
    let managed: string = this.renderManagedRegion()
    if (managed.length === 0) { return unmanaged }
    let newline: string = this.sourceText.includes('\r\n') ? '\r\n' : '\n'
    return managed + (unmanaged.length > 0 ? newline + unmanaged : '')
  }

  private renderManagedRegion(): string {
    if (this.managedAliases.length === 0) { return '' }
    let newline: string = this.sourceText.includes('\r\n') ? '\r\n' : '\n'
    let managed: string = MANAGED_BEGIN + newline
    for (let i = 0; i < this.managedAliases.length; i++) {
      let host: SshConfigHost | null = this.findHost(this.managedAliases[i])
      if (host !== null) { managed = this.appendHost(managed, host) }
    }
    managed += MANAGED_END + newline
    return managed
  }

  private commitConfigText(context: common.Context, content: string): void {
    let sshDir: string = FileUtils.getSshDir(context)
    FileUtils.ensureDir(sshDir)
    if (this.sourceText.length > 0) {
      FileUtils.writeTextFile(sshDir + '/config.leantty.bak', this.sourceText)
    }
    DurableStateManager.commitSshConfig(context, content)
    this.loadFromText(content)
  }

  private validateImportedText(content: string, allowEmpty: boolean): void {
    if (content.length === 0 && !allowEmpty) {
      throw new Error('The imported config is empty')
    }
    if (DurableAssetFormat.encodeText(content).length > MAX_CONFIG_BYTES) {
      throw new Error('The imported config exceeds 1 MiB')
    }
    let lines: string[] = content.split(/\r?\n/)
    for (let i = 0; i < lines.length; i++) {
      let raw: string = lines[i]
      for (let charIndex = 0; charIndex < raw.length; charIndex++) {
        let code: number = raw.charCodeAt(charIndex)
        if (code < 0x20 && code !== 0x09) {
          throw new Error('The imported config contains a control character at line ' + (i + 1).toString())
        }
      }
      let trimmed: string = raw.trim()
      if (trimmed === MANAGED_BEGIN || trimmed === MANAGED_END) {
        throw new Error('The imported config contains a reserved LeanTTY managed marker')
      }
      let line: string = this.stripInlineComment(trimmed)
      if (line.length === 0 || line.startsWith('#')) { continue }
      let directive: string[] = this.parseDirective(line)
      let name: string = directive[0]
      let lowerName: string = name.toLowerCase()
      let value: string = directive[1]
      if (lowerName === 'include' || lowerName === 'match') {
        throw new Error(name + ' is not supported in imported config at line ' + (i + 1).toString())
      }
      if (lowerName === 'host' && value.length === 0) {
        throw new Error('Host is missing a pattern at line ' + (i + 1).toString())
      }
      if (lowerName === 'host' && value.includes('"')) {
        throw new Error('Host uses unsupported quoting at line ' + (i + 1).toString())
      }
      if (SshConfig.isSupportedValueDirective(lowerName) &&
        (value.includes('%') || value.includes('${') || value.includes('"'))) {
        throw new Error(name + ' uses unsupported expansion or quoting at line ' + (i + 1).toString())
      }
    }
  }

  private static isSupportedValueDirective(name: string): boolean {
    return name === 'hostname' || name === 'port' || name === 'user' || name === 'identityfile' ||
      name === 'proxyjump' || name === 'connecttimeout' || name === 'serveraliveinterval' ||
      name === 'serveralivecountmax'
  }

  private static validateTransferFileName(name: string): void {
    if (name.length === 0 || name.length > 128 || name === '.' || name === '..' ||
      !VALID_CONFIG_FILE_NAME.test(name)) {
      throw new Error('Config file name can only contain letters, digits, ".", "_", "-"')
    }
  }

  private static readDownloadsText(fileName: string, allowEmpty: boolean): string {
    let path: string = SshConfig.downloadsRoot() + '/' + fileName
    if (!fs.accessSync(path)) {
      throw new Error('Downloads does not contain "' + fileName + '"')
    }
    let stat: fs.Stat = fs.lstatSync(path)
    if (!stat.isFile() || stat.isSymbolicLink() || (!allowEmpty && stat.size < 1) || stat.size > MAX_CONFIG_BYTES) {
      throw new Error('The imported config must be a regular file no larger than 1 MiB')
    }
    let file: fs.File | null = null
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW)
      let bytes: Uint8Array = new Uint8Array(stat.size)
      let read: number = fs.readSync(file.fd, bytes.buffer)
      if (read !== stat.size) {
        throw new Error('The imported config could not be read completely')
      }
      return DurableAssetFormat.decodeText(bytes)
    } finally {
      SshConfig.closeFile(file)
    }
  }

  private static writeDownloadsText(fileName: string, content: string): void {
    let root: string = SshConfig.downloadsRoot()
    let finalPath: string = root + '/' + fileName
    let tempPath: string = root + '/.leantty-config-' + Date.now().toString() + '-' +
      Math.floor(Math.random() * 4294967296).toString(16) + '.part'
    let file: fs.File | null = null
    try {
      let bytes: Uint8Array = DurableAssetFormat.encodeText(content)
      file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY)
      let written: number = fs.writeSync(file.fd, bytes.buffer)
      if (written !== bytes.length) {
        throw new Error('The config export could not be written completely')
      }
      fs.fsyncSync(file.fd)
      SshConfig.closeFile(file)
      file = null
      fs.moveFileSync(tempPath, finalPath, 1)
    } catch (e) {
      SshConfig.closeFile(file)
      SshConfig.removeTempFile(tempPath)
      let detail: string = '' + e
      if (detail.includes('File exists')) {
        throw new Error('Downloads already contains "' + fileName + '"')
      }
      throw new Error('Cannot export config to Downloads: ' + detail)
    }
  }

  private static downloadsRoot(): string {
    let root: string = Environment.getUserDownloadDir().replace(/\/+$/, '')
    if (root.length === 0) {
      throw new Error('Downloads directory is unavailable')
    }
    return root
  }

  private static closeFile(file: fs.File | null): void {
    if (file !== null) {
      try { fs.closeSync(file) } catch (e) {}
    }
  }

  private static removeTempFile(path: string): void {
    try {
      if (fs.accessSync(path)) { fs.unlinkSync(path) }
    } catch (e) {}
  }

  private appendHost(content: string, host: SshConfigHost): string {
    let newline: string = content.includes('\r\n') ? '\r\n' : '\n'
    let text: string = content
    if (text.length > 0 && !text.endsWith('\n')) {
      text += newline
    }
    if (text.length > 0 && !text.endsWith(newline + newline)) {
      text += newline
    }
    text += 'Host ' + host.alias + newline
    text += '  HostName ' + host.hostname + newline
    text += '  User ' + host.user + newline
    if (host.port !== 22) {
      text += '  Port ' + host.port.toString() + newline
    }
    if (host.identityFile.length > 0) {
      text += '  IdentityFile ' + host.identityFile + newline
    }
    if (host.proxyJump.length > 0) {
      text += '  ProxyJump ' + host.proxyJump + newline
    }
    if (host.connectTimeoutMs !== DEFAULT_SSH_CONNECT_TIMEOUT_MS) {
      text += '  ConnectTimeout ' + Math.floor(host.connectTimeoutMs / 1000).toString() + newline
    }
    if (host.serverAliveIntervalSeconds !== DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS) {
      text += '  ServerAliveInterval ' + host.serverAliveIntervalSeconds.toString() + newline
    }
    if (host.serverAliveCountMax !== DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX) {
      text += '  ServerAliveCountMax ' + host.serverAliveCountMax.toString() + newline
    }
    return text + newline
  }

  private readManagedAliases(content: string): string[] {
    let aliases: string[] = []
    let lines: string[] = content.split(/\r?\n/)
    let managed: boolean = false
    for (let i = 0; i < lines.length; i++) {
      let trimmed: string = lines[i].trim()
      if (trimmed === MANAGED_BEGIN) { managed = true; continue }
      if (trimmed === MANAGED_END) { managed = false; continue }
      if (!managed) { continue }
      let clean: string = this.stripInlineComment(trimmed)
      if (clean.toLowerCase().startsWith('host ')) {
        let names: string[] = clean.substring(5).trim().split(/\s+/)
        for (let nameIndex = 0; nameIndex < names.length; nameIndex++) {
          if (!names[nameIndex].includes('*') && !names[nameIndex].includes('?') &&
            !names[nameIndex].startsWith('!')) {
            this.addPending(aliases, names[nameIndex])
          }
        }
      }
    }
    return aliases
  }

  private removeManagedRegion(content: string): string {
    let lines: string[] = content.split(/\r?\n/)
    let output: string[] = []
    let managed: boolean = false
    let skipOwnedSeparator: boolean = false
    for (let i = 0; i < lines.length; i++) {
      let trimmed: string = lines[i].trim()
      if (trimmed === MANAGED_BEGIN) { managed = true; continue }
      if (trimmed === MANAGED_END) { managed = false; skipOwnedSeparator = true; continue }
      if (skipOwnedSeparator) {
        skipOwnedSeparator = false
        if (lines[i].length === 0) { continue }
      }
      if (!managed) { output.push(lines[i]) }
    }
    return output.join(content.includes('\r\n') ? '\r\n' : '\n')
  }

  private addPending(items: string[], alias: string): void {
    if (items.indexOf(alias) < 0) {
      items.push(alias)
    }
  }

  private removePending(items: string[], alias: string): void {
    let index: number = items.indexOf(alias)
    if (index >= 0) {
      items.splice(index, 1)
    }
  }

  private parseConfig(content: string): void {
    let lines: string[] = content.split('\n')
    for (let i = 0; i < lines.length; i++) {
      let line: string = this.stripInlineComment(lines[i].trim())
      if (line.length === 0 || line.startsWith('#')) {
        continue
      }
      let directive: string[] = this.parseDirective(line)
      if (directive[0].toLowerCase() === 'host') {
        let aliases: string[] = directive[1].split(/\s+/)
        for (let aliasIndex = 0; aliasIndex < aliases.length; aliasIndex++) {
          let alias: string = aliases[aliasIndex]
          if (alias.length > 0 && !alias.includes('*') && !alias.includes('?') &&
            !alias.startsWith('!') && !this.hasHostAlias(alias)) {
            let host: SshConfigHost = new SshConfigHost(alias)
            host.hostname = alias
            this.hosts.push(host)
          }
        }
      }
    }
    for (let hostIndex = 0; hostIndex < this.hosts.length; hostIndex++) {
      let resolved: SshConfigHost = this.resolveSourceHost(this.hosts[hostIndex].alias)
      this.hosts[hostIndex] = resolved
    }
  }

  private resolveSourceHost(alias: string): SshConfigHost {
    let resolved: SshConfigHost = new SshConfigHost(alias)
    let hostnameSet: boolean = false
    let portSet: boolean = false
    let userSet: boolean = false
    let identitySet: boolean = false
    let proxyJumpSet: boolean = false
    let connectTimeoutSet: boolean = false
    let serverAliveIntervalSet: boolean = false
    let serverAliveCountMaxSet: boolean = false
    let active: boolean = true
    let lines: string[] = this.sourceText.split(/\r?\n/)
    for (let i = 0; i < lines.length; i++) {
      let line: string = this.stripInlineComment(lines[i].trim())
      if (line.length === 0 || line.startsWith('#')) { continue }
      let directive: string[] = this.parseDirective(line)
      let name: string = directive[0]
      let lowerName: string = name.toLowerCase()
      let value: string = directive[1]
      if (lowerName === 'host') {
        if (value.length === 0) {
          if (resolved.errorMessage.length === 0) {
            resolved.errorMessage = this.configError(alias, name, i + 1, 'missing host pattern')
          }
          active = false
        } else {
          active = this.matchesHostPatterns(alias, value.split(/\s+/))
        }
        continue
      }
      if (lowerName === 'match') {
        if (resolved.errorMessage.length === 0) {
          resolved.errorMessage = this.configError(alias, name, i + 1, 'directive is not supported')
        }
        active = false
        continue
      }
      if (!active) { continue }
      if (lowerName === 'hostname' && !hostnameSet) {
        if (value.length === 0) {
          if (resolved.errorMessage.length === 0) {
            resolved.errorMessage = this.configError(alias, name, i + 1, 'missing value')
          }
          continue
        }
        resolved.hostname = value
        hostnameSet = true
      } else if (lowerName === 'port' && !portSet) {
        let port: number = parseInt(value, 10)
        if (/^\d+$/.test(value) && !isNaN(port) && port > 0 && port < 65536) {
          resolved.port = port
          portSet = true
        } else if (resolved.errorMessage.length === 0) {
          resolved.errorMessage = this.configError(alias, name, i + 1, 'expected port 1-65535')
        }
      } else if (lowerName === 'user' && !userSet) {
        if (value.length === 0) {
          if (resolved.errorMessage.length === 0) {
            resolved.errorMessage = this.configError(alias, name, i + 1, 'missing value')
          }
          continue
        }
        resolved.user = value
        userSet = true
      } else if (lowerName === 'identityfile' && !identitySet) {
        if (value.length === 0) {
          if (resolved.errorMessage.length === 0) {
            resolved.errorMessage = this.configError(alias, name, i + 1, 'missing value')
          }
          continue
        }
        resolved.identityFile = value
        identitySet = true
      } else if (lowerName === 'identityfile') {
        if (resolved.errorMessage.length === 0) {
          resolved.errorMessage = this.configError(alias, name, i + 1,
            'appears more than once for matching Host')
        }
      } else if (lowerName === 'proxyjump' && !proxyJumpSet) {
        if (value.length === 0) {
          if (resolved.errorMessage.length === 0) {
            resolved.errorMessage = this.configError(alias, name, i + 1, 'missing value')
          }
          continue
        }
        resolved.proxyJump = value
        proxyJumpSet = true
      } else if (lowerName === 'connecttimeout' && !connectTimeoutSet) {
        let seconds: number = parseInt(value, 10)
        if (/^\d+$/.test(value) && !isNaN(seconds) && seconds >= 1 &&
          seconds <= MAX_SSH_CONNECT_TIMEOUT_SECONDS) {
          resolved.connectTimeoutMs = seconds * 1000
          connectTimeoutSet = true
        } else if (resolved.errorMessage.length === 0) {
          resolved.errorMessage = this.configError(alias, name, i + 1,
            'expected whole seconds 1-' + MAX_SSH_CONNECT_TIMEOUT_SECONDS.toString())
        }
      } else if (lowerName === 'serveraliveinterval' && !serverAliveIntervalSet) {
        let seconds: number = parseInt(value, 10)
        if (/^\d+$/.test(value) && !isNaN(seconds) && seconds >= 0 &&
          seconds <= MAX_SSH_SERVER_ALIVE_INTERVAL_SECONDS) {
          resolved.serverAliveIntervalSeconds = seconds
          serverAliveIntervalSet = true
        } else if (resolved.errorMessage.length === 0) {
          resolved.errorMessage = this.configError(alias, name, i + 1,
            'expected whole seconds 0-' + MAX_SSH_SERVER_ALIVE_INTERVAL_SECONDS.toString())
        }
      } else if (lowerName === 'serveralivecountmax' && !serverAliveCountMaxSet) {
        let count: number = parseInt(value, 10)
        if (/^\d+$/.test(value) && !isNaN(count) && count >= 1 &&
          count <= MAX_SSH_SERVER_ALIVE_COUNT_MAX) {
          resolved.serverAliveCountMax = count
          serverAliveCountMaxSet = true
        } else if (resolved.errorMessage.length === 0) {
          resolved.errorMessage = this.configError(alias, name, i + 1,
            'expected count 1-' + MAX_SSH_SERVER_ALIVE_COUNT_MAX.toString())
        }
      } else if (lowerName !== 'hostname' && lowerName !== 'port' && lowerName !== 'user' &&
        lowerName !== 'identityfile' && lowerName !== 'proxyjump' && lowerName !== 'connecttimeout' &&
        lowerName !== 'serveraliveinterval' && lowerName !== 'serveralivecountmax' &&
        resolved.errorMessage.length === 0) {
        resolved.errorMessage = this.configError(alias, name, i + 1, 'directive is not supported')
      }
    }
    if (!hostnameSet) { resolved.hostname = alias }
    return resolved
  }

  private matchesHostPatterns(alias: string, patterns: string[]): boolean {
    let positive: boolean = false
    let lowerAlias: string = alias.toLowerCase()
    for (let i = 0; i < patterns.length; i++) {
      let pattern: string = patterns[i].toLowerCase()
      let negated: boolean = pattern.startsWith('!')
      if (negated) { pattern = pattern.substring(1) }
      if (this.globMatches(lowerAlias, pattern)) {
        if (negated) { return false }
        positive = true
      }
    }
    return positive
  }

  private globMatches(value: string, pattern: string): boolean {
    let valueIndex: number = 0
    let patternIndex: number = 0
    let starIndex: number = -1
    let retryIndex: number = -1
    while (valueIndex < value.length) {
      if (patternIndex < pattern.length && (pattern[patternIndex] === '?' ||
        pattern[patternIndex] === value[valueIndex])) {
        valueIndex++
        patternIndex++
      } else if (patternIndex < pattern.length && pattern[patternIndex] === '*') {
        starIndex = patternIndex
        retryIndex = valueIndex
        patternIndex++
      } else if (starIndex >= 0) {
        patternIndex = starIndex + 1
        retryIndex++
        valueIndex = retryIndex
      } else {
        return false
      }
    }
    while (patternIndex < pattern.length && pattern[patternIndex] === '*') { patternIndex++ }
    return patternIndex === pattern.length
  }

  private hasHostAlias(alias: string): boolean {
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hosts[i].alias === alias) { return true }
    }
    return false
  }

  private parseDirective(line: string): string[] {
    let separator: number = line.search(/[\s=]/)
    if (separator < 0) { return [line, ''] }
    let name: string = line.substring(0, separator)
    let value: string = line.substring(separator).trim()
    if (value.startsWith('=')) { value = value.substring(1).trim() }
    return [name, value]
  }

  private configError(alias: string, directive: string, line: number, reason: string): string {
    return 'SSH config error for ' + alias + ' at line ' + line.toString() + ': ' +
      directive + ' ' + reason +
      '. Supported directives: Host, HostName, User, Port, IdentityFile, ProxyJump, ConnectTimeout, ' +
      'ServerAliveInterval, ServerAliveCountMax.'
  }

  private stripInlineComment(line: string): string {
    let commentIndex: number = line.indexOf('#')
    if (commentIndex >= 0) {
      return line.substring(0, commentIndex).trim()
    }
    return line
  }
}

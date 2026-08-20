import { FileUtils } from '../../common/utils/FileUtils'
import { common } from '@kit.AbilityKit'
import { DurableStateManager } from '../persistence/DurableStateManager'
import {
  DEFAULT_SSH_CONNECT_TIMEOUT_MS,
  MAX_SSH_CONNECT_TIMEOUT_SECONDS
} from '../../common/types/SshTypes'

const MANAGED_BEGIN: string = '# >>> LeanTTY managed hosts >>>'
const MANAGED_END: string = '# <<< LeanTTY managed hosts <<<'

export class SshConfigHost {
  alias: string
  hostname: string
  port: number
  user: string
  identityFile: string
  proxyJump: string
  connectTimeoutMs: number
  errorMessage: string

  constructor(alias: string) {
    this.alias = alias
    this.hostname = ''
    this.port = 22
    this.user = ''
    this.identityFile = ''
    this.proxyJump = ''
    this.connectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
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

  isManagedHost(alias: string): boolean {
    return this.managedAliases.indexOf(alias) >= 0
  }

  resolveHost(alias: string): SshConfigHost {
    return this.resolveSourceHost(alias)
  }

  addAlias(alias: string, hostname: string, port: number, user: string, proxyJump: string | null = null,
    connectTimeoutMs: number | null = null): void {
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
      if (proxyJump !== null) { existing.proxyJump = proxyJump }
      if (connectTimeoutMs !== null) { existing.connectTimeoutMs = connectTimeoutMs }
    } else {
      let host: SshConfigHost = new SshConfigHost(alias)
      host.hostname = hostname
      host.port = port
      host.user = user
      if (proxyJump !== null) { host.proxyJump = proxyJump }
      if (connectTimeoutMs !== null) { host.connectTimeoutMs = connectTimeoutMs }
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
    let unmanaged: string = this.removeManagedRegion(this.sourceText).trim()
    if (this.managedAliases.length === 0) { return unmanaged.length > 0 ? unmanaged + '\n' : '' }
    let newline: string = this.sourceText.includes('\r\n') ? '\r\n' : '\n'
    let managed: string = MANAGED_BEGIN + newline
    for (let i = 0; i < this.managedAliases.length; i++) {
      let host: SshConfigHost | null = this.findHost(this.managedAliases[i])
      if (host !== null) { managed = this.appendHost(managed, host) }
    }
    managed += MANAGED_END + newline
    if (unmanaged.length > 0) { managed += newline + unmanaged + newline }
    return managed
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
    return text + newline
  }

  private removeAliasFromText(content: string, alias: string): string {
    let newline: string = content.includes('\r\n') ? '\r\n' : '\n'
    let lines: string[] = content.split(/\r?\n/)
    let output: string[] = []
    let index: number = 0
    while (index < lines.length) {
      let header: string = this.stripInlineComment(lines[index].trim())
      if (!header.toLowerCase().startsWith('host ')) {
        output.push(lines[index])
        index++
        continue
      }
      let aliases: string[] = header.substring(5).trim().split(/\s+/)
      let aliasIndex: number = aliases.indexOf(alias)
      if (aliasIndex < 0) {
        output.push(lines[index])
        index++
        continue
      }
      let blockEnd: number = index + 1
      while (blockEnd < lines.length) {
        let candidate: string = this.stripInlineComment(lines[blockEnd].trim()).toLowerCase()
        if (candidate.startsWith('host ') || candidate.startsWith('match ')) {
          break
        }
        blockEnd++
      }
      if (aliases.length > 1) {
        aliases.splice(aliasIndex, 1)
        let commentIndex: number = lines[index].indexOf('#')
        let comment: string = commentIndex >= 0 ? ' ' + lines[index].substring(commentIndex).trim() : ''
        output.push('Host ' + aliases.join(' ') + comment)
        for (let lineIndex = index + 1; lineIndex < blockEnd; lineIndex++) {
          output.push(lines[lineIndex])
        }
      }
      index = blockEnd
    }
    return output.join(newline)
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
    for (let i = 0; i < lines.length; i++) {
      let trimmed: string = lines[i].trim()
      if (trimmed === MANAGED_BEGIN) { managed = true; continue }
      if (trimmed === MANAGED_END) { managed = false; continue }
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
      } else if (lowerName !== 'hostname' && lowerName !== 'port' && lowerName !== 'user' &&
        lowerName !== 'identityfile' && lowerName !== 'proxyjump' && lowerName !== 'connecttimeout' &&
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
      '. Supported directives: Host, HostName, User, Port, IdentityFile, ProxyJump, ConnectTimeout.'
  }

  private stripInlineComment(line: string): string {
    let commentIndex: number = line.indexOf(' #')
    if (commentIndex >= 0) {
      return line.substring(0, commentIndex).trim()
    }
    return line
  }
}

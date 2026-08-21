import { SshConfig, SshConfigHost } from '../ssh/SshConfig'
import { KeyAlgorithm } from '../../common/types/SshKeyTypes'
import { TerminalTextPolicy } from '../../common/security/TerminalTextPolicy'
import {
  DEFAULT_SSH_CONNECT_TIMEOUT_MS,
  MAX_SSH_CONNECT_TIMEOUT_SECONDS,
  DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS,
  DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX,
  MAX_SSH_SERVER_ALIVE_INTERVAL_SECONDS,
  MAX_SSH_SERVER_ALIVE_COUNT_MAX
} from '../../common/types/SshTypes'

export class CommandParseResult {
  isValid: boolean
  host: string
  displayHost: string
  port: number
  username: string
  isAlias: boolean
  identityFile: string
  jumpHost: string
  jumpDisplayHost: string
  jumpPort: number
  jumpUsername: string
  jumpIdentityFile: string
  jumpConnectTimeoutMs: number
  jumpServerAliveIntervalSeconds: number
  jumpServerAliveCountMax: number
  connectTimeoutMs: number
  serverAliveIntervalSeconds: number
  serverAliveCountMax: number
  verbose: boolean
  errorMessage: string

  constructor() {
    this.isValid = false
    this.host = ''
    this.displayHost = ''
    this.port = 22
    this.username = ''
    this.isAlias = false
    this.identityFile = ''
    this.jumpHost = ''
    this.jumpDisplayHost = ''
    this.jumpPort = 22
    this.jumpUsername = ''
    this.jumpIdentityFile = ''
    this.jumpConnectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
    this.jumpServerAliveIntervalSeconds = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
    this.jumpServerAliveCountMax = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
    this.connectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
    this.serverAliveIntervalSeconds = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
    this.serverAliveCountMax = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
    this.verbose = false
    this.errorMessage = ''
  }
}

export enum KeyCommandKind {
  KEYGEN = 0,
  KEYS = 1,
  KEYIMPORT = 2,
  KEYPUB = 3,
  KEYRM = 4,
  HELP = 5,
  KEYPUSH = 6,
  ALIAS_ADD = 7,
  ALIAS_RM = 8,
  ALIAS_LIST = 9,
  EXIT = 10,
  HOST_SET = 11,
  SSH_CONFIG = 12,
  KEYINFO = 13,
  KEYEXPORT = 14,
  HOST_KEY_REMOVE = 15,
  KEY_PASSPHRASE_CHANGE = 16,
  HOST_KEY_FIND = 17
}

export class KeyCommandResult {
  kind: KeyCommandKind
  algorithm: KeyAlgorithm
  keyName: string
  destinationName: string
  sourcePath: string
  sshHost: string
  sshPort: number
  sshUser: string
  sshJump: string
  sshConnectTimeoutMs: number
  sshServerAliveIntervalSeconds: number
  sshServerAliveCountMax: number
  errorMessage: string
  legacySyntax: boolean

  constructor() {
    this.kind = KeyCommandKind.KEYS
    this.algorithm = KeyAlgorithm.ED25519
    this.keyName = ''
    this.destinationName = ''
    this.sourcePath = ''
    this.sshHost = ''
    this.sshPort = 22
    this.sshUser = ''
    this.sshJump = ''
    this.sshConnectTimeoutMs = -1
    this.sshServerAliveIntervalSeconds = -1
    this.sshServerAliveCountMax = -1
    this.errorMessage = ''
    this.legacySyntax = false
  }
}

export enum TransferDirection {
  PUT = 0,
  GET = 1,
  SCP_HINT = 2
}

export class TransferCommandResult {
  direction: TransferDirection
  isValid: boolean
  host: string
  port: number
  username: string
  identityFile: string
  connectTimeoutMs: number
  serverAliveIntervalSeconds: number
  serverAliveCountMax: number
  localPath: string
  remotePath: string
  automaticLocalName: boolean
  localTargetDirectory: boolean
  remoteTargetDirectory: boolean
  errorMessage: string

  constructor(direction: TransferDirection) {
    this.direction = direction
    this.isValid = false
    this.host = ''
    this.port = 22
    this.username = ''
    this.identityFile = ''
    this.connectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
    this.serverAliveIntervalSeconds = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
    this.serverAliveCountMax = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
    this.localPath = ''
    this.remotePath = ''
    this.automaticLocalName = false
    this.localTargetDirectory = false
    this.remoteTargetDirectory = false
    this.errorMessage = ''
  }
}

export class CommandParser {
  static requiresSshEnvironment(input: string): boolean {
    let trimmed: string = input.trim()
    let words: string[] = trimmed.length > 0 ? trimmed.split(/\s+/) : []
    if (trimmed.length === 0 || trimmed === '?' || trimmed === '？' ||
      trimmed === '-h' || trimmed === '--help' || words[0] === 'help' ||
      (words.length >= 2 && words.length <= 3 && words[words.length - 1] === '--help')) {
      return false
    }
    if (words[0] === 'exit' || words[0] === 'scp') {
      return false
    }
    // Default to the gate so a future command cannot accidentally read an
    // unprepared SSH projection. Only explicit, stable local commands bypass it.
    return true
  }

  static parseInput(
    input: string,
    sshConfig: SshConfig
  ): CommandParseResult | KeyCommandResult | TransferCommandResult | null {
    let trimmed: string = input.trim()
    let words: string[] = trimmed.length > 0 ? trimmed.split(/\s+/) : []
    if (trimmed === '?' || trimmed === '？' || trimmed === '-h' || trimmed === '--help' || words[0] === 'help') {
      let result: KeyCommandResult = new KeyCommandResult()
      result.kind = KeyCommandKind.HELP
      if (words.length > 2) { result.errorMessage = 'Usage: help [<command>]'; return result }
      if (words.length === 2) { result.keyName = words[1] }
      return result
    }
    if (words[0] === 'exit') {
      let result: KeyCommandResult = new KeyCommandResult()
      result.kind = KeyCommandKind.EXIT
      if (words.length !== 1) { result.errorMessage = 'Usage: exit' }
      return result
    }
    if (words.length >= 2 && words.length <= 3 && words[words.length - 1] === '--help') {
      let result: KeyCommandResult = new KeyCommandResult()
      result.kind = KeyCommandKind.HELP
      result.keyName = words[0]
      return result
    }
    if (words[0] === 'ssh' && words[1] === '-G') {
      let result: KeyCommandResult = new KeyCommandResult()
      result.kind = KeyCommandKind.SSH_CONFIG
      if (words.length === 3) {
        result.keyName = words[2]
      } else if (words.length === 5 && words[2] === '-J') {
        result.sshJump = words[3]
        result.keyName = words[4]
      } else {
        result.errorMessage = 'Usage: ssh -G [-J <jump-spec>] <host-name>'
      }
      return result
    }
    if (words[0] === 'ssh-keygen') {
      return CommandParser.parseSshKeygen(trimmed)
    }
    if (words[0] === 'ssh-copy-id') {
      return CommandParser.parseSshCopyId(trimmed)
    }
    if (words[0] === 'put' || words[0] === 'get') {
      return CommandParser.parseTransfer(trimmed, sshConfig)
    }
    if (words[0] === 'scp') {
      return new TransferCommandResult(TransferDirection.SCP_HINT)
    }
    if (trimmed.startsWith('ssh ') || trimmed.startsWith('ssh@') || trimmed.length === 0) {
      return CommandParser.parseCommand(trimmed, sshConfig)
    }

    if (trimmed === 'key list' || trimmed === 'keys') {
      let result: KeyCommandResult = new KeyCommandResult()
      result.kind = KeyCommandKind.KEYS
      return result
    }
    if (words[0] === 'key' && words[1] === 'show') {
      return CommandParser.parseKeyShow(trimmed)
    }
    if (words[0] === 'key' && words[1] === 'rm') {
      return CommandParser.parseKeyRm(trimmed)
    }
    if (words[0] === 'key' && words[1] === 'import') {
      return CommandParser.parseKeyImport(trimmed)
    }
    if (words[0] === 'key' && words[1] === 'export') {
      return CommandParser.parseKeyExport(trimmed)
    }
    if (words[0] === 'key' || words[0] === 'keys') {
      let result: KeyCommandResult = new KeyCommandResult()
      result.kind = KeyCommandKind.KEYS
      result.errorMessage = 'Usage: key list | key import <path> [<key-name>] | ' +
        'key export <key-name> [<file-name>] | key rm <key-name>'
      return result
    }

    if ((words[0] === 'host' || words[0] === 'alias') && (words[1] === 'add' || words[1] === 'set')) {
      let result: KeyCommandResult = CommandParser.parseAliasAdd(trimmed)
      if (words[0] === 'host' && words[1] === 'set') { result.kind = KeyCommandKind.HOST_SET }
      result.legacySyntax = words[0] === 'alias'
      return result
    }
    if ((words[0] === 'host' || words[0] === 'alias') && words[1] === 'rm') {
      let result: KeyCommandResult = CommandParser.parseAliasRm(trimmed)
      result.legacySyntax = words[0] === 'alias'
      return result
    }
    if (trimmed === 'host list' || trimmed === 'host' || trimmed === 'alias list' || trimmed === 'alias') {
      let result: KeyCommandResult = new KeyCommandResult()
      result.kind = KeyCommandKind.ALIAS_LIST
      result.legacySyntax = words[0] === 'alias'
      return result
    }
    if (words[0] === 'host' || words[0] === 'alias') {
      let result: KeyCommandResult = new KeyCommandResult()
      result.kind = KeyCommandKind.ALIAS_LIST
      result.legacySyntax = words[0] === 'alias'
      result.errorMessage = 'Usage: host add|set <host-name> <user>@<host>[:<port>] [-J <jump>] ' +
        '[--connect-timeout <1-300|default>] [--server-alive-interval <0-3600|default>] ' +
        '[--server-alive-count-max <1-100|default>] | ' +
        'host rm <host-name> | host list'
      return result
    }

    if (trimmed === 'ssh') {
      return CommandParser.parseCommand(trimmed, sshConfig)
    }
    return null
  }

  static parseCommand(input: string, sshConfig: SshConfig): CommandParseResult {
    let result: CommandParseResult = new CommandParseResult()
    let trimmed: string = input.trim()
    if (trimmed.length === 0) {
      result.errorMessage = 'Usage: ssh <user>@<host>'
      return result
    }
    let argText: string = trimmed
    if (trimmed.startsWith('ssh ')) {
      argText = trimmed.substring(4).trim()
    }
    if (argText.length === 0) {
      result.errorMessage = 'Usage: ssh <user>@<host> or ssh <host-name>'
      return result
    }

    let args: string[] = argText.split(/\s+/)
    let target: string = ''
    let explicitPort: number = 0
    let identitySpecified: boolean = false
    let explicitJump: string = ''
    let jumpSpecified: boolean = false
    let verboseSpecified: boolean = false
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '-p') {
        if (i + 1 >= args.length) { result.errorMessage = 'Missing port after -p'; return result }
        if (explicitPort > 0) { result.errorMessage = 'Duplicate SSH option: -p'; return result }
        explicitPort = parseInt(args[i + 1], 10)
        if (!/^\d+$/.test(args[i + 1]) || isNaN(explicitPort) || explicitPort < 1 || explicitPort > 65535) {
          result.errorMessage = 'Port must be between 1 and 65535'; return result
        }
        i++
      } else if (args[i] === '-i') {
        if (i + 1 >= args.length) { result.errorMessage = 'Missing identity file after -i'; return result }
        if (identitySpecified) { result.errorMessage = 'Duplicate SSH option: -i'; return result }
        result.identityFile = args[i + 1]
        identitySpecified = true
        i++
      } else if (args[i] === '-J') {
        if (i + 1 >= args.length) { result.errorMessage = 'Missing jump host after -J'; return result }
        if (jumpSpecified) { result.errorMessage = 'Duplicate SSH option: -J'; return result }
        explicitJump = args[i + 1]
        jumpSpecified = true
        i++
      } else if (args[i] === '-v') {
        if (verboseSpecified) { result.errorMessage = 'Duplicate SSH option: -v'; return result }
        result.verbose = true
        verboseSpecified = true
      } else if (args[i].startsWith('-')) {
        result.errorMessage = 'Unsupported SSH option: ' + args[i]; return result
      } else if (target.length === 0) {
        target = args[i]
      } else {
        result.errorMessage = 'Unexpected SSH argument: ' + args[i]; return result
      }
    }
    if (target.length === 0) { result.errorMessage = 'Missing SSH host'; return result }

    let host: SshConfigHost | null = sshConfig.findHost(target)
    if (host !== null) {
      if (host.errorMessage.length > 0) { result.errorMessage = host.errorMessage; return result }
      if (host.user.length === 0) { result.errorMessage = 'SSH alias must define User: ' + target; return result }
      result.isValid = true
      result.host = host.hostname
      result.displayHost = target
      result.port = explicitPort > 0 ? explicitPort : host.port
      result.username = host.user
      if (result.identityFile.length === 0) { result.identityFile = host.identityFile }
      result.connectTimeoutMs = host.connectTimeoutMs
      result.serverAliveIntervalSeconds = host.serverAliveIntervalSeconds
      result.serverAliveCountMax = host.serverAliveCountMax
      result.isAlias = true
      CommandParser.applyProxyJump(jumpSpecified ? explicitJump : host.proxyJump, sshConfig, result)
      if (result.errorMessage.length > 0) { result.isValid = false }
      return result
    }

    let atIdx: number = target.lastIndexOf('@')
    if (atIdx <= 0) { result.errorMessage = 'Username required'; return result }
    result.username = target.substring(0, atIdx)
    let hostPort: string = target.substring(atIdx + 1)
    CommandParser.parseHostPort(hostPort, result)
    if (result.errorMessage.length > 0) { return result }
    if (explicitPort > 0) { result.port = explicitPort }
    result.isValid = result.username.length > 0 && result.host.length > 0
    if (result.isValid) { result.displayHost = result.host }
    if (!result.isValid) { result.errorMessage = 'Invalid SSH target' }
    if (result.isValid) {
      CommandParser.applyProxyJump(jumpSpecified ? explicitJump : '', sshConfig, result)
      if (result.errorMessage.length > 0) { result.isValid = false }
    }
    return result
  }

  private static applyProxyJump(spec: string, sshConfig: SshConfig, result: CommandParseResult): void {
    let trimmed: string = spec.trim()
    if (trimmed.length === 0 || trimmed.toLowerCase() === 'none') { return }
    if (trimmed.includes(',') || trimmed.includes('://') || trimmed.includes('%') ||
      trimmed.includes('$') || /\s/.test(trimmed)) {
      result.errorMessage = 'Unsupported ProxyJump expression: only one [user@]host[:port] is supported'
      return
    }

    let explicitUser: string = ''
    let hostPort: string = trimmed
    let atIndex: number = trimmed.lastIndexOf('@')
    if (atIndex >= 0) {
      if (atIndex === 0 || atIndex === trimmed.length - 1 || trimmed.substring(0, atIndex).includes('@')) {
        result.errorMessage = 'Invalid ProxyJump user or host'
        return
      }
      explicitUser = trimmed.substring(0, atIndex)
      hostPort = trimmed.substring(atIndex + 1)
    }

    let parsed: CommandParseResult = new CommandParseResult()
    CommandParser.parseHostPort(hostPort, parsed)
    if (parsed.errorMessage.length > 0) {
      result.errorMessage = 'ProxyJump: ' + parsed.errorMessage
      return
    }
    if (parsed.host.length === 0) {
      result.errorMessage = 'ProxyJump host must not be empty'
      return
    }

    let explicitJumpPort: boolean = CommandParser.hasExplicitPort(hostPort)
    let jumpAlias: SshConfigHost | null = sshConfig.findHost(parsed.host)
    let jumpHost: string = parsed.host
    let jumpPort: number = parsed.port
    let jumpUser: string = explicitUser
    let jumpIdentity: string = ''
    let jumpDisplayHost: string = parsed.host
    if (jumpAlias !== null) {
      if (jumpAlias.errorMessage.length > 0) {
        result.errorMessage = jumpAlias.errorMessage
        return
      }
      if (jumpAlias.proxyJump.length > 0 && jumpAlias.proxyJump.toLowerCase() !== 'none') {
        result.errorMessage = 'ProxyJump chain is not supported for jump host: ' + parsed.host
        return
      }
      jumpHost = jumpAlias.hostname
      jumpPort = explicitJumpPort ? parsed.port : jumpAlias.port
      jumpUser = explicitUser.length > 0 ? explicitUser : jumpAlias.user
      jumpIdentity = jumpAlias.identityFile
      result.jumpConnectTimeoutMs = jumpAlias.connectTimeoutMs
      result.jumpServerAliveIntervalSeconds = jumpAlias.serverAliveIntervalSeconds
      result.jumpServerAliveCountMax = jumpAlias.serverAliveCountMax
    }
    if (jumpUser.length === 0) {
      result.errorMessage = 'ProxyJump host must define User: ' + jumpDisplayHost
      return
    }
    if (jumpHost.toLowerCase() === result.host.toLowerCase() && jumpPort === result.port) {
      result.errorMessage = 'ProxyJump cannot use the target endpoint itself: ' + jumpDisplayHost
      return
    }

    result.jumpHost = jumpHost
    result.jumpDisplayHost = jumpDisplayHost
    result.jumpPort = jumpPort
    result.jumpUsername = jumpUser
    result.jumpIdentityFile = jumpIdentity
  }

  private static hasExplicitPort(hostPort: string): boolean {
    if (hostPort.startsWith('[')) {
      let closingBracket: number = hostPort.indexOf(']')
      return closingBracket > 0 && closingBracket + 1 < hostPort.length
    }
    let firstColon: number = hostPort.indexOf(':')
    return firstColon > 0 && firstColon === hostPort.lastIndexOf(':')
  }

  static parseTransfer(input: string, sshConfig: SshConfig): TransferCommandResult {
    let tokenized: string[] | string = CommandParser.tokenizeTransfer(input)
    let command: string = input.trim().startsWith('get') ? 'get' : 'put'
    let direction: TransferDirection = command === 'get' ? TransferDirection.GET : TransferDirection.PUT
    let result: TransferCommandResult = new TransferCommandResult(direction)
    let usage: string = direction === TransferDirection.PUT ?
      'Usage: put [-p port] [-i identity] [--] <local-relative-file> <host>:<remote-path>' :
      'Usage: get [-p port] [-i identity] [--] <host>:<remote-file> [local-relative-path]'
    if (typeof tokenized === 'string') {
      result.errorMessage = command + ': ' + tokenized
      return result
    }
    let args: string[] = tokenized
    if (args.length === 0 || args[0] !== command) {
      result.errorMessage = usage
      return result
    }
    let portText: string = ''
    let identity: string = ''
    let operands: string[] = []
    let optionsEnded: boolean = false
    for (let index: number = 1; index < args.length; index++) {
      let argument: string = args[index]
      if (!optionsEnded && argument === '--') {
        optionsEnded = true
      } else if (!optionsEnded && (argument === '-p' || argument === '-i')) {
        if (index + 1 >= args.length) {
          result.errorMessage = command + ': missing value after ' + argument
          return result
        }
        let value: string = args[index + 1]
        if (argument === '-p') {
          if (portText.length > 0) {
            result.errorMessage = command + ': duplicate option -p'
            return result
          }
          let port: number = parseInt(value, 10)
          if (!/^\d+$/.test(value) || isNaN(port) || port < 1 || port > 65535) {
            result.errorMessage = command + ': port must be between 1 and 65535'
            return result
          }
          portText = value
        } else {
          if (identity.length > 0) {
            result.errorMessage = command + ': duplicate option -i'
            return result
          }
          if (value.length === 0) {
            result.errorMessage = command + ': identity must not be empty'
            return result
          }
          identity = value
        }
        index++
      } else if (!optionsEnded && argument.startsWith('-')) {
        result.errorMessage = command + ': unsupported option ' + argument
        return result
      } else {
        operands.push(argument)
      }
    }
    let expectedMinimum: number = direction === TransferDirection.PUT ? 2 : 1
    let expectedMaximum: number = 2
    if (operands.length < expectedMinimum || operands.length > expectedMaximum) {
      result.errorMessage = usage
      return result
    }
    let remoteOperand: string = direction === TransferDirection.PUT ? operands[1] : operands[0]
    let localOperand: string = direction === TransferDirection.PUT ? operands[0] :
      (operands.length === 2 ? operands[1] : '')
    let localDirectoryRequested: boolean = direction === TransferDirection.GET && localOperand.endsWith('/')
    if (localOperand.startsWith('./')) { localOperand = localOperand.substring(2) }
    let remoteParts: string[] | string = CommandParser.splitRemoteOperand(remoteOperand)
    if (typeof remoteParts === 'string') {
      result.errorMessage = command + ': ' + remoteParts
      return result
    }
    result.remotePath = remoteParts[1]
    result.remoteTargetDirectory = direction === TransferDirection.PUT &&
      (result.remotePath.length === 0 || result.remotePath.endsWith('/'))
    if (!CommandParser.validRemotePath(result.remotePath, result.remoteTargetDirectory)) {
      result.errorMessage = direction === TransferDirection.GET ?
        command + ': remote source must name one safe file and must not end with /' :
        command + ': remote target must name a safe file or end with / for a directory'
      return result
    }
    result.localTargetDirectory = localDirectoryRequested
    if ((direction === TransferDirection.PUT || localOperand.length > 0) &&
      !CommandParser.validDownloadsRelativePath(localOperand, result.localTargetDirectory)) {
      result.errorMessage = command + ': local path must stay within Downloads and use a relative file path'
      return result
    }
    result.localPath = localOperand
    result.automaticLocalName = direction === TransferDirection.GET &&
      (localOperand.length === 0 || result.localTargetDirectory)
    if (direction === TransferDirection.PUT && result.remoteTargetDirectory) {
      let slash: number = localOperand.lastIndexOf('/')
      let basename: string = localOperand.substring(slash + 1)
      result.remotePath = (result.remotePath.length === 0 ? './' : result.remotePath) + basename
      if (!CommandParser.validRemotePath(result.remotePath, false)) {
        result.errorMessage = command + ': derived remote file path is too long or unsafe'
        return result
      }
    }
    let sshCommand: string = 'ssh '
    if (portText.length > 0) { sshCommand += '-p ' + portText + ' ' }
    if (identity.length > 0) { sshCommand += '-i ' + identity + ' ' }
    sshCommand += remoteParts[0]
    let connection: CommandParseResult = CommandParser.parseCommand(sshCommand, sshConfig)
    if (!connection.isValid) {
      result.errorMessage = command + ': ' + connection.errorMessage
      return result
    }
    result.host = connection.host
    result.port = connection.port
    result.username = connection.username
    result.identityFile = connection.identityFile
    result.connectTimeoutMs = connection.connectTimeoutMs
    result.serverAliveIntervalSeconds = connection.serverAliveIntervalSeconds
    result.serverAliveCountMax = connection.serverAliveCountMax
    result.isValid = true
    return result
  }

  private static tokenizeTransfer(input: string): string[] | string {
    let tokens: string[] = []
    let current: string = ''
    let quote: string = ''
    let escaping: boolean = false
    let tokenStarted: boolean = false
    for (let index: number = 0; index < input.length; index++) {
      let character: string = input[index]
      if (escaping) {
        current += character
        escaping = false
        tokenStarted = true
      } else if (character === '\\' && quote !== "'") {
        escaping = true
        tokenStarted = true
      } else if (quote.length > 0) {
        if (character === quote) { quote = '' } else { current += character }
        tokenStarted = true
      } else if (character === '"' || character === "'") {
        quote = character
        tokenStarted = true
      } else if (/\s/.test(character)) {
        if (tokenStarted) {
          tokens.push(current)
          current = ''
          tokenStarted = false
        }
      } else {
        current += character
        tokenStarted = true
      }
    }
    if (escaping) { return 'trailing escape is not allowed' }
    if (quote.length > 0) { return 'unterminated quote' }
    if (tokenStarted) { tokens.push(current) }
    return tokens
  }

  private static splitRemoteOperand(value: string): string[] | string {
    let separator: number = -1
    let bracketDepth: number = 0
    for (let index: number = 0; index < value.length; index++) {
      if (value[index] === '[') { bracketDepth++ }
      else if (value[index] === ']') { bracketDepth-- }
      else if (value[index] === ':' && bracketDepth === 0) { separator = index; break }
      if (bracketDepth < 0 || bracketDepth > 1) { return 'invalid bracketed remote target' }
    }
    if (bracketDepth !== 0 || separator <= 0) {
      return 'remote target must use <host>:<remote-path>'
    }
    return [value.substring(0, separator), value.substring(separator + 1)]
  }

  private static validDownloadsRelativePath(path: string, directoryTarget: boolean): boolean {
    if (path.length === 0 || path.startsWith('/') || path.startsWith('\\') ||
      CommandParser.utf8Length(path) > 4096 ||
      /^[A-Za-z]:/.test(path) || path.includes('\\') || CommandParser.hasUnsafePathCharacter(path) ||
      (path.endsWith('/') && !directoryTarget)) {
      return false
    }
    let normalized: string = directoryTarget ? path.substring(0, path.length - 1) : path
    if (normalized.length === 0) { return false }
    let components: string[] = normalized.split('/')
    for (let index: number = 0; index < components.length; index++) {
      if (components[index].length === 0 || components[index] === '.' || components[index] === '..' ||
        CommandParser.utf8Length(components[index]) > 255) {
        return false
      }
    }
    return true
  }

  private static validRemotePath(path: string, directoryTarget: boolean): boolean {
    if (path.length > 4096 || CommandParser.hasUnsafePathCharacter(path)) {
      return false
    }
    if (directoryTarget) {
      return path.length === 0 || path.endsWith('/')
    }
    if (path.length === 0 || path.endsWith('/')) { return false }
    let normalized: string = path.replace(/\\/g, '/')
    let basename: string = normalized.substring(normalized.lastIndexOf('/') + 1)
    return basename.length > 0 && basename !== '.' && basename !== '..'
  }

  private static hasUnsafePathCharacter(path: string): boolean {
    return !TerminalTextPolicy.isSafe(path)
  }

  private static utf8Length(value: string): number {
    let length: number = 0
    for (let index: number = 0; index < value.length; index++) {
      let code: number = value.charCodeAt(index)
      if (code <= 0x7F) { length++ }
      else if (code <= 0x7FF) { length += 2 }
      else if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length &&
        value.charCodeAt(index + 1) >= 0xDC00 && value.charCodeAt(index + 1) <= 0xDFFF) {
        length += 4
        index++
      } else { length += 3 }
    }
    return length
  }

  private static parseHostPort(hostPort: string, result: CommandParseResult): void {
    if (hostPort.startsWith('[')) {
      let closingBracket: number = hostPort.indexOf(']')
      if (closingBracket <= 1) { result.errorMessage = 'Invalid bracketed IPv6 hostname'; return }
      result.host = hostPort.substring(1, closingBracket)
      if (closingBracket + 1 < hostPort.length) {
        if (hostPort[closingBracket + 1] !== ':') {
          result.errorMessage = 'Unexpected text after bracketed SSH host'; return
        }
        let portText: string = hostPort.substring(closingBracket + 2)
        let p: number = parseInt(portText, 10)
        if (!/^\d+$/.test(portText) || isNaN(p) || p < 1 || p > 65535) {
          result.errorMessage = 'Port 1-65535'; return
        }
        result.port = p
      }
    } else {
      let firstColon: number = hostPort.indexOf(':')
      let lastColon: number = hostPort.lastIndexOf(':')
      if (firstColon > 0 && firstColon === lastColon) {
        result.host = hostPort.substring(0, firstColon)
        let portText: string = hostPort.substring(firstColon + 1)
        let p: number = parseInt(portText, 10)
        if (!/^\d+$/.test(portText) || isNaN(p) || p < 1 || p > 65535) {
          result.errorMessage = 'Port 1-65535'; return
        }
        result.port = p
      } else {
        result.host = hostPort
      }
    }
  }

  static parseSshKeygen(input: string): KeyCommandResult {
    let result: KeyCommandResult = new KeyCommandResult()
    result.kind = KeyCommandKind.KEYGEN
    let parts: string[] = input.split(/\s+/)
    if (parts.length >= 2 && (parts[1] === '-F' || parts[1] === '-R')) {
      let mode: string = parts[1]
      result.kind = mode === '-F' ? KeyCommandKind.HOST_KEY_FIND : KeyCommandKind.HOST_KEY_REMOVE
      if (parts.length !== 3) {
        result.errorMessage = 'Usage: ssh-keygen ' + mode + ' <host> or ssh-keygen ' + mode + ' [<host>]:<port>'
        return result
      }
      CommandParser.parseKnownHostTarget(parts[2], mode, result)
      return result
    }
    let publicMode: boolean = false
    let fingerprintMode: boolean = false
    let passphraseMode: boolean = false
    let keyTypeSpecified: boolean = false
    let commentSpecified: boolean = false
    let keyFileCount: number = 0
    let unexpectedArgument: string = ''
    let i: number = 1
    while (i < parts.length) {
      if (parts[i] === '-t') {
        keyTypeSpecified = true
        if (i + 1 >= parts.length) { result.errorMessage = 'ssh-keygen: missing type after -t'; return result }
        let keyType: string = parts[i + 1].toLowerCase()
        if (keyType === 'ed25519') { result.algorithm = KeyAlgorithm.ED25519 }
        else if (keyType === 'rsa' || keyType === 'rsa4096' || keyType === 'rsa-4096') {
          result.algorithm = KeyAlgorithm.RSA4096
        } else { result.errorMessage = 'ssh-keygen: unsupported key type ' + parts[i + 1]; return result }
        i += 1
      } else if (parts[i] === '-y') {
        publicMode = true
      } else if (parts[i] === '-l') {
        fingerprintMode = true
      } else if (parts[i] === '-p') {
        if (passphraseMode) { result.errorMessage = 'ssh-keygen: duplicate option -p'; return result }
        passphraseMode = true
      } else if (parts[i] === '-f') {
        if (i + 1 >= parts.length) { result.errorMessage = 'ssh-keygen: missing filename after -f'; return result }
        keyFileCount += 1
        result.keyName = parts[i + 1]; i += 1
      } else if (parts[i] === '-C') {
        commentSpecified = true
        if (i + 1 >= parts.length) { result.errorMessage = 'ssh-keygen: missing comment after -C'; return result }
        result.sourcePath = parts[i + 1]; i += 1
      } else if (parts[i].startsWith('-')) {
        result.errorMessage = 'ssh-keygen: unknown option ' + parts[i]; return result
      } else {
        unexpectedArgument = parts[i]
      }
      i += 1
    }
    if (passphraseMode) {
      if (publicMode || fingerprintMode || keyTypeSpecified || commentSpecified) {
        result.errorMessage = 'ssh-keygen: -p cannot be combined with key generation or inspection options'
      } else if (keyFileCount !== 1 || result.keyName.length === 0) {
        result.errorMessage = 'ssh-keygen: -p requires exactly one -f <identity>'
      } else if (unexpectedArgument.length > 0) {
        result.errorMessage = 'ssh-keygen: unexpected argument ' + unexpectedArgument
      } else {
        result.kind = KeyCommandKind.KEY_PASSPHRASE_CHANGE
      }
    } else if (publicMode && fingerprintMode) {
      result.errorMessage = 'ssh-keygen: -y and -l cannot be used together'
    } else if (publicMode || fingerprintMode) {
      if (result.keyName.length === 0) {
        result.errorMessage = 'ssh-keygen: -f <identity> is required with -y or -l'
      } else {
        result.kind = publicMode ? KeyCommandKind.KEYPUB : KeyCommandKind.KEYINFO
      }
    }
    return result
  }

  private static parseKnownHostTarget(target: string, mode: string, result: KeyCommandResult): void {
    if (target.length === 0) {
      result.errorMessage = 'ssh-keygen: missing host after ' + mode
      return
    }
    if (target.startsWith('[')) {
      let closingBracket: number = target.indexOf(']')
      if (closingBracket <= 1 || closingBracket + 1 >= target.length ||
        target[closingBracket + 1] !== ':' || target.indexOf(']', closingBracket + 1) >= 0) {
        result.errorMessage = 'ssh-keygen: invalid [host]:port target'
        return
      }
      let portText: string = target.substring(closingBracket + 2)
      let port: number = parseInt(portText, 10)
      if (!/^\d+$/.test(portText) || isNaN(port) || port < 1 || port > 65535) {
        result.errorMessage = 'ssh-keygen: port must be between 1 and 65535'
        return
      }
      result.sshHost = target.substring(1, closingBracket)
      result.sshPort = port
      return
    }
    let firstColon: number = target.indexOf(':')
    if (firstColon > 0 && firstColon === target.lastIndexOf(':')) {
      result.errorMessage = 'ssh-keygen: non-default ports must use [host]:port'
      return
    }
    result.sshHost = target
    result.sshPort = 22
  }

  static parseSshCopyId(input: string): KeyCommandResult {
    let result: KeyCommandResult = new KeyCommandResult()
    result.kind = KeyCommandKind.KEYPUSH
    let parts: string[] = input.split(/\s+/)
    let identitySpecified: boolean = false
    let portSpecified: boolean = false
    let targetSpecified: boolean = false
    let i: number = 1
    while (i < parts.length) {
      if (parts[i] === '-i') {
        if (i + 1 >= parts.length) { result.errorMessage = 'ssh-copy-id: missing key name after -i'; return result }
        if (identitySpecified) { result.errorMessage = 'ssh-copy-id: duplicate option -i'; return result }
        result.keyName = parts[i + 1]; i += 1
        identitySpecified = true
      } else if (parts[i] === '-p') {
        if (i + 1 >= parts.length) { result.errorMessage = 'ssh-copy-id: missing port after -p'; return result }
        if (portSpecified) { result.errorMessage = 'ssh-copy-id: duplicate option -p'; return result }
        let portText: string = parts[i + 1]
        let p: number = parseInt(parts[i + 1], 10)
        if (!/^\d+$/.test(portText) || isNaN(p) || p < 1 || p > 65535) {
          result.errorMessage = 'ssh-copy-id: port 1-65535'; return result
        }
        result.sshPort = p; i += 1
        portSpecified = true
      } else if (parts[i].startsWith('-')) {
        result.errorMessage = 'ssh-copy-id: unknown option ' + parts[i]; return result
      } else {
        if (targetSpecified) { result.errorMessage = 'ssh-copy-id: unexpected target ' + parts[i]; return result }
        let target: string = parts[i]
        let atIdx: number = target.lastIndexOf('@')
        if (atIdx <= 0) { result.errorMessage = 'ssh-copy-id: expected user@host'; return result }
        result.sshUser = target.substring(0, atIdx)
        let hostPort: string = target.substring(atIdx + 1)
        if (hostPort.startsWith('[')) {
          let closing: number = hostPort.indexOf(']')
          if (closing <= 1) { result.errorMessage = 'ssh-copy-id: invalid IPv6'; return result }
          result.sshHost = hostPort.substring(1, closing)
          if (closing + 1 < hostPort.length) {
            if (hostPort[closing + 1] !== ':') {
              result.errorMessage = 'ssh-copy-id: unexpected text after bracketed host'; return result
            }
            let portText: string = hostPort.substring(closing + 2)
            let p: number = parseInt(portText, 10)
            if (!/^\d+$/.test(portText) || isNaN(p) || p < 1 || p > 65535) {
              result.errorMessage = 'ssh-copy-id: port 1-65535'; return result
            }
            result.sshPort = p
          }
        } else {
          let colonIdx: number = hostPort.indexOf(':')
          if (colonIdx > 0 && hostPort.lastIndexOf(':') === colonIdx) {
            result.sshHost = hostPort.substring(0, colonIdx)
            let portText: string = hostPort.substring(colonIdx + 1)
            let p: number = parseInt(portText, 10)
            if (!/^\d+$/.test(portText) || isNaN(p) || p < 1 || p > 65535) {
              result.errorMessage = 'ssh-copy-id: port 1-65535'; return result
            }
            result.sshPort = p
          } else { result.sshHost = hostPort }
        }
        targetSpecified = true
      }
      i += 1
    }
    if (result.keyName.length === 0) { result.errorMessage = 'ssh-copy-id: -i <key-name> is required' }
    if (result.sshHost.length === 0) { result.errorMessage = 'ssh-copy-id: target <user>@<host> is required' }
    return result
  }

  static parseKeyShow(input: string): KeyCommandResult {
    let result: KeyCommandResult = new KeyCommandResult()
    result.kind = KeyCommandKind.KEYPUB
    result.sourcePath = 'legacy-key-show'
    let parts: string[] = input.split(/\s+/)
    if (parts.length !== 3) { result.errorMessage = 'Usage: key show <key-name>'; return result }
    result.keyName = parts[2]
    return result
  }

  static parseKeyRm(input: string): KeyCommandResult {
    let result: KeyCommandResult = new KeyCommandResult()
    result.kind = KeyCommandKind.KEYRM
    let parts: string[] = input.split(/\s+/)
    if (parts.length !== 3) { result.errorMessage = 'Usage: key rm <key-name>'; return result }
    result.keyName = parts[2]
    return result
  }

  static parseKeyImport(input: string): KeyCommandResult {
    let result: KeyCommandResult = new KeyCommandResult()
    result.kind = KeyCommandKind.KEYIMPORT
    let parts: string[] = input.split(/\s+/)
    if (parts.length < 3 || parts.length > 4) {
      result.errorMessage = 'Usage: key import <path> [<key-name>]'
      return result
    }
    result.sourcePath = parts[2]
    if (parts.length === 4) { result.keyName = parts[3] }
    else {
      let normalizedPath: string = parts[2].replace(/\\/g, '/')
      let lastSlash: number = normalizedPath.lastIndexOf('/')
      result.keyName = lastSlash >= 0 ? normalizedPath.substring(lastSlash + 1) : normalizedPath
    }
    return result
  }

  static parseKeyExport(input: string): KeyCommandResult {
    let result: KeyCommandResult = new KeyCommandResult()
    result.kind = KeyCommandKind.KEYEXPORT
    let parts: string[] = input.split(/\s+/)
    if (parts.length < 3 || parts.length > 4) {
      result.errorMessage = 'Usage: key export <key-name> [<file-name>]'
      return result
    }
    result.keyName = parts[2]
    result.destinationName = parts.length === 4 ? parts[3] : result.keyName
    return result
  }

  static parseAliasAdd(input: string): KeyCommandResult {
    let result: KeyCommandResult = new KeyCommandResult()
    result.kind = KeyCommandKind.ALIAS_ADD
    let parts: string[] = input.split(/\s+/)
    let operation: string = parts.length >= 2 && parts[1] === 'set' ? 'set' : 'add'
    let usage: string = 'Usage: host ' + operation + ' <host-name> <user>@<host>[:<port>] ' +
      '[-J <jump>] [--connect-timeout <1-300|default>] ' +
      '[--server-alive-interval <0-3600|default>] [--server-alive-count-max <1-100|default>]'
    if (parts.length < 4 || parts.length > 12 || parts.length % 2 !== 0) {
      result.errorMessage = usage
      return result
    }
    for (let index: number = 4; index < parts.length; index += 2) {
      let option: string = parts[index]
      let value: string = parts[index + 1]
      if (value.length === 0) {
        result.errorMessage = usage
        return result
      }
      if (option === '-J') {
        if (result.sshJump.length > 0) {
          result.errorMessage = 'Duplicate host option: -J'
          return result
        }
        if (value.includes(',') || value.includes('://') || value.includes('%') || value.includes('$')) {
          result.errorMessage = 'Unsupported ProxyJump expression: only one [user@]host[:port] is supported'
          return result
        }
        result.sshJump = value
      } else if (option === '--connect-timeout') {
        if (result.sshConnectTimeoutMs >= 0) {
          result.errorMessage = 'Duplicate host option: --connect-timeout'
          return result
        }
        if (value === 'default') {
          result.sshConnectTimeoutMs = DEFAULT_SSH_CONNECT_TIMEOUT_MS
        } else {
          let seconds: number = parseInt(value, 10)
          if (!/^\d+$/.test(value) || isNaN(seconds) || seconds < 1 ||
            seconds > MAX_SSH_CONNECT_TIMEOUT_SECONDS) {
            result.errorMessage = 'Connect timeout must be whole seconds 1-' +
              MAX_SSH_CONNECT_TIMEOUT_SECONDS.toString() + ', or default'
            return result
          }
          result.sshConnectTimeoutMs = seconds * 1000
        }
      } else if (option === '--server-alive-interval') {
        if (result.sshServerAliveIntervalSeconds >= 0) {
          result.errorMessage = 'Duplicate host option: --server-alive-interval'
          return result
        }
        if (value === 'default') {
          result.sshServerAliveIntervalSeconds = DEFAULT_SSH_SERVER_ALIVE_INTERVAL_SECONDS
        } else {
          let seconds: number = parseInt(value, 10)
          if (!/^\d+$/.test(value) || isNaN(seconds) || seconds < 0 ||
            seconds > MAX_SSH_SERVER_ALIVE_INTERVAL_SECONDS) {
            result.errorMessage = 'Server alive interval must be whole seconds 0-' +
              MAX_SSH_SERVER_ALIVE_INTERVAL_SECONDS.toString() + ', or default'
            return result
          }
          result.sshServerAliveIntervalSeconds = seconds
        }
      } else if (option === '--server-alive-count-max') {
        if (result.sshServerAliveCountMax >= 0) {
          result.errorMessage = 'Duplicate host option: --server-alive-count-max'
          return result
        }
        if (value === 'default') {
          result.sshServerAliveCountMax = DEFAULT_SSH_SERVER_ALIVE_COUNT_MAX
        } else {
          let count: number = parseInt(value, 10)
          if (!/^\d+$/.test(value) || isNaN(count) || count < 1 ||
            count > MAX_SSH_SERVER_ALIVE_COUNT_MAX) {
            result.errorMessage = 'Server alive count max must be 1-' +
              MAX_SSH_SERVER_ALIVE_COUNT_MAX.toString() + ', or default'
            return result
          }
          result.sshServerAliveCountMax = count
        }
      } else {
        result.errorMessage = 'Unsupported host option: ' + option
        return result
      }
    }
    result.keyName = parts[2]
    if (!/^[A-Za-z0-9._-]+$/.test(result.keyName)) {
      result.errorMessage = 'Host name may contain only letters, numbers, dot, underscore and hyphen'
      return result
    }
    let target: string = parts[3]
    let atIdx: number = target.lastIndexOf('@')
    if (atIdx <= 0) {
      result.errorMessage = usage
      return result
    }
    result.sshUser = target.substring(0, atIdx)
    let hostPort: string = target.substring(atIdx + 1)
    if (hostPort.length === 0) {
      result.errorMessage = usage
      return result
    }
    if (hostPort.startsWith('[')) {
      let closing: number = hostPort.indexOf(']')
      if (closing <= 1) { result.errorMessage = 'Invalid bracketed IPv6 host'; return result }
      result.sshHost = hostPort.substring(1, closing)
      if (closing + 1 < hostPort.length) {
        if (hostPort[closing + 1] !== ':') {
          result.errorMessage = 'Unexpected text after bracketed host'; return result
        }
        let portText: string = hostPort.substring(closing + 2)
        let port: number = parseInt(portText, 10)
        if (!/^\d+$/.test(portText) || isNaN(port) || port < 1 || port > 65535) {
          result.errorMessage = 'Port 1-65535'; return result
        }
        result.sshPort = port
      }
      return result
    }
    let colonIdx: number = hostPort.indexOf(':')
    if (colonIdx > 0 && hostPort.lastIndexOf(':') === colonIdx) {
      result.sshHost = hostPort.substring(0, colonIdx)
      let portText: string = hostPort.substring(colonIdx + 1)
      let p: number = parseInt(portText, 10)
      if (!/^\d+$/.test(portText) || isNaN(p) || p < 1 || p > 65535) {
        result.errorMessage = 'Port 1-65535'; return result
      }
      result.sshPort = p
    } else { result.sshHost = hostPort }
    return result
  }

  static parseAliasRm(input: string): KeyCommandResult {
    let result: KeyCommandResult = new KeyCommandResult()
    result.kind = KeyCommandKind.ALIAS_RM
    let parts: string[] = input.split(/\s+/)
    if (parts.length !== 3) { result.errorMessage = 'Usage: host rm <host-name>'; return result }
    result.keyName = parts[2]
    return result
  }
}

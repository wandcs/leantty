import { common } from '@kit.AbilityKit'
import { SshKeyManager } from '../ssh/SshKeyManager'
import { KeyPairInfo } from '../../common/types/SshKeyTypes'
import { CommandParser, CommandParseResult, KeyCommandResult, KeyCommandKind } from './CommandParser'
import { SshConfig } from '../ssh/SshConfig'
import { Logger } from '../../common/logger/Logger'
import { KnownHostQueryResult, KnownHostRemovalResult, KnownHostsManager } from '../ssh/KnownHostsManager'
import { LocalCommandOutput } from '../terminal/LocalCommandOutput'
import { TerminalTextPolicy } from '../../common/security/TerminalTextPolicy'

const logger: Logger = new Logger('KeyCommandService')
const HELP_TEXT: string =
  '\r\n' +
  'Syntax: <...> is required; [...] is optional; <a|b> means choose one.\r\n' +
  '\r\n' +
  'Connection\r\n' +
  '  ssh [-p <port>] [-i <identity>] [-J <jump>] <user>@<host>\r\n' +
  '  ssh [-p <port>] [-i <identity>] [-J <jump>] <host-name>\r\n' +
  '\r\n' +
  'File transfer\r\n' +
  '  put [-p <port>] [-i <identity>] [--] <local-file> <host>:<remote-path>\r\n' +
  '  get [-p <port>] [-i <identity>] [--] <host>:<remote-file> [local-path]\r\n' +
  '  Local paths stay in Downloads. End a directory target with /. Existing files are never overwritten.\r\n' +
  '\r\n' +
  'OpenSSH keys\r\n' +
  '  ssh-keygen [-t <ed25519|rsa>] [-f <key-name>]  Generate a key pair\r\n' +
  '  ssh-keygen -y -f <identity>                    Show a public key\r\n' +
  '  ssh-keygen -l -f <identity>[.pub]               Show a fingerprint\r\n' +
  '  ssh-keygen -p -f <identity>                     Change a private-key passphrase\r\n' +
  '  ssh-keygen -F <host>|[<host>]:<port>            Find trusted host keys\r\n' +
  '  ssh-keygen -R <host>|[<host>]:<port>            Remove trusted host keys\r\n' +
  '  ssh-copy-id -i <key-name> [-p <port>] <user>@<host>  Install a public key\r\n' +
  '\r\n' +
  'LeanTTY key store\r\n' +
  '  key list                                       List verified key pairs\r\n' +
  '  key import <path> [<key-name>]                  Import and verify a private key\r\n' +
  '  key export <key-name> [<file-name>]             Export a key pair to Downloads\r\n' +
  '  key rm <key-name>                               Delete a verified key pair\r\n' +
  '\r\n' +
  'Host configuration\r\n' +
  '  host add <name> <user>@<host>[:<port>] [options]  Add a host\r\n' +
  '  host set <name> <user>@<host>[:<port>] [options]  Update a host\r\n' +
  '  host rm <host-name>                            Remove a host\r\n' +
  '  host list                                      List hosts\r\n' +
  '\r\n' +
  '  help [<command>], <command> --help, ?           Show help\r\n' +
  '  exit                                           Close this pane\r\n'

const SSH_HELP: string = '\r\nUsage: ssh [-p <port>] [-i <identity>] [-J <jump>] <user>@<host>\r\n' +
  '       ssh [-p <port>] [-i <identity>] [-J <jump>] <host-name>\r\n\r\n' +
  'Host settings, including one ProxyJump and ConnectTimeout, come from ~/.ssh/config.\r\n' +
  'Command options take precedence where LeanTTY provides one.\r\n' +
  '<jump> is one saved Host or [user@]host[:port]. Use -J none to bypass a saved ProxyJump.\r\n' +
  'ProxyCommand and multi-hop chains are not supported.\r\n'
const KEYGEN_HELP: string = '\r\nUsage: ssh-keygen [-t <ed25519|rsa>] [-f <key-name>] [-C <comment>]\r\n' +
  '       ssh-keygen -y -f <identity>\r\n       ssh-keygen -l -f <identity>[.pub]\r\n' +
  '       ssh-keygen -p -f <identity>\r\n' +
  '       ssh-keygen -F <host>|[<host>]:<port>\r\n' +
  '       ssh-keygen -R <host>|[<host>]:<port>\r\n\r\n' +
  'Creates, inspects or updates keys, and finds or removes trusted host records in LeanTTY ~/.ssh.\r\n'
const COPY_ID_HELP: string = '\r\nUsage: ssh-copy-id -i <key-name> [-p <port>] <user>@<host>\r\n\r\n' +
  'Installs the public key once; an existing identical line is not duplicated.\r\n'
const KEY_HELP: string =
  '\r\nUsage: key list | key import <path> [<key-name>] | ' +
  'key export <key-name> [<file-name>] | key rm <key-name>\r\n\r\n' +
  '<key-name> is the name shown by "key list". <file-name> is the optional Downloads basename; ' +
  'it defaults to <key-name>. The private key and .pub file are never overwritten.\r\n'
const HOST_HELP: string = '\r\nUsage: host add|set <host-name> <user>@<host>[:<port>] [-J <jump>] ' +
  '[--connect-timeout <1-300|default>]\r\n' +
  '       host rm <host-name>\r\n       host list\r\n\r\n' +
  '-J saves one ProxyJump in the same OpenSSH Host entry; -J none disables it.\r\n' +
  '--connect-timeout saves whole seconds in that Host; default restores 15 seconds.\r\n' +
  'Legacy alias commands remain temporarily supported.\r\n'
const TRANSFER_HELP: string =
  '\r\nUsage: put [-p <port>] [-i <identity>] [--] <local-file> <host>:<remote-path>\r\n' +
  '       get [-p <port>] [-i <identity>] [--] <host>:<remote-file> [local-path]\r\n\r\n' +
  'Local paths stay in Downloads; existing subdirectories are allowed but never created.\r\n' +
  'End a target directory with /. GET chooses the remote basename when local-path is omitted or a directory.\r\n' +
  'Existing local and remote files are never overwritten. Tab completes local paths and Host names, not remote paths.\r\n' +
  'Use put/get instead of scp.\r\n'

export interface KeyCommandContext {
  context: common.Context
  sshConfig: SshConfig
  onConnect: (host: string, port: number, username: string) => void
  setPendingKeypush: (keyPath: string, pubText: string) => void
  writeError: (msg: string) => void
  writeOutput: (text: string) => void
  beginKeyPassphraseChange: (keyName: string) => void
  confirmKeyDelete: (name: string, fingerprint: string, onConfirm: () => void, onCancel: () => void) => void
  showTopLevelHelp: (helpText: string) => void
}

export class KeyCommandService {
  static execute(result: KeyCommandResult, ctx: KeyCommandContext): void {
    if (result.errorMessage.length > 0) {
      ctx.writeError(result.errorMessage +
        (result.errorMessage.startsWith('Usage: ') ? '' : '\r\nTry: help'))
      return
    }
    if (result.kind === KeyCommandKind.HELP) { KeyCommandService.executeHelp(result, ctx); return }
    if (result.legacySyntax) {
      ctx.writeOutput('\r\n' + LocalCommandOutput.note(
        '"alias" is deprecated; use "host" instead.') + '\r\n')
    }

    if (result.kind === KeyCommandKind.KEYS) { KeyCommandService.executeKeys(ctx); return }
    if (result.kind === KeyCommandKind.KEYGEN) { KeyCommandService.executeKeygen(result, ctx); return }
    if (result.kind === KeyCommandKind.KEYIMPORT) { KeyCommandService.executeKeyimport(result, ctx); return }
    if (result.kind === KeyCommandKind.KEYPUB) { KeyCommandService.executeKeypub(result, ctx); return }
    if (result.kind === KeyCommandKind.KEYINFO) { KeyCommandService.executeKeyinfo(result, ctx); return }
    if (result.kind === KeyCommandKind.KEY_PASSPHRASE_CHANGE) {
      KeyCommandService.executeKeyPassphraseChange(result, ctx)
      return
    }
    if (result.kind === KeyCommandKind.KEYEXPORT) { KeyCommandService.executeKeyexport(result, ctx); return }
    if (result.kind === KeyCommandKind.HOST_KEY_FIND) {
      KeyCommandService.executeHostKeyFind(result, ctx)
      return
    }
    if (result.kind === KeyCommandKind.HOST_KEY_REMOVE) {
      KeyCommandService.executeHostKeyRemove(result, ctx)
      return
    }
    if (result.kind === KeyCommandKind.KEYRM) { KeyCommandService.executeKeyrm(result, ctx); return }
    if (result.kind === KeyCommandKind.KEYPUSH) { KeyCommandService.executeKeypush(result, ctx); return }
    if (result.kind === KeyCommandKind.ALIAS_ADD) { KeyCommandService.executeAliasAdd(result, ctx); return }
    if (result.kind === KeyCommandKind.HOST_SET) { KeyCommandService.executeHostSet(result, ctx); return }
    if (result.kind === KeyCommandKind.ALIAS_RM) { KeyCommandService.executeAliasRm(result, ctx); return }
    if (result.kind === KeyCommandKind.ALIAS_LIST) { KeyCommandService.executeAliasList(ctx); return }
    if (result.kind === KeyCommandKind.SSH_CONFIG) { KeyCommandService.executeSshConfig(result, ctx); return }
  }

  private static executeHelp(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let topic: string = result.keyName.toLowerCase()
    if (topic.length === 0) { ctx.showTopLevelHelp(HELP_TEXT); return }
    if (topic === 'ssh') { ctx.writeOutput(SSH_HELP + LocalCommandOutput.prompt()); return }
    if (topic === 'ssh-keygen') { ctx.writeOutput(KEYGEN_HELP + LocalCommandOutput.prompt()); return }
    if (topic === 'ssh-copy-id') { ctx.writeOutput(COPY_ID_HELP + LocalCommandOutput.prompt()); return }
    if (topic === 'key' || topic === 'keys') { ctx.writeOutput(KEY_HELP + LocalCommandOutput.prompt()); return }
    if (topic === 'host' || topic === 'alias') { ctx.writeOutput(HOST_HELP + LocalCommandOutput.prompt()); return }
    if (topic === 'put' || topic === 'get' || topic === 'scp') {
      ctx.writeOutput(TRANSFER_HELP + LocalCommandOutput.prompt()); return
    }
    ctx.writeError('Unknown help topic: ' + KeyCommandService.safeText(result.keyName) +
      '.\r\nTry: help')
  }

  private static executeKeys(ctx: KeyCommandContext): void {
    let keys: KeyPairInfo[] = SshKeyManager.listKeys(ctx.context)
    if (keys.length === 0) {
      ctx.writeOutput('\r\nNo keys found.\r\n  Try: ssh-keygen\r\n' + LocalCommandOutput.prompt())
      return
    }
    ctx.writeOutput('\r\n  NAME          TYPE      FINGERPRINT\r\n')
    ctx.writeOutput('  ----          ----      -----------\r\n')
    for (let i = 0; i < keys.length; i++) {
      let name: string = KeyCommandService.fileName(keys[i].filePath)
      let algo: string = keys[i].algorithm === 0 ? 'ed25519' : 'rsa'
      ctx.writeOutput('  ' + KeyCommandService.safeText(name).padEnd(14, ' ') + algo.padEnd(10, ' ') +
        KeyCommandService.safeText(keys[i].fingerprint) + '\r\n')
    }
    ctx.writeOutput(LocalCommandOutput.prompt())
  }

  private static async executeKeygen(result: KeyCommandResult, ctx: KeyCommandContext): Promise<void> {
    try {
      let genResult = await SshKeyManager.generateKeyPair(ctx.context, result.algorithm, '', result.keyName,
        result.sourcePath)
      let name: string = KeyCommandService.fileName(genResult.privateKey.filePath)
      ctx.writeOutput('\r\n' + LocalCommandOutput.success('Generated key ' +
        KeyCommandService.safeText(name) + '.') + '\r\n')
      ctx.writeOutput('  Fingerprint: ' + KeyCommandService.safeText(genResult.privateKey.fingerprint) + '\r\n')
      ctx.writeOutput('Public key:\r\n' + KeyCommandService.safeMultilineText(
        genResult.privateKey.publicKeyText) + '\r\n')
      ctx.writeOutput('  Try: key list\r\n' + LocalCommandOutput.prompt())
      logger.info('Key generated: ' + genResult.privateKey.fingerprint)
    } catch (e) {
      logger.warn('Key generation failed: ' + e)
      ctx.writeError('The key could not be generated.\r\nCheck the key name and try again.')
    }
  }

  private static async executeKeyimport(result: KeyCommandResult, ctx: KeyCommandContext): Promise<void> {
    try {
      let key: KeyPairInfo = await SshKeyManager.importKey(ctx.context, result.sourcePath, result.keyName)
      ctx.writeOutput('\r\n' + LocalCommandOutput.success('Imported key ' +
        KeyCommandService.safeText(key.filePath) + '.') + '\r\n')
      ctx.writeOutput('  Fingerprint: ' + KeyCommandService.safeText(key.fingerprint) + '\r\n')
      ctx.writeOutput(LocalCommandOutput.prompt())
    } catch (e) {
      logger.warn('Key import failed: ' + e)
      ctx.writeError('The key could not be imported.\r\nCheck the Downloads path and key format, then try again.')
    }
  }

  private static executeKeypub(result: KeyCommandResult, ctx: KeyCommandContext): void {
    if (result.sourcePath === 'legacy-key-show') {
      ctx.writeOutput('\r\n' + LocalCommandOutput.note(
        '"key show" is deprecated; use ssh-keygen -y -f <identity>.') + '\r\n')
    }
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: key list')
      return
    }
    let pubText: string = key.publicKeyText
    if (pubText.length === 0) {
      pubText = SshKeyManager.readPublicKeyText(ctx.context, result.keyName)
    }
    ctx.writeOutput('\r\n' + KeyCommandService.safeMultilineText(pubText) + '\r\n' +
      LocalCommandOutput.prompt())
  }

  private static executeKeyinfo(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: key list')
      return
    }
    let name: string = KeyCommandService.fileName(key.filePath)
    let algo: string = key.algorithm === 0 ? 'ED25519' : 'RSA'
    ctx.writeOutput('\r\n' + KeyCommandService.safeText(key.fingerprint) + ' ' +
      KeyCommandService.safeText(name) + ' (' + algo + ')\r\n' + LocalCommandOutput.prompt())
  }

  private static executeKeyPassphraseChange(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: key list')
      return
    }
    ctx.beginKeyPassphraseChange(KeyCommandService.fileName(key.filePath))
  }

  private static executeKeyrm(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: key list')
      return
    }
    let keyName: string = result.keyName
    ctx.confirmKeyDelete(keyName, key.fingerprint, () => {
      SshKeyManager.deleteKey(ctx.context, keyName)
      logger.info('KEY_DELETE result=success')
      ctx.writeOutput('\r\n' + LocalCommandOutput.success('Deleted key ' +
        KeyCommandService.safeText(keyName) + '.') + '\r\n' + LocalCommandOutput.prompt())
    }, () => { ctx.writeOutput(LocalCommandOutput.prompt()) })
  }

  private static executeHostKeyRemove(result: KeyCommandResult, ctx: KeyCommandContext): void {
    try {
      let removal: KnownHostRemovalResult =
        KnownHostsManager.remove(ctx.context, result.sshHost, result.sshPort)
      if (removal.removed === 0) {
        ctx.writeOutput('\r\nNo host key found for ' + KeyCommandService.safeText(removal.target) +
          '.\r\n' + LocalCommandOutput.prompt())
        return
      }
      let noun: string = removal.removed === 1 ? 'entry' : 'entries'
      ctx.writeOutput('\r\n' + LocalCommandOutput.success('Removed ' + removal.removed.toString() +
        ' host key ' + noun + ' for ' + KeyCommandService.safeText(removal.target) + '.') +
        '\r\n  Reconnect to verify and trust the new host key.\r\n' + LocalCommandOutput.prompt())
    } catch (e) {
      logger.warn('Failed to remove host key: ' + e)
      ctx.writeError('The host key could not be removed.\r\nCheck the Host target and try again.')
    }
  }

  private static executeHostKeyFind(result: KeyCommandResult, ctx: KeyCommandContext): void {
    try {
      let query: KnownHostQueryResult = KnownHostsManager.find(result.sshHost, result.sshPort)
      if (query.found === 0) {
        ctx.writeOutput('\r\nNo host key found for ' + KeyCommandService.safeText(query.target) +
          '.\r\n' + LocalCommandOutput.prompt())
        return
      }
      ctx.writeOutput('\r\n' + KeyCommandService.safeMultilineText(query.output) +
        LocalCommandOutput.prompt())
    } catch (e) {
      logger.warn('Failed to find host key: ' + e)
      ctx.writeError('The host key could not be read.\r\nCheck the Host target and try again.')
    }
  }

  private static async executeKeyexport(result: KeyCommandResult, ctx: KeyCommandContext): Promise<void> {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: key list')
      return
    }
    let keyName: string = KeyCommandService.fileName(key.filePath)
    let exportFileName: string = result.destinationName.length > 0 ? result.destinationName : keyName
    try {
      await SshKeyManager.exportKeyPair(ctx.context, keyName, exportFileName)
      ctx.writeOutput('\r\n' + LocalCommandOutput.success('Exported key pair to Downloads.') +
        '\r\n  ' + KeyCommandService.safeText(exportFileName) + '\r\n  ' +
        KeyCommandService.safeText(exportFileName + '.pub') + '\r\n' + LocalCommandOutput.prompt())
    } catch (e) {
      logger.warn('Key export failed: ' + e)
      ctx.writeError('The key pair could not be exported.\r\nCheck Downloads access and the file name, then try again.')
    }
  }

  private static executeAliasAdd(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let config: SshConfig = ctx.sshConfig
    if (!result.legacySyntax && config.findHost(result.keyName) !== null) {
      ctx.writeError('Host already exists: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: host set ' + KeyCommandService.safeText(result.keyName) + ' ...')
      return
    }
    let updated: boolean = config.findHost(result.keyName) !== null
    KeyCommandService.saveHost(result, ctx, updated)
  }

  private static executeHostSet(result: KeyCommandResult, ctx: KeyCommandContext): void {
    if (ctx.sshConfig.findHost(result.keyName) === null) {
      ctx.writeError('Host not found: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: host add ' + KeyCommandService.safeText(result.keyName) + ' ...')
      return
    }
    KeyCommandService.saveHost(result, ctx, true)
  }

  private static saveHost(result: KeyCommandResult, ctx: KeyCommandContext, updated: boolean): void {
    let config: SshConfig = ctx.sshConfig
    let current = config.resolveHost(result.keyName)
    if (current.errorMessage.length > 0) {
      ctx.writeError(current.errorMessage + '\r\nCheck the matching Host entry in ~/.ssh/config.')
      return
    }
    config.addAlias(result.keyName, result.sshHost, result.sshPort, result.sshUser,
      result.sshJump.length > 0 ? result.sshJump : null,
      result.sshConnectTimeoutMs >= 0 ? result.sshConnectTimeoutMs : null)
    config.saveConfig(ctx.context)
    let info: string = result.keyName + ' -> ' + result.sshUser + '@' + result.sshHost
    if (result.sshPort !== 22) { info += ':' + result.sshPort.toString() }
    if (result.sshJump.length > 0) { info += ' via ' + result.sshJump }
    if (result.sshConnectTimeoutMs >= 0) {
      info += ' timeout=' + Math.floor(result.sshConnectTimeoutMs / 1000).toString() + 's'
    }
    ctx.writeOutput('\r\n' + LocalCommandOutput.success('Host ' +
      (updated ? 'updated: ' : 'added: ') + KeyCommandService.safeText(info) + '.') +
      '\r\n' + LocalCommandOutput.prompt())
    logger.info('Host added: ' + info)
  }

  private static executeSshConfig(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let command: string = 'ssh '
    if (result.sshJump.length > 0) { command += '-J ' + result.sshJump + ' ' }
    command += result.keyName
    let connection: CommandParseResult = CommandParser.parseCommand(command, ctx.sshConfig)
    if (!connection.isValid) {
      ctx.writeError(connection.errorMessage + '\r\nCheck the matching Host entry in ~/.ssh/config.')
      return
    }
    ctx.writeOutput('\r\nhost ' + KeyCommandService.safeText(result.keyName) + '\r\n')
    ctx.writeOutput('hostname ' + KeyCommandService.safeText(connection.host) + '\r\n')
    ctx.writeOutput('user ' + KeyCommandService.safeText(connection.username) + '\r\n')
    ctx.writeOutput('port ' + connection.port.toString() + '\r\n')
    if (connection.identityFile.length > 0) {
      ctx.writeOutput('identityfile ' + KeyCommandService.safeText(connection.identityFile) + '\r\n')
    }
    ctx.writeOutput('connecttimeout ' + Math.floor(connection.connectTimeoutMs / 1000).toString() + '\r\n')
    if (connection.jumpHost.length > 0) {
      ctx.writeOutput('proxyjump ' + KeyCommandService.safeText(connection.jumpDisplayHost) + '\r\n')
      ctx.writeOutput('proxyjumphostname ' + KeyCommandService.safeText(connection.jumpHost) + '\r\n')
      ctx.writeOutput('proxyjumpuser ' + KeyCommandService.safeText(connection.jumpUsername) + '\r\n')
      ctx.writeOutput('proxyjumpport ' + connection.jumpPort.toString() + '\r\n')
      ctx.writeOutput('proxyjumpconnecttimeout ' +
        Math.floor(connection.jumpConnectTimeoutMs / 1000).toString() + '\r\n')
      if (connection.jumpIdentityFile.length > 0) {
        ctx.writeOutput('proxyjumpidentityfile ' +
          KeyCommandService.safeText(connection.jumpIdentityFile) + '\r\n')
      }
    }
    ctx.writeOutput(LocalCommandOutput.prompt())
  }

  private static executeAliasRm(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let config: SshConfig = ctx.sshConfig
    if (config.removeAlias(result.keyName)) {
      config.saveConfig(ctx.context)
      ctx.writeOutput('\r\n' + LocalCommandOutput.success('Host removed: ' +
        KeyCommandService.safeText(result.keyName) + '.') + '\r\n' + LocalCommandOutput.prompt())
    } else {
      ctx.writeError('Host not found: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: host list')
    }
  }

  private static executeAliasList(ctx: KeyCommandContext): void {
    let hosts = ctx.sshConfig.getHosts()
    if (hosts.length === 0) {
      ctx.writeOutput('\r\nNo hosts configured.\r\n  Try: host add <host-name> <user>@<host>\r\n' +
        LocalCommandOutput.prompt())
      return
    }
    ctx.writeOutput('\r\n  HOST        USER@HOST\r\n')
    ctx.writeOutput('  ----        ---------\r\n')
    for (let i = 0; i < hosts.length; i++) {
      let h = hosts[i]
      let target: string = h.user + '@' + h.hostname
      if (h.port !== 22) { target += ':' + h.port.toString() }
      ctx.writeOutput('  ' + KeyCommandService.safeText(h.alias).padEnd(12, ' ') +
        KeyCommandService.safeText(target) + '\r\n')
    }
    ctx.writeOutput(LocalCommandOutput.prompt())
  }

  static executeKeypush(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: key list')
      return
    }
    let pubText: string = key.publicKeyText
    if (pubText.length === 0) {
      pubText = SshKeyManager.readPublicKeyText(ctx.context, result.keyName)
    }
    if (pubText.length === 0) {
      ctx.writeError('The public key could not be read: ' + KeyCommandService.safeText(result.keyName) +
        '.\r\nTry: key list')
      return
    }
    ctx.setPendingKeypush(result.keyName, pubText)
    ctx.onConnect(result.sshHost, result.sshPort, result.sshUser)
  }

  private static fileName(filePath: string): string {
    let lastSlash: number = filePath.lastIndexOf('/')
    return lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath
  }

  private static safeText(value: string): string {
    return TerminalTextPolicy.escape(value)
  }

  private static safeMultilineText(value: string): string {
    let normalized: string = value.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
    let lines: string[] = normalized.split('\n')
    let safe: string = ''
    for (let index: number = 0; index < lines.length; index++) {
      if (index > 0) { safe += '\r\n' }
      safe += TerminalTextPolicy.escape(lines[index])
    }
    return safe
  }
}

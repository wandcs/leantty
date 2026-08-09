import { common } from '@kit.AbilityKit'
import { SshKeyManager } from '../ssh/SshKeyManager'
import { KeyPairInfo } from '../../common/types/SshKeyTypes'
import { KeyCommandResult, KeyCommandKind } from './CommandParser'
import { SshConfig } from '../ssh/SshConfig'
import { Logger } from '../../common/logger/Logger'
import { KnownHostQueryResult, KnownHostRemovalResult, KnownHostsManager } from '../ssh/KnownHostsManager'

const logger: Logger = new Logger('KeyCommandService')
const HELP_TEXT: string =
  '\r\n' +
  'Syntax: <...> is required; [...] is optional; <a|b> means choose one.\r\n' +
  '\r\n' +
  'Connection\r\n' +
  '  ssh [-p <port>] [-i <identity>] <user>@<host>  Connect to a server\r\n' +
  '  ssh [-p <port>] [-i <identity>] <host-name>    Connect using ~/.ssh/config\r\n' +
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
  '  host add <host-name> <user>@<host>[:<port>]    Add a host\r\n' +
  '  host set <host-name> <user>@<host>[:<port>]    Update a host\r\n' +
  '  host rm <host-name>                            Remove a host\r\n' +
  '  host list                                      List hosts\r\n' +
  '\r\n' +
  '  help [<command>], <command> --help, ?           Show help\r\n' +
  '  exit                                           Close this pane\r\n'

const SSH_HELP: string = '\r\nUsage: ssh [-p <port>] [-i <identity>] <user>@<host>\r\n' +
  '       ssh [-p <port>] [-i <identity>] <host-name>\r\n\r\n' +
  'Host settings come from ~/.ssh/config; command options take precedence.\r\nltty> '
const KEYGEN_HELP: string = '\r\nUsage: ssh-keygen [-t <ed25519|rsa>] [-f <key-name>] [-C <comment>]\r\n' +
  '       ssh-keygen -y -f <identity>\r\n       ssh-keygen -l -f <identity>[.pub]\r\n' +
  '       ssh-keygen -p -f <identity>\r\n' +
  '       ssh-keygen -F <host>|[<host>]:<port>\r\n' +
  '       ssh-keygen -R <host>|[<host>]:<port>\r\n\r\n' +
  'Creates, inspects or updates keys, and finds or removes trusted host records in LeanTTY ~/.ssh.\r\nltty> '
const COPY_ID_HELP: string = '\r\nUsage: ssh-copy-id -i <key-name> [-p <port>] <user>@<host>\r\n\r\n' +
  'Installs the public key once; an existing identical line is not duplicated.\r\nltty> '
const KEY_HELP: string =
  '\r\nUsage: key list | key import <path> [<key-name>] | ' +
  'key export <key-name> [<file-name>] | key rm <key-name>\r\n\r\n' +
  '<key-name> is the name shown by "key list". <file-name> is the optional Downloads basename; ' +
  'it defaults to <key-name>. The private key and .pub file are never overwritten.\r\nltty> '
const HOST_HELP: string = '\r\nUsage: host add|set <host-name> <user>@<host>[:<port>]\r\n' +
  '       host rm <host-name>\r\n       host list\r\n\r\nLegacy alias commands remain temporarily supported.\r\nltty> '
const TRANSFER_HELP: string =
  '\r\nUsage: put [-p <port>] [-i <identity>] [--] <local-file> <host>:<remote-path>\r\n' +
  '       get [-p <port>] [-i <identity>] [--] <host>:<remote-file> [local-path]\r\n\r\n' +
  'Local paths stay in Downloads; existing subdirectories are allowed but never created.\r\n' +
  'End a target directory with /. GET chooses the remote basename when local-path is omitted or a directory.\r\n' +
  'Existing local and remote files are never overwritten. Tab completes local paths and Host names, not remote paths.\r\n' +
  'Use put/get instead of scp.\r\nltty> '

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
    if (result.errorMessage.length > 0) { ctx.writeError(result.errorMessage); return }
    if (result.kind === KeyCommandKind.HELP) { KeyCommandService.executeHelp(result, ctx); return }
    if (result.legacySyntax) {
      ctx.writeOutput('\r\nNote: "alias" is deprecated; use "host" instead.\r\n')
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
    if (topic === 'ssh') { ctx.writeOutput(SSH_HELP); return }
    if (topic === 'ssh-keygen') { ctx.writeOutput(KEYGEN_HELP); return }
    if (topic === 'ssh-copy-id') { ctx.writeOutput(COPY_ID_HELP); return }
    if (topic === 'key' || topic === 'keys') { ctx.writeOutput(KEY_HELP); return }
    if (topic === 'host' || topic === 'alias') { ctx.writeOutput(HOST_HELP); return }
    if (topic === 'put' || topic === 'get' || topic === 'scp') { ctx.writeOutput(TRANSFER_HELP); return }
    ctx.writeError('Unknown help topic: ' + result.keyName)
  }

  private static executeKeys(ctx: KeyCommandContext): void {
    let keys: KeyPairInfo[] = SshKeyManager.listKeys(ctx.context)
    if (keys.length === 0) {
      ctx.writeOutput('\r\nNo keys found. Use ssh-keygen to create one.\r\nltty> ')
      return
    }
    ctx.writeOutput('\r\n  NAME          TYPE      FINGERPRINT\r\n')
    ctx.writeOutput('  ----          ----      -----------\r\n')
    for (let i = 0; i < keys.length; i++) {
      let name: string = KeyCommandService.fileName(keys[i].filePath)
      let algo: string = keys[i].algorithm === 0 ? 'ed25519' : 'rsa'
      ctx.writeOutput('  ' + name.padEnd(14, ' ') + algo.padEnd(10, ' ') + keys[i].fingerprint + '\r\n')
    }
    ctx.writeOutput('ltty> ')
  }

  private static async executeKeygen(result: KeyCommandResult, ctx: KeyCommandContext): Promise<void> {
    try {
      let genResult = await SshKeyManager.generateKeyPair(ctx.context, result.algorithm, '', result.keyName,
        result.sourcePath)
      let name: string = KeyCommandService.fileName(genResult.privateKey.filePath)
      ctx.writeOutput('\r\nGenerated: ' + name + '\r\n')
      ctx.writeOutput('Fingerprint: ' + genResult.privateKey.fingerprint + '\r\n')
      ctx.writeOutput('Public key:\r\n' + genResult.privateKey.publicKeyText + '\r\n')
      ctx.writeOutput('Use "key list" to view stored key fingerprints.\r\nltty> ')
      logger.info('Key generated: ' + genResult.privateKey.fingerprint)
    } catch (e) {
      ctx.writeError('Key generation failed: ' + e)
    }
  }

  private static async executeKeyimport(result: KeyCommandResult, ctx: KeyCommandContext): Promise<void> {
    try {
      let key: KeyPairInfo = await SshKeyManager.importKey(ctx.context, result.sourcePath, result.keyName)
      ctx.writeOutput('\r\nImported: ' + key.filePath + '\r\n')
      ctx.writeOutput('Fingerprint: ' + key.fingerprint + '\r\n')
      ctx.writeOutput('ltty> ')
    } catch (e) {
      ctx.writeError('Key import failed: ' + e)
    }
  }

  private static executeKeypub(result: KeyCommandResult, ctx: KeyCommandContext): void {
    if (result.sourcePath === 'legacy-key-show') {
      ctx.writeOutput('\r\nNote: "key show" is deprecated; use ssh-keygen -y -f <identity>.\r\n')
    }
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + result.keyName + '. Use key list to see available names.')
      return
    }
    let pubText: string = key.publicKeyText
    if (pubText.length === 0) {
      pubText = SshKeyManager.readPublicKeyText(ctx.context, result.keyName)
    }
    ctx.writeOutput('\r\n' + pubText + '\r\nltty> ')
  }

  private static executeKeyinfo(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + result.keyName + '. Use key list to see available names.')
      return
    }
    let name: string = KeyCommandService.fileName(key.filePath)
    let algo: string = key.algorithm === 0 ? 'ED25519' : 'RSA'
    ctx.writeOutput('\r\n' + key.fingerprint + ' ' + name + ' (' + algo + ')\r\nltty> ')
  }

  private static executeKeyPassphraseChange(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + result.keyName + '. Use key list to see available names.')
      return
    }
    ctx.beginKeyPassphraseChange(KeyCommandService.fileName(key.filePath))
  }

  private static executeKeyrm(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + result.keyName + '. Use key list to see available names.')
      return
    }
    let keyName: string = result.keyName
    ctx.confirmKeyDelete(keyName, key.fingerprint, () => {
      SshKeyManager.deleteKey(ctx.context, keyName)
      logger.info('KEY_DELETE result=success')
      ctx.writeOutput('\r\nDeleted: ' + keyName + '\r\nltty> ')
    }, () => { ctx.writeOutput('ltty> ') })
  }

  private static executeHostKeyRemove(result: KeyCommandResult, ctx: KeyCommandContext): void {
    try {
      let removal: KnownHostRemovalResult =
        KnownHostsManager.remove(ctx.context, result.sshHost, result.sshPort)
      if (removal.removed === 0) {
        ctx.writeOutput('\r\nNo host key found for ' + removal.target + '.\r\nltty> ')
        return
      }
      let noun: string = removal.removed === 1 ? 'entry' : 'entries'
      ctx.writeOutput('\r\nRemoved ' + removal.removed.toString() + ' host key ' + noun +
        ' for ' + removal.target + '.\r\nReconnect to verify and trust the new host key.\r\nltty> ')
    } catch (e) {
      ctx.writeError('Failed to remove host key: ' + e)
    }
  }

  private static executeHostKeyFind(result: KeyCommandResult, ctx: KeyCommandContext): void {
    try {
      let query: KnownHostQueryResult = KnownHostsManager.find(result.sshHost, result.sshPort)
      if (query.found === 0) {
        ctx.writeOutput('\r\nNo host key found for ' + query.target + '.\r\nltty> ')
        return
      }
      ctx.writeOutput('\r\n' + query.output.replace(/\n/g, '\r\n') + 'ltty> ')
    } catch (e) {
      ctx.writeError('Failed to find host key: ' + e)
    }
  }

  private static async executeKeyexport(result: KeyCommandResult, ctx: KeyCommandContext): Promise<void> {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + result.keyName + '. Use key list to see available names.')
      return
    }
    let keyName: string = KeyCommandService.fileName(key.filePath)
    let exportFileName: string = result.destinationName.length > 0 ? result.destinationName : keyName
    try {
      await SshKeyManager.exportKeyPair(ctx.context, keyName, exportFileName)
      ctx.writeOutput('\r\nExported to Downloads:\r\n  ' + exportFileName + '\r\n  ' +
        exportFileName + '.pub\r\nltty> ')
    } catch (e) {
      ctx.writeError('Key export failed: ' + e)
    }
  }

  private static executeAliasAdd(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let config: SshConfig = ctx.sshConfig
    if (!result.legacySyntax && config.findHost(result.keyName) !== null) {
      ctx.writeError('Host already exists: ' + result.keyName + '. Use host set to update it.')
      return
    }
    let updated: boolean = config.findHost(result.keyName) !== null
    KeyCommandService.saveHost(result, ctx, updated)
  }

  private static executeHostSet(result: KeyCommandResult, ctx: KeyCommandContext): void {
    if (ctx.sshConfig.findHost(result.keyName) === null) {
      ctx.writeError('Host not found: ' + result.keyName + '. Use host add to create it.')
      return
    }
    KeyCommandService.saveHost(result, ctx, true)
  }

  private static saveHost(result: KeyCommandResult, ctx: KeyCommandContext, updated: boolean): void {
    let config: SshConfig = ctx.sshConfig
    let current = config.resolveHost(result.keyName)
    if (current.errorMessage.length > 0) {
      ctx.writeError(current.errorMessage)
      return
    }
    config.addAlias(result.keyName, result.sshHost, result.sshPort, result.sshUser)
    config.saveConfig(ctx.context)
    let info: string = result.keyName + ' -> ' + result.sshUser + '@' + result.sshHost
    if (result.sshPort !== 22) { info += ':' + result.sshPort.toString() }
    ctx.writeOutput('\r\nHost ' + (updated ? 'updated: ' : 'added: ') + info + '\r\nltty> ')
    logger.info('Host added: ' + info)
  }

  private static executeSshConfig(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let host = ctx.sshConfig.resolveHost(result.keyName)
    if (host.errorMessage.length > 0) {
      ctx.writeError(host.errorMessage)
      return
    }
    ctx.writeOutput('\r\nhost ' + result.keyName + '\r\n')
    ctx.writeOutput('hostname ' + host.hostname + '\r\n')
    if (host.user.length > 0) { ctx.writeOutput('user ' + host.user + '\r\n') }
    ctx.writeOutput('port ' + host.port.toString() + '\r\n')
    if (host.identityFile.length > 0) { ctx.writeOutput('identityfile ' + host.identityFile + '\r\n') }
    ctx.writeOutput('ltty> ')
  }

  private static executeAliasRm(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let config: SshConfig = ctx.sshConfig
    if (config.removeAlias(result.keyName)) {
      config.saveConfig(ctx.context)
      ctx.writeOutput('\r\nHost removed: ' + result.keyName + '\r\nltty> ')
    } else {
      ctx.writeError('Host not found: ' + result.keyName)
    }
  }

  private static executeAliasList(ctx: KeyCommandContext): void {
    let hosts = ctx.sshConfig.getHosts()
    if (hosts.length === 0) {
      ctx.writeOutput('\r\nNo hosts configured. Use host add to create one.\r\nltty> ')
      return
    }
    ctx.writeOutput('\r\n  HOST        USER@HOST\r\n')
    ctx.writeOutput('  ----        ---------\r\n')
    for (let i = 0; i < hosts.length; i++) {
      let h = hosts[i]
      let target: string = h.user + '@' + h.hostname
      if (h.port !== 22) { target += ':' + h.port.toString() }
      ctx.writeOutput('  ' + h.alias.padEnd(12, ' ') + target + '\r\n')
    }
    ctx.writeOutput('ltty> ')
  }

  static executeKeypush(result: KeyCommandResult, ctx: KeyCommandContext): void {
    let key: KeyPairInfo | null = SshKeyManager.findKeyByName(ctx.context, result.keyName)
    if (key === null) {
      ctx.writeError('Key not found: ' + result.keyName + '. Use key list to see available names.')
      return
    }
    let pubText: string = key.publicKeyText
    if (pubText.length === 0) {
      pubText = SshKeyManager.readPublicKeyText(ctx.context, result.keyName)
    }
    if (pubText.length === 0) {
      ctx.writeError('Cannot read public key for: ' + result.keyName)
      return
    }
    ctx.setPendingKeypush(result.keyName, pubText)
    ctx.onConnect(result.sshHost, result.sshPort, result.sshUser)
  }

  private static fileName(filePath: string): string {
    let lastSlash: number = filePath.lastIndexOf('/')
    return lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath
  }
}

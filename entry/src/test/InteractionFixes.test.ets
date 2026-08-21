import { describe, it, expect } from '@ohos/hypium'
import {
  CommandParser,
  CommandParseResult,
  KeyCommandKind,
  KeyCommandResult,
  TransferCommandResult,
  TransferDirection
} from '../main/ets/model/command/CommandParser'
import { SshConfig } from '../main/ets/model/ssh/SshConfig'
import { SshClient } from '../main/ets/model/ssh/SshClient'
import {
  SshEscapeEvent,
  SshEscapeEventKind,
  SshEscapeParser,
  SshEscapeResult
} from '../main/ets/model/ssh/SshEscapeParser'
import { BridgeMessage, BridgeProtocol } from '../main/ets/model/bridge/BridgeProtocol'
import { InteractionPolicy, WorkspaceNavigationAction } from '../main/ets/model/ui/InteractionPolicy'
import { KeyCodeMap } from '../main/ets/common/constants/KeyCodeMap'
import { TerminalOutputBuffer } from '../main/ets/model/terminal/TerminalOutputBuffer'
import {
  TerminalInputAction,
  TerminalInputActionKind,
  TerminalInputParser
} from '../main/ets/model/terminal/TerminalInputParser'
import { LocalCommandLine } from '../main/ets/model/terminal/LocalCommandLine'
import { LocalCommandOutput } from '../main/ets/model/terminal/LocalCommandOutput'
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'
import { FileTransferLifecycle, FileTransferPhase } from '../main/ets/model/transfer/FileTransferLifecycle'
import {
  FileTransferFailureInfo,
  FileTransferFailureKind,
  FileTransferFailurePresenter
} from '../main/ets/model/transfer/FileTransferFailure'
import { BrowserLauncher } from '../main/ets/model/browser/BrowserLauncher'
import { CommandBarViewModel } from '../main/ets/viewmodel/CommandBarViewModel'
import { AppTheme, ColorMode, TransparencyMode, TransparencyPolicy } from '../main/ets/view/theme/ThemeManager'
import { UserGuideFileDecision, UserGuidePolicy } from '../main/ets/model/guide/UserGuidePolicy'
import { TransferFileManager } from '../main/ets/model/transfer/TransferFileManager'
import { DownloadsAccessManager } from '../main/ets/model/transfer/DownloadsAccessManager'
import { ApplicationCloseCoordinator } from '../main/ets/model/ui/ApplicationCloseCoordinator'
import { TerminalTextPolicy } from '../main/ets/common/security/TerminalTextPolicy'
import {
  LocalCompletionEngine,
  LocalCompletionSet,
  LocalCompletionUpdate,
  LocalCompletionUpdateKind
} from '../main/ets/model/terminal/LocalCompletionEngine'
import {
  LocalCompletionLayout,
  LocalCompletionNavigation,
  LocalCompletionRenderer
} from '../main/ets/model/terminal/LocalCompletionRenderer'

function asciiBytes(text: string): Uint8Array {
  let result: Uint8Array = new Uint8Array(text.length)
  for (let i: number = 0; i < text.length; i++) {
    result[i] = text.charCodeAt(i)
  }
  return result
}

export default function interactionFixesTest() {
  describe('InteractionFixes', () => {
    it('acceptsAuthEventsOnlyForTheCurrentSessionGeneration', 0, () => {
      expect(SshClient.isCurrentAuthEvent('41', 7, '41', 7)).assertEqual(true)
      expect(SshClient.isCurrentAuthEvent('41', 7, '42', 7)).assertEqual(false)
      expect(SshClient.isCurrentAuthEvent('41', 7, '41', 8)).assertEqual(false)
      expect(SshClient.isCurrentAuthEvent('', 7, '', 7)).assertEqual(false)
    })

    it('parsesOneShotSafeSshVerboseWithoutChangingTheSavedHost', 0, () => {
      let config: SshConfig = new SshConfig()
      let verbose: CommandParseResult = CommandParser.parseCommand('ssh -v root@example.com', config)
      let normal: CommandParseResult = CommandParser.parseCommand('ssh root@example.com', config)
      let duplicate: CommandParseResult = CommandParser.parseCommand('ssh -v -v root@example.com', config)
      let unsupported: CommandParseResult = CommandParser.parseCommand('ssh -vv root@example.com', config)
      expect(verbose.isValid).assertEqual(true)
      expect(verbose.verbose).assertEqual(true)
      expect(normal.verbose).assertEqual(false)
      expect(duplicate.errorMessage).assertEqual('Duplicate SSH option: -v')
      expect(unsupported.errorMessage).assertEqual('Unsupported SSH option: -vv')
    })

    it('keepsVerboseDiagnosticsOnAClosedFieldWhitelist', 0, () => {
      let label: string = SshClient.safeRustEventLogLabel(
        'HOST_KEY_PROMPT:target\tssh-ed25519 SHA256:secret\t[private.example]:2222 ssh-ed25519 secret')
      expect(label).assertEqual('rust event: HOST_KEY_PROMPT:target\tredacted')
      expect(label.includes('secret')).assertEqual(false)
      expect(SshClient.safeRustEventLogLabel('AUTH:target:authentication was rejected'))
        .assertEqual('rust event: AUTH:target:authentication was rejected')
      expect(SshClient.safeRustEventLogLabel('AUTH:target:server says private.example'))
        .assertEqual('rust event: AUTH:target')
      expect(SessionViewModel.safeSshErrorLogLabel('target:connection timed out after 1000 ms'))
        .assertEqual('SSH error: target:connection timed out after 1000 ms')
      expect(SessionViewModel.safeSshErrorLogLabel('target:private.example refused the key'))
        .assertEqual('SSH error')
      let line: string = SessionViewModel.formatSshDiagnostic(
        '{"layer":"target","stage":"connect","status":"started","host":"private.example"}')
      expect(line.includes('Target transport: started.')).assertEqual(true)
      expect(line.includes('private.example')).assertEqual(false)
      let rejected: string = SessionViewModel.formatSshDiagnostic(
        '{"layer":"target","stage":"raw_packet","status":"started"}')
      expect(rejected.includes('Diagnostic event rejected.')).assertEqual(true)
      let refused: string = SessionViewModel.formatSshDiagnostic(
        '{"layer":"target","stage":"connect","status":"failed","reason":"tcp_refused","error":"private.example"}')
      expect(refused.includes('Target TCP connection: refused.')).assertEqual(true)
      expect(refused.includes('private.example')).assertEqual(false)
    })

    it('parsesKeySubcommandsFromTheCorrectArgument', 0, () => {
      let config: SshConfig = new SshConfig()
      let showResult: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('key show deploy', config)
      let removeResult: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('key rm deploy', config)
      let importResult: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('key import C:\\keys\\source deploy', config)
      let exportResult: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('key export deploy', config)
      expect(showResult instanceof KeyCommandResult).assertEqual(true)
      expect(removeResult instanceof KeyCommandResult).assertEqual(true)
      expect(importResult instanceof KeyCommandResult).assertEqual(true)
      expect(exportResult instanceof KeyCommandResult).assertEqual(true)
      if (showResult instanceof KeyCommandResult) { expect(showResult.keyName).assertEqual('deploy') }
      if (removeResult instanceof KeyCommandResult) { expect(removeResult.keyName).assertEqual('deploy') }
      if (importResult instanceof KeyCommandResult) {
        expect(importResult.sourcePath).assertEqual('C:\\keys\\source')
        expect(importResult.keyName).assertEqual('deploy')
      }
      if (exportResult instanceof KeyCommandResult) {
        expect(exportResult.kind).assertEqual(KeyCommandKind.KEYEXPORT)
        expect(exportResult.keyName).assertEqual('deploy')
        expect(exportResult.destinationName).assertEqual('deploy')
      }
    })

    it('recognizesExitAsALocalCommand', 0, () => {
      let result: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('exit', new SshConfig())
      expect(result instanceof KeyCommandResult).assertEqual(true)
      if (result instanceof KeyCommandResult) { expect(result.kind).assertEqual(KeyCommandKind.EXIT) }
      let invalid = CommandParser.parseInput('exit now', new SshConfig())
      expect(invalid instanceof KeyCommandResult).assertEqual(true)
      if (invalid instanceof KeyCommandResult) { expect(invalid.errorMessage).assertEqual('Usage: exit') }
    })

    it('supportsTopicHelpAndExactCommandNames', 0, () => {
      let help: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('help ssh-keygen', new SshConfig())
      let commandHelp: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('host --help', new SshConfig())
      expect(help instanceof KeyCommandResult).assertEqual(true)
      expect(commandHelp instanceof KeyCommandResult).assertEqual(true)
      if (help instanceof KeyCommandResult) { expect(help.keyName).assertEqual('ssh-keygen') }
      if (commandHelp instanceof KeyCommandResult) { expect(commandHelp.keyName).assertEqual('host') }
      expect(CommandParser.parseInput('ssh-keygen-bad -t rsa', new SshConfig())).assertEqual(null)
    })

    it('acceptsAsciiAndFullwidthQuestionMarksAsStartupHelp', 0, () => {
      let ascii = CommandParser.parseInput('?', new SshConfig())
      let fullwidth = CommandParser.parseInput('？', new SshConfig())
      expect(ascii instanceof KeyCommandResult).assertEqual(true)
      expect(fullwidth instanceof KeyCommandResult).assertEqual(true)
      if (ascii instanceof KeyCommandResult) { expect(ascii.kind).assertEqual(KeyCommandKind.HELP) }
      if (fullwidth instanceof KeyCommandResult) { expect(fullwidth.kind).assertEqual(KeyCommandKind.HELP) }
    })

    it('keepsAllTopLevelHelpAliasesSeparateFromTopicHelp', 0, () => {
      let aliases: string[] = ['help', '?', '？', '-h', '--help']
      for (let i: number = 0; i < aliases.length; i++) {
        let result = CommandParser.parseInput(aliases[i], new SshConfig())
        expect(result instanceof KeyCommandResult).assertEqual(true)
        if (result instanceof KeyCommandResult) {
          expect(result.kind).assertEqual(KeyCommandKind.HELP)
          expect(result.keyName).assertEqual('')
        }
      }
      let topic = CommandParser.parseInput('help ssh', new SshConfig())
      expect(topic instanceof KeyCommandResult).assertEqual(true)
      if (topic instanceof KeyCommandResult) { expect(topic.keyName).assertEqual('ssh') }
    })

    it('decidesUserGuideUpdatesFromExactBytesAndOwnership', 0, () => {
      let current: Uint8Array = asciiBytes('<!-- leantty-owned-user-guide -->current')
      let old: Uint8Array = asciiBytes('<!-- leantty-owned-user-guide -->old')
      let foreign: Uint8Array = asciiBytes('<!doctype html><title>mine</title>')
      expect(UserGuidePolicy.decide(null, current)).assertEqual(UserGuideFileDecision.CREATE)
      expect(UserGuidePolicy.decide(current, current)).assertEqual(UserGuideFileDecision.CURRENT)
      expect(UserGuidePolicy.decide(old, current)).assertEqual(UserGuideFileDecision.REPLACE_OWNED)
      expect(UserGuidePolicy.decide(foreign, current)).assertEqual(UserGuideFileDecision.CONFLICT)
    })

    it('buildsOnlyTheTwoFixedUserGuidePaths', 0, () => {
      expect(UserGuidePolicy.guidePath('/downloads/', 'com.leantty.app'))
        .assertEqual('/downloads/com.leantty.app/LeanTTY-User-Guide.html')
      expect(UserGuidePolicy.tempPath('/downloads', 'com.leantty.app'))
        .assertEqual('/downloads/com.leantty.app/.LeanTTY-User-Guide.html.tmp')
      expect(UserGuidePolicy.validateBundleName('../other')).assertEqual(false)
      expect(UserGuidePolicy.validateBundleName('com.leantty.app')).assertEqual(true)
    })

    it('allowsOnlyTheExactCanonicalLocalUserGuideUri', 0, () => {
      let expected: string = 'file://docs/storage/Users/currentUser/Download/com.leantty.app/' +
        'LeanTTY-User-Guide.html'
      expect(BrowserLauncher.isAllowedUserGuideUrl(expected, expected)).assertEqual(true)
      expect(BrowserLauncher.isAllowedUserGuideUrl(expected + '#section', expected)).assertEqual(false)
      expect(BrowserLauncher.isAllowedUserGuideUrl(expected.replace('LeanTTY-User-Guide.html', 'other.html'), expected))
        .assertEqual(false)
      expect(BrowserLauncher.isAllowedUserGuideUrl('https://example.com', expected)).assertEqual(false)
      expect(UserGuidePolicy.osc8Link(expected)).assertEqual(
        '\u001b]8;;' + expected + '\u001b\\LeanTTY-User-Guide.html\u001b]8;;\u001b\\')
    })

    it('keepsUnknownAndInvalidLocalCommandsDistinct', 0, () => {
      let unknown: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('not-a-command', new SshConfig())
      let empty: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('', new SshConfig())
      let invalidSsh: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh', new SshConfig())
      expect(unknown).assertEqual(null)
      expect(empty instanceof CommandParseResult).assertEqual(true)
      expect(invalidSsh instanceof CommandParseResult).assertEqual(true)
      if (empty instanceof CommandParseResult) {
        expect(empty.errorMessage).assertEqual('Usage: ssh <user>@<host>')
      }
      if (invalidSsh instanceof CommandParseResult) {
        expect(invalidSsh.errorMessage).assertEqual('Username required')
      }
    })

    it('parsesPutAndGetWithTheSshConnectionModel', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n  Port 2200\n' +
        '  IdentityFile deploy-key\n')
      let put = CommandParser.parseInput('put "daily report.txt" prod:/srv/reports/daily.txt', config)
      let get = CommandParser.parseInput('get -p 2222 user@[2001:db8::1]:/var/log/app.log', config)
      expect(put instanceof TransferCommandResult).assertEqual(true)
      if (put instanceof TransferCommandResult) {
        expect(put.direction).assertEqual(TransferDirection.PUT)
        expect(put.localPath).assertEqual('daily report.txt')
        expect(put.remotePath).assertEqual('/srv/reports/daily.txt')
        expect(put.host).assertEqual('files.example.com')
        expect(put.port).assertEqual(2200)
        expect(put.username).assertEqual('deploy')
        expect(put.identityFile).assertEqual('deploy-key')
      }
      expect(get instanceof TransferCommandResult).assertEqual(true)
      if (get instanceof TransferCommandResult) {
        expect(get.direction).assertEqual(TransferDirection.GET)
        expect(get.host).assertEqual('2001:db8::1')
        expect(get.port).assertEqual(2222)
        expect(get.username).assertEqual('user')
        expect(get.remotePath).assertEqual('/var/log/app.log')
        expect(get.automaticLocalName).assertEqual(true)
      }
    })

    it('treatsLeadingDotSlashAsTheExplicitDownloadsRoot', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n')
      let put = CommandParser.parseInput('put ./reports/app.log prod:/incoming/', config)
      let getDirectory = CommandParser.parseInput('get prod:/reports/app.log ./saved/', config)
      let getRoot = CommandParser.parseInput('get prod:/reports/app.log ./', config)
      let nestedDot = CommandParser.parseInput('put ./reports/./app.log prod:/incoming/', config)
      expect(put instanceof TransferCommandResult).assertEqual(true)
      expect(getDirectory instanceof TransferCommandResult).assertEqual(true)
      expect(getRoot instanceof TransferCommandResult).assertEqual(true)
      if (put instanceof TransferCommandResult) {
        expect(put.isValid).assertEqual(true)
        expect(put.localPath).assertEqual('reports/app.log')
        expect(put.remotePath).assertEqual('/incoming/app.log')
      }
      if (getDirectory instanceof TransferCommandResult) {
        expect(getDirectory.isValid).assertEqual(true)
        expect(getDirectory.localPath).assertEqual('saved/')
        expect(getDirectory.localTargetDirectory).assertEqual(true)
      }
      if (getRoot instanceof TransferCommandResult) {
        expect(getRoot.isValid).assertEqual(true)
        expect(getRoot.localPath).assertEqual('')
        expect(getRoot.localTargetDirectory).assertEqual(true)
        expect(getRoot.automaticLocalName).assertEqual(true)
      }
      expect(nestedDot instanceof TransferCommandResult && !nestedDot.isValid).assertEqual(true)
    })

    it('keepsTransferPathsBoundedAndScpAsAHint', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n')
      let escaped = CommandParser.parseInput('put daily\\ report.txt prod:/srv/daily.txt', config)
      let traversal = CommandParser.parseInput('put ../secret prod:/srv/secret', config)
      let absolute = CommandParser.parseInput('get prod:/srv/file /tmp/file', config)
      let directory = CommandParser.parseInput('get prod:/srv/logs/', config)
      let overwrite = CommandParser.parseInput('get --overwrite prod:/srv/file', config)
      let unterminated = CommandParser.parseInput('put "daily report.txt prod:/srv/file', config)
      let scp = CommandParser.parseInput('scp anything anywhere', config)
      expect(escaped instanceof TransferCommandResult).assertEqual(true)
      if (escaped instanceof TransferCommandResult) { expect(escaped.isValid).assertEqual(true) }
      for (let result of [traversal, absolute, directory, overwrite, unterminated]) {
        expect(result instanceof TransferCommandResult).assertEqual(true)
        if (result instanceof TransferCommandResult) { expect(result.isValid).assertEqual(false) }
      }
      expect(scp instanceof TransferCommandResult).assertEqual(true)
      if (scp instanceof TransferCommandResult) {
        expect(scp.direction).assertEqual(TransferDirection.SCP_HINT)
        expect(scp.isValid).assertEqual(false)
      }
    })

    it('parsesExistingSubdirectoryAndExplicitDirectoryTargets', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n')
      let putDirectory = CommandParser.parseInput('put reports/app.log prod:/srv/inbox/', config)
      let putHome = CommandParser.parseInput('put reports/app.log prod:', config)
      let getDirectory = CommandParser.parseInput('get prod:/logs/app.log reports/', config)
      let explicitGet = CommandParser.parseInput('get prod:/logs/app.log reports/today.log', config)
      for (let parsed of [putDirectory, putHome, getDirectory, explicitGet]) {
        expect(parsed instanceof TransferCommandResult).assertEqual(true)
        if (parsed instanceof TransferCommandResult) { expect(parsed.isValid).assertEqual(true) }
      }
      if (putDirectory instanceof TransferCommandResult) {
        expect(putDirectory.remoteTargetDirectory).assertEqual(true)
        expect(putDirectory.remotePath).assertEqual('/srv/inbox/app.log')
      }
      if (putHome instanceof TransferCommandResult) {
        expect(putHome.remoteTargetDirectory).assertEqual(true)
        expect(putHome.remotePath).assertEqual('./app.log')
      }
      if (getDirectory instanceof TransferCommandResult) {
        expect(getDirectory.localTargetDirectory).assertEqual(true)
        expect(getDirectory.automaticLocalName).assertEqual(true)
        expect(getDirectory.localPath).assertEqual('reports/')
      }
      if (explicitGet instanceof TransferCommandResult) {
        expect(explicitGet.localTargetDirectory).assertEqual(false)
        expect(explicitGet.automaticLocalName).assertEqual(false)
      }
    })

    it('rejectsUnsafePathComponentsAndSupportsOptionTerminator', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n')
      let dashFile = CommandParser.parseInput('put -- -report.txt prod:/srv/', config)
      let emptyComponent = CommandParser.parseInput('put reports//app.log prod:/srv/app.log', config)
      let dotComponent = CommandParser.parseInput('get prod:/app.log reports/./app.log', config)
      let backslash = CommandParser.parseInput("get prod:/app.log 'reports\\app.log'", config)
      let control = CommandParser.parseInput('get prod:/app\u001b[31m.log', config)
      expect(dashFile instanceof TransferCommandResult).assertEqual(true)
      if (dashFile instanceof TransferCommandResult) {
        expect(dashFile.isValid).assertEqual(true)
        expect(dashFile.remotePath).assertEqual('/srv/-report.txt')
      }
      for (let parsed of [emptyComponent, dotComponent, backslash, control]) {
        expect(parsed instanceof TransferCommandResult).assertEqual(true)
        if (parsed instanceof TransferCommandResult) { expect(parsed.isValid).assertEqual(false) }
      }
    })

    it('rejectsEveryUnsupportedTransferOptionArityAndDirection', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n')
      for (let input of [
        'put', 'put report.txt', 'put one two prod:/target',
        'get', 'get prod:/one first second',
        'put -p prod report.txt prod:/target', 'get -p 0 prod:/one',
        'get -p 65536 prod:/one', 'put -p 22 -p 23 report.txt prod:/target',
        'get -i first -i second prod:/one', 'put -i report.txt',
        'put --force report.txt prod:/target', 'put --overwrite report.txt prod:/target',
        'get --force prod:/one', 'get --overwrite prod:/one',
        'put prod:/remote report.txt', 'get report.txt prod:/remote',
        'put report.txt prod', 'get prod'
      ]) {
        let parsed = CommandParser.parseInput(input, config)
        expect(parsed instanceof TransferCommandResult).assertEqual(true)
        if (parsed instanceof TransferCommandResult) { expect(parsed.isValid).assertEqual(false) }
      }
    })

    it('handlesTransferQuotesEscapesUnicodeAndUtf8Bounds', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n')
      let unicode = CommandParser.parseInput("put '报告 😀.txt' prod:'/srv/报告 😀.txt'", config)
      let empty = CommandParser.parseInput("put '' prod:/target", config)
      let trailingEscape = CommandParser.parseInput('put report.txt prod:/target' + '\\', config)
      let unpairedLocal = CommandParser.parseInput('put bad\uD800.txt prod:/target', config)
      let unpairedRemote = CommandParser.parseInput('get prod:/bad\uDC00.txt', config)
      let longLocal = CommandParser.parseInput('put ' + 'a'.repeat(256) + ' prod:/target', config)
      let longRemote = CommandParser.parseInput('get prod:/' + 'a'.repeat(4097), config)
      expect(unicode instanceof TransferCommandResult).assertEqual(true)
      if (unicode instanceof TransferCommandResult) {
        expect(unicode.isValid).assertEqual(true)
        expect(unicode.localPath).assertEqual('报告 😀.txt')
        expect(unicode.remotePath).assertEqual('/srv/报告 😀.txt')
      }
      expect(empty instanceof TransferCommandResult && !empty.isValid).assertEqual(true)
      expect(trailingEscape instanceof TransferCommandResult && !trailingEscape.isValid).assertEqual(true)
      expect(unpairedLocal instanceof TransferCommandResult && !unpairedLocal.isValid).assertEqual(true)
      expect(unpairedRemote instanceof TransferCommandResult && !unpairedRemote.isValid).assertEqual(true)
      expect(longLocal instanceof TransferCommandResult && !longLocal.isValid).assertEqual(true)
      expect(longRemote instanceof TransferCommandResult && !longRemote.isValid).assertEqual(true)
    })

    it('keepsSshAndTransferConnectionResolutionConsistent', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n' +
        '  Port 2200\n  IdentityFile default-key\n  ConnectTimeout 9\n')
      let ssh = CommandParser.parseInput('ssh prod', config)
      let put = CommandParser.parseInput('put report.txt prod:/report.txt', config)
      let get = CommandParser.parseInput('get prod:/report.txt', config)
      expect(ssh instanceof CommandParseResult).assertEqual(true)
      expect(put instanceof TransferCommandResult).assertEqual(true)
      expect(get instanceof TransferCommandResult).assertEqual(true)
      if (ssh instanceof CommandParseResult && put instanceof TransferCommandResult &&
        get instanceof TransferCommandResult) {
        for (let connection of [put, get]) {
          expect(connection.host).assertEqual(ssh.host)
          expect(connection.port).assertEqual(ssh.port)
          expect(connection.username).assertEqual(ssh.username)
          expect(connection.identityFile).assertEqual(ssh.identityFile)
          expect(connection.connectTimeoutMs).assertEqual(ssh.connectTimeoutMs)
        }
      }
    })

    it('keepsTransferIdentityAndPortOverridesCommandLocal', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n' +
        '  Port 2200\n  IdentityFile default-key\n')
      let originalConfig: string = config.previewConfigText()
      let getOverride = CommandParser.parseInput(
        'get -p 2222 -i one-shot-key prod:/report.txt', config)
      let putOverride = CommandParser.parseInput(
        'put -p 2223 -i other-one-shot-key report.txt prod:/report.txt', config)
      let followingSsh = CommandParser.parseInput('ssh prod', config)
      let followingPut = CommandParser.parseInput('put report.txt prod:/report.txt', config)
      let followingGet = CommandParser.parseInput('get prod:/report.txt', config)
      expect(getOverride instanceof TransferCommandResult).assertEqual(true)
      expect(putOverride instanceof TransferCommandResult).assertEqual(true)
      expect(followingSsh instanceof CommandParseResult).assertEqual(true)
      expect(followingPut instanceof TransferCommandResult).assertEqual(true)
      expect(followingGet instanceof TransferCommandResult).assertEqual(true)
      if (getOverride instanceof TransferCommandResult && putOverride instanceof TransferCommandResult &&
        followingSsh instanceof CommandParseResult && followingPut instanceof TransferCommandResult &&
        followingGet instanceof TransferCommandResult) {
        expect(getOverride.port).assertEqual(2222)
        expect(getOverride.identityFile).assertEqual('one-shot-key')
        expect(putOverride.port).assertEqual(2223)
        expect(putOverride.identityFile).assertEqual('other-one-shot-key')
        for (let connection of [followingSsh, followingPut, followingGet]) {
          expect(connection.port).assertEqual(2200)
          expect(connection.identityFile).assertEqual('default-key')
        }
      }
      expect(config.previewConfigText()).assertEqual(originalConfig)
    })

    it('keepsHostManagementAndLocalCommandParsingIndependentFromTransfers', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName files.example.com\n  User deploy\n')
      let originalConfig: string = config.previewConfigText()
      CommandParser.parseInput('get -i one-shot-key prod:/report.txt', config)
      CommandParser.parseInput('put report.txt prod:/report.txt', config)
      let hostAdd = CommandParser.parseInput('host add next ops@next.example.com:2222', config)
      let hostSet = CommandParser.parseInput('host set prod deploy@new.example.com:2200', config)
      let hostList = CommandParser.parseInput('host list', config)
      let keyList = CommandParser.parseInput('key list', config)
      let help = CommandParser.parseInput('help', config)
      let exit = CommandParser.parseInput('exit', config)
      expect(hostAdd instanceof KeyCommandResult && hostAdd.kind === KeyCommandKind.ALIAS_ADD).assertEqual(true)
      expect(hostSet instanceof KeyCommandResult && hostSet.kind === KeyCommandKind.HOST_SET).assertEqual(true)
      expect(hostList instanceof KeyCommandResult && hostList.kind === KeyCommandKind.ALIAS_LIST).assertEqual(true)
      expect(keyList instanceof KeyCommandResult && keyList.kind === KeyCommandKind.KEYS).assertEqual(true)
      expect(help instanceof KeyCommandResult && help.kind === KeyCommandKind.HELP).assertEqual(true)
      expect(exit instanceof KeyCommandResult && exit.kind === KeyCommandKind.EXIT).assertEqual(true)
      expect(config.previewConfigText()).assertEqual(originalConfig)
    })

    it('generatesMinimalAutomaticDownloadNames', 0, () => {
      expect(TransferFileManager.automaticName('app.log', 0)).assertEqual('app.log')
      expect(TransferFileManager.automaticName('app.log', 1)).assertEqual('app (1).log')
      expect(TransferFileManager.automaticName('.env', 2)).assertEqual('.env (2)')
      expect(TransferFileManager.automaticName('.config.json', 4)).assertEqual('.config (4).json')
      expect(TransferFileManager.automaticName('archive.tar.gz', 5)).assertEqual('archive.tar (5).gz')
      expect(TransferFileManager.automaticName('trailing.', 6)).assertEqual('trailing (6).')
      expect(TransferFileManager.automaticName('报告.txt', 3)).assertEqual('报告 (3).txt')
      expect(TransferFileManager.automaticName('app.log', 9999)).assertEqual('app (9999).log')
      let longName: string = 'a'.repeat(252) + '.log'
      let numbered: string = TransferFileManager.automaticName(longName, 1)
      expect(numbered.endsWith(' (1).log')).assertEqual(true)
      expect(numbered.length).assertEqual(255)
      let unicodeName: string = '😀'.repeat(62) + 'abc.log'
      let unicodeNumbered: string = TransferFileManager.automaticName(unicodeName, 9999)
      expect(unicodeNumbered.endsWith(' (9999).log')).assertEqual(true)
      expect(unicodeNumbered.includes('\uFFFD')).assertEqual(false)
      let boundedCandidates: Set<string> = new Set<string>()
      for (let index: number = 0; index < 10000; index++) {
        boundedCandidates.add(TransferFileManager.automaticName('bounded.log', index))
      }
      expect(boundedCandidates.size).assertEqual(10000)
    })

    it('formatsAStableAsciiFileTransferProgressLine', 0, () => {
      expect(SessionViewModel.formatTransferProgress(32768, 131072, 65536, false))
        .assertEqual('[━━━━━━━╸──────────────────────]  25% 32.0/128.0 KiB  64.0 KiB/s  ETA 00:02')
      expect(SessionViewModel.formatTransferProgress(12288, 0, 4096, false))
        .assertEqual('[──────────────────────────────]  --% 12.0 KiB  4.0 KiB/s  ETA --:--')
      expect(SessionViewModel.formatTransferProgress(0, 0, 0, true))
        .assertEqual('[━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━] 100% 0 B  --  Finalizing...')
      expect(SessionViewModel.formatTransferProgress(131072, 131072, 65536, true))
        .assertEqual('[━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━] 100% 128.0/128.0 KiB  64.0 KiB/s  Finalizing...')
      expect(SessionViewModel.styleTransferProgress(
        '[━━━━━━━╸──────────────────────]  25% 32.0/128.0 KiB  64.0 KiB/s  ETA 00:02', false))
        .assertEqual('\u001b[36m[━━━━━━━╸──────────────────────]  25%\u001b[0m 32.0/128.0 KiB  64.0 KiB/s  ETA 00:02')
      expect(SessionViewModel.styleTransferProgress(
        '[━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━] 100% 128.0/128.0 KiB  64.0 KiB/s  Finalizing...', true))
        .assertEqual('\u001b[36m[━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━] 100%\u001b[0m 128.0/128.0 KiB  64.0 KiB/s  ' +
          '\u001b[33mFinalizing...\u001b[0m')
      expect(SessionViewModel.formatTransferClock(3723)).assertEqual('1:02:03')
      expect(SessionViewModel.formatTransferRate(5 * 1024 * 1024)).assertEqual('5.0 MiB/s')
      expect(SessionViewModel.formatTransferCompletion(118349760, 22000))
        .assertEqual('112.9 MiB in 00:22, avg 5.1 MiB/s')
    })

    it('keepsFileTransferLifecyclePaneLocalAndRejectsInvalidTransitions', 0, () => {
      let first: FileTransferLifecycle = new FileTransferLifecycle()
      let second: FileTransferLifecycle = new FileTransferLifecycle()
      expect(first.transition(FileTransferPhase.TRANSFERRING)).assertEqual(false)
      expect(first.transition(FileTransferPhase.PREPARING)).assertEqual(true)
      expect(first.isActive()).assertEqual(true)
      expect(second.getPhase()).assertEqual(FileTransferPhase.IDLE)
      expect(first.transition(FileTransferPhase.TRANSFERRING)).assertEqual(true)
      expect(first.transition(FileTransferPhase.SUCCEEDED)).assertEqual(false)
      expect(first.transition(FileTransferPhase.FINALIZING)).assertEqual(true)
      expect(first.transition(FileTransferPhase.SUCCEEDED)).assertEqual(true)
      expect(first.isActive()).assertEqual(false)
      expect(first.transition(FileTransferPhase.IDLE)).assertEqual(true)
    })

    it('allowsEveryFileTransferTerminalStateToReturnToIdle', 0, () => {
      for (let terminal of [
        FileTransferPhase.SUCCEEDED, FileTransferPhase.FAILED, FileTransferPhase.CANCELLED
      ]) {
        let lifecycle: FileTransferLifecycle = new FileTransferLifecycle()
        expect(lifecycle.transition(FileTransferPhase.PREPARING)).assertEqual(true)
        if (terminal === FileTransferPhase.SUCCEEDED) {
          expect(lifecycle.transition(FileTransferPhase.TRANSFERRING)).assertEqual(true)
          expect(lifecycle.transition(FileTransferPhase.FINALIZING)).assertEqual(true)
        }
        expect(lifecycle.transition(terminal)).assertEqual(true)
        expect(lifecycle.transition(FileTransferPhase.IDLE)).assertEqual(true)
      }
    })

    it('cancelsOnlyTheCurrentPaneWaitDuringDownloadsPreparation', 0, async () => {
      let resolveRequest: () => void = () => {}
      let resolveCancellation: () => void = () => {}
      let sharedRequestCompleted: boolean = false
      let sharedRequest: Promise<void> = new Promise<void>((resolve: () => void) => {
        resolveRequest = resolve
      }).then(() => {
        sharedRequestCompleted = true
      })
      let cancellation: Promise<void> = new Promise<void>((resolve: () => void) => {
        resolveCancellation = resolve
      })
      let waiting: Promise<void> = DownloadsAccessManager.waitForRequest(sharedRequest, cancellation)
      resolveCancellation()
      let cancelled: boolean = false
      try {
        await waiting
      } catch (e) {
        cancelled = ('' + e).includes('TRANSFER_CANCELLED')
      }
      expect(cancelled).assertEqual(true)
      expect(sharedRequestCompleted).assertEqual(false)
      resolveRequest()
      await sharedRequest
      expect(sharedRequestCompleted).assertEqual(true)
    })

    it('mapsFileTransferFailuresToActionableBoundedMessages', 0, () => {
      let permission = FileTransferFailurePresenter.describe(
        'WRITE', 'server detail: Permission denied\u001b[31msecret', 'put')
      let space = FileTransferFailurePresenter.describe('WRITE', 'No space left on device', 'get')
      let auth = FileTransferFailurePresenter.describe('AUTH', 'password=do-not-display', 'get')
      let unknown = FileTransferFailurePresenter.describe('bad\u001b[2Jcode', 'private detail', 'put')
      expect(permission.kind).assertEqual(FileTransferFailureKind.PERMISSION)
      expect(permission.message.includes('remote target directory')).assertEqual(true)
      expect(permission.message.includes('\r\n')).assertEqual(true)
      expect(permission.message.includes('secret')).assertEqual(false)
      expect(space.kind).assertEqual(FileTransferFailureKind.SPACE)
      expect(space.message.includes('Downloads')).assertEqual(true)
      expect(auth.kind).assertEqual(FileTransferFailureKind.AUTHENTICATION)
      expect(auth.message.includes('do-not-display')).assertEqual(false)
      expect(unknown.kind).assertEqual(FileTransferFailureKind.UNKNOWN)
      expect(unknown.message.includes('\u001b')).assertEqual(false)
      expect(unknown.message.includes('private detail')).assertEqual(false)
    })

    it('distinguishesTransferConflictsPathsServicesAndCleanup', 0, () => {
      expect(FileTransferFailurePresenter.describe('LOCAL_CONFLICT', '', 'get').kind)
        .assertEqual(FileTransferFailureKind.LOCAL_CONFLICT)
      expect(FileTransferFailurePresenter.describe('REMOTE_CONFLICT', '', 'put').kind)
        .assertEqual(FileTransferFailureKind.REMOTE_CONFLICT)
      expect(FileTransferFailurePresenter.describe('REMOTE_PATH', '', 'get').kind)
        .assertEqual(FileTransferFailureKind.PATH)
      expect(FileTransferFailurePresenter.describe('SFTP_UNAVAILABLE', '', 'get').kind)
        .assertEqual(FileTransferFailureKind.SFTP_UNAVAILABLE)
      expect(FileTransferFailurePresenter.describe('NETWORK_TIMEOUT', '', 'get').kind)
        .assertEqual(FileTransferFailureKind.NETWORK)
      let keepaliveTimeout: FileTransferFailureInfo =
        FileTransferFailurePresenter.describe('KEEPALIVE_TIMEOUT', '', 'get')
      expect(keepaliveTimeout.kind).assertEqual(FileTransferFailureKind.NETWORK)
      expect(keepaliveTimeout.message.includes('SSH keepalive timed out')).assertEqual(true)
      expect(FileTransferFailurePresenter.describe('HOST_KEY_REJECTED', '', 'get').kind)
        .assertEqual(FileTransferFailureKind.HOST_VERIFICATION)
      expect(FileTransferFailurePresenter.describe('LOCAL_COMMIT', '', 'get').kind)
        .assertEqual(FileTransferFailureKind.COMMIT)
      let remoteCleanup: FileTransferFailureInfo =
        FileTransferFailurePresenter.describe('REMOTE_CLEANUP', '', 'put')
      expect(remoteCleanup.kind).assertEqual(FileTransferFailureKind.CLEANUP)
      expect(remoteCleanup.message.includes('remote temporary file')).assertEqual(true)
      expect(remoteCleanup.message.includes('.leantty-*.part')).assertEqual(true)
      expect(remoteCleanup.message.includes('\r\n')).assertEqual(true)
      let disconnectedGet: FileTransferFailureInfo =
        FileTransferFailurePresenter.describe('SOURCE_CHANGED', '', 'get')
      expect(disconnectedGet.kind).assertEqual(FileTransferFailureKind.NETWORK)
      expect(disconnectedGet.message.includes('network')).assertEqual(true)
      expect(disconnectedGet.message.includes('remote source changed')).assertEqual(true)
      let changedPut: FileTransferFailureInfo =
        FileTransferFailurePresenter.describe('SOURCE_CHANGED', '', 'put')
      expect(changedPut.kind).assertEqual(FileTransferFailureKind.IO)
      expect(changedPut.message.includes('local source changed')).assertEqual(true)
    })

    it('rejectsUnsupportedKeyTypesInsteadOfFallingBack', 0, () => {
      let result: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -t dsa')
      expect(result.errorMessage.length > 0).assertEqual(true)
    })

    it('parsesOpenSshKeyInspectionModes', 0, () => {
      let publicResult: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -y -f ~/.ssh/deploy')
      let infoResult: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -l -f deploy.pub')
      expect(publicResult.kind).assertEqual(KeyCommandKind.KEYPUB)
      expect(infoResult.kind).assertEqual(KeyCommandKind.KEYINFO)
      expect(publicResult.keyName).assertEqual('~/.ssh/deploy')
    })

    it('parsesOnlyTheSecretInputPassphraseChangeForm', 0, () => {
      let standard: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -p -f deploy')
      let reordered: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -f ~/.ssh/deploy -p')
      expect(standard.kind).assertEqual(KeyCommandKind.KEY_PASSPHRASE_CHANGE)
      expect(standard.keyName).assertEqual('deploy')
      expect(reordered.kind).assertEqual(KeyCommandKind.KEY_PASSPHRASE_CHANGE)
      expect(reordered.keyName).assertEqual('~/.ssh/deploy')
      expect(CommandParser.parseSshKeygen('ssh-keygen -p').errorMessage.length > 0).assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -p -f one -f two').errorMessage.length > 0)
        .assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -p -f deploy -N secret').errorMessage.length > 0)
        .assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -p -f deploy extra').errorMessage.length > 0)
        .assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -p -f deploy -y').errorMessage.length > 0)
        .assertEqual(true)
    })

    it('parsesExactOpenSshKnownHostRemovalTargets', 0, () => {
      let defaultPort: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -R server.example.com')
      let customPort: KeyCommandResult =
        CommandParser.parseSshKeygen('ssh-keygen -R [server.example.com]:2222')
      let ipv6: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -R [2001:db8::1]:2200')
      expect(defaultPort.kind).assertEqual(KeyCommandKind.HOST_KEY_REMOVE)
      expect(defaultPort.sshHost).assertEqual('server.example.com')
      expect(defaultPort.sshPort).assertEqual(22)
      expect(customPort.kind).assertEqual(KeyCommandKind.HOST_KEY_REMOVE)
      expect(customPort.sshHost).assertEqual('server.example.com')
      expect(customPort.sshPort).assertEqual(2222)
      expect(ipv6.sshHost).assertEqual('2001:db8::1')
      expect(ipv6.sshPort).assertEqual(2200)
      expect(CommandParser.parseSshKeygen('ssh-keygen -R server.example.com:2222').errorMessage.length > 0)
        .assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -R').errorMessage.length > 0).assertEqual(true)
    })

    it('parsesExactOpenSshKnownHostQueryTargets', 0, () => {
      let defaultPort: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -F server.example.com')
      let customPort: KeyCommandResult =
        CommandParser.parseSshKeygen('ssh-keygen -F [server.example.com]:2222')
      let ipv6: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -F [2001:db8::1]:2200')
      expect(defaultPort.kind).assertEqual(KeyCommandKind.HOST_KEY_FIND)
      expect(defaultPort.sshHost).assertEqual('server.example.com')
      expect(defaultPort.sshPort).assertEqual(22)
      expect(customPort.kind).assertEqual(KeyCommandKind.HOST_KEY_FIND)
      expect(customPort.sshHost).assertEqual('server.example.com')
      expect(customPort.sshPort).assertEqual(2222)
      expect(ipv6.sshHost).assertEqual('2001:db8::1')
      expect(ipv6.sshPort).assertEqual(2200)
      expect(CommandParser.parseSshKeygen('ssh-keygen -F server.example.com:2222').errorMessage.length > 0)
        .assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -F').errorMessage.length > 0).assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -F one extra').errorMessage.length > 0)
        .assertEqual(true)
    })

    it('buildsChangedHostRemovalCommandFromResolvedAliasEndpoint', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName server.example.com\n  Port 2222\n  User deploy\n')
      let parsed: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh prod', config)
      let overridden: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh -p 2200 prod', config)
      expect(parsed instanceof CommandParseResult).assertEqual(true)
      if (parsed instanceof CommandParseResult) {
        let warning: string = SessionViewModel.buildHostKeyChangedWarning(
          parsed.host, parsed.port, 'ssh-ed25519', 'SHA256:old', 'SHA256:new')
        expect(warning.includes('Host: [server.example.com]:2222')).assertEqual(true)
        expect(warning.includes('ssh-keygen -R [server.example.com]:2222')).assertEqual(true)
        expect(warning.includes('ssh-keygen -R prod')).assertEqual(false)
      }
      expect(overridden instanceof CommandParseResult).assertEqual(true)
      if (overridden instanceof CommandParseResult) {
        let warning: string = SessionViewModel.buildHostKeyChangedWarning(
          overridden.host, overridden.port, 'ssh-ed25519', 'SHA256:old', 'SHA256:new')
        expect(warning.includes('ssh-keygen -R [server.example.com]:2200')).assertEqual(true)
      }
    })

    it('keepsProxyJumpFailureAndChangedHostLayersVisibleWithoutExposingDetails', 0, () => {
      expect(SessionViewModel.sshFailureTitle('jump:authentication rejected'))
        .assertEqual('The jump host connection failed.')
      expect(SessionViewModel.sshFailureTitle('target:connection refused'))
        .assertEqual('The target host connection failed.')
      expect(SessionViewModel.sshFailureTitle('connection refused'))
        .assertEqual('The SSH connection failed.')
      let warning: string = SessionViewModel.buildHostKeyChangedWarning(
        'jump.example.com', 2200, 'ssh-ed25519', 'SHA256:old', 'SHA256:new', 'jump')
      expect(warning.startsWith('Jump host identification has changed.')).assertEqual(true)
      expect(warning.includes('Host: [jump.example.com]:2200')).assertEqual(true)
    })

    it('parsesStructuredChangedHostKeyEvents', 0, () => {
      let info = SshClient.parseHostKeyChangedInfo(
        'target\tssh-ed25519\tSHA256:old\tSHA256:new\tserver.example.com\t2222')
      expect(info !== null).assertEqual(true)
      if (info !== null) {
        expect(info.layer).assertEqual('target')
        expect(info.algorithm).assertEqual('ssh-ed25519')
        expect(info.oldFingerprint).assertEqual('SHA256:old')
        expect(info.newFingerprint).assertEqual('SHA256:new')
        expect(info.host).assertEqual('server.example.com')
        expect(info.port).assertEqual(2222)
      }
      expect(SshClient.parseHostKeyChangedInfo('SHA256:new')).assertEqual(null)
    })

    it('formatsProxyJumpAuthenticationPromptsWithoutChangingDirectSshPrompts', 0, () => {
      expect(SessionViewModel.formatPasswordPrompt('target', false)).assertEqual('Password: ')
      expect(SessionViewModel.formatPrivateKeyPassphrasePrompt('/data/key', 'target', false))
        .assertEqual('\r\nThe key at /data/key is encrypted.\r\nEnter passphrase: ')
      expect(SessionViewModel.formatHostKeyPrompt('SHA256:direct', 'target', false))
        .assertEqual('\r\nThe authenticity of this host cannot be established.\r\n' +
          'Fingerprint: SHA256:direct\r\nTrust this host key? Type yes or no: ')
      expect(SessionViewModel.formatAuthenticationHeading('target', false)).assertEqual('')

      expect(SessionViewModel.formatPasswordPrompt('jump', true)).assertEqual('Jump host password: ')
      expect(SessionViewModel.formatPasswordPrompt('target', true)).assertEqual('Target host password: ')
      expect(SessionViewModel.formatPrivateKeyPassphrasePrompt('/data/jump-key', 'jump', true))
        .assertEqual('\r\nThe jump host key at /data/jump-key is encrypted.\r\n' +
          'Enter jump host key passphrase: ')
      expect(SessionViewModel.formatHostKeyPrompt('SHA256:target', 'target', true))
        .assertEqual('\r\nThe authenticity of this target host cannot be established.\r\n' +
          'Fingerprint: SHA256:target\r\nTrust this target host key? Type yes or no: ')
      expect(SessionViewModel.formatAuthenticationHeading('jump', true))
        .assertEqual('Jump host authentication')
      expect(SessionViewModel.formatAuthenticationHeading('target', true))
        .assertEqual('Target host authentication')
    })

    it('parsesOptionalKeyExportFileNameAndRejectsInvalidSyntax', 0, () => {
      let missingName: KeyCommandResult = CommandParser.parseKeyExport('key export')
      let renamed: KeyCommandResult = CommandParser.parseKeyExport('key export deploy deploy-backup')
      let extraName: KeyCommandResult = CommandParser.parseKeyExport('key export deploy backup extra')
      expect(missingName.errorMessage).assertEqual('Usage: key export <key-name> [<file-name>]')
      expect(renamed.keyName).assertEqual('deploy')
      expect(renamed.destinationName).assertEqual('deploy-backup')
      expect(extraName.errorMessage).assertEqual('Usage: key export <key-name> [<file-name>]')
    })

    it('parsesHostCommandsAndMarksLegacyAliasSyntax', 0, () => {
      let host: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('host add prod root@example.com', new SshConfig())
      let alias: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('alias add prod root@example.com', new SshConfig())
      let jumped: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('host add private deploy@target.example.com -J jump', new SshConfig())
      let configured: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput(
          'host set private deploy@target.example.com --connect-timeout 9 -J jump', new SshConfig())
      expect(host instanceof KeyCommandResult).assertEqual(true)
      expect(alias instanceof KeyCommandResult).assertEqual(true)
      if (host instanceof KeyCommandResult) { expect(host.legacySyntax).assertEqual(false) }
      if (alias instanceof KeyCommandResult) { expect(alias.legacySyntax).assertEqual(true) }
      expect(jumped instanceof KeyCommandResult).assertEqual(true)
      if (jumped instanceof KeyCommandResult) { expect(jumped.sshJump).assertEqual('jump') }
      expect(configured instanceof KeyCommandResult).assertEqual(true)
      if (configured instanceof KeyCommandResult) {
        expect(configured.sshJump).assertEqual('jump')
        expect(configured.sshConnectTimeoutMs).assertEqual(9000)
      }
    })

    it('validatesAndPersistsManagedHostConnectTimeout', 0, () => {
      let configured: KeyCommandResult = CommandParser.parseAliasAdd(
        'host add prod deploy@example.com --connect-timeout 25')
      let reset: KeyCommandResult = CommandParser.parseAliasAdd(
        'host set prod deploy@example.com --connect-timeout default')
      let invalid: KeyCommandResult = CommandParser.parseAliasAdd(
        'host add prod deploy@example.com --connect-timeout 301')
      let duplicate: KeyCommandResult = CommandParser.parseAliasAdd(
        'host add prod deploy@example.com --connect-timeout 5 --connect-timeout 6')
      expect(configured.errorMessage).assertEqual('')
      expect(configured.sshConnectTimeoutMs).assertEqual(25000)
      expect(reset.sshConnectTimeoutMs).assertEqual(15000)
      expect(invalid.errorMessage.includes('whole seconds 1-300')).assertEqual(true)
      expect(duplicate.errorMessage).assertEqual('Duplicate host option: --connect-timeout')

      let config: SshConfig = new SshConfig()
      config.loadFromText('')
      config.addAlias('prod', configured.sshHost, configured.sshPort, configured.sshUser,
        null, configured.sshConnectTimeoutMs)
      expect(config.previewConfigText().includes('  ConnectTimeout 25\n')).assertEqual(true)
      config.addAlias('prod', reset.sshHost, reset.sshPort, reset.sshUser,
        null, reset.sshConnectTimeoutMs)
      expect(config.previewConfigText().includes('  ConnectTimeout ')).assertEqual(false)
    })

    it('validatesAndPersistsManagedHostServerAliveSettings', 0, () => {
      let configured: KeyCommandResult = CommandParser.parseAliasAdd(
        'host add prod deploy@example.com --server-alive-interval 0 --server-alive-count-max 7')
      let reset: KeyCommandResult = CommandParser.parseAliasAdd(
        'host set prod deploy@example.com --server-alive-interval default --server-alive-count-max default')
      let invalidInterval: KeyCommandResult = CommandParser.parseAliasAdd(
        'host add prod deploy@example.com --server-alive-interval 3601')
      let invalidCount: KeyCommandResult = CommandParser.parseAliasAdd(
        'host add prod deploy@example.com --server-alive-count-max 0')
      let duplicate: KeyCommandResult = CommandParser.parseAliasAdd(
        'host add prod deploy@example.com --server-alive-count-max 2 --server-alive-count-max 3')
      expect(configured.errorMessage).assertEqual('')
      expect(configured.sshServerAliveIntervalSeconds).assertEqual(0)
      expect(configured.sshServerAliveCountMax).assertEqual(7)
      expect(reset.sshServerAliveIntervalSeconds).assertEqual(30)
      expect(reset.sshServerAliveCountMax).assertEqual(3)
      expect(invalidInterval.errorMessage.includes('whole seconds 0-3600')).assertEqual(true)
      expect(invalidCount.errorMessage.includes('must be 1-100')).assertEqual(true)
      expect(duplicate.errorMessage).assertEqual('Duplicate host option: --server-alive-count-max')

      let config: SshConfig = new SshConfig()
      config.loadFromText('')
      config.addAlias('prod', configured.sshHost, configured.sshPort, configured.sshUser,
        null, null, configured.sshServerAliveIntervalSeconds, configured.sshServerAliveCountMax)
      expect(config.previewConfigText().includes('  ServerAliveInterval 0\n')).assertEqual(true)
      expect(config.previewConfigText().includes('  ServerAliveCountMax 7\n')).assertEqual(true)
      config.addAlias('prod', reset.sshHost, reset.sshPort, reset.sshUser,
        null, null, reset.sshServerAliveIntervalSeconds, reset.sshServerAliveCountMax)
      expect(config.previewConfigText().includes('  ServerAliveInterval ')).assertEqual(false)
      expect(config.previewConfigText().includes('  ServerAliveCountMax ')).assertEqual(false)
    })

    it('persistsProxyJumpInTheSingleManagedHostConfig', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('')
      config.addAlias('jump', 'jump.example.com', 22, 'gateway')
      config.addAlias('private', 'target.example.com', 2222, 'deploy', 'jump')
      let text: string = config.previewConfigText()
      expect(text.includes('Host private\n')).assertEqual(true)
      expect(text.includes('  ProxyJump jump\n')).assertEqual(true)
      config.addAlias('private', 'new-target.example.com', 2200, 'deploy')
      expect(config.previewConfigText().includes('  ProxyJump jump\n')).assertEqual(true)
      config.addAlias('private', 'new-target.example.com', 2200, 'deploy', 'none')
      expect(config.previewConfigText().includes('  ProxyJump none\n')).assertEqual(true)
    })

    it('rejectsInvalidKnownCommandSyntaxExplicitly', 0, () => {
      let invalidKey = CommandParser.parseInput('key unknown', new SshConfig())
      let invalidHost = CommandParser.parseInput('host unknown', new SshConfig())
      let invalidName = CommandParser.parseInput('host add bad*name deploy@example.com', new SshConfig())
      let missingHost = CommandParser.parseInput('host add prod deploy@', new SshConfig())
      expect(invalidKey instanceof KeyCommandResult).assertEqual(true)
      expect(invalidHost instanceof KeyCommandResult).assertEqual(true)
      expect(invalidName instanceof KeyCommandResult).assertEqual(true)
      expect(missingHost instanceof KeyCommandResult).assertEqual(true)
      if (invalidKey instanceof KeyCommandResult) { expect(invalidKey.errorMessage.length > 0).assertEqual(true) }
      if (invalidHost instanceof KeyCommandResult) { expect(invalidHost.errorMessage.length > 0).assertEqual(true) }
      if (invalidName instanceof KeyCommandResult) { expect(invalidName.errorMessage.length > 0).assertEqual(true) }
      if (missingHost instanceof KeyCommandResult) { expect(missingHost.errorMessage.length > 0).assertEqual(true) }
    })

    it('rejectsAmbiguousSshCopyIdSyntax', 0, () => {
      expect(CommandParser.parseSshCopyId('ssh-copy-id -i first -i second deploy@example.com')
        .errorMessage.includes('duplicate option -i')).assertEqual(true)
      expect(CommandParser.parseSshCopyId('ssh-copy-id -i key -p 22oops deploy@example.com')
        .errorMessage.includes('port 1-65535')).assertEqual(true)
      expect(CommandParser.parseSshCopyId('ssh-copy-id -i key deploy@example.com root@other.example')
        .errorMessage.includes('unexpected target')).assertEqual(true)
      expect(CommandParser.parseSshCopyId('ssh-copy-id -i key deploy@[2001:db8::1]oops')
        .errorMessage.includes('unexpected text')).assertEqual(true)
    })

    it('completesHostsOnlyForSupportedHostTakingCommands', 0, () => {
      let vm: CommandBarViewModel = new CommandBarViewModel()
      vm.getSshConfig().loadFromText('Host prod\n  HostName prod.example.com\n  User deploy\n' +
        'Host jump\n  HostName jump.example.com\n  User gateway\n')
      vm.setInputText('ssh -G pr')
      expect(vm.tryTabComplete()[0]).assertEqual('ssh -G prod')
      vm.setInputText('ssh -J ju pr')
      expect(vm.tryTabComplete()[0]).assertEqual('ssh -J ju prod')
      vm.setInputText('ssh -J ju')
      expect(vm.tryTabComplete()[0]).assertEqual('ssh -J jump')
      vm.setInputText('ssh -G -J jump pr')
      expect(vm.tryTabComplete()[0]).assertEqual('ssh -G -J jump prod')
      vm.setInputText('host set pr')
      expect(vm.tryTabComplete()[0]).assertEqual('host set prod')
      vm.setInputText('host rm pr')
      expect(vm.tryTabComplete()[0]).assertEqual('host rm prod')
      vm.setInputText('put report.txt pr')
      expect(vm.tryTabComplete()[0]).assertEqual('put report.txt prod:')
      vm.setInputText('get pr')
      expect(vm.tryTabComplete()[0]).assertEqual('get prod:')
    })

    it('cyclesAndAcceptsAmbiguousCompletionsWithoutRunningTheCommand', 0, () => {
      let vm: CommandBarViewModel = new CommandBarViewModel()
      let engine: LocalCompletionEngine = new LocalCompletionEngine()
      vm.getSshConfig().loadFromText('Host prod production\n  HostName prod.example.com\n  User deploy\n')
      vm.setInputText('get p')
      let set: LocalCompletionSet = vm.completionSet()
      expect(set.replacements.length).assertEqual(2)
      expect(set.displayValues[0]).assertEqual('prod:')
      expect(set.displayValues[1]).assertEqual('production:')
      let listed: LocalCompletionUpdate = engine.complete('get p', set)
      expect(listed.kind).assertEqual(LocalCompletionUpdateKind.LISTED)
      expect(listed.text).assertEqual('get p')
      expect(listed.selectedIndex).assertEqual(-1)
      let selected: LocalCompletionUpdate = engine.complete('get p', set)
      expect(selected.kind).assertEqual(LocalCompletionUpdateKind.SELECTED)
      expect(selected.text).assertEqual('get prod:')
      expect(selected.displayValues.length).assertEqual(2)
      expect(selected.selectedIndex).assertEqual(0)
      expect(engine.isMenuActive()).assertEqual(true)
      let cycled: LocalCompletionUpdate = engine.cycle(1)
      expect(cycled.text).assertEqual('get production:')
      expect(cycled.selectedIndex).assertEqual(1)
      expect(engine.cycle(1).text).assertEqual('get prod:')
      expect(engine.cycle(-1).text).assertEqual('get production:')
      expect(engine.accept().text).assertEqual('get production:')
      expect(engine.isMenuActive()).assertEqual(false)

      listed = engine.complete('get p', set)
      expect(listed.kind).assertEqual(LocalCompletionUpdateKind.LISTED)
      expect(engine.cancel().text).assertEqual('get p')

      let directorySet: LocalCompletionSet = new LocalCompletionSet()
      directorySet.replacements = ['put ./reports/', 'put ./report.txt']
      directorySet.displayValues = ['reports/', 'report.txt']
      let directory: LocalCompletionUpdate = engine.complete('put ./r', directorySet)
      expect(directory.kind).assertEqual(LocalCompletionUpdateKind.LISTED)
      directory = engine.complete('put ./r', directorySet)
      expect(directory.text).assertEqual('put ./reports/')
      expect(engine.selectedCandidate()).assertEqual('put ./reports/')
      expect(engine.accept().text).assertEqual('put ./reports/')
    })

    it('editsTheSelectedCompletionAndUsesRollbackOnlyForCancellation', 0, () => {
      let engine: LocalCompletionEngine = new LocalCompletionEngine()
      let initial: LocalCompletionSet = new LocalCompletionSet()
      initial.replacements = ['put ./alpha.txt', 'put ./alpine.txt']
      initial.displayValues = ['alpha.txt', 'alpine.txt']
      engine.complete('put ./a', initial)
      let selected: LocalCompletionUpdate = engine.complete('put ./a', initial)
      expect(selected.text).assertEqual('put ./alpha.txt')

      let line: LocalCommandLine = new LocalCommandLine()
      line.setText(selected.text)
      line.setText(engine.editingText())
      line.insert(' ')
      expect(line.getText()).assertEqual('put ./alpha.txt ')
      expect(engine.isActive()).assertEqual(false)

      let directorySet: LocalCompletionSet = new LocalCompletionSet()
      directorySet.replacements = ['put ./alpha/', 'put ./archive/']
      directorySet.displayValues = ['alpha/', 'archive/']
      engine.complete('put ./a', directorySet)
      selected = engine.complete('put ./a', directorySet)
      line.setText(selected.text)
      line.setText(engine.editingText())
      line.insert('c')
      expect(line.getText()).assertEqual('put ./alpha/c')
      expect(engine.isActive()).assertEqual(false)

      engine.complete('put ./a', initial)
      selected = engine.complete('put ./a', initial)
      line.setText(selected.text)
      line.setText(engine.editingText())
      line.backspace()
      expect(line.getText()).assertEqual('put ./alpha.tx')
      expect(engine.isActive()).assertEqual(false)

      engine.complete('put ./a', initial)
      engine.complete('put ./a', initial)
      expect(engine.cancel().text).assertEqual('put ./a')

      engine.complete('put ./a', initial)
      expect(engine.editingText()).assertEqual('put ./a')
      expect(engine.isActive()).assertEqual(false)
    })

    it('formatsCompletionCandidatesByTerminalCells', 0, () => {
      expect(CommandBarViewModel.completionDisplayValue(
        'put ./reports/report\\ alpha.txt', 4)).assertEqual('report alpha.txt')
      expect(CommandBarViewModel.completionDisplayValue(
        'put ./reports/', 4)).assertEqual('reports/')
      expect(SessionViewModel.terminalCellWidth('plain')).assertEqual(5)
      expect(SessionViewModel.terminalCellWidth('报告')).assertEqual(4)
      expect(SessionViewModel.terminalCellWidth('😀')).assertEqual(2)
      expect(SessionViewModel.formatCompletionCandidates(['alpha', '报告/', 'beta'], 14))
        .assertEqual('alpha  beta\r\n报告/')
    })

    it('rendersOneTransientCompletionRegionBelowTheCommand', 0, () => {
      let renderer: LocalCompletionRenderer = new LocalCompletionRenderer()
      let first: string = renderer.render('ltty> ', 'put ./a', 7,
        ['alpha/', 'alpine.txt'], -1, false, 40, 24)
      expect(first.indexOf('ltty> put ./a\r\nalpha/')).assertEqual(5)
      expect(first.includes('\u001b[7m')).assertEqual(false)

      let second: string = renderer.render('ltty> ', 'put ./alpha/', 12,
        ['alpha/', 'alpine.txt'], 0, false, 40, 24)
      expect(second.includes('\u001b[1B\r\u001b[2K')).assertEqual(true)
      expect(second.includes('ltty> put ./alpha/\r\n\u001b[7malpha/\u001b[0m')).assertEqual(true)
      expect(second.indexOf('alpine.txt')).assertEqual(second.lastIndexOf('alpine.txt'))
    })

    it('navigatesCompletionColumnsInDisplayedOrder', 0, () => {
      let layout: LocalCompletionLayout = LocalCompletionRenderer.layout(
        ['aaaa', 'bbbb', 'cccc', 'dddd', 'eeee', 'ffff'], 0, false, 14, 8)
      expect(layout.rowCount).assertEqual(3)
      expect(LocalCompletionRenderer.moveSelection(
        0, LocalCompletionNavigation.DOWN, 6, layout)).assertEqual(1)
      expect(LocalCompletionRenderer.moveSelection(
        0, LocalCompletionNavigation.UP, 6, layout)).assertEqual(2)
      expect(LocalCompletionRenderer.moveSelection(
        1, LocalCompletionNavigation.RIGHT, 6, layout)).assertEqual(4)
      expect(LocalCompletionRenderer.moveSelection(
        4, LocalCompletionNavigation.LEFT, 6, layout)).assertEqual(1)
    })

    it('boundsLongCompletionRowsWithoutDroppingTheDirectoryMarker', 0, () => {
      let layout: LocalCompletionLayout = LocalCompletionRenderer.layout(
        ['this-is-a-very-long-directory-name/'], -1, false, 10, 4)
      expect(layout.lines.length).assertEqual(1)
      expect(LocalCompletionRenderer.terminalCellWidth(layout.lines[0]) <= 9).assertEqual(true)
      expect(layout.lines[0].endsWith('.../')).assertEqual(true)
    })

    it('reflowsTheTrackedCommandRegionAfterATerminalResize', 0, () => {
      let renderer: LocalCompletionRenderer = new LocalCompletionRenderer()
      renderer.render('ltty> ', '123456789012345', 15, [], -1, false, 20, 24)
      let resized: string = renderer.render(
        'ltty> ', '123456789012345', 15, [], -1, false, 10, 24)
      expect(resized.startsWith('\r\u001b[2A')).assertEqual(true)
      expect(resized.includes('\u001b[1B\r\u001b[2K')).assertEqual(true)
      expect(resized.endsWith('\r\u001b[1C')).assertEqual(true)
    })

    it('doesNotTreatEscapedOrQuotedTrailingSpacesAsOperandSeparators', 0, () => {
      let vm: CommandBarViewModel = new CommandBarViewModel()
      vm.getSshConfig().loadFromText('Host alpha beta gamma\n  HostName fixture.example\n  User deploy\n')
      vm.setInputText('put missing\\ ')
      expect(vm.tryTabComplete().length).assertEqual(0)
      vm.setInputText('put "missing ')
      expect(vm.tryTabComplete().length).assertEqual(0)
    })

    it('keepsTransferCompletionContextsBoundedAndOffline', 0, () => {
      let vm: CommandBarViewModel = new CommandBarViewModel()
      let configText: string = ''
      for (let index: number = 0; index < 105; index++) {
        configText += 'Host host' + index.toString().padStart(3, '0') + '\n' +
          '  HostName fixture.example\n  User deploy\n'
      }
      configText += 'Host Prod prod 报告\n  HostName fixture.example\n  User deploy\n'
      vm.getSshConfig().loadFromText(configText)
      vm.setInputText('get host')
      let bounded: LocalCompletionSet = vm.completionSet()
      expect(bounded.replacements.length).assertEqual(100)
      expect(bounded.truncated).assertEqual(true)
      vm.setInputText('get P')
      expect(vm.tryTabComplete()[0]).assertEqual('get Prod:')
      vm.setInputText('get 报')
      expect(vm.tryTabComplete()[0]).assertEqual('get 报告:')
      vm.setInputText('get prod:/remote')
      expect(vm.tryTabComplete().length).assertEqual(0)
      vm.setInputText('put -p ')
      expect(vm.tryTabComplete().length).assertEqual(0)
      vm.setInputText('put -i ')
      expect(vm.tryTabComplete().length).assertEqual(0)
      vm.setInputText('put local')
      expect(vm.tryTabComplete().length).assertEqual(0)
      let commandVm: CommandBarViewModel = new CommandBarViewModel()
      commandVm.setInputText('ex')
      expect(commandVm.tryTabComplete()[0]).assertEqual('exit')
    })

    it('rejectsUnsafeCompletionValuesBeforeTheyReachTheTerminal', 0, () => {
      expect(CommandBarViewModel.safeCompletionValue('报告 😀.txt')).assertEqual(true)
      for (let value of [
        'bad\u001b[2J', 'line\nbreak', 'c1\u0085name', 'bidi\u202Ename', 'isolate\u2066name',
        'zero\u200Bwidth', 'bom\uFEFFname', 'tag\uDB40\uDC61name', 'bad\uD800', 'bad\uDC00'
      ]) {
        expect(CommandBarViewModel.safeCompletionValue(value)).assertEqual(false)
      }
      expect(TerminalTextPolicy.escape('报告 😀.txt')).assertEqual('报告 😀.txt')
      expect(TerminalTextPolicy.escape('bidi\u202Ename')).assertEqual('bidi\\u{202e}name')
      let unsafePath = CommandParser.parseInput('put bidi\u202Ename prod:/tmp/name', new SshConfig())
      expect(unsafePath instanceof TransferCommandResult).assertEqual(true)
      if (unsafePath instanceof TransferCommandResult) {
        expect(unsafePath.isValid).assertEqual(false)
      }
      let vm: CommandBarViewModel = new CommandBarViewModel()
      vm.getSshConfig().loadFromText('Host prod bad\u001b[2J\n  HostName prod.example.com\n  User deploy\n')
      vm.setInputText('get ')
      let matches: string[] = vm.tryTabComplete()
      expect(matches.length).assertEqual(1)
      expect(matches[0]).assertEqual('get prod:')
    })

    it('parsesEffectiveConfigInspection', 0, () => {
      let result: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh -G prod', new SshConfig())
      let jumped: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh -G -J jump prod', new SshConfig())
      expect(result instanceof KeyCommandResult).assertEqual(true)
      if (result instanceof KeyCommandResult) {
        expect(result.kind).assertEqual(KeyCommandKind.SSH_CONFIG)
        expect(result.keyName).assertEqual('prod')
      }
      expect(jumped instanceof KeyCommandResult).assertEqual(true)
      if (jumped instanceof KeyCommandResult) {
        expect(jumped.kind).assertEqual(KeyCommandKind.SSH_CONFIG)
        expect(jumped.keyName).assertEqual('prod')
        expect(jumped.sshJump).assertEqual('jump')
      }
    })

    it('resolvesControlledConnectTimeoutWithOpenSshFirstValueSemantics', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName prod.example.com\n  User deploy\n' +
        '  ConnectTimeout 9\n\nHost *\n  ConnectTimeout 30\n')
      let configured = CommandParser.parseInput('ssh prod', config)
      let transfer = CommandParser.parseInput('get prod:/report.txt', config)
      let direct = CommandParser.parseInput('ssh deploy@example.com', config)
      expect(configured instanceof CommandParseResult).assertEqual(true)
      expect(transfer instanceof TransferCommandResult).assertEqual(true)
      expect(direct instanceof CommandParseResult).assertEqual(true)
      if (configured instanceof CommandParseResult) {
        expect(configured.isValid).assertEqual(true)
        expect(configured.connectTimeoutMs).assertEqual(9000)
      }
      if (transfer instanceof TransferCommandResult) {
        expect(transfer.isValid).assertEqual(true)
        expect(transfer.connectTimeoutMs).assertEqual(9000)
      }
      if (direct instanceof CommandParseResult) {
        expect(direct.isValid).assertEqual(true)
        expect(direct.connectTimeoutMs).assertEqual(15000)
      }
    })

    it('acceptsConnectTimeoutBoundsAndRejectsInvalidValuesBeforeConnection', 0, () => {
      for (let value of ['1', '300']) {
        let valid: SshConfig = new SshConfig()
        valid.loadFromText('Host prod\n  User deploy\n  ConnectTimeout ' + value + '\n')
        let result = CommandParser.parseInput('ssh prod', valid)
        expect(result instanceof CommandParseResult).assertEqual(true)
        if (result instanceof CommandParseResult) {
          expect(result.isValid).assertEqual(true)
          expect(result.connectTimeoutMs).assertEqual(parseInt(value, 10) * 1000)
        }
      }
      for (let value of ['0', '301', '-1', '1.5', 'forever']) {
        let invalid: SshConfig = new SshConfig()
        invalid.loadFromText('Host prod\n  User deploy\n  ConnectTimeout ' + value + '\n')
        let result = CommandParser.parseInput('ssh prod', invalid)
        expect(result instanceof CommandParseResult).assertEqual(true)
        if (result instanceof CommandParseResult) {
          expect(result.isValid).assertEqual(false)
          expect(result.errorMessage.includes('ConnectTimeout')).assertEqual(true)
          expect(result.errorMessage.includes('expected whole seconds 1-300')).assertEqual(true)
        }
      }
    })

    it('resolvesServerAliveBoundsWithOpenSshFirstValueSemantics', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName prod.example.com\n  User deploy\n' +
        '  ServerAliveInterval 0\n  ServerAliveCountMax 100\n\nHost *\n' +
        '  ServerAliveInterval 60\n  ServerAliveCountMax 5\n')
      let connection = CommandParser.parseInput('ssh prod', config)
      let transfer = CommandParser.parseInput('get prod:/report.txt', config)
      expect(connection instanceof CommandParseResult).assertEqual(true)
      expect(transfer instanceof TransferCommandResult).assertEqual(true)
      if (connection instanceof CommandParseResult) {
        expect(connection.isValid).assertEqual(true)
        expect(connection.serverAliveIntervalSeconds).assertEqual(0)
        expect(connection.serverAliveCountMax).assertEqual(100)
      }
      if (transfer instanceof TransferCommandResult) {
        expect(transfer.serverAliveIntervalSeconds).assertEqual(0)
        expect(transfer.serverAliveCountMax).assertEqual(100)
      }
      for (let value of ['3601', '-1', '1.5', 'forever']) {
        let invalid: SshConfig = new SshConfig()
        invalid.loadFromText('Host prod\n  User deploy\n  ServerAliveInterval ' + value + '\n')
        let result = CommandParser.parseInput('ssh prod', invalid)
        if (result instanceof CommandParseResult) {
          expect(result.isValid).assertEqual(false)
          expect(result.errorMessage.includes('expected whole seconds 0-3600')).assertEqual(true)
        }
      }
      for (let value of ['0', '101', '-1', '1.5', 'forever']) {
        let invalid: SshConfig = new SshConfig()
        invalid.loadFromText('Host prod\n  User deploy\n  ServerAliveCountMax ' + value + '\n')
        let result = CommandParser.parseInput('ssh prod', invalid)
        if (result instanceof CommandParseResult) {
          expect(result.isValid).assertEqual(false)
          expect(result.errorMessage.includes('expected count 1-100')).assertEqual(true)
        }
      }
    })

    it('resolvesSingleProxyJumpWithSeparateHostIdentityAndOverrides', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName target.example.com\n  User target-user\n' +
        '  IdentityFile target-key\n  ConnectTimeout 9\n  ServerAliveInterval 11\n' +
        '  ServerAliveCountMax 2\n  ProxyJump jump-user@bastion:2200\n\n' +
        'Host bastion\n  HostName jump.example.com\n  User config-jump-user\n' +
        '  Port 2222\n  IdentityFile jump-key\n  ConnectTimeout 4\n' +
        '  ServerAliveInterval 17\n  ServerAliveCountMax 6\n')
      let parsed = CommandParser.parseInput('ssh prod', config)
      expect(parsed instanceof CommandParseResult).assertEqual(true)
      if (parsed instanceof CommandParseResult) {
        expect(parsed.isValid).assertEqual(true)
        expect(parsed.host).assertEqual('target.example.com')
        expect(parsed.username).assertEqual('target-user')
        expect(parsed.identityFile).assertEqual('target-key')
        expect(parsed.jumpDisplayHost).assertEqual('bastion')
        expect(parsed.jumpHost).assertEqual('jump.example.com')
        expect(parsed.jumpPort).assertEqual(2200)
        expect(parsed.jumpUsername).assertEqual('jump-user')
        expect(parsed.jumpIdentityFile).assertEqual('jump-key')
        expect(parsed.connectTimeoutMs).assertEqual(9000)
        expect(parsed.jumpConnectTimeoutMs).assertEqual(4000)
        expect(parsed.serverAliveIntervalSeconds).assertEqual(11)
        expect(parsed.serverAliveCountMax).assertEqual(2)
        expect(parsed.jumpServerAliveIntervalSeconds).assertEqual(17)
        expect(parsed.jumpServerAliveCountMax).assertEqual(6)
      }
    })

    it('appliesOneShotProxyJumpWithoutMutatingSavedConfig', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName target.example.com\n  User target-user\n' +
        '  ProxyJump saved-jump\n\nHost saved-jump\n  HostName saved.example.com\n  User saved-user\n')
      let disabled = CommandParser.parseInput('ssh -J none prod', config)
      let overridden = CommandParser.parseInput('ssh -J once@other.example.com:2200 prod', config)
      let following = CommandParser.parseInput('ssh prod', config)
      if (disabled instanceof CommandParseResult) {
        expect(disabled.isValid).assertEqual(true)
        expect(disabled.jumpHost).assertEqual('')
      }
      if (overridden instanceof CommandParseResult) {
        expect(overridden.isValid).assertEqual(true)
        expect(overridden.jumpHost).assertEqual('other.example.com')
        expect(overridden.jumpPort).assertEqual(2200)
        expect(overridden.jumpUsername).assertEqual('once')
      }
      if (following instanceof CommandParseResult) {
        expect(following.isValid).assertEqual(true)
        expect(following.jumpHost).assertEqual('saved.example.com')
        expect(following.jumpUsername).assertEqual('saved-user')
      }
    })

    it('rejectsUnsupportedProxyJumpChainsLoopsAndExpressions', 0, () => {
      let chain: SshConfig = new SshConfig()
      chain.loadFromText('Host prod\n  HostName target.example.com\n  User target\n  ProxyJump jump\n\n' +
        'Host jump\n  HostName jump.example.com\n  User jump\n  ProxyJump outer\n')
      let self: SshConfig = new SshConfig()
      self.loadFromText('Host prod\n  HostName same.example.com\n  User target\n' +
        '  ProxyJump jump\n\nHost jump\n  HostName same.example.com\n  User jump\n')
      let direct: SshConfig = new SshConfig()
      direct.loadFromText('Host prod\n  HostName target.example.com\n  User target\n')
      let chained = CommandParser.parseInput('ssh prod', chain)
      let looped = CommandParser.parseInput('ssh prod', self)
      let multiple = CommandParser.parseInput('ssh -J one,two prod', direct)
      let uri = CommandParser.parseInput('ssh -J ssh://jump prod', direct)
      let missingUser = CommandParser.parseInput('ssh -J unknown prod', direct)
      for (let parsed of [chained, looped, multiple, uri, missingUser]) {
        expect(parsed instanceof CommandParseResult).assertEqual(true)
        if (parsed instanceof CommandParseResult) {
          expect(parsed.isValid).assertEqual(false)
          expect(parsed.errorMessage.length > 0).assertEqual(true)
        }
      }
    })

    it('aliasUpdatesPreserveUnmanagedSshConfigText', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('# keep\nHost *\n  ForwardAgent yes\n\nHost prod production # shared\n' +
        '  HostName old\n  User root\n  ProxyJump bastion\n')
      config.addAlias('prod', 'new.example.com', 2222, 'deploy')
      let text: string = config.previewConfigText()
      expect(text.includes('# keep')).assertEqual(true)
      expect(text.includes('ForwardAgent yes')).assertEqual(true)
      expect(text.includes('Host prod production # shared')).assertEqual(true)
      expect(text.includes('ProxyJump bastion')).assertEqual(true)
      expect(text.includes('# >>> LeanTTY managed hosts >>>')).assertEqual(true)
      expect(text.includes('Host prod\n  HostName new.example.com\n  User deploy\n  Port 2222')).assertEqual(true)
    })

    it('managedHostUpdatesPreserveProxyJump', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('# >>> LeanTTY managed hosts >>>\nHost prod\n' +
        '  HostName old.example.com\n  User old-user\n  ProxyJump jump\n\n' +
        '# <<< LeanTTY managed hosts <<<\n\nHost jump\n  HostName jump.example.com\n  User jump-user\n')
      config.addAlias('prod', 'new.example.com', 2200, 'new-user')
      let text: string = config.previewConfigText()
      expect(text.includes('Host prod\n  HostName new.example.com\n  User new-user\n' +
        '  Port 2200\n  ProxyJump jump')).assertEqual(true)
    })

    it('managedHostUpdatesPreserveConnectTimeout', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('# >>> LeanTTY managed hosts >>>\nHost prod\n' +
        '  HostName old.example.com\n  User old-user\n  ConnectTimeout 25\n' +
        '# <<< LeanTTY managed hosts <<<\n')
      config.addAlias('prod', 'new.example.com', 2200, 'new-user')
      let text: string = config.previewConfigText()
      expect(text.includes('Host prod\n  HostName new.example.com\n  User new-user\n' +
        '  Port 2200\n  ConnectTimeout 25')).assertEqual(true)
    })

    it('resolvesOpenSshFirstValueAndIdentityFile', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName prod.example.com\n  IdentityFile ~/.ssh/deploy\n\n' +
        'Host *\n  User deploy\n  Port 2200\n')
      let result: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh prod', config)
      expect(result instanceof CommandParseResult).assertEqual(true)
      if (result instanceof CommandParseResult) {
        expect(result.host).assertEqual('prod.example.com')
        expect(result.displayHost).assertEqual('prod')
        expect(result.username).assertEqual('deploy')
        expect(result.port).assertEqual(2200)
        expect(result.identityFile).assertEqual('~/.ssh/deploy')
      }
    })

    it('rejectsUnsupportedMatchBeforeConnection', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName prod.example.com\nMatch user root\n  Port 9999\n' +
        'Host *\n  Port 2222\n  User deploy\n')
      let result: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh prod', config)
      expect(result instanceof CommandParseResult).assertEqual(true)
      if (result instanceof CommandParseResult) {
        expect(result.isValid).assertEqual(false)
        expect(result.errorMessage.includes('Match')).assertEqual(true)
        expect(result.errorMessage.includes('line 3')).assertEqual(true)
      }
    })

    it('rejectsUnresolvableProxyJumpOrInvalidConfigBeforeConnection', 0, () => {
      let unknown: SshConfig = new SshConfig()
      unknown.loadFromText('Host prod\n  HostName prod.example.com\n  User deploy\n  ProxyJump bastion\n')
      let unknownResult = CommandParser.parseInput('ssh prod', unknown)
      expect(unknownResult instanceof CommandParseResult).assertEqual(true)
      if (unknownResult instanceof CommandParseResult) {
        expect(unknownResult.isValid).assertEqual(false)
        expect(unknownResult.errorMessage.includes('ProxyJump')).assertEqual(true)
      }

      let proxyCommand: SshConfig = new SshConfig()
      proxyCommand.loadFromText('Host prod\n  HostName prod.example.com\n  User deploy\n' +
        '  ProxyCommand ssh jump -W %h:%p\n')
      let proxyCommandResult = CommandParser.parseInput('ssh prod', proxyCommand)
      expect(proxyCommandResult instanceof CommandParseResult).assertEqual(true)
      if (proxyCommandResult instanceof CommandParseResult) {
        expect(proxyCommandResult.isValid).assertEqual(false)
        expect(proxyCommandResult.errorMessage.includes('ProxyCommand')).assertEqual(true)
      }

      let invalid: SshConfig = new SshConfig()
      invalid.loadFromText('Host prod\n  HostName prod.example.com\n  User deploy\n  Port 22oops\n')
      let invalidResult = CommandParser.parseInput('ssh prod', invalid)
      expect(invalidResult instanceof CommandParseResult).assertEqual(true)
      if (invalidResult instanceof CommandParseResult) {
        expect(invalidResult.isValid).assertEqual(false)
        expect(invalidResult.errorMessage.includes('expected port 1-65535')).assertEqual(true)
      }
    })

    it('scopesUnsupportedConfigToMatchingHosts', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host other\n  User root\n  ProxyJump bastion\n\n' +
        'Host prod\n  HostName prod.example.com\n  User deploy\n  Port=2200\n')
      let result = CommandParser.parseInput('ssh prod', config)
      expect(result instanceof CommandParseResult).assertEqual(true)
      if (result instanceof CommandParseResult) {
        expect(result.isValid).assertEqual(true)
        expect(result.host).assertEqual('prod.example.com')
        expect(result.port).assertEqual(2200)
      }
    })

    it('rejectsMalformedAndDuplicateSshOptionsBeforeConnection', 0, () => {
      let config: SshConfig = new SshConfig()
      let malformed = CommandParser.parseInput('ssh -p 22oops deploy@example.com', config)
      let duplicatePort = CommandParser.parseInput('ssh -p 22 -p 2200 deploy@example.com', config)
      let duplicateIdentity = CommandParser.parseInput('ssh -i first -i second deploy@example.com', config)
      let duplicateJump = CommandParser.parseInput('ssh -J one -J two deploy@example.com', config)
      let malformedTarget = CommandParser.parseInput('ssh deploy@example.com:22oops', config)
      let bracketSuffix = CommandParser.parseInput('ssh deploy@[2001:db8::1]oops', config)
      expect(malformed instanceof CommandParseResult).assertEqual(true)
      expect(duplicatePort instanceof CommandParseResult).assertEqual(true)
      expect(duplicateIdentity instanceof CommandParseResult).assertEqual(true)
      expect(duplicateJump instanceof CommandParseResult).assertEqual(true)
      expect(malformedTarget instanceof CommandParseResult).assertEqual(true)
      expect(bracketSuffix instanceof CommandParseResult).assertEqual(true)
      if (malformed instanceof CommandParseResult) { expect(malformed.isValid).assertEqual(false) }
      if (duplicatePort instanceof CommandParseResult) {
        expect(duplicatePort.errorMessage).assertEqual('Duplicate SSH option: -p')
      }
      if (duplicateIdentity instanceof CommandParseResult) {
        expect(duplicateIdentity.errorMessage).assertEqual('Duplicate SSH option: -i')
      }
      if (duplicateJump instanceof CommandParseResult) {
        expect(duplicateJump.errorMessage).assertEqual('Duplicate SSH option: -J')
      }
      if (malformedTarget instanceof CommandParseResult) { expect(malformedTarget.isValid).assertEqual(false) }
      if (bracketSuffix instanceof CommandParseResult) { expect(bracketSuffix.isValid).assertEqual(false) }
    })

    it('reportsCopySelectionResultsIncludingAnEmptySelection', 0, () => {
      expect(BridgeProtocol.copySelectionResult('copied text').serialize())
        .assertEqual('H2|W2N|CONTROL|copySelection|copied text')
      expect(BridgeProtocol.copySelectionResult('').serialize())
        .assertEqual('H2|W2N|CONTROL|copySelection|')
    })

    it('acceptsOnlyWebToNativeUrlOpenControls', 0, () => {
      let openUrl: BridgeMessage | null =
        BridgeProtocol.parse('H2|W2N|CONTROL|openUrl|https://example.com/path?q=1')
      expect(openUrl !== null).assertEqual(true)
      if (openUrl !== null) {
        expect(openUrl.kind).assertEqual(BridgeProtocol.KIND_OPEN_URL)
        expect(openUrl.payload).assertEqual('https://example.com/path?q=1')
      }
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|openUrl|https://example.com')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|DATA|openUrl|https://example.com')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|openUrl|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|openUrl|' +
        'x'.repeat(BridgeProtocol.MAX_URL_PAYLOAD_LENGTH + 1))).assertEqual(null)
    })

    it('allowsOnlyNormalizedCredentialFreeHttpUrls', 0, () => {
      expect(BrowserLauncher.normalizeHttpUrl('https://example.com/path?q=1'))
        .assertEqual('https://example.com/path?q=1')
      expect(BrowserLauncher.normalizeHttpUrl('HTTP://EXAMPLE.COM'))
        .assertEqual('http://EXAMPLE.COM')
      expect(BrowserLauncher.normalizeHttpUrl('ftp://example.com')).assertEqual(null)
      expect(BrowserLauncher.normalizeHttpUrl('https://user:secret@example.com')).assertEqual(null)
      expect(BrowserLauncher.normalizeHttpUrl(' https://example.com')).assertEqual(null)
      expect(BrowserLauncher.normalizeHttpUrl('https://example.com/\nnext')).assertEqual(null)
    })

    it('encodesTerminalFocusAndBlurAsSeparateBridgeMessages', 0, () => {
      expect(BridgeProtocol.focus().serialize()).assertEqual('H2|N2W|CONTROL|focus|')
      expect(BridgeProtocol.blur().serialize()).assertEqual('H2|N2W|CONTROL|blur|')
      expect(BridgeProtocol.clearSelection().serialize()).assertEqual('H2|N2W|CONTROL|clearSelection|')
    })

    it('routesTerminalSurfaceActionsThroughBridgeControls', 0, () => {
      expect(BridgeProtocol.fit().serialize()).assertEqual('H2|N2W|CONTROL|fit|')
      expect(BridgeProtocol.fontSize(18).serialize()).assertEqual('H2|N2W|CONTROL|fontSize|18')
      expect(BridgeProtocol.inputSecurity(true).serialize())
        .assertEqual('H2|N2W|CONTROL|inputSecurity|masked')
      expect(BridgeProtocol.inputSecurity(false).serialize())
        .assertEqual('H2|N2W|CONTROL|inputSecurity|plain')
      expect(BridgeProtocol.copySelection().serialize()).assertEqual('H2|N2W|CONTROL|copySelection|')
      expect(BridgeProtocol.parse(BridgeProtocol.copySelection().serialize()) !== null).assertEqual(true)
      expect(BridgeProtocol.secondaryAction().serialize()).assertEqual('H2|N2W|CONTROL|secondaryAction|')
      expect(BridgeProtocol.copyOrInterrupt().serialize()).assertEqual('H2|N2W|CONTROL|copyOrInterrupt|')
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|copyOrInterrupt|unexpected') === null).assertEqual(true)
      expect(BridgeProtocol.searchOpen().serialize()).assertEqual('H2|N2W|CONTROL|searchOpen|')
      expect(BridgeProtocol.searchClose().serialize()).assertEqual('H2|N2W|CONTROL|searchClose|')
    })

    it('preservesDirectionalBridgePayloadsWithoutJsonEncoding', 0, () => {
      let raw: string = BridgeProtocol.write('a|b:c\r\n').serialize()
      let parsed: BridgeMessage | null = BridgeProtocol.parse(raw)
      expect(parsed !== null).assertEqual(true)
      if (parsed !== null) {
        expect(parsed.direction).assertEqual(BridgeProtocol.DIRECTION_NATIVE_TO_WEB)
        expect(parsed.channel).assertEqual(BridgeProtocol.CHANNEL_DATA)
        expect(parsed.kind).assertEqual(BridgeProtocol.KIND_TERMINAL)
        expect(parsed.payload).assertEqual('a|b:c\r\n')
      }
      expect(BridgeProtocol.parse('D:legacy')).assertEqual(null)
    })

    it('rejectsUnknownOrMisdirectedBridgeMessages', 0, () => {
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|unknown|payload')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|bell|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|title|remote-title')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|bellAttention|unexpected')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|attentionAcknowledged|unexpected')).assertEqual(null)
      let bellAttention: BridgeMessage | null =
        BridgeProtocol.parse('H2|W2N|CONTROL|bellAttention|')
      expect(bellAttention !== null).assertEqual(true)
      if (bellAttention !== null) {
        expect(bellAttention.kind).assertEqual(BridgeProtocol.KIND_BELL_ATTENTION)
        expect(bellAttention.payload).assertEqual('')
      }
      let attentionAcknowledged: BridgeMessage | null =
        BridgeProtocol.parse('H2|W2N|CONTROL|attentionAcknowledged|')
      expect(attentionAcknowledged !== null).assertEqual(true)
      if (attentionAcknowledged !== null) {
        expect(attentionAcknowledged.kind).assertEqual(BridgeProtocol.KIND_ATTENTION_ACKNOWLEDGED)
        expect(attentionAcknowledged.payload).assertEqual('')
      }
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|ready|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|theme|{}')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|DATA|resize|80,24')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|DATA|terminal|ok') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|DATA|terminal|ok') !== null).assertEqual(true)
      let searchOpen: BridgeMessage | null = BridgeProtocol.parse('H2|N2W|CONTROL|searchOpen|')
      expect(searchOpen !== null).assertEqual(true)
      if (searchOpen !== null) {
        expect(searchOpen.kind).assertEqual(BridgeProtocol.KIND_SEARCH_OPEN)
        expect(searchOpen.payload).assertEqual('')
      }
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|searchOpen|query')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|searchClose|query')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchState|open') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchState|composing') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchState|closed') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchState|unknown')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|inputSecurity|secret')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchOpen|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|DATA|searchOpen|')).assertEqual(null)
    })

    it('routesPhysicalTabToTerminalCompletion', 0, () => {
      let tab: string = KeyCodeMap.toAnsi(KeyCodeMap.TAB, false, false, false)
      let actions: TerminalInputAction[] = TerminalInputParser.parse(tab, true)
      let reverseTab: string = KeyCodeMap.toAnsi(KeyCodeMap.TAB, false, false, true)
      let reverseActions: TerminalInputAction[] = TerminalInputParser.parse(reverseTab, true)
      let escapeActions: TerminalInputAction[] = TerminalInputParser.parse('\u001b', true)
      expect(InteractionPolicy.isTerminalTabKey(KeyCodeMap.TAB, false, false, false)).assertEqual(true)
      expect(InteractionPolicy.isTerminalTabKey(KeyCodeMap.TAB, true, false, false)).assertEqual(false)
      expect(InteractionPolicy.isTerminalTabKey(KeyCodeMap.TAB, false, false, true)).assertEqual(true)
      expect(tab).assertEqual('\t')
      expect(actions.length).assertEqual(1)
      expect(actions[0].kind).assertEqual(TerminalInputActionKind.TAB)
      expect(reverseTab).assertEqual('\u001b[Z')
      expect(reverseActions.length).assertEqual(1)
      expect(reverseActions[0].kind).assertEqual(TerminalInputActionKind.REVERSE_TAB)
      expect(escapeActions.length).assertEqual(1)
      expect(escapeActions[0].kind).assertEqual(TerminalInputActionKind.ESCAPE)
    })

    it('recognizesOnlySupportedSshEscapesAtLineStartAcrossChunks', 0, () => {
      let parser: SshEscapeParser = new SshEscapeParser()
      let pending: SshEscapeResult = parser.consume('~')
      expect(pending.events.length).assertEqual(0)
      let info: SshEscapeResult = parser.consume('I')
      expect(info.events.length).assertEqual(1)
      expect(info.events[0].kind).assertEqual(SshEscapeEventKind.CONNECTION_INFO)

      let ordinary: SshEscapeResult = parser.consume('echo ~.\r')
      expect(ordinary.events.length).assertEqual(1)
      expect(ordinary.events[0].kind).assertEqual(SshEscapeEventKind.REMOTE_DATA)
      expect(ordinary.events[0].data).assertEqual('echo ~.\r')
      let help: SshEscapeResult = parser.consume('~?')
      expect(help.events.length).assertEqual(1)
      expect(help.events[0].kind).assertEqual(SshEscapeEventKind.HELP)
    })

    it('preservesLiteralAndUnknownSshEscapesAndStopsAfterDisconnect', 0, () => {
      let parser: SshEscapeParser = new SshEscapeParser()
      let literal: SshEscapeResult = parser.consume('~~value\r~x\n')
      expect(literal.events.length).assertEqual(1)
      expect(literal.events[0].kind).assertEqual(SshEscapeEventKind.REMOTE_DATA)
      expect(literal.events[0].data).assertEqual('~value\r~x\n')
      let disconnect: SshEscapeResult = parser.consume('~.ignored')
      expect(disconnect.events.length).assertEqual(1)
      expect(disconnect.events[0].kind).assertEqual(SshEscapeEventKind.DISCONNECT)

      parser.reset()
      let crlf: SshEscapeResult = parser.consume('command\r\n~?')
      expect(crlf.events.length).assertEqual(2)
      expect(crlf.events[0].data).assertEqual('command\r\n')
      expect(crlf.events[1].kind).assertEqual(SshEscapeEventKind.HELP)
    })

    it('preservesSshEscapeAndRemoteDataOrderWithinOneInputChunk', 0, () => {
      let parser: SshEscapeParser = new SshEscapeParser()
      let result: SshEscapeResult = parser.consume('~?echo ok\r~I~~x\r~.ignored')
      expect(result.events.length).assertEqual(5)
      let help: SshEscapeEvent = result.events[0]
      let firstRemote: SshEscapeEvent = result.events[1]
      let info: SshEscapeEvent = result.events[2]
      let secondRemote: SshEscapeEvent = result.events[3]
      let disconnect: SshEscapeEvent = result.events[4]
      expect(help.kind).assertEqual(SshEscapeEventKind.HELP)
      expect(firstRemote.kind).assertEqual(SshEscapeEventKind.REMOTE_DATA)
      expect(firstRemote.data).assertEqual('echo ok\r')
      expect(info.kind).assertEqual(SshEscapeEventKind.CONNECTION_INFO)
      expect(secondRemote.kind).assertEqual(SshEscapeEventKind.REMOTE_DATA)
      expect(secondRemote.data).assertEqual('~x\r')
      expect(disconnect.kind).assertEqual(SshEscapeEventKind.DISCONNECT)
    })

    it('formatsSshConnectionInfoFromDisplayRouteWithoutSecretFields', 0, () => {
      let text: string = SessionViewModel.formatSshConnectionInfo(
        'deploy', 'production', 2222, 'gateway', '2001:db8::1', 22)
      expect(text).assertEqual(
        'Target: deploy@production:2222\r\nJump: gateway@[2001:db8::1]:22\r\nState: connected')
      expect(text.includes('Identity')).assertEqual(false)
      expect(text.includes('password')).assertEqual(false)

      let escaped: string = SessionViewModel.formatSshConnectionInfo('user', 'bad\u001B[31mhost', 22)
      expect(escaped.includes('\u001B')).assertEqual(false)
    })

    it('routesExactCtrlCBeforeArkWebConsumesSelectionCopy', 0, () => {
      expect(InteractionPolicy.isTerminalCopyOrInterruptKey(2019, true, false)).assertEqual(true)
      expect(InteractionPolicy.isTerminalCopyOrInterruptKey(2019, true, true)).assertEqual(false)
      expect(InteractionPolicy.isTerminalCopyOrInterruptKey(2019, false, false)).assertEqual(false)
      expect(InteractionPolicy.isTerminalCopyOrInterruptKey(2018, true, false)).assertEqual(false)
    })

    it('matchesOnlyExactCtrlTabWorkspaceNavigation', 0, () => {
      expect(InteractionPolicy.workspaceNavigationAction(2049, true, false, false))
        .assertEqual(WorkspaceNavigationAction.NEXT_TAB)
      expect(InteractionPolicy.workspaceNavigationAction(2049, true, false, true))
        .assertEqual(WorkspaceNavigationAction.PREVIOUS_TAB)
      expect(InteractionPolicy.workspaceNavigationAction(2049, false, false, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2049, false, false, true))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2049, true, true, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2015, true, false, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
    })

    it('matchesOnlyExactCtrlAltPaneNavigation', 0, () => {
      expect(InteractionPolicy.workspaceNavigationAction(2014, true, true, false))
        .assertEqual(WorkspaceNavigationAction.FOCUS_LEFT_PANE)
      expect(InteractionPolicy.workspaceNavigationAction(2015, true, true, false))
        .assertEqual(WorkspaceNavigationAction.FOCUS_RIGHT_PANE)
      expect(InteractionPolicy.workspaceNavigationAction(2014, false, true, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2015, true, false, false))
        .assertEqual(WorkspaceNavigationAction.NONE)
      expect(InteractionPolicy.workspaceNavigationAction(2014, true, true, true))
        .assertEqual(WorkspaceNavigationAction.NONE)
    })

    it('matchesOnlyExactCtrlAltFTerminalSearch', 0, () => {
      expect(InteractionPolicy.isTerminalSearchShortcut(2022, true, true, false)).assertEqual(true)
      expect(InteractionPolicy.isTerminalSearchShortcut(2022, true, true, true)).assertEqual(false)
      expect(InteractionPolicy.isTerminalSearchShortcut(2022, true, false, false)).assertEqual(false)
      expect(InteractionPolicy.isTerminalSearchShortcut(2022, false, true, false)).assertEqual(false)
      expect(InteractionPolicy.isTerminalSearchShortcut(2019, true, true, false)).assertEqual(false)
    })

    it('separatesTransparencyAndFontSizeAdjustmentShortcuts', 0, () => {
      expect(InteractionPolicy.transparencyShortcutDirection(2057, true, true)).assertEqual(-1)
      expect(InteractionPolicy.transparencyShortcutDirection(2058, true, true)).assertEqual(1)
      expect(InteractionPolicy.transparencyShortcutDirection(2057, true, false)).assertEqual(0)
      expect(InteractionPolicy.transparencyShortcutDirection(2058, false, true)).assertEqual(0)
      expect(InteractionPolicy.fontSizeShortcutDirection(2057, true, false)).assertEqual(-1)
      expect(InteractionPolicy.fontSizeShortcutDirection(2058, true, false)).assertEqual(1)
      expect(InteractionPolicy.fontSizeShortcutDirection(2057, true, true)).assertEqual(0)
      expect(InteractionPolicy.fontSizeShortcutDirection(2058, false, false)).assertEqual(0)
    })

    it('consumesPaneNavigationOnlyForTheFixedTwoPaneLayout', 0, () => {
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.FOCUS_LEFT_PANE, 1))
        .assertEqual(-1)
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.FOCUS_RIGHT_PANE, 1))
        .assertEqual(-1)
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.FOCUS_LEFT_PANE, 2))
        .assertEqual(0)
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.FOCUS_RIGHT_PANE, 2))
        .assertEqual(1)
      expect(InteractionPolicy.workspacePaneIndex(WorkspaceNavigationAction.NEXT_TAB, 2))
        .assertEqual(-1)
    })

    it('wrapsWorkspaceTabsInVisualOrder', 0, () => {
      expect(InteractionPolicy.wrappedTabIndex(0, 0, 1)).assertEqual(-1)
      expect(InteractionPolicy.wrappedTabIndex(0, 1, 1)).assertEqual(0)
      expect(InteractionPolicy.wrappedTabIndex(0, 3, 1)).assertEqual(1)
      expect(InteractionPolicy.wrappedTabIndex(2, 3, 1)).assertEqual(0)
      expect(InteractionPolicy.wrappedTabIndex(2, 3, -1)).assertEqual(1)
      expect(InteractionPolicy.wrappedTabIndex(0, 3, -1)).assertEqual(2)
      expect(InteractionPolicy.wrappedTabIndex(-1, 3, 1)).assertEqual(0)
      expect(InteractionPolicy.wrappedTabIndex(-1, 3, -1)).assertEqual(2)
    })

    it('keepsCursorPositionWhenEditingAPastedLocalCommand', 0, () => {
      let actions: TerminalInputAction[] = TerminalInputParser.parse('\u001b[D\u001b[D\u001b[C', true)
      expect(actions.length).assertEqual(3)
      expect(actions[0].kind).assertEqual(TerminalInputActionKind.CURSOR_LEFT)
      expect(actions[1].kind).assertEqual(TerminalInputActionKind.CURSOR_LEFT)
      expect(actions[2].kind).assertEqual(TerminalInputActionKind.CURSOR_RIGHT)

      let interrupt: TerminalInputAction[] = TerminalInputParser.parse('\u0003', true)
      expect(interrupt.length).assertEqual(1)
      expect(interrupt[0].kind).assertEqual(TerminalInputActionKind.INTERRUPT)

      let deleteActions: TerminalInputAction[] = TerminalInputParser.parse('\u001b[3~', true)
      expect(deleteActions.length).assertEqual(1)
      expect(deleteActions[0].kind).assertEqual(TerminalInputActionKind.DELETE)

      let line: LocalCommandLine = new LocalCommandLine()
      line.insert('ssh user@host')
      expect(line.moveLeft()).assertEqual(true)
      expect(line.moveLeft()).assertEqual(true)
      let suffix: string = line.insert('X')
      expect(line.getText()).assertEqual('ssh user@hoXst')
      expect(line.getCursor()).assertEqual(12)
      expect(suffix).assertEqual('st')
      expect(line.delete()).assertEqual('t')
      expect(line.getText()).assertEqual('ssh user@hoXt')

      line.setText('a😀b')
      expect(line.moveLeft()).assertEqual(true)
      expect(line.moveLeft()).assertEqual(true)
      expect(line.getCursor()).assertEqual(1)
      expect(line.delete()).assertEqual('b')
      expect(line.getText()).assertEqual('ab')
      line.setText('a😀')
      expect(line.backspace()).assertEqual('')
      expect(line.getText()).assertEqual('a')
    })

    it('redrawsLocalCommandsWithoutAssumingChineseCharactersAreOneTerminalColumn', 0, () => {
      let line: LocalCommandLine = new LocalCommandLine()
      line.insert('中文')
      expect(line.moveLeft()).assertEqual(true)
      expect(line.renderForTerminal(LocalCommandOutput.prompt()))
        .assertEqual('\r\u001b[2K\u001b[32mltty>\u001b[0m 中文' +
          '\r\u001b[32mltty>\u001b[0m 中')
      expect(line.backspace() !== null).assertEqual(true)
      expect(line.renderForTerminal(LocalCommandOutput.prompt()))
        .assertEqual('\r\u001b[2K\u001b[32mltty>\u001b[0m 文' +
          '\r\u001b[32mltty>\u001b[0m ')
    })

    it('keepsLocalCommandOutputSemanticAndTextCompleteWithoutColor', 0, () => {
      expect(LocalCommandOutput.prompt()).assertEqual('\u001b[32mltty>\u001b[0m ')
      expect(LocalCommandOutput.status('Preparing', 'upload...'))
        .assertEqual('\u001b[36mPreparing\u001b[0m upload...')
      expect(LocalCommandOutput.success('Uploaded file.'))
        .assertEqual('\u001b[32m●\u001b[0m Uploaded file.')
      expect(LocalCommandOutput.warning('A unique name will be used.'))
        .assertEqual('\u001b[33mWarning:\u001b[0m A unique name will be used.')
      expect(LocalCommandOutput.note('"alias" is deprecated.'))
        .assertEqual('\u001b[36mNote:\u001b[0m "alias" is deprecated.')
      expect(LocalCommandOutput.cancelled()).assertEqual('\u001b[33mCancelled.\u001b[0m')
      expect(LocalCommandOutput.error('Unknown command "oops".', 'Try: help'))
        .assertEqual('\u001b[0m\r\n\u001b[31mError:\u001b[0m Unknown command "oops".\r\n' +
          '  Try: help\r\n\u001b[32mltty>\u001b[0m ')
      expect(LocalCommandOutput.error('Usage: host rm <host-name>'))
        .assertEqual('\u001b[0m\r\n\u001b[31mError:\u001b[0m Invalid command syntax.\r\n' +
          '  Usage: host rm <host-name>\r\n\u001b[32mltty>\u001b[0m ')
      expect(LocalCommandOutput.error('First line.\r\n\r\nSecond group.'))
        .assertEqual('\u001b[0m\r\n\u001b[31mError:\u001b[0m First line.\r\n\r\n' +
          '  Second group.\r\n\u001b[32mltty>\u001b[0m ')
    })

    it('confirmsApplicationCloseOnlyForUnsuppressedActiveSessions', 0, () => {
      expect(InteractionPolicy.shouldConfirmApplicationClose(false, false)).assertEqual(false)
      expect(InteractionPolicy.shouldConfirmApplicationClose(true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldConfirmApplicationClose(true, true)).assertEqual(false)
    })

    it('keepsApplicationClosePreparationSingleFlight', 0, () => {
      let calls: number = 0
      let handler = (): Promise<void> => {
        calls++
        return Promise.resolve()
      }
      ApplicationCloseCoordinator.register(handler)
      let first: Promise<void> = ApplicationCloseCoordinator.prepareTermination()
      let second: Promise<void> = ApplicationCloseCoordinator.prepareTermination()
      expect(calls).assertEqual(1)
      expect(first === second).assertEqual(true)
      ApplicationCloseCoordinator.resetPreparation()
      ApplicationCloseCoordinator.prepareTermination()
      expect(calls).assertEqual(2)
      ApplicationCloseCoordinator.unregister(handler)
    })

    it('keepsBellAttentionPendingOnlyOutsideTheVisibleFocusedPane', 0, () => {
      expect(InteractionPolicy.shouldPersistBellAttention(true, true, true, false)).assertEqual(false)
      expect(InteractionPolicy.shouldPersistBellAttention(false, true, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldPersistBellAttention(true, false, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldPersistBellAttention(true, true, false, false)).assertEqual(true)
      expect(InteractionPolicy.shouldPersistBellAttention(true, true, true, true)).assertEqual(true)
      expect(InteractionPolicy.bellPulseCount(false)).assertEqual(1)
      expect(InteractionPolicy.bellPulseCount(true)).assertEqual(2)
    })

    it('keepsTransparencyToFiveStableSemanticModes', 0, () => {
      expect(TransparencyPolicy.defaultMode()).assertEqual(TransparencyMode.MEDIUM)
      expect(TransparencyPolicy.normalize(-1)).assertEqual(TransparencyMode.MEDIUM)
      expect(TransparencyPolicy.normalize(TransparencyMode.OFF)).assertEqual(TransparencyMode.OFF)
      expect(TransparencyPolicy.normalize(TransparencyMode.HIGH)).assertEqual(TransparencyMode.HIGH)
      expect(TransparencyPolicy.normalize(TransparencyMode.LOW)).assertEqual(TransparencyMode.LOW)
      expect(TransparencyPolicy.normalize(TransparencyMode.EXTREME)).assertEqual(TransparencyMode.EXTREME)
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.OFF)).assertEqual(1.00)
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.LOW)).assertEqual(0.82)
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.MEDIUM)).assertEqual(0.72)
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.HIGH)).assertEqual(0.60)
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.EXTREME)).assertEqual(0.45)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.OFF)).assertEqual(1.00)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.LOW)).assertEqual(0.94)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.MEDIUM)).assertEqual(0.94)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.HIGH)).assertEqual(0.86)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.EXTREME)).assertEqual(0.86)
      expect(TransparencyPolicy.cellBackgroundOpacity(TransparencyMode.OFF)).assertEqual(0.24)
      expect(TransparencyPolicy.cellBackgroundOpacity(TransparencyMode.LOW)).assertEqual(0.20)
      expect(TransparencyPolicy.cellBackgroundOpacity(TransparencyMode.MEDIUM)).assertEqual(0.16)
      expect(TransparencyPolicy.cellBackgroundOpacity(TransparencyMode.HIGH)).assertEqual(0.12)
      expect(TransparencyPolicy.cellBackgroundOpacity(TransparencyMode.EXTREME)).assertEqual(0.08)
      expect(TransparencyPolicy.increase(TransparencyMode.OFF)).assertEqual(TransparencyMode.LOW)
      expect(TransparencyPolicy.increase(TransparencyMode.HIGH)).assertEqual(TransparencyMode.EXTREME)
      expect(TransparencyPolicy.increase(TransparencyMode.EXTREME)).assertEqual(TransparencyMode.EXTREME)
      expect(TransparencyPolicy.decrease(TransparencyMode.EXTREME)).assertEqual(TransparencyMode.HIGH)
      expect(TransparencyPolicy.decrease(TransparencyMode.LOW)).assertEqual(TransparencyMode.OFF)
      expect(TransparencyPolicy.decrease(TransparencyMode.OFF)).assertEqual(TransparencyMode.OFF)
      expect(TransparencyPolicy.canDecrease(TransparencyMode.OFF)).assertEqual(false)
      expect(TransparencyPolicy.canIncrease(TransparencyMode.EXTREME)).assertEqual(false)
    })

    it('derivesSeparateChromeAndContentSurfacesWithAnOpaqueFallback', 0, () => {
      let dark: AppTheme = new AppTheme(ColorMode.DARK, TransparencyMode.HIGH)
      let light: AppTheme = new AppTheme(ColorMode.LIGHT, TransparencyMode.LOW)
      let medium: AppTheme = new AppTheme(ColorMode.DARK, TransparencyMode.MEDIUM)
      let extreme: AppTheme = new AppTheme(ColorMode.DARK, TransparencyMode.EXTREME)
      let lightExtreme: AppTheme = new AppTheme(ColorMode.LIGHT, TransparencyMode.EXTREME)
      let off: AppTheme = new AppTheme(ColorMode.LIGHT, TransparencyMode.OFF)
      expect(dark.background()).assertEqual('#991E1E2E')
      expect(dark.chromeBackground()).assertEqual('#DB1E1E2E')
      expect(dark.chrome.tabBackground).assertEqual('#DB313244')
      expect(dark.chrome.tabHoverBackground).assertEqual('#DB3B3D4F')
      expect(dark.chrome.tabActiveBackground).assertEqual('#DB404255')
      expect(dark.background(false)).assertEqual('#FF1E1E2E')
      expect(dark.chromeBackground(false)).assertEqual('#FF1E1E2E')
      expect(dark.terminal.toJsInitObject().indexOf('rgba(0, 0, 0, 0)') >= 0).assertEqual(true)
      expect(light.background()).assertEqual('#D1EFF1F5')
      expect(light.chromeBackground()).assertEqual('#F0EFF1F5')
      expect(light.chrome.tabBackground).assertEqual('#F0D3D7DF')
      expect(light.chrome.tabHoverBackground).assertEqual('#F0CACED8')
      expect(light.chrome.tabActiveBackground).assertEqual('#F0C6CAD4')
      expect(medium.chromeBackground()).assertEqual('#F01E1E2E')
      expect(medium.chrome.tabBackground).assertEqual('#F02D2E40')
      expect(medium.chrome.tabHoverBackground).assertEqual('#F0343547')
      expect(medium.chrome.tabActiveBackground).assertEqual('#F0393A4D')
      expect(light.background(false)).assertEqual('#FFEFF1F5')
      expect(light.terminal.toJsInitObject().indexOf('rgba(0, 0, 0, 0)') >= 0).assertEqual(true)
      expect(extreme.background()).assertEqual('#731E1E2E')
      expect(extreme.chromeBackground()).assertEqual('#DB1E1E2E')
      expect(extreme.chrome.tabBackground).assertEqual('#DB313244')
      expect(extreme.chrome.tabHoverBackground).assertEqual('#DB3B3D4F')
      expect(extreme.chrome.tabActiveBackground).assertEqual('#DB404255')
      expect(extreme.chromeBackground()).assertEqual(dark.chromeBackground())
      expect(extreme.chrome.tabBackground).assertEqual(dark.chrome.tabBackground)
      expect(extreme.chrome.tabHoverBackground).assertEqual(dark.chrome.tabHoverBackground)
      expect(extreme.chrome.tabActiveBackground).assertEqual(dark.chrome.tabActiveBackground)
      expect(lightExtreme.chrome.tabBackground).assertEqual('#DBCCD0DA')
      expect(lightExtreme.chrome.tabHoverBackground).assertEqual('#DBC4C8D3')
      expect(lightExtreme.chrome.tabActiveBackground).assertEqual('#DBC0C4D0')
      expect(off.background()).assertEqual('#FFEFF1F5')
      expect(off.chromeBackground()).assertEqual('#FFEFF1F5')
      expect(off.chrome.tabBackground).assertEqual('#FFDEE1E8')
      expect(off.chrome.tabHoverBackground).assertEqual('#FFD5D8E1')
      expect(off.chrome.tabActiveBackground).assertEqual('#FFCCD0DA')
    })

    it('doesNotTreatTerminalQueryResponsesAsLocalCommandText', 0, () => {
      let actions: TerminalInputAction[] = TerminalInputParser.parse(
        '\u001b[?1;2c\u001b[6;1R\u001b[1;1R', true)
      expect(actions.length).assertEqual(0)
    })

    it('endsAcceptedHostKeyInputBeforeTheNextAuthenticationPrompt', 0, () => {
      expect(SessionViewModel.hostKeyDecisionSubmitOutput('yes')).assertEqual('\r\n')
      expect(SessionViewModel.hostKeyDecisionSubmitOutput('no')).assertEqual('\r\n')
      expect(SessionViewModel.hostKeyDecisionSubmitOutput('maybe'))
        .assertEqual('\r\nPlease type yes or no: ')
    })

    it('buildsKeypushMarkerAndShellCommandWithoutEchoFalsePositive', 0, () => {
      let generatedMarker: string = SessionViewModel.buildKeypushMarker()
      expect(generatedMarker.startsWith('__LTTY_KEYPUSH_')).assertEqual(true)
      expect(generatedMarker.length > '__LTTY_KEYPUSH_'.length).assertEqual(true)

      let marker: string = '__LTTY_KEYPUSH_99'
      let cmd: string = SessionViewModel.buildKeypushShellCommand('ssh-ed25519 AAAAC test', marker)
      expect(cmd.indexOf(marker + ':') < 0).assertEqual(true)
      let markerPrint: string = "printf '\\n%s:%s\\n' '" + marker + "' \"$command_status\""
      expect(cmd.indexOf(markerPrint) >= 0).assertEqual(true)
      let echoLine: string = "printf '\\n%s:%s\\n' '" + marker + "' '$command_status'\n"
      expect(SessionViewModel.parseKeypushMarker(echoLine, marker)).assertEqual(null)
    })

    it('parsesOnlyCompleteNumericKeypushStatusLines', 0, () => {
      let marker: string = '__LTTY_KEYPUSH_100'
      expect(SessionViewModel.parseKeypushMarker('other\n' + marker + ':0\nmore', marker)).assertEqual(0)
      expect(SessionViewModel.parseKeypushMarker(marker + ':-1\n', marker)).assertEqual(-1)
      expect(SessionViewModel.parseKeypushMarker('missing marker', marker)).assertEqual(null)
      expect(SessionViewModel.parseKeypushMarker(marker + ':0', marker)).assertEqual(null)
      expect(SessionViewModel.parseKeypushMarker(marker + ':%s\n', marker)).assertEqual(null)
      expect(SessionViewModel.parseKeypushMarker(marker + ':\n', marker)).assertEqual(null)
      expect(SessionViewModel.parseKeypushMarker(marker + ':0junk\n', marker)).assertEqual(null)
    })

    it('rejectsRemovedReplayMessagesAndKeepsOsc52DirectionBounded', 0, () => {
      expect(BridgeProtocol.clipboardWriteResult('中文').serialize())
        .assertEqual('H2|W2N|CONTROL|clipboardWrite|中文')
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|replayBegin|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|replayBegin|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|releaseBuffers|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|clipboardWrite|text')).assertEqual(null)
    })

    it('allowsOnlyBoundedDirectionalTerminalSnapshotControls', 0, () => {
      expect(BridgeProtocol.snapshotRequest(7).serialize())
        .assertEqual('H2|N2W|CONTROL|snapshotRequest|7')
      expect(BridgeProtocol.restoreSnapshot('\u001b[31mhistory').serialize())
        .assertEqual('H2|N2W|CONTROL|restoreSnapshot|\u001b[31mhistory')
      let snapshot: BridgeMessage | null =
        BridgeProtocol.parse('H2|W2N|CONTROL|snapshot|7|\u001b[31mhistory')
      expect(snapshot !== null).assertEqual(true)
      if (snapshot !== null) {
        expect(snapshot.kind).assertEqual(BridgeProtocol.KIND_SNAPSHOT)
        expect(snapshot.payload).assertEqual('7|\u001b[31mhistory')
      }
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshotRequest|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshotRequest|0')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshotRequest|07')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|restoreComplete|') !== null).assertEqual(true)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|restoreComplete|unexpected')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshot|history')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|restoreSnapshot|history')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|snapshotRequest|unexpected')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|snapshot|' +
        'x'.repeat(BridgeProtocol.MAX_SNAPSHOT_PAYLOAD_LENGTH + 1))).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|CONTROL|restoreSnapshot|' +
        'x'.repeat(BridgeProtocol.MAX_SNAPSHOT_PAYLOAD_LENGTH + 1))).assertEqual(null)
    })

    it('encodesShiftedDigitsAndAltPunctuation', 0, () => {
      expect(KeyCodeMap.toAnsi(KeyCodeMap.NUM_1, false, false, true)).assertEqual('!')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.NUM_0, false, false, true)).assertEqual(')')
      expect(KeyCodeMap.toAnsi(2057, false, true, false)).assertEqual('\u001b-')
    })

    it('encodesCursorKeysForTerminalModeAndModifiers', 0, () => {
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_UP, false, false, false, true)).assertEqual('\u001bOA')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_LEFT, true, false, false, false)).assertEqual('\u001b[1;5D')
      expect(KeyCodeMap.toAnsi(KeyCodeMap.ARROW_DOWN, false, false, true, false)).assertEqual('\u001b[1;2B')
    })

    it('clampsLayoutAndKeepsOnlyOnePreviousTabSurfaceWarm', 0, () => {
      expect(InteractionPolicy.DEFAULT_FONT_SIZE).assertEqual(16)
      expect(InteractionPolicy.clampSplitRatio(0.05)).assertEqual(0.2)
      expect(InteractionPolicy.clampSplitRatio(0.55)).assertEqual(0.55)
      expect(InteractionPolicy.clampSplitRatio(0.95)).assertEqual(0.8)
      expect(InteractionPolicy.clampFontSize(2)).assertEqual(8)
      expect(InteractionPolicy.clampFontSize(60)).assertEqual(48)
      expect(InteractionPolicy.warmTabAfterSwitch('A')).assertEqual('A')
      expect(InteractionPolicy.evictedWarmTab('A', 'B', '')).assertEqual('')
      expect(InteractionPolicy.warmTabAfterSwitch('B')).assertEqual('B')
      expect(InteractionPolicy.evictedWarmTab('B', 'A', 'A')).assertEqual('')
      expect(InteractionPolicy.warmTabAfterSwitch('A')).assertEqual('A')
      expect(InteractionPolicy.evictedWarmTab('A', 'C', 'B')).assertEqual('B')
    })

    it('keepsConnectedTabsMountedOutsideTheWarmSet', 0, () => {
      expect(InteractionPolicy.shouldMountTab(false, false, true)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(true, false, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(false, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(false, false, false)).assertEqual(false)
      expect(InteractionPolicy.shouldMountTab(true, false, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(false, false, true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(true, false, false, false)).assertEqual(true)
      expect(InteractionPolicy.shouldMountTab(false, true, false, false)).assertEqual(false)
      expect(InteractionPolicy.shouldDetachTabOnEviction(true)).assertEqual(false)
      expect(InteractionPolicy.shouldDetachTabOnEviction(false)).assertEqual(true)
    })

    it('buffersOnlyOutputProducedWhileTheTerminalSurfaceIsDetached', 0, () => {
      let output: TerminalOutputBuffer = new TerminalOutputBuffer(6)
      output.append(new Uint8Array([1, 2, 3, 4]))
      expect(output.isOutputPaused()).assertEqual(false)
      output.append(new Uint8Array([5, 6]))
      expect(output.isOutputPaused()).assertEqual(true)
      expect(output.getDetachedByteCount()).assertEqual(6)
      let detachedChunks: Uint8Array[] = output.takeDetachedChunks()
      expect(detachedChunks.length).assertEqual(2)
      expect(detachedChunks[0][0]).assertEqual(1)
      expect(detachedChunks[1][1]).assertEqual(6)
      output.markAttached()
      expect(output.isOutputPaused()).assertEqual(false)
      output.append(new Uint8Array([7, 8, 9, 10, 11, 12]))
      expect(output.getDetachedByteCount()).assertEqual(0)
      output.setBridgeBackpressured(true)
      expect(output.isOutputPaused()).assertEqual(true)
      output.releaseDisconnectedFlowControl()
      expect(output.isOutputPaused()).assertEqual(false)
      output.markDetached()
      output.append(new Uint8Array([13, 14]))
      expect(output.getDetachedByteCount()).assertEqual(2)
      expect(output.takeDetachedChunks()[0][1]).assertEqual(14)
    })

    it('keepsTheLatestTerminalSnapshotAcrossSurfaceReplacement', 0, () => {
      let output: TerminalOutputBuffer = new TerminalOutputBuffer(16)
      expect(output.getSnapshot()).assertEqual('')
      output.replaceSnapshot('\u001b[31mold')
      expect(output.getSnapshot()).assertEqual('\u001b[31mold')
      output.markAttached()
      output.append(new Uint8Array([1, 2]))
      output.markDetached()
      expect(output.getSnapshot()).assertEqual('\u001b[31mold')
      output.markSessionReset('\u001b[?25h')
      expect(output.getSnapshot()).assertEqual('\u001b[31mold\u001b[?25h')
      output.append(new Uint8Array([3, 4]))
      expect(output.takeDetachedChunks()[0][1]).assertEqual(4)
      output.replaceSnapshot('\u001b[32mnew')
      expect(output.getSnapshot()).assertEqual('\u001b[32mnew')
      output.replaceSnapshot('')
      expect(output.getSnapshot()).assertEqual('')
    })

    it('mapsTaggedCloseResultsToAnActionableSshError', 0, () => {
      expect(SshClient.parseCloseError('-1')).assertEqual(null)
      expect(SshClient.parseCloseError('ERROR:SSH keepalive timed out. Check the network.'))
        .assertEqual('SSH keepalive timed out. Check the network.')
      expect(SshClient.parseCloseError('ERROR:'))
        .assertEqual('SSH connection ended unexpectedly.')
    })
  })
}

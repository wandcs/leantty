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
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'
import { BrowserLauncher } from '../main/ets/model/browser/BrowserLauncher'
import { CommandBarViewModel } from '../main/ets/viewmodel/CommandBarViewModel'
import { AppTheme, ColorMode, TransparencyMode, TransparencyPolicy } from '../main/ets/view/theme/ThemeManager'
import { UserGuideFileDecision, UserGuidePolicy } from '../main/ets/model/guide/UserGuidePolicy'
import { TransferFileManager } from '../main/ets/model/transfer/TransferFileManager'

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

    it('generatesMinimalAutomaticDownloadNames', 0, () => {
      expect(TransferFileManager.automaticName('app.log', 0)).assertEqual('app.log')
      expect(TransferFileManager.automaticName('app.log', 1)).assertEqual('app (1).log')
      expect(TransferFileManager.automaticName('.env', 2)).assertEqual('.env (2)')
      expect(TransferFileManager.automaticName('报告.txt', 3)).assertEqual('报告 (3).txt')
      let longName: string = 'a'.repeat(252) + '.log'
      let numbered: string = TransferFileManager.automaticName(longName, 1)
      expect(numbered.endsWith(' (1).log')).assertEqual(true)
      expect(numbered.length).assertEqual(255)
      let unicodeName: string = '😀'.repeat(62) + 'abc.log'
      let unicodeNumbered: string = TransferFileManager.automaticName(unicodeName, 1)
      expect(unicodeNumbered.endsWith(' (1).log')).assertEqual(true)
      expect(unicodeNumbered.includes('\uFFFD')).assertEqual(false)
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

    it('parsesStructuredChangedHostKeyEvents', 0, () => {
      let info = SshClient.parseHostKeyChangedInfo(
        'ssh-ed25519\tSHA256:old\tSHA256:new\tserver.example.com\t2222')
      expect(info !== null).assertEqual(true)
      if (info !== null) {
        expect(info.algorithm).assertEqual('ssh-ed25519')
        expect(info.oldFingerprint).assertEqual('SHA256:old')
        expect(info.newFingerprint).assertEqual('SHA256:new')
        expect(info.host).assertEqual('server.example.com')
        expect(info.port).assertEqual(2222)
      }
      expect(SshClient.parseHostKeyChangedInfo('SHA256:new')).assertEqual(null)
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
      expect(host instanceof KeyCommandResult).assertEqual(true)
      expect(alias instanceof KeyCommandResult).assertEqual(true)
      if (host instanceof KeyCommandResult) { expect(host.legacySyntax).assertEqual(false) }
      if (alias instanceof KeyCommandResult) { expect(alias.legacySyntax).assertEqual(true) }
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
      vm.getSshConfig().loadFromText('Host prod\n  HostName prod.example.com\n  User deploy\n')
      vm.setInputText('ssh -G pr')
      expect(vm.tryTabComplete()[0]).assertEqual('ssh -G prod')
      vm.setInputText('host set pr')
      expect(vm.tryTabComplete()[0]).assertEqual('host set prod')
      vm.setInputText('host rm pr')
      expect(vm.tryTabComplete()[0]).assertEqual('host rm prod')
      vm.setInputText('put report.txt pr')
      expect(vm.tryTabComplete()[0]).assertEqual('put report.txt prod:')
      vm.setInputText('get pr')
      expect(vm.tryTabComplete()[0]).assertEqual('get prod:')
    })

    it('usesCommonPrefixBeforeListingAmbiguousCompletions', 0, () => {
      let vm: CommandBarViewModel = new CommandBarViewModel()
      vm.getSshConfig().loadFromText('Host prod production\n  HostName prod.example.com\n  User deploy\n')
      vm.setInputText('get p')
      expect(vm.tryTabComplete()[0]).assertEqual('get prod')
      expect(vm.applyCompletion('get prod')).assertEqual('get prod')
      vm.setInputText('get prod')
      expect(vm.tryTabComplete().length).assertEqual(0)
      expect(vm.tryTabComplete().length).assertEqual(2)
    })

    it('parsesEffectiveConfigInspection', 0, () => {
      let result: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh -G prod', new SshConfig())
      expect(result instanceof KeyCommandResult).assertEqual(true)
      if (result instanceof KeyCommandResult) {
        expect(result.kind).assertEqual(KeyCommandKind.SSH_CONFIG)
        expect(result.keyName).assertEqual('prod')
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

    it('resolvesOpenSshFirstValueAndIdentityFile', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('Host prod\n  HostName prod.example.com\n  IdentityFile ~/.ssh/deploy\n\n' +
        'Host *\n  User deploy\n  Port 2200\n')
      let result: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('ssh prod', config)
      expect(result instanceof CommandParseResult).assertEqual(true)
      if (result instanceof CommandParseResult) {
        expect(result.host).assertEqual('prod.example.com')
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

    it('rejectsUnknownOrInvalidConfigBeforeConnection', 0, () => {
      let unknown: SshConfig = new SshConfig()
      unknown.loadFromText('Host prod\n  HostName prod.example.com\n  User deploy\n  ProxyJump bastion\n')
      let unknownResult = CommandParser.parseInput('ssh prod', unknown)
      expect(unknownResult instanceof CommandParseResult).assertEqual(true)
      if (unknownResult instanceof CommandParseResult) {
        expect(unknownResult.isValid).assertEqual(false)
        expect(unknownResult.errorMessage.includes('ProxyJump')).assertEqual(true)
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
      let malformedTarget = CommandParser.parseInput('ssh deploy@example.com:22oops', config)
      let bracketSuffix = CommandParser.parseInput('ssh deploy@[2001:db8::1]oops', config)
      expect(malformed instanceof CommandParseResult).assertEqual(true)
      expect(duplicatePort instanceof CommandParseResult).assertEqual(true)
      expect(duplicateIdentity instanceof CommandParseResult).assertEqual(true)
      expect(malformedTarget instanceof CommandParseResult).assertEqual(true)
      expect(bracketSuffix instanceof CommandParseResult).assertEqual(true)
      if (malformed instanceof CommandParseResult) { expect(malformed.isValid).assertEqual(false) }
      if (duplicatePort instanceof CommandParseResult) {
        expect(duplicatePort.errorMessage).assertEqual('Duplicate SSH option: -p')
      }
      if (duplicateIdentity instanceof CommandParseResult) {
        expect(duplicateIdentity.errorMessage).assertEqual('Duplicate SSH option: -i')
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
      expect(BridgeProtocol.copySelection().serialize()).assertEqual('H2|N2W|CONTROL|copySelection|')
      expect(BridgeProtocol.parse(BridgeProtocol.copySelection().serialize()) !== null).assertEqual(true)
      expect(BridgeProtocol.secondaryAction().serialize()).assertEqual('H2|N2W|CONTROL|secondaryAction|')
      expect(BridgeProtocol.searchOpen().serialize()).assertEqual('H2|N2W|CONTROL|searchOpen|')
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
      expect(BridgeProtocol.parse('H2|W2N|CONTROL|searchOpen|')).assertEqual(null)
      expect(BridgeProtocol.parse('H2|N2W|DATA|searchOpen|')).assertEqual(null)
    })

    it('routesPhysicalTabToTerminalCompletion', 0, () => {
      let tab: string = KeyCodeMap.toAnsi(KeyCodeMap.TAB, false, false, false)
      let actions: TerminalInputAction[] = TerminalInputParser.parse(tab, true)
      expect(tab).assertEqual('\t')
      expect(actions.length).assertEqual(1)
      expect(actions[0].kind).assertEqual(TerminalInputActionKind.TAB)
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

      let line: LocalCommandLine = new LocalCommandLine()
      line.insert('ssh user@host')
      expect(line.moveLeft()).assertEqual(true)
      expect(line.moveLeft()).assertEqual(true)
      let suffix: string = line.insert('X')
      expect(line.getText()).assertEqual('ssh user@hoXst')
      expect(line.getCursor()).assertEqual(12)
      expect(suffix).assertEqual('st')
    })

    it('redrawsLocalCommandsWithoutAssumingChineseCharactersAreOneTerminalColumn', 0, () => {
      let line: LocalCommandLine = new LocalCommandLine()
      line.insert('中文')
      expect(line.moveLeft()).assertEqual(true)
      expect(line.renderForTerminal('ltty> '))
        .assertEqual('\r\u001b[2Kltty> 中文\rltty> 中')
      expect(line.backspace() !== null).assertEqual(true)
      expect(line.renderForTerminal('ltty> '))
        .assertEqual('\r\u001b[2Kltty> 文\rltty> ')
    })

    it('confirmsApplicationCloseOnlyForUnsuppressedActiveSessions', 0, () => {
      expect(InteractionPolicy.shouldConfirmApplicationClose(false, false)).assertEqual(false)
      expect(InteractionPolicy.shouldConfirmApplicationClose(true, false)).assertEqual(true)
      expect(InteractionPolicy.shouldConfirmApplicationClose(true, true)).assertEqual(false)
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
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.LOW)).assertEqual(0.90)
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.MEDIUM)).assertEqual(0.82)
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.HIGH)).assertEqual(0.72)
      expect(TransparencyPolicy.contentOpacity(TransparencyMode.EXTREME)).assertEqual(0.60)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.OFF)).assertEqual(1.00)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.LOW)).assertEqual(0.94)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.MEDIUM)).assertEqual(0.88)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.HIGH)).assertEqual(0.80)
      expect(TransparencyPolicy.chromeOpacity(TransparencyMode.EXTREME)).assertEqual(0.70)
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
      let extreme: AppTheme = new AppTheme(ColorMode.DARK, TransparencyMode.EXTREME)
      let off: AppTheme = new AppTheme(ColorMode.LIGHT, TransparencyMode.OFF)
      expect(dark.background()).assertEqual('#B81E1E2E')
      expect(dark.chromeBackground()).assertEqual('#CC11111B')
      expect(dark.background(false)).assertEqual('#FF1E1E2E')
      expect(dark.chromeBackground(false)).assertEqual('#FF11111B')
      expect(dark.terminal.toJsInitObject().indexOf('rgba(0, 0, 0, 0)') >= 0).assertEqual(true)
      expect(light.background()).assertEqual('#E6EFF1F5')
      expect(light.chromeBackground()).assertEqual('#F0DCE0E8')
      expect(light.background(false)).assertEqual('#FFEFF1F5')
      expect(light.terminal.toJsInitObject().indexOf('rgba(0, 0, 0, 0)') >= 0).assertEqual(true)
      expect(extreme.background()).assertEqual('#991E1E2E')
      expect(extreme.chromeBackground()).assertEqual('#B311111B')
      expect(off.background()).assertEqual('#FFEFF1F5')
      expect(off.chromeBackground()).assertEqual('#FFDCE0E8')
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

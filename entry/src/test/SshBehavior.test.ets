import { describe, it, expect } from '@ohos/hypium'
import { CommandParser, CommandParseResult, KeyCommandKind, KeyCommandResult, TransferCommandResult } from '../main/ets/model/command/CommandParser'
import { SshConfig } from '../main/ets/model/ssh/SshConfig'
import { SshClient, SshDiagnosticInfo } from '../main/ets/model/ssh/SshClient'
import { SshError, SshErrorCode } from '../main/ets/common/types/SshTypes'
import { SshEscapeEvent, SshEscapeEventKind, SshEscapeParser, SshEscapeResult } from '../main/ets/model/ssh/SshEscapeParser'
import { TerminalInputAction, TerminalInputParser } from '../main/ets/model/terminal/TerminalInputParser'
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'

export default function sshBehaviorTest() {
  describe('SshBehavior', () => {
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
      expect(SessionViewModel.safeSshErrorLogLabel(new SshError(
        SshErrorCode.Network, 'connection timed out after 1000 ms',
        'connection timed out after 1000 ms', 'target')))
        .assertEqual('SSH error: target:connection timed out after 1000 ms')
      expect(SessionViewModel.safeSshErrorLogLabel(new SshError(
        SshErrorCode.Network, 'private.example refused the key',
        'private.example refused the key', 'target')))
        .assertEqual('SSH error')
      let started: SshDiagnosticInfo = new SshDiagnosticInfo()
      started.layer = 'target'
      started.stage = 'connect'
      started.status = 'started'
      let line: string = SessionViewModel.formatSshDiagnostic(started)
      expect(line.includes('Target transport: started.')).assertEqual(true)
      expect(line.includes('private.example')).assertEqual(false)
      let invalid: SshDiagnosticInfo = new SshDiagnosticInfo()
      invalid.layer = 'target'
      invalid.stage = 'raw_packet'
      invalid.status = 'started'
      let rejected: string = SessionViewModel.formatSshDiagnostic(invalid)
      expect(rejected.includes('Diagnostic event rejected.')).assertEqual(true)
      let failed: SshDiagnosticInfo = new SshDiagnosticInfo()
      failed.layer = 'target'
      failed.stage = 'connect'
      failed.status = 'failed'
      failed.reason = 'tcp_refused'
      let refused: string = SessionViewModel.formatSshDiagnostic(failed)
      expect(refused.includes('Target TCP connection: refused.')).assertEqual(true)
      expect(refused.includes('private.example')).assertEqual(false)
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

  })
}

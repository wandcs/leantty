import { describe, it, expect } from '@ohos/hypium'
import { CommandParser, CommandParseResult, KeyCommandKind, KeyCommandResult, TransferCommandResult } from '../main/ets/model/command/CommandParser'
import { SshConfig } from '../main/ets/model/ssh/SshConfig'
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'
import { CommandBarViewModel } from '../main/ets/viewmodel/CommandBarViewModel'

export default function keyManagementBehaviorTest() {
  describe('KeyManagementBehavior', () => {
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

    it('parsesOnlyTheInteractiveKeyCommentChangeForm', 0, () => {
      let standard: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -c -f deploy')
      let reordered: KeyCommandResult = CommandParser.parseSshKeygen('ssh-keygen -f ~/.ssh/deploy -c')
      expect(standard.kind).assertEqual(KeyCommandKind.KEY_COMMENT_CHANGE)
      expect(standard.keyName).assertEqual('deploy')
      expect(reordered.kind).assertEqual(KeyCommandKind.KEY_COMMENT_CHANGE)
      expect(reordered.keyName).assertEqual('~/.ssh/deploy')
      expect(CommandParser.parseSshKeygen('ssh-keygen -c').errorMessage.length > 0).assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -c -f one -f two').errorMessage.length > 0)
        .assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -c -f deploy -C inline').errorMessage.length > 0)
        .assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -c -f deploy -p').errorMessage.length > 0)
        .assertEqual(true)
      expect(CommandParser.parseSshKeygen('ssh-keygen -c -f deploy extra').errorMessage.length > 0)
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
      expect(SessionViewModel.sshFailureTitle('jump'))
        .assertEqual('The jump host connection failed.')
      expect(SessionViewModel.sshFailureTitle('target'))
        .assertEqual('The target host connection failed.')
      expect(SessionViewModel.sshFailureTitle(''))
        .assertEqual('The SSH connection failed.')
      let warning: string = SessionViewModel.buildHostKeyChangedWarning(
        'jump.example.com', 2200, 'ssh-ed25519', 'SHA256:old', 'SHA256:new', 'jump')
      expect(warning.startsWith('Jump host identification has changed.')).assertEqual(true)
      expect(warning.includes('Host: [jump.example.com]:2200')).assertEqual(true)
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

  })
}

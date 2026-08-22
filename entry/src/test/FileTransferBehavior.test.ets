import { describe, it, expect } from '@ohos/hypium'
import { CommandParser, CommandParseResult, KeyCommandKind, KeyCommandResult, TransferCommandResult, TransferDirection } from '../main/ets/model/command/CommandParser'
import { SshConfig } from '../main/ets/model/ssh/SshConfig'
import { SessionViewModel } from '../main/ets/viewmodel/SessionViewModel'
import { FileTransferLifecycle, FileTransferPhase } from '../main/ets/model/transfer/FileTransferLifecycle'
import { FileTransferFailureInfo, FileTransferFailureKind, FileTransferFailurePresenter } from '../main/ets/model/transfer/FileTransferFailure'
import { TransferFileManager } from '../main/ets/model/transfer/TransferFileManager'
import { DownloadsAccessManager } from '../main/ets/model/transfer/DownloadsAccessManager'

export default function fileTransferBehaviorTest() {
  describe('FileTransferBehavior', () => {
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

  })
}

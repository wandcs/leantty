import { describe, it, expect } from '@ohos/hypium'
import { CommandParser, CommandParseResult, KeyCommandKind, KeyCommandResult, TransferCommandResult } from '../main/ets/model/command/CommandParser'
import { SshConfig } from '../main/ets/model/ssh/SshConfig'
import { BrowserLauncher } from '../main/ets/model/browser/BrowserLauncher'
import { UserGuideFileDecision, UserGuidePolicy } from '../main/ets/model/guide/UserGuidePolicy'

function asciiBytes(text: string): Uint8Array {
  let result: Uint8Array = new Uint8Array(text.length)
  for (let i: number = 0; i < text.length; i++) {
    result[i] = text.charCodeAt(i)
  }
  return result
}

export default function localCommandBehaviorTest() {
  describe('LocalCommandBehavior', () => {
    it('parsesKeySubcommandsFromTheCorrectArgument', 0, () => {
      let config: SshConfig = new SshConfig()
      let removeResult: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('key rm deploy', config)
      let importResult: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('key import C:\\keys\\source deploy', config)
      let exportResult: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('key export deploy', config)
      expect(removeResult instanceof KeyCommandResult).assertEqual(true)
      expect(importResult instanceof KeyCommandResult).assertEqual(true)
      expect(exportResult instanceof KeyCommandResult).assertEqual(true)
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

    it('rejectsRemovedLegacyCommandSpellings', 0, () => {
      let config: SshConfig = new SshConfig()
      for (let command of ['alias add prod root@example.com', 'alias list', 'keys']) {
        expect(CommandParser.parseInput(command, config)).assertNull()
      }
      let keyShow: CommandParseResult | KeyCommandResult | TransferCommandResult | null =
        CommandParser.parseInput('key show deploy', config)
      expect(keyShow instanceof KeyCommandResult).assertEqual(true)
      if (keyShow instanceof KeyCommandResult) {
        expect(keyShow.kind).assertEqual(KeyCommandKind.KEYS)
        expect(keyShow.errorMessage).assertEqual('Usage: key list | key import <path> [<key-name>] | ' +
          'key export <key-name> [<file-name>] | key rm <key-name>')
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
      expect(UserGuidePolicy.localizedOpenUri(expected, true)).assertEqual(expected + '#guide-zh')
      expect(UserGuidePolicy.localizedOpenUri(expected, false)).assertEqual(expected + '#guide-en')
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

  })
}

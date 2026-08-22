import { describe, it, expect } from '@ohos/hypium'
import { SshConfig } from '../main/ets/model/ssh/SshConfig'
import { SshConfigCommitPolicy } from '../main/ets/model/persistence/SshConfigCommitPolicy'
import { CommandParser, KeyCommandKind, KeyCommandResult } from '../main/ets/model/command/CommandParser'
import {
  CONFIG_INCLUDE,
  CONFIG_MATCH,
  CONFIG_ROUND_TRIP_CRLF,
  CONFIG_ROUND_TRIP_LF,
  CONFIG_TOKEN_EXPANSION,
  CONFIG_UNKNOWN_DIRECTIVE
} from './fixtures/ssh-config/SshConfigFixtures'

export default function sshConfigImportTest() {
  describe('SshConfigImport', () => {
    it('preservesImportedLfTextAcrossManagedAddSetRemoveAndReopen', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('')
      let imported: string = config.previewImportedText(CONFIG_ROUND_TRIP_LF)
      expect(imported).assertEqual(CONFIG_ROUND_TRIP_LF)

      config.loadFromText(imported)
      config.addAlias('leantty-local', 'local.example.test', 22, 'developer')
      let added: string = config.previewConfigText()
      expect(added.includes(CONFIG_ROUND_TRIP_LF)).assertEqual(true)

      let reopened: SshConfig = new SshConfig()
      reopened.loadFromText(added)
      expect(reopened.previewConfigText()).assertEqual(added)
      reopened.addAlias('leantty-local', 'changed.example.test', 2200, 'operator')
      let updated: string = reopened.previewConfigText()
      expect(updated.includes(CONFIG_ROUND_TRIP_LF)).assertEqual(true)

      reopened.loadFromText(updated)
      expect(reopened.removeAlias('leantty-local')).assertEqual(true)
      expect(reopened.previewConfigText()).assertEqual(CONFIG_ROUND_TRIP_LF)
    })

    it('preservesCrLfAndWhitespaceExactly', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('')
      expect(config.previewImportedText(CONFIG_ROUND_TRIP_CRLF)).assertEqual(CONFIG_ROUND_TRIP_CRLF)
      config.loadFromText(CONFIG_ROUND_TRIP_CRLF)
      expect(config.getConfigText()).assertEqual(CONFIG_ROUND_TRIP_CRLF)
    })

    it('preservesUnknownDirectiveButBlocksItsMatchingConnection', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText('')
      let imported: string = config.previewImportedText(CONFIG_UNKNOWN_DIRECTIVE)
      expect(imported).assertEqual(CONFIG_UNKNOWN_DIRECTIVE)
      config.loadFromText(imported)
      let guarded = config.findHost('guarded')
      expect(guarded !== null).assertEqual(true)
      if (guarded !== null) {
        expect(guarded.errorMessage.includes('StrictHostKeyChecking')).assertEqual(true)
      }
    })

    it('rejectsExternalAuthorityConditionalParsingAndTokenExpansion', 0, () => {
      for (let invalid of [CONFIG_INCLUDE, CONFIG_MATCH, CONFIG_TOKEN_EXPANSION,
        '# >>> LeanTTY managed hosts >>>\nHost forged\n']) {
        let config: SshConfig = new SshConfig()
        config.loadFromText('')
        expect(() => config.previewImportedText(invalid)).assertThrowError(Error)
      }
    })

    it('rejectsASecondUnmanagedImport', 0, () => {
      let config: SshConfig = new SshConfig()
      config.loadFromText(CONFIG_ROUND_TRIP_LF)
      expect(() => config.previewImportedText(CONFIG_ROUND_TRIP_CRLF)).assertThrowError(Error)
      expect(config.previewImportedText(CONFIG_ROUND_TRIP_CRLF, true)).assertEqual(CONFIG_ROUND_TRIP_CRLF)
      expect(config.previewImportedText('', true)).assertEqual('')
    })

    it('parsesOnlyTheBoundedConfigCommands', 0, () => {
      let config: SshConfig = new SshConfig()
      let imported = CommandParser.parseInput('config import workstation.conf --replace', config)
      let exported = CommandParser.parseInput('config export', config)
      let namedExport = CommandParser.parseInput('config export backup.conf', config)
      expect(imported instanceof KeyCommandResult).assertEqual(true)
      expect(exported instanceof KeyCommandResult).assertEqual(true)
      expect(namedExport instanceof KeyCommandResult).assertEqual(true)
      if (imported instanceof KeyCommandResult) {
        expect(imported.kind).assertEqual(KeyCommandKind.CONFIG_IMPORT)
        expect(imported.sourcePath).assertEqual('workstation.conf')
        expect(imported.replaceExisting).assertEqual(true)
      }
      if (exported instanceof KeyCommandResult) {
        expect(exported.kind).assertEqual(KeyCommandKind.CONFIG_EXPORT)
        expect(exported.destinationName).assertEqual('leantty-ssh-config')
      }
      if (namedExport instanceof KeyCommandResult) {
        expect(namedExport.destinationName).assertEqual('backup.conf')
      }
      let unsupported = CommandParser.parseInput('config watch', config)
      expect(unsupported instanceof KeyCommandResult).assertEqual(true)
      if (unsupported instanceof KeyCommandResult) {
        expect(unsupported.errorMessage.includes('Usage: config import')).assertEqual(true)
      }
    })

    it('rollsProjectionBackWhenDurableCommitFails', 0, () => {
      let projected: string = 'old'
      let durable: string = 'old'
      let removed: boolean = false
      expect(() => SshConfigCommitPolicy.commit('old', 'new',
        (content: string): void => { projected = content },
        (content: string): void => { durable = content; throw new Error('fault') },
        (): void => { removed = true })).assertThrowError(Error)
      expect(projected).assertEqual('old')
      expect(durable).assertEqual('new')
      expect(removed).assertEqual(false)
    })

    it('removesNewProjectionWhenFirstDurableCommitFails', 0, () => {
      let projected: string = ''
      let removed: boolean = false
      expect(() => SshConfigCommitPolicy.commit(null, 'new',
        (content: string): void => { projected = content },
        (content: string): void => { throw new Error('fault') },
        (): void => { removed = true; projected = '' })).assertThrowError(Error)
      expect(projected).assertEqual('')
      expect(removed).assertEqual(true)
    })
  })
}

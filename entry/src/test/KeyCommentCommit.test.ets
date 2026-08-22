import { describe, expect, it } from '@ohos/hypium'
import { KeyCommentCommitPolicy } from '../main/ets/model/persistence/KeyCommentCommitPolicy'

export default function keyCommentCommitTest(): void {
  describe('KeyCommentCommit', () => {
    it('returnsTheOldCommentAfterDurableCaptureSucceeds', 0, () => {
      let projected: string = 'old comment'
      let durable: string = 'old comment'
      let oldComment: string = KeyCommentCommitPolicy.commit(
        (): string => {
          let previous: string = projected
          projected = 'new comment'
          return previous
        },
        (): void => { durable = projected },
        (previous: string): void => { projected = previous }
      )
      expect(oldComment).assertEqual('old comment')
      expect(projected).assertEqual('new comment')
      expect(durable).assertEqual('new comment')
    })

    it('rollsThePairBackWhenDurableCaptureFails', 0, () => {
      let projected: string = 'old comment'
      let rollbackComment: string = ''
      expect(() => KeyCommentCommitPolicy.commit(
        (): string => {
          projected = 'new comment'
          return 'old comment'
        },
        (): void => { throw new Error('fault') },
        (previous: string): void => {
          rollbackComment = previous
          projected = previous
        }
      )).assertThrowError(Error)
      expect(projected).assertEqual('old comment')
      expect(rollbackComment).assertEqual('old comment')
    })

    it('reportsWhenProjectionRollbackAlsoFails', 0, () => {
      let detail: string = ''
      try {
        KeyCommentCommitPolicy.commit(
          (): string => 'old comment',
          (): void => { throw new Error('durable fault') },
          (_previous: string): void => { throw new Error('rollback fault') }
        )
      } catch (e) {
        detail = '' + e
      }
      expect(detail.includes('durable retention and rollback failed')).assertEqual(true)
    })
  })
}

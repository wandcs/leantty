import { describe, expect, it } from '@ohos/hypium'
import { KeyPairDeletionPolicy } from '../main/ets/model/persistence/KeyPairDeletionPolicy'

export default function keyPairDeletionTest(): void {
  describe('KeyPairDeletion', () => {
    it('removesTheProjectionBeforeItsDurableAuthority', 0, () => {
      let calls: string[] = []
      KeyPairDeletionPolicy.commit(
        (): void => { calls.push('remove-projection') },
        (): void => { calls.push('remove-durable') },
        (): void => { calls.push('restore-projection') },
        (): void => { calls.push('restore-durable') }
      )
      expect(calls.join(',')).assertEqual('remove-projection,remove-durable')
    })

    it('restoresTheProjectionWithoutTouchingDurableStateWhenProjectionRemovalFails', 0, () => {
      let calls: string[] = []
      expect(() => KeyPairDeletionPolicy.commit(
        (): void => {
          calls.push('remove-projection')
          throw new Error('projection fault')
        },
        (): void => { calls.push('remove-durable') },
        (): void => { calls.push('restore-projection') },
        (): void => { calls.push('restore-durable') }
      )).assertThrowError(Error)
      expect(calls.join(',')).assertEqual('remove-projection,restore-projection')
    })

    it('restoresDurableAndProjectionStateWhenDurableRemovalFails', 0, () => {
      let calls: string[] = []
      expect(() => KeyPairDeletionPolicy.commit(
        (): void => { calls.push('remove-projection') },
        (): void => {
          calls.push('remove-durable')
          throw new Error('durable fault')
        },
        (): void => { calls.push('restore-projection') },
        (): void => { calls.push('restore-durable') }
      )).assertThrowError(Error)
      expect(calls.join(',')).assertEqual(
        'remove-projection,remove-durable,restore-durable,restore-projection')
    })

    it('reportsWhenDurableAndProjectionRollbackBothFail', 0, () => {
      let detail: string = ''
      try {
        KeyPairDeletionPolicy.commit(
          (): void => {},
          (): void => { throw new Error('durable fault') },
          (): void => { throw new Error('projection rollback fault') },
          (): void => { throw new Error('durable rollback fault') }
        )
      } catch (e) {
        detail = '' + e
      }
      expect(detail.includes('durable rollback failed')).assertEqual(true)
      expect(detail.includes('projection rollback failed')).assertEqual(true)
    })
  })
}

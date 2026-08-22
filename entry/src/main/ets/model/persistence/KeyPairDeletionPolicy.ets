export class KeyPairDeletionPolicy {
  static commit(
    removeProjection: () => void,
    removeDurable: () => void,
    restoreProjection: () => void,
    restoreDurable: () => void
  ): void {
    try {
      removeProjection()
    } catch (e) {
      try {
        restoreProjection()
      } catch (rollbackError) {
        throw new Error('Key projection deletion and rollback failed; durable key remains retained: ' +
          rollbackError)
      }
      throw new Error('Key deletion failed; the original key remains active: ' + e)
    }

    try {
      removeDurable()
    } catch (e) {
      let durableRollbackError: string = ''
      let projectionRollbackError: string = ''
      try {
        restoreDurable()
      } catch (rollbackError) {
        durableRollbackError = '' + rollbackError
      }
      try {
        restoreProjection()
      } catch (rollbackError) {
        projectionRollbackError = '' + rollbackError
      }
      if (durableRollbackError.length > 0 || projectionRollbackError.length > 0) {
        let detail: string = 'Key deletion failed and rollback was incomplete:'
        if (durableRollbackError.length > 0) {
          detail += ' durable rollback failed: ' + durableRollbackError + ';'
        }
        if (projectionRollbackError.length > 0) {
          detail += ' projection rollback failed: ' + projectionRollbackError + ';'
        }
        throw new Error(detail)
      }
      throw new Error('Key deletion failed; the original key remains active: ' + e)
    }
  }
}

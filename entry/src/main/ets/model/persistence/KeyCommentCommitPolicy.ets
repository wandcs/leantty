export class KeyCommentCommitPolicy {
  static commit(
    changeProjection: () => string,
    captureDurable: () => void,
    rollbackProjection: (oldComment: string) => void
  ): string {
    let oldComment: string = changeProjection()
    try {
      captureDurable()
    } catch (e) {
      try {
        rollbackProjection(oldComment)
      } catch (rollbackError) {
        throw new Error('Key comment changed but durable retention and rollback failed: ' + rollbackError)
      }
      throw new Error('Failed to retain changed key comment; the original comment remains active: ' + e)
    }
    return oldComment
  }
}

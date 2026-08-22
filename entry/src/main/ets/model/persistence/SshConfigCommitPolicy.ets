export class SshConfigCommitPolicy {
  static commit(
    previous: string | null,
    next: string,
    writeProjection: (content: string) => void,
    writeDurable: (content: string) => void,
    removeProjection: () => void
  ): void {
    writeProjection(next)
    try {
      writeDurable(next)
    } catch (e) {
      try {
        if (previous === null) {
          removeProjection()
        } else {
          writeProjection(previous)
        }
      } catch (rollbackError) {
        throw new Error('SSH config commit and projection rollback failed: ' + rollbackError)
      }
      throw new Error('SSH config commit failed; the previous config remains active: ' + e)
    }
  }
}

export class SshEnvironmentReadiness {
  private preparation: Promise<void> | null = null
  private ready: boolean = false

  ensure(action: () => Promise<void>): Promise<void> {
    if (this.ready) {
      return Promise.resolve()
    }
    if (this.preparation !== null) {
      return this.preparation
    }
    let started: Promise<void>
    try {
      started = action()
    } catch (e) {
      return Promise.reject(e)
    }
    this.preparation = started.then(() => {
      this.ready = true
      this.preparation = null
    }, (e: Error) => {
      this.preparation = null
      throw e
    })
    return this.preparation
  }

  isReady(): boolean {
    return this.ready
  }
}

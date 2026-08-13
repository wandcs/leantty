export enum FileTransferPhase {
  IDLE = 0,
  PREPARING = 1,
  TRANSFERRING = 2,
  FINALIZING = 3,
  SUCCEEDED = 4,
  FAILED = 5,
  CANCELLED = 6
}

export class FileTransferLifecycle {
  private phase: FileTransferPhase = FileTransferPhase.IDLE

  getPhase(): FileTransferPhase {
    return this.phase
  }

  isActive(): boolean {
    return FileTransferLifecycle.isActivePhase(this.phase)
  }

  transition(next: FileTransferPhase): boolean {
    if (!FileTransferLifecycle.canTransition(this.phase, next)) { return false }
    this.phase = next
    return true
  }

  static isActivePhase(phase: FileTransferPhase): boolean {
    return phase === FileTransferPhase.PREPARING ||
      phase === FileTransferPhase.TRANSFERRING ||
      phase === FileTransferPhase.FINALIZING
  }

  static isTerminalPhase(phase: FileTransferPhase): boolean {
    return phase === FileTransferPhase.SUCCEEDED ||
      phase === FileTransferPhase.FAILED ||
      phase === FileTransferPhase.CANCELLED
  }

  static canTransition(current: FileTransferPhase, next: FileTransferPhase): boolean {
    if (current === next && FileTransferLifecycle.isActivePhase(current)) { return true }
    if (current === FileTransferPhase.IDLE) {
      return next === FileTransferPhase.PREPARING
    }
    if (current === FileTransferPhase.PREPARING) {
      return next === FileTransferPhase.TRANSFERRING ||
        next === FileTransferPhase.FAILED || next === FileTransferPhase.CANCELLED
    }
    if (current === FileTransferPhase.TRANSFERRING) {
      return next === FileTransferPhase.FINALIZING ||
        next === FileTransferPhase.FAILED || next === FileTransferPhase.CANCELLED
    }
    if (current === FileTransferPhase.FINALIZING) {
      return next === FileTransferPhase.SUCCEEDED ||
        next === FileTransferPhase.FAILED || next === FileTransferPhase.CANCELLED
    }
    return FileTransferLifecycle.isTerminalPhase(current) && next === FileTransferPhase.IDLE
  }
}

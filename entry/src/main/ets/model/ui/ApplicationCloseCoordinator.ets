export type ApplicationCloseHandler = () => Promise<void>

export class ApplicationCloseCoordinator {
  private static handler: ApplicationCloseHandler | null = null
  private static preparation: Promise<void> | null = null

  static register(handler: ApplicationCloseHandler): void {
    ApplicationCloseCoordinator.handler = handler
    ApplicationCloseCoordinator.preparation = null
  }

  static unregister(handler: ApplicationCloseHandler): void {
    if (ApplicationCloseCoordinator.handler !== handler) {
      return
    }
    ApplicationCloseCoordinator.handler = null
    ApplicationCloseCoordinator.preparation = null
  }

  static prepareTermination(): Promise<void> {
    if (ApplicationCloseCoordinator.preparation !== null) {
      return ApplicationCloseCoordinator.preparation
    }
    if (ApplicationCloseCoordinator.handler === null) {
      return Promise.resolve()
    }
    ApplicationCloseCoordinator.preparation = ApplicationCloseCoordinator.handler()
    return ApplicationCloseCoordinator.preparation
  }

  static resetPreparation(): void {
    ApplicationCloseCoordinator.preparation = null
  }
}

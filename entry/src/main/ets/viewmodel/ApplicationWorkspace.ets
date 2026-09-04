import { AppViewModel } from './AppViewModel'

// Keep the live Tab -> Pane -> Session graph outside ArkUI state storage. The graph owns callbacks,
// native handles and renderer objects; only the simple UI projections belong in @State/AppStorage.
export class ApplicationWorkspace {
  private static instance: ApplicationWorkspace | null = null
  private readonly appViewModel: AppViewModel = new AppViewModel()
  private initialized: boolean = false
  private splitRatio: number = 0.5

  static getInstance(): ApplicationWorkspace {
    if (ApplicationWorkspace.instance === null) {
      ApplicationWorkspace.instance = new ApplicationWorkspace()
    }
    return ApplicationWorkspace.instance
  }

  getViewModel(): AppViewModel {
    return this.appViewModel
  }

  isInitialized(): boolean {
    return this.initialized
  }

  initialize(splitRatio: number): void {
    if (this.initialized) {
      return
    }
    this.splitRatio = splitRatio
    this.initialized = true
  }

  getSplitRatio(): number {
    return this.splitRatio
  }

  setSplitRatio(splitRatio: number): void {
    this.splitRatio = splitRatio
  }
}

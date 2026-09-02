import { AppViewModel } from './AppViewModel'

// HarmonyOS may rebuild the WindowStage while the application process and its Sessions stay alive.
// Keep the Tab -> Pane -> Session owner at process scope so a replacement page only rebinds UI.
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

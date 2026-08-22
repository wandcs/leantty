import webview from '@ohos.web.webview'
import { Logger } from '../common/logger/Logger'
import { TerminalSurfaceController } from '../model/terminal/TerminalSurfaceController'
import { SessionViewModel } from './SessionViewModel'

const logger: Logger = new Logger('PaneRuntime')

export class PaneRuntime {
  readonly id: string
  readonly viewModel: SessionViewModel
  readonly surface: TerminalSurfaceController
  generation: number = 0
  private disposed: boolean = false

  constructor(id: string, viewModel: SessionViewModel) {
    this.id = id
    this.viewModel = viewModel
    this.surface = new TerminalSurfaceController()
    this.viewModel.bindTerminalSurface(this.surface)
  }

  attachSurface(ctrl: webview.WebviewController): void {
    if (this.disposed) {
      return
    }
    this.detachSurface()
    this.surface.attach(ctrl)
  }

  detachSurface(): void {
    this.surface.detach()
    this.viewModel.onTerminalSurfaceDetached()
  }

  recycleSurface(): void {
    if (this.disposed) {
      return
    }
    this.detachSurface()
    this.generation++
  }

  isDisposed(): boolean {
    return this.disposed
  }

  async disconnect(): Promise<void> {
    await this.viewModel.disconnect()
  }

  async dispose(): Promise<void> {
    if (this.disposed) {
      return
    }
    this.disposed = true
    try {
      await this.viewModel.disconnect()
    } catch (e) {
      logger.warn('Pane disconnect failed: ' + e)
    }
    this.detachSurface()
  }
}

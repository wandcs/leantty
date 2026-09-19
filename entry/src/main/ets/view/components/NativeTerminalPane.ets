import { common } from '@kit.AbilityKit'
import { TerminalSurfaceController } from '../../model/terminal/TerminalSurfaceController'
import { NativeTerminalController } from '../../model/terminal/NativeTerminalController'
import { UiText } from '../../model/ui/UiText'
import { KeyCodeMap } from '../../common/constants/KeyCodeMap'
import { pointer } from '@kit.InputKit'

class PaneSurface extends XComponentController {
  changed: (id: string, rect: SurfaceRect) => void = () => {}
  destroyed: (id: string) => void = () => {}
  onSurfaceCreated(id: string): void { this.changed(id, this.getXComponentSurfaceRect()) }
  onSurfaceChanged(id: string, rect: SurfaceRect): void { this.changed(id, rect) }
  onSurfaceDestroyed(id: string): void { this.destroyed(id) }
}

@Component
export struct NativeTerminalPane {
  surface: TerminalSurfaceController = new TerminalSurfaceController()
  paneId: string = ''
  @Prop isFocused: boolean = true
  private controller: PaneSurface = new PaneSurface()
  private native: NativeTerminalController | null = null
  @State unavailable: boolean = false
  @State canRetryDisplay: boolean = false
  @State searchOpen: boolean = false
  @State query: string = ''
  @State resultIndex: number = 0
  @State resultCount: number = 0
  @State searchFocus: number = -1
  @State searchHover: number = -1
  @State searchError: string = ''
  @State preedit: string = ''
  @State preeditX: number = 0
  @State preeditY: number = 0
  @State preeditFontSize: number = 14
  @State linkPreview: string = ''
  private dragging: boolean = false
  private wheelRemainder: number = 0
  private composingSearch: boolean = false
  private searchInput: TextInputController = new TextInputController()
  onKey: (event: KeyEvent) => boolean = () => false
  onReady: () => void = () => {}
  onRebuildDisplay: () => void = () => {}

  aboutToAppear(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext
    let regular = context.resourceManager.getRawFileContentSync('JetBrainsMonoNerdFontMono-Regular.ttf')
    let bold = context.resourceManager.getRawFileContentSync('JetBrainsMonoNerdFontMono-Bold.ttf')
    this.native = this.surface.initializeNative(regular.buffer as ArrayBuffer, bold.buffer as ArrayBuffer)
    this.native.onDisplayState = (available: boolean) => {
      this.unavailable = !available
      this.canRetryDisplay = this.native?.canRetryDisplay() ?? false
    }
    this.native.onRebuildDisplay = () => { this.onRebuildDisplay() }
    this.native.onLinkHover = (url: string) => {
      if (this.linkPreview === url) { return }
      this.linkPreview = url
      if (url.length > 0) { this.getUIContext().getCursorController().setCursor(pointer.PointerStyle.HAND_POINTING) }
      else { this.getUIContext().getCursorController().restoreDefault() }
    }
    this.native.onGeometry = () => { this.updateScreenOrigin() }
    this.native.onPreedit = (text: string, x: number, y: number) => {
      this.preeditFontSize = this.native?.getFontSize() ?? 14
      this.preedit = text; this.preeditX = this.getUIContext().px2vp(x); this.preeditY = this.getUIContext().px2vp(y)
    }
    this.native.onSearchOpen = (open: boolean) => {
      if (open && this.searchOpen) {
        this.getUIContext().getFocusController().requestFocus('native-search-' + this.paneId)
        this.searchInput.setTextSelection(0, this.query.length)
      }
      this.searchOpen = open
      if (!open) {
        this.query = ''; this.resultIndex = 0; this.resultCount = 0; this.composingSearch = false
        this.searchFocus = -1; this.searchHover = -1; this.searchError = ''
        this.surface.setSearchComposing(false)
      }
    }
    this.native.onSearchResult = (index: number, count: number) => { this.resultIndex = index; this.resultCount = count }
    this.native.onSearchError = (resource: string) => { this.searchError = resource }
    this.native.onRequestFocus = () => {
      try {
        this.getUIContext().getFocusController().requestFocus('native-terminal-' + this.paneId)
        return true
      } catch (_) { return false }
    }
    this.controller.changed = (id: string, rect: SurfaceRect) => {
      this.native?.attach(id, rect.surfaceWidth, rect.surfaceHeight, this.getUIContext())
    }
    this.controller.destroyed = (id: string) => { this.native?.detach(id) }
    this.onReady()
  }

  private updateScreenOrigin(): void {
    let node = this.getUIContext().getFrameNodeById('native-terminal-' + this.paneId)
    if (node !== null) {
      let position = node.getPositionToScreen()
      this.native?.setScreenOrigin(this.getUIContext().vp2px(Number(position.x)), this.getUIContext().vp2px(Number(position.y)))
    }
  }
  private text(name: string): string {
    return UiText.get(this.getUIContext().getHostContext() as common.UIAbilityContext, name)
  }

  private handleDisplayRetryKey(event: KeyEvent): boolean {
    let ctrl = event.getModifierKeyState?.(['Ctrl']) ?? false
    let alt = event.getModifierKeyState?.(['Alt']) ?? false
    if (!ctrl && !alt) {
      if (event.keyCode === 2049) { return false }
      // Recovery is a UI action; consume both phases before IME/default activation.
      if (event.keyCode === 2054 || event.keyCode === 2050) {
        if (event.type === KeyType.Down) { this.native?.retryDisplay() }
        return true
      }
    }
    return this.onKey(event)
  }

  private handleNativeKey(event: KeyEvent, afterIme: boolean = false): boolean {
    let code = event.keyCode
    if (!afterIme && (code === 2072 || code === 2073 || (code >= 2045 && code <= 2048))) {
      let shift = event.getModifierKeyState?.(['Shift']) ?? false
      let ctrl = event.getModifierKeyState?.(['Ctrl']) ?? false
      let alt = event.getModifierKeyState?.(['Alt']) ?? false
      this.native?.hover((shift ? 1 : 0) | (ctrl ? 2 : 0) | (alt ? 4 : 0))
    }
    if (this.onKey(event)) { return true }
    if (event.type !== KeyType.Down) { return false }
    let ctrl = event.getModifierKeyState?.(['Ctrl']) ?? false
    let alt = event.getModifierKeyState?.(['Alt']) ?? false
    let shift = event.getModifierKeyState?.(['Shift']) ?? false
    if (code === 2072 || code === 2073 || (code >= 2045 && code <= 2048)) { return false }
    if (ctrl && !alt && code === 2038) { this.native?.paste(); return true }
    if (shift && !ctrl && !alt && (code === 2068 || code === 2069)) {
      this.native?.scrollPage(code === 2068 ? -1 : 1); return true
    }
    // ArkUI returns keys not consumed by IME through onKeyEvent. Some IME
    // modes commit letters but return digits/editing keys through this path.
    // Escape first belongs to IME candidate cancellation, then to the terminal.
    // Handling them before IME would duplicate text or steal candidate keys.
    if (afterIme) {
      let unicode = event.unicode ?? 0
      let text = unicode >= 32 && unicode !== 127 && unicode <= 0x10FFFF &&
        (unicode < 0xD800 || unicode > 0xDFFF) ? String.fromCodePoint(unicode) : KeyCodeMap.toPrintable(code, shift)
      if (text.length > 0 || code === 2054 || code === 2055 || code === 2070 || code === 2071 || code === 2083 ||
        (code >= 2012 && code <= 2015)) {
        return this.native?.key(code, (shift ? 1 : 0) | (ctrl ? 2 : 0) | (alt ? 4 : 0), text) ?? true
      }
    }
    // Ordinary text and editing keys are delivered by the system IME. Handle
    // only terminal shortcuts and keys outside that path before IME dispatch.
    if (ctrl || alt || code === 2049 || code === 2068 || code === 2069 ||
      code === 2081 || code === 2082 || (code >= 2090 && code <= 2101)) {
      return this.native?.key(code, (shift ? 1 : 0) | (ctrl ? 2 : 0) | (alt ? 4 : 0), KeyCodeMap.toPrintable(code, shift)) ?? true
    }
    return false
  }

  private handleSearchKey(event: KeyEvent, index: number): boolean {
    if (this.composingSearch) { return false }
    let shift = event.getModifierKeyState?.(['Shift']) ?? false
    let ctrl = event.getModifierKeyState?.(['Ctrl']) ?? false
    let alt = event.getModifierKeyState?.(['Alt']) ?? false
    if (index > 0 && !ctrl && !alt && !shift && (event.keyCode === 2054 || event.keyCode === 2050)) {
      if (event.type === KeyType.Down) {
        if (index === 3) { this.surface.closeSearch() }
        else if (this.resultCount > 0) { this.native?.search(this.query, index === 1 ? -1 : 1) }
      }
      return true
    }
    if (event.type !== KeyType.Down) { return false }
    if (event.keyCode === 2070 && !ctrl && !alt && !shift) { this.surface.closeSearch(); return true }
    if (event.keyCode === 2049 && !ctrl && !alt) {
      let next = (index + (shift ? 3 : 1)) % 4
      if (this.resultCount === 0) { next = index === 3 ? 0 : 3 }
      let names = ['native-search-', 'native-search-prev-', 'native-search-next-', 'native-search-close-']
      this.getUIContext().getFocusController().requestFocus(names[next] + this.paneId)
      return true
    }
    if (index === 0 && event.keyCode === 2054 && !ctrl && !alt) {
      this.native?.search(this.query, shift ? -1 : 1); return true
    }
    if (index === 0 && (event.keyCode === 2019 || event.keyCode === 2038)) { return false }
    return this.onKey(event)
  }

  @Builder
  private searchControl(index: number, glyph: string, name: string, tip: string) {
    Stack() {
      Button(glyph, { type: ButtonType.Normal })
        .id('native-search-' + name + '-' + this.paneId)
        .width(26).height(26).padding(0).borderRadius(2).fontSize(16)
        .fontColor(index === 3 || this.resultCount > 0 ? '#CDD6F4' : '#585B70')
        .backgroundColor((this.searchFocus === index || this.searchHover === index) &&
          (index === 3 || this.resultCount > 0) ? '#45475A' : Color.Transparent)
        .border({ width: 1, color: this.searchFocus === index ? '#89B4FA' : Color.Transparent })
        .enabled(index === 3 || this.resultCount > 0).opacity(1)
        .accessibilityText(this.text(index === 1 ? 'search_previous_match' : index === 2 ? 'search_next_match' : 'search_close'))
        .onFocus(() => { this.searchFocus = index })
        .onBlur(() => { if (this.searchFocus === index) { this.searchFocus = -1 } })
        .onKeyPreIme((event: KeyEvent) => this.handleSearchKey(event, index))
        .onClick(() => {
          if (index === 3) { this.surface.closeSearch() }
          else { this.native?.search(this.query, index === 1 ? -1 : 1) }
        })
      if (this.searchFocus === index) {
        Text(tip).fontSize(11).fontColor('#CDD6F4').backgroundColor('#1E1E2E')
          .width(index === 1 ? 84 : 44).maxLines(1)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .border({ width: 1, color: '#585B70', radius: 4 })
          .position({ top: 34, right: 0 }).hitTestBehavior(HitTestMode.None)
      }
    }
    .width(26).height(26)
    .onHover((inside: boolean) => { this.searchHover = inside ? index : -1 })
    // The wrapper keeps hover tips available even when navigation is disabled.
    .bindTips(tip, { appearingTime: 300, disappearingTime: 0 })
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      XComponent({ id: 'terminal-' + this.paneId, type: XComponentType.SURFACE, controller: this.controller })
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .id('native-terminal-' + this.paneId)
        .focusable(true)
        .defaultFocus(this.isFocused)
        .onFocus(() => { this.native?.focusedBySurface() })
        .onBlur(() => { this.native?.blur() })
        .onHover((inside: boolean) => { if (!inside) { this.native?.hover(-1) } })
        .onKeyPreIme((event: KeyEvent) => this.handleNativeKey(event))
        .onKeyEvent((event: KeyEvent) => this.handleNativeKey(event, true))
        .onAreaChange(() => { this.updateScreenOrigin() })
        .onMouse((event: MouseEvent) => {
          let action = event.action === MouseAction.Press ? 0 : event.action === MouseAction.Release ? 1 : 2
          if (action === 0 && event.button === MouseButton.Left) { this.dragging = true }
          if (event.button !== MouseButton.Left && event.button !== MouseButton.Right && !this.dragging && action !== 2) { return }
          let ctrl = event.getModifierKeyState?.(['Ctrl']) ?? false
          let shift = event.getModifierKeyState?.(['Shift']) ?? false
          let alt = event.getModifierKeyState?.(['Alt']) ?? false
          this.native?.pointer(action, event.button === MouseButton.Right ? 2 : event.button === MouseButton.Left || this.dragging ? 1 : 0, this.getUIContext().vp2px(event.x), this.getUIContext().vp2px(event.y),
            (shift ? 1 : 0) | (ctrl ? 2 : 0) | (alt ? 4 : 0))
          if (action === 1) { this.dragging = false }
          if (event.button === MouseButton.Right) { event.stopPropagation() }
        })
        .onAxisEvent((event: AxisEvent) => {
          this.wheelRemainder += event.getVerticalAxisValue()
          let lines = Math.trunc(this.wheelRemainder / 40)
          if (lines !== 0) { this.wheelRemainder -= lines * 40; this.native?.scroll(lines) }
        })
      if (this.searchOpen) {
        Row({ space: 2 }) {
          TextInput({ text: this.query, placeholder: this.text('search_placeholder'), controller: this.searchInput })
            .id('native-search-' + this.paneId)
            .layoutWeight(1).constraintSize({ minWidth: 0 }).height(24)
            .padding({ left: 7, right: 7, top: 0, bottom: 0 }).fontSize(12).fontColor('#CDD6F4')
            .placeholderColor('#A6ADC8').caretColor('#89B4FA').backgroundColor('#45475A')
            .border({ width: 1, color: this.searchFocus === 0 ? '#89B4FA' : Color.Transparent, radius: 3 })
            // Keep one overflow character so UTF-8 validation can show the error.
            .maxLength(1024 * 1024 + 1)
            .accessibilityText(this.text('search_find_text'))
            .onFocus(() => { this.searchFocus = 0 })
            .onBlur(() => { if (this.searchFocus === 0) { this.searchFocus = -1 } })
            .onAppear(() => { this.getUIContext().getFocusController().requestFocus('native-search-' + this.paneId) })
            .onChange((value: string, preview: PreviewText) => {
              this.composingSearch = preview.value.length > 0
              this.surface.setSearchComposing(this.composingSearch)
              if (!this.composingSearch) { this.query = value; this.native?.search(value) }
            })
            .onSubmit(() => { this.native?.search(this.query, 1) })
            .onKeyPreIme((event: KeyEvent) => this.handleSearchKey(event, 0))
          Text(this.resultIndex.toString() + '/' + this.resultCount.toString()).fontColor('#CDD6F4')
            .id('native-search-result-' + this.paneId)
            .width(48).fontSize(12).textAlign(TextAlign.Center).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .accessibilityText(this.resultCount > 0 ? this.resultIndex.toString() + '/' + this.resultCount.toString() :
              this.text(this.query.length > 0 ? 'search_no_results' : 'search_type_to_find'))
            .bindTips(this.resultCount > 0 ? this.resultIndex.toString() + '/' + this.resultCount.toString() :
              this.text(this.query.length > 0 ? 'search_no_results' : 'search_type_to_find'),
              { appearingTime: 300, disappearingTime: 0 })
          Row() {
            this.searchControl(1, '↑', 'prev', 'Shift+Enter')
            Divider().vertical(true).height(24).color('#585B70').strokeWidth(1)
            this.searchControl(2, '↓', 'next', 'Enter')
          }.border({ width: 1, color: '#585B70', radius: 3 }).height(26)
          Row() { this.searchControl(3, '×', 'close', 'Esc') }
            .border({ width: 1, color: '#585B70', radius: 3 }).height(26).margin({ left: 2 })
        }
        .id('native-search-panel-' + this.paneId)
        .width(344).constraintSize({ maxWidth: 'calc(100% - 64vp)' }).height(34).padding(4)
        .backgroundColor('#1E1E2E').border({ width: 1, color: '#585B70', radius: 5 })
        .shadow({ radius: 14, offsetY: 4, color: '#47000000' })
        .margin({ top: 8, right: 54 })
        .align(Alignment.TopEnd)
        if (this.searchError.length > 0) {
          Text(this.text(this.searchError)).id('native-search-error-' + this.paneId)
            .fontSize(12).fontColor('#F38BA8').backgroundColor('#1E1E2E')
            .padding(6).border({ width: 1, color: '#585B70', radius: 4 })
            .constraintSize({ maxWidth: 'calc(100% - 64vp)' })
            .position({ top: 48, right: 54 })
        }
      }
      if (this.preedit.length > 0) {
        Text(this.preedit).fontColor('#CDD6F4').backgroundColor('#1E1E2E')
          .fontSize(this.preeditFontSize)
          .decoration({ type: TextDecorationType.Underline })
          .position({ x: this.preeditX, y: this.preeditY }).hitTestBehavior(HitTestMode.None)
      }
      if (this.linkPreview.length > 0 && !this.searchOpen) {
        Text(this.linkPreview).id('native-link-preview-' + this.paneId)
          .fontSize(12).fontColor('#CDD6F4').backgroundColor('#181825')
          .padding(4).constraintSize({ maxWidth: '90%' }).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .position({ left: 12, bottom: 12 }).hitTestBehavior(HitTestMode.None)
      }
      if (this.unavailable) {
        Column({ space: 12 }) {
          Text(this.text('terminal_display_unavailable')).fontColor('#CDD6F4')
          if (this.canRetryDisplay) {
            Button(this.text('terminal_display_retry'))
              .id('native-display-retry-' + this.paneId)
              .onKeyPreIme((event: KeyEvent) => this.handleDisplayRetryKey(event))
              .onClick(() => { this.native?.retryDisplay() })
              .onAppear(() => {
                if (this.isFocused) {
                  this.getUIContext().getFocusController().requestFocus('native-display-retry-' + this.paneId)
                }
              })
          }
        }.backgroundColor('#181825').padding(16)
      }
    }
    .width('100%')
    .height('100%')
  }
}

import { TabInfo, SshSessionState } from '../../common/types/TerminalTypes'
import { ChromeColors } from '../theme/ThemeConstants'
import { accessibility } from '@kit.AccessibilityKit'
import { common } from '@kit.AbilityKit'
import { UiText } from '../../model/ui/UiText'

@Component
export struct ChromeBar {
  @Link tabs: TabInfo[]
  @Prop activeTabIndex: number = 0
  @Prop chromeColors: ChromeColors = new ChromeColors()
  @Prop chromeBackground: string = '#FF11111B'
  @Prop titleButtonReservedWidth: number = 140
  @Prop attentionPulsePaneId: string = ''
  @Prop attentionPulseToken: number = 0
  @Prop attentionPulseCount: number = 0
  onTabSelect: (index: number) => void = () => {}
  onTabClose: (index: number) => void = () => {}
  onNewTab: () => void = () => {}
  onMenuToggle: () => void = () => {}
  private tabScroller: Scroller = new Scroller()
  private lastScrolledTabId: string = ''

  onDidBuild(): void {
    if (this.activeTabIndex < 0 || this.activeTabIndex >= this.tabs.length) {
      return
    }
    let activeId: string = this.tabs[this.activeTabIndex].id
    if (activeId === this.lastScrolledTabId) {
      return
    }
    this.lastScrolledTabId = activeId
    setTimeout(() => {
      this.tabScroller.scrollTo({
        xOffset: Math.max(0, this.activeTabIndex * 176 - 176),
        yOffset: 0,
        animation: { duration: 160, curve: Curve.EaseOut }
      })
    }, 0)
  }

  private tabViewportWidth(): number {
    return 12 + this.tabs.length * 176
  }

  private tabRenderKey(tab: TabInfo): string {
    return tab.id
  }

  private tabContainsPane(tab: TabInfo, paneId: string): boolean {
    if (paneId.length === 0) {
      return false
    }
    for (let i = 0; i < tab.panes.length; i++) {
      if (tab.panes[i].id === paneId) {
        return true
      }
    }
    return false
  }

  build() {
    Row() {
      Scroll(this.tabScroller) {
        Row() {
          ForEach(this.tabs, (tab: TabInfo, index: number) => {
            ChromeTab({
              tab: tab,
              isActive: index === this.activeTabIndex,
              attentionPulseCount: this.tabContainsPane(tab, this.attentionPulsePaneId) ?
                this.attentionPulseCount : 0,
              attentionPulseToken: this.tabContainsPane(tab, this.attentionPulsePaneId) ?
                this.attentionPulseToken : 0,
              chromeColors: this.chromeColors,
              onSelect: () => { this.onTabSelect(index) },
              onClose: () => { this.onTabClose(index) }
            })
          }, (tab: TabInfo) => this.tabRenderKey(tab))
        }
        .padding({ left: 12 })
      }
      .align(Alignment.TopStart)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .fadingEdge(this.tabs.length > 1)
      .width(this.tabViewportWidth())
      .constraintSize({ maxWidth: 'calc(100% - 172vp)' })
      .height(40)

      Column()
        .width(1)
        .height(18)
        .backgroundColor(this.chromeColors.divider)
        .opacity(0.72)
        .margin({ left: 4, right: 4 })

      ChromeButton({
        symbol: '+',
        chromeColors: this.chromeColors,
        onTap: () => { this.onNewTab() }
      })

      Blank()
        .layoutWeight(1)
        .constraintSize({ minWidth: 96 })
        .height(40)

      MoreButton({
        chromeColors: this.chromeColors,
        onTap: () => { this.onMenuToggle() }
      })
        .margin({ right: 8 })
    }
    .width('100%')
    .height(40)
    .padding({ right: this.titleButtonReservedWidth })
    .backgroundColor(this.chromeBackground)
  }
}

@Component
struct ChromeTab {
  @ObjectLink tab: TabInfo
  @Prop isActive: boolean = false
  @Prop attentionPulseCount: number = 0
  @Prop @Watch('onAttentionPulseTokenChanged') attentionPulseToken: number = 0
  @Prop chromeColors: ChromeColors = new ChromeColors()
  @State hovered: boolean = false
  @State focused: boolean = false
  @State closeFocused: boolean = false
  @State attentionPulseOpacity: number = 0
  @State reduceMotion: boolean = false
  private attentionPulseTimers: number[] = []
  onSelect: () => void = () => {}
  onClose: () => void = () => {}

  aboutToAppear(): void {
    this.startAttentionPulse()
  }

  aboutToDisappear(): void {
    this.clearAttentionPulseTimers()
  }

  private onAttentionPulseTokenChanged(): void {
    this.startAttentionPulse()
  }

  private clearAttentionPulseTimers(): void {
    for (let i = 0; i < this.attentionPulseTimers.length; i++) {
      clearTimeout(this.attentionPulseTimers[i])
    }
    this.attentionPulseTimers = []
  }

  private scheduleAttentionPulse(opacity: number, delayMs: number): void {
    let timerId: number = setTimeout(() => {
      this.attentionPulseOpacity = opacity
    }, delayMs)
    this.attentionPulseTimers.push(timerId)
  }

  private startAttentionPulse(): void {
    this.clearAttentionPulseTimers()
    this.attentionPulseOpacity = 0
    if (this.attentionPulseCount <= 0) {
      return
    }
    try {
      this.reduceMotion = accessibility.isAnimationReduceEnabledSync()
    } catch (e) {
      this.reduceMotion = false
    }
    if (this.reduceMotion) {
      this.attentionPulseOpacity = 1
      this.scheduleAttentionPulse(0, 700)
      return
    }
    for (let pulseIndex = 0; pulseIndex < this.attentionPulseCount; pulseIndex++) {
      this.scheduleAttentionPulse(1, 40 + pulseIndex * 560)
      this.scheduleAttentionPulse(0, 320 + pulseIndex * 560)
    }
  }

  private indicatorColor(): string {
    if (this.hasAttention()) {
      return this.chromeColors.attention
    }
    let sessionState: SshSessionState = this.activeSessionState()
    if (sessionState === SshSessionState.CONNECTED) {
      return this.chromeColors.statusConnected
    }
    if (sessionState === SshSessionState.CONNECTING || sessionState === SshSessionState.RECONNECTING ||
      sessionState === SshSessionState.AUTHENTICATING || sessionState === SshSessionState.HOST_VERIFICATION_REQUIRED) {
      return this.chromeColors.statusConnecting
    }
    if (sessionState === SshSessionState.FAILED) {
      return this.chromeColors.statusDisconnected
    }
    return this.chromeColors.commandBarPlaceholder
  }

  private activeSessionState(): SshSessionState {
    for (let paneIndex: number = 0; paneIndex < this.tab.panes.length; paneIndex++) {
      if (this.tab.panes[paneIndex].id === this.tab.activePaneId) {
        return this.tab.panes[paneIndex].state
      }
    }
    return SshSessionState.IDLE
  }

  private hasAttention(): boolean {
    for (let paneIndex: number = 0; paneIndex < this.tab.panes.length; paneIndex++) {
      if (this.tab.panes[paneIndex].needsAttention) {
        return true
      }
    }
    return false
  }

  private text(name: string, ...args: Array<string | number>): string {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext
    return UiText.get(context, name, ...args)
  }

  private surfaceColor(): string {
    if (this.isActive) {
      return this.chromeColors.tabActiveBackground
    }
    if (this.hovered) {
      return this.chromeColors.tabHoverBackground
    }
    return this.chromeColors.tabBackground
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width(172)
        .height(36)
        .margin({ top: 4 })
        .backgroundColor(this.surfaceColor())
        .borderRadius({
          topLeft: 8,
          topRight: 8,
          bottomLeft: 0,
          bottomRight: 0
        })
        .animation({ duration: 100, curve: Curve.EaseOut })

      if (this.attentionPulseCount > 0) {
        Row()
          .width(172)
          .height(36)
          .backgroundColor(this.chromeColors.attention)
          .borderRadius({
            topLeft: 8,
            topRight: 8,
            bottomLeft: 0,
            bottomRight: 0
          })
          .position({ x: 0, y: 4 })
          .opacity(this.attentionPulseOpacity * 0.18)
          .animation({ duration: this.reduceMotion ? 0 : 240, curve: Curve.EaseInOut })
          .hitTestBehavior(HitTestMode.None)
      }

      Row() {
        Circle()
          .width(6)
          .height(6)
          .fill(this.indicatorColor())
          .opacity(this.isActive ? 1 : 0.55)
          .margin({ right: 6 })
        Text(this.tab.title)
          .fontSize(13)
          .fontColor(this.isActive ? this.chromeColors.commandBarText : this.chromeColors.statusText)
          .fontWeight(this.isActive ? FontWeight.Medium : FontWeight.Regular)
          .opacity(this.isActive || this.hovered ? 1 : 0.72)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.isActive || this.hovered) {
          Text('\u2715')
            .fontSize(10)
            .fontColor(this.hovered ? this.chromeColors.statusText : this.chromeColors.commandBarPlaceholder)
            .width(24)
            .height(24)
            .textAlign(TextAlign.Center)
            .borderRadius(8)
            .border({ width: this.closeFocused ? 1 : 0, color: this.chromeColors.focusRing })
            .focusable(true)
            .accessibilityText(this.text('a11y_close_tab', this.tab.title))
            .onClick(() => { this.onClose() })
            .onFocus(() => { this.closeFocused = true })
            .onBlur(() => { this.closeFocused = false })
        }
      }
      .width(172)
      .height(32)
      .position({ x: 0, y: 4 })
      .padding({ left: 12, right: 8 })

      Row()
        .width(172)
        .height(36)
        .position({ x: 0, y: 4 })
        .border({ width: this.focused ? 1 : 0, color: this.chromeColors.focusRing, radius: 8 })
        .hitTestBehavior(HitTestMode.None)
    }
    .width(176)
    .height(40)
    .accessibilityDescription(this.tab.title)
    .accessibilityText(this.text(this.isActive ? 'a11y_active_tab' : 'a11y_tab', this.tab.title) +
      (this.hasAttention() ? this.text('a11y_attention_suffix') : ''))
    .focusable(true)
    .onFocus(() => { this.focused = true })
    .onBlur(() => { this.focused = false })
    .onClick(() => { this.onSelect() })
    .onHover((isHover: boolean) => { this.hovered = isHover })
  }
}

@Component
struct ChromeButton {
  @Prop symbol: string = ''
  @Prop chromeColors: ChromeColors = new ChromeColors()
  @State hovered: boolean = false
  @State focused: boolean = false
  onTap: () => void = () => {}

  private text(name: string): string {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext
    return UiText.get(context, name)
  }

  build() {
    Text(this.symbol)
      .fontSize(13)
      .fontColor(this.chromeColors.statusText)
      .opacity(this.hovered || this.focused ? 1 : 0.72)
      .width(32)
      .height(32)
      .textAlign(TextAlign.Center)
      .borderRadius(6)
      .backgroundColor(this.hovered ? this.chromeColors.commandBarBorder : '#00000000')
      .border({ width: this.focused ? 1 : 0, color: this.chromeColors.focusRing, radius: 6 })
      .focusable(true)
      .accessibilityText(this.text('a11y_new_tab'))
      .onClick(() => { this.onTap() })
      .onHover((isHover: boolean) => { this.hovered = isHover })
      .onFocus(() => { this.focused = true })
      .onBlur(() => { this.focused = false })
  }
}

@Component
struct MoreButton {
  @Prop chromeColors: ChromeColors = new ChromeColors()
  @State hovered: boolean = false
  @State focused: boolean = false
  onTap: () => void = () => {}

  private text(name: string): string {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext
    return UiText.get(context, name)
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Circle()
            .width(3)
            .height(3)
            .fill(this.chromeColors.statusText)
            .margin({ right: 4 })
          Circle()
            .width(3)
            .height(3)
            .fill(this.chromeColors.statusText)
        }
        .margin({ bottom: 4 })
        Row() {
          Circle()
            .width(3)
            .height(3)
            .fill(this.chromeColors.statusText)
            .margin({ right: 4 })
          Circle()
            .width(3)
            .height(3)
            .fill(this.chromeColors.statusText)
        }
      }
    }
    .width(32)
    .height(32)
    .opacity(this.hovered || this.focused ? 1 : 0.72)
    .borderRadius(6)
    .backgroundColor(this.hovered ? this.chromeColors.commandBarBorder : '#00000000')
    .border({ width: this.focused ? 1 : 0, color: this.chromeColors.focusRing, radius: 6 })
    .focusable(true)
    .accessibilityText(this.text('a11y_open_menu'))
    .onClick(() => { this.onTap() })
    .onHover((isHover: boolean) => { this.hovered = isHover })
    .onFocus(() => { this.focused = true })
    .onBlur(() => { this.focused = false })
  }
}

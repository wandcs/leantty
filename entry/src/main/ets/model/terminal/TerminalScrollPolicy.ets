// Per-Pane input policy. Axis values are vp; the caller converts BaseEvent's
// nanosecond timestamp to milliseconds. No timers or deferred scroll commands.
export class TerminalScrollPolicy {
  private remainder: number = 0
  private lastTime: number = -1
  private velocity: number = 0
  private touchpad: boolean = false

  reset(): void {
    this.remainder = 0; this.lastTime = -1; this.velocity = 0
  }

  consume(delta: number, time: number, touchpad: boolean): number {
    if (!Number.isFinite(delta) || !Number.isFinite(time)) { this.reset(); return 0 }
    if (delta === 0) { return 0 }
    let gap = time - this.lastTime
    if (touchpad !== this.touchpad || gap > 120 || gap < 0 || this.velocity * delta < 0) { this.reset() }
    this.touchpad = touchpad
    let elapsed = this.lastTime < 0 ? 16 : Math.max(1, time - this.lastTime)
    let speed = delta / elapsed
    let blend = elapsed / (40 + elapsed)
    this.velocity = this.lastTime < 0 ? speed : this.velocity + blend * (speed - this.velocity)
    this.lastTime = time
    // Preserve the existing 40-vp base step. Only touchpad motion gains up to
    // four times that rate; slow movement stays precise and wheel ticks stable.
    let gain = touchpad ? 1 + 3 * Math.max(0, Math.min(1, (Math.abs(this.velocity) - 0.25) / 1.75)) : 1
    this.remainder += delta * gain
    let whole = Math.trunc(this.remainder / 40)
    this.remainder -= whole * 40
    return Math.max(-256, Math.min(256, whole))
  }
}

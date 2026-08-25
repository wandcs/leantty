export class WindowGridSnapPolicy {
  private static readonly TERMINAL_INSET_VP: number = 8
  private static readonly WINDOW_CHROME_HEIGHT_VP: number = 40
  private static readonly REFERENCE_FONT_SIZE: number = 14
  private static readonly REFERENCE_CELL_WIDTH_VP: number = 9
  private static readonly REFERENCE_CELL_HEIGHT_VP: number = 20

  static snapWidth(widthPx: number, fontSize: number, density: number): number {
    return WindowGridSnapPolicy.snapExtent(
      widthPx,
      WindowGridSnapPolicy.TERMINAL_INSET_VP * 2,
      WindowGridSnapPolicy.cellWidth(fontSize),
      density,
      2)
  }

  static snapHeight(heightPx: number, fontSize: number, density: number): number {
    return WindowGridSnapPolicy.snapExtent(
      heightPx,
      WindowGridSnapPolicy.WINDOW_CHROME_HEIGHT_VP + WindowGridSnapPolicy.TERMINAL_INSET_VP * 2,
      WindowGridSnapPolicy.cellHeight(fontSize),
      density,
      1)
  }

  static clampExtent(extentPx: number, minimumPx?: number, maximumPx?: number): number {
    let result: number = extentPx
    if (minimumPx !== undefined && minimumPx > 0) {
      result = Math.max(result, minimumPx)
    }
    if (maximumPx !== undefined && maximumPx > 0) {
      result = Math.min(result, maximumPx)
    }
    return result
  }

  private static cellWidth(fontSize: number): number {
    return WindowGridSnapPolicy.REFERENCE_CELL_WIDTH_VP *
      fontSize / WindowGridSnapPolicy.REFERENCE_FONT_SIZE
  }

  private static cellHeight(fontSize: number): number {
    return WindowGridSnapPolicy.REFERENCE_CELL_HEIGHT_VP *
      fontSize / WindowGridSnapPolicy.REFERENCE_FONT_SIZE
  }

  private static snapExtent(currentPx: number, fixedVp: number, cellVp: number,
    density: number, minimumCells: number): number {
    if (!Number.isFinite(currentPx) || !Number.isFinite(cellVp) || !Number.isFinite(density) ||
      currentPx <= 0 || cellVp <= 0 || density <= 0) {
      return currentPx
    }
    let currentVp: number = currentPx / density
    let cells: number = Math.max(minimumCells, Math.round((currentVp - fixedVp) / cellVp))
    return Math.round((fixedVp + cells * cellVp) * density)
  }
}

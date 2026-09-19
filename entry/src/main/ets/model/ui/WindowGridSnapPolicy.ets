export class WindowGridSnapPolicy {



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

  // Native font metrics have already been rounded by the renderer. Keep all
  // arithmetic in physical pixels, including the independently rounded inset.
  static snapNativeExtent(currentPx: number, fixedPx: number, cellPx: number, minimumCells: number): number {
    if (!Number.isFinite(currentPx) || !Number.isInteger(fixedPx) || !Number.isInteger(cellPx) ||
      currentPx <= 0 || fixedPx < 0 || cellPx <= 0) { return currentPx }
    return fixedPx + Math.max(minimumCells, Math.round((currentPx - fixedPx) / cellPx)) * cellPx
  }



}

import { TerminalTextPolicy } from '../../common/security/TerminalTextPolicy'

export enum LocalCompletionNavigation {
  UP = 0,
  DOWN = 1,
  LEFT = 2,
  RIGHT = 3
}

export class LocalCompletionLayout {
  lines: string[] = []
  renderedLines: string[] = []
  rowCount: number = 0
  columnCount: number = 0
  pageStart: number = 0
  pageEnd: number = 0
}

export class LocalCompletionRenderer {
  private hasRegion: boolean = false
  private previousCommandWidth: number = 0
  private previousCursorWidth: number = 0
  private previousCandidateWidths: number[] = []
  private lastLayout: LocalCompletionLayout = new LocalCompletionLayout()

  render(prompt: string, text: string, cursor: number, displayValues: string[], selectedIndex: number,
    truncated: boolean, terminalColumns: number, terminalRows: number): string {
    let columns: number = Math.max(10, terminalColumns)
    let safeText: string = TerminalTextPolicy.escape(text)
    let safePrefix: string = TerminalTextPolicy.escape(text.substring(0, cursor))
    let promptWidth: number = LocalCompletionRenderer.visibleCellWidth(prompt)
    let commandWidth: number = promptWidth + LocalCompletionRenderer.terminalCellWidth(safeText)
    let cursorWidth: number = promptWidth + LocalCompletionRenderer.terminalCellWidth(safePrefix)
    let layout: LocalCompletionLayout = LocalCompletionRenderer.layout(
      displayValues, selectedIndex, truncated, columns, terminalRows)

    let output: string = this.clearPreviousRegion(columns)
    output += prompt + safeText
    for (let index: number = 0; index < layout.renderedLines.length; index++) {
      output += '\r\n' + layout.renderedLines[index]
    }

    let commandEndRow: number = LocalCompletionRenderer.physicalRows(commandWidth, columns) - 1
    let cursorRow: number = LocalCompletionRenderer.cursorRow(cursorWidth, columns)
    let rowsUp: number = commandEndRow + layout.renderedLines.length - cursorRow
    if (rowsUp > 0) { output += '\u001b[' + rowsUp.toString() + 'A' }
    output += '\r'
    let cursorColumn: number = LocalCompletionRenderer.cursorColumn(cursorWidth, columns)
    if (cursorColumn > 0) { output += '\u001b[' + cursorColumn.toString() + 'C' }

    this.hasRegion = true
    this.previousCommandWidth = commandWidth
    this.previousCursorWidth = cursorWidth
    this.previousCandidateWidths = []
    for (let index: number = 0; index < layout.lines.length; index++) {
      this.previousCandidateWidths.push(LocalCompletionRenderer.terminalCellWidth(layout.lines[index]))
    }
    this.lastLayout = layout
    return output
  }

  reset(): void {
    this.hasRegion = false
    this.previousCommandWidth = 0
    this.previousCursorWidth = 0
    this.previousCandidateWidths = []
    this.lastLayout = new LocalCompletionLayout()
  }

  getLastLayout(): LocalCompletionLayout {
    return this.lastLayout
  }

  private clearPreviousRegion(columns: number): string {
    if (!this.hasRegion) { return '\r\u001b[2K' }
    let cursorRow: number = LocalCompletionRenderer.cursorRow(this.previousCursorWidth, columns)
    let physicalRows: number = LocalCompletionRenderer.physicalRows(this.previousCommandWidth, columns)
    for (let index: number = 0; index < this.previousCandidateWidths.length; index++) {
      physicalRows += LocalCompletionRenderer.physicalRows(this.previousCandidateWidths[index], columns)
    }
    let output: string = '\r'
    if (cursorRow > 0) { output += '\u001b[' + cursorRow.toString() + 'A' }
    for (let row: number = 0; row < physicalRows; row++) {
      output += '\u001b[2K'
      if (row + 1 < physicalRows) { output += '\u001b[1B\r' }
    }
    if (physicalRows > 1) { output += '\u001b[' + (physicalRows - 1).toString() + 'A' }
    return output + '\r'
  }

  static layout(values: string[], selectedIndex: number, truncated: boolean,
    terminalColumns: number, terminalRows: number): LocalCompletionLayout {
    let result: LocalCompletionLayout = new LocalCompletionLayout()
    if (values.length === 0) { return result }

    let safeValues: string[] = []
    let widths: number[] = []
    let widest: number = 1
    let columns: number = Math.max(10, terminalColumns)
    let contentColumns: number = Math.max(8, columns - 1)
    for (let index: number = 0; index < values.length; index++) {
      let safe: string = LocalCompletionRenderer.truncateCellText(
        TerminalTextPolicy.escape(values[index]), contentColumns)
      let width: number = LocalCompletionRenderer.terminalCellWidth(safe)
      safeValues.push(safe)
      widths.push(width)
      widest = Math.max(widest, width)
    }

    let maximumRows: number = Math.max(1, Math.min(8, Math.floor((terminalRows - 1) / 2)))
    let maximumColumns: number = Math.max(1, Math.min(6, Math.floor((columns + 2) / (widest + 2))))
    let columnCount: number = 1
    let rowCount: number = values.length
    let showsAll: boolean = false
    for (let candidateColumns: number = Math.min(maximumColumns, values.length);
      candidateColumns >= 1; candidateColumns--) {
      let candidateRows: number = Math.ceil(values.length / candidateColumns)
      if (candidateRows <= maximumRows &&
        LocalCompletionRenderer.gridWidth(widths, 0, values.length, candidateRows, candidateColumns) <= columns) {
        columnCount = candidateColumns
        rowCount = candidateRows
        showsAll = true
        break
      }
    }

    let statusRequired: boolean = truncated || !showsAll
    if (!showsAll) {
      let dataRows: number = Math.max(1, maximumRows - (maximumRows > 1 ? 1 : 0))
      columnCount = maximumColumns
      rowCount = dataRows
    }
    let capacity: number = Math.max(1, rowCount * columnCount)
    let pageAnchor: number = selectedIndex >= 0 ? selectedIndex : 0
    let pageStart: number = showsAll ? 0 : Math.floor(pageAnchor / capacity) * capacity
    let pageEnd: number = Math.min(values.length, pageStart + capacity)
    let pageColumnCount: number = Math.max(1, Math.ceil((pageEnd - pageStart) / rowCount))
    let columnWidths: number[] = []
    for (let column: number = 0; column < pageColumnCount; column++) {
      let columnWidth: number = 0
      for (let row: number = 0; row < rowCount; row++) {
        let itemIndex: number = pageStart + column * rowCount + row
        if (itemIndex >= pageEnd) { break }
        columnWidth = Math.max(columnWidth, widths[itemIndex])
      }
      columnWidths.push(columnWidth)
    }

    for (let row: number = 0; row < rowCount; row++) {
      let plainLine: string = ''
      let renderedLine: string = ''
      for (let column: number = 0; column < pageColumnCount; column++) {
        let itemIndex: number = pageStart + column * rowCount + row
        if (itemIndex >= pageEnd) { continue }
        let value: string = safeValues[itemIndex]
        plainLine += value
        renderedLine += itemIndex === selectedIndex ? '\u001b[7m' + value + '\u001b[0m' : value
        if (column + 1 < pageColumnCount && pageStart + (column + 1) * rowCount + row < pageEnd) {
          let padding: string = ' '.repeat(Math.max(2, columnWidths[column] - widths[itemIndex] + 2))
          plainLine += padding
          renderedLine += padding
        }
      }
      if (plainLine.length > 0) {
        result.lines.push(plainLine)
        result.renderedLines.push(renderedLine)
      }
    }
    if (statusRequired && maximumRows > 1) {
      let suffix: string = truncated ? '+' : ''
      let status: string = '... ' + (pageStart + 1).toString() + '-' + pageEnd.toString() +
        ' / ' + values.length.toString() + suffix
      if (LocalCompletionRenderer.terminalCellWidth(status) > contentColumns) {
        status = '... ' + (pageStart + 1).toString() + '/' + values.length.toString() + suffix
      }
      status = LocalCompletionRenderer.truncateCellText(status, contentColumns)
      result.lines.push(status)
      result.renderedLines.push('\u001b[2m' + status + '\u001b[0m')
    }
    result.rowCount = rowCount
    result.columnCount = pageColumnCount
    result.pageStart = pageStart
    result.pageEnd = pageEnd
    return result
  }

  static moveSelection(currentIndex: number, direction: LocalCompletionNavigation,
    totalCount: number, layout: LocalCompletionLayout): number {
    if (totalCount <= 0) { return -1 }
    if (currentIndex < 0 || currentIndex >= totalCount) {
      return direction === LocalCompletionNavigation.UP || direction === LocalCompletionNavigation.LEFT ?
        totalCount - 1 : 0
    }
    let rowCount: number = Math.max(1, layout.rowCount)
    let pageStart: number = layout.pageStart
    let pageEnd: number = Math.max(pageStart + 1, layout.pageEnd)
    let localIndex: number = currentIndex - pageStart
    let column: number = Math.floor(localIndex / rowCount)
    let row: number = localIndex % rowCount
    if (direction === LocalCompletionNavigation.UP) {
      let first: number = pageStart + column * rowCount
      let last: number = Math.min(pageEnd, first + rowCount) - 1
      return currentIndex > first ? currentIndex - 1 : last
    }
    if (direction === LocalCompletionNavigation.DOWN) {
      let first: number = pageStart + column * rowCount
      let last: number = Math.min(pageEnd, first + rowCount) - 1
      return currentIndex < last ? currentIndex + 1 : first
    }
    let columnCount: number = Math.max(1, layout.columnCount)
    let targetColumn: number = direction === LocalCompletionNavigation.LEFT ? column - 1 : column + 1
    if (targetColumn < 0) { targetColumn = columnCount - 1 }
    if (targetColumn >= columnCount) { targetColumn = 0 }
    let target: number = pageStart + targetColumn * rowCount + row
    let targetLast: number = Math.min(pageEnd, pageStart + (targetColumn + 1) * rowCount) - 1
    return Math.min(target, targetLast)
  }

  static formatPlain(values: string[], terminalColumns: number): string {
    return LocalCompletionRenderer.layout(values, -1, false, terminalColumns, 1024).lines.join('\r\n')
  }

  static terminalCellWidth(value: string): number {
    let width: number = 0
    for (let index: number = 0; index < value.length; index++) {
      let code: number = value.charCodeAt(index)
      if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length) {
        let low: number = value.charCodeAt(index + 1)
        if (low >= 0xDC00 && low <= 0xDFFF) {
          width += 2
          index++
          continue
        }
      }
      if ((code >= 0x0300 && code <= 0x036F) || (code >= 0xFE00 && code <= 0xFE0F)) { continue }
      width += LocalCompletionRenderer.isWideTerminalCodeUnit(code) ? 2 : 1
    }
    return width
  }

  private static visibleCellWidth(value: string): number {
    let plain: string = ''
    for (let index: number = 0; index < value.length; index++) {
      if (value.charCodeAt(index) === 0x1B && index + 1 < value.length && value[index + 1] === '[') {
        index += 2
        while (index < value.length) {
          let code: number = value.charCodeAt(index)
          if (code >= 0x40 && code <= 0x7E) { break }
          index++
        }
      } else {
        plain += value[index]
      }
    }
    return LocalCompletionRenderer.terminalCellWidth(plain)
  }

  private static gridWidth(widths: number[], start: number, end: number,
    rowCount: number, columnCount: number): number {
    let total: number = 0
    for (let column: number = 0; column < columnCount; column++) {
      let widest: number = 0
      for (let row: number = 0; row < rowCount; row++) {
        let index: number = start + column * rowCount + row
        if (index >= end) { break }
        widest = Math.max(widest, widths[index])
      }
      total += widest
      if (column + 1 < columnCount) { total += 2 }
    }
    return total
  }

  private static truncateCellText(value: string, maximumWidth: number): string {
    if (LocalCompletionRenderer.terminalCellWidth(value) <= maximumWidth) { return value }
    let directory: boolean = value.endsWith('/')
    let suffix: string = directory ? '.../' : '...'
    let available: number = Math.max(1, maximumWidth - suffix.length)
    let result: string = ''
    let used: number = 0
    for (let index: number = 0; index < value.length; index++) {
      let character: string = value[index]
      let code: number = value.charCodeAt(index)
      if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length) {
        let low: number = value.charCodeAt(index + 1)
        if (low >= 0xDC00 && low <= 0xDFFF) {
          character += value[index + 1]
          index++
        }
      }
      let width: number = LocalCompletionRenderer.terminalCellWidth(character)
      if (used + width > available) { break }
      result += character
      used += width
    }
    return result + suffix
  }

  private static physicalRows(width: number, columns: number): number {
    return Math.max(1, Math.ceil(Math.max(1, width) / columns))
  }

  private static cursorRow(width: number, columns: number): number {
    if (width <= 0) { return 0 }
    return Math.floor((width - 1) / columns)
  }

  private static cursorColumn(width: number, columns: number): number {
    if (width <= 0) { return 0 }
    let remainder: number = width % columns
    return remainder === 0 ? columns - 1 : remainder
  }

  private static isWideTerminalCodeUnit(code: number): boolean {
    return code >= 0x1100 && (code <= 0x115F || code === 0x2329 || code === 0x232A ||
      (code >= 0x2E80 && code <= 0xA4CF && code !== 0x303F) ||
      (code >= 0xAC00 && code <= 0xD7A3) || (code >= 0xF900 && code <= 0xFAFF) ||
      (code >= 0xFE10 && code <= 0xFE19) || (code >= 0xFE30 && code <= 0xFE6F) ||
      (code >= 0xFF00 && code <= 0xFF60) || (code >= 0xFFE0 && code <= 0xFFE6))
  }
}

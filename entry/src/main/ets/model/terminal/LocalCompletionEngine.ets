export class LocalCompletionSet {
  replacements: string[] = []
  displayValues: string[] = []
  truncated: boolean = false
}

export enum LocalCompletionUpdateKind {
  NONE = 0,
  COMPLETED = 1,
  LISTED = 2,
  PREVIEWED = 3,
  ACCEPTED = 4,
  CANCELLED = 5
}

export class LocalCompletionUpdate {
  kind: LocalCompletionUpdateKind
  text: string
  displayValues: string[]
  truncated: boolean
  selectedIndex: number

  constructor(kind: LocalCompletionUpdateKind, text: string,
    displayValues: string[] = [], truncated: boolean = false, selectedIndex: number = -1) {
    this.kind = kind
    this.text = text
    this.displayValues = displayValues
    this.truncated = truncated
    this.selectedIndex = selectedIndex
  }
}

enum LocalCompletionPhase {
  NONE = 0,
  LISTED = 1,
  MENU = 2
}

export class LocalCompletionEngine {
  private phase: LocalCompletionPhase = LocalCompletionPhase.NONE
  private baseInput: string = ''
  private candidates: string[] = []
  private displayValues: string[] = []
  private truncated: boolean = false
  private selectedIndex: number = -1

  complete(input: string, set: LocalCompletionSet, direction: number = 1): LocalCompletionUpdate {
    if (set.replacements.length === 0) {
      this.reset()
      return new LocalCompletionUpdate(LocalCompletionUpdateKind.NONE, input)
    }
    if (set.replacements.length === 1) {
      let completed: string = LocalCompletionEngine.acceptedText(set.replacements[0])
      this.reset()
      return new LocalCompletionUpdate(LocalCompletionUpdateKind.COMPLETED, completed)
    }
    if (this.phase === LocalCompletionPhase.LISTED && this.baseInput === input &&
      LocalCompletionEngine.sameCandidates(this.candidates, set.replacements)) {
      this.phase = LocalCompletionPhase.MENU
      this.selectedIndex = direction < 0 ? this.candidates.length - 1 : 0
      return this.snapshot(LocalCompletionUpdateKind.PREVIEWED, this.candidates[this.selectedIndex])
    }
    return this.storeListed(input, set)
  }

  refresh(input: string, set: LocalCompletionSet): LocalCompletionUpdate {
    if (set.replacements.length === 0) {
      this.reset()
      return new LocalCompletionUpdate(LocalCompletionUpdateKind.NONE, input)
    }
    return this.storeListed(input, set)
  }

  isMenuActive(): boolean {
    return this.phase === LocalCompletionPhase.MENU && this.selectedIndex >= 0 &&
      this.selectedIndex < this.candidates.length
  }

  isActive(): boolean {
    return this.phase !== LocalCompletionPhase.NONE
  }

  cycle(direction: number): LocalCompletionUpdate {
    if (!this.isMenuActive()) {
      return new LocalCompletionUpdate(LocalCompletionUpdateKind.NONE, this.baseInput)
    }
    let count: number = this.candidates.length
    this.selectedIndex = (this.selectedIndex + (direction < 0 ? -1 : 1) + count) % count
    return this.snapshot(LocalCompletionUpdateKind.PREVIEWED, this.candidates[this.selectedIndex])
  }

  select(index: number): LocalCompletionUpdate {
    if (!this.isMenuActive() || index < 0 || index >= this.candidates.length) {
      return this.snapshot(LocalCompletionUpdateKind.NONE, this.baseInput)
    }
    this.selectedIndex = index
    return this.snapshot(LocalCompletionUpdateKind.PREVIEWED, this.candidates[this.selectedIndex])
  }

  accept(): LocalCompletionUpdate {
    if (!this.isMenuActive()) {
      return new LocalCompletionUpdate(LocalCompletionUpdateKind.NONE, this.baseInput)
    }
    let accepted: string = LocalCompletionEngine.acceptedText(this.candidates[this.selectedIndex])
    this.reset()
    return new LocalCompletionUpdate(LocalCompletionUpdateKind.ACCEPTED, accepted)
  }

  cancel(): LocalCompletionUpdate {
    let restored: string = this.baseInput
    this.reset()
    return new LocalCompletionUpdate(LocalCompletionUpdateKind.CANCELLED, restored)
  }

  editingText(): string {
    let restored: string = this.baseInput
    this.reset()
    return restored
  }

  selectedCandidate(): string {
    if (!this.isMenuActive()) { return '' }
    return this.candidates[this.selectedIndex]
  }

  current(): LocalCompletionUpdate {
    if (this.phase === LocalCompletionPhase.MENU && this.isMenuActive()) {
      return this.snapshot(LocalCompletionUpdateKind.PREVIEWED, this.candidates[this.selectedIndex])
    }
    if (this.phase === LocalCompletionPhase.LISTED) {
      return this.snapshot(LocalCompletionUpdateKind.LISTED, this.baseInput)
    }
    return new LocalCompletionUpdate(LocalCompletionUpdateKind.NONE, '')
  }

  finishEditing(): void {
    this.reset()
  }

  private reset(): void {
    this.phase = LocalCompletionPhase.NONE
    this.baseInput = ''
    this.candidates = []
    this.displayValues = []
    this.truncated = false
    this.selectedIndex = -1
  }

  private storeListed(input: string, set: LocalCompletionSet): LocalCompletionUpdate {
    this.phase = LocalCompletionPhase.LISTED
    this.baseInput = input
    this.candidates = set.replacements.slice()
    this.displayValues = set.displayValues.slice()
    this.truncated = set.truncated
    this.selectedIndex = -1
    return this.snapshot(LocalCompletionUpdateKind.LISTED, input)
  }

  private snapshot(kind: LocalCompletionUpdateKind, text: string): LocalCompletionUpdate {
    return new LocalCompletionUpdate(
      kind, text, this.displayValues.slice(), this.truncated, this.selectedIndex)
  }

  private static acceptedText(candidate: string): string {
    return candidate.endsWith('/') || candidate.endsWith(':') ? candidate : candidate + ' '
  }

  private static sameCandidates(left: string[], right: string[]): boolean {
    if (left.length !== right.length) { return false }
    for (let index: number = 0; index < left.length; index++) {
      if (left[index] !== right[index]) { return false }
    }
    return true
  }
}

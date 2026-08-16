import { SshConfig } from '../model/ssh/SshConfig'
import { common } from '@kit.AbilityKit'
import { Environment, fileIo as fs } from '@kit.CoreFileKit'
import { CommandParser, CommandParseResult, KeyCommandResult, KeyCommandKind } from '../model/command/CommandParser'
import { SshKeyManager } from '../model/ssh/SshKeyManager'
import { KeyPairInfo } from '../common/types/SshKeyTypes'
import { TerminalTextPolicy } from '../common/security/TerminalTextPolicy'
import { LocalCompletionSet } from '../model/terminal/LocalCompletionEngine'

export { CommandParseResult, KeyCommandResult, KeyCommandKind } from '../model/command/CommandParser'

class CompletionToken {
  value: string = ''
  start: number = 0
}

export class CommandBarViewModel {
  private inputText: string = ''
  private history: string[] = []
  private historyIndex: number = -1
  private sshConfig: SshConfig = new SshConfig()
  private context: common.Context | null = null
  private static readonly MAX_HISTORY: number = 100
  private static readonly MAX_COMPLETIONS: number = 100

  setInputText(text: string): void { this.inputText = text }

  loadSshConfig(context: common.Context): void {
    this.context = context
    this.sshConfig.load(context)
  }

  getSshConfig(): SshConfig { return this.sshConfig }

  tryTabComplete(): string[] {
    return this.completionSet().replacements
  }

  completionSet(): LocalCompletionSet {
    let transferMatches: string[] | null = this.transferCompletions()
    if (transferMatches !== null) { return this.finishCompletions(transferMatches) }
    let trimmed: string = this.inputText.trim()
    let hostPrefix: string = ''
    if (this.inputText.startsWith('ssh -G ')) { hostPrefix = 'ssh -G ' }
    else if (this.inputText.startsWith('ssh ')) { hostPrefix = 'ssh ' }
    else if (this.inputText.startsWith('host set ')) { hostPrefix = 'host set ' }
    else if (this.inputText.startsWith('host rm ')) { hostPrefix = 'host rm ' }
    if (hostPrefix.length > 0) {
      let partial: string = this.inputText.substring(hostPrefix.length).trim()
      let aliases: string[] = this.sshConfig.getHostAliases()
      let hostMatches: string[] = []
      for (let i = 0; i < aliases.length; i++) {
        if (CommandBarViewModel.safeCompletionValue(aliases[i]) && aliases[i].startsWith(partial)) {
          hostMatches.push(hostPrefix + aliases[i])
        }
      }
      return this.finishCompletions(hostMatches)
    }
    let commands: string[] = ['help', 'ssh', 'put', 'get', 'ssh-keygen', 'ssh-copy-id', 'key list', 'key import',
      'key export', 'key rm', 'host list', 'host add', 'host set', 'host rm', 'exit']
    let matches: string[] = []
    for (let i = 0; i < commands.length; i++) {
      if (commands[i].startsWith(trimmed)) { matches.push(commands[i]) }
    }
    return this.finishCompletions(matches)
  }

  private finishCompletions(matches: string[]): LocalCompletionSet {
    let set: LocalCompletionSet = new LocalCompletionSet()
    matches.sort()
    if (matches.length > CommandBarViewModel.MAX_COMPLETIONS) {
      matches = matches.slice(0, CommandBarViewModel.MAX_COMPLETIONS)
      set.truncated = true
    }
    set.replacements = matches
    let tokens: CompletionToken[] = CommandBarViewModel.tokenizeForCompletion(this.inputText)
    let displayStart: number = 0
    if (tokens.length > 0) {
      displayStart = tokens[tokens.length - 1].start
    }
    for (let index: number = 0; index < matches.length; index++) {
      set.displayValues.push(CommandBarViewModel.completionDisplayValue(matches[index], displayStart))
    }
    return set
  }

  private transferCompletions(): string[] | null {
    let tokens: CompletionToken[] = CommandBarViewModel.tokenizeForCompletion(this.inputText)
    if (tokens.length === 0 || (tokens[0].value !== 'put' && tokens[0].value !== 'get')) { return null }
    if (tokens.length === 1 && !this.inputText.endsWith(' ')) { return null }
    let current: CompletionToken = tokens[tokens.length - 1]
    let command: string = tokens[0].value
    let operandIndex: number = 0
    let optionsEnded: boolean = false
    let expectValue: string = ''
    for (let index: number = 1; index < tokens.length - 1; index++) {
      let value: string = tokens[index].value
      if (expectValue.length > 0) { expectValue = ''; continue }
      if (!optionsEnded && value === '--') { optionsEnded = true; continue }
      if (!optionsEnded && (value === '-p' || value === '-i')) { expectValue = value; continue }
      if (!optionsEnded && value.startsWith('-')) { return [] }
      operandIndex++
    }
    if (expectValue === '-i') { return this.keyCompletions(current) }
    if (expectValue === '-p') { return [] }
    if (!optionsEnded && current.value === '-i') { return [] }
    if (!optionsEnded && current.value.startsWith('-') && current.value.length > 0) { return [] }
    let remoteOperand: boolean = (command === 'get' && operandIndex === 0) ||
      (command === 'put' && operandIndex === 1)
    if (remoteOperand) { return this.transferHostCompletions(current) }
    let localOperand: boolean = (command === 'put' && operandIndex === 0) ||
      (command === 'get' && operandIndex === 1)
    if (!localOperand) { return [] }
    return this.localPathCompletions(current, command === 'put')
  }

  private transferHostCompletions(token: CompletionToken): string[] {
    if (token.value.includes(':') || token.value.includes('@')) { return [] }
    let aliases: string[] = this.sshConfig.getHostAliases()
    let matches: string[] = []
    for (let index: number = 0; index < aliases.length; index++) {
      if (CommandBarViewModel.safeCompletionValue(aliases[index]) && aliases[index].startsWith(token.value)) {
        matches.push(this.inputText.substring(0, token.start) + aliases[index] + ':')
      }
    }
    return matches
  }

  private keyCompletions(token: CompletionToken): string[] {
    if (this.context === null) { return [] }
    let keys: KeyPairInfo[] = SshKeyManager.listKeys(this.context)
    let matches: string[] = []
    for (let index: number = 0; index < keys.length; index++) {
      let slash: number = keys[index].filePath.lastIndexOf('/')
      let name: string = keys[index].filePath.substring(slash + 1)
      if (CommandBarViewModel.safeCompletionValue(name) && name.startsWith(token.value)) {
        matches.push(this.inputText.substring(0, token.start) + name)
      }
    }
    return matches
  }

  private localPathCompletions(token: CompletionToken, includeFiles: boolean): string[] {
    let slash: number = token.value.lastIndexOf('/')
    let visibleDirectory: string = slash < 0 ? '' : token.value.substring(0, slash)
    let explicitRoot: boolean = token.value.startsWith('./')
    let directory: string = visibleDirectory
    if (directory === '.') { directory = '' }
    else if (directory.startsWith('./')) { directory = directory.substring(2) }
    let partial: string = slash < 0 ? token.value : token.value.substring(slash + 1)
    if (!CommandBarViewModel.safeCompletionDirectory(directory)) { return [] }
    try {
      let root: string = Environment.getUserDownloadDir().replace(/\/+$/, '')
      if (root.length === 0) { return [] }
      let path: string = directory.length > 0 ? root + '/' + directory : root
      let directoryStat: fs.Stat = fs.lstatSync(path)
      if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) { return [] }
      let entries: string[] = fs.listFileSync(path)
      let matches: string[] = []
      for (let index: number = 0; index < entries.length; index++) {
        let name: string = entries[index]
        if (!CommandBarViewModel.safeCompletionValue(name) || !name.startsWith(partial) ||
          (name.startsWith('.') && !partial.startsWith('.'))) { continue }
        let child: string = path + '/' + name
        let stat: fs.Stat = fs.lstatSync(child)
        if (stat.isSymbolicLink() || (!stat.isDirectory() && (!includeFiles || !stat.isFile()))) { continue }
        let relative: string = directory.length > 0 ? directory + '/' + name : name
        if (explicitRoot) { relative = './' + relative }
        if (stat.isDirectory()) { relative += '/' }
        matches.push(this.inputText.substring(0, token.start) + CommandBarViewModel.escapeArgument(relative))
      }
      return matches
    } catch (e) {
      return []
    }
  }

  private static tokenizeForCompletion(input: string): CompletionToken[] {
    let tokens: CompletionToken[] = []
    let token: CompletionToken | null = null
    let quote: string = ''
    let escaping: boolean = false
    let endedOnSeparator: boolean = false
    for (let index: number = 0; index < input.length; index++) {
      let character: string = input[index]
      if (token === null && !/\s/.test(character)) {
        token = new CompletionToken()
        token.start = index
        endedOnSeparator = false
      }
      if (token === null) {
        endedOnSeparator = true
        continue
      }
      if (escaping) { token.value += character; escaping = false; endedOnSeparator = false }
      else if (character === '\\' && quote !== "'") { escaping = true }
      else if (quote.length > 0) {
        if (character === quote) { quote = '' } else { token.value += character }
        endedOnSeparator = false
      } else if (character === '"' || character === "'") { quote = character }
      else if (/\s/.test(character)) { tokens.push(token); token = null; endedOnSeparator = true }
      else { token.value += character; endedOnSeparator = false }
    }
    if (token !== null) { tokens.push(token) }
    if (endedOnSeparator) {
      let empty: CompletionToken = new CompletionToken()
      empty.start = input.length
      tokens.push(empty)
    }
    return tokens
  }

  private static safeCompletionDirectory(directory: string): boolean {
    if (directory.startsWith('/') || directory.startsWith('\\') || directory.includes('\\') ||
      /^[A-Za-z]:/.test(directory) || !CommandBarViewModel.safeCompletionValue(directory)) { return false }
    if (directory.length === 0) { return true }
    let parts: string[] = directory.split('/')
    for (let index: number = 0; index < parts.length; index++) {
      if (parts[index].length === 0 || parts[index] === '.' || parts[index] === '..') { return false }
    }
    return true
  }

  static safeCompletionValue(value: string): boolean {
    return TerminalTextPolicy.isSafe(value)
  }

  private static escapeArgument(value: string): string {
    let escaped: string = ''
    for (let index: number = 0; index < value.length; index++) {
      let character: string = value[index]
      if (/\s/.test(character) || character === '\\' || character === '"' || character === "'") {
        escaped += '\\'
      }
      escaped += character
    }
    return escaped
  }

  private static unescapeDisplayValue(value: string): string {
    let display: string = ''
    let escaping: boolean = false
    for (let index: number = 0; index < value.length; index++) {
      let character: string = value[index]
      if (escaping) {
        display += character
        escaping = false
      } else if (character === '\\') {
        escaping = true
      } else {
        display += character
      }
    }
    if (escaping) { display += '\\' }
    return display
  }

  static completionDisplayValue(replacement: string, tokenStart: number): string {
    let value: string = replacement.substring(tokenStart)
    let searchEnd: number = value.endsWith('/') ? value.length - 1 : value.length
    let slash: number = value.lastIndexOf('/', Math.max(0, searchEnd - 1))
    if (slash >= 0) { value = value.substring(slash + 1) }
    return CommandBarViewModel.unescapeDisplayValue(value)
  }

  navigateHistory(direction: number): string {
    if (this.history.length === 0) { return this.inputText }
    let newIndex: number = this.historyIndex + (direction < 0 ? 1 : -1)
    if (newIndex < -1) { newIndex = -1 }
    if (newIndex >= this.history.length) { newIndex = this.history.length - 1 }
    this.historyIndex = newIndex
    if (this.historyIndex >= 0) { this.inputText = this.history[this.historyIndex] }
    else { this.inputText = '' }
    return this.inputText
  }

  addToHistory(command: string): void {
    if (command.trim().length === 0) { return }
    if (this.history.length > 0 && this.history[0] === command) { return }
    this.history.unshift(command)
    if (this.history.length > CommandBarViewModel.MAX_HISTORY) { this.history.pop() }
    this.historyIndex = -1
  }
}

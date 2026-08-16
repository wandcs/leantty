# LeanTTY Tab 补全设计

> 状态：Implemented；待最终候选人工视觉 smoke
>
> milestone：1.3
>
> 更新日期：2026-08-15
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：已进入 [`next-work.md`](../next-work.md)；按其中顺序实现和验证

## 用户问题与目标

LeanTTY 在未连接服务器时提供少量本地命令，其中 `put/get` 需要在固定的 Downloads 边界内
补全本地文件和目录。首版菜单补全已经证明候选生成、前缀匹配、目录下钻和键盘事件链可行，
但候选列表被当作普通终端输出写入：列表出现在命令上方、旧列表留在屏幕中，新列表继续叠加；
进入选择后，命令行虽然预览了候选，列表中却没有同步高亮当前项。编辑输入还会直接结束补全，
无法让已经打开的候选区随前缀变化。

目标是把它收敛为一个短生命周期、键盘优先、行为接近成熟 Shell 行编辑器的本地补全区域：

- 候选始终位于当前命令行下方，并且只有一个可重绘区域；
- 用户真实输入、候选集合、当前选择和命令行预览保持一致；
- 目录可以逐层下钻，接受候选不会误执行整条命令；
- 候选生成继续保持本地、有界、无网络、无额外授权和无递归枚举；
- 不把补全扩大为 Shell、文件管理器、模糊搜索器或通用命令面板。

## 产品原则评估

本项修复的是核心键盘路径的正确性和可预测性，属于必须闭合的可靠性问题。候选重复、选择状态
不可见和输入状态不同步会让用户无法判断 Enter、Tab 或继续输入将作用于哪个路径，不能作为
纯视觉问题推迟。

采用单一临时区域和单一补全会话，比保留永久输出后继续用清行序列修补更简单。范围只覆盖
LeanTTY 已有本地命令的有限候选，不引入设置、常驻控件、在线服务或另一套本地文件入口。

## 外部参考与复用结论

需要区分终端、Shell 行编辑器和候选生成器：终端负责渲染控制序列，Bash Readline、Zsh ZLE
或 fish reader/pager 才拥有当前输入、候选菜单和重绘生命周期。

- [GNU Readline 补全命令](https://www.gnu.org/s/bash/manual/html_node/Commands-For-Completion.html)
  提供普通 Tab、候选列表和可选的 `menu-complete`。Bash 的默认体验最简单，但没有提供本项
  所需的常驻高亮候选菜单。
- [Zsh completion options](https://zsh.sourceforge.io/Doc/Release/Options.html#Completion-4)
  通过 `AUTO_LIST`、`AUTO_MENU`、`ALWAYS_LAST_PROMPT` 和 `AUTO_PARAM_SLASH` 管理首 Tab
  列表、连续 Tab 菜单、回到输入行和目录尾随 `/`。
- [Zsh `complist` menu selection](https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html#Menu-selection)
  负责列表高亮、滚动、四方向移动、Enter 只接受候选、Esc 恢复输入，以及接受目录后继续
  补全下一层。其默认当前项使用终端 standout/reverse-video，而不是依赖固定强调色。
- [Oh My Zsh completion configuration](https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/lib/completion.zsh)
  和 [Prezto completion configuration](https://raw.githubusercontent.com/sorin-ionescu/prezto/master/modules/completion/init.zsh)
  主要配置 ZLE/`complist`，并不自行实现第二套候选 UI。Oh My Zsh 用 `Ctrl+O` 绑定
  `accept-and-infer-next-history`，说明目录立即下钻是独立接受动作，不是 Enter 执行命令。
- [fish interactive completion](https://fishshell.com/docs/current/interactive.html#tab-completion)
  和 [fish pager source](https://raw.githubusercontent.com/fish-shell/fish-shell/master/src/pager.rs)
  展示了命令下方的有限高度 pager、当前项样式、按终端尺寸重排、滚动位置和可选搜索模式。
- [bash-completion](https://github.com/scop/bash-completion) 只向 Bash/Readline 提供候选；
  Starship 只生成 prompt 和 Shell 补全入口。两者都不是可嵌入 LeanTTY 的菜单渲染器。

上游实现不能直接作为 LeanTTY 依赖：Zsh `complist` 与 ZLE、terminfo 和 Shell 状态耦合；fish
pager 与其 reader、screen 和 highlight 系统耦合；Bash completion recipes 依赖 Bash 变量和
函数。LeanTTY 复用它们已经验证的职责边界、状态语义和终端重绘方法，不复制 Shell 运行时或
大段实现代码。

## 已确认的交互合同

### 打开和唯一补全

- 在可补全位置按 Tab 才启动补全；普通输入期间不主动枚举或显示候选。
- 没有候选时保持当前输入并安静结束，不输出红色错误或永久提示。
- 只有一个候选时，第一次 Tab 直接完成。目录保留尾随 `/`，文件沿用既有参数空格规则。
- 多个候选时，第一次 Tab 只打开列表，不隐式选择第一项，也不自动改写用户输入。
- 对同一输入连续第二次按 Tab 才进入菜单选择并选中第一项；Shift+Tab 从最后一项进入。

### 候选区位置和生命周期

- 当前命令行是视觉锚点，候选区只显示在它下方；完成重绘后，输入光标仍回到命令行中的正确
  cell，而不是停在候选末尾。
- 同一 Pane 同一时刻最多有一个候选区。候选、选择、终端宽度或可见窗口变化时，清除旧区域并
  在原位置重绘，不追加第二块候选。
- 候选区属于当前本地输入会话，不是命令结果。接受、取消、执行命令、切换模式、Pane/Tab
  失活、Session 建立、窗口或 Surface 销毁时完整清除；关闭后不得留下可见旧候选或把它重新
  恢复到另一个 Pane。
- 终端靠近底部、发生换行或调整窗口大小时仍遵守同一合同；实现不能只在候选恰好占一行时正确。

### 列表、选择和高亮

- 首次列表态没有当前选择，因此不伪造高亮。进入菜单选择后必须且只能有一个高亮项。
- 命令行中的候选预览和候选区高亮使用同一个 `selectedIndex`；两者不能分别推进。
- 当前项使用主题安全的反显或等价中性背景，不引入蓝色、图标、bold 或新的语义色。文字和目录
  尾随 `/` 在深浅主题、五档透明度和固定字体下都必须可辨。
- Tab/Shift+Tab 按候选顺序正反向循环；候选按列从上到下排列，再进入下一列，使连续 Tab 的
  视觉移动与列表顺序一致。
- 进入菜单后 Up/Down 按行移动，Left/Right 按列移动，边界循环；没有进入菜单时，方向键继续
  执行原有光标或历史行为并关闭候选区，不能在无选择状态下暗中改写命令。
- Enter 只接受当前候选并退出菜单，不执行整条 `put/get`。列表态没有选择时按 Enter 先清除
  候选区，再按普通命令提交处理。
- Esc 在列表态只关闭列表并保留当前真实输入；在选择态取消候选预览、恢复最近一次真实输入并
  关闭列表。

### 输入变化和实时更新

- 候选区打开后，普通文字、Backspace 或 Delete 先取消当前候选预览，再作用于最近一次真实
  输入；随后用新前缀重新生成候选并原地更新区域。
- 普通文字不能隐式接受高亮候选。用户输入 `D` 是改变真实前缀，不是把当前预览目录提交后再
  向该目录写入 `D`。
- 更新后有多个或一个候选时均可继续显示，但普通输入本身不自动完成唯一候选；用户仍通过 Tab
  或明确接受动作提交。更新后没有候选、上下文不再可补全或光标离开当前操作数时关闭区域。
- 候选刷新只做当前目录一层的原始大小写和 Unicode 前缀匹配，不引入模糊、子串、大小写折叠
  或始终开启的搜索框。fish/Zsh 的独立 pager 搜索模式不进入 1.3。

### 目录接受和逐层下钻

- LeanTTY 路径语法固定使用正斜杠 `/`；反斜杠 `\` 继续属于转义语法，不能同时充当目录
  分隔符。
- 所有目录候选和接受结果统一以 `/` 结尾。Enter 接受目录后，用户可以继续输入下一层前缀或
  再按 Tab 打开下一层候选。
- 选择态高亮目录时，按 `/` 作为快捷下钻：接受当前目录并立即生成下一层候选；候选已经带 `/`
  时不得产生 `//`。没有下一层候选时保留已接受的目录文本并关闭候选区，不把“空目录”当错误。
- `/` 只在当前高亮项被可靠识别为目录时承担快捷下钻；高亮文件或不在菜单选择时，继续按普通
  输入和既有转义/路径规则处理。

## 候选布局与有界行为

- 候选使用固定字体的终端 cell 宽度计算，不按 UTF-16 长度对齐；空格、CJK、Unicode 和经过
  安全转义的文件名不得破坏列边界。
- 在可用宽度内从多列逐步退化到单列，不横向溢出。过长显示值可以有界截断，但接受值必须保留
  完整、安全的原始路径语义。
- 初始可见高度不超过候选区可用终端高度的一半，并在空间允许时至少显示四行；终端太小时优先
  保留可编辑命令行和一行候选，而不是覆盖提示符或输出无界列表。
- 超出可见区域时只渲染包含当前项的窗口，并提供不依赖颜色的紧凑位置/剩余量说明；导航时窗口
  跟随当前项。现有 100 个安全候选上限继续生效，超限说明属于同一临时区域。
- terminal resize、字体/主题应用和候选内容变化必须重新计算列数、行数、可见窗口及光标位置。

## 所有权与实现边界

```text
TerminalInputParser keyboard action
  → current Pane SessionViewModel local input owner
    → CommandBarViewModel completion provider
      → safe LocalCompletionSet (replacement + display value + directory kind)
    → one LocalCompletionSession
      → real input + candidates + phase + selected index + preview
    → one transient terminal completion renderer below the command line
```

- `CommandBarViewModel` 继续只负责判断补全上下文和生成安全候选，不拥有 Tab 次数、选择、颜色、
  光标移动或终端行。
- 当前 Pane 的本地输入所有者独占一个补全会话。真实输入、预览、阶段、候选、目录类型和当前项
  必须来自该会话，不能由 formatter、命令行缓冲和按键分支各存一份隐式状态。
- 显示层只根据补全会话快照重绘并记录自己占用的可见行，不从已写入终端的文字反推状态。
- 补全不进入 SSH Transport，不发网络请求，不触发连接、认证、主机校验或 Downloads 授权弹窗。
  它只使用当前已经可读的 Downloads 能力；读取失败返回无候选，不扩大权限。
- 每个 Pane 的补全状态隔离。切换 Pane/Tab、开始连接、执行命令或销毁 Surface 时先结束当前补全
  会话，迟到输入或重绘不能落入另一个 Pane。

## 实现结果与证据边界

2026-08-15 的旧版实现曾经验证以下基础能力：Downloads 一层候选、安全前缀匹配、目录 `/`、
首 Tab 列表、二次 Tab 选择、Tab/Shift+Tab 和 Up/Down 循环、Enter 接受、Esc 取消，以及无网络、
无授权和无传输副作用。对应测试 HAP SHA-256 为
`5e34bdf7e5deef141e7d196a35d79e454c50fdd5c4b73602e5573a49c1431054`。

旧证据不证明本文新增合同，也不能作为 1.3 release candidate。

2026-08-15 已按本文合同完成重新实现：当前 Pane 独占补全会话，真实输入、列表/选择阶段、候选、
`selectedIndex` 和命令行预览来自同一状态；独立 transient renderer 在命令下方清除并重绘唯一
候选区域，按固定字体终端 cell 宽度进行列布局、有界分页、长名称截断和 resize 重排。普通输入、
Backspace/Delete 从真实输入重新匹配；Tab/Shift+Tab、四方向、Enter、Esc 和目录 `/` 下钻均进入
同一状态机。候选只显示当前层 basename，接受值仍保留完整且安全转义的路径。

受影响 ArkTS 单元测试为 112/112；构建工作流、设备验收脚本和公开源码检查通过。物理 ARM64
HAD-W32 上的 `TabCompletionMatrix` 使用真实终端 key dispatch 闭合首 Tab 列表、二次 Tab 选择、
正反向与二维导航、Enter/Esc、实时输入与 Backspace 刷新、`/` 下钻、空格/引号/Unicode/隐藏项和
不安全格式字符过滤；候选区位于命令下方，列表态无高亮、选择态只有一个反显项，更新不叠加，
全程没有权限、认证、网络或传输副作用。证据位于忽略目录
`build/verification/tab-completion-transient-final-v3/`，汇总结果为 `passed`，验收 HAP SHA-256 为
`c43d3e9ee303cd38fb2bb2da21f82d782dfe4e1041aa72c3fb8d4161901d2efa`。验收结束后已重新构建、
安装并启动不含夹具的正常开发包。

上述证据证明实现和核心设备事件链，不把当前 dirty-tree test-signed HAP 宣称为 release candidate。
深浅桌面背景、Off/Medium/Extreme、窄/宽窗口、屏幕底部和实体键盘体感继续保留到从精确 release
commit 冻结的最终候选人工视觉 smoke；它们不再阻塞本实现项关闭，但任一可见错误仍会阻止 1.3
候选晋级。

## 验证合同

### 纯逻辑与 ArkTS 自动化

- 覆盖关闭、列表、选择三个阶段，以及真实输入、预览、候选和当前项的单一状态转换。
- 覆盖无/一/多候选、首 Tab、二次 Tab、Shift+Tab、四方向循环、Enter、Esc、普通输入、
  Backspace/Delete、`/` 下钻和空目录。
- 覆盖旧候选区域清除、同一区域重绘、列表缩短/增高、单行/多行候选、终端 resize 和命令行换行；
  断言连续更新不会增加第二个候选区或留下旧项。
- 覆盖空格、引号、隐藏项、CJK/Unicode、宽字符、控制字符净化、长文件名、候选上限和窄终端。
- 证明补全不触发网络、认证、传输、权限请求，不改变 Host、Identity、命令名和已连接 SSH 的
  Tab 透传。

### ARM64 与物理 HarmonyOS PC

- 只在受影响检查通过后运行日常 `tools/dev-pc.ps1`，构建并部署新的 ARM64 test-signed HAP。
- 使用真实物理键盘验证候选在命令下方、连续筛选不叠加、选择项高亮同步、Tab/Shift+Tab、
  四方向、Enter、Esc、Backspace 和 `/` 目录下钻。
- 在固定字体、深浅桌面背景、至少 Off/Medium/Extreme、窄/宽窗口和命令靠近屏幕底部时观察
  对齐、反显、滚动和清除；安装/启动或单张截图不能替代完整事件链。
- 验证候选关闭后命令输出、scrollback、连接、Pane 切换和后续本地命令仍正常，没有旧候选复现。

## 非目标与停止条件

- 不做远端路径补全、递归目录树、模糊/子串匹配、拼写纠正、文件预览、图标、鼠标候选菜单、
  搜索框、自定义按键或补全设置。
- 不嵌入 Bash、Zsh、fish、Readline、fzf 或本地 Shell，不为了复用候选菜单增加 native Shell
  运行时、进程、PTY 或许可证负担。
- 不把候选区实现为新的全局 ArkUI 文件面板或通用 overlay 框架，也不改变远端 Shell 自己的
  Tab 补全和 TUI 按键语义。
- 如果可靠的临时区域必须改写 xterm 私有 buffer、建立第二套终端网格或让候选进入其他 Pane，
  停止实现并重新评估显示方案；不能用更多清行特例掩盖所有权错误。

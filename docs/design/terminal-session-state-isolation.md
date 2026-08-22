# SSH Session 终端状态隔离方案

> 状态：Verified；`v1.4.0` 已通过 GitHub、AppGallery 发布
>
> 当前 milestone：1.4.0
>
> 更新日期：2026-08-22
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：已按原 [`next-work.md`](../next-work.md) 门禁闭合；完成事实保留在本文

## 用户问题

2026-08-17，用户在物理 ARM64 HarmonyOS PC 上复现：

1. 打开 LeanTTY，通过普通 SSH 连接 HSL。
2. 使用 `hx` 打开任意文件，不编辑直接退出。
3. 光标由 LeanTTY 默认闪烁竖线变为竖块。
4. 退出 HSL 回到 `ltty>` 后，再在同一 Pane 连接其他服务器，竖块仍然
   延续。
5. 新建分屏或 Tab 没有该问题。

光标是已经被观察到的表象。代码盘点进一步确认，同一 Terminal Surface 还可能保留
上一个远端 PTY 设置的输入、渲染、缓冲区与颜色状态。因此需要解决的问题不是
`hx` 或 HSL 兼容特例，而是：

> **同一 Pane 从一个 SSH Session 回到 LeanTTY 本地提示符或进入新 PTY 时，
> 没有隔离上一个远端 PTY 留下的终端模拟器运行态。**

## 产品原则评估

- **可靠。** 远端会话结束后，本地提示符和下一个 Session 必须有确定输入输出；
  不能继承上一台服务器的隐式模式。
- **所有权清楚。** 远端连接存活期间，PTY 可以通过标准终端序列控制当前
  Terminal Surface；Session 结束后，这些临时控制权也必须结束。
- **简洁。** 保留一个统一的 Session-boundary reset，不针对 `hx`、vim、tmux、HSL 或
  某台服务器分别打补丁，不增加用户设置。
- **终端兼容。** 在活跃 SSH Session 内继续完整尊重远端模式；LeanTTY 不猜测
  远端程序何时退出，也不强制会话内始终使用竖线光标。

## 当前事实与证据边界

### 已确认

1. `terminal.html` 创建 xterm 时配置 `cursorStyle: 'bar'` 和 `cursorBlink: true`。
2. 远端 SSH 字节流直接交给 xterm；xterm 6.0.0 支持 DECSCUSR（`CSI Ps SP q`），
   并将光标形状与闪烁保存为实例运行态。
3. SSH 关闭路径返回 `IDLE` 后只通过 `ESC[0m` 复位 SGR 属性并输出本地提示符，
   没有统一结束远端终端模式。
4. 同一 Pane 复用同一 `TerminalSurfaceController` 与 xterm 运行时；新分屏和新 Tab 创建
   新实例，与实际问题边界一致。
5. xterm SerializeAddon 会把备用屏幕和多种 mode 写入 Terminal Surface 快照；LeanTTY 还会
   另外序列化“光标隐藏”。因此部分远端状态可以跨 WebView 回收延续，不只是
   在当前 renderer 存活时暂存。
6. 固定 xterm 6.0.0 行为矩阵确认：`47`、`1047`、`1049` 三种 alternate-buffer 进入方式
   可以由统一边界退出，但不存在一条仅靠固定退出序列排列、同时为三种方式保留远端
   cursor 的通用契约。Session 结束后因此只保留 normal buffer/scrollback，不保留远端
   cursor；新的本地输出显式锚定在屏幕末行之后。
7. xterm `write` 完成回调证明字节已经解析，但不保证用户当前 viewport 位于底部；
   alternate buffer 退出后若用户原先停留在 scrollback，必须在本地 close/prompt 写入并
   完成 ACK 后，再通过公开 `scrollToBottom()` 恢复可见位置。

### 证据分级

| 级别 | 内容 | 当前结论 |
| --- | --- | --- |
| 物理机已复现 | `hx` 退出后块状光标留在同一 Pane，并跨 HSL 与下一台服务器 | 真实用户缺陷 |
| 代码确认可残留 | 备用屏幕、光标隐藏、application cursor/keypad、bracketed paste、mouse tracking、focus reporting、insert/origin/wrap 等 | 必须纳入诊断矩阵 |
| 同一活跃 xterm 可残留 | 光标闪烁、滚动区域、默认/调色板颜色、鼠标编码、字符集、tab stop、`convertEol` | 需要自动化与真机逐项确认实际用户影响 |
| 已有有界恢复 | SGR 属性与 App Shell 中的 `ltty` 标题 | 不代表其他终端模式已恢复 |
| 不预期永久残留 | synchronized output | xterm 有超时自动解除，仍作为时序回归项 |

上表不将“代码上可保留”写成“用户已经遇到”。除光标外，其他项必须在实施前
用可控序列与异常断开补齐证据。

## 主流终端调研对比（2026-08-17）

本节只使用各项目官方文档或上游源码。当前没有在这些产品上逐一完成相同脚本的
物理机对照，因此“明确行为”与“由架构推导”分开记录，不把源码阅读写成实测结论。

### 两类不同的 SSH 生命周期

主流桌面终端的常见路径是“本地 Terminal Surface → 本地 shell → `ssh` 子进程”。
终端模拟器只看到同一 PTY 中的字节流，并不知道哪些序列来自本地 shell、SSH、远端
shell 或远端 TUI。`ssh` 返回时，同一 Terminal Surface 继续服务本地 shell；光标等状态
是否恢复，通常依赖远端程序的退出清理或本地 shell/prompt 再次发出覆盖序列。

另一类是应用直接管理 SSH Domain/Session，并把连接生命周期与 Pane 绑定。连接结束时
可以销毁 Pane，或者由应用在复用 Terminal Surface 前显式回收远端状态。LeanTTY 属于
直接管理 SSH Session、但选择保留同一 Pane 与 scrollback 的第三种组合，因此不能完全
照搬前一种产品的偶然恢复，也不能照搬后一种产品的 Pane 销毁。

| 产品与入口 | SSH 结束时的已确认行为 | 状态恢复机制与限制 | 对 LeanTTY 的含义 |
| --- | --- | --- | --- |
| Ghostty：在本地 shell 中运行 `ssh` / `ghostty +ssh` | 官方文档说明 `+ssh` 最终 `exec` 系统 `ssh`，不是独立的远端 Terminal Surface；返回后仍由原本地 shell 继续使用该 Surface | 默认 shell integration 会在 prompt 发出 bar cursor，在命令执行前发出 DECSCUSR reset。上游 Bash 脚本明确把 `CSI 5/6 SP q` 加到 `PS1`，把 `CSI 0 SP q` 加到 `PS0`。因此常见的“SSH 退出后光标恢复”是 prompt 覆盖，不是 SSH 边界全量 reset；关闭 cursor integration 后不能依赖该覆盖 | 证明“本地提示符必须主动重申自己的光标状态”是成熟做法，但不能由此推导 mouse、alternate buffer、颜色等也已回收 |
| kitty：`ssh` / `kitten ssh` | 官方文档称 ssh kitten 是传统 `ssh` 的薄包装，并可在远端安装 shell integration；本地仍是同一终端中的命令 | kitty shell integration 在编辑 prompt 时把光标设为 bar、执行命令前恢复默认形状；官方配置也明确运行程序可覆盖默认 cursor shape。恢复仍由 shell hook/应用清理驱动，不是连接退出触发的统一终端重建 | 与 Ghostty 一致：prompt 重申可以修复光标表象，但不能作为 Session 隔离契约 |
| Windows Terminal：在 PowerShell/cmd 中运行 `ssh` | Microsoft 的 SSH 指南把 OpenSSH 当作普通命令执行；若配置为以 `ssh user@host` 直接启动的 profile，正常进程结束时默认 `closeOnExit=automatic` 会关闭该 profile | 前一种路径回到同一 shell/Terminal Surface，官方没有给出 SSH 边界 reset 契约；后一种路径以关闭 Tab/profile 隔离状态，不存在回到同一 Pane 再连接的问题。这一项是由官方进程/profile 模型作出的架构推论，不是相同脚本实测 | 关闭 Surface 能天然隔离，但 LeanTTY 要保留 Pane 与 scrollback，不能用关闭/重建代替有界 reset |
| WezTerm：普通 `ssh` 与 SSH Domain | 普通 `ssh` 仍属于本地 shell 子进程模型；官方 SSH Domain 文档说明 `multiplexing = "None"` 时，失去连接会失去对应 panes/tabs | 直连 Domain 把远端生命周期绑定到远端 Pane；断开后丢弃该 Pane 状态。multiplexing 模式若保留远端 Pane，则保留现场本身是功能语义，不应复位 | 支持“远端状态的生命周期应与拥有它的 Session/Pane 一致”；LeanTTY 若复用 Pane，必须在所有权转移时显式清理，而非让旧 Session 状态继续拥有 Surface |

官方依据：

- Ghostty [`+ssh` 文档](https://ghostty.org/docs/features/ssh)、
  [shell integration 文档](https://ghostty.org/docs/features/shell-integration) 与
  [Bash integration 源码](https://github.com/ghostty-org/ghostty/blob/main/src/shell-integration/bash/ghostty.bash)。
- kitty [shell integration 文档](https://sw.kovidgoyal.net/kitty/shell-integration/)、
  [ssh kitten 文档](https://sw.kovidgoyal.net/kitty/kittens/ssh/) 与
  [cursor 配置源码](https://github.com/kovidgoyal/kitty/blob/master/kitty/options/definition.py)。
- Microsoft [Windows Terminal SSH 指南](https://learn.microsoft.com/en-us/windows/terminal/tutorials/ssh)
  与 [profile 退出行为](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-advanced)。
- WezTerm [SSH Domain 文档](https://wezterm.org/config/lua/SshDomain.html) 与
  [SSH host/domain 生成文档](https://wezterm.org/config/lua/wezterm/default_ssh_domains.html)。

### 对修复原则的校准

1. **不在远端应用退出时介入。** Ghostty 与 kitty 都允许运行程序在活跃 PTY 内覆盖
   cursor 等状态；LeanTTY 也继续尊重 vim、Helix、tmux 和 Agent TUI 的标准控制序列。
2. **本地提示符不能依赖远端善后。** 主流 shell integration 会在 prompt 重新发光标序列，
   说明控制权回来后由新所有者重申状态是合理边界。LeanTTY 的 `ltty>` 由 App 自己拥有，
   应在输出 prompt 前完成确定恢复。
3. **不能只模仿 cursor prompt hook。** Ghostty/kitty 的 hook 解释了光标为何常常看似正常，
   但没有证明 alternate buffer、mouse、focus、bracketed paste、颜色等都已隔离；LeanTTY
   直接知道异常断开和 reconnect 边界，应覆盖经测试证实会污染下一 Session 的状态。
4. **不照搬关闭 Pane。** Windows Terminal 的直接 SSH profile 与 WezTerm 直连 Domain
   可以通过关闭/丢弃 Surface 隔离；LeanTTY 明确要保留 Pane 和 scrollback，因此选择
   有界 reset，而不是用重建终端获得表面干净。
5. **reset 范围由证据决定。** 对比产品没有提供一个可直接复制的“SSH 退出全量复位”
   标准。实现仍须以固定 xterm 6.0.0 的失败基线决定序列集合；未证明跨 Session 残留或
   影响核心输入输出的状态不进入 reset。

## 连带风险

| 远端留下的状态 | 可观察失败 |
| --- | --- |
| 光标形状/闪烁/可见性 | `ltty>` 或下一会话出现块状、不闪烁或完全看不到光标 |
| alternate buffer（`?1049h`） | 本地提示符留在 TUI 备用屏幕，正常 scrollback 不可见 |
| application cursor keys | 方向键产生 `ESC O A/B/C/D`，本地历史或光标移动失效或混入文本 |
| application keypad | 数字键盘产生下一个环境不期望的特殊序列 |
| bracketed paste | 新会话尚未请求时，粘贴被包装为 `ESC[200~...ESC[201~` |
| mouse tracking 与编码 | 点击、拖动或滚轮转成终端输入，影响选区并可能污染本地/新会话 |
| focus reporting | Pane 焦点变化产生 `ESC[I` / `ESC[O`，被本地命令行或下一会话接收 |
| insert/origin/wrap/reverse-wrap/scroll region | 本地提示符覆盖字符、定位错误、不换行或只在局部区域滚动 |
| 动态调色板、前景/背景/光标颜色 | 下一个服务器或本地提示符继承上一环境改写的颜色 |

## 已确认的状态隔离契约

### 远端 Session 内

- 完整支持远端 shell、tmux、vim、Helix 和 Agent TUI 通过标准序列切换光标、
  备用屏幕、鼠标、粘贴、键盘和渲染模式。
- `hx` 退出但仍在同一远端 shell 时，LeanTTY 不猜测程序边界，也不强制恢复
  竖线光标；远端环境仍然拥有当前 PTY 表现。

### Session 边界必须保留

- normal buffer 中的可见内容和现有 scrollback；修复不能用清屏或重建终端隐藏问题。
- Pane 的稳定标识、本地命令历史、字号、透明度、LeanTTY 主题与用户所有的设置。
- Tab / Pane / Session 所有权和既有输出背压、快照与 renderer 恢复语义。

### Session 边界必须复位

- 回到 normal buffer，让本地提示符不留在上一个 TUI 的 alternate buffer。
- 恢复 LeanTTY 配置的光标形状与闪烁，并显示光标。
- 关闭 application cursor/keypad、bracketed paste、mouse tracking/编码、focus reporting、
  insert、origin 与 reverse-wrap，恢复标准 wrap 和全屏滚动区域。
- 恢复默认字符集、换行与本地提示符必需的输出属性。
- 恢复 LeanTTY 当前主题的 ANSI 调色板、默认前景/背景和光标颜色，不保留远端对
  Terminal Surface 主题的临时改写。

### 触发边界

| 事件 | 是否复位 | 理由 |
| --- | --- | --- |
| 远端 shell 正常退出并返回 `ltty>` | 是 | 远端 PTY 控制权已结束 |
| 已连接 Session 网络错误、超时或异常断开 | 是 | 远端可能没有机会发送清理序列 |
| 旧 PTY 结束后执行 reconnect | 是 | 新 PTY 不得继承旧 PTY 模式 |
| 连接/认证取消或失败 | 幂等执行 | 路径统一，但不假设已有远端模式 |
| 远端程序退出但 SSH shell 仍存活 | 否 | 仍在同一 PTY，不猜测应用边界 |
| Tab 切换、Pane 焦点变化或分屏 | 否 | 未结束 Session；不破坏 TUI 与焦点语义 |
| 活跃 Session 中的 WebView/renderer 回收恢复 | 否 | 应保留当前远端现场 |
| Pane 或 APP 被真正销毁 | 不要求可见复位 | 资源即将销毁；不为表象增加延迟 |

## 所有权与事件链

```text
SSH Transport / PTY closes
  → SessionViewModel confirms old remote output ownership has ended
  → release disconnected output flow control and reject late remote events
  → TerminalSurfaceController performs one bounded session-state reset and waits for xterm write ACK
  → position the new local-output anchor after preserved normal-buffer content
  → append local close/error text and ltty>, then wait for their write ACK
  → restore the viewport to the bottom through one typed public xterm operation
  → only after its completion acknowledgement accept local input
  → capture a clean snapshot when lifecycle requires it
  → next SSH PTY may establish its own terminal modes
```

- **SessionViewModel** 只决定何时远端控制权结束，不了解 xterm 私有字段。
- **TerminalSurfaceController** 是唯一的 reset 入口，负责与输出、快照和 renderer 生命周期
  排序；不创建第二套 Session 状态。
- **TerminalBridge / terminal.html** 只在有必要时承载类型化、有限的复位意图，实现 xterm
  边界内的标准序列或公开 API 操作；不在 Bridge 中维护业务状态。
- **App Shell** 不参与 reset；Tab 与 Pane 仍只负责所有权、焦点和布局。

## 实现方向与技术门禁

### 已确认方向

1. 只实现一个 Session-boundary reset，不在 SSH close、error、cancel、reconnect 各自复制
   一组序列。
2. reset 发生在旧远端输出被截止之后、本地提示符输出之前；不允许迟到远端字节
   在 reset 之后重新污染 Terminal Surface。
3. reset 只处理远端所有的短生命状态，不清屏、不清 scrollback、不重建 Pane，不
   改变用户设置。
4. 修复后仍使用固定 xterm 6.0.0 的实际解析器和快照恢复链验证，不用字符串存在性
   代替行为证据。

### 已选择的实现形式

开发候选采用一个窄的组合边界：

1. 复用现有 Terminal binary write 与 ACK，发送固定、有界的标准序列，退出三类
   alternate buffer，恢复已证实的输入、鼠标、光标、滚动区域、字符集和颜色状态；
   最后用标准 CUP 把新的本地输出锚定到屏幕末行，不清除 normal buffer 或 scrollback。
2. reset 字节完成 ACK 后，由 Session 的唯一结束回调写入 close/error 与 `ltty>`；这些本地
   字节继续走同一个有序输出队列。
3. Bridge 只有在所有较早 pending/in-flight writes 都完成 ACK 后，才发送一个空 payload 的
   `sessionResetViewport` 控制意图；ArkWeb 仅调用 xterm 公共 `scrollToBottom()` 并返回
   `sessionResetComplete`。
4. Session 在完成回执前拒绝本地输入和迟到远端字节；bridge detach 会中断旧回调并由当前
   Surface 重新完成边界，旧 snapshot request 不能越过 reset commit floor。

之所以保留这个类型化 viewport 意图，是因为标准序列可以确定 parser/cursor 状态，却不能
代表用户 viewport 已回到底部。它不提供任意 xterm 操作，不引入通用终端管理器、新持久状态
或调试面板。

### 明确拒绝的修复

- 不将 reset 放在 `hx` 退出或 HSL 专用分支中。
- 不禁止 DECSCUSR、alternate buffer、mouse tracking 或 bracketed paste。
- 不在每次远端输出或每次光标改变后强制覆盖远端状态。
- 不只在 `LocalCommandOutput.prompt()` 前增加光标复位后就宣称问题闭合。
- 不直接调用 `term.reset()`、销毁 WebView 或重建 Terminal Surface；这些方法会把
  scrollback、选区、焦点和生命周期风险扩大到问题之外。
- 不增加“光标形状”、“会话复位”或“兼容 HSL”用户设置。

## 验证计划

### 1. 确定性失败基线

在固定 xterm 6.0.0 的 Web terminal policy harness 中，逐项写入标准序列，再模拟返回
本地提示符和连接新 Session。每个用例必须先证明当前实现残留该状态，不把编写
了检查就当作失败证据。

最小矩阵：

- DECSCUSR 块状/下划线光标、光标不闪烁和 `?25l` 隐藏光标；
- `?1049h` alternate buffer；
- `?1h`、`?66h`、`?2004h`、`?1004h`；
- `?9h` / `?1000h` / `?1002h` / `?1003h` 与 SGR mouse encoding；
- insert、origin、wrap、reverse-wrap 与非全屏 scroll region；
- OSC 4/10/11/12 动态颜色；
- 上述状态被 Terminal Surface 快照并恢复后的同等结果；
- reset 前后 synchronized output 超时和 write acknowledgment 次序。

### 2. 自动化完成条件

- 每个已确认远端模式在 Session 内生效，证明修复没有禁用标准 TUI 能力。
- Session-boundary reset 后回到契约默认，并且新 Session 不继承旧模式。
- normal buffer 内容与 scrollback 在 reset 前后逐字节保留；不使用清屏隐藏差异。
- 旧 Session 的迟到输出、旧 reset 回执和过期 snapshot 不能覆盖当前 Pane 状态。
- 两个 Pane 和两个 Tab 并行时，只复位结束 Session 的 Terminal Surface。

截至 2026-08-18 已完成的开发候选证据：

- 固定 xterm 6.0.0 同时覆盖 live xterm 与 SerializeAddon restore，证明远端模式先能生效，
  再由边界恢复；覆盖光标形状/闪烁/隐藏、alternate buffer、application cursor/keypad、
  bracketed paste、focus、mouse、insert/origin/wrap/reverse-wrap、scroll region 与 OSC
  palette/default colors。
- `47h`、`1047h`、`1049h` 三类 alternate-buffer 入口均回到 normal buffer，normal 内容与
  scrollback 保留；本地 close/prompt 位于原 normal 内容之后，viewport 最终位于底部。
- policy harness 覆盖唯一 reset 入口、迟到 SSH 字节/输入门禁、snapshot commit floor、
  renderer 离线时只由 snapshot reset 后缀恢复状态、typed viewport allowlist，以及 viewport
  必须等待全部较早输出 ACK。
- ArkTS 单元测试与日常 ARM64 debug HAP 构建通过。运行期又覆盖已连接错误/断线、reconnect、
  renderer 中断期间的旧 Bridge/reset 回执，以及两 Pane/Tab 并行；旧 Session 的迟到事件不能
  重新取得 Terminal Surface 所有权，本节自动化完成条件已经闭合。

### 3. 物理 ARM64 HarmonyOS PC

必须在真实键盘、ArkWeb 和 xterm renderer 上覆盖：

1. HSL 与普通 SSH 服务器上的 `hx` 正常退出；同一远端 shell 内仍尊重远端光标，
   SSH 结束后 `ltty>` 恢复 LeanTTY 默认光标。
2. 在 vim/Helix/tmux/Agent TUI 活跃时强制远端断开，验证 alternate buffer、隐藏光标、
   mouse、focus 和 bracketed paste 的异常清理。
3. 同一 Pane 连续连接两台不同服务器，新 Session 不继承旧模式与颜色。
4. 新分屏、新 Tab、Tab 切换、renderer 回收恢复和合盖/锁屏后不串状态。
5. 修复前的 normal scrollback、复制选择、方向键历史、粘贴、鼠标选区和物理键盘
   主路均保持可用。

安装、启动、看到 `ltty>` 或一次 SSH 成功均不能代替这些交互验证。

截至 2026-08-18 已完成的聚焦真机证据：

- HSL 普通 SSH 中主动设置块状/隐藏光标、application cursor、bracketed paste、focus 等模式
  后正常退出，`ltty>` 恢复闪烁竖线，第一个本地字母可立即输入。
- 用户原始 `HSL → hx → 退出 hx → 退出 SSH` 路径中，同一远端 Session 内保留 hx 留下的
  块状光标；SSH 所有权结束后同一 Pane 恢复 LeanTTY 竖线光标和本地输入。
- dirty alternate buffer 中同时开启隐藏光标、mouse、bracketed paste 与 focus 后直接结束
  SSH：normal 内容/scrollback 保留，`Connection closed` 与 `ltty>` 无需先输入即可在底部
  看见，随后第一个 `r` 正确显示并由本地模式接收。
- 活跃 SSH 的 alternate buffer 经编译期隔离的 renderer 重建入口后，远端内容、颜色、光标
  与连接所有权原样恢复；随后在 renderer 退出到新 Bridge ready 的窗口内让 SSH 正常结束，
  日志顺序实际为 renderer exited → SSH closed → Bridge initialized/ready。恢复后只出现一份
  `Connection closed` 和一份 `ltty>`，第一个本地 `r` 可立即输入。该路径同时证明 renderer
  离线时 reset 只需 snapshot 状态后缀，不应再向 detached output 队列追加第二份 reset。
- 双 Pane 同时连接 HSL 时，左 Pane 带 alternate buffer、隐藏光标与 mouse 状态退出后只复位
  左侧 Surface；右 Pane 随即执行并显示 `RIGHT_SURVIVED`，连接、颜色、光标和输入不受影响。
  随后在新 Tab 中用 dirty alternate buffer 退出，切回原双 Pane Tab 后原右侧连接继续执行并
  显示 `TAB1_SURVIVED`。验收后已关闭新增 Tab/Pane 并正常退出剩余 SSH，恢复单 Tab/Pane。

后续物理矩阵又完成：

- 受控 target 与 jump 分别在 alternate buffer、隐藏光标、mouse、focus、bracketed paste、
  OSC 颜色均活跃时被强制断开；同一 normal scrollback、可见默认光标、本地输入和后续重连
  均恢复，且没有迟到 `CONNECTED`。
- 普通 SSH fixture 通过物理方向键、Ctrl 组合键、Tab、粘贴、1 MiB 输入、持续大输出、resize、
  Pane 关闭、native close 可观测和重连输入；随后连接 HSL 与真实 ProxyJump 目标，形成连续不同
  服务器与直连/跳板路径的非继承证据。
- reconnect 保留旧 normal buffer 并建立新 generation；renderer 在旧 reset ACK 窗口被终止时，
  本地关闭输出只提交一次，Bridge 恢复后输入立即可用。
- 真实 `power-shell suspend` 覆盖挂起、唤醒、锁定与解锁：活跃 SSH 在同一应用进程内合法保留
  dirty 终端模式并继续接收目标输入；远端随后正常退出时才执行边界 reset，恢复 `ltty>`。
- 真实 tmux、vim、Helix 与 Codex TUI 在 ProxyJump 目标中完成进入、交互、resize 和返回同一
  shell；结合固定 xterm 6.0.0 的 mouse/focus/paste/颜色矩阵，证明修复没有禁用活跃 Session
  的标准 TUI 模式。复制选择沿用 1.3 已发布物理基线，相关实现未被本修复改写。

至此第二服务器、错误/断线、键盘/粘贴/mouse/focus/颜色、连续连接、Pane/Tab、renderer 与
挂起/锁屏矩阵均闭合，本方案提升为开发候选 `Verified`。后续正式 production 候选又完成
完整发布回归、签名与人工确认；`v1.4.0` GitHub Release 于 2026-08-19 发布，维护者于
2026-08-22 确认匹配的 production APP 已通过 AppGallery 审核并正式上架。

## 1.4 发布门禁

本方案不是一项新的用户功能，而是 1.4 必须关闭的终端正确性缺陷。执行顺序固定为：

1. ProxyJump 开发与日常验证已完成。
2. 本方案的失败基线、实现、自动化与物理机验收已完成。
3. 下一步可以从干净、已推送的精确提交准备 1.4 production 候选；日常 debug HAP 与上述证据
   不代替正式门禁。
4. 本缺陷已经在正式候选前关闭，不以“只影响 HSL”、“只是光标外观”或“新 Tab 没问题”延后。

## 非目标与停止条件

- 不在本项中升级 xterm、替换 renderer、重构全部 Terminal Surface 或重写快照格式。
- 不为低价值、未验证的终端序列扩张通用兼容框架；矩阵以 xterm 6.0.0 已支持、
  会跨 Session 影响核心输入输出的状态为限。
- 如果标准序列方案必须清空 scrollback、调用 xterm 私有 reset 或依赖一组时序延迟，
  停止该方案，重新比较有完成回执的类型化 Terminal Surface 操作。
- 如果 reset 会破坏活跃 Session 中的 vim、Helix、tmux、Agent TUI、鼠标或粘贴，视为
  所有权边界错误，不通过对单个程序加例外继续。
- 如果实际证据只支持某些连带模式，保留已证实矩阵并删除无证据项，不为计划完整
  维护无价值的 reset 序列。

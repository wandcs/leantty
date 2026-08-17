# 终端输入调度与大粘贴连续可用性

> 状态：实现已验证；正式候选复验待执行
>
> 当前归属：1.3.0 可靠性门禁
>
> 最近更新：2026-08-14
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 活动任务：[`next-work.md`](../next-work.md)

本文记录 SSH 终端大输入问题的上下文、实机证据、同类终端调研、产品决策和版本边界。
它不维护第二套执行清单；当前实施顺序和完成状态只由 `next-work.md` 决定。

## 一、问题与产品判断

LeanTTY 的正常终端输入链为：

```text
xterm onData
  -> WebView Bridge
  -> SessionViewModel
  -> SshClient.write
  -> native sshWrite
  -> 当前 Session 的单一 writer/FIFO
  -> russh ChannelWriteHalf
  -> 远端 PTY
```

粘贴不是独立传输协议。xterm 会把粘贴形成的终端输入交给同一 `onData` 路径，最终与键盘、
IME 和 TUI 输入共享 Session writer。因此产品必须保证的不是某个特定剪贴板尺寸，而是：任意
一次较大终端输入都不能让后续输入、resize、断开或重连永久失去处理机会。

这属于核心终端路径的正确性和可恢复性。根据“可靠是底线”和“失败不能表现为无响应”，
1.3.0 在冻结候选前必须闭合该问题。以下事项不是同一个必要功能：

- 对危险多行或控制字符粘贴进行确认，属于安全和易用策略；
- 仅因字节数较大而弹窗，属于可选的入口保护；
- 保证固定体积在固定秒数内传完，属于受网络、SSH window、远端读取速度和设备负载影响的
  性能指标，不能直接成为跨环境产品承诺。

## 二、当前实现与实机证据

1.3 收尾 smoke 使用受控 SSH fixture 检查了 512 KiB、随后 1 MiB 终端粘贴，以及粘贴后的普通 PERF
命令、resize、断开和重连。

诊断阶段观察到：

- russh 通用 `AsyncRead/copy` 写入路径以约 8 KiB 分块，30 秒内远端只收到 278,528 字节；
- 改用拥有型、窗口感知的 `data_bytes` 后，fixture 以约 32 KiB 分块收到完整 524,288 字节，
  内容一致；
- 1 MiB 样本也按 32 KiB 分块逐字节完整到达；仅调度让步和额外 10 ms 固定节奏都没有让随后
  命令到达；
- 随后的 37 个单字符事件进入 ArkTS，native 同步入队调用未报告拒绝，但 fixture 在粘贴完成后
  没有收到任何后续字节；一次性 control-callback 探针不足以稳定界定 writer 内部停在哪个 await。

完整产品 writer actor 回归随后证明 1 MiB、紧随短命令、resize、FIFO 和任务唤醒均正常，继续调整
块大小、固定睡眠或改写 `select` 不能解释真机差异。根因最终位于仓库专用 russh fixture：shell
channel 建立后，fixture 只在 `Handler::data` 处理输入，却没有消费同一 `Channel` 的 `wait()` receiver。
russh server 会先把每个 channel message 发入该 receiver，再调用 `Handler::data`；默认 100 项缓冲区
被此前 27 个输入检查消息、37 个粘贴准备消息和 32 个数据块占到 96 项，后续命令前 4 个字符填满
缓冲区，第 5 个字符在进入 handler 前阻塞。这与现场“1 MiB 完整、后续 4 字符后停住”精确一致。

fixture 现在持续排空 shell receiver，同时保留 SFTP channel 的独立所有权；对应回归发送超过默认
缓冲区的 120 个单字节消息后仍能处理短命令。产品侧保留单 writer/FIFO、32 KiB 有界
`data_bytes` 推进、完整 writer actor 回归，并监督 writer 任务，防止未来异常退出静默表现为输入
无响应；没有加入固定延迟、第二输入通道或新的粘贴状态。

2026-08-14，物理 ARM64 HAD-W32 在同一测试签名 HAP（SHA-256
`d0f9b20fffc2eb3cf0146629c875045908038b7445707a46511fdc136b81941d`）上通过完整
`transport-main-path`：1 MiB 逐字节匹配、648,000 字节持续输出、分屏 resize、输出后的普通输入、
显式关闭已连接 Pane、重连、重连后普通输入和远端正常结束全部通过。最终证据位于
`build/verification/ssh-large-input-main-path-final/`，attempt
`0fb3bbbbbc8d4d299b52a2612792e038`。该包仍是 diagnostic HAP，不是可发布或保留候选。

512 KiB 和 1 MiB 都只是稳定压力样本，不是 LeanTTY 宣布支持的最大尺寸，也不是要求普通用户
经常执行的工作流。

## 三、同类终端调研

本轮只采用官方文档、官方源码或项目维护记录，不以二手功能列表决定产品范围。

| 产品 | 已确认做法 | 可借鉴部分 | 不能直接推出的结论 |
| --- | --- | --- | --- |
| Ghostty | 提供不安全粘贴确认；应用启用 bracketed paste 时默认把该粘贴视为安全；粘贴策略、编码和写入队列分层 | 区分内容安全策略与底层 I/O；尊重远端应用的 bracketed paste 语义 | 没有证据表明它用固定大粘贴尺寸或时限定义可靠性 |
| iTerm2 | 普通 paste 和 slow paste 都分块，并在块之间留出可调间隔；官方列出 Quick Paste 的 1024 B/次与 10 ms 间隔参数 | 大输入不必作为一次不可分割写入；可以在块间恢复调度机会 | 固定 10 ms 是一个产品选择，不应未经测量照搬到 SSH 路径 |
| Windows Terminal | 默认对超过 5 KiB 和多行粘贴分别确认，并明确把避免连接程序处理剪贴板时终端无响应作为理由之一 | 入口确认可以减少误操作和意外超大输入 | 用户确认后仍需要可靠传输；弹窗不能修复 writer 饥饿 |
| Kitty | 默认确认危险控制码；另提供超过 16 KiB 时确认、替换换行或危险控制码等可组合动作 | “危险内容”和“体积很大”是不同风险，应分别判断 | 这些可配置动作不符合 LeanTTY 当前减少设置的方向，不能整套复制 |
| WezTerm | bracketed paste 生效时不再按终端配置改写粘贴换行 | 保持内容和远端应用语义正确 | 换行语义不等于 SSH 背压或 writer 公平性 |
| Alacritty | 维护记录明确修复过阻塞式 paste 导致终端冻结，以及 64 KiB 截断 | 不冻结、不截断是底层正确性，而不是高级粘贴功能 | 不能仅从修复记录推断其当前内部块大小或节流算法 |

来源：

- [Ghostty clipboard paste options](https://ghostty.org/docs/config/reference#clipboard-paste-protection)
- [Ghostty paste implementation](https://github.com/ghostty-org/ghostty/blob/dab1b105b932fecf155d2b6a66c79d8311f826ea/src/Surface.zig)
- [Ghostty close-surface action](https://ghostty.org/docs/config/keybind/reference#close_surface)
- [iTerm2 hidden paste settings](https://iterm2.com/documentation-hidden-settings.html)
- [iTerm2 session closing behavior](https://iterm2.com/documentation-preferences-profiles-session.html)
- [Windows Terminal paste warnings](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/interaction#paste-warnings)
- [Kitty paste actions](https://sw.kovidgoyal.net/kitty/conf/#opt-kitty.paste_actions)
- [WezTerm pasted newline semantics](https://wezterm.org/config/lua/config/canonicalize_pasted_newlines.html)
- [Alacritty changelog](https://github.com/alacritty/alacritty/blob/master/CHANGELOG.md)

共同规律不是“所有终端都弹窗”或“所有终端都固定限速”，而是两层职责：

1. 内容语义与安全层决定是否需要确认、过滤，以及是否尊重 bracketed paste；
2. 输入传输层保证顺序、背压、有界资源和事件循环连续可用。

本轮实机失败发生在第二层，不能用第一层的弹窗绕过。

Ghostty 和 iTerm2 也都把关闭 surface/session 作为独立产品动作，并按活跃进程决定是否确认。
`Ctrl+D` 则仍是发给远端 TTY/前台程序的输入，其是否退出取决于远端行规程和程序状态。因此 1.3
用 LeanTTY 现有 Pane 关闭确认验证本地断开，用受控 fixture 的普通 `ltty-exit` 命令验证远端
正常结束；不把 HDC 是否能稳定合成 `Ctrl+D` 误写为产品断开合同。

## 四、1.3.0 已确认方案

### 4.1 必须实现

- 保留当前 Session 的单一 writer 和 FIFO 顺序，不增加粘贴管理器、后台任务系统或第二套输入
  通道；
- 在 native writer 内把较大输入作为有界块推进，使调度器能在块之间处理已有的 resize、取消/
  断开等控制事件；
- 每块继续遵守 SSH window 和 russh 的背压，不通过无界缓存换取表面吞吐；
- 默认不加入任意固定睡眠。只有实机和受控 fixture 证明单纯有界分块仍会压垮远端读取方时，
  才根据测量引入最小等待；
- 不要求 WebView 判断“这是不是粘贴”。调度正确性应覆盖同一终端输入路径上的所有较大写入，
  避免输入来源形成新的分支和状态；
- 保留 UTF-8/终端字节顺序，不改写用户内容，不改变 bracketed paste 语义；
- 诊断完成后删除一次性大写入跟踪，除非它仍然满足有界、无内容、低噪声和明确运维价值。

具体块大小和使用 `data`/`data_bytes` 的选择是实现细节，必须由自动化背压用例和物理 PC 结果
决定，不在本文固化为用户合同。

WSL 回归已覆盖完整产品 writer actor，而不只直接调用 russh channel：使用与产品一致的 mpsc
输入/resize 接收器，发送超过 1 MiB 后立即排入短命令，验证任务唤醒、FIFO、resize 和后续输入。
该回归排除了产品 actor 调度假设；结合 russh server 消息顺序和 fixture 红/绿回归，最终只修复
fixture receiver 消费，并为产品 writer 增加异常退出监督。当前没有升级 russh 或重构 session
调度的证据，不继续实现这两条备选路线。

### 4.2 1.3.0 不做

- 不新增大粘贴弹窗、进度提示、取消按钮、慢速粘贴模式或相关设置；
- 不把 5 KiB、16 KiB、512 KiB 等竞品或测试阈值变成产品限制；
- 不承诺固定网络和服务器无关的完成秒数；
- 不为此升级成通用优先级队列、流量整形框架或可扩展输入管线；
- 不通过截断、丢弃后续输入或静默断开来恢复会话。

## 五、版本边界

| 版本 | 决定 | 范围 |
| --- | --- | --- |
| 1.3.0 | 必须完成 | writer 有界推进与公平调度、产品 writer 自动化、受控 fixture、物理 ARM64 PC 连续可用性，以及移除无长期价值的诊断探针 |
| 未来 MINOR，尚未排期 | 只在出现持续用户证据后重新评估 | 危险多行/控制字符粘贴确认；若评估，应优先采用无设置的默认行为，并对 bracketed paste 保持安全例外 |
| 当前无计划版本 | 不做 | 仅按字节数弹窗、用户可调块大小/延迟、独立 slow paste 模式和固定大粘贴 SLA |

“未来 MINOR”不是把粘贴确认加入既定 1.4 启动性能 milestone，也不授权实现。它只说明该体验议题
不会进入 1.3.0；若以后证据充分，必须先按产品原则重新评审并提升到当时的 `next-work.md`。

## 六、验证与完成证据

自动化至少证明：

- 多块输入逐字节一致、没有截断、重复或重排；
- 大输入之后的普通输入在同一 Session 到达 fixture；
- 远端停止读取时保持背压和有界内存，恢复读取后继续；
- 背压期间 resize 与取消/断开具有有界结果；
- writer 关闭、远端断开和后续重连不会遗留不可恢复状态；
- 当前小输入主路径没有新增可见延迟或来源分支。

物理 ARM64 HarmonyOS PC 在同一个保留候选上至少证明：

- 512 KiB 压力样本完整到达并匹配；
- 随后普通命令在同一 Session 获得可观察响应；
- 分屏 resize、断开和重连仍可用；
- 键盘、IME、选择/复制、搜索和主流 TUI 的最小 smoke 没有因 writer 改动回归。

场景可以设置防止自动化无界等待的测试上界，但完成结论不把该上界宣传为产品性能 SLA。

## 七、停止与重新评审条件

如果有界 writer 推进必须改变终端内容、绕开 SSH 背压、引入无界缓存、破坏小输入延迟，或必须
建立第二套 Session/输入所有权，停止当前实现并重新评审。若问题最终只能由升级 russh 解决，先用
最小复现确认上游版本的行为和依赖影响，再按 1.3 可靠性修复评估升级；不能为了追逐竞品功能扩大
为通用粘贴系统。

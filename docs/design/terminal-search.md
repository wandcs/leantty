# 终端 scrollback 搜索技术方案

> 状态：Verified
>
> milestone：1.2.0
>
> 发布状态：GitHub/AppGallery 已发布；AppGallery 于 2026-08-13 审核通过并上架
>
> 更新日期：2026-08-13
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：已进入 [`next-work.md`](../next-work.md)；可以按其中依赖顺序切片实现

## 用户问题与目标

开发和运维用户经常需要在当前终端输出与 scrollback 中定位错误、命令结果、路径或
标识符。LeanTTY 当前没有搜索路径，用户只能滚动目视查找或依赖远端工具；对于已经
输出但仍在当前内存缓冲区中的内容，这是桌面终端自身应提供的高频能力。

目标是在当前 Pane 的 Terminal Surface 内提供一个短生命周期、键盘优先的搜索交互，
不改变 Session、远端字节流、终端内容或其他 Pane 的状态。

## 拟议最小范围

- 打开搜索、输入普通文本、跳到下一处/上一处、关闭并恢复终端焦点。
- 搜索当前 Terminal Surface 的可见内容和内存 scrollback。
- 显示查询、当前匹配位置或无结果状态；反馈不能只依赖颜色。
- 搜索状态只属于当前 Pane/Terminal Surface，不持久化、不跨 Session 共享。
- 支持中文、Unicode、宽字符、多行输出和有界的大 scrollback。

## 非目标

- 跨 Tab、跨 Session、跨重启或远端文件搜索。
- 正则表达式、模糊搜索、搜索历史、结果列表、索引服务或遥测。
- 搜索命令历史、日志、已销毁 Session 或应用持久快照以外的数据。
- 命令面板、自定义快捷键或为了搜索建立通用覆盖层框架。

## 已确认所有权与 Bridge 边界

当前实现已经提供所需的局部所有权，不新增 Search Model、Session 字段或 App 全局
状态：

```text
Index exact shortcut router
  → active PaneRuntime.surface.openSearch()
    → current TerminalBridge: N2W CONTROL searchOpen, empty payload
      → this terminal.html DOM: input + SearchAddon + result feedback
        → W2N CONTROL searchState, payload open/composing/closed only

physical Escape while search owns focus
  → active PaneRuntime.surface.closeSearch()
    → current TerminalBridge: N2W CONTROL searchClose, empty payload
      → this terminal.html closes search and restores xterm focus
```

- 每个 `PaneRuntime` 由稳定 `paneId` 标识，独占一个 `SessionViewModel` 和一个
  `TerminalSurfaceController`；每次 ArkWeb 页面 attach 才由该 controller 创建当前
  `TerminalBridge`。因此 `activePaneRuntime()` 足以把打开意图送到唯一当前 Pane。
- ArkTS 只路由精确 `Ctrl+Alt+F`，以及搜索实际占用当前 Surface 时的物理 `Escape`。
  Bridge 的 N2W `searchOpen/searchClose` payload 必须为空；Web 只以 W2N `searchState`
  回报 `open/composing/closed`。Native 与 Web 双侧 allowlist 都拒绝错误方向、channel、非法 payload
  和未知 kind。
- 查询文本、组合输入、匹配、当前位置、结果总数和 addon 实例都只存在于
  `terminal.html` 当前页面。除浮层的 `open/closed` 所有权状态外，它们不经过 W2N Bridge，不进入 `SessionViewModel`、
  `SshClient`、SSH Transport、AppStorage、Preferences、日志、终端字节流或 framebuffer
  snapshot。无需新增搜索结果 Bridge kind。
- 搜索输入获得 DOM focus 后，xterm textarea 不再接收查询按键；精确打开 chord 在
  ArkUI 被消费。HarmonyOS 的物理 Escape 不会稳定进入 ArkWeb DOM，因此只有在当前
  Surface 已报告搜索打开且未处于输入法组合时，ArkUI 才消费 Escape 并发送 `searchClose`；
  组合期间的第一个 Escape 仍交给输入法。关闭后页面调用
  `term.focus()` 并回报 `closed`。远端
  只可能观察既有的终端 focus-out/focus-in 报告，不会收到查询、Enter、Tab 或 Escape。

生命周期固定如下：

- 当前 Pane 收到 native `blur`、窗口 blur、normal/alternate buffer 切换、Pane/Tab
  切换或关闭时，Web 侧关闭搜索并清除查询与 decorations。Tab 失活路径已经对其所有
  Pane 调用 `requestBlur()`，双 Pane 焦点恢复也会 blur 非活动 Pane。
- warm Tab 仍挂载时已经因 blur 关闭搜索；后续淘汰和 `TerminalSurfaceController.detach()`
  不保留任何搜索状态。
- ArkWeb renderer process 退出会递增 `PaneRuntime.generation` 并重建 WebView；新页面
  总是从搜索关闭状态开始，旧页面的 port 和 DOM 不能恢复查询。WebGL 在同一页面内降级
  到 DOM renderer 不销毁 Terminal 实例，搜索可继续由 addon 重画。
- framebuffer capture/restore 只保存终端内容与模式，不保存 DOM、selection decoration
  或查询。恢复完成后搜索仍关闭；持续 SSH 输出继续走既有 binary output/ACK 路径。

这一路径没有跨 Pane 可寻址的搜索消息，也没有 W2N 查询或搜索结果，因此迟到状态消息不能
选择另一 Pane、修改 Session 或驱动系统效果。Native 与 Web parser 都在 dispatch 前
校验 `searchOpen/searchClose/searchState` 的方向、CONTROL channel 和封闭 payload；协议测试覆盖未知 kind、错误
方向/channel 和非法 payload。Surface detach 会先关闭旧 port、移除回调、清除搜索所有权并清除排队的
打开意图，再递增 `PaneRuntime.generation`，旧 WebView 消息不能进入替代 Surface。

## 已确认交互契约

搜索采用当前 Pane 内、Terminal Surface 右上角的紧凑浮层，不改变终端网格、PTY
尺寸或远端程序布局。浮层与其查询状态由当前 Surface 独占；双 Pane 时只出现在发起
搜索的 Pane 中，不增加 App Shell 全局搜索状态，也不允许拖动、自定义位置或自定义
快捷键。

| 用户意图 | 固定键盘路径 | 确定行为 |
| --- | --- | --- |
| 打开或重新聚焦搜索 | `Ctrl+Alt+F` | 打开当前 Pane 的搜索条并聚焦查询输入；已打开时重新聚焦并全选现有查询，不切换开关 |
| 下一处 | `Enter` | 查询输入未处于输入法组合时跳到下一处；按钮获得焦点时执行该按钮 |
| 上一处 | `Shift+Enter` | 查询输入未处于输入法组合时跳到上一处 |
| 关闭 | `Escape` | 输入法组合期间先交给输入法取消组合；组合结束后的 `Escape` 关闭搜索、清除短期查询与高亮并恢复原活动 Pane 的终端焦点 |
| 遍历控件 | `Tab` / `Shift+Tab` | 输入法组合结束后在查询、上一处、下一处、关闭之间正向或反向循环；不进入远端 PTY |

查询输入法组合期间，`Enter`、`Shift+Enter`、`Escape` 和 `Tab` 先由输入法处理，搜索
只在 `compositionend` 后使用已提交文本刷新结果。关闭搜索保留当前匹配所在的滚动
位置，不自动回到底部；再次打开从空查询开始，不保存历史，也不从终端 selection
自动填充查询。

采用右上角浮层而不是 Pane chrome 或 App Shell，是因为搜索对象和生命周期都属于
Terminal Surface；不重排网格可以避免搜索本身触发 PTY resize。临时遮挡少量右上角
内容是明确取舍，用户关闭后仍停留在当前匹配处。

### selection、指针与终端副作用所有权

- 空查询不会触碰已有 terminal selection。第一次非空查询由官方 SearchAddon 从 active
  buffer 顶部查找，并临时把当前匹配写入 xterm selection；这是 addon 导航下一处/上一处
  的游标，不把原 selection 当成查询，也不经过 Bridge。清空查询、关闭搜索、buffer 或
  主题切换时，同时清除这一份搜索拥有的 selection，不能把已关闭搜索的匹配留给后续
  `Ctrl+C` 或 secondary action。
- 在搜索打开时点击终端内容，会在 capture 阶段先关闭搜索并释放其 selection，但不
  `preventDefault` 或停止事件；同一次指针事件随后继续进入现有 xterm selection、链接和
  mouse-reporting 路径。点击搜索条自身不进入 terminal container。
- 搜索打开期间 secondary action 由搜索浮层拥有，不能复制当前匹配或把系统剪贴板粘贴
  到远端；终端区域的右键按下会先按上一条关闭搜索，随后才恢复既有“有选区复制、无
  选区粘贴”语义。查询输入内的 `Ctrl+C` 由 DOM 文本输入处理；终端重新取得焦点后，
  `Ctrl+C` 仍按既有规则在有选区时复制、无选区时发送中断。
- OSC 52、HTTP(S)/OSC 8 link provider、mouse tracking 和 alternate-buffer wheel handler
  不读取搜索状态，也不增加平行分支。搜索 decorations 不处理指针；终端区域的原事件
  在搜索关闭后继续使用既有 modifier、拖动阈值和 mouse-reporting 规则。
- 查询变化不预先 `scrollToTop()`。清除 selection 后，SearchAddon 从 buffer 顶部选择
  第一处并只在匹配不在 viewport 时滚动；后续导航与用户滚轮继续使用 xterm 的同一
  viewport。关闭保留当前 viewport，不回到底部。
- 搜索颜色来自当前主题。主题变化时关闭短生命周期搜索、释放 selection 并恢复终端
  焦点，再应用新主题，避免旧 decorations 保留上一主题的内联颜色。
- framebuffer snapshot 仍只由 SerializeAddon 生成；查询 DOM、decorations 和 selection
  都不进入序列化内容，因此搜索不能改变恢复字节或在 renderer 重建后复现系统副作用。

### 快捷键冲突基线

- LeanTTY 当前精确路由占用 `Ctrl+Shift+T/D/W`、`Ctrl+Tab`、`Ctrl+Shift+Tab`、
  `Ctrl+Alt+Left/Right` 与字号快捷键；`Ctrl+Alt+F` 没有内部冲突，并与已有 Ctrl+Alt
  工作区导航处于同一精确 modifier 路由族。
- `Ctrl+F` 继续完整传给远端，因为它常被 shell、编辑器和 TUI 使用。只消费精确的
  `Ctrl+Alt+F`；搜索关闭后所有未命中按键仍走原终端输入路径。
- Windows Terminal 默认使用 `Ctrl+Shift+F`，搜索条位于当前 Pane 右上角；Ghostty
  GTK 的 scrollback 搜索也使用 `Ctrl+Shift+F`，并以 `Enter` / `Shift+Enter` 导航。
  LeanTTY 复用这组桌面终端惯例，但不引入它们的自定义快捷键或可拖动位置。
- 2026-08-06 的实现前 HDC 注入只观察了“未出现系统搜索或对话框”，没有记录应用收到
  的最终 F KeyEvent，因此不足以证明 chord 未被抢占。2026-08-07 的实现后诊断使用同一
  物理 PC 对照：`Ctrl+Shift+D` 能进入现有 ArkTS 路由并创建双 Pane；`Ctrl+Shift+F`
  只向应用交付 Ctrl 与 Shift，F 在应用入口前消失，原始左 Shift 序列还出现输入法切换
  提示。用户随后用物理键盘确认该 chord 会触发输入法简繁切换，因此 `Ctrl+Shift+F`
  已被裁剪且不保留兼容别名。唯一入口改为 `Ctrl+Alt+F`；HDC 三键组合和物理键盘都能
  正常打开产品搜索。中英文逐字输入和远端 TUI 透传仍按最后人工边界完整验收，不能
  由一次打开成功替代。
- 2026-08-08 的 1.2 最终候选验收确认：鸿蒙飞书在前台或后台运行时会抢占
  `Ctrl+Shift+W`，关闭飞书后 LeanTTY 的关闭 Pane 快捷键正常。这是第三方应用的全局
  快捷键冲突，不是 LeanTTY 或 HarmonyOS 系统冲突；不为它增加替代组合、KeyUp/Pre-IME
  拦截或控件级快捷键。后续物理机验收须先关闭飞书；若触发后前台切换到飞书，应记录为
  验收环境未清理并重试，不进入 LeanTTY 产品缺陷排查。

参考：[Windows Terminal Search](https://learn.microsoft.com/en-us/windows/terminal/search)、
[Ghostty 1.3.0 scrollback search](https://ghostty.org/docs/install/release-notes/1-3-0)。

## 已确认匹配语义

- 查询是单行普通文本，固定使用 `regex: false`、`wholeWord: false` 和
  `caseSensitive: false`；不显示模式开关。英文字母忽略大小写，中文和无大小写概念的
  Unicode 字符按原字符匹配。查询不做 Unicode normalization，因此组合字符与预组合
  字符可以是不同文本。
- 空字符串不执行搜索，显示紧凑 `0/0`，清除当前搜索高亮并禁用上一处/下一处；其
  可访问说明为 `Type to search`。只包含空格的非空查询仍是有效普通文本；HTML 单行
  输入不接受 CR/LF。
- 非空查询没有匹配时同样显示 `0/0`，可访问说明为 `No results`，反馈不能只依赖颜色；
  有匹配时显示 `当前序号/总数`。结果计数达到 addon 的安全上限时显示有界计数而不
  伪造精确总数，具体上限在依赖审计中冻结。
- 第一次提交查询从 active buffer 顶部开始选中第一处；`Enter` 向 buffer 底部查找，
  `Shift+Enter` 向顶部查找。两个方向到达边界后循环；只有一个结果时仍保持该结果，
  不短暂显示无结果。
- 搜索可以跨 xterm 的软换行，因为软换行仍是一条逻辑终端行；不能跨显式 CR/LF
  形成的硬行。中文、宽字符和 emoji 由 xterm cell 到字符串的官方映射定位，不按显示
  列数切割查询。
- 只搜索 `term.buffer.active`。normal buffer 活跃时覆盖其可见区与内存 scrollback；
  alternate buffer 活跃时只覆盖当前 alternate screen，不搜索被隐藏的 normal buffer。
  normal/alternate buffer 每次切换都关闭搜索并清除查询与高亮，避免把旧坐标带到另一
  个 buffer；切回 normal 后用户可重新打开搜索访问原 scrollback。

这些语义与 xterm 6.0.0 对应 search addon 的字面量匹配、双向回绕、软换行合并、
active buffer 和 CJK/emoji cell 映射一致；不承诺跨硬行或跨 buffer 搜索。

参考：[xterm.js 6.0.0 search addon API](https://github.com/xtermjs/xterm.js/blob/6.0.0/addons/addon-search/typings/addon-search.d.ts)、
[search engine](https://github.com/xtermjs/xterm.js/blob/6.0.0/addons/addon-search/src/SearchEngine.ts)。

## 已确认依赖基线

采用 xterm.js 官方 `@xterm/addon-search@0.16.0`，与仓库已锁定的
`@xterm/xterm@6.0.0` 来自同一个 `6.0.0` 标签。应用代码只调用公开的 `SearchAddon`、
`findNext`、`findPrevious`、`clearDecorations` 和 `onDidChangeResults`，不自行遍历
xterm 私有 buffer 数据结构，也不增加搜索索引或第二套匹配实现。实现测试同时发现：
该锁定版本的 addon 在启用 decorations 与结果计数时内部调用 xterm 6.0 的 proposed
`registerDecoration`，因此 Terminal 必须设置 `allowProposedApi: true`；这是官方 addon
当前实现的受控依赖，不是 LeanTTY 直接调用 proposed API。版本必须继续精确锁定，并由
Web 测试和真机 renderer 门禁防止上游内部契约漂移。

审计结论：

- 来源为 `xtermjs/xterm.js` 官方仓库与 npm 包；固定版本 `0.16.0`、MIT 许可证、npm
  integrity `sha512-9OeuBFu0/uZJPu+9AHKY6g/w0Czyb/Ut0A5t79I4ULoU4IfU5BEpPFVGQxP4zTTMdfZEYkVIRYbHBX1xWwjeSA==`。
- HAP 只需打包 UMD `lib/addon-search.js`。npm 原文件为 78,826 bytes；构建脚本移除
  source-map 注释后的实际资源为 78,786 bytes、SHA-256
  `BEADC1A87F56C24068389EDCEF219988FADE893B7836C95015157B3C0D812B70`，相对原
  5,617,480-byte rawfile 集合增加 1.40%。npm tarball、source map、TypeScript 源码和
  ESM bundle 都不进入应用包；最终 HAP 的实际压缩增量在干净 ARM64 构建时复测。
- UMD bundle 暴露 `SearchAddon` 全局，不含 fetch、XHR、WebSocket、Worker、WASM、
  动态 import 或运行时 require。唯一 URL 文本是许可证注释，不产生网络请求；现有
  CSP 和全本地 rawfile 模型不需要放宽。
- addon 使用与当前 xterm 6、fit/serialize/web-links/webgl addon 相同的浏览器构建
  目标，只依赖 Terminal 公开 API、DOM decoration 和 timer。xterm 上游只正式列出主流
  浏览器，不单独声明 ArkWeb；因此这里确认的是低风险的源码与打包兼容，不把它写成
  已验证的 ARM64 ArkWeb 行为。依赖落地后必须在物理 PC 上证明加载、查询、高亮、持续
  输出和 renderer 重建，失败则撤回 addon 而不是增加兼容框架。
- 已把 `@xterm/addon-search` 加入 `tools/web-terminal/package.json` 与 lockfile，由
  `build.mjs` 只复制 `addon-search.js`，并同步 manifest、README、现有公共源码检查和
  `docs/THIRD_PARTY_NOTICES.md`。干净 `npm ci`、资源重建和 Web terminal policy 测试
  已通过；`terminal.html` 已加载该本地资源，并由当前 Surface 独占搜索实例与短期状态。

参考：[xterm.js 6.0.0 release](https://github.com/xtermjs/xterm.js/releases/tag/6.0.0)、
[`@xterm/addon-search` package](https://github.com/xtermjs/xterm.js/tree/6.0.0/addons/addon-search)。

## 已确认物理 PC 基线

2026-08-06 在物理 ARM64 HarmonyOS PC 上建立搜索实现前基线：设备为 HAD-W32，系统为
OpenHarmony 6.0.2.130。设备安装包报告 `1.1.0 / 1001000`；`v1.1.0` 到 `v1.1.1`
在 Terminal、ArkTS、Web terminal 和 SSH core 路径没有运行时代码差异，只有版本号和
发布文档变化，因此该结果只作为两版共同的搜索前终端运行时基线，不冒充 1.1.1 包体
身份。

当前版本尚无搜索实现，因此无法在“修改实现前”测量搜索打开、逐字输入和跳转本身。
基线把可实际观察的当前 Terminal Surface 行为与后续搜索测量协议分开：

- 快捷键冲突结果见上文；实现前 `Ctrl+Shift+F` 基线已由原始 KeyEvent 与物理键盘
  证据推翻，最终固定的 `Ctrl+Alt+F` 已通过 HDC 和物理键盘打开验证。
- 仓库专用、不会进入 HAP 的 russh fixture 通过真实
  `SSH → Rust/N-API → ArkTS/WebMessagePort → xterm` 路径，生成每次 12,000 行、每行
  80 字符的有界输出；这会超过 xterm 现有 10,000 行 scrollback 上限。
- 11 次正式尝试得到 10 次完整样本，全部为 100% 计数完整；1 次失败定位为 HDC 快速
  文本注入把 `prepare` / `run` 交错成畸形命令，服务端未生成输出，已排除并只重试一次。
- 前 6 次同协议样本的现有输出解析耗时为 min 3236.9 ms、P50 3268.3 ms、P95
  3335.8 ms、max 3353.5 ms；首帧后耗时为 min 3252.2 ms、P50 3295.25 ms、P95
  3357.25 ms、max 3373.4 ms。该区间包含 HDC 提交测试端 `run` 命令的时间，不是纯
  renderer 指标，也不是尚不存在的搜索延迟。
- 为避免把 handler 内排队误写成持续流，fixture 最终使用 russh `Session::handle()` 在
  handler 返回后异步发送 16 KiB chunk，并在 chunk 间等待 5 ms。额外 3 次 12,000 × 80
  持续流样本均为 100% 完整，解析耗时 min 4516.9 ms、P50 4576.2 ms、P95
  4594.29 ms、max 4596.3 ms；首帧后耗时 min 4539.0 ms、P50 4597.2 ms、P95
  4619.88 ms、max 4622.4 ms。每次结束时 Bridge 均为 `queued=0`、`inFlight=0`、
  `dropped=0`；这些结果仍包含测试端 `run` 输入时间。
- 相关主进程、GPU 和 ArkWeb renderer 总 RSS 从约 444.3 MiB 增至 506.1 MiB，增量
  约 61.8 MiB；其中一个 renderer 增加约 59.4 MiB，主进程增加约 2.6 MiB。这里只记录
  分布与环境，不据此设置任意百分比或固定时限。
- 测试完成后已退出临时 SSH、删除临时 `known_hosts` 记录、关闭一次性 Tab、移除 HDC
  端口映射、停止 fixture、删除随机凭据目录并恢复设备屏幕超时。

最小搜索切片落地后、任何性能优化前，在同一设备与相同 12,000 × 80 buffer 形状上，
以 Web 侧 `performance.now()` 分别记录打开空搜索、逐字查询、下一处、上一处、首尾
回绕、无结果、持续输出期间查询和关闭的 warm-up 与分布；同时记录总结果数、完整性、
renderer、内存、失败域和重试次数。第 4 节用这些分布与本基线比较，再决定是否需要
局部优化。

## 2026-08-07 最小实现真机证据

本轮使用 `dev-pc.ps1` 构建并安装 ARM64 调试 HAP；切换到唯一 `Ctrl+Alt+F` 候选后的
签名包为 9,906,477 bytes，SHA-256
`7B23AED6036EBF72DA0008C49B96132703CCB0EB667E4FB429F461E34B7847D9`。设备仍为 HAD-W32。
为隔离上述快捷键注入限制，调试构建通过既有 `ACCEPTANCE_TESTS` 源码注入机制增加
`Acceptance: Open Search` 菜单项；它只调用生产 `activePaneRuntime().surface.openSearch()`，
不实现查询、匹配或第二条 Bridge 路径，release 构建继续自动裁剪所有 acceptance 源码。
正式四点菜单后来增加了同一生产 Search 入口，因此该临时验收项已删除，当前调试构建直接
复用正式入口。

证据保存在 `C:\tmp\leantty-1.2-search-ui-20260806`：

- `08-search-open` 证明当前 Surface 的 N2W Bridge 能打开紧凑搜索条，搜索输入获得焦点，
  Terminal input 同时失焦；`09-search-match` 显示 `ltty` 的 `1/1` 和可见高亮。
- `10-search-no-result` 显示非颜色文字 `No results`；搜索期间终端提示符未改变。
  `11-search-closed` 证明 Escape 关闭后只剩 Terminal input 且焦点恢复；随后普通输入再次
  进入终端并在取证后清理。
- `13-search-right-pane` 证明双 Pane 时搜索只出现在活动右 Pane；切到左 Pane 后
  `14-pane-switch-layout` 记录 `searchNodes=0`、`focusedTerminalInputs=1`。
- 左 Pane 两个匹配的 `15` 到 `18` 截图依次记录 `1/2 → 2/2 → 1/2 → 2/2`，覆盖
  Enter 下一处、向下回绕和 Shift+Enter 反向回绕。
- `20-ctrl-alt-f-product` 通过系统 UI 测试框架把 Ctrl、Alt、F 作为一个 chord 注入，
  不经过 acceptance 菜单即记录 `searchNodes=1`、`focusedSearchInputs=1`，证明该候选能
  到达同一产品搜索链；用户随后确认物理键盘 `Ctrl+Alt+F` 同样正常打开搜索。中英文
  逐字输入仍是独立未闭合门禁。
- 测试后关闭新增 Pane，恢复单 Pane，并成功释放设备屏幕常亮租约。

这些证据只完成单 Pane 最小查询、无结果、导航、焦点和双 Pane 隔离的开发期主路径；
不能替代物理键盘与中英文输入法、大 scrollback/持续输出、selection/链接/TUI、Tab/warm
淘汰、renderer 重建和正式候选门禁。

同日的所有权冲突实现复核确认：固定版本 SearchAddon 通过 xterm selection 标识当前匹配，
而 `clearDecorations()` 不释放该 selection；Terminal Surface 因此显式记录并释放搜索拥有的
selection。自动化覆盖关闭/清空、终端指针事件顺序、secondary action、主题切换、滚动、
buffer 切换、快照边界和既有 OSC/link/mouse policy，增量 ARM64 HAP 构建通过。测试机仍
保留 `wandc@192.168.1.4` 标签且无法客观确认 SSH 已断开，本轮没有用重装中断它；以下
交互继续保留为物理 PC 门禁。

Web 自动化矩阵直接在固定版本 xterm 的真实 normal/alternate buffer 上运行官方
SearchAddon，不引入浏览器、模拟搜索引擎或新增依赖。用例覆盖普通文本、空查询、无结果、
多个结果、双向回绕、大小写、中文双宽字符、Unicode 代理对、跨软换行匹配、2,000 行
scrollback、持续输出后的结果刷新和 80 次快速重复查询；持续输出使用条件等待而非固定
延时。该矩阵连续 5 次运行均通过。

ArkTS/Bridge 自动化覆盖唯一 `Ctrl+Alt+F` modifier 组合、活动 Pane 稳定 ID、双 Pane 与
跨 Tab 活动 Pane 隔离、查询 DOM 不调用 terminal/Bridge 输入 API、关闭与焦点恢复、Pane/
Tab 关闭、warm Tab 淘汰、renderer generation 重建、排队打开意图取消，以及未知、错误
方向/channel、非空 payload 和旧 port 消息拒绝。

既有 Web/ArkTS 回归继续覆盖 selection-aware `Ctrl+C` 与 secondary action、系统剪贴板、
OSC 52、HTTP(S)/OSC 8 链接 modifier、TUI mouse-reporting bypass、alternate-buffer wheel、
SerializeAddon 快照恢复、字体缩放、fit/resize、binary output ACK 和普通终端输入。搜索用例
同时断言查询 DOM 不调用 Bridge/terminal 输入 API、快照不含查询或 decorations，并在终端
指针事件交还前释放搜索拥有的 selection；这些是自动化边界证据，不替代后续物理 PC 回归。

## 2026-08-07 开发切片验证记录

本节是本功能技术方案中的一次开发证据记录，不是第二份 TODO 或发布门禁。各短提交按
受影响事件链选择聚焦门禁；后续汇总复核绑定精确提交，不能倒推为尚未执行的物理场景：

| 提交切片 | 受影响事件链 | 聚焦门禁 |
| --- | --- | --- |
| `9a058a8` | addon/asset、快捷键、Bridge、Surface 搜索 UI 与最小真机路径 | Web policy、ArkTS unit、增量 ARM64 开发包与下述 HAD-W32 场景 |
| `645af8c` | Surface blur 时排队打开意图取消 | Web lifecycle policy、ArkTS Bridge/Surface unit |
| `34d65d0` | selection、secondary action、主题、指针与 viewport 所有权 | Web terminal policy、增量 ArkTS/资源构建 |
| `2e16ccc` | `searchOpen` 双向 parser、allowlist 与畸形消息拒绝 | Web parser policy、ArkTS protocol unit |
| `bd352de` | 真实 SearchAddon 查询矩阵 | `npm test`，含连续 5 次稳定运行 |
| `ce7fb55` | Pane/Tab、warm 淘汰与 renderer generation 所有权 | Web policy、ArkTS Pane/interaction unit |
| `2c90fd9` | 自动化覆盖说明 | 文档链接/状态核对与 `git diff --check` |
| `a380b6a` | npm 锁、资产重建、manifest/许可证/在线资源、release marker 与 ARM64-only | 锁定安装、资产零差异、Web policy、build-workflow/public-source policy |
| `16b7486`、`7b41ca0` | 固定 addon 的 Gitleaks 误报与 8.24 配置兼容 | Gitleaks 8.24.3 同版本红绿复现及 Public Checks |
| `93a924c` | 搜索面板与终端指针事件边界 | Web policy 红绿回归、增量 ARM64 开发包与 HAD-W32 实机点击路径 |

本地汇总复核结果：

- 在 `a380b6a` 上运行 `npm ci --ignore-scripts`、`npm run build`、指定资产路径的
  `git diff --exit-code` 和 `npm test`：锁定安装为 6 个包、0 个漏洞，重建后的 lockfile、
  manifest 与 rawfile 零差异，font/search/terminal policy 全部通过。
- 同一产品树运行 DevEco `hvigorw --mode module -p module=entry@default test`：
  `Tests run: 74, Failure: 0, Error: 0, Pass: 74, Ignore: 0`；结果位于忽略目录
  `entry/.test/default/intermediates/test/coverage_data/test_result.txt`。随后运行
  `tools/dev-build.ps1`，增量 ArkTS/资源主路径通过。后续两个 Gitleaks 提交没有修改产品
  输入，因此没有重复构建或安装 HAP。
- `tools/test-build-workflows.ps1` 通过 release 验收标记拒绝、许可证接线和唯一
  `arm64-v8a` 约束；`tools/check-public-source.ps1` 通过 193 个源码文件；
  `git diff --check` 退出 0。这些命令只输出控制台结果，没有伪造保留候选证据。
- Gitleaks 8.24.3 对同一 9 提交范围的红绿复现先得到 1 个
  `addon-search.js:generic-api-key` finding 和退出码 2；把全局表从该版本忽略的
  `[[allowlists]]` 改为兼容的 `[allowlist]` 后，同版本、同范围报告 `no leaks found`、
  退出码 0。GitHub Public Checks run
  [`31140251704`](https://github.com/wandcs/leantty/actions/runs/31140251704) 随后在
  `7b41ca0` 上通过 Secret scan、public-source/build-workflow、Web 锁定重建/policy 以及
  Rust fmt/clippy/core tests。
- 设备开发证据仍只对应上文 HAP SHA-256
  `7B23AED6036EBF72DA0008C49B96132703CCB0EB667E4FB429F461E34B7847D9`，保存在
  `C:\tmp\leantty-1.2-search-ui-20260806`；29 个 screenshot/layout 文件覆盖已明确列出的
  最小主路径。它不因后续自动化通过而晋升为未执行场景的物理验收。
- 继续验证所有权冲突时，第一版实现暴露了一个实机缺陷：搜索面板是
  `terminal-container` 的子节点，容器 capture 监听器把点击查询输入也当作终端点击，先
  关闭搜索再把后续按键交给远端。`93a924c` 在关闭搜索前排除 `search-panel` 后代事件，
  并增加先失败、修复后通过的 Web policy 回归。修复树经 `dev-pc.ps1` 生成 9,906,460-byte
  ARM64 调试 HAP，SHA-256
  `E5BFE505A0D3978132582EA1BD067474572B2FE65DB34C11CFF0568860A2F52F`。
- 修复后的 HAD-W32 通过真实 SSH fixture 验证：点击查询输入后搜索保持打开，`FIXTURE_OK`
  显示 `1/1` 且 Terminal input 仍失焦；随后同一 Surface 的终端点击关闭搜索、释放匹配
  selection 并恢复 Terminal input 焦点。证据保存在
  `C:\tmp\leantty-1.2-search-ownership-20260807`；测试后已退出 SSH、删除临时
  `known_hosts` 记录、移除 HDC 反向端口、停止 fixture、删除随机凭据目录并恢复屏幕超时。

本轮没有运行 `tools/test-regression.ps1`、`tools/verify-pc.ps1` 或完整命名物理矩阵；它们
仍只用于正式候选。selection/link/TUI、输入法、大 scrollback、持续输出和 renderer 重建
等剩余设备行为在当时继续保留在 `next-work.md` 的最终物理机矩阵，不能由这里的开发期记录代替。

## 2026-08-08 1.2 保留候选验收

正式候选来自已推送提交 `59a8cbfb50f7c67931881169a8695a303f22a718`、tree
`9b3a4437058d27f621bb41c1b0b5c04b90d0be16`；测试签名 ARM64 HAP 为 10,261,825 bytes，
SHA-256 `3f9e20b195d1353fdd2f59eb2134dbafb018d9baeac06b775dc0f68cbbf9119b`。保留 manifest 和
软件门禁位于本机 verified-candidate store；软件门禁覆盖 Web policy、77 项 ArkTS、Rust
format/Clippy/core/native/fixture tests、干净 ARM64 构建、安装和启动。

同一候选在 HAD-W32（USB、`arm64-v8a`）上的正式搜索证据位于
`C:\tmp\leantty-1.2-final-search-retained-20260808-rerun2\device-terminal-search.json`：

- 结果为 `device-behavior / acceptance / passed`，候选和 harness 都记录 commit/tree，
  candidate 由保留库解析而不是显式诊断 HAP；五个命名阶段总耗时 509,955 ms。
- `open-close-focus`、逐字 `l → lt → ltt → ltty`、空/无结果、两个结果的正反向回绕、
  双 Pane、跨 Tab、30 秒 warm 淘汰和 window/renderer 生命周期全部通过。右 Pane 不读取
  左 Pane scrollback，新 Tab 不读取旧 Tab 查询，renderer 重建后查询不复活。
- 每个阶段保留 layout/截图和阶段耗时；最终搜索关闭、单 Tab/单 Pane恢复、Terminal input
  焦点恢复、屏幕常亮租约恢复，cleanup 为 `passed`。
- 早期诊断记录曾把隐藏 warm Surface 当作活动 Pane，并把清理误判为失败；修正 detector 后
  的生命周期单项通过，最终保留候选全矩阵也一次通过。旧失败 JSON 仍保留，未覆盖或改写。

自动化和真机注入共同覆盖普通文本、Unicode/宽字符、软换行、大 scrollback、持续输出、
normal/alternate buffer、selection/clipboard/OSC/link/mouse policy、resize 与 renderer
重建；HDC chord 证明生产 `Ctrl+Alt+F` 路由，但证据明确声明它不能替代真实物理键盘和
中英文 IME。

## 2026-08-08 搜索按钮视觉收敛

搜索条保持 344px、26px 按钮和既有事件所有权，只调整三个图标按钮的局部结构与表现：
Previous/Next 进入语义 `group`，共用一条外框并以 1px 中线分隔；Close 保持独立外框和
额外 2px 间距。没有把三个动作合成一个控件：前后导航属于同一任务，Close 是退出边界。
三者删除浏览器 `title`，改用同一 300ms 深色 Tips 显示 `Shift+Enter`、`Enter`、`Esc`；
无障碍名称同时包含动作和键位。空查询时 Previous/Next 只用主题 border token 弱化图标，
不降低节点 opacity，因此禁用态 Tips 仍保持完整对比度。

Web terminal policy 的结构契约先按旧 DOM 失败、实现后通过；测试同时锁定分组/独立边界、
三项 Tips、焦点和禁用态不连带淡化提示。HAD-W32（USB、ARM64）debug HAP 构建、测试签名、
安装和启动成功，SHA-256 为
`D07734F99822E798C36A0F90D35F973297BE12E08586CD624E2CC26FB43804DF`，源码基线提交为
`f31cebf327920b8fccd6211351e0811cdd4eecf0` 加当前工作树改动。真机常态截图确认导航组外框、
中线、独立 Close 及紧凑间距；真实鼠标逐项显示 `Shift+Enter`、`Enter`、`Esc`，空查询的
禁用导航提示仍清楚。输入 `t` 后得到 `1/2`，Tab 依次聚焦 Previous、Next、Close；点击
Next/Previous 得到 `2/2 → 1/2`，点击 Close 后搜索关闭。截图和 layout 位于
`C:\tmp\leantty-search-controls-20260808-r1`。该 debug HAP 只证明本次定向改动，不替代
从新精确提交重建的正式候选。

## 人工验收结果

- 2026-08-08，用户关闭鸿蒙飞书后，用真实物理键盘和中英文输入法完成组合输入、导航、
  关闭、焦点恢复及 focus ring 检查，未发现问题；`Ctrl+Alt+F` 没有不可接受的系统或
  输入法冲突。飞书的 `Ctrl+Shift+W` 抢占继续只按已记录的环境问题处理。
- 同日，用户在实际 SSH 服务器上完成 tmux、vim、less 与主流 Agent TUI 的 Medium/Extreme
  回归，覆盖 selection、OSC 52、HTTP(S)/OSC 8、鼠标、滚轮、resize、可读性和 BEL 节奏，
  未发现问题。

## 已完成的验收

### 自动化

- 普通文本、无结果、多个结果、首尾回绕、大小写规则、Unicode 与宽字符。
- 打开/关闭、下一处/上一处、焦点恢复和查询不进入 SSH。
- Tab/Pane 隔离、Surface 销毁、renderer 重建和持续输出期间的确定行为。
- 搜索高亮不改变终端 buffer、selection、OSC/link 处理或远端输入。

### ARM64 构建与物理 PC

- 干净 ARM64 HAP、双 Pane/Tab 归属、焦点恢复、warm 淘汰、renderer 生命周期和大
  scrollback 的候选客观门禁已完成，无隐式在线资源。
- 真实物理键盘/中英文输入法和用户服务器 tmux/vim/less/Agent TUI 已由用户按上一节完成；
  该结论来自人工验收，不用 HDC 注入或 fixture 名称替代。

## 基线闭合结论

1. 1.1.1 已作为确切 GitHub Release 冻结，商店审核与 1.2 开发分开治理。
2. 布局、输入法、关闭、匹配和 buffer 语义已经冻结；`Ctrl+Shift+F` 已因输入法简繁
   切换冲突被裁剪，固定入口 `Ctrl+Alt+F` 已通过 HDC 与物理键盘打开验证。
3. 所有权可以局部留在 Terminal Surface，不增加跨 Session 索引或持久状态。
4. 官方 search addon 已通过来源、许可证、体积和源码/打包兼容审计；ArkWeb 行为仍按
   实现后真机门禁验证，不把上游浏览器支持声明替代设备证据。
5. 1.2 保留候选的搜索自动化、物理 PC 所有权、warm 淘汰和 renderer 生命周期已经闭合；
   真实物理键盘/中英文输入法和用户服务器 TUI 也已完成人工验收。

如果最小搜索仍要求通用命令面板、跨 Session 索引或高成本前端替换，应停止该方案并
重新评估问题，而不是为了维持 1.2 版本号扩大架构。

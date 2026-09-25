# 1.7 原生终端：既有需求迁移审计

2026-09-25 补充评审：旧行为不是最优方案的默认依据。维护者批准修正高缩放字号、
常见 HTTP(S) 文本识别，并加入温和有界的触摸板速度增益；鼠标滚轮不加速，不加入
惯性或定时补滚。普通复制/粘贴单独确认保留 1 MiB UTF-8 上限，超限/忙碌必须明确
反馈且不能截断或断开会话。拖出边缘选择的距离加速明确延期。执行与证据只记在
[Next Work](next-work.md)；下方此前“总审闭合”不代表这批新发现已通过真机。

轴事件单位依据平台 [AxisEvent 文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-events-axis.md)
及 [BaseEvent 文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-gesture-customize-judge.md)：
位移为 vp、时间戳为 ns。ArkTS 输入处转为毫秒，不按事件频率猜测设备，不更改 VT。

最新人工反馈（2026-09-19）：维护者按体验说明确认 Alt 矩形及 URL/Ctrl 点击正常，
开发期实体交互缺口已在 Next Work 闭合；本文下方“仍待验”的批次记录保留其历史边界。
同期新增拖动后左 Pane 大面积空白报告，当前截图确认内容集中在底部、上方大面积空白，
独立诊断已在不加载用户配置的 zsh 满宽两行提示符上复现：同一 PTY 重绘字节流在原生
Ghostty 与随包旧 xterm 中均每轮增加一个空行，短提示符与无重绘样本稳定；这证明一个
与现场相符的共同重排机制，尚不等于已证实用户实际 Shell 的完整因果链。另已修正原生
像素变化时重复上报相同行列数的迁移缺口，软件合同及授权安装后的定向真机验证通过：
76→85→76 列无连续重复通知，同网格的 7 px 变化不发送 SSH resize，左右后续输入正常。
证据：`build/verification/1.7-left-pane-drag-blank/`。这是此前诊断边界，最新 Starship
配置对照与归属判断见下节；
人工反馈不冒充代理观察或正式候选验收，截图也不能单独证明空白随拖动增长的过程。

2026-09-19。基线为已交付的 `CHANGELOG.md`、替换前 Web 实现及其回归、产品原则和既有
真机证据；对照当前开发分支的原生实现。这里记录需求与证据，不另建 TODO，执行项只在
[Next Work](next-work.md)。`已接入` 仅指实现链存在，不能替代指定场景的设备验收。

## 当前替换准备状态

09-19 后续替换批已删除产品 Web/Bridge/快照回放及 xterm 依赖，debug/release 均为
单一原生路径；本地指南保留。186 项 ArkTS、原生控制器/Session 合同、指南检查和
构建工具检查通过，两种 ARM64 包均通过构建和资源核对，release 排除了验收探针。
维护者授权后已安装 `1.7-native-only` 普通开发包，受控 SSH、搜索、分屏和会话退出
主路径通过；具体包身份、无效样本和清理记录在同目录及 Next Work。后续批次已迁移
共享输入、搜索、性能及 Mosh 的原生观察；工具合同和四项真实 Mosh 恢复场景通过。
09-20 交付前总审已闭合开发期完整替换项，不将开发期证据升格为正式候选验收。

## 2026-09-20 交付前总审

复核本表各项合同、当前单一原生路径及已删除的 Web/Bridge/快照链，检查输入和协议
回写所有者、VT 队列/结束屏障、关闭释放、搜索与系统效果、显示/IME、固定依赖和发布
探针隔离。未发现新的产品阻塞项；上游约一万行、1 MiB 搜索、右侧分割条热区和 GPU
持续不可用等已确认决定保持不变。精确光标周期、未穷尽的平台事件排列与 Shell 满宽
提示符重排继续保留各自证据边界，不作为新兼容实现的理由。

修正一处验收观察缺陷：搜索队列满时，原查询返回 0，控制器随后可接受空查询以清理
旧结果；旧探针在清理后记录原查询成功。实际控制器反例先复现，再将日志移到原查询
返回处，25 项合同通过。产品搜索行为未变。既有负向搜索结果布局没有错误提示节点，
Mosh 页面恢复另由 worker 内独立摘要证明；未修改旧包、旧报告或伪造补测。

安全/隐私、职责/透明/GPU 原则、开发依赖表与验收说明同步到原生实现。历史设计保留
时点，修正删除文件的链接和已废弃的当前实现描述。输出探针、构建注入/异常还原及
包标记排除、device helpers、policy 检查通过；四份 Mosh 报告及三个保留包的哈希相符。
证据位于 `build/verification/1.7-final-audit/`。本批仅修改工具及文档，未操作测试机；
开发交付闭合不等于正式候选、GitHub 发布或 AppGallery 上架。合入顺序仍由版本规则
和 Next Work 控制。维护者随后于 09-20 确认 1.6.0 已过审上架，该版本前置门已满足。

## 替换前预检记录

以下为替换前的预检记录：

默认光标和 SSH 退出锚点的后续修复已完成定向软件与真机验证。最新代码的 release 原生
预检也通过：API 24/AArch64 库、验收标记排除和构建配置精确还原均已核对，包与报告在
`build/verification/1.7-native-final-readiness/`。预检包没有安装；它不是正式候选，不能
代替删除旧实现后的集成验收。当时设备使用 `1.7-session-output-anchor` 的普通开发包。

最新反馈确认未连接时正常，`ssh wsl` 后仍增长。现已用同机 zsh 5.9、Starship 1.25.1
及实际提示符配置的只读副本，在隔离目录复现：满宽 `$fill` 提示符经十轮缩放，原生和
旧 xterm 均由 4 行增至 14 行；仅移除 `$fill` 后，两者均保持 4 行，非空内容保留。
因此将该可复现的 Shell 重绘/提示符重排机制归为既有第三方限制；定位完成不等于现象
消失，没有修改用户配置或添加集成。未采集原现场完整字节流的边界仍保留。
[上游作者说明](https://mitchellh.com/writing/ghostty-devlog-001)解释了相同机制及 Shell
集成的额外责任；按质量策略，此类已定位限制不单独阻止继续原生替换。
本地证据为 `build/verification/1.7-ssh-wsl-resize/`。剩余执行顺序只在 Next Work 维护；
Web/快照桥/终端依赖的删除与其工具适配应作为同一批完成。
源码核对同时确认，本地 HTML 指南及生成/预览测试也位于现有资源和 tools/web-terminal
目录；它们仍服务既有指南功能，不能随 xterm 专用资产一起删除。

## 迁移缺口的当前处理结果

| 原需求与证据 | 原生实现位置与现状 | 判断 |
| --- | --- | --- |
| 四边至少 8 vp 视觉留白；整格余量居中。`terminal.html` 的 `fitAndCenterTerminalGrid`、Web policy 的四边断言、Changelog 的居中修复 | 审计发现 renderer 无 inset、从零原点绘制。本批由 `TerminalGrid` 统一有效行列与原点，绘制、指针、选区、链接和 IME 使用相同偏移 | **已补齐并定向验证**。几何、输入及真机普通/最大化窗口、字号和候选位置通过；后续 window-grid 批次已补齐 SSH/Mosh/双 Pane PTY，见下项 |
| 浮窗拖动结束后吸附当前字体的整格；拖左/上边保持对边不动。`EntryAbility.snapWindowAfterDrag`、`WindowGridSnapPolicy`、Changelog | 原生 attach 回传实测 cell/inset，由当前 Pane 保存；窗口按物理像素计算，并拒绝过期字体/DPI/Surface 度量。沿用对边固定和窗口限制 | **已补齐并定向真机验证**。左边 125→199 时右边保持 2911；上边 23→87 时底边保持 1953，结果 2712×1866。保留双 Pane 的既有分割比例，各自居中，不承诺任意比例下两边同时零余量 |
| 滚动条有 8 px 命中范围和 2 px 滑块，显示位置并支持拖动。`terminal.html`、xterm CSS、Changelog | `TerminalScrollbar` 共用绘制/命中几何，worker 操作当前 VT viewport；滑块靠原 gutter 内侧，中央分割条使用获批的右侧 12 vp 鼠标热区 | **已补齐并定向真机验证**。同一普通包的浮窗/最大化、左右 Pane 拖动到顶/底、轨道翻页通过；中央热区中间/外侧均可拖动分屏，外窗仍可 resize。原 8 vp 留白与内容网格不变，最外缘仍由系统窗口热区决定事件归属；未新增转发层或窗口模式分支 |
| 链接按修饰键显示下划线、指针与目标预览；普通文本选择不被误激活。`handleLinkHover` / `setCurrentLinkDecorations` / `activateTerminalLink` | VT worker 共用 URL/OSC 8 命中与修饰键规则，派生可见格范围；GLES 下划线、ArkUI 标准手形 API 和左下目标预览，修饰键/leave/状态变化统一清理 | **已实现，实体点击由维护者确认**。真实 VT/控制器及触发式下划线、目标、松键、搜索清理已验证；09-19 维护者按体验说明确认普通 URL/OSC 8 的 Ctrl 点击正常。不补造物理指针形状截图，未重开失败的注入驱动路线 |
| 搜索对全部可见匹配着色，区分当前项，并在滚动概览标示。Web `searchOptions().decorations` | worker 刷新上游搜索视口，完成结果后派生去重行号；`TerminalSearchHighlights` 投影可见格，GLES 绘制高亮/当前边框及原有 gutter 内的概览 | **已补齐并定向验证**。真实 VT 覆盖 Unicode/折行/裁切/重排/查询替换及离屏行号；真机验证多匹配、导航、跨历史视口、概览位置稳定和清空/关闭清理。未增加历史正文副本、另一搜索所有者或额外占位 |
| 常规 SSH 有 10,000 行历史，临时 Mosh 页面退出不污染本地历史。Web `TERMINAL_SCROLLBACK_LINES` / 临时页面合同 | 经维护者确认，regular VT 改用上游 10,000 行限制和整页淘汰，移除 8 MiB 截断；temporary VT 仍为零历史 | **按确认后的约一万行合同实现并定向验证**。153/512 列样式容量、搜索和临时页面隔离合同通过；ARM64 App 纯文本/逐格彩色样本搜索分别为 9,792/9,855 条匹配，包含当前屏。单次内存及关闭回收数据见下文，不作为独立 VT 峰值或正式压力验收 |
| 当前字号、系统缩放和双 Pane 下字符、PTY、鼠标及候选窗一致 | `NativeTerminalController.attach` 按 `vp2px` 转字体与 8 vp inset；cursor 与 pointer 统一网格原点，窗口读取原生实测 cell | **开发期场景已闭合**。字号、最大化、双 Pane SSH/Mosh PTY 及系统 density 1.9→2.2125→1.9 通过，右 Pane 选词和双 Pane 候选位置通过；后续跨 Pane/越顶拖动已取证，Alt 矩形由维护者确认。未隔离“DPI 改变但 Surface 未通知”分支，不宣称穷尽平台事件排列 |

## 已接入的合同及证据边界

| 原需求 | 原生实现/共享所有者 | 已有证据与剩余边界 |
| --- | --- | --- |
| 单一输入所有者、组合键、IME 提交与预编辑 | `NativeTerminalPane.handleNativeKey`、`TerminalInput`、controller 输入代次 | `1.7-native-keyboard` 的 23 项真机键盘场景，Backspace/Delete 注册修复；几何变更后补验双 Pane 候选位置，并修复 Escape 提前消费。新包证明候选取消及未消费 ESC 关闭终端补全 |
| Tab/Pane 独立会话，过期回调不能串输入输出 | `TerminalSurfaceController`、`NativeTerminalController`、`TerminalRuntime`；Session 继续拥有协议 | Session/控制器合同及双 Pane、Mosh 既有证据；不另建 renderer-owned Session |
| 最大可用行列与 SSH/Mosh PTY 一致 | renderer → ordered Display → resize event → `SessionViewModel.handleTerminalResize` | **Padding 后已定向验证**。SSH 服务实际 resize 和 Mosh 真实 PTY 对照了单/双 Pane、字号、最大化及恢复；详情见本批窗口几何证据 |
| Ctrl+C 有选区复制、无选区中断；右键复制/粘贴；复制成功后清选区 | `copy`、`writeSelection`、共享 `ClipboardManager` | runtime/控制器合同及原生交互批次；保留异步复制的 revision/owner 保护 |
| 系统粘贴、bracketed paste、安全输入遮罩 | `paste`、Ghostty 编码、`TerminalInput`、controller 输入代次 | 原生粘贴/输入合同；不在 ArkTS 再解释 VT 粘贴模式 |
| 普通/单词/整行选择、Shift 强制本地选择、拖出区域滚动 | `TerminalInteraction.pointer` 与 Ghostty selection gesture | 已有带偏移的正反向 Unicode 矩形复制合同和真机触发式选区显示；普通包系统鼠标验证已激活 Pane 的跨 Pane 松手、越顶历史滚动及释放停止。实体 Alt 矩形已由维护者于 09-19 确认；未将未激活遮罩上的拖动算作通过 |
| 主屏历史、备用屏 wheel/TUI mouse、不泄漏到本地历史 | runtime `Scroll`、鼠标编码、临时 VT | runtime 及 `1.7-native-mosh-mainpath` 等设备记录；滚动条缺口单列，不能以 wheel 覆盖 |
| Ctrl+Alt+F、当前终端搜索、大小写/循环导航、IME 与 Escape/Tab 键归属 | 原生搜索面板、`search/advanceSearch`、controller search generation | 搜索条密度/分组/Tips/键盘激活已恢复；真机空/非空/清空后切屏关闭并恢复焦点。获批 1 MiB UTF-8 容量和局部提示已落地，详见下方充电后验证；外观对照已获维护者明确接受 |
| 终端字体、粗斜体、宽字符、emoji、下划线种类、反色、光标 | renderer 字形/样式和固定 Regular/Bold 字体 | 六种光标模式及显示隐藏通过真实 VT 合同；真机确认方块/下划线/竖线/隐藏、分屏空心及回焦实心，宽字最后两格和仅余一格换行的边界。精确闪烁周期采样按 §4.9 延后，不以代表性样本声称穷尽 |
| 透明度只影响默认背景，显式 ANSI/TrueColor 背景不透明；OSC 11 固定逻辑背景 | ArkUI 共享透明表面、renderer clear/显式背景、VT 调色板 | 已有透明/样式与颜色回复证据；native `sendTheme` 不消费 Web JSON，但当前仅固定 Mocha 调色板与透明度，不存在已交付的可切换主题缺口 |
| 稳定标题归 App 所有，远端 OSC 不能覆盖 Host 标题 | 共享 Session/Tab 标题链；原生不把 VT title 投递 UI | 所有者未变；不因 Ghostty 支持标题回调就新增远端标题功能 |
| BEL、OSC 9/777/99 只触发限定提醒；后台节流 | `TerminalEffects`、controller、共享提醒所有者 | 实际 runtime 的 framing/owner 合同及原生提醒批次；保留有限协议子集与查询响应，不扩展动作能力 |
| OSC 52 只允许限定目标写入，禁止读取；异步副作用检查 Session 代次 | `TerminalEffects`、`acceptsRemoteEffect`、共享 clipboard | host 分片/无效序列及设备剪贴板证据；不把所有 Ghostty 通知/剪贴板回调直接开放 |
| 安全打开链接/本地指南及文件边界 | native link event → `TerminalSurfaceController.onOpenUrl` → 原 Session/系统 URL owner | 继续使用共享 URL/文件策略；普通 URL/OSC 8 系统点击已由维护者按体验说明确认，不补造代理浏览器截图 |
| 尾部输出、关闭、重连、Mosh 临时页面退出不丢失或混入下一会话 | consumed barrier、共享会话边界 reset、regular/temporary VT | 原生 SSH/Mosh/双 Pane 与输出负载证据；09-19 已补齐 SSH 退出输出锚点，真实 VT 和真机确认 close/prompt 紧接内容，保留历史；继续使用单一 VT worker 顺序 |
| 后台暂停绘制、返回重验 Surface、资源回收 | controller visibility、runtime worker、renderer GPU 生命周期 | 已核对 Surface 替换、Mosh/SSH 连续、受控 EGL context loss、Tab/最小化/休眠的既有身份和清理证据；当前普通包补验表面替换、最小化后历史搜索与输入，实际恢复方法及控制器合同通过。详见 `1.7-native-lifecycle-review`；不是自然驱动故障或完整发布矩阵通过 |
| 异常退出仅恢复 Tab/Pane 布局，不恢复连接/内容/凭据 | 共享 `UnexpectedExitRecoveryStore`、AppViewModel；native 初始化新 VT | 所有者与产品边界保持；原生重建保留进程内 VT，无需照搬 Web snapshot 回放和临时尺寸补偿 |

## 实现边界

- Padding 和整格吸附是已经交付的核心体验修复，按当前授权恢复，不属于扩大兼容范围。
- Web 的二次 fit、DOM scrollbar gutter、snapshot 回放期间抑制 resize 是具体实现手段。
  原生应保留结果合同，以一次确定的几何计算和有序 VT resize 实现，不复制 DOM 补偿流程。
- GPU 持续不可用按维护者 09-19 决策接受 App 无法使用；CPU 兜底不属于迁移遗漏。
- 本表是源码和已有证据审计，不是一次完整设备矩阵通过。全部执行缺口与优先级在 Next Work。

本批几何修复证据：`build/verification/1.7-native-geometry/batch-evidence.json`。还覆盖了
重新居中后鼠标静止时的 wheel 坐标：真实 VT 反例先失败，调整已有 pointer 坐标后通过。
没有增加第二套 renderer、兼容后端或新的系统依赖。

窗口吸附及双协议 PTY 的同包证据：
`build/verification/1.7-native-window-grid/batch-evidence.json`。这是受影响场景验证，
未运行完整发布矩阵。

系统 DPI 往返、双 Pane 候选位置与右 Pane 选词证据：
`build/verification/1.7-native-dpi-input/batch-evidence.json`。显示几何未新增代码；只计入
已观察到的系统切换路径，完整指针组合仍按 Next Work 保持待验。该批发现 Escape 在
IME 前被消费；后续修复将其交给 IME，未消费时再送终端，沿既有分派而不新增状态。
反例、签名构建及真机取消/普通 ESC 证据：`build/verification/1.7-native-ime-escape/`。

滚动条实现及未通过的边缘场景：`build/verification/1.7-native-scrollbar/`。首次参数遮蔽
和按到底角的操作不计产品通过；后续窗口状态对照证明最大化可拖动而浮窗边缘仍有冲突。
后续 `build/verification/1.7-scrollbar-hit-ownership/` 闭合该问题：当前普通包内侧起拖
对照通过后，将可见滑块移至该位置；经维护者确认，将 splitter 鼠标热区移到右侧既有
12 vp 空白。浮窗/最大化、左右 Pane 的前后像素与边界均支持滚动，中央分屏和外窗
resize 各自正常；新包搜索 1/26 和原 gutter 内侧标记可见。没有扩大四边留白或减少
完整行列，未添加独立历史、事件转发或设备判断。
滚动条命中项已按该批证据闭合；未引入平台适配或修改 Padding 合同。

搜索装饰与概览证据：`build/verification/1.7-native-search-highlights/batch-evidence.json`
及 `build/verification/1.7-native-search-overview/batch-evidence.json`。跨历史导航 1/16→16/16
时概览像素位置保持一致；清空/关闭后归零。最终包补验无历史短页的三个匹配标记，
修复该几何路径的除零边界；长历史路径未变，复用首包有效证据，没有扩大 gutter。

历史容量测量：`build/verification/1.7-history-budget/measured.csv`，固定 VT 的原生宿主
库、8 MiB、46 行视口，写入 10,046 条不自动折行的记录并检查 VT 无处理错误。
153/256/512 列 ASCII 与 CJK 分别保留 5,745/3,449/1,720 行历史；逐格变化 TrueColor
压力样本分别为 881/537/446 行。80 列纯文本样本保留 10,001 行，说明预算既不能保证
最少 10,000 行，也不是固定行数上限。以上是容量反例，不是典型工作负载内存指标。

同目录 `lines-measured.csv` 核对固定上游的行数接口：移除字节上限、设置 10,000 行，
46 行视口写入 14,046 条记录后，80/153/256/512 列分别留下 9,955/9,745/9,997/9,997
行，ASCII、CJK、逐格 TrueColor 一致。`SCROLLBACK_ROWS` 与 scrollbar 的 total-len
交叉核对一致；固定源 `src/terminal/PageList.zig` 的 “max lines does not round larger
limits” 测试明确整页淘汰会少于指定值。09-19 维护者确认“接受约一万行，复用上游机制”，
据此改用该行数限制，不引入上游补丁、额外历史缓冲或新的设置。

本批 `build/verification/1.7-history-lines-arm64/` 保存新合同及真机证据。旧 8 MiB 实现
在新增的宽行样式容量测试失败，新实现的全部 25 组运行时合同通过。编译期临时样本每批
等待生产消费屏障，签名包在 153 列、46 行视口连续输入公开纯文本和彩色记录；搜索
分别返回 1/9792、1/9855，彩色导航变为 2/9855，后续 `help mosh` 精确输入成功。
这些计数包含当前屏，不冒充精确的历史行数，也不替代 SSH 输出字节完整性测试。

同一 PID 的 mapped PSS（排除 GPU/图形、单位 KiB）：原三 Tab 103,528；新空 Pane
112,859；纯文本 154,430；逐格彩色 184,096；关闭测试 Pane 后 143,560，约 43 秒后
123,306。关闭后明显回落，尚未完全回到原基线；本批不据此证明零泄漏或判定存在泄漏。
这是 App 加公开样本的单次观察，包含 ArkTS/渲染缓存，不是独立 VT 内存或峰值；未强制
GC、未读取堆内容、未改变回收策略。普通包已单独保留，临时源码还原后按原包恢复。

## 2026-09-19 充电期间离线复查

本节记录修复前的审计快照；当前处理结果见末尾“充电后搜索修复与定向验证”。

本轮基于当前未提交工作树、旧版搜索设计与真实截图、现有原生证据和生产运行时最小
宿主诊断。没有连接测试机，没有修改产品源码。首轮审计只核对“搜索已接入”，漏掉了
搜索控件曾单独收敛过的视觉与提示合同；功能自动化通过不能替代这些要求。

### 搜索框：已有真机截图和源码共同证明的差异

旧版基线见 [搜索设计](design/terminal-search.md) 的“搜索按钮视觉收敛”，以及
`entry/src/main/resources/rawfile/terminal.html` 的 `#search-panel`、`#search-navigation`
和 `initializeSearchUi`。原生为 `NativeTerminalPane.ets` 的搜索 Row 和 `handleSearchKey`。

| 核对项 | 已交付的 Web 实现 | 当前原生实现与判断 |
| --- | --- | --- |
| 面板密度与边界 | 344 CSS px 宽、34 高、4 padding、2 gap；边框、圆角、阴影；上/右有间距 | Row gap 8、padding 8，输入固定 220 vp；没有面板总宽/高度/最大宽度约束，也无相同边框和间距。旧/新截图分别显示紧凑悬浮条和更高、贴边的深色条。**确认视觉退化**，不把 CSS px 直接当 vp 或根据不同窗口截图计算缩放比例 |
| 导航与退出层次 | Previous/Next 共用 54×26 导航组外框及中线；Close 独立 26×26 框与额外间距，常态透明底 | 三个独立 `Button('↑'/'↓'/'×')` 使用系统默认尺寸和背景；现有真机图中为三枚实心蓝按钮。**原有分组和层次缺失** |
| 查询与计数 | 输入可收缩、明确字体/高度/焦点框；计数固定 48 宽并省略，避免结果数量改变面板布局 | 输入固定 220；计数未约束宽度，输入/按钮多项样式依赖系统默认。**布局约束缺失**；实际窄 Pane 是否溢出待真机，不在源码审查中假装已经复现 |
| 快捷键提示和可达性 | 导航/关闭显示 Shift+Enter、Enter、Esc Tips；键盘 focus 可见，禁用态 Tips 不随按钮变淡 | 保留动作 accessibilityText 和键盘路由，但没有按钮 Tips/导航语义组。**提示缺失**；资源中的无障碍动作文本仍存在，不能称全部无障碍丢失 |
| 空查询/无结果 | 可见计数同样为 0/0；title/aria-label 区分输入提示与无结果 | 可见计数为 0/0，accessibilityText 仍区分两者，但缺少鼠标描述提示。**提示体验差异**，不是计数算法缺失 |
| 窄 Pane | max-width 与可伸缩输入；小宽度下调整位置 | 无对应最大宽度/收缩策略。**实现缺口**，需要在真实最小窗口/双 Pane 核对实际布局，而非机械搬运 Web 媒体查询 |

本地可评审对照为 `build/verification/1.7-offline-migration-audit/search-ui-comparison.md`。
原图是 `C:/tmp/leantty-search-controls-20260808-r1/after.png` 和
`build/verification/1.7-native-search-overview/final-short-search.png`，两者均为 3120×2080。
日期、窗口与查询不同，只证明各自候选的真实表现；未将旧截图标作当前重测。

建议沿现有原生搜索所有者恢复紧凑外观、导航分组、独立关闭、键位提示及可收缩布局。
不增加第二套搜索模型、不改终端网格，也不重新设计一套无旧版依据的视觉语言。
完成需同时看有结果/空查询/无结果、hover/focus/disabled、中英文、窄窗口和双 Pane；
源码与截图已支持修复方向，修改后仍需同条件真机评审。

### 搜索行为：另列的两处迁移差异

1. **新增查询长度限制。** 原生 `TextInput.maxLength(256)`，旧 Web input 没有 maxlength。
   原生运行时 `TerminalRuntime::search` 另有 4096 字节上限，本轮真实宿主探针确认 300 个
   ASCII 字符能进入运行时。因此 256 不是运行时必然要求；本轮未找到维护者批准的搜索
   容量收缩合同。下一步先对照长查询及 Unicode 输入，保留必要资源边界并给出明确反馈，
   不能直接去掉 UI 限制后让大于 4096 字节的拒绝落入 controller 通用失败路径。
2. **空查询切屏没有关闭通知。** 旧合同要求 normal/alternate screen 切换时关闭搜索，
   不以是否有查询为条件。`TerminalInteraction.cpp::refreshSearch` 只在 `search_ != nullptr`
   时发送 `search-close`；空查询和清空查询都会释放该对象。当前 UI/controller 仍可处于
   searching=true，生产输出切屏本身没有另一条面板关闭通知。最小宿主诊断观察到
   empty=0、nonempty=1、cleared=0 次关闭事件。**运行时事件缺口已复现**，实际 ArkUI 面板
   行为尚待真机。状态权威分别是 UI 搜索打开状态与 VT 活动屏；修复应表达屏幕变化边界，
   不能用存在匹配对象推断面板是否打开，也不新增并行搜索状态机。

诊断直接编译当前 `TerminalRuntime.cpp`、`TerminalInteraction.cpp`、`TerminalEffects.cpp`，
链接现有固定 Ghostty 宿主静态库；只用公开合成文本、DEC 1049 与消费屏障，无网络或设备。
源码和输出在 `build/verification/1.7-offline-migration-audit/search-probe.cpp` / `.txt`。
这不是 ARM64/IME/真实按键验证。首次编译因用户级 Zig 缓存无权限失败；改用本批忽略目录
缓存后成功，未修改机器权限或工具脚本。编译出现上游 libc++ nullability 警告，未作为产品失败。

### 其他迁移范围及剩余证据

| 范围 | 本轮对照与结论 |
| --- | --- |
| Padding、网格、字号/DPI、SSH/Mosh PTY | 复用既有几何、window-grid 和 dpi-input 证据；源码由同一实测网格映射显示/命中/候选位置。不重新列成完整 DPI 矩阵，不把未隔离的无 Surface 通知分支称通过 |
| 滚动、历史、搜索装饰 | 滚动条命中修复、搜索高亮/概览和新约一万行合同已有定向记录。本轮修正本文仍称滚动条“开放”的过时句子；容量取舍已获确认，不再次撤回或重复讨论 |
| 输入、选区、剪贴板 | 原生 IME 前后分派、按键编码、selection revision 保护和搜索期间副作用隔离已有实现；实体 Alt 矩形仍待验。普通跨 Pane 拖动/释放后停止已在 lifecycle-review 取证，不能再泛化成全部跨边界选择待做 |
| 链接 | 下划线、目标、清理已接入，普通 URL/OSC 8 的实体 Ctrl、手形和系统打开结果仍待验。复用既有触发式视觉证据，不再扩建组合键注入工具 |
| 样式、透明度、字体和光标 | 当前 renderer 处理粗斜体、颜色/装饰、Unicode 与系统字形；已有形状/裁切证据。精确闪烁周期按既有低风险延期处理，不等同通过。没有发现据此需要新字体引擎或显示后端的证据 |
| 焦点、Tab/Pane、Surface/会话与系统效果 | 检查共享 Session 所有者和原生代次边界，已有生命周期/效果合同继续有效；本轮新增缺口限于上述空查询切屏通知，未证明其他领域不存在缺陷 |

完整替换仍未通过。后续优先闭合搜索条外观与上述行为差异，再集中完成实体键鼠、
受影响链与最小冒烟；当前原生 debug 和旧 Web release 仍有明确过渡边界。

## 2026-09-19 充电后搜索修复与定向验证

本批沿既有 Pane/Surface/VT 所有者补齐搜索迁移，没有增加搜索模型、历史副本或兼容后端。
维护者明确确认“采用 1 MiB 上限和明确提示”，替代旧版无显式上限的查询能力边界。

| 修复 | 证据与边界 |
| --- | --- |
| 紧凑搜索条、导航分组、独立关闭、键位及计数 Tips、焦点和禁用外观 | 单 Pane 实测 654×65 px，对应 density 1.9 下 344×34 vp；中英文、空/有/无结果、禁用 hover 和键盘焦点图已留存。594 px 窄 Pane 内面板为 370 px，控件可见；保持既有终端网格和 Padding。旧/新对照可供维护者评审，未把不同日期/窗口截图当作同条件重测 |
| 按钮键盘激活 | 真机 Next 从 1/13 前进到 2/13，Close 按 Enter 关闭；实际 Pane 方法合同覆盖 Enter/Space 两阶段只激活一次、焦点环、IME 及输入框导航 |
| 1 MiB UTF-8 查询和非致命错误 | 真实 VT 接受边界长度 ASCII/emoji、拒绝超限且仍可消费输出；真机 300 字中文完整保留，1 MiB + 1 ASCII 保持查询并显示中英文错误，随后同进程本地命令输入成功。该大查询通过编译期临时 UI 触发，不宣称系统剪贴板粘贴百万字通过；输出队列占满后的提示/重试为宿主合同证据 |
| 空/非空/清空后切屏关闭 | 测试包触发生产输出的 DEC 1049，三种查询状态均关闭并恢复同 Pane 焦点；实际 VT 合同覆盖双向切换。首次打开空查询登记代次，重复打开不丢查询；未新增平行搜索状态机 |

真实缺陷和失败尝试均保留：首版输入的系统默认 padding 裁字、焦点 Tips 换行已修复；
空字符串编码在真机返回 undefined 导致 JS_ERROR，改为零字节查询不做编码，并用相同
返回语义的宿主反例核对。平台 TextInput 默认限制 1,000,000 字符，会截短超限样本并
消除错误；最终显式允许 1 MiB 加一个字符，由 UTF-8 字节数判断查询是否可提交。
首轮按钮 Enter 未前进，修复现有搜索按键入口后通过；没有另加事件层。

22 项控制器合同、29 组真实运行时合同及定向签名构建通过。证据目录为
`build/verification/1.7-search-parity/`，`search-ui-review.md` 保存裁图和原图路径，
`batch-evidence.json` 区分各包身份、有效场景和失败尝试。临时触发器仅位于忽略目录，
最终普通包单独构建安装；现场恢复和普通包冒烟以本批记录为准。

本批自动化曾误把搜索父节点当作焦点控件、被脚本 Action 参数遮蔽，均在动作前停止；
局部诊断 helper 已修正，记作 automation-flaky-harness，不冒充稳定矩阵通过。
没有运行发布矩阵。维护者随后确认“接受当前外观”，搜索视觉项闭合；实体 Alt 矩形和
Ctrl 链接仍由 Next Work 保持待验。

## 2026-09-19 替换前关闭所有权检查

检查发现：异步关闭准备失败时，`Close` 析构只删除 work/ref；Binding 的 TSFN 回调
仍引用 controller，controller 又持有 native handle，不能依赖 handle 的 GC 来打破这个环。
原生方法的最小宿主反例在失败返回后观察到 runtime/input/renderer/sink 仍被持有。
这属于已接入关闭链的资源释放缺陷，不是新增兼容范围或 GPU 后备路径。

清理现收敛到 `Binding::release`：先结束 IME，停止并 join VT worker，再释放显示资源
及回调；正常异步完成、完成被取消、准备/入队失败和最终析构使用同一入口。失败仍通过
既有异常返回，不伪装关闭成功；准备失败时没有异步所有者接手，因此当场完成清理。
正常路径继续异步等待 worker。没有新队列、重试状态或依赖。

`binding-close-test.cpp` 编译实际 Binding 与 close 源码，只替换 N-API 和资源边界，
覆盖 Promise、引用、资源名、work 创建、入队五个失败点，以及正常完成/未执行即取消，
核对释放顺序与 work/ref/sink 余额。它不能证明设备自然发生过资源耗尽。
[OpenHarmony N-API 规范](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/napi/napi-guidelines.md)
要求检查非成功返回；本项修复依据仍是本地实际所有权和编译反例，不把历史平台 issue
当作当前设备故障。源文件及证据见 `build/verification/1.7-close-ownership/`。

原生合同分组（含 22 项控制器和 29 组真实 VT 合同）及最终 ARM64 签名构建通过。
普通包同一进程完成两次新 Tab 的精确命令输入、单次提交和关闭，原三个 Tab、第二 Tab
焦点、浮窗与中文拼音均恢复。首次 `mosh` 停在中文预编辑的无效样本保留；未发送 Enter，
取消并清理后显式准备英文才计入通过。未在真机制造资源耗尽，不以正常关闭证明异常
分支自然发生，也不将本批归为完整发布验收。

本次检查同时确认 debug 原生开启、release 原生关闭及 release acceptance-marker 扫描
仍在；这是源码边界检查，没有启用正式替换，也没有把既有 debug 包称为发布候选。

## 2026-09-19 默认光标与退出输出定位补齐

旧 Web 明确使用闪烁竖线；随包 xterm WebGL 的线宽为 1 CSS px、闪烁间隔为 600 ms。
原生 VT 初始化却继承上游不闪烁方块，renderer 又按 cellWidth/6 绘制竖线，并采用
500 ms 间隔。现通过固定上游的默认光标 API 设置竖线/闪烁，由 UIContext 将 1 vp
换算为物理像素，沿用既有渲染和计时循环。标准远端覆盖、默认 reset 和 RIS 仍有效，
失焦继续使用旧版的空心轮廓，没有增加设置或 Shell 特判。

实际 VT 合同覆盖初始值、六种远端样式、显示隐藏和 Mosh 临时页；真机初始/搜索返回帧
同时观察到亮灭，竖线为 2×40 px，搜索失焦为 18×40 px、2 px 边框。受控 SSH 备用屏
隐藏光标、退出恢复竖线通过。多帧证明闪烁存在，不宣称精确测量 600 ms 周期。
证据在 `build/verification/1.7-cursor-parity/`；对应包身份在 Next Work。

同轮发现另一个独立遗漏：统一 Session reset 末尾的 `CSI 999;1H` 只用于保护已有内容，
旧 Web 随后还会定位到最后有内容的行；原生分支跳过该步骤，直接在底行写 close/prompt。
这正是既有 1.5 会话状态隔离设计曾修复的输出定位合同。实际 Runtime 加载当前统一
reset 的反例在六行页面插入五个额外空行，真机也独立复现大块间隙。

现于同一命令队列加入窄的输出定位操作：VT worker 使用上游 active-grid API 有界扫描，
以标准 CUP 定位，再回到底部；Session 仍拥有模式复位和本地输出。扫描保留字面空格，
忽略清空/背景单元格；不清历史，不影响活动远端，不改变 Mosh 临时页恢复。真实 VT
覆盖空页、短/满页、宽字、组合字符、空格和历史视口；控制器验证背压下的次序，实际
Surface 方法验证 reset→定位→本地输出→完成。共 23 项控制器、31 组 VT 和 8 项
Session 事件合同通过，ARM64 普通签名构建通过。

最终普通包在同一真机完成受控 SSH 输入、备用屏幕、正常退出和随后本地命令；截图
显示 close/prompt 紧接原内容，光标恢复。证据在
`build/verification/1.7-session-output-anchor/`。临时信任、测试 Tab、fixture 和端口映射
已清理，原双 Pane、右侧焦点、窗口与中文拼音恢复。本批未运行完整发布矩阵；原始
拖动分隔线时的 zsh 空白报告继续独立保持未闭合，不能将本次退出修复当作其最终归因。

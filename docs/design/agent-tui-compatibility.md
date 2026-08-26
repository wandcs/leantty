# Agent CLI/TUI 原生兼容基线

> 状态：Verified；1.5 兼容矩阵、协议适用性与指南走查已闭合  
> milestone：1.5  
> 核对日期：2026-08-25  
> 上位规则：[`project-principles.md`](../project-principles.md)  
> 活动工作：[`next-work.md`](../next-work.md)

## 用户问题与范围

LeanTTY 应当让用户通过普通 SSH 或远端 tmux 使用主流 Agent CLI/TUI，并保持工具自身的
键盘、终端协议和 attention 行为。LeanTTY 不内置 Agent，不解析 Agent 输出，不为不同 Agent
增加专属通知或状态模型，也不把测试脚本追加的 BEL 当作 Agent 原生行为。

本方案先建立可重复的兼容性基线。它只授权兼容性调查、受控测试环境和证据采集；发现阻断时，
仍需按产品原则单独判断是否值得修改产品。矩阵通过本身不授权升级 xterm、增加 Kitty keyboard、
CSI-u、完整 OSC 99 或 Agent 专属分支；OSC 99 仅在后续独立评审后进入 roadmap 明确的精简接收子集。

## 验收完整性与 Token 成本目标

第一目标是用真实 Agent、普通 SSH、远端 tmux 和物理 HarmonyOS PC 完成既定矩阵，取得足以
支持兼容性结论的可重复证据。在此前提下，第二目标是尽量减少 Codex、OpenCode、Pi Agent 与
Qwen Code 的模型请求和 Token 消耗；不得通过缩短既定矩阵、以 fixture 冒充 Agent 原生行为、
降低断言强度或省略失败与恢复路径来换取成本下降。

执行遵循以下规则：

- 调用模型前先完成二进制、版本、认证、网络、测试目录、SSH/tmux、设备控制和观察通道预检；
  前置条件不成立时直接记录 `not-assessed` 或 infrastructure failure，不消耗 Token 反复试探。
- 只使用不含真实项目和用户数据的最小合成仓库，以及能够稳定触发目标行为的短、固定任务；
  不要求 Agent 扫描无关目录、总结整个仓库或执行开放式开发任务。
- 同一 Agent、传输路径和候选中的键盘、粘贴、显示、通知与生命周期检查尽量在一次受控会话中
  完成。已经取得且未受变化影响的证据按 `quality-strategy.md` 复用；失败只重跑受影响阶段，
  每次新增模型调用必须产生尚未取得的证据或检验一个不同的失败假设。
- Agent 能提供用量时，长期证据记录 Agent 版本、模型/提供方、请求次数与输入/输出 Token；
  不记录 prompt、回答、凭据或代理值。工具不提供可靠用量时标记为 `unavailable`，不得估算为零。
- 不设可能截断回答、阻止工具调用或改变原生通知时机的统一硬 Token 上限。若节省措施改变了
  待测 Agent 的真实行为，该次结果无验收资格，应恢复真实合同后重测。

完成时除兼容矩阵外，还应汇总各 Agent 的模型调用次数、可取得的 Token 用量、重试次数及原因。
成本优化是否有效以“没有新增结论的调用被删除、每次额外调用都有明确证据价值”为准，不预设
任意百分比，也不跨不同模型、提供方或任务复杂度比较绝对 Token 数。

## 当前工具合同与受控配置

2026-08-24 在默认 WSL `Ubuntu-26.04` 中安装并固定了下列版本。版本、配置和认证状态由每次
运行的 inventory 重新记录，不能把这次快照永久解释为“最新版本”。

| Agent | 本次版本 | 官方合同与受控配置 |
| --- | --- | --- |
| Codex CLI | `0.149.1` | 官方配置提供 `tui.notifications`、`tui.notification_method` 与 `tui.notification_condition`；验收进程显式使用 BEL、`always`、`--no-alt-screen`、只读 sandbox 和 run-scoped project trust，不写入用户配置。参见 [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) 与 [CLI commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli)。 |
| OpenCode | `1.18.23` | 固定 `opencode/big-pickle` 和最小合成仓库。TUI 会查询 OSC 99；LeanTTY 固定回答 `p=title,body`，只接收完整 title/body 帧并丢弃全部内容与 ID，不支持分片状态或回报。OpenCode 默认关闭 attention，验收仅通过临时 `OPENCODE_CONFIG_DIR` 启用，不改用户配置。通知 prompt 在交互式 TUI 完成启动后由 LeanTTY 输入，再执行一次无副作用的有界 `sleep`；不得使用启动参数 `--prompt`，否则内置通知插件可能错过 busy 事件并把夹具竞态误判成不兼容。参见 [OpenCode TUI](https://opencode.ai/docs/tui/)、[OpenTUI notifications](https://opentui.com/docs/core-concepts/notifications/) 与 [Kitty desktop notifications](https://sw.kovidgoyal.net/kitty/desktop-notifications/)。 |
| Pi Agent | `0.84.3` | 固定 `deepseek/deepseek-v4-flash`，关闭会话持久化，并使用安装包随附的官方 `notify.ts` extension；extension 在没有 Windows Terminal/Kitty 标识时原生发出 `OSC 777;notify;...`。远端 title/body 只用于确认 wire sequence，LeanTTY 不保留其内容。 |
| Qwen Code | `0.22.0` | 固定 `deepseek-v4-flash`，关闭聊天记录、更新与休眠，显式启用 `terminalBell` 和 `notificationMode=all`。0.22.0 在失焦且等待确认时发 BEL，长任务完成门槛为 20 秒；验收用一次需要批准的 run-scoped 临时文件操作稳定触发等待确认。参见 [settings](https://github.com/QwenLM/qwen-code/blob/main/docs/users/configuration/settings.md) 与 [approval mode](https://github.com/QwenLM/qwen-code/blob/main/docs/users/features/approval-mode.md)。 |

tmux 使用独立配置，启用 `focus-events`、passthrough、bell monitoring 与任意窗口 bell action。
`focus-events` 是 Qwen 通过 DEC 1004 接收失焦状态的必要条件；tmux 默认关闭该选项。参见
[tmux manual](https://man.openbsd.org/tmux)。所有 Agent 仅继承
默认 WSL 进程中已经存在的代理变量；运行证据只记录变量名，不记录值。认证凭据由各工具自行
持有，验收只检查“可用/不可用”，不读取或复制凭据内容。

## 环境与事件链

物理验收使用同一条受控链路：

1. Windows 桌面用户的默认 WSL 启动一次性 OpenSSH server，只接受 LeanTTY 测试 Identity
   已有的 Ed25519 公钥，并通过一次性 HDC reverse port 暴露给测试 PC。
2. 测试 PC 上安装指定的签名 diagnostic HAP，在不影响既有工作区的独立 Tab 中连接该 server。
3. 受控 shell 启动 Agent 的普通 SSH 或 tmux 路径；通知必须由 Agent 自身设置产生，验收末尾
   不追加 `printf '\a'`，也不直接写入 LeanTTY attention 状态。
4. 服务端在 Enter 前保存 Readline 当前行的无内容快照，PTY 记录器分别采集 input/output，
   分析 BEL、OSC、alternate screen、bracketed paste、focus reporting 等 wire behavior。
5. 原始 PTY 输入输出在 fixture 清理前删除；长期证据只保留字节数、哈希、协议计数、布尔结果、
   工具版本、候选 HAP 哈希和清理审计。

生产凭据、Agent 输出、prompt 正文、代理值、SSH 私钥和现有工作区内容都不属于证据。缺少认证、
设备控制通道失败或 Agent 未安装时必须分别记录为 `not-assessed` 或 infrastructure failure，不能
降级成通过。

## 2026-08-24 物理结果

矩阵在 HAD-W32 物理 ARM64 HarmonyOS PC 上完成。Codex 复用未受后续改动影响的候选
`06FC2184...DB3DD97`；OpenCode 的最终 OSC 99 复测使用 `2D8484CD...72507E6`，Qwen 使用
`6C639139...28AA86`；Pi 的 OSC 777 复测使用
`EE855871...76BBE`；加入最终双语指南后的 BEL 回归使用 `F796FBCD...C0696`。这些都是
test-signed diagnostic HAP，不是 release candidate。

| Agent | 普通 SSH | tmux | 当前结论 |
| --- | --- | --- | --- |
| Codex CLI 0.149.0 | Passed | Passed | Agent 原生 BEL 被识别；通用通知 payload、返回来源、LeanTTY 搜索、4096 字符输入、语义 Unicode 输入、物理 `Shift+Enter`、SSH 重连通过；tmux 路径另通过 detach/reconnect/reattach。 |
| OpenCode 1.18.22 | Passed | Interaction passed; upstream tmux notification failed | normal direct 在 TUI ready 后交互提交 prompt，能力响应、完整 OSC 99、通用系统通知、准确返回、搜索、输入和 SSH 重连全部通过。normal tmux 与强制 `OPENTUI_NOTIFICATION_PROTOCOL=osc99` 的诊断轮均只有能力查询、完整通知帧为 0；搜索、输入、detach/reconnect/reattach 与清理通过。该失败与上游已知 tmux 通知边界一致，不授权 LeanTTY 增加 Agent 专属 workaround。 |
| Pi Agent 0.84.2 | Interaction passed; delayed notification failed | Interaction passed; delayed notification failed | 两条路径均捕获原生 OSC 777，且搜索、输入、SSH 重连和 tmux 恢复通过；但 Agent 完成较晚时 HarmonyOS 已暂停应用侧终端解析，系统通知未发布。 |
| Qwen Code 0.22.0 | Interaction passed; delayed notification failed | Passed | 两条路径均捕获原生 BEL 和 DEC 1004 focus input；tmux 开启 `focus-events` 后通知、返回、交互、SSH 重连和 tmux 恢复完整通过。direct 的较晚完成信号遇到相同后台暂停边界。 |

分析器把 standalone BEL 与 OSC 的 BEL terminator 分开统计，并分别记录 OSC 9/52/99/777、
DEC 1004、alternate screen、bracketed paste、OSC 8 与 Kitty sequence 计数。所有 input/output
原始捕获均已删除；fixture、sshd、reverse mapping、测试 Tab、tmux 与屏幕超时租约完成清理。

2026-08-25 又在同一 OpenCode 最终 test-signed HAP `2D8484CD...72507E6` 上运行
`-InteractionOnlyProbe`，最终证据为
`build/verification/agent-compatibility-20260824T181806341Z/result.json`。该探针不提交 prompt，
八格 `plannedModelRequests` 均为 0：Codex、OpenCode、Pi、Qwen 的 direct/tmux 都收到受控物理
英文键序列和真实 HarmonyOS 中文输入法 composition，PTY 全部处于 raw 模式；真实窗口切换
分别把 direct 从 36×141 改为 46×171、tmux 从 35×141 改为 45×171；OpenCode/Qwen 均成对
记录一次 alternate screen 进入/退出，Codex 的 `--no-alt-screen` 与 Pi 均未请求 alternate screen。
所有窗口恢复、输入法恢复、SSH/tmux、反向端口、测试 Tab、屏幕超时与原始 PTY/termios 文件
清理通过。该结果只闭合物理中英文输入、raw、alternate 与 resize，不证明 Agent 内 OSC 52/8
激活动作、scrollback 或原生通知。

产品现已在 Web 边界接受受限 OSC 9、格式正确的 OSC 777 与完整 OSC 99 title/body 帧，
UTF-8 payload 上限 1024 bytes。OSC 99 只允许 `i/p/e/d`，仅对有界查询固定回答
`p=title,body`，并拒绝分片、扩展操作、重复字段、
畸形 Base64、空值、控制字符和其他编号；通过后立即丢弃远端内容与 ID，只向既有 BEL attention
发送空 payload。`F796FBCD...C0696` 上的无模型 BEL 真机回归已通过，证明共享 attention、通用
通知、返回与清理主链没有退化。OSC 9 没有选定 Agent 的原生样本，因此只有软件协议覆盖，不能
写成 Agent 真机通过。

兼容性摘要另外只计数回传给 Agent 的精确 `p=title,body` 能力响应，不记录查询 ID；后续可以
在不保留 PTY 原文的前提下区分“终端未回答”与“Agent 回答后未通知”。
为避免继续消耗 Agent token，设备脚本提供独立的 `-Osc99CapabilityProbe`：它在相同的物理
HAP、WSL OpenSSH、SSH PTY 与 Terminal Surface 链路中只发送一次标准能力查询，并只保留是否
收到精确响应、响应次数和接收字节数。该探针不启动 Agent、不发送通知帧、不最小化窗口，也不能
替代 OpenCode 原生通知验收；它只负责定位“终端回传”这一条边界。

2026-08-26 的正式 1.5 候选验收发现自动化 verdict 仍把上述已闭合的适用性边界当成“每个
Agent/mode 都必须完成系统通知”。这不是产品合同：OpenCode tmux 未发原生 attention 时记录
`not-emitted-by-agent`；Pi direct/tmux 与 Qwen direct 已捕获原生信号、但命中隐藏窗口暂停边界
时记录 `platform-deferred`。两者都不能写成系统通知通过，且只有搜索、输入、重连、tmux 恢复、
UTF-8、清理等其余断言全部通过时才是非阻断结论。Codex direct/tmux、OpenCode direct、Qwen
tmux 以及任何实际已发出并进入 LeanTTY 的支持路径仍要求通用 payload、系统通知和准确返回。
验收脚本还必须绑定保留候选的 commit/tree/hash 与干净 harness 身份；诊断 HAP 不能进入发布
证据。该修正只调整测试判定和证据身份，不增加产品分支、后台保活或模型请求。

2026-08-25 使用同一最终 test-signed HAP
`3EE504FEFACCB1D244A25335749AE6A0A924E1348B99E1E4CE7B6F16C8130D39` 补齐了三个证据缺口。
首先，Codex、Pi、Qwen 的 tmux 零模型同步截图与先前 OpenCode 复测共同确认 UTF-8 fixture 下
四种 TUI 的中文最终画面正常；证据目录为
`build/verification/remaining-agent-tmux-cjk-synchronized-20260825T134500Z/`。其次，Qwen tmux
受控协议探针只提交一次短固定回答请求，原生 `/copy` 在第一次尝试发出一次 OSC 52，LeanTTY
日志和 HarmonyOS “已复制”提示共同证明系统剪贴板写入；随后内置 `!seq 1 120` 不调用模型，
`PageUp` 从 84–120 回看到 47–83，`Ctrl+End` 返回 84–120。最终证据为
`build/verification/qwen-tmux-protocol-ctrl-end-20260825T135554Z/result.json` 与同目录三张截图。

同一 Qwen prompt 明确要求输出一个 Markdown 链接，并设置 `FORCE_HYPERLINK=1`，但 PTY 中
OSC 8 open/reset 均为 0；零模型 `!echo` 也只产生普通 URL。安装包的独立伪 PTY 探针证明 Qwen
的 tmux OSC 8 包装函数可生成合法字节，因此当前结论是“所选 Agent 在该真实渲染路径没有发出
OSC 8”，而不是 LeanTTY 链接失败。LeanTTY 的通用 HTTP(S)/OSC 8 激活已有独立终端门禁；不向
Agent 注入控制序列、不为制造一次通过而增加模型请求，也不增加工具专属分支。Pi 先前被记为
64/75 个 OSC 8 的值经分析器修正后证明全部为空 URI reset，实际 hyperlink open 为 0；修正
证据为 `build/verification/pi-osc8-corrected-zero-model-20260825T143000Z/`。

HarmonyOS 窗口隐藏后仍会暂停 ArkTS/ArkWeb；Qwen direct 与 Pi direct/tmux 的较晚通知输出虽
最终到达 PTY，却不能在后台及时解析。1.5 不增加常驻服务、隐式保活、前台伪装或第二套 Session
所有权，故指南必须把系统通知描述为尽力而为，并把 tmux/screen 作为任务持久性的真正所有者。

关键长期证据：Codex direct/tmux 分别在
`build/verification/agent-compatibility-20260823T180728950Z/result.json` 与
`agent-compatibility-20260823T180938445Z/result.json`；OpenCode direct/tmux 在
`agent-opencode-direct-baseline-20260824/result.json` 与
`agent-opencode-tmux-baseline-20260824/result.json`；Pi 最终 direct/tmux 在
`agent-pi-direct-osc777-rearm-20260824/result.json` 与
`agent-pi-tmux-osc777-rearm-20260824/result.json`；Qwen direct/tmux 在
`agent-qwen-direct-deterministic-20260824/result.json` 与
`agent-qwen-tmux-focus-events-20260824/result.json`。当前指南候选 HAP 的 SHA-256 是
`F796FBCD0786910364F31643806E51513E03402B0C48BCF579AF528E206C0696`，无模型 BEL 回归在
`build/verification/background-bell-agent-guide-final-20260824/result.json`。

OSC 99 子集测试 HAP 的 SHA-256 为
`20848310796DB45D35A5AD3575ECA43FCE40CA4957D3E60BAFB0C685FC59EEDA`。复测证据在
`build/verification/agent-compatibility-20260824T150736580Z/result.json`、
`agent-compatibility-20260824T152119031Z/result.json` 与
`agent-compatibility-20260824T152903399Z/result.json`：OpenCode 1.18.22 的 direct/tmux 均只
出现能力查询，完整 OSC 99 通知帧为 0；每轮清理通过，不能把结果写成产品通知已验收。
零模型能力响应探针随后在重新构建的同源 test-signed HAP（SHA-256
`2D8484CDC42400C59B368F88831EDAA9F78749753693AFF2846F8E98872507E6`）通过，证据为
`build/verification/agent-compatibility-20260824T165520752Z/result.json`：远端 PTY 收到一次精确
响应，`receivedBytes=47`、`plannedModelRequests=0`，原始响应、查询 ID 与内容均未保留，且测试
Tab、临时 sshd、reverse mapping、fixture 与屏幕超时租约清理通过。因此可以排除 LeanTTY 能力
应答未返回这一假设。

随后发现旧夹具通过启动参数 `--prompt` 提交任务，可能早于 OpenCode 内置通知插件订阅 busy
事件。改为等待 TUI 进入 alternate screen 后从 LeanTTY 交互输入，同一 HAP 的 normal direct 在
`build/verification/agent-compatibility-20260824T170959189Z/result.json` 完整通过：能力响应与完整
通知帧各 1 次，系统通知、返回、搜索、输入、SSH 重连与清理均通过。带强制协议的先行诊断轮
`agent-compatibility-20260824T170739249Z/result.json` 也通过，但不计为正常配置验收。

normal tmux 在 `agent-compatibility-20260824T171232127Z/result.json` 仍只有 2 次能力查询，内层
能力响应和完整通知帧均为 0；强制协议诊断
`agent-compatibility-20260824T171806056Z/result.json` 结果相同。两轮交互、tmux 恢复与清理均
通过。这与 OpenCode 上游仍开放的 tmux 通知问题一致，属于外部路径限制；不能通过扩大 LeanTTY
协议子集或加入 Agent 专属分支来掩盖。

## 2026-08-25 完整性与指南闭合

兼容矩阵按“真实行为是否适用”闭合，不要求四种 Agent 人为发出每一种控制序列。四种 TUI 的
direct/tmux 输入、真实中文输入法、raw/alternate、resize、搜索、SSH 重连和适用的 tmux
detach/reconnect/reattach 已有命名物理证据；Qwen tmux 进一步证明一次原生 OSC 52 写入和
PageUp/`Ctrl+End` scrollback。半开网络检测与重新连接由 1.5 已闭合的 ServerAlive、Session
close/reconnect 和 tmux 持久性合同负责，Agent 只是 PTY 内工作负载，不为其重复建立传输层。

OSC 适用性也以可观察事实闭合：OpenCode direct 原生 OSC 99 通过，OpenCode tmux 上游只查询
能力而不发完成帧；Pi direct/tmux 原生 OSC 777 到达 PTY，但隐藏窗口后的 HarmonyOS 暂停会
阻止较晚输出及时形成系统提醒；所选 Agent 没有 OSC 9 原生样本。四种 Agent 的受控真实渲染
路径均未发 OSC 8 open，LeanTTY 通用 HTTP(S)/OSC 8 激活已有独立终端门禁。继续注入控制序列、
扩大协议、增加常驻解析或额外模型请求只会制造不真实的通过，不改善用户结果，因此停止。

离线指南走查先在测试签名 HAP `3EE504FE...130D39` 上确认本地 `help` 保持技术英文并输出固定
指南链接；HDC 合成鼠标可证明 Ctrl 和链接 hover 分别到达，但不能把鼠标事件自身的 modifier
可靠标记为 Ctrl，因此不拿自动化点击冒充真实 `Ctrl+Click`。通用本地指南打开链路沿用 1.2
已完成的真实鼠标验收，路由代码未改变；同一设备上的系统文件管理器和浏览器随后直接读取
`Downloads/com.leantty.app/LeanTTY-User-Guide.html`，中文 Agent 章节显示正常。

走查英文目录时发现实际缺陷：切换到英文首页后，`#en-agent` 只把子章节设为 `:target`，旧 CSS
却只识别 `#guide-en` 根节点，导致页面回落到默认中文。修复后，语言页自身或其任一后代 target
都会维持同一语言；静态 `web` 门通过，并用新测试签名 ARM64 HAP
`2DB93C2D9D8D1B09F54035B82415184DA0AEFED2433180CF2EFDEA64AFB5A167` 完成红绿真机复验：
`build/verification/agent-guide-fixed-help-output.png` 显示当前 Help 链接，
`agent-guide-zh-section.png` 显示中文 Agent 章节，`agent-guide-en-top.png` 显示文档内英文切换，
`agent-guide-fixed-en-agent.png` 显示英文页内跳转准确落到 `Agent workflow`。该 HAP 是开发期
test-signed 包，不是正式候选。

至此，矩阵、协议入口、通用通知/返回、指南与已知平台边界共同满足 1.5 的 Agent 友好目标，
且没有增加 Agent 状态模型、品牌分支、常驻服务、第二套 Session/attention 所有权或不必要的
Token 消耗。完成事实进入 roadmap，`next-work.md` 不再保留已完成 checkbox。

## 模型请求与成本审计

长期证据可确认共 26 次固定短请求：Codex 2 次、OpenCode 11 次、Pi 5 次、Qwen 8 次。四个工具
都没有提供可与单次 run-scoped 场景可靠绑定的输入/输出 Token 统计，因此统一记录
`unavailable`，不估算为零。超过 direct/tmux 各一次基线的请求都检验了不同假设：区分 OSC
terminator 与 BEL、确认 Qwen 的 focus/approval 条件、验证 tmux `focus-events`、实现 OSC 777、
区分 OpenCode 能力查询与完成帧、启用其 run-scoped attention、把完成时序推迟到失焦之后、
验证能力响应回传、定位启动 prompt 竞态，并分别验证 normal direct、normal tmux 与 tmux 强制
协议边界，最后隔离 HarmonyOS 后台暂停。没有为重复确认同一事实而重跑已通过
的 Codex，也没有用模型执行 BEL、UTF-8、raw/alternate/resize 或清理回归。新增三次 Qwen
请求分别暴露了“等待 OSC 8 不能作为通过门”、整图哈希不能证明 `End` 已回到底部，以及最终
`Ctrl+End` 的正确合同；每次都改变了下一轮断言，没有为相同结论盲目重复。

## 自动化入口与证据边界

2026-08-25 的视觉复查确认，旧隔离 SSH fixture 通过 `bash --noprofile --rcfile` 启动时没有
设置 locale；其 `LANG` 为空且 `LC_CTYPE=POSIX`。普通 Shell、单独 alternate screen 和
OpenCode direct 均能显示中文，只有 tmux 把非 ASCII 输出降级为下划线；同一场景仅设置
`LANG=C.UTF-8`、`LC_ALL=C.UTF-8` 后立即恢复。该现象属于测试环境，不授权修改 LeanTTY
字体、renderer 或 Agent 兼容逻辑。tmux 官方也明确说明它从 `LC_ALL`、`LC_CTYPE`、`LANG`
判断 UTF-8，判断为不兼容时会用下划线替换 UTF-8 字符：
<https://github.com/tmux/tmux/wiki/FAQ#how-do-i-use-utf-8>。

受控服务器现在必须在 Bash 启动前显式设置 `C.UTF-8`，第一次 SSH 连接必须以
`locale charmap` 得到精确的 `UTF-8`，并把规范化结果写入证据；不满足时归类为 environment
failure，禁止继续形成 Agent 兼容结论。旧零模型探针中的 `containsCjkUtf8` 只证明中文输入字节
到达 PTY，不证明 tmux 最终画面正确；视觉结论只能使用 locale 门禁修复后的新证据。清理阶段
还必须用本轮 `sshd.pid` 和唯一 `sshd_config` 核对进程身份，在 WSL 内停止并独立确认其不再
存活，不能只结束 Windows 侧 `wsl.exe` 包装进程后报告清理通过。

修复后的零模型 OpenCode tmux 复测使用未改变的 test-signed HAP（SHA-256
`3EE504FEFACCB1D244A25335749AE6A0A924E1348B99E1E4CE7B6F16C8130D39`），结果在
`build/verification/opencode-tmux-locale-fix-20260825T024000Z/result.json`：
`terminalLocale=UTF-8`、中文 composition、raw/alternate/resize 与清理均通过，独立 WSL
进程检查未发现本轮 sshd；同目录 `opencode-tmux-cjk-fixed.jpeg` 显示 Logo 和输入框“中文”
均正常。随后同步取图的 Codex、Pi、Qwen tmux 证据补齐四种 Agent 的视觉结论。

协议分析器现在只把 OSC 8 非空 URI 帧计作 hyperlink open，并分别记录空 URI reset 与畸形帧；
软件门同时覆盖普通序列和 tmux DCS 包装。清理复核还发现旧 harness 结束 Windows `wsl.exe`
包装进程后，历史上遗留了 40 个严格匹配 `leantty-agent-compat-<GUID>/sshd_config` 的测试
`sshd`。这些残留已按唯一 fixture 身份全部停止；清理逻辑现在检查 TERM 返回、以 root 权限轮询
同一 PID，必要时才对同一已验证 PID 使用 KILL。零模型复测
`build/verification/qwen-direct-zero-model-cleanup-20260825T140157Z/result.json` 通过，独立进程
审计为 `fixture_sshd=0`、`fixture_sudo=0`。因此旧结果中的业务/PTY 结论仍按各自证据使用，但其
“sshd-stopped”字段不能单独作为环境清理证明；后续只接受修正后门禁或独立进程审计。

- `tools/agent-compatibility-wsl.sh`：准备、配置、inventory、Agent 启动、受控 PTY 捕获和清理。
- `tools/agent-compatibility/osc99_capability_probe.py`：零模型查询与无原文能力响应摘要。
- `tools/agent-compatibility/analyze_capture.py`：生成无内容 wire summary 并删除原始捕获。
- `tools/test-agent-compatibility.ps1`：分析器、实际 WSL PTY 和脚本安全合同的软件门。
- `tools/verify-agent-compatibility-pc.ps1`：默认 WSL → OpenSSH → 物理 HarmonyOS PC 的命名场景。

软件门只能证明 helper 合同、分析准确性与真实 PTY harness 可运行；签名 HAP 安装/启动只能证明
候选可部署；只有命名物理场景才可以证明设备上可观察的 Agent 交互。诊断 HAP 证据不能描述为
正式 release candidate、GitHub Release 或 AppGallery 能力。

## 停止与修复判断

若失败来自 Agent 认证、上游版本、服务端环境或测试控制通道，先修复或记录对应边界，不改变
LeanTTY。只有同一失败能在受控普通 SSH/tmux 中稳定复现、影响高频 Agent 工作，并且不能通过
Agent 的公开配置解决时，才评审最小产品修复。修复仍必须复用现有 Terminal Surface、Pane
attention、通知和返回所有权，不能引入按 Agent 解析输出的长期维护面。

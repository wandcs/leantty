# `mosh-client-rs` 接入问题记录

> 状态：Open；LeanTTY 只记录和规避问题，不直接修改 `wandcs/mosh-client-rs`
>
> 审计基线：[`wandcs/mosh-client-rs`](https://github.com/wandcs/mosh-client-rs)
> `e1346b3dfce5c38b95ef43d78cfb3d73529f00e5`（2026-08-31）

本文只记录会阻断或改变 LeanTTY 集成合同的问题。`mosh-client-rs` 的实现缺陷应在其仓库中
独立修复和验证；LeanTTY 不维护协议 fork，也不复制协议实现。

## MCRS-001：缺少可复现的发布来源（Resolved）

**原始证据。** 本地基线 `69450f4` 没有 remote，只能作为 sibling path 依赖；包清单使用
`version = "0.0.0"` 和 `publish = false`。

**解决证据。** 维护者已把仓库公开到 `https://github.com/wandcs/mosh-client-rs`；默认分支
`main` 的审计提交为 `0c841cc61d31cf9dc9e556cf2f25a81520128572`。相对原基线只增加仓库
metadata 和发布/集成文档，没有修改 `src/` 或公共 API。LeanTTY 通过完整 Git `rev` 固定该提交，
Cargo.lock 记录 Git source，因此干净 checkout 和 CI 不再依赖本机目录。

**剩余版本属性。** 远端目前没有 tag，crate 仍是 `0.0.0 / publish=false`。这不阻断按完整 commit
复现 Git 依赖；升级时必须显式评审并更新 `rev`，不能跟随可移动分支。

**状态。** 依赖来源问题已关闭。正式候选仍需从干净 checkout 重跑许可证、供应链、ARM64 构建
和真机门禁，但这属于 LeanTTY 发布验证，不再是库来源缺陷。

## MCRS-002：公共生命周期不提供中断与恢复状态（Resolved）

**原始证据。** 修订 `2db538a` 的公共 `SessionState` 只有 `Connecting`、`Active` 和 `Closed`。
`Active` 不表示当前网络可达，LeanTTY 不能用 UI 定时器、未认证流量或“若干秒无输出”伪造
`interrupted` 或 `restoring`。

**解决证据。** 修订 `cbc069c` 保持单调生命周期，并新增独立、latest-value 的
`SessionReachabilityWatch`。LeanTTY 在 Session 创建后订阅观察器，先发送 `current()`，再消费
`changed()`：`AwaitingPeer` 保持连接中，`Responsive` 表示正常，`Interrupted` 只把 Pane 状态点
改为警告色；从 `Interrupted` 回到 `Responsive` 即恢复连接色。LeanTTY 不复制 6.5/10 秒阈值，
也不增加 `Restoring` 定时状态。首次 15 秒没有认证远端状态时，
`SessionError::ConnectionTimeout` 进入普通连接失败路径。

HAD-W32 使用 stock 1.4.0 和动态 UDP 60001。精确双向丢弃约 7.9 秒后，当前 ARM64 HAP 收到
`Interrupted(NoRecentContact)`，Session、server 与远端 PTY 均存活；删除规则后收到
`Responsive` recovery，同一 PTY 执行新命令成功，随后完成认证关闭和全部清理。证据为
`build/verification/device-mosh-20260830T131919121Z/device-mosh.json`。

**状态。** 公共状态缺口已关闭。`Interrupted` 不是完成事件，不能关闭 Pane 或 Session。

## MCRS-003：部分本地 UDP 发送错误会终止 Session

**证据。** Session 直接等待 `UdpSocket::send_to`；错误进入 `SessionError::Io`。项目文档把“选定
本地 UDP 发送错误的恢复”列为延后项。当前公共 API 也不允许调用方替换 socket 或提交临时错误
分类。

**影响。** HarmonyOS 在网络切换、锁屏或恢复时若短暂返回可恢复的 socket 错误，Session 可能
在 Mosh 本应保持的场景中关闭。现有 Linux loopback 的丢包和源端口变化证据不能排除此风险。

**临时边界。** 不在 LeanTTY 捕获字符串后自动重建 Session，也不把失败隐藏成恢复。首次真机
纵向切片必须记录原始 `ErrorKind` 的安全类别、Session 是否关闭以及远端 shell 是否仍存活。

**当前物理证据。** 精确 UDP 丢弃只产生网络静默，没有产生本地 socket 错误，Session 和远端
shell 均存活并恢复。因此该场景没有命中终止性 `SessionError::Io`，也不能关闭网络切换、锁屏
或接口变化时的 MCRS-003 风险。后续只在这些真实平台场景出现本地 I/O 错误时记录安全类别，
不为了制造错误而替换产品 socket。

**关闭条件。** 物理 PC 证明目标场景不产生终止性错误；或者 `mosh-client-rs` 用明确白名单、
有界重试和回归测试处理已验证的临时错误。

## MCRS-004：网络静默与 server 消失没有可信终止信号（Resolved as non-goal）

**证据。** 修订 `cbc069c` 用认证关闭报文区分 peer graceful close，并用
`Interrupted(NoRecentContact|NoRecentReply)` 表示临时可达性警告；网络静默仍不会自动完成
Session，因为它不能区分可恢复路径故障、休眠、地址变化和 server disappearance。

**产品决定。** LeanTTY 不需要自动识别 server disappearance。`Interrupted` 只警告当前屏幕或
输入确认可能过期；Pane 与 Session 保持活动，认证关闭仍是唯一远端正常结束，用户可用
`Ctrl-^ .` 主动关闭。产品不增加静默定时器、进程探针或自动重连。

**临时边界。** 最小联调把 `LocalClosed`、`RemoteClosed` 视为正常结束，把本地 I/O、协议、资源、
内部错误与意外 hard stop 视为失败。网络静默保持会话，用户可用 Mosh escape 主动关闭。

**物理触发证据。** HAD-W32 的正常 Session 已完成一条精确命令后，对受控 stock server PID
发送 `SIGKILL`。约 5 秒观察窗内，远端 terminal PID 已退出，但库没有 close/error，LeanTTY
仍保持连接态；用户必须执行 `Ctrl-^ .`。由于 peer 不存在，关闭没有认证 ACK，库在 hilog 中
从 escape 到 `SessionExit::LocalClosed` 用时 4006 ms，符合 4 秒 ACK 上限加调度粒度；本地
`ltty>`、Preferences、secret 与清理检查均通过。证据为
`build/verification/device-mosh-20260830T113943049Z/device-mosh.json`。

当前 ARM64 HAP 再次对精确 server PID 发送 `SIGKILL`。约 6.6 秒后 LeanTTY 收到
`Interrupted(NoRecentContact)`，没有自动 close/error；用户执行 `Ctrl-^ .` 后，本地关闭用时
4005 ms，并完成提示符、Preferences、secret 和清理检查。证据为
`build/verification/device-mosh-20260830T132741950Z/device-mosh.json`。

**状态。** 按维护者确认的 warning-only 合同关闭。本项不声称能识别 server disappearance；
如果未来要自动失败，必须重新提供可认证关闭或明确平台错误证据。

## MCRS-005：本地取消不通知 stock server 终止（Resolved）

**证据。** 在 HarmonyOS PC 上通过 stock `mosh-server 1.4.0` 建立真实 UDP Session 后，
LeanTTY 的 `Ctrl-^ .` 已触发本地 `Session::cancel()`、关闭 UI Session，但 detached server 在
20 秒后仍存活。固定 revision 的公共 `Session::cancel()` 只设置本地 cancellation watch；API
没有 graceful remote shutdown。官方 `mosh-server(1)` 说明 server 应在客户端终止连接时退出，
同时说明没有收到更新时由 `MOSH_SERVER_NETWORK_TMOUT` 控制回收。

**影响。** 用户主动断开后，远端 `mosh-server` 和 PTY 可能一直保留到服务器自己的网络超时；
未设置该变量的服务器甚至可能无限等待。LeanTTY 不能从应用层安全伪造协议 shutdown，也不能
通过 SSH 回连后按进程名杀死不属于当前 Session 的 server。

**解决证据。** 修订 `2db538a` 新增 `Session::close()`、`SessionExit::LocalClosed` 与
`RemoteClosed`，实现 stock 1.4.0 兼容的认证关闭、重传和最长 4 秒 ACK 等待；`cancel()` 继续用于
立即停止。LeanTTY 在用户主动关闭时先提交已排队输入，再调用 `close()`，等待期间持续消费最终
输出；callback、协议错误和所有者 teardown 仍走 hard cancellation。

上游 locked 全目标/全 feature 测试通过 109 项，21 项 stock 黑盒测试按声明忽略；其中本地主动
关闭 server、远端关闭与最终输出排空两项又在本机 stock 1.4.0 上显式运行并通过。物理 HAD-W32
场景把 `MOSH_SERVER_NETWORK_TMOUT` 从 5 秒延长到 30 秒，并要求 8 秒内观察精确 server PID
消失；test-signed HAP 的 `Ctrl-^ .` 使 server 在 96 ms 内退出，同时完成精确命令、本地提示符、
secret 审计和 fixture 清理。证据为
`build/verification/device-mosh-20260830T082437253Z/device-mosh.json`。

**状态。** 关闭条件已满足。后续修订 `cbc069c` 已独立关闭 MCRS-002；MCRS-003 仍保持
证据触发，也不把网络静默解释成断开。

## MCRS-006：ARM64 公共 Session 没有产生 prediction 输出

**状态。** Resolved。固定修订 `e1346b3` 已在库侧 stock 1.4.0 测试和 LeanTTY HarmonyOS ARM64
产品链路中同时证明公共 `Session` prediction；LeanTTY 未复制预测状态机或增加产品 workaround。

**已解决。** 修订 `cdb8719` 新增公共
`PredictionMode::{Adaptive, Always, Never}` 和 `Session::connect_with_prediction_mode`，并保持
`Session::connect` 默认使用 `Adaptive`。模式和 adaptive 状态由每个 Session 独立拥有。LeanTTY 已
固定该修订，并把严格枚举从 parser 经 Pane、N-API 传入库；无效、重复或非标准值在联网前失败。

官方 [`mosh.pl`](https://github.com/mobile-shell/mosh/blob/master/scripts/mosh.pl) 接受
`adaptive`、`always`、`never` 和实验模式。标准默认值是 `adaptive`；`always` 在快速链路也使用
本地回显，`never` 禁用本地回显。LeanTTY 不采用实验模式或 `--predict-overwrite`，也不把
`adaptive` 改名为非标准的 `auto`。

**库侧关闭证据。** 2026-08-31 在 `e1346b3` 上运行库自带的 stock 1.4.0 prediction 测试通过：40 ms
和 80 ms 单向延迟下，`always` 与 `adaptive` 在前三个权威回显后把后续可预测 ASCII 的中位可见
延迟降为 0 ms，`never` 仍等待远端。新增公共全丢包用例通过正常 PTY 内核 echo 建立 confirmed
epoch：第 4 个 `Always` warmup 字节以 0 ms 显示；双向 relay 完全暂停后，下一个 `Always` ASCII
仍以 0 ms 从公共 VT 输出出现，`Never` 在恢复前没有输出；两边各丢弃 2 个 datagram，恢复后各自与
stock 权威屏幕收敛。该提交的格式、Clippy 和 locked 全目标/全 feature 测试同时通过：127 项通过，
23 项依赖 stock 二进制的测试按声明忽略。

**最新上游修复审计。** `e1346b3` 在 `383b10a` 的中性 authenticated-update 修复上，将 echo
acknowledgement 保存在权威 `TerminalState`，允许 acknowledgement 与 HostBytes 在不同认证差异中
以任意顺序到达；tentative epoch 可收集多个候选，并只确认与权威显示等价的最长前缀，ACK 不能
越过尚未匹配的 host effect。新增确定性测试和 64-case property test 覆盖两种到达顺序、伪造或
过快 ACK 以及 display-equivalent 前缀。该修改没有扩大协议、公共 API、可预测字符或资源边界。

LeanTTY 的旧 ARM64 诊断则在四个逐字权威回显后双向丢弃精确
UDP 端口；`always` 在丢包期间没有产生非零 VT 输出，恢复 UDP 后才输出并收敛。证据为
`build/verification/device-mosh-20260830T172832656Z/device-mosh.json`；设备、fixture、网络规则和
临时目录均清理完成。

该真机 fixture 使用 `stty -echo` 加用户态回写记录精确输入，不能证明 stock PTY 的内核 echo
acknowledgement 已建立 confirmed epoch，因此只作为被修正版替代的历史证据。

**修正版真机证据。** 最新固定修订 `ba4b649` 的 ARM64 candidate HAP SHA-256 为
`ebc89d79aef7835ae6e8cefd9287e68cfe3aa455e330c55dea638d2812b96939`。其证据
`build/verification/device-mosh-20260830T193121458Z/device-mosh.json`
使用正常 PTY 内核 echo、真实 `PS1=MOSH_SESSION> /bin/sh -i` 和两个独立方向的 40 ms UDP relay；
测量期间只逐个发送 ASCII，没有 Enter、控制字符、resize 或 repaint。`Always` 的 10 个 warmup
字符实际 VT 可见延迟为 107、151、127、119、157、119、118、116、145、142 ms，没有一个低于
40 ms；测试在阻断 UDP 前按门禁停止。一次仅用于定位的 native 计时证明公共 `Session` 输出本身
需要 116–139 ms，N-API/ArkTS 只增加 0–2 ms，renderer ACK 再增加 1–2 ms；定位埋点随后删除。

为排除调用方干扰，LeanTTY 还删除了连接成功后重复提交初始尺寸的 resize；结果不变。更早的
自定义 PTY reader 与单任务 relay 也分别替换为上游等价的真实 shell 和双向独立 relay；结果仍
不变。本次失败证据中的即时 fixture 清理字段为 `false`，不能声称场景内清理门通过；脚本返回后
独立 WSL 进程审计确认 server、terminal 和 fixture 均已不存在，临时目录也已删除。到此没有证据
支持在 LeanTTY 的 N-API、ArkTS 或 renderer 层增加计时器、overlay 或预测状态机。

**修复后真机复测。** 修订 `383b10a` 的 ARM64 原生库 SHA-256 为
`EB5BAD11B8C01A00CA088134956CD8369FFC0AB5A8175E55C951E4FD22374866`，test-signed HAP
SHA-256 为 `887691e6c0491d7652b968f46f18d7e371e3d2c8371baeb0948de895fdb5e3d1`。证据
`build/verification/device-mosh-20260831T020847661Z/device-mosh.json` 使用相同正常 PTY、真实
shell、40 ms 双向独立 relay 和单字节 ASCII 合同；10 个 `Always` warmup 字节的公共 VT 可见
延迟为 125、122、129、119、120、120、118、150、121、156 ms，仍没有一个低于 40 ms，因此
在阻断 UDP 前按门禁停止。UiTest 输入 6 次均无 mismatch，测量期没有 Enter、控制字符、resize
或 repaint。场景返回后独立审计确认 mosh-server、terminal 和 fixture 进程均不存在，临时目录
已删除。这个结果证明 `383b10a` 的修复不足以关闭 ARM64 症状，不证明新增状态机逻辑本身错误。

**历史最小复现边界。** 以修订 `383b10a` 构建 ARM64 native，调用
`Session::connect_with_prediction_mode(..., PredictionMode::Always)`，连接 stock 1.4.0 的正常
交互 shell；通过双向独立 40 ms relay 逐字发送 `abcdefghijk`，并持续消费公共 `next_output()`。
预期在 confirmed epoch 后至少一个字符低于 40 ms；实际每个非零输出都在 118–156 ms 后出现。
`e1346b3` 的 order-independent confirmation 修复关闭了这个复现；LeanTTY 仍不直接修改库。

**最终真机证据。** `e1346b3` 的 ARM64 原生库 SHA-256 为
`080B4E1DE205AE1EAE5896E7B01B39025E4D0B5F100E8F6D871DEC5A2A6BFAAC`，test-signed HAP
SHA-256 为 `d2bbc45eeb18dcd625ac2c032789a0b7e3ee327894dce1b6a98347d5f03dae65`。证据
`build/verification/device-mosh-20260831T042441659Z/device-mosh.json` 使用正常 PTY 内核 echo、
真实 `/bin/sh -i`、双向独立 40 ms relay 和公共 VT/renderer ACK 时间线。RTT 基线为 128 ms；
`Always` 第二个 warmup 字节在 1 ms 可见、2 ms 渲染，完全暂停双向 UDP 后下一个 ASCII 仍在
1 ms 可见、3 ms 渲染，relay 丢弃 13 个 datagram；`Never` 首字节等待 134 ms。恢复后的权威
状态收敛、两个 Session 隔离、首个 Session 的认证关闭、最终真实 shell 命令、零输入 mismatch、
Preferences 不变和成对清理全部通过。场景结束后独立 WSL 审计再次确认没有 mosh/fixture 进程，
临时目录不存在。该记录是开发期诊断，`acceptanceEligible=false`。

两次先行运行分别在
`build/verification/device-mosh-20260831T041422462Z/device-mosh.json` 和
`build/verification/device-mosh-20260831T042027187Z/device-mosh.json` 暴露 fixture oracle 问题：
第一版用复杂 shell 命令证明收敛，却没有精确的当前行权威；第二版又在真实 `/bin/sh -i` 中调用
只属于自定义 fixture reader 的 `ltty-mosh-check`。两者均归类为 harness failure，不改变已经观测到
的产品 prediction。最终 fixture 改为在同一真实 shell 中提交 `touch -- <run-owned-safe-path>`，并
等待精确 marker；工具回归固定该边界。

**物理 harness 调研记录（2026-08-31）。** 问题是当前 HarmonyOS UiTest 是否能可靠提交组合键，
以及真实交互 shell 应如何提供不干扰 prediction 的收敛 oracle。OpenHarmony arkXtest 的
[`uiInput keyEvent` 组合键说明](https://gitee.com/openharmony/testfwk_arkxtest/pulls/612)确认命令接受
多个 key code；本机真机通道也已使用 `Ctrl+U` 清空当前行。`mosh-client-rs` 的
[`stock prediction fixture`](https://github.com/wandcs/mosh-client-rs/blob/e1346b3dfce5c38b95ef43d78cfb3d73529f00e5/src/session/tests/stock/prediction.rs)
与本机证据一致要求正常 PTY 内核 echo 和真实 shell。没有权威接口能直接读取远端 PTY 当前行，
因此仍以不进入测量窗口的 shell-safe marker 作为恢复后 oracle；测量窗口继续禁止 Enter、控制
字符、resize 和 repaint。本记录适用于 HAD-W32、HarmonyOS 6.1.1.130 和 UiTest 6.0.2.3；未发现
来源冲突，未解决边界仅为平台不提供精确 PTY 当前行 oracle。

三种模式必须继续遵守现有认证权威和资源边界：预测不能修改 authoritative terminal state；
`always` 不能扩大到当前未支持的 Unicode、paste、backspace 或控制序列；`never` 不得产生预测
projection；`adaptive` 由库根据自己的可验证信号决定何时显示。分歧、超限、过期、repaint、
resize、关闭、取消和 owner drop 仍按库的统一状态机处理。

现有公共 API、低/高延迟、默认值、Session 隔离、32 scalar、32 byte、10 秒和单 projection 测试
继续保留。新增全丢包用例不能用私有 driver 或内部状态代替公共 `Session` 输出。

**关闭条件。** 新的固定库修订先用公开 ARM64 复现或等价测试证明 `Always` 从公共 Session 产生
低于 RTT 的输出；随后 LeanTTY 用同一 ARM64 HAP 证明 `adaptive` 默认值、`always` 与 `never`
的真实终端显示差异、全丢包行为、Session 隔离、认证关闭和清理。

**关闭结论。** 上述库侧和真机证据已满足关闭条件；活动清单不再保留 prediction TODO。

## MCRS-007：公共地址合同仅支持 IPv4（Deferred）

**状态。** 不阻塞 IPv4-only 的 1.6；阻塞未来 IPv6 与 `-6`/`--family=inet6`。固定修订
`e1346b3` 的 `Bootstrap::parse` 接受 `Ipv4Addr`，保存并公开 `SocketAddrV4`；Session driver 也绑定
`0.0.0.0`，来源验证和迁移合同均以 IPv4 endpoint 为边界。LeanTTY 当前只能从
`SSH_CONNECTION` 提取 server-side IPv4，并在遇到 IPv6 时于创建 UDP Session 前失败。

这不是 LeanTTY 可以用类型转换或双 socket wrapper 规避的问题：地址族参与 socket 绑定、peer
来源认证、roaming 更新和所有公开测试。LeanTTY 不 fork 库、不在调用侧复制 transport driver，
也不接受 `-6` 后回落 IPv4。

2026-08-31 的环境盘点同时确认 HAD-W32 只有 `wlan0` link-local IPv6，没有全局地址或 IPv6
默认路由；Windows/WSL 的有线全局 IPv6 不与设备共享二层链路。因此即使公共 API 立即扩展，当前
设备也不能提供合格的真机 IPv6 门禁。官方 Mosh 的 `-4/-6` 同时选择 SSH 和 Mosh Session family，
LeanTTY 已据此把 IPv6 从 1.6 roadmap 裁剪，并明确拒绝 address-family options。

**重新进入条件。** 库仓库提供经过 stock IPv4/IPv6、错误 family、来源变化和 roaming 测试的
`IpAddr`/`SocketAddr` 公共合同；测试 PC 获得可重复的全局 IPv6/default route 或同链路 link-local
fixture；LeanTTY 再用同一 ARM64 HAP 证明 SSH bootstrap 与 UDP family 一致、IPv6 literal/Host、
关闭和清理。届时升级完整 Git revision，不直接修改本地库。

## MCRS-008：公共 VT 输出没有保留 alternate-buffer 边界

**状态。** Closed as contract clarification；`mosh-client-rs` 明确公共输出只代表远端当前可见
画面，不提供 Vim、`less` 等应用进入和退出临时屏幕的可靠边界。LeanTTY 不再等待上游增加这类
事件，也不声称 Mosh 与 SSH 具有相同的字节流历史。

**物理证据。** HAD-W32 通过 stock `mosh-server 1.4.0` 运行 DEC 1049 fixture。进入页只显示
`LTTY_MOSH_ALT_ACTIVE`；发送一个受控按键退出后，当前屏同时显示 active 内容、
`LTTY_MOSH_ALT_CLOSED` 和提示符，终端搜索也能再次找到 active 标记。真实 Vim 可以编辑、保存
并退出，但其 `~` 屏幕行同样留在后续本地历史。证据为
`build/verification/device-mosh-20260831T141514450Z/device-mosh.json` 及同目录的
`mosh-alternate-active.png`、`mosh-alternate-closed.png`。同一运行的 Preferences、secret 和
成对清理均通过。

**边界。** `Session::next_output()` 给 LeanTTY 的 VT 差异足以重绘当前远端屏幕，却没有让调用方
恢复本地 alternate buffer。因此 LeanTTY 不能把应用级临时屏幕映射到本地页面，也不能承诺与
SSH 直接转发应用 VT 序列相同的会话内历史。

**LeanTTY 合同。** 每个 Mosh Session 在首段 Mosh 输出前封存原页面，并创建一个独立的整段
Session 页面。所有 Mosh 输出和 repaint 只进入该页。正常关闭、取消、异常结束或 Pane 销毁时，
先消费已经交付的输出，再丢弃整个 Mosh 页并恢复原页面。实现不解析输出，不猜测应用生命周期，
也不复制 `mosh-client-rs` 的终端状态机。

**闭合证据。** xterm 实测矩阵覆盖原页面恢复、Mosh 与远端 alternate-buffer 内容从搜索历史
移除、Surface 快照重建和独立 Pane 状态；ArkTS 合同覆盖首段输出排队、全页替换 ACK、结束
顺序和旧 Mosh client 回调隔离。HAD-W32 的 stock `mosh-server` 诊断进一步证明正常关闭、
受控异常结束、ArkWeb Surface 重建、Pane 销毁、双 Mosh 与 SSH/Mosh 并存隔离；各场景均完成
Preferences、secret、进程、fixture 和临时目录清理。证据分别位于
`build/verification/device-mosh-20260831T154604274Z/device-mosh.json`、
`build/verification/device-mosh-20260831T155140309Z/device-mosh.json`、
`build/verification/device-mosh-20260831T155423325Z/device-mosh.json`、
`build/verification/device-mosh-20260831T160503963Z/device-mosh.json` 和
`build/verification/device-mosh-20260831T161711503Z/device-mosh.json`。

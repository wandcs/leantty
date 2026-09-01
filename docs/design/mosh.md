# Mosh 弱网连接技术方案

> 状态：Implementing；维护者已授权本地纵向切片，正式候选仍取决于目标平台证据
>
> 当前 milestone：1.6
>
> 更新日期：2026-08-31
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：已进入 [`next-work.md`](../next-work.md)；当前使用固定公共 Git revision 继续开发

> 命令面治理：[`command-system.md`](command-system.md)

## 用户问题与目标

SSH 可以检测半开连接并重连，但合盖、短暂离线、网络抖动或地址变化通常仍会终止
当前远端 shell。Mosh 的价值候选是让交互式终端在这些变化后继续，而不是把 LeanTTY
定位成移动终端或承诺永久在线。

目标是在物理 ARM64 HarmonyOS PC 上确有持续弱网问题时，提供一个明确的 Mosh
Session：SSH 只负责安全 bootstrap，Mosh 负责随后可恢复的交互式终端同步。

## 进入前必须建立的证据

- 在目标 PC 的办公、合盖、锁屏、Wi-Fi 抖动和网络切换场景建立 SSH 断线分布与用户
  影响基线，证明问题持续存在且重连不能满足核心工作。
- 确认目标用户控制的主要执行环境可以安装并运行兼容 `mosh-server`。
- 确认 HarmonyOS 三方应用的 UDP、后台/休眠和网络变化能力足以支撑协议恢复。
- 先测量收益，再确定恢复时间、丢失率和性能门槛；不以功能存在本身作为版本理由。

### 2026-08-29 环境门：有线 endpoint 已闭合

本轮固定使用 HAD-W32、OpenHarmony 6.1.1.130、`arm64-v8a` 物理 PC。设备控制预检通过；
测试只使用系统可见入口、HDC 诊断和一次性用户态 socket，没有修改 LeanTTY 产品代码。

默认 WSL 为 Ubuntu 26.04、Linux 6.18.33.1、x86_64，运行 OpenSSH 10.2p1。已安装 Ubuntu
官方 `mosh 1.4.0-1ubuntu5`；包元数据 SHA-256 为
`ac8f265c8fd91cfb1420695b14c8e281ba4825ea52654a2838d3e26f6f065adc`。一次性运行证明
`mosh-server` 能在固定 UDP 端口启动，输出合法 `MOSH CONNECT` bootstrap，建立监听，
再按精确 PID 退出；临时 key 未写入日志，端口和进程均无残留。

候选上游为 `mobile-shell/mosh`。官方最新 release 仍为 1.4.0；tag object 是
`094fdba5ca7566efd98e1c36fb2295ef508c145a`，peeled commit 是
`bc73a26316ede2a79259d859f8ee309b32412420`。官方合同确认 SSH 只负责启动 server 和传递
临时 key，随后使用 UDP；默认端口范围是 60000–61000，`-p` 可固定端口。

有线网络固定使用 Windows/WSL 的 `192.168.1.4`。真机先通过 `192.168.1.4:2222` 取得
WSL OpenSSH banner，再使用 `192.168.1.4:60042/UDP`。管理员把 Windows Defender Firewall
和 WSL Hyper-V Firewall 的临时规则都限制为 UDP 60042、本地 `192.168.1.4`、远端
`192.168.1.0/24`；测试没有依赖 WLAN 或 HDC 端口映射。

HDC shell 自带 Toybox `netcat` 创建 UDP socket 时返回 `setsockopt: Permission denied`，因此
它不能充当 sender，该失败不属于网络证据。真机 HSL/openEuler 可作为环境探针；其默认 `zsh`
不支持 `/dev/udp`，显式调用 `bash -c` 后，WSL 完整收到 41 字节 allow 标记。规则从 Allow
切到 Block 后立即发送的数据报落入规则生效窗口，不能作为阻断证据；规则稳定后，相同端点的
30 秒监听收到 0 字节。规则恢复 Allow 并稳定后，WSL 完整收到 11 字节恢复标记。

同一端口上的真实 `mosh-server 1.4.0` 再次输出合法 `MOSH CONNECT 60042`，生成 22 字符
临时 key 并建立 UDP 监听。探针只在权限为当前用户的 WSL 临时目录中短暂保存 bootstrap，
没有输出 key；退出后确认监听、进程和临时 secret 文件均不存在。最终审计也确认两条精确
防火墙规则、UDP 60042 listener、探针脚本和原始数据已全部删除。

该结果闭合了“真机可达的兼容 server、固定 UDP allow/drop/恢复和清理”环境门。HSL 仍没有
可安装的 `mosh-server`：`dnf --disablerepo=source info mosh` 返回
`No matching Packages to list`，openEuler 官方 aarch64 包索引也未找到 `mosh`。本次环境证据
不替代后续 HarmonyOS 三方应用 UDP、后台/休眠和网络变化能力门禁，也不证明 Mosh 已值得实现。

### 2026-08-30 继续决定

现有 SSH 在测试机关闭 Wi-Fi 后直接结束并退回 `ltty>`；远端进程 PID 和 shell 变量没有保留。
这证明当前 SSH 重连不能保持该工作现场。维护者随后完成独立 Rust Mosh client，并明确授权
LeanTTY 依赖它继续开发。因此本地最小纵向切片进入实现阶段。

该决定不把主机间 UDP 探针或库的 ARM64 编译提升为 HarmonyOS App 恢复证据。正式候选仍须在
同一物理 PC 上验证应用 socket、网络变化、锁屏、休眠、取消和清理；收益不足或恢复失败时删除
Mosh 产品路径。

### 2026-08-30 真机场景 fixture 调研记录

本任务要解决的精确问题是：如何在不保存 bootstrap 密钥、不依赖固定 UDP 端口、也不把
HDC 端口映射误当成真实网络的前提下，为 HarmonyOS PC 建立可重复、可清理的 stock Mosh
Shell oracle。适用环境仍是 HAD-W32 / OpenHarmony 6.1.1.130、Windows 11、mirrored-mode WSL
Ubuntu 26.04 与 `mosh-server 1.4.0`。

本轮复核的主来源及结论如下：

- 官方 [`mosh-server(1)`](https://github.com/mobile-shell/mosh/blob/master/man/mosh-server.1)
  规定 server 默认选择 60000–61000/UDP，`-p` 可固定端口，stdout 返回客户端所需端口和一次性
  key；60 秒内没有客户端会退出，客户端正常终止后 server 也会退出。production 命令继续让
  server 选端口；受控 fixture 也走同一默认选择路径，只把选中的 port/PID 写入控制文件，
  bootstrap 原文只经过 SSH channel，不进入证据。
- 官方 [`mosh.pl`](https://github.com/mobile-shell/mosh/blob/master/scripts/mosh.pl) 仍采用 SSH
  bootstrap 后切换 UDP 的两段路径，并从 server 输出解析连接参数。它与 LeanTTY 的固定远端
  bootstrap 命令一致；fixture 只在受控用户收到这个精确命令时替换末端 PTY，不放宽产品命令。
- Microsoft 的 [WSL 网络文档](https://learn.microsoft.com/en-us/windows/wsl/networking) 和
  [WSL troubleshooting](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting) 说明 mirrored
  mode 可从 LAN 直接访问 WSL，但 Hyper-V firewall 仍可能要求显式规则。现有 2222/TCP 是 Windows
  `portproxy` 到 WSL `127.0.0.1:22`；此前 60042/UDP 的成功路径是 mirrored WSL 直达加两层 firewall，
  不是 UDP portproxy。Microsoft 的
  [`netsh interface portproxy`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-interface)
  只支持 TCP，因此 fixture 使用持久的 `192.168.1.4:2223/TCP -> 127.0.0.1:32223/TCP`，UDP
  继续由 mirrored WSL 在 server 选中的 60000–61000 端口直接监听。Microsoft 的
  [`New-NetFirewallRule`](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule)
  和 [`New-NetFirewallHyperVRule`](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallhypervrule)
  都接受端口范围；Windows 与 WSL creator 对应的 Hyper-V 入站规则因此限制为本机
  `192.168.1.4`、远端 `192.168.1.0/24` 和 UDP 60000–61000。现有 2222 不动。
- HarmonyOS 的
  [NetConnection API](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/_net_connection-V14)
  和[网络连接管理](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V3/js-apis-net-connection-0000001333720849-V3)
  支持 Internet socket、网络绑定与 Ethernet bearer，但没有为本应用的后台恢复给出自动保证。
  所以本场景只证明有线前台 Shell，网络切换、锁屏和休眠仍保留为后续独立真机门禁。

来源在 server 生命周期、SSH/UDP 分段和有线直连模型上没有冲突。当时固定的 `mosh-client-rs`
修订已暴露认证 graceful close，但还没有独立 reachability；本场景不能借 UI 定时器伪造状态。
实际键盘注入所用 Ctrl、Shift、6、句点 keycode 由本机
DevEco SDK 6.0.0.107 的 `oh_input_manager.h` 复核，最终仍以真机控制 PTY 收到精确输入及 server
退出作为 oracle。

### 2026-08-30 持久测试网络与真机结果

`tools/configure-mosh-test-network.ps1` 是该机器上唯一的 Mosh 测试网络入口。`Enable`/`Disable`
需要管理员权限，`Status` 只读且不提权；脚本拥有一个 2223 TCP portproxy 和四个稳定命名规则，
发现同端口冲突或规则漂移时拒绝覆盖。一次性迁移已把两条旧 60042 规则替换为两条
60000–61000 规则；迁移后的普通权限 `Status` 和两次诊断读取均为 `ready`，旧规则不存在，2222 与
2223 同时存在且状态不变。日常 `tools/verify-mosh-pc.ps1` 只校验这些状态，不创建或删除规则。

真实 HAD-W32 场景已完成 2223 SSH 主机校验/密码认证、stock server bootstrap、动态 UDP
Session 和受控 PTY 精确命令。fixture 没有传 `-p`，stock 1.4.0 实际选择 60001；它把
`MOSH CONNECT` 写到 stdout、detached PID 写到 stderr，fixture 分流解析且不记录 key。

首轮真机关闭暴露出 ArkWeb 有序 ACK 队列被零长度 Mosh repaint 输出占满：Web 端二进制协议拒绝
零长度 payload，因此后续 Session reset 永远得不到 ACK。Bridge 现在把零长度终端写入作为成功的
no-op，不让它进入有序队列。修复后的同一场景已证明 `Ctrl-^ .`、reset 写入、输出锚定、本地
`ltty>`、视口恢复、立即输入和设备状态清理全部完成；证据为
`build/verification/device-mosh-20260830T065111115Z/device-mosh.json`。

升级 `mosh-client-rs` 后，LeanTTY 把本地主动断开改为认证 `Session::close()`，等待时继续消费
最终输出；错误和立即 teardown 才使用 `cancel()`。收紧后的 fixture 把
`MOSH_SERVER_NETWORK_TMOUT` 延长为 30 秒，并要求 8 秒内观察 server PID 消失，排除网络超时兜底。
HAD-W32 上的 stock 1.4.0 server 实际在 `Ctrl-^ .` 后 96 ms 退出，精确命令、本地 `ltty>`、
secret 审计和全部临时状态清理同时通过；证据为
`build/verification/device-mosh-20260830T082437253Z/device-mosh.json`。详细库边界见
`mosh-client-rs-integration-issues.md`。

动态端点的首次诊断在 bootstrap 前因 UiTest 无法精确准备本地命令而停止，证据将其归为 harness
失败并证明 fixture、设备状态和临时目录已清理。未修改产品或协议代码的原样重跑随后通过：端口
策略为 stock 默认 60000–61000，实际端口 60001，认证 bootstrap、UDP、精确命令、`Ctrl-^ .`、
90 ms 认证关闭、最终提示符、secret 审计和全部清理均成功。证据为
`build/verification/device-mosh-20260830T084641199Z/device-mosh.json`；这是开发期命名场景，
不是正式 release acceptance。

同一诊断随后扩展为真实兼容工作负载。受控 PTY 只负责非秘密结果和清理，依次启动实际
GNU Bash 5.3、tmux 3.6 与 Vim 9.1；512 字节输入和 32 个交错输出帧闭合双向持续流，Terminal
Search 证明最终 marker 可见且终端不存在 `MOSH CONNECT`。真实 HarmonyOS 最大化使远端
`stty size` 改变，恢复后 terminal Web 仍保持 focused，物理 `Ctrl-^ .` 到达 Session 并让 stock
server 在 97 ms 内认证退出。两次早期尝试因把 resize 后短暂缺失的 UiTest 隐藏 textarea 当作
物理键前置条件而停在 harness；修正后的 oracle 以 focused terminal surface 和真实 server close
为准，不点击终端或放宽产品行为。Preferences 前后 SHA-256 相同，hilog、fixture、终端与清理
证据均未暴露 bootstrap secret，设备状态、进程和临时目录全部清理。通过证据为
`build/verification/device-mosh-20260830T091908411Z/device-mosh.json`；其签名 HAP SHA-256 为
`69431f60b4ea58f982c642efb10a59f1c17d73f8424408fcce5cb052c5161171`，仍是开发期诊断。

同一 HAP 随后完成两个网络生命周期诊断。`pause-recovery` 在 stock server 选择动态 UDP 60001
后，临时为 WSL `eth0` 增加自有 `clsact`，只按该端口双向丢弃约 6.2 秒；Session 没有 close/error，
server 与 terminal PID 均存活，删除规则后同一 terminal PID 执行新命令成功。规则在场景与
`finally` 中成对清理，独立复核没有残留；随后认证关闭让 server 在 92 ms 内退出。证据为
`build/verification/device-mosh-20260830T113251351Z/device-mosh.json`。

`server-disappearance` 在基线命令后对精确 server PID 发送 `SIGKILL`。远端 terminal 随之退出，
但 5 秒内库没有 close/error，Session 仍等待网络恢复；用户执行 `Ctrl-^ .` 后，本地关闭在 hilog
记录的 4006 ms 内完成，没有声称远端认证 ACK。该场景证明手动关闭、提示符、Preferences、secret
和清理可靠，也实际触发 MCRS-004；它没有提供自动判断 server 消失的依据。证据为
`build/verification/device-mosh-20260830T113943049Z/device-mosh.json`。两项都是开发期诊断，
不会把 WSL 进程探针或静默计时器带入产品。

### 2026-08-30 reachability 调研、实现与真机结果

本任务要确认：应用应如何展示短暂网络中断、恢复和 server 静默，同时不破坏 Mosh 的可恢复
Session。适用版本为 stock `mosh-server 1.4.0`、`mosh-client-rs` 提交 `cbc069c`、
OpenHarmony 6.1.1.130 和 DevEco SDK 6.0.0.107。

- [Mosh 官方说明](https://mosh.org/)明确要求网络中断时警告用户，并在网络恢复后继续原 Session；
  三秒 heartbeat 用于提示近期没有远端联系，不把静默定义为断开。
- [`mosh-client-rs` 决策记录](https://github.com/wandcs/mosh-client-rs/blob/cbc069cc82c02d8919d419b9249297c8888fe1a3/docs/decisions/0009-session-reachability.md)
  把 reachability 与单调 Session lifecycle 分开：6.5 秒无新认证远端状态为
  `NoRecentContact`，10 秒无客户端状态确认进度为 `NoRecentReply`，首次 15 秒无认证远端状态才
  返回 `ConnectionTimeout`。两者一致；没有来源支持从静默推断 server 已死亡。

LeanTTY 因此只映射库事件：`AwaitingPeer` 保持连接中，`Responsive` 使用正常状态色，
`Interrupted` 使用警告色但保持 Pane、Session、输入和输出；恢复是
`Interrupted -> Responsive` 转换，不建立 `Restoring` 状态或产品计时器。迟到观察事件在 Session
结束后被丢弃，`ConnectionTimeout` 作为连接失败处理。

当前 test-signed ARM64 HAP SHA-256 为
`7259a9ba8900d075de83beb9707673423af0c70ff12c8a21e67669d634adeb89`。`pause-recovery` 在约
7.9 秒双向精确丢包后观察到 `Interrupted(NoRecentContact)`，解除丢弃后观察到 `Responsive`
recovery，同一远端 PTY 执行新命令成功；证据为
`build/verification/device-mosh-20260830T131919121Z/device-mosh.json`。`server-disappearance`
在精确 server PID 被移除约 6.6 秒后观察到相同 warning，没有自动 close/error；用户主动关闭
约 4005 ms 后返回本地提示符；证据为
`build/verification/device-mosh-20260830T132741950Z/device-mosh.json`。

同一 HAP 的最终 compatibility 诊断通过 Bash 5.3、tmux 3.6、Vim 9.1、resize、512 字节持续
输入与 32 个输出帧、认证关闭、Preferences、secret 和清理检查；证据为
`build/verification/device-mosh-20260830T132948428Z/device-mosh.json`。两次更早的 compatibility
尝试因 UiTest 文本少注入一字符且旧 `uinput` 重试未进入应用而归类为 harness failure。当前 Mosh
重试在重新确认 terminal focus 后改用 OpenHarmony
[`uiInput keyEvent`](https://gitee.com/openharmony/testfwk_arkxtest/pulls/612) 支持的多键组合；该来源
同时只把 `inputText` 定义为文本框输入，没有承诺逐字无损，因此远端精确 snapshot 仍是 Enter
前置 oracle。tooling 红绿测试已通过。最终通过场景没有触发重试，因此不把它声称为物理重试
稳定性证据。

常用命令：

```powershell
# 一次性初始化（管理员）
.\tools\configure-mosh-test-network.ps1 -Mode Enable

# 日常开发（普通权限）
.\tools\configure-mosh-test-network.ps1 -Mode Status
.\tools\verify-mosh-pc.ps1
.\tools\verify-mosh-pc.ps1 -Scenario fixed-endpoint
.\tools\verify-mosh-pc.ps1 -Scenario server-path
.\tools\verify-mosh-pc.ps1 -Scenario pause-recovery
.\tools\verify-mosh-pc.ps1 -Scenario server-disappearance

# 不再需要该环境时（管理员）
.\tools\configure-mosh-test-network.ps1 -Mode Disable
```

## 客户端依赖合同

LeanTTY 选择 [`wandcs/mosh-client-rs`](https://github.com/wandcs/mosh-client-rs) 的
`mosh-client` crate。依赖通过完整 Git `rev`
`e1346b3dfce5c38b95ef43d78cfb3d73529f00e5` 固定，包版本 `0.0.0`，许可证为
`MIT OR Apache-2.0`。LeanTTY 不直接修改该仓库，也不维护协议 fork；发现的问题记录在
[`mosh-client-rs-integration-issues.md`](mosh-client-rs-integration-issues.md)，由库仓库独立修复、
验证和升级。

依赖边界如下：

- `mosh-client` 负责严格 bootstrap 解析、认证 UDP、重放保护、分片、SSP 同步、终端权威状态、
  VT repaint、恢复调度、资源上限、认证 graceful close 和 Session hard cancellation。
- LeanTTY 负责 Host 解析、主机密钥校验、认证、受控启动 `mosh-server`、Pane 生命周期、N-API、
  Terminal Surface 和用户可见策略。
- 初始兼容目标仅为 stock `mosh-server` 1.4.0、IPv4、bootstrap 返回的 UDP 端点、
  `TERM=xterm-256color` 和 UTF-8。IPv6、完整 scrollback、server 管理与远端命令不在首版合同。
- bootstrap 最多 4 KiB、64 行，只接受一个 `MOSH CONNECT <port> <key>`；UDP datagram 最多
  2 KiB，fragment body 最多 1,400 bytes、每条 instruction 最多 749 个 fragment，未完成 instruction
  只保留 10 秒；压缩 instruction 最多 1 MiB，解压 instruction、state difference 和单个输出块最多
  2 MiB。单条输入最多 64 KiB，ACK 后 client operation 最多 4,096，命令队列 64、输出队列 1。
- 终端上限为 500 列、200 行、100,000 个可见单元格、每 cell 8 个 Unicode scalar 和每次 difference
  4,096 个 terminal operation；已发送/已接收参考状态各保留 32 个，待确认预测最多 32 个 scalar/
  32 bytes 并在 10 秒后失效。所有超限必须在继续修改协议状态前显式失败。
- 重传间隔限定 50 ms–5 秒，heartbeat 为 3 秒；6.5 秒无 contact 或 10 秒无 reply 只产生临时
  reachability warning，首次 attachment 15 秒仍未成功才失败，认证关闭 ACK 最多等待 4 秒。
  LeanTTY 的 N-API transport/control/auth callback 队列各为 64，输入队列 64，resize 与输出暂停队列
  各 8，disconnect/auth/host-key 队列各 1；bootstrap 各步骤复用 Host 的 `ConnectTimeout`，非优雅
  teardown 对协议任务最多等待 1 秒。诊断只携带固定 stage/status/reason，不记录 bootstrap key、
  terminal bytes、Host 原文或凭据。
- 公共 API 固定使用 `Bootstrap::parse`、`Session::connect_with_prediction_mode`、`send_input`、`resize`、
  `request_repaint`、`next_output`、`subscribe_reachability/current/changed`、
  `state/state_changed`、`close`、`cancel`、`SessionExit` 和 `SessionTask::run`。调用方等待
  graceful close 时必须继续消费输出；立即停止才使用 `cancel()`。

Cargo 和 lockfile 使用公开 Git source 与完整 commit，不依赖 sibling checkout，也不跟随
`main`。未来库升级必须先审计上游差异、更新固定 `rev`，再重跑依赖、许可证、ARM64 和真机门禁。

固定库修订提供按 Session 隔离的 `Adaptive`、`Always` 和 `Never`。LeanTTY 接受标准
`--predict=adaptive/always/never`，默认 `adaptive`，只透传严格枚举。库侧 x86_64 公共 Session
的全丢包显示合同已验证；`e1346b3` 进一步让 echo acknowledgement 与 HostBytes 的到达顺序
无关。正常 PTY、真实交互 shell 和双向独立 40 ms relay 下的 ARM64 公共 Session 已证明
`Always` 在权威 RTT 前显示、`Never` 等待权威输出、全丢包期间继续预测、恢复后收敛以及
Session 隔离，详见
[`MCRS-006`](mosh-client-rs-integration-issues.md#mcrs-006arm64-公共-session-没有产生-prediction-输出)。

2026-08-31 的依赖门结果如下：

- 固定修订 `e1346b3` 的 `mosh-client-rs` 格式、Clippy 和 locked 全目标/全 feature 测试通过：
  127 项通过，23 项依赖 stock Mosh 二进制的测试按声明忽略；两个 prediction stock 用例已在
  本机 1.4.0 上显式运行并通过，LeanTTY 的真机场景另行覆盖 stock 1.4.0
  的认证关闭、最终输出排空、中断警告、恢复和 server 消失。
- LeanTTY 的 locked 全目标/全 feature `cargo check` 通过；目标图保留一个 Tokio 1.53.1。
- LeanTTY 现有 OHOS linker/archiver 完成 `aarch64-unknown-linux-ohos` release 构建；固定 Git
  revision 已进入 test-signed ARM64 HAP。HAD-W32 命名场景进一步证明真实 stock server 的精确
  命令、认证关闭、最终输出排空、本地提示符恢复和清理；这仍是开发期诊断，不是正式候选验收。
- ARM64 metadata 包含 181 个 registry package 和一个外部 Git package。新增许可证族、包名与
  临时来源已写入 [`RUST_DEPENDENCIES.md`](../RUST_DEPENDENCIES.md) 和
  [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。

最新固定修订的 ARM64 原生库 SHA-256 为
`080B4E1DE205AE1EAE5896E7B01B39025E4D0B5F100E8F6D871DEC5A2A6BFAAC`。对应 test-signed HAP
SHA-256 为 `d2bbc45eeb18dcd625ac2c032789a0b7e3ee327894dce1b6a98347d5f03dae65`；真机证据
`build/verification/device-mosh-20260831T042441659Z/device-mosh.json` 的 RTT 基线为 128 ms，
`Always` 第二个 warmup 字节在 1 ms 可见、2 ms 完成渲染，双向全丢包后的下一个 ASCII 仍在
1 ms 可见、3 ms 完成渲染；`Never` 首字节等待 134 ms。权威状态恢复收敛、两个 Session 隔离、
首个 Session 认证关闭、最终主路径、Preferences 与成对清理均通过。该记录是开发期真机诊断，
`acceptanceEligible=false`，不替代正式候选矩阵。

### 2026-08-31 IPv4/IPv6 family 门禁结论

官方 [`mosh(1)`](https://github.com/mobile-shell/mosh/blob/master/man/mosh.1) 把 `-4`/`-6`
分别定义为 SSH bootstrap 与 Mosh Session 都只使用 IPv4/IPv6；默认 family 策略会优先 IPv4，
但仍可尝试双栈地址。因此 LeanTTY 不能只在 parser 中接受同名参数，而让 SSH 与 UDP 实际使用
不同或未经验证的 family。

当前 IPv4 fixture 已可重复运行：Windows `192.168.1.4:2223/TCP` 只转发 SSH bootstrap，WSL
mirrored network 直接暴露 stock 1.4.0 动态 `60000–61000/UDP`；最终 prediction 场景也再次证明
同一 IPv4 endpoint 的连接、双向阻断/恢复、认证关闭和成对清理。

IPv6 门在两个独立边界上不成立：

- HAD-W32 的 `wlan0` 只有 `fe80::/64` link-local 地址，没有全局 IPv6 或 IPv6 默认路由；Windows/
  WSL 的有线接口虽有 `2408:8207:4823:24f0::/64` 与默认路由，但不与测试机共享二层链路，不能
  用 link-local scope 拼成真实应用路径。
- 固定 `mosh-client-rs` 修订 `e1346b3` 的公共
  [`Bootstrap::parse`](https://github.com/wandcs/mosh-client-rs/blob/e1346b3dfce5c38b95ef43d78cfb3d73529f00e5/src/bootstrap.rs)
  接受 `Ipv4Addr` 并返回 `SocketAddrV4`，Session driver 绑定 IPv4 unspecified socket；LeanTTY
  即使解析出 IPv6 server 地址也无法通过公共 API 建立协议 Session。

因此 1.6 维持 IPv4-only，不增加无实际价值的 `-4` 别名，也不接受 `-6` 或 `--family` 后静默
回落。上述选项和 IPv6 literal 都在联网前明确说明本版本仅支持 IPv4；Host 名称只有在 SSH
实际连接并报告 IPv4 server endpoint 时才能继续。该裁剪同步到 roadmap，不阻塞 1.6。

IPv6 的重新进入条件是：公共库先提供经过 stock 双栈测试的 `IpAddr`/`SocketAddr` bootstrap、
socket 与来源迁移合同；目标物理 PC 同时取得可重复的全局 IPv6/default route 或与 fixture 同链路
的 link-local 路径；随后同一 HAP 完成 SSH 与 UDP family 一致性、IPv6 literal/Host、错误 family、
地址变化、关闭和清理门禁。只满足其中一边不授权产品 option。

### 2026-08-30 原生 Session 所有权基线

LeanTTY native 已建立独立的 Mosh Session map 和 N-API 边界。一个 native Session 依次拥有
SSH 主机校验与认证、固定 `mosh-server new -s -c 256` bootstrap、严格解析后的临时密钥、UDP
协议任务、输入、resize、输出暂停后 repaint 和取消。SSH bootstrap 结束后立即关闭 SSH route；
Mosh UDP 不复用 SSH shell，也没有引入通用 Transport 接口。

bootstrap 通过固定远端命令读取 `SSH_CONNECTION` 的 server-side IPv4，并把完整输出直接放入
Rust `Zeroizing<Vec<u8>>`；输出上限 4 KiB，地址记录必须唯一且为规范 IPv4，随后交给
`Bootstrap::parse` 校验唯一 `MOSH CONNECT`。临时 key 不经过 ArkTS、Terminal Surface、日志或
持久化层。认证输入仍通过现有 generation 与 layer 检查，Mosh Session 关闭时从独立 map 删除。

### 2026-08-30 Pane 与 ArkTS 纵向切片

Pane 现在独立拥有 `MoshClient`，复用现有 Host、Identity、主机校验和认证策略，但没有引入通用
Transport。命令入口只接受下节定义的最小语法；连接成功后，输入、resize、输出暂停后 repaint、
取消和迟到事件均按当前 Pane 与 Session generation 隔离。`Ctrl-^ .` 断开当前 Mosh Session，
`Ctrl-^ ?` 显示本地帮助，跨输入帧的 escape 前缀由独立 parser 保留。

用户可见状态只映射库能证明的 bootstrap、UDP connecting、connected、reachability warning、
认证 local/remote close 和终止错误。`Interrupted` 只改变 Pane 状态点，不关闭 Session；恢复由
库的下一次 `Responsive` 事件证明。LeanTTY 不增加 `Restoring` 定时状态，也不从静默推断 server
死亡。剩余本地 socket 错误风险记录在
[`mosh-client-rs-integration-issues.md`](mosh-client-rs-integration-issues.md)。

聚焦 `policy,arkts,rust-native` 回归、ARM64 强制原生构建和 test-signed HAP 部署均已通过。
命名真机场景随后闭合 stock server、真实 Shell/tmux/Vim、resize、持续流、网络暂停恢复、server
消失、认证关闭和 secret 清理；这些开发期诊断仍不能替代正式候选的完整网络与生命周期矩阵。

### 2026-08-30 固定 UDP port/range 结果

LeanTTY 现在接受 `-p <port>` 或 `-p <low>:<high>`，并只把该选择传给 SSH bootstrap 启动的
`mosh-server`。端口必须是十进制 1–65535，范围包含两端且 `low <= high`；缺值、重复 option、
未知 option、额外参数、符号、空边界、越界和反向范围均在联网前失败。`0` 虽可让官方命令选择
动态端口，但不属于本固定端点合同；省略 `-p` 才表示 stock 默认动态选择。

Host 的 `Port` 始终只控制 SSH bootstrap。Rust 边界重新验证端口范围，并要求 stock server
返回的 `MOSH CONNECT` 端口落在请求范围内；不匹配时连接失败，不能悄悄退回动态端点。
这保持了官方 `mosh(1)` 的单端口/范围语法和 `mosh-server` 返回实际端点的责任，也没有把
防火墙或 NAT 管理带入产品。

HAD-W32 的 `fixed-endpoint` 诊断向 stock `mosh-server 1.4.0` 请求 `60042:60044`，实际选择
60042。真实 UDP Session、精确终端命令、物理 `Ctrl-^ .`、95 ms server 退出、本地提示符、
Preferences、secret 审计和全部清理通过；test-signed HAP SHA-256 为
`60f5a18947ad1f436ec3ebb8216215b1a827ceb796d50183a8fa8cc9bfebfe69`，证据为
`build/verification/device-mosh-20260830T140514105Z/device-mosh.json`。该结果只闭合固定端点
开发切片，`acceptanceEligible=false`。

### 2026-08-30 受控 server path 结果

官方 [Mosh README](https://github.com/mobile-shell/mosh) 使用 `--server=PATH` 处理 server 不在
远端 `PATH` 的情况，而官方 [`mosh.pl`](https://github.com/mobile-shell/mosh/blob/master/scripts/mosh.pl)
实际把该值视为可执行的 `COMMAND`。LeanTTY 没有远端 shell 命令合同，因此不会继承任意命令、
quoting 或附加参数语义；产品只接受 `--server=<absolute-path>` 这一种内联形式。

路径最多 1024 ASCII 字节，必须以 `/` 开头且不能以 `/` 结尾；每段只能包含字母、数字、`.`、
`_`、`+`、`-`，并拒绝空段、`.`、`..`、空白、引号、`~`、变量和 shell 元字符。省略 option 时
仍由远端 `PATH` 查找 `mosh-server`。Parser 与 Rust native 边界分别验证，Pane 保存该选择用于
同一连接的重试。Native 只把一个已验证路径放入固定 bootstrap，仍维持 4 KiB 输出上限；远端
exit 126 和 127 分别映射为不可执行和不存在，其他非零退出保持通用启动失败。路径不进入产品日志。

HAD-W32 的 `server-path` 诊断要求 stock `mosh-server 1.4.0` 从
`/usr/bin/mosh-server` 启动，fixture 记录的实际 executable 与请求完全一致。真实 UDP Session、
精确终端命令、物理 `Ctrl-^ .`、105 ms server 退出、本地提示符、Preferences、secret 审计和
全部清理通过；test-signed HAP SHA-256 为
`68b90937f3642a52eb4d2d273705985169cca6e2d93c731c102689698e948347`，证据为
`build/verification/device-mosh-20260830T144055423Z/device-mosh.json`。该结果只闭合受控路径
开发切片，`acceptanceEligible=false`。

## 最小命令合同

当前接受 `mosh [-p <port>[:<port>]] [--server=<absolute-path>]
[--predict=adaptive|always|never] [user@]host|alias` 和
`mosh --help`。命令恰有一个连接目标；未知或重复 option、额外参数、无效端口或路径、空 user、
空 host 和无效别名立即失败。显式 user 覆盖 Host 的 `User`；SSH bootstrap 复用 Host 的
`HostName`、`Port`、`IdentityFile`、`ConnectTimeout` 与 ServerAlive 设置。`-p` 只选择远端
Mosh UDP server 端点；`--server` 只选择一个受控远端 executable。

当前拒绝包含 `ProxyJump` 的 Host，不把 SSH jump 成功解释为 UDP 可达。它也不接受远端命令、
`-4/-6`、文件传输或第二份 Mosh 配置。后续 option 必须按
`next-work.md` 逐项获得证据和测试后加入。

## 拟议范围

- 使用现有 SSH Host、Identity、主机校验和多方法认证启动远端 `mosh-server`。
- 解析结构化 bootstrap 结果后建立一个 Mosh UDP 会话；不把服务器输出当作任意 shell
  命令继续执行。
- 显示 bootstrap、UDP 建连、connected、closed 和可证明的终止错误；中断与恢复状态以库合同为准。
- 一个 Pane 拥有一个 Mosh Session 和一个 Terminal Surface；输入、resize、焦点和
  终端状态不能跨 Pane。
- Mosh 只承载交互式终端。SFTP、文件传输、ProxyJump 和其他 SSH 子系统不复用该
  UDP 会话。

## 非目标

- 不内置、上传、自动安装或升级 `mosh-server`。
- 不承诺 UDP 被企业网络、防火墙或代理阻断时仍可工作。
- 不以手机、平板、竖屏或纯触控移动场景作为产品范围依据。
- 不把 SSH 和 Mosh 抹平成一个隐藏真实差异的通用 Transport 接口。
- 不实现通用 roaming VPN、端口转发、文件同步或后台任务平台。

## 初步所有权与事件链

```text
Pane → Mosh Session
  → SSH bootstrap (existing SSH security path)
  → validate server bootstrap result
  → Mosh protocol state + UDP socket
  → Terminal Surface
```

Mosh Session 是独立生命周期，因为它拥有 UDP、加密状态、序列/同步状态和网络恢复；
这满足新增局部类型的技术原则。但 SSH Session 与 Mosh Session 不需要提前共享一个
公共插件层：共同的 Host 解析与认证策略可以复用，协议状态必须按真实边界分别实现。

## 安全与数据边界

- SSH bootstrap 继续执行标准主机密钥校验与认证，不通过 shell 文案绕过信任。
- bootstrap 产生的临时连接秘密只存在于当前 Session 内存，不进入终端、日志、
  Preferences、持久资产或剪贴板，并在成功、失败或取消后清理。
- UDP 端点、协议版本和服务器输出都视为不可信输入，必须校验长度、格式和允许范围。
- 不记录终端内容；网络诊断只记录安全状态、时序和错误类别。

## 已验证的终端兼容边界

2026-08-31 的 HAD-W32 诊断使用 stock `mosh-server 1.4.0` 和固定的
`mosh-client-rs` 修订。真实 Bash、tmux、Vim、`less`、resize、512 字节持续输入及同步输出均
通过。UTF-8 locale fixture 输出 5 个中文宽字符和 1 个组合序列；终端搜索与当前截图同时确认
字符到达并正确显示。

Mosh 与 SSH 的历史语义不同。fixture 以受控节奏输出 242 行：末尾标记可搜索，已停留 500 ms
的开头标记仍不在本地历史中。真实 `less` 的 `g/G` 则能可靠显示并搜索文档首尾。该结果符合
状态同步而非字节流传输的边界；用户需要可靠远端历史时应使用 `less` 或 tmux，LeanTTY 不承诺
SSH 式完整 scrollback。

DEC 1049 fixture 的进入页和退出页均可见，但退出后旧页内容仍停留在当前屏和搜索历史。真实
Vim 可以编辑、保存并退出；差异在于当前 Mosh 公共 VT 输出没有给 LeanTTY 可用的本地
alternate-buffer 恢复边界。LeanTTY 暂不复制终端状态机或按输出猜测模式，详见
[`MCRS-008`](mosh-client-rs-integration-issues.md#mcrs-008公共-vt-输出没有保留-alternate-buffer-边界)。

诊断证据为
`build/verification/device-mosh-20260831T141514450Z/device-mosh.json`；HAP SHA-256 为
`420da0a0cd04558cf326bec20b69746913b76ed1cb07c23df8d9786d6f38271b`。Preferences、secret、
设备状态、fixture 进程、临时目录和持久网络检查均通过。本记录是开发期诊断，
`acceptanceEligible=false`。

同日的独立 `agent-tui` 场景通过 Mosh 启动 Codex CLI 0.149.1，并保持模型请求为 0。受控 PTY
进入 raw mode，物理英文标记到达；真实窗口切换把尺寸从 144×42 改为 171×46；`/exit` 返回 0。
capture 只保留字节数、hash 和协议计数，原始输入、输出与 termios 均已删除。证据为
`build/verification/device-mosh-20260831T143219872Z/device-mosh.json`。该运行也通过认证关闭、
Preferences、secret 和成对清理。

## 待研究与讨论

- Mosh 对 OSC、标题、剪贴板、鼠标和现代 TUI 的实际兼容边界。
- 远端 `mosh-server` 命令、端口范围、locale 与版本协商如何在不增加大量设置的情况
  下保持可诊断。
- HSL 是否允许 UDP loopback Mosh 没有优先价值；本 milestone 主要针对远端弱网环境，
  不能为了复用而和 HSL 入口合并。
- Mosh Session 与现有断线后 `ltty>`、重连、终端内容保留语义如何区分。
- ProxyJump 后的 Mosh bootstrap/UDP 可达性不是首版默认组合，需独立证明才讨论。

## 验证门禁

### 自动化与协议

- bootstrap 成功/失败、恶意或超长输出、版本不兼容、UDP 超时和错误密钥。
- 有序/乱序/重复/丢失数据、网络中断与恢复、地址变化、取消、Pane 关闭和迟到事件。
- 两个 Mosh Session 以及 SSH/Mosh 并行时状态、密钥、终端和清理不串联。
- Unicode、resize、持续输入、大输出和协议资源上限。

### 2026-08-31 Pane 关闭验收研究记录

**问题。** 在物理 HarmonyOS PC 上验证活动 Mosh Pane 关闭时，是否可以继续复用当前的
UiTest 语义布局、坐标点击和受控 PTY/server oracle；如何避免把按钮点击、日志行或固定等待
误当成 Session 所有权结论。当前目标系统使用 UiTest 6.0.2.3。

**外部证据。** OpenHarmony 官方
[`arkXtest` 文档](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)
把 UiTest 定义为通过组件属性定位并点击组件的异步接口；因此脚本仍须在点击前从当前布局唯一
定位可见、可点击的关闭按钮，并在点击后等待新的布局和业务后置条件。OpenHarmony 的
[`uitest-guidelines`](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)
同样采用“查找组件、执行点击、断言结果”的事件链。官方仓库曾记录 UiTest daemon 断连，且较新
事件监听改动仍存在部分窗口/文本事件不触发的自测结果；本场景因此不引入事件监听，也不把一次
UiTest 成功返回当成业务通过。作为可比较模式，Playwright 的
[`actionability`](https://playwright.dev/docs/actionability) 要求动作前唯一、可见、可交互，并用可
重试断言等待动作后的状态；这里只采用该模式，不把它当作 HarmonyOS 行为证据。

Mosh 官方 [`mosh-server(1)`](https://github.com/mobile-shell/mosh/blob/master/man/mosh-server.1)
说明 server 在 client 终止连接后退出；官方
[`Ending the connection`](https://mosh.org/#getting) 说明 `Ctrl-^ .` 是强制结束连接入口。固定
`mosh-client-rs` 修订另行实现认证关闭。由此，Pane 关闭场景的协议后置条件是旧 server/PTY
退出，而 Pane 所有权后置条件是幸存 Pane 不出现旧 Pane 的唯一输出，并能立即建立第二个 Mosh
Session、执行新的受控 PTY 命令且保持存活。

**采用与未决项。** 场景复用已有序列化 UiTest mutex、当前布局、关闭确认、精确输入和受控
fixture；不新增延时判定、截图 oracle、UiTest 事件监听或 acceptance-only 产品入口。没有找到
HarmonyOS PC 上 Mosh Pane 关闭的同类公开报告，最终结论只能来自本项目目标真机。旧 native
回调无法由外部系统精确调度，L1 所有权测试负责拒绝非当前 `MoshClient`，L3 则用关闭 Pane 后的
负向终端搜索、第二个真实 Session 命令、旧 server/PTY 退出和完整清理共同闭合可观察结果。

### 2026-08-31 并发 Session 隔离验收研究记录

**问题。** 如何在物理 HarmonyOS PC 上证明两个 Mosh Session 以及 SSH/Mosh 并行时，Pane 的
状态、Mosh bootstrap key、输入、终端输出和清理没有串联；哪些结果属于协议或系统事实，哪些
必须由 LeanTTY 的 Pane 所有权场景证明。

**外部证据。** Mosh 官方
[`mosh-server(1)`](https://github.com/mobile-shell/mosh/blob/master/man/mosh-server.1) 说明每次
`new` 启动的 server 选择一个高位 UDP 端口和加密 key，等待对应 client，并在该 client 终止时
退出；默认范围是 60000–61000。官方仓库关于
[`multiple sessions`](https://github.com/mobile-shell/mosh/issues/295) 的记录也明确说明当前实现靠
端口范围容纳同一主机的多个 Session，而不是在一个 UDP 端口上复用。因此两个并发 Mosh 的必要
fixture 事实是不同 server/PTY PID、不同 UDP Session 和不同 bootstrap key；关闭其中一个只应
结束它自己的 server/PTY。Mosh 官方
[`README`](https://github.com/mobile-shell/mosh) 说明 SSH 只负责认证和启动 server，之后退出，
交互终端改走 UDP；SSH/Mosh 并行测试必须保留一个真正的 SSH shell，不能把 Mosh 的 bootstrap
SSH 当成并行 SSH Session。

OpenHarmony 官方
[`arkXtest` 文档](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md) 支持按
组件属性定位、点击和读取 focused 状态。脚本据此从当前双 Pane 布局按左右位置切换唯一终端输入，
每次切换后重新读取当前布局确认只有目标 Pane focused。该 UI 事实只证明输入目标；业务 oracle
仍是每个远端收到自己的精确命令、每个终端只搜索到自己的唯一 marker，以及单侧关闭后对侧立即
完成一个新命令。

**采用与未决项。** 采用一个受控 SSH fixture 并让 stock `mosh-server` 建立两个真实 UDP
Session；fixture 只在内存比较连续 bootstrap key，证据记录布尔结果而不记录 key 或派生值。
先证明 Mosh/Mosh 双向输入输出隔离和单侧关闭，再保留左侧 Mosh、在右侧建立真正 SSH shell，
证明跨协议隔离并关闭 Mosh 后继续使用 SSH。共享 `known_hosts` 和 Host 配置属于既有持久策略，
Session、认证响应、native handle、终端和远端进程属于 Pane；不新增 session manager、端口复用、
关闭后重新附着或测试专用产品 API。

**执行结果。** 并发 fixture 为每个 Mosh PTY 分配独立 `mosh-session-N` 控制目录。首次运行因两个
PTY 共用输入快照和事件文件而产生串扰。隔离目录消除串扰后，下一次运行因脚本误用普通 `exit`
而停在 SSH 清理；改用 fixture 的 `ltty-exit` 后完整通过。L3
`build/verification/device-mosh-20260831T085407149Z/device-mosh.json` 使用 test-signed HAP
`420da0a0cd04558cf326bec20b69746913b76ed1cb07c23df8d9786d6f38271b`，证明两个 Mosh server/PTY
PID 和 bootstrap key 不同，双向输入与输出互不串联，关闭右侧 Pane 后左侧 Mosh 继续执行命令。
随后，真实 SSH 与左侧 Mosh 通过相同隔离检查；关闭 Mosh 后 SSH 继续执行命令并正常退出。证据还
确认 Preferences 未变、日志和结果无 secret pattern，且设备状态、fixture 进程和临时目录均已清理。
`Ctrl-^ .` 的认证关闭由独立单 Pane 场景证明；本场景使用可见 Pane 关闭，直接验证 Pane 所有权。

### 2026-08-31 首轮协议与生命周期可靠性闭合

固定 `e1346b3` 由库侧负责并测试：错误 key 与认证区域篡改、乱序只接受一次、replay/旧包拒绝、
短包与超长 datagram、重复/冲突 fragment、乱序重组、丢包与重传、client 来源地址变化、无首次
peer 状态的 15 秒 timeout、未知 instruction 版本/尺寸/压缩/尾随数据、所有资源上限、取消清空
排队工作与拒绝迟到包、优雅关闭丢包重传/同时关闭/4 秒 ACK 上限，以及两个公共 Session 的包、
状态和生命周期隔离。LeanTTY 不复制这些 SSP、crypto、fragment、prediction 或计时器规则。

LeanTTY 侧负责并测试：bootstrap combined stdout/stderr 在 4 KiB 边界立即失败，server 的 126、
127 和其他退出状态可区分，`SSH_CONNECTION` 只能提供一个规范 server-side IPv4，完整输出继续交给
库解析唯一 `MOSH CONNECT`；`ConnectionTimeout`、protocol、resource limit 和 state exhaustion
保持独立错误类别。Pane 的 `SessionViewModel` 以当前 `MoshClient` 对象身份作为唯一回调 owner；
重连、取消、Pane dispose、启动失败和终止先撤销旧 event/data callback，再请求 native 断开。
`Ctrl-^ .` 则保留当前 owner，继续消费认证关闭的最终输出，直到该 Session 自己结束。

L1 `SshSessionLifecycle` 增加当前/旧/null Mosh owner 的拒绝用例。L3
`build/verification/device-mosh-20260831T080001390Z/device-mosh.json` 使用 test-signed HAP
`420da0a0cd04558cf326bec20b69746913b76ed1cb07c23df8d9786d6f38271b`：活动 Mosh Pane 关闭后，
幸存 Pane 搜索不到旧 Pane 的唯一 terminal marker，并立即建立第二个 stock 1.4.0 Session、执行
新的精确受控 PTY 命令；旧 server/PTY 在 98 ms 内退出，第二个 server 保持存活直到自身认证关闭。
本地提示符、secret audit、Preferences、设备状态、fixture、持久网络和临时目录清理全部通过；
`result=passed`、`harnessStability=stable`、`acceptanceEligible=false`。结合既有
`pause-recovery`、`server-disappearance`、`compatibility`、fixed endpoint、server path 和 prediction
证据，首轮乱序/丢包/地址变化/timeout/bootstrap/server/取消/Pane/迟到事件范围已闭合；正式候选
仍须运行冻结后的适用 L4 网络与生命周期矩阵。

### 2026-09-01 独立锁屏与物理合盖边界

同一 test-signed HAP（SHA-256
`0e1063e7915df5229aeccc3d6eb49c0d1f4bc749e111dc59eb80a1a18e5451c0`）已通过独立
`Win+L` 锁屏：`build/verification/device-mosh-20260831T164542731Z/device-mosh.json`
记录同一 App 进程与远端 terminal PID，约 43 秒操作员窗口后自动恢复命令通过，认证关闭、
原页面恢复、Preferences、secret 与全部清理通过。

物理合盖不是同一结果。首次有效失败
`build/verification/device-mosh-20260831T165404882Z/device-mosh.json` 在合盖/解锁后观察到
App PID 变化。一次中间尝试保留进程，但受控 fixture 当时把
`MOSH_SERVER_NETWORK_TMOUT` 固定为 30 秒，操作员窗口超出该测试专用值，不能作为产品结论。
fixture 随后把生命周期场景的 timeout 改为 `OperatorWaitSeconds + 60`，普通关闭诊断仍为 30 秒；
Rust fixture 测试与 tooling 回归通过。修正后证据
`build/verification/device-mosh-20260831T172728600Z/device-mosh.json` 再次在恢复命令前观察到
主进程从 `57242` 变为 `60436`，新进程重新初始化 ArkWeb；远端 PTY 与 stock server 已结束，
场景清理完整。失败日志没有形成 LeanTTY crash 证据，当前边界是 HarmonyOS 物理合盖可能回收
第三方应用进程，而 Mosh 的 UDP/SSP 恢复不能跨越本地进程死亡。

官方 [`backgroundTaskManager.startBackgroundRunning()`](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/js-apis-resourceschedule-backgroundtaskmanager)
支持 PC，并要求 `ohos.permission.KEEP_BACKGROUND_RUNNING`。长时任务会产生用户可见通知；
[后台任务使用规范](https://developer.huawei.com/consumer/cn/doc/doccenter-architecture/standard-background-task)
还要求用户可主动开始/停止，并在应用市场功能说明中声明原定用途。为活动远端 Session 申请长时任务可能是
唯一直接保留进程的系统路径，但它会新增权限、通知、生命周期状态、取消处理和上架声明，不能
作为测试 workaround 或默认常驻能力静默加入。维护者确认该产品取舍前，物理合盖保持未通过，
Wi-Fi 暂断和网络切换不越过当前顺序门。

### ARM64 HarmonyOS PC 与真实服务器

- 正常网络下 Shell、tmux、vim、less 和 Agent TUI 基础兼容。
- 合盖、锁屏、Wi-Fi 暂断、网络切换、UDP 被阻断、服务器重启与 `mosh-server` 缺失。
- 与同场景 SSH 的恢复时间、会话保留和用户操作对比，证明收益而非仅证明能连接。
- 检查 hilog、Preferences、终端内容和崩溃信息不泄露 bootstrap 秘密。

## 裁剪与停止条件

如果目标网络普遍阻断 UDP、可靠库不可维护、终端兼容明显低于当前 SSH，或真机测量
不能证明持续核心收益，则取消 1.6。不能通过捆绑服务器、扩张为网络平台或牺牲 SSH
可靠性来维持 Mosh milestone。

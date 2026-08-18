# OpenSSH ProxyJump 技术方案

> 状态：Verified（开发候选）；实现、自动化与聚焦物理机矩阵已闭合，正式 production 候选待发布流程复验
>
> 当前 milestone：1.4.0
>
> 更新日期：2026-08-17
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：已进入 [`next-work.md`](../next-work.md)；只按其中的依赖顺序和停止条件执行

> 命令面治理：[`command-system.md`](command-system.md)

## 用户问题与目标

部分开发和运维环境只允许先连接一个标准 SSH 跳板机，再从该连接访问目标服务器。
用户当前只能在远端 shell 中再次执行 `ssh`，这会割裂 LeanTTY 的目标主机校验、认证、
取消、错误恢复和 Session 所有权。

目标是支持 OpenSSH `ProxyJump` 的最小标准路径，让一个 Pane 仍然拥有一个最终目标
Session，并清楚管理跳板与目标两层 SSH 安全边界。

## 已授权范围

- 首个版本只支持一个 SSH 跳板 Host 和一个最终目标 Host。
- 读取 OpenSSH config 的 `ProxyJump`，并支持复用同一解析和 Session 路径的一次性 `-J`。
- 跳板连接成功后，通过 SSH `direct-tcpip` channel 承载目标服务器的 SSH 连接。
- 跳板和目标分别解析 HostName、User、Port、Identity，分别校验主机密钥和完成认证。
- 目标连接成功后才创建 PTY；终端只显示最终目标的 shell 字节流。

## 非目标

- 不支持 `ProxyCommand`、执行任意本地/远端代理命令或 shell 拼接。
- 不提供通用 local/remote/dynamic port forwarding、SOCKS、VPN 或网络代理功能。
- 不建立堡垒机资产管理、共享凭据、审计、厂商 SDK 或 GUI 主机数据库。
- 首个版本不承诺逗号分隔任意多跳、循环跳转或嵌套 ProxyJump 链。
- 不用跳板 shell 内再次运行 `ssh` 代替协议级 `direct-tcpip`。

## 所有权与事件链

```text
Pane → Target Session
  → resolve target Host + ProxyJump Host
  → connect/authenticate jump SSH
  → open direct-tcpip(jump → target)
  → perform target SSH handshake over channel
  → verify/authenticate target
  → open target PTY
  → Terminal Surface
```

- Pane 只拥有最终 Target Session；该 Session 内部拥有跳板前置连接和目标连接的完整
  生命周期。
- 两层连接不复用其他 Pane 的 russh Handle，不成为全局连接池。
- 跳板 channel 关闭必须使目标 Session 进入明确断线状态；目标失败后也必须释放跳板。
- UI 只渲染结构化阶段和错误，不根据文本猜测当前失败层级。

## Transport 技术门禁结论

2026-08-17 已针对仓库锁定的 russh 0.62.5 建立受控双服务器门禁。该版本公开提供
`Handle::channel_open_direct_tcpip`、`Channel::into_stream` 与
`client::connect_stream`，不需要远端 shell 拼接、全局连接池、库 fork 或新增依赖即可形成
第二层 SSH：

```text
jump Handle
  → direct-tcpip Channel
  → ChannelStream
  → target client::connect_stream
```

仓库测试 `ssh-auth-fixture/tests/proxy_jump_transport.rs` 已证明：

- jump 与 target 分别完成 host-key callback 和密码认证，错误层凭据不会被另一层接受；
- 未授权目的地在建立 channel 前被明确拒绝，批准的目标可完成第二层握手和字节往返；
- target 正常断开会释放 `direct-tcpip` 隧道；jump 主动断开会终止活动 target 会话并释放隧道；
- 两个 server key、两个 client handler 和两个 russh Handle 保持独立，嵌套连接可以由最终
  Target Session 局部拥有，不要求共享或池化跳板连接。

因此 transport 停止条件未触发，并已沿该边界完成单跳解析与生产 Session 生命周期实现。
本节只记录最初的底层门禁；完整完成证据见下文。

## 配置与解析

- `ProxyJump` 遵循当前 config 的 first-obtained-value 规则；值为 `none` 时明确关闭 jump，
  其他值只接受一个 config alias 或一个 `[user@]host[:port]`。
- `ssh -J <jump-spec> target` 覆盖目标 Host 的 `ProxyJump`，只影响当前命令；`-J none`
  强制本次直连。重复 `-J`、缺少参数和其他未知 SSH option 沿用当前严格拒绝策略。
- jump spec 的 host 部分先尝试作为 config alias 解析自己的 `HostName`、`User`、`Port` 和
  `IdentityFile`，再由 spec 中显式的 user/port 覆盖对应字段。它不继承目标 Host 的配置。
- spec 未命中 alias 时按直接 endpoint 处理；由于 LeanTTY 没有可靠的本地 Unix 用户默认值，
  此时必须显式提供 user。alias 也必须最终解析出 User。
- config 中的逗号多跳、SSH URI、`%` token 或环境变量展开、空值及其他表达式不进入首版；
  接受后不能静默降级。jump Host 自身存在非 `none` ProxyJump 时，按不支持的链或循环失败。
- jump 与 target 的有效 `HostName + Port` 相同视为自引用并在连接前失败；端口不同仍是不同
  endpoint。Host alias 名称只用于显示和配置查找，不代替有效 endpoint 判断。
- `ssh -G` 输出目标有效配置，并在有 jump 时增加脱敏的有效 jump alias/hostname/user/port/
  identity 名称；不输出私钥内容、口令、认证回答或完整服务器 banner。

`ssh -J <jump-spec> target` 只作为当前命令的一次性 jump Host 覆盖，不写入 config，不建立
第二套 Host 状态，也不能绕过对 jump spec、循环、多跳和安全边界的相同校验。

## 安全与秘密边界

- 跳板和目标拥有各自的 `known_hosts` endpoint 与指纹确认，不因跳板受信而自动信任
  目标。
- 每一层只接收为该 Host 解析出的凭据；认证回答通过对应 Session layer 的轮次校验。
- 错误可显示安全的 Host alias、有效 endpoint、失败阶段和指纹，但不记录密码、OTP、
  私钥口令、完整服务器 banner 或目标敏感路径。
- 取消、超时、Pane 关闭和 app 生命周期变化必须同时终止两层未完成工作。

## 两层交互契约

- 一个 Pane 仍只有一个 native session id 和 generation。native 内部顺序执行 jump connect /
  verify / auth、`direct-tcpip`、target connect / verify / auth、PTY / shell；只有最后一步成功
  才发出 `CONNECTED`。
- host-key、password、private-key passphrase、banner 和 keyboard-interactive 事件统一携带
  `jump` 或 `target` layer。UI 继续使用现有一套输入模式，在提示前显示安全的层级与 Host
  名称，不增加第二个对话框、页面或状态机。
- host-key 决策、密码、私钥口令和 keyboard-interactive 回答必须回传事件的 layer；后者还
  回传当前 round id。native 只接受当前 session、generation、layer 和轮次全部匹配的回答，
  因取消、重试或前一层留下的迟到回答直接拒绝。
- 同一时刻只有一层可以等待用户输入。jump 完成认证并打开 channel 后才开始 target 握手；
  target 失败不会重新打开 jump 的认证提示，重试从整个 Target Session 重新开始。
- 跳板相关错误使用 `jump connect`、`jump host key`、`jump auth` 或 `direct-tcpip` 阶段；目标
  使用 `target connect`、`target host key`、`target auth`、`PTY` 或 `shell`。错误包含安全的
  alias/endpoint 和下一步，不泄露秘密，也不把 target 错误归为 jump 已连接成功。
- `ControlMaster`、agent forwarding、SSH agent 和证书认证不是当前能力；实现、help 和错误
  不得暗示已支持，也不为这些能力预留新的全局所有者。

## 验证门禁

### 自动化与受控服务端

- 直连回归；单跳成功；跳板/目标分别覆盖密码、私钥与 keyboard-interactive。
- 两层主机首次确认、已知匹配、指纹变化与删除恢复。
- 目标不可达、direct-tcpip 拒绝、任一层认证失败、取消、超时、断线和迟到事件。
- 循环、未知 Host、不支持多跳和无可用认证方法的明确失败。
- 两个 Pane 经不同跳板并行连接时，状态、凭据、输出和清理不串联。

### ARM64 HarmonyOS PC

- 物理键盘完成两层主机确认与认证，错误明确指出 jump 或 target。
- 合盖、锁屏、最小化、网络中断、目标退出和跳板退出后的确定恢复行为。
- Shell、tmux、vim、Agent TUI、复制粘贴、resize 和大输出与直连一致。

## 2026-08-18 开发候选完成证据

- config `ProxyJump`、一次性 `-J`、`-J none`、安全 `ssh -G`、循环/自引用/多跳/未知参数拒绝
  均由 ArkTS 自动化覆盖；`host add|set ... -J` 把普通用户入口写回同一 OpenSSH config，help
  与 Tab 补全复用同一 Host alias 来源。
- 当前签名 debug HAP 又在物理 PC 上通过 `host add jump ...`、`host add target ... -J jump`、
  `ssh -G target` 与 `help ssh`，实际显示有效 jump alias/hostname/user/port；验收后两个临时 Host
  均删除并二次确认不存在。
- 仓库双服务器 fixture 覆盖直连非退化、单跳握手、密码/私钥/keyboard-interactive 在 jump
  与 target 两层的代表性组合、两层首次信任/已知匹配/指纹变化恢复，以及 target 不可达、
  `direct-tcpip` 拒绝和超时、两层认证失败、取消、跳板/目标断线与资源清理。
- 两个 Pane 通过不同跳板并行连接时使用四组独立认证输入；关闭一条路由后另一条仍能交互，
  输出、回答、Session 状态和清理均不串联。普通直连 fixture 同时通过 1 MiB 粘贴、持续大输出、
  resize、Pane 关闭、native close 可观测、重连与后续物理键盘输入。
- 真实用户管理的 HSL 双服务器拓扑通过目标信任与 PTY、tmux、vim 9.0、Helix、Codex TUI、
  154x42→76x42→154x42 resize、OSC 52 剪贴板往返、约 1.14 MB 大输出，以及同一进程/Session
  的真实挂起、唤醒、锁定和解锁后继续输入。
- 受控路径逐项确认 jump/target 提示与错误层级；正常退出、目标断开、跳板断开和挂起后退出
  均回收两层资源并把同一 Pane 恢复到可输入的 `ltty>`。没有为此增加第二套认证 UI、共享跳板
  连接、远端 shell 拼接或产品专用服务器适配。

这些证据把本方案提升为开发候选 `Verified`，但不等于 1.4 已形成 production 包、GitHub
Release 或 AppGallery 交付。正式候选仍须在干净、已推送的精确提交上执行完整发布门禁。

## 裁剪与停止条件

如果 russh 无法在可维护的边界内承载目标 SSH、单跳不能覆盖主要真实场景，或嵌套认证
必须引入第二套 UI/状态机，应裁剪 1.4 的 ProxyJump 交付，而不是退化为远端 shell 拼接命令
或扩张成网络代理平台。ProxyJump 被裁剪时，1.4 仍可保留已经完成的启动优化进入正式候选。

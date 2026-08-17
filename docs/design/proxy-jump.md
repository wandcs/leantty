# OpenSSH ProxyJump 技术方案

> 状态：Implementing；1.4 范围已确认，技术门禁与嵌套认证模型按活动 TODO 闭合
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

## 初步所有权与事件链

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

## 配置与解析

- 单个 `ProxyJump <jump-spec>` 支持 config alias 与标准 `[user@]host[:port]` 形式，并通过与
  目标相同的 OpenSSH config 解析器和覆盖规则解析。
- 目标与跳板的 Identity 优先级分别计算，不能把目标密钥隐式提交给跳板或反之。
- 必须拒绝目标引用自身、循环引用、未知 jump Host 和首版不支持的多跳表达式。
- 配置解析结果应能在安全的 `ssh -G` 输出中解释 jump Host，但不能输出秘密。

`ssh -J <jump-spec> target` 只作为当前命令的一次性 jump Host 覆盖，不写入 config，不建立
第二套 Host 状态，也不能绕过对 jump spec、循环、多跳和安全边界的相同校验。

## 安全与秘密边界

- 跳板和目标拥有各自的 `known_hosts` endpoint 与指纹确认，不因跳板受信而自动信任
  目标。
- 每一层只接收为该 Host 解析出的凭据；认证回答通过对应 Session layer 的轮次校验。
- 错误可显示安全的 Host alias、有效 endpoint、失败阶段和指纹，但不记录密码、OTP、
  私钥口令、完整服务器 banner 或目标敏感路径。
- 取消、超时、Pane 关闭和 app 生命周期变化必须同时终止两层未完成工作。

## 实施前需要闭合

- 真实主要场景是否以单跳为主；若多数用户需要多跳，首版是扩展有界链还是取消该
  milestone，需要在设计前决定。
- 跳板与目标同时需要 `keyboard-interactive` 时，终端如何清楚标识当前回答属于哪一层。
- 跳板连接建立后目标不可达、主机密钥变化或认证失败时的最小错误文案。
- russh 当前版本对在现有 channel 上建立第二层客户端 SSH 的支持边界与取消行为。
- `ControlMaster`、agent forwarding、SSH agent 和证书认证不属于当前能力，文档与
  错误如何避免暗示支持。

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

## 裁剪与停止条件

如果 russh 无法在可维护的边界内承载目标 SSH、单跳不能覆盖主要真实场景，或嵌套认证
必须引入第二套 UI/状态机，应裁剪 1.4 的 ProxyJump 交付，而不是退化为远端 shell 拼接命令
或扩张成网络代理平台。ProxyJump 被裁剪时，1.4 仍可保留已经完成的启动优化进入正式候选。

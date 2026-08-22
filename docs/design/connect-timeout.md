# ConnectTimeout

> 状态：Verified；1.5.0 首个产品切片已闭合
>
> 更新日期：2026-08-21
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 完成记录：实现与命名验证已闭合；1.5 正式发布准备尚未启动

## 用户结果

当目标不可达，或 TCP 建连后的初始 SSH 握手/密钥交换没有完成时，用户可以用唯一
OpenSSH config 的 `ConnectTimeout` 控制等待时间。超时必须结束当前连接尝试、指出发生在
jump 还是 target，并允许同一 Pane 立即发起新连接；不能表现为无期限无响应。

## 受控语义

- `host add|set ... --connect-timeout <1-300|default>` 是用户可达的持久入口，只修改该
  Host 在唯一 config 中的 `ConnectTimeout`；它不是一次性 SSH option。`default` 删除显式
  行并恢复 15 秒。
- 接受 `ConnectTimeout <seconds>`，值必须是 `1` 到 `300` 的十进制整数；未设置时使用
  LeanTTY 当前可靠默认值 15 秒。
- 保持 OpenSSH config 的 Host 匹配和“第一个获得的值生效”规则。后续匹配块中的值不覆盖
  首值；无效的首个活动值在网络动作前失败，不静默回退。
- 目标 Host 的有效值用于 direct/target、reconnect 和复用该 Host 的 `put/get`；命名 jump
  Host 使用自己的有效值。一次性 jump endpoint 没有命名 Host 配置时使用 15 秒默认值。
  `ssh -G` 以秒输出目标有效值，并继续分别展示 jump/target 解析结果。
- Rust 现有 deadline 已覆盖 TCP 建连、SSH version exchange、初始握手和密钥交换，并在等待
  用户确认主机密钥时暂停。认证密码、私钥口令、OTP 等用户等待仍由独立认证边界负责。
- Pane 关闭、`Ctrl+C` 取消、Session generation 和迟到事件拒绝保持原有所有权；超时不触发
  自动重试，也不保存瞬时连接状态。

## 非目标

- 不增加通用 `ssh -o`、一次性 timeout override、第二份 config 或 GUI 设置。
- 不改变已连接 Session 的 half-open 检测；`ServerAliveInterval` 和
  `ServerAliveCountMax` 是后续独立候选。
- 不增加连接池、后台重试、DNS 策略或 AddressFamily 选择。
- 不把 `0` 解释为无限等待。LeanTTY 的可靠性边界要求连接尝试有确定上限。

## 事件链与验证

```text
~/.ssh/config
  -> SshConfigHost.connectTimeoutMs
  -> CommandParseResult / TransferCommandResult
  -> SshSession reconnect state or FileTransferOptions
  -> SshConnectOptions target/jump connectTimeoutMs
  -> Rust wait_for_connect deadline per jump/target layer
```

自动化覆盖默认值、Host/通配 Host 首值、有效边界、无效值、后续值不覆盖、`ssh -G`、
SSH/transfer 解析一致性和 Rust 用户等待暂停/分层超时/取消。物理 ARM64 HarmonyOS PC 只验证
本切片的普通握手超时、jump 超时、target-over-jump 超时、取消、超时后恢复和默认连接 smoke。

## 完成证据

- 聚焦 ArkTS、Web、Rust native、policy/tooling 检查与 ARM64 debug 签名 HAP 构建通过；
  Rust native 为 27/27，ArkTS 为 130/130。
- 物理 ARM64 HarmonyOS PC `HAD-W32` 通过
  `tools/verify-connect-timeout-pc.ps1` 的 direct target、jump handshake、
  target-over-jump、Ctrl+C 取消和默认连接恢复五项业务场景；每项均由真实命令提交、
  分层 Rust 事件、终端截图或受控 SSH fixture 后置条件共同判定。
- 本次真机证据使用签名 HAP SHA-256
  `6af84c4604d39ab16102b6a89a4bdfba91946b3dcb2567543999ea8db019148e`，汇总位于
  `build/verification/connect-timeout-20260821-022630/summary.json`。该开发期证据不替代
  1.5 正式候选和发布验收。
- 验收结束后，测试 Host、`known_hosts` 记录、HDC reverse mapping、fixture socket 和临时
  凭据均已移除；`fport ls` 返回空。

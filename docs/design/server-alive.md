# ServerAliveInterval / ServerAliveCountMax

> 状态：Implementing；direct target 黑洞已通过桌面与物理 PC 门禁
>
> 更新日期：2026-08-21
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 活动工作：[`next-work.md`](../next-work.md)

## 用户结果

当 Wi-Fi、休眠恢复、NAT 或路由黑洞留下仍显示 connected、但已无法从服务端收到任何 SSH
packet 的半开连接时，LeanTTY 应在有界时间内明确结束 Session、保留 terminal 内容并允许用户
立即重连。普通远端 shell 长时间没有输出时必须保持连接。

## 已有实现与兼容差异

LeanTTY 从 1.0 起已经在 russh client config 中固定使用 `30s` interval / `3` count。这个配置
覆盖 direct/target、ProxyJump target 和文件传输；连接 driver 返回 `KeepaliveTimeout` 时，现有
Session 路径会输出明确错误并进入已有关闭/重连状态。该切片不新增 ArkTS timer、周期 shell
输入、TCP keepalive 或第二套连接生命周期。

[OpenSSH `ssh_config(5)`](https://man.openbsd.org/man5/ssh_config.5) 的标准语义是：未收到服务端
数据达到 interval 后，通过加密 SSH 通道请求响应；interval 默认 `0`，即不发送；count 默认
`3`，示例 `15/3` 约 45 秒断开。配置仍采用 Host 匹配和每项首值生效规则。

russh `0.62.5` 的可观察行为与 OpenSSH 不完全相同：

- client 发送 want-reply 的 `keepalive@openssh.com` global request；
- 任意收到的 SSH packet 都复位 `alive_timeouts`，不只复位于特定 keepalive reply；
- timer 每次到期先递增计数；只有 `keepalive_max != 0 && alive_timeouts > keepalive_max` 才返回
  `KeepaliveTimeout`；因此 `100ms/3` 的受控黑洞在约第 4 个 interval 报错，而不是第 3 个；
- russh server 对未知 global request 自动返回 failure，普通静默 shell 仍会持续提供 SSH-level
  响应，不能用“shell 没有输出”模拟半开。

## 当前产品决策

- 未显式配置时保留 LeanTTY 现有 `30s/3` 可靠性默认。直接改成 OpenSSH 的 interval `0` 会
  静默撤销现有半开检测，且与“失败必须可观察、不能表现为无响应”的项目原则冲突。
- 显式 `ServerAliveInterval 0` 关闭 russh keepalive；`default` 删除 Host 中的显式 directive，
  恢复 LeanTTY 产品默认，而不冒充 OpenSSH 编译默认。
- 配置只进入唯一 `~/.ssh/config` 和现有 Host 编辑命令，不增加 GUI 设置或通用 `-o`。
- target Host 的有效值用于 direct/target、reconnect 和 `put/get`。命名 jump Host 应使用自己的
  有效值；一次性 jump endpoint 使用 LeanTTY 默认。最终分层行为仍须由受控 target/jump 黑洞
  真机证据确认。
- 超时继续复用现有 Session close/error/reconnect 路径，不自动重试，不清空 terminal，不在
  Pane、Tab 或应用全局保存瞬时 timer 状态。

## 受控半开 fixture

fixture 在公开监听 socket 和内部 russh server 之间加入 repository-only TCP proxy。连接、密钥
交换、认证和 shell 先正常完成；创建 run-scoped 控制文件后，proxy 继续转发 client→server，
但读取并丢弃 server→client 字节，两个 TCP socket 都保持打开。这样 server 仍实际收到
`keepalive@openssh.com` 并产生 reply，而 client 永远收不到 reply；它不是主动 close、端口拒绝、
进程退出或短 `ConnectTimeout`。

`tools/start-ssh-auth-fixture.ps1 -EnableServerOutputDrop` 只在临时 fixture 目录暴露控制文件，
进程结束后沿用现有目录清理。Rust 自动化已经证明控制文件前双向传输正常、文件后只有
server output 被丢弃、client 退出后双方资源释放，以及 russh `max + 1` interval 的超时行为。

物理 ARM64 HarmonyOS PC `HAD-W32` 使用未改动的现有 `30s/3` 产品值通过 direct target
诊断：正常认证和 fixture 输入先成立，控制文件触发单向黑洞后 Session 在允许的
`105–145s` 窗口内显示 keepalive 超时错误；移除控制文件后同一 Pane 立即重新认证，受控服务器
收到新的 terminal 输入并正常关闭。证据位于
`build/verification/device-ssh-auth-20260820T202730610Z/device-ssh-auth.json`，签名 HAP
SHA-256 为 `0345c8418e766a9697e7f7aa177d5bf369cd49c8e177ac1271c3fe7da287ac2e`；这是开发期
诊断，不替代 1.5 正式候选验收。Host/known_hosts、HDC reverse、fixture 进程、控制文件与临时
凭据的清理审计通过。

## 进入实现前仍须闭合

1. 以同一 fixture 证明普通静默 shell 不误断，并确定 ProxyJump 的 jump transport 与 target
   transport 分层结果；若 jump driver 错误没有进入用户可恢复路径，先修正现有所有权。
2. 锁定配置整数边界、`ServerAliveCountMax 0` 在 russh 中的用户可解释语义、`ssh -G` 输出和
   Host 编辑命令，再授权解析与传播实现。
3. 实现后补齐 direct、ProxyJump、transfer、取消、Pane close、休眠恢复、立即重连和双 Pane
   隔离的最小自动化与真机场景；验收结束必须删除 Host、known_hosts、reverse mapping、fixture
   socket、控制文件和临时凭据。

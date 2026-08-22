# Basic SSH Escape

> 状态：Verified；1.5.0 第二个产品切片已闭合
>
> 更新日期：2026-08-21
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 活动工作：[`next-work.md`](../next-work.md)

## 用户结果

交互式 SSH PTY 已连接时，用户可以在行首输入 `~.` 立即断开当前 Session，输入 `~?`
查看 LeanTTY 支持的 escape，输入 `~I` 查看当前连接 route；`~~` 向远端发送一个字面
`~`。这些动作不要求关闭 Pane，不借用远端 shell 命令，也不会串到其他 Pane。

## 受控语义

- 固定使用 OpenSSH 默认 escape character `~`，仅在 Session 开始或 CR/LF 后识别。
- 语义基线来自 OpenBSD [`ssh(1)`](https://man.openbsd.org/ssh.1)；终端 focus report 等
  实际输入也会结束“刚发送换行”的状态，alternate-screen 中需在要使用 escape 前明确按 Enter。
- 识别器跨 ArkWeb 输入 chunk 保留行首和待定 `~`；行中的 `~`、未知 `~x` 和其他输入
  原样发往远端。`~~` 在行首只发送一个 `~`。
- `~.` 复用当前 `SshClient.disconnect → onSshClose → IDLE` 路径，保留终端内容并允许立即
  重连；识别后同一输入 chunk 的剩余字符不再发送。
- `~?` 只列出 `~.`、`~?`、`~I`、`~~`，不展示 LeanTTY 未实现的 OpenSSH escape。
- `~I` 只显示 Session 已有的 target、可选 jump、用户可见 Host、端口和 connected 状态；
  不显示密码、口令、Identity 路径、终端内容、内部 Session ID 或解析后的额外资产。
- 进入或离开 connected mode 时清空识别状态；每个 SessionViewModel 拥有自己的识别器。

## 非目标

- 不支持 `-e`、`EscapeChar`、`~C`、`~R`、`~B`、`~^Z`、`~&`、`~#` 或动态 verbosity。
- 不增加后台 Session、local command、forwarding、rekey、BREAK、菜单或新设置。
- 不在认证、Host key、local command、`put/get` 或未连接状态识别 SSH escape。

## 事件链与验证

```text
ArkWeb terminal input chunk
  -> SessionViewModel (current Pane owner)
  -> SshEscapeParser (line-start/pending-tilde only)
  -> remote bytes via existing SshClient.write
     or local help/info/disconnect action
```

纯逻辑测试覆盖逐字符、整段、跨 chunk、CR/LF、行中 tilde、字面与未知 escape、disconnect
后丢弃、事件顺序、reset 和 connection-info 脱敏格式。物理 ARM64 HarmonyOS PC 专项证据为
`build/verification/device-ssh-auth-20260820T193344280Z/device-ssh-auth.json`：受控 fixture 验证
普通/字面/未知输入的远端最终字节、help/info 本地消费、alternate-screen 明确换行后的 escape、
断开后立即重连和双 Pane pending-state 隔离；临时凭据、reverse、known_hosts 与 fixture 清理通过。

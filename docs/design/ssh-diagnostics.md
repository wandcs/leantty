# 安全 SSH 诊断

> 状态：Completed
>
> 更新日期：2026-08-21
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 活动工作：[`next-work.md`](../next-work.md)

## 用户结果与进入结论

当连接停在网络、SSH 握手、主机校验、认证、ProxyJump、PTY 或 keepalive 时，用户可以只为
本次连接执行 `ssh -v ...`，在当前 Pane 看到固定、可行动的阶段变化。诊断默认关闭，不写文件、
不进入历史、配置、遥测或上传通道，Session 结束后不保留单独状态。

当前 russh `0.62.5` 已提供足够的结构化生命周期节点，且公开错误枚举可以在不输出原始异常的
前提下区分名称解析、TCP 拒绝/超时、SSH version 与 KEX。因此本切片通过进入门禁，采用现有
`Pane → Session → SshClient → native driver` 事件链，不开启 russh trace，不增加第二套连接
状态机。`-vv`、`-vvv`、`-E`、日志导出和通用 `LogLevel` 不进入范围。

## 事件目录与能力边界

| 路径 | 可观察节点 | 固定诊断 | 不能声称的粒度 |
| --- | --- | --- | --- |
| direct target | connect、host key、authentication、channel、PTY、shell、session、keepalive | `target` layer 的 started/waiting/succeeded/failed/timed out/cancelled/closed | 任意 packet、算法列表、服务端原文 |
| ProxyJump | jump connect/host key/auth/tunnel；target 全部 direct 节点 | jump 与 target 严格分层 | 多跳、链路逐 hop packet trace |
| reconnect | 复用同一连接链；普通 reconnect 不继承 `-v` | 只有用户再次显式执行 `ssh -v` 才开启 | 持久 verbose 偏好 |
| `put/get` | 已有 transfer stage、layered auth、host key、connection-driver keepalive | 继续使用文件传输自己的当前进度与错误 | `put/get -v`、把 transfer 数据纳入 SSH trace |

`russh::client::connect` 在网络连接、SSH version、KEX 和 host-key callback 完成后才返回。LeanTTY
在 handler 内单独发出 host-key 节点，并把公开错误压缩为固定 `reason`：

- `name_resolution`、`tcp_refused`、`tcp_timeout`、`tcp_failed`；
- `ssh_version`、`key_exchange`、`transport_failed`。

只有 `connect/failed` 可以携带上述 `reason`。无法由公开类型可靠判断的错误归入
`transport_failed`，不根据本地化错误字符串猜测。认证方法、server banner、keyboard-interactive
提示与回答继续走现有受控交互，但不会成为诊断字段。

## 字段与数据安全

native 诊断对象只允许以下字段：

| 字段 | 允许值 |
| --- | --- |
| `kind` | 固定为 `diagnostic` |
| `layer` | `jump`、`target` |
| `stage` | `connect`、`host_key`、`authentication`、`tunnel`、`channel`、`pty`、`shell`、`session`、`keepalive` |
| `status` | `started`、`waiting`、`succeeded`、`failed`、`timed_out`、`cancelled`、`closed` |
| `reason` | 空或上节固定 connect failure 枚举 |

ArkTS 在渲染前再次验证全部枚举；额外对象字段被忽略，非法枚举显示固定的 rejected 文案。
终端输出只由本地固定字符串组成，例如 `Target TCP connection: refused.`，不拼接 native 原始
异常。

以下内容禁止进入诊断事件、诊断终端行或系统日志：password、passphrase、OTP、private/session
key、认证回答、server prompt/banner、terminal input/output、host、IP、username、path、
fingerprint 和 public-key material。原有必须驱动交互的 control event 仍可在进程内携带 host-key
或 server prompt，但系统日志只记录经过白名单压缩的类别、layer 和固定失败类别。超时日志只
保留十进制毫秒数。自动化使用 fixture 侧的真实连接结果证明目标，不再把 host 写入系统日志
作为同步信号。

## 生命周期

- parser 每条命令最多接受一个独立 `-v`；重复 `-v` 和组合 `-vv` 在网络动作前失败；
- `verbose` 只在当前 `CommandParseResult` 和 `SshClient` 存活，不写入 `SshSession` 或 Host；
- native 只在该连接的 flag 为 true 时调用 diagnostic callback；默认 `ssh` 不产生诊断行；
- 本地取消发出 fixed cancelled，remote close、driver failure 和 keepalive timeout 使用现有
  Session close/error/reconnect 路径；
- Pane 只渲染自己的 `SshClientEvent.DIAGNOSTIC`，不建立全局诊断中心。

## 验收边界

源码门禁必须覆盖 parser 一次性语义、全部字段/原因白名单、敏感 sentinel 不进入日志标签与
终端固定文案、native reason 分类、默认关闭和 reconnect 不继承。物理 ARM64 HarmonyOS PC
至少验证：

1. direct 首次 host-key、password auth、channel/PTY/shell/session 的有序诊断和真实 shell；
2. 不带 `-v` 的同一路径没有诊断行；
3. TCP refusal 显示固定 target 原因，系统日志不含命令 host、fingerprint 或 fixture secret；
4. ProxyJump 的 jump/target 分层顺序与真实 target 输入；
5. `~.` 或认证等待取消只结束当前 Session，随后普通重连仍默认关闭诊断；
6. run-scoped Host、known_hosts、fixture、HDC mapping 和临时凭据全部清理。

这些是开发期 change-scoped 证据，不替代正式 release candidate 的完整 L4 验收。

## 物理 ARM64 HarmonyOS PC 证据

最终测试使用同一测试签名 HAP，SHA-256 为
`c69be8abfd127c7fc77367d254b3e3796c76a0833c291ae6df67c7eb852fecd1`：

- direct 场景覆盖首次 host-key、password auth、channel/PTY/shell/session 的固定有序诊断，
  fixture 收到 `ltty-input-check diagnostics`；截图确认诊断只在当前终端显示，密码为掩码，
  正常 host-key prompt 仍按用户动作显示 fingerprint。随后同一 endpoint 的普通 `ssh` 没有
  diagnostic event，未监听端口被固定分类为 `target/tcp_refused`，认证等待中的 Ctrl+C 产生
  cancelled 并恢复本地输入。证据位于
  `build/verification/device-ssh-auth-20260821T142908051Z/device-ssh-auth.json`。首次隔离尝试在
  fixture 预检命令提交阶段得到 unknown，未进入产品 SSH 链且清理通过；成功证据按合同记录了
 该 attempt ID 后原样重跑，没有修改产品或 oracle。
- ProxyJump 场景使用不同临时密码验证 jump/target host key 和认证；jump tunnel succeeded 后
  target 独立进入 connect/host-key/auth/channel/PTY/shell/session，目标 fixture 收到
  `ltty-input-check diagnosticsproxy`，同一命令随后复用两层 known_hosts 正常重连并关闭。
  证据位于 `build/verification/proxy-jump-20260821-223111/summary.json`。

两项证据均通过临时凭据扫描；产品 `SshClient` 日志投影不含 host、IP、fingerprint 或 fixture
secret。测试 HAP 的 source-injected `ACCEPTANCE_INPUT_SUBMIT` 会记录测试命令本身，不能冒充
生产日志边界，因此诊断安全 oracle 只读取产品 `SshClient` 行；生产源同时由静态断言保证不再
记录完整命令 target 或原始 control payload。direct 和 ProxyJump 的 known_hosts、fixture、
HDC mapping 与临时凭据均清理，direct evidence 的 cleanup audit 全部通过。

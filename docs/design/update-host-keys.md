# UpdateHostKeys

> 状态：Deferred；russh 0.62.5 公开 API 不提供完整证明链
>
> 更新日期：2026-08-21
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 活动工作：[`next-work.md`](../next-work.md)

## 用户结果

用户已经可信连接并认证到正确服务器后，服务器可以在旧主机密钥仍有效时提前提供新密钥，
让后续轮换不必删除整条信任记录并重新走 TOFU。这个便利不能降低主机信任边界：服务端仅仅
声称一个 public key 属于自己，不足以把它写入 `known_hosts`。

## 标准与 OpenSSH 基线

[OpenSSH protocol extension](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL) 和
[IETF host key update draft](https://datatracker.ietf.org/doc/draft-ietf-sshm-hostkey-update/) 共同定义
了一条不可拆分的链路：

1. 用户认证成功后，服务端最多一次发送 `hostkeys-00@openssh.com`，其中每个 SSH public key
   blob 必须唯一；公告不要求 reply，也不建立新信任。
2. 客户端只对尚未信任的新 key 发送 want-reply 的
   `hostkeys-prove-00@openssh.com`，请求顺序与 key 一一对应。
3. 服务端必须用每个新 key 的 private half 对
   `"hostkeys-prove-00@openssh.com" + session identifier + hostkey` 的 SSH wire structure 签名；
   客户端必须逐个验签。failure、数量或顺序不一致、畸形 payload、不安全 RSA signature 或任一
   验签失败时，不得信任对应的新 key。
4. 只有完整证明通过后才可以记录新 key。公告集合不再包含的旧 key 可以删除或停用，但这不是
   自动接受当前连接未知/变化 key 的替代路径；新信任的上限仍是建立本次 SSH transport 的旧 key。

[OpenSSH `ssh_config(5)`](https://man.openbsd.org/ssh_config) 的产品语义是：`UpdateHostKeys` 接受
`yes`、`no` 或 `ask`；只有当前 host key 已受信或由用户明确接受、来自 `UserKnownHostsFile`、
且使用普通 key 而不是 certificate 时才允许更新。未覆盖默认 `UserKnownHostsFile` 且未启用
`VerifyHostKeyDNS` 时默认开启，否则默认关闭；`ask` 在写文件前确认。

OpenSSH 当前实现还施加以下保守持久化边界：

- 主机匹配按本次 target 的 known-host identity 执行；非默认端口继续使用 `[host]:port` 表示，
  `HashKnownHosts` 决定新写入名称是否哈希。
- wildcard、手工 host 列表、CA/revocation marker 或其他复杂 hostspec 不自动改写。
- 待删除的旧 key 若还在其他名称/地址下出现，则跳过更新，避免共享 key 的别名被误删。
- ProxyJump 的 jump 与 target 是两条独立 SSH transport 和主机信任链；每层只能更新自己的
  known-host identity，不能把 target 公告用于 jump，反之亦然。
- 用户显式 `no` 必须完全关闭处理；不支持扩展的普通服务器保持现有连接与 known_hosts 不变。

## russh 0.62.5 能力审计

LeanTTY 的 `Cargo.lock` 固定使用 russh `0.62.5`。实际依赖源码显示：

- client 能识别 `hostkeys-00@openssh.com`，把可解析 blob 转成 `Vec<PublicKey>` 后调用
  `Handler::openssh_ext_host_keys_announced`；无法解析的 key 只写 debug log，回调拿不到原始
  payload、重复项或解析失败的结构化结果。
- public `client::Session` 只提供 tcp/streamlocal forward、keepalive、ping 和
  `no-more-sessions` 等固定 global request。`GlobalRequestResponse`、packet buffer 与待响应队列均为
  crate-private，没有任意 request + reply payload API；源码中也没有 `hostkeys-prove` 实现。
- proof 必须绑定的 `Encrypted.session_id` 位于 crate-private session state；公告 handler 收到的
  public `client::Session` 没有 accessor。
- request-success parser 只接受固定 response variant，不能把 proof signatures 返回给 LeanTTY。
- server public API 可以对收到的 global request 发送空 success/failure，并能发送少量固定 request，
  但不能构造带 host key 列表的公告或带 signatures payload 的 proof reply。因此现有 repository
  fixture 也无法通过公开 API 忠实建立该协议链。

结论是“能观察公告，但不能安全实现 UpdateHostKeys”。IETF 安全说明明确要求实现公告与证明两部分，
并禁止在未验证 private-key possession proof 时记录新 key。仅新增 parser、在回调中直接写
`known_hosts`、从日志猜 response、复制 russh 私有 packet state，或维护本地 fork 都会扩大密码学与
协议维护边界，不符合用户信任、可靠和简洁原则。

## 当前裁剪决定与重新进入条件

1. 1.5 不实现 `UpdateHostKeys`，不增加 config directive、持久化、fixture 或用户入口；当前
   known_hosts 行为保持不变。
2. 不执行原计划的 observation-only 双服务器 fixture。它只能证明公告回调，而不能证明产品所需
   的 request、session-bound signatures、failure payload 与完整验签，继续投入不会改善进入判断。
3. 满足以下任一条件后才重新进入：
   - russh 稳定公开 API 原生提供公告原始结果、proof request/reply、session id 与逐 key 验签；或
   - 上游接受并发布经过独立评审、覆盖异常 payload 与算法边界的等价 API。
4. 重新进入时仍须重新确认当时 IETF/OpenSSH 语义，并补齐 valid add/replace、proof failure、
   unknown/duplicate/malformed、断线、target/jump 隔离、原子 no-follow 写入、失败保留原文件和立即
   重连真机验证。依赖升级本身不等于产品能力完成。

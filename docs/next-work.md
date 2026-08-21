# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-21
>
> 当前 milestone：[`1.5 — SSH 连接可靠性、诊断与资产互操作`](roadmap.md)
>
> 当前工程阶段：启动 1.5 第五个产品切片的安全诊断进入门禁
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 测试权威：[`quality-strategy.md`](quality-strategy.md)

本文件只保留尚未完成、已经授权的活动工作，并按实际依赖顺序执行。完成事实进入相应
规范、设计文档和 Git 历史；旧 checkbox、定向实现证据、WIP 技术方案及后续 milestone
不在这里维护第二份清单。

## 当前发布基线

`v1.3.0` 已于 2026-08-17 通过 AppGallery 审核并正式上架。`v1.4.0` 已由不可变签名
标签、精确发布源和 GitHub Release 冻结，production APP、review-test HAP、manifest、
哈希和发布材料已经完成；维护者已于 2026-08-21 在 AppGallery 提交审核，当前等待审核
结果。项目只有在维护者报告结果后才记录新的商店状态。当前工作不修改 `v1.4.0` 的发布
身份，也不补做新的 1.4 产品范围。

1.4 发布复盘形成的验收与发布工具链优化是 1.5 的第一项工程基础：稳定规则写入
`quality-strategy.md`，研究、红绿证据和量化结果写入 `test-release-efficiency.md`。它不改变
用户可见产品源，也不能替代 1.5 产品范围确认。

## 1.5 当前活动工作

### 第五个切片：安全 `ssh -v` 诊断基线与进入判断

用户在连接、主机校验、认证、ProxyJump 或半开连接失败时，应能在 LeanTTY 内看到下一步真正
有用的诊断，而不必换到另一台电脑。该能力不能复制 russh/OpenSSH 原始日志：原始 host、IP、
username、路径、key material、认证回答或 terminal 内容都可能扩大本地暴露面。这个切片首先
只建立安全事件目录、数据边界和库能力；没有证据前不开放持久日志或分享入口。

1. [ ] 盘点 direct、ProxyJump target/jump、reconnect 与 `put/get` 的现有结构化事件和错误来源，
   用真实失败样本建立最小诊断问题集；区分 DNS/TCP、SSH version/KEX、host verification、auth、
   PTY、keepalive、remote close 与用户取消，不用 UI 文案或原始 log 反推状态。
2. [ ] 建立字段级安全分级与默认脱敏规则：证明 password/passphrase/OTP/private key、session key、
   terminal input/output 永不进入诊断；host/IP/user/path/fingerprint 只在当前终端按用户动作有界
   显示，不持久化、不进入系统日志，target/jump 分层但不串资产。
3. [ ] 审计 russh `0.62.5` 与 LeanTTY 当前 handler/driver 能否在不启用全局 trace log 的情况下
   提供这些结构化节点；用 repository-only fixture 覆盖至少 DNS/拒绝、握手/KEX、host key、
   多方法 auth、jump/target、keepalive 与取消，并加入禁止敏感值出现的自动化断言。
4. [ ] 基于证据形成专项方案并做进入/裁剪决定。若进入，优先使用一次连接、默认关闭、仅当前
   Pane 可见且随 Session 结束丢弃的 `ssh -v`；不加入日志文件、历史中心、遥测、自动上传、
   “复制全部原始日志”或第二套连接状态机。

`ConnectTimeout`、基本 SSH escape 与 `ServerAliveInterval/ServerAliveCountMax` 已完成并归档到
专项设计。`AddressFamily` / `ssh -4/-6` 已完成标准基线，但当前物理 PC 没有全局 IPv6 默认
路由，HDC reverse 也没有提供可用的 `::1` SSH fixture；按真机进入门禁暂不实现，不能以 parser
或字段传播测试代替。UpdateHostKeys 已完成标准与 russh `0.62.5` 能力审计；依赖缺少完整 proof
request/reply、session binding 和验签公开 API，因此按安全停止条件裁剪，重新进入条件记录在
[`design/update-host-keys.md`](design/update-host-keys.md)。除本节晋级的安全诊断基线外，config
导入导出、`ssh-keygen -c` 和 ECDSA 互操作仍是候选集合，不因 1.5 milestone 已启动而整体获得
实现授权。
推广手册只提供稳定工作方法；没有单独写入本文件的 Pxx 不属于当前活动任务。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到权威文档和 Git 历史，并从本文件删除。
2. 每项任务必须说明可观察完成条件；代码修改、一次通过、构建、安装、窗口出现或 HDC 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

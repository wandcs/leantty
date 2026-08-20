# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-21
>
> 当前 milestone：[`1.5 — SSH 连接可靠性、诊断与资产互操作`](roadmap.md)
>
> 当前工程阶段：实现并闭合 1.5 第二个产品切片 `AddressFamily` / `ssh -4/-6`
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

### 第二个切片：受控 `AddressFamily` 与 `ssh -4/-6`

用户面对双栈 DNS、单栈网络或只能通过特定地址族到达的目标时，可以在唯一 OpenSSH config
中保存标准 `AddressFamily`，也可以用标准 `ssh -4/-6` 对当前连接作一次明确选择。选择必须
约束真实 DNS 解析和 TCP 连接，而不是只接受一个无效 flag；失败必须指出是 IPv4、IPv6 还是
默认双栈路径，并保持 Host、认证、主机校验、ProxyJump、重连和 `put/get` 的现有所有权。

这个切片只增加一个三值连接策略，不增加 DNS 缓存、Happy Eyeballs 框架、网络扫描、地址
重写、第二份 Host/config 或通用 `-o`。命名 jump 与 target 分别使用自己的有效配置；一次性
`-4/-6` 是否以及如何作用于 jump/target，必须先对照 OpenSSH 标准行为和受控双栈证据锁定，
不能由当前实现猜测。

1. [ ] 建立标准与受控网络基线：记录 OpenSSH `AddressFamily any|inet|inet6`、`ssh -4/-6`、
   Host 首值和 CLI/config 优先级；在本机与物理 HarmonyOS PC 上证明可重复的 IPv4-only、
   IPv6-only、双栈同名目标及单跳 ProxyJump fixture。没有真实 IPv6 路径时不得用 parser 测试
   代替，也不得实现后再倒推语义。
2. [ ] 形成专项方案并确定最小用户入口：`host add|set ... --address-family
   <any|inet|inet6|default>` 只修改唯一 config 中的标准字段，`ssh -4/-6` 只影响当前 SSH；
   `ssh -G` 输出真实有效值，重复、冲突、无效配置和不适用于本地命令的 option 在网络动作前
   明确失败。
3. [ ] 让地址族策略贯穿真实解析与连接：普通 SSH、命名 jump/target、重连和复用 Host 的
   `put/get` 使用同一解析结果；Rust 只尝试允许的 socket family，并保留 ConnectTimeout、
   取消、Host key identity、Session generation 和迟到事件拒绝。
4. [ ] 补齐 ArkTS/Rust 自动化，至少覆盖默认 any、Host/通配 Host 首值、CLI 覆盖、`-4/-6`
   冲突、IPv4/IPv6 literal、DNS 多地址过滤、无允许地址、jump/target 独立配置、reconnect、
   transfer 和取消；测试必须证明实际选择的 socket family，而不只断言字段传播。
5. [ ] 运行映射的最小本地门禁与 ARM64 debug build，再在物理 ARM64 HarmonyOS PC 上验证
   IPv4-only、IPv6-only、双栈强制 v4/v6、错误 family 的确定失败、ProxyJump 分层、取消和
   默认 any 正常 smoke；安装、启动、`ssh -G` 或日志字段本身不能替代真实连接后置条件。
6. [ ] 将最终语义、非目标、自动化和真机证据同步到专项设计、User Guide/Help、Changelog
   与相关权威文档；从本文件删除完成切片，再依据真实阻断和复杂度决定 1.5 下一项。

`ConnectTimeout` 已完成并归档到专项设计。除本节已经晋级的地址族切片外，路线图中的
半开恢复、主机密钥轮换、
诊断、config 导入导出和 ECDSA 互操作仍是候选集合，不因 1.5 milestone 已启动而整体获得
实现授权。推广手册也只提供稳定工作方法；没有单独写入本文件的 Pxx 不属于当前活动任务。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到权威文档和 Git 历史，并从本文件删除。
2. 每项任务必须说明可观察完成条件；代码修改、一次通过、构建、安装、窗口出现或 HDC 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

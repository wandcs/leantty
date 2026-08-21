# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-21
>
> 当前 milestone：[`1.5 — SSH 连接可靠性、诊断与资产互操作`](roadmap.md)
>
> 当前工程阶段：启动 1.5 第四个产品切片的 UpdateHostKeys 进入门禁
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

### 第四个切片：UpdateHostKeys 标准基线与进入判断

用户已经可信连接并认证到正确服务器后，服务器可能因正常轮换而同时提供新的主机密钥。LeanTTY
应评估能否通过标准 SSH 扩展验证并原子更新唯一 `known_hosts`，减少下一次连接被迫删除整条
信任记录并重新走 TOFU 的风险。这个切片首先只建立标准、库能力和受控失败边界；没有证据前
不实现自动持久化，也绝不把当前连接遇到的未知/变化主机密钥当作轮换直接接受。

1. [ ] 建立 OpenSSH `UpdateHostKeys` 的标准与默认行为基线：明确扩展协商、服务端证明、何时
   允许增加/删除 key、通配 Host 与非默认端口表示、HashKnownHosts、跳板 target/jump 分层和
   用户显式关闭语义；只使用上游协议/实现资料，不从命令名称猜测行为。
2. [ ] 审计 russh `0.62.5` client/server 能力和 LeanTTY 当前 handler 生命周期，证明能否观察
   `hostkeys-00@openssh.com`、请求 `hostkeys-prove-00@openssh.com` 并验证每个 key 的签名；若库
   无法提供完整证明链，停止实现并记录重新进入条件，不自建未经审计的旁路协议 parser。
3. [ ] 扩展 repository-only 双服务器 fixture，覆盖 valid add、valid replace、证明失败、未知算法、
   重复/畸形 payload、连接中断、target/jump 串扰和普通不支持扩展的服务器；所有场景先只观察，
   不修改设备 `known_hosts`。
4. [ ] 基于证据形成专项方案并做进入/裁剪决定。若进入，只允许当前已验证 Host 的 opt-in/受控
   config 子集、原子 no-follow 持久化、失败保留原文件、明确用户结果和立即重连验证；不加入
   CA/certificate 管理、后台扫描、静默 TOFU、全局一键接受或第二份主机信任存储。

`ConnectTimeout`、基本 SSH escape 与 `ServerAliveInterval/ServerAliveCountMax` 已完成并归档到
专项设计。`AddressFamily` / `ssh -4/-6` 已完成标准基线，但当前物理 PC 没有全局 IPv6 默认
路由，HDC reverse 也没有提供可用的 `::1` SSH fixture；按真机进入门禁暂不实现，不能以 parser
或字段传播测试代替。除本节晋级的 UpdateHostKeys 基线外，安全诊断、config 导入导出、
`ssh-keygen -c` 和 ECDSA 互操作仍是候选集合，不因 1.5 milestone 已启动而整体获得实现授权。
推广手册只提供稳定工作方法；没有单独写入本文件的 Pxx 不属于当前活动任务。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到权威文档和 Git 历史，并从本文件删除。
2. 每项任务必须说明可观察完成条件；代码修改、一次通过、构建、安装、窗口出现或 HDC 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

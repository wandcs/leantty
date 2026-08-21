# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-21
>
> 当前 milestone：[`1.5 — SSH 连接可靠性、诊断与资产互操作`](roadmap.md)
>
> 当前工程阶段：实现 1.5 第七个产品切片的 `ssh-keygen -c`
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

### 第七个切片：实现 `ssh-keygen -c` key comment

用户从其他 OpenSSH 环境导入或长期维护 Identity 时，应能修正公钥注释而不生成一把新 key、
改变 fingerprint、削弱私钥加密或制造公私钥两份身份。标准、`ssh-key` 0.6.7、当前 Ed25519/RSA
格式和提交边界审计已通过进入门禁，专项合同见
[`design/key-comment-change.md`](design/key-comment-change.md)。

1. [ ] 在 Rust core/NAPI 实现私钥与 `.pub` 的验证、同口令重编码、双文件 stage/replace/rollback，
   覆盖无口令/有口令、空格与 Unicode/空注释、公私钥不一致、错误口令、两阶段替换失败、0600
   权限、临时文件清理和 fingerprint/public wire key 不变。
2. [ ] 增加 `ssh-keygen -c -f <identity>` parser 与交互状态：加密 key 复用 masked 旧口令输入，
   新 comment 使用可见输入并支持空值删除；控制字符和超过 1023 UTF-8 bytes 的输入必须在写入前拒绝。
3. [ ] 将成功 pair 纳入现有 durable Identity，建立 durable commit 失败时恢复旧 comment 的故障
   注入；错误口令、取消、失败详情和日志不得泄露 passphrase 或私钥内容。
4. [ ] 跑聚焦 Rust/ArkTS/策略门及命名物理 PC 场景，证明 fingerprint、加密状态、原口令认证、
   restart/reopen 和测试 key 清理，再收口指南、CHANGELOG 与本清单。

`ConnectTimeout`、基本 SSH escape 与 `ServerAliveInterval/ServerAliveCountMax` 已完成并归档到
专项设计。受控 config import/export 已完成真实样本、严格导入、原文 round-trip、原子恢复与
物理 PC 闭环，见 [`design/config-import-export.md`](design/config-import-export.md)。
`AddressFamily` / `ssh -4/-6` 已完成标准基线，但当前物理 PC 没有全局 IPv6 默认
路由，HDC reverse 也没有提供可用的 `::1` SSH fixture；按真机进入门禁暂不实现，不能以 parser
或字段传播测试代替。UpdateHostKeys 已完成标准与 russh `0.62.5` 能力审计；依赖缺少完整 proof
request/reply、session binding 和验签公开 API，因此按安全停止条件裁剪，重新进入条件记录在
[`design/update-host-keys.md`](design/update-host-keys.md)。安全 `ssh -v` 已完成固定事件、脱敏、
direct/ProxyJump 真机闭环，见 [`design/ssh-diagnostics.md`](design/ssh-diagnostics.md)。除本节
晋级的 `ssh-keygen -c` 门禁外，ECDSA 互操作仍是候选集合，不因 1.5 milestone 已启动而获得
实现授权。
推广手册只提供稳定工作方法；没有单独写入本文件的 Pxx 不属于当前活动任务。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到权威文档和 Git 历史，并从本文件删除。
2. 每项任务必须说明可观察完成条件；代码修改、一次通过、构建、安装、窗口出现或 HDC 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-21
>
> 当前 milestone：[`1.5 — SSH 连接可靠性、诊断与资产互操作`](roadmap.md)
>
> 当前工程阶段：1.5 已授权产品切片已闭合；当前没有未完成的授权工程项
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

## 1.5 当前状态

`ConnectTimeout`、基本 SSH escape、`ServerAliveInterval/ServerAliveCountMax`、安全 `ssh -v`、
受控 config import/export 和 `ssh-keygen -c` 已分别完成专项实现、聚焦软件门与所需的物理
ARM64 HarmonyOS PC 闭环。`AddressFamily` / `ssh -4/-6` 因当前设备没有可重复的全局 IPv6
fixture 路径而暂缓；UpdateHostKeys 因 russh 缺少完整 proof request/reply、session binding 和
验签公开 API 而按安全停止条件裁剪。专项完成事实和重新进入条件保留在 roadmap 与对应设计
文档，不在本文件复制历史 checklist。

当前没有尚未完成且已经授权的 1.5 工程项。ECDSA 互操作仍是候选集合，必须单独通过库、
安全、真实样本与物理机互操作门禁后才能写入本文件；1.5 正式候选、版本元数据、完整验证、
签名、GitHub Release 和 AppGallery 交付也必须由维护者单独启动 release preparation，不能由
开发期签名 HAP 或局部真机证据自动推导。推广手册只提供稳定工作方法；没有单独写入本文件的
Pxx 不属于当前活动任务。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到权威文档和 Git 历史，并从本文件删除。
2. 每项任务必须说明可观察完成条件；代码修改、一次通过、构建、安装、窗口出现或 HDC 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

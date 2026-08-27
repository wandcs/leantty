# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO；1.5.1 产品与发布工具开发已闭合，等待合入和正式发布准备
>
> 更新日期：2026-08-28
>
> 当前 milestone：[`1.5.1 — Host/Identity 主路径修复与发布工程效率`](roadmap.md)
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 测试权威：[`quality-strategy.md`](quality-strategy.md)

本文件只保留尚未完成、已经授权的活动工作。完成事实进入相应规范、设计文档和 Git 历史；
历史 checkbox、定向证据和后续 milestone 不在这里维护第二份清单。

## 当前发布基线

`v1.3.0` 已于 2026-08-17 通过 AppGallery 审核并正式上架。`v1.4.0` 已由不可变签名
标签、精确发布源和 GitHub Release 冻结，维护者于 2026-08-22 确认匹配的 production APP
已通过 AppGallery 审核并正式上架。`v1.5.0` 已于 2026-08-26 由不可变签名标签、精确
发布源、非草稿
[GitHub Release](https://github.com/wandcs/leantty/releases/tag/v1.5.0) 和归档产物冻结；
维护者于 2026-08-28 确认匹配的 production APP 已通过 AppGallery 审核并正式上架。
当前工作不修改以上版本的发布身份。

## 当前活动工作

### 1.5.1 — 合入与正式发布准备

1.5.1 已完成 `host add|set -i <identity|none>`、严格错误、原子 OpenSSH config 持久化、
解析优先级和中英文指南。聚焦软件门覆盖新增、更新、保留、删除、错误输入、重启解析、
direct/ProxyJump 与 `put/get` 共用结果；物理 ARM64 HarmonyOS PC 已用临时专用 Identity
闭合 `host add -i` → `ssh-copy-id -i` → `ssh <alias>`、应用重启、`-i none` 密码回退、
恢复绑定和独立清理。除仓库受控 russh 夹具外，同一 test-signed HAP 也已通过默认 WSL
系统 OpenSSH 的随机临时账户互操作；账户、home、`authorized_keys`、HDC reverse 和设备侧
临时资产均由 harness 删除并独立确认缺席。

发布工程改进也已实现：候选库使用规范化 origin 身份；product candidate 与 acceptance
harness 分别绑定精确身份；SSH、通知和 Agent 长矩阵具有原子检查点、attempt 链、只读恢复
审计和无内容进度；冻结前 readiness drill、可逆发布资产预生成及单一发布后状态更新已有
可执行入口。以上工具只减少重复工作，不改变签名、正式软件门、真实 PC、不可变标签、
GitHub Release 或 AppGallery 维护者操作的进入条件。

- [ ] 将本轮聚焦分支通过 PR 合入 `main`，并证明本地与远端 `main` commit/tree 相同、
  ahead/behind 为 `0/0`、工作区干净且主题分支已删除。
- [ ] 在干净 development、production 和 review checkout 上运行冻结前
  `test-release-readiness.ps1`，预生成并审计 license ZIP、Release notes、AppGallery 文案、
  交接清单和附件摘要；不得创建正式候选、标签或调用 Agent 模型。
- [ ] 从精确 release commit 建立一次 production candidate，按
  [`release-process.md`](release-process.md) 和
  [`quality-strategy.md`](quality-strategy.md) 完成正式软件门、生产签名、匹配 review HAP
  与适用物理 PC 矩阵。候选与 harness 身份、清理状态和恢复级别必须完整。
- [ ] 全部门禁通过后冻结 1.5.1 日期，创建不可变签名标签和非草稿 GitHub Release；核对远程
  commit、tag、附件和 SHA-256 后，向维护者交付同版本 production APP 与 AppGallery 材料。
- [ ] GitHub Release 与维护者交接事实齐备后只创建一个状态 PR。AppGallery `Released` 只能在
  维护者确认后记录；HSL/openEuler 推广文章也只在 1.5.1 正式上架后恢复发布。

下一次正式发布继续测量：实际执行时间目标约 2 小时 30 分钟、正常范围不超过 3 小时；
release commit 冻结后 product candidate 正常只构建一次；Agent 固定为 4 个工具 ×
direct/tmux 的 8 次请求，长任务另 1 次，0 自动重试；中断后 5 分钟内形成可审计恢复级别；
GitHub Release 后只需一个状态 PR。指标不能用于停止必要修复或弱化门禁。

## 维护规则

1. 只保留未完成且已授权工作；完成事实同步到权威文档和 Git 历史后从本文件删除。
2. 代码修改、一次通过、构建、安装、窗口出现或 HDC 成功不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

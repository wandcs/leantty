# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO；1.5.1 已通过 AppGallery 审核并上架，进入 1.6.0 开发
>
> 更新日期：2026-09-09
>
> 当前 milestone：[`1.6 — Mosh 弱网连接`](roadmap.md)
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 测试权威：[`quality-strategy.md`](quality-strategy.md)

本文件只保留尚未完成、已经授权或满足前置门后继续执行的工作。以下编号就是执行顺序；
前一阶段的停止条件未通过时，不进入后一阶段。完成事实进入相应规范、设计文档、
`CHANGELOG.md` 和 Git 历史，不在这里长期保留已完成 checkbox。

**当前执行位置：1. 密钥 cleanup 报告已完成软件修复；合并后按 R4 构建新候选并重启正式门。**

1.6 产品和验收工具的开发验证、CQ-001 至 CQ-004 修复，以及诊断后的两处精简已闭合。
普通 SSH/Mosh 不再做无消费者的输出观察解码；Mosh 首次连接成功后停用状态空轮询。
新 ARM64 测试包的 Keypush、SSH 主路径和 Mosh 固定端点验证及清理通过，未量化 CPU、
功耗或延迟收益。结果与限制见 [代码质量诊断](code-quality-diagnosis-1.6.md) 和
[性能诊断](performance-diagnosis-1.6.md)。

合并前评审新发现的 Mosh 末尾输出竞态已完成 native/owner 反例、最小幂等关闭修复及输入
拒绝/正常关闭真机验证；测试机已恢复普通开发包，清理通过。它与此前诊断分开记录在
[代码质量诊断](code-quality-diagnosis-1.6.md#2026-09-07-合并前发现的-mosh-关闭竞态)。

文档一致性收口已完成：维护者于 2026-09-07 确认离线指南无问题；revision 9 的双语文字和
截图已审查，源码/rawfile 字节一致；架构、隐私、安全、命令合同和依赖清单已对齐。证据与发布边界见
[指南审查记录](../tools/web-terminal/README.md#16-guide-revision-9-editorial-record--2026-09-07)。

历史工作、失败及停止记录已移入 [开发快照](archive/next-work-1.6-development-20260907.md)，
不再授权重复排错。development GO 依据仍为
[test-release-efficiency.md](test-release-efficiency.md) §8.30，不等于正式发布就绪。
旧候选的失败不被新开发结果改写；后续正式验收必须绑定新的精确 candidate/harness。

## 当前发布基线

`v1.3.0`、`v1.4.0`、`v1.5.0` 和 `v1.5.1` 已由不可变 GitHub Release 冻结，并由维护者确认
匹配的 production APP 已通过 AppGallery 审核并正式上架。维护者于 2026-08-29 确认
`v1.5.1` 的商店状态；其
[GitHub Release](https://github.com/wandcs/leantty/releases/tag/v1.5.1)、tag、release commit、
manifest、附件和哈希保持不变。

## 执行规则

1. 核心正确性、安全、泄密、状态串扰、崩溃或不可恢复问题随时抢占顺序；工具波动和性能
   噪声单独归类。先定位最后正确边界和首个错误边界，再做最小诊断，不重启整轮矩阵。
2. 每次变更只运行受影响的软件门和命名真机场景。完整软件、签名和物理矩阵只在正式候选
   执行；旧 revision、旧系统或其他 HAP 的报告保留原身份，不可改写成当前验收。
3. 诊断已按固定预算结束：checkpoint 仅 3 个有效样本，hitch unavailable，长期泄漏、系统
   OOM 和同系统 1.5.1 对比未证明。保留同步持久化、warm/队列预算和既有 xterm 补丁；不按
   文件行数拆类，不引入通用 Transport。只有新反例、可复核成本或相关源码变化才重开。
4. 按可交付结果合并执行批次：发布前收口、精确候选与正式验收、正式发布与商店交付。
   同一批次连续完成实现、相关验证和 PR 合并，不再按单个脚本或文档逐轮交接；遇到失败、
   新的授权边界或需维护者决策时才暂停。合并颗粒度不改变失败停止和证据身份规则。

## 1. 精确候选构建与正式验收

PR #171/#172 后的干净提交 `28b104991c300fe1909f2b490c1d7b64b1fba86e` 已通过当前
release-mode 包的 readiness（8 项）、完整 C1（26 项）、C2 构建/安装和正式 QH。
两种包中的指南均匹配已确认的 revision 9。C2 HAP、单独的 readiness 测试签名包及其
身份已留存；不混作 production APP。首次 C3 密钥场景的 9 项检查和实际清理通过，但
汇总器拒绝其旧 cleanup 格式，正式结果仍为失败，后续 17 阶段未运行。详见
[正式批次停止记录](test-release-efficiency.md#833-精确候选与正式密钥场景停止2026-09-08)。

密钥报告现在把标准判定和缺席细节分开，真实生产者/清理分支到汇总器的反例通过；共享
汇总器和产品不变。12 个注册报告生产者已检查。5 个现有兼容门均不接纳本次工具差异，
因此不再尝试旧报告 resume，也不扩大白名单来节省一次构建。按可靠、简单的优先顺序选择
R4；旧候选及全部报告保留原身份，不改判。理由与检查见
[工具修复及重建取舍](test-release-efficiency.md#834-密钥报告契约修复与候选重建取舍2026-09-09)。

- [ ] 从本次修复合并后的精确远端提交准备独立干净发布源和离线输入，更新 release-mode
  readiness 输入并完成预检；按 R4 新建 C0/C1/C2，再完成正式 QH 和完整 C3。两种新包都
  重新核对已确认指南的打包字节。旧 readiness/C2 不自动提升为新身份，未过 C3 不执行 C4。
  使用新的正式证据目录，按已注册入口完成完整 Agent/IME 及其余场景。Mosh 子矩阵
  按 compatibility、runtime-reclaim、UDP pause、suspend、lock、lid、Wi-Fi pause、
  Wi-Fi network switch 固定顺序执行。
  首个失败立即停止，后续只做 failed-stage 诊断并按 R1–R4 决定复用范围；只有同一
  candidate/harness 的全部场景和 cleanup 通过才能声明完整 C3，再完成其余交付门。

## 2. 正式发布与商店交付

- [ ] 按 [release-process.md](release-process.md) 完成交付。只有 1.6.0 全部门禁
  通过且交接资产齐备后，才创建不可变签名 tag 和非草稿 GitHub Release，向维护者交付
  同版本 production APP 与 AppGallery 材料。商店 `Released` 只由维护者确认后记录。

## 3. 1.6.0 之后再决定 Host/Key 列表输出合同

本节只授权方案决策，不进入 1.6.0 产品范围。当前固定 `padEnd` 表格不能处理长字段、窄终端
和 Unicode 显示宽度；已有 `ssh -G` 则能展示解析后的完整 Host 配置。

- [ ] 比较宽度感知摘要、窄终端逐项多行、显式截断加详情入口，以及摘要加
  `wide`/`--no-trunc`；明确不可歧义截断的标识、宽度来源、最窄列数和是否复用 `ssh -G`。
- [ ] 决定 `host list` 是否显示 Identity 及其他非默认持久选项，`key list` 是否显示 comment
  和 passphrase-protected 状态；优先展示会改变后续连接的持久配置，不暴露私钥路径或秘密。
- [ ] 维护者确认合同后，再把实现和验证拆成活动 TODO；届时统一 Host/Key 的排版所有者与字段
  投影，并覆盖长 Host/key、IPv6、转义文本、窄/宽窗口、双 Pane、重启持久化和列表/详情一致性。

## 当前不进入活动清单

- MatePad 实体键盘双模式仍因缺少合格物理测试机而阻塞；获得设备后按 roadmap 的抢占规则重排。
- Mosh remote command、高级网络覆盖、server 管理、文件传输、session manager、通用 Transport
  插件层，以及 HSL 直接本地 transport 仍需独立触发条件，不因 1.6.0 自动获得授权。

## 维护规则

1. 只保留未完成、已授权或明确受前置门约束的工作；完成后从本文件删除。
2. 代码修改、测试一次通过、构建、安装、窗口出现或 HDC 成功不能替代端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

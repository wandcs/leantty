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

**当前执行位置：1. 通知验收工具修复及三组最小真机验证已通过；下一批按 R4 建立新精确候选并完成正式验收。**

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

PR #173 合并后的 `2063de224562e28ddcd7db98075d7db1a5ceb9ef` 已按 R4 完成新包
readiness（8 项）、完整 C1（26 项）、C2 和正式 QH。两个新包中的指南均匹配已确认的
revision 9。密钥口令、comment 重启、ECDSA 导入重启，以及三组 Host/Identity 场景
和清理通过；旧 cleanup 报告缺陷已在真实链路闭合。现有 `id_ed25519` 经产品导出、
临时移除和恢复，私钥字节、公钥指纹、Host 配置均一致，临时备份已删除并确认缺席。

第九个注册阶段 `background-bell` 失败后立即停止，后续 11 阶段未运行。系统通知当时
关闭，产品按合同延后发布；工具却直接归为 product failure。返回前台的权限弹窗又遮住
终端，导致原 cleanup 失败。另发现 Pane ID 正则截断，以及只等待 BEL fired、未等待
异步发布完成的静态缺口。已独立拒绝弹窗、清除 attention、确认通知中心无 LeanTTY 卡片
并恢复可见终端；原正式失败不改判。详见
[本轮停止与恢复记录](test-release-efficiency.md#835-r4-候选与后台通知场景停止2026-09-09)。

通知工具修复已用真实脚本反例和正向、权限开关、双 Pane suppression/reset 三组真机验证，
原通知设置、卡片缺席、临时分屏和屏幕超时清理均通过。未改变产品权限策略；此次系统未
再次弹出授权框，该分支只计软件验证。结果与限制见
[通知工具修复记录](test-release-efficiency.md#836-通知验收前置状态与异步边界修复2026-09-09)。

- [ ] 修复合并后按 R4 冻结新的精确 candidate/harness，完成 readiness、C1/C2 和 QH。
  五个现有兼容门不接纳这次工具差异，不直接跨 harness resume，不扩大白名单或改报告。
  随后完成注册通知（包括本轮未重跑的冷启动、晚到和手动消除变体）、恢复、
  Mosh、完整 Agent/IME 与 SSH 矩阵；Mosh 维持既定八场景顺序。首个失败即停止，全部
  场景及清理通过前不声明完整 C3，也不进入 C4。旧候选和所有失败证据保留原身份。

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

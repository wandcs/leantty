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

**当前执行位置：1. 回收/搜索验收探针修复及命名真机诊断已闭合；合并后按 R4 建立新精确候选并执行正式验收。**

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

PR #174 合并后的 `759937c3465692ef4f8539a6535f27041d4d2010` 已按 R4 完成 readiness
8 项、C1 全部 26 项、C2 和正式 QH。指南匹配已确认的 revision 9；六组密钥/Host、
七组通知及普通卸载恢复通过。现有 `id_ed25519` 经产品导出、临时移除和恢复，私钥字节、
公钥指纹、Host 配置一致，临时备份缺席。新 C2 HAP SHA-256 为
`1331c584dbff2169f7cf01d62a6a4b967877e1329eafe032b89b386e4c4478d5`。

Mosh 兼容性通过，运行时回收场景随后因应用布局为空停止；后六个 Mosh 场景和长任务、
Agent/IME、SSH 注册阶段未运行。单次独立检查证明顶层 `help` 会拉起 Downloads 授权
界面，此时全局布局有节点而应用过滤布局为空；前序卸载已重置普通应用状态。该测试探针
引入了与回收目标无关的权限依赖，尚无证据据此认定 Mosh 恢复失败。原失败保留，场景清理
通过，测试应用已恢复可见。详情见
[本轮停止与最小诊断](test-release-efficiency.md#837-r4-通知闭合与回收探针授权干扰2026-09-09)。

恢复及搜索探针已改用 `help mosh`，保留足够滚屏内容和配套搜索断言；产品顶层帮助、
指南及权限策略未改。七项真实脚本命令边界反例修复后通过；同一保留 HAP 的运行时回收、
Pane/Tab 搜索隔离和 renderer 生命周期三项真机诊断及清理单次通过，输入稳定、零模型。
五个既有候选兼容门均拒绝这组工具差异，旧正式报告也不支持跨 harness resume，因此选
R4，不扩张白名单。详情见
[探针修复与续跑决策](test-release-efficiency.md#838-回收和搜索探针去除无关权限依赖2026-09-09)。

- [ ] 在合并后的干净 revision 上按 R4 重新建立精确候选，执行 readiness、C1/C2、正式 QH
  和完整 C3 注册矩阵。Mosh 维持既定八场景顺序，首个失败即停止；不复用旧 C3 前缀。
  全部适用场景及清理通过前不声明完整 C3，也不进入 C4。旧候选、失败和独立诊断保留
  各自身份，诊断通过不得回填正式报告。

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

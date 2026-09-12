# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO；1.5.1 已通过 AppGallery 审核并上架，进入 1.6.0 开发
>
> 更新日期：2026-09-12
>
> 当前 milestone：[`1.6 — Mosh 弱网连接`](roadmap.md)
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 测试权威：[`quality-strategy.md`](quality-strategy.md)

本文件只保留尚未完成、已经授权或满足前置门后继续执行的工作。以下编号就是执行顺序；
前一阶段的停止条件未通过时，不进入后一阶段。完成事实进入相应规范、设计文档、
`CHANGELOG.md` 和 Git 历史，不在这里长期保留已完成 checkbox。

**当前执行位置：1. 维护者已确认：有证据的第三方责任外限制不阻断其他验收。Pi/tmux 裸 OSC 777 分类适配正在隔离分支验证；原包与旧失败报告不改写。完成定向反例后冻结工具，按 R2 刷新准入和 QH，再继续完整 Agent/SSH 后缀；Qwen、C3/C4 仍未闭合。**

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

## 1. 合盖后 Mosh 错误结束诊断与正式验收

PR #176 已合并。新来源 `adf652929917d2b5e6389b2a3a14f51321e37b95` 完成 readiness 八项、
C1 全部 27 项、C2 和正式 QH；候选指南匹配已确认的 revision 9。C2 HAP SHA-256：
`2c11445667fcb0542881666fbc24f5e51aa02fe4d5e6f33a6b95797de5072679`。

2026-09-09 至 10 日的正式入口约 63.6 分钟后按首个失败停止：16 个注册阶段通过，
Mosh 前五场景及清理通过，第六项真实合盖恢复失败。两个 WiFi 场景及后续长任务、
Agent、SSH 矩阵未运行，没有模型调用；完整 C3、C4 和发布仍未通过。

默认 ECDSA 的正式验证已闭合：原 `id_ed25519` 经产品导出、验证备份、临时移除和恢复，
私钥摘要、公钥指纹、Host 配置一致；敏感备份清除，Downloads 恢复未授权状态。
七项后台通知及异常恢复卸载阶段通过，不因本次合盖失败重开这些产品诊断。

合盖后应用 PID 与启动时间未变，恢复输入前远端 shell 和 mosh-server 存活；输入却进入
本地 IDLE，未发送 Enter。收尾截图显示 `The Mosh connection failed`。现有日志未保留
对应错误类别或完整结束时序，不能据此断言是接口 send error、进程回收或错误 Pane。
失败场景清理通过，原候选、冻结源码和失败报告不变。详细证据与边界见
[本轮停止记录](test-release-efficiency.md#842-r4-正式验收推进至合盖恢复失败2026-09-10)；
此前密钥修复与授权诊断保留在该文档 §8.39–8.41。

上游 `ae86bfea2da48ddfe36e7c29882e72be144f3327` 的源码/API 核对、七项定向检查
和 ARM64 包已就绪。2026-09-10 晚维护者配合的一次真实合盖通过工作区恢复分支：
旧进程收到 onDestroy，开盖后 PID/启动时间改变，工作区警告、本地命令、旧远端内容
隔离及清理通过；**原 Mosh Session 没有存活**。本轮此前一次启动空布局失败已单独保留，
没有改代码或重复合盖。结果与限制见 [证据记录](design/mosh-permission-denied-20260910.md)。

同一 Session 的 PermissionDenied 恢复仍没有本次真机证据；库侧自动化回归不能写成
真机 PTY 恢复。本次不追逐另一种合盖结果，具体进程销毁原因也保持未知。

正式库 v0.1.1 已发布并接入，Git tag 加精确版本固定到
`dfc188975ed0a8bd734bbf14bd6cfdeb3838e629`，没有本地路径或移动分支依赖。
发布附件哈希、许可证、11 项定向软件检查和新 ARM64 签名包通过。
随后修复了生命周期观察器默认调用跳过日志读取的问题，空快照不再生成无错误证据。
29 项观察器/真实调用分支反例、7 项 policy/tooling 和 4 项 arkts 检查通过；同一保留
0.1.1 HAP 的 UDP 暂停、实际 WLAN 开关、服务端消失三组真机回归和独立审计通过，
日志状态与同一 PTY 新命令、原页面恢复和清理一致。旧报告和失败结论保持原身份，
详情见 [修复与复跑记录](design/mosh-permission-denied-20260910.md#相同-011-hap-的三组定向真机复跑)。

发布来源 `ac01156` 的精确候选已建立，正式矩阵完成 17 阶段（含 Mosh 八场景），在
长任务通知前置条件及清理缺口停止。原始失败不改写。通知工具修复已完成 shell-only
和 Agent 前置两组零模型真机验证，均恢复原通知关闭状态、单 Pane 与临时资源。
依据、限制和证据见 [通知验收修复记录](design/notification-fixture-permission-20260911.md)。

图标工具 sharp 告警已按根工作区的工具准入规则交独立维护：唯一消费者读取仓库固定 SVG，
正式入口不执行生成器或安装 `tools/` 根依赖，不阻塞原候选。本修复不升级或关闭告警。

2026-09-11 晚 R3 已通过 Mosh 八项和 shell/tmux/Codex 长任务通知；Agent 在首次信任
输入的 owner 检查停止，清理另缺少关闭 Tab 确认分支，SSH 矩阵未运行。原正式失败保留。
失败元数据与自有 Tab 收尾已修复；原 HAP 的信任前主动停止、正常 SSH 前置两条零模型
真机路径及清理通过；该轮未复现原输入异常。随后 PR #179 新 R3 捕获了失败当时的比较：
原生 Web 的 window/accessibility ID 相同，仅祖先路径索引变化，确认当前检查拒绝的条件。
实现、研究和证据见 [Agent 诊断记录](design/agent-tui-compatibility.md#2026-09-11-ssh-信任输入与失败收尾诊断)。

2026-09-12 的共享判定修复改用操作内唯一 window/accessibility ID，保留错误 owner、
重复/缺失身份拒绝与单次输入。16 项 native Web 用例、policy/tooling 七项检查、原 HAP
零模型 SSH prerequisite 和 Pane ownership 诊断均通过；临时资源、原 Tab 与通知设置收尾
通过，旧报告不变。未做自然输入采样、模型工作负载或完整矩阵，详见
[修复与定向验证](design/agent-tui-compatibility.md#修复与定向验证)。

- [ ] 完成剩余 R2：冻结已验证的第三方限制分类，更新资源/平台/身份准入，再运行新 QH → 完整 Agent → SSH 正式矩阵。Pi/tmux 只记录已证实的 `upstream-not-forwarded`，不算通知通过；未知原因、产品错误与清理门禁保持。详见 [分类实现](design/agent-exit-boundary-20260912.md#evidence-bound-classification-implementation)。
  PR #181 的 R3 已完成新 QH、Mosh 八项、长任务通知及其清理，随后在 OpenCode 退出后的
  SSH 关闭观察停止。保留原 `ac01156` / `0db0f090…95e71` 候选和旧失败报告；完整 C3
  尚未通过。此次修复只影响 Agent 工具，不重做共享输入、不改产品或 HAP。
  四个 Agent 的 direct/tmux 共八项零模型退出诊断及独立清理审计通过，详见
  [退出边界修复与证据](design/agent-exit-boundary-20260912.md)。
  正式入口已新增受限的 `-AgentContinuationPath`：新报告固定旧报告、独立恢复和实时
  准入审计的哈希；复用项保留原路径及结果身份，始终重新做 QH，不改写旧失败。
  当前完成软件反例与准入审计后，从干净提交运行新 QH、完整 Agent 和 SSH；正式结果
  尚未通过。实现与证据见上述修复文档的“Agent-local formal continuation”。
  不因脚本限制自动重复无关锁屏、合盖或 Wi-Fi；若证据条件不满足，按实际影响重新定范围。
  零模型启动/退出诊断不替代正式通知、输入和重连工作负载；模型只用固定正式预算。
  WSL 生命周期仍由维护者管理；全 C3 与清理通过前不进入 C4。

  PR #183 的正式续跑曾在新 QH 通过后、SSH 信任 `yes` 输入前停止，且未启动模型。
  原报告与通过项保持不变。Agent 调用只传节点、未传布局，落入虚拟 hierarchy 比较；
  本次只补齐调用方的操作内节点/布局对，保留 shared native Web owner 规则。
  当时的 68 项软件反例和 policy/tooling 七项通过；一次零模型 SSH 前置与独立清理审计通过，
  用时 125 秒，三条本地命令和一条远端命令均单次输入、单次 Enter、零不匹配。
  PR #184 随后的正式续跑在最后 Qwen tmux 通知失败处停止，SSH 未开始。新增外层观察器
  区分提前、隐藏区间不明、隐藏后信号及未确认发布；缺证据仍失败，不追加豁免。软件与
  零模型真机观察通过，全部诊断资源清理已独立核对。最终捕获入口隔离到 Agent 专用文件，
  共享 WSL/分析器、Mosh、产品和 HAP 未改；R2 仍拒绝共享或产品变更。详见
  [观察器修复与证据边界](design/agent-exit-boundary-20260912.md#agent-notification-observer)。
  PR #185 的正式 R2 随后在 Pi direct 的通知落入隐藏过渡区间时停止，原报告保留失败。
  新启动门等待真实隐藏检查点后才放行原生工作负载；软件与 direct/tmux 零模型真机验证、
  独立清理审计通过，原 HAP、共享 fixture、通知判据不变。先冻结修复并重新核对全部
  尝试的资源、平台和旧证据哈希；满足 R2 后运行新 QH、完整 Agent 和 SSH。
  详见 [启动门及验证边界](design/agent-exit-boundary-20260912.md#hidden-window-startup-gate)。

- [ ] C3 完成后进入 C4 前，补齐同版本 AppGallery 文案的审查与归档入口；当前冻结来源
  只有 `docs/release/1.5.1-appgallery.md`，不能作为 1.6.0 文案。明确材料与候选身份关系
  及复验范围，不修改冻结 checkout 或绕过正式脚本的来源检查。

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

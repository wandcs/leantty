# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO；1.5.1 已通过 AppGallery 审核并上架，进入 1.6.0 开发
>
> 更新日期：2026-09-01
>
> 当前 milestone：[`1.6 — Mosh 弱网连接`](roadmap.md)
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 测试权威：[`quality-strategy.md`](quality-strategy.md)

本文件只保留尚未完成、已经授权或满足前置门后继续执行的工作。以下编号就是执行顺序；
前一阶段的停止条件未通过时，不进入后一阶段。完成事实进入相应规范、设计文档、
`CHANGELOG.md` 和 Git 历史，不在这里长期保留已完成 checkbox。

## 当前发布基线

`v1.3.0`、`v1.4.0`、`v1.5.0` 和 `v1.5.1` 已由不可变 GitHub Release 冻结，并由维护者确认
匹配的 production APP 已通过 AppGallery 审核并正式上架。维护者于 2026-08-29 确认
`v1.5.1` 的商店状态；其
[GitHub Release](https://github.com/wandcs/leantty/releases/tag/v1.5.1)、tag、release commit、
manifest、附件和哈希保持不变。

## 执行规则

1. Mosh 最小纵向切片、认证关闭、reachability warning、固定 UDP 端点和受控 server path 已在
   同一物理 PC 闭合；
   当前按下列顺序扩展 option 与可靠性，不能用编译、安装或一次手工连接替代真实终端和清理证据。
2. 任一新增 option 未通过自身门禁时不进入下一项，不用新增通用 Transport、捆绑 server 或
   产品侧协议 workaround 维持版本。
3. 每个实现切片只运行受影响的软件门和最小真机主路径；完整软件、签名和物理矩阵只在正式候选执行。
4. 核心正确性、安全、泄密、状态串扰、崩溃或不可恢复问题随时抢占当前顺序；工具波动和性能噪声
   单独记录，不能冒充产品缺陷或产品收益。

## 1. 补齐 1.6.0 产品范围与可靠性

- [x] 在 HAD-W32 上覆盖 Unicode/宽字符、resize、持续输入、受控大输出、scrollback 边界、
  alternate screen、Shell、tmux、vim 和 less。Mosh 同步终端状态，不保证 SSH 式字节流历史；
  应用级临时屏幕不再由 LeanTTY 推断，统一包含在整段 Mosh Session 页面内。
- [x] 用零模型请求启动真实 Codex TUI，覆盖 raw mode、物理输入、resize、退出和 content-free
  清理；复用现有 Agent capture，没有新增假 TUI、模型请求或第二套隐私协议。
- [ ] 在同一物理 PC 上完成正常网络、合盖、锁屏、Wi-Fi 暂断、网络切换、UDP 阻断和恢复矩阵，
  对比 SSH 的恢复时间、会话保留和用户操作，并审计 hilog、Preferences、终端与崩溃信息无 secret。
  - [x] 当前 test HAP 已通过正常网络基线和精确端口双向 UDP 阻断/恢复；Mosh 在
    `Interrupted(NoRecentContact)` 期间保留 Session 与远端 PTY，恢复后继续执行命令。
  - [x] 受控系统挂起/唤醒已在 Mosh 和 SSH ProxyJump 上通过；两者均保留 App 进程、远端
    会话和恢复后输入，因此短暂系统挂起本身不构成 Mosh 相对 SSH 的优势证据。
  - [x] 独立 `Win+L` 锁屏/解锁保留同一 App 进程、Mosh Session、stock server 与远端 PTY，
    恢复命令和认证关闭通过，Preferences、secret、fixture、设备状态和临时目录清理通过。
  - [ ] 物理合盖当前阻塞后续网络场景：同一 test HAP 已重复观察到 HarmonyOS 在解锁前替换
    LeanTTY 进程，Mosh Session 与远端 PTY 因本地进程死亡而结束。受控 server 超时已按操作员
    预算延长后仍复现，排除 30 秒 fixture 超时。下一步必须先决定是否只在活动远端 Session 期间
    申请带用户可见通知和商店声明的 `KEEP_BACKGROUND_RUNNING` 长时任务；未确认前不引入常驻后台。
  - [ ] 物理合盖决策闭合后，再按 Wi-Fi 暂断、网络切换顺序执行，分别记录 Mosh 与 SSH 的
    恢复时间、会话状态和必要用户操作。
  - [ ] 汇总全部场景后审计 hilog、Preferences、终端、fixture、临时目录和崩溃信息；任何
    secret、状态污染或清理不确定均使本项保持未完成。

## 2. 在正式候选前收敛发布环境

以下工作来自 1.5.1 正式发布证据。它只减少无效重跑、人工拼接和日志噪声，不减少正式模型
请求、软件门、真机矩阵、独立 production/review 身份、签名或发布审计。

- [ ] 将完整 Agent 结果的构造、原子写盘和回读加入零模型 readiness；用接近正式矩阵深度与
  尺寸的合成结果覆盖最终序列化路径。模型调用前先证明结果可落盘，正式用量仍固定为 4 个
  工具 × direct/tmux 的 8 次请求、长任务另 1 次、0 自动模型重试。
- [ ] 增加单一薄发布编排入口，只调用现有权威脚本并保存阶段、candidate/harness 身份、耗时、
  重试、模型用量和清理结果。SSH 组失败后输出绑定原证据目录的精确 `-Resume`；最终生成统一
  `release-report.json` 和维护者摘要，不另建第二套发布实现。
- [ ] 为 release-mode review HAP 增加独立正常产品路径 smoke，覆盖启动、键盘分 Pane、关闭
  Pane 和清理。安装前拒绝把 release-mode HAP 用于 acceptance-only marker；production
  APP/HAP 继续禁止进入 HDC 安装路径。
- [ ] 收敛 UiTest 命令缓冲：输入前证明目标焦点和空缓冲，输入后逐字回读，完全一致后只发送
  一次 Enter。保留有限清空重试、首个差异位置和 `flaky-harness` 分类，不用延时或放宽相等条件。
- [ ] 收敛构建与归档噪声：评估 release checkout 显式禁用不可用的 Hvigor daemon，规范化
  license ZIP 历史时间戳，并区分既有与新增 ArkTS 警告；保持 production/review 的 commit、
  tree、版本、ABI 和 native hash 一致性检查。
- [ ] 为离线用户指南提供 loopback 静态服务和 Playwright 浏览器审查入口，覆盖中英文切换、
  目录链接、关键任务和截图；浏览器审查仍是独立编辑门。
- [ ] 用合成故障完成序列化失败、SSH 恢复、HAP 角色误用和汇总报告的红绿测试；再在同一物理
  PC 上运行 review smoke 与最小 UiTest 输入场景。记录重复组时长、计划/实际模型请求和真实
  输入重试；不得并行控制真机、缩减 Agent 覆盖或自动化 AppGallery 登录提交。

## 3. 完成整体性能与稳定性诊断

本阶段在 1.6.0 核心事件链稳定后、正式候选前执行。诊断先于优化；只有核心可靠性缺陷必须
在本版本修复，普通优化仍按收益与复杂度单独决定，不能让无边界调优拖住发布。

- [ ] 盘点并复用已有启动、连续输出、renderer、内存、GPU/hitch、SSH 背压和生命周期证据与
  工具，列出基线、证据时效和测量缺口；只有缺口阻断决定时才加入可删除的最小插桩。
- [ ] 在统一协议下测量冷/温启动到首个可用输入，持续大文本与大 scrollback 的吞吐、完整性和
  交互延迟，WebGL 时延、掉帧、context loss 与 DOM 故障回退，以及单/双 Pane、多 Tab、
  长会话、切换和关闭后的 PSS、renderer/GPU 占用、回收与泄漏迹象。
- [ ] 同时诊断高负载输入输出顺序与背压、前后台/窗口生命周期、ArkWeb 重建、网络恢复、Session
  关闭和跨 Tab/Pane 隔离；把产品缺陷、工具波动、系统行为和设备噪声分开记录。
- [ ] 为每个候选记录证据、用户影响、预期收益、实现/维护复杂度、正确性/安全/兼容风险、验证和
  回退，归入“采用”“放弃”或“待证实”；只把被采用方案拆成最小独立工作重新写入本文。
- [ ] 放弃低于噪声或只改善合成数字的微优化，以及为小收益增加设置、缓存、常驻后台、第二套
  状态、并行初始化/渲染、设备特例、依赖或长期 fork 的方案；不得以丢输出、放宽门禁、隐藏
  初始化、无界缓冲或主动降低默认 renderer 换取指标。
- [ ] 形成按用户价值、可靠性、收益证据、复杂度和长期成本排序的诊断记录。若没有高价值候选，
  以“无需优化”正常闭合本阶段。

## 4. 闭合 1.6.0 文档、验收与正式发布

- [ ] 同步命令 help、错误、设计、架构、安全、质量映射、中英文离线指南、依赖/许可证和
  `CHANGELOG.md`；只描述已经通过对应门禁的 Mosh 能力与限制。
- [ ] 逐切片完成受影响的软件门与命名真机场景；范围冻结后从精确 release commit 构建一次
  production candidate，按发布规范完成完整软件门、生产签名、匹配 review HAP 和适用物理矩阵。
- [ ] 只有 1.6.0 门禁全部通过且交接资产齐备时，才冻结日期、
  创建不可变签名 tag 和非草稿 GitHub Release，并向维护者交付同版本 production APP 与
  AppGallery 材料。商店 `Released` 仍只由维护者确认后记录。

## 5. 1.6.0 之后再决定 Host/Key 列表输出合同

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

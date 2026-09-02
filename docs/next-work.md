# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO；1.5.1 已通过 AppGallery 审核并上架，进入 1.6.0 开发
>
> 更新日期：2026-09-03
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
- [x] 按 [`design/unexpected-process-recovery.md`](design/unexpected-process-recovery.md) 先闭合应用
  异常回收防护与恢复，再继续剩余网络矩阵。实现顺序固定如下，前一项失败时先按方案停止条件
  裁剪，不得用保活 workaround 绕过平台合同：
  - [x] 后台能力门已按停止条件闭合。HAD-W32 在屏幕保持点亮和解锁、SSH 仍连接且 PID 不变时，
    因 Live View 超过 10 分钟未更新传输进度撤销 `dataTransfer` 长时任务。交互式 SSH/Mosh 没有
    可诚实更新的有限传输进度，因此删除权限、后台模式、平台封装和 UI，不发送虚假进度或流量，
    也不再执行通知移除、Mosh、合盖或 AppGallery 后台用途门。
  - [x] 已闭合单一版本化异常退出记录和 clean/unclean generation。HAD-W32 上受控终止后恢复
    了两 Tab、每 Tab 双 Pane、活动位置和非默认 split ratio；所有 Pane 使用新 generation-scoped
    runtime ID，以 `IDLE`、本地 `ltty` 和明确的“远端 Session/终端内容未恢复”提示开始。正常
    关闭重新启动为默认单 Pane且无误报，未来版本记录整条降级；Preferences/hilog 审计未发现
    Host、标题、终端内容、命令、凭据、secret、attention 或 Session state。
  - [x] 窗口几何兜底已按停止条件裁剪。HAD-W32 证明应用在 `loadContent` 前写入自由窗口矩形
    会被内容加载重置；即使使用平台受控 Starting Window，移除启动页时仍回到系统最近一次正常
    保存的矩形。继续在内容加载后修正必然重引入可见跳动，因此删除应用几何记录、策略、启动页
    控制和运行期回写，保留 `setWindowRectAutoSave(true)` 为所有启动的唯一窗口权威。
  - [x] 活动 stock Mosh Session 的受控进程终止已闭合状态机和故障定位。HAD-W32 上 LeanTTY
    PID 被替换时远端 server/PTY 仍存活；新进程只恢复本地工作区和明确提示，旧远端命令不可见，
    本地命令可用，且没有创建或伪恢复 Mosh Session。临时 HDC reverse、fixture 和目录清理通过。
  - [x] 正常关闭、物理合盖、活动与无活动 Session、多 Tab/Pane、非默认 split ratio、未来版本
    损坏记录、页面/Surface 重建和窗口系统权威均已有独立真机证据；相关 Preferences/hilog
    secret 审计通过。系统选择进程替换时只恢复本地结构；只重建 Page 时保留进程级工作区与
    Mosh Session，且重新绑定 Surface 后仍可继续远端输入。
  - [x] 旧通知跨进程隔离已通过：强制停止前发布的 BEL 通知在新 PID 冷启动后仍可被点击，但
    旧 Pane Want 因 source 不再 pending 被拒绝，不改变默认单 Pane 工作区；通知 payload 通用，
    可见生命周期取消通知并完成清理。
  - [x] 普通卸载重装清理门已通过：卸载前存在两 Tab/活动 Tab 双 Pane 的异常记录；不保留
    应用私有数据地卸载并重装同一 HAP 后，以 generation 1、无异常恢复、默认单 Tab/Pane 启动。
    测试未读取、删除或迁移用于长期保留 SSH key/config 的独立 Durable Asset Store。
- [ ] 在同一物理 PC 上完成正常网络、合盖、锁屏、Wi-Fi 暂断、网络切换、UDP 阻断和恢复矩阵，
  对比 SSH 的恢复时间、会话保留和用户操作，并审计 hilog、Preferences、终端与崩溃信息无 secret。
  - [x] 当前 test HAP 已通过正常网络基线和精确端口双向 UDP 阻断/恢复；Mosh 在
    `Interrupted(NoRecentContact)` 期间保留 Session 与远端 PTY，恢复后继续执行命令。
  - [x] 受控系统挂起/唤醒已在 Mosh 和 SSH ProxyJump 上通过；两者均保留 App 进程、远端
    会话和恢复后输入，因此短暂系统挂起本身不构成 Mosh 相对 SSH 的优势证据。
  - [x] 独立 `Win+L` 锁屏/解锁保留同一 App 进程、Mosh Session、stock server 与远端 PTY，
    恢复命令和认证关闭通过，Preferences、secret、fixture、设备状态和临时目录清理通过。
  - [x] 物理合盖已在 HAD-W32 上闭合“进程替换”分支：解锁后 LeanTTY 恢复本地工作区并显示
    明确提示，旧远端输出不可见且没有伪恢复 Mosh Session；stock server 与远端 PTY 在进程替换
    时仍存活，随后由 fixture 清理。测试进程身份改用 PID 加 `/proc` start time，避免 PID 复用
    被误判为同一进程；不再期待长时任务保留进程。
  - [x] 同一物理场景也证明 HarmonyOS 可能保留相同 PID 与 `/proc` start time、但重建
    WindowStage/Page；页面析构曾错误释放 Mosh Session。工作区所有权已提升到进程级，新页面只
    重绑 UI callback。当前 HAP 的再次合盖选择了进程替换分支并通过；为避免反复碰系统分支，新增
    编译期裁剪的确定性页面替换场景，在同一 PID/start time 下证明 Mosh 页面、Session、server、
    PTY、后续远端命令和认证关闭全部保留，且 Preferences、secret、fixture 与临时映射清理通过。
  - [x] 真实 Wi-Fi 暂断已闭合
    [`MCRS-003`](design/mosh-client-rs-integration-issues.md#mcrs-003部分本地-udp-发送错误会终止-session)：
    固定 `mosh-client-rs` 修订 `94f13225aba535c6645a9179e0ce9f00b156629e` 后，HAD-W32 关闭
    `wlan0` 约 9.7 秒时，同一 Session 保持活动并报告 `Interrupted(NoRecentContact)`；恢复 WLAN
    后回到 `Responsive`，在同一远端 PTY（PID 12575）执行新命令，随后认证关闭。没有自动
    close/error；Preferences、secret、fixture、映射、持久网络和 WLAN 恢复清理均通过。证据为
    `build/verification/device-mosh-wifi-pause-recovery-20260903-94f1322/device-mosh.json`。
  - [ ] Wi-Fi 暂断通过后再执行网络切换，并分别记录 Mosh 与 SSH 的恢复时间、会话状态和必要
    用户操作；不能用已有的精确端口丢包结果代替真实接口/路由变化。
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

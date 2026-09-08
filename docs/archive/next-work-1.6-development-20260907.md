# 1.6.0 开发工作历史快照

> 归档：2026-09-07，两处诊断后精简的验证期间。
>
> 本文件保留当时的顺序、停止记录和待办状态，不授权后续执行。当前唯一 TODO 是
> [Next Work](../next-work.md)；本轮最终结果见
> [代码质量诊断](../code-quality-diagnosis-1.6.md#2026-09-07-诊断复核后的最小精简)。

## 归档原文

> 状态：唯一有效的项目 TODO；1.5.1 已通过 AppGallery 审核并上架，进入 1.6.0 开发
>
> 更新日期：2026-09-07
>
> 当前 milestone：[`1.6 — Mosh 弱网连接`](../roadmap.md)
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 测试权威：[`quality-strategy.md`](../quality-strategy.md)

本文件只保留尚未完成、已经授权或满足前置门后继续执行的工作。以下编号就是执行顺序；
前一阶段的停止条件未通过时，不进入后一阶段。完成事实进入相应规范、设计文档、
`CHANGELOG.md` 和 Git 历史，不在这里长期保留已完成 checkbox。

**当前执行位置：诊断后的两处已授权精简；完成后回到文档收口。**
CQ-001 至 CQ-004 的修复及受影响开发验证已闭合。冷/温启动、完整输出、负载输入、实际
WebGL → DOM 回退、Mosh Surface 重建、双 Mosh/SSH 混合隔离和固定 600 秒资源尾段均已
形成证据；本轮取舍见 [`code-quality-diagnosis-1.6.md`](../code-quality-diagnosis-1.6.md) 和
[`performance-diagnosis-1.6.md`](../performance-diagnosis-1.6.md)。没有采用性能微调或大重构，
没有重跑网络矩阵。资源观察不能排除长期泄漏，checkpoint 只有 3 个有效计时样本且没有
完整写入频率，窗口 hitch 为 unavailable；这些限制不包装成通过或优化收益，也不据此
无限追加抽样。测试机已恢复普通开发包，正式候选验收尚未执行。
development GO 依据仍为
[`test-release-efficiency.md`](../test-release-efficiency.md) §8.30。
下方第 1、2 阶段的过程记录不再授权重复排错；历史自然输入归因仍暂缓，正式候选 readiness、
QH、完整 Agent/IME 与八项 Mosh 矩阵仍属第 4 阶段，不因 development GO 获得豁免。

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
   客户端依赖现固定到 `mosh-client` 0.1.0 正式 tag，不再使用开发 revision；旧 revision 的
   真机报告保留原版本身份，不能改写成 0.1.0 的验收证据。
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
- [x] 按 [`design/unexpected-process-recovery.md`](../design/unexpected-process-recovery.md) 先闭合应用
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
- [x] 在同一物理 PC 上完成正常网络、合盖、锁屏、Wi-Fi 暂断、网络切换、UDP 阻断和恢复矩阵，
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
    [`MCRS-003`](../design/mosh-client-rs-integration-issues.md#mcrs-003部分本地-udp-发送错误会终止-session)：
    固定 `mosh-client-rs` 修订 `94f13225aba535c6645a9179e0ce9f00b156629e` 后，HAD-W32 关闭
    `wlan0` 约 9.7 秒时，同一 Session 保持活动并报告 `Interrupted(NoRecentContact)`；恢复 WLAN
    后回到 `Responsive`，在同一远端 PTY（PID 12575）执行新命令，随后认证关闭。没有自动
    close/error；Preferences、secret、fixture、映射、持久网络和 WLAN 恢复清理均通过。证据为
    `build/verification/device-mosh-wifi-pause-recovery-20260903-94f1322/device-mosh.json`。
  - [x] 真实 Wi-Fi 网络切换已在 HAD-W32 上通过。测试机切换到已保存、可访问同一 LAN 的备用
    网络后，源地址和路由均改变；Mosh 从 `Interrupted(NoRecentContact)` 回到 `Responsive`，保留
    同一 Session 与远端 PTY，并在切换开始后约 53.3 秒完成新命令，无需用户操作。作为对照，
    SSH 在约 23.3 秒后退回本地提示符；设备直连 TCP 端口仍可达，用户需重新连接，约 7.0 秒后
    新 SSH Session 可执行命令。候选 HAP SHA-256 为
    `59de09640022fa23e9d4529e7cdfbb715a4f6efc7a6ca18a013079141d978fc8`；Preferences、secret、
    fixture、映射、持久网络、原 Wi-Fi 和临时目录清理均通过。证据为
    `build/verification/device-mosh-network-switch-20260904-final/device-mosh.json`。
  - [x] 已汇总每类场景的最后一份通过证据并审计 hilog、Preferences、终端、fixture、临时目录
    和崩溃信息。七组证据均为 `passed` 且到达 `cleanup-complete`；Preferences 未变、终端未显示
    bootstrap secret、设备状态与 fixture 进程均已清理、临时目录已删除、持久网络未被修改。
    旧四组未使用 HDC reverse，使用 reverse 的后三组均记录映射已删除；20 份保留日志中未发现
    crash/panic/fatal/OOM 模式，全部证据中未发现原始 `MOSH CONNECT` 密钥。聚合记录为
    `build/verification/mosh-matrix-audit-20260904.md`。这些是逐切片 test HAP 证据，不替代正式
    release commit 的 production/review candidate 与完整发布矩阵。

## 2. 在正式候选前收敛发布环境

以下工作来自 1.5.1 正式发布证据。它只减少无效重跑、人工拼接和日志噪声，不减少正式模型
请求、软件门、真机矩阵、独立 production/review 身份、签名或发布审计。

- [x] 完整 Agent 结果已由共享构造器和原子写入后回读校验统一所有；正式真机脚本与零模型
  readiness 使用同一路径。合成结果覆盖 4 个工具 × direct/tmux 的 8 项检查、40 条本地及 40 条
  连接命令观测，当前为 53,314 UTF-8 字节；回读会核对结构、身份、状态、请求数、检查数、
  inventory/privacy 和 cleanup。readiness 不启动 Agent 或模型，正式用量仍为 8 次请求、长任务
  另 1 次、0 自动模型重试。
- [x] 已增加单一薄发布编排入口 `tools/verify-release-pc.ps1`。它按现有正式清单串行调用权威
  脚本，失败即停；显式续跑会核对 candidate、harness、设备、端口和 WSL 身份，只复用已通过
  检查点。报告原子保存阶段、attempt/resume、耗时、计划/可取得的实际模型用量和 cleanup；SSH
  失败会给出绑定原目录的精确 `-Resume`。统一输出为 `release-report.json` 与
  `maintainer-summary.md`，不包含第二套设备驱动。当前报告明确不声称 1.6 完整 C3，因为 Mosh
  verifier 仍只产生 diagnostic evidence。
### 当前停止记录

2026-09-05 的正式候选 commit 为 `e2e3f0f4d6dee15130b0b346097271a766f22abe`，tree 为
`c7fb8bddaad5833913e0b8deae99066eac4f0149`，HAP SHA-256 为
`769bf6348cf46c80e6d3f1c6a75d675e44f8aa15aa7520fa1377b7f4c007fcb6`。完整软件门、签名、安装
和启动通过；证据位于维护者 verification 根目录的
`1.6-formal-20260905/candidate-e2e3f0f-r2`。

同一 candidate/harness 的七组矩阵为 **6/7 通过、整体失败**。compatibility 首次因物理输入
marker 丢失而以 flaky harness 续跑后通过；UDP pause、suspend、lock、lid 和 Wi-Fi pause 通过。
Wi-Fi network switch 已证明 Mosh 恢复同一 Session/PTY 和新命令、SSH 断开后可重连及 Mosh
认证关闭，但关闭后 Search 未证明原页面 marker 恢复。应用日志只证明页面 replace callback 和
ownership release；它不能区分 snapshot 丢失、Surface 显示错误和 Search UI 失败。聚合证据为
`1.6-formal-20260905/mosh-matrix-e2e3f0f/mosh-matrix.json`。失败 attempt 的 Host、known-host、
fixture、HDC reverse 和临时目录已清理；自动恢复测试前 Wi-Fi 失败，事后独立恢复成功，但不改变
formal failure。当前不得续跑矩阵或修改产品，必须按下列顺序重新进入。

- [x] **先完成只读根因包，不运行真机、不改代码。** 从最后 attempt 的三份 Search layout、应用
  日志和 page replace ACK 反向追踪 `TerminalOutputBuffer` base snapshot、Surface page ownership、
  Bridge replace 与 Search query/result。逐边界记录 expected/observed、最后正确、首个错误、唯一
  权威和证据缺口；把结论归为 product、harness、environment 或 unknown。没有首个错误边界时，
  本项不得进入实现。2026-09-05 的只读包确认原 formal failure 只能证明 Search oracle 未闭合，不能
  证明页面未恢复；页面权威链是 xterm snapshot、`TerminalOutputBuffer`、page replace ACK，Search
  只拥有独立的历史污染判断。vendored SerializeAddon 源码同时确认序列化内容不包含 `viewportY`。
- [x] **只为根因建立一个最小可证伪复现。** 页面 snapshot 恢复、Mosh 页面丢弃、Search history
  隔离和网络漫游使用各自直接 oracle，Search 不再代替页面恢复。若现有证据不足，只运行能区分
  当前两个主要假设的单个 diagnostic，不从 compatibility 重跑矩阵。product 根因先建立失败测试；
  harness 根因先建立 oracle 红绿测试；environment 或 unknown 只补证据，不改产品。相邻无输入
  layout 证明 UiTest `accessibilityId` 会重建，而节点语义、焦点、bounds 和 Pane 归属不变；helper
  红绿测试据此只把新鲜唯一焦点与同 bounds/Pane 作为目标合同。异常退出 diagnostic
  `mosh-abnormal-exit-direct-oracle-20260905-r4` 在任何本地恢复输出前直接读取 xterm，首次把错误
  边界缩到 snapshot replay：保存页 `viewport=0`，恢复页 `viewport=10`。后续取证又发现早期
  marker 指纹位于 `mosh` 命令之前，不能代表真正保存的会话基线；验收探针改在生成 snapshot 的
  同一 write callback 取基线，在 page replace ACK 前取恢复结果。
- [x] **用一个相干修复闭合根因。** 修复必须落在已确认的权威所有者，并删除被替代的投影或 guard；
  先通过 L1/L2、deterministic runtime-reclaim 和受影响的单一 L3 场景。第二个不同修复仍失败或
  90 分钟仍无根因时，停止并重写诊断，不启动第三个修复、相邻 PR 或正式候选。相干修复让
  snapshot、`TerminalOutputBuffer`、Bridge 和 xterm page replacement 一起携带保存时 viewport，
  并在解析 snapshot 后、发送 ACK 前调用 xterm `scrollToLine`。最终 ARM64 test HAP SHA-256 为
  `a801e6f64b9b0d1d461c37f3cae1e6868b7fbc1c7e40e9f421503992c47128a3`；聚焦
  `policy,tooling,arkts` 通过。`mosh-abnormal-exit-direct-oracle-20260905-r6` 中保存页和恢复页均为
  `normal,144,36,10,f6c607089a7f3e08`，Mosh 页面 Search 阴性、偏好/secret/cleanup 通过；attempt
  `d257edc2b8c441efb1c756930799036d`。同一 HAP 的
  `mosh-runtime-reclaim-harness-readiness-20260905-r2` 也通过 runtime 回收、workspace 警告、旧远端
  内容缺失、Session 不恢复、本地首命令和 cleanup；attempt
  `a0841b9acd1342789ab3336f83c88710`。
- [x] **进入性能诊断所需的 development harness readiness 已闭合。** 正式候选资格留在第 4 阶段。
  本项历史范围：普通命令要求空缓冲、逐字一致和单次 Enter；
  retry-success 保持 flaky。分别证明页面、Search、Wi-Fi 切换及原网络恢复 oracle，预热并验证干净
  OHPM/npm/WSL/DevEco 输入，消除 Hvigor daemon、license ZIP 时间戳和新增 ArkTS warning 的歧义。
  先用 diagnostic/release-readiness 路径稳定通过；绑定 exact retained candidate 的正式 QH 仍只在
  C2 之后执行，不能用正式矩阵发现这些前置问题。
  2026-09-05 已完成 L1/L2 实现：页面恢复使用 snapshot 同时刻的不可逆可见画面指纹作为基线、
  page replace ACK 前的同格式指纹作为结果，Search 独立读取
  SearchAddon 结果，Wi-Fi 按 SSID/link/address/direct endpoint reachability 状态推进，把经典 route
  table 只作为可用时的辅助证据，并用本地 dirty marker 隔离恢复失败；正式构建增加独立预热、
  后续 offline、Hvigor `--no-daemon`、stdout/stderr
  分流、版本绑定的精确 ArkTS warning baseline 和确定性 license ZIP。聚焦
  `policy,tooling,arkts` 软件门及 ARM64 debug HAP 集成构建通过。
  真机无 Enter 边界诊断证明坐标 `inputText` 6/6 精确，聚焦 `text` 对字面量 `help` 为 0 字符；
  相邻 layout 又证明只有瞬态 `accessibilityId` 变化。修正后的
  `text-input-focus-targeted-contract-20260905-fixed-r1` 完成 6/6 exact 坐标输入、5/6 focus-path
  观察和 6/6 raw-key，0 Enter 且 cleanup 通过。最终 HAP 的异常退出与 runtime-reclaim L3 也均为
  首次输入成功、0 mismatch、单次 Enter。`formal-inputs-harness-readiness-20260905.json` 已证明
  npm/OHPM/Cargo 预热完成且跟踪输入字节不变。
  Wi-Fi readiness 的前置排错记录：r1 暴露路由 helper 误用 PowerShell 自动变量 `$Matches`，红绿测试改为
  `$matchingRoutes`；随后真机证明 `netstat -rn` 可缺少目标的经典路由条目，而端点 telnet 仍成功，
  因此实连不再依赖该条目。r4 在任何网络切换和产品判断前，因系统面板没有提供“已连接 WLAN”
  语义区停止。重构现保留可见系统面板作为唯一切换入口，但先按可观察 open/closed 状态归一化，
  不盲发 Back；当前 SSID 改由只读 `hidumper -s WifiDevice` 获取，不增加 test HAP 权限，也不解析
  本地化连接文案。L1 已覆盖 connected/disconnected、CRLF、重复 SSID fail-closed，以及 panel
  open/closed/unknown、重复 owner 和单次 Back；真机只读 preflight 与 WifiDevice 当前格式通过。
  r5 的 Pane 焦点误报已由红绿测试闭合：公共 helper 保留当前布局树的 Pane 顺序，删除按 xterm
  光标 X 坐标排序；重叠 Web bounds、反序/同序光标、左右焦点和双焦点拒绝均通过。r6
  `mosh-wifi-network-switch-harness-readiness-20260905-r6` 已通过原先的左右焦点门，并取得目标 SSID、
  link/address、端点可达性、真实地址/路由变化和 SSH 重连新命令证据；原网络与全部 cleanup 通过。
  但 Mosh 恢复命令未执行：输入前第一个 Pane focused，坐标 inputText 后第二个 SSH Pane focused，
  该命令出现在第二个 Pane 的可见内容中；受控 Mosh PTY 的输入长度为 0，3 次 mismatch、0 Enter。
  `productVerdict=not-assessed`，不能据此判定 Mosh 漫游失败或完成网络验收。
  独立 checkout 的 `release-readiness-harness-20260905.json` 已通过全部 8 项检查、0 模型调用、无新
  candidate；它使用现有 1.5.1 发布包和同 commit 的 production/review checkout 作为工具环境基线，
  不代表当前 1.6.0 代码或正式候选的发布预检。当前工作树的聚焦 `policy,tooling,web,arkts` 通过，
  证据为 `software-focused-20260905T075340151Z.json`。
  **双 Pane 输入归属已闭合：** 最小复现确认实际产品布局重叠，不是仅 UiTest 坐标投影错误。
  Index 布局/显隐/焦点改读现有可观察 workspace 投影，保持 Web key 和 Session；工具排除隐藏
  warm Tab，并在输入前后和重试前核对同一 Pane，丢失时立即停止。新签名 HAP 为
  `595d5b569e1620b430e5fd748f647c25487b8dd8d8163b83e4d8398e34613ebc`。
  `pane-input-ownership-20260905-r4` 在 39118 ms 内通过关闭左侧、原右侧全宽恢复、再次分屏、
  原生缓冲保留及两侧输入隔离，0 Enter、无切网、cleanup 通过；完整根因见
  `test-release-efficiency.md` §8.10。policy/tooling/web/arkts 及最终工具聚焦检查通过。
  r7 `mosh-wifi-network-switch-harness-readiness-20260905-r7` 已通过网络比较：Mosh 同 Session/PTY
  恢复并执行新命令，SSH 断开后重连新命令通过；14 次本地受控提交及两次 Mosh 受控命令均首次
  精确，0 mismatch，原网络及 cleanup 通过。整轮仍在关闭后的页面指纹比较失败：保存时 144 列，
  新增 SSH Pane 后恢复时 71 列；当前精确 identity 比较缺少同几何前提，不能直接认定产品丢内容。
  **resize 对照和重放修复已完成：** 独立无网络对照确认跨尺寸 identity 无法比较，同时直接在
  新尺寸重放与 xterm 正常 resize 的长行/光标语义不一致。快照现携带保存尺寸，ArkWeb 先按
  原尺寸及 viewport 重放，再调整到当前尺寸；两条恢复入口共用此路径，中间尺寸不上报 Session。
  六组生产函数回归覆盖同尺寸、双向变宽、变宽高、活动长行光标、已完成逻辑行逐字保留、下一次
  写入、Search 隔离及 Surface restore；聚焦 policy/tooling/web/arkts 通过。比较工具拒绝把不同
  几何直接判为内容丢失；Wi-Fi 两协议比较完成后关闭已退出的 SSH Pane，恢复精确比较前提。
  签名 HAP `cc02fee50dc4834d4c6c256464a0f107389d4bb1d2d8477d6e7689b2f8df2509` 的
  `mosh-page-rebuild-snapshot-geometry-20260905-r1` 在 182822 ms 内通过同进程页面重建、同 Session
  新命令、同几何原页精确恢复、Search/偏好/secret/cleanup；9 次受控本地命令均首次精确、0 mismatch。
  本轮没有切网；变宽组合是 L1 证据，真机这轮验证重建/恢复完整链路，不宣称跨宽度关闭 L3 或正式
  验收已完成。详见 `test-release-efficiency.md` §8.11。
  **单次收口复核 r8 已执行并停止：** `mosh-wifi-network-switch-harness-readiness-20260905-r8`
  使用同一 `cc02fee5…f8df2509` HAP，158514 ms，attempt `077d19180de44ee5b21e4711a6f040ac`。
  尚未切网：首次 SSH bootstrap 密码认证应收到 32 字节，服务端实际收到 31 字节并拒绝，应用
  记录 `Mosh error stage=authentication`，工具随后等待 connected 超时。11 次受控本地命令均
  首次精确不代表密码输入精确；`networkSwitchComparison.productVerdict=not-assessed`。
  原网络未切换，所有 fixture/Host/known-host/reverse/临时目录清理通过，0 dirty marker；本轮无
  产品或工具代码改动、无重试。完整边界与证据见 `test-release-efficiency.md` §8.12。
  **下一步先隔离认证输入，暂停 Wi-Fi 综合复跑：** 重新查阅当前 UiTest、ArkWeb/xterm 输入及
  masked textarea 相关上游资料，使用一次性 fixture 做不切网的最小认证输入对照。区分坐标
  `inputText` 本身的不完整交付与 masked 输入清理/Bridge/native 缓冲问题；只记录长度和相等性，
  不输出密码或可还原内容，不用日志行数代替字节证据。先建立可证伪边界再修代码；不删除密码
  遮罩/隐私清理，不增加盲目认证重试，不延长 connected 等待来掩盖已观察到的认证失败。认证
  输入可靠后才允许单次 Wi-Fi 收口复核；不生成新正式候选、不重跑完整矩阵。
  **本轮分层诊断已收口，原问题仍未修复：** `398badc0…6fbea073` 测试 HAP 上，两次公开合成
  向量的普通/密码首组均为 32/32；真实出现 22 个 keyCode 229、0 composition，xterm→Native
  完整，textarea 清空后密码缓冲仍完整。重复启动第二个探针时焦点身份保护拒绝，两次清理通过；
  已停止该循环并把诊断收窄为单组。现有 SSH `password-success` 单项在 66009 ms 内通过并清理，
  但成功报告未保留 Web 计数，不能据此补全逐层定位。详见 `test-release-efficiency.md` §8.13。
  **观测缺口已补齐（§8.14）：** 输入前/后拒绝保留匿名结构，认证成功/失败保留内容无关计数和
  fixture 结果；本地正反例通过，不放宽焦点/提交保护。一次同 HAP 的真实认证在 80540 ms 内
  通过并清理，Web/xterm 为 32、fixture 实际 matched，报告在清理后完整保留。目标拒绝元数据
  只有本地负例证据，未宣称本轮真机覆盖。清理普通命令却出现 30/31，精确校验在 Enter 前
  拦截并重输成功，整体是业务 passed、flaky-harness；原始密码丢字仍未修复。
  **本地时序已定位一个可复现机制（§8.15），真机同因待证：** 实际打包 xterm 6.0.0 的
  229/input 门禁与延迟差分，在完整 DOM 输入下可丢字或重复；公开 31 字符向量可构造成
  30 字符，普通/masked 对照相同。只放宽门禁会引入重复，未采用这种修补。上游 #5887/#6045
  提供相近报告，但本机 UiTest→ArkWeb 的真实事件顺序仍未知，不能宣布原问题已定位或修复。
  **单次事件顺序已采集并停止（§8.16）：** 测试包专用轨迹按 Pane/token 隔离，最多 256 行/
  20 秒，仅数字枚举、相对时间和长度；停用/截断/晚到隔离及转换恢复的本地检查通过。
  `1b3929c6…5b7ea547` HAP 的 `input-order-pc-20260905-r1` 耗时 42577 ms，单次公开向量、
  未提交向量，保留 156 行/10 块完整轨迹，onData 31、Native 31 且逐字一致，清理通过。
  10 次普通键路径不产生 input，21 次 229 路径产生 input；所以 input 计数少于总字符数不能
  直接判定 DOM 丢字。本次均为 keydown 在前，没有观察到 §8.15 的坏时序，原问题仍未修复。
  不追加输入/认证/切网抽样、不修 xterm；重新进入此分支需要真实坏轨迹或新的可核对根因证据，
  并先改写最小诊断计划。Wi-Fi 收口继续暂停。下方 runtime-reclaim 的独立验证不替代输入
  可靠性或 Wi-Fi 验收。
  **输入归因四格对照已完成（§8.19）：** 维护者授权按新增差分回调时序假设重新进入诊断。
  同一 `90778323…c2fbe73` debug HAP 上，UiTest/真实键盘 × 普通 textarea/xterm 四个有效样本
  均为 31/31；两组 xterm 的 Native 缓冲逐字一致。真实键盘也经过 21 次 229 路径，两个样本的
  差分回调均在 input 后执行，没有复现旧丢字或本地模型的坏时序。首版普通框焦点适配缺失和
  维护者确认的准备期按键干扰各保留为无效样本；全部临时 Tab 已清理。停止追加抽样，不修
  xterm、不解除输入/Wi-Fi 停止门。下一次只在有新的真实坏边界证据或明确可区分假设时进入；
  原问题继续记录为自动化输入链路间歇不完整，正常用户影响和故障归属未确认。
  **最新维护者决策（2026-09-05）：暂缓输入归因，继续 Wi-Fi。** 这项明确决策取代上文
  “输入可靠后才允许切网”的执行顺序；输入问题保持未解决，不追加采样、不修改 xterm。
  下一步复用当前 `90778323…c2fbe73` 测试 HAP，仅执行一次 `wifi-network-switch`，验证
  Mosh 同 Session/远端 PTY 新命令、SSH 对照、同几何原页恢复、Search 隔离及原网络清理。
  保留精确输入和焦点保护；本次失败即保存证据并结束场景，不盲目重试认证或重跑完整矩阵。
  此为开发诊断，不创建正式候选，也不把输入问题标为已修复。
  **Wi-Fi 单次收口已通过（§8.20）：** `mosh-wifi-network-switch-deferred-input-20260905-r1`
  使用上述同一 HAP，347788 ms；源地址和路由身份实际变化，Mosh 同 Session/远端 PTY 新命令
  通过，SSH 断开后重连并执行新命令。同几何原页指纹精确恢复，Search/偏好/secret/原网络及
  fixture 清理通过。普通命令与远端基线各有一次输入不匹配，均在 Enter 前拦截；清理首命令
  在输入前失败，既有 app-relaunch 路径完成清理。业务 passed、harness `failed-harness`，
  不宣称无重试或正式验收通过；输入调查继续暂缓，不追加切网。下一项为下方离线指南浏览器
  审查工具，正式候选前的 harness readiness 仍未完成。
  **新增维护者请求：构建输入问题的最小复现。** §8.20 再次记录普通命令和远端基线输入不匹配；
  本次只授权复现/取证，不修生产输入或重跑 Wi-Fi。已知正确边界为工具持有的预期文本，错误
  边界为 Native/受控远端缓冲；中间 DOM→xterm 仍缺真实失败轨迹，不能归因工具或 xterm。
  下一步把“229 差分回调早于 input”的假设缩成一个字符的独立原版 xterm 浏览器页面，去掉
  LeanTTY、Bridge、认证和网络，用正常顺序、无 keydown、提前 keyup 及普通 textarea 作对照。
  只完成一次有界重复性验证；合成顺序必现不等于真机同因，不用它绕过失败轨迹要求。
  **候选机制已缩成单字符浏览器复现（§8.21）：** `input-order-repro.html` 加载未修改的
  xterm 6.0.0；Chrome 十个独立页面均在延迟 input 的 229 顺序下出现 DOM `a`、onData 空串，
  四个对照各 10/10 正常。无虚拟定时器、DOM stub 或私有方法替换，运行器和说明位于
  `tools/web-terminal/`。这是合成浏览器机制证据，不是真机“必现”或原问题根因；没有运行
  真机、认证或切网，也未改生产代码。停止追加样本，后续只据真实失败轨迹判断是否同因；
  当前主线仍为离线指南浏览器审查工具。
  **本轮维护者授权逐层取证：** 一次 `input-attribution -AttributionMode 4`，在临时空闲 Tab
  通过原 UiTest helper 注入公开 30 字符片段的六次拼接（180 字符，一次调用，无 Enter）。
  对齐 DOM key/input、原版差分安排/执行、onData、WebMessagePort 发送、所属 Surface 接收和
  应用缓冲；20 秒/2048 数字行封顶。首个不一致边界决定归属；没有坏轨迹则明确未复现，
  不重复采样、不修产品、不进入网络场景。只改测试转换/观察器，软件门后重建并单次取证。
  **逐层结果与取证缺口（2026-09-06，§8.22）：** `input-chain-20260906/device` 最终应用缓冲
  180/180 精确，没有复现丢字。探针预算估计不足，在第 156 个字符、12.885 秒触及 2048 行
  上限；保留 `failed-harness/incomplete`，不把它写成完整链路通过。前 156 个字符的 DOM
  等值、原版差分、onData、Bridge 发送/所属 Surface 接收均一致；156 个差分都在 input 后，
  未出现单字符最小集的提前空差分。Native 逐步日志只保留末 46 项（查询限定最近 500 行），
  后 24 字符无完整 Web 轨迹，不能归因原故障。临时 Tab、输入和屏幕超时清理通过；未重跑。
  再取证前先按真实事件行数验证向量/容量预算，并把应用端进度改为有界摘要，避免依赖
  hilog 尾部；之后才针对既有失败场景取一次坏轨迹。不据成功前缀改 xterm、输入重试或 Mosh。
  **本轮先检验观察者效应：** 固定三组 `input-attribution` 5/6/7，分别为详细 IDLE 日志开/
  Web 探针关、详细 IDLE 日志关/探针关、详细 IDLE 日志关/探针开；一次同包同向量对照，
  不调注入速度、不改产品。每组只在结束后读取一次应用缓冲摘要，输入期间不轮询日志。
  两个对照分别隔离 IDLE 验收日志和 Web 采样；既有生产日志/ACK、未启用探针的空判断仍在，
  不称零开销。先用实际事件形状验证有界容量，再构建并各执行一次；失败停止，不随机补样。
  **三组已完成（§8.23）：** `input-observer-effect-20260906` 的同一 `1F22410F…995734F`
  HAP，5/6/7 均一次输入 180/180，无向量 Enter、重试或网络变化，清理通过；第 7 组保留
  2365 行/148 块完整轨迹，各层均 180，全部差分在 input 后，无提前空差分。未证实观察者
  隐藏故障，也未排除该可能；3 组单次对照不是发生率或性能测量。日志开关仅覆盖两处
  IDLE 验收日志，生产 `D` 与 ACK 日志、UiTest 节奏、空探针判断和系统负载仍是未隔离因素。
  停止追加孤立样本。后续在原失败场景保留低干扰终态摘要，若自然失败再决定是否需要
  上游复现或更细轨迹；不为采样修改 xterm 语义、不改变输入节奏、不修未证明的产品缺陷。
  **维护者授权真机受控复现（2026-09-06，§8.24）：** 把原单字符最小集的五种顺序搬到
  真机 ArkWeb，xterm 四组使用临时空闲 Pane 的实际终端，普通 textarea 作第五个对照。
  固定十组，保留原处理器/定时器，只用合成 DOM 事件和任务屏障控制顺序；按例记录 DOM 与
  onData，核对所属 Surface 和应用缓冲总量。无向量 UiTest/Enter、网络变化或产品修复。
  自然故障是否同因仍须真实失败轨迹；受控 10/10 不能写成真实键盘或 UiTest 100% 复现。
  **真机受控机制已复现（§8.24）：** 同一 `67ADFD3A…BA955EAA` HAP 的 `device-r2` 在
  43206 ms 内完成；延迟 input 十例均 DOM 有 `a`、onData 空，其余四组各 10/10 正常。
  xterm 四组共 40 字符到达 DOM，onData/所属 Surface/应用缓冲均只有 30；受控丢失发生在
  DOM→xterm 输出，后续链路一致。完整 51 行/4 块，无向量 UiTest 或 Enter，清理通过。
  第一次准备因焦点布局传输失败在 Enter 前停止，未启动实验；清理/通道复查后仅重试一次，
  两份证据均保留。未改生产输入语义或重跑网络；停止追加样本。后续自然失败仍须对齐这条
  事件顺序，才能归因原故障；修复若涉及 xterm 输入/IME 语义，须另行明确取舍与授权。
  **维护者已授权独立修复受控机制（2026-09-06）：** 暂停追查历史偶发输入问题的其他原因。
  当前正确边界为 textarea 文本，错误边界为 xterm.onData；xterm 的输入门控与
  CompositionHelper 延迟差分共同拥有此缺陷。假设：实际 composition 状态门控与已处理
  input 的差分取消可以同时消除漏发和重发。先用固定时序做原版红灯，再评估一份版本、完整
  哈希与唯一命中锁定的构建期补丁；不 fork、不做运行时私有覆盖，不在 Bridge/Mosh 补字。
  验证包含交错/重复字符、composition、删除、控制键、屏幕阅读及输入禁用边界，再执行
  同一真机受控场景和最小输入兼容检查。若需要接管 IME 或堆积时序特例则停止重新评估。
  受控机制修复不等于历史自然故障同因，不重跑 Wi-Fi 或正式矩阵。
  **本轮实现与验证（§8.25）：** 已加入构建期 `xterm-input-order.mjs`，原版/补丁版同一
  32 例浏览器对照为 11 例失败/全部通过；13 项生成代码 owner 测试与双 Terminal 隔离通过，
  已注册到 `web` 组。ARM64 `BC848D0D…CDA1D2E2` HAP 在真机受控场景五组各 10/10 正确，
  DOM→xterm→所属 Surface→命令缓冲均 40；普通/掩码各 32/32、Pane 保留/隔离通过，三项
  清理均通过。没有改 Bridge、Rust 或 Mosh。历史偶发输入故障仍暂缓归因。
  **输入补丁的开发验证已闭合（§8.26）：** 修复 Agent 结果工厂的 `completedAt` 契约，增加
  完整检查点和资源身份。一次 TUI 复核在 SSH 前置连接失败，报告已保留，不能归因 IME。
  按直接 owner 重审后，改用独立本地 Tab 的系统 IME 检查：同一 `BC848D0D…CDA1D2E2` HAP，
  23184 ms 内英文 10/10、拼音提交中文 2/2、composition 后重复 ASCII 累计 6/6，全部逐字
  精确，无 Enter/网络/模型/重试；输入法、临时 Tab 和屏幕覆盖清理通过。policy/tooling 通过，
  没有再改产品或重跑 Wi-Fi。旧失败场景的历史条目未删除；复核前归还屏幕覆盖，r2 后确认
  known_hosts 全文摘要不变、本轮 endpoint/映射/临时目录不存在、专属 Tab 已移除。
  历史自然丢字仍暂缓归因，不以受控补丁通过声称同因；正式远端 TUI 验收仍保留。当前不再
  追加输入样本，回到下方离线指南浏览器审查工具。
- [x] **把不可控合盖分支改成可完成的正式合同。** 已注册 runtime-reclaim 为 formal named
  scenario，共享八项列表将可控恢复放在网络扰动/人工动作前，矩阵拒绝缺失或失败的结构化
  结果。2026-09-05 `runtime-reclaim-formal-contract-20260905-r1` 在 `b432d608…830e5963` 开发
  test HAP 上完成单次 L3，耗时 179153 ms：PID/start time 相同、Tab/Pane 身份保持、首字符
  拦截且本地缓冲为 0、native 取消 1、server/PTY 均消失，恢复警告/help 输出可检索、旧远端
  内容不可检索；Preferences 和清理通过。普通命令 10/10、远端基线 1/1，均无输入重试。
  生产源码仍裁剪触发器及观察器，八类包符号拒绝、转换恢复和反例检查通过；没有改产品
  恢复逻辑。此为开发诊断 `acceptanceEligible=false`，非系统 GC/真实合盖复现，详见
  `test-release-efficiency.md` §8.17。exact retained candidate 正式执行仍属第 4 阶段；真实合盖
  只执行一次并接受已文档化结果，不反复等待系统选择稀有分支。下一项为 review HAP smoke。
- [x] release-mode review HAP 正常产品路径 smoke 已完成开发验证。`verify-review-smoke-pc.ps1`
  在含 mosh-client 0.1.0 的 `8eecd666…f0f506266` 测试签名 HAP 上，25830 ms 内通过启动、
  新建临时 Tab、键盘分/关 Pane 及清理，保留原工作区和 Settings；无命令提交或输入重试。
  首次运行在任何 Tab 操作前因 UiTest 字段假设失败，已保留记录并用实际节点身份/持久化
  工作区修正工具，未改产品。安装入口核验实际签名 Profile、构建模式和验收能力，拒绝
  production APP/HAP 及 release-mode/acceptance 混用。详见 `test-release-efficiency.md` §8.18。
  这不是正式候选验收，也不解除输入/Wi-Fi 分支的停止条件。下一项为离线指南浏览器审查工具。
- [x] 离线指南的 loopback 预览和 Playwright 审查入口已完成。只服务固定 HTML 快照，HTTP
  边界/清理 34 例通过；Chrome 152 中英双语、两种宽度、目录/任务/历史导航 59 项在 5789 ms
  内通过，8 张截图已查看。工具使用标准 reduced-motion 偏好，未改指南；自动结果不代表
  内容审批或 HarmonyOS 验收。两次工具预期/预算失败和修正均保留，详见
  `test-release-efficiency.md` §8.27。下一项先做无设备 SSH 前置门故障注入。
- [x] 用合成故障完成序列化失败、SSH 恢复、HAP 角色误用和汇总报告的红绿测试；再在同一物理
  PC 上运行 review smoke 与最小 UiTest 输入场景。记录重复组时长、计划/实际模型请求和真实
  输入重试；不得并行控制真机、缩减 Agent 覆盖或自动化 AppGallery 登录提交。
  Agent 结果对象/检查点及 SSH 前置门的软件修复已完成：信任确认错误原样传播，缺失日志
  归 unknown，当前连接证据决定是否允许 Ctrl+D/本地清理，首个失败停止后续用例；不再
  强停整个应用来恢复单个测试 Tab。原工具 21 例中 17 例红灯，修复后 21/21，扩展边界
  25/25；保留原失败和资源身份，详见 `test-release-efficiency.md` §8.28。
  2026-09-06 剩余软件缺口已闭合：截断序列化拒绝覆盖旧检查点，未确认 cleanup 不再被
  汇总为通过；27 例中 9 例红灯，修复后扩展 31/31。HAP 角色复用既有反例，仅补 ABI/
  Profile 身份缺口；SSH 窄场景接线扩展到 28/28。两次定向 policy/tooling 门均约 13 秒。
  同一 PC 的零模型 SSH 窄场景 70276 ms 通过：远端命令、正常断开和清理均确认，3 条本地
  命令及 1 条远端命令首次输入精确、无重试；这 3 条普通命令同时完成最小 UiTest 输入检查，
  不另跑输入归因矩阵。独立核对 endpoint、反向映射、fixture 进程/目录均已消失。
  review smoke 26909 ms 通过，保留原工作区/Settings；两项均零模型、非正式验收，使用各自
  已核验的 test-signed HAP，详见 `test-release-efficiency.md` §8.29。状态不明仍失败关闭；
  不以本轮通过反推旧真机缺失轨迹的具体根因，不替代完整 Agent/IME 验收。
development go/no-go 已完成：17 份原始报告、2 个留存诊断 HAP 及相关源码哈希已审计。
允许进入性能诊断，不宣布发布就绪；没有新建 candidate、重建 HAP、操作真机或重跑矩阵。
结论、包身份限制和重新进入故障分支的条件见 `test-release-efficiency.md` §8.30。

## 3. 完成性能、稳定性与代码质量诊断

维护者于 2026-09-07 授权按诊断复核落实两处减法，依次执行：

- [ ] 普通 SSH/Mosh 不再为无消费者的观察解码输出；Keypush 和开发 ping 各自拥有有界
  流式解码生命周期，保留原始字节、分块 marker、关闭及 Session 隔离。
- [ ] Mosh 首次连接成功后停用 100 ms 状态检查；保留首次通知、reachability、取消、
  超时及关闭合同，不改协议时钟。先红绿与聚焦门，再执行命名 Keypush/SSH/Mosh 主路径。
- [ ] 记录实际结果和限制，将已完成过程移入历史记录，Next Work 只留活动顺序；不做
  大拆类、异步 checkpoint、缓存/队列调参或新的全量性能矩阵。

本阶段在 1.6.0 核心事件链稳定后、正式候选前执行。诊断先于优化；只有核心可靠性缺陷必须
在本版本修复，普通优化仍按收益与复杂度单独决定，不能让无边界调优拖住发布。

2026-09-06 维护者确认补齐代码质量、可读性与臃肿程度的独立诊断。先只读审查，再取得
改动前基线，统一排序后才优化；已确认的正确性缺陷优先修复。不边审边大规模重构，也不以
行数或测试通过代替质量判断。

2026-09-07 已按固定预算闭合本阶段，不再保留已完成 checkbox。续轮修复输入工具对同一
原生 Web 内虚拟子树重建的误拒绝，负例继续拒绝跨 Pane/窗口、Web 替换和不唯一目标。
新 native 的 Surface 重建、双 Mosh/SSH 混合隔离、认证关闭及另一个 Session 新命令均通过。
Full/Closed 交错由真实 N-API 软件测试证明；真机验证受影响集成链，不冒称自然触发了队列
饱和。两条 SSH、两个额外本地 Tab 的资源尾段实际 601.7 秒，8 组完整输出零 mismatch，
关闭和工作区/fixture 清理通过。checkpoint 样本为 0、0、3 ms；没有高价值瓶颈的确证，
保留同步耐久性和现有 warm 策略，不因样本不足启动异步化或延长观察。

上述结论是有界开发诊断，不是长期无泄漏、系统 OOM、同系统 1.5.1 性能对比或正式验收。
只有新的反例、可复核成本或受影响源码变化才重新进入对应最小事件链；不重新泛审、按
行数拆类或重跑已完成矩阵。完整稳定性矩阵仍在第 4 阶段。

## 4. 闭合 1.6.0 文档、验收与正式发布

- [ ] 同步命令 help、错误、设计、架构、安全、质量映射、中英文离线指南、依赖/许可证和
  `CHANGELOG.md`；只描述已经通过对应门禁的 Mosh 能力与限制。
  离线指南当前标题/页脚为 1.6.0，但中英文页首仍为 1.5.0；版本标识与 Mosh 内容一起同步，
  再执行双语文字/截图审查及源文件和打包字节一致性检查，不能沿用工具通过作为内容审批。
  同时消歧架构文档“Tab/Pane 状态不持久化”与“只恢复结构”的边界，对齐 SSH projection
  的 lazy 初始化描述，并删除安全文档中已过时的 1.1 未交付措辞。
- [ ] 逐切片完成受影响的软件门与命名真机场景；范围、性能结论和文档冻结后，从精确 release
  commit 完成该身份的离线构建输入和 release-readiness 预检，只构建一轮 production/review
  candidate。历史 1.5.1 环境预检及旧 review HAP smoke 不作当前候选证明。
  C2 后完成正式 QH 与完整 Agent/IME 验收，再按 compatibility、
  runtime-reclaim、UDP pause、suspend、lock、lid、Wi-Fi pause、Wi-Fi network switch 固定顺序执行
  完整矩阵。首个失败立即停止，后续只做 failed-stage 诊断并按 R1–R4 决定复用范围；只有同一
  candidate/harness 的全部场景和 cleanup 通过才能声明完整 C3，然后继续生产签名和交付门。
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

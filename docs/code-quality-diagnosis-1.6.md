# 1.6.0 代码质量诊断

更新：2026-09-07。本文保存诊断证据和取舍，不是第二份 TODO；执行顺序由
[`next-work.md`](next-work.md) 管理，性能测量依据见
[`performance-diagnosis-1.6.md`](performance-diagnosis-1.6.md)。

## 结论

**当前状态：** CQ-001/CQ-002 的软件与命名真机开发验证已经闭合。2026-09-07 的复核新确认
CQ-003：旧性能 ping 观察器会把特定前缀后的输入正文交给公开 HiLog；已用公开 canary 执行
实际 owner 和 Logger 复现。按维护者授权实施正式/开发包分级隔离，实际产物与命名 SSH
主路径已验证。另确认并修复 CQ-004 最后 resume 因有界队列 Full 遗失；真实 N-API 软件
测试及修复后的 Mosh Surface 重建、双 Mosh/SSH 混合隔离、关闭主路径均通过。续轮修复
renderer 回退后的 harness 目标身份误判，实际 DOM 后续新输出和命令通过。固定资源预算
和有限 checkpoint 计时已完成，没有支持调优的新瓶颈证据；第 3 阶段有界开发诊断闭合。
进展及证据限制见文末，旧反例不代表当前源码仍失败；这不替代正式验收或全仓安全审计。
没有证据支持大规模重构。诊断复核后另完成无消费者解码和 Mosh 首次通知空轮询两处
精简，新包的 Keypush/SSH/Mosh 命名验证通过；未量化性能收益。历史风险及取舍列在文末。

以下保留第一轮只读诊断的发现；后续实施状态见文末“修复进展”，不能将旧反例视为当前
代码仍失败，也不能将软件修复视为真机验收完成。

本轮确认两个 LeanTTY 集成层问题：Mosh native 拒绝输入时，上层吞掉失败；同一客户端
重叠断开时，前一个调用者的等待可能永不结束。应先修这两个正确性问题，再推进性能采样。
这不是 `mosh-client-rs` 的缺陷报告，也不能解释此前尚未归因的自然输入丢字。

生产代码和既有验收工具本轮未修改。未发现足以支持大规模拆类、统一 Transport 或删除
现有 xterm 补丁的证据。同步持久化是待测成本，不是已确认的性能瓶颈。

## 范围与证据身份

- 基于工作区 HEAD `e2e3f0f4d6dee15130b0b346097271a766f22abe` 加未提交改动；不能用该
  commit 单独重建本次输入。`inventory.json` 保存当时 84 条 Git 状态及 163 个源码/工具
  文件的 SHA-256 和物理行数，排除生成物和第三方打包资源。
- 对照基线为 `v1.5.1` / `ef3184bf8f3d8e7edcc09c96fedf42d1f0caf209`。
- 本地原始证据均在 `build/verification/code-quality-diagnosis-20260906/`，不进入发布包。
  `inventory.json`、`mosh-boundaries.json`、`startup-transform.json` 分别记录盘点、类级反例
  和启动转换准备检查；相邻脚本保存复现方法。
- 首轮诊断时 `MoshClient.ets` 的 SHA-256 为
  `10ee6979868d11899680d863f9ef821af20ab56c29fefa918678ff0abe1e3fd0`。

这是按事件链展开的第一轮审查，不是全仓逐行审计、完整安全审计或正式发布验收。

| 检查范围 | 阅读重点 | 本轮判断 |
| --- | --- | --- |
| MoshClient、native Mosh 会话 | 输入入队、事件身份、错误、关闭及输出消费 | CQ-001、CQ-002 有可执行反例 |
| SessionViewModel、PaneRuntime、应用关闭 | 客户端实例所有权、调用者等待、清理与晚到事件 | 重叠断开有多个调用入口；实际 UI 交错尚未真机复现 |
| Terminal Surface、OutputBuffer、Bridge | 临时页面、快照、重放、ACK 与 generation | 状态有不同生命周期，不能按变量相似就合并；负载成本待测 |
| ApplicationWorkspace、异常恢复存储 | 活状态与 UI 投影、检查点持久化 | 未证实双重 owner；同步写盘列为性能候选 |
| Mosh、启动及输入验收工具 | 场景入口、转换/还原、诊断模式、判定边界 | 启动转换可复用；工具可读性有热点，未确认新的判定错误 |
| xterm 输入补丁与测试入口 | 版本/哈希限制、行为解释、移除条件 | 保留受控补丁；缺少直接覆盖本轮两个类级反例的常规回归 |

## CQ-001：Mosh 输入入队失败只记日志（P1，采用修复）

**期望：** 输入未被接受时，调用者必须知道失败，不能把已拒绝输入视为正常发送。是否保留
未接受数据、如何提示及何时结束会话须沿已有可靠性合同决定，不能靠盲目重发掩盖拒绝。

**边界：** `SessionViewModel.ets:1332` 的连接态输入经 Mosh escape 解析后调用
[`MoshClient.write`](../entry/src/main/ets/model/mosh/MoshClient.ets)。native
[`mosh_write`](../leantty_ssh/src/lib.rs)（4253 行）向容量为 **64 条消息**的有界队列
`try_send`；Full/Closed 会返回 N-API 错误。这里是最后一个正确边界。`MoshClient.ets:285`
捕获异常后只写 warning，既不返回结果，也不发应用事件；这是第一个错误边界。输入接纳
由 native 队列负责，失败传播由 LeanTTY 的 MoshClient/SessionViewModel 负责。

**最小验证：** 执行当前实际 MoshClient 类，替换 native 写入为同步拒绝。结果为 native
调用 1 次、日志 1 条、应用事件 0、调用者异常 0、客户端仍显示 connected。成功写入和
单次关闭对照正常。反例证明拒绝后的失败被吞掉，不证明真机已经发生队列饱和。

**影响与取舍：** 背压或关闭竞态下可能静默丢掉未入队输入，优先级高于吞吐优化。采用
局部修复，成本集中在接纳/失败合同及调用方；不新建通用输入框架、不无界缓存，也不只
增大队列。回退不得重新隐藏失败。下一次最小诊断需区分 Full 和 Closed，并核对入队后
错误的现有路径，避免把“未接受”和“已接受但后来失败”混为一谈。

**验证边界：** 增加真实 Rust 有界队列 Full/Closed 和实际 ArkTS 类的失败传播回归，覆盖
成功路径、同 Pane 状态和另一 Session 隔离；修复后按受影响输入链做最小真机验证。
不得用此反例倒推历史 UiTest/真实键盘丢字同因，不记录输入正文或密钥。

## CQ-002：重叠断开覆盖前一个完成回调（P2，采用修复）

**期望：** 同一 Session 已在关闭时再次调用 disconnect，所有等待者最终都能结束，不能
因为第二个调用覆盖第一个等待者；正常关闭仍须处理已接收输出。

**边界：** `MoshClient.ets:312` 每次调用创建 Promise 并覆盖单一
`disconnectCompletion`；`clearSession`（555 行）只完成最后保存的回调。第一次登记是
最后正确边界，第二次覆盖是第一个错误边界，owner 是 MoshClient 的每 Session 关闭状态。
`SessionViewModel.disconnect`、Pane 销毁和应用关闭均有等待入口；实际 UI 时序尚未复现。

**最小验证：** 在同一活动 Session 上连续启动两次断开，再发合法关闭事件。两次 native
请求都被接受时，第二个 Promise 结束，第一个仍未结束；第二次 native 请求抛错时也会
遗失第一个等待者。单次关闭及两个独立客户端各自关闭的对照均正常。

**影响与取舍：** 并发清理可能悬挂，妨碍 Pane/窗口清理完成。采用每 Session 幂等关闭、
共享完成状态或等价的完整等待者管理；优先最小实现，不新增全局生命周期 Manager。
修复不能以提前宣布关闭、固定 sleep 或把正常关闭改为硬取消来换取 Promise 完成。

**验证边界：** 常规回归覆盖上述两种重叠、单次关闭、两个客户端隔离以及关闭事件/异常
到达顺序，并保留输出排空、晚到事件隔离和库的 4 秒优雅关闭上限。随后做受影响的真机
关闭/页面恢复检查；不要为复现竞态反复合盖。回退不能恢复覆盖等待者的行为。

## 待测成本和可读性取舍

1. **检查点同步落盘：待证实。** `UnexpectedExitRecoveryStore.ets:100` 的 `writeCurrent`
   使用 `putSync` / `flushSync`；`Index.ets:1173` 的 workspace checkpoint 被焦点及布局
   变化调用。先测焦点/布局切换及落盘成本，不把它写成逐字符写盘或已确认卡顿。异步化、
   合并写入可能改变异常回收的数据持久性，不能在测量前作为“免费优化”。
2. **长文件：维护热点，不是缺陷分数。** native `lib.rs` 5531 行、Mosh 验收工具 4642 行、
   SessionViewModel 3006 行、source 转换工具 2312 行值得定向检查，但含测试和不同业务
   入口。后续只有明确的责任混杂或重复规则导致维护风险时，才随局部修复抽取责任；不以
   行数目标安排一次大拆分，也不把既有无关的大型传输验收工具纳入此次改造。
3. **输入诊断模式：保留，暂不整理。** `diagnose-text-input-pc.ps1` 的模式在多处分流，
   未来修改时应核对映射一致性；本轮没有错误分类反例。保留受控回归及暂停归因所需证据，
   不因探针多就直接删除，也不为可读性新建一套场景框架。
4. **必要的不同状态：不合并。** SSH 字节流与 Mosh 当前画面状态、临时页面请求与原页面
   已保存状态各有不同合同。现有客户端实例身份、generation、快照提交边界不是同一类
   冗余；全局工作区活对象与 ArkUI 投影也不能仅凭名称判为双重真相。
5. **受控 xterm 补丁：不移除。** `xterm-input-order.mjs` 保留版本/哈希和唯一匹配限制、
   行为说明及上游版本通过同一 corpus 后移除的条件。现在没有证据支持换成运行时私有
   API 覆盖、长期 fork 或撤掉已验证边界。

## 已执行验证及限制

- 类级诊断用本机 Node 24.18.0、DevEco 自带 TypeScript 4.9.5，将当前 ArkTS 类转译后
  执行；实际控制事件策略也执行，只替换 native、日志和未使用的类型依赖。共 5 个用例：
  **2 个正常对照、3 个故障反例**。报告结果为 `defects-reproduced`，不是产品通过。
- 在当前 6 个启动相关源文件的副本上调用既有冷/温启动转换；正常返回、action 抛错各
  一例，共 **4/4 通过**，副本恢复、原文件不变。只证明转换/还原准备条件，不证明编译、
  HAP、真实 T5 终点或启动性能。无需为开始测量先修改该工具。
- 无设备操作、网络扰动、模型请求或构建；这些证据均 `acceptanceEligible=false`。
  类级替身不证明真实 N-API 饱和概率、ArkTS 完整编译或 HarmonyOS 调度行为。
- 收尾哈希核对：盘点的 163 个源码/工具文件全部未变。文档的 20 个本地链接目标存在；
  `test-regression.ps1 -Group policy` 与 `git diff --check` 通过，软件证据见同目录的
  `software-policy.json`。这是文档 L0 检查，不是本轮发现已修复的证明。
- 未完成当前包的性能分布、PSS、长期负载/回收测量；未审计全仓安全、全部异常分支或
  第三方实现。未发现问题的已读路径不能写成已通过完整稳定性验收。

## 外部依据

2026-09-06 针对本轮边界验证查阅以下一手资料：

- [Tokio 1.53.1 Sender::try_send](https://docs.rs/tokio/1.53.1/tokio/sync/mpsc/struct.Sender.html#method.try_send)：
  对应当前 Cargo.lock 的 Tokio 版本；Full/Closed 返回未发送值，支持区分输入未接纳与
  之后传输失败。没有从该 API 文档推断真机发生频率。
- [TypeScript Compiler API](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API)：
  `transpileModule` 支持单文件转译；本轮使用已安装的 4.9.5，而非更新依赖。转译不能替代
  ArkTS 项目类型检查或平台测试。

本轮未改验收工具的交互、判定或注入规则。未来如需改这些规则，仍须针对具体问题执行
质量策略的外部研究门，不能沿用本次两条资料充当平台依据。

## 修复进展（2026-09-06）

维护者已授权实施。CQ-001 的安全失败需要等待正常关闭，所以先将 CQ-002 的共享关闭结果
作为局部前置，再接入输入拒绝处理；没有重新调查历史自然输入丢字。

采用的合同是：未被 native 接纳即停止后续输入和当前 parser 帧，不重发；继续消费已收
输出，关闭后在恢复的本地页面报告输入失败并建议检查远端状态后重连。已接纳后失败仍由
原 native 错误路径处理，临时 reachability 中断仍保留 Session。新增生产状态仅是每客户端
共享关闭 Promise 和待报告输入错误；没有改变 native 队列容量、库、Bridge 或 xterm。

`tools/test-mosh-client.cjs` 执行当前实际 ArkTS 类及调用方方法，使用 DevEco 的 TypeScript
4.9.5 和 Node 18.20.1，替换 native/日志及未触及的平台服务。前 8 例修复前只有 2 例通过，
6 例失败；修复后 8/8，通过补充中断与错误文案检查后为 10/10。这里只模拟边界，不模拟
业务实现；页面完成回调的单测替身不能证明真实 xterm 恢复。

真实 Rust 队列测试调用 `mosh_write`：64 条消息保持顺序，Full 拒绝值未发送，Closed 拒绝
不影响另一 Session，错误不含输入正文。native 生产实现无需修改，Rust 改动只有两项测试
及其独立资源 fixture。

软件证据目录：`build/verification/mosh-input-close-fix-20260906/`。
`software-focused.json` 保留首次因新测试格式失败而停止的记录；修正格式后
`software-green.json` 的 `policy,arkts,rust-native` 全通过，ArkTS 202/202、native 52/52，
包含格式、clippy 和生产 native 测试依赖隔离。补充的两项 host 用例另由同一命令直接通过。
Rust 定向检查首次工作目录误指仓库根，改为 `leantty_ssh` 后两例通过；未为命令错误修改产品。

本任务开始时重新查阅 TypeScript 官方 Compiler API，并核对本机工具版本和真实队列行为。
本次 Tokio 固定版本页与 OpenHarmony Hypium 的远程页面未成功读取，未将其视为新平台依据；
沿用的 Tokio 文档语义另经锁定依赖的真实队列测试验证。不修改物理注入/等待/判定规则，
也未据此声称平台原生 mocking 或物理饱和已获保证。

`software-final.json` 的 `policy,arkts` 再次通过，包含全部 10 个 host 用例与 ArkTS 202/202。
ARM64 native 构建和 test-signed HAP 安装/启动通过；该 HAP 的 SHA-256 为
`3d26fdd6b8922ee557f4f18c97b8fe3f1ff14da748fcec909c29b1051304fc4b`。

首个真机 `pane-close` 场景持续 182 秒后停在工具前置条件，报告为 failed/harness，而非
产品通过。已观察到关闭旧 Pane、旧输出不进入存活 Pane、新 Session 执行精确命令和最终
Ctrl-^ 关闭/server 退出；清理全部通过。失败后不重跑、不改产品或放宽比较。

最小诊断：工具在首个 Session 捕获 71×36 的原页面快照，关闭该 Pane 后另一个 Session
恢复 144×36 页面，却仍用首个 Session 的全局基线比较。最后正确边界是第二个 Session
完成关闭；第一个错误边界是验收工具把不同 Session 的基线交给同尺寸比较函数。页面
owner 是各 Session 的 Surface，比较基线应由该次测试连接拥有，而非场景全局复用。
证据在 `pane-close/device-mosh.json`，原始失败及清理结果保留。

随后复用现有 `fixed-endpoint` 单 Session 场景作同尺寸对照，150 秒完成并通过：原页面与
恢复页面均为 144×36、viewport 10，内容指纹相同；Mosh 页面丢弃、本地提示符、精确远端
命令、认证关闭、固定端点、设置不变及 secret 检查通过。9 个本地命令和 1 个远端命令均
单次输入，无不匹配；临时配置、进程、目录和反向映射的清理全部通过。证据为
`same-geometry-close/device-mosh.json`，使用同一 HAP；没有修改工具或重跑 pane-close。

该对照支持将上一场比较失败归于工具基线复用，但不把原 failed/harness 改成 passed。
普通输入、关闭和同尺寸恢复已有真机证据；输入拒绝的确定性物理触发仍无现成场景，作为
独立缺口保留。发布 L4、Wi-Fi/合盖矩阵、性能采样和模型请求均未执行。

收尾源码哈希与第一轮盘点对照：163 个原有源码/工具中，本轮仅修改 MoshClient、
SessionViewModel、native 测试及回归注册四个文件；另新增 host 测试文件。原有无关工作区
改动保留，无提交、推送或依赖更新。未完成项继续只由 Next Work 管理。

## pane-close 基线归属修复（2026-09-06）

本轮只修验收工具。假设是关闭旧 Pane 后，工具没有为存活 Pane 的新连接更新比较基线；
同尺寸对照和实际重连分支的最小反例共同支持该判断。不同 Session 即使尺寸相同，也不能
互用页面快照；不能通过放宽比较或改变产品尺寸来消除误报。

针对本任务重新查阅的资料：

- [xterm Terminal.write API](https://xtermjs.org/docs/api/terminal/classes/terminal/#write)
  与 [parser 执行时序](https://xtermjs.org/docs/guides/hooks/)：写入异步解析，buffer 读取应等
  write callback；解析完成不等于屏幕已绘制。当前固定 xterm 6.0.0，继续使用现有保存快照
  与恢复完成回调的 cell 指纹，不改为等待页面加载或截屏。
- [OpenHarmony Web 生命周期](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/web/web-event-sequence.md)：
  Web 销毁会解除 controller 绑定并销毁 JS 环境，onPageEnd 也不保证下一帧反映 DOM 状态。
  这是上游生命周期依据，不是本机特定版本的行为保证；Pane/Session 的归属仍由本项目定义。
  本轮 Huawei 当前及 V5 对应文档页均抓取失败，未视为已读依据。
- [Playwright visual comparisons](https://playwright.dev/docs/test-snapshots)：基线和结果需要
  可比较的环境，快照按测试身份区分。采用的是这一方法原则，不新增 Playwright 依赖，
  也不把其像素容差用于终端内容比较。

检索 Huawei 开发者域的 Mosh/快照与 Web 生命周期资料，没有找到本项目“跨 Session
复用基线”的直接案例；这不证明平台没有相关问题。本次归因来自本地事件链与反例。

`Get-MoshSessionPageBaseline` 统一读取该次连接保存的原页面和当前 Mosh 页面，并保持
原有页面代际检查。首个连接及 pane-close 存活 Pane 的新连接各自调用；先读快照，再调用
会清日志的当前页指纹工具。第二次使用独立文件名前缀，第一连接的指纹文件仍保留。
最终 JSON 的 original/mosh/restored 三者都属于最终关闭的连接；严格尺寸与内容比较未改。

`test-device-regression.ps1` 直接执行工具的存活 Pane 重连分支，仅替换设备及 fixture 边界。
修复前在“仍持有已关闭 Pane 的基线”断言失败；修复后覆盖 71→144 列、同尺寸不同内容、
原页/Mosh 页成对更新、快照缺失和页面代际未变化时停止。原有内容不等与尺寸不等的
比较器反例保留；移除只认固定日志文件名的旧静态断言，由上述行为测试接替。

复核同时发现新增的当前页采集会清除日志，若放在原隔离检查之前，可能漏看更早的关闭事件。
该反例在修复前失败。最终将整组采集移到既有隔离判定之后，再执行
最终关闭；不新增日志缓存、计时器或状态层。基线仍读取连接时保存的快照，远端命令不会
改变它。这个先消费证据、后清日志的约束已纳入同一个行为回归。

软件证据位于 `build/verification/mosh-pane-baseline-fix-20260906/`。三次直接检查退出码均为 1；
`software-red.log`、`software-green.log`、`lifecycle-observation-red.log` 只收录失败前输出，
终止异常由外层 PowerShell 上报，没有进入重定向文件。终端实际断言依次为：

- `Survivor reconnect retained the closed Pane baseline, including when geometry matches`
- `Mosh page restoration lacks an acknowledged pre-local-output xterm fingerprint oracle`
- `Fingerprint capture must not erase a pre-existing survivor close event`

首次修复的 `software-desktop.json` 和最终工具的 `software-final.json` 均为
`policy,tooling` 通过。`software-focused.json` 保留沙箱内运行
tooling 组时 WSL 注册访问被拒绝的失败；按身份规则改用桌面用户后通过，未改产品或环境配置。

真机复跑使用原签名 HAP，SHA-256 为
`3d26fdd6b8922ee557f4f18c97b8fe3f1ff14da748fcec909c29b1051304fc4b`，没有重建。
第一次 `verify-mosh-pc.ps1 -Scenario pane-close` 在 201 秒通过，原页和恢复页均为
144×36、viewport 8、指纹一致，清理通过。该中间结果保留在
`build/verification/mosh-pane-baseline-fix-20260906/pane-close/device-mosh.json`；因上述日志
窗口问题，不将它作为最终工具版本的隔离证明。最终版本需使用新目录单次复跑同一场景。
输入拒绝负向触发、性能采样和正式 L4 不属于该次复跑。

最终版本的单次复跑在 198 秒通过，证据为上述目录的
`pane-close-final/device-mosh.json`，并以 previousAttemptId 关联中间结果。原页与关闭后
恢复页都是 144×36、viewport 8，cell 指纹同为 `64c1d8db4ab45623`。关闭旧 Pane 后，
旧输出未进入存活 Pane，新 Session 执行精确命令；旧 server 101 ms 退出，最终 Session
认证关闭后 server 98 ms 退出。Mosh 页面丢弃、本地提示符、设置不变和 secret 检查通过。
10 个本地命令及 2 个远端命令均为一次输入、零不匹配，工具稳定性为 stable。
临时设备配置、fixture 进程、反向映射和目录全部清理，持久网络配置未改。

最终复跑工具 SHA-256 为 `29b017f3b4d8a46d39ffe7d1cf7ab194ddee00a38d83afc110650c6444aa5f7f`。
这是未提交工作树上的单项 L3 诊断，`acceptanceEligible=false`，不是正式发布验收。
本轮只改两项工具代码及其质量/诊断/Next Work 文档，无产品、依赖、签名包、Git 或网络配置
改动。旧失败报告、中间通过报告和最终通过报告均保留；下一项仍是输入拒绝的确定性真机负例。

## 输入拒绝的确定性真机负例（2026-09-06）

目标是验证 CQ-001/CQ-002 的真实 native → N-API → ArkTS → xterm 失败处理，不估算自然
队列饱和的概率。最后已有证据的边界是 Rust `mosh_write` 对真实 Full/Closed 的接纳结果；
尚缺的是同一次拒绝跨越平台调用后，停止输入、处理已收输出、恢复页面并隔离另一 Session。
输入接纳由 native Session 队列拥有，关闭结果由 MoshClient 拥有，页面由对应 Surface 拥有。

本次针对最小触发点重新研究的一手依据：

- [Tokio Sender::try_reserve_many](https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Sender.html#method.try_reserve_many)
  的官方示例预留全部容量后，原 `try_send` 返回 Full；释放未使用 permit 即归还容量。
  固定版本远程页抓取失败，另读取 WSL 中锁定的 Tokio 1.53.1 `bounded.rs` 实现并执行真实
  队列测试。只借用资源预留，不改 64 条容量、不灌消息、不停接收器。
- [NAPI-RS 错误处理](https://napi.rs/docs/concepts/error-handling)说明同步 Result 错误抛给 JS；
  [OpenHarmony 5.1 Node-API 接口](https://raw.githubusercontent.com/openharmony/docs/OpenHarmony-5.1.0-Release/zh-cn/application-dev/napi/napi-data-types-interfaces.md)
  将 `napi_throw_error` 定义为带文本的 ArkTS Error。它们不能替代 napi-ohos 1.2.0 的真机
  证据。当前本机 ETS/NDK 包为 6.1.1.125、API 24，不把上游 5.1 文档冒充本机版本保证。
- [Linux proc_pid_fd](https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html)支持由受控 PTY 的
  stdout 产生真实远端输出；工具先核对该次 fixture PID 的 fd/1 指向 `/dev/pts/`。
- [SQLite 异常测试](https://www.sqlite.org/testing.html#anomaly_testing)采用可控资源失败验证
  异常后的完整性。本次沿用有限、隔离触发的方法，不引入其框架或循环枚举失败点。

Huawei 当前 N-API 指南页未成功读取；开发者域与上游检索没有找到与本项目相同的 Mosh
接纳失败案例。此检索缺口不证明平台无问题；选型依据是公开 API、锁定实现及下述分层验证。

专用 source 转换为每个 Session 增加一次性 arm 标记。下一次实际 `mosh_write` 暂持全部
permit，让原 `try_send` 和原错误映射返回 Full；返回即释放，不插入任何合成消息。
忙、关闭、不存在或重复 arm 均停止触发。普通 debug 转换不带此入口；专用 native 与 ArkTS
转换嵌套在构建锁中，`finally` 按字节还原。生产包及 review-smoke 禁止六个对应入口标记。

`input-rejection` 场景保留左侧真实 Mosh Session，在右侧收到一段真实远端输出后，先调用
生产 `writeMoshBytes`，再启用 native 故障并调用生产输入处理。只注入一个短 parser 帧；
拒绝后检查正字节 write ACK 先于页面恢复、右侧原页严格指纹、固定错误/建议、远端输入为空、
搜索历史不含 Mosh 页面，以及左侧原 PTY 能执行新命令。此次触发不依赖 HDC 高频字符注入。

原生触发器测试 2/2 通过，包括一次拒绝不入队、容量恢复、独立 Session 正常，以及失败前置
条件。`software.json` 保留旧场景枚举断言未登记新场景的失败；补登记后 `software-final.json`
的 `policy,tooling,arkts,rust-native` 全通过。真实 ARM64 专用包已编译、签名、安装并启动；
此时尚未把构建、host 测试或设备 preflight 视为物理负向验证通过。

首个真机报告 `device/device-mosh.json` 失败并完成全部清理。原始日志已证明真实 Full，
但新观察器误将其判为输出未排空：收到 27 字节在 23:03:16.554，Full 在 .555，ACK 在
.557，恢复指纹在 .597。`Get-LeanTTYAppLogs` 因标签数量限制分两次查询，最后拼接
MoshClient；观察器把字符串偏移误当时间。最后正确边界是设备 ACK/恢复事件；第一个错误
边界是新观察器的跨查询排序，owner 是 HiLog 事件时间，而非宿主文本排列。

竞争假设是产品先恢复再 ACK，或采集/判定顺序错乱；上述原始时间和本地分标签查询实现
支持后者。下一步只用离线反例区分：同一组真实时间按标签重排，应仍通过；真实 ACK 晚于
恢复、Full 早于接收、时间缺失或无法区分的 ACK/恢复必须停止。新增标签重排反例在当前
观察器失败，先保留这项红例再修代码，不更改旧 failed/product 原始报告。

针对这个新问题查阅了 [华为鸿蒙电脑终端命令](https://consumer.huawei.com/cn/support/content/zh-cn16083991/)
的 HiLog 标签上限和时间输出格式。上游/开发者域未找到本项目这种宿主二次拼接的直接案例；
不新增全局日志排序器或更改采集格式，复用工具已有时间解析函数，仅修改新观察器。

修正后标签重排反例、缺失/倒序反例和原始现场日志重放通过；`software-timestamp.json`
的 `policy,tooling` 通过。两个物理尝试使用同一 HAP，SHA-256 为
`7d34002b4f63a2f33895051c12e106d260a104e0b0e16308516f2b69b045847a`；只修观察器，未重建。
最终 `device-final/device-mosh.json` 在 243 秒通过，并关联首次失败 attempt：

- 真实 native Full 跨 N-API 进入生产拒绝路径；本次 27 字节接收在 .757，Full 在 .758，
  xterm ACK 在 .760，恢复指纹在 .786。被拒帧未到达远端 PTY。
- 右侧原页与恢复页均为 71×36、viewport 0、指纹 `2e476559db9957d3`；固定错误及建议
  可搜索，该 Session 的远端命令标记不可搜索，右侧 server/PTY 已退出。
- 左侧原 server/PTY 保留并执行新的精确命令，随后正常认证关闭；其 144×36、viewport 10
  的原页严格恢复，server 112 ms 内退出。本地提示符、设置不变、secret 检查通过。
- 10 个本地命令和 3 个远端命令均单次输入、零不匹配；设备临时配置、fixture 进程、反向
  映射和临时目录全部清理，持久网络未改。最终工具稳定性为 stable。

证据均在 `build/verification/mosh-input-rejection-20260906/`。专用 HAP 已独立留存；对真实
普通/专用包执行六个标记的隔离检查，普通包通过，专用包在 `ets/modules.abc` 被拒绝。
这闭合当前输入接纳失败处理的开发验证，不证明自然 Full 的概率、完整交错空间、性能或
发布 L4。历史自然输入归因仍暂停；未修改 Mosh 库或新增生产设置、队列和诊断日志。

收尾将新观察器的时间证据不足归为 harness：缺失 ACK、时间分辨率相同或跨查询时序矛盾
不能独立判为产品缺陷。通过条件未变，不再为错误文案/分类重跑真机。普通测试包已重建、
安装并启动，HAP SHA-256 为 `a8953380f3f545a3161aedcf704fa27f7a1beec57a10b4bc83854c614e49f454`；
native SHA-256 回到本轮开始的 `d9a7148098b6ca523ffd4663e7cd967919d542b8bc6f1ed490272d5c2a13c3a0`。
重新扫描默认 HAP 与生产源码，六个故障入口标记全部缺席。测试包 source 转换及本轮物理
fixture 均已还原；没有 Git 提交、推送或额外性能采样。文档将通过项与证据限制分开记录，
下一项回到既定冷/温启动基线。

## 第二轮事件链复核（2026-09-07）

本轮在 CQ-001/CQ-002 之后继续诊断，未扩展为全仓安全审计。以
`build/verification/quality-diagnosis-1.6-20260906/inventory.json` 的 165 个源码/工具文件绑定
输入；核心生产源码与前轮普通 HAP 的输入一致。新物理数据和工具计时/计数限制见
[`performance-diagnosis-1.6.md`](performance-diagnosis-1.6.md)，不重复展开第二份测试日志。

| 事件链 | 直接检查的权威与清理边界 | 判断 |
| --- | --- | --- |
| 输入 → native 接纳 → 关闭 | SessionViewModel、MoshClient、真实有界队列和共享 close Promise | 两项已修复合同保留；未重开历史自然输入归因 |
| native 输出 → Bridge → xterm ACK | `run_mosh_protocol`、输出 pause、Surface attach/detach、pending write | 关闭继续消费已收输出；queue/ACK 所有权不同，不能为了少变量合并 |
| Mosh 页面 → snapshot → 恢复 | 每个 Surface 的 generation、页面请求/保存状态、Bridge replacement ACK | 保持尺寸/viewport 与晚到事件隔离；既有真实负例与 xterm 回归可复用 |
| Tab/Pane → Page/进程生命周期 | ApplicationWorkspace、AppViewModel、PaneRuntime、Index warm timer | 工作区活对象只有进程级 owner；UI 投影不是第二份独立持久状态；dispose 及 timer 有清理入口 |
| 工作区变化 → 异常恢复记录 | checkpoint capture、putSync/flushSync、只保存结构的校验 | 同步写盘成本未测；不能拿启动 read 时间代替 write，也不能擅自改耐久性 |
| 诊断输入/输出 → 日志 | SessionViewModel 的 perf observer、TerminalBridge、Logger | CQ-003 有实际 owner 反例；Web perf 的计数与时钟还存在独立测量缺口 |

### CQ-003：性能 ping 将特定命令正文写入公开日志（P2，采用修复方向）

**合同与预期：** `security-model.md` 明确终端正文及 secret 不进入日志。测试 marker 只是
输入数据，不是放宽生产日志隐私边界的授权；正常诊断最多记录固定事件、数值或不可承载
任意正文的受控标识。问题尚未修复，本节采用的是处理方向，不代表已经实施。

**最后正确边界：** 已连接 SSH 的输入被正常送入 `handleConnectedInput`；该分支在写入前
调用 `observePerfInput`（`SessionViewModel.ets:1363`）。后者逐字符保存最多 256 字符；若
输入在 Enter 前以 `echo LTTY_PERF_PING_` 开头，就把 `substring(5)` 的全部剩余文字作为
`perfPingId`，并非只提取固定 case ID。服务端原样 echo 后，`observePerfOutput`（981–990 行）
将整个值拼入 `logger.info`，这是正文越过日志边界的位置。真实
`Logger.ets:12–13` 以 `%{public}s` 调用 `hilog.info`，无 release/debug 编译条件。

**最小证据：** ignored `perf-log-boundary.cjs` 转译当前实际 SessionViewModel/Logger，
只替换最终 `hilog.info` 平台边界，不复制两个观察函数。使用公开字符串，三项检查成立：

1. 普通 `echo` 加公开 canary 不写日志。
2. 分两段输入性能前缀加 canary，随后模拟匹配的 echo，真实 Logger 收到一次公开格式的
   日志，且包含前缀后完整 canary。
3. 另一个 Session 只收到相同输出不会触发该日志，未发现由此造成跨 Session 串扰。

报告 `perf-log-boundary.json` 为 `defect-reproduced`，不是产品通过。没有访问真实凭据、
上传日志或对用户 Session 试验；这是 host owner 证据，不是自然发生率或真机利用证明。
它需要精确性能前缀及匹配输出，**不是普通输入都会泄漏，也不是 SSH 登录认证回调泄密**；
但若该特殊命令携带敏感正文，现有实现会原文记录，因此仍违反已有边界。

本轮核对了[华为 HiLog API 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V3/js-apis-hilog-0000001333800437-V3)：
`public` 参数明文输出，`private` 参数默认过滤。此 V3 文档只支持格式语义，不冒充本机
API 24 的完整实现测试。实际调用参数已由执行当前 Logger 证明，不需要修改系统日志隐私
开关或读取真实终端内容来验证。

**建议的最小边界修复：** 将旧性能 ping 的正文观察从生产路径移除；若验收仍需要该探针，
复用现有编译期测试 source 转换，普通生产包中不保留相关输入缓存和日志入口。测试标识
也只接受受控、有限格式。Keypush 的独立输出观察需求须保留，不把整个 decoder 或其他
状态机一并删除。不通过全局 Logger 打码、加用户设置或过滤几个敏感词修补。

收益是关闭一条已确认的正文日志路径，并减少无用的生产观察职责；不承诺尚未测量的
吞吐收益。复杂度集中在删除旧观察器及迁移依赖它的测试入口，风险是破坏旧性能判定或
误删 Keypush 观察。验证应包含普通/专用包隔离、实际 owner 的公开 canary 红绿测试、
受影响 SSH 主路径与测试 marker 检查；回退可以停用这项探针，但不能恢复生产正文日志。

### 其余候选：不把怀疑、长文件或单次增长写成产品缺陷

| 候选 | 证据与用户影响 | 取舍、成本与验证边界 |
| --- | --- | --- |
| 输出 resume 入队失败 | SSH/Mosh pause 信号各用容量 8 的 `try_send`；Mosh 捕获异常只记 warning。若最后 resume 未入队，存在保持暂停的条件性风险；尚无真实状态序列反例 | **待证实**。先执行实际队列与 owner 的最小饱和/关闭交错测试，区分 Full/Closed；证实后才选择修复。不能直接改 watch channel、加重试 timer 或放大队列；需保留另一 Session 和关闭排空边界 |
| workspace 同步 checkpoint | 有同步落盘代码，但没有焦点/布局路径的阻塞时延样本 | **待证实**。先测发生频率和实际阻塞；收益须大于观察噪声，异步化有崩溃耐久性风险，回退须保留当前合同 |
| 多 Tab 图形峰值 | 本轮新建两个本地 Tab 时 graphics 增长，超过 warm 保留期/关闭后明显回落 | **待证实**。不是已确认泄漏；先补固定预算长时与压力观察。改 30 秒 warm 策略可能损害切换体验，当前不改默认值 |
| 长文件和工具规模 | 盘点 native 5592 行、Mosh verifier 4781 行、SessionViewModel 3012 行、Index 1665 行；工具包含大量场景和测试 | **放弃纯行数重构**。随明确缺陷抽取唯一责任；CQ-003 是可定位的诊断职责混入，优先删这项而非整类重写。回退不应保留两套 owner |
| 通用 Transport、合并所有 generation/页面状态 | SSH 字节流与 Mosh 画面、Pane runtime 与 Surface/页面有不同生命周期 | **放弃**。没有收益证据，合并会扩大隔离和恢复风险，验证/维护成本高 |
| xterm 补丁移除或运行时私有 API 覆盖 | 版本/哈希、行为 corpus 和移除条件仍有效，软件组重新通过 | **放弃本轮改动**。上游同一 corpus 通过才重新评估，不为少代码撤掉正确性保护 |
| 透明度、队列、tick 微调 | 本轮没有可比较的纯吞吐、负载输入/帧丢失证据；100 ms Mosh tick 只是代码事实 | **放弃未经测量的优化**。不增加设置、缓存、常驻后台或调度层，也不以丢输出换数字 |

现有静态/host/真机测试没有覆盖所有异步交错；上表的“待证实”不是通过，也不授权先修。
新工具本身两次产生错误（启动 import 转换、临时 driver 的脚本作用域），说明测试复杂度有
实际维护成本。已在各自最小边界验证/修正，未新建常规测试框架；一次性内存脚本仍留在
ignored 证据目录，不提升为另一套工作区或发布控制器。

架构文档中“不持久化 Tab/Pane 状态”的旧笼统表述与新增“只恢复结构”需消歧，SSH projection
初始化说明应对齐当前 lazy 路径；安全文档的旧 1.1 未交付措辞也需随 1.6 文档收口更新。
这些是文档一致性问题，已归入 Next Work 第 4 阶段，不冒充新的产品功能或安全修复。

### 本轮验证和停止点

聚焦 `policy,tooling`、`ssh-flow,web,arkts` 通过；165 个源码/工具文件的身份核对中只有
两个启动工具发生预期变化。普通 ARM64 debug 包已重建、安装、启动，并在实际包上排除
启动/输入拒绝专项探针。没有改产品、库、Git 或正式发布身份。

代码诊断和已有测量已形成记录，但整个第 3 阶段仍有缺口。CQ-003 是新确认的安全边界问题，
因此按本轮允许的异常暂停条件停止扩展性能探针，先交付证据和修复方向；不边诊断边修改
生产日志合同。剩余执行顺序只保存在 Next Work，不重复冷/温 40 例或再次启动 Wi-Fi 综合矩阵。

收尾 `software-final.json` 的 `policy,tooling` 再次通过；三份诊断/Next Work 文档共 19 个
本地链接目标存在，`git diff --check` 通过。测试状态与 CQ-003 的 `defect-reproduced`
分别记录，软件回归成功不覆盖该新反例。

## 2026-09-07：日志分级实施与后续诊断

维护者采纳：正式审核/用户交付包不记录正文与 secret；受控开发诊断允许必要正文及可
废弃的 fixture secret，真实凭据默认排除。CQ-003 因此按发布隔离缺陷修复，不删除开发
观测能力。源转换复用既有 debug 编译入口和 `finally` 还原，不添加用户开关或日志框架。

依据：本地 `build-all.ps1` 已按 BuildMode 选择源转换、检查 unsigned/signed HAP；
[Android 官方日志披露指南](https://developer.android.com/privacy-and-security/risks/log-info-disclosure)
支持开发采集与发布裁剪分离；[OWASP Logging](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
支持凭据默认排除和日志访问/留存控制。后两者是安全设计依据，不作为 HarmonyOS 编译行为
证明；平台隔离以本项目实际产物验证为准。未发现需要绕过的上游库缺陷。

实际改动：将 Session ping、Web 性能标题/正文观察和 `perfRender` Bridge 路由移入
`performance-diagnostic-source.ps1`。生产保留结构化 renderer/队列计数及 Keypush 观察。
debug ping 只接纳有界 fixture 标识，非匹配输入立即丢弃观察缓存；断开/Surface 脱离清理，
输出只在 pending ping 期间观察。包扫描新增七种性能标记及 checkpoint 专项标记；
冷/温启动注入改用稳定生产锚点。

红绿测试先证明任意命令后缀进入实际 `%{public}s` 日志，再证明生产静默、debug 正常指标、
拆包匹配、Session 隔离、输入不变、Keypush 保留和转换恢复。旧 Web 测试要求生产标题解析器
存在，与新合同冲突，已改为生产不存在，并在 debug owner 测试执行真实注入标题解析器。
证据目录：`build/verification/diagnostic-logging-isolation-20260907/`。以下继续记录最终验证。

### 输出 pause/resume 接纳：验证前假设

- 预期：活跃 Session 的最后期望输出状态不能因控制接收者短时延迟而永久遗失。
- 最后正确边界：Surface 已更新自身背压状态并调用 `setOutputPaused(false)`。
- 疑似首个错误边界：容量 8 的 N-API `try_send(false)` 返回 Full，上层只告警且不重新同步。
- 权威 owner：Surface 拥有期望暂停状态，native 消费任务应用它；不是需要重放的用户命令队列。
- 最小鉴别：暂不消费实际 native receiver，经真实 SSH/Mosh N-API 发送初始 false 和四轮
  pause/resume，读取消费端最终值。这只能证明有条件接纳缺陷，不能证明真机自然发生率。
- 若没有反例不改队列。若成立，优先比较最新状态通道与失败关闭；不扩容或新增重试计时器。

反例成立：SSH、Mosh 分别执行同一真实 N-API 接纳测试，最后 `false` 均返回
`send failed: no available capacity`，消费队列后的状态仍为 `true`。上层只告警且 Surface
已变更，后续不再通知同值，因此定为 **CQ-004 条件性活性缺陷**；未声称真机自然必现。

采用现有 Tokio `watch<bool>`，保留最后期望状态，native 以 `changed()` 和
`borrow_and_update()` 应用；关闭后的接纳仍报错，关闭控制通道不重复唤醒空循环，Mosh
close 仍强制恢复输出并排空。依据是锁定版 Tokio 1.53.1 的
[watch 合同](https://docs.rs/tokio/1.53.1/tokio/sync/watch/index.html) 与
[try_send Full 语义](https://docs.rs/tokio/1.53.1/tokio/sync/mpsc/error/enum.TrySendError.html)。
不重放已过时暂停，不增加依赖、缓冲容量或重试 owner。相较失败关闭，此方案保留同一
Session；风险是中间暂停可能合并，符合“当前背压状态”合同，用户输入仍走原有有序通道。
回退应还原此切片并停止发布，不能把原先会丢最后 resume 的行为当作通过。

### 本次验证、复杂度与未闭合项

CQ-003 已验证：真实 owner 的红绿、production/debug/production 源转换及恢复、debug
实际 HAP 被 release 扫描拒绝，release-mode unsigned/signed HAP 的标记扫描通过。
保留的 release-mode test-signed HAP SHA-256 为
`77f13c011b337553921ce138065e4d9b474c5e245c9edb423e7949a606703d97`；结束时以最新
标记列表再次扫描通过。该包完成 install/startup/new Tab/split/close Pane/原工作区恢复
冒烟，debug 包完成 SSH 认证、1 MiB 精确输入与传输主路径；均不是正式发布验收。

CQ-004 的共享改动只将“当前期望输出暂停状态”改为 watch；输入、resize、关闭的顺序
合同不变。WSL clippy、native 53 项及 Mosh 专用输入拒绝 2 项通过，真实 N-API 测试覆盖
最新 false 保留、后续 true/false 更新、receiver 关闭仍报错。新 native 已用于完整 SSH
输出和 60 个负载输入样本，但这不证明物理 pause/resume 压力或另一 Mosh PTY 隔离；
两者仍留在 Next Work，不能用此前 native 身份的真机结果覆盖该变更。

测试维护成本本轮再次显现：一次性 driver 缺报告函数、回退检查误解 xterm 3 秒宽限，
修正后又遇到 UiTest 目标层级/bounds 变化。前两项有直接原因并保留失败；第三项不放宽
输入保护、不开始第三种旁路，转为用户可审阅的暂停记录。性能探针另加普通 debug
主动行为默认关闭及结束帧边界测试，避免诊断工具改变正常用户输入或污染结果。

本轮采用两项有明确反例的正确性修复；性能/资源候选没有新证据支持调优。新增复杂度
主要在测试侧，未引入产品设置、依赖、重试 owner、通用 Transport 或大拆类。文档区分
历史发现、当前实现与验证缺口；活动顺序只保留在 Next Work。

最终软件门为 `software-final.json` 的 `policy,tooling,web,arkts,rust-native` 全通过。
普通包恢复、精确哈希、样本限制及清理见性能诊断文末；`round-summary.json` 明确记录
CQ-003 已验证、CQ-004 软件修复/物理隔离待补，资源与 checkpoint 未取得新结果。

## 2026-09-07 续轮收口

上一节的物理待补项已按边界完成，旧报告保持原结果。新证据位于
`build/verification/diagnosis-continuation-20260907/`；详细场景、数字和实际包身份见
[`performance-diagnosis-1.6.md`](performance-diagnosis-1.6.md) 文末。

输入 harness 的错误 owner 是完整虚拟 hierarchy。实际 UiTest 构树源码和本地 xterm
输入框实现不承诺其跨重建稳定；改为同一次串行输入前后的非空原生 Web 窗口、层级、
accessibility ID 及唯一终端子输入框。新增实际 helper 红绿测试允许同一 Web 的虚拟子树
重建，拒绝跨 Pane/窗口、Web 替换、Search 夺焦和多候选，保留单次输入/Enter 前保护。
它只新增测试工具内的局部结构解析，不创建生产 owner、缓存、重试或第二套终端身份。
窄真机场景证明 DOM 回退后的 984,000 字节完整输出和新命令，清理通过。

CQ-004 的 Mosh Surface 重建和双 Mosh/SSH 混合隔离均通过；关闭一条不会破坏另一条，
后续新命令、认证关闭、原页面和清理均确认。另有两条 SSH 固定 601.7 秒尾段、8 组精确
输出及关闭终点通过。这些是新 native 的集成回归，不是自然触发 Full 的发生率证明。
Full/Closed 的精确交错保留在真实 N-API 的确定性软件测试；不为重复该 owner 证明新增
真机饱和触发器。输入仍用有序通道，watch 只拥有最新期望 pause 状态，回退条件不变。

| 候选 | 最终取舍 | 依据与重新进入条件 |
| --- | --- | --- |
| CQ-001 至 CQ-004 | 采用并完成受影响开发验证 | 均有实际 owner 反例与回归；正式验收仍绑定最终候选 |
| 同步 checkpoint 异步化 | 本轮不采用 | 3 个有效样本为 0、0、3 ms，1 ms 分辨率；完整频率未测，不足以承担崩溃耐久性风险；只有可复核阻塞或用户退化才重开 |
| Tab warm/图形预算微调 | 本轮不采用 | 固定尾段无持续单调增长，图形峰值回落；关闭后映射 PSS 高于起点，长期泄漏未排除，需持续增长/归因证据而非单点差值 |
| 长类拆分、统一 Transport/状态层 | 不采用 | 无已测用户收益，扩大生命周期和隔离风险；只随明确缺陷调整唯一责任，不按行数重写 |
| 全量移除 xterm 补丁或调队列/tick | 不采用 | 既有正确性 corpus 仍有效，没有纯吞吐或稳定性收益证据 |

工具复杂度的教训落实为局部 owner 修复和明确停止点，而不是增加永久框架。checkpoint
通用查询漏 tag 的原空结果保留，补充只读数值不冒充完整样本；资源不强制 GC、不延长
预算，不以缺少 hitch 数据声称无卡顿。收益不足时保留产品现状，避免诊断本身继续膨胀。

普通 debug 包已恢复到测试机，主动测量关闭，专项标记和源还原审计通过；policy/tooling
聚焦门通过。没有 Git 提交、依赖升级或正式 candidate。下一阶段仅按 Next Work 进行
文档一致性收口，再进入精确候选的软件/物理发布门；不重复已完成的开发诊断矩阵。

## 2026-09-07 合并前发现的 Mosh 关闭竞态

独立差异评审发现了新的正确性反例，因此抢占 PR 切片，不重启性能诊断。native 已把末尾
data/close 入队并清除 Session map，而 ArkTS 仍在处理输入时，write 被拒绝后的 disconnect
再次报 map 缺失。旧错误分支立即清空 ArkTS owner，导致末尾回调被丢弃。固定调度执行真实
owner：基线保留两个字节，新输入拒绝路径丢失两个字节。它证明可达机制，不是设备发生率。

修复只改变 native `mosh_disconnect`：map 缺失、已有关闭请求和接收端关闭均幂等确认；
非法 ID 和 poisoned lock 仍报错。请求确认不是回调消费完成，既有 transport close 继续
拥有排空、原页恢复和重叠 waiter 的完成。没有延时、重试、异常字符串解析或新状态层。
拒绝的文本不会重发，之后的 Enter 仍被阻止。此结论限于已连接协议链路，不扩张为任意
native panic、运行时销毁或 bootstrap 取消都保证 transport close。

证据根目录：`build/verification/pr-slices-20260907/`。

| 验证 | 结果与边界 |
| --- | --- |
| 真实 native `mosh_disconnect_*` | 新增 3 例先全部失败、修复后全部通过；覆盖缺失 map、Full/Closed、无效 ID 和另一 Session 隔离 |
| 真实 ArkTS owner 宿主测试 | 12/12；输入拒绝与主动关闭在 map 已清理、尾回调待处理时均先排空后完成，晚到事件被隔离 |
| `mosh-close-software-recheck.json` | policy/arkts/rust-native 11 项通过，ArkTS 202、native 56 及专项触发器 2 例通过；非 release gate |
| `mosh-close-input-rejection/device-mosh.json` | 238.5 秒；真实 Full 拒绝、27 字节输出先 ACK、原页指纹相同、安全提示、被拒输入未到服务器、另一 PTY 新命令及清理通过 |
| `mosh-close-fixed-endpoint/device-mosh.json` | 普通开发包 156.7 秒；连接、命令、输入输出、正常关闭、原页恢复及清理通过 |

专项 HAP SHA-256 为 `1b58bec4fac746b20e45257e5247ef544b6700b6111646385e2534074a9e577d`；
随后重建并恢复普通开发 HAP `aebad8ef5c78cc13e35ac605fbfe127e28ae06ef6cc2cc2d4ca62b197a73e885`，
普通 native 为 `1d7c4812cabfbc3eb65ee10d272d0350d845375882ab8ec4d0144825f12c680f`。
专项构建的 11 个源码文件还原哈希一致。真机仍为同一 ARM64 HarmonyOS PC，未跑 Wi-Fi、
资源尾段或正式矩阵；精确 map/回调交错由分层软件反例覆盖，不冒充物理确定性触发。

第一次软件门在验收源码转换时遇到 Windows 文件映射占用，报告保留为
`mosh-close-software.json`；finally 已恢复，独占打开检查通过后仅重检一次。没有修改工具
或把这个环境失败改写为通过。独立复核记录在 `security-review.md` 第 10 节，关闭该项
代码级阻断；历史抛错 native 模型的红反例保留，不能单独用更新后的 mock 声称已修复。

## 2026-09-07 诊断复核后的最小精简

维护者授权两项删减，不重新打开全量性能诊断。输出字节在当前 SessionViewModel 到达时
正确；无消费者的额外工作发生于 `observeSessionOutput`：Mosh 永不使用解码结果，普通
SSH 在没有 Keypush 时也立即丢弃。真实方法的只读计数已确认两种空观察，不能据此量化
CPU 收益。Keypush 字符流应由 Keypush 操作拥有，开发 ping 由编译期探针独立拥有。
最小假设是：只在这两个消费者活动时解码，可以保持原字节交付和分块语义且删除空工作。

另一个边界在 `run_mosh_protocol`：100 ms tick 只负责首次 Active 通知，但通知后仍被
select 轮询。`connected_reported` 已拥有一次性状态；只禁用完成后的分支，不改客户端
协议计时器、输入、reachability 或关闭。采用前的一次性源码检查确认了缺少分支条件；
它不是调度测试。按质量规范，不把私有变量名和实现形状冻结成永久静态检查，也不为
一个条件新增生产抽象。保留 native 编译/既有合同测试，并验证新包首次连接、命令和关闭。

选择 L0 policy、L1/L2 arkts/ssh-flow/tooling/rust-native 与 ARM64 构建，L3 只用现成
Keypush、SSH 和 Mosh 命名主路径，覆盖输出、首命令与关闭。禁止用新主机计数冒充真机
耗时或功耗改善；测试失败先停在对应 owner，不重跑启动、资源、Wi-Fi 或正式矩阵。

### API 依据与软件反例

2026-09-07 核对锁定的 Tokio 1.53.1 和当前 OpenHarmony 官方文档：

- [Tokio select](https://docs.rs/tokio/1.53.1/tokio/macro.select.html) 说明 false 前置条件
  禁用该分支的 future polling。这里仅关闭 LeanTTY 的首次通知观察，不更改库内时钟。
- [OpenHarmony util](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-arkts/js-apis-util.md#decodetostringoptions12)
  说明 `decodeToString(..., { stream: true })` 保留末尾不完整字节。继续使用既有 API，
  只将 decoder 生命周期移到实际消费者；没有采用已弃用的 `decodeWithStream`。

旧 SSH/Mosh 入口共用无消费者解码；实际 SessionViewModel 的公开 9 字节向量首先在旧
SSH 入口以“实际 9、预期 0”触发新增断言失败。新入口保持原始字节，包括拆开的 UTF-8、
NUL、无效字节和终端转义。扩展用例
验证 Keypush 分块 marker、无 marker 不解码、完成/取消释放、下一操作无残余、另一个
Session 隔离和晚到输出拒绝。主机用平台 decoder 替身计数，不代表 HarmonyOS 解码性能。

开发 ping 独立懒建 decoder，只在明确的待响应命令窗口内观察；完成、重置或 30 秒过期
时释放。生产 → 开发注入 → 还原生产三态测试通过。第一次聚焦门在旧验收注入锚点失败，
报告保留为 `software.json`；修复 Mosh 字节计数探针的入口后，`software-focused.json`
通过 `policy,tooling,ssh-flow,arkts,rust-native`。未改变字节计数探针的输出内容或默认开关。

### 新包真机结果与收口

证据根目录：`build/verification/hot-path-simplification-20260907/`。本轮仍为当前 dirty
工作树的开发验证，没有提交、推送、依赖更新或正式 candidate。ARM64 普通 debug HAP
SHA-256 为 `747d74bc64708524c0c42c1f9c0f2b8345cd774d154706204f2ebd53993bada1`，包内
native 为 `da82e41185d9e21f89f85d38eeb65ccb85208946f0cdf15f883b25f2a1099693`。三项场景
在同一 HAD-W32 上串行使用该包，不借用旧包的结果。

| 命名场景 | 结果与直接证据 | 全程耗时 |
| --- | --- | --- |
| Host Identity / Keypush | 真实 `ssh-copy-id` 安装指纹精确匹配的临时公钥；重启后认证、移除绑定后的回退及恢复均通过；12 条普通命令无输入重试 | 162.0 秒 |
| SSH `transport-main-path` | 1 MiB 粘贴、12,000 行输出的完整性/顺序/可见尾部、新命令、resize、断开重连通过；5 条本地和 7 条受控远端命令无输入重试 | 156.4 秒 |
| Mosh `fixed-endpoint` | 首次 UDP 连接、请求端点和受控 PTY 命令、认证关闭、原页面精确指纹恢复及 Mosh 页面丢弃通过；9 条本地和 1 条远端命令无输入重试 | 156.9 秒 |

三份原始 JSON 的 cleanup 均通过，SSH/Mosh Preferences 未变，Mosh 持久网络未变；没有
操作已有 `id_ed25519`。测试机保留该普通 debug 包，主动输入/context-loss 关闭，专项
checkpoint、启动、输入拒绝标记不存在，源码转换已还原；见 `package-audit.json`。
本轮未重建 release-mode 包，正式包隔离仍须在最终精确候选上验证。

软件结果包含 202 项 ArkTS、10 项 Mosh owner、53 项 native 和 2 项专用 native 触发测试；
ArkTS 单测的 47 条既有告警指纹不变。这里的测试计数不是性能样本。没有重新采集启动、
600 秒资源尾段、Wi-Fi 或完整矩阵，不声明已量化延迟、CPU、功耗收益或长期无泄漏。

按维护者批准的减法范围，将 Next Work 的已完成过程完整保存为
[历史快照](archive/next-work-1.6-development-20260907.md)，活动清单回到文档、精确候选、
正式发布的顺序；历史失败不改写为通过，也不再授权重复诊断。

收尾 `policy,tooling,ssh-flow` 通过，见 `software-final-desktop.json`。此前同组因沙箱
身份访问 WSL 得到 `E_ACCESSDENIED`，保留为 `software-final.json`；改用桌面用户后通过，
没有因此修改产品或重复真机场景。4 份本轮文档的 32 个本地链接目标、归档原文一致性
及 `git diff --check` 均通过。

# 1.6.0 性能与稳定性诊断

更新：2026-09-07。本文记录测量依据，不是第二份 TODO；执行顺序由
[`next-work.md`](next-work.md) 管理，采样和失败处理遵循
[`quality-strategy.md`](quality-strategy.md) 的 Performance and reliability measurement。

## 当前结论

development GO 依据见 [`test-release-efficiency.md`](test-release-efficiency.md) §8.30。
CQ-001/CQ-002 开发验证闭合后，本轮取得冷/温启动各 20 例、持续输出 15 例，以及
340 秒内 16 次主进程/renderer/GPU 内存观察。冷启动首字母 P50/P95 为 1492/1537 ms，
温启动为 504/545 ms；关闭后的资源占用明显回落，尚无高价值性能优化或泄漏的确证。
这些是当前工作树的 debug 诊断，不是同包 release-mode、1.5.1 对比或长期稳定性结论。

**第 3 阶段有界开发诊断已完成，下一步是文档收口。** CQ-003 日志发布隔离和 CQ-004
最后 resume 遗失的修复及受影响验证见
[`code-quality-diagnosis-1.6.md`](code-quality-diagnosis-1.6.md)。新增 3 例全正文输出及
60 个负载输入样本；续轮修复 harness 的虚拟输入层级误判后，实际 DOM 回退后的完整
新输出、新命令，以及新 native 的 Mosh 重建/隔离均通过。固定资源尾段完成 601.7 秒和
8 组精确输出；没有取得支持参数微调或大重构的确证，保留现有预算。诊断复核后另采用
无消费者解码和首次通知空轮询两处精简，其新包验证见文末；不据此改写此前测量数字。
checkpoint 只有 3 个有效计时样本，未测完整写入频率；hitch unavailable、长期泄漏和
系统 OOM 仍是证据边界，不据此声称无卡顿或无泄漏。下文保留旧轮判断和失败报告，最新
结果、产物身份及停止边界见文末；这些开发诊断不替代正式候选验收。

## 采样前盘点与历史时效

下表保留进入本轮前的缺口；本轮实际覆盖和剩余限制见文末，不以新结论改写旧证据。

| 范围 | 已有证据或实现入口 | 能复用什么 | 当前缺口与限制 |
| --- | --- | --- | --- |
| 冷/温启动 | [`design/startup-performance.md`](design/startup-performance.md)；`tools/verify-startup-performance-pc.ps1`、`tools/verify-startup-warm-pc.ps1` | 真正图标点击 → 首字母生产输入回路 → paint 的 T0–T5；冷启动确认进程不存在，温启动确认 PID 不变 | 2026-08-17 的 1.4 候选冷启动 P50/P95 为 1491/1519 ms、温启动为 482/499 ms，各 20 例；是旧包旧系统数据，不是当前基线 |
| 连续输出与大 scrollback | [`design/terminal-search.md`](design/terminal-search.md)；`tools/verify-ssh-auth-pc.ps1` 的 `transport-performance` / `performance-matrix`；SSH fixture | 12,000 × 80 有界输出、Web 侧 expected/actual bytes、parse/paint 时间；现有五档透明度每档三例 | 旧搜索报告的时间包含准备后提交 run 命令的成本；不是纯 renderer 耗时。字节计数相同也不单独证明顺序或内容相同 |
| renderer、GPU、hitch | `terminal.html` 的 `reportPerfResult`、`fallbackToDomRenderer`；SSH 工具的 `Get-AuthHitchSample` / GPU 查询 | 现有 WebGL 初始化/context-loss 回退入口及系统观察通道 | 系统累计 hitch 需同窗口前后差值；字段缺失为 unavailable，不是 0。当前缺少负载中输入到 paint 的独立分布 |
| 内存与回收 | SSH 工具的 `Get-AuthProcessMemorySample` | 主进程及 render/GPU 的 VmRSS、VmHWM、RenderService GPU bytes | **没有 PSS 字段**。旧 RSS 总量含共享页重复计数，不能写成 PSS；缺少单/双 Pane、多 Tab、关闭后和长会话趋势 |
| 背压与输出顺序 | `tools/check-ssh-transport-flow.ps1`、`TerminalInteraction.test.ets`、Web terminal 策略/快照回归 | 既有 Bridge 队列、ACK、重放、Session 隔离的正确性护栏 | 软件合同及历史队列清空不等于当前高负载时延；需与同一次负载的完整性、丢弃和队列终态合看 |
| 生命周期与页面恢复 | §8.11 / §8.17 / §8.20 的原始诊断报告；`tools/verify-mosh-pc.ps1` 命名场景 | 同几何页面恢复、受控 runtime-reclaim、同 Session/PTY 网络恢复的业务边界 | 不同诊断包不是同一性能样本；runtime-reclaim 非系统 GC；一次恢复通过不证明长期内存稳定，不重复切网来测噪声 |

本轮已查阅上述源码和文档，并在当前 `build/verification` 中查找性能报告。
旧文档指向的 `startup-performance-final-4c44709-20/summary.json` 当前不在该位置；
旧数值保留为文档中的历史参照，不补造原始数据或混入新统计。

## 测量次序及进入条件

先测启动，因为它独立于远端、认证与网络扰动，已有完整输入终点；随后持续输出可以同时
暴露 renderer、队列和负载中输入问题；最后扩展 Pane/Tab 和生命周期，避免一开始叠加变量。

1. **冷/温启动。** 使用现有测试包转换和真实图标入口；先验证转换、还原及 T5 终点，冻结
   每组包/工具哈希，再执行已有协议的各 20 个有效样本。保留全部失败及排除原因，首个无法
   解释的失败停止本组，不能不断补样。工具默认计数已经是 20，不增加一轮临时预跑矩阵。
2. **连续输出、renderer 与输入。** 复用固定 fixture 形状和现有五档透明度三例协议；每档
   报全部值与 min/median/max，不从三例生成 P95。分别记录端到端和 Web 时钟区间，不把
   prepare/run 的 HDC 等待当作纯解析成本。负载中输入若现有终点不足，只补能回答该问题
   的测试侧观察，不在 Bridge 或 Mosh 中新增补偿逻辑。
3. **内存和生命周期。** 沿同一包的空闲 → 单 Pane 负载 → 双 Pane/多 Tab → 关闭回收记录
   有界时间序列及进程身份；GPU 与 renderer 分开，不把 RSS 当 PSS。先核对目标系统可用的
   只读 PSS 通道，才决定是否需要工具改动。长会话采样预算在执行前固定，不能为了等到下降
   或上涨无限延长。页面重建/关闭继续使用直接 owner 证据，不解析终端文案猜生命周期。

这些是已授权诊断的拆分，不改变正式验收合同。下一轮执行前仍需读取真机验收 skill，
preflight 后串行控制设备，保留原工作区和设置。若要修改验收工具，先按单项问题重新查阅
官方平台/依赖资料并做最小红绿验证，不因本次盘点跳过工具修复的研究门。

## 比较与停止规则

- 初始盘点不含设备样本；后续采样的专用启动包和普通 debug 包分别绑定哈希。输入诊断
  包含测试探针，不能在未核对观察开销的情况下直接作为 release-mode 性能结论。
- 固定设备、系统、包及签名角色、窗口几何、renderer/透明度、数据与工作区状态、供电/
  网络和工具版本；包或受影响链路不同则分组。需要量化相对 1.5.1 的退化时，必须重新取得
  同系统同协议基线；1.4 文档数字只能帮助定位数量级。
- 输出丢失、乱序、串 Pane、崩溃或不可恢复优先于性能。保留故障现场，只回到第一个错误
  边界的最小诊断；自然输入故障仍须实际失败证据，不能用合成补丁通过倒推同因。
- 两个不同修复失败、第三个 workaround 前或未解失败达到 90 分钟，执行既有重审门。
  没有高价值瓶颈时以“无需优化”结束，不为了完成清单制造优化目标。
- 不足以改变用户体验、低于噪声或靠增加长期复杂度获得的小收益，归入“放弃”；缺当前
  证据的候选归入“待证实”，不得当作已发现产品问题。

## 本轮执行记录

证据目录：`build/verification/quality-diagnosis-1.6-20260906/`。
当前工作树以 `inventory.json` 的 165 个文件哈希冻结；`policy,tooling` 和设备 preflight
通过。它们只证明软件护栏及设备通道可用，不是性能结果。

### 冷启动插桩构建失败：import 顺序

- 预期：测试侧插桩可编译，退出后生产源码逐字节恢复，再采集 20 个冷启动样本。
- 最后正确边界：普通生产源码与签名 HAP；第一个错误边界：插桩后的
  `DurableStateManager.ets` / `TerminalPane.ets` 把日志常量放到了后续静态 import 前。
- owner：`tools/startup-performance-source.ps1`。当前 SDK ETS `6.1.1.125` / API 24
  在 `cold-build/hvigor-build.stderr.log` 报 `arkts-no-misplaced-imports`。
- 2026-09-07 查阅 [OpenHarmony ArkTS 迁移规则](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/quick-start/typescript-to-arkts-migration-guide.md#不支持在import语句前使用其他语句)：
  静态 import 必须先于其他语句。华为文档搜索结果同规则；未发现需要 SDK workaround 的
  上游问题证据，实际编译错误也不支持归因于产品初始化。
- 最小假设与验证：只把日志常量移到整个 import 列表之后；新增声明顺序反例，保留现有
  转换/异常还原检查，再用同一编译器构建。不开新探针、不改生产初始化或 T0–T5 定义。
- 失败未进入采样、未安装新 HAP；165 个盘点文件已恢复，普通 HAP SHA-256 仍为
  `a8953380f3f545a3161aedcf704fa27f7a1beec57a10b4bc83854c614e49f454`。
  先前的转换 4/4 没有覆盖 ArkTS 编译合法性，不能替代本轮构建验证。

新增 import 顺序反例先失败；仅修转换后的 `policy,tooling` 通过，冷/温专用 ARM64 包均
编译成功。失败与修复后证据分别保存在 `startup-import-red.*`、
`software-startup-import-green.json`、`cold-build-fixed/` 和 `warm-build/`。

### 样本身份与环境

- 同一 HAD-W32 ARM64 PC，系统 `HAD-W24 6.1.0.135(SP60C00E100R13P3log)`，USB。
  系统查询 GPU 为 HUAWEI Maleoon 916 / OpenGL ES 3.2 B301；能力查询不等于每一帧的
  renderer 归属。未记录完整供电/温控/全机后台负载时间线，不能量化环境噪声。
- 工作树 HEAD 为 `e2e3f0f4d6dee15130b0b346097271a766f22abe` 加已有未提交改动。
  同一原有 3 个本地 Tab、一个可见 Pane；自由窗口 `[168,319][2798,1902]`，屏幕
  3120×2080。冷启动前 force-stop，因此包含异常退出后的工作区结构恢复，不是首次安装。
  首例冷/温截图均已查看，恢复提示和 `ltty> a` 可见；不公开截图中的其他应用内容。
- 冷启动包 SHA-256：`649864e92485bdcf7e50b499a4d42c705501f6b6591cb879dd4ec521cabbec88`。
  温启动包：`33c55a5c6999ceca34254a9684ed4f269b19a1df7890e800b497156622c067ca`。
  二者是独立测试转换，不能当成同一签名包；生产源码在构建后按字节还原。
- 输出/内存使用未加启动、输入拒绝专项探针的普通 debug HAP：
  `a8953380f3f545a3161aedcf704fa27f7a1beec57a10b4bc83854c614e49f454`。
  它仍包含标准 debug acceptance hook，不冒充 production 包。

### 冷/温启动：各 20 个有效样本

| 区间（ms） | P50 | P95 | min–max |
| --- | ---: | ---: | ---: |
| 冷启动：图标点击 → 首字母 paint | 1492 | 1537 | 1443–1539 |
| 冷启动：图标点击 → Ability | 406 | 431 | 371–433 |
| 冷启动：Ability → content | 168 | 181 | 164–190 |
| 冷启动：content → Web page end | 463 | 482 | 456–505 |
| 冷启动：Web page end → prompt paint | 304 | 307 | 283–309 |
| 冷启动：输入注入 → 字母 paint | 84 | 89 | 72–89 |
| 温启动：图标点击 → 首字母 paint | 504 | 545 | 465–547 |
| 温启动：图标点击 → foreground paint | 349 | 391 | 330–395 |
| 温启动：输入注入 → 字母 paint | 76 | 85 | 66–86 |

报告为 `cold-unlocked/summary.json` 与 `warm/summary.json`。冷启动逐例验证旧进程不存在；
温启动逐例确认 PID 不变。统计区间不是可相加的各阶段独立 P95，也不是 GPU 扫描显示时间。
初始化记录中的 Durable initialized-read P50/P95 为 48/58 ms，**不是** workspace checkpoint
同步写盘耗时，不能据此改变异常恢复的落盘合同。

冷启动第一份物理 attempt `cold/` 在样本 1 前因系统锁屏停止，没有有效计时样本。已有开发
文档提供自动解锁路径，执行时却先要求维护者配合，是操作流程错误；后使用现有
`Start-LeanTTYRegressionApp` 和本机解锁凭据成功，再以同一 HAP 开始 `cold-unlocked/`。
未记录凭据内容，未覆盖失败报告，也未把锁屏失败补成通过样本。

### 连续输出：15 例完成，但指标解释有边界

`output/device-ssh-auth.json` 的五档透明度各三例全部完成，31 次受控远端命令均首次精确、
0 mismatch、逐字核对后单次 Enter；原 Medium 设置恢复，Preferences 比较及 cleanup 通过。
每例 fixture 生成 12,000 行，每行 80 字符加 CRLF，正文共 **984,000 字节**。

| 透明度 | BEGIN → render callback 全部值（ms） | min / median / max | END parse → callback 全部值（ms） |
| --- | --- | --- | --- |
| Off | 5548.6 / 5589.0 / 5460.4 | 5460.4 / 5548.6 / 5589.0 | 24.3 / 29.5 / 28.0 |
| Low | 5489.1 / 5565.5 / 5480.5 | 5480.5 / 5489.1 / 5565.5 | 19.8 / 28.1 / 19.6 |
| Medium | 5540.6 / 5843.5 / 5624.4 | 5540.6 / 5624.4 / 5843.5 | 29.6 / 23.7 / 31.1 |
| High | 5594.7 / 5612.7 / 5557.6 | 5557.6 / 5594.7 / 5612.7 | 27.7 / 18.2 / 18.6 |
| Extreme | 5621.4 / 5469.7 / 5867.9 | 5469.7 / 5621.4 / 5867.9 | 30.4 / 18.3 / 29.3 |

不采用报告中约 1 Mbps 作为最大吞吐，也不根据这些样本调整默认透明度：

1. fixture 的 Prepare 已发送 BEGIN，工具随后才输入、核对并提交 Run；`parseMs` 包含这段
   宿主调度间隔及服务端分块 5 ms 节流，不是解析器 CPU 用时。`paintMs` 终点是
   xterm `onRender` 后的 rAF 回调，不是硬件 GPU 时间。
2. `perf_stream_expected_bytes` 与 Web `countPerfPayloadBytes` **只统计填充字符 X**，不统计
   行号/前缀/CRLF。各档 expected=actual 分别为 696000、696000、660000、684000、648000；
   差异来自 case ID 长度。100% 只能证明 X 数量，不足以证明全正文完整或顺序正确。
3. 系统 `hitchs app0` 前后均为零，但工具未绑定 LeanTTY 窗口/采样总帧数，因此掉帧结果为
   **未建立有效归属**，不是“零掉帧”。本轮也没有负载中输入到 paint 的独立分布。
4. 未执行真实 WebGL context-loss 触发。代码中的初始化失败/context-loss → dispose → DOM
   refresh 路径可审查，但 ArkWeb renderer 进程重建的旧证据不能替代 WebGL context loss。

这是一项测量可信度发现，不是输出丢失、低吞吐或 GPU 故障的产品确证。后续应在测试侧
合并 Prepare/Run 的测量起点、校验全正文及序号，并建立独立输入终点；不要为修数字改生产
Bridge、关闭背压或降低 renderer。三例不计算 P95，也不继续累积同一无效指标。

### 内存：16 个观察点，覆盖 340.1 秒

先使用官方命令和实际设备检查：`hidumper --mem PID` 可用，`/proc/PID/smaps_rollup` 被拒绝。
没有修改权限、强制 GC 或导出 heap。依据
[华为鸿蒙电脑命令说明](https://consumer.huawei.com/cn/support/content/zh-cn16083991/)及
[OpenHarmony hidumper 字段说明](https://github.com/openharmony/docs/blob/master/en/application-dev/dfx/hidumper.md)，
本机 Total 含 SwapPss 和 graphics；观察器校验分类 PSS 之和加 SwapPss 等于 Total，并分别保留
GL/Graph、mapped PSS、SwapPss、RSS。不能重复加 graphics，也不能把 Linux proc 可用性想当然。
[Linux proc 文档](https://docs.kernel.org/filesystems/proc.html)用于核对共享页比例分摊的概念，
不代替本机系统列的语义。真实输出与四类格式反例共 5 项离线检查通过。

下表汇总同一应用主进程、GPU 和两个 renderer，单位 KiB；采集逐进程进行，每点约 2 秒，
不是原子全机快照。“含图形 PSS”是本机分类字段之和，不宣称跨进程 graphics 已全局去重。

| 阶段 | 含图形 PSS 合计 | 其中 GL/Graph | 排除图形的 mapped PSS | 主进程 PSS |
| --- | ---: | ---: | ---: | ---: |
| 原工作区空闲 | 384844 | 137704 | 247140 | 104811 |
| 单 Pane 输出后 | 432622 | 138876 | 293746 | 112977 |
| 双 Pane（仅一个 SSH Session） | 492579 | 161732 | 330847 | 114450 |
| 关闭新 Pane | 453262 | 138340 | 314922 | 116249 |
| 新增两个本地 Tab | 732702 | 396632 | 336070 | 121729 |
| 等待 35 秒自然 warm-Tab 回收 | 566791 | 267356 | 299435 | 110087 |
| 关闭新增 Tab，原 Session 再输出 | 454813 | 139352 | 315461 | 113345 |
| Session 关闭后 | 486346 | 138760 | 347586 | 116422 |
| 关闭后 35 秒 | 432182 | 139032 | 293150 | 110607 |

固定尾段六点的含图形 PSS 为 453357、433878、447499、438408、448551、447851 KiB；
间隔至少 30 秒，中间两次重复输出令实际尾段约 186 秒。没有为了等上涨或下降延长预算。
全程四个进程身份未变；新 Tab 的主要峰值在 graphics，关闭后有明显回落。最后仍高于初始
空闲约 46 MiB，且保留终端历史及 Web 缓存；短时序列不能区分这些保留与长期泄漏，不能说
“无泄漏”。没有测试多条活跃 SSH/Mosh Session 或持续内存压力。

`resources-fixed/resource-summary.json` 及 `device-ssh-auth.json` 通过，9 次受控远端命令
首次精确、0 mismatch，新增 Tab/Pane 撤销并保留原 3 Tab。known-host、fixture 进程、临时目录
及 reverse 映射清理通过；该轮未要求 Preferences digest，不能沿用输出轮的未变证明。

首个一次性 driver 使用 `&` 执行现有 verifier，初始化变量与函数内 `$script:` 更新落在不同
作用域，导致空 PID 被误报为“进程变化”，并遗漏 fixture Linux PID 清理。离线红绿测试证明
dot-source 才保持既有脚本 owner；修正仅在 ignored driver，不改变产品或常规 verifier。
失败目录 `resources/` 保留，专用 fixture PID/可执行文件及精确临时目录经只读确认后清理，
记录在 `memory-failed-run-cleanup.json`。新目录 `resources-fixed/` 完成单次修正版采样。

### 稳定性、收尾与剩余边界

当前源码的 `policy,tooling` 与 `ssh-flow,web,arkts` 聚焦组通过；后者含 ArkTS 202/202、
Mosh owner 10/10、实际 xterm 补丁及页面/背压合同。CQ-001/CQ-002 的真实拒绝、输出排空、
认证关闭、另一个 PTY 与原页恢复证据见代码诊断。网络/前后台/异常回收按原证据身份复用，
本轮没有重新切网、合盖或做正式矩阵，也没有用新的普通负载成功覆盖历史失败。

`round-summary.json` 统一保存统计、限制与最终源码哈希核对：165 个文件中，仅启动 source
转换及其测试两个工具发生预期变化，生产源码不变。结束时普通包重建、安装、启动成功，
HAP SHA-256 为 `053b1f78f327a9a93bf65eeaf6d774654bbfcc69517dd78d95b79c0c2b29afb3`；
native 仍为 `d9a7148098b6ca523ffd4663e7cd967919d542b8bc6f1ed490272d5c2a13c3a0`。
真实 HAP 的冷/温启动及输入拒绝专项标记扫描通过。新构建身份只作恢复普通包的记录，不
回填既有性能样本；没有产品优化、依赖更新、Git 提交、推送或发布。

优先处理 CQ-003，再补测量 oracle 和剩余命名场景；长期/内存压力、负载输入及实际 WebGL
失效回退仍未完成。没有证据支持改同步持久化、缓存期限、队列大小、透明度默认值或大拆类。
本轮观察到的计数/计时限制和新安全问题足以修订后续顺序，不需要继续重复整套已有采样。

## 2026-09-07 后续诊断边界

维护者授权日志分级修复并继续诊断。CQ-003 已通过实际发布模式产物隔离与命名真机主路；
CQ-004 的最终 pause/resume 丢失反例与最小 watch 修复见代码诊断。后续不重跑 40 次启动、
透明度全矩阵或 Wi-Fi；仅补未闭合证据。

输出 oracle 现在逐行比较公开 fixture 的前缀、序号、正文和 CRLF，覆盖 984,000 全字节，
并验证 xterm 公共 buffer 的可见尾行。BEGIN 移至 Run 紧邻负载，排除 Prepare → Run 人工/
工具输入间隔；计时仍含 fixture 的 5 ms 分块节奏、传输、解析、观测及下一帧，不冒充纯
renderer 或生产吞吐。新增探针的 CPU 成本单独记录，不能以其数字直接断言生产瓶颈。

负载输入通过 xterm 公共 `input` API，复用 onData → Bridge → native SSH → fixture 回显 →
write callback/onRender/下一帧；每组最多 20 个公开 `?`，不按 Enter，末尾 Ctrl-C 清理。
这些回显单独计数，负载正文仍必须逐行精确；fixture 在此类样本采用明确的 50 ms 分块节奏。
不包含硬件键盘/IME，不把下一帧回调描述成光子级显示时间。依据是
[xterm 公共 API](https://xtermjs.org/docs/api/terminal/classes/terminal/)，不是私有 renderer 补丁。

第一轮 driver 缺少报告函数导入：第一例完整输出已通过，写报告才失败。工具错误被通用
verifier 误分为 product；审计分类为 harness，原证据不改写。补显式导入与无设备预检，只
复用已完成测量并执行剩余项，没有重跑第一例。`renderer/` 与 `renderer-fixed/` 均保留。

第二次停止发生在 WebGL 验收时机：本地锁定 addon 的 `WebglRenderer.ts` 明确等待
3000 ms 的恢复宽限后才发 `onContextLoss`；旧检查在约 408 ms 就要求 DOM，属于测试
假设错误。恢复原目标为“真实失效后按现有事件链回退并继续输入/输出”，等待该通知后再
验证 DOM 新负载。保留此前 6 例完整输出/负载输入，不修改或绕过上游 3 秒合同。
失效期间的 onRender 不是有效像素证明，那一例不进入正常 paint 分布。触发依据为
[Khronos WEBGL_lose_context](https://registry.khronos.org/webgl/extensions/WEBGL_lose_context/)。

长会话固定为两条 SSH、两个额外本地 Tab，600 秒尾段、每 60 秒观察一次，按固定索引重放
负载并关闭恢复。预算在运行前冻结，既有 fixture/awake 租期覆盖 setup/cleanup；不强制 GC、
不耗尽整机内存、不为等待趋势延长。它是有界多 Session 资源压力诊断，不是无限期无泄漏
或 OS OOM 保证。同步 checkpoint 仅在专用包直接计时 put/encode/flush，最多 100 条，1 ms
时钟分辨率；不改变持久化语义，源文件在构建后逐字节还原。

### 本次有效样本与停止结果

以下证据均位于 `build/verification/diagnostic-logging-isolation-20260907/`，不是正式候选
验收。`renderer-fixed/renderer-summary.json` 整体仍为 failed；只提取失败前已完成的
独立样本，不改写原报告结果。3 例正常输出和 3 例负载输入均为 984,000 字节、12,000 行，
前缀/序号/正文/CRLF 零 mismatch，公共 buffer 可见尾行吻合。

| 场景 | 有效数量 | 观察结果 | 不能推出的结论 |
| --- | --- | --- | --- |
| WebGL 正常输出 | 3 例 | Run → 下一帧 399.4、406.6、402.7 ms；观察器自身耗时 57.6、58.0、61.2 ms | 含分块节奏和探针开销，不是生产纯 renderer 吞吐或优化收益 |
| 负载中输入/回显 | 3×20 个公开字符 | 全部发生在负载中；每组 P95 50.5、53.2、51.8 ms，合并 P95 52.7 ms，范围 16.9–53.8 ms；无 pending 回显 | 不含真实键盘/IME，也不是历史自然丢字的归因或无缺陷证明 |
| 实际 WebGL context loss | 1 次窄场景 | 标准扩展触发后收到 `actual=dom, fallbackReason=context-loss, contextLossCount=1` | 回退后新输出未完成；失效期间帧回调不计入正常 paint 分布 |
| RenderService hitch/fps | 只读核对 | 本机 help 支持 `app0 hitchs` / `app0 fps`；前者累计零，后者无帧记录 | 缺少采样覆盖和应用窗口到 RS 节点的身份绑定，结论为 unavailable 而非无掉帧 |
| 长会话资源 / checkpoint | 未执行 / 无有效样本 | 600 秒固定预算 driver 已做无设备预检；checkpoint 样本数组为空 | 不报告无泄漏、无卡顿或零写盘成本 |

`context-fixed/context-summary.json` 保留 `fallbackObserved=true`；该场景整体 failed 的
直接原因在 `device-ssh-auth.json` 中归为 harness：输入下一条准备命令后，目标的
accessibility ID、层级和 bounds 改变，helper 因身份合同不满足而拒绝 retry/Enter。
前后仍有唯一焦点，窗口、输入类型和 hint 相同；这些事实既不足以授权自动继续，也不能
证明输入去了错误 Pane 或产品丢字。原始 layout 本地保留，不在报告转录终端正文。

原目标是证明回退后同一终端可用，不是让 UiTest 节点 ID 永远不变。下一轮先在已有证据
上区分真正目标改变与渲染树重建，建立 owner 层的最小判定测试，再决定工具修复或直接
oracle。此轮已依次遇到 driver 导入、上游 3 秒宽限误解及目标身份问题；继续补旁路会
增加测试复杂度，因此按异常暂停约定停止，不取消输入保护、不进入资源/Mosh 矩阵。
两次 renderer/context 场景的 fixture、known-host、reverse 和临时进程清理通过。

### 源码、软件门与普通包恢复

普通 debug 包只保留被动、有界性能观察；自动公开字符输入和主动 context-loss 的
`perfActiveActionsEnabled` 默认关闭。专用 fixture 构建才临时打开，构建后还原源文件；
远端输出不能在普通开发会话中授权自动输入。结束标记后的 prompt 不进入已完成的负载
结果；default-off 和 closed-frame 两个边界均有实际注入模块测试。

最终 `software-final.json` 为 `policy,tooling,web,arkts,rust-native` 全通过，含真实
owner 的 production → debug → production 隔离、native 53 项及专用触发 2 项。
此前 `software-oracles.json` 的 `ssh-flow,arkts,ssh-fixture` 通过；保留中途失败，
不将聚焦软件证据提升为完整发布门。没有修改 `mosh-client` 版本、提交或推送 Git。

测试机已重建、安装并启动普通 ARM64 debug 包，SHA-256 为
`ac40718c95315c4347089494b4ee81d8bffb46547a291100817cfe7d94c29150`。实际 HAP 证明主动
输入/context-loss 为 false，checkpoint、启动和 Mosh 输入拒绝专项标记不存在；源文件也
已还原。测量包 `9d978adee577900a05f114d52c8c5614f93fb89cd0776509a4ba5f322c52d2c6`
保留原身份，不把最终探针防护改动回填到旧物理样本。

native 打包前 SHA-256 为
`bcc4abd4926590c2aed7803d8f13d16ee3194b573c2891835f30f9efc2e968cd`；三份实际测量/
release-mode/最终普通 HAP 内 native 均为
`a99059f691e8bd4a3b68878aae56d31d872c9d25c98c965a24635aef7177d37a`。两类哈希不是同一
产物，不相互代用。收口脚本首次将其混比而失败，核对实际三份 HAP 后分别记录，未重建
或重跑物理样本。安全汇总为 `round-summary.json`，整体状态为
`paused-harness-target-identity`，不是诊断全部完成。

## 2026-09-07 续轮：输入目标归属

维护者授权按停止记录继续。预期是同一终端在 DOM 回退后仍可输入；不是要求 Web
无障碍子树路径不变。最后正确边界为实际 DOM 回退通知；首个错误判定在
`Invoke-LeanTTYDeviceText` 的 post-input 比较。该 helper 把输入框完整 hierarchy 当作
owner，虽允许光标 bounds 和 opaque ID 改变，却不允许同一 Web 内容器层级改变。
旧报告显示路径变化位于原生 Web 之下；保留的三份相邻布局有同一 Web 路径和非空
accessibility ID。post-input 原始临时布局已删除，旧报告不能单独证明该时刻 Web 未替换。

2026-09-07 外部核对：[OpenHarmony UiTest 源码](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/core/ui_model.cpp)
的 `WidgetHierarchyBuilder` 用 parent + child index 构造路径；
[UiTest 命令说明](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)
区分坐标 inputText 和当前焦点 text，未承诺虚拟节点跨重建身份稳定。
[xterm 输入框源码](https://github.com/xtermjs/xterm.js/blob/master/src/browser/input/CompositionHelper.ts)
与本地锁定 6.0.0 的 `_syncTextArea` 均随光标更新 textarea 位置。
[Playwright locator 实践](https://playwright.dev/docs/locators)支持按稳定语义重新定位，
仅作设计参考，不能证明 HarmonyOS 行为。华为开发社区/上游问题搜索未找到与本次
“WebGL 回退后少一层 genericContainer”一致的已确认报告；不推断为平台已知缺陷。
上游 master 的新 UiTest 特性不套用到本机 6.0.2.3；目标平台仍为 ARM64 HarmonyOS PC。

最小假设：原生 Web owner 不变，仅其虚拟输入子树重建。修复拟在同次串行输入的前后
完整布局内验证同一原生 Web（非空 window、hierarchy、accessibility ID 一致），且该
Web 内只有一个终端输入框；其他文本框保持旧规则。跨 Pane、窗口、Web 替换、多个
终端候选仍失败，不接受“同窗口即可”。先在实际 helper 建立红绿测试，再复跑窄 context
场景，用真实后续命令与输出证明假设；若原生 Web 也改变，停止并保留原始边界，不降级
保护或追加时间重试。仅选择 L0/L1 tooling 和命名 L3，正式矩阵、已有启动/输入分布不重跑。

红绿已完成：同一 Web 内虚拟路径重建的实际 helper 测试在旧实现失败；新实现通过，
跨 Pane、Web 实例替换、窗口变化、Search 夺焦、多候选及原有重叠 bounds 负例均拒绝。
`diagnosis-continuation-20260907/software-owner.json` 的 policy/tooling 通过，含
命令 exact-before-single-Enter 和失败后不重试的既有测试。

同目录 `context-fixed/device-ssh-auth.json` 的实际窄场景通过（116.6 秒，含 setup/cleanup）：
收到 DOM 回退通知后，`domafter01` 完成 984,000 字节/12,000 行、零 mismatch、可见尾行
匹配，之后 `afterdom` 新命令通过；6 条连接命令均首次 exact、0 mismatch、每条一次 Enter。
本地截图确认回退后的尾行和 fixture prompt 可见，原图只作本地证据，不直接对外发布。
Preferences 未变，known-host、reverse 和 fixture 进程清理通过。该结果闭合回退后可用性，
不是所有虚拟树变体或自然键盘无丢字的保证。

本次专用 ARM64 HAP SHA-256 为
`c6ef3b9c3d0cacad855cb9f9ad6dcddb106814761024ef7b46500b1a97e318ce`，使用上一轮相同
native；新包采用已通过软件测试的结束帧边界，并仅在此 fixture 构建打开有界主动触发。
构建后 checkpoint 和探针源码已还原，后续物理样本保留此包身份。

### 续轮：受影响 native 集成验证

同一专用 HAP 的 `mosh-surface/device-mosh.json` 通过（184.4 秒）：受控 Surface 重建后
Mosh 页面保留，同一远端 PTY 可执行新命令，随后认证关闭并恢复原页面。
`mosh-isolation/device-mosh.json` 通过（358.6 秒）：两条 Mosh 的 server/密钥各自独立，
输入输出不串 Pane，关闭一条后另一条可用；SSH/Mosh 混合时也通过输入输出隔离和
“关闭 Mosh 后 SSH 继续执行”。12 条受控本地命令首次 exact、零 mismatch，均单次 Enter。
两项的 Preferences、fixture、临时 reverse、目录及设备状态清理通过，未修改持久网络。

这些结果验证 CQ-004 修复后的真实编译/回调/渲染/关闭集成链。队列 Full 的最后 resume
反例及修复、Closed 行为和后续状态更新由实际 N-API 的确定性软件测试证明；本轮没有
取得真机自然饱和或 pause 振荡的轨迹，不能把集成通过改写成所有异步交错覆盖。没有
为了制造 L3 饱和再加生产触发器，也没有重跑 Wi-Fi、合盖或完整稳定性矩阵。

### 续轮：固定资源预算与 checkpoint

`resources-fixed/device-ssh-auth.json` 和 `resource-summary.json` 均通过。两条 SSH、双
Pane、两个新增后关闭的本地 Tab，固定 600 秒尾段实际 601.7 秒，11 个尾段点保持同一组
4 个 app/renderer/GPU PID；观察以 PID 集合核对，未声称 start-time 级身份保证。八组
输出各为 984,000 字节、12,000 行、零 mismatch，逐字顺序和可见尾行均通过。右侧关闭后
左侧仍可执行新命令，随后关闭左侧，保留关闭后 35 秒观察；未强制 GC、注入 OOM 或
延长预算等待好趋势。原 3 Tab 结构恢复，额外 Tab/split 为零，Preferences 和清理通过。

下表按同一 `hidumper --mem` 口径汇总 4 进程，单位 MiB；“含图形”是分类 PSS 加 GL/Graph，
不是进程 RSS，也不是纯 JS 堆，不能与其他产品的 Task Manager 数字直接比较。

| 观察点 | 含图形合计 | 排除图形的映射 PSS | GL/Graph |
| --- | ---: | ---: | ---: |
| 连接前 | 377.0 | 242.5 | 134.5 |
| 新增两个 Tab 峰值 | 739.1 | 333.3 | 405.8 |
| 超过 warm 保留期 | 610.6 | 330.4 | 280.1 |
| 尾段开始 | 494.1 | 339.5 | 154.5 |
| 尾段结束 | 452.5 | 314.1 | 138.4 |
| 会话关闭后 35 秒 | 460.8 | 324.7 | 136.1 |

全部 11 点和进程明细在 `round-summary.json`，不只保留上表选点。尾段第 1–10 分钟含图形
合计在约 451.4–458.6 MiB 波动，没有持续单调增长；图形峰值回落。关闭后比初始高约
83.7 MiB，映射 PSS 也未回到起点，不能宣称无泄漏或全量释放。现有存活工作区、scrollback、
ArkWeb 缓存和短观察窗口均影响解释；没有堆归因证据，不把差值直接定为泄漏或有益缓存。
本轮未证明用户可感知的持续增长，因此不改 30 秒 warm 策略、scrollback 或队列预算。

checkpoint 原采集数组为空的原因已定位到工具：通用应用日志 helper 的 tag 列表不包含
`UnexpectedExitRecoveryStore`，不是所有写入都耗时为零。未修改正在运行的 fixture，
用三次只读、限定当前 app PID 和该 tag 的补充查询提取数值；不保留原始正文，也不发输入。
两个独立 fixture 日志清理窗口取得 `[0,3]` 和 `[0]` ms，关闭后查询无有效样本。原空数组
和三份补充报告均保留，汇总总数为 3，min/median/max 为 0/0/3 ms，时钟分辨率 1 ms。
样本少且机会性采集，不计算 P95、整体发生率或完整写入频率，0 ms 不代表零成本。
这只能说明已观察到的三次同步写入没有显示高价值阻塞；不足以削弱异常恢复耐久性。

### 续轮收口与恢复

本轮采用的是有红绿反例支持的输入工具 owner 修复，没有新增产品优化、依赖、设置或
状态层。资源和 checkpoint 选择保留现状；重新进入需要真实退化、可复核持续成本或相关
源码变化。有效窗口 hitch 分母、长期无泄漏、OS OOM 和同系统 1.5.1 对比仍未取得，不
把这些缺口写成通过，也不为追求“全部诊断”无限添加探针。当前按有界诊断范围进入文档
收口，正式完整矩阵仍须绑定之后的精确候选。

安全汇总 `diagnosis-continuation-20260907/round-summary.json` 为
`named-diagnostics-passed`、`acceptanceEligible=false`。四份报告的原 schema 不同：SSH 用
`candidate.sha256`，Mosh 用 `candidate.hapSha256`；汇总已按对应字段核对同一测量 HAP，
没有改写原始报告。软件证据 `software-owner.json` 的 policy/tooling 通过，上一轮同一
native 的 53 项和专用触发 2 项仍保留原证据身份。源码之外的收口检查曾误查默认探针的
转换脚本，已改为核对真正的 JS owner；没有因此改变产品或重跑物理场景。

普通 ARM64 debug HAP 已重建并通过实际包扫描，SHA-256 为
`90ab83422ef87a2767b2416bf855b2461d8a77b1c1a6c0adc402ba3b30b7dac8`。主动输入/context-loss
为 false，checkpoint、启动和 Mosh 输入拒绝专项标记不存在；源码也已还原。包内 native
仍为 `a99059f691e8bd4a3b68878aae56d31d872c9d25c98c965a24635aef7177d37a`。原构建输出
未完整保留安装结尾，收口只对该留存普通包执行一次 `-SkipBuild` 安装/启动确认，通过；
未重建第二次。`final-package-audit.json` 与 `ordinary-restoration.log` 分别保留包和设备
证据。此前留存 release-mode test-signed HAP 的全标记扫描也再次通过，不是 production
签名或正式审核包。所有本地证据留在 ignored 目录；没有提交或推送 Git。

收尾再次运行输入 helper 回归和 `git diff --check`，均通过；四份本轮文档的本地链接
目标检查通过。最终记录见 `final-checks.json`，不包含新的物理场景或正式软件全门。

## 2026-09-07 诊断后精简

维护者批准消除两项确定无用的工作：普通 SSH/Mosh 的额外观察解码，以及 Mosh 首次
连接成功后的 100 ms 状态轮询。Keypush 和开发 ping 保持独立、有界的分块解码，Mosh
协议计时器、reachability 和关闭合同未改。没有引入依赖、缓存策略或统一 Transport。

新 ARM64 debug 包的 Keypush、SSH 主路径与 Mosh 固定端点均通过，原字节输出、认证
关闭、原页面恢复及清理有独立证据；精确身份和结果见
[代码质量诊断](code-quality-diagnosis-1.6.md#新包真机结果与收口)。这是删减后的正确性
回归，不是新一轮性能采样。旧包的启动、内存、输入延迟数字不能转标成该包的测量结果；
本轮没有前后对照，故不声称 CPU、功耗或用户可感知时延改善。

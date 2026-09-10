# MCRS-009：合盖后 PermissionDenied 结束 Session

> 2026-09-10：上游修复已合并；真实合盖工作区恢复通过，同一 Session 的错误恢复仍缺真机证据。

一次 HAD-W32 / OpenHarmony-6.1.1.135 真机诊断确认：已连接的 Mosh Session 在合盖后
收到 PermissionDenied，随后才退到本地 IDLE。依赖是 GitHub v0.1.0，完整 revision
`aed5865c1d779a989a3b0cf0c84aa046313515ee`；远端是 WSL stock mosh-server 1.4.0。

## 证据

- 合盖前受控命令一次输入、一次 Enter，server 验证通过。
- 01:26:30.479（UTC+8）：主窗口不可见，workspaceBinding=retained。
- 01:26:31.411：generation=1、connected=true、closing=false、source=transport、
  stage=mosh_udp、nativeCode=network、ioKind=PermissionDenied。
- 01:26:31.414：SessionViewModel 处理 Mosh error，结束临时页面并进入 IDLE。
- 开盖后 PID/startticks 未变、runtimeRecovery=not-required；恢复输入前远端 shell/server
  仍存活。恢复文字进入本地，Enter 未发送。

场景历时 275225 ms，失败重现，fixture、设备状态、reverse mapping、临时目录全部清理通过；
持久网络未改。额外主机/设备日志读取进程均已停止并核对不存在。没有第二次合盖或模型请求。
证据：`build/verification/mosh-lid-diagnosis-20260910/` 下的 `reader-v2.log`、
`device/device-mosh.json`、`identity.json` 和 `reader-cleanup.json`。

## 归因限制

source=transport 表示 native close 回调先到，不代表 UDP 发送/接收方向。库只提供
ErrorKind，不能直接把它写成 EACCES，也尚未确定系统策略。MCRS-003 已验证的四类临时
send 错误不含 PermissionDenied；接收路径也会传播 I/O error。本次新证据不推翻此前
WLAN 修复，也不授权在 LeanTTY 重建 Session 或绕过权限。

诊断 HAP：`9f72b112fbf8db36617a7b641e54f269126e1ce7c3a948123143ad7e27dcbb86`。
内置 native：`c1a1257359cbeefac79bb100b0abe866bbfbf0935f377b9eebd2f03c0266afbc`。
基于 LeanTTY `adf6529`，只改 ArkTS 错误元数据和测试，复用开发目录 native 缓存。
旧 C2 内置 native 为
`0b5e4509fa649a1e3d0334cdeb637423ae60fba70ed202dcbdbf22adc2186b63`。
两者不是同 native 字节的单变量对照；旧正式失败没有 ErrorKind，不能倒推其原因相同。
旧 C2、冻结源码和正式失败报告经审计未变。

## 已交接的工作

用户要求直接交另一个任务执行，已发送到此前修复 MCRS-003 的「梳理项目架构与测试方案」
（`01a04c96-e679-7361-af12-6857ca2eef09`），已确认任务 active。

要求库侧先用区分性回归核对 PermissionDenied 的安全恢复范围，再做最小修复；
保留首次连接失败、无忙循环、永久拒绝、输入排序、最终输出、双 Session 隔离、
即时 cancel 和四秒 close 上限。不得修改 LeanTTY、发布新版本或重写 v0.1.0；
完成后回传准确变更、API 影响和一次命名真机复跑要求。

LeanTTY 的错误来源/脱敏/旧事件测试 16/16，通过 policy/arkts 六项定向检查和 ARM64 构建。
这些是诊断工具证据，不是问题修复或正式验收。诊断修改留在独立开发分支
`codex/diagnose-mosh-lid-exit`，未提交。活动待办仍由 [Next Work](../next-work.md) 管理。

## 上游修复与接入检查（2026-09-10）

库侧已将修复合并到 GitHub main：
`ae86bfea2da48ddfe36e7c29882e72be144f3327`。已核对生产差异集中于
Session driver；公共 API、依赖清单和包版本不变。已建立 Session 的 send/recv
PermissionDenied 使用既有 RTO 限速重试，保留原 socket 和协议状态；
首次连接及未知 I/O 错误仍失败。库侧将其记录为 MCRS-003 的补充，
设计见上游 ADR 0012；具体收发方向和 HarmonyOS 策略仍未证明。

LeanTTY 仅在独立开发目录临时固定这个完整 revision，从 GitHub 获取依赖，
没有使用本地库或追踪 main。最终锁文件只变更 Mosh 来源；policy/rust-native
七项检查通过，包含 56 项 native 测试及 2 项输入拒绝隔离测试。
强制重建 ARM64 native、签名测试 HAP，并完成真机安装和基线命令验证。

保留的诊断 HAP SHA-256：
`1a3986dafb3595239b2e13f50cf93abc724652a1918f1b03b7ba2c7406b44c84`。
内置 native SHA-256：
`f7d567db8a8e7e879a2ca997303885ee282340786dad783225090029c51a9cce`。
主工作区证据为 `build/verification/mosh-lid-ae86bfe-20260910/`：
`identity.json`、`software-final.json`、保留 HAP、诊断 Cargo 输入和构建日志。

## 本次真机场景未完成

同目录 `device/device-mosh.json` 记录 attempt
`cbaea448b4214bd9882e55a23fd8e36b`，总耗时 455273 ms。
34 字符基线命令一次输入、一次 Enter，远端精确匹配；
随后 300 秒内未观察到要求的合盖边界，按 environment 超时停止。
提示音和语音使用系统默认设备。没有第二次尝试。

`physicalLidExercised=false`、`recoveryOutcome=not-run`，
不能据此确认或否定修复。恢复后 PID、PTY、命令和关闭字段未执行；
初始化为 false 的字段不是进程替换或远端死亡证据。

失败清理首次本地命令未能定位输入（0 次注入），已有 app-relaunch 兜底后，
设备状态、fixture 进程、reverse mapping、临时目录清理全部通过，持久网络保留。
因此 automation 汇总保留 failed-harness，不能称为全链路稳定通过；
这不是输入丢字证据。额外日志读取进程也已停止并独立核对不存在。
未运行本场景后段的完整 secret/Preferences 验收，不将默认 false 解释为泄密。

诊断结束后 Cargo.toml/Cargo.lock 已恢复原 v0.1.0 tag 依赖；
修复包及其准确输入另行保留，测试机仍安装该诊断包。尚未接入新的正式库版本，
未提交 PR、创建新候选或续跑正式矩阵。下次先确认维护者能配合合盖，再使用同一
保留 HAP 补一次命名验证；发布依赖仍须按版本接入，产品依赖改变后正式验收选 R4。

## 维护者就绪后的真实合盖（2026-09-10 22 时）

复用上述 HAP，SHA-256 和系统 OpenHarmony-6.1.1.135 经复核一致，没有重新构建。
第一条准备 attempt `a6028ddf3c53423bb8bf69b093c93471` 在启动时连续两次
得到空布局，51969 ms 后 environment 停止；尚未连接 Mosh、未合盖。
原始空布局和清理记录保留。已有 app-relaunch 清理兜底通过后，
复查得到正常布局、唯一且聚焦的终端输入；没有修改产品或验收工具。

从已确认可操作的状态重新准备，attempt
`ba3d18fb4a8148a08224d91f591cf7cd` 完成一次真实合盖：
`operator-lid-recovery` 通过，耗时 238954 ms，最终场景 automation 为
passed/stable。该状态只描述这次完整场景，不抹去前一次准备失败。
证据位于主工作区 `build/verification/mosh-lid-ae86bfe-20260910-ready/`：
首次 `device/device-mosh.json`、成功场景
`device-after-readiness/device-mosh.json`、`reader.log` 和 `final-audit.json`。

本次观察到的是进程替换后的工作区恢复，不是同一 Session 恢复：

- 合盖前 34 字符远端命令一次输入、一次 Enter、精确匹配。
- 22:03:16.581 主窗口不可见且保留 workspace binding；
  22:03:17.386 旧进程收到 EntryAbility.onDestroy。
- 开盖后 PID 与 /proc 启动时间均改变，远端 shell/server 当时仍活着。
- 恢复警告可搜索、旧远端命令不可搜索，没有自动创建替代 Mosh Session；
  本地 `help mosh` 一次输入、一次 Enter 成功。
- Preferences 摘要不变、已配置的 secret-pattern 审计通过；设备状态、远端 fixture、
  reverse mapping、临时目录清理通过，本次不需 app-relaunch 清理兜底。
  额外日志读取进程停止，独立审计数量为 0。

`recoveryOutcome=client-process-replaced-workspace-only`，
`sessionStayedConnected=false`。报告中的 `recoveryCommandPassed=true`
在此分支指本地命令，不是同一远端 PTY 上的新命令。
87596 ms 的操作窗口包含人工响应和解锁时间，不是测得的实际合盖时长。

没有再次合盖来追逐另一条系统分支。旧进程的连续记录没有捕获 PermissionDenied；
补充销毁原因快照没有返回匹配信息，具体终止原因仍未知，不能排除或断言某种系统策略。
本次支持异常结束后工作区恢复的既有合同，不能单凭它关闭同一 Session 的
PermissionDenied 真机验证缺口；库侧错误注入回归与该物理结论分开保留。

GitHub 最新正式 Release 仍是 v0.1.0（本次只读核对）。下一步按 Next Work 接入包含修复的
正式版本，再以新候选执行 R4；不得续接旧 C2 前缀或把本次诊断升格为完整 C3。

## 0.1.1 正式版本接入（2026-09-10）

维护者随后授权上游发布 [v0.1.1](https://github.com/wandcs/mosh-client-rs/releases/tag/v0.1.1)。
上游回传完成后，LeanTTY 独立核对非草稿、非预发布 Release、tag 和下载附件：

- tag 对应提交 `dfc188975ed0a8bd734bbf14bd6cfdeb3838e629`；
- `mosh-client-0.1.1.crate` 为 211571 bytes，下载后 SHA-256 为
  `db24ec691186bb02050aade55b24753ff0fff7b653c4986860151078e51fd34c`，与 SHA256SUMS 一致；
- 相对 `ae86bfe` 修复提交，生产 `src/` 没有变化，只有版本和发布材料更新；
- 公共 API、依赖版本、协议和资源上限不变，许可证为 MIT OR Apache-2.0，MSRV 1.88。

LeanTTY 使用 GitHub `tag = "v0.1.1"` 加精确 `version = "=0.1.1"`；
Cargo.lock 只更新该包的版本与来源。此版本未发布到 crates.io，不改用 registry 或本地路径。
主工作区与独立修复副本的 Cargo 输入和当前依赖文档字节一致，其他主工作区变更保持原样。

定向验证在 `build/verification/pr-slices-20260907/checkout` 执行，基于
`adf652929917d2b5e6389b2a3a14f51321e37b95` 加本轮依赖升级和安全错误元数据改动。
证据位于主工作区 `build/verification/mosh-client-v0.1.1-20260910/`：

- `cargo fetch --locked --target aarch64-unknown-linux-ohos` 及随后离线 metadata 通过；
  181 个 registry 包、1 个 Git 包，全部有许可证信息，见 `dependency-audit.json`。
- `test-regression.ps1 -Group policy,arkts,rust-native` 的 11 项检查通过，包含
  16 项 Mosh owner 合同、56 项 native 测试和 2 项隔离触发测试，见 `software.json`。
  `test-device-regression.ps1` 的版本合同及 helper 检查通过。
- `dev-pc.ps1 -RequireUsb -ForceNative -NoDaemon -Offline` 重建 ARM64 native、
  测试签名 HAP、安装和启动通过。保留 HAP 的 SHA-256 为
  `eba559c4ce8dc81cfd1462944bd7ea3b01c77cbdbc1b27dbbf3701f955eac9b9`；
  包内 native SHA-256 为
  `c83c6b6401fc0d5a63c7df7b759e704a8a826b40cfe8af3a9598ecf0e0620a24`。
  `identity.json`、`source.patch` 和 `dev-pc.log` 保留构建来源；该包是 dirty-source
  常规诊断包，不是正式候选。

### 新包真机主路径与报告缺陷

同一保留 HAP 的 `pause-recovery` attempt `1e88ad3e80864296bf8550a32dfc5439`
历时 151939 ms。原始 `device/device-mosh.json` 返回 passed/stable：
9 次本地命令均一次输入、一次 Enter、零不匹配；两条远端命令分别为 34/35 字符，
均经服务端精确比对后提交。UDP 双向阻断约 6.6 秒后，同一受控 PTY 执行新命令，
认证关闭、原页面恢复、Mosh 历史隔离、Preferences、secret-pattern 审计和清理通过。
没有再次合盖、切换 WiFi 或调用模型；不证明 PermissionDenied 的真机恢复。

复核发现原报告有工具缺陷，**不能将整组摘要采用为完整通过证据**：
`interruptionObserved=false`、`recoveredStatusObserved=false`，
而两个 `Wait-LeanTTYAppLog` 状态等待已返回；保存的 network 日志仅一个换行。
最后正确边界是状态等待，首个错误边界是随后不带参数调用的
`Get-MoshLifecycleObservation`。该函数以 `[string]$Logs = $null` 声明默认值，
却用 `$null -eq $Logs` 决定是否查询日志；默认值已变为空字符串，查询分支没有执行。

一次只读、host-only 的真实函数提取复现确认：默认调用的日志读取计数为 0，两个状态
为 false；显式传入包含中断/恢复标记的公开测试文本后，两者为 true。
见 `observation-owner-repro.json`。空快照也使 closed/error 返回 false，因此本轮
不采用“没有自动错误/关闭事件”的负向结论；服务端新命令、页面指纹和清理的独立证据保留。
这不是 Mosh 0.1.1 的产品失败，也不是已经修复的验收工具。

本轮没有修改观察器、覆盖原报告或重跑场景。升级源码已保留，尚未提交/合并本轮 PR；
下一步按工具研究门修复并验证观察器，再合并修复批次和准备 R4。
所有旧候选、合盖记录及正式失败保持原身份；任务顺序只在 Next Work 维护。

### 2026-09-10 验收观察器修复前研究与验证计划

目标是让结构化结果忠实反映已经获取的设备证据，不改 Mosh 产品合同或重试策略。
本机 PowerShell 7.6.3 的真实函数复现已区分根因：日志等待成功，默认观察器却没有调用
读取边界。责任 owner 是 `Get-MoshLifecycleObservation` 的参数绑定判断，不是 HiLog、
ArkTS 或 Mosh 库。下一项最小反例要求默认调用恰好查询一次；显式快照不查询；空快照
不能生成 closed/error=false 的成功观察。

当日外部研究结论：

- [PowerShell 团队的参数绑定说明](https://devblogs.microsoft.com/powershell/checking-for-bound-parameters/)
  推荐用 `$PSBoundParameters.ContainsKey()` 区分省略参数与显式传值。
  [上游 #4616](https://github.com/PowerShell/PowerShell/issues/4616) 描述了 `$null` 到
  `[string]::Empty` 的转换，与本机反例一致；不需要修改系统或引入依赖。
- [华为 PC HiLog 命令说明](https://consumer.huawei.com/cn/support/content/zh-cn16083991/)
  及 [OpenHarmony HiLog 文档](https://github.com/openharmony/docs/blob/master/en/application-dev/dfx/hilog.md)
  将 `-z` 定义为有限缓冲区尾部读取，`-r` 为清空。已匹配的状态快照应直接用于判断，
  避免丢弃后再查询；恢复后仍补读命令完成时的日志，保留晚到错误。非空快照也不是完整
  生命周期账本，最终仍由同一远端 PTY、新命令、页面恢复和清理交叉验证。
- [Playwright 的有界状态断言](https://playwright.dev/docs/test-assertions) 是可比工具模式：
  重试观察条件，而不是重复具有副作用的操作。本次不新增输入重试、采样或测试框架。
  鸿蒙社区检索未找到与该 PowerShell 绑定缺陷相同的报告；日志过滤问题不足以推翻本地
  已定位的错误边界。原研究 CLI 未配置凭证，使用现有网页检索完成，无账号或环境改动。

修复限定为绑定判断、空快照失败和命名网络场景的快照消费。旧进程回收后可选诊断日志
缺失时保留 null/unknown，不阻断已有工作区恢复合同，也不将缺失当作无错误。
先运行真实函数提取的 host-only 红绿反例及 policy/tooling；再用相同保留 HAP 复跑
UDP 暂停、WiFi 暂停和服务端消失三个受影响场景。首个失败停止，不合盖、不重开输入
调查、不重建产品包。旧 attempt 和 `final-audit.json` 保持不变；新报告独立绑定来源。

### 观察器实现与软件回归

观察器改用 `$PSBoundParameters.ContainsKey('Logs')`：省略参数时恰好读取当前目标/PID
一次，显式快照不再查询设备；null、空串或纯空白均抛出 harness 错误。三个网络场景
直接解析等待函数捕获的快照；恢复后再严格读取一份新命令完成时的日志，与中断、恢复
快照一并保留。晚到 close/error 不会被已恢复标记掩盖。旧进程日志缺失只使可选诊断
字段为 null/unknown，实际工作区恢复仍由原有直接状态检查决定。

新增测试从真实脚本 AST 提取观察器及调用分支，仅替换设备/fixture 边界，没有复制
生产解析器。修复前 16 个 owner 反例中 11 个失败、5 个通过，证明缺陷存在；修复后
扩展为 29 项，全部通过，包括快照滚动、恢复后日志缺失、晚到终止及旧进程缺失。
新测试已接入 `test-device-regression.ps1`。观察器修复没有改动产品代码、依赖或日志采样。

证据目录为主工作区 `build/verification/mosh-lifecycle-observation-20260910/`：

- `red.json`、`green-owner.json`、`green.json` 保留红绿验证。
- `software.json`：policy/tooling 的 7 项检查通过。
- `arkts.json`：4 项检查通过，含 16 个 Mosh owner 合同、202 个 ArkTS 测试、生产/开发
  诊断隔离；ArkTS 47 条警告仍保留，不宣称零警告。
- 一次额外直接执行 `test-mosh-client.cjs` 漏传 TypeScript 路径，在测试开始前报参数
  错误；随后由上述 arkts 注册入口完成验证。未修改产品来适配该调用错误。
- `identity.json`、`source.patch`、新增测试快照绑定 dirty harness 和原 0.1.1 HAP。
  本轮 MoshClient 源码 SHA-256 与该 HAP 的已记录构建输入一致，未重建/重签 HAP。

主工作区只同步对应修复；其原有分支及其他积累变更保留。提交与合并仅使用独立开发
clone，不把主工作区描述为干净或已与远程整体一致。

### 相同 0.1.1 HAP 的三组定向真机复跑

2026-09-10 晚依次执行 `verify-mosh-pc.ps1 -Scenario <下表场景>`，均显式传入原保留
`LeanTTY-test-signed.hap` 的 `-HapPath`，分别使用上述证据目录的 `pause`、`wifi`、
`server` 子目录作为 `-EvidenceDirectory`。UDP 复跑还记录
`-PreviousAttemptId 1e88ad3e80864296bf8550a32dfc5439`。每组入口 preflight 通过，
使用同一 HAP SHA-256 `eba559c4ce8dc81cfd1462944bd7ea3b01c77cbdbc1b27dbbf3701f955eac9b9`。

| 场景 / attempt | 耗时 | 直接行为与日志复核 |
|---|---:|---|
| pause-recovery / `60adc36eeb7e4486968d940ba03e1f21` | 155633 ms | UDP 阻断 6588 ms；同一 PTY 执行新命令，interrupted/recovered 均为 true；日志 9111 字节 |
| wifi-pause-recovery / `a9b0266fe69840599555f0920f39c02e` | 173029 ms | 实际 WLAN 关闭约 12038 ms 后恢复；同一 PTY 执行新命令，interrupted/recovered 均为 true；日志 8655 字节 |
| server-disappearance / `9464a82989d849968d2ab5c3d210aa2a` | 147330 ms | 约 5176 ms 后显示中断，不自动关闭；主动关闭 4006 ms 完成；recovered=false、userCloseRequired=true；日志 136 字节 |

三份 `device-mosh.json` 与对应 `network-behavior-device-app.log` 的状态一致，逐组
`observation-audit.json` 通过；旧空快照的负向结论没有被沿用。两个恢复场景均收到认证
关闭 ACK；服务端消失场景没有 ACK，按库的四秒上限完成本地关闭，未伪造远端恢复。

每组 9 条本地命令均一次输入、一次 Enter、零不匹配；远端受控命令分别为 2、2、1 条，
均由 server 精确比对后提交。三组原页面指纹还原、Mosh 页面丢弃、bootstrap/secret
扫描、Preferences 和清理全部通过；没有 cleanup fallback。fixture 进程、反向映射和
临时目录已移除，设备测试配置已清理，WiFi/持久网络恢复，未新增防火墙或端口代理。

本次只闭合观察器修复和三个命名回归；没有再次合盖，没有验证 PermissionDenied 在
真机上被触发后保留同一 Session，也没有进行模型调用或正式 C3。三份报告保持
`acceptanceEligible=false`。升级、安全错误元数据和工具修复可作为同一收口 PR；
合并后必须从新干净来源建立 R4，不能续接旧正式候选或覆盖旧报告。

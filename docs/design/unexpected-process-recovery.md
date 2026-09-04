# 应用异常回收防护与恢复技术方案

> 状态：Implementing；后台能力门已按停止条件失败并删除，工作区恢复切片已通过真机验证
>
> 当前 milestone：1.6
>
> 更新日期：2026-09-04
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：已进入 [`next-work.md`](../next-work.md)；当前按四个独立切片实施

## 用户问题与目标

HarmonyOS 可以在合盖、低内存、省电或系统稳定性治理时挂起或终止后台应用。当前真机已经
观察到物理合盖后 LeanTTY 进程被替换：活动 SSH/Mosh Session、Tab、Pane 和窗口位置随进程
一起丢失。Mosh 能恢复网络中断，却不能在本地客户端进程死亡后继续原 Session。

LeanTTY 不能承诺进程永不退出，但应把意外退出从“整个工作现场消失”降级为可理解、可恢复的
结果：

1. 进程被终止时，恢复 Tab、Pane、焦点和分屏等本地工作区结构，并明确说明远端 Session
   没有恢复。
2. 所有启动继续使用系统窗口自动保存；异常退出不以应用矩形换取一次可见窗口跳动。
3. 整个方案不持久化终端内容、命令、凭据、远端标题或协议 secret，也不伪装 Session 仍在线。

## 已确认的产品决策

| 问题 | 决策 | 原因 |
| --- | --- | --- |
| 是否使用长时任务 | 不使用；已删除 `KEEP_BACKGROUND_RUNNING`、`dataTransfer` 和平台封装 | 真机证明空闲 10 分钟会因无传输进度被撤销；终端没有可诚实更新的有限进度 |
| 是否增加保活开关或 workaround | 不增加 | 开关不能修复平台合同；虚假进度、流量或错误模式违反产品原则 |
| 没有活动 Session 时 | 不申请长时任务，允许系统回收进程 | 用恢复解决工作区连续性，不把空工作区变成常驻后台理由 |
| 恢复哪些工作区状态 | 恢复 Tab 顺序、每个 Tab 的一或二个 Pane、活动 Tab/Pane 和稳定分屏比例 | 这些状态由 LeanTTY 拥有，丢失会直接破坏工作连续性 |
| 不恢复哪些状态 | 不恢复连接、终端画面、scrollback、输入历史、远端标题、attention 或临时 UI | 避免泄密、陈旧画面、虚假连接和第二套终端历史 |
| 是否自动重连 | 不自动重连 | 启动时不得擅自联网、触发认证或假定远端 PTY 仍存在 |
| 窗口几何权威 | 所有启动都只以 HarmonyOS 为权威；异常几何兜底已按停止条件删除 | 真机证明应用兜底会被系统重置，或只能在内容加载后以可见跳动修正 |
| 是否依赖 `appRecovery` | 不作为主恢复路径 | 它面向 JS crash/app freeze 等应用故障，不能覆盖任意系统进程回收 |

## 当前事实与证据边界

- `EntryAbility` 已调用 `setWindowRectAutoSave(true)`。正常关闭后，HarmonyOS 可以直接以正确
  矩形创建 Starting Window；过去在 `loadContent` 后由应用 `moveWindowTo`/`resize` 会产生可见
  跳动，因此已经删除，见 [`startup-performance.md`](startup-performance.md)。
- HAD-W32 进一步证明异常启动也没有无跳动的应用补偿点：`loadContent` 前写入会被内容加载
  重置；启用受控 Starting Window 后，系统仍在移除启动页时恢复自己的矩形。该门已按下述
  停止条件裁剪，恢复记录不再包含窗口几何。
- 当前 `TerminalSurfaceController` 的 framebuffer checkpoint 和 detached output 只存在于进程
  内。它解决 ArkWeb Surface 重建，不解决应用进程终止。
- 长期配置持久化仍明确排除工作区和 Session。新增的异常退出记录只含 Tab/Pane 数量与活动
  位置、稳定 split ratio 和 run generation；终端内容、远端状态、秘密和透明度仍不持久化。
  主窗口几何目前完全由 HarmonyOS 托管，见 [`architecture.md`](../architecture.md)。
- HAD-W32 已证明受控挂起和 `Win+L` 不会必然替换进程。物理合盖存在三种可观察结果：系统替换
  LeanTTY 进程；保留同一 PID/start time 且保留完整 Session graph；或保留进程身份但回收 ArkTS
  Session graph。前者只能恢复本地工作区；第二种必须保留同一远端 PTY；第三种必须保留布局、
  明确提示重连并清理失主的 native Session。PID 不是唯一运行时身份，三者都不证明长时任务适用。
- HarmonyOS `dataTransfer` 要求 Live View 持续更新真实传输进度。HAD-W32 在屏幕保持点亮和
  解锁、SSH 仍连接且 LeanTTY PID 不变时，因 10 分钟没有更新通知进度撤销任务。系统服务先以
  reason 23 删除通知，再向应用回调 reason 1；因此不能把 reason 1 单独解释成用户取消。
- HarmonyOS 仍可因 LowMemoryKill、StabilityCheckKill、SWAP_FULL、Power Save Clean 或高负载
  终止进程。LeanTTY 不承诺进程永久存活。

平台参考：

- [HarmonyOS Background Task Management](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V5/js-apis-resourceschedule-backgroundtaskmanager-V5)
- [HarmonyOS appRecovery](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/js-apis-app-ability-apprecovery-V14)
- [HarmonyOS 应用前台闪退或后台退出排查](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-appgallery-1)

### 2026-09-02 后台能力门结论

最小实现曾证明单/双 SSH Session 只创建一个系统 Live View，首个 Session 启动、最后一个停止，
且通知不含 Host、Pane、标题、输出或 secret。随后在屏幕保持点亮和解锁的有效空闲测试中，任务
从 `00:58:53.790` 到 `01:08:56.793` 存活 603003 ms，之后系统明确以“超过 10 分钟未更新通知”
删除任务；SSH 和 LeanTTY PID 在测试清理前保持不变。首轮与屏幕锁定重叠的结果已排除，不用于
结论。证据位于 `build/verification/background-idle-contract-20260902/result.json`。

该结果命中本方案停止条件。SSH/Mosh 交互 Session 可能长期空闲，没有文件传输式总量和进度；
定时改进度或发送流量属于伪造保活。项目已删除后台权限、mode、实现、测试、UI 和文案。后续不再
验证用户移除通知、Mosh、合盖或 AppGallery 后台用途，资源转向异常恢复。

## 范围与非目标

### 范围

- 恢复当前单窗口、多个 Tab、每个 Tab 最多双 Pane 的既有工作区模型。
- 记录正常/异常退出和稳定工作区结构。
- 覆盖正常关闭、强制进程终止、物理合盖、Surface 重建和损坏记录。

### 非目标

- 不保证抵抗所有系统回收、用户强制停止、系统重启或硬件断电。
- 不增加 resident service、保活心跳、静音音频、伪造传输流量或错误后台模式。
- 不持久化或恢复终端内容、scrollback、命令历史、密码、passphrase、Mosh key、Host、远端标题
  或远端输出。
- 不实现 Mosh server 重新附着、SSH 自动重连、远端 tmux 自动发现或 session manager。
- 不把恢复扩展为通用 workspace framework、通用 persistence layer 或跨设备同步。
- 不改变正常退出后重新打开应用时的现有“新工作区”语义；本方案只补偿异常退出。
- 不让窗口几何跨卸载、重装或不同应用身份保留。

## 所有权与组件边界

```text
AppViewModel
  ├─ owns live Tab -> Pane structure and active focus
  ├─ emits a bounded structural checkpoint
  └─ reconstructs fresh generation-scoped Tab/Pane identities
          │
          └─> UnexpectedExitRecoveryStore
                ├─ owns one versioned Preferences record
                ├─ owns running/clean exit state
                ├─ merges workspace and emergency window checkpoints
                └─ never owns Session or terminal bytes

EntryAbility
  ├─ owns UIAbility/window lifecycle and HarmonyOS context
  ├─ starts the current run marker before content initialization
  ├─ leaves all restart window geometry to HarmonyOS
  └─ marks clean only after graceful application close completes
```

`AppViewModel` 仍是工作区唯一权威。恢复记录是上次稳定状态的检查点，不是并行可编辑模型；
恢复后必须构造新的 runtime，并立即重新以 `AppViewModel` 为权威。

## 后台保护门（已停止）

`dataTransfer` 是唯一曾经语义接近 SSH/Mosh 的模式，但平台要求 Live View 更新真实传输进度。
空闲终端稳定触发 10 分钟撤销，其他后台模式又不描述远程交互 Session。LeanTTY 因此不声明
后台权限、不创建长时任务，也不增加设置或提示。物理合盖后进程仍可能被系统回收；产品通过下述
结构恢复降低损失，并继续把 tmux/screen 作为远端任务持久化边界。

## 异常退出检查点

### 存储边界

恢复状态存入应用私有 Preferences 的一个版本化记录，不进入 `DurableAssetStore`：

- 记录不含秘密，不需要凭据级加密；
- 它只服务当前安装，不应像 SSH key/config 一样跨卸载保留；
- 单一小记录比新增数据库或持久化框架更符合当前范围。

写入使用一个序列化值和显式 `flush`。解析失败、字段越界、版本不兼容或大小超限时整条记录
失败关闭并启动默认工作区。只有真机故障注入证明平台会产生撕裂写入时，才考虑双槽或指针切换；
不提前复制 `DurableAssetStore` 的多代机制。

### 最小数据合同

```text
RecoveryRecord
  schemaVersion
  generation
  runState: running | clean
  workspace:
    activeTabPosition
    splitRatio
    tabs[]:
      paneCount: 1 | 2
      activePanePosition
```

不保存 Tab/Pane runtime ID。恢复时为所有 Tab、Pane 和 Session runtime 分配新 ID；旧进程的
notification Want、回调和晚到事件因 run generation 不匹配而丢弃，不能命中新工作区。

不保存 `TabInfo.title`、`PaneInfo.title`、Session state、Terminal mode 或 attention。这些字段可能
来自不可信远端内容，恢复后也不再描述真实连接。所有恢复 Pane 以本地 `ltty` 标题、`IDLE` 状态
和无 attention 开始。

### 写入时机

只在状态稳定后写入，不为每个渲染或网络事件落盘：

- 新建/关闭 Tab、分 Pane、关闭 Pane完成后；
- 活动 Tab/Pane 变化后；
- 分隔条拖动结束并完成 clamp 后；
- 窗口 drag/resize 和网格吸附全部完成后；
- 最大化或还原状态稳定后；
- `onBackground` 时做一次最终机会性 flush。

结构变化立即提交；连续焦点或几何事件只合并到最终稳定值。终端输出、按键、Session 数据和
reachability 状态不得触发恢复写入。

## 启动、恢复与正常关闭

### 启动事件链

```text
EntryAbility.onCreate
  -> read previous RecoveryRecord
  -> classify previous run as clean / unexpected / unusable
  -> synchronously mark the new generation running

EntryAbility.onWindowStageCreate
  -> keep setWindowRectAutoSave(true)
  -> loadContent

Index.aboutToAppear
  -> if previous run was unexpected and workspace checkpoint is valid:
       construct new Tab/Pane identities from the structural snapshot
     else:
       create the normal single ltty Pane
  -> render once from the selected workspace
```

恢复必须在创建默认 Tab 之前决定，不能先显示默认工作区再替换。每个恢复 Pane 只写一次稳定的
本地技术英文提示，例如：

```text
Previous LeanTTY process ended unexpectedly. Workspace layout was recovered;
the remote session and terminal contents were not restored.
```

该提示不声称系统终止原因；除非 fault 信息提供了可靠结构化证据，否则只描述 LeanTTY 能确认的
“上一进程没有完成正常关闭”。

### 正常关闭事件链

正常关闭继续使用现有确认和 `ApplicationCloseCoordinator`：

```text
user confirms close
  -> close/cancel every Session through its existing contract
  -> wait for Pane runtime disposal
  -> flush latest structural/window checkpoint
  -> mark current run clean as the final durable write
  -> allow application termination
```

不能依赖 `onDestroy` 标记 clean；强制终止不保证回调。任一步失败时取消正常关闭，或保持
`running` 标记，让下次以异常恢复处理。clean 必须是关闭事务的最后一次持久写入。

HAD-W32 还证明，页面调用 `UIAbilityContext.terminateSelf()` 的应用内关闭路径不会可靠触发
`onPrepareToTerminateAsync()`。因此页面必须先显式等待同一个
`ApplicationCloseCoordinator.prepareTermination()`，再调用 `terminateSelf()`；Ability 生命周期
钩子仍保留为系统发起终止时的入口。两条入口复用 single-flight coordinator，不能分别维护
关闭事务。未显式准备时，进程虽会退出，但记录仍是 `running`，下次启动会误报异常恢复。

### 2026-09-02 工作区恢复切片证据

精确 test HAP（SHA-256
`477e5a15eba88868050a0105231a9e7fc9bcb907382500055730cebb86d9a4d1`）在 HAD-W32 上完成以下
受控验证：

- 两个 Tab、每 Tab 两个 Pane、活动 Tab/Pane 在 `aa force-stop` 后恢复；活动 Tab 只挂载两个
  Web surface，且只有一个获得焦点；所有 Pane 从本地 `ltty`/`IDLE` 开始并显示一次恢复提示。
- 真实拖动分隔条后，两个 Web surface 从默认边界变为
  `[168,395][1660,1902]` 与 `[1667,395][2798,1902]`；强制停止并重启后的边界完全一致，证明
  非默认稳定 split ratio 经检查点恢复。
- 通过 `Ctrl+Shift+W` 正常关闭全部 Pane 后，当前 generation 在进程退出前写为 `clean`；再次
  启动只有默认单 Pane，没有恢复提示。该场景同时发现并修复了上述 `terminateSelf()` 生命周期
  假设错误。
- 注入 schema 99 的未来记录后整条拒绝并回到默认单 Pane；测试 fixture 已移除。持久记录只含
  schema、generation、run state、活动位置、split ratio 和 Pane 数量；相关 hilog 不含 Host、
  地址、标题、终端内容、命令、凭据、协议 secret、attention 或 Session state。

详细机器可读证据位于
`build/verification/unexpected-exit-recovery-20260902/result.json`。这闭合无活动 Session 的
结构恢复切片；Surface 重建、旧事件隔离和物理合盖按下述独立证据执行。

### 2026-09-02 活动 Mosh 受控进程回收证据

同一 test HAP（SHA-256
`f46abd50e7eb559d73f6e6db30b146eef47842e27dd04799c130a1ee89cca8a4`）在活动 stock Mosh Session
执行过受控远端命令后强制停止 LeanTTY。应用 PID 从 30709 变为 32303；进程替换时 stock server
和远端 PTY 仍存活，但新进程只恢复本地工作区并显示一次恢复提示。终端搜索证明旧远端命令不可见，
本地 `help` 可继续执行，且新进程没有创建或伪恢复 Mosh Session。

测试的 SSH bootstrap 使用临时 HDC reverse 映射，Mosh UDP 仍走 `192.168.1.4` 有线网络；映射、
fixture 进程和临时目录均已清理。机器可读证据位于
`build/verification/device-mosh-process-recovery-20260902-retry2/device-mosh.json`。该结果闭合活动
Session 的受控状态机，不替代物理合盖、Surface 重建或 Pane 晚到事件验证。

### 2026-09-02 物理合盖恢复证据

精确 test HAP（SHA-256
`5bde573d5863658e91ccd14f15ad2e99a22caaac0455c8e0690acf3cded015e6`）在 HAD-W32 上完成真实
合盖、开盖和解锁。LeanTTY PID 从 16447 变为 19630；进程替换时 stock server 与远端 PTY 均
仍存活。新进程显示一次工作区恢复提示，旧远端命令不可见，没有创建或伪恢复 Mosh Session，
本地命令可继续执行；临时 HDC reverse、fixture、设备状态与临时目录清理均通过。

机器可读证据位于
`build/verification/device-mosh-operator-lid-recovery-20260902-workspace-owner-retry/device-mosh.json`。
该结果闭合物理合盖的进程替换分支，不宣称系统会保留本地 Mosh Session。

随后一轮加入 `/proc/<pid>/stat` start time 的运行给出了另一条确定证据：合盖前后 PID 均为
24550，start time ticks 均为 38439318，但解锁后输入落入本地 `ltty`。它证明同一进程身份仍
存活，但当时尚不能区分页面析构主动释放 Session、工作区 owner 被替换或 ArkTS 对象内部状态
被回收；这不是 PID 复用，也不是测试输入失败。机器可读证据位于
`build/verification/device-mosh-operator-lid-recovery-20260902-proc-identity/device-mosh.json`。

工作区所有权随后提升到进程级 `ApplicationWorkspace`：它在进程内持有唯一 `AppViewModel`，
替换页面只重绑 Pane runtime 的 UI callback 并重新附着 Surface；页面析构不再释放工作区或
Session。确定性 `page-rebuild` 真机证据证明该边界正确，但它没有解释真实合盖中的对象状态回收。
显式正常关闭仍先断开所有 runtime 再标记 clean，进程真正替换时仍只走持久化结构恢复。

当前修复 HAP 首次重跑真实合盖时选择了进程替换分支：PID/start time 从
40273/38593315 变为 45041/38618783，stock server 与 PTY 在替换点仍存活，本地工作区提示、
旧远端内容隔离、无伪 Session 和全部清理通过。证据位于
`build/verification/device-mosh-operator-lid-recovery-20260902-page-rebind-retry2/device-mosh.json`，
HAP SHA-256 为 `65abaadfb1439d7b60726a0900cf9a178161329e3ccc8cfa64c2a28ffc48e9f6`。

物理合盖由系统选择分支，继续重复操作不能稳定产生同进程证据。因此验收改用编译期裁剪的
`page-rebuild` 入口，在 HAD-W32 上由 UI-context router 明确销毁并替换当前 `Index` 页面。
PID 51684 与 start time 38667801 全程不变，新页面记录 `workspace=reused`；原 Mosh 页面仍可搜索，
同一 server/PTY 接受并显示新的精确远端命令，认证关闭成功，Preferences、secret、临时 HDC
reverse、fixture、设备状态和临时目录全部清理。证据位于
`build/verification/device-mosh-page-rebuild-20260902-retry2/device-mosh.json`，HAP SHA-256 为
`2d3c43605ac2c9133387d4c1846d95e120969100f92744528d47db95649afc5a`。这条确定性证据直接覆盖
此前故障所在的页面析构/重建边界；生产源码和发布包不包含该触发入口。

### 2026-09-04 同进程运行时回收证据与合同

两次新的真实合盖诊断排除了“只要保留 workspace owner 就能保留 Session”的假设：
`mosh-appstorage-lid-r2` 的 PID/start time 为 `59496/55760057`，`mosh-runtime-owner-lid-r3` 为
`765/55802674`，合盖前后均未改变；恢复输入前都没有 Mosh close/error，stock server 与远端
PTY 仍存活，但 Pane 已为本地空闲状态。第二次日志还记录 `workspaceBinding=retained`。因此
WindowStage、Page、workspace 对象甚至进程身份都不是 Session 完整性的充分证明；把复杂
`AppViewModel` 放进 AppStorage 或只移除页面字段上的 `@State` 也不能建立该保证。

最终实现把 live Tab -> Pane -> Session graph 保持为普通应用级 owner，不放进 `@State` 或
AppStorage；后两者只保存用于 UI 更新和不一致检测的简单投影。每次同步工作区时，AppStorage
记录活动远端 Pane ID 和其中的 Mosh Pane ID。窗口恢复可见时，如果投影仍声明活动 Session，
但 live graph 已全部回到空闲，LeanTTY 认定 ArkTS Session graph 已被回收：先停止接收旧输出，
恢复每个 Pane 的本地页面并显示重连提示，再通过 native registry 取消失主的 SSH、Mosh 和传输
Session。该分支不恢复终端内容、凭据或连接，也不解析远端输出猜测生命周期。

物理合盖由系统选择进程替换、Session 保留或 runtime 回收，重复合盖不能稳定命中指定分支。
因此测试包增加编译期裁剪的 `runtime-reclaim` 症状注入：它只制造“简单活动投影仍在、
SessionViewModel 已空闲、native Mosh 仍存活”的已观察状态，恢复本身完全走生产路径。HAD-W32
上 PID/start time 均保持 `33256/56033973`，恢复日志记录 `panes=1,nativeCancelRequests=1`；结构化
结果证明 `processReplaced=false`、
`runtimeReclaimed=true`、提示可见、旧远端内容不可见、Session 未伪恢复、本地 `help` 可执行，
stock server、远端 PTY、HDC reverse、fixture 和临时目录全部清理。测试 HAP SHA-256 为
`8b1b5851b916dfc6d9ac60bdab35f26716507801da630c066063e19d46d79e9e`，机器可读证据位于
`%USERPROFILE%\Documents\LeanTTY-verification\1.6-mosh-formal-20260904\mosh-runtime-reclaim-deterministic-r4\device-mosh.json`，关键日志同目录保存为
`mosh-runtime-reclaim-device-app.log`。
这条确定性证据与两次真实合盖的症状证据配对，闭合 runtime-reclaim 合同；它不把注入本身表述
为一次真实合盖，也不承诺系统保留远端 Session。

正式 retained candidate `59375d85867b59e45a440f05982ed8be8d35162e153a0bc95a0274269ab68bc4`
随后补充了一个重要时序边界：真实合盖前后 PID/start time 均为 `56909/56192126`，恢复可见时
日志先记录 `runtimeRecovery=not-required`，但 4.3 秒后的首个输入已落入 `SessionViewModel mode=0`。
原因是旧检测读取 `PaneInfo.mode` UI 投影，它仍残留 CONNECTED；live SessionViewModel 已被回收为
IDLE。矩阵在第 5 组按规则失败并停止，前四组虽各自通过且清理完成，也不能跨产品修复沿用。
机器可读证据位于
`%USERPROFILE%\Documents\LeanTTY-verification\1.6-formal-20260904\mosh-matrix-4fe407d\mosh-matrix.json`。

修订后的不一致门逐个检查简单活动 Pane 投影对应的 live `SessionViewModel.getMode()`；只有全部
runtime 仍存在且均非 IDLE 才视为 Session graph 完整。任一 runtime 缺失或已空闲时，整组投影
声明的远端 Pane 一起降级为明确重连并统一清理 native registry，避免保留半个可信 graph。
测试包的 `runtime-reclaim` 注入也保留陈旧 `PaneInfo.mode`，从而覆盖真实系统形态，而不再让 UI
投影同步掩盖该问题。

修订后的测试 HAP `cb098fd2a7f4e6c09fd79a612603e30423ca2107c3bd3502c979cf5eb3dd433c`
已在 HAD-W32 上通过上述确定性场景：PID/start time 保持 `63331/56240158`，运行时回收、提示、
旧内容隔离、Session 未恢复和 cleanup 均为真；日志记录 `nativeCancelRequests=1`，并拒绝晚到的
Mosh output/event。该结果只证明修订后的同进程不一致门，真实合盖仍须由新 retained candidate
重新执行完整矩阵。

正式候选 commit `8b92a0dc6366697c03138af52cec9e16d5f90105`、HAP
`38cf485bf9754a7a0df80ebbe468f6968497657b9c66249392f5193ff0014e5c` 的完整矩阵又证明：即使窗口
恢复可见时核对 live mode，系统仍可在该检查之后、首个输入之前丢失 Session graph。第 5 组真实
合盖前后 PID/start time 均为 `23031/56407267`；`00:08:11.136` 可见性检查仍记录
`runtimeRecovery=not-required`，`00:08:11.715` 收到 `onNewWant`，但 `00:08:16.066` 首个输入已
进入 `mode=0` 并退回 `ltty>`。恢复输入前没有 Mosh close/error/interruption，stock server 与远端
PTY 仍存活。矩阵按规则停止，前四组结果不能跨修复沿用。机器可读证据位于
`%USERPROFILE%\Documents\LeanTTY-verification\1.6-formal-20260904\mosh-matrix-8b92a0d\mosh-matrix.json`。

因此恢复门增加真实输入边界防护，而不是增加任意延时：每次工作区同步只投影当前活动 Pane ID
和活动远端 Pane ID；如果活动 Pane 的 live `SessionViewModel` 已为 IDLE，但简单投影仍声明它是
远端 Session，第一段输入会被整段消费，并用一次性 token 请求 `Index` 执行既有的统一恢复路径。
正常 IDLE Pane、其他 Pane 的远端 Session、非当前 Pane 的晚到输入，以及 live mode 非 IDLE 都
不会触发。`Index` 在执行前
再次核对活动 Pane，仍由 `recoverReclaimedRuntimeSessions()` 独占降级、提示和 native registry
清理责任；这里不引入第二套 Session 状态机或超时计时器。

编译期裁剪的 `runtime-reclaim` 随之改为在可见性检查后只丢弃 runtime，再发送一个不带 Enter 的
ASCII `x`。HAD-W32 上测试 HAP
`87b32579163b0b38a87aa0a4bf64ff23166b3b42bfb6719a75d2287bb2a3c3bb` 保持同一 PID/start time
`46922/56576305`；日志依次证明状态丢弃、首次输入被拦截、`panes=1,nativeCancelRequests=1` 和
恢复请求完成。结构化结果同时证明提示可见、旧远端内容不可见、Session 未伪恢复、后续本地
`help` 可执行且 cleanup 通过；如果 `x` 泄漏到本地输入缓冲，后续命令不会通过。证据位于
`%USERPROFILE%\Documents\LeanTTY-verification\1.6-formal-20260905\mosh-runtime-first-input-r3\device-mosh.json`。
该测试证明首次输入安全边界，不代替新正式候选的真实合盖和完整七组矩阵。

commit `eede0ab760ea23866c0d62008d277d2c5e1d242b`、HAP
`584fa1fe6a9afe1ce3d081bec4e8d09d11ade4a5be8b910c708d697dd06a8430` 的正式矩阵再次校正了这条
边界。第 5 组真实合盖保持同一 PID/start time `5386/56737521`，恢复输入前 stock server 和远端
PTY 仍存活，也没有 Mosh close/error/interruption；但窗口恢复日志仍报告
`runtimeRecovery=not-required`，首个输入进入 `mode=0` 后直接落入 `ltty>`，且没有
`Terminal input withheld`。这证明合盖也会清除用来判断活动 Pane 的 AppStorage 简单投影；把
AppStorage 当成最终输入权威仍然不成立。矩阵按规则停止，已通过的 compatibility、UDP pause、
suspend 和 lock 结果不能跨修复沿用。证据位于
`%USERPROFILE%\Documents\LeanTTY-verification\1.6-formal-20260905\mosh-matrix-eede0ab\mosh-matrix.json`。

修订后的最终输入门改用输入来源 `TerminalSurfaceController` 自己持有的 Mosh Session 页面状态和
Pane identity。Surface 是用户当前可见 Mosh 画面与输入事件的直接所有者；如果对应
`SessionViewModel` 已为 IDLE，但该 Surface 仍持有 Mosh 页面，首段输入会被消费，并把 Surface 的
Pane ID 交给 `Index`。`Index` 再核对它仍是活动 Pane，合并仍存在的 UI 投影，并继续独占布局降级、
提示和 native registry 清理。正常 Mosh 页面关闭期间的 `terminalResetPending`、不持有 Mosh 页面的
本地 IDLE Pane，以及非活动或晚到 Surface 输入都不能触发恢复；实现没有增加延时、计时器或第二套
Session 状态机。

编译期裁剪的 `runtime-reclaim` 进一步主动清空 `activeRemotePaneIds` 和 `activeMoshPaneIds`，证明
这条门不再依赖 AppStorage 活动投影。HAD-W32 上测试 HAP
`636035b2d115f597b821e36042fcb45b1b6d0c3ac051457c6ea04b0479e22a56` 保持同一 PID/start time
`20453/56837533`；日志依次记录 `mode=0`、首字符被拦截、
`panes=1,nativeCancelRequests=1`、请求完成以及晚到 Mosh output/event 被拒绝。结构化结果同时证明
提示可见、旧内容不可见、Session 未伪恢复、后续本地 `help` 可执行且 cleanup 通过。证据位于
`%USERPROFILE%\Documents\LeanTTY-verification\1.6-formal-20260905\mosh-runtime-surface-owned-r1\device-mosh.json`。
该结果仍是诊断 HAP 的确定性合同证据；真实合盖和完整七组矩阵必须在合并后的新正式候选上从头
复验。

### 2026-09-02 旧通知跨进程隔离证据

同一 HAP 建立后台 BEL 通知后，测试强制停止 LeanTTY，再点击仍留在系统通知中心的旧通知。
应用 PID 从 58779 变为 59468；新进程拒绝旧 Pane 的 Want，hilog 明确记录 source 已不再
pending，活动工作区没有被切换或污染。通知 payload 保持通用，不含终端内容；应用恢复可见后
请求取消通知，并确认最终为默认单 Pane。

机器可读证据位于
`build/verification/unexpected-recovery-cold-stale-bell-20260902/result.json`，HAP SHA-256 为
`2d3c43605ac2c9133387d4c1846d95e120969100f92744528d47db95649afc5a`。该结果覆盖真实系统
notification Want 的跨进程隔离；generation/runtime ID 的 codec 与模型边界仍由单元测试覆盖。

### 2026-09-02 普通卸载重装清理证据

同一 HAP 在 fresh-install 基线上建立两个 Tab，并在活动 Tab 建立两个 Pane；异常退出 Preferences
记录存在后强制停止 PID 64157。随后执行未带 `-k` 的普通卸载并重装完全相同的 HAP，新 PID
64198 以 `generation=1, unexpected=false` 启动，界面只有默认一个 Tab、一个 Pane，旧工作区
没有恢复，且卸载前后的恢复记录摘要不同。

机器可读证据位于
`build/verification/unexpected-recovery-uninstall-20260902/result.json`，HAP SHA-256 为
`2d3c43605ac2c9133387d4c1846d95e120969100f92744528d47db95649afc5a`。测试不读取或改动
HarmonyOS Asset Store；同一 HAP 已重装并保持默认工作区可见，设备屏幕超时覆盖已还原。

## 窗口几何门结论

异常窗口兜底已触发停止条件并删除。HAD-W32 上按同一个非默认自由窗口矩形重复执行了三种
时序：

1. 先调用 `setWindowRectAutoSave(true)`，再在 `loadContent` 前 `resize`/`moveWindowTo`；系统在
   内容加载后恢复最近一次正常保存的矩形。
2. 等待 `setWindowRectAutoSave(true)` Promise 完成后再写入；结果相同，排除仅仅是 API Promise
   未等待的竞争。
3. 配置 `enable.remove.starting.window=true`，在页面加载和窗口装饰初始化后写入，再调用
   `removeStartingWindow()`；日志顺序正确，但系统在启动页移除时仍恢复自己的矩形。

三种路径均能执行应用写入，却不能在终端内容显示前留下该结果。唯一能强制保留应用矩形的剩余
路径是在 `loadContent` 或启动页移除后再次移动窗口，这正是 1.3 已删除的可见跳动路径。按已批准
停止条件，项目删除 `emergencyWindow`、显示环境映射、clamp 策略、窗口事件检查点和受控启动页，
不以双权威复杂度换取异常启动的一次跳动。`setWindowRectAutoSave(true)` 继续作为正常与异常启动
的唯一权威；异常回收只恢复 LeanTTY 自己拥有的工作区结构。

## 失败与降级行为

| 失败 | 用户结果 | 系统行为 |
| --- | --- | --- |
| 进程仍被回收 | 下次恢复工作区结构并使用系统窗口结果 | Session 与终端内容明确不恢复 |
| 恢复记录损坏/过新 | 启动正常单 Pane | 丢弃整条记录，不部分猜测 |
| 正常关闭事务失败 | 保持应用打开或按异常退出处理 | 不写虚假 clean |
| 恢复构造部分失败 | 丢弃恢复并启动单 Pane | 不留下半个工作区或孤立 runtime |

`appRecovery` 可以在未来作为 JS crash/app freeze 的启动加速候选，但不能替代上述应用私有
检查点，也不能把 LowMemoryKill、Power Save Clean 或用户强制停止描述成可自动恢复的故障。

## 实施顺序

方案按依赖拆成四个切片；可执行 checkbox 只保留在 [`next-work.md`](../next-work.md)：

1. **后台能力门（完成/停止）。** 真机证明空闲 10 分钟撤销 `dataTransfer`；实现和声明已删除。
2. **异常退出与工作区检查点。** 先完成纯策略、codec、run generation、clean/unclean 事务和
   AppViewModel 结构恢复，再接入稳定状态写入；不同时实现窗口补偿。
3. **异常窗口门（完成/停止）。** 真机证明公开应用时序无法同时保留异常矩形和避免窗口跳动；
   已删除兜底并保持 HarmonyOS 单一权威。
4. **端到端收口。** 组合验证活动/无活动 Session、正常/异常退出、多 Tab/Pane、Surface 重建、
   stale event、隐私和物理合盖，再继续 1.6 的 Wi-Fi 暂断与网络切换矩阵。

每个切片独立验证；端到端收口只组合已经通过或按停止条件裁剪的行为。

## 验证门禁

### 软件门

- 恢复 codec 覆盖版本、大小、字段范围、损坏 JSON、单/双 Pane、多 Tab、活动位置、split ratio
  和默认失败关闭。
- clean/unclean 覆盖启动即终止、正常关闭失败、重复恢复和新 generation；clean 只允许最后写入。
- 恢复模型证明 runtime ID 全部重建，旧 notification Want、Pane ID 和 callback 不能命中新实例。
- 数据合同测试拒绝 Host、远端标题、终端内容、命令、凭据、secret、attention 和 Session state。
- 源码门证明 `setWindowRectAutoSave(true)` 仍是唯一窗口持久化路径，且不存在异常矩形读取、
  `loadContent` 后几何修正或受控 Starting Window。
- manifest/policy 门证明不残留后台权限或 mode，production/review 构建都不含测试入口。

### ARM64 构建门

- 目标 `arm64-v8a` 构建不包含已停止的 Background Tasks Kit 路径。
- production 与 review 包的权限和代码路径一致；验收入口继续由编译期裁剪。

### 物理 HarmonyOS PC 门

按以下顺序在 HAD-W32 上验证，每组记录 PID、Session/远端 PTY、恢复结果、Preferences
摘要、hilog secret 审计和清理：

1. 没有活动 Session 时建立多个 Tab/Pane、活动焦点和非默认 split ratio，强制结束进程后恢复同一
   结构，但所有 runtime ID 更新、Pane 为 `IDLE` 且没有远端内容。
2. 有活动 Session 时进程被回收后恢复工作区，并明确显示 Session 未恢复。
3. 正常关闭后重新打开仍走系统窗口和默认工作区，没有异常恢复提示。
4. 自由窗口和最大化分别执行正常关闭与异常终止；确认系统窗口路径没有因工作区恢复回归，不再
   期待异常终止前尚未提交的应用几何被恢复。
5. ArkWeb Surface 重建、Pane 销毁和旧通知点击不污染恢复记录，也不能把旧事件送到新 Pane。
6. 注入损坏和未来版本记录后安全回到单 Pane；卸载重装后不恢复工作区。

上述六组均已在 2026-09-02 闭合；后续只有相关所有权、持久化合同或平台生命周期实现变化时
才重跑对应组，不把整套恢复矩阵塞入每个功能迭代。

不能用 `hdc shell kill` 单独替代物理合盖，但可以用它稳定覆盖异常分类和恢复逻辑。物理合盖负责
证明真实产品场景，受控终止负责定位失败阶段。

## 停止与裁剪条件

- 后台停止条件已触发并执行；除非平台以后提供明确适用于空闲交互终端的新合同，否则不重开。
- 若工作区恢复只有持久化 Host、远端标题、终端内容或凭据才可用，停止扩展并重新讨论信任边界；
  本方案不隐式授权这些数据。
- 异常窗口停止条件已触发并执行；除非平台以后提供能在应用内容显示前更新系统窗口恢复记录的
  公共合同，否则不重开应用矩形兜底。
- 若持久化开始复制 Session、Transport 或 terminal owner，回到所有权设计并删除重复
  状态，不以新增 Manager 或通用框架掩盖冲突。

## 完成条件

本方案只有同时满足以下结果才算闭合：

- 无活动 Session 的进程即使被回收，多 Tab/Pane 工作区也不会无提示地退回全新单 Pane；
- 任何进程死亡后都不伪造已连接 Session，也不持久化终端或秘密数据；
- 所有窗口启动继续由 HarmonyOS 托管且无应用侧几何跳动；
- 物理合盖门闭合后，1.6 才继续 Wi-Fi 暂断和网络切换比较。

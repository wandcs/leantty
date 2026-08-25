# 后台 BEL 通知与返回技术方案

> 状态：Verified；1.5 产品实现与物理矩阵已闭合
>
> milestone：1.5
>
> 更新日期：2026-08-23
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 完成事实：产品实现、聚焦软件门与同一签名 ARM64 diagnostic HAP 的命名物理矩阵均已闭合；正式候选与发布仍须单独授权

## 用户问题与目标

用户在远端 shell、tmux 或 Code Agent 中运行长任务时，需要能够离开 LeanTTY，等标准
terminal BEL 到达后得到一次安静的提醒，并准确回到仍然有效的来源 Pane。产品不应要求
用户持续盯住窗口，也不应为了这个结果理解 Agent、命令或远端屏幕内容。

本期目标是复用现有 Pane attention：前台仍只有有限 Tab pulse 与 Pane 标记；仅当整个
LeanTTY 窗口处于后台、最小化或不可见时，一次从“已处理”到“待处理”的 BEL attention
跃迁才可发布一条本地系统通知。通知点击只把用户带回现有来源，不创建或复活任何工作区
状态。

## 最小范围与非目标

最小范围固定为：

- 输入只接受 xterm.js 已解析的标准 BEL；不新增另一条远端注意协议。
- 整个窗口可见时，不因非活动 Tab、非焦点 Pane 或菜单遮挡发布系统通知。
- 全应用只有一条可移除、点击后清除的普通文本通知；每次后台停留只绑定第一个有效来源，
  后续来源只保留应用内 attention，不替换、不刷新系统通知。
- 通知文案固定为 LeanTTY 本地通用文案，不含用户、主机、远端 title、命令、输出、Agent
  回答、凭据或其他终端内容。
- 点击使用稳定 Pane ID 解析当前工作区；只定位仍存在且仍拥有 attention 的 Pane。
- 通知关闭、权限拒绝、系统服务失败或迟到点击都不影响终端输入输出、SSH Session 或应用内
  attention。

本方案已闭合的 BEL 切片本身不实现 OSC 9/777/99、shell integration、命令完成推断、Agent 私有
协议、动作按钮、图片、进度、角标、自定义声音、勿扰绕过、Live View、后台常驻服务、跨设备
通知、通知历史、设置矩阵或通用通知框架。2026-08-24，维护者把 Agent 原生兼容矩阵、OSC 9/777/99
受限 attention 输入和中英文使用指南作为后续 1.5 正式范围写入 `roadmap.md` 与 `next-work.md`；
该后续工作只能复用本文的 attention/通知/返回合同，并在 Terminal Surface 丢弃远端 payload，
不把本方案的 Verified BEL 证据冒充新协议完成事实。OSC 99 只进入 roadmap 已批准的完整帧
接收子集；能力面只固定回答 `p=title,body`，分片状态、远端回报与其余富通知语义仍不进入范围。也不把
“某个 Pane 在可见窗口内不可见”扩大为系统通知条件；应用内 Tab/Pane attention 已经覆盖这种
情况。

## 公开平台合同与证据边界

目标构建使用 HarmonyOS SDK `6.1.1(24)`，兼容 SDK `6.0.2(22)`。2026-08-23 核对当前
SDK 类型与官方文档得到以下可实现合同：

- Notification Kit 的 `publish()` 接受普通文本通知；相同 `id` 与 `label` 的新请求替换旧
  请求，`cancel()` 可按同一键撤销。
- `isNotificationEnabled()` 和绑定 `UIAbilityContext` 的 `requestEnableNotification()`
  提供应用级通知状态与系统授权对话框；发布失败区分 disabled、slot disabled、permission
  和服务错误。
- Ability Kit 的 `WantAgent` 可启动本应用 UIAbility；冷启动通过 `onCreate(want, ...)`，
  热启动可通过 `onNewWant(want, ...)` 接收参数。
- `OTHER_TYPES` 是普通应用可用的最低通知级，`SERVICE_INFORMATION` 是高等级。二者在
  HarmonyOS PC 上的实际横幅、声音、通知中心留存和点击恢复效果不能由 SDK 类型推断，必须
  用物理设备比较。

官方通知 UX 要求通知提供明确价值、不重复应用内信息、使用标准布局，并点击进入对应内容。
上述合同证明实现入口存在，但在物理 PC 完成类别强度、权限、替换、热/冷点击和生命周期探针
前，不把它描述为已经可交付的 HarmonyOS PC 行为。

参考：

- [HarmonyOS Notification UX](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/system-features-notification-0000001793074217)
- [NotificationManager API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/js-apis-notificationmanager-V13)
- [通知添加 WantAgent](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/notification-with-wantagent)
- [UIAbility 生命周期](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/js-apis-app-ability-uiability)

## 所有权与唯一事件链

`AppViewModel` 中的 `PaneInfo.needsAttention` 仍是唯一 attention 真相；系统通知只拥有一项
可撤销的外部副作用，不保存 Session、Tab 或第二份 attention 状态。

```text
remote BEL
  -> xterm.js onBell
  -> existing one-shot W2N bellAttention
  -> Index.markPaneAttention(stable paneId)
  -> AppViewModel false -> true attention transition
  -> if entire window is not visible
       -> claim the one in-memory attempt for this background episode
          -> publish one generic OTHER_TYPES notification
          -> WantAgent(stable paneId only)
             -> EntryAbility onCreate/onNewWant
                -> AppStorage short-lived return request
                   -> Index validates current AppViewModel
                      -> existing tab select + pane focus + attention clear
```

规则如下：

- `markPaneAttention` 是唯一发布入口。只有 `needsAttention` 的 `false -> true` 跃迁且
  `mainWindowVisible == false` 时发布；同一 pending 状态的重复 BEL 不再发布。
- 一次后台停留从窗口变为不可见开始，到窗口重新可见结束。第一次符合条件的 BEL 同步占用
  本次后台停留唯一的系统通知投递机会；随后无论同一还是其他 Pane 再次出现新的 attention，
  都只保留应用内标记，不发布、不刷新通知，也不延迟补发。窗口重新可见才恢复下一次机会。
- 投递机会表示一次有界尝试，而不是通知的“已读”状态。权限关闭、平台失败、用户未点击、
  手动 dismiss 或 24 小时自动过期均不在后台追提醒；不增加通知监听、计时器、频率计数、
  持久化或设置项。
- 通知使用固定 ID、label、标题与正文。当前外部通知目标可在进程内记录，用于匹配撤销，
  但不能反向证明 Pane attention；进程退出即丢弃该辅助值。
- WantAgent 使用固定 request code 与 update flag，但本次后台停留只绑定第一个获得投递机会的
  Pane。payload 只含该内部稳定 Pane ID 和固定来源标记，不含可显示或远端可控数据。
- EntryAbility 只负责验证固定来源标记、发布短生命周期的 return request；Index 仍是
  Tab/Pane/focus 路由所有者。冷启动没有原工作区时验证失败，只显示新应用工作区。
- 返回有效性由 Pane 是否仍存在且是否仍拥有 attention 决定，不由已经结束或替换的 Session
  对象决定。Session 结束但 Pane 仍保留待处理输出时仍可安全返回该 Pane；Pane 被销毁后回调
  必须失效，且不得重建 Session 或 Pane。
- 窗口回到前台、有效点击被消费、目标 attention 被清除或目标 Pane 被销毁时撤销当前
  通知。只有窗口重新可见会同时重置后台投递机会；其他撤销不会让后续 Pane 绕过避让规则。
  撤销失败只记录非秘密错误；系统已移除通知视为幂等完成。

## 权限、失败与恢复

不在首次启动时索取通知授权。第一次后台 BEL 若发现通知未启用，只保留既有应用内 attention，
并记录一次“下次前台可解释授权”的本地状态；用户回到 LeanTTY 后至多请求一次系统授权。
拒绝后不循环弹窗、不阻止任何终端路径，用户仍可从系统设置自行改变通知权限。该一次性决定
必须持久化，但不得记录 Pane、主机或终端内容。

发布、WantAgent 创建和撤销均为可失败系统副作用：失败只记录固定事件名、错误码和内部 Pane
ID，不记录通知 payload 之外的数据。投递机会在进入异步平台调用前同步占用，避免相邻 Pane
并发穿透；单调请求代次仍在异步边界阻止窗口恢复或撤销后的旧发布迟到落地。

点击解析失败时统一退化为“只打开应用”：Pane 不存在、attention 已清除、进程已冷启动、
参数错误或回调迟到，都不得重建 Tab/Pane、连接旧 Session 或把输入焦点转移到别的终端。

## 验证映射与停止条件

自动化至少证明：前台永不发布、后台只在 attention 新跃迁尝试、同一后台停留只允许第一次
投递、后续同 Pane/跨 Pane BEL 只保留应用内 attention、窗口可见后恢复下一次机会、固定无敏感
文案、无效/迟到点击只打开应用、有效点击按第一来源稳定 ID 返回、权限拒绝不改变 attention，
以及撤销后的过时异步结果不能迟到落地。ARM64 debug HAP 构建只证明 Notification/Ability Kit
类型和打包边界成立。

物理 ARM64 HarmonyOS PC 必须用命名场景分别观察：

1. `OTHER_TYPES` 与 `SERVICE_INFORMATION` 的实际提示强度、声音和通知中心行为；
2. 首次授权、拒绝后不重复请求，以及随后系统设置改变；
3. 后台 shell/tmux/Agent BEL、同 Pane 重复 BEL、另一 Pane 被抑制和手动 dismiss；
4. 通知点击的前台、后台、最小化、热启动、冷启动、已清除与已销毁来源；
5. 日志、通知卡片、Want 参数和清理结果均不出现远端敏感内容。

若 `OTHER_TYPES` 在目标 PC 上无法形成可发现的提醒，而语义不匹配且高噪声的高等级类别才
能工作；或 WantAgent 不能可靠回到现有 UIAbility；或普通 AppGallery 应用的权限/生命周期
无法满足上述合同，则裁剪系统通知，只保留现有应用内 attention。不得以
`SERVICE_INFORMATION` 冒充服务消息、前台伪装、常驻服务或私有接口绕过停止条件。

## 当前实现与诊断证据

2026-08-23 的签名 ARM64 diagnostic HAP 在 HAD-W32 上闭合了避让产品链：整窗可见时不发布，
最小化后的第一个 pending Pane 发布一条 `OTHER_TYPES` 通知，第二个 Pane 在同一后台停留中只
保留 attention 并产生日志化抑制，通知中心仍只有一张固定无敏感文案的卡片；点击返回第一来源。
窗口恢复可见后再次最小化并触发 BEL，新后台停留重新发布一张通知并再次返回第一来源。场景
结束后恢复窗口、撤销通知并确认只剩单 Pane。

低等级与临时 `SERVICE_INFORMATION` 对照构建在该 PC 上都能发布，后者没有产生可见收益；因此
产品源保留公开 API 中最低可用的 `OTHER_TYPES`。当前边界 diagnostic HAP SHA-256 为
`06FC2184E3AFAE3DE47C77704415B32850942EB0B1F43F11C1E4F0137DB3DD97`。这只是开发期诊断身份，
不是 1.5 正式候选或 AppGallery 能力。

可重复的命名入口是 `tools/verify-background-bell-notification-pc.ps1 -HapPath <signed-test-hap>`
及其 `-Suppression`、`-ColdStale`、`-LateHandled`、`-LateDestroyed` 和 `-ManualDismiss` 场景；
本次精确 HAP、抑制、重置、返回、隐私和清理结果保存在
`build/verification/background-bell-episode-final/result.json`。冷启动点击的既有证据已证明新进程
只打开应用并忽略不再 pending 的旧 Pane ID。真实 SSH fixture `bell-attention` 冒烟保存在
`build/verification/background-bell-episode-ssh-smoke/device-ssh-auth.json`，证明活动 Pane、非活动
Tab、双 Pane、重复合并和进入清除语义未被通知桥破坏。

同一 HAP 的新增证据分别保存在 `build/verification/background-bell-late-handled/result.json`、
`build/verification/background-bell-late-destroyed/result.json` 和
`build/verification/background-bell-manual-dismiss/result.json`：用户先行处理与来源 Pane 销毁后，
设备通过真实 `aa start --ps` 向热 UIAbility 送入原 Want 参数，均被当前 attention/Pane 校验忽略，
进程不重启、工作区保持单 Pane；通知中心手动清除后卡片持续为空，第二来源仍只产生应用内
attention 和抑制日志。三条场景均确认通用文案、相同 HAP 哈希和清理完成。

24 小时过期由 `autoDeletedTime` 交给系统执行，本应用不接收清除事件；软件门固定检查期限存在，
且不得引入通知订阅或后台重试。它与手动 dismiss 共享“投递机会已经消耗、没有回调、没有追发”
不变量，因此不使用缩短产品期限的诊断构建冒充真实 24 小时等待。

最终真实工作负载证据保存在 `build/verification/long-task-notification-passed/result.json`。同一
diagnostic HAP 通过临时隔离的 WSL OpenSSH 连接分别运行真实 shell、独立 `tmux 3.6` 和已登录的
`codex-cli 0.149.0` 只读任务；三者完成后输出标准 BEL，均在整窗后台形成一张通用中文通知，
点击返回原 Pane，随后 SSH 正常关闭。5 条本地命令均一次精确、0 mismatch；临时 sshd、tmux
socket、HDC 反向端口、known_hosts 和 fixture 文件均被清理，应用 Identity 未改动。

权限证据 `build/verification/background-bell-permission-passed/result.json` 证明原系统设置为允许：
临时关闭后后台 BEL 只保留应用内 attention、通知中心为 0 卡片；用户处理该 attention 并重新
允许后，下一后台停留发布一张通知且点击返回成功，最后恢复原设置。设备已有授权尝试历史，
因此没有再次展示首次授权对话框；这不冒充首次弹窗视觉证据，但同时证明产品不会为既有拒绝
历史循环请求。偏好状态机的软件门保证一次持久化 attempted 边界，不清应用数据来伪造首次运行。

`build/verification/device-ssh-auth-20260823T162755223Z/device-ssh-auth.json` 复跑并通过既有
`pane-focus-attention`：活动 Pane 瞬时 BEL、非活动 Tab、双 Pane、BEL flood 合并、进入清除和
并行认证均未被系统通知桥破坏，所有 fixture、known-host 与反向端口清理通过。至此，前台/后台/
最小化、活动/非活动 Tab、双 Pane、跨 Pane 抑制与额度重置、权限禁用/允许、有效/迟到返回、
用户先行处理、Pane 销毁、进程冷启动、手动 dismiss、过期合同和敏感内容边界均有对应软件门或
命名物理证据。该 HAP 仍只是开发期 diagnostic 身份，不是 1.5 正式候选或 AppGallery 能力。

2026-08-24 在 OSC 9/777 共用入口、前后台 focus 修复和最终双语 Agent 指南打包后，又以
test-signed HAP `F796FBCD0786910364F31643806E51513E03402B0C48BCF579AF528E206C0696` 运行原始
无模型 BEL 场景并通过；证据为
`build/verification/background-bell-agent-guide-final-20260824/result.json`。这只证明本文 BEL
下游通知/返回合同没有回归，不替代 Agent 原生 OSC 或后台长时运行证据。

### 2026-08-23 通知避让决策

- **问题：** 在用户没有返回 LeanTTY 时，后续相同文案的 BEL 是否继续刷新系统通知，以及是否
  需要用未读状态、冷却时间或计数器避免短期过度提醒。
- **平台证据：** HarmonyOS 通知 UX 要求不要重复发送相同内容，并要求多条通知采用组合；
  Notification Kit 只提供发布、替换和撤销合同，当前产品链没有可依赖的“用户已读”语义。
  Apple 官方同样明确建议即使用户尚未回应，也不要为同一内容重复通知；Android 官方建议有
  新进展时更新既有通知而不是创建冗余通知。三者共同支持合并和克制，但都不能证明 HarmonyOS
  上一次替换不会再次打扰，因此不把重复 `publish()` 当作静默更新。
- **采用：** 每次连续后台停留只尝试一次系统通知，后续信号只进入既有 Pane attention；窗口
  可见是唯一明确且无需跟踪用户的重置边界。
- **未采用：** 未读/已读监听、固定分钟冷却、延迟补发、每小时计数和后台定时器会增加状态与
  不可解释的追提醒；保留“最新 Pane 替换”则会继续产生系统发布事件，因此一并撤回。
- **参考：** [HarmonyOS Notification UX](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/system-features-notification-0000001793074217)、
  [NotificationManager API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/js-apis-notificationmanager-V13)、
  [Apple Notifications](https://developer.apple.com/cn/design/human-interface-guidelines/notifications)、
  [Android notifications](https://developer.android.com/develop/ui/compose/notifications)。

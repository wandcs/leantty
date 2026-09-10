# 通知验收的权限前置条件与失败清理

## 根因与边界

2026-09-11，候选 `0db0f090cc9053b15204d55f6a49a2df202aa970eaf3e3672192fb668da95e71`
的正式矩阵完成 17 个阶段（含 Mosh 八场景），在长任务 shell 通知阶段停止。
前序权限场景正确恢复了原始关闭状态；长任务脚本没有建立通知已开启的前置条件。
shell 完成文件已出现，产品日志明确记录通知因关闭而延后。恢复窗口后出现系统通知授权
弹窗，旧清理把遮挡误判成零 Pane。原始报告仍为 failed，清理仍为 failed；独立清理
已恢复关闭状态、单 Pane、零通知及临时端点/文件缺失，不回写原报告。

预期：每个通知发布场景独立准备系统开关并在所有退出路径恢复原值。最后正确边界是
shell 完成与产品查询系统开关；第一个错误边界是脚本未经准备便等待发布。通知授权
由系统拥有，工具只保存原值、通过现有设置页切换并重新打开核验。Pane 由产品拥有，
授权弹窗下没有可见输入节点不能证明 Pane 丢失。

产品缺陷假设缺少支持；控制通道失败应单独报告，不能伪装成发布超时。下一项最小验证：
执行真实脚本分支的 L1 反例，再用同一 HAP 的 shell-only L3 证明关闭→开启→发布→
返回→恢复关闭。Agent 工具复用同一准备/恢复流程，先以零模型入口验证集成。

## 外部核对（2026-09-11）

适用环境：ARM64 HarmonyOS PC，OpenHarmony-6.1.1.135，target SDK 6.1.1(24)，
compatible SDK 6.0.2(22)。公开 OpenHarmony 文档用于接口语义，不等同于该商业固件
的完整实现或版本保证。

- [OpenHarmony NotificationManager](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-notification-kit/js-apis-notificationManager.md)：
  开关查询返回布尔值；授权请求需在界面加载完成后调用，可出现系统弹窗；关闭和已有
  弹窗有独立错误码。故测试必须先证明开关状态，不能把缺少发布日志直接归因于产品。
- [通知设置半模态页面上游需求](https://gitee.com/openharmony/notification_distributed_notification_service/issues/IAJ10Q)：
  已完成的接口能力需求，与项目既有设置页路径一致；不证明所有固件的节点或时序稳定。
- [华为开发者社区相近报告](https://developer.huawei.com/consumer/cn/forum/topic/0204222366959258670)：
  检索到启动期请求授权内部错误的提问，症状不同，未获得本次 PC 场景的已验证解决方案。
  不据此加入延时或产品补丁。没有找到匹配本次“前序恢复关闭→后序发布”的上游缺陷报告。
- [Playwright fixtures](https://playwright.dev/docs/test-fixtures)：准备与清理成对、测试独立。
  这里只采用工具设计原则，不把浏览器行为当成 HarmonyOS 保证。

Huawei 动态文档正文和旧版本 raw URL 本次未能读取；不声明已核对其未返回的内容。
现有真机设置页成功证据与公开接口语义一致，没有发现要求改产品授权策略的冲突。

## 修复与验收范围

复用 `notification-regression.ps1`；删除调用方重复 UI 函数。保存原开关，启用并重开
核验后才执行任务；finally 处理权限弹窗、恢复原值、核验通知消失。独立清理步骤分别
捕获错误，保留最初失败；清理失败不得输出 Pass。临时 known-host 删除只发送一次，
等待实际投影缺失，不把输入提交 ACK 当完成。

长任务增加仅限 diagnostic 的 shell-only 入口；正式 shell/tmux/Codex 顺序及固定模型
预算不变。原始失败和已完成的 Mosh 证据保留；本次不修改冻结候选、上游库、产品权限
策略或 WSL 生命周期。先完成工具修复及定向验证，再按 quality-strategy 决定续跑范围；
现有失败清理默认要求 R3，同一候选可保留，但不能手工把诊断提升成正式通过。

## 验证结果

软件检查：通知回归 45 项、Agent SSH gate 29 项通过，包含实际 finally 分支、原开关
捕获、设置/恢复失败、弹窗隔离、早退、已提交删除不重发、投影读取失败不算缺失。
新增反例先在旧实现失败，再在修复后通过。候选兼容性检查从五个实际场景读取 allowlist，
允许本批明确的工具/文档路径，拒绝产品通知代码；不放开 `tools/*` 或产品目录。
`policy,tooling` 定向组通过，未运行 Rust、Web 构建或完整发布门。

同一 HAP 的两次 L3（均为 diagnostic，不是正式验收）：

| 场景 | 结果 | 清理与边界 |
| --- | --- | --- |
| `-DiagnosticHap -ShellOnlyProbe` | shell 完成、通用通知卡片、点击返回、SSH 关闭通过；3 条本地命令无重试/不匹配 | 原通知关闭恢复、单 Pane、零通知、临时 known-host/映射/fixture 清除；零模型请求 |
| Agent `-DiagnosticHap -SshPrerequisiteProbe` | 通知前置、隔离 Tab、SSH 连接/远端命令/关闭通过 | 原通知关闭恢复、测试 Tab 移除、单 Pane、零通知、known-host/映射/sshd/fixture 清除；未启动 Agent，零模型请求 |

本地证据根目录：`build/verification/notification-permission-20260911/`。
shell attempt `564e90c8d0974b14b1336a5a71ab5ab0`，result SHA-256
`f6ec0ca784831cc273ffa89e9786323e936566f2bf05ddc52c60aeb34cbaf910`；
Agent attempt `c80396f181424351a854d8122e5ec09e`，result SHA-256
`140e0630121b1a040194c9545fab221c3e59f11f91aed84abb5086a8b7c52f09`。
`audit-result.json` 独立核对两次最终布局均为单 Pane、临时端点/监听器/进程/目录缺失，
候选哈希及两个冻结 checkout 未变。没有操作 WSL 实例生命周期，没有重写正式失败报告。
初次软件组误在沙箱调用 WSL 被拒绝，随后用桌面用户身份重跑；新增外部读回边界的旧
单测 mock 缺失也已补齐。两者均保留失败记录，不算产品失败。

正式续跑范围确定为 **R3**：当前 release Resume、QH 和 Mosh checkpoint 均绑定精确
harness 身份，原通知阶段 cleanup failed；本批不改恢复合同来保留旧前缀。保留 C0–C2
和原始证据，重新资格确认工具并取得全部 C3，才进入 C4。真实 Agent 通知与 tmux/Codex
工作负载留给正式固定预算，本次零模型诊断不声称覆盖它们。

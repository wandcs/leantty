# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO；1.5.0 等待维护者提交 AppGallery，发布效率改进已授权
>
> 更新日期：2026-08-26
>
> 当前 milestone：[`1.5 — SSH 可靠性、资产互操作、长任务返回与 Agent TUI 兼容`](roadmap.md)
>
> 当前工程阶段：1.5 产品、GitHub 正式发布与维护者交接已闭合；等待 AppGallery 提交与审核，
> 同时改进下一次正式发布的工程效率
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 测试权威：[`quality-strategy.md`](quality-strategy.md)

本文件只保留尚未完成、已经授权的活动工作。完成事实进入相应规范、设计文档和 Git 历史；
历史 checkbox、定向证据和后续 milestone 不在这里维护第二份清单。

## 当前发布基线

`v1.3.0` 已于 2026-08-17 通过 AppGallery 审核并正式上架。`v1.4.0` 已由不可变签名
标签、精确发布源和 GitHub Release 冻结，维护者于 2026-08-22 确认匹配的 production APP
已通过 AppGallery 审核并正式上架。当前工作不修改 `v1.4.0` 的发布身份，也不补做新的
1.4 产品范围。`v1.5.0` 已于 2026-08-26 由不可变签名标签、精确发布源、非草稿
[GitHub Release](https://github.com/wandcs/leantty/releases/tag/v1.5.0) 和归档产物冻结；这不
表示 AppGallery 已提交、通过审核或正式上架。

## 1.5 产品开发闭合事实

1.5 的 SSH 可靠性与资产互操作、长任务 attention/通知/返回、英文默认与明确中文系统语言
的双语界面，以及 Codex CLI、OpenCode、Pi Agent、Qwen Code 的普通 SSH/tmux 兼容矩阵均已
完成产品源、映射软件门、测试签名 ARM64 debug HAP 和适用的物理 HarmonyOS PC 命名场景。

Agent 兼容矩阵按真实适用性闭合，而不是要求每个工具人为发出每种协议：四种 TUI 的输入、
真实中文输入法、raw/alternate、resize、搜索、重连和 tmux 恢复已经覆盖；Qwen tmux 原生
OSC 52 复制与 PageUp/`Ctrl+End` scrollback 已通过。所选 Agent 的真实渲染路径没有发出
OSC 8，LeanTTY 通用 HTTP(S)/OSC 8 激活由独立终端门禁负责，不向 Agent 注入控制序列。
连接中断、半开检测和重连由既有 SSH/ServerAlive 与 Session 合同负责，不按 Agent 重复建立
传输层实现。

受限 OSC 9/777/99 入口复用唯一 BEL attention 所有权并在 Web 边界丢弃远端内容。OpenCode
普通 SSH 的原生 OSC 99 通知、系统提醒与返回通过；OpenCode tmux 上游只查询能力而不发完整
通知帧。Pi direct/tmux 可发原生 OSC 777，但 HarmonyOS 隐藏后暂停 ArkTS/ArkWeb，较晚输出
无法及时形成系统提醒；所选 Agent 没有 OSC 9 原生样本。以上是已验证的平台/上游边界，
不授权常驻服务、第二解析器、Agent 专属 workaround 或额外模型请求。

离线指南已交付中英文 Agent 工作方法，并在最终同源测试 HAP 上确认本地 `help` 链接、中文
Agent 章节、文档内英文切换和英文 Agent 页内跳转。页内锚点曾使英文页面回落中文，已修正为
由语言页本身或其任一后代锚点共同维持语言。完整矩阵、请求/Token 审计、证据身份与失败边界见
[`design/agent-tui-compatibility.md`](design/agent-tui-compatibility.md)；协议、架构、安全、质量和
用户合同分别保留在 roadmap、`architecture.md`、`security-model.md`、`quality-strategy.md`
与用户指南中。

## 当前活动工作

### 1.5.0 AppGallery 提交与审核

1.5.0 的发布源冻结、production/review 构建归档、正式软件与物理门禁、不可变签名标签和
GitHub Release 均已完成；唯一 production signed APP、SHA-256、商店文案和提交清单也已归档
并交付维护者。剩余工作以
[`release-process.md`](release-process.md)、[`versioning.md`](versioning.md) 和
[`quality-strategy.md`](quality-strategy.md) 为执行权威；本节只记录仍未完成的发布结果，
不复制命令或建立第二套流程。

- [ ] 由维护者本人复核并上传唯一 production signed APP，核对商店资料后提交 AppGallery；
  随后按维护者反馈记录提交、审核或上架状态。

不得移动或复用 `v1.5.0` 标签和 Release。若 AppGallery 审核失败或上传产物必须变化，按发布
规则提升版本并重新走发布流程，不在既有版本身份上替换产物。拟议 1.6 Mosh 和其他 roadmap
候选不属于本次发布授权。

### 发布效率改进

维护者于 2026-08-26 授权把 1.5.0 发布复盘转化为下一次正式发布前可执行的工程改进。
本项只改发布、验收和证据工具，不修改 `v1.5.0` 标签、Release、生产包或既有发布结论，也不
授权任何 1.6 产品能力。执行仍以 [`release-process.md`](release-process.md)、
[`quality-strategy.md`](quality-strategy.md) 和
[`test-release-efficiency.md`](test-release-efficiency.md) 为权威，不在本节复制第二套发布流程。

按以下顺序执行：

- [ ] **P0 — 建立候选冻结前的 release-readiness drill。** 用聚焦、可重复且不产生正式候选的
  演练覆盖：中英文系统对话框；性能场景 Preferences 的语义恢复；alternate screen/focus
  reporting 后按受控服务器边界触发 SSH escape；既定 Agent 通知适用性规则的离线重放；
  qualifier、候选库命名空间和 Agent 精确 allowlist 的组合预检；release-mode HAP 不依赖私有
  acceptance marker 的最小 smoke；以及 production/review checkout 的锁定依赖和签名配置
  完整性。演练失败只修复对应工具，不得创建 release commit、正式候选或调用 Agent 模型。
- [ ] **P1 — 将 product candidate 与 acceptance harness 双身份前置为正式合同。** 候选继续绑定
  精确 product commit/tree/HAP 和 manifest；harness 单独绑定 clean commit/tree，并记录两者
  的精确差异。显式 HAP 必须通过候选 manifest/身份解析，不能依赖当前 checkout 的 Git
  common-dir 猜测命名空间；只允许场景声明的 harness-only 路径，不建立宽泛全局放行表。
- [ ] **P1 — 为长矩阵增加原子检查点、可恢复执行和无内容进度。** SSH、通知和 Agent 每个独立
  分组完成后原子记录候选/harness 身份、结果、清理状态和 attempt 链；中断恢复必须先只读审计
  device、reverse、fixture、临时目录和应用状态，再由规则判定 R1/R2/R3/R4。进度只暴露
  Agent/mode/stage/截止时间等非内容元数据，不保留 PTY 输入输出，不自动重试模型请求。
- [ ] **P2 — 把可逆发布资产准备前移并合并发布后状态更新。** 在不可变标签前预生成并审计
  license zip、Release notes、AppGallery 文案、交接清单和附件摘要；标签与 GitHub Release 仍只
  能在全部正式门禁通过后创建。发布完成后用一个状态 PR 同时记录 GitHub Release 与维护者
  交接，避免两轮内容相邻的 CI/合并等待。

本轮工具实现只运行受影响的 `policy/tooling` 软件门和必要的最小真机控制通道检查；不得为了
验证效率改进再次调用 Codex、OpenCode、Pi Agent 或 Qwen Code。完整耗时目标留到下一次正式
发布按同一口径测量：从发布准备核对开始，到 GitHub Release 与维护者交接完成，扣除用户等待
和机器关闭时间。

下一次正式发布在依赖、设备、CI 和网络正常且没有新增产品缺陷时，按以下指标复盘；超出指标
触发原因分析，不得为了满足数字停止必要修复或弱化门禁：

- 实际执行时间目标约 2 小时 30 分钟，正常范围不超过 3 小时；
- release commit 冻结后的 product candidate 正常只构建 1 次；真实产品源或发布输入变化仍须
  重建，已演练 harness 缺陷导致的 candidate 失效目标为 0 次；
- Agent 兼容矩阵只执行 4 个 Agent × direct/tmux 的 8 次固定请求，长任务场景另 1 次，
  0 自动重试、0 计划外诊断请求；
- 中断后 5 分钟内形成可审计的恢复级别与下一条命令，不重跑已经通过且清理完整的检查点；
- GitHub Release 后只需 1 个状态 PR，并最终证明 `HEAD == main == origin/main`、tree 相同、
  ahead/behind 为 `0/0`、工作区干净。

效率改进不得通过并行控制同一物理 PC、复用失效候选、跳过签名/远程摘要/真实设备 smoke、
弱化候选差异 allowlist，或把诊断结果提升为正式发布证据来达成。

## 维护规则

1. 只保留未完成且已授权工作；完成事实同步到权威文档和 Git 历史后从本文件删除。
2. 代码修改、一次通过、构建、安装、窗口出现或 HDC 成功不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

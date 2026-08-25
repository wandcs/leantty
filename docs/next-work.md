# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO；1.5.0 正式发布准备进行中
>
> 更新日期：2026-08-25
>
> 当前 milestone：[`1.5 — SSH 可靠性、资产互操作、长任务返回与 Agent TUI 兼容`](roadmap.md)
>
> 当前工程阶段：1.5 产品开发已闭合；已进入 1.5.0 release preparation
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
1.4 产品范围。

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

### 1.5.0 正式发布准备

维护者已于 2026-08-25 明确启动 release preparation。发布准备以
[`release-process.md`](release-process.md)、[`versioning.md`](versioning.md) 和
[`quality-strategy.md`](quality-strategy.md) 为执行权威；本节只记录仍未完成的发布结果，
不复制命令或建立第二套流程。

- [ ] 通过 PR 把发布源合入 `main`，确认工作区干净、远程一致，并冻结一个精确 GitHub 提交
  作为 1.5.0 release commit。
- [ ] 从隔离的 production/review checkout 对该提交完成签名与廉价预检，构建并归档同源的
  production APP、production HAP 和 review-test HAP；核对 commit、tree、版本、ABI、native
  哈希、签名、产物角色和 manifest。
- [ ] 对未变化的 review-test HAP 完成 L4 全量软件门、acceptance-harness qualification、
  全部适用的物理 HarmonyOS PC 命名场景和最终真实设备 smoke；保留证据与清理结果。
- [ ] 在全部门禁通过后创建并验证不可变签名 `v1.5.0` 标签，发布匹配提交和归档资产的非草稿
  GitHub Release。
- [ ] 向维护者交付唯一可上传的 production signed APP、SHA-256、商店资料和提交清单；由维护者
  本人核对并提交 AppGallery，随后按其确认记录审核状态。

任一产品源、依赖、资源、版本或打包输入变化都会使候选失效，必须形成新的已推送提交并从相应
检查点重建、重验。拟议 1.6 Mosh 和其他 roadmap 候选不属于本次发布授权。

## 维护规则

1. 只保留未完成且已授权工作；完成事实同步到权威文档和 Git 历史后从本文件删除。
2. 代码修改、一次通过、构建、安装、窗口出现或 HDC 成功不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

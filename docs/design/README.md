# LeanTTY 技术方案

本目录为跨组件或高风险功能保存专项技术方案。每份文档只围绕一个大的功能点，说明
用户问题、范围、所有权、实现候选、未决问题、验证方法和停止条件。

## 状态

| 状态 | 含义 |
| --- | --- |
| `WIP` | 仍有待讨论或待验证内容；不是实现承诺 |
| `Accepted` | 产品范围与技术方向已确认；仍需进入 `next-work.md` 才能开始 |
| `Implementing` | 已在 `next-work.md` 中成为活动工作 |
| `Verified` | 已实现并按方案门禁验证；完成事实转入 Changelog/Git，文档只保留仍有长期价值的设计约束 |
| `Closed` | 条件调查或进入门禁已经闭合，产品实现已裁剪；只有文档化的重新进入条件成立时才重议 |
| `Superseded` | 已被另一文档或方向取代，不再指导新工作 |

`project-principles.md` 始终是最高规则，`roadmap.md` 负责 milestone，`next-work.md`
是唯一活动 TODO。方案正文不得维护第二套任务勾选或用 WIP 内容授权实现。

## 当前方案

| 功能点 | 状态 | milestone | 文档 |
| --- | --- | --- | --- |
| SSH 与 Mosh 命令体系 | Accepted 能力取舍基线 | 跨 1.1–1.6 | [`command-system.md`](command-system.md) |
| SSH keyboard-interactive 与多方法认证 | Verified / GitHub/AppGallery 已发布 | 1.1 | [`ssh-authentication.md`](ssh-authentication.md) |
| 工作区键盘导航 | Verified / GitHub/AppGallery 已发布 | 1.1 | [`workspace-navigation.md`](workspace-navigation.md) |
| 终端 scrollback 搜索 | Verified；GitHub/AppGallery 已发布 | 1.2 | [`terminal-search.md`](terminal-search.md) |
| 桌面终端界面与交互收敛 | Verified / 1.2–1.3 | 1.2–1.3 | [`ui-interaction-polish.md`](ui-interaction-polish.md) |
| 最小单文件传输 | Verified / GitHub、AppGallery 已发布 | 1.3 | [`file-transfer.md`](file-transfer.md) |
| 终端输入调度与大粘贴连续可用性 | Verified / GitHub、AppGallery 已发布 | 1.3；粘贴安全体验未排期 | [`terminal-input-scheduling.md`](terminal-input-scheduling.md) |
| SSH Session 终端状态隔离 | Verified 开发候选 / 正式发布门禁待执行 | 1.4 | [`terminal-session-state-isolation.md`](terminal-session-state-isolation.md) |
| 本地命令提示符与输出规范 | Verified / GitHub、AppGallery 已发布 | 1.3 | [`local-command-output.md`](local-command-output.md) |
| 本地命令 Tab 补全 | Verified / GitHub、AppGallery 已发布 | 1.3 | [`tab-completion.md`](tab-completion.md) |
| 启动到首次输入性能 | Verified 开发候选 / 正式发布门禁待执行 | 1.4 | [`startup-performance.md`](startup-performance.md) |
| HSL 本地执行环境入口 | Closed / 进入门禁失败，专用入口已裁剪 | 1.4 决策 | [`hsl-execution-environment.md`](hsl-execution-environment.md) |
| OpenSSH ProxyJump | Verified 开发候选 / 正式发布门禁待执行 | 1.4 | [`proxy-jump.md`](proxy-jump.md) |
| Mosh 弱网连接 | WIP / 未授权实现 | 拟议 1.5 | [`mosh.md`](mosh.md) |

## 最小文档结构

新增方案至少包含：

1. 状态、拟议 milestone、上位规则和实现授权状态。
2. 用户问题、目标、非目标和产品原则评估。
3. 当前事实与证据边界。
4. 所有权、事件链、数据/秘密边界和失败行为。
5. 待讨论、待验证和已确认决策，三者分开书写。
6. 自动化、ARM64 构建和物理 HarmonyOS PC 各自证明什么。
7. 裁剪或停止条件。

方案不重复 milestone 的版本说明，不复制 `next-work.md` 的执行顺序，也不把 SDK 文档、
构建通过或安装启动描述成真机行为已经成立。

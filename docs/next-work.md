# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-17
>
> 当前 milestone：[`1.4 — 启动性能`](roadmap.md)
>
> 当前阶段：启动性能实现与开发候选验收、HSL 第二轮真机调研均已完成；
> HSL 产品入口继续裁剪，1.4 进入集成与正式候选准备
>
> 上位规则：[`project-principles.md`](project-principles.md)

本文件只保留尚未完成、已经授权的活动工作，并按实际依赖顺序执行。完成事实进入
`CHANGELOG.md`、设计文档和 Git 历史；旧 checkbox、定向实现证据、WIP 技术方案及后续
milestone 不在这里维护第二份清单。

## 当前状态与 1.3 发布基线

`v1.3.0` 已由不可变签名标签、精确发布源和
[`GitHub Release`](https://github.com/wandcs/leantty/releases/tag/v1.3.0) 冻结，并于
2026-08-17 通过 AppGallery 审核、正式上架。1.3 的产品实现、候选回归、版本、签名和发布
工作均已完成，旧发布清单和 `release/1.3.0` 分支不再授权新工作；不可变 `v1.3.0` 标签、
Release、精确提交和已归档产物是恢复与追溯基线。

`main` 已进入 1.4 集成周期。1.4 改动继续使用聚焦、短期 topic branch，并通过 PR 合入；
只有正式准备候选时才创建 `release/1.4.0`，该分支不接收新的产品范围。

## 1.4 用户结果与版本边界

1.4 现在只保留一项产品交付：

1. **启动到首次输入性能。** 缩短用户点击 LeanTTY 图标，到首个 Pane 的终端
   能够正确接收并显示第一个字母的时间。窗口出现、页面完成、ArkWeb ready 或提示符进入
   DOM 都只是诊断节点，不代替端到端结果。

启动路径必须保持用户信任、终端正确性、`Tab → Pane → Session`、现有 SSH/认证/主机
校验、可恢复错误和正式包边界。详细方案见
[`design/startup-performance.md`](design/startup-performance.md)。

HSL 公开接口与物理机进入门禁已形成失败结论：当前系统只提供动态地址、手工启动的
`sshd` 和系统终端内部集成，没有三方应用可依赖的公开稳定发现/状态 API、Intent 或文档化
loopback endpoint。1.4 因此不增加 HSL 专用入口，普通 OpenSSH Host 手工连接能力保持不变；
完整证据和重新进入条件见
[`design/hsl-execution-environment.md`](design/hsl-execution-environment.md)。

第二轮普通签名 HAP 与物理机验证没有发现新的公开 HSL 语义接口：应用可以直连已知来宾
`IP:22`，但 Network Kit 不暴露 HSL 网桥或来宾 endpoint，HSL/`sshd` 不发布 `_ssh._tcp`，
HiShell 内的 `loh`、`localhost` 和动态 `eth0` 地址也没有三方调用契约。因此调研按停止条件
闭合，不执行只会验证内部实现的状态/重启矩阵；HSL 专用入口继续裁剪。HSL 作为普通 SSH
服务器使用，不增加专用适配、入口或使用指南，也不改变现有 OpenSSH Host/Identity 权威来源。

## 1. 集成、文档与发布

1. [ ] 把当前 HSL 门禁与“按普通 SSH 服务对待”的最终决策通过 PR 合入 `main`，随后
   `git pull --ff-only origin main` 并确认本地 `main`、`origin/main` 与工作区一致、干净。
2. [ ] 从干净、已推送的精确提交准备正式 1.4 候选，运行 `tools/test-regression.ps1`、
   `tools/verify-pc.ps1` 和完整适用的物理机矩阵，冻结同一候选、签名角色、manifest 和哈希。
3. [ ] 在 production 候选上从真实桌面图标完成冷启动到首字母输入人工确认；安装、启动、看到
   窗口或 Bridge ready 不能替代。
4. [ ] 全部 1.4 门禁闭合后，按 `release-process.md` 从 `release/1.4.0` 准备并合入精确候选，
   发布不可变 `v1.4.0` GitHub Release，再提交匹配 production APP；不移动标签或替换 Release。

## 当前非目标与停止条件

- 不把启动性能工作扩大为应用体积、运行期内存、持续输出吞吐或连接速度综合重构；新的测量
  若发现独立问题，先按产品价值另行评估。
- 不因“ArkWeb 看起来重”或同步 API 看起来可疑就直接替换 renderer、延后安全初始化或建立
  预热机制；只有端到端分段证据授权优化。
- 不做 HSL 安装、启用、创建、删除、升级、修复、用户/软件包/服务/资源管理，不捆绑 Linux
  用户空间或开发工具链。
- 不使用私有 API、固定弱凭据、跳过/自动接受主机密钥、HDC/开发者模式依赖，不建立 HSL
  Host 数据库、Local Transport 或通用执行环境框架。
- 1.5 ProxyJump、1.6 Mosh、1.7 SSH 配置/诊断/资产互操作和未排期的大粘贴安全体验不进入
  1.4。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到 Changelog、设计文档和 Git 历史，并从
   本文件删除。
2. 每项任务必须说明可观察完成条件；构建、安装、窗口出现、ArkWeb ready 或一次 SSH 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

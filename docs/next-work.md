# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-17
>
> 当前 milestone：[`1.4 — 启动性能与 OpenSSH ProxyJump`](roadmap.md)
>
> 当前阶段：启动性能实现与开发候选验收、HSL 门禁结论均已完成；
> 原 1.5 ProxyJump 已并入 1.4，当前工作转入 ProxyJump 技术门禁与实现
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

1.4 现在计划包含两项产品交付：

1. **启动到首次输入性能。** 缩短用户点击 LeanTTY 图标，到首个 Pane 的终端
   能够正确接收并显示第一个字母的时间。窗口出现、页面完成、ArkWeb ready 或提示符进入
   DOM 都只是诊断节点，不代替端到端结果。
2. **OpenSSH ProxyJump。** 用户可以通过一个标准 SSH 跳板机进入无法直接访问的目标环境，
   同时继续复用现有 Host、Identity、主机校验、认证、取消和错误模型；首版只支持单跳，
   覆盖 config `ProxyJump` 与标准 `-J` 一次性入口。

两项交付都必须保持用户信任、终端正确性、`Tab → Pane → Session`、现有 SSH/认证/主机
校验、可恢复错误和正式包边界。启动优化的开发候选已经完成；正式候选仍需按发布流程复验。
详细方案见 [`design/startup-performance.md`](design/startup-performance.md) 与
[`design/proxy-jump.md`](design/proxy-jump.md)。

HSL 公开接口与物理机进入门禁已形成失败结论：当前系统只提供动态地址、手工启动的
`sshd` 和系统终端内部集成，没有三方应用可依赖的公开稳定发现/状态 API、Intent 或文档化
loopback endpoint。1.4 因此不增加 HSL 专用入口，普通 OpenSSH Host 手工连接能力保持不变；
完整证据和重新进入条件见
[`design/hsl-execution-environment.md`](design/hsl-execution-environment.md)。

HSL 调研已经闭合；HSL 只作为普通 SSH 服务器使用，不增加专用适配、入口或使用指南，也不
改变现有 OpenSSH Host/Identity 权威来源。该结论不因 ProxyJump 并入 1.4 而重新打开。

## 1. ProxyJump 技术门禁与范围冻结

1. [ ] 冻结单跳用户契约：OpenSSH config `ProxyJump <jump-spec>` 与
   `ssh -J <jump-spec> target` 进入同一解析和 Session 路径；单个 jump spec 覆盖 config alias
   及标准 `[user@]host[:port]` 形式，目标引用自身、循环、逗号多跳及不支持的表达式必须在
   连接前明确失败。
2. [ ] 冻结两层安全与交互模型：跳板和目标分别解析 endpoint、User、Identity，分别进行
   主机密钥校验与认证；提示和错误必须明确属于 jump 还是 target，且不增加第二套认证 UI、
   Host/Identity 数据库或隐式信任。

## 2. ProxyJump 实现

1. [ ] 扩展唯一 OpenSSH config/命令解析路径，支持单跳 `ProxyJump` 与 `-J`，并让安全的
   `ssh -G` 输出解释有效 jump Host；不接受后静默忽略 `ProxyCommand`、多跳或未知参数。
2. [ ] 让目标 Session 内部拥有跳板连接、`direct-tcpip` channel 和目标连接的完整生命周期；
   只有目标完成主机校验、认证和 PTY 建立后才进入 connected，Terminal Surface 只接收目标
   shell 字节流。
3. [ ] 复用现有密码、私钥、keyboard-interactive、多方法认证和 `known_hosts` 提交入口，
   保证每层只取得为该 Host 解析的凭据，目标 Identity 不提交给跳板，跳板受信不自动信任目标。
4. [ ] 为解析、跳板连接、jump 认证、channel 建立、目标连接、target 认证和 PTY 建立提供
   结构化阶段与错误；取消、超时、Pane 关闭、网络断开和任一层失败必须终止两层未完成工作，
   拒绝迟到事件并释放资源。

## 3. ProxyJump 验证

1. [ ] 在仓库内受控双服务器 fixture 覆盖直连非退化、单跳成功，以及密码、私钥和
   keyboard-interactive 分别出现在 jump/target 层的代表性组合；避免无价值的全笛卡尔矩阵，
   但每种现有认证方法都必须在两层各有证据。
2. [ ] 覆盖两层主机首次确认、已知匹配、指纹变化与删除恢复，以及目标不可达、
   `direct-tcpip` 拒绝、任一层认证失败、取消、超时、断线、循环、多跳和迟到事件。
3. [ ] 验证两个 Pane 经不同跳板并行时状态、认证回答、凭据、输出和清理不串联，并保持
   现有直连 SSH、文件传输、Tab/Pane、终端输入输出和断线恢复回归。
4. [ ] 完成 ARM64 HarmonyOS PC 日常构建与物理键盘 smoke：两层主机确认/认证的当前层级
   清楚，jump/target 错误可区分；Shell、tmux、vim、Agent TUI、复制粘贴、resize、大输出、
   合盖/锁屏和任一层退出后的行为与所有权一致。

## 4. 集成、文档与发布

1. [ ] ProxyJump 用户行为和门禁形成真实完成证据后，更新 `CHANGELOG.md` 的 1.4
   `In development`、离线用户指南、命令 help/补全和长期设计约束；规划文档不能提前声明交付。
2. [ ] 从干净、已推送的精确提交准备正式 1.4 候选，运行 `tools/test-regression.ps1`、
   `tools/verify-pc.ps1` 和完整适用的物理机矩阵，冻结同一候选、签名角色、manifest 和哈希。
3. [ ] 在同一 production 候选上，从真实桌面图标完成冷启动到首字母输入，并通过真实双服务器
   完成 ProxyJump 两层信任/认证、目标 PTY 和错误层级的最终人工确认；安装、启动、一次直连或
   仅看到 connected 都不能替代。
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
- ProxyJump 不扩张为 `ProxyCommand`、远端 shell 拼接、任意多跳、通用端口转发、SOCKS、
  VPN、堡垒机资产管理、共享凭据、连接池或第二套 Host/Identity/认证模型。
- 重新编号后的 1.5 Mosh、1.6 SSH 配置/诊断/资产互操作和未排期的大粘贴安全体验不进入 1.4。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到 Changelog、设计文档和 Git 历史，并从
   本文件删除。
2. 每项任务必须说明可观察完成条件；构建、安装、窗口出现、ArkWeb ready 或一次 SSH 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

# LeanTTY milestones

> 状态：当前版本路线；采用滚动规划
>
> 更新日期：2026-08-08
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 当前执行清单：[`next-work.md`](next-work.md)

本文把长期愿景转换为可交付的版本 milestone，只回答“为什么现在做、这个版本交付
什么用户结果、哪些内容明确不在范围内”。它不维护任务勾选、实施顺序或详细技术
设计。

## 规划边界

LeanTTY 采用滚动规划，不假装能够一次确定项目生命周期内的所有版本：

1. 当前开发版本给出确定范围和发布门禁。
2. 后续 minor milestone 给出拟议主题和进入条件；在进入开发前重新对照产品原则、
   用户证据、平台能力和上一版本结果确认，版本顺序可以据此调整。
3. 更远方向只记录触发条件，不预分配版本号，不据此建设抽象或依赖。
4. 紧急可靠性、安全、兼容性和性能修复可以随时形成 patch 版本，不改变后续 minor
   milestone 的产品顺序。
5. milestone 决定版本边界，但只有写入 [`next-work.md`](next-work.md) 的事项才是活动
   工作；技术方案和候选方向均不单独授权实现。

这条边界服务“可靠、简洁高效”的原则。越远的计划证据越弱，把其提前写成确定功能
清单，反而会让路线图倒逼原则和真实需求让步。

## 跨 milestone：核心质量与愿景验收

每个 milestone 都必须保持终端正确性、用户信任、SSH/Session 生命周期、状态隔离、
HarmonyOS 原生交互和可恢复错误等核心质量；没有修改某个领域，不表示新增功能通过
就可以代替相应回归。核心质量门禁失败时不得发布，当前修复必须进入 `next-work.md`。

完成 roadmap 功能不自动证明使命和愿景达成，条件 milestone 被证据正确裁剪也不表示
路线失败。只有真实用户能够持续把 HarmonyOS PC 作为主要命令行设备、不再仅因终端
限制依赖另一台电脑，并且 LeanTTY 相对可信可负担的替代产品仍有重要独特价值时，才能
判断愿景在当前阶段成立。

完整门禁、有效证据、触发时机和四类验收结论见
[`vision-acceptance.md`](vision-acceptance.md)。该文档不是并行 TODO；愿景复盘发现的
阻断先通过产品原则进入 roadmap，只有属于当前 milestone 时才进入 `next-work.md`。
测试层级、真机矩阵和证据复用边界见
[`quality-strategy.md`](quality-strategy.md)。

## 跨 milestone：SSH 与 Mosh 命令体系治理

LeanTTY 不能继续按“维护者使用时发现缺什么，就补一个命令”的方式演进。删除
`known_hosts` 记录、导出 key 等能力虽然分别解决了真实问题，但如果没有完整能力
地图，产品会长期处于被动补洞状态，也无法判断下一个缺口究竟是核心能力、低频便利，
还是本来就不应由 LeanTTY 承担。

从现在开始，SSH 与 Mosh 命令面遵循以下治理方式：

1. **先建立上游全集。** 以 OpenSSH 与 Mosh 官方手册为基线，完整盘点用户命令、
   主要 option family、配置语义、交互 escape、client/server/helper 边界。
2. **再依次通过决策门。** 每项能力按用户信任、核心任务、职责归属、标准语义、永久
   复杂度和完整交付六道门判定为“必须做”“应该做”“待证实”“不做”或“内部能力”；
   硬否决不能由其他收益抵消，详细规则以 [`design/command-system.md`](design/command-system.md)
   为准。
3. **最后进入版本。** 只有被路线图分配到 milestone、形成专项方案并写入
   [`next-work.md`](next-work.md) 的能力才能实现；上游存在或审计表收录都不授权开发。
4. **保持一个命令心智。** 与 OpenSSH/Mosh 语义一致时优先使用标准名称和参数；只有
   HarmonyOS 权限、LeanTTY key store 或受约束产品范围确实不同，才使用 `host`、
   `key`、`put/get` 等本地命令，并明确差异。
5. **不静默兼容。** 未支持的 option 必须给出明确错误或替代路径，不能忽略后继续，
   也不能使用同名命令却承诺明显不同的安全或数据语义。
6. **成套交付。** 一个能力只有语法、配置、help、错误、取消、安全边界、自动化和所需
   真机验收同时闭合，才算完整；不能只增加 parser 分支。

“完善的命令体系”表示**完整审计、明确取舍、内部一致和错误可预测**，不表示复制
OpenSSH 的全部工具与 option。端口转发、X11、agent、CA/KRL、批处理 SFTP 等能力仍须
独立通过产品原则，不能用“OpenSSH 有”作为实现理由。

统一判定是：只内建由客户端负责、会阻断核心 TTY 工作、能诚实遵循标准语义，并能以
可控复杂度完成安全与生命周期闭环的能力；其余交给标准配置、系统或执行环境，证据
不足的保持 WIP。

正式能力矩阵、明确不做范围和 milestone 分配见
[`design/command-system.md`](design/command-system.md)。该基线跨越 1.1–1.7；它决定
后续版本的命令边界，但不是新的并行 TODO，活动工作仍只进入 `next-work.md`。

## 已完成基础：1.0

### 用户结果

用户已经可以在 ARM64 HarmonyOS PC 上通过一个键盘优先、开箱即用的原生终端，
使用密码或私钥安全连接 SSH 执行环境，并在少量 Tab、最多双 Pane 中完成日常终端
工作。

### 已交付边界

- SSH 密码、私钥、`known_hosts`、Host 配置和密钥管理。
- 正确的 PTY、终端字节流、UTF-8、窗口 resize、焦点、剪贴板和常见 TUI 行为。
- Tab、双 Pane、主题、字号和窗口状态。
- 半开连接检测、断线后的终端内容保留和主机指纹变化恢复。
- 1.0.1 于 2026-07-28 成为首个公开版本；完成事实以 `CHANGELOG.md`、Git 标签和
  GitHub Release 为准。

## 已发布 milestone：1.1 — 可信认证与工作连续性

### 版本目标

> 让受密码、私钥、PAM、动态验证码或多方法认证保护的标准 SSH 环境，都能通过同一
> 条可信、可取消、不会串 Session 的连接路径进入；同时收拢 1.0 发布后发现的状态
> 连续性和键盘效率缺口，并补齐当前密钥、主机信任与命令错误边界中的核心缺口。

### 发布核心

- 完成 SSH `keyboard-interactive`、authentication banner 和多方法认证；正确处理
  `remaining_methods`、`partial_success`、多提示、多轮回答、取消和秘密边界。
- 增加 `ssh-keygen -p` 修改私钥口令和 `ssh-keygen -F` 查询 `known_hosts`；旧/新口令
  不进入命令历史，查询覆盖散列记录、IPv4/IPv6 和非默认端口。
- 让未知 option、未知或会影响目标、认证、主机信任和 Session 的未支持 config
  directive 在连接前明确失败；同步当前命令的 help、补全和测试边界。
- 闭合休眠/ArkWeb renderer 重建后的终端内容、tmux OSC 52 复制、工程 SSH smoke、
  卸载重装持久资产等现有可靠性门禁。
- 保持密码、私钥、主机校验、PTY、Tab、Pane、焦点、剪贴板、窗口、常见 Shell/TUI、
  断线和重连的 1.0 回归行为。

### 可独立裁剪的增强

- `Ctrl+Tab` / `Ctrl+Shift+Tab` 按视觉顺序切换 Tab，并恢复目标 Tab 的活动 Pane。
- `Ctrl+Alt+Left` / `Ctrl+Alt+Right` 只有先通过 ARM64 HarmonyOS PC 的系统、输入法
  和终端透传门禁后才进入版本；失败时直接裁剪，不增加自定义快捷键或兼容别名。

### 明确不在 1.1

- 文件传输、终端搜索、ProxyJump、Mosh 或新的执行环境入口。
- `-4/-6`、安全 `-v`、SSH escape、config import/export、`UpdateHostKeys` 和其他
  1.7 兼容/诊断能力。
- 厂商认证 SDK、验证码生成/保存、第二套 Host/Identity 或厂商特例。
- SFTP 文件管理器、复杂工作区、自定义快捷键和会话恢复。

### 方案与完成定义

- `v1.1.1` 已于 2026-08-08 通过 AppGallery 审核并上架；其发布身份仍由既有 GitHub
  Release、不可变标签、精确提交和归档产物共同确定。
- [`design/ssh-authentication.md`](design/ssh-authentication.md)
- [`design/workspace-navigation.md`](design/workspace-navigation.md)
- [`design/command-system.md`](design/command-system.md)
- 活动顺序和勾选状态只在 [`next-work.md`](next-work.md) 维护。

## 已完成 milestone：1.2 — 终端检索与日常效率

### 为什么现在做

滚动缓冲区搜索和安静、清楚的桌面工作区反馈都属于终端工作本身，是产品原则明确要求
长期做好的高频能力。它们不引入新的执行环境、主机模型或后台生命周期，能够在保持
现有 `Tab → Pane → Session` 和 Terminal Surface 边界的前提下，补齐桌面终端的基础
效率与日常可读性。

### 范围

- 在当前 Pane 的当前内存缓冲区中搜索可见文字与 scrollback。
- 稳定的打开、下一处、上一处、关闭键盘路径；搜索状态只属于当前 Terminal Surface。
- 清楚显示查询、匹配位置和无结果状态，不改变终端内容、选择所有权或远端输入。
- 覆盖普通屏幕、alternate screen、中文、宽字符、大 scrollback、Tab/Pane 切换和
  renderer 重建边界。
- 收敛多 Tab 边界与溢出、固定的新建入口、分屏边界、搜索控件密度、键盘焦点和主题
  token；BEL 使用有限 Tab 提示与来源 Pane 标记，不再包围整个终端内容。
- 在可读性、终端正确性和低性能负担成立时，提供关、低、中、高、极限五档非循环透明度；
  Chrome 与内容区由同一档位派生不同 alpha，非 Off 档只使用一次固定 Regular 根材质。
  不成立时按证据撤回材质或回退不透明，不增加连续参数、独立材质设置或兼容框架。

### 非目标

- 不做跨 Tab/Session 全局搜索、正则表达式语言、搜索历史、索引服务或持久化。
- 不搜索远端文件、命令历史、日志或已销毁 Session。
- 不借此增加命令面板、自定义快捷键或新的通用 UI 框架。
- 不做 Tab 拖动排序、持续动画、全窗口闪烁、通用外观设置、自适应 Tab 宽度或新图标依赖；
  不加入自定义 Gaussian、CSS/WebGL blur 或逐 Pane 动态材质。

### 已满足的进入条件

- 1.1 已发布或已冻结为一个通过全部核心门禁的确切候选。
- WIP 方案中的交互、xterm 集成、输入/选择冲突和真机验收点已经共同确认。
- 明确证明现有 Terminal Surface 可以局部实现，无需增加跨 Session 状态或长期索引。

### 发布状态

- `v1.2.0` 已于 2026-08-13 通过 AppGallery 审核并正式上架；商店版本映射到既有
  GitHub Release、不可变签名标签、精确提交
  `90c20cacf47ac620ccc89d21e70b6cdbbfeb0a68` 和已归档 production APP。

技术方案：[`design/terminal-search.md`](design/terminal-search.md) 与
[`design/ui-interaction-polish.md`](design/ui-interaction-polish.md)。上述条件已闭合，
活动顺序与完成状态只在 [`next-work.md`](next-work.md) 维护。

## 当前 milestone：1.3 — 受约束的单文件交付

### 用户结果

用户无需把 HarmonyOS PC 仅仅当作终端显示器，可以在本地 `L>` 通过同一 Host、
身份和主机校验模型，把一个文件上传到执行环境，或把一个文件下载到系统 Downloads；
任何失败、取消或冲突都不覆盖已有文件，也不留下伪装成完成文件的半成品。

### 最大范围

- 仅提供 `put` / `get` 单文件上传下载，内部使用 SSH SFTP 子系统。
- 本地根固定为用户授权的 Downloads；文件数据由 Rust 流式传输，不经过 ArkTS、
  WebView Bridge 或终端字节流。
- 复用唯一 Host/Identity、认证、主机指纹、取消和错误模型。
- 前台、当前 Pane、短生命周期传输；无覆盖提交，失败和取消清理本任务临时文件。

### 已闭合的可靠性边界

- 公共 Downloads 的原子无覆盖提交在物理 HarmonyOS PC 上成立。
- 远端排他临时文件、标准 rename、并发冲突和服务器差异有受控互操作证据。
- FD/no-follow 路径边界、临时文件所有权、跨重启清理、取消、迟到事件和内存上限闭合。
- 新依赖通过许可证、供应链、ARM64 构建和维护成本审查。
- 重新评估后，收益仍高于权限、SFTP、文件生命周期和支持成本；否则取消整个
  milestone，而不是扩大为文件管理器补救。

### 明确不做

目录浏览、递归、多源、同步、后台队列、覆盖选项、文件预览/打开、任意本地路径和
第二套 Host/Identity 均不进入范围。

完成方案：[`design/file-transfer.md`](design/file-transfer.md)。1.3 已于 2026-08-08 在
1.2.0 提交 AppGallery 审核后进入活动开发；到 2026-08-14，产品实现和适用功能矩阵已经
闭合。剩余候选回归、版本和发布步骤只按 [`next-work.md`](next-work.md) 执行；后续若核心
可靠性出现直接反证，仍应停止发布，而不是扩大为文件管理器补救。

## 拟议 milestone：1.4 — HSL 本地执行环境入口

### 当前系统事实

HarmonyOS PC 当前已经提供 HSL，系统级 Linux 执行环境不再只是未来假设。但 HSL
目前不能像 Windows 的 `wsl` 命令那样由终端直接进入，需要通过 SSH 连接。因此在
当前系统能力下，LeanTTY 对 HSL 的正确定位是“本机上的标准 SSH 执行环境”，不是新的
本地 shell transport。

上述事实来自当前产品规划输入；进入开发前仍须在目标 ARM64 HarmonyOS PC 上确认
HSL 的启用方式、SSH endpoint、身份认证、主机密钥、启动/停止和系统升级行为。

### 用户结果

用户可以从 LeanTTY 清楚、直接地进入本机 HSL，在 HarmonyOS PC 自身完成命令行工作，
而不必先知道内部地址、端口或手工维护一套与普通 Host 平行的配置。

### 拟议范围

- 仍通过现有 SSH Transport、Session、终端和主机校验路径连接 HSL。
- 提供一个最小、可发现的 HSL 入口；具体是系统发现、本地默认 Host 还是固定命令，
  由 WIP 方案和真机能力决定，但不得建立第二套 Host/Identity 权威来源。
- 明确区分“HSL 未启用”“SSH 服务未就绪”“认证失败”“主机密钥变化”和普通网络错误。
- HSL Session 与远端 SSH Session 使用相同的 Tab、Pane、终端、取消和错误恢复模型。

### 非目标与进入条件

- LeanTTY 不安装、创建、升级或管理 HSL，不捆绑 Linux 用户空间、包管理器或发行版。
- 不用回环 SSH 包装成伪本地 shell，也不为尚不存在的直接系统 API 建立 Local Transport。
- 必须先证明 HSL SSH 接口对三方应用公开、稳定、可分发，且无需削弱主机校验、凭据
  隔离或用户信任边界。
- 若 HSL 只能依赖私有 API、固定弱凭据或不稳定 endpoint，则保留普通 SSH 手工连接，
  裁剪产品级 HSL 入口。

技术草案：[`design/hsl-execution-environment.md`](design/hsl-execution-environment.md)。
该 milestone 已进入路线图，但未进入 `next-work.md`，不授权实现。

## 拟议 milestone：1.5 — OpenSSH ProxyJump

### 用户结果

用户可以通过一个标准 SSH 跳板机进入无法直接访问的目标执行环境，同时继续使用
LeanTTY 已有的 Host、Identity、主机校验、认证、取消和错误模型。

### 拟议范围

- 支持 OpenSSH config 中的标准 `ProxyJump` 单跳语义，并提供复用同一状态机的标准
  `-J` 一次性入口；逗号多跳在首版明确报错。
- 使用 SSH `direct-tcpip` 在跳板 Session 内建立目标连接，不调用远端 shell 拼接
  `ssh` 命令。
- 跳板和目标分别执行主机密钥校验与认证，错误必须指出失败发生在哪一跳。
- 目标 PTY Session 仍是 Pane 唯一拥有的业务 Session；跳板连接只是其传输前置状态。

### 非目标与进入条件

- 不支持 `ProxyCommand`、任意命令执行、通用端口转发、动态代理或堡垒机资产管理。
- 首个版本不承诺逗号分隔任意多跳；单跳不足以覆盖真实主要场景时，重新评估整个范围，
  不能无界扩展状态机。
- 必须先有受控双服务器基线，并证明嵌套认证、主机校验、取消、超时和错误恢复不会
  串 Session 或泄露目标/凭据。

技术草案：[`design/proxy-jump.md`](design/proxy-jump.md)。该 milestone 未进入
`next-work.md`，不授权实现。

## 拟议 milestone：1.6 — Mosh 弱网连接

### 用户结果

用户在 ARM64 HarmonyOS PC 合盖、短暂离线、网络抖动或地址变化后，可以继续一个
面向交互式终端的会话，而不是只能等待 SSH 超时或重新建立全新远端 shell。

### 拟议范围

- 通过 SSH 完成主机校验、认证和远端 `mosh-server` 启动，再使用 Mosh 协议承载一个
  交互式终端 Session。
- 首版支持 `mosh [user@]host|alias`、固定 UDP port/range、受控 `--server=PATH`、
  `--predict=auto/always/never`、IPv4/IPv6 选择和 `Ctrl-^ .` 强制断开。
- 明确展示 SSH bootstrap、UDP 建连、已连接、网络中断、恢复和不可恢复失败状态。
- 复用现有 Tab、Pane、Terminal Surface 与用户输入边界，但按 Mosh 的真实生命周期
  建立局部状态，不假装它与 SSH 字节流具有相同语义。
- 只面向交互式终端；文件传输和其他 SSH 子系统继续使用 SSH。

### 非目标与进入条件

- 不内置或自动安装服务器端 `mosh-server`，不把手机移动网络作为范围依据。
- 不接受任意 `--ssh="..."` 或 `--client=PATH`，不建立第二套 Mosh Host/Identity 配置，
  不管理 firewall/NAT，也不承诺关闭客户端后重新附着旧 Mosh server。
- ProxyJump 最多帮助 SSH bootstrap；目标 UDP 仍须能从 LeanTTY 直接到达，不能把
  “SSH 经跳板成功”描述为“Mosh 一定可用”。
- 不为了 SSH/Mosh 两个实现提前建设通用传输插件框架。
- 必须先在目标 PC 上建立休眠、短断网、网络切换、UDP 受限网络和终端兼容性基线，
  证明 Mosh 相比现有 SSH 重连提供持续、可测量的核心价值。
- 新协议、密码学、Unicode/终端状态同步依赖必须通过许可证、供应链、ARM64 构建、
  安全和长期维护审查；收益不足时取消 milestone。

技术草案：[`design/mosh.md`](design/mosh.md)。该 milestone 未进入 `next-work.md`，
不授权实现。

## 拟议 milestone：1.7 — SSH 配置、诊断与资产互操作

### 用户结果

用户在 IPv4/IPv6、长延迟、主机密钥轮换或从已有 OpenSSH 环境迁移配置时，可以诊断
并解决问题，而不必依靠另一台电脑临时修改 LeanTTY 内部资产；这些能力继续使用唯一
Host、Identity、`known_hosts` 和 config，不引入第二套配置模型。

### 拟议范围

- `ssh -4/-6` 与 `AddressFamily`，以及脱敏、结构化、可关闭的安全 `ssh -v`。
- `~.`、`~?`、`~I` 基本 SSH escape，与 Pane 关闭、连接信息和错误恢复统一。
- `ConnectTimeout`、`ServerAliveInterval`、`ServerAliveCountMax` 的受控 config 子集。
- 经过服务端扩展、原子持久化和失败恢复验证的 `UpdateHostKeys`。
- 通过 HarmonyOS 文件授权进入唯一资产的 config import/export；导入前验证，关键
  directive 未支持时明确失败，导出保留非 LeanTTY 管理原文。
- `ssh-keygen -c` 修改 key comment；在库、安全和互操作证据成立时支持 ECDSA key
  导入和认证，但不因此新增 ECDSA 生成入口。

### 非目标与进入条件

- 不加入通用 `-o`、任意 `-F`、任意算法降级、`ProxyCommand`、local command、agent、
  forwarding、X11、tunnel 或第二份 known-hosts/config 权威来源。
- 不因配置导入而承诺完整 OpenSSH parser；`Include`、safe `Match`、token expansion、
  certificate 等仍按证据触发，不能静默忽略后声称兼容。
- 进入开发前必须收集受控 IPv4/IPv6、超时、半开连接、host-key rotation 和真实 config
  样本，并确认每个子能力可以独立裁剪，不让 1.7 变成无限兼容版本。

命令边界与单项门禁见 [`design/command-system.md`](design/command-system.md)。该 milestone
未进入 `next-work.md`，不授权实现。

## 未分配版本的长期触发方向

以下内容只记录项目治理触发条件，不构成功能路线图：

| 方向 | 重新讨论的必要触发条件 | 当前不提前做的内容 |
| --- | --- | --- |
| HSL 直接本地 transport | HarmonyOS 提供公开、稳定、可分发且明显优于 SSH 的直接 HSL 终端 API | 为不存在的 API 预留 Local Transport、并存两套 HSL 入口 |
| SSH 远端命令与 `-t` | 高频 TTY 场景和统一 quoting、退出状态、取消、输出所有权方案 | 用当前空白拆词 parser 接受任意远端命令 |
| SSH certificate/host CA | 真实标准环境阻断、库支持和完整信任生命周期证据 | CA 签发、证书管理平台或企业专有认证 |
| FIDO/PKCS#11 | HarmonyOS 公开稳定硬件接口、隔离和物理设备交互证据 | 自建硬件 key service 或暴露 OpenSSH helper |
| 复杂 `ssh_config` | 真实配置样本证明 `Include`、safe `Match` 或 token expansion 的收益高于解析成本 | `Match exec`、任意本地命令或静默兼容 |
| Mosh remote command/高级网络参数 | 与 SSH 共用的远端命令模型或受控多地址/NAT 证据 | 任意 `--ssh` shell 字符串、Mosh 网络管理平台 |
| 项目退出 | 出现持续、可信、明显更好且大多数目标用户可负担的替代产品，LeanTTY 不再提供重要独特价值 | 为项目存续进行功能竞赛 |

触发发生后，先重新评估 [`project-principles.md`](project-principles.md) 的愿景、产品
边界、信任和长期成本，再决定是否替换现有 SSH 路径或调整项目方向。

## milestone 变更规则

1. 调整当前版本核心、版本顺序或产品边界时，必须记录动机、证据、替代方案和裁剪
   结果；不能只修改 `next-work.md` 的一个勾选项。
2. WIP 技术方案可以提出候选，但不能自行把能力加入 milestone。
3. milestone 确认后，才把其第一段可执行工作写入 `next-work.md`；完成事实进入
   `CHANGELOG.md` 和 Git 历史，不在路线图复制验收记录。
4. 版本号遵循 [`versioning.md`](versioning.md)；AppGallery、签名 tag 和发布顺序遵循
   [`release-process.md`](release-process.md)。

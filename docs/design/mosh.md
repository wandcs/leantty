# Mosh 弱网连接技术方案

> 状态：WIP；用户证据、协议依赖和目标平台可行性均待验证，未授权实现
>
> 拟议 milestone：1.6
>
> 更新日期：2026-08-23
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：未进入 [`next-work.md`](../next-work.md)

> 命令面治理：[`command-system.md`](command-system.md)

## 用户问题与目标

SSH 可以检测半开连接并重连，但合盖、短暂离线、网络抖动或地址变化通常仍会终止
当前远端 shell。Mosh 的价值候选是让交互式终端在这些变化后继续，而不是把 LeanTTY
定位成移动终端或承诺永久在线。

目标是在物理 ARM64 HarmonyOS PC 上确有持续弱网问题时，提供一个明确的 Mosh
Session：SSH 只负责安全 bootstrap，Mosh 负责随后可恢复的交互式终端同步。

## 进入前必须建立的证据

- 在目标 PC 的办公、合盖、锁屏、Wi-Fi 抖动和网络切换场景建立 SSH 断线分布与用户
  影响基线，证明问题持续存在且重连不能满足核心工作。
- 确认目标用户控制的主要执行环境可以安装并运行兼容 `mosh-server`。
- 确认 HarmonyOS 三方应用的 UDP、后台/休眠和网络变化能力足以支撑协议恢复。
- 先测量收益，再确定恢复时间、丢失率和性能门槛；不以功能存在本身作为版本理由。

## 拟议范围

- 使用现有 SSH Host、Identity、主机校验和多方法认证启动远端 `mosh-server`。
- 解析结构化 bootstrap 结果后建立一个 Mosh UDP 会话；不把服务器输出当作任意 shell
  命令继续执行。
- 显示 bootstrap、UDP 建连、connected、interrupted、restoring、failed 等明确状态。
- 一个 Pane 拥有一个 Mosh Session 和一个 Terminal Surface；输入、resize、焦点和
  终端状态不能跨 Pane。
- Mosh 只承载交互式终端。SFTP、文件传输、ProxyJump 和其他 SSH 子系统不复用该
  UDP 会话。

## 非目标

- 不内置、上传、自动安装或升级 `mosh-server`。
- 不承诺 UDP 被企业网络、防火墙或代理阻断时仍可工作。
- 不以手机、平板、竖屏或纯触控移动场景作为产品范围依据。
- 不把 SSH 和 Mosh 抹平成一个隐藏真实差异的通用 Transport 接口。
- 不实现通用 roaming VPN、端口转发、文件同步或后台任务平台。

## 初步所有权与事件链

```text
Pane → Mosh Session
  → SSH bootstrap (existing SSH security path)
  → validate server bootstrap result
  → Mosh protocol state + UDP socket
  → Terminal Surface
```

Mosh Session 是独立生命周期，因为它拥有 UDP、加密状态、序列/同步状态和网络恢复；
这满足新增局部类型的技术原则。但 SSH Session 与 Mosh Session 不需要提前共享一个
公共插件层：共同的 Host 解析与认证策略可以复用，协议状态必须按真实边界分别实现。

## 安全与数据边界

- SSH bootstrap 继续执行标准主机密钥校验与认证，不通过 shell 文案绕过信任。
- bootstrap 产生的临时连接秘密只存在于当前 Session 内存，不进入终端、日志、
  Preferences、持久资产或剪贴板，并在成功、失败或取消后清理。
- UDP 端点、协议版本和服务器输出都视为不可信输入，必须校验长度、格式和允许范围。
- 不记录终端内容；网络诊断只记录安全状态、时序和错误类别。

## 待研究与讨论

- 采用现有 Rust Mosh 实现、协议库还是局部实现的安全性、维护性、许可证和活跃度。
- Mosh 对终端 Unicode、宽字符、滚动历史、alternate screen、OSC、标题、剪贴板、
  鼠标和现代 TUI 的实际兼容边界。
- 远端 `mosh-server` 命令、端口范围、locale 与版本协商如何在不增加大量设置的情况
  下保持可诊断。
- HSL 是否允许 UDP loopback Mosh 没有优先价值；本 milestone 主要针对远端弱网环境，
  不能为了复用而和 HSL 入口合并。
- Mosh Session 与现有断线后 `ltty>`、重连、终端内容保留语义如何区分。
- ProxyJump 后的 Mosh bootstrap/UDP 可达性不是首版默认组合，需独立证明才讨论。

## 验证门禁

### 自动化与协议

- bootstrap 成功/失败、恶意或超长输出、版本不兼容、UDP 超时和错误密钥。
- 有序/乱序/重复/丢失数据、网络中断与恢复、地址变化、取消、Pane 关闭和迟到事件。
- 两个 Mosh Session 以及 SSH/Mosh 并行时状态、密钥、终端和清理不串联。
- Unicode、resize、持续输入、大输出和协议资源上限。

### ARM64 HarmonyOS PC 与真实服务器

- 正常网络下 Shell、tmux、vim、less 和 Agent TUI 基础兼容。
- 合盖、锁屏、Wi-Fi 暂断、网络切换、UDP 被阻断、服务器重启与 `mosh-server` 缺失。
- 与同场景 SSH 的恢复时间、会话保留和用户操作对比，证明收益而非仅证明能连接。
- 检查 hilog、Preferences、终端内容和崩溃信息不泄露 bootstrap 秘密。

## 裁剪与停止条件

如果目标网络普遍阻断 UDP、可靠库不可维护、终端兼容明显低于当前 SSH，或真机测量
不能证明持续核心收益，则取消 1.6。不能通过捆绑服务器、扩张为网络平台或牺牲 SSH
可靠性来维持 Mosh milestone。

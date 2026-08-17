# HSL 本地执行环境入口技术方案

> 状态：WIP；系统接口与真机证据调查已进入当前工作，产品实现仍有条件
>
> 当前 milestone：1.4.0
>
> 更新日期：2026-08-17
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：[`next-work.md`](../next-work.md) 只授权先完成公开接口与真机进入门禁；门禁
> 通过并锁定最小用户模型后才授权产品实现

## 当前事实与证据边界

HarmonyOS PC 当前已经提供 HSL，LeanTTY 不再需要把“系统级 Linux 执行环境”仅作为
未来假设。但是 HSL 目前不支持像 Windows `wsl` 命令一样从终端直接进入，需要通过
SSH 访问。

因此现阶段 HSL 是“运行在本机、通过标准 SSH 接入的执行环境”。LeanTTY 已有的 SSH
Transport 是正确起点，不应仅因为目标位于本机就建立第二套 Local Transport。

本文尚未确认以下真机事实：HSL 的标准发现接口、地址与端口稳定性、SSH 服务启动
时机、用户与凭据建立方式、主机密钥生命周期、网络隔离、多实例能力和系统升级行为。
这些内容必须在物理 ARM64 HarmonyOS PC 上验证，不能从“HSL 已存在”继续推断。

## 用户问题与目标

如果用户仍需手工查找 HSL 的内部 endpoint、拼接 SSH 参数并维护额外配置，HSL 虽然
已经存在，却没有成为一个打开 LeanTTY 就能工作的本地执行环境入口。

目标是在不建设 Linux 环境、不削弱 SSH 安全边界的前提下，为 HSL 提供一条清楚、
可发现、可恢复的进入路径，并让它继续遵循普通 Tab、Pane、Session 和 Terminal
Surface 行为。

## 非目标

- 不安装、启用、创建、删除、升级或修复 HSL。
- 不捆绑发行版、BusyBox、Linux 用户空间、包管理器或开发工具链。
- 不管理 HSL 内部用户、软件包、文件、服务或资源配额。
- 不通过私有 API、固定弱凭据、跳过主机密钥校验或自动信任换取“零配置”。
- 不并存 HSL Host 数据库与普通 OpenSSH config 两个权威来源。
- 不为尚不存在的直接系统终端 API预建 Local Transport 或通用执行环境框架。

## 候选用户模型

### A. 普通 SSH Host

用户手工把 HSL endpoint 写入 OpenSSH config，再运行 `ssh <alias>`。这是当前能力的
基线，不需要产品功能，但发现成本高，也不能给出 HSL 专属的启用/未就绪错误。

### B. 系统 HSL 入口

LeanTTY 通过公开系统能力发现 HSL SSH endpoint，并把它映射为一个系统来源的本地
目标；连接仍进入现有 Host 解析、主机校验、认证和 Session 状态机。此方案是当前
首选候选，但只有系统 API、endpoint 与凭据边界被验证后才能确定其 UI 和持久化方式。

系统目标不能悄悄覆盖用户同名 Host。若必须落入 OpenSSH config，应使用清楚、稳定的
生成规则，并保证用户配置仍是唯一可检查的结果；若系统 endpoint 每次动态变化，则
只把发现结果作为当前连接输入，不复制为长期 Host 数据库。

### C. 直接本地 transport

当前不可行，也不进入 1.4。只有 HarmonyOS 将来提供公开、稳定、可分发的直接 HSL
终端 API，并证明其明显优于 SSH 时，才单独重新评估。

## 初步事件链与所有权

```text
App Shell: 用户选择进入 HSL
  → HSL discovery adapter: 只读取公开系统 endpoint/状态
  → SshConfig/connection policy: 形成一次有效连接目标
  → Session: 主机校验、认证、取消、断线、重连
  → SSH Transport → HSL sshd
  → Terminal Surface
```

- HSL discovery adapter 只有在公开系统边界真实存在时才成立；它不拥有 Session。
- Session 继续拥有连接生命周期，Rust/russh 继续拥有 SSH、PTY 和字节流。
- HSL 与远端 Host 不能共享隐式全局连接或凭据；每个 Pane 仍拥有自己的 Session。
- System Services 可以报告 HSL 状态，但不能绕过认证或替代 OpenSSH 主机校验。

## 待共同确认与验证

- HSL 是否提供三方应用可用的公开发现/状态 API；如果没有，是否存在稳定且文档化的
  loopback endpoint。
- SSH endpoint 是固定、动态还是按 HSL 实例变化，是否存在多个 HSL 环境。
- HSL 的用户、密码/密钥如何初始化，LeanTTY 能否只复用现有 Identity 和认证状态机。
- HSL sshd 未启动时，系统是否提供可解释状态；LeanTTY 是否有权启动，还是只能引导
  用户在系统设置中启用。
- HSL 重建、升级或重置后主机密钥如何变化，如何避免自动信任本机目标。
- HSL 的启动耗时、合盖、锁屏、系统重启和资源回收对 SSH Session 的影响。
- 入口名称、位置和快捷键如何保持可发现，同时不增加第二套主机管理界面。

## 验证门禁

### 文档与接口

- 只采用公开 HarmonyOS/HSL 能力，记录系统版本、API、权限和分发限制。
- 明确 endpoint、身份、主机密钥和生命周期的权威来源，没有硬编码敏感值。

### 自动化

- 系统目标与用户 Host 不冲突，动态发现结果不写入第二套长期数据库。
- HSL 未启用、未就绪、endpoint 变化、认证失败、主机密钥变化和取消分类明确。
- HSL Session 与远端 Session 并行时状态、输出、认证和重连不串联。

### 物理 HarmonyOS PC

- 首次启用、正常进入、关闭/重启 HSL、锁屏、合盖、系统重启和系统升级后的行为。
- 密码、私钥、`keyboard-interactive`（若 HSL 支持）、主机密钥首次确认与变化恢复。
- 至少两个 Pane 分别连接 HSL 与远端服务器，验证焦点、输入、输出、剪贴板和生命周期。
- 确认不依赖开发者模式、HDC、私有权限或商店版本不可用的接口。

## 裁剪与停止条件

如果 HSL 没有公开稳定的发现/接入能力，或产品入口必须绕过主机校验、保存固定凭据、
依赖私有 API，那么 1.4 不增加专属入口。用户仍可把 HSL 当作普通 SSH Host 手工配置；
LeanTTY 不为保持 milestone 而接管 HSL 或构造伪本地 shell。

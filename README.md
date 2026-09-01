# LeanTTY

**简体中文** | [English](README.en.md)

**LeanTTY 是为鸿蒙系统打造的键盘优先 SSH / TTY 终端，让开发者和运维人员能够可靠、
高效地进入 Linux 子系统、服务器和开发环境，完成专业命令行与 Coding Agent 工作。**

![LeanTTY 1.5 在鸿蒙电脑上的左右分屏](docs/assets/leantty-1.5-workspace.png)

> **当前支持范围：** 物理 ARM64 HarmonyOS PC 与键鼠场景。MatePad 和纯触控场景尚未支持。
>
> **当前版本状态：** 维护者于 2026-08-29 确认 1.5.1 已通过 AppGallery 审核并正式上架。
> 对应源码与不可变发布产物见
> [GitHub Release](https://github.com/wandcs/leantty/releases/tag/v1.5.1)。

## 为什么选择 LeanTTY

- **简洁：** 保留一条清楚的 SSH / TTY 主路径，不建立另一套主机资产平台，也不追求大而全。
- **高效：** 多标签、最多双分屏、终端搜索、系统剪贴板和稳定的键盘路径，帮助用户减少切换并
  快速找回上下文。
- **安全：** 没有 LeanTTY 账号、广告、分析 SDK、遥测或 LeanTTY 云服务；主机配置和已验证
  密钥保存在设备上的受保护本地存储中。
- **稳定：** 连接、输入输出、焦点、尺寸、剪贴板、断线与恢复都以可预测为目标，并在物理
  HarmonyOS PC 上验证关键交互。
- **现代化：** 自然使用鸿蒙系统的窗口、键盘、剪贴板、语言和通知能力，并面向今天的
  OpenSSH、tmux、编辑器与 Coding Agent TUI 工作流。

## 适合哪些场景

### 把鸿蒙电脑的 Linux 子系统作为本机执行环境

在支持的鸿蒙电脑上，可以安装华为官方[融合开发引擎（Linux 子系统）](https://consumer.huawei.com/cn/support/content/zh-cn16091898/)，
在 openEuler 中运行 Shell、工具链、tmux、编辑器或 Coding Agent，不需要先拥有外部服务器。
当前需要用户在子系统中手工启动 `sshd`、查看当前 IP，并把它配置成普通 SSH Host；LeanTTY
不会自动安装、启动、发现或管理 Linux 子系统。

### 连接服务器和远程开发环境

如果已经有 Linux 服务器、开发机或其他 SSH 执行环境，可以沿用 OpenSSH Host 配置、私钥和
单跳 ProxyJump，通过同一套键盘工作区进入不同任务。

### 运行需要长时间交互的 TUI 与 Coding Agent

LeanTTY 1.5 已为 Codex CLI、OpenCode、Pi Agent 和 Qwen Code 的选定稳定版本建立普通 SSH 与
tmux 兼容基线。当远端程序发出受支持的终端提醒信号时，LeanTTY 可以提供克制的系统提醒并
返回来源分屏；它不会分析终端内容来猜测任务是否完成。

## 核心能力

- SSH 密码认证，以及 OpenSSH Ed25519、RSA、ECDSA 私钥认证
- `known_hosts` 主机指纹校验、OpenSSH Host 配置和单跳 ProxyJump
- OpenSSH 配置与密钥导入导出、连接超时、ServerAlive 和一次性脱敏诊断
- 多标签、每个标签最多双分屏、终端搜索、链接打开与系统剪贴板
- 当前前台分屏中的受控单文件 `put` / `get`
- 中英文原生界面；命令、技术输出和远端终端内容保持原样
- ArkTS / ArkUI 应用外壳、Rust / russh SSH 传输与 ArkWeb / xterm.js 终端渲染

## 开始使用

1. 在鸿蒙电脑的应用市场中搜索 **LeanTTY** 并安装当前已上架版本。
2. 准备一个可访问的执行环境：鸿蒙电脑上的融合开发引擎，或已有 SSH 服务器。
3. 在 LeanTTY 中配置普通 SSH Host，核对首次连接的主机指纹，然后开始工作。
4. 首次连接、键盘交互、文件传输、数据保留与恢复见[用户指南](docs/user-guide.md)。

LeanTTY 是执行环境的入口，不内置 Linux、本地 Shell、Coding Agent、模型服务或 SSH 服务器。

## 信任与产品边界

LeanTTY 只会为用户主动发起的 SSH 连接和操作处理必要数据。SSH 协议数据会发送到用户选择的
服务器；系统浏览器、HarmonyOS 与 AppGallery 也有各自的数据处理边界。完整说明见
[隐私政策](PRIVACY.md)与[安全模型](docs/security-model.md)。

LeanTTY 当前不是 GUI SFTP 文件管理器、堡垒机、协作审计平台或大规模主机资产管理工具；也
不为手机、竖屏、纯触控和虚拟键盘优先场景引入当前复杂度。长期设备范围可以扩展到外接实体
键盘的 MatePad，但只有经过对应真机适配与验证后才会正式支持。

## 文档

- [用户指南](docs/user-guide.md)
- [产品原则](docs/project-principles.md)
- [版本路线图](docs/roadmap.md)
- [隐私政策](PRIVACY.md)
- [安全政策](SECURITY.md)
- [支持与常见问题](SUPPORT.md)

## 开发与贡献

开发环境需要 Windows、DevEco Studio 与 HarmonyOS SDK API 6.1.1 (24)，以及带有
`aarch64-unknown-linux-ohos` 目标的 Rust 1.96+。真实键盘、窗口、生命周期和 SSH 交互必须在
物理 ARM64 HarmonyOS PC 上验证。

```powershell
# 构建
.\tools\build-all.ps1

# 日常相关检查示例
.\tools\test-regression.ps1 -Group policy,tooling

# 需要真机交互时的开发循环
.\tools\dev-pc.ps1
```

正式发布使用独立的完整门禁。开始贡献前请阅读[贡献指南](CONTRIBUTING.md)、
[编码指南](docs/coding-guide.md)、[质量策略](docs/quality-strategy.md)和
[发布流程](docs/release-process.md)。

## License

LeanTTY 使用 [Apache-2.0](LICENSE) 许可证。第三方组件继续遵循各自许可证，详见
[第三方声明](docs/THIRD_PARTY_NOTICES.md)。

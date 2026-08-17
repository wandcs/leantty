# HSL 本地执行环境入口技术结论

> 状态：进入门禁已完成；1.4 产品级 HSL 专用入口已裁剪
>
> 判定日期：2026-08-17
>
> 验证目标：物理 ARM64 HarmonyOS PC（HAD-W32，HarmonyOS 6.1.0.135）
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 当前授权：不实现 discovery adapter、HSL 专用 UI、命令、Host 数据或 Local Transport；
> 只有本文“重新进入条件”满足并重新写入 [`next-work.md`](../next-work.md) 后才能恢复产品实现

## 结论

HSL 当前可以作为本机上的普通 SSH 目标使用，但不能成为 LeanTTY 1.4 的产品级专用入口。

公开资料和目标真机共同确认了以下事实：

- HSL 地址不固定，官方要求用户进入 Linux 环境后通过 `ipconfig` 或 `ip addr` 自行查看。
- HSL 不支持 `systemctl`，`sshd` 需要用户在 Linux 环境中手工启动。
- 当前没有面向三方 HarmonyOS 应用的公开 HSL 发现/状态 API、稳定 Intent，或文档化的
  loopback SSH endpoint。
- 系统终端能够显示 openEuler 入口并不构成三方应用接口；真机上的相关进程、网卡名称、
  Unix socket 和数据目录都是内部实现，不是可分发契约。

因此，LeanTTY 无法在正式商店包中可靠区分“HSL 未安装”“HSL 未启动”“endpoint 已变化”
和“`sshd` 未就绪”，也不能在不依赖私有实现的前提下生成一次有效连接目标。进入门禁按预设
停止条件判定为**失败**，不进入产品实现。

## 公开资料证据

华为官方《[融合开发引擎（Linux子系统）相关问题](https://consumer.huawei.com/cn/support/content/zh-cn16091898/)》
适用于 HarmonyOS 6.0/6.1，并明确说明：

- 当前 HSL IP 不固定，需要在来宾环境中执行 `ipconfig` 或 `ip addr` 查看；
- 当前不支持 `systemctl`，SSH 示例要求用户执行 `which sshd` 后手工运行
  `sudo /usr/sbin/sshd`；
- 网络模式可为 NAT 或 host-only，host-only 只与主机通信；当前不支持 IPv6；
- 当前只支持 openEuler，并存在主用户、资源回收和系统版本相关约束；
- HarmonyOS 6.1 与融合开发引擎 1.1.0.0+ 的 `loh [cmd][args]` 用法被限定在 HiShell 页签，
  文档没有把它定义为三方应用 API 或独立系统命令。

华为官方《[终端应用下拉菜单 openEuler 置灰](https://consumer.huawei.com/cn/support/content/zh-cn16071791/)》
说明系统终端入口依赖 HarmonyOS 6.0+ 和从应用市场安装的融合开发引擎。它证明系统产品之间
存在集成，但没有公布三方应用可调用的发现、状态或连接契约。

截至判定日期，[HarmonyOS SDK 文档中心](https://developer.huawei.com/consumer/cn/doc/) 与
[应用开发导读](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-dev-guide)
没有 HSL/Fusion Development Engine Kit、API、Intent 或 loopback endpoint 文档。公开文档
缺失不能单独证明接口不存在，但与包能力和真机服务证据一致，不能授权正式产品依赖。

## 物理机证据

目标机为 HAD-W32，系统版本 `HAD-W24 6.1.0.135(SP11C00E100R13P3log)`，ABI 为
`arm64-v8a`。验证通过 HDC 只读采集完成；HDC 仅作为诊断工具，不是产品路径。

### 安装包与能力边界

- 系统终端 `com.huawei.hmos.hishell` 版本 6.1.1.31，分发类型为 `os_integration`，安装来源为
  `pre-installed`。其模块 `hasIntent=false`；公开 skill 只有桌面入口和打开 shell 脚本文件，
  没有 HSL 发现、状态或执行 Intent。该系统包还申请了 `CUSTOM_SANDBOX`、
  `GET_BUNDLE_INFO_PRIVILEGED` 等普通商店应用不能据此复用的能力。
- openEuler 镜像包 `com.huawei.developer.rgm.images_openeuler22.03` 版本 1.1.0.7，由 AppGallery
  安装，`hasIntent=false`，没有请求权限；其可见 Ability 只声明普通桌面入口，没有 HSL
  endpoint 或状态 skill。
- 公共系统参数与系统服务注册表中没有 HSL、openEuler、RGM、Linux Fusion 或虚拟机发现项。

### 当前运行状态不构成接口

采集时 HSL 正在运行。系统内部可见 `linux_fusion_service`、`hmos_fusion_manager`、
`rgm_manager`、`stratovirt` 和 `virtiofsd` 等进程；虚拟机命令行使用 `/data/virt_service/...`
下的私有 QMP、console 与 virtiofs socket。这些路径需要系统服务身份，未出现在公开 SDK。

当前主机桥为 `172.16.105.1/24`，来宾 `172.16.105.2` 可达且 TCP 22 可连接。这只是本次运行
快照：地址不是 loopback，且官方明确说明 HSL IP 不固定，因此不能硬编码 `172.16.105.2`、
根据内部网卡名推导 endpoint，或把一次发现结果长期写入另一套 Host 数据库。

`loh` 在普通 HDC shell 中不是可执行命令；结合官方只说明 HiShell 页签用法，它属于系统终端
集成证据，而不是 LeanTTY 正式包可以调用的公开执行边界。

## 未继续执行的验证

门禁第一前提已经失败，因此没有继续改变 HSL 状态、凭据或主机密钥，也没有为满足清单而做
停止/重启、合盖、锁屏、系统升级和多 Pane 连接矩阵。那些验证只有在公开发现边界成立后才有
产品意义；现在执行只会证明 HDC 或内部路径可用，不能证明 AppGallery 包可交付。

## 保留的用户路径

LeanTTY 继续把 HSL 当作普通 OpenSSH Host：用户在 HSL 中启动 `sshd`、查看当前 IP，并在自己
的 OpenSSH config 中维护 Host alias，然后从 LeanTTY 执行 `ssh <alias>`。连接继续复用现有
SSH Transport、Session、认证、Identity 和主机密钥校验，不增加 HSL Host/Identity 权威来源，
也不自动信任本机目标。

LeanTTY 不安装、启用、启动、停止、升级或修复 HSL，不管理 Linux 用户、凭据、`sshd`、软件包
或资源，也不从内部网卡、进程、socket、包名或固定地址猜测 endpoint。

## 重新进入条件

只有同时满足以下条件，HSL 产品入口才可重新进入 `next-work.md`：

1. 华为公开并文档化三方应用可使用的 HSL 发现/状态 API、稳定 Intent，或稳定 loopback
   endpoint，并说明系统版本、权限、生命周期和分发限制；
2. 普通签名的 production/AppGallery 包可以调用该接口，不依赖 HDC、开发者模式、系统签名、
   私有权限、内部目录、内部网卡名或固定弱凭据；
3. 物理 ARM64 HarmonyOS PC 证明 endpoint、`sshd` 就绪、身份、主机密钥和系统生命周期可在
   不削弱 SSH 安全边界的情况下形成一次连接输入；
4. 方案继续复用现有 SSH Transport、Session、Host/Identity 和主机校验，不建立 Local
   Transport、第二套数据库或 HSL 管理器。

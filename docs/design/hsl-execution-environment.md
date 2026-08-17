# HSL 本地执行环境入口技术结论

> 状态：第一轮进入门禁失败；第二轮公开接口与替代接入调研已启动，产品实现仍未授权
>
> 判定日期：2026-08-17
>
> 验证目标：物理 ARM64 HarmonyOS PC（HAD-W32，HarmonyOS 6.1.0.135）
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 当前授权：只进行公开资料/SDK 调研、最小普通签名测试 HAP 和物理机验证；不实现 discovery
> adapter、HSL 专用连接入口、Host 数据或 Local Transport。只有本文“重新进入条件”满足后
> 才能恢复产品实现

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

2026-08-17 用户进一步授权启动 HSL 调研项目。该决定重新打开的是证据调查，不是产品实现；
第一轮门禁结论在出现新的公开、稳定、可分发接口证据前继续有效。

## 第二轮桌面调研

测试 PC 暂不可用期间，已对 HarmonyOS 6.1.1/API 24 本地 DevEco SDK、HarmonyOS SDK 文档
索引、OpenHarmony 官方源码和 OpenSSH 官方源码进行静态复核。

### API 与源码结果

- ArkTS/JS/NDK SDK 中没有 HSL、openEuler、`loh`、RGM、Linux Fusion 或虚拟机管理接口、
  Kit、系统能力或 HSL Intent 声明。
- SDK 中名称相近的 `FusionConnectivity` 是基于蓝牙的伙伴设备发现，`ScenarioFusionKit` 是
  场景化 UI/文件组件；二者均与 Linux 子系统无关，不能因名称相近复用。
- Network Kit 的公开 `getAllNets`/`getConnectionProperties` 可以返回通用网络句柄、接口名、
  地址和路由，但没有 HSL、虚拟机类型、实例 ID 或 `sshd` 状态字段。
- HarmonyOS 公开 mDNS API 只能发现主动发布的服务；HSL 官方资料没有声明 `_ssh._tcp` 服务，
  OpenSSH Portable 官方源码也没有内置 mDNS/Avahi 发布逻辑。
- OpenHarmony 官方源码中没有目标真机上的 `linux_fusion_service`、`hmos_fusion_manager` 或
  `rgm_manager` 实现，说明这些是当前 HarmonyOS 商业系统内部组件，不是已公开的 OpenHarmony
  契约。
- `CUSTOM_SANDBOX` 在 OpenHarmony 权限定义中属于 `system_basic` 的受限权限。即使系统终端
  拥有该权限，也没有公开接口表明它能授予或代理 HSL endpoint；LeanTTY 不申请与用户结果
  无直接、文档化关系的受限权限。

### 替代接入模型比较

| 方案 | 当前证据 | 结论 |
| --- | --- | --- |
| 公开 HSL API/Intent/loopback | 文档、API 24 SDK 与 OpenHarmony 源码均未发现 | 最理想；等待平台公开后重议 |
| 显式拉起系统终端/openEuler Ability | 真机包存在桌面入口，但无 HSL Intent、状态或返回值契约 | 最多打开系统界面，不能形成连接目标；不作为专用入口 |
| Network Kit 枚举接口与路由 | API 公开，但只提供通用网络属性 | 依赖内部网卡名或地址模式才能猜测 HSL，不能区分其他虚拟机；不采用 |
| 扫描本地网段或 TCP 22 | 可能发现某个 SSH banner | 会探测无关目标，不能证明它是 HSL，也不能解释生命周期；不采用 |
| mDNS/稳定 hostname | 平台具备 mDNS API，但 HSL/sshd 没有发布契约 | 真机只做一次否证/确认；无官方承诺前不进入产品 |
| `loh`/HiShell 脚本跳转 | 官方只说明 HiShell 页签，普通 shell 中不存在独立命令 | 系统终端内部集成，不作为 LeanTTY 执行或发现边界 |
| 用户维护普通 OpenSSH Host | 现有 LeanTTY 已完整支持 | 当前唯一可靠产品路径；保持单一 Host/Identity 权威来源 |
| 官方步骤的 HSL 使用指南 | 不需要新权限、接口、后台服务或状态模型 | 可独立评估，但必须诚实保留手工启动 `sshd` 和动态 IP 步骤 |

### 当前建议

HSL 项目现阶段应保持为“平台接口调研 + 真机最小探针 + 可选手工使用指南”，而不是进入
discovery adapter 或专用连接 UI 开发。这样既持续关注平台新能力，又不会把一次真机内部地址、
包名或系统终端行为固化为长期维护负担。

测试 PC 可用后，只验证可能改变门禁结论的事实：普通签名应用能否获得带 HSL 语义的网络/状态
信息、HSL 是否发布稳定服务名、显式 Ability 是否有公开结果，以及官方流程中的 endpoint、
`sshd`、认证和主机密钥生命周期。详细清单以 [`next-work.md`](../next-work.md) 为准。

### 官方支持提问草案

> 面向普通签名并通过 AppGallery 分发的 HarmonyOS PC 三方应用，是否存在公开、稳定的 API、
> Intent、系统服务或文档化 loopback/hostname，可查询融合开发引擎（HSL）的安装状态、运行
> 状态、实例、IPv4/SSH endpoint 与生命周期？如果存在，请提供 Kit/API、最低系统版本、权限
> 等级、分发限制和 endpoint 稳定性说明。`loh` 是否仅供 HiShell 使用，还是有三方应用调用
> 契约？如果当前没有，是否有公开规划中的替代接口？

该草案只保存在项目文档中；向华为开发者支持提交属于外部沟通，需用户另行确认。

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

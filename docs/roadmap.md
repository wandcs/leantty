# LeanTTY milestones

> 状态：当前版本路线；采用滚动规划
>
> 更新日期：2026-08-25
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

## 跨 milestone：发布、推广与反馈闭环

推广是产品交付的持续工作，不单独占用一个功能版本，也不要求停止后续开发。
每个公开 milestone 都按以下节奏形成可核验的闭环：

1. 候选与发布准备期同步准备 README、AppGallery 介绍、截图、演示和技术文章
   素材；素材只能使用已经通过对应发布门禁的产品事实。
2. 对应精确版本在 AppGallery 可获取后，再发布包含该版本能力的对外内容；
   GitHub Release、测试 HAP 和本地源码不能代替商店可获取性。
3. 以鸿蒙 PC、HSL/openEuler、Code Agent 和 LeanTTY 的可复现实践为主干，诚实
   保留手工启动 `sshd`、查询动态 IP 和通过普通 SSH Host 连接的当前边界；
   不宣传未实现的 HSL 自动发现或管理。
4. 发布后持续收集真实设备、核心任务、阻断问题和恢复路径；反馈可以调整
   尚未开始的 milestone，但不为追逐竞品功能数打断已在收口的版本。

只有已授权、尚未完成的具体推广交付才进入 [`next-work.md`](next-work.md)；
渠道候选、文章草稿和发布后反馈本身不得成为第二份活动 TODO。

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
[`design/command-system.md`](design/command-system.md)。该基线跨越 1.1–1.6；它决定
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
  1.5 连接、诊断与互操作能力。
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

## 已发布 milestone：1.3 — 受约束的单文件交付

### 用户结果

用户无需把 HarmonyOS PC 仅仅当作终端显示器，可以在本地 `ltty>` 通过同一 Host、
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

完成方案：[`design/file-transfer.md`](design/file-transfer.md)。1.3 已形成不可变
[`v1.3.0` GitHub Release](https://github.com/wandcs/leantty/releases/tag/v1.3.0)，并于
2026-08-17 通过 AppGallery 审核、正式上架。该发布身份由标签、Release、精确提交和归档
production 产物共同冻结，不再由发布分支承载。`main` 后续已完成 1.4 并进入
发布后工程优化；后续功能版本仍使用聚焦、短期 topic branch 和正式候选阶段才创建的
release branch。

## 已完成 milestone：1.4 — 启动性能与 OpenSSH ProxyJump

### 版本目标

1.4 包含两个核心结果：启动优化与 OpenSSH ProxyJump。前者缩短
用户点击 LeanTTY 图标，到本地终端能够正确接收并显示第一个字母的时间；后者让用户通过一个
标准 SSH 跳板机进入无法直接访问的目标执行环境。`v1.4.0` 已由不可变签名标签、
精确发布源、GitHub Release 和归档发布产物冻结；维护者于 2026-08-22 确认匹配的
production APP 已通过 AppGallery 审核并正式上架。该商店状态来自维护者确认，不由
本地源码或 GitHub 发布推断。
启动窗口出现、页面加载或 ArkWeb ready 只用于定位分段耗时；ProxyJump 仅解析成功、跳板已连
或目标 TCP 可达也不等于目标 TTY 已可用。

原拟议 1.5 OpenSSH ProxyJump 已于 2026-08-17 合并到 1.4，不再保留独立的 ProxyJump 1.5
发布计划。2026-08-20 路线回顾进一步将连接可靠性/诊断与配置迁移/资产互操作
合并为 1.5，并曾把长任务体验和 Mosh 排为 1.6、1.7。2026-08-23 在 1.5 尚未进入
正式候选时，长任务注意力与返回路径又并入 1.5，Mosh 相应调整为 1.6；MatePad 双模式
仍是受真机阻塞的 2.0 战略 milestone，获得测试设备后可依据本文的抢占规则前移。

原条件 HSL 本地入口已于 2026-08-17 完成公开接口与物理机进入门禁。由于没有三方应用可用的
公开稳定发现/状态 API、Intent 或文档化 loopback endpoint，该入口按预设停止条件整体裁剪，
不进入 1.4 产品实现，也不阻止启动性能版本发布。

### 启动性能用户结果与范围

用户点击 LeanTTY 后，可以更快进入真正可工作的 `ltty>`：首个字符不会丢失、延迟到达、
出现在错误 Pane 或只在空壳界面之后才开始初始化。主指标、基线、分段边界和候选对比见
[`design/startup-performance.md`](design/startup-performance.md)。

- 以物理 ARM64 HarmonyOS PC 上“点击应用图标 → 第一个字母已由终端正确显示”为主指标。
- 分开记录冷启动和温启动分布，并把 Ability、页面、ArkWeb/xterm、Bridge、提示符与输入
  回显作为诊断节点。
- 1.3 日常冷启动基线与主导阶段已由物理机分段和 A/B 确认；最小方案已经共同锁定并形成
  冷启动与温启动各 20 次的真机候选分布，数据规模、升级、失败恢复与交互护栏已经闭合。
- 正确性、安全、密钥与主机信任、首帧可读性、焦点和输入完整性都是硬约束。
- 只保留有真实端到端收益、没有明显长期复杂度的优化；无收益的预热、缓存、延后或特殊
  分支应撤回。

启动性能不以更早显示 splash、空窗口、不可输入的提示符或隐藏真实初始化作为完成；不增加
常驻后台服务、启动守护进程、第二套状态缓存或需要用户理解的新设置，也不延后必须在首次
输入前成立的安全与持久化边界。

### HSL 进入门禁结论

HarmonyOS PC 已提供 HSL，但当前官方规格要求用户手工启动 `sshd`，并在 Linux 环境中查看
不固定的 IP。目标 HAD-W32 真机上的系统终端、openEuler 镜像包、内部虚拟化进程、网桥和
socket 没有形成普通 AppGallery 应用可依赖的公开发现契约；HiShell 的 openEuler 入口和
`loh` 命令也没有三方应用 API 文档。

因此 1.4 不增加 discovery adapter、HSL 专用 UI/命令、Host 数据或 Local Transport，不从
内部网卡名、进程、socket、包名或固定地址猜测 endpoint。用户仍可在 HSL 中手工启动
`sshd`、查看 IP、维护 OpenSSH Host alias，并通过 LeanTTY 现有 SSH Transport、Session、
认证和主机校验路径连接；这一普通 SSH 基线不因入口裁剪而退化。

完整证据与未来重新进入条件见
[`design/hsl-execution-environment.md`](design/hsl-execution-environment.md)。只有华为公开稳定、
可分发的三方发现/状态 API、Intent 或 loopback endpoint，并经普通签名 production 包和物理
ARM64 HarmonyOS PC 验证后，HSL 产品入口才可重新排期。

2026-08-17 完成第二轮 HSL 调研。普通签名 HAP 能直连已知 HSL `IP:22`，但 Network Kit
看不到 HSL 网桥或来宾 endpoint，8 秒 `_ssh._tcp` 发现没有服务，HiShell 的 `loh` 仍只暴露
内部执行结果而非三方接口。因此没有重新进入产品实现；HSL 沿用普通 OpenSSH Host 路径，
不提供专用入口、适配或指南。该结论不因 ProxyJump 并入 1.4 而重新打开，也不授权以内部
网卡名、地址扫描、包名或系统权限实现 HSL 专用入口。

### OpenSSH ProxyJump 用户结果与范围

用户可以通过一个标准 SSH 跳板机进入无法直接访问的目标执行环境，同时继续使用
LeanTTY 已有的 Host、Identity、主机校验、认证、取消和错误模型。

- 支持 OpenSSH config 中的标准 `ProxyJump` 单跳语义，并提供复用同一状态机的标准
  `-J` 一次性入口；逗号多跳在首版明确报错。
- 使用 SSH `direct-tcpip` 在跳板 Session 内建立目标连接，不调用远端 shell 拼接
  `ssh` 命令。
- 跳板和目标分别执行主机密钥校验与认证，错误必须指出失败发生在哪一跳。
- 目标 PTY Session 仍是 Pane 唯一拥有的业务 Session；跳板连接只是其传输前置状态。

#### 非目标与进入条件

- 不支持 `ProxyCommand`、任意命令执行、通用端口转发、动态代理或堡垒机资产管理。
- 首个版本不承诺逗号分隔任意多跳；单跳不足以覆盖真实主要场景时，重新评估整个范围，
  不能无界扩展状态机。
- 必须先有受控双服务器基线，并证明嵌套认证、主机校验、取消、超时和错误恢复不会
  串 Session 或泄露目标/凭据。

完成方案：[`design/proxy-jump.md`](design/proxy-jump.md)。实现、验证与发布事实以该方案、
`CHANGELOG.md`、不可变标签和 GitHub Release 为准；ProxyJump 不再是当前活动工作。

## 当前 milestone：1.5 — SSH 可靠性、资产互操作、长任务返回与 Agent TUI 兼容

1.5 产品开发已于 2026-08-25 闭合，当前没有已授权的产品工作；正式候选与发布准备仍须
维护者单独启动并写入 `next-work.md`。

### 用户结果

用户在长延迟、半开连接或从已有 OpenSSH 环境迁移配置时，可以在 LeanTTY 内理解
失败、恢复连接并复用已有资产；在远端 shell、tmux 或 Code Agent 中运行长任务时，
也不必持续盯住 LeanTTY，可以从有界提醒准确返回仍然有效的来源 Tab/Pane。主流 Agent
CLI/TUI 自身发出的标准终端通知、常用键盘输入、复制、链接、scrollback、resize 和生命周期
行为也应在真实 SSH/tmux 工作链中可用，并由一份克制的中英文指南说明稳定使用方法。这些
能力继续使用唯一 Host、Identity、`known_hosts`、config、Pane attention 和 Session 所有权，
不引入第二套连接、资产或任务模型。

### SSH 范围与裁剪结果

- `ssh -4/-6` 与 `AddressFamily`，以及脱敏、结构化、可关闭的安全 `ssh -v`。
- `~.`、`~?`、`~I` 基本 SSH escape，与 Pane 关闭、连接信息和错误恢复统一。
- `ConnectTimeout`、`ServerAliveInterval`、`ServerAliveCountMax` 的受控 config 子集。
- 经过服务端扩展、原子持久化和失败恢复验证的 `UpdateHostKeys`。
- 通过 HarmonyOS 文件授权进入唯一资产的 config import/export；导入前验证，关键
  directive 未支持时明确失败，导出保留非 LeanTTY 管理原文。
- `ssh-keygen -c` 修改 key comment；在库、安全和互操作证据成立时支持 ECDSA key
  导入和认证，但不因此新增 ECDSA 生成入口。

上述子能力必须能够独立验证和裁剪。合并为同一 milestone 表示共同改善“连接、排障、
迁移”这条用户路径，不表示必须为了版本号保留每一项候选。

### SSH 非目标与裁剪条件

- 不加入通用 `-o`、任意 `-F`、任意算法降级、`ProxyCommand`、local command、agent、
  forwarding、X11、tunnel 或第二份 known-hosts/config 权威来源。
- 不因配置导入而承诺完整 OpenSSH parser；`Include`、safe `Match`、token expansion、
  certificate 等仍按证据触发，不能静默忽略后声称兼容。
- 对每个候选收集受控网络、超时、半开连接、host-key rotation 和真实 config 样本，
  并确认诊断输出不会泄露密码、口令、私钥、远端敏感内容或不必要的主机资产。
- 合并后仍按用户结果和证据控制范围，不让 1.5 变成无限的 OpenSSH 兼容版本。

### 当前长任务注意力与返回范围

- 以现有 BEL 的有限 Tab 强调和来源 Pane 标记为应用内基线，不回退为全窗口闪烁或
  持续动画。
- 仅在整个应用窗口处于后台、最小化或不可见时，通过 HarmonyOS 公开稳定的本地
  通知能力给出有界提醒；通知授权拒绝不得影响终端和应用内 attention。
- 每次连续后台停留最多尝试一次系统通知；用户没有返回 LeanTTY 时，后续同 Pane 或跨 Pane
  BEL 只累积既有应用内 attention，不刷新、追发或延迟补发。窗口重新可见是唯一重置边界。
- 通知只携带定位所需的 LeanTTY 本地状态，默认不复制远端输出、Agent 回答、
  命令、凭据或未脱敏主机信息。
- 点击有效提醒后返回对应 Tab/Pane；Session 已结束、Pane 已销毁、信号已被用户处理
  或提醒已过期时不复活旧状态。
- BEL 继续作为最小、跨工具的注意信号；同时支持已有主流 Agent CLI/TUI 原生使用的
  OSC 9、OSC 777 与精简 OSC 99。OSC 99 只接收完整 title/body 帧，元数据限于 `i/p/e/d`；
  有界 `p=?` 查询只返回 `p=title,body` 与原 query ID，不拼接 `d=0` 分片、不保存 ID，也不实现 action、close、alive、buttons、
  icon 或其他生命周期语义。三者只被归一化为现有空 payload Pane attention，远端 title、
  正文和其他参数在 Terminal Surface 边界内完成长度限制与格式校验后丢弃，不进入 Bridge、
  日志、系统通知或持久状态。
- OSC 9/777/99 受限输入复用 BEL 已有的一次后台停留一次投递、稳定来源、有效/迟到返回、权限和清理
  合同，不新增协议专属通知类型、文案、优先级、设置或第二套 attention 状态。

### Agent CLI/TUI 原生兼容与指南范围

- 以当前稳定版本的 Codex CLI、OpenCode、Pi Agent 与 Qwen Code 建立物理 ARM64
  HarmonyOS PC 兼容矩阵；记录确切工具版本、运行环境和配置，不把测试脚本在任务结束后
  追加的 `printf '\a'` 当作工具原生通知证据。
- 在普通 SSH 与远端 tmux 内分别验证工具原生完成/等待注意信号、`Shift+Enter` 等实际使用的
  组合键、多行与大段粘贴、中英文输入法、OSC 52 复制、OSC 8 链接、alternate/raw/scrollback、
  LeanTTY 搜索、resize、最小化/恢复、断网和重新连接。只对真实阻断建立产品修复；测试矩阵
  本身不授权升级 xterm、增加键盘协议或建立 Agent 兼容层。
- 在当前离线使用指南中增加简洁的中英文 Agent 工作方法：远端 tmux/screen 负责持久任务，
  LeanTTY 负责 TTY、提醒和准确返回；说明工具通知、raw/scrollback、远程复制和 `put/get`
  的适用边界。通用稳定方法优先，工具专属示例必须标明核对日期或版本且不得扩展为配置百科。

### 长任务非目标与进入条件

- 不内置 Agent、编辑器、任务队列、提示词系统、云 relay、账号或跨设备同步。
- 不解析远端自然语言或屏幕内容猜测“Agent 已完成”、“正在等待确认”或“任务失败”。
- 不展示或保存 OSC 9/777/99 携带的远端 title、正文、标识、工作目录、任务状态或其他 payload，不让
  协议编号、Agent 品牌或远端字符串决定本地通知文案和业务状态。
- 不为维持通知新增常驻后台服务、隐式保活、第二套 Session/attention 所有权或通用
  通知框架。
- HarmonyOS PC 公开通知 API、后台/最小化生命周期、热/冷启动点击返回、用户先行处理、来源
  Pane 销毁、手动 dismiss、权限禁用/恢复和 shell/tmux/Codex 标准 BEL 已由同一签名 ARM64
  diagnostic HAP 与命名场景证明成立；产品保留最低可用 `OTHER_TYPES`。若正式候选门禁失败，
  只保留现有应用内 attention，不使用私有系统接口、地址猜测或前台伪装绕过。
- 必须用真实长任务与物理 PC 闭合重复、过期、跨 Pane 串扰、权限拒绝、应用重启和
  敏感内容边界；开发期探针、模拟点击或窗口出现不能代替端到端返回结果。
- 2026-08-25 最终真机矩阵确认：Codex direct/tmux 原生 BEL、Qwen tmux BEL 和 OpenCode
  direct 原生 OSC 99 均完成通用通知与准确返回；OpenCode tmux 只发能力查询，Pi direct/tmux
  原生 OSC 777 与 Qwen direct 的较晚完成信号会在窗口隐藏后遇到 HarmonyOS ArkTS/ArkWeb
  暂停。所选 Agent 没有 OSC 9 原生样本，也没有在受控真实渲染路径发出 OSC 8；前者保留软件
  协议覆盖，后者复用通用链接门禁，不注入控制序列。以上均作为上游或平台适用性边界闭合，
  不触发常驻服务、第二解析器或 Agent 专属 workaround，指南按尽力而为披露。

### 当前产品语言范围

- HarmonyOS 原生界面和 LeanTTY 自有图形控件只维护英文默认与中文两版；系统语言明确为
  中文时使用中文，其他及未知语言回退英文，不增加菜单语言切换或应用内语言设置。
- 终端 Help、错误、风险、警告、建议、命令、参数和状态保持英文技术语言；远端字节原样
  透传，日志和自动化标识保持稳定英文。
- 中文使用用户能够直接感知的“标签页”“分屏”“SSH 连接”，不引入“窗格”；内部
  `Tab/Pane/Session` 所有权和协议名不因显示文案改变。
- 具体资源边界、平台依据和中英文真机门禁见
  [`design/product-language.md`](design/product-language.md)，活动状态只在 `next-work.md` 维护。

### 2026-08-23 范围合并决策

- **动机：** 1.5 尚未进入正式候选，原 SSH 范围已经闭合；在同一开发版本中继续补齐
  “长任务发出标准注意信号后能够离开并准确返回”的高频键盘 TTY 路径，比立即冻结一个
  只改善连接与迁移的版本形成更完整的用户结果。
- **证据：** 现有 BEL 已有 Pane 所有权、稳定 Tab 聚合、有限动画、重复合并、进入/输入
  清除和物理 PC 验收基线。新增工作的核心缺口是公开系统通知合同与点击返回生命周期，
  不需要建立 Agent 任务模型或重写 Terminal/Session 所有权。
- **替代方案：** 保持 SSH-only 1.5、再发布独立 1.6 可以缩短本次发布收口，但会增加一次
  独立版本和发布成本，并把同一条“可靠离开并返回远端工作”路径拆成两个相邻版本；当前
  没有已经冻结的 1.5 候选需要保护，因此不采用。
- **裁剪与顺序：** 只并入标准 BEL 驱动的有界提醒和有效来源返回；自然语言推断、私有
  Agent 协议、常驻保活与通知框架继续不做。原 1.6 删除，Mosh 顺位调整为 1.6，2.0
  MatePad 的设备门禁和抢占规则不变。

### 2026-08-24 Agent 兼容范围扩展决策

- **动机：** 1.5 已闭合的长任务门禁证明 shell、tmux 和真实 Codex 工作负载完成后显式输出
  BEL 可以形成有界提醒，但没有证明主流 Agent CLI/TUI 自身的通知配置、控制序列和高频输入
  在 LeanTTY 中原生互操作。用户明确决定在 1.5 正式候选前补齐这条真实使用链。
- **采用方向：** 先建立 Codex CLI、OpenCode、Pi Agent 与 Qwen Code 的原生真机兼容
  矩阵，再把 OSC 9/777 作为现有 Pane attention 的受限输入，最后交付一份克制的中英文
  Agent 使用指南。三项均进入 `next-work.md`，1.5 产品开发状态重新打开。
- **未采用方向：** 不解析 Agent 内容或状态，不加入 Agent 品牌文案、任务模型、专属设置、
  shell integration、增强键盘协议、内联图片或通用通知框架；OSC 99 当时未由矩阵自动授权，
  后续仅按下面独立决策进入精简接收子集。矩阵发现的新缺口必须
  单独通过产品原则和真实阻断证据，不能随本次授权自动实现。
- **依赖顺序与停止条件：** 原生矩阵先冻结确切 wire behavior 和失败边界；OSC 实现复用现有
  attention/通知所有权并在 Terminal Surface 丢弃 payload；指南只记录最终验证成立的行为。
  任一公开协议若无法在不泄露内容、不引入第二状态或不破坏 BEL/终端语义的前提下实现，应
  停止该协议实现并把证据提交维护者，而不是增加兼容特例。

### 2026-08-24 OSC 99 精简子集决策

- **动机与证据：** OpenCode direct/tmux 的无内容 PTY 证据均出现 OSC 99，但旧分析器未区分
  `p=?` 查询与通知帧；当前 OpenTUI 源码证明它先查询能力，并以
  `p=body:e=1:d=1` 完整帧结束一次通知。完全排除 OSC 99 会失去一个已选主流 Agent 的原生提醒，
  完整实现则会引入 LeanTTY 不需要的远端通知状态机。
- **采用方向：** 只接收 1024 bytes 内的完整 title/body 帧；允许 `i/p/e/d` 仅用于格式校验，
  Base64 只校验不解码，全部字段随后丢弃并归一为既有空 payload attention。为让 OpenTUI 选择
  该协议，只对有界 `i=<id>:p=?;` 同步返回 `p=title,body` 与原 ID；不声明其他能力、不保留 ID、
  不组装分片，因此不增加第二套通知或 Session 所有权。
- **明确拒绝：** `p=close/alive/buttons/icon`、`d=0`、action/close report、未知或重复元数据、
  畸形 Base64、控制字符和超长帧均失败关闭。LeanTTY 不宣称兼容完整 Kitty desktop notification。
- **停止条件：** 若 OpenCode 后续必须依赖已声明范围外的能力或跨帧状态才能发出完成信号，先重新评审协议
  承诺；不得伪装成完整终端能力，也不得为单一 Agent 增加品牌分支。

### 2026-08-25 Agent 兼容与指南闭合决策

- **完整性判断：** 四种 Agent 的普通 SSH/tmux 矩阵已经覆盖真实中英文输入、raw/alternate、
  resize、搜索、重连和 tmux 恢复；Qwen tmux 另以一次短固定请求证明原生 OSC 52 写入，并用
  零模型本地命令证明 PageUp/`Ctrl+End` scrollback。连接中断与半开检测属于既有 SSH、
  ServerAlive 和 Session 合同，不按 Agent 重建第二套传输门禁。
- **协议适用性：** OSC 9/777/99 接收和共享下游由软件门与真机结果共同闭合；没有所选 Agent
  原生 OSC 9 样本、Agent 未发 OSC 8、OpenCode tmux 不发完整通知、HarmonyOS 隐藏后暂停解析，
  都是已经定位并公开记录的适用性边界，不要求伪造 wire behavior 才能完成验收。
- **指南结果：** 最终同源测试 HAP 已显示技术英文 `help`、中文 Agent 章节、文档内英文切换和
  英文 Agent 页内跳转。检查中发现英文子章节锚点会回落中文，已把语言选择从“语言页根节点
  target”修正为“语言页或其任一后代 target”，并完成红绿真机复验。
- **闭合结论：** 上述结果满足 1.5 用户目标，同时保持一个 Terminal Surface、Pane attention、
  Session、浏览器和指南所有权。1.5 产品开发重新闭合；不再为重复结论消耗 Agent Token，
  release preparation 仍由维护者另行授权。

命令边界与单项门禁见 [`design/command-system.md`](design/command-system.md)。其中 SSH
产品开发曾按 `next-work.md` 执行，原 SSH 范围已经闭合。首个 `ConnectTimeout` 切片已经闭合。
`AddressFamily` / `ssh -4/-6`
完成标准基线后因当前物理 PC 缺少可重复的全局 IPv6/IPv6 SSH fixture 路径而暂缓，不能以
parser 测试代替；第二个基本 SSH escape（`~.`、`~?`、`~I`）和第三个
`ServerAliveInterval/ServerAliveCountMax` 半开检测切片已经闭合。UpdateHostKeys 的标准与
russh `0.62.5` 能力门禁确认依赖只暴露公告回调，不提供 proof request/reply、session binding
和验签所需公开 API；该候选按用户信任原则裁剪并记录重新进入条件。安全 `ssh -v` 已完成
一次性入口、固定结构化事件、字段级脱敏，以及 direct/ProxyJump 的物理 ARM64 HarmonyOS PC
验收。config import/export 已完成真实样本、文件授权、严格导入、round-trip、原子失败恢复和
物理 PC 闭环。`ssh-keygen -c` 已完成 OpenSSH 行为、当前 Ed25519/RSA 格式、`ssh-key`
0.7.0-rc.11 comment 能力、原子提交边界、错误恢复和物理 PC 验证。现有 OpenSSH ECDSA
P-256/P-384/P-521 Identity 也已通过锁定库、加密格式、共同安全生命周期、签名 ARM64 构建和
命名真机场景门禁，进入既有导入、认证、重启与删除路径；不新增 ECDSA 生成入口。原 1.5 SSH
子范围与 BEL 驱动的长任务注意力/返回路径已经完成产品源、聚焦软件门、同一签名 ARM64
diagnostic HAP 和命名物理矩阵闭环。2026-08-24 重新打开的 Agent 原生兼容矩阵、OSC
9/777/99 受限输入和中英文指南也已于 2026-08-25 按上述适用性边界闭合。1.5 尚未进入正式
候选；release preparation 仍须由维护者单独授权并写入 `next-work.md` 后开始，开发期证据
不自动获得发布资格。

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

## 阻塞的战略 milestone：2.0 — MatePad 实体键盘双模式

### 优先级与用户结果

MatePad 适配是当前最高优先级的设备扩展方向，但因缺少支持 PC 模式的真实测试机而
阻塞。目标是让用户在 MatePad 的 PC 模式和平板模式中使用外接实体键盘完成同一套
高频 SSH/TTY 工作，同时保留 LeanTTY 的信任、可靠性和键盘优先原则。

### 拟议顺序与范围

1. 先闭合 **PC 模式 + 外接键盘/鼠标**，因为它与当前 HarmonyOS PC 的产品合同最接近。
2. 再闭合 **平板模式 + 外接实体键盘**，单独验证窗口/全屏、系统返回、焦点、
   快捷键、触控板/鼠标、分屏、尺寸和生命周期。
3. 复用同一 SSH Transport、Session、Terminal Surface、Host/Identity 和主机信任模型；
   不为设备扩展建立第二套产品或数据边界。

### 非目标、设备门禁与抢占规则

- 不投入大量精力优化纯触屏 + 系统虚拟键盘工作流，不新增大型虚拟快捷键盘或
  触控优先的第二套交互。
- 开发前必须获得一台支持 PC 模式、能安装正式签名 HAP 且可长期回归的物理
  MatePad，并核对 HarmonyOS 版本、分发设备范围和两种模式的公开平台合同。
- 获得合格测试机后，2.0 成为当前正在收口的 milestone 之后的下一优先级，可前移
  到尚未开始的 1.6 之前；不为此中断已进入正式候选或发布收口的版本。
- 没有真机时可做公开 API、应用市场设备范围、现有 PC 假设审计和验收矩阵准备，
  但不编写适配实现、不用模拟器或响应式布局代替物理设备结论。

该 milestone 未进入 `next-work.md`，设备门禁成立前不授权适配实现。

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

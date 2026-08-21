# SSH 与 Mosh 命令体系

> 状态：Accepted 能力取舍基线；待证实项保持 WIP，不授权实现
>
> 适用 milestone：跨 1.1–1.7
>
> 更新日期：2026-08-17
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 路线治理：[`roadmap.md`](../roadmap.md)
>
> 实现授权：只以 [`next-work.md`](../next-work.md) 中当前 milestone 的活动任务为准

## 一、结论

LeanTTY 要完整覆盖“通过交互式 TTY 进入执行环境”的客户端生命周期，不复制完整的
OpenSSH Unix 工具箱：

1. 完整做好目标解析、连接、主机校验、认证、PTY、维持、诊断、恢复和退出。
2. 完整做好 LeanTTY 实际拥有的 Host、Identity、`known_hosts` 和 config 资产生命周期。
3. 使用 OpenSSH/Mosh 标准名称时保持主要语法、安全和生命周期语义；无法保持时使用
   `host`、`key`、`put/get` 等局部名称。
4. 文件管理、通用代理、后台 Unix 进程、PKI、服务端和执行环境管理不进入产品。
5. 被采纳的能力按 milestone 逐步交付；能力全集和本文件本身不授权提前实现。

推荐的长期用户命令面如下：

| 命令 | 决策 | LeanTTY 范围 |
| --- | --- | --- |
| `ssh` | 必须做 | 交互式 TTY 登录、认证、主机信任和连接生命周期 |
| `ssh-keygen` | 必须做受控子集 | 用户密钥和 `known_hosts` 生命周期 |
| `ssh-copy-id` | 必须做受控子集 | 将一个明确公钥安全部署到目标账户 |
| `host` | 必须做 | 管理唯一 OpenSSH Host 配置，不建立 GUI 主机数据库 |
| `key` | 必须做 | 管理 HarmonyOS 中的 LeanTTY 私有密钥资产 |
| `put/get` | 已采纳，1.3 | 受限单文件交付；内部使用 SFTP，不冒充 `scp/sftp` |
| `mosh` | 应该做，WIP 1.7 | SSH bootstrap 后的交互式弱网 TTY Session |
| `scp`、`sftp` | 不做用户命令 | 标准语义超出受限单文件和 TTY 入口边界 |
| `ssh-agent`、`ssh-add` | 不做 | 没有 Unix agent socket、子进程和环境变量模型 |
| `ssh-keyscan` | 不做 | 采集不能证明主机密钥真实性 |
| `sshd`、`sftp-server`、helper | 不做或仅内部 | LeanTTY 不建设执行环境和 SSH 服务端 |

## 二、完整性与实现授权

“完善的命令体系”包含四项完整性：

1. **能力全集完整：** OpenSSH/Mosh 的用户命令、主要 option family、配置、交互
   escape、client/server/helper 边界均已审计。
2. **产品决策完整：** 每项属于“必须做、应该做、待证实、不做或内部能力”，没有
   “以后遇到再说”的无归属空白。
3. **单项交付完整：** 语法、help、错误、取消、安全、持久化、自动化、ARM64 构建和
   所需真机门禁同时闭合，不能只有 parser 或 happy path。
4. **版本归属完整：** 采用项有明确 milestone；进入当前 `next-work.md` 前不实现。

决策结果与实现状态是两个维度。“必须做”不表示全部进入 1.1；“应该做”在进入对应
milestone 前仍不是活动任务；“待证实”只能保留 WIP 和重新讨论条件。

## 三、能力取舍规则

命令能力依次通过六道决策门，不使用可互相补偿的打分：

1. **用户信任：硬否决。** 不允许用不必要的数据、凭据、终端内容、控制权或安全降级
   换取能力。
2. **核心 TTY 任务：确认真实阻断。** 能力须直接服务“目标 → 连接 → 校验 → 认证 →
   终端 → 维持 → 诊断 → 恢复/退出”，或 Host/Identity/known-hosts/config 资产链。
3. **职责归属：先找正确所有者。** 能由 `.ssh/config`、HarmonyOS/HSL 或远端工具完整
   解决的，不在 LeanTTY 建立平行入口和状态。
4. **标准语义：名称必须诚实。** 标准名称保持主要语义；不支持项明确失败；受限能力
   使用局部名称并说明差异。
5. **永久复杂度：收益覆盖长期成本。** 评估概念、状态、入口、权限、秘密、监听、
   依赖、配置、故障和跨层协调，而不只评估 parser 代码量。
6. **完整交付：无法闭环就保持 WIP。** 必须能闭合语法与 quoting、help、错误、取消、
   安全、原子持久化、测试、目标构建和物理 HarmonyOS PC 验收。

统一判定是：

> **LeanTTY 只内建那些由客户端负责、会阻断核心 TTY 工作、能够诚实遵循标准语义，
> 并能以可控复杂度完成安全与生命周期闭环的命令能力；其余能力交给标准配置、系统或
> 执行环境，证据不足的保持 WIP。**

## 四、当前实现基线

以下来自当前 `CommandParser.ets`、`KeyCommandService.ets`、`SshConfig.ets` 和相关测试：

| 命令 | 当前范围 | 本基线判定 |
| --- | --- | --- |
| `ssh [-p port] [-i identity] user@host|alias` | 交互式 SSH、PTY | 必须保留并完善 |
| `ssh -G alias` | 输出 HostName/User/Port/Identity | 必须保留并反映真实解析 |
| `ssh-keygen [-t ed25519|rsa] [-f name] [-C comment]` | 生成 key pair | 必须保留并维持安全策略 |
| `ssh-keygen -y/-l/-R` | 公钥、fingerprint、删除 host key | 必须保留；1.1 补 `-F/-p` |
| `ssh-copy-id -i key [-p port] user@host` | 部署一个公钥 | 必须保留受控子集 |
| `key list/import/export/rm` | LeanTTY key store 生命周期 | 必须保留局部命令 |
| `host list/add/set/rm` | 管理 LeanTTY 负责的 Host block | 必须保留局部命令 |
| `help`、`?`、`exit` | 可发现性与本地生命周期 | 必须保留并统一错误边界 |

临时兼容的 `alias`、`keys` 和 `key show` 是历史语法，不作为新设计依据；退出版本须按
已发布兼容性合同单独决定。

当前 parser 主要按空白拆词，不能诚实支持带 quoting 的远端命令；当前 config 解析只
实际应用 `HostName`、`Port`、`User` 和 `IdentityFile`。1.1 必须先让未知 option、未知
或未支持的关键 directive 具有明确失败行为，不能用当前实现反向定义标准范围。

## 五、`ssh` 命令能力矩阵

| 能力 | 代表语法 | 决策 | 归属与边界 |
| --- | --- | --- | --- |
| 交互式登录 | `ssh [user@]host|alias` | 必须做 | 当前核心；只打开交互式 PTY Session |
| 端口和身份覆盖 | `-p`、`-i` | 必须做 | 当前核心；复用唯一 Host/Identity 解析 |
| 配置诊断 | `-G` | 必须做 | 输出真实有效配置和不支持项，不宣称完整 OpenSSH |
| 密码、公钥、加密私钥 | authentication methods | 必须做 | 当前核心并持续回归 |
| keyboard-interactive、多方法、banner | RFC 4256 等 | 必须做 | 1.1；结构化 challenge 和唯一 Session 状态机 |
| 主机校验 | unknown/changed host key | 必须做 | 首次确认；变化立即拒绝；不得配置为静默信任 |
| 连接默认策略 | timeout、keepalive、取消 | 必须做 | 安全可靠默认；可配置子集进入 1.5 |
| 地址族 | `-4/-6`、`AddressFamily` | 应该做 | 1.5；强制实际网络族，不作为无效 flag |
| 安全诊断 | `-v` | 应该做 | 1.5；LeanTTY 结构化、脱敏诊断，不复制原始 OpenSSH log |
| 基本 escape | `~.`、`~?`、`~I` | 应该做 | 1.5；断开、帮助、连接信息；与 Pane 生命周期统一 |
| Jump Host | `ProxyJump`、`-J` | 应该做 | 1.4；配置为主，`-J` 复用同一状态机，首版单跳 |
| 远端命令 | `ssh host command...` | 待证实 | quoting、PTY、输出、退出状态和取消闭合后重议 |
| PTY override | `-t/-T` | 待证实/不做 | 远端命令未采用前不加 `-t`；`-T` 不属于 TTY 产品路径 |
| URI、`-l` | `ssh://...`、`-l user` | 不单独规划 | `user@host` 是唯一主路径；只可作为无新语义兼容语法重议 |
| alternate config | `-F file` | 不做 | 受控 config import/export 进入 1.5，不建立临时第二权威 |
| generic config override | `-o option` | 不做 | 不能绕过逐 directive 审计和安全策略 |
| 版本与算法查询 | `-V/-Q` | 不做当前命令 | 使用 LeanTTY 自身版本/help；算法诊断按真实需求提供 |
| 日志文件 | `-E file` | 不做 | 不扩大本地文件和秘密泄露面 |
| 压缩与算法覆盖 | `-C/-c/-m` 等 | 不做通用入口 | 采用安全默认；互操作降级须独立证据和明确安全边界 |
| forwarding | `-L/-R/-D/-W` | 不做用户能力 | 通用网络代理；`direct-tcpip` 仅可作 ProxyJump 内部能力 |
| multiplex | `-M/-O/-S` | 不做 | Unix control socket 与 `Pane → Session` 所有权冲突 |
| agent forwarding | `-A/-a` | 不做 | 没有 agent，且增加远端滥用签名风险 |
| X11 forwarding | `-X/-Y/-x` | 不做 | 无产品内 X server，偏离 TTY 入口 |
| tunnel device | `-w` | 不做 | VPN/网络设备职责 |
| background/stdio | `-f/-n/-N` | 不做 | App 拥有 Session，不复制 Unix 后台进程语义 |
| arbitrary subsystem | `-s` | 内部能力 | 1.3 可内部启动 SFTP，不开放任意 subsystem |
| advanced escapes | `~C/~R/~B/~^Z/~&` | 不做或待证实 | 本地命令、转发和后台不做；rekey/BREAK 仅凭证据重议 |

所有不支持的 option 必须在连接或资产变更前失败。不能接受后静默忽略，也不能把
“parser 能识别”当作能力已交付。

## 六、`ssh_config` 能力矩阵

| 指令族 | 决策 | 归属与行为 |
| --- | --- | --- |
| `Host` pattern、negation | 必须做 | 唯一 Host 选择模型；匹配顺序确定 |
| `HostName/User/Port/IdentityFile` | 必须做 | 当前核心；`ssh -G` 必须反映结果 |
| host trust 与 known-hosts | 必须做 | 产品策略拥有；不允许配置关闭核心信任 |
| auth 与 multi-method | 必须做 | 1.1；config 不替代 Rust Session 状态机 |
| timeout/keepalive | 应该做 | 1.5：`ConnectTimeout`、`ServerAliveInterval/CountMax` 的受控子集 |
| `AddressFamily` | 应该做 | 1.5；与 `-4/-6` 共用策略 |
| `UpdateHostKeys` | 应该做 | 1.5；须验证服务端扩展、原子持久化和错误恢复 |
| `ProxyJump` | 应该做 | 1.4；首版单跳，跳板与目标分别校验和认证 |
| config import/export | 应该做局部命令 | 1.5；通过 HarmonyOS 文件授权进入唯一 config，不用 `-F` |
| certificate/CA directives | 待证实 | 只考虑使用证书；不建设签发和 CA 管理平台 |
| `Include`、safe `Match`、token expansion | 待证实 | 由真实配置迁移样本和解析复杂度决定；`Match exec` 不做 |
| `IdentitiesOnly`、auth preference | 待证实 | 先证明多 identity 与受控认证顺序的真实缺口 |
| canonicalization、DNS SSHFP | 不做当前范围 | DNS/别名复杂度和信任收益不足 |
| `ProxyCommand`、local command | 不做 | 无本地 shell；禁止任意本地命令执行 |
| forwarding、agent、X11、tunnel | 不做 | 与相应 CLI 决策一致 |
| arbitrary crypto downgrade | 不做 | 不允许 config 绕过安全策略 |
| alternate known-hosts files | 不做 | 保持唯一持久资产和主机信任来源 |
| `StrictHostKeyChecking=no/off/accept-new` | 不做 | 未知主机必须人工确认，变化主机必须拒绝 |

解析规则：

- 未知或会影响目标、认证、主机信任、网络路径和 Session 行为的未支持 directive，必须
  在连接前明确失败。
- 已知且明确表示关闭 LeanTTY 本就不提供的能力时，可以保留原文并给出诊断，但不得
  宣称已经实现该 directive。
- 导入、编辑和导出必须保留未由 LeanTTY 管理的原文；连接决策只使用明确支持的语义。
- `ssh -G` 必须区分“已应用、使用产品固定安全策略、未支持并拒绝”，不得静默遗漏。

## 七、密钥、主机信任与本地资产命令

### 7.1 `ssh-keygen`

| mode | 决策 | 归属与边界 |
| --- | --- | --- |
| Ed25519/RSA 生成 | 必须做 | 当前核心；RSA 只接受安全位数，KDF 使用安全默认 |
| `-p` 修改 passphrase | 必须做 | 1.1；旧/新口令只经秘密输入，不进入命令历史 |
| `-y` 输出公钥 | 必须做 | 当前核心 |
| `-l` fingerprint | 必须做 | 当前核心；默认 SHA-256 |
| `-F` 查询 known-hosts | 必须做 | 1.1；覆盖散列记录、IPv4/IPv6、非默认端口 |
| `-R` 删除 known-hosts | 必须做 | 当前核心；精确删除并原子持久化 |
| `-c` 修改 comment | 应该做 | 1.5；复用同一 key identity 和提交入口 |
| safe `-b/-C/-f` | 必须做受控子集 | 与生成 mode 一起保持明确范围 |
| ECDSA key 导入和认证 | 应该做，待实现证据 | 1.5 候选；不要求新增 ECDSA 生成入口 |
| public-key 格式转换 `-i/-e` | 不做标准 mode | 通过受控 `key import/export` 覆盖实际平台边界 |
| known-host hashing `-H` | 内部安全能力 | 可按产品策略读写散列；不复制 `.old` 文件语义 |
| passphrase flags `-N/-P` | 不做 | 秘密不得进入命令文本和历史 |
| certificate inspect/use | 待证实 | 只有 client authentication/host trust 证据成立时重议 |
| FIDO/PKCS#11/security key | 待证实 | 需要 HarmonyOS 公开稳定硬件接口和真机证据 |
| `mldsa44-ed25519` 等新算法 | 待证实 | 需要库、服务器生态和安全维护证据 |
| CA 签发、KRL、DH moduli | 不做 | PKI、撤销和服务端密码学运维职责 |
| SSHFP、file signatures `-Y` | 不做 | 不属于 TTY 接入和本地 SSH 资产核心 |
| host key batch generation `-A` | 不做 | LeanTTY 不运行 `sshd` |
| bubblebabble/randomart 等 | 不做 | 低频显示收益不足 |

### 7.2 `key`、`host` 与 config

- `key list/import/export/rm` 是必须保留的 HarmonyOS 局部命令；导入前验证，导出只经
  用户主动文件授权，删除经唯一持久提交入口。
- 修改 passphrase 使用标准 `ssh-keygen -p`，修改 comment 使用标准 `ssh-keygen -c`，
  不再增加等价 `key` 子命令。
- `host list/add/set/rm` 只管理唯一 OpenSSH config 中 LeanTTY 负责的 Host block，
  不演进成主机数据库、标签、分组或 GUI 资产管理。
- 查看有效 Host 使用 `ssh -G`；查找和删除主机信任使用 `ssh-keygen -F/-R`，不增加
  平行的 `host show-known-key` 命令。
- 1.5 可增加受控 config import/export，但不得导入后静默忽略关键 directive。

### 7.3 `ssh-copy-id`

`ssh-copy-id -i key [-p port] user@host` 保留为必须做的受控标准子集：

- 只安装用户明确选择的一个公钥，不上传私钥，不覆盖 `authorized_keys`。
- 复用 Host、主机校验、认证、取消和错误模型；对重复 key、权限、远端 shell 失败和
  持久结果具有确定行为。
- `-f/-n/-s`、批量 identity 和其他未实现语法明确报错；只有真实受限 shell 场景证明
  SFTP mode 必要时才重议。

## 八、文件、agent、采集、helper 与 server

| 上游能力 | 决策 | 理由与去向 |
| --- | --- | --- |
| `scp` | 不做用户命令 | 完整语义包含多源、递归、远端路径和兼容行为；1.3 只提供受限 `put/get` |
| `sftp` | 不做用户命令 | 交互/批处理文件管理超出范围；协议仅可作 1.3 内部能力 |
| `ssh-agent` | 不做 | 依赖 Unix 进程、socket 和环境变量；LeanTTY key store 不是 agent |
| `ssh-add` | 不做 | 没有 agent 时同名命令会制造虚假兼容 |
| agent forwarding | 不做 | 增加远端滥用签名风险且没有本地 agent |
| `ssh-keyscan` | 不做 | 未验证采集不能建立信任；继续在实际连接中逐 endpoint 确认 |
| `ssh-keysign` | 不做 | host-based auth 与特权 helper 不符合三方应用边界 |
| PKCS#11/FIDO helper | 内部/待证实 | 只有系统硬件能力成立后评估，不暴露 helper 命令 |
| `sshd`、`sftp-server` | 不做 | LeanTTY 是执行环境入口，不建设执行环境或服务端 |

1.3 的 `put/get` 只表达“单文件、同一 Host/Identity/认证、受控 Downloads、无覆盖
提交”；具体边界由 [`file-transfer.md`](file-transfer.md) 负责。

## 九、Mosh 命令体系

Mosh 的产品方向通过前五道决策门：它直接改善合盖、短断网、网络切换和高延迟下的
交互式 TTY 可靠性。但在 UDP、native 依赖、安全、终端同步和真机生命周期证据闭合前，
第六道完整交付门仍未通过，因此整体保持 WIP 1.7。

| 能力 | 决策 | 1.7 边界 |
| --- | --- | --- |
| `mosh [user@]host|alias` | 必须做 | 唯一用户入口；复用 SSH Host/User/Identity |
| SSH bootstrap | 必须做 | 复用主机校验、全部认证、取消和错误；启动远端 server 后结束 SSH |
| UDP Session | 必须做 | 独立、明确的建连、中断、恢复和不可恢复状态 |
| `-p` UDP port/range | 必须做 | 固定端口是 NAT/firewall 下的可用性前提；与 SSH Port 明确区分 |
| `--server=PATH` | 应该做 | 支持用户目录安装；只接受远端路径，不接受 shell 片段 |
| `--predict=auto/always/never` | 应该做 | 默认 auto；长 option 作为高级入口，反馈必须可理解 |
| IPv4/IPv6 family | 应该做 | 与真实 UDP 地址选择一致，不复制无效 option |
| `Ctrl-^ .` | 必须做 | 标准强制断开；与 Pane 关闭、取消和迟到事件统一 |
| UTF-8、server、UDP 诊断 | 必须做 | 明确区分 SSH 成功、server 启动、UDP 建连和网络恢复 |
| `mosh host -- command` | 待证实 | 依赖远端命令 quoting、PTY 和生命周期模型 |
| bind/server-address overrides | 待证实 | 由真实多地址、NAT 和兼容证据决定 |
| `--ssh="..."` | 不做 | 无本地 shell；任意字符串破坏统一 Host 模型和安全边界 |
| `--client=PATH` | 不做 | 客户端协议是 LeanTTY native 内部能力 |
| `mosh-client` | 内部能力 | 不公开 session key、endpoint 或调试原语 |
| `mosh-server` | 远端要求 | LeanTTY 不内置、安装、升级、管理或清理远端 server |
| port forwarding/X11/agent/file | 不做 | Mosh 只承载交互式终端，其他能力继续按 SSH 决策 |
| second Mosh config | 不做 | 不建立第二套 Host/Identity；Mosh 专有项只属于命令或局部配置 |
| firewall/NAT 管理 | 不做 | 系统和网络管理员职责；LeanTTY 只提供可理解诊断 |
| 关闭后重新附着旧 server | 不做 | 持久工作使用远端 tmux/screen，不建设 Mosh session manager |

ProxyJump 最多帮助 Mosh 的 SSH bootstrap；它不转发 UDP。只有目标 UDP 能从 LeanTTY
直接到达时二者才可组合，产品不得把“SSH 经跳板成功”描述为“Mosh 一定可用”。

## 十、统一命令设计与交付规则

### 10.1 一个语义一个入口

- `ssh`、`ssh-copy-id`、`put/get`、HSL、ProxyJump 和 `mosh` 共用一个 Host 解析结果和
  Identity 优先级，不各自重写 endpoint 规则。
- 标准能力使用标准名称；平台特有资产边界使用 `host`、`key`、`put/get`。
- 不增加多个等价别名；历史别名按版本兼容政策退出。
- 不为能力全集建立插件、反射式命令框架或通用 Transport 抽象。

### 10.2 Parser、help 与错误

- parser 只把输入变为结构化意图；Session/SSH/Mosh 状态机决定生命周期。
- 需要 quoting 的能力在统一 lexer 存在前不能进入实现，不能继续用空白拆词假装支持。
- 顶层 help 只展示正式支持的高频命令；高级内容进入 `help <command>`。
- help 同时列出容易误判的关键不支持边界和正确替代路径。
- 未知 option、互斥 option、缺失参数和超出范围必须在网络或资产变更前失败。
- 错误说明阶段、原因和下一步，不打印秘密，不把远端文本当控制序列。

### 10.3 单项完成定义

每项采用能力必须同时闭合：

1. 正式语法、quoting、配置优先级和 Host/Identity 所有权。
2. help、补全、未知/互斥/缺失输入和不支持边界。
3. 连接、认证、主机校验、取消、超时、断线、迟到事件和错误恢复。
4. 密码、口令、OTP、session key、路径和日志的安全边界。
5. 文件或资产变更的验证、原子提交、失败清理和卸载重装语义。
6. 自动化、Rust 格式、ARM64 build 和所需物理 HarmonyOS PC 验收。

## 十一、milestone 分配

| milestone | 已采纳的命令体系范围 |
| --- | --- |
| 1.1 | keyboard-interactive/多方法认证；`ssh-keygen -p/-F`；未知 option/config 的明确失败；现有 `ssh`、`ssh-keygen`、`ssh-copy-id`、`host/key` help/test 边界 |
| 1.2 | 不强行加入命令能力；保持终端搜索的单一主题 |
| 1.3 | 已采纳 `put/get`；SFTP 只作内部 subsystem，不开放 `scp/sftp` |
| 1.4 | 启动性能；`ProxyJump` 配置与标准 `-J`，首版单跳并保持 jump/target 双重信任与认证。HSL 专用入口因公开发现门禁失败而裁剪，手工 HSL Host 仍复用现有 SSH 命令、认证和主机信任 |
| 1.5 | `ConnectTimeout`、基本 SSH escape、`ServerAliveInterval/ServerAliveCountMax` 与安全 `ssh -v` 已闭合；`-4/-6` / `AddressFamily` 因真机 IPv6 fixture 门禁暂缓；UpdateHostKeys 因 russh 0.62.5 缺少完整 proof 公开 API 而裁剪。当前只晋级 config import/export 的真实样本、文件授权、round-trip 与原子失败恢复门禁；`ssh-keygen -c`、ECDSA 导入/认证仍逐项晋级 |
| 1.6 | 长任务注意力与返回路径；不为版本号强行增加命令能力 |
| 1.7 | Mosh 首版：SSH bootstrap、UDP port、server path、prediction、地址族、escape、弱网生命周期 |

路线图分配不等于实现授权。每个后续 milestone 确认并把第一段可执行工作写入
`next-work.md` 后才能开始实现；1.2 不为“每版都加命令”而混入无关范围。

## 十二、待证实能力的重新讨论条件

| 能力 | 必要证据 |
| --- | --- |
| 远端命令与 `-t` | 高频 TTY 场景、统一 quoting、退出状态、取消和输出所有权方案 |
| SSH certificate/host CA | 真实标准环境阻断证据、库支持、秘密和信任生命周期；不建设 CA |
| FIDO/PKCS#11 | HarmonyOS 公开稳定硬件接口、设备隔离和真机交互证据 |
| `Include`/safe `Match`/token expansion | 真实 config 样本覆盖率与可控解析、导入、错误语义 |
| 新密钥/签名算法 | 上游稳定、Rust 库、服务器生态、安全维护和迁移证据 |
| Mosh remote command | 与 SSH 远端命令共用的 quoting、PTY、取消和退出模型 |
| Mosh advanced network overrides | 受控多地址/NAT 场景证明默认和 `-p/-4/-6` 不足 |

证据出现后重新通过六道决策门，再决定 milestone；不得从“待证实”直接进入 parser。

## 十三、维护规则

新增、删除或改变命令前必须：

1. 在上游能力全集中定位其标准语义。
2. 逐项记录六道决策门的结论和证据。
3. 明确决策结果、职责所有者、milestone 或外部归属。
4. 若采用，定义完整交付、裁剪和停止条件。
5. 若待证实或不做，记录重新讨论触发条件。

不接受“刚好遇到一次”“OpenSSH/Mosh 有”“parser 很容易加”作为单独理由。

## 十四、上游依据

- [OpenSSH Portable 官方仓库与工具范围](https://github.com/openssh/openssh-portable)
- [OpenBSD `ssh(1)`](https://man.openbsd.org/ssh.1)
- [OpenBSD `ssh_config(5)`](https://man.openbsd.org/ssh_config.5)
- [OpenBSD `scp(1)`](https://man.openbsd.org/scp.1)
- [OpenBSD `sftp(1)`](https://man.openbsd.org/sftp.1)
- [OpenBSD `ssh-keygen(1)`](https://man.openbsd.org/ssh-keygen.1)
- [OpenBSD `ssh-keyscan(1)`](https://man.openbsd.org/ssh-keyscan.1)
- [OpenBSD `ssh-agent(1)`](https://man.openbsd.org/ssh-agent.1)
- [OpenBSD `ssh-add(1)`](https://man.openbsd.org/ssh-add.1)
- [Mosh 官方用法与技术说明](https://mosh.org/)
- [Mosh 官方源码与 README](https://github.com/mobile-shell/mosh)

# 1.7 依赖评审与产品范围决定

评审日期：2026-09-24。基线：`35e16079c65adb9bad7bdfab3d48c9cfc729fa95`。
本记录交付评审、升级方案及维护者确认的范围，不代表依赖或界面已经修改。
实施与验证事项只登记在 [next-work](../next-work.md)。正式验收仍暂停。

## 结论

| 项目 | 1.7 范围 | 结论 |
|---|---|---|
| 剪贴板二次授权 | 已完成 | #236 已合入；人工确认与包身份记录已在主线 |
| russh 0.62.5 → 0.63.3 / #216 | 纳入 | 有当前客户端默认路径涉及的安全修复；先适配，再合入 |
| data-encoding 2.11.0 → 2.11.1 / #129 | 纳入 | 库本身仅清理包元数据；限制锁文件变动，单独交付 |
| chacha20 0.10.1 → 0.10.2 | 纳入 | 当前版本已撤回；修复 SSE2 后端错误使用 SSE4.1 指令的问题 |
| wnaf 0.14.0 → 0.14.1 | 纳入 | 当前版本已撤回；涉及 trait 约束变化，须编译及 ECDSA 回归 |
| russh-sftp 2.4.0 → 3.0.0 / #217 | 明确延期 | 暂无已知安全升级必要性；读写流水线变化应单独评估收益和传输合同 |
| ssh-key 本地 ECDSA 补丁 | 保留 | 最新发布版及上游当前源码仍有短标量限制；russh 升级不替代补丁 |
| RSA 加密实现更换或新本地补丁 | 不纳入 | 没有已发布修复版；记录公告与实际路径，不借评审扩展密码学实现 |
| 重启恢复常驻 warning | 纳入 | 维护者确认取消文字，保留恢复、日志及真实错误提示 |
| Host/Key 列表 | 纳入 | 维护者确认完整字段、多行条目和自然换行 |
| Host 证书/CA、新列表选项及宽度自适应框架 | 明确延期 | 不随依赖更新或列表整理扩展支持合同 |

## 剪贴板与开发基线

[PR #236](https://github.com/wandcs/leantty/pull/236) 于 2026-09-24 合入，
squash 提交为本报告基线。35 项 controller 合同、构建交付、维护者回复“可以了”的
证据边界已登记在 next-work；不把人工体验扩称完整自动拒绝矩阵通过。
本次重新 fetch 后，main 与 origin/main 的 ahead/behind 为 0/0，工作区干净。
不重复创建剪贴板 PR，不重装 App，也不改已冻结的发布检出。

## 三个现有 PR 的差异与风险

三个 PR 的共同基线为 `6d594c8`。09-24 核对时均可合并且旧提交的四项云端检查成功。
该工作流只编译、lint 和测试 `leantty-ssh-core`，不编译完整 NAPI 产品 crate 或
所有独立 fixture。旧基线上的绿灯不是最新主线完整构建或真机通过证明。
本批按认证/密码学路径高风险评审：审阅三个 PR 的全部差异及关键调用链；发现
1 项明确合入阻断（回调 API 不匹配）、1 项需延期的广泛传输行为变化，未确认
新引入的可利用产品安全回退。上游漏洞的严重度与产品可达性分列，不能混作漏洞计数。

| PR / 已审 head | 变更 | 评审判断 |
|---|---|---|
| [#129](https://github.com/wandcs/leantty/pull/129) / `9bda987` | 仅 Cargo.lock，+3/-3 | 小范围可接受；另带 errno 的 windows-sys 边重选，合入前核对必要性 |
| [#216](https://github.com/wandcs/leantty/pull/216) / `18de925` | 3 个 Cargo.toml 与锁文件，+10/-21 | 当前形式不可直接合入：缺少主机密钥回调适配 |
| [#217](https://github.com/wandcs/leantty/pull/217) / `f6bbc86` | 2 个 Cargo.toml 与锁文件，+20/-20 | 延期；同时带入 log、wasm-bindgen/js-sys 及 syn 变动 |

### russh：有升级理由，也有明确迁移缺口

[0.63.0](https://github.com/warp-tech/russh/releases/tag/v0.63.0) 把
`Handler::check_server_key` 的参数从 `&PublicKey` 改为 `PublicKeyOrCertificate`。
产品 `leantty_ssh/src/lib.rs:827` 仍使用旧签名；同文件测试、ssh-auth-fixture 的测试、
backpressure 测试和独立 sftp-interop-fixture 也有旧签名，共 5 个实现。
#216 未修改这些文件。此为源码接口不匹配的静态发现，本轮未伪称运行了失败构建。

影响面包括普通 SSH、ProxyJump 各层、Mosh 的 SSH bootstrap 和 SFTP 的 SSH 通道。
迁移必须保留已知主机匹配、首次确认、指纹变化拒绝及信任文件写入边界。
对新增 Certificate 变体明确拒绝，不把其中公钥直接抽出并按普通公钥信任，
不增加 CA 信任或主机证书支持。必要时保持协商列表只包含现有受支持的普通公钥算法。

0.63.3 还替换了 internal-russh-num-bigint 为 num-bigint 0.5.1，修复 rekey 期间
写入及 stalled-write timeout 等行为；不能只验证纯 keygen/core。
0.62.7 虽避免回调 API 变化，却早于下列 0.63 系列客户端修复，不作为本轮终点。

### russh-sftp：不是单纯版本号变化

上游无 GitHub release/tag 可作为完整变更说明；因此检查官方 crates.io 的两个发布包，
其 VCS 提交分别为 `e145c1f7ece99f41f558949ef59731f2cd1a9dfe`、
`c2776c64c27e554dda0e0304925f890833fea5b1`。
[上游比较](https://github.com/AspectUnk/russh-sftp/compare/e145c1f7ece99f41f558949ef59731f2cd1a9dfe...c2776c64c27e554dda0e0304925f890833fea5b1)
包含 11 个 src 文件、+505/-199 行：并行读取、借用写入、请求超时/取消清理、
忽略已取消请求的迟到回复，以及便捷 read/write 显式 close。
默认并行读取数为 16，并行写入数从 8 改为 16；Config 新增
max_concurrent_reads/max_write_packet_len。

LeanTTY 的 `transfer.rs` 使用文件 AsyncRead/AsyncWrite，已明确等待 close，
这些内部行为会影响上传、下载、取消和提交/清理合同。当前没有上游安全公告，
也没有证据说明 1.7 当前失败由 2.4.0 导致。russh-sftp 运行时不依赖 russh，
其 Cargo.toml 中 russh 只是 dev-dependency，故升级 russh 不强迫升级 SFTP。
保留 2.4.0；未来以实际吞吐需求或已复现缺陷重新准入，而非为了清空 PR 列表合入。

### data-encoding

[发布差异](https://github.com/ia0/data-encoding/compare/v2.11.0...v2.11.1) 显示
lib/CHANGELOG 只记移除废弃 authors 字段，没有库运行时源码改动。
syn 3 支持属于宏子包更新，不能说当前主库因此修复安全问题。
该项是维护更新，验证来源、锁文件和 core 合同即可，不单独要求新真机矩阵。

## 安全公告与实际可达性

威胁入口按恶意或已被攻陷的 SSH 服务端、被导入的密钥及用户主动粘贴的文本区分。
主机认证不意味着后续输入天然可信；也不能把服务端库漏洞套用到本产品客户端上。

09-24 重新执行现有 cargo-audit 0.22.2：产品锁文件 224 个依赖，独立 SFTP fixture
锁文件 194 个依赖，均报告 1 条 RSA 公告和 2 个 yanked 版本。
RustSec 数据库提交 `ef8244d224cb89be53491e0c55a96c1279d9fdf1`。
npm audit 扫描 tools 锁文件 33 个依赖，0 条漏洞。GitHub 仓库告警全部为 fixed，
0 条 open；但 russh 上游新公告未全部出现在这些扫描结果中，需交叉核对。

| 公告 | 上游级别 / 当前路径 | 处理 |
|---|---|---|
| [GHSA-w3jg-pjxf-73p4](https://github.com/warp-tech/russh/security/advisories/GHSA-w3jg-pjxf-73p4) | Medium；默认首选 ML-KEM/X25519，旧 hybrid 路径缺少零贡献校验 | 纳入 0.63.3；已读目标源码，client/server 均检查计算结果为零。公告受影响范围与首个修复版本字段边界冲突，不能只机械读取范围 |
| [GHSA-47hw-gvq5-r2gm](https://github.com/warp-tech/russh/security/advisories/GHSA-47hw-gvq5-r2gm) | High；无效 channel ID 仍调用 Handler 回调 | 纳入升级；本产品只自定义 auth_banner/check_server_key，不自定义受影响逐通道回调，未证明公告中的状态伪造/DoS 在本产品可达 |
| [GHSA-p8qx-h547-fjw9](https://github.com/warp-tech/russh/security/advisories/GHSA-p8qx-h547-fjw9) | Low；需要把 MAC none 放进可协商列表 | 纳入升级；当前沿用默认安全 MAC 列表，不含 none，未满足公告攻击前提 |
| [GHSA-35g8-35p8-c8fw](https://github.com/warp-tech/russh/security/advisories/GHSA-35g8-35p8-c8fw) / [GHSA-g6xm-f9xp-qq35](https://github.com/warp-tech/russh/security/advisories/GHSA-g6xm-f9xp-qq35) | Medium / Low；分别为服务端 rekey 内存和认证次数上限 | 产品不作为 SSH server；升级也覆盖本地服务端 fixture，不能宣传成产品远程 server 漏洞修复 |
| [GHSA-g4mp-vgx3-xrvm](https://github.com/warp-tech/russh/security/advisories/GHSA-g4mp-vgx3-xrvm) | Medium；Windows Pageant | ARM64 HarmonyOS 产品不走此路径，不增加 Windows 产品支持 |

另有两个现有 PR 遗漏的撤回版本：

- [chacha20 0.10.2](https://github.com/RustCrypto/stream-ciphers/pull/580)：
  0.10.1 的 SSE2 RNG/legacy 后端调用 SSE4.1 指令，已撤回。ARM64 不执行 SSE2，
  不能称为 ARM64 远程漏洞；仍应同步更新产品及独立 fixture 锁文件，避免继续固定撤回版本。
- [wnaf 0.14.1](https://github.com/RustCrypto/elliptic-curves/pull/1916)：
  使用 primefield trait 确定 scalar 字节序，0.14.0 因这一 breaking bounds change
  被撤回，不是已公布的安全漏洞。经 primeorder → p256/p384/p521 到达产品；
  在升级批次核对兼容性，不因为 PATCH 号假定零风险，不修改 vendored ssh-key 源码适配。

### RSA 公告：保留风险记录，不伪造“升级即可修复”

[RUSTSEC-2023-0071](https://rustsec.org/advisories/RUSTSEC-2023-0071.html)
仍覆盖锁定的 rsa 0.10.0-rc.18，patched 列表为空；它也是当前最新预发布版。
[上游 #626](https://github.com/RustCrypto/RSA/issues/626) 的剩余问题集中在解密填充，
[#702](https://github.com/RustCrypto/RSA/pull/702) 尚未合入，明确只处理解密，不能
据此声称 SSH 签名已修复，也不引入未发布 git 版本。

源码链为 russh helpers::sign_with_hash_alg → ssh-key RSA try_sign →
rsa PKCS#1 v1.5 SigningKey → sign_pad/私钥运算。它没有对远端输入开放 RSA 解密去填充。
keygen.rs 的 decrypt(passphrase) 是 OpenSSH 私钥文件的对称密码解密，不是 RSA 解密。
因此没有发现本产品的 Marvin 解密 oracle；这不等于证明所有时序侧信道不存在。
当前签名入口没有 RNG blinding，底层 crypto-bigint 0.7 以常数时间为设计目标，
本轮没有做 ARM64 侧信道实测或形式化证明。

1.7 保持已发布 RSA 支持，保留告警与路径判定，不新增全局 audit ignore，
不扩大 ECDSA 本地补丁到 RSA。后续若出现明确影响该签名路径的证据或可用修复，
按信任原则重新评估；不能将“目前无修复版”当作无限期忽略理由。

### 固定源码和扫描覆盖边界

- ssh-key、russh、russh-sftp、data-encoding 上游均未归档且有近期维护活动。
  最新发布版本分别为 0.7.0-rc.11、0.63.3、3.0.0、2.11.1。
- mosh-client-rs 固定 v0.1.1，当前上游 latest release 仍为该版本；未发现公开仓库公告。
- Ghostty 固定 `82938b6`（09-07），比较确认包含 v1.3.0 祖先及
  [粘贴控制字符修复 #10746](https://github.com/ghostty-org/ghostty/pull/10746)。
  LeanTTY 调用 ghostty_paste_encode；本轮未据 Ghostty 桌面 App 公告机械升级整个 VT。
  其他公开旧公告涉及本地 shell/桌面动作，不能直接推断为本产品同一入口。
- npm 既有 sharp/xmldom 修复保留。HarmonyOS 模块运行依赖为本地原生库，
  hypium/hamock 为开发依赖。本轮未升级 SDK、Zig 0.16.0 或固定原生构建依赖。
- npm/RustSec 不覆盖 HarmonyOS SDK、所有原生源码与全部未公开漏洞；
  GitHub Actions 已固定 SHA，本轮不做无依据的全量版本刷新。
  “没有发现其他需要立即升级的公开问题”不是全依赖无漏洞认证。

## ssh-key 补丁与升级合同

0.63.3 workspace 仍精确依赖 `ssh-key = =0.7.0-rc.11`。
当前 root `[patch.crates-io]` 因而可继续命中同一 vendor；#216 的锁文件未更换 ssh-key。
09-24 读取上游 HEAD 的 private/ecdsa.rs 仍有 MIN_SIZE=32，不能移除本地补丁。
0.6.7 是最新稳定版但不满足 russh 的精确约束，降级并不能作为修复方案。

补丁只改变 private/ecdsa.rs 的正标量解码，保留官方完整包、来源哈希和单独 diff。
升级时保持 [补丁维护合同](../../third-party/ssh-key/README.md)：核对唯一依赖来源，
执行独立 ecdsa_scalar 回归、公开源码校验及定向真机导入/认证。
上游发布并通过同一回归后，才连同 override 和校验钩子一起删除，保留产品回归测试。
独立 sftp-interop-fixture 本来不继承产品 workspace patch；不得把它测试成功当成
产品短 ECDSA 标量补丁成功，也不要为本次审查给这个 fixture 扩加 vendor 机制。

## warning 与 Host/Key：已确认的输出合同

09-24 维护者在本次讨论中明确选择下述两项纳入 1.7。

warning 的判定只有 previous.runState == RUNNING，正常退出路径在断开 runtime 后
调用 markClean。缺失 CLEAN 不能单独证明崩溃。当前 SessionViewModel 将长英文
warning 写入恢复 Pane 的终端历史，没有可执行动作。取消该输出及仅服务该输出的状态，
不删 checkpoint、正常退出标记、布局恢复和实际错误。取消后仍不恢复旧远端会话/内容。
替换为 toast、增加故障类型推断、设置开关均不纳入本轮。

Host/Key 当前 padEnd 表格只规定最小列宽：长名称会挤连后列，窄 Pane 会自动折断整行。
新合同采用同一种多行格式，独立字段且不靠空格列对齐，不引入终端宽度测量或截断框架。

| 列表 | 字段与含义 |
|---|---|
| Host | 完整别名、user 与 hostname/port 组成的目标（IPv6 用方括号区分端口）、Identity；已配置跳板、超时和保活选项。沿用既有解析/默认值语义；自动选钥明确标识为自动，不伪报为某把已选 key |
| Key | 完整文件名、算法类型、完整 SHA256 指纹、hasPassphrase 对应的口令保护状态、comment；comment 由现有公钥文本投影，不为列表解密私钥 |

长标识符、指纹和 comment 保留全文并由终端自然换行，字段行之间可区分；空 comment
明确显示为空，无口令明确显示无口令。控制字符先按既有 TerminalTextPolicy 转义。
不展示内部私钥路径或秘密。不增加 --wide/--no-trunc/新详情命令，Host 详情复用 ssh -G。
宽窗、窄窗和双 Pane 使用同一格式；后续改变窗口尺寸无需维护第二份列表状态。

以下只示意字段分组，样例不是设备数据；指纹占位说明不表示产品会截断指纹：

```text
Host: development-server
  Target: user@[2001:db8::10]:2222
  Identity: work-key
  ProxyJump: bastion
  ConnectTimeout: 10s

Key: work-key
  Type: ed25519
  Fingerprint: <完整 SHA256 指纹>
  Passphrase: protected
  Comment: workstation access
```

## 交付顺序、验证与回退

本轮为评审与范围记录；下一实施批先完成 russh 安全升级/缺失间接依赖，随后交付
warning 与列表，再从最终主线重建候选。#129 单独小 PR；#216 需要补适配或由带完整
适配的 PR 替代，旧 PR 在替代交付后按流程收口；#217 保持明确延期，不在本轮关闭或合入。

验证采用受影响范围：完整产品 crate 编译、core/ECDSA 回归、SSH fixture 的
主机信任/认证/ProxyJump/通道/重键与传输主路径、ARM64 构建和定向真机 SSH/Mosh
bootstrap/密钥认证；列表与 warning 验证当前输出和恢复机制。只复用未变化证据，
不为依赖评审运行正式模型矩阵。升级后的源码与锁文件属于新候选，旧包不覆盖新字节。

迁移失败先停止该批，回退完整聚焦提交，不追加第二套协议后端或随机依赖刷新。
上游修复不能以忽略现有功能失败为代价。若 wnaf 新约束不兼容，应记录具体冲突再决定，
不得扩展 ssh-key 补丁。变更均经 PR；不强推，不删除旧证据与冻结分支。

本次证据：三个 PR 全部文件差异、上述上游发布包/公告、两个 cargo audit、npm audit、
受影响源码与历史（ECDSA 补丁 #227、恢复 #140）。原始只读抓取留在忽略目录
`build/review-20260924/`；七个下载发布包的 SHA-256 均与 crates.io 对应版本 checksum
一致。这是关键路径的依赖差异审查，不是上游全源码密码学审计。
本轮未运行产品构建、升级后测试或真机验收；相应要求属于下一实施批，不写作已通过。

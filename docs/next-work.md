# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-09
>
> 当前 milestone：[`1.3 — 受约束的单文件交付`](roadmap.md)
>
> 当前阶段：实现与定向集成验证
>
> 上位规则：[`project-principles.md`](project-principles.md)

本文件只保留尚未完成、已经授权的活动工作，并按实际依赖顺序执行。完成事实进入
`CHANGELOG.md`、设计文档和 Git 历史；旧 checkbox、定向实现证据、WIP 技术方案及后续
milestone 不在这里维护第二份清单。

## 当前状态与完成定义

`v1.2.0` 已由精确提交 `90c20cacf47ac620ccc89d21e70b6cdbbfeb0a68`、不可变签名标签和
[GitHub Release](https://github.com/wandcs/leantty/releases/tag/v1.2.0) 冻结。2026-08-08，
用户确认 SHA-256 为 `2a5bf97856c0915325abc4ebe5acd1acd6c6c142141e278a9d34f4c6c3505233`
的 production signed APP 与已审定商店材料已经提交 AppGallery，当前处于审核中。审核中的
1.2.0 不阻止 `main` 开始 1.3 开发，但其提交、标签、包体和 Release 不得移动或替换；若审核
失败，必须从适当的已发布标签准备最小 `1.2.1` PATCH，并把必要修复前向合并到 1.3，不能把
1.3 功能混入替代包。

1.3 已授权推进一个受约束的单文件交付能力。用户只在尚未连接服务器的当前 Pane 的
`ltty>` 中执行 `put` 或 `get`；本地根固定为系统 Downloads，远端通过同一 Host、Identity、
认证和主机校验模型连接 SFTP。传输前台运行且一次一个文件；文件字节由 Rust 流式处理，
不经过 ArkTS、WebView Bridge 或终端字节流。任何已有目标都不能被覆盖，失败、取消和并发
冲突不能把半成品暴露为最终文件。

当前只授权按下列依赖顺序收敛实现和验证。可靠性门禁或实现验证失败时必须按停止条件取消
或推迟 milestone，不能通过增加覆盖、Picker、文件管理器、后台服务、第二套 Host/Identity
或其他永久复杂度补救。详细边界、已确认决策和实现见
[`design/file-transfer.md`](design/file-transfer.md)。

2026-08-08，第一项本地提交门禁已在物理 HAD-W32（ARM64、API 22）闭合：公共 Downloads
根目录中的同目录 `fs.moveFileSync(temp, final, 1)` 成功提交只在源文件完整写入、`fsync` 并
关闭后执行；最终内容逐字节一致。预检查后由另一对象抢占目标时返回 `File exists`，已有目标
和本任务临时文件内容均不变；探针随后从应用权限上下文确认四个精确随机路径全部清理。
可复现入口为 `tools/verify-file-transfer-pc.ps1`，调试能力只在构建期注入并受 release package
marker 门禁约束。该证据只闭合本地无覆盖提交，不单独代表完整传输。

同日，物理 PC 的本地能力门禁也已闭合：上传源由 ArkTS 在已授权 Downloads 根执行
`lstat`、以 `READ_ONLY | NOFOLLOW` 打开并把 FD 交给 native，native 复制 FD 后再次 `fstat`
普通文件；打开后替换路径不会改变已打开对象。目标系统拒绝在公共 Downloads 和应用 cache
创建符号链接，因此 symlink 场景记录为系统能力不适用，而 no-follow 防线仍保留在产品路径。
可复现入口仍为 `tools/verify-file-transfer-pc.ps1`。

同日，远端协议门禁也由独立的 `leantty_ssh/sftp-interop-fixture` 闭合。锁定的
`russh 0.62.5 + russh-sftp 2.4.0` 在 WSL Ubuntu 26.04 上与临时 OpenSSH 10.2p1 完成两次
E2E：`CREATE | EXCLUDE | WRITE`、完整关闭、标准 SFTP v3 rename、提交前抢占、两侧内容保持
和精确清理全部通过；fmt、clippy 与 `aarch64-unknown-linux-ohos` 交叉 `cargo check` 通过。
`russh-sftp 2.4.0` 是检查时最新版本，Apache-2.0；相对 1.2 产品锁文件的传递新增包名均为
MIT、Apache-2.0 或双许可证。该依赖现已进入产品锁文件并通过 ARM64 HAP 构建。

当前产品已接入受约束的 `put/get` 解析、Downloads FD/no-follow 边界、独立 SFTP Session、
结构化事件、Pane 所有权、节流进度、`Ctrl+C` 取消入口、本地/远端排他临时对象及无覆盖提交。
2026-08-08，`tools/verify-put-get-pc.ps1` 先在物理 HAD-W32 上以生产命令事件链完成
131,089 字节 `GET → Downloads → PUT`。2026-08-09，同一脚本又使用 118,349,760 字节
（112.9 MiB）真实安装包，在同一个调试 HAP 上连续完成两轮稳定性复验：GET 分别为
6.232 秒和 6.254 秒，PUT 分别为 1.942 秒和 1.917 秒。线条式进度条收敛后的最终视觉候选
又完成第三轮，GET 为 6.198 秒、PUT 为 2.202 秒。三轮均显示正字节进度、实时速度和
`FINALIZING`，双向 SHA-256 一致，远端无临时对象残留，本地一次性文件精确清理。该定向
证据证明密码认证、显式 basename 下的小/大文件主链；下列取消、异常网络、其他认证方式和
完整尺寸/生命周期矩阵仍未完成。进度条选择的 `━`、`╸`、`─` 与完成标记 `●` 均已通过
固定打包字体 Regular/Bold 的单 cell advance 回归。

2026-08-09，路径语义和 Tab 补全收敛后，同一物理 PC 又完成 131,089 字节定向链路，以及
用户指定的 118,349,760 字节安装包链路。大文件 GET 为 6.550 秒（17.23 MiB/s），PUT 为
1.959 秒（57.59 MiB/s），双向 SHA-256 均为
`3cb7d8f41e6815992b0208552ad4626fd9ad0e4e159beaecba1afe34d494c613`。两轮均在已存在的
Download 子目录中预置同名文件，经 Tab 完成 GET 目录后自动提交为 `source (1).bin` 且原文件
保持不变；PUT 本地文件名经 Tab 完成并正确转义空格，远端目录目标沿用本地 basename。验证
期间未由命令创建目录，Tab 未发起网络请求，正字节进度、实时速度、`FINALIZING` 和精确清理
均通过。该调试门禁通过编译期隔离的验收 action 准备/清理公共 Download 测试状态，正式包继续
排除验收标记。

完成 1.3 必须满足：实现前门禁均有可复现证据；`put/get` 的解析、所有权、取消、冲突和
清理通过自动化；干净 ARM64 构建通过；同一个保留候选完成全部适用的物理 HarmonyOS PC
矩阵；文档、版本、签名、归档、GitHub Release 和 AppGallery 记录可追溯。SDK 声明、构建、
安装或启动不能替代真实行为验收。

## 1. 剩余实现收敛
- [ ] 把当前 Pane 的短生命周期传输状态收敛为明确的
  `PREPARING → TRANSFERRING → FINALIZING → SUCCEEDED/FAILED/CANCELLED` 状态；一次只运行一个
  本地命令，完成后回到原 `ltty>`，并为最终提交和全部终态增加定向状态测试。状态不得属于
  Tab 索引、WebView 或共享全局单例。
- [ ] 收敛结构化、可测试且不含凭据/文件内容的错误模型；至少区分权限拒绝、
  本地/远端冲突、路径拒绝、无 SFTP、认证/主机校验失败、空间不足、断线、取消、提交失败和
  清理失败。错误必须说明已发生什么以及用户下一步可执行的命令。
- [ ] 为 SFTP metadata/open/close/rename/remove 等复制循环之外的等待补齐取消和超时边界，
  并验证清理失败、断线和背压不会让 Pane 永久停留在传输状态或暴露半成品最终名称。

## 2. 自动化与集成门禁

- [ ] 覆盖 `put/get` 分词、引号、反斜杠、`--`、缺参、未知选项、未闭合引号、方向错误、
  文件与目录目标、多源、本地绝对路径、IPv6、Unicode/非 UTF-8、控制字符和空/超长名称；
  证明 `scp` 只提示，`--force`、`--overwrite` 和其他等价入口均被拒绝。
- [ ] 覆盖 Host/Identity/认证与 `ssh` 的解析一致性、命令级 `-i` 的非持久覆盖，以及
  `host add/set/list` 和已有本地命令行为不变。
- [ ] 覆盖 Downloads 边界、no-follow、FD 所有权、目标预存在、提交期并发抢占、自动编号、
  后缀/隐藏文件/Unicode/序号耗尽、既有多级子目录、中间 symlink、目录意图、临时文件同目录
  可见性与精确清理；每个冲突用例验证已有内容哈希不变。
- [ ] 覆盖本地路径、Host 和 `-i` 的 Tab 上下文、唯一/多候选、公共前缀、空格与引号转义、
  隐藏项、大小写/Unicode、控制字符净化、候选上限和无授权状态；证明补全不发起网络请求、
  不递归枚举，也不改变已有 `ssh`、`host` 和命令名补全。
- [ ] 覆盖上传 `CREATE | EXCL | WRITE`、标准 rename、禁止危险回退、空/小/大文件哈希、
  进度节流、取消、断线、背压、清理失败、两个 Pane 隔离和取消后的迟到事件。
- [ ] 运行受影响的 ArkTS、Web/策略、PowerShell 工作流和 WSL Rust fmt/clippy/test；只在受影响
  行为需要设备包时运行 `tools/dev-pc.ps1`，并通过干净 ARM64 debug HAP 集成检查和
  `git diff --check`。普通迭代不运行完整 release gate。

## 3. 物理 ARM64 HarmonyOS PC 验收

- [ ] 从未授权状态执行首条 `put/get`：只出现真实系统 Downloads 权限弹窗；拒绝后终端仍可用，
  再次执行可以恢复；两个 Pane 同时请求时不出现并行授权状态。
- [ ] 从 Downloads 根上传并下载空、小、大文件，验证文件管理器可见性、实际保存名称和端到端
  SHA-256；覆盖空格、Unicode、长文件名与已决定的相对子目录规则。
- [ ] 预置远端上传目标、明确本地下载目标，以及省略目标或指向既有目录的 basename，并在
  预检查后抢占最终名称：明确目标与所有 `put` 必须失败且已有文件哈希不变；LeanTTY 选择的
  本地名称必须在不重传内容的情况下提交到下一个最小可用名称。
- [ ] 在固定打包字体下验证 Tab 补全的文件/目录候选、空格与 Unicode、公共前缀和候选列表；
  验证 Tab 不弹 Downloads 权限、不连接远端，候选和传输摘要中的不安全控制字符不能影响
  终端布局或注入控制序列。
- [ ] 分别在传输中执行无选区 `Ctrl+C`、有选区 `Ctrl+C`、断网、关闭 Pane、关闭应用、最小化、
  休眠和恢复；验证已冻结行为、最终名称不可见/完整、临时文件精确清理和迟到事件隔离。
- [ ] 使用密码、未加密密钥、加密密钥和 keyboard-interactive Host 各完成传输，并验证
  `put/get -i other` 不改变后续 `ssh` 或 `put/get`。
- [ ] 验证无 SFTP、远端权限拒绝、本地空间不足、服务器不支持可靠无覆盖提交和清理失败时，
  终端可恢复、错误可执行且已有文件不变；检查 hilog、命令历史和错误快照不含凭据或文件内容。
- [ ] 在同一个保留候选上完成键盘、IME、Tab/Pane、终端输入输出、搜索、选择/复制、链接、
  tmux/vim/less/Agent TUI、窗口与 SSH 主路径的最小稳定 smoke，证明文件传输没有破坏现有核心
  终端事件链。

## 4. 文档、版本与发布

- [ ] 实现与证据闭合后，把 `design/file-transfer.md` 从活动方案更新为完成事实，并同步
  `design/README.md`、中英文离线 User Guide、安全边界和必要的开发文档；删除已失去门禁价值的
  临时探针或只保留受原则约束的持续回归入口。
- [ ] 将用户可见改动记录到 `CHANGELOG.md`。在功能和依赖稳定、准备保留候选时再按
  `versioning.md` 选择并统一推进 `1.3.0` 的所有版本源和 `versionCode`；不能提前把 WIP 描述成
  已发布能力。
- [ ] 准备正式发布包时才运行 `tools/test-regression.ps1`、`tools/verify-pc.ps1` 和
  `release-process.md` 的隔离 production/review 流程；冻结一个精确提交、tree、native 输出、
  签名 APP/HAP、哈希和同候选物理机证据。
- [ ] 只有 1.2.0 AppGallery 审核已到终态，且 1.3.0 的不可变签名标签和匹配 GitHub Release
  已发布后，才提交同版本 production APP。1.2.0 若审核失败，先按独立 `1.2.1` PATCH 流程处理，
  不移动标签、不替换 Release，也不把 1.3 功能混入补丁。

## 当前非目标与停止条件

- 不做远端目录浏览或路径补全、递归、多源、同步、后台队列、覆盖选项、文件预览/打开、
  Picker、Downloads 之外的本地路径、文件管理 UI、传输历史或第二套 Host/Identity；仅保留
  本节已授权的本地 Downloads、Host 和 LeanTTY 密钥名有界补全。
- 不开放交互式 `sftp`、`scp` 兼容命令或任意 SSH subsystem；不为未来 Mosh/HSL/插件建立
  通用 transport、任务系统或扩展点。
- `russh-sftp` 无法可靠构建/运行、现有认证状态机必须被破坏、Downloads 权限无法稳定发布、
  取消/断线不能避免损坏最终文件，或实现必须扩大为文件管理器/后台服务/持久队列时，停止
  1.3 而不是扩大方案。
- 拟议 1.4 HSL、1.5 ProxyJump、1.6 Mosh 和 1.7 SSH 配置/诊断/资产互操作只存在于
  [`roadmap.md`](roadmap.md)，不是当前 TODO。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到 Changelog、设计文档和 Git 历史，并从
   本文件删除。
2. 每项任务必须说明可观察完成条件；SDK 声明、构建、安装或启动不能替代真实行为证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-13
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
证据证明密码认证、显式 basename 下的小/大文件主链；后续门禁已闭合取消、异常网络、其他认证
方式和完整尺寸/生命周期矩阵。进度条选择的 `━`、`╸`、`─` 与完成标记 `●` 均已通过
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

2026-08-12，当前 Pane 已拥有显式、可测试且不进入 Tab/WebView/全局单例的传输生命周期：
`PREPARING → TRANSFERRING → FINALIZING → SUCCEEDED/FAILED/CANCELLED → IDLE`。本地 Downloads
准备阶段也进入同一完成 Promise，`Ctrl+C` 或关闭 Pane 不会在异步准备返回后重新启动 native
传输；全部终态回到原 `ltty>`。错误输出收敛为有限类别并给出可执行下一步，底层 detail、凭据
和文件内容不直接回显；本地/远端清理失败有独立警告。SFTP metadata/open/close/rename/remove
以及本地 flush/sync 均增加 30 秒上界并响应同一取消信号，远端失败清理由独立 30 秒上界兜底。
解析矩阵还覆盖分词、单双引号、转义、`--`、参数数量/方向、全部拒绝选项、IPv6、Unicode、
控制字符、空/超长路径和无法形成有效 UTF-8 的孤立 surrogate；由此修复了 `put ''` 曾错误复用
GET 可省略本地目标规则的问题。ArkTS 97/97、Rust 产品库 17/17、workspace clippy 和调试构建
工作流通过；ARM64 native 与调试 HAP 构建、安装成功。随后按专用测试机流程只在 HarmonyOS
明确返回锁屏错误时从仓库外本机凭据转换数字物理按键完成解锁，并直接启动已安装 HAP。该 HAP
SHA-256 为 `82e63465776698a584984693a69f7780b9741c5b94ae0ddfd29f0fc6cea34121`；用户指定的
118,349,760 字节安装包再次完成 `GET → Downloads 既有子目录自动编号 → PUT 到既有远端目录`，
GET 为 10.215 秒（11.05 MiB/s），PUT 为 4.308 秒（26.20 MiB/s），双向 SHA-256 一致，正字节
进度、实时速度、`FINALIZING`、原文件保留和临时对象清理均通过。另一个编译期隔离的专用验收
HAP 重新闭合 Downloads no-replace 与 FD/no-follow 边界；过程中发现并修复验收源在产品已经导入
`BorrowedFd` 时重复注入该 import 的构建回归，构建工作流新增唯一性断言。取消、断线、清理失败
和生命周期物理矩阵仍保留在下文。

同日，SFTP channel 建立、subsystem 请求、Session 初始化、Session 关闭和 SSH 断开也复用同一
30 秒等待与取消原语，不再存在独立无界等待。随后使用同一生产 GET、密码认证和 8,388,608 字节
受控慢速 SFTP 源，在物理 PC 正字节传输期间注入无选区 `Ctrl+C`；终端仅产生一次 `cancelled`，
436 毫秒内回到 `IDLE` 和原 `ltty>`。既有 `source.bin` 哈希不变，自动编号最终文件未出现，任务
所有的同目录 `.part` 在 fixture 清理前已不存在；本轮调试 HAP SHA-256 为
`ab2f0b3c2dcdfd4efcac2df82c1ad9efab64b2b6eaa9d0a2d73de38224ca05f9`。该证据只闭合无选区
`Ctrl+C` 的在途 GET 路径；有选区复制、断线、清理失败及其他生命周期场景仍保留在下文。

同一受控源随后把每次 SFTP 读写延迟提高到 250 毫秒，并在生产 GET 已出现正字节进度后分别
执行真实系统关闭按钮与活动 Pane 的 `×`。确认关闭应用时，全部 Pane 共用一次关闭准备 Promise，
先得到恰好一次 `cancelled` 和 `IDLE`，再记录准备完成并退出旧进程；确认到进程退出为 793 毫秒，
重新启动后证明既有文件字节不变，未暴露自动编号最终文件且无本地/远端任务临时对象。确认关闭
Pane 时，实机先分屏并聚焦传输 Pane，再通过真实 `Close pane` 对话框确认；710 毫秒内恰好一次
`cancelled` 并回到 `IDLE`，原应用进程和另一个 Pane 均保留，最终文件和临时对象均不存在。当前
源码加入的应用关闭协调器只复用每个 Pane 已有的 `disconnect()` / 完成 Promise，不增加传输
管理器或后台任务。该证据闭合传输中的受控 Pane/应用关闭；后续门禁又闭合异步 Downloads 准备
期间关闭、强制终止、断线、背压、清理失败和迟到事件隔离。两条门禁复用当前源码构建的同一 HAP，
SHA-256 为 `942a775628625f6dda9c7df8297e12ae6255fe04769a514a7fe93587fedca51f`。

随后审计发现，`disconnect()` 虽会等待 `PREPARING` 完成，但系统 Downloads 请求若长期不返回，
原实现没有释放当前 Pane 等待的入口。现在共享权限请求继续保持进程内 single-flight，各 Pane 只用
自己的取消 Promise 与该请求竞争；关闭只结束该 Pane 的准备等待，不伪造或取消系统请求。取消先到
时立即进入统一 `CANCELLED → IDLE`，权限 Promise 稍后完成只清除共享状态，不会迟到打开文件或
创建 native Session。ArkTS 98/98 及构建注入/还原契约通过。编译期隔离的调试哨兵随后在物理 PC
让 GET 永久停在 `PREPARING`：确认关闭应用在 496 毫秒内完成唯一 `cancelled`、`IDLE`、关闭准备
和进程退出；确认关闭 Pane 在 406 毫秒内完成相同终态，并保留原 PID 与另一个 Pane。两条路径均
未进入认证、正字节进度、`FINALIZING` 或完成事件，也没有最终文件和本地/远端临时对象。两条
门禁复用同一 HAP，SHA-256 为
`d756165a410ffe2cdaf01c5f864c864e3d59eccfc8b06ee78018b854c47757b5`。

同一 HAP 随后完成受控远端清理失败门禁：仓库内 SFTP fixture 在生产 PUT 创建随机排他临时文件后，
先拒绝写入，再拒绝删除该临时文件。真机只收到一次 `REMOTE_CLEANUP` 失败并回到 `IDLE` 和原
`ltty>`；终端用红色固定文案提示用户删除匹配的 `.leantty-*.part`，不回显底层 detail 或凭据。
远端 `cleanup.bin` 最终名从未出现，只留下一个可识别的
`.cleanup.bin.leantty-1-a93a09b52a94cff7.part`，既有本地 `source.bin` 字节不变。fixture 的
write/remove 双故障日志、设备截图与结构化证据保存在
`build/verification/put-remote-cleanup-failure-final-verified/`。验收中同时修复了 fixture 为新连接
构造 Handler 时漏传故障模式，以及 Windows 重定向日志必须以 `FileShare.ReadWrite` 读取的问题；
两处均有自动化回归保护。

断线门禁随后使用 8,388,608 字节、每次 read 延迟 250 毫秒的生产 GET，在已经读取两个 65,536
字节块并出现正字节进度后终止受控 SSH 服务。审计同时发现复制循环原先没有拒绝“已知大小但
提前 EOF”，可能把截断数据当成功提交；现在 PUT/GET 都核对已知源大小，无错误提前 EOF 统一为
`SOURCE_CHANGED`，远端 GET 的读连接错误按方向标记为 `NETWORK`，本地 PUT 读错误仍为 `READ`。
真机断线后恰好一次 `NETWORK`，10,418 毫秒内回到 `IDLE` 和 `ltty>`，红色固定文案正确提示检查
网络和 Host；既有 `source.bin` 不变，自动编号最终文件和任务 `.part` 均不存在。该次重新构建的
ARM64 native SHA-256 为 `a498f3e57dd953ea3555e28a0f2c0851afba30ab65606493b54e7c6b5facdf39`，
HAP SHA-256 为 `97581c68a9f19b6e7901b0021e68001b6bde5abcf6666f2445e42c9cc4ae10b4`；截图和
结构化证据保存在 `build/verification/get-disconnect-final-network/`。

本地清理失败门禁随后使用编译期隔离的原生/ArkTS 双层故障点：生产 GET 为不存在的远端源创建
排他 `.part` 后，原生守卫只对该专用源把清理交还 ArkTS，ArkTS 的真实 cleanup 分支再注入 unlink
失败。真机保留 `REMOTE_NOT_FOUND` 作为唯一主失败，追加红色本地清理警告并回到 `IDLE`；明确的
`local-cleanup-failure.bin` 最终名未出现，fixture 在清理前观察到恰好一个同目录 `.part`，既有
`source.bin` 字节不变，随后删除全部验收数据。调试注入在构建后逐字节还原，不进入生产源码；
HAP SHA-256 为 `d72185ebe4fdb25269a49ba46bf3da1a733339f37dd91b6019a902d9586f2c11`，截图和
结构化证据保存在 `build/verification/get-local-cleanup-failure-final-v3/`。

背压门禁把编译期隔离的文件传输 N-API 回调队列缩到 2，并仅对专用 8,388,608 字节 GET 的首个
进度回调阻塞 ArkTS 主线程 1,500 毫秒；受控 SFTP 每次操作延迟 100 毫秒。原生层明确记录 5 个
中间回调因队列已满而丢弃，但阻塞送达的 `FINALIZING`/完成事件仍使 GET 恰好完成一次并回到
`IDLE`。最终 `backpressure-result.bin` 只在完成后出现，无 `.part` 残留；随后生产 PUT 将其回传，
双向 SHA-256 都为 `2e6a02073336e11815d473865145e9cca58a3b622699a294cce91068831c5f37`。
调试 HAP SHA-256 为 `2c68787f036cc73215ff372c9e02faaaa4c4ed802e780fa14e5b597f2953999b`，截图和
结构化证据保存在 `build/verification/put-get-backpressure-final-v3/`。

强制终止门禁在生产 GET/PUT 均出现正字节进度后执行系统 `aa force-stop`，旧进程分别在 325/329
毫秒内退出，且没有进入应用关闭准备、传输终态或 `IDLE`，证明没有借用优雅取消路径。GET 的
`force-get-result.bin` 最终名未出现，只留下一个同目录 `.part`；PUT 的 `force-put-result.bin`
最终名未出现，只留下一个
`.force-put-result.bin.leantty-1-d74f81d9c15fcc44.part`。每次重启后的新 Pane 均可聚焦，验收夹具
记录现场后删除本地/远端残留和专用源文件。该调试 HAP SHA-256 为
`f4c2aeb615ca109928df62df7f685bed5ca7e4d65def00a27e4d1a425e768056`，结构化证据保存在
`build/verification/put-get-force-termination-final/`。

最后的双 Pane 迟到事件门禁在原应用进程内保留两个 Pane：左 Pane 的 8,388,608 字节 GET 在正字节
进度后由 `Ctrl+C` 恰好取消一次；下一次同 Pane GET 启动后，编译期隔离夹具把旧
`transferId + paneId + generation` 伪装为完成事件重新送达，生产客户端明确拒绝。随后在第二次
GET 正字节进度后终止受控 SSH 服务，得到恰好一次 `NETWORK` 和 `IDLE`；焦点移到右 Pane 后，
第二个旧完成事件延迟 10 秒送达并再次被拒绝。两次拒绝均没有产生完成结果，两个 Pane 和原 PID
保留，右 Pane 可聚焦，两个请求的最终文件均未出现且没有任务 `.part` 残留。调试 HAP SHA-256 为
`2a1395efec149242556316a046e3d9f2659cb9b3ee3902f1d55c9eaa936fc84e`，结构化证据、布局和截图保存在
`build/verification/put-get-late-events-final-8/`。验收同时补齐 `FileTransferClient` 的设备日志采集
标签，避免门禁把日志过滤误判为事件缺失；该标签有 PowerShell 回归保护。

认证观测门禁随后从“提交命令后反复读取 `hilog -z 500` 尾部快照”收敛为两个有界来源：按 Enter
前启动的当前应用 PID / `SessionViewModel,FileTransferClient` 实时流，以及原有快照。纯函数回归
分别覆盖 snapshot-only、live-only、双命中和双缺失；前任一来源命中即可继续，并把来源写入证据，
后者在 30/20 秒边界保存布局、截图和诊断 JSON 后明确报告产品认证状态未被观察到，不作无界重试。
物理 PC 使用随机端口完成 131,089 字节 `GET → Downloads → PUT`：GET 主机校验、GET 密码与 PUT
密码三个检查点本轮均由两种来源观察到，双向 SHA-256 一致，实时捕获不含临时密码。证据位于
`build/verification/put-get-auth-observation-final/`，复用的调试 HAP SHA-256 为
`2a1395efec149242556316a046e3d9f2659cb9b3ee3902f1d55c9eaa936fc84e`。

2026-08-13，编译期隔离的 Downloads manager 门禁直接调用生产 `TransferFileManager`，不复制
传输实现。物理 HAD-W32 上，明确目标预存在会在准备期拒绝且原字节不变；准备后再抢占明确目标会
在 mode 1 提交期拒绝，同时保留已有目标和完整临时对象；自动目标连续占用 basename 与 `(1)` 后
把同一临时对象提交为最小可用 `(2)`，前两份内容不变。探针同时确认 `.part` 位于最终目录、失败后
由产品 cleanup 精确删除，以及多级既有目录中的 PUT 通过 `NOFOLLOW` 打开并把原对象 FD 交给
native。原有同目录 no-replace 与 FD/no-follow 探针也在同一 HAP 复验通过；设备拒绝在 Downloads
和私有 cache 创建 symlink，因此记录的是平台拒绝边界，产品仍保留逐组件 `lstat + DIR + NOFOLLOW`。
随机探针目录完全清理，HAP SHA-256 为
`0eb2098ddf09c6314e28cbd05419c1d47bae3e1b62ac8e103d1cb5180912a71d`，证据位于
`build/verification/file-transfer-manager-boundary-final/`。自动化另固定隐藏文件、多后缀、尾点、Unicode
截断与第 9,999 号候选，并保护 10,000 候选耗尽后的安全失败源码契约；后续
`file-transfer-manager-boundary-final-3` 已在物理机上闭合完整序号耗尽交互。

2026-08-13，固定打包字体下的物理 Tab 矩阵闭合：真实裸 Tab 经 ArkUI key dispatch 进入当前 Pane，
依次覆盖既有目录、转义空格、未闭合引号规范化、Unicode、隐藏文件、公共前缀、二次确认后的
双候选列表，以及 bidi 格式控制符文件名过滤；全程没有权限、认证或传输事件。门禁过程中发现并
修复补全分词器把 `report\ ` 的转义末尾空格误判为新操作数、继而错误进入 Host 补全的问题；
ArkTS 103/103 和物理矩阵均通过。按键注入器同时增加 5 秒上界和一次有限重试，避免 HDC `uinput`
异常时无界挂住。证据、原始补全状态、布局和截图位于
`build/verification/put-get-tab-completion-product-fix-final/`。

同日，本地空间不足门禁也闭合。Rust 复制循环以真实 `ENOSPC` writer 证明错误稳定映射为 `WRITE`
且失败字节不产生进度；编译期隔离的物理 acceptance 路径在生产 GET 已建立 SFTP Session、拥有
Downloads 同目录排他临时文件后注入同一 `No space left on device` 终态。真机只产生一次失败并
回到 `IDLE`，红色固定文案明确提示释放 Downloads 空间，最终文件未出现、任务临时文件精确删除、
既有文件字节不变，布局、日志和错误快照未暴露临时凭据。证据位于
`build/verification/get-local-disk-full-passed/`。目标系统 shell 对 `/dev/full` 返回权限拒绝，因此
没有把不可达设备节点伪装成产品证据；真实错误映射由 Rust 单测覆盖，设备门禁负责 UI、所有权、
清理和恢复事件链。

同日，完整认证矩阵在物理 HAD-W32 上闭合。生产 `get/put` 依次使用显式未加密 Ed25519 key、
为同一 key 增加 passphrase 后的加密 key、两轮 keyboard-interactive，以及显式 `-i` 命令后的
无 identity 密码回退；每条命令都完成真实 SFTP 传输、唯一终态、方向与精确清理检查，临时 key
最终通过产品 `key rm` 流程删除。安全输入通过 Native → Web 的有类型 `inputSecurity` 状态只在
密码、key passphrase 和非回显 challenge 模式启用；xterm 消费按键后清空辅助输入值。所有隐藏
输入布局快照与应用日志均不含凭据，正常命令输入与终端画布保持可用。证据位于
`build/verification/put-get-authentication-matrix-final-2/`，HAP SHA-256 为
`40eea79c4009a8542716b9799c5f7edc362f2975ea329d4a30486b748af7d86c`。

同一 HAP 随后分别闭合无 SFTP subsystem、远端权限拒绝和服务器拒绝标准可靠 rename 三条失败
门禁：每条只产生一次对应失败、回到 `IDLE`，没有最终名或临时文件残留，也没有降级为覆盖写。
空文件又完成 `GET → Downloads 自动编号 → PUT`，双向 SHA-256 为标准空文件哈希且显示 `0 B`
完成摘要。最后，8 MiB 延迟 GET 在出现正字节进度后经真实系统按钮最小化，在窗口不可见期间完成，
恢复时保持同一 PID、可聚焦终端和完整最终文件，并继续完成 PUT、哈希与清理。证据分别位于
`build/verification/put-get-sftp-*-final*/`、`build/verification/put-get-empty-final/` 和
`build/verification/put-get-minimize-final/`。

当前源码的软件回归已顺序通过：公共源码与构建工作流策略、设备门禁 helper、Web/固定字体、
离线指南、ArkTS 103/103、WSL Rust fmt、workspace clippy、native/core/fixture 单测和 SSH fixture
E2E；证据为 `build/verification/targeted-regression-final.json`。真机门禁不以安装或构建代替行为。

同日，有选区 `Ctrl+C` 门禁发现 ArkWeb 在 xterm 选区存在时会吞掉浏览器快捷键分发，DOM
`keydown` 与浏览器级 `copy` 都不能稳定到达产品处理器。当前实现把精确 Ctrl+C 提升到 Web 的
`onKeyPreIme`，经空 payload typed bridge 回到所属 xterm：终端选区优先复制，搜索框只复制自身
选区，无选区才发送 ETX。物理 PC 在 1 MiB 受控慢速 GET 已显示正字节进度和实时速度后建立
4 字符选区，Ctrl+C 只产生一次成功剪贴板写入，没有取消或失败；随后 GET、PUT、`FINALIZING`、
双向 SHA-256 和精确清理全部通过。HAP SHA-256 为
`8c97fa390f742efea09ae24bc10d441b480097167e9c199a2e75f40766c6e97d`，结构化证据位于
`build/verification/put-get-selection-copy-final-9/`。

随后，生产命令事件链完成空格、Unicode 与 224 字符 basename 的 GET/PUT 往返。三组均在既有
Downloads 同名文件旁选择最小 `(1)` 名称、保留原内容并保持 131,089 字节 SHA-256 一致。长名称
首次发现远端临时名复制最终 basename 会超过组件上限；实现改为同目录固定长度
`.leantty-<transfer>-<nonce>.part` 后，Rust 255 字节回归和真机往返均通过。相同 HAP 又完成固定
字体 Tab 矩阵：目录、空格、引号、Unicode、隐藏项、公共前缀、再次 Tab 列表及格式控制字符排除
均使用生产命令缓冲区判定，且没有权限或网络副作用。证据分别位于
`build/verification/put-get-file-name-matrix-final-9/` 和
`build/verification/put-get-tab-completion-final-1/`，HAP SHA-256 为
`5928accd750c2bfb0a1d37c77111cd87b2e32d86672c8175856da14ce391b4ab`。

Downloads manager 探针又实际预置 basename 与 `(1)..(9999)` 共 10,000 个占用名称；生产自动
提交安全返回 `LOCAL_CONFLICT`，全部占用内容逐字节不变，完整临时对象只由产品 cleanup 删除。
同一门禁继续通过 no-replace、FD/no-follow、提交期抢占、最小编号、多级既有目录和精确清理；
证据为 `build/verification/file-transfer-manager-boundary-final-3/`。8 MiB 延迟 GET 随后在正字节
进度和实时速度后执行真实系统 suspend，5 秒后 HDC wakeup 并按本机流程解锁；应用保持同一 PID，
GET 经 `FINALIZING` 提交完整文件，同一 Pane 继续完成 PUT、SHA-256 与清理。证据为
`build/verification/put-get-suspend-final-3/`，HAP SHA-256 为
`57044b4927448c909e2167775f0f528f211144a69e5e712e3672543f5ec44ca9`。当前源码随后通过完整软件
回归：ArkTS 104/104、Web/固定字体/指南、PowerShell、WSL Rust fmt/clippy/native/core/fixture
测试及 SSH fixture E2E；证据为 `build/verification/targeted-regression-1.3-final-2.json`。

完成 1.3 必须满足：实现前门禁均有可复现证据；`put/get` 的解析、所有权、取消、冲突和
清理通过自动化；干净 ARM64 构建通过；同一个保留候选完成全部适用的物理 HarmonyOS PC
矩阵；文档、版本、签名、归档、GitHub Release 和 AppGallery 记录可追溯。SDK 声明、构建、
安装或启动不能替代真实行为验收。

## 1. 自动化与集成门禁

- [x] 覆盖 Downloads 边界、no-follow、FD 所有权、目标预存在、提交期并发抢占、自动编号、
  后缀/隐藏文件/Unicode/序号耗尽、既有多级子目录、中间 symlink、目录意图、临时文件同目录
  可见性与精确清理；每个冲突用例验证已有内容哈希不变。
- [x] 覆盖本地路径、Host 和 `-i` 的 Tab 上下文、唯一/多候选、公共前缀、空格与引号转义、
  隐藏项、大小写/Unicode、控制字符净化、候选上限和无授权状态；证明补全不发起网络请求、
  不递归枚举，也不改变已有 `ssh`、`host` 和命令名补全。
- [x] 覆盖上传 `CREATE | EXCL | WRITE`、标准 rename、禁止危险回退、空/小/大文件哈希、
  进度节流、取消、断线、背压、清理失败、两个 Pane 隔离和取消后的迟到事件。
- [x] 运行受影响的 ArkTS、Web/策略、PowerShell 工作流和 WSL Rust fmt/clippy/test；只在受影响
  行为需要设备包时运行 `tools/dev-pc.ps1`，并通过干净 ARM64 debug HAP 集成检查和
  `git diff --check`。普通迭代不运行完整 release gate。

## 2. 物理 ARM64 HarmonyOS PC 验收

- [ ] 从未授权状态执行首条 `put/get`：只出现真实系统 Downloads 权限弹窗；拒绝后终端仍可用，
  再次执行可以恢复；两个 Pane 同时请求时不出现并行授权状态。
- [x] 从 Downloads 根上传并下载空、小、大文件，验证文件管理器可见性、实际保存名称和端到端
  SHA-256；覆盖空格、Unicode、长文件名与已决定的相对子目录规则。
- [x] 预置远端上传目标、明确本地下载目标，以及省略目标或指向既有目录的 basename，并在
  预检查后抢占最终名称：明确目标与所有 `put` 必须失败且已有文件哈希不变；LeanTTY 选择的
  本地名称必须在不重传内容的情况下提交到下一个最小可用名称。
- [x] 在固定打包字体下验证 Tab 补全的文件/目录候选、空格与 Unicode、公共前缀和候选列表；
  验证 Tab 不弹 Downloads 权限、不连接远端，候选和传输摘要中的不安全控制字符不能影响
  终端布局或注入控制序列。
- [x] 分别在传输中验证休眠和恢复；有选区 `Ctrl+C` 只复制、断网和最小化已经由上文物理门禁
  闭合。继续验证已冻结
  行为、最终名称不可见/完整、临时文件精确清理和迟到事件隔离。无选区 `Ctrl+C` 以及确认
  关闭 Pane/应用的在途 GET 已由上文物理门禁闭合。
- [x] 使用密码、未加密密钥、加密密钥和 keyboard-interactive Host 各完成传输，并验证
  `put/get -i other` 不改变后续 `ssh` 或 `put/get`。
- [x] 验证无 SFTP、远端权限拒绝、本地空间不足、服务器不支持可靠无覆盖提交和清理失败时，
  终端可恢复、错误可执行且已有文件不变；检查 hilog、命令历史和错误快照不含凭据或文件内容。
- [ ] 在同一个保留候选上完成键盘、IME、Tab/Pane、终端输入输出、搜索、选择/复制、链接、
  tmux/vim/less/Agent TUI、窗口与 SSH 主路径的最小稳定 smoke，证明文件传输没有破坏现有核心
  终端事件链。

## 3. 文档、版本与发布

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

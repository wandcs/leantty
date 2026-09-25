# Mosh 断连批量诊断与去重案例

日期：2026-09-25。对象：`mosh-client v0.1.3`，提交
`77f210150a54963148304adabeae1e4382f6a750`；stock Mosh 1.4.0，WSL C.UTF-8，147×43。
这是一次诊断交接，不授权修改库的兼容合同或资源限制。任务状态仅在 `next-work.md`。

## 结果

原始 `\cat /bin/ls` 已录制到独立后续命令完成，遇错后继续重放，没有在第一个错误处
结束。48 个差分中 8 个操作被拒绝，全部归并为 C01；后面的输出没有发现另一个拒绝
类别。再根据全部终端拒绝入口和 stock 服务端的输出序列化分支，扫描 277 个直接输入
案例，其中 271 个也经过真实 stock-server 归一化；最终得到以下 **7 类**。

| ID | 去重后的 case | 具体触发 | 原版结果 | 定性与处理建议 |
|---|---|---|---|---|
| C01 | 标题文本含分号 | OSC 0/1/2，`hello;world`；BEL/ST | UnsupportedOsc → Protocol | 确认缺陷；按标题文本语义处理分号。单/多分号、中英文、三种标题命令归同一根因 |
| C02 | SGR 属性缺口 | `CSI 5 m` 闪烁、`CSI 8 m` 隐藏文字 | UnsupportedCsi → Protocol | stock 保留并发送的普通文字属性；同一属性解析/存储缺口，两个语义子例都须保留 |
| C03 | 整屏反色缺口 | `CSI ?5h`；开启后的 `CSI ?5l` | UnsupportedCsi → Protocol | stock 正常屏幕模式；单独建反色状态 case，不能与 SGR 7 的单字反显混淆 |
| C04 | 已排除的鼠标模式 | `CSI ?1001h`、`CSI ?1015h` | UnsupportedCsi → Protocol | 库既有 profile 只抑制相应复位，未支持开启；需一次决定支持、抑制或保留拒绝，不冒称新回归 |
| C05 | 非法 OSC 52 载荷 | 剪贴板内容 `%%%` 非 Base64 | UnsupportedOsc → Protocol | 已有拒绝策略；独立于 C01。合法 `YWJj` 正常且不转发副作用，不应为它放宽其他 OSC |
| C06 | 每格 scalar 数超过 8 | `A` + 8 个 U+0301，共 9 个 scalar | TooManyScalarsInCell → Protocol | 真实触及维护者要求保留的资源上限；7 个重音、共 8 个 scalar 是正例 |
| C07 | 每格 UTF-8 字节存储边界 | `A` + 7 个 U+1AB0，共 8 个 scalar、22 字节 | CellEncodingTooLarge → Protocol | 另一条既有资源边界；追加前已有 19 字节，达到 `>=18` 的保守拒绝线；6 个重音、19 字节是正例 |

不是 7 个都要“修到不报错”。建议库侧本批一起处理 C01–C03；C04–C05明确策略，
C06–C07保留已批准上限并作为负例。两个资源错误目前映射为 Protocol；如调整错误
分类，应与资源策略分开，不通过吞错、重试或自动重连掩盖。

## 可直接交接的最小样本

机器可读的 [cases.json](../../tools/diagnostics/mosh-disconnect/cases.json) 保留七组
19 个独立正反例、精确字节、原版私有错误和 stock-server 公共结果。
[批量重放脚本](../../tools/diagnostics/mosh-disconnect/run.py) 在副本中调用原版
`apply_host_bytes`，一次执行全组，某个失败不会阻止下一个 case；
[运行说明](../../tools/diagnostics/mosh-disconnect/README.md) 包含使用方法及判据。
基线里的错误不是修复后的期望值，不能要求所有 case 都变成 Ok。

最短远端输出样本如下。它们会影响当前终端状态，仅用于受控测试会话；本轮已经
通过独立 stock-server 会话执行，无需维护者再手动逐个断连。

```sh
# C01：OSC 0；OSC 1、2 同组，ST 终止另有子例
printf '\033]0;hello;world\007'
# C02：两个子例分别执行
printf '\033[5mX'
printf '\033[8mX'
# C03：开启反色；复位子例须先处于反色状态
printf '\033[?5h'
# C04：两个已排除模式分别执行
printf '\033[?1001h'
printf '\033[?1015h'
# C05：不合法的剪贴板载荷
printf '\033]52;c;%s\007' '%%%'
# C06、C07：两条资源上限，分别执行
python3 -c 'print("A" + "\u0301" * 8)'
python3 -c 'print("A" + "\u1ab0" * 7)'
```

原版库的 19 个独立 stock-server 案例中，12 个返回 Protocol，7 个对照正常结束并
输出 AFTER_CASE。另用官方 stock 客户端检查九个失败代表：都能看到后续标记并正常
退出。它证明服务器会发送这些状态及客户端行为差异，不替 LeanTTY 决定扩展合同。

特别注意 C03：单独发送 `?5l`，服务器本来就未反色时不会产生该状态变化，因此
独立 stock 正例正常；它作为直接 HostBytes 会失败，批量录制也确实捕获了开启后的
复位失败。OSC 的 BEL/ST连续相同标题同样可能被服务器去重，不能把第二个无差分
样本当作“已支持”；独立会话和直接字节 case 保留这种区别。

## 如何保证没有只看到第一个错误

1. 固定库源码，隔离副本只用于受控录制。记录经过鉴权、解压和同步计划筛选后的
   原始 TerminalDifference，保留 `base_state → target_state`，没有简单拼接数据流。
2. 对每个 HostBytes 先执行原版校验。拒绝时保留类别与操作位置，诊断副本才推进
   解析，并记录同操作中所有拒绝回调，继续接收后续差分。没有修改产品、锁定源码
   缓存或 `mosh-client-rs` 项目，没有将该行为安装到测试机。
3. 离线从对应引用状态重放每个差分，记录错误后继续到最后。资源拒绝后的诊断
   屏幕可能截断；它只用于找后续入口，不是恢复方案或会话通过证据。
4. 从每类提取独立字节样本，在干净副本复验。生产代码与锁定版本一致，只追加
   测试模块；19 个 stock-server 正反例分别从新会话开始，排除上一错误污染。
5. 对照 stock 1.4.0 的输出序列化源码，补扫文字属性和模式，避免只围绕当前二进制
   文件做随机重试。该过程完成后才整体交接。

| 录制 | 完整差分数 | 原版拒绝操作数 | 结束证明 |
|---|---:|---:|---|
| 原始交互 zsh + `\cat /bin/ls` | 48 | 8 | 单独提交的 BATCH_BINARY_DONE 在最终屏幕可见 |
| 字符/标题/控制/模式批次，156 个输出样本 | 159 | 22 | BATCH_SWEEP_DONE，全部差分遍历完成 |
| SGR 0–109 与复位/颜色补充，115 个样本 | 118 | 2 | BATCH_SWEEP_DONE，全部差分遍历完成 |
| 合计 | 325 | 32 | 三份记录均完成 |

直接输入的 277 个样本中有 170 个被拒绝；**不能把它们叫做 170 个真实断连点**。
例如 C0/C1、DEL、某些 ESC/CSI 被 stock 服务端消费、替换或归一化，没作为同样的
HostBytes 发给客户端。非法 UTF-8、不完整序列和跨操作组合字符另保留为协议合同
负例；未把它们虚构为当前 stock 输出缺陷。

这些潜在拒绝也没有丢弃：[完整 277 项扫描集](../../tools/diagnostics/mosh-disconnect/scan-cases.jsonl)
保留每个输入与原版结果，批量脚本加 `--scan` 可一次重放。按触发语义另外归并如下，
它们不是新增已确认的 stock-server 断连点：

| 类别 | 最小字节/步骤 | 直接 HostBytes 结果 | stock 路径与边界 |
|---|---|---|---|
| R01 OSC 的 ST 终止 | `ESC ] 0 ; hello ESC \\`，标题无分号也成立 | UnsupportedEscape | stock 将输出规范化为 BEL；底层 ST 终止处理缺口独立于 C01，原始 ST 字节不能据此宣称支持 |
| R02 真正零宽字符的起点/分段 | 行首 U+0301；两次操作 `A`、U+0301；控制定位后组合符 | TooManyScalarsInCell | 同操作基字符要求已写入库合同；stock 生成带基字符的格内容。本轮无对应普通输出断连；不同于已修复的 U+0605 |
| R03 未支持的 C0/C1/DEL | 如 `01`、UTF-8 U+0080、`7f` | UnsupportedControl | stock 消费或替换；恶意/其他服务端直接发送仍会拒绝，不取消校验 |
| R04 未支持的 ESC/CSI/profile | ESC D、ESC (0、CSI s/u、光标样式、部分 SGR/模式等；全部具体值在扫描集 | UnsupportedEscape / UnsupportedCsi | stock 归一化为可见状态或忽略；不能把直接输入拒绝都称为真实断连 |
| R05 非法/不完整输入 | FF、截断 UTF-8、ESC [、未结束 OSC/DCS | InvalidUtf8 / IncompleteSequence | 已有协议防线，本轮只做直接负例，不伪造 stock 发送该格式的证据 |

同一 OSC/ST 分号样本的直接错误可能先后被回调覆盖为 UnsupportedEscape，而 stock
规范化为 BEL 后是 UnsupportedOsc；案例文件保留两个层次的精确结果，不只按最终
错误枚举去重。去重依据是触发语义与责任分支，避免再次掩盖先后发生的拒绝。

库原有非忽略单测 124 项通过；另一个收集测试完成全部 277 个输入并输出结果。
25 个外部/stock 测试保持 ignored，本轮没有借机重跑正式网络/生命周期矩阵。
19 个独立 stock 正反例和九个官方客户端对照另有记录。

## 致命出口清单及覆盖边界

已检查 `SessionTask/SessionDriver::run`、错误转换和各层 `?` 传播路径。
完整的枚举名、源文件、行号及每个 variant 见
[fatal-exits.json](../../tools/diagnostics/mosh-disconnect/fatal-exits.json)。
其中 DriverError 有 17 个顶层 variant，TerminalError 有 14 个；这是一份静态出口
清单，不伪称逐条分支覆盖率。每项动态证据来自上面的案例或原有单测。

| 出口 | 具体触发/边界 | 本轮结论 |
|---|---|---|
| Protocol / 终端 | 14 类包括 difference/operation 上限、非法 protobuf/操作、UTF-8、不完整序列、字符/控制/ESC/CSI/OSC 拒绝、scalar/字节上限；echo ACK 倒退也拒绝 | 正常输出误拒绝与限制已分成 C01–C07；其他保存为原有防线，直接/单测证据不冒充 stock 断连 |
| Protocol / 鉴权后协议 | 分片结构/冲突、zlib 格式或尾随数据、protobuf/版本、无效 ACK/状态迁移/throwaway、无效同步计划 | 静态列全，原有库单测通过；不是将未鉴权网络垃圾当作会话错误 |
| ResourceLimit | 压缩 1 MiB、解压/差分/绘制 2 MiB、分片/未完成消息、累积待 ACK 输入操作 4096 等 | 保留限制；4096 是未确认操作累计上限，断网大量输入可能触发，非屏幕字符 case。本轮未制造真实大流量/内存耗尽 |
| Io | UDP 创建失败、不可恢复收发错误、部分 datagram 发送 | 原有注入单测通过；已连接时 NetworkDown/Unreachable、HostUnreachable、AddrNotAvailable、PermissionDenied 延后重试，其余仍可能终止 |
| ConnectionTimeout | 15 秒内未取得首个完整已鉴权状态 | 建连阶段；已有 Active 会话普通静默不会因该计时器断开 |
| InvalidTerminalSize | 0、超过 500 列或 200 行等非法尺寸 | 初始/协议状态边界；公共 resize 入参先拒绝，不能都算运行时断连 |
| StateExhausted | 包序号、片编号、输入/状态编号、generation、计时值溢出/部分时间不变量 | 原有单测与静态边界；没有声称真实运行穷尽 64 位序号 |
| InternalState | 缺失客户端 checkpoint 或终端引用状态 | 内部不变量错误；录制按引用状态重放无缺失，不通过跳过引用伪造后续状态 |
| 正常 SessionExit | LocalClosed、RemoteClosed、Cancelled、OwnerDropped | 明确关闭、远端关闭、取消、持有者/输出消费者丢弃；不是协议解析缺陷 |
| 连接前拒绝 | Bootstrap 七类错误，公共命令 Closed/InputTooLarge/InvalidTerminalSize | 清单包含，但不得混称远端输出导致断连 |

反例也核对：错误来源、错方向、鉴权失败、重复/过旧包等在 driver 收包入口被丢弃；
输出队列背压、预测过期、短暂不可达本身不是 fatal。资源和计时的常量完整来源为
锁定版本 `src/limits.rs`，清单不授权去掉这些保护。

## 上游源码交叉检查

- [stock 1.4.0 terminaldisplay.cc](https://github.com/mobile-shell/mosh/blob/mosh-1.4.0/src/terminal/terminaldisplay.cc)
  明确输出标题、OSC 52、反色、鼠标模式和光标/擦除/滚动等差分。
- [stock 1.4.0 terminalframebuffer.cc](https://github.com/mobile-shell/mosh/blob/mosh-1.4.0/src/terminal/terminalframebuffer.cc)
  的 Renditions::sgr 保留并发出 blink/invisible，解释 C02 为什么并非任意非法 CSI。
- 固定 Rust 版本 `src/vt100/perform.rs` 的 OSC 分支只接受两段标题；
  `src/vt100/screen.rs` 的 sgr/decset/decrst 缺少上述属性/模式；
  `src/terminal/state.rs` 将未处理回调设为 fatal。
- 该库 `docs/compatibility.md`、`docs/limits.md`、`docs/provenance.md` 已声明同操作
  组合字符、资源边界和鼠标策略。因此 C04–C07 必须和 C01–C03 分开决策。

## 证据、清理与交付

本地忽略目录：`build/verification/mosh-batch-20260925/`。保留三组原始录制及 SHA-256
manifest、全量重放日志、277 项 CSV、19 项原版 stock 结果、九项官方对照，以及
`scan-summary.json`。可交接的公开 pack 只含合成字节，不含现场终端记录或凭据。

录制脚本首次把完成标记的长度写错，收集断言失败；未丢弃录制或重新撞通过。
离线按状态图重建后，在原始记录的 45–47 帧确认完整标记，修正证据判据。合成批次
中的 RIS 和 132 列模式会擦除前置 case 标签，相关帧保留按顺序关联的边界；最终
独立正反例负责证明真实失败，不能只靠诊断续跑的画面。

全部本轮服务端/客户端进程已清理，原四条用户服务端保留。本轮零设备操作、零模型
调用，未增加产品容错路径。升级草稿继续不合入，首 Tab 诊断和发布仍暂停。

此结论覆盖固定版本、当前 stock-server/profile、完整保留的原始样本和所列有限输入，
不是对任意 Unicode/locale/服务端、全部字节组合、OS 杀进程或内存耗尽的穷尽证明。
Mosh 同步屏幕差分，48 帧不是原文件每个字节/每个瞬间的画面；时序变化可能生成
其他差分。因此本轮用序列化源码审计和系统化案例补足单次录制，仍保留这个边界。
后续一次修复后应跑整份去重 pack 与选定 stock 正反例，再检查原始命令和独立后续
输入；不要重新回到“修一个、只验一个、再发现一个”的流程。

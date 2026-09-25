# Mosh U+FFFD 断连诊断与库修复交接

日期：2026-09-25。原始诊断针对 v0.1.1；维护者已在 v0.1.2 修复，LeanTTY 已接入并
通过当时的定向验证。随后维护者在同包再次断连，已确认另一个 U+0605 字符宽度问题，
**原二进制输出主诉仍未解决**。下面保留各轮原始事实，不能把单次通过扩展为整体修复。
本文件记录证据，不是第二份任务清单；后续状态归 `docs/next-work.md`。

## 结论与影响

`mosh-client-rs v0.1.1` 将合法 Unicode 替换字符 `U+FFFD`（`�`）误判为致命终端错误，
最终以 `SessionError::Protocol` 结束连接。无需大文件、非法协议包、HarmonyOS 或
LeanTTY 渲染器，仅正常远端输出一个 UTF-8 编码的 `�` 就可以触发。

原现场 `\cat /bin/ls` 输出二进制后退回 `ltty`，App 没有退出，远端 mosh-server
仍存活。二进制中的非法 UTF-8 被服务端转换为替换字符；最小对照证明客户端也拒绝
直接输出的合法替换字符。因此不能将它限定为“用户错误输出二进制”，普通日志或
文本里的 `�` 也受影响。当前是可靠性缺陷；本轮未做恶意服务端安全影响评估。

## 版本与复现

- LeanTTY 基线：`e9a4af667e319a0c73819144ae43dedf8600370a`。
- 库锁定：`mosh-client-rs v0.1.1`，提交
  `dfc188975ed0a8bd734bbf14bd6cfdeb3838e629`。
- 依赖：`vt100 0.16.2`、`vte 0.15.0`。
- 服务端与对照客户端：stock Mosh 1.4.0，WSL Ubuntu 26.04，UTF-8 locale。
- 隔离连接：IPv4 loopback，160 列 × 45 行；与实际 PC 网络、ClashBox、防火墙无关。
- 本机独立的 `mosh-client-rs` 工作区在只读检查时为
  `3d793aee1218a0f2b7896b3df01ad7b95501635f`，相同 `unhandled_char` 致命分支仍存在；
  未在该提交重跑测试，也未修改该项目。

在使用受影响库的 Mosh 连接内执行：

```sh
printf 'BEFORE-\357\277\275-AFTER\n'
```

这里三字节 `EF BF BD` 是合法 UTF-8 的 U+FFFD。预期显示 `BEFORE-�-AFTER` 并可继续
输入；实际客户端报告协议错误并断开。以下单个非法字节经 stock 服务端处理后也触发：

```sh
printf 'BEFORE-\377-AFTER\n'
```

## 对照证据

| 样本 / 层次 | 结果 |
| --- | --- |
| 真机 `\cat /bin/ls`，11,352,352 字节 | `connected=true,source=transport,stage=mosh_udp,nativeCode=protocol`，返回 ltty |
| 隔离库 + stock server，同一二进制 | `Terminal(UnsupportedCharacter)` → `Err(Protocol)` |
| 隔离库 + stock server，纯 ASCII | 正常输出，测试脚本结束后 `RemoteClosed` |
| 隔离库 + stock server，合法 U+FFFD | `Terminal(UnsupportedCharacter)` → `Err(Protocol)` |
| 隔离库 + stock server，单字节 FF | 服务端输出 U+FFFD，发生相同错误 |
| stock client + stock server，后两种最小样本 | 均显示替换字符及前后标记，脚本正常结束，退出码 0 |
| 纯终端状态单元复现，无网络 | UTF-8/序列校验通过，`apply_host_bytes` 返回 `UnsupportedCharacter` |

真机原始断连时间为设备时钟 18:37:49.166。进程仍为 PID 5484，独立诊断服务端仍存活。
验证使用隔离的依赖源码副本，仅增加错误枚举和测试码点输出，没有改错误处理行为。
只对受控测试输出记录码点；不得将这种输出日志用于真实用户会话。

## 准确错误链

1. `mosh-client-rs/src/terminal/state.rs:128` 的 `validate_host_bytes` 接受合法 UTF-8。
2. 同文件 `apply_host_bytes` 交给 `vt100::Parser` 构建远端终端状态。
3. `vt100 0.16.2/src/perform.rs:34` 的 `print` 对 U+FFFD（以及 C1 区间）调用
   `callbacks.unhandled_char`，不走普通 `screen.text`。
4. `mosh-client-rs/src/terminal/state.rs:235` 的 `TerminalCallbacks::unhandled_char`
   无条件记录 `TerminalError::UnsupportedCharacter`。
5. `apply_host_bytes` 返回该错误，`src/session/driver.rs:138` 将其归为
   `SessionError::Protocol`；LeanTTY `leantty_ssh/src/lib.rs` 如实传出 `protocol` 并关闭会话。

因此修复责任在库的终端字符处理路径与 `vt100` 回调语义的衔接处，不能通过修改
LeanTTY 显示层、SSH、网络重试或防火墙解决。C1 控制字符未在本轮验证，不将其混入
U+FFFD 修复范围。

## 给库维护者的修复建议

目标是正确保留并显示合法 U+FFFD，同时保持光标宽度、屏幕状态、后续差分和重绘一致。
优先检查 `vt100` 可采用的修复或最小依赖补丁；若在库中处理，应先证明所用机制能把
该字符真正写入状态。**仅忽略 `unhandled_char` 错误不够**：当前 vt100 分支也没有
调用 `screen.text`，可能静默丢字符、导致光标和服务端状态不一致。

不应整体取消 UTF-8、终端序列、资源或协议校验，也不应把所有 `Protocol` 错误变为
继续运行。结构化错误细分可帮助以后排障，但不是根因修复的替代品；不要记录用户
终端内容或原始协议载荷。

建议以本轮最小样本验证：合法 U+FFFD 的字符和光标状态、正常 ASCII 对照、非法输入
经 stock server 的替换结果，以及后续输入/resize/重绘仍一致。之后回归原始二进制
样本；若暴露另一个明确错误，单独记录，不以一次修复声称支持所有随机二进制。
库发布修复版本后，再由 LeanTTY 更新锁定版本并做定向真机验证，无需为本轮诊断
重跑完整发布矩阵。

可将下面的最小单元测试放入库 `src/terminal/state.rs` 的测试模块：

```rust
#[test]
fn accepts_valid_replacement_character() {
    let bytes = "BEFORE-\u{fffd}-AFTER".as_bytes();
    assert!(validate_host_bytes(bytes).is_ok());
    let mut terminal = TerminalState::new(80, 24).unwrap();
    terminal.apply_host_bytes(bytes).unwrap();
    assert_eq!(terminal.screen().contents(), "BEFORE-\u{fffd}-AFTER");
}
```

本轮已实际运行等价测试：在 `apply_host_bytes` 处失败，尚无修复后通过结果。

## 另外两项与本机修复

- **滚动历史**：现有 Mosh 临时页面不保留额外 scrollback，符合 `docs/user-guide.md`
  的现行合同；[Mosh 官方 FAQ](https://mosh.org/#faq) 同样说明只同步可见屏幕，推荐远端
  tmux/screen。没有为此增加本地伪历史或修改产品范围。
- **上下键历史**：现场为 `No such widget 'history-substring-search-up'`。WSL `.zshrc`
  把上下键和 Ctrl-P/N 绑定到未注册插件 widget；现已仅将该五行块改为四个内置绑定：
  `up-line-or-history` / `down-line-or-history`，未改其他配置。备份保存在用户主目录
  `.zshrc.before-leantty-history-20260925T184149`。`zsh -n` 和新 shell 的绑定检查通过；
  真机新 Mosh 会话按上键成功调出历史命令，按下键回到空输入，未执行调出的命令。
  新 shell 自动生效；原有 shell 未强制重启，也未重新加载整份用户配置。

## 本地证据与清理

证据位于忽略目录，不提交用户屏幕或原始日志：

- `build/verification/mosh-three-issues-20260925/`：初始截图、真机二进制命令与断连日志。
- `build/verification/mosh-client-diagnosis-20260925/`：隔离源码、`minimize.py`、
  `stock_control.py`、`minimal-results.json`、`stock-client-results.json`、
  `unit-replacement.log` 和历史键真机截图。

临时 Mosh 服务端均已清理，仅保留原先两条用户会话；已返回原 Tab。
未修改产品、库项目或防火墙，未调用模型，未重跑正式矩阵，未发布版本。
首 Tab 的“终端暂时无法显示”诊断仍按维护者要求暂停，1.7 发布保持暂停。

## v0.1.2 接入验证

维护者发布并授权升级 `v0.1.2`，锁定提交
`177d2a11f8829df5582da4c1495ed9c9885461c3`。该版本将 vt100 0.16.2 作为私有模块，
让 U+FFFD 真正写入屏幕；原有 UTF-8、C1 和资源校验保持显式失败，DEL 也显式拒绝。
对照原 crate 源码，九个引入的 Rust 模块仅 `perform.rs` 不同，MIT LICENSE 完全一致。
LeanTTY 不增加补丁或适配分支，完整 MIT 声明纳入既有发布 notice 文件。

锁定版本的隔离 stock-server Unicode 测试通过，包含替换字符、服务端替换、常见
Unicode、后续输入、resize 和重绘。复用本诊断原始 `cat /bin/ls` 脚本也正常完成，
结果为 `RemoteClosed`（脚本结束），而非 `Protocol`。这些是库层证据，不替代真机。
LeanTTY Rust 原生边界 57 项单测、Clippy、生产 feature 隔离、2 项输入拒绝触发测试、
设备工具合同及 focused policy 通过。定向证据保存于
`build/verification/mosh-client-v012-20260925/`。

ARM64 debug 签名包构建、安装准入与维护者批准的安装通过。HAP SHA-256：
`10224ddfb882d92f339fa4234493dbd1c52868159719d486707f9eb3bd5c447e`。
物理 PC 上同一新 Mosh 会话的定向检查通过：

- 合法 `EF BF BD` 与非法 `FF` 经服务端转换后均显示 `�`，两个 AFTER 和完成标记可见。
- `/bin/cat /bin/ls` 原始样本输出结束，完成标记出现，仍在远端 shell；之后单独提交的
  `echo LTTY_FOLLOWUP_OK` 正常回显。脚本只在全部二进制输出后发送 RIS 恢复可读画面，
  此项证明样本不再断连，不声称任意二进制输出的显示保真或全面兼容。
- App PID 前后均为 `19877`；主动 `exit` 后返回 ltty，本轮服务端 PID `50867` 消失。
  另两条服务端进程保留，原中文拼音模式与终端焦点恢复。

首次连接输入因原中文输入法导致精确字节检查拒绝，未提交命令；取消组合输入并按
语义菜单切到英文后才建立本轮连接。该准备失败单独保留，不计为产品失败或通过。
现场截图、布局、进程日志与 `device-result.json` 均保留在上述忽略目录。本轮零模型，
没有重跑正式矩阵；首 Tab 暂停问题和 1.7 发布仍保持暂停。

## v0.1.2 再次断连：U+0605 宽度不一致

### 现场与结论修正

维护者报告 `/bin/cat /bin/ls` 正常、`\cat /bin/ls` 仍会退回 ltty。同一新包 PID 19877
在 21:13:18 记录 `Mosh failure ... stage=mosh_udp,nativeCode=protocol`，不是旧包或 App
进程退出。WSL 的 `cat` 别名为 `bat --paging=never`；没有 cat shell function，PATH
解析为 `/usr/bin/cat`，与 `/bin/cat` 都指向 `/usr/lib/cargo/bin/coreutils/cat`，版本均为
uutils coreutils 0.8.0。`/bin/ls` 解引用后为 11,352,352 字节，SHA-256 为
`48893b0fb21436b54619db80486e83ef39dfccaf1aefe83dfa00c02d6146e8c0`。
[zsh 的引用规则](https://zsh.sourceforge.io/Doc/Release/Shell-Grammar.html#Aliasing)
允许以反斜杠避免别名展开；这里没有证据表明两种写法运行不同 cat。

隔离 v0.1.2 副本只增加错误分类输出，不改变处理逻辑或库项目。在现场 147×43 网格、
stock mosh-server 1.4.0 下进行以下有界对照：

| 受控环境与输出 | 结果 |
|---|---|
| sh 中 `/bin/cat /bin/ls`，结束后停留 3 秒 | 本次成功 |
| 交互 zsh 中 `/bin/cat /bin/ls`，结束后停留 | 失败，`Terminal(TooManyScalarsInCell)` |
| 交互 zsh 中 `\cat /bin/ls`，结束后停留 | 先失败；加诊断后另一次成功 |
| 交互 zsh 中 `\cat /bin/ls`，随后立即 RIS 清屏 | 本次成功 |

这些结果证明两种 cat 写法都能失败，也说明大样本有状态/时序敏感性；不能把维护者
观察到的差异简单归因于别名，亦不能证明反斜杠本身是触发条件。Mosh 传递屏幕差分，
立即清屏、初始画面及更新分批都会改变客户端接收的状态。上一轮脚本确实执行了真实
二进制输出，但随后立即 RIS；其通过只适用于当时这一链，不能排除中间状态处理缺陷。

### 固定最小复现与错误边界

无需二进制文件或 cat，在 Mosh 会话中执行以下命令即可触发已证实的新问题：

```sh
printf '\330\205-AFTER\n'
```

`D8 85` 是合法 UTF-8 字符 U+0605。隔离版本记录：

```text
DIAGNOSTIC_SCALAR leading-zero-width U+0605
DIAGNOSTIC_DRIVER_ERROR: Terminal(TooManyScalarsInCell)
DIAGNOSTIC_SESSION_RESULT: Ok(Ok(Err(Protocol)))
```

并未达到 8 个 scalar 上限。锁定版本 `src/terminal/state.rs` 的 `ScalarBudget::print`
调用 `UnicodeWidthChar::width()` 得到 0；此前 scalars 为 0，即直接返回
`TooManyScalarsInCell`。该状态只按本段字节计数，控制/定位序列也会重置它。
本机 C.UTF-8 下 libc `wcwidth(U+0605)` 实测为 1；
[stock Mosh 1.4.0 的字符处理](https://github.com/mobile-shell/mosh/blob/mosh-1.4.0/src/terminal/terminal.cc#L62)
使用 libc `wcwidth`。这是服务端与客户端宽度判定不一致及客户端准入误判。

最小样本的 stock-server 对照结果：

- 行首 U+0605：Rust 客户端 Protocol；stock Mosh 客户端正常显示该字符和 AFTER，正常结束。
- `BEFORE-` 后的 U+0605：本次不报错，但不能据此声称光标/屏幕宽度一致。
- `A` 加 U+0301 组合重音、`BEFORE-` 加 U+FFFD：正常完成，后者证明旧修复仍有效。

物理 PC 上在同一个已安装 HAP 新建临时 Tab，连接 WSL 后只运行行首 U+0605 样本。
21:22:37 立即退回 ltty，日志为 `mosh_udp / protocol`，PID 19877 不变。该物理失败与
库层最小复现相互印证；历史那次大样本日志只有 Protocol，不能回填成已捕获其私有子类。
没有重新安装、修改用户配置或执行完整矩阵。临时 Tab 已删除、原第二 Tab 恢复；
自建服务端 PID 52865 已清理，原四个进程保留，英文输入法前后未切换。

### 库修复交接与验收修正

修复责任仍在 `mosh-client-rs` 的终端状态语义，不应修改 cat 别名、SSH、防火墙，
也不应在 LeanTTY 吞掉 Protocol 或自动重连。此轮只诊断，不改库或产品。

库维护者需统一字符准入、vt100 状态存储及服务端宽度语义，至少覆盖 U+0605 的行首、
普通字符后、光标定位后、分段差分、后续输入及 resize/repaint。仅删除报错不够：
当前“前面加 ASCII 即不报错”仍可能把本应占一列的字符追加到前一格，造成屏幕漂移。
保留真实资源上限，并将“孤立零宽/宽度不一致”与“超过容量”区分；不要整体取消校验。
具体采用何种宽度策略需在库中结合 stock Mosh 行为决定，本交接不授权额外兼容层。

后续验收以固定最小样本、正确字符/光标状态、单独提交的后续输入为首要判据；大样本
只是补充。二进制输出后的清屏必须在确认会话和错误边界之后单独提交，不再拼进同一
脚本当作通过判据。原失败和成功都保留，不能反复重跑直到出现一次成功。

本轮证据：`build/verification/mosh-v012-reopened-20260925/`，含原始现场、四样本对照、
错误分支分类、固定字符对照、stock 客户端结果、真机前后截图/日志及清理布局。

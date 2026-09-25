# Mosh U+FFFD 断连诊断与库修复交接

日期：2026-09-25。状态：根因已定位，库修复交由维护者后续处理；**未修复、未升级依赖**。
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

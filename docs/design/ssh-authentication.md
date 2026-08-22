# SSH keyboard-interactive 与多方法认证技术方案

> 状态：Verified；`v1.1.1` 已通过 GitHub、AppGallery 发布
>
> 目标 milestone：1.1.0
>
> 更新日期：2026-08-05
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 完成记录：实现与验证已闭合；后续变更须重新进入 [`next-work.md`](../next-work.md)

> 命令面治理：[`command-system.md`](command-system.md)

## 用户问题与目标

LeanTTY 1.0 支持直接密码、未加密私钥和加密私钥，但当前认证路径不能正确表达标准
SSH `keyboard-interactive`、authentication banner、一个请求中的多个提示、多轮回答，
以及服务器要求多个认证方法时的部分成功。这会让 PAM、密码加动态验证码、私钥加
动态验证码和私钥加密码等常见标准 SSH 环境无法可靠进入。

本方案目标是让认证由服务器协议能力和当前 Session 的凭据共同驱动，在同一终端路径
中安全完成标准 SSH 认证，不增加“启用 MFA”、厂商选择或验证码类型等产品概念。

## 范围

- 保持直接密码、未加密/加密 ed25519 与 RSA 私钥路径。
- 支持 RFC 4256 `keyboard-interactive` 的 `name`、`instructions`、零个或多个 prompt、
  每个 prompt 的 `echo` 标志以及连续多轮请求。
- 单独处理 RFC 4252 authentication banner；它是只读提示，不是回答轮次。
- 根据 `remaining_methods` 和 `partial_success` 继续服务器允许的下一因素。
- 统一处理取消、超时、断线、Pane 关闭、重连 generation 变化和并行 Session。
- 对不支持的方法、回答拒绝、协议异常和密码修改请求给出不同且可恢复的错误。

## 非目标

- 不集成厂商 MFA SDK，不生成、保存或同步 OTP 种子。
- 不根据 `OTP:`、`Verification code:` 等提示文案猜测认证类型。
- 不承诺未实际验证的堡垒机、Duo、JumpServer 或其他厂商兼容性。
- 不支持 RFC 4252 密码修改请求；收到时明确报告当前版本不支持。
- 不让认证回答进入命令历史、Preferences、持久资产、日志、遥测或 PTY 字节流。
- 不建立 ArkTS 与 Rust 两套并行认证状态机。

## 已知现状与证据边界

Rust Session 现已成为认证协商的唯一状态机；N-API/ArkTS 使用结构化事件传递 banner、
challenge 和 `sessionId + generation + roundId`，UI 不再根据私钥失败或服务器提示文字
决定下一方法。网络认证交换使用 30 秒超时，等待用户回答使用 300 秒超时，断开与取消
都会终止当前等待。

`russh 0.62.5` 提供相关客户端 API 是实现候选事实，不等于 LeanTTY 已经在 ARM64 HAP
和物理 HarmonyOS PC 上完成互操作。仓库现已提供独立的受控 russh 服务端和 OpenSSH
端到端协议基线；这证明测试场景可重现，不证明 LeanTTY 客户端已经实现或通过互操作。

受控服务端位于 `leantty_ssh/ssh-auth-fixture`，不属于默认构建成员，不进入 native 库
或 HAP。运行 `tools/start-ssh-auth-fixture.ps1` 时才会在系统临时目录生成随机凭据，
进程结束即删除。服务端按测试用户名提供直接密码、直接公钥、密码后 interactive、
公钥后密码、公钥后 interactive、多轮 interactive、零 prompt 与不支持方法；
`test-e2e.sh` 使用 OpenSSH 逐项验证未加密/加密私钥、partial success、多提示混合
echo、多轮和零 prompt 协议行为。物理 ARM64
HarmonyOS PC 已使用同一夹具验证直接密码、未加密/加密私钥、密码后 interactive、
公钥后密码、公钥后 interactive、多轮 interactive、零 prompt 自动提交、不支持方法
失败后恢复、混合 echo、banner、取消、两个 Pane 并行认证和同一进程最小化/恢复期间
隐藏回答连续性。2026-08-05 的诊断矩阵进一步覆盖错误回答恢复、加密私钥口令、隐藏
输入期间 `Ctrl+C`、认证中关闭 Pane、进程停止清理和一次性密钥删除，共 18 个阶段全部
通过；证据位于 `build/verification/device-ssh-auth-20260804T195329418Z/`。该次运行使用
显式未保留的诊断 HAP，不提升或替代正式候选。

2026-08-05 的针对性诊断进一步在密码后 mixed-echo interactive、隐藏输入取消、加密
私钥口令和隐藏输入期间进程停止路径前后计算应用沙箱 Preferences 的 SHA-256。前后摘要
一致；文件内容未读取或导出，摘要值仅在脚本内存中比较且未写入证据。证据位于
`build/verification/device-ssh-auth-20260805T002009859Z/`，其中明确记录
`contentReadOrExported=false`、`digestPersisted=false`、`unchanged=true` 与完整清理结果。

`tools/verify-ssh-auth-pc.ps1` 将这些主路径固化为保留候选验收：脚本
只在系统临时目录生成凭据，通过可清理的 HDC reverse 映射让设备标准 `ssh` 命令连接
仓库夹具，并使用原始按键、结构化非秘密日志与 accessibility layout 覆盖直接密码、
密码后 mixed-echo interactive、多轮错误恢复、未加密/加密公钥、公钥后密码、公钥后
interactive、零 prompt 自动提交、不支持方法的明确失败与恢复，以及隐藏回答期间进程
停止后的清理。一次性密钥由应用标准 `ssh-keygen`
路径创建、加密并删除；两个 Pane 通过现有分屏、焦点和独立 Session 路径并行完成不同
认证链；最小化/恢复通过 HarmonyOS 系统窗口按钮、可见性事件和同一进程 ID 验证隐藏
回答连续性、隐藏输入期间 `Ctrl+C` 取消后的新连接恢复，以及认证中关闭 Pane 后剩余
Pane 的新连接恢复。脚本独立检查沙箱文件已清理。debug/test 编译通过
`acceptance-source.ps1` 临时注入 `ACCEPTANCE_INPUT_SUBMIT` 非秘密提交序号/类型标记，
用于确认 Enter 已进入真实输入状态机；注入文件在 `finally` 中逐字节恢复。它不记录内容
或长度，也不作为认证成功判据。release 编译不注入该源码，HAP 包扫描还必须证明标记、
字段和 helper 符号均不存在。真实服务名称只在对应互操作完成后用于兼容性声明；断网、
超时与完整组合矩阵保留在正式候选门禁。

脚本无 `-Only` 时运行完整 acceptance 矩阵并可提升候选；`-Only <stage>` 只运行目标
场景及必要的密钥创建/产品删除依赖，证据标为 diagnostic，绝不提升候选。每个阶段声明独立
保守预算，fixture 生命周期按所选阶段预算之和再加设置/清理余量计算；fixture 提前退出归为
infrastructure，不再手工维护固定总超时或用统一平均值。候选 commit/tree/HAP SHA-256 与 harness
commit/tree 分别记录；只有二者间差异全部属于明确 allowlist 的测试脚本、测试回归或本文档
时才可复用 HAP，任何产品输入变化都必须重新执行候选构建。

每次运行写入实时阶段状态、attempt lineage、失败域、所选场景、阶段耗时和资源清单。
每条命令与隐藏回答提交前都重新激活 LeanTTY 并确认当前终端输入焦点；系统通知、弹窗或
前台切换使本次输入无效，不能依赖前一次点击仍然生效。
关闭 Pane 与删除密钥按“触发动作 → 预期确认框 → 确认 → 可观察后置条件”执行；一次性
密钥必须先通过产品 `key rm` 删除，再由沙箱只读检查确认缺失。hilog 重复行数量不是可靠
按键 ACK，不得用于字符完整性结论。

## 用户交互

认证方法不增加设置。用户继续运行 `ssh user@host` 或使用 Host/Identity 配置：

1. TCP、密钥交换和主机校验完成后进入 `AUTHENTICATING`。
2. 有可用私钥时先尝试私钥；没有私钥时优先尝试 `keyboard-interactive`，仅当服务器
   不允许它而允许 `password` 时进入直接密码输入，避免 PAM-only 服务器重复问密码。
3. 部分成功只表示一个因素完成，所有因素完成前不创建 PTY、不进入 `CONNECTED`。
4. 一次 challenge 的 prompts 按服务器顺序逐项收集，收齐后一次提交同样数量回答。
5. `echo=false` 使用掩码输入；`echo=true` 显示实际输入，并可能只留在当前 xterm 内存
   scrollback，不能宣称其完全不出现在终端内容中。
6. `Ctrl+C` 在任何认证输入阶段取消整个连接，不提交半成品回答。

Banner 和服务器提示视为不可信文本：保留正常 Unicode 与必要换行，过滤 C0/C1、ESC
和终端控制序列，不能借提示改变标题、剪贴板、模式或其他 Session。

## 所有权与事件链

```text
SessionViewModel (当前 Pane 的输入交互)
  ↕ structured N-API events/commands
Rust Session (唯一认证状态机与 russh Handle)
  ↕
russh server negotiation
```

- Rust Session 独占方法协商、已完成因素、已尝试方法和唯一待处理 challenge。
- `SshClient` 只转换结构化事件与回答，不决定下一认证方法。
- `SessionViewModel` 只拥有当前 challenge 的展示、当前输入索引和尚未提交回答。
- 认证信息不借用 WebView H2 Bridge，不混入远端 PTY 字节流。

## Rust 认证状态机

状态机输入包括当前凭据、`auth_banner`、`AuthResult`、
`KeyboardInteractiveAuthResponse`、用户命令、取消、断开和超时。约束如下：

1. `AuthResult::Success` 立即结束认证；`Failure` 必须读取
   `remaining_methods + partial_success`。
2. 私钥、直接密码和 `keyboard-interactive` 是协议方法，不由 UI 文案推断。
3. 只选择服务器仍允许且当前阶段尚未失败的方法；一个阶段内不无界重试，新的部分
   成功阶段可以按服务器要求继续合法方法。
4. `InfoRequest` 的 `name`、`instructions`、`prompts` 与每个 `Prompt.echo` 全部保留；
   回答数量必须精确相等。
5. 对认证阶段、交互轮数、单轮提示数、字段长度和回答总长度设置明确上限；越界时
   失败关闭，不截断后继续提交。
6. 没有受支持的剩余方法时，返回安全的方法分类和可理解错误，不记录凭据或完整提示。

用户发给 Rust 的命令应表达“本次输入”，而不是暗示一次调用完成整个认证：

```text
AuthCommand
  DirectPassword(secret)
  PrivateKey(path, passphrase)
  KeyboardInteractiveResponses(roundId, responses[])
```

纯策略位于 `leantty-ssh-core::authentication`：方法选择固定为“可用的配置私钥 →
keyboard-interactive → 直接密码”，同一阶段不重复已失败的方法，`partial_success` 后进入
新的有界阶段。当前上限为每次认证最多 8 个方法阶段、8 个 interactive 轮次、每轮最多
16 个 prompt、name、instructions
和单项 prompt/response 各 4096 bytes、单轮 prompt/response 各 16384 bytes；越界失败，
不截断后继续提交。

## 结构化边界

```text
AuthBanner
  text

AuthChallenge
  roundId
  name
  instructions
  prompts[]
    text
    echo
```

`roundId` 在一个 Session generation 内单调递增。回答 API 至少携带
`sessionId + generation + roundId + responses[]`；Native 必须拒绝不存在的 Session、
过期/重复/跨 Session 轮次、回答数量不匹配和 challenge 结束后的回答。

## 秘密边界

- 密码、私钥口令、OTP 和全部认证回答不得进入日志、错误快照、Preferences、命令
  历史、持久资产、遥测或跨重启恢复。
- Rust 的拥有型秘密在提交、失败、取消和超时后尽快 `zeroize`。
- ArkTS 不能承诺物理内存清零；提交或取消后立即清空数组与引用，避免复制、拼接和
  跨异步任务长期持有。
- `echo=false` 回答不得以明文进入终端内容；`echo=true` 只允许按服务器要求出现在
  当前终端输入与内存缓冲区，不进入其他存储。
- 日志只记录认证方法类别、阶段和安全错误码，不记录服务器提示正文或任何回答。

## 发布前证据边界

- 真实服务、断网、超时、输入法和外接键盘组合在正式候选全量门禁验证；未实际完成的
  厂商或服务不得写入兼容性声明。
- 协议上限、密码修改请求及未支持组合继续明确失败，不做提示文本猜测或厂商特例。

## 验证门禁

### 自动化

- Native 宿主测试通过仅在 `dev-dependencies` 启用的 `napi-ohos/dyn-symbols` 运行；统一
  回归同时检查 production `normal,build` 依赖树不含 `dyn-symbols` 或 `noop`，ARM64
  production native 仍按真实 N-API 链接。当前已执行认证交换成功/失败、交换超时、回答
  超时、取消、generation 拒绝和两条独立 Session 回答通道隔离测试。
- 现有密码、未加密/加密 ed25519 与 RSA 私钥及错误口令回归。
- banner 的 Unicode/换行保留与控制序列过滤；banner 不创建轮次。
- success、普通失败、部分成功及不同 `remaining_methods` 组合。
- 单 prompt、多 prompt、混合 echo、零 prompt、多轮、空回答和 Unicode。
- roundId 过期、重复、跨 Session、数量错误、长度/轮数上限和并行 Session。
- 用户拒绝、错误回答、取消、超时、断线、Pane 关闭与 generation 变化。
- 日志、错误快照、历史和 Preferences 不包含秘密。

受控服务端至少覆盖 `password`、`password,keyboard-interactive`、
`publickey,password`、`publickey,keyboard-interactive` 与多轮 interactive；测试凭据只
存在于临时目录。

### ARM64 构建

Rust core、N-API typing、ArkTS 集成和干净 ARM64 native/debug HAP 均须通过，且不得
引入未声明依赖或 x86_64 目标。

### 物理 HarmonyOS PC

- 直接密码、未加密/加密私钥回归。
- PAM password、密码加 TOTP、私钥加 TOTP、私钥加密码。
- banner、单轮/多轮、多提示、混合 echo、拒绝、不支持和取消。
- 两个 Pane 并行认证、最小化/恢复、断网、超时、关闭 Pane 和重连。
- 检查终端、历史、Preferences 与 hilog 的秘密边界。

厂商名称只有在对应真实服务完成成功、取消和失败恢复矩阵后才能出现在兼容性声明中。

## 裁剪与停止条件

SSH 标准认证补全是 1.1 发布核心，不能以退回字符串提示、重复尝试或厂商特例降低
正确性。若上游 API 缺口阻止可靠实现，应暂停 1.1 发布并收敛最小上游/本地修复，不能
让 UI 猜测协议状态或先宣传不完整的 MFA 支持。

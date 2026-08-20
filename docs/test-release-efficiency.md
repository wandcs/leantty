# LeanTTY 测试与发布效率改进

> 状态：当前工程流程的原因说明、决策记录与改进候选
>
> 更新日期：2026-08-20
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 测试权威：[`quality-strategy.md`](quality-strategy.md)
>
> 发布权威：[`release-process.md`](release-process.md)

本文解释 LeanTTY 的测试和发布为什么耗时、哪些证据不能省略，以及如何在不降低用户
信任和可靠性的前提下减少重复构建、重复验收和发布返工。本文只记录原因、边界、决策
和待评估方向，不维护操作手册或活动任务；需要开发的新工具只有进入
[`next-work.md`](next-work.md) 后才获得实施授权。

测试范围、候选复用和重跑规则只以 `quality-strategy.md` 为准；正式发布命令和顺序只以
`release-process.md` 为准；当前是否需要执行发布工作只以 `next-work.md` 为准。本文不
复制或修改这些权威流程。

## 1. 改进目标

效率改进不等于缩短每个等待时间，也不等于减少必要证据。目标是删除不能增加结论
可信度的重复工作：

1. 功能迭代只验证受影响事件链和一个快速主路径。
2. 正式发布只对一个冻结候选完成一次完整、可归因的验证。
3. 验收工具失败时只诊断失败边界，不从头重复无关矩阵。
4. 在版本号被 GitHub Release 消耗前完成所有低成本发布前置检查。
5. 产品候选、验收工具和发布材料分别记录身份，避免工具修复迫使产品重复构建。

优化后的结果仍必须回答三个问题：测试的是什么、发布的是什么、两者为什么是同一个
候选或可合法复用的证据。

## 2. 耗时的主要来源

### 2.1 真机事件链本身较长

焦点、物理键盘、剪贴板、窗口、持久化、终端交互和 SSH 生命周期只能在目标 ARM64
HarmonyOS PC 上得出行为结论。一次有效验收不仅包含点击或输入，还包含：

- 确认设备、应用和受控服务器处于可用状态；
- 等待当前终端输入控件可访问并重新证明焦点；
- 以物理按键事件输入命令或非回显响应；
- 从真实产品状态、服务器结果、布局或结构化日志判断结果；
- 覆盖适用的拒绝、取消、重试和恢复路径；
- 清理临时密钥、记录、进程和设备状态，并独立确认不存在残留。

固定缩短这些步骤会把环境抖动误判为产品通过或失败，因此不能作为主要优化方向。

### 2.2 验收工具不稳定会放大重跑成本

2026-08-05 的收敛过程连续修正了干净构建依赖恢复、非回显输入、OHPM lockfile、
物理按键节奏、终端焦点和输入就绪判断。多次失败属于验收工具、设备环境或基础设施
边界，不是 LeanTTY 产品错误。

如果每次工具调整都重新构建产品、安装候选并从完整矩阵第一阶段开始，就会把一个
局部问题放大为多轮发布级验收。测试工具必须先证明控制和观察通道，再创建产品状态。

### 2.3 正式发布包含多层独立证据

正式发布除功能验收外，还必须验证：

- 精确 commit、tree、版本来源和洁净状态；
- WSL Rust ARM64 编译、ArkTS/N-API 集成和目标 ABI；
- APP/HAP 生产签名、Profile、Bundle、应用标识和权限；
- native library、APP、HAP、Profile 和发布附件的 SHA-256；
- 许可证和第三方声明完整性；
- 不可变 GPG 标签、GitHub Release 状态和远程附件摘要。

这些层证明的结论不同，不能用 CI、安装启动或一张截图互相替代，但每层只需要对同一个
精确源码身份或权威流程明确映射的对应包执行一次。

### 2.4 发布前置条件过晚确认会造成整版返工

`v1.1.0` 发布后才确认 AppGallery 生产 Profile 需要增加 Downloads 目录授权。由于
GitHub Release 已经消耗版本号，不能移动标签或替换既有 Release，只能顺延到 `1.1.1`，
重新完成版本元数据、构建、签名、归档、标签、Release 和状态文档。

这是最应优先消除的浪费：Profile 内容可以在昂贵构建和版本发布之前验证。

### 2.5 Git 和 CI 是较小但可累积的等待

一个局部验收工具问题如果被拆成多个微小 PR，每个 PR 都会重复分支、推送、公共 CI、
合并和本地同步。公共 CI 必须保留，但同一失败域的相关工具修正可以先在一个短期分支上
收敛，再通过一个 PR 提交。

## 3. 必须保留与应当删除的工作

### 3.1 必须保留

- 受影响事件链的正向、失败、恢复、隐私和清理验证。
- 焦点、键盘、剪贴板、窗口、持久化和 SSH 生命周期的物理机证据。
- 正式发布候选的一次完整软件门禁、干净 ARM64 构建和适用真机矩阵。
- 生产 Profile、应用身份、权限、签名和包体哈希验证。
- 测试候选与发布候选的精确身份和连续性记录。
- 不可变标签、GitHub Release 和远程附件的独立复核。

### 3.2 应当删除或合并

- 普通功能迭代中的完整软件、构建和物理机矩阵。
- 只修改验收脚本后无条件重新构建未变化的产品候选。
- 同一失败边界尚未诊断时反复从完整矩阵第一阶段重跑。
- 在 `verify-pc.ps1` 已经内部执行 `test-regression.ps1` 的情况下，紧邻执行一轮完全
  相同、没有诊断目的的独立软件门禁。
- 发布脚本已经生成并验证 manifest、签名和哈希后，多次使用临时命令重复同一检查。
- 在最终生产 Profile 未通过与最终 release tree 绑定的预检前创建标签或发布 GitHub
  Release。
- AppGallery 没有要求且当前版本没有变化时重复制作截图、MP4 和提交备注。

删除重复不表示取消独立复核。每项关键身份应由生产步骤生成一次，再按现有发布权威完成
一次只读复核；统一审计 helper 在获得活动授权并实现前只是改进候选。

## 4. 已由权威文档采用的减重边界

以下内容只解释现有权威规则为什么能减少浪费，不重新定义命令或门禁：

- 日常迭代按 `quality-strategy.md` 的变更到证据矩阵，只验证受影响事件链和一个快速
  主路径；风险增加受影响链路的深度，不自动扩大到全部无关功能。
- 正式候选只在准备发布包时建立，并由同一个保留 HAP 承载全部适用物理机证据。
- 验收工具失败先按 `quality-strategy.md` 分类并切换到命名诊断阶段；诊断通过不能替代
  最终候选所需的一次完整适用矩阵。
- 发布身份、构建、签名、标签、GitHub Release 和 AppGallery 顺序只按
  `release-process.md` 执行，不在本文维护另一份步骤表。

这些规则已经覆盖日常范围选择、候选与工具双重身份、失败分类、重跑停止条件和正式
发布门禁。本文不再复制其详细清单，以免同一流程出现多个可漂移来源。

## 5. 候选与证据复用的安全边界

候选复用只允许 `quality-strategy.md` 已定义的场景：候选 commit 是干净验收工具 commit
的祖先，并且两者之间的每条变化路径都在该场景的显式 harness/document allowlist 中。
任何 ArkTS、Rust、资源、依赖、构建输入、版本元数据或其他产品树变化都会产生新 tree，
必须建立新的正式候选，不能用“用户行为没有变化”豁免精确源码门禁。

如果产品 commit/tree 完全不变，只替换仓库外的生产签名材料或 Profile，可以只复用未受
影响的行为层证据；新的 APP/HAP、签名、Profile、权限和哈希仍必须按
`quality-strategy.md` 与 `release-process.md` 取得对应层的新证据。已经发布 GitHub
Release 的版本仍不可修改；任何替代包都必须使用新的版本并重复权威流程要求的门禁。

## 6. Profile 预检的有效身份

Profile 类型、分发类型、Bundle、应用标识、ACL 和请求权限适合在昂贵构建前检查，但
结论只有在绑定以下输入时才有效：

- 已经合并版本元数据和 Changelog 的最终 release commit/tree；
- 该 tree 中的 Bundle、`requestPermissions`、权限理由和使用场景；
- 最终生产 P7B 的 SHA-256 和预期签名角色。

选择并提交版本元数据不会消耗版本；发布非草稿 GitHub Release 才是版本消耗边界。因此
应先冻结精确提交，再在构建、标签和 GitHub Release 之前执行低成本检查。最终包仍须由
`release-process.md` 规定的构建、签名和 manifest 证据复核，源码文本检查不能替代包内
结果。

当前仓库尚无独立解析原始 P7B 并比对 ACL 的只读 helper。它进入 `next-work.md` 并完成
验证前，只能作为待评估优化，不能成为当前发布流程中一个没有可执行命令的必经门禁。

## 7. 当前可执行入口

本文不提供逐步发布操作。需要执行时使用以下唯一入口：

| 目的 | 权威入口 |
| --- | --- |
| 日常变更的测试范围与停止条件 | `quality-strategy.md` → Routine feature or bug-fix iteration |
| 正式候选、重跑和证据复用 | `quality-strategy.md` → Formal release-package verification、Execution and rerun policy |
| 正式构建、签名、归档、标签和提交 | `release-process.md` |
| 当前是否有已授权发布工作 | `next-work.md` |

`release-process.md` 当前给出的 `git tag -s`、`prepare-appgallery-release.ps1` 和 GitHub
发布步骤仍是可执行权威。本文不引入未命名的本地辅助脚本，也不把尚未实现的审计工具
写成现行步骤。

## 8. 已采用与待评估的自动化方向

只有标明“已采用”的入口属于当前流程；其他方向用于以后评估，不自动建立活动开发任务。

### 8.1 设备控制通道预检

**已采用。** `tools/preflight-device.ps1` 在现有 HDC helper 上检查唯一 Ready 目标、受检命令
通道、串行 UiTest layout 和有效屏幕 bounds，并写入明确标记为不可验收的机器证据。它不安装、
启动、解锁或修复设备；应用 PID、终端焦点、日志和服务器状态继续由真正需要它们的命名场景
检查，避免为了通用预检增加高成本或易漂移的观察。

2026-08-19 的首次真机衔接发现，共享 layout helper 默认过滤 `com.leantty.app`，与预检不启动
应用的合同冲突；全局 UiTest 原始布局正常，排除了设备和 UiTest 通道故障。合同测试先稳定失败，
helper 增加保留原默认值的可选 bundle 范围后通过。干净工具提交上的最终预检用 6.269 秒取得
172 个全局 layout 节点，随后唯一的 `terminal-search/open-close-focus` 诊断场景用 19.133 秒
验证真实打开、关闭和焦点恢复，搜索状态、单 Tab/单 Pane 工作区和屏幕常亮策略均清理成功。
诊断 HAP 与预检结果都未提升为发布证据。

### 8.2 Profile 预检

提供一个只读 helper，输入 P7B 和预期 Bundle/ACL，输出机器可读结果。它不读取或输出
口令、私钥和 keystore 内容，并可在正式版本准备前独立运行。

### 8.3 发布归档审计

提供一个统一的只读审计 helper，检查 manifest、包内 module、ABI、Profile、签名、
许可证 ZIP、本地哈希、商店材料范围和 GitHub Release 远程摘要。生产脚本负责生成，
审计脚本负责独立复核，避免多组临时 PowerShell 命令重复同一结论。

### 8.4 阶段续跑和耗时记录

每个物理阶段记录开始时间、完成时间、重试次数、失败域和清理结果。先收集至少三个正式
候选的分布，再决定超时和优化目标，不凭单次感受设定固定时限。

除 8.1 已采用入口外，上述 helper 和阶段续跑候选都不是当前活动任务，也不能替代现有手工
或脚本门禁。只有 `next-work.md` 明确授权后才实施；当前工作继续使用第 7 节列出的权威入口。

## 9. 效果评估

流程是否变快以证据衡量，不预设任意百分比目标。每个正式候选记录：

- 完整软件门禁执行次数；
- 产品 clean build 次数；
- 完整物理矩阵次数和各阶段耗时；
- 诊断重跑次数及失败域；
- 候选复用或失效原因；
- Profile 预检是否在版本消耗前完成；
- 发布后是否发生可由前置检查避免的 PATCH 顺延。

理想状态不是所有计数都为一，而是每次额外执行都有清楚原因和新增证据。没有新增结论的
重复执行应被删除；能够防止错误包、错误权限、秘密泄露或行为回归的步骤必须保留。

## 10. 决策记录

### 2026-08-06 测试与发布效率收敛

- **动机：** 1.1 验收期间，真机输入工具收敛、正式发布固定成本和生产 Profile 晚确认
  叠加，使局部失败多次扩散为完整矩阵、构建和版本发布返工。
- **采用方向：** 日常变更只测受影响链路；工具失败使用命名诊断和受 allowlist 约束的
  候选复用；正式发布只验证一个精确源码候选；Profile 优化绑定最终 commit/tree；所有
  可执行步骤继续由质量与发布权威维护。
- **未采用方向：** 不取消真机行为证据，不用构建或启动代替交互，不因赶时间跳过签名、
  身份、许可证和哈希检查，也不移动已发布标签或替换 GitHub Release。
- **预期成本：** 需要维护候选与工具双重身份、可靠的失败分类；Profile 预检、统一归档
  审计和阶段续跑 helper 在获得活动授权前仍需使用现有权威流程，不提前依赖未实现能力。

### 2026-08-20 1.4 发布验证复盘与优化排序

- **现场基线：** 2026-08-19 的发布前验证约用时 4 小时 26 分。最终产品路径通过，但期间
  出现普通命令短写、空写、错误失败域、共享 harness 连续修复、长 SSH 场景局部失败后重跑、
  高频布局观察和 release/review 包差异过晚暴露。自动化短写不能直接证明真实物理键盘或
  SSH 字节链路存在产品丢失。
- **外部依据：** OpenHarmony 的官方
  [`UiTest` 输入示例](https://gitee.com/openharmony/applications_app_samples/blob/master/code/Project/Test/uitest/entry/src/ohosTest/ets/test/operationExampleTest/ui/InputEvent.test.ets)
  在 `inputText` 后重新获取控件并用 `getText()` 做精确断言，而不是把 Promise 完成当作文本
  已正确到达；HarmonyOS 官方
  [`UiTest` 示例说明](https://gitee.com/harmonyos_samples/ui-test/blob/master/README.md)
  也明确 Driver/Component 操作是异步接口，并提醒结果随实际设备而变化。它们支持“注入后
  读取和验证”的方向，但没有证明 LeanTTY 当前短写的具体根因。
- **失败域依据：** Google Testing Blog 的
  [flaky test 分类](https://testing.googleblog.com/2020/12/test-flakiness-one-of-main-challenges.html)
  将不稳定性分别归于测试、测试框架、被测系统及操作系统/硬件；Android Developers 的
  [CI 测试指南](https://developer.android.com/training/testing/continuous-integration/features)
  要求按失败层级选择重跑范围并持续记录 flaky 来源。该模式与本项目的候选、harness、环境、
  基础设施和未知结果分类一致。
- **采集依据：** Playwright 的
  [trace 指南](https://playwright.dev/docs/trace-viewer)
  推荐在失败/首次重试时保留高成本 trace，而不是每次成功运行都全量采集。这只授权我们测量
  “正常路径最小观察、失败时升级诊断”是否适合当前 UiTest，不授权直接照搬其实现。
- **采用顺序：** 先定位文字在哪个组件边界丢失，再统一安全提交合同和结果可观察性；只有
  结论可信后才拆分长场景、减少观察、建立发布前 harness 资格化，最后处理独立小故障并用
  分布复测收益。活动 checkbox 和逐项完成条件只在 `next-work.md` 维护。
- **研究约束：** 上述资料只支持当前排序，不视为后续任务的预研究完成。每个任务实际开始时
  仍须按 `quality-strategy.md` 重新查询当前 SDK、上游问题和社区案例，并记录当时适用版本、
  冲突与未知内容。

### 2026-08-20 普通文字注入边界诊断

- **研究问题：** 2026-08-19 验证中的空写和短写究竟发生在 HDC/UiTest、桌面焦点、
  LeanTTY 原生命令缓冲、ArkWeb/PTY 还是服务器之后；UiTest 命令返回是否足以证明文字已
  完整送达；设备上的 UiTest 版本是否存在已知输入限制。
- **官方与上游依据：** HarmonyOS 的
  [`UiTest` API 参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/js-apis-uitest-V13)
  将 Driver/Component 操作定义为异步接口并声明模块不支持并发调用。OpenHarmony
  [`arkxtest` 说明](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)
  同时提供坐标定向的 `uiInput inputText x y text` 和向当前焦点输入的 `uiInput text text`；
  其版本记录说明 5.0.1.2 起超过 200 字符改走剪贴板与 Ctrl+V，5.1.1.1 才加入无坐标
  `text` 命令，6.0.1.0 又为 API 增加追加/粘贴选项。官方
  [`InputEvent` 示例](https://gitee.com/openharmony/applications_app_samples/blob/master/code/Project/Test/uitest/entry/src/ohosTest/ets/test/operationExampleTest/ui/InputEvent.test.ets)
  在 `inputText` 完成后重新查找控件并以 `getText()` 精确断言结果，支持“完成返回不等于
  内容正确，提交前必须读回”的判断。
- **已知案例检索：** 检索了 `inputText` 丢字、末字符缺失、异步完成、ArkWeb/IME、daemon
  断连和焦点等组合；上游
  [`I8EWXH`](https://gitee.com/openharmony/testfwk_arkxtest/issues/I8EWXH) 是旧 4.1
  XTS `inputText` 阻塞，
  [`I57ZFF`](https://gitee.com/openharmony/testfwk_arkxtest/issues/I57ZFF) 是 UiTest daemon
  断连，均不匹配当前“命令成功但末字符偶发缺失”。华为开发者社区及可核验论坛中也没有
  找到相同症状和可直接采用的修复。资料共同支持定向输入、串行化和结果读回，但没有公开
  说明 `help` 参数冲突，也不能替代本项目真机复现。
- **受控环境：** 物理 HAD-W32，HarmonyOS `HAD-W24 6.1.0.135
  (SP11C00E100R13P3log)`、API 24、UiTest 6.0.2.3；使用 commit
  `5a6d3feed250f14292a949d2d10c953b9c103667` 对应的验收测试 HAP，SHA-256 为
  `327920650DAF8B92CDA200298CBEAA9E8356C236B17EE5034E0E53DC5D09ABE2`。诊断不按
  Enter：每次先走真实 Ctrl+C 清空路径，以单字符 `q` 建立并读回基线，再注入待测文字，
  从验收专用原生命令缓冲记录 expected/actual、首个差异位置、输入耗时、观察耗时和事件数。
- **主矩阵结果：** 10 轮短命令、32 个重复字符、标点、SSH 形状命令，以及 199/201
  字符边界共 144 次注入。坐标定向 `inputText` 为 48/48 完整；聚焦式 `text` 为 38/48，
  唯一稳定失败是文字恰好为 `help` 时 10/10 空写；原始键事件为 47/48，唯一失败发生在
  199 字符合成按键压测。普通长度的原始键事件 40/40 完整，后续 199 字符快速原始键对照
  又 6/6 完整。后者只能说明一次长合成事件波动未稳定复现，不能冒充真人物理键盘证据。
- **根因对照：** 在相同焦点和 `q` 基线下，`uitest uiInput text help` 退出码为 0，却输出
  `UiInput` 的完整 Usage，原生命令缓冲仍为空且没有输入事件；把 payload 仅改为 `test` 后
  返回 `No Error`，缓冲精确成为 `qtest` 并出现 4 个输入事件。因此发布验证中的两次
  `help` 空写已经确认是 UiTest CLI 将 payload 当作保留帮助参数的 harness 缺陷，不是
  LeanTTY、ArkWeb、PTY 或 SSH 丢字。
- **仍未知边界：** 2026-08-19 的定向 `inputText` 确实留下过一次 SSH 形状命令末字符没有
  进入原生命令缓冲的证据；当前 48/48 不能抹掉这个低频事实，也不足以进一步区分 HDC
  参数传输、UiTest 注入内部或系统输入服务。长原始键事件的 1 次波动同样没有稳定复现。
  两者都没有证明真人物理键盘、LeanTTY 已接收后的原生缓冲、ArkWeb/PTY 或服务器字节链
  存在产品丢失。
- **结论与取舍：** 本项按 harness 边界闭合，不修改 1.4 产品输入代码。普通文字不得使用
  聚焦式 `uiInput text`；下一项只收敛坐标定向 `inputText` 的安全提交合同：注入后先读取
  真实命令缓冲，逐字一致才按 Enter，Enter 前不一致只能从已知空状态有限重试，Enter 后
  仍以业务结果为 oracle 且禁止盲目重发。秘密输入继续保持非回显、不可读明文的独立合同。
  `tools/diagnose-text-input-pc.ps1` 保留为不提交命令、不可升级为发布验收的边界诊断工具。

### 2026-08-20 普通命令安全提交合同

- **研究问题与适用版本：** 在 UiTest 6.0.2.3 的 shell 接口不能直接调用 Component
  `getText()` 时，怎样保证普通本地命令在 Enter 前完整，并且不把短写重试扩张为重复执行；
  研究覆盖当前 HarmonyOS API 24、OpenHarmony arkXtest master、Android Espresso 与
  Playwright 当前官方文档。
- **HarmonyOS/OpenHarmony 结论：** HarmonyOS
  [`UiTest` 参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/js-apis-uitest-V13)
  和 arkXtest
  [`README`](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)
  都要求等待异步 Driver/Component 操作；shell 命令表同时把 `help` 列为 `uiInput` 子命令，
  并把坐标 `inputText` 与当前焦点 `text` 定义为两条不同路径。官方
  [`InputEvent` 测试](https://gitee.com/openharmony/applications_app_samples/blob/master/code/Project/Test/uitest/entry/src/ohosTest/ets/test/operationExampleTest/ui/InputEvent.test.ets)
  在输入后重新查找控件并精确比较值。shell 接口没有等价的安全 `getText` 命令，且 LeanTTY
  已证明 ArkWeb accessibility text 会漏数字，因此采用现有验收测试 HAP 的原生命令缓冲
  marker，而不新增产品 API 或把 layout 文本重新升级为 oracle。
- **相近体系参考：** Android Espresso 的
  [`ViewAction`/`ViewAssertion` 模式](https://developer.android.com/training/testing/espresso/basics)
  把输入动作和 `matches(withText(...))` 断言分开；Playwright 的
  [`toHaveValue`](https://playwright.dev/docs/api/class-locatorassertions#locator-assertions-to-have-value)
  会在超时内重试读取实际值。它们支持“动作完成后读取实际状态”的模式，但既不证明
  HarmonyOS 事件交付，也不授权在 Enter 后重试副作用。
- **唯一合同：** `tools/device-regression.ps1` 现在拥有普通本地命令的单一提交入口：先用真实
  Ctrl+C 取得已确认空状态，每次重新定位当前语义输入并只调用坐标定向 `inputText`，等待
  验收原生命令缓冲逐字相等；短写/空写只记录 expected/actual 长度、首个差异位置和尝试数，
  最多三次且每次重试前再次清空。只有精确相等才发送一次 Enter；随后缺少精确
  `ACCEPTANCE_INPUT_SUBMIT` 确认立即成为 unknown outcome，不发送第二次 Enter。帮助、SSH、
  ProxyJump、搜索、密钥口令、启动就绪/升级、PUT/GET 以及其 Tab/Unicode 命令准备路径均
  复用该入口；调用者仍必须用服务器、最终文件/状态或对应业务结果作最终 oracle。
- **独立边界：** 密码、口令、host-key 决策和 keyboard-interactive 回答仍是非回显秘密
  合同，不读取或记录明文缓冲；已连接远端终端的普通字节以受控服务器实际收到的字节为
  oracle，不错误套用只存在于本地命令模式的缓冲。`Invoke-LeanTTYDeviceText` 在调用者没有
  传节点时也只从当前 layout 解析唯一已聚焦节点后走定向 `inputText`，不再回退到聚焦式
  `uiInput text`。
- **红绿证据：** 新 helper 测试先因公共解析/提交函数不存在而失败；实现后用一次人为末字符
  缺失证明第一次不会按 Enter、清空后第二次精确才按一次 Enter，并证明提交确认缺失返回
  unknown、动态 Tab/Unicode 最终命令也经过同一合同。聚焦 `policy,tooling` 回归随后通过。
- **真机证据：** 使用与上一项相同 SHA-256 的显式 diagnostic HAP，最终执行真正包含两次
  字面量 `help` 的 terminal-search `pane-tab-ownership` 场景；两个命令都在一次定向输入后
  精确读回 4/4 字符、各发送一次 Enter 并取得提交确认，随后 Pane/Tab 所有权与清理通过。
  证据明确记录 `runMode=diagnostic`、`harness.gitDirty=true`，不提升为候选或发布验收。
- **维护取舍：** 公共层只拥有“已知空状态、准备输入、精确读回、一次 Enter、提交确认”；
  各场景通过两个小回调保留自己的 Pane 定位和 Tab/Unicode 准备，不把 SSH、传输或搜索业务
  规则塞入 helper。这样删除了多份漂移的循环，同时没有建立第二个设备驱动框架。

### 2026-08-20 成功结果可观察性

- **研究问题：** 一次通过、重试后通过、持续失败、超时/中断、环境/基础设施失败和副作用
  未确认，应怎样同时表达“最终 verdict”和“运行稳定性”；哪些重试信息必须保留在机器结果中。
- **官方模式：** Playwright 的
  [`Retries`](https://playwright.dev/docs/test-retries) 明确把首次通过称为 `passed`、首次失败后
  重试通过称为 `flaky`、所有重试均失败称为 `failed`，并公开零起点 `testInfo.retry`；其
  [`TestInfo`](https://playwright.dev/docs/api/class-testinfo) 另将单次执行状态区分为 passed、
  failed、timedOut、skipped、interrupted。Playwright 还允许 `--fail-on-flaky-tests`，说明
  flaky 不能被最终绿色结果吞掉。
- **失败域模式：** Google Testing Blog 的
  [flakiness 分类](https://testing.googleblog.com/2020/12/test-flakiness-one-of-main-challenges.html)
  将来源分成测试本身、测试运行框架、被测系统及其依赖、OS/硬件，支持 LeanTTY 保留
  product、harness、environment、infrastructure 四个失败域，而不是用一次重试后成功把
  来源改写为 product pass。
- **采用结论：** LeanTTY 机器结果使用两个正交维度：业务 verdict 与 harness stability。
  `passed + inputAttempts=1` 才是稳定一次通过；业务通过但 `inputAttempts>1` 必须标为
  `flaky-harness`；Enter 后确认缺失保持 `unknown`，不能进入 retry 统计后自动重发。公共命令
  helper 现在记录 stage、expected/actual 长度、每次不匹配的首差异位置、输入/Enter 次数、
  耗时、失败域和最后已证明边界；汇总同时记录业务 postcondition，且不保存命令正文或秘密。
- **接入边界：** 密钥口令、SSH 认证、终端搜索、ProxyJump、启动就绪和升级验证将汇总嵌入
  各自最终 JSON。PUT/GET 存在多组互斥的提前返回场景，因此在相同证据目录统一写入
  `device-command-automation.json`，避免复制十余个结果构造器。没有使用普通命令的场景明确为
  `not-exercised`，不能伪装成已验证稳定。
- **红绿证据：** helper 回归人为制造第一次末字符缺失、第二次精确，最终只按一次 Enter；
  机器结果为 `businessVerdict=passed`、`harnessStability=flaky-harness`、2 次尝试、1 次不匹配。
  另一个用例在 Enter 后缺少确认，结果保持 `unknown`、最后边界为 `enter-dispatched`；序列化
  JSON 不含测试命令正文。所有普通命令所有者都由静态回归要求提供 observation sink 和汇总。
- **真机校正过程：** 首次误选只开关搜索的 `open-close-focus`，52.245 秒通过但正确报告
  `not-exercised`，因此不冒充命令证据。改跑 `pane-tab-ownership` 后先发现提交确认正则错误地
  要求 marker 位于整段日志末尾；原始失败日志实际已包含 marker，现改为行尾或日志尾。随后
  又发现定向输入的无节点 fallback 只识别终端输入，导致已聚焦搜索框被误报为环境失败；现从
  当前 layout 选择唯一已聚焦 `textField`，仍走坐标定向 `inputText`，没有恢复不安全的聚焦
  CLI `text` 命令。
- **最终真机证据：** `pane-tab-ownership` 用时 285.141 秒并通过；最终 JSON 为业务 `passed`、
  harness `stable`、2 条命令/2 次输入/0 次不匹配/2 次 Enter，每条最后边界均为
  `submission-acknowledged`，且不含 `help` 正文。该时长同时保留为后续拆分长场景与降低观察
  成本的输入，不在本项用减少断言掩盖。

### 2026-08-20 SSH 长场景分组与安全续跑边界

- **研究问题与适用范围：** 如何把约一小时的 SSH 物理验收按真实失败域拆开，同时保证每组
  独立建立/清理 fixture、设备和产品状态；局部失败后哪些证据可复用；研究面向当前物理
  ARM64 HarmonyOS PC、API 24、UiTest 6.0.2.3 以及现有仓库内 russh fixture。
- **HarmonyOS/OpenHarmony 官方依据：** HarmonyOS
  [`Test Kit` 概览](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/test-kit-overview-V14)
  将测试准备和清理放在 suite/case 生命周期；OpenHarmony
  [`arkxtest` 指南](https://gitee.com/openharmony/docs/blob/ca4467409329c262b239693b7ba5e96185122ff6/en/application-dev/application-test/arkxtest-guidelines.md)
  提供 suite/case 过滤、超时和 `breakOnError`，支持有边界的选择与失败停止。它们没有定义
  LeanTTY 的 SSH fixture、候选身份或跨进程续跑格式，因此只能支持生命周期/选择原则，不能
  直接证明当前脚本可以安全分组。
- **相近体系官方依据：** AndroidJUnitRunner 的
  [sharding 与 Test Orchestrator](https://developer.android.com/training/testing/instrumented-tests/androidx-test-libraries/runner)
  通过分片和逐测试独立 Instrumentation 减少共享状态及崩溃扩散，但同时增加启动成本；
  Android 的
  [CI 测试能力](https://developer.android.com/training/testing/continuous-integration/features)
  要求按失败层级决定只重跑测试、任务还是 workflow。Playwright 的
  [fixture](https://playwright.dev/docs/test-fixtures)、
  [retry](https://playwright.dev/docs/test-retries) 和
  [parallelism](https://playwright.dev/docs/test-parallel) 文档强调按需 setup/teardown、不要依赖
  其他测试副作用，并说明串行依赖组失败时整组重跑。这些模式共同支持“最小独立组，而非每个
  阶段启动一次进程”，但不是 HarmonyOS 行为证据。
- **上游与社区检索：** 检索了 OpenHarmony arkXtest issue、华为开发者社区及可核验论坛中
  关于长 UiTest、`afterEach`/清理、case 过滤、失败续跑和 SSH fixture 的讨论；没有找到与
  LeanTTY 当前“同一应用内多种 SSH 认证 + Pane/窗口生命周期 + 性能矩阵”相同且可直接采用的
  案例。公开资料也没有证明 HDC reverse、known_hosts 或应用 Preferences 会被框架自动隔离。
- **共同结论、冲突与未知：** 官方资料一致要求清晰的选择边界和生命周期清理；Android 的
  “每测试重启”隔离最强，却与当前每次部署、SSH 环境准备和窗口恢复成本冲突，因此没有照搬。
  尚未知各组在优化观察成本后的稳定时长分布，以及不同系统更新后 UiTest/窗口状态是否仍满足
  当前清理条件；这些必须由后续真机分布复测回答。

现有脚本的资源/依赖图如下；箭头表示同一组内必须保持的先后关系，不表示跨组共享状态：

| 失败域 | 阶段与依赖 | 独占/可变资源 | 清理与可复用条件 |
| --- | --- | --- | --- |
| 传输/性能 | terminal key → transport reconnect → five-mode performance | fixture、reverse port、known-host、透明度偏好 | 关闭 session，删除 known-host，恢复原透明度，移除 mapping/fixture；候选与 harness 身份不变 |
| 认证方法 | 临时 key 生成 → 各 public-key 方法 → encrypted key → 产品删除 key | fixture 凭据、临时私钥、known-host、应用 key 文件 | 产品删除并独立审计 key 不存在，删除 known-host，移除 mapping/fixture |
| 生命周期恢复 | Ctrl+C / Pane close / minimize-restore / process-stop，各自随后恢复连接 | app PID、窗口可见性、Pane、fixture session | 恢复可见单 Pane，删除 known-host，移除 mapping/fixture |
| Pane/焦点/attention | BEL 状态 → parallel Pane authentication | Tab/Pane 布局、焦点、attention、临时 key | 回到单 Pane，删除临时 key/known-host，移除 mapping/fixture |

- **采用实现：** `verify-ssh-auth-pc.ps1` 新增四个稳定 `-Group` 入口；每份 JSON 明确记录
  `executionGroup`、声明 stages、setup、资源、primary oracle、cleanup、前置身份和展开后的
  内部 key 依赖。显式 diagnostic HAP 可以在 dirty harness 上做开发验证，但结果记录
  `runMode=diagnostic`、`harness.gitDirty=true`；正式组仍要求保留候选和 clean harness。
  `verify-ssh-matrix-pc.ps1` 固定串行执行四组，逐组核对候选 SHA-256、harness tree、Preferences
  不变和 cleanup，通过一组才进入下一组。
- **状态隔离修正：** 性能矩阵不再固定恢复 `Medium`，而是读取并在成功/失败路径恢复用户原值；
  Preferences 基线移动到任何 SSH 连接/host-key 信任之前；失败 cleanup 也执行 known-host 删除。
  因此不含 `password-success` 的组不会把测试自己建立和删除的信任误报为用户偏好变化。
- **续跑规则：** 一个阶段失败只失效所属组；先用同组 diagnostic 定位，确认清理和 C3 身份后，
  以整组 acceptance 重跑，再按固定顺序执行尚未完成的组。组内单阶段 `-Only` 不能提升为
  acceptance；候选、harness、fixture/端口、Preferences 或 cleanup 任一身份不明时升级到 R3。
  不并行运行共享同一测试机或端口的组，也不自动重发 unknown 副作用。
- **当前验证状态：** 新的静态/解析回归先因分组入口、正式编排和原透明度恢复不存在而失败；
  实现后 `tools/test-device-regression.ps1` 及聚焦 `policy,tooling` 已通过，软件证据为
  `software-focused-20260820T133138734Z.json`。代表性 `pane-focus-attention` diagnostic 已正确
  记录 group manifest，但首次在任何 SSH stage 前因测试机锁屏停止；UiTest 点击和现有 Home
  键均未使锁屏密码框取得焦点，cleanup 通过。手动解锁并完成观察成本优化后，完整
  `pane-focus-attention` 组于 `device-ssh-auth-20260820T140530534Z` 通过：BEL、双 Pane 独立认证、
  用户 Preferences 不变以及所有 fixture/known-host/reverse mapping 清理均有机器证据。因此分组
  和安全续跑边界已经闭合；锁屏记录只保留为环境失败样本。

### 2026-08-20 布局、截图和日志观察成本

- **研究问题与适用范围：** 在当前物理 ARM64 HarmonyOS PC、API 24、UiTest 6.0.2.3 上，
  `dumpLayout` 的默认与扩展属性、截图传输和过滤 HiLog 快照分别付出多少成本；哪些成功证据
  不参与判定；怎样在不降低 primary oracle、失败分类、秘密扫描和清理审计的前提下减采集。
- **HarmonyOS/OpenHarmony 官方与上游依据：** OpenHarmony
  [`arkXtest` 指南](https://gitee.com/openharmony/docs/blob/ca4467409329c262b239693b7ba5e96185122ff6/en/application-dev/application-test/arkxtest-guidelines.md)
  说明 UiTest 接口异步、不可并发，且 UI 变化后旧 Component 可能失效；上游
  [`README`](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md) 说明默认
  `dumpLayout` 会过滤不可见节点并合并窗口，`-a` 额外保存背景色、内容、字体等视觉属性，
  `-w/-b/-m/-i` 才分别控制窗口、bundle、合并和过滤。上游的
  [`IBCMVR`](https://gitee.com/openharmony/testfwk_arkxtest/issues/IBCMVR) 与
  [`PR 819`](https://gitee.com/openharmony/testfwk_arkxtest/pulls/819) 进一步表明这些参数属于
  布局范围/完整性能力，不是每次语义定位必须打开的模式；
  [`I57ZFF`](https://gitee.com/openharmony/testfwk_arkxtest/issues/I57ZFF) 记录过 daemon 断连，
  支持继续保留串行化和失败域分类，但不证明本项目当前存在断连。
- **社区与相近体系：** 检索了华为开发者社区、OpenHarmony issue 和可核验论坛中的
  `dumpLayout -a` 性能、截图频率、HiLog 轮询及 ArkWeb 选择器案例，没有找到与 LeanTTY 当前
  调用形状相同且给出可直接采用阈值的报告。Android 官方
  [`UI Automator`](https://developer.android.com/training/testing/other-components/ui-automator-legacy)
  建议等待可观察条件而非预测固定转场时长；Playwright 官方
  [`test-use options`](https://playwright.dev/docs/test-use-options) 与
  [`trace`](https://github.com/microsoft/playwright/blob/master/docs/src/trace-viewer.md) 建议把截图
  和高成本 trace 放在失败或首次重试，且明确全程 trace 有性能成本。这些只提供采集分层模式，
  不冒充 HarmonyOS 性能证据。
- **历史热点：** 2026-08-19 通过的完整 SSH 证据用时 3,574,748 ms（约 59.6 分钟），目录含
  189 份最终 layout、8 张截图、3 份日志，共约 57.6 MiB。59 份
  `layout-auth-text-focus-*` 来自普通文字输入前的重复焦点确认；逐份解析后 59/59 都已有唯一
  聚焦的 `Terminal input`，其中 54 份为单 Pane、5 份为双 Pane，后者也只有一个焦点。旧实现
  对每份路径先抓布局、点击，再覆盖抓取一次，因此历史运行至少执行了 248 次 layout 抓取。
- **受控操作分布：** 在同一台当前锁屏但 UiTest/HDC 正常的测试机上各测 10 次布局：默认
  layout 为 P50 1,091 ms、P95 1,154 ms，`-a` 为 P50 3,451 ms、P95 3,507 ms；两者均为
  61 个节点，脚本实际使用的 15 个属性序列完全一致。5 次截图为 P50 831 ms、P95 847 ms。
  过滤后的 HiLog 快照 10 次为 P50 125 ms、P95 142 ms；增加显式非阻塞 `-x` 后为 P50
  123 ms、P95 137 ms，没有足以授权代码变化的收益。锁屏样本只量化控制通道成本，不作为
  LeanTTY 产品通过或代表场景耗时。
- **采用实现与估算收益：** 公共 layout helper 不再默认请求未消费的 `-a`；普通 SSH 文字在
  当前 layout 已证明唯一焦点时直接定向输入，不再无条件点击并二次抓取；真正改变 Pane/窗口
  焦点及隐藏秘密输入的路径仍显式定位、点击和复核。冷/热启动脚本每个样本各抓取两次全局
  layout，也只读取 `id/clickable/bounds`，因此同步移除 `-a`；默认 20 样本时每个脚本 40 次
  抓取，按本次 P50 估算可各减少约 94 秒控制通道时间。性能矩阵的 5 张成功截图不参与模式或
  性能判定，已删除；模式继续由语义标签证明，性能继续由 device-clock render/hitch/memory
  数据证明，BEL 的视觉截图及全局失败截图/日志保留。按历史最少 248 次调用和本次 P50 估算，
  layout 控制通道从约 14.3 分钟降至约 3.4 分钟，预计减少约 10.8 分钟；移除的 5 张性能图
  历史占 28.6 MiB。以上是受控操作分布映射到历史调用数的估算，不替代优化后代表组实测。
- **保留边界与仍未知：** 认证值前后的布局/日志秘密扫描、受控 SSH 服务器结果、native 精确
  命令缓冲与一次 Enter 合同、阶段结果、cleanup 和失败升级采集均未删除；常驻 HiLog observer
  因当前快照成本低且会增加进程生命周期/清理复杂度而不采用。第 5 项仍须以同一口径取得至少
  三轮分布，避免把本次单轮收益当作长期 flaky-rate 结论。

### 2026-08-20 连接态文字的 Enter 前服务器确认

- **真机失败边界：** 解锁后的首次 `pane-focus-attention` 在第二条 BEL 命令安全停止。期望
  `ltty-bell inactive01 5000` 共 25 字符，应用日志只有 24 个文字事件后才出现 Enter，受控
  fixture 收到并执行的是 `ltty-bell inative01 5000`，缺少索引 13 的 `c`。这证明本次丢失发生
  在 UiTest/ArkWeb 进入 LeanTTY 之前，不是 fixture parser、SSH 传输或布局减采集；也再次证明
  `inputText` 成功退出和固定 500 ms 等待不能代表完整送达。
- **研究结论：** OpenHarmony 官方
  [`InputEvent` 样例](https://gitee.com/openharmony/applications_app_samples/blob/master/code/Project/Test/uitest/entry/src/ohosTest/ets/test/operationExampleTest/ui/InputEvent.test.ets)
  在 `inputText` 后等待、重新查找组件并用 `getText()` 精确比较，API 20 的普通输入与 paste
  变体也都做结果读回；官方没有承诺 shell 命令返回即代表目标已完整消费。Android 官方
  [`UI Automator`](https://developer.android.com/training/testing/other-components/ui-automator-legacy)
  同样要求等待可观察条件，Playwright 的
  [`Actions`](https://playwright.dev/docs/input) 也区分直接填值与逐键输入并以目标状态断言。上游
  issue 和华为开发者社区仍未找到与“ArkWeb 终端中间漏一个字符”完全相同且有稳定修复的报告，
  因此不把类比资料当作根因证明。
- **采用合同：** 控件无法可靠读回连接态终端整行，但受控 fixture 已持有尚未回车的真实服务器
  字节。fixture 现在把该缓冲写入运行期临时文件；脚本只在逐字相等后发送一次 Enter。不完整时
  记录期望/实际长度和首个差异位置，通过 fixture 的 Ctrl+C 清空并确认空状态，最多重试三次
  文字；Enter 后缺少业务 marker 仍是 unknown，绝不重发。原始快照不写入证据并随 fixture
  删除，秘密认证输入不经过该路径。
- **失败测试与实现校正：** PowerShell 合同测试先因 snapshot、重试与清空边界不存在而失败；
  Rust 测试先因 snapshot API 不存在而编译失败。实现后又由真实运行发现 `new_client()` 没有
  传播 snapshot 路径，相应测试稳定得到 `None` 后修复；fixture 完整离线套件最终 25/25 通过。
  一次 PowerShell 空字符串被折叠为 `$null` 的误判也改为显式 `{observed,value}`，避免把已清空
  错报为未观察。
- **最终真机证据与收益：** `bell-attention` 定向证据
  `device-ssh-auth-20260820T140323024Z` 用时 70.640 秒，6 条连接命令均一次精确、0 mismatch、
  6 次 Enter。随后完整 `pane-focus-attention` 证据
  `device-ssh-auth-20260820T140530534Z` 通过，8 条连接命令均一次精确、0 mismatch、8 次 Enter，
  Preferences 与 cleanup 通过。历史同两阶段 BEL 226.466 秒、parallel Pane 281.772 秒，合计
  508.238 秒；优化后分别 70.370 秒和 74.249 秒，合计 144.619 秒，单轮减少 363.619 秒，
  即 71.5%。这证明代表路径在保留更强 Enter 前字节判定后仍显著提速；长期分布留给第 5 项。

### 2026-08-20 验收工具资格化与冻结

- **研究问题与检索范围：** 在正式 release-candidate 物理矩阵开始前，怎样证明测试工具本身
  能按预定用途可靠控制和观察被测对象；怎样同时冻结产品候选与 harness 身份；工具变更后
  哪些证据必须失效。检索了 HarmonyOS Test Kit、OpenHarmony arkXtest/xDevice、test
  readiness review、测试工具 validation、不可变工具身份、隔离重试，以及 OpenHarmony issue、
  华为开发者社区和可核验论坛中的相近案例。
- **HarmonyOS/OpenHarmony 依据：** HarmonyOS V14
  [`Test Kit` 概览](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/test-kit-overview-V14)
  明确支持 suite/case 级预置与清理、筛选、随机和压力执行；OpenHarmony
  [`arkXtest` 指南](https://gitee.com/openharmony/docs/blob/ca4467409329c262b239693b7ba5e96185122ff6/en/application-dev/application-test/arkxtest-guidelines.md)
  要求测试有断言/检查点，并提供 suite/case 过滤、timeout 与 `breakOnError`；
  [`xDevice` 指南](https://gitee.com/openharmony/docs/blob/6e4ecf693a1a58a9889f0a248a006f3aa8ad2b1f/zh-cn/device-dev/device-test/xdevice.md)
  把执行前 Setup 与执行后 Teardown 作为测试支撑 kit 的职责。它们支持“先证明控制/观察通道、
  明确上下文并闭合清理”，但没有定义 LeanTTY 的 review HAP、SSH fixture 或候选/harness 双重
  身份。
- **readiness 与工具 validation 依据：** NASA 的官方
  [`Test Readiness Review`](https://nodis3.gsfc.nasa.gov/displayCA.cfm?Internal_ID=N_PR_7123_0001_&page_name=AppendixG)
  要求在 verification testing 前确认 test article、设施、人员、程序以及数据采集/控制均已
  就绪，并冻结被测配置与接口；NASA
  [`Software Test Procedures`](https://swehb.nasa.gov/spaces/SWEHBVB/pages/32604437/Test%2B-%2BSoftware%2BTest%2BProcedures)
  还要求在使用前验证测试步骤的适用性、充分性、完整性和准确性。FDA 的
  [`General Principles of Software Validation`](https://www.fda.gov/media/73141/download)
  要求软件测试工具按明确 intended use 保留验证协议、客观接受标准、结果和摘要。LeanTTY
  不是受这些航空/医疗规则约束的产品，因此只采用“context of use + 客观证据 + 变更后重评”
  的通用工程原则，不引入其审批组织或文档负担。
- **身份与失败处理依据：** GitHub 官方建议把可执行 Action 固定到
  [完整 commit SHA](https://docs.github.com/en/code-security/tutorials/secure-your-organization/protect-against-threats)，
  因为完整 SHA 才标识所审查的不可变代码；Playwright 的
  [retry 文档](https://playwright.dev/docs/test-retries) 区分一次通过、flaky 和持续失败，并在
  失败后丢弃 worker 状态。两者分别支持“候选 SHA 与 harness commit/tree 分开记录”和
  “重试后通过不能伪装成稳定资格”。OpenHarmony 上游
  [`I9KTGC`](https://gitee.com/openharmony/testfwk_arkxtest/issues/I9KTGC) 记录过官方 UiTest CLI
  文档把 `dumpLayout -p` 误写成 `screenCap -p`，说明仅信任文档或命令存在不足以资格化实际
  工具路径；它不是 LeanTTY 当前故障的同类根因。华为社区和论坛中没有找到与本项目完整
  candidate/harness 冻结模型相同、可直接采用的实现。
- **采用清单与实现：** 新的 `qualify-acceptance-harness-pc.ps1` 只编排现有能力，不创建第二套
  设备驱动。它要求显式 `-ReviewHapPath`，正式模式要求 clean harness 和已保留的 clean
  candidate；先跑 `test-acceptance-harness.ps1`，再复用最小 `password-success` 场景。最终
  JSON 必须证明预检、普通命令逐字精确且一次 Enter、运行期临时秘密输入、语义 layout、结构化
  app/fixture 日志、仓库内 russh server、Preferences/known-host/reverse mapping/fixture 清理，
  以及 release 包排除 acceptance-only marker 的负向回归。记录分别绑定 candidate SHA/源码
  commit/tree 与 harness commit/tree；任一身份、控制合同、包策略或正式矩阵前设备 Test Kit
  环境变化都使记录失效。
- **红绿与真机证据：** `test-build-workflows.ps1` 的新证据校验先覆盖 review HAP 哈希错配、
  flaky harness、输入 mismatch 和清理失败，只有稳定样本通过。随后以 1.4 冻结源码
  `5a6d3feed250f14292a949d2d10c953b9c103667` 对应的保留 HAP
  `327920650DAF8B92CDA200298CBEAA9E8356C236B17EE5034E0E53DC5D09ABE2` 执行诊断资格化；
  `harness-qualification-20260820T141758939Z` 约 70 秒通过，3 条普通命令均一次输入、0 mismatch、
  3 次 Enter，秘密输入、布局、日志、受控服务器与全部清理通过。由于当前 harness dirty，记录
  正确标为 `runMode=diagnostic`、`releaseEligible=false`，不冒充正式发布资格，也不修改或提升
  1.4 候选。另对 1.4 已冻结 production HAP
  `282487C02EF1F9062F472F3D3B2BFB35C3746417E2F9A61A330B7438F309942C` 直接执行包策略扫描，
  所有注册的 acceptance-only marker 均不存在；这份只证明已发布 release 包边界，不把当前
  dirty harness 变成正式资格记录。
- **取舍、冲突与未知：** 没有新增完整 smoke 或重复预检；最小场景内部已经在创建状态前验证
  控制通道，额外再跑一次独立 preflight 只会增加时间。正式资格记录必须在 clean commit 后重新
  运行，诊断结果不能复用。仍未知 HarmonyOS/UiTest 升级后的长期稳定率以及 70 秒单轮时长分布，
  留给本轮第 5 项至少三轮复测；正式矩阵中若首次发现 harness 缺陷，必须停止对应场景、分类并在
  矩阵外修复，不能边跑边改。

### 8.6 独立发布验证故障收敛（2026-08-20）

- **检索问题与范围：** 分别检索 “Git signed tag creation verification different gpg program/keyring”、
  “PowerShell PID read-only automatic variable assignment/AST” 和 “HarmonyOS production release Profile
  HAP versus debug/review HAP HDC install”。范围为 2026-08-20 可访问的 Git 2.49/当前在线文档、
  PowerShell 7.5/7.6 SDK 文档、HarmonyOS 5/API 级别 22 附近的 HDC/HAP/签名指南，以及
  OpenHarmony 对应公开文档；没有找到与 LeanTTY 三个操作失误完全相同且有更强证据的论坛方案。
- **GPG 官方依据：** Git 的
  [`git-tag`](https://git-scm.com/docs/git-tag.html) 与
  [`git-config`](https://git-scm.com/docs/git-config/2.49.0.html) 明确由 `gpg.format` 选择签名后端，
  由 `gpg.<format>.program` 选择其可执行程序，OpenPGP 下 `gpg.program` 只是兼容别名；GnuPG 的
  [`GPG Configuration Options`](https://gnupg.org/documentation/manuals/gnupg/GPG-Configuration.html)
  说明 home/keyring 决定可见密钥。共同结论是标签创建和验证必须固定同一个 Git 有效后端，
  不能一边临时覆盖 `gpg.program`、另一边回退全局配置。实现只解析现有后端并在两次 Git 调用中
  复用，不创建密钥、不改变配置、不推送标签，也没有扩大签名信任边界。
- **PowerShell 官方依据：** Microsoft 的
  [`about_Automatic_Variables`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables?view=powershell-7.5)
  定义 `$PID` 为当前 PowerShell host 进程 ID，并说明自动变量通常应视为只读；
  [`AssignmentStatementAst`](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.language.assignmentstatementast?view=powershellsdk-7.6.0)
  提供赋值目标的结构化解析。项目不禁止读取 `$PID`，只用 AST 拒绝大小写不敏感的参数、赋值和
  `foreach` 写入；这比文本检索更少误报，也保留现有 build-lock 对 `$PID` 的合法读取。
- **HAP 官方依据：** 华为
  [`HAP` 指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/hap-package-V14)
  把 HDC 安装定位为 HAP 调试路径；
  [`HarmonyOS 应用签名`](https://developer.huawei.com/consumer/en/doc/development/hmscore-common-Guides/harmony-signature-info-0000001167185654)
  明确调试设备需要 debug certificate/profile，而 release certificate/profile 属于发布路径；当前
  [`HDC`](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/hdc) 文档只定义 install 命令，
  不会替项目区分 production/review 角色。项目因此在设备准备之前拒绝规范命名的 production
  release-Profile HAP，并把升级脚本参数改名为 `BaselineReviewHapPath` /
  `CandidateReviewHapPath`；旧参数仅保留 alias 兼容已有命令。它不是根据文件名证明签名可信，
  正式资格仍必须再通过 retained-candidate 身份门禁。
- **红绿证据与边界：** 修复前可稳定重现三项：旧标签 helper 只在创建时覆盖 `gpg.program`、
  `pwsh -Command '$pid = 1'` 返回 “Cannot overwrite variable PID”、资格化入口接受 production
  文件名并会继续到设备阶段。修复后 `test-build-workflows.ps1` 用受控 Git 仓库和假 GPG 证明
  配置解析，静态证明创建/验证都携带同一 backend config；用合成脚本证明合法 `$PID` 读取通过而
  参数/赋值/循环写入失败；用合成 HAP 证明 production 立即失败而 review/retained 路径通过。
  三项都是 L1/`tooling` 证据，不声称真实签名、生产包可安装或产品行为已重新验收。
- **冲突与未知：** Git 同时保留 `gpg.program` 和 `gpg.openpgp.program` 两个 OpenPGP 配置名；
  helper 按新专用项优先、旧别名回退，避免改变用户配置。文件名 guard 只能阻止本项目已确认的
  production 命名，不能解析任意第三方 HAP Profile；该剩余风险由正式候选记录、release identity
  和签名/manifest 检查承担。尚未实际创建新标签，因为没有新版本且本轮不授权签名 Git 变更；
  真正签名仍留在下一次发布的 L4 门禁中。

### 8.7 三轮复测与收益口径固化（2026-08-20）

- **检索问题与版本：** 检索 “flaky test trend first retry pass rate”、 “test duration trend and
  longest test”、 “repeat/retry report OpenHarmony xDevice” 和 “fast reliable shift-left tests”。
  适用范围为当前 HarmonyOS PC/UiTest harness、Playwright 当前文档、Azure DevOps 2022/Services
  2025 文档和 OpenHarmony xDevice/arkXtest 公开指南；它们提供统计与报告模式，不替代本项目
  ARM64 PC 的实测。
- **外部共同结论：** Playwright 的
  [`Retries`](https://playwright.dev/docs/test-retries) 把首次失败、重试通过明确标为 flaky；
  Microsoft 的
  [`Test Analytics`](https://learn.microsoft.com/en-us/azure/devops/pipelines/test/test-analytics?view=azure-devops)
  要求从一段时期内的 pass rate、结果分布和反复/间歇失败趋势判断，而不是单次运行；
  [`Test runs`](https://learn.microsoft.com/en-us/azure/devops/test/test-runs?view=azure-devops)
  记录 outcome、duration、environment 并支持比较运行和最长用例；
  [`Shift testing left`](https://learn.microsoft.com/en-us/devops/develop/shift-left-make-testing-fast-reliable)
  按依赖和耗时划分测试，指出小时级、末端才运行的测试会延迟反馈并降低信号价值。OpenHarmony
  [`xDevice`](https://gitee.com/openharmony/docs/blob/6e4ecf693a1a58a9889f0a248a006f3aa8ad2b1f/zh-cn/device-dev/device-test/xdevice.md)
  把 `--retry` 定义为只重跑上一任务失败用例并生成新报告；
  [`arkXtest`](https://gitee.com/openharmony/docs/blob/ca4467409329c262b239693b7ba5e96185122ff6/en/application-dev/application-test/arkxtest-guidelines.md)
  提供 case/suite 过滤、timeout、break-on-error 和 stress 次数。共同支持“按 claim 选择最小场景、
  保留每次结果、重试不洗白”；没有官方资料支持把一次快跑外推成长期 P95 或完整发布覆盖。
- **冻结口径：** 相同 HAP SHA、harness 工作树、设备、受控 fixture、`password-success` 场景与
  diagnostic 模式连续三轮；报告全部样本及 min/median/max，不对 3 个样本计算 P95。统计普通
  命令首次尝试/总尝试、mismatch、Enter、unknown、cleanup、运行期人工介入、无新增证据重跑，
  并把 deliberate measurement repeats 与失败后的无假设重跑分开。软件层用同一
  `policy,tooling` 组跑三轮；物理层用同一 harness 资格化最小场景跑三轮，不进入 L4。
- **软件三轮：** 证据为 `software-focused-20260820T142838468Z.json`、
  `software-focused-20260820T142949276Z.json`、`software-focused-20260820T142955739Z.json`，
  三轮 3/3 通过、均为 `mode=focused`、`releaseEligible=false`；墙钟约 7.4/6.6/5.4 秒，
  min/median/max 为 5.4/6.6/7.4 秒。控制台中的一次 `RETRY inexact ...` 是固定的合成负向单测，
  不是本轮真实输入重试。
- **真机三轮：** 证据目录为 `efficiency-qualification-round-1/2/3`。资格化总时长约
  60/56/57 秒，min/median/max 为 56/57/60 秒；其中物理子场景为
  53.641/49.546/50.524 秒，min/median/max 为 49.546/50.524/53.641 秒。三轮合计 9 条普通命令、
  9 次首次尝试、0 mismatch、9 次 Enter、0 unknown、3/3 cleanup 通过、运行期人工介入 0、
  无新增证据的失败重跑 0。三轮是预先定义的分布样本，不计为浪费性重跑；所有记录保持
  `diagnostic`、`releaseEligible=false`。
- **相对收益：** 2026-08-19 的 4 小时 26 分是完整发布前验证，不能与本轮 focused 证据做
  等价覆盖或直接速度百分比。可比较的重叠 claim 是“harness 的普通/秘密输入、layout、日志、
  fixture 与清理是否适合开始矩阵”：过去依附在 3,574,748 ms（约 59.6 分钟）的完整 SSH 证据
  之后才能判断；现在独立资格化的物理中位数为 50.524 秒，针对该 readiness claim 减少约
  98.6% 等待，同时保留不稳定/失败就停止矩阵的门禁。普通功能迭代可在约 6 秒软件组后只跑
  受影响命名场景，不再默认进入完整 SSH 或全量回归；新版本发布仍完整执行 L4。
- **已消除干扰与剩余未知：** 本轮三轮没有文字短写、重复 Enter、unknown 误判、锁屏、Offline、
  Preferences 污染或清理失败；production HAP 也会在 HDC 前停止。样本只有三轮，只能证明当前
  HAP/harness/设备时段的稳定性，不能证明长期 flaky rate、OS/Test Kit 升级后的稳定性或物理
  键盘输入质量。以后出现真实 retry 时必须计入 flaky-harness；累积样本足够后再报告 P50/P95，
  不用本次 0/9 外推永久零丢失。

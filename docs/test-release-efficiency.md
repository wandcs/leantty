# LeanTTY 测试与发布效率改进

> 状态：当前工程流程的原因说明、已采用决策与后续测量口径
>
> 更新日期：2026-08-28
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

## 2026-08-28：1.5.1 已采用实现

1.5.1 将复盘中的四项工程改进落为现有权威流程的可执行入口：

- `test-release-readiness.ps1` 在 C0 前组合聚焦软件门、离线 Agent 规则、release 包 marker、
  稳定候选命名空间及 production/review 预检；记录明确不可作为发布资格，且模型调用为 0。
- 候选库按规范化 `origin` 身份命名；显式 HAP 仍必须匹配保留 manifest、源码身份和 SHA-256。
- SSH 矩阵支持原子检查点和显式恢复；SSH、Agent 与长任务通知记录 attempt 链及无内容进度，
  候选和 harness 身份分开保存。
- `prepare-appgallery-release.ps1` 在标签前生成 license ZIP、Release notes、AppGallery 文案、
  交接清单和附件摘要；`prepare-release-status-update.ps1` 把 GitHub Release 与维护者交接事实
  合并为一次状态 PR 的输入。

这些工具只减少重复工作，不改变签名、真实设备 smoke、标签、GitHub Release 或 AppGallery
维护者操作的进入条件。耗时、候选构建次数和恢复时长仍在下一次正式发布中按既定指标实测。

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

### 8.8 失败矩阵后的 harness readiness 修复（2026-09-05）

- **问题与版本：** 本轮只修正式矩阵暴露的验收工具边界：普通输入目标、Mosh 页面与 Search
  oracle、Wi-Fi 转场、正式构建输入、Hvigor 输出、ArkTS warning 和 license ZIP。适用环境为
  HarmonyOS API 24、UiTest 6.0.2.3、DevEco Studio 6.1.1.290、Hvigor 6.24.3 和当前固定依赖；
  先修 harness；只有直接页面 oracle 把首个错误边界定位到产品 snapshot owner 后，才补充
  viewport 的保存与恢复。
- **输入依据：** 华为 [`UiTest`](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/js-apis-uitest-V13)
  要求等待异步 Component 操作；OpenHarmony
  [`arkXtest`](https://gitee.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)
  将坐标 `inputText` 与当前焦点 `text` 定义为不同 shell 路径。既有 48/48 对照和本轮 6/6
  小样本都支持坐标路径；本轮再次观察到 `text help` 成功退出却向 native 缓冲写入 0 字符。
  公共 helper 因此在一个 UiTest mutex 内重抓布局、验证唯一焦点和调用者目标，再从当前节点取
  坐标执行 `inputText`。无输入相邻 layout 证明 `accessibilityId` 会重建，而节点 type、id、hint、
  focus、bounds 和 Pane 归属保持一致；目标等价因此不再依赖瞬态 accessibility ID。exact native
  buffer、最多三次输入和单次 Enter 合同不变。
- **直接 oracle：** xterm.js 明确说明 [`Terminal.write`](https://xtermjs.org/docs/api/terminal/classes/terminal/)
  异步更新 buffer，必须在 callback 后读取；官方 Search addon typings 提供
  [`onDidChangeResults`](https://github.com/xtermjs/xterm.js/blob/master/addons/addon-search/typings/addon-search.d.ts)
  及 result index/count。官方 SerializeAddon 说明和仓内 vendored 实现都只序列化 buffer/mode，
  不保存 `viewportY`；`Terminal.scrollToLine` 是公开恢复接口。验收 HAP 现在在产生 snapshot 的同一
  write callback 记录不可逆基线指纹，并在 replay 完成、恢复 viewport、发送 page replace ACK 和
  写入本地输出之前记录结果指纹；二者都包含 buffer、尺寸、viewport 和可见单元格 hash。Search
  单独验证查询与 SearchAddon 结果，两种 oracle 不再互相代替。
- **Wi-Fi 状态：** 2026-09-05 重新查询的问题是：不扩大 LeanTTY 权限、也不解析本地化 Settings
  文案时，HarmonyOS API 24 上哪个值可以作为当前 SSID 的稳定权威。HarmonyOS
  [`WLAN STA 指南`](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/sta-development-guide)
  区分连接事件、当前连接信息和 IP 信息；公开 Wi-Fi API 的当前连接信息需要权限清单中的
  [`ohos.permission.GET_WIFI_INFO`](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/permissions-for-all)。
  但验收配置不得扩大产品权限，所以没有把该权限注入 test HAP。OpenHarmony 当前
  [`WifiDevice` 服务实现](https://github.com/openharmony/communication_wifi/blob/ac2cdee8673a79831307f2aa14a8efc54b1eee8c/wifi/services/wifi_standard/wifi_framework/wifi_manage/wifi_sta_sa/wifi_device_service_impl.cpp)
  的 dump 直接从 `WifiConfigCenter` 读取 `WifiLinkedInfo`，输出 active、connection status 和
  connected SSID；同一真机的只读 `hidumper -s WifiDevice` 已与该格式一致。因此可见系统面板
  只负责选择精确的已保存 SSID，连接状态由此系统服务读取，再依次观察 WLAN link、link IPv4 和
  endpoint reachability。官方 HDC 文档没有承诺该文本格式跨版本不变，所以 parser 严格要求唯一
  active/status/SSID，格式漂移即以 harness failure 停止，不能产生产品 verdict。
- **Wi-Fi 转场与路由：** `netstat -rn` 的最长匹配 route 只作为可取得时的辅助身份。真机已证明
  经典表可以没有 `192.168.1.4` 条目，而同一时刻对 `192.168.1.4:2222` 的 telnet 成功，因此不得
  用该条目阻止直接探测。初态先从当前 layout 将面板归一化为已关闭，再打开并选择行；关闭也只在
  已观察到面板打开时发送 Back，不再依赖“已连接 WLAN”等语言文案。业务恢复 verdict 与原网络
  cleanup 分开；cleanup 失败写本地 dirty marker，恢复前阻止下一次网络场景。
- **构建与归档依据：** npm 的 [`npm ci`](https://docs.npmjs.com/cli/commands/npm-ci/)
  面向自动化干净安装；Cargo 的 [`fetch`](https://doc.rust-lang.org/cargo/commands/cargo-fetch.html)
  明确支持预取后 offline。`.NET` 分别公开
  [`RedirectStandardError`](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.redirectstandarderror)
  和 ZIP entry 的 [`LastWriteTime`/`ExternalAttributes`](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.ziparchiveentry)。
  正式入口现先预热 npm/OHPM/Cargo，再以 offline 和 Hvigor `--no-daemon` 运行；stdout、stderr、
  exit code 独立保存，ArkTS warnings 按工具版本、数量和规范化 hash 精确比较。license ZIP 使用
  ordinal entry、固定时间和属性，回归在扰动源文件 mtime 后双构建并比较 SHA-256。
- **研究记录：** 2026-09-05 查询的问题是 UiTest 节点身份能否跨 dump 持久、xterm snapshot 是否
  包含 viewport，以及何时才能读取稳定页面。公开 UiTest/arkXtest 材料没有给出
  `accessibilityId` 跨 dump 稳定合同，因此以相邻无输入实测约束 helper；xterm 公开 API、
  [SerializeAddon 仓库](https://github.com/xtermjs/xterm.js/) 和
  [序列化恢复讨论](https://github.com/xtermjs/xterm.js/discussions/4467) 与 vendored 源码一致：
  write callback 是已解析边界，序列化可重建大部分 buffer 状态但不携带 viewport。当前未决问题
  是 Wi-Fi Settings 自动化在目标系统版本上的长期稳定率，而不是页面恢复语义。
- **当前证据与停止边界：** PowerShell 实际 hash helper 的 `0xffffffff` 被解释成有符号 `-1`，已改用
  `[uint32]::MaxValue` 并以 `help -> 3871a3fa7c715c94` 的红绿测试闭合。输入诊断
  `text-input-focus-targeted-contract-20260905-fixed-r1` 为坐标 6/6、focus 5/6、raw-key 6/6、
  0 Enter、cleanup 通过。`mosh-abnormal-exit-direct-oracle-20260905-r4` 首次直接证明 snapshot replay
  丢失 viewport；产品随后让 snapshot、buffer、Bridge 和 xterm replacement 共同携带 viewport。
  r5 进一步发现旧基线取在输入 `mosh` 命令前，属于 harness 取证时点错误；改为 snapshot 同回调
  基线后，最终 HAP SHA-256
  `a801e6f64b9b0d1d461c37f3cae1e6868b7fbc1c7e40e9f421503992c47128a3` 的
  `mosh-abnormal-exit-direct-oracle-20260905-r6` 精确恢复
  `normal,144,36,10,f6c607089a7f3e08`，Mosh Search 阴性且 cleanup 通过；同 HAP 的
  `mosh-runtime-reclaim-harness-readiness-20260905-r2` 也通过。最新聚焦软件证据为
  `software-focused-20260905T041045608Z.json`。页面、Search、普通输入和 deterministic lifecycle
  已取得 L3；`formal-inputs-harness-readiness-20260905.json` 也证明网络依赖预热完成且跟踪输入未变。
  Wi-Fi r1 的 `$Matches` 自动变量覆盖已由最长前缀路由红绿测试修复；经典 route 前置假设也被真机
  实连反证并移除。r4 随后在切网前因 HarmonyOS 面板缺少“已连接 WLAN”语义区停止，没有产品
  verdict。只读 panel 已证明原 WLAN link 与 `192.168.1.4:2222` 可达；dirty marker 被移入 r4
  证据目录并关闭检查面板。停止后完成的重构不再增加 UI workaround：L1 已覆盖 WifiDevice
  connected/disconnected、CRLF、重复 SSID fail-closed，以及 panel open/closed/unknown、重复 owner
  和一次性 Back 归一化。真机只读 preflight 与 `WifiDevice` dump 也已通过。唯一允许的重构后 L3
  `mosh-wifi-network-switch-harness-readiness-20260905-r5` 通过 preflight、fixture、安装、Mosh 命令和
  SSH baseline，但在实际切网前停止：`Focus-MoshPane` 把两个 xterm 隐藏输入框按当前光标 X 坐标
  排序，当前布局中第一个 Pane 为 X=1613、第二个 Pane 为 X=1541；快捷键已让第一个 Pane focused，
  排序后的 index 0 却指向未聚焦的第二个 Pane，最终误报 environment timeout。证据的
  `transitionHistory=[]`、`productVerdict=not-assessed` 明确说明新 SSID oracle 尚未进入 L3。cleanup
  全部通过，测试后 `WifiDevice` 的散列身份为原网络且 `192.168.1.4:2222` 仍可达。按停止条件本轮
  不修复、不重跑；下一步先为 Pane selector 建立光标坐标反序的红绿合同，再跑聚焦 L1/L2 和唯一
  一次 named L3。独立 checkout release-readiness drill 同样尚未闭合，因此不能声明完整 harness
  readiness、新候选资格或 1.6 验收通过。

### 8.9 Pane 焦点选择器修复（2026-09-05）

当前问题是 UiTest 6.0.2.3 / HarmonyOS API 24 上，如何在 xterm 光标移动后仍判断目标 Pane。
预期是 Ctrl+Alt+Left 后第一个 Pane 独占输入焦点。r5 最后正确边界是当前 layout 中第一个 Web
子树的输入已 focused，第二个未 focused；首个错误边界是公共 `Get-LeanTTYTerminalInputNodes`
按 textarea X 坐标排序，把第一个 Pane 排到 index 1。`Index.mountedPaneRuntimes()` 按各 Tab 的
`panes` 顺序挂载，`isRightPane()` 使用同一 Tab 的第二个 Pane；当前可见两 Pane 的布局树顺序与
该映射一致。坐标不是所有权，根因假设是删除该排序即可消除这次误报。

外部研究核对了 [xterm 6.0.0 源码](https://github.com/xtermjs/xterm.js/blob/6.0.0/src/browser/CoreBrowserTerminal.ts)
的 `_syncTextArea()`：textarea 随 cursor move 更新位置；[相关上游 issue](https://github.com/xtermjs/xterm.js/issues/3058)
也记录了 textarea 位置影响布局的问题，但不是本次 HarmonyOS 缺陷的证明。
[OpenHarmony UiTest 源码](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/core/ui_model.cpp)
将 hierarchy 定义为父路径加 child index，未承诺其跨重建稳定。
[Playwright locator 文档](https://playwright.dev/docs/locators#strictness)建议以明确定位合同代替任意
`first/nth`；这里借鉴其原则，每次仍读新 layout，并只在恰好两个可见终端输入且目标独占焦点时
通过。搜索 Huawei 开发者社区及 OpenHarmony issue 未找到与双 ArkWeb 边界重叠完全相同的可复现
报告，不能据此承诺所有应用的树顺序等于左右顺序。本工具的映射限定于上述 LeanTTY 挂载合同，
不保存跨 dump 的 hierarchy 或 accessibilityId。

最小验证先用两个独立 Web 子树、相同 Web bounds、反序 textarea X 和切换焦点的 L1 fixture
重现错误，再删除坐标排序；随后执行聚焦 policy/tooling 和一次 Wi-Fi network-switch L3。
该 L3 同时覆盖左右 Pane 的后续真实命令、Wi-Fi 切换和原网络恢复，失败时按新首错边界重新评估。

修复后的 L1 通过；原 r5 layout 离线重放也识别到第一个 Pane focused、第二个未 focused。
`software-focused-20260905T074614194Z.json` 的 policy/tooling 通过。唯一一次 L3 r6，attempt
`fef399270f94473fa5a3652f533ec2c6`，沿用 HAP `a801e6f6…c47128a3`，耗时 291238 ms。它通过了原
Pane 焦点失败点、系统面板归一化、SSID/IPv4/route 改变、端点可达性和 SSH 断开重连后的新命令；
原网络恢复、fixture、Host、known-host、HDC reverse、临时目录 cleanup 全通过。

r6 在 Mosh 恢复输入处以 harness failure 停止：`network-switch-mosh-after-switch.json` 和
`mosh-connected-focus-1.json` 证明第一个 Pane 独占焦点；随后
`mosh-retry-interrupt-focus-1.json` 证明焦点已到第二个 Pane，且恢复命令只出现在该 Pane 的 Web
可见内容中。两 Web 子树报告相同 bounds。`connectedInput` 为 expectedLength=39、actualLength=0、
3 次 mismatch、0 Enter。因此最后正确边界是键盘选择目标 Pane，首个错误边界是坐标 inputText
把文本送到另一个 Pane。后续 retry 重新选取“当前焦点”而丢失了最初目标，使这个错误持续。
现有证据未区分 UiTest 坐标投影、ArkWeb 命中测试与产品布局；不能改为认定 Mosh 丢字，也不能在
未知输入归属下继续提交。`productVerdict=not-assessed`，本轮停止切网测试。

下一次最小诊断应只有两个 Pane、无 Enter、无网络变化，逐次保留目标与注入后 owner、实际输入
和窗口几何。先核对官方 UiTest/ArkWeb 输入与坐标合同，再判断是修正工具定位还是产品布局。
目标丢失要立即停止，不能把新的当前焦点当成同一目标。网络比较还有一个待评估的简化：SSH
重连命令通过后先退出并关闭其 Pane，Mosh 恢复命令随后在唯一 Pane 运行；它保留同一次切网及
两个协议的命令/恢复合同，但不能代替双 Pane 输入归属问题的独立诊断。

独立 checkout 演练 `release-readiness-harness-20260905.json` 通过 8 项检查、0 模型调用，未创建
candidate。该次当前工作树的 `policy,tooling,web,arkts` 证据为
`software-focused-20260905T075340151Z.json`。包扫描与 production/review 预检使用现有 1.5.1
发布基线，两 checkout 同为 `ef3184bf8f3d8e7edcc09c96fedf42d1f0caf209` 且保持干净；本次只证明
当前演练工具与已有发布环境可运行，不声称未提交的 1.6.0 修复已通过独立发布预检。

### 8.10 双 Pane 输入归属的最小复现（2026-09-05）

目标是可靠输入到指定 Pane，不是继续寻找能绕过重叠界面的输入命令。预期关闭左 Pane 后，
原右 Pane 铺满窗口；再次分屏时两者左右分离。r2 最后正确边界是模型顺序与键盘焦点；首错
边界提前到 ArkUI 布局：原右 Pane 保留旧位置、宽度和关闭按钮，再次分屏时两 Web 都位于
`[1490,395][2798,1902]`。截图也显示左半边空白、右侧两终端重叠，排除了仅 UiTest 投影错误。

`pane-input-ownership-20260905-r2` 使用相同 HAP `a801e6f6…c47128a3`、HarmonyOS
`6.1.0.135(SP60C00E100R13P3log)`、API 24、UiTest 6.0.2.3。无网络变化、无 Enter。键盘分别
输入 `l`、`r` 后，指定左侧的坐标 inputText 将 `probe` 投入右侧；随后分别追加单字符读取原生
缓冲，左侧为 `lx`，右侧为 `rprobey`。临时 Tab/Pane 和屏幕超时租约已清理。r1 在新 Tab 门
停止：原 Tab 的两个 warm Pane 仍报告可见，30 秒保留期后消失；这也是显隐状态未刷新线索。

本次重新核对的外部证据：

- [官方 UiTest input 实现](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/input/ui_input.cpp)
  的坐标 inputText 先点击、等待 500 ms，再输入，不保证保留点击前的焦点。master 为后续版本，
  具体设备行为由上述 6.0.2.3 复现确认。
- [华为状态刷新排查指南](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/troubleshooting-state-manage)
  说明依赖收集是刷新的前提；[ForEach 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/ts-rendering-control-foreach-V13)
  说明稳定 key 对应节点复用。当前 Index 的布局、显隐和焦点方法读取普通 `appVm`，没有读取
  `@State tabs/activeTabIndex`，已有节点因而不订阅这些变化。
- [xterm 上游 issue 3058](https://github.com/xtermjs/xterm.js/issues/3058)涉及 textarea 坐标，但不是
  本次原生 Pane 重叠的原因。搜索 OpenHarmony issue 和华为开发者社区未找到该组合的精确报告。
- [Playwright actionability](https://playwright.dev/docs/actionability)区分可见与实际命中对象；这里
  只借鉴输入前后验证目标的原则，不据此推断 HarmonyOS API 的保证。

修复假设：让 UI 读取现有可观察 workspace 投影，保持 Session 所有权、Web key 和 generation
不变，即可更新位置、宽度、显隐和焦点；不通过重建 Web 或更换输入协议掩盖问题。工具应在同一
次输入前后核对当前树中的输入所有者，丢失则抛错，不进入重试/Enter。先做 L1 红绿和聚焦软件门，
再用相同无 Enter 复现做真机对照；通过后才恢复一次 Wi-Fi 命名诊断。

Index 修复让 `activeTab()`、`findTabForPane()` 和 `paneMode()` 读取现有 `@State` 投影；未改变
Web key/generation，也未重建 surviving Session。工具排除 opacity=0/HitTestMode.None 的外层
Tab wrapper，并在同一次输入前后核对 window/hierarchy；Mosh 重试始终绑定第一次的 Pane。
L1 先重现重叠目标未报错、隐藏 Tab 混入两个问题，再验证修复；源码依赖约束也完成红绿检查。

ARM64 debug HAP 重建成功，SHA-256 为
`595d5b569e1620b430e5fd748f647c25487b8dd8d8163b83e4d8398e34613ebc`。r3 的同一诊断已恢复
正确左右几何，原生缓冲为 `lprobex` / `ry`。保存后的入口
`diagnose-text-input-pc.ps1 -Scenario pane-ownership` 在 r4 用时 39118 ms 通过：原右 Pane 的
`r` 在关闭左 Pane 后仍保留，追加得到 `rs`；再次分屏后指定左 Pane 输入，再独立读取缓冲得到
`rsprobex` / `y`。全宽恢复、无重叠、0 Enter、无切网、临时 Tab/Pane 和屏幕租约 cleanup 均通过。
截图已人工核对。诊断证据目录为 `pane-input-ownership-20260905-r4`。

`pane-input-ownership-software-desktop-20260905.json` 的 policy/tooling/web/arkts 通过；此前在
sandbox 运行的工具组因 WSL 身份边界被拒绝，属于运行身份错误，未修改系统或 WSL。最终工具
修改另由 `pane-input-ownership-tooling-final-20260905.json` 检查。随后只恢复一次 Wi-Fi r7，
使用上述新 HAP；仍不是正式 retained candidate 或发布验收。

r7（attempt `bd8d6ab05b1a4e43a0dbb5cb1e8110c3`，311854 ms）已完成网络比较：源地址和路由
变化、端点可达；Mosh 同一 Session/远端 PTY 保留并执行新命令，SSH 断开后重连并执行新命令。
14 次本地受控提交均首次精确、0 mismatch；两次 Mosh 受控命令分别 34/34、39/39 字符，均一次
输入、一次 Enter。`networkSwitchComparison.productVerdict=passed`。Mosh 恢复观察值 64293 ms
包含 SSH 比较和工具动作，不能解释为协议恢复延迟。原网络及全部 cleanup 通过，无 dirty marker。

整轮仍为 failed：关闭阶段的精确页面指纹不相等。保存页为
`normal,144,36,15,26200508fed88bbe`，恢复页为 `normal,71,36,15,d400a2dce025dac8`。Mosh
启动后场景才新增 SSH Pane，因此当前列宽已改变；此前布局缺陷恰好让旧 Pane 没有正确缩窄。
现有 oracle 将列数与当前可见行一起纳入 identity，却没有同几何前提。原始结果文件保留脚本的
`failureDomain=product`，人工结论是**不同几何的比较不足以判定页面恢复缺陷**，也不能反向
宣称恢复正确。已通过原页隔离、Mosh 内容退出后 Search 阴性、认证优雅关闭和本地输入就绪。
偏好 after digest 与最终 secret 扫描尚未执行；对应默认 false 不是已观察到变化或泄露。

本轮到此收口，不修改页面恢复或再切网。下一步先做无网络的保存页/resize/恢复对照，明确同
几何精确比较与变宽重排的区别。网络场景可在两协议比较完成后退出并关闭 SSH Pane，让 Mosh
恢复到保存时的宽度再执行关闭检查；但这不能替代独立的变宽内容保留测试。只在对照证明实际
内容或恢复状态错误后改产品；否则修正 oracle 前提、场景布局和失败分类。不得强制终端保持
旧列宽、跳过历史隔离检查，或把 `networkSwitchComparison=passed` 升级为整轮通过。

### 8.11 快照恢复与尺寸重排的无切网对照（2026-09-05）

本项预期：同尺寸恢复保存画面；尺寸改变时，内容、光标和 viewport 应与原终端正常 resize
一致，不要求跨尺寸可见画面哈希相同。最后正确边界是保存时的 xterm framebuffer；r7 的首个
错误比较是 144 列与 71 列的可见页 identity。快照重放的唯一所有者是 ArkWeb，原页生命周期
仍由 Session/TerminalOutputBuffer 持有，不让测试脚本或 Rust 修补内容。

本次重新查阅外部资料：

- 锁定的 xterm 6.0.0 / addon-serialize 0.14.0
  [公共 API](https://github.com/xtermjs/xterm.js/blob/6.0.0/addons/addon-serialize/typings/addon-serialize.d.ts)
  建议先在保存尺寸恢复，再 resize；上游
  [#3093](https://github.com/xtermjs/xterm.js/issues/3093) 与维护者
  [#4467](https://github.com/xtermjs/xterm.js/discussions/4467) 说明跨尺寸反序列化的光标和内容伪影风险。
- Huawei [Web 布局说明](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/web-fit-content)
  涉及 Web 容器尺寸，不提供 xterm 快照合同。Huawei 开发者社区的 xterm/resize/快照检索未找到
  与本症状一致且可复现的报告；不能把网络检索当作本机 ArkWeb 通过证据。
- [Playwright visual comparisons](https://playwright.dev/docs/test-snapshots) 强调比较环境一致，
  这里只借鉴同几何比较前提，不作为 HarmonyOS 行为保证。物理验证仍针对 API 24、
  HarmonyOS 6.1.0.135、UiTest 6.0.2.3，以 live preflight 为准。

最低成本假设检验使用仓库原样 xterm 和 SerializeAddon，不连接设备或网络，不模拟解析器。
`build/verification/page-resize-probe-20260905.json` 的 24 个对照表明：同尺寸均一致；144→71
短行内容不丢；长行直接在窄尺寸重放后逻辑内容、物理行和光标均不一致，首个差异在第 92 行，
光标为 `[95,64]` 而正常 resize 为 `[93,60]`。这是带活动光标的长行；xterm 正常 resize 对该行
本身有裁剪语义，不能把差异全部描述为重放丢字。已完成长行的逻辑内容对照相等，alternate
buffer 的直接跨尺寸重放另有物理行和光标差异。先按 144 列重放再缩窄，全部相等。因此既有
oracle 前提错误，也有独立证实的产品重放缺陷；不能只删除列宽比较。

选定修复：快照携带保存尺寸，在 ArkWeb 现有两条恢复入口复用一个重放函数；先恢复保存尺寸和
viewport，再 resize 到进入恢复时的当前尺寸。中间尺寸不得上报 Session，不能永久锁定旧宽度。
L1 直接执行生产函数，对照实时 resize 的内容、光标、viewport、后续写入及 Search 隔离；L3
只验证受影响页面恢复，不切换 WLAN、不跑完整矩阵或新正式候选。Wi-Fi 场景的精确画面比较
另行恢复同几何前提；不同几何应报告 harness 前提缺失，而不是自动判为 product 丢内容。

实现只改变 `terminal.html` 的快照生成/重放：在现有 opaque、仅内存快照前附加
`LTTY1:cols,rows|`，尺寸计入原 payload 上限；原生层仍原样持有快照及可追加的 VT reset suffix，
不增加第二套原页状态。Mosh page replacement 与 Surface restore 共用一个函数，保存 viewport
先于正常 resize 应用。恢复期间暂缓 fit/resize 上报，完成后恢复当前实际尺寸和正常上报。

生产函数回归覆盖六组：同尺寸、双向变宽、同时变宽高及活动长行光标；检查物理行、wrap、
光标、viewport、所有已完成逻辑行的逐字保留、下一次写入、Search 阳性/阴性、Surface 重放及
native reset suffix。异步重放中的 fit 不执行、旧尺寸不送入 Session，完成后只上报当前尺寸。
首个失败测试明确落在 144×36→71×36 的生产 page replacement；修复后六组均通过。

聚焦 `policy,tooling,web,arkts` 通过，原始记录为
`build/verification/snapshot-resize-software-20260905.json`；补齐六组最终断言后的记录为
`build/verification/snapshot-resize-software-final-20260905.json`。
`dev-pc.ps1 -NoDaemon -Offline -RequireUsb -NoLaunch` 完成 ARM64 debug 签名构建及安装，HAP
SHA-256 为 `cc02fee50dc4834d4c6c256464a0f107389d4bb1d2d8477d6e7689b2f8df2509`。
原生库未变；没有重建正式候选或修改 Mosh client。

该 HAP 的唯一 L3 为 `verify-mosh-pc.ps1 -Scenario page-rebuild`，证据在
`build/verification/mosh-page-rebuild-snapshot-geometry-20260905-r1/device-mosh.json`，attempt
`6fd1d2b7862043758b9aeb6d2801cdf7`，182822 ms，passed、stable。PID/start time 相同、workspace
复用、Mosh 页保留、同远端 Session 新命令通过；原页保存与 ACK 前恢复指纹均为
`normal,144,36,10,b9a2261263fa4f54`。Mosh 历史 Search 阴性、认证关闭、local prompt、Preferences、
secret audit 和全部 cleanup 通过；9 次受控本地命令为 9 次输入/9 次 Enter、0 mismatch。

证据边界：变宽/变高的精确状态对照由 L1 原样 xterm 与生产函数证明；L3 验证真实 ArkWeb、Bridge、
页面重建、Session 和同几何原页恢复链路，不冒充变宽关闭真机测试。本轮没有切换网络、没有增加
新的验收触发入口或跑完整矩阵。现有 Wi-Fi 场景已修正为在完成两协议比较并确认 SSH 正常退出后，
关闭那个 idle Pane 再恢复 Mosh 原页；这项复合流程尚待单次收口复核，任务只列在 Next Work。

### 8.12 单次 Wi-Fi 收口复核在认证阶段停止（2026-09-05）

按 §8.11 的边界只执行了一次 `wifi-network-switch`，无构建、无代码修改、无重跑。
开始前重新通过 `test-device-regression.ps1`、`test-terminal-policy.mjs` 与设备 preflight，
HAP SHA-256 仍为 `cc02fee50dc4834d4c6c256464a0f107389d4bb1d2d8477d6e7689b2f8df2509`。
证据为 `build/verification/mosh-wifi-network-switch-harness-readiness-20260905-r8/device-mosh.json`，
attempt `077d19180de44ee5b21e4711a6f040ac`，前序为 r7 的 `bd8d6ab05b1a4e43a0dbb5cb1e8110c3`，
耗时 158514 ms，failed。

首次 Mosh bootstrap 的密码认证失败，尚未进入 UDP Session，更未切换 Wi-Fi：

- 服务端 `failure-fixture-stderr.log` 明确记录 `auth method=password scenario=Mosh result=reject`，
  `expected_bytes=32 received_bytes=31 overlap_mismatches=23 length_delta=-1`。这些字段是
  fixture 对实际收到字节的比较，不包含密码，也不能用重叠差异数推断精确丢字位置。
- 应用日志 18:12:35.727 记录 password submit，18:12:35.782 记录
  `Mosh error stage=authentication`。工具仍等待 connected，最后报告等待超时；原始
  `failureDomain=harness`、`lastProvenBoundary=test-hap-launched` 保留不改。人工边界判断应细化为
  **认证输入不一致已证实，丢字所属层尚未确定**，不是 Mosh UDP、漫游或页面恢复缺陷。
- `Submit-InteractiveValue` 使用坐标 `inputText` 和前后焦点检查，然后发送一次 Enter；与普通
  本地命令不同，它没有 native password buffer 的逐字判定。11 次本地受控命令为 11 次输入、
  11 次 Enter、0 mismatch，原报告 `harnessStability=stable` 只覆盖这些命令，不覆盖密码路径。

预期是一次性密码被完整提交并认证成功。最后可确认的正确控制边界是当前唯一目标的输入前后
焦点检查均被接受；第一个直接错误数据边界是服务端收到 31/32 字节。中间的
UiTest→ArkWeb/xterm→Bridge→`passwordBuffer`→SSH auth 仍有观测缺口。源码还显示 masked 模式
会在 input/key 后安排 100 ms textarea 清理；这只是待区分的候选原因，当前证据不证明该计时器
导致丢字，也不授权删除安全清理。日志事件条数不作为字节完整性的证据。

`networkSwitchComparison.productVerdict=not-assessed`，transition history 为空，SSH 比较为
not-run。`originalNetworkRestored=true` 在这里表示未进入切换、无需恢复，不表示执行过漫游
恢复。全部 device-state、fixture process、reverse mapping、persistent network 和 temporary
directory 清理通过，复查无 dirty marker。最终 Preferences after digest 与 secret audit 未执行，
对应默认 false 不代表已经发现偏好改变或泄露。

本轮按停机条件收口。后续先做不切网的最小认证输入对照，区分普通注入与 masked 输入路径，
并对认证错误的即时观察与字节完整性分别建立证据。具体工作仅列于 Next Work；不把这一失败
转化为 Wi-Fi 重跑、扩大密码可见性、增加盲目重试或延长连接等待。

### 8.13 认证输入分层诊断（2026-09-05）

本轮问题是 r8 的 32 字节密码在服务端变成 31 字节：最后正确的数据边界未知，不能从焦点
检查通过推断输入完整。候选原因包括 UiTest/ArkWeb 交付、xterm 的延迟 textarea 差分、100 ms
隐私清理，以及 Bridge/ArkTS 密码缓冲。`passwordBuffer` 仍是本地密码输入的唯一状态源。

开始时重新调研了以下资料：

- [OpenHarmony UiTest 官方指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)
  和 [官方命令与版本记录](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)
  区分定向 `inputText`、获焦 `text` 和实体键事件。命令成功不是目标应用收到全部字节的证明；
  当前 master 的新显示器参数也不能套用于测试机 UiTest 6.0.2.3。
- [xterm 6.0.0 CompositionHelper 源码](https://github.com/xtermjs/xterm.js/blob/6.0.0/src/browser/input/CompositionHelper.ts)
  与本地锁定源码一致：非 composition 状态下的 keyCode 229 通过异步 textarea 差分生成输入。
  [#6012](https://github.com/xtermjs/xterm.js/issues/6012) 和
  [#6078](https://github.com/xtermjs/xterm.js/issues/6078) 报告隐藏 textarea 残留与字段替换导致异常；
  后者基于 6.1 beta、Chrome/WebKit，不能直接当作 HarmonyOS 同一缺陷的证明。
- 检索华为开发者论坛的 UiTest/inputText“丢字”“输入不全”，未找到可核对、直接匹配本机
  版本与 xterm 场景的报告。此负结果不表示平台没有问题。
- [Playwright 官方输入说明](https://playwright.dev/docs/input) 区分字段填充与逐键事件。这支持
  按事件链选择诊断方法，不支持直接把另一个平台的注入方式替换为鸿蒙验收结论。

新增能力仅由 debug acceptance source transform 注入，正式源码不包含入口，包扫描拒绝探针
标记。`__acceptance_input_probe` 建立不连接服务器的一次性 PASSWORD_INPUT 状态，实际输入仍走
Web/xterm→Bridge→生产 `handleBufferedInput`；只比较公开合成向量，不处理真实凭据。Web 探针
保存按事件类型统计的计数，不保存 key、event.data、textarea 内容或内容哈希；Native 只记录
收到长度、缓冲长度和与公开向量的相等性。100 ms 清理和遮罩不改，300 ms 聚合报告仅用于
诊断，不能作为认证提交门禁。输入向量不发送 Enter，最后取消输入并关闭已确认 ID 的临时 Tab。

签名 HAP 为 `398badc0df94ea1f0959bc19fcd04504e21ac805ed074e7d3b8383786fbea073`，native
库未改。`masked-input-probe-software-20260905.json` 的 policy/tooling/web/arkts 通过；收集器
测试覆盖 DOM 与 onData 独立计数、DEL/控制分类、不输出内容、下一提示重置及取消观察计时器。

两次最小真机诊断保留在 `build/verification/masked-input-boundary-20260905-r1` 和 `r2`：

- 每次第一组普通输入与 masked 输入均为 32 字符且逐字相等。masked 的 DOM printable keydown
  为 32、keyCode 229 为 22、input 事件及其字符数为 22、composition 事件为 0；xterm onData
  可打印字符为 32、DEL/其他控制为 0，Native 缓冲为 32。隐私清理执行一次，确实清空了非空
  textarea；最终 textarea 长度为 0，Native 缓冲仍完整。这里证明本机实际经过 229 差分路径，
  但不证明它导致了 r8 的丢字，也不能排除低概率时序问题。
- r1 在下一组诊断准备期间被输入前目标检查拒绝；r2 明确在第二次 fixture-start 被输入后
  目标检查拒绝。两次均未执行分段向量，均终止并确认临时 Tab 删除、屏幕策略恢复。没有切网、
  没有提交测试向量或认证重试。r1 原 JSON 的 `not-reproduced-in-controlled-probe` 仅对应已完成
  子样本，整体仍是 failed；工具已将未完成对照分类改为 `incomplete-boundary-probe`。

**重设诊断范围：** 两次失败都在重复建立诊断入口的控制链，而不是已完成的第一段 masked
输入。原目标是定位认证字节差异，不是完成分段循环。保留焦点保护，不修改未证实有错的产品
输入逻辑；停止重复启动诊断入口。下一次最小证据改用现有 SSH `password-success` 单项，在
同一探针 HAP 上比较真实一次性认证与 Web 聚合计数。只执行一次；若未复现，记录未复现，
不以增加样本或 Wi-Fi 综合重跑代替根因。输入目标变化作为独立控制问题保留，不在本轮叠加修复。

单项真实认证已执行：`build/verification/ssh-password-input-boundary-20260905-r1/device-ssh-auth.json`，
attempt `4ee26b75c2fd45f9b3388862e3016717`，总计 66009 ms；`password-success` 为 34448 ms，
passed。fixture 实际密码匹配后建立 SSH Session，并完成关闭及 known-host、reverse mapping、
fixture process 清理。此命令未选择 Preferences 前后 digest，不宣称已做该检查。成功路径没有
保留 Web 聚合计数，fixture 的原始临时日志也随正常清理删除，因此这份结果只证明一次真实密码
认证成功，不能补写浏览器→服务端的计数对照，更不能宣称 r8 已修复。

本轮至此停止真机执行，未改产品输入语义、未升级 xterm、未重跑 Wi-Fi。诊断脚本已收窄为一次
普通/一次 masked 对照，移除分段与重复入口循环，保留失败时的部分样本和清理结果；这个脚本
收窄发生在上述真机运行之后，不把旧报告改写为新脚本整体通过。下次应先补齐失败时匿名目标
差异与成功认证的内容无关计数留存，不能再拿另一轮综合测试尝试替代缺失观察。

### 8.14 输入失败与认证结果的安全留存（2026-09-05）

本轮只修补 §8.13 的两处观测缺口，不修未定位的密码丢字。预期是清理后仍能解释目标检查
为何拒绝，以及一次认证在 Web 与服务端分别观测到什么。最后正确边界是检查时的两个布局、
提交前的应用日志及 fixture 的实际密码比较；首个错误边界是工具只保留错误文字或成功状态，
随后删除临时证据。状态所有者分别是单次 UiTest 操作、`Submit-AuthValue` 和 fixture 的密码
比较。待验证假设是白名单快照能跨异常和清理保留证据，无需放宽焦点保护或改产品输入语义。

开始时重新调研“如何跨异常/清理保留安全证据，以及树路径是否能证明稳定身份”：

- [.NET Exception.Data](https://learn.microsoft.com/en-us/dotnet/fundamentals/runtime-libraries/system-exception-data)
  可携带附加信息，但所有上层处理器均可读取或修改，不是保密容器。因此在抛错处只构造白名单，
  不把布局或凭据先放入异常后再脱敏。
- [Playwright TestInfo.attach](https://playwright.dev/docs/api/class-testinfo) 在报告接管附件后允许
  清理原文件。这里仅借鉴“先留存、后清理”的责任顺序，不引入依赖，也不推导鸿蒙输入保证。
- 重新查阅 [OpenHarmony UiTest 指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)
  和 [UiTest 版本记录](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)，
  未找到可把跨布局 hierarchy 当作永久身份的保证。master 不等于测试机 UiTest 6.0.2.3，
  本轮只比较同一次操作，不改变现有目标判定。
- 复查 [xterm #6078](https://github.com/xtermjs/xterm.js/issues/6078)：它仍只是 6.1 beta 的相关
  输入问题，不能证明本机 6.0.0/ArkWeb 有同一缺陷。检索华为论坛 dumpLayout、accessibilityId
  和 hierarchy，未找到直接对应本机版本的可核对报告；输入丢字的实际归属仍未知。

目标拒绝证据包含 before/after、获焦数量、属性存在性/相等性、移除 ROOT 标识的数字树路径，
以及根标识是否相同。最多保留四个获焦候选并显式标记截断；缺少/非法路径记为未知。不保留
text、hint 内容、原始 ID、布局或内容哈希；普通命令、masked 探针和 SSH 认证报告接收同一异常
元数据。零/多目标及目标变化仍失败关闭，不增加输入或 Enter 重试。

认证 Web 计数复用原有提交前隐私审计的日志读取，不增加等待或提交门禁。报告明确它是进程
日志中最新的、未等待稳定的聚合快照，不是逐 Pane 的收据；没有计数是 missing，不是零或通过。
提交前抛错时最多补读一次，不让观测失败覆盖原错误。fixture 在成功和失败清理前都提取固定
枚举及数值；matched 证明实际凭据相等，但日志没有收到长度时保留 null，不倒推数值。不按
数组下标把多提示/多 Pane 的 Web 快照与服务端事件配对。

本地测试先确认旧实现缺少异常元数据和认证留存函数会失败，再验证输入前后拒绝、零/多目标、
非法路径、原始内容不落盘、成功/失败留存、清理后结果保留、缺失日志和不发送额外 Enter。

本轮验证结果：

- `test-regression.ps1 -Group policy,tooling` 首次在沙箱执行，工具组内 WSL analyzer 因
  `Wsl/Service/CreateInstance/E_ACCESSDENIED` 中断；改为桌面用户上下文后全部通过，未为此
  改代码或系统配置。通过报告为 `input-evidence-retention-software-desktop-20260905.json`。
- 独立设备预检通过，记录于 `input-evidence-retention-preflight-20260905.json`。随后只执行
  `verify-ssh-auth-pc.ps1 -Only password-success -DiagnosticHap`，复用 §8.13 的 `398badc0…6fbea073`
  签名 HAP，没有重建、切网或追加物理场景。
- `ssh-password-evidence-retention-20260905-r1/device-ssh-auth.json`，attempt
  `06d63ec8d5404b70b861c999c7a5c8ef`，80540 ms，密码认证阶段 35664 ms，业务通过。唯一密码
  提交期望 32 单元，留存的 printable keydown、229、input 事件/单元、xterm printable 均为 32，
  composition/删除/其他输入为 0；非空 textarea 清理一次后为 0。fixture 独立记录
  `Password/matched`，实际凭据相等；收到长度为 null，未从成功状态虚构字节统计。
- 清理中的普通命令首次为 30/31 字符，首个差异位置 14。原有 native 精确校验在 Enter 前
  拦截，保持同一目标，第二次输入准确后只提交一次。因此报告是 `businessVerdict=passed`、
  `harnessStability=flaky-harness`，不是稳定通过。三个普通命令共四次输入，一次不匹配。
  known-host 移除、reverse mapping、fixture process、临时目录和屏幕策略清理通过。未选择
  Preferences digest，不宣称验证了偏好未变；没有构建或提升正式候选。

留存缺口已获得本地正反例及真实成功报告证据；目标拒绝的匿名结构本轮只有本地负例，没有
新真机失败样本。原始 31/32 密码丢字仍未修复。普通命令的 30/31 是新的、更安全的定位入口，
说明不应继续把密码遮罩当作唯一候选原因，但它本身也不能区分 UiTest、ArkWeb 或 xterm。
本轮停止真机执行。下一步先在公开普通向量上检查 UiTest→ArkWeb→xterm→Native 的共同输入
链，优先用本地可控时序区分 229 延迟差分与注入交付；没有可证伪假设前不改产品、不再认证
抽样或切网。实际待办仅维护于 Next Work。

### 8.15 普通输入的可控事件顺序实验（2026-09-05）

本轮在实际打包的 xterm 6.0.0 上稳定构造了丢字和重复输入，尚未证明它就是 §8.14 真机
30/31 的原因。原始失败缺少 DOM 事件顺序，不能用相同长度差异认定根因相同。

调研问题是“UiTest 如何交付短 ASCII，以及 xterm 的 229 回退能否在完整 DOM 输入下丢字”：

- [UiTest CLI](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/input/ui_input.cpp)
  的定点输入先点击，再等待 500 ms，随后调用 Driver；
  [UiDriver](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/core/ui_driver.cpp)
  将可映射的短 ASCII 转为逐键 DOWN/UP，每次 DOWN 带 50 ms 保持时间；
  [系统注入层](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/server/system_ui_controller.cpp)
  顺序提交这些事件，没有应用收到完整文本的 ACK。这是当前公开 master，不是测试机
  UiTest 6.0.2.3 的二进制溯源；不能断言系统提交顺序等于 ArkWeb DOM 交付顺序。
- [xterm #5887](https://github.com/xtermjs/xterm.js/issues/5887) 报告 6.0.0 的 input-before-keydown
  与 229 组合会丢字；[#6045](https://github.com/xtermjs/xterm.js/issues/6045) 提供可控的丢字/
  重复时序。报告来自 macOS/WebKit 等环境，不是 HarmonyOS 复现。它们比此前 #6078 的长字段
  重放更贴近本轮问题，但仍只是待验证的设备机制。
- [PR #6009](https://github.com/xtermjs/xterm.js/pull/6009) 查询时仍为 Open；其描述同时涉及
  输入门禁与延迟发送，不能把“提前重置一个标志”当作已合并修复。本轮没有采用该 PR，也没有
  声称完整评审了它的实现。
- 检索华为论坛 `inputText` 丢字、`uitest` 输入不完整，没有找到对应版本的可核对报告。
  [Playwright 的逐键输入说明](https://playwright.dev/docs/api/class-locator#locator-press-sequentially)
  仅帮助区分 DOM 事件链和字段赋值，不提供鸿蒙的交付保证。

实验前的可证伪假设：完整 DOM 插入也可能在 xterm 的 `_keyDownSeen` 门禁与延迟 textarea
差分之间丢失。公开向量的 DOM 插入是本实验最后正确边界，`onData` 是第一待检查边界；
门禁由 CoreBrowserTerminal 持有，延迟快照由 CompositionHelper 持有，100 ms 隐私清理由
LeanTTY 的 `scheduleSecureInputClear` 持有。后者只在 masked 状态启用，普通输入失败不以它
为必要条件。实验不修改 Bridge、Native、输入注入或生产清理策略。

复现脚本与结果保留在 `build/verification/xterm-input-order-20260905/diagnose.mjs`、`result.json`。
运行命令：`node build/verification/xterm-input-order-20260905/diagnose.mjs`。它校验完整
xterm SHA-256 `98d0973151aff2991d335b1adbbdac2e14da26341abe329d677d4c0034402bdf`，并确认与
已安装的 6.0.0 npm 产物只差构建时删除的 source-map 尾注。VM 中只额外暴露既有构造器，调用
真实 `_keyDown`、`_keyUp`、`_inputEvent` 和 CompositionHelper；渲染/焦点用空实现，计时器
使用虚拟时间。masked 对照执行从 `terminal.html` 提取的原始清理函数。

这是 L1 方法级时序实验，不是浏览器原生事件投递或真机证据。全部向量公开，不连接服务器。
六种时序分别运行普通/masked 两种状态，共十二项，结果如下；普通与 masked 在这些时序下相同：

| 可控时序 | `onData` 结果 | 结论 |
| --- | --- | --- |
| 两字符分别完成；keydown 在 input 前或后 | `jk` | 对照完整 |
| 两字符重叠，最后才运行差分计时器 | `jk` | 两条路径恰好补偿，不能推论稳定 |
| 前一 keyup 已到、后一 input 已到，差分计时器才执行 | `jkk` | 重复一个字符 |
| 前一差分已执行、keyup 未到，后一 input 先到 | `j` | 第二字符丢失 |
| 31 字符公开向量，只在索引 13/14 构造上述交错 | 30 字符，首差异索引 14 | 可构造与真机同量级差异，但不是同因证明 |

机制已在这个局部模型中解释清楚：前一 keydown 使 `_keyDownSeen=true`，后一 composed input
可能被拒绝；若 229 差分快照在该字符插入之后才取得，计时器看到的值不变，也不会补发。
另一种时序下 input 已经发出字符，旧快照的差分又发一次。额外的三个反例只在 VM 中暂时
放宽输入门禁：一个丢字用例恢复为 `jk`，另两项却变成 `jkk` 和 `jjkk`。这否定了 gate-only
修补，不是生产修复。实验断言验证这些已知特征，脚本退出成功不表示输入完整性通过。

本轮没有新 HAP、设备操作、认证、Wi-Fi 或产品修复。原 HAP 仍为 `398badc0…6fbea073`。
下一步只需要一次公开普通向量的真实事件顺序，区分“DOM 本身少字符”与“DOM 完整、xterm
少发/重复”；若 DOM/xterm 均完整而 Native 不完整，才转向 Bridge。采集必须按 Pane 隔离、
限定事件数和生命周期，只记录事件类型、相对时间、229 分类、composed/isComposing 与长度，
禁止 key/data/textarea 内容或哈希，不提交向量。没有坏样本或结果受采集扰动时应保留证据
不足并停止，不追加认证抽样或凭此修改 xterm。

### 8.16 普通输入事件顺序探针（2026-09-05，单次执行后停止）

本轮只检验 §8.15 的时序假设，不修输入：公开 31 字符应完整到达 Native；已知正确边界是
工具提交的向量，已知错误边界是此前 Native 30/31，中间 DOM/xterm 仍未知。DOM 由 ArkWeb
交付，xterm 持有门禁与差分状态，Bridge 负责传输，Session 持有命令缓冲。

本轮重新查询 [UiTest 源码](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/input/ui_input.cpp)
及 [xterm #6045](https://github.com/xtermjs/xterm.js/issues/6045)，没有新增鸿蒙同因证明。
[DOM 派发规范](https://dom.spec.whatwg.org/#dispatching-events) 支持在祖先 capture listener
观察目标监听器之前的事件；不能把 xterm 注册后的同目标 listener 当成前置观察点。
[UI Events](https://w3c.github.io/uievents/#event-type-beforeinput) 区分更新前 beforeinput、更新后
input；composed 与 isComposing 分别记录。[Playwright 初始化脚本](https://playwright.dev/docs/api/class-page#page-add-init-script)
是提前布置观察点的参照，不是 ArkWeb 投递保证。华为社区 ArkWeb/input/keydown 检索未找到
匹配 UiTest 6.0.2.3 的可核对报告。公开 OH master 仍不等同该二进制；目标系统版本以本轮报告为准。

实现边界：只在测试源码转换中注入；显式一次性 arm、每 Web/Pane 独立、最多 256 行/20 秒；
仅保存数字枚举、相对时间及长度。先在内存采集，停止后分块发送；模式切换、页面离开、重放
终止采集，当前 Surface/Bridge/token 校验拒绝晚到报告。本地验证隔离、脱敏、截断、停用和
转换恢复后，构建一次探针 HAP，执行一次普通向量，不提交向量、不连接服务器、不切网。
轨迹不完整、出现采集扰动或未复现坏样本均停止，不追加轮数。

本地检查覆盖默认停用、数字白名单、256 行截断、20 秒截止（含计时器延迟）、模式/重放/
页面销毁停用、独立 Pane、旧 Bridge/token 拒绝、缺块/重复/乱序拒绝，以及测试转换后的
源码恢复。`test-regression.ps1 -Group policy,tooling,web,arkts` 通过，证据为
`build/verification/input-order-software-20260905.json`；随后补充空 Surface 停用检查和诊断
临时布局清理，Node 采集器及 PowerShell helper 检查再次通过。无 Rust 或 xterm 修改。

`preflight-device.ps1` 通过；`dev-pc.ps1 -NoLaunch -RequireUsb` 完成 ARM64 debug 构建、测试
签名和安装，构建日志在 `build/verification/input-order-build-20260905/`。探针 HAP SHA-256：
`1b3929c6d98e810f95c828781511a8c134b58ca3253895afd2df7cd05b7ea547`；Native 仍为
`db31bc05d9279ed3ac856236bc4165f7ccb63812a2b8db8e0d8f898346547e66`。
直接检查 HAP 中的 `terminal.html` 确认采集器、capture 安装及截止计时器已打包；源目录已恢复，
不含新增探针标记。本轮没有生产包构建，不能把标记策略和转换测试当成生产包物理验收。

唯一真机命令为 `diagnose-text-input-pc.ps1 -Scenario input-order -HapPath <上述 signed HAP>
-EvidenceDirectory build/verification/input-order-pc-20260905-r1`。目标仍为 ARM64 HarmonyOS PC，
系统 `6.1.0.135(SP60C00E100R13P3log)`、UiTest `6.0.2.3`。报告
`input-order-pc-20260905-r1/text-input-diagnostic.json` 保留完整轨迹和候选身份，耗时 42577 ms：

- 公开向量 `0123456789abcdefghijklmnopqrstu` 注入一次；仅启动探针的命令使用 Enter，向量
  未提交，无密码、连接或网络切换。
- 20 秒窗口正常结束，156 行分成 10 块，序号和相对时间连续有效；事件位于 arm 后
  4604.3–6302.8 ms。`onData` 为 31 个 printable unit，0 delete/other；Native 为 31 且逐字一致。
- 前 10 组都是 `keydown(other) → onData → keyup(other)`；后 21 组都是
  `keydown(229) → beforeinput → input → keyup(229) → onData → keyup(other)`。
  beforeinput/input 各 21，均 composed=true、isComposing=false；没有 input-before-keydown
  或跨字符差分补发的坏样本。长度不能证明内容相等，DOM/xterm 报告仍保留
  `contentEqualityObserved=false`，只有 Native 对公开向量做了逐字比较。
- 临时 Tab 按确切 ID 关闭、输入经 Ctrl+C 清空、息屏策略恢复；临时布局已删除，报告保留。
  本轮启动、普通输入和关闭构成探针的最小主路径验证，不是正式产品验收。

结论为 `not-reproduced-in-single-input-order-probe`。本轮修正了一个诊断假设：并非每个有效
字符都产生 input，单独比较 input 数量与向量长度会误判。轨迹没有显示输入被探针破坏，但
一次成功样本不能排除观测改变时序，也不能解释原始 31/32 或 30/31。按停止条件结束输入
分支，不加试、不修 xterm、不启动 Wi-Fi；后续工作顺序见唯一工作表 `next-work.md`。

收口复核 `input-order-final-software-20260905.json` 的 policy/tooling/web/arkts 全部通过；
报告中的 HAP 哈希与当前签名包再次比对一致。该复核不再操作设备，不增加真机样本。

### 8.17 runtime-reclaim 正式场景注册（2026-09-05，开发验证完成）

目标是让进程内 Session 状态丢失后的安全恢复可重复验收，不证明系统 GC 会丢弃存活对象。
现有触发器只断开测试 Pane 的 ArkTS Session 引用，保留 native Session，由下一次正常输入
触发生产恢复。缺口在正式列表和独立结果：原报告没有保留工作区身份、首字符后的本地缓冲
长度及 native 取消数量；“看到恢复提示”不能替代这些断言。所有者仍是 AppViewModel 的
Tab/Pane 布局、SessionViewModel 的输入/连接状态和 native Session registry，不改产品恢复逻辑。

本轮重新调研的结论与限制：

- [华为 ArkTS 内存说明](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-overview-of-arkts-memory-leaks-overview)
  （更新于 2026-09-03）说明 GC 基于可达性，VMRoot/Native 强引用会保留对象。因此本场景只能
  称为受控状态丢失注入，不能包装成系统低内存或物理合盖的真实复现。
- [OpenHarmony appRecovery API](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-ability-kit/js-apis-app-ability-appRecovery.md)
  的 restartApp 重启进程，保存/恢复是独立 API；它不能替代需要相同 PID/start time 的此项测试。
  文档涵盖 API 9/10 起的恢复能力，公开 master 不等同测试机 API 24 的二进制溯源。
- 查询 OpenHarmony 上游及华为社区，没有找到能证明此机型“合盖必定丢失同进程 Session graph”
  的可核对报告。[社区后台任务提问](https://developer.huawei.com/consumer/cn/forum/topic/0204223283983774003)
  只有可检索的问题，答复正文未能取得，不能用它支持协议或生命周期保证。
- [Android ActivityScenario.recreate](https://developer.android.com/reference/androidx/test/core/app/ActivityScenario#recreate())
  是有界生命周期驱动的参照，但只控制 Activity 重建，不代表进程死亡，更不代表鸿蒙行为。

计划复用既有 runtime-reclaim 入口，在测试转换内增加内容无关的工作区相等性和本地缓冲长度
观察；正式场景列表共用一处定义，矩阵消费结构化逐项结果，缺失即失败。用本地反例覆盖
PID 重用、缺字段、首字符泄漏、工作区变化、零 native 取消和 server/PTY 残留。之后只跑一次
开发 HAP 的该场景；SSH bootstrap 是建立待回收 Session 的必要前置，不做认证抽样或 Wi-Fi。
若前置输入失败则保留证据并停止，不返回已关闭的丢字诊断循环。正式候选执行和真实合盖留到
发布阶段；本轮不创建正式候选，不运行完整矩阵。

实现已将 runtime-reclaim 放在 compatibility 之后、网络扰动和人工动作之前。共享列表同时
控制单项正式准入、矩阵顺序和 resume 身份；旧七项报告不能恢复成新八项矩阵。测试专用转换
在实际 AppViewModel 上比较有序 Tab/Pane ID 和活动项，在 SessionViewModel 上读取首字符后
的本地缓冲长度；只记录布尔值和计数，不记录工作区内容。正式报告消费独立 contract v1，
要求同 PID/start time、输入拦截、空缓冲、相同工作区、非零 native 取消、server/PTY 消失，
以及精确提交 help 后在终端搜索到其输出。生产包扫描新增八个触发器/观察器符号。

本地 `test-mosh-runtime-contract.ps1` 直接调用实际观察解析器和矩阵证据读取器，覆盖有效结果、
缺失/重复/畸形日志、缺字段或错误类型、PID 重用、非空输入、工作区变化、零取消、残留进程，
以及八类测试符号混入 HAP 时的拒绝。首次测试因 PowerShell 数组内未加括号的字符串拼接
产生错误样本；最小表达式确认这是测试构造边界错误，补括号后通过，没有放宽断言。
`runtime-reclaim-software-20260905.json` 的 policy/tooling/arkts 全部通过；源码转换和字节级
恢复检查也通过。`runtime-reclaim-preflight-20260905.json` 证明 HDC/UiTest 控制通道可用。

`dev-pc.ps1 -NoLaunch -RequireUsb` 完成 ARM64 debug 构建、测试签名和安装，日志保存在
`build/verification/runtime-reclaim-build-20260905/`。HAP SHA-256 为
`b432d60862a83beb9e479115add96b043037dde3636c6f3f26fe83a3830e5963`，native 保持
`db31bc05d9279ed3ac856236bc4165f7ccb63812a2b8db8e0d8f898346547e66`。
新观察器仅存在于开发包；构建后生产源码已恢复。本轮没有构建生产包，不以负例包扫描
替代正式 production/review 包验证。

唯一真机执行为 `verify-mosh-pc.ps1 -Scenario runtime-reclaim -HapPath <上述 signed HAP>
-EvidenceDirectory build/verification/runtime-reclaim-formal-contract-20260905-r1`。报告
`device-mosh.json` 为 passed，耗时 179153 ms，`acceptanceEligible=false`。单一活动 Mosh Pane
完成远端基线后注入状态丢失；PID/start time 前后一致，工作区身份相同，本地输入缓冲 0，
native 取消请求 1，stock server/PTY 均退出；恢复警告和 help 输出可检索，旧远端命令不可检索。
这是安全回到本地工作区，不是恢复原远端 Session 或证明其他 Pane 并发场景。

普通命令 10 次、10 次输入、0 mismatch、10 次 Enter，远端基线命令 1 次且服务端输入逐字
相等；本报告的 harnessStability=stable 不推翻已记录的间歇丢字问题。fixture、临时 HDC
反向映射和临时目录清理通过，持久网络未改变，Preferences 不变，secret/bootstrap 审计通过。
HAP 哈希与报告再次核对一致，独立 runtime contract validator 对实际报告通过。本轮无模型
测试请求，不切网、不合盖、不加试、不改 mosh-client-rs；输入/Wi-Fi 分支仍按原停止条件暂停。

收口时补充矩阵反例，要求恢复警告、旧远端内容缺席和 Session 未重建也必须是明确通过，
不只相信报告标题。此变更只收紧离线证据消费，没有改变已测 HAP 或触发链，不增加真机样本。
开发阶段该项已完成；正式 exact candidate 和一次真实合盖仍留在 `next-work.md` 第 4 阶段，
下一独立工作为 release-mode review HAP 正常产品路径 smoke。

最终 `runtime-reclaim-final-software-20260905.json` 的 policy/tooling/arkts 全部通过，包含收紧后
的矩阵反例和 `git diff --check`；没有追加构建或真机执行。

### 8.18 release-mode review HAP 独立 smoke（2026-09-05）

本项只解决包用途准入和正常产品路径 smoke，不重新进入间歇输入丢字或 Wi-Fi 综合诊断。
问题是“如何证明裁剪验收入口的 review 包仍能正常使用，并在安装前阻止包角色误用”。
研究日为 2026-09-05；设备为 HAD-W32 ARM64，系统
`HAD-W24 6.1.0.135(SP60C00E100R13P3log)`、API 24、UiTest 6.0.2.3。

**外部依据与边界：**

- 华为[安装与更新一致性校验](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/install-and-update-consistency-verification)
  区分 Profile 的 debug/release 类型；[构建模式说明](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hvigor-compilation-options-customizing-sample)
  和[打包工具](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/packing-tool)
  说明 buildMode 与包内 debug 属性。签名用途不能从文件名或是否可调试推断。
- [OpenHarmony hapsigner](https://github.com/openharmony/developtools_hapsigner)
  提供 verify-app。使用本机 SDK 验证实际 HAP，再读取其签名 Profile；没有自写签名协议或
  把本地文件名当作信任依据。首次只读探测误用了 `.pem` 输出，被 SDK 拒绝；沿现有构建
  路径改用 `.cer` 后通过，临时证书/Profile 均清除，准入工具不输出这些内容。
- [Android UI Automator](https://developer.android.com/training/testing/other-components/ui-automator)
  的黑盒 UI 测试是方法参照，不是 HarmonyOS 保证。[OpenHarmony IBCMVR](https://gitee.com/openharmony/testfwk_arkxtest/issues/IBCMVR)
  是 dumpLayout 能力增强需求，不能证明本机导出全部无障碍标签。检索 Huawei 社区未找到
  与本机“标签 accessibilityText 未导出”完全匹配的可靠案例；以下字段结论来自当前 PC。

`device-package.ps1` 分别检查签名 Profile、module/bundle/ARM64、`app.debug` 和验收符号。
所有现有 HDC install 入口接入此门：生产或未知 Profile 即使改名也拒绝，APP 扩展名拒绝；
review smoke 要求 release-mode 且无验收入口，marker 场景要求 debug-mode 且具有 native
输入观察/提交能力。`dev-pc` 默认选择后者。保留 `Assert-LeanTTYDeviceTestHapPath` 作为
早期文件名过滤，但它不再代表完整安装准入。SDK 是签名真实性的唯一校验实现。

**L0/L1：** 合成 ZIP 的正反例覆盖 release review、debug acceptance、两类错用、残留符号、
非布尔或缺失 debug、错误 bundle、改名的 production/unknown Profile、签名校验失败和 APP。
只 stub SDK 签名边界，其余 ZIP 解析/准入实际执行；未制造生产签名或安装生产包。
smoke 契约覆盖重复标题、空 accessibilityText、唯一节点身份、持久化活动位置、隐藏 Tab
过滤、歧义拒绝、禁止验收输入/日志 helper，以及现有安装入口的准入连接。

**L2：** `build-all.ps1 -BuildMode release -Offline -NoDaemon` 使用现有本地测试签名完成构建；
没有 `-Metadata`、正式独立 checkout 或 retained candidate。新 native SHA-256 为
`d9a7148098b6ca523ffd4663e7cd967919d542b8bc6f1ed490272d5c2a13c3a0`，包含
`mosh-client` 0.1.0 / `v0.1.0`，lock 对应 `aed5865c1d779a989a3b0cf0c84aa046313515ee`。
实际 HAP 的 Profile=debug、app.debug=false、验收符号扫描通过；把该实际 HAP 交给 acceptance
准入，在设备访问前被拒绝。HAP SHA-256 为
`8eecd666b09be07db693dcabe363266164cf11c6a21984bc7dbaa0bf0f506266`。

**L3 与失败保留：** 证据根为 `build/verification/review-smoke-20260905/`。
`run-r1/review-smoke.json` 在 12310 ms 后报告 harness failed：安装启动已通过，但工具错误地
假设标签有导出的活动文本、标题唯一。没有创建 Tab 或发送产品快捷键，清理 not-needed。
只读核对发现三个 Tab 标题均为 `ltty`，`text/originalText` 为空，`accessibilityId` 各异；
workspace Preferences 的实际字段为 `string key="record"`。原方案中的标题唯一性不是产品合同。
据此改为本轮 UI 节点身份，活动位置来自已存在的 workspace-only 持久记录；不增加产品测试
入口。合成反例还拦住了 PowerShell 混用 `-and/-or` 的优先级错误，显式括号修正后通过。

一次只读契约核对通过后，`run-r2/review-smoke.json` 关联 r1 attempt，25830 ms 全部通过：
安装/启动 4423 ms、新建 Tab 2811 ms、键盘分 Pane 2736 ms、键盘关 Pane 2918 ms、清理
7109 ms。临时 Tab 经自身 UI 关闭，原 Tab 节点及活动位置恢复，持久化 workspace 与 Settings
摘要一致，屏幕超时租约恢复；不保留成功布局正文。本轮普通命令提交 0、输入重试 0、模型
测试请求 0，不切网、不读取 SSH 凭据。首轮失败不因后轮通过而改写。

本项是开发证据，`acceptanceEligible=false`。当前测试机安装此 release-mode 测试包；后续
marker 场景必须正常重建 debug 测试包，不能拿本轮 review HAP 或旧 client 的备份冒充。
旧 debug HAP 只备份在同一证据目录的 `previous-debug-test-signed.hap`，不作为 0.1.0 验收。
没有更改产品代码、创建正式候选、发布或提交 PR；下一项为离线指南浏览器审查工具。

最终 `review-smoke-final-software-20260905.json` 的 policy/tooling 和 `git diff --check` 通过。
独立复核 r2 的七个 stage、资源移除和 cleanup 全部 passed；HAP 及报告列出的六个 harness
文件哈希与当前文件一致。收口没有增加第三次真机执行。

### 8.19 输入归因：UiTest / 真实键盘与普通 textarea / xterm（2026-09-05）

维护者报告日常手动使用基本没有丢字，并授权一次分层对照。问题不是证明某一方有错，
而是区分系统输入、xterm 事件协调与 LeanTTY 缓冲边界。旧坏样本仍缺逐层轨迹。
新增本地模型证明：即使 keydown 在前，229 延迟差分先于文本插入执行，也可能漏发字符；
这只是虚拟计时器下的可复现机制，不是 ArkWeb 的物理因果证据。

当天重新检查了 [UiDriver 源码](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/core/ui_driver.cpp)、
[xterm 6.0.0 CompositionHelper](https://github.com/xtermjs/xterm.js/blob/6.0.0/src/browser/input/CompositionHelper.ts)、
[#6045](https://github.com/xtermjs/xterm.js/issues/6045) 和
[Playwright 输入语义](https://playwright.dev/docs/input)。公开 UiTest master 不等于测试机
6.0.2.3 二进制；上游 WebView 报告不是 HarmonyOS 归因，Playwright 只提供对照方法。
Huawei 官方/社区检索未找到匹配 HAD-W32 丢字的已确认报告，不能据此推导没有平台问题。

**观察器和范围：** 复用测试包转换、按 Pane/token 隔离的通道和现有精确提交 helper。
`input-attribution` 每个文档只允许一次启动，最多 256 行；自动组 20 秒，人工组 60 秒。
记录 DOM 事件、xterm 原版差分安排/执行和 onData 的数字元数据；公开向量只在内存比较。
包装器不改变回调延迟、参数、次数或输入决策；停止后恢复原方法、移除临时框和监听。
包装和观测仍可能扰动时序，所以成功样本不等于无故障保证。生产源码不包含这些入口。

**准备失败没有隐藏：**

- `input-attribution-pc-20260905-r1/uitest-plain` 的坐标点击经过 Pane→Bridge focus 后重新
  聚焦 xterm。临时普通框缺少测试专用焦点所有权，输入后目标保护停止；该对照无效。
  原轮未保留延迟轨迹，临时 Tab 清理失败，顶层 `cleanup=passed` 只代表屏幕超时恢复。
  随后独立核对工作区，把本轮最后新增 Tab 移除，保留原三个 Tab 的 2/2/1 Pane 结构；
  `cleanup-result.json` 记录恢复，不改写失败。测试转换随后只为已启动的普通框保留 focus，
  不改变正常终端行为；本地正反例通过后才进入修正版。
- `r2/manual-plain` 在探针启动命令阶段出现 expected 40 / actual 41、首个差异 index 0。
  维护者明确确认准备期间按过键，因此该轮是人工干扰样本，不是工具重字证据。精确门
  在 Enter 前拦截，向量尚未输入，清理通过。旧报告的 `enterInjected=true` 是按场景推算的
  字段，并非实际提交；本轮工具收尾改为保留 arming observation 并读真实 Enter 次数。
  重新进入只改变协作前提：准备阶段不按键，收到 READY 后才输入，没有修输入代码。

**四个有效样本：** 设备 HAD-W32、系统 6.1.0.135、API 24、UiTest 6.0.2.3；同一测试签名
debug HAP SHA-256 为 `907783234d9b5a97d94f437b1b1289de749ec5faab32b24243a96264ac2fbe73`。
native 复用含 mosh-client 0.1.0 的 `d9a71480…13c3a0`；未升级 xterm 6.0.0 或修改其输入规则。
证据在 `build/verification/input-attribution-pc-20260905-r2/`，每格只有一个有效样本：

| 目录 / 输入方式 | 表面 | 直接结果 | 轨迹行数 | 全程耗时 |
| --- | --- | --- | --- | --- |
| `uitest-plain` | 普通 textarea | DOM 输入及最终值 31/31 exact | 146 | 39946 ms |
| `uitest-xterm` | xterm | onData 31/31；Native 31/31 exact | 220 | 39949 ms |
| `manual-plain-clean` | 普通 textarea | DOM 输入及最终值 31/31 exact | 146 | 80884 ms |
| `manual-xterm` | xterm | onData 31/31；Native 31/31 exact | 220 | 79966 ms |

真实键盘由维护者输入，工具未代输；不存在独立硬件按键计数，不能声称测试了任意手速。
四组均有 21 次 keydown 229。普通框的 31 个字符都产生 input；xterm 的 10 个数字直接
产生 onData，21 个字母经 input/延迟差分。两组 xterm 均有 21 次完整的差分安排/执行，
回调全部在 input 之后，执行时 textarea 均已变化；未观察到本地模型的“回调先于插入”。
自动组安排至回调为 1.6–3.1 ms，人工组为 2.2–5.6 ms；这是各 21 次观察，不是性能基准。

四组向量均未提交，没有认证、切网或模型请求；临时 Tab 和屏幕超时均清理。首轮临时框
失败和人工干扰样本保持无效，不能删除后只报成功率。测试机现在安装上述 debug HAP，
不再是 §8.18 的 release-mode review HAP。

**结论和停止条件：** 本轮没有复现原始丢字，不能归因 UiTest、输入法/ArkWeb、xterm 或
LeanTTY。真实键盘也走 229，否定“只有自动化才进入该路径”的解释；不能凭手动使用正常
就忽略兼容风险，也不能把方法级模型当作实际产品故障。保留原版 xterm，不追加抽样、认证
或 Wi-Fi 复跑。后续工作条件仍由 `next-work.md` 决定。

聚合命令为 `node build/verification/input-attribution-pc-20260905-r2/analyze.mjs`，输出
`summary.json`，独立核对同包身份、完整轨迹、原始回调配对和清理。工具收尾补齐 arming
观察、真实 Enter 字段、probe/timeout 清理区分及解析器负例；这些报告改动只有软件证据，
没有借此再跑真机或改写既有报告。

最终 `software-final-desktop.json` 的 policy/tooling/web 聚焦检查全部通过，包含新观察器、
解析器负例、转换恢复、包隔离及 `git diff --check`。此前两份软件报告分别保留负例数据
拼接的 PowerShell 括号错误，以及在 sandbox 身份调用桌面用户 WSL 的环境失败；前者
修正测试表达式，后者切回要求的桌面身份，没有修改产品。未运行 Rust/ArkTS 全量门、
正式候选矩阵、认证或网络场景，不把这份诊断记录升级成发布验收。

### 8.20 暂缓输入归因后的单次 Wi-Fi 收口（2026-09-05）

维护者明确要求暂缓输入问题、继续 Wi-Fi。`next-work.md` 已用该决策取代旧的输入先行顺序；
输入问题保持未解决。复用 §8.19 的 `90778323…c2fbe73` 测试签名 debug HAP，含 mosh-client
0.1.0，只执行一次 `wifi-network-switch`。没有重建、改产品/工具代码或重启完整矩阵。

证据目录为 `build/verification/mosh-wifi-network-switch-deferred-input-20260905-r1/`。
`device-mosh.json` 的 attempt 为 `f64fbffd1b354eada1042f40b3a14988`，关联 §8.12 的 r8；
全程 347788 ms，`result=passed`、`acceptanceEligible=false`。USB/UiTest 前置检查通过，
既有 TCP/UDP/Hyper-V 配置 ready；本轮使用桌面用户身份，没有申请管理员权限或修改持久规则。

**直接结果：**

- 在系统 Wi-Fi 面板选择已保存的备用网络；源 IPv4 和匹配端点的路由身份均改变，直连 SSH
  端口可达。报告仅保存状态和相对时间，不保存原始网络身份。
- Mosh 保持同一 Session 和远端 PTY，切网后受控新命令通过，没有自动关闭或错误，无需重连。
  本轮未观察到 Interrupted/Recovered 提示，不把本样本算作该告警转换的覆盖。
- SSH 对照断开，需要重连；重连后新命令及 Search 标记通过。报告中 64757 ms 的 Mosh
  恢复观察时长包含先做 SSH 对照的时间，不是 Mosh 实际恢复延迟。
- 两协议比较完成后关闭已退出的 SSH Pane，再关闭 Mosh。原页与恢复页均为
  `normal,144,36,15,3e2d3989f10ea16b`；原页隐藏/恢复、Mosh 页面丢弃及 Search 隔离通过。
  认证关闭握手通过，服务端退出观察为 101 ms；Preferences 和 secret 检查通过。
- 原 Wi-Fi 已恢复，临时 Host、known-host、fixture 进程、HDC reverse 和临时目录清理通过。
  清理后的独立 preflight 与网络 Status 仍通过，持久网络配置未改变。

**工具异常单独保留：** 普通命令记录 15 项、15 次输入尝试、14 次 Enter；清理已知主机项的
第一次输入为 29/30、差异位置 18，Enter 前拦截，第二次精确后才提交。两次远端命令共三次
输入尝试：基线有一次不匹配、差异位置 6，远端逐字校验拦截后重输成功；切网后命令首次精确。
这些计数只覆盖各自已观测的命令，不能当作所有交互的总输入计数。

恢复原网络后的首个清理命令在输入前失败，耗时 10800 ms，0 次输入、0 次 Enter；既有
`Remove-DeviceState` 的 app-relaunch 路径随后完成清理。报告没有保留该首错的具体异常，
不能进一步归因焦点或产品。最终为业务 `passed`、工具 `failed-harness`，不是稳定无重试。
不改写原失败、不修输入或追加切网；Wi-Fi 开发验证在此收口，正式候选前的工具稳定性仍未完成。

### 8.21 单字符、真实浏览器的候选机制复现（2026-09-05）

维护者要求在输入问题再次出现时构建必现最小集。§8.20 的重复不匹配证明问题仍存在，
但该轮只保留 Native/远端缓冲差异，没有失败时的 DOM/差分轨迹。本次目标是压缩可检验
机制，不从相似症状直接宣称根因，也不重新启动 Wi-Fi 或随机输入采样。

新入口为 `tools/web-terminal/input-order-repro.html`，操作说明见同目录 `input-order-repro.md`。
与 §8.15 的 Node VM 方法级模型不同，本轮使用实际 Chrome、DOM、未修改的浏览器定时器，
通过公开 textarea 事件和 `Terminal.onData` 验证；没有 LeanTTY、Bridge/native、认证、网络、
DOM stub 或私有方法替换。载入打包的 xterm 6.0.0，SHA-256 为
`98d0973151aff2991d335b1adbbdac2e14da26341abe329d677d4c0034402bdf`，运行器另核对上游资产
等价性。全部事件为合成事件，`isTrusted=false`，并非真实键盘或 UiTest 事件。

当天重新核对 UiTest 官方文档/源码、xterm #5887/#6045、Huawei 文档/社区和 Playwright
输入语义；问题、链接、适用版本和未解决差异记录在复现说明中。上游 macOS 报告为
input 在 keydown 前，而本轮候选是 keydown 在前、差分早于 input；不将二者直接等同。
未找到针对本测试机的已确认平台诊断。Python Playwright 不可用，复用已有 Node Playwright，
没有安装依赖。首次 `input-order-minimal-browser-20260905-r1` 缺少 Playwright 管理的浏览器，
在任何页面执行前停止并保留 invalid 结果；随后显式绑定本机已安装 Chrome，不改变测试假设。

`build/verification/input-order-minimal-browser-20260905-r2/result.json` 记录 Chrome
152.0.7977.76、源码哈希、十个独立页面和完整公开向量轨迹；浏览器执行约 7.5 秒。
同目录 `repro.png` 已目视核对。五种条件在各自新建的 surface 上执行：

| 条件 | DOM | onData / 普通框结果 | 十次结果 |
| --- | --- | --- | --- |
| 229 keydown，input 后才运行差分 | `a` | `a` | 10/10 正常 |
| 229 keydown，差分结束后才 input，最后 keyup | `a` | 空串 | 10/10 漏发 |
| 上一条件，但把 keyup 移到 input 前 | `a` | `a` | 10/10 正常 |
| 只有 input，无 keydown | `a` | `a` | 10/10 正常 |
| 普通 textarea，沿用延迟 input 顺序 | `a` | `a` | 10/10 正常 |

一个字符已经是非空载荷的下限。故障条件下，差分快照窗口先关闭；随后 composed input
被尚未复位的 `_keyDownSeen` 拦住，两条路径均未发出字符。对照移除任一关键条件即可恢复。
这证明真实浏览器中的候选机制，不证明 HarmonyOS 自然产生此顺序；四格真机成功样本中的
差分均在 input 后，仍缺原问题的坏轨迹。报告明确 `deviceCauseProven=false`、
`acceptanceEligible=false`；页面、terminal、浏览器已关闭，无设备状态或临时网络清理。

本次未改生产逻辑或验收输入保护；不把预期漏发加入正常产品通过门，不运行 Rust/ArkTS、
HAP 构建、真机或正式矩阵。后续需要真实失败轨迹才能做同因判断，主线不因该合成复现暂停。

### 8.22 DOM → xterm → Bridge → 应用缓冲的单次逐层取证（2026-09-06）

维护者要求分析链路各环节。预期是一次公开 ASCII 输入在各层保持顺序和数量；旧坏样本
只保留最终差异，最后正确边界和首个错误边界未知。UiTest 拥有注入，ArkWeb 拥有 DOM，
xterm 拥有输入差分/onData，Surface 与 SessionViewModel 拥有消息路由和本地命令缓冲。
源码确认 IDLE 输入进入 ArkTS CommandLine，不经过 Rust、SSH 或 Mosh。最小区分假设为：
真实丢字是否出现 §8.21 的“229 keydown 后差分先结束，input 才到达”，还是丢在更早/更晚层。

研究问题是 UiTest 的注入方式、xterm 的相关已知问题能否解释自然轨迹。
再次核对 [UiDriver 官方源码](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/core/ui_driver.cpp)
的字符事件及长文本剪贴板分支，选择小于其公开 master 200 字符阈值的 180 字符向量；
设备 UiTest 6.0.2.3 与 master 不等同，不从源码直接断定该二进制行为。
[xterm #6045](https://github.com/xtermjs/xterm.js/issues/6045) 为相关 IME 顺序案例而非本机根因；
[Playwright 输入语义](https://playwright.dev/docs/input) 也不能替代 HarmonyOS 自然事件。
Huawei 官方/社区检索未找到该设备的已确认同类诊断，不把未检索到解释为平台无问题。

只扩展测试构建转换、数字观察器和解析/回归测试，增加 `AttributionMode 4`；生产输入逻辑
不变。原版差分仍以原延迟调用原回调一次，观察器可能影响调度时间，不能声称零扰动。
模式只在一次性空闲 Tab 显式启用，记录事件类别、长度、差分 ID、公开向量相等性、
onData/Bridge 计数；不保存字符、key 值或认证内容。20 秒或 2048 行停止，报告最多 128 块。

执行记录：

- `test-regression.ps1 -Group policy,tooling,web` 通过，涵盖转换/恢复、解析拒绝、五模式、
  原定时回调转发、Pane/旧 Bridge 隔离、容量停止和内容排除。没有运行 Rust 或完整发布门。
- `dev-pc.ps1 -RequireUsb -NoLaunch -NoDaemon` 完成 ARM64 debug 构建、测试签名及安装；
  native 库复用 SHA-256 `D9A7148098B6CA523FFD4663E7CD967919D542B8BC6F1ED490272D5C2A13C3A0`。
  HAP SHA-256 为 `684B941DE7BE3F36B673F535B8F1A316C2260F2CBBC8503FB62BE4B68EEF5C57`。
  构建后检查生产文件，观察器仍仅存在于测试转换中。
- `diagnose-text-input-pc.ps1 -Scenario input-attribution -AttributionMode 4` 只运行一次，
  总耗时 38021 ms。设备 HAD-W32 / API 24 / UiTest 6.0.2.3，与 §8.19/20 相同系统版本。
  临时 Tab 的 arming 命令 40/40 精确、1 次输入和 1 次 Enter；公开 30 字符片段重复六次，
  一次 UiTest 调用，向量没有 Enter，没有 SSH/Mosh 认证或网络操作。
- 证据位于 `build/verification/input-chain-20260906/`：`software.json`、两个 preflight、
  构建日志和 `device/text-input-diagnostic.json`。token 为 `7038913`，PID 20197，
  所有 128 个数字块都收到，但捕获在 12.885 秒触及行上限，`stopReason=2`，保留
  `result=failed`、`failureDomain=harness`、`classification=incomplete-input-order-probe`。

| 边界 | 本轮实际证据 | 可下结论的范围 |
| --- | --- | --- |
| UiTest 请求 | 180 字符，一次调用，无向量提交 | 发起量，不独立证明每个系统事件 |
| DOM | 截止时 156 个 input 均匹配对应公开字符 | 已捕获前缀没有早期字符缺失 |
| xterm 差分 | 156 次安排/执行，每次 textarea 增 1、发出 1 | 全部在 input 后，无提前空差分 |
| xterm onData | 156 字符，所有累计前缀精确 | 已捕获段没有漏发或错序 |
| WebMessagePort | 156 次尝试、156 次返回，无缺失 port | 发送调用完成；不等于单独证明传输 |
| 所属 Surface | 停止报告前收到 156 包/156 字符 | 与 Web 已捕获段一致 |
| 应用命令缓冲 | 最终 180/180 精确；保留的 135–180 长度逐步前缀均精确 | 最终未丢字，不是完整逐事件时间线 |

156 个差分中，安排至 input 为 0.6–1.9 ms，input 至回调为 0.3–2.9 ms。这是带探针的
本次成功前缀，不是时延基准或原故障发生概率。没有首个坏边界可定位；§8.21 的候选顺序
在此次前缀未出现，也不能用此样本排除间歇性问题。

**本轮做得不够的地方：** 预算按简化事件模型估算，未计入实际 beforeinput、额外 keyup
及关联行，180 字符需超过 2048 行；软件测试验证了容量安全停止，却没验证真实形状的完整
向量可以装入。另一个保留缺口是 `Get-LeanTTYAppLogs` 使用 `hilog -z 500`，128 个报告块
与常规日志共享尾部，应用逐步轨迹只剩末 46 项。原始查询内容不另行落盘，不能补回其余项。
前 156 的计数与最终 180 来自不同时间边界，差值 24 不是字符丢失。这个工具结果不能算作
完整链路通过，更不能以它修改 xterm 或宣布 UiTest 有错。

按停止条件没有追加输入、扩大容量重跑或修改产品。一次性 Tab `tab-183-4` 的清空/关闭
确认通过，原有 Tab 不属于删除目标；诊断进程停止，屏幕超时恢复，临时焦点布局删除。
本次不需要人工输入或通知。后续先按实际事件预算补软件约束，并让应用端使用有界摘要
而非依赖 hilog 尾部；只有采集能完整保留之后，才在原失败场景捕获一次自然坏轨迹。

### 8.23 日志与 Web 探针的观察者效应对照（2026-09-06）

维护者指出：日志或采样可能改变运行时序，让原本会发生的错误消失。本轮目标改为检验
这个干扰因素，不继续从带探针的成功样本推断产品无错。输入合同不变：同一公开向量在
应用缓冲中精确保留。原始自然坏样本的首个错误边界仍未知，§8.21 只是候选机制。

**外部依据与本地发现：** 当天重查 [HTML event loop](https://html.spec.whatwg.org/multipage/webappapis.html#event-loops)
与 [timers](https://html.spec.whatwg.org/multipage/timers.html)：不同任务源的调度不能简化为
一个全局 FIFO，零延迟定时器也不是与输入事件的顺序保证。由此推断，同步探针开销可能
改变两者的相对就绪状态；不能认定“变慢只会修好”，也可能扩大错误窗口。
[Chromium tracing 指南](https://www.chromium.org/developers/how-tos/trace-event-profiling-tool/tracing-event-instrumentation/)
提供低开销设计参照，并未保证任意 JavaScript 观察器零扰动。
重查 [UiDriver 源码](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/core/ui_driver.cpp)、
[xterm #6045](https://github.com/xtermjs/xterm.js/issues/6045) 和
[Huawei HiLog 文档](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/hilog-guidelines-ndk)。
它们没有证明本设备的日志隐藏了丢字；Huawei 社区检索仍未找到匹配的已确认诊断。
公开 master、NDK 指南和相关 macOS 案例均不能替代 API 24 / UiTest 6.0.2.3 的实测。

源码中需要区分四类开销：

| 位置 | 确认的行为 | 本轮如何处理 |
| --- | --- | --- |
| Web 事件采样 | 时钟读取、数组分配、textarea 长度、累计字符串及前缀比较 | 探针开/关对照 |
| 原版差分外包装 | 包裹 helper、暂时替换 setTimeout 转发入口、回调前后采样 | 只在探针开组启用；不声称原调用延迟等于原实际调度 |
| IDLE 验收日志 | 每动作前后格式化、读取缓冲/补全状态并调用 HiLog | 在单一临时 Session 中开/关，不改变动作和重绘 |
| 其他日志与自动化 | 生产 `D` 日志、验收写入 ACK、焦点布局检查、UiTest 固定节奏 | 保持一致；输入期间不轮询日志，不宣称完全无干扰 |

三组使用相同签名 debug HAP、相同 180 字符和一次原 UiTest helper 调用。5 为详细日志开/
Web 探针关；6 只关闭两处详细 IDLE 日志；7 在 6 上增加 mode-4 Web 探针。A/B 只比较日志，
B/C 只比较 Web 采样。没有调整注入速度、添加逐字确认、提交向量或切换网络。三组均在
arming 后 23 秒读取一次权威 commandLine，并只输出数字长度、精确相等性和差异位置。
这不是每字符缓存、计时或成功模拟；非 IDLE 状态拒绝读取，断开/Surface detach 取消，
旧 token 回调不再报告。原有生产日志和 ACK 日志未关闭，未启用观察器的空判断仍存在。

**修正上一轮的两个取证缺口：** Web 预算增加至固定 4096 行/256 块，软件测试使用每字符
13 行和额外非文本键对，完整向量 2365 行可装入；容量、丢块、重复块仍失败关闭。
应用端用上述一次终态摘要，不再依赖 `hilog -z 500` 保留所有逐步日志。旧 §8.22 的失败
记录不变。测试转换/恢复、owner 取消与晚到、隐私边界、模式和摘要解析检查通过；
`test-regression.ps1 -Group policy,tooling,web` 通过，ARM64 debug 构建/安装通过，native 库复用。

证据根目录 `build/verification/input-observer-effect-20260906/`。三组 candidate SHA-256 均为
`1F22410F4A9DAC17296E30964E4F7E53798EF267A2C087EA3A6074B49995734F`，设备仍为
HAD-W32 / HAD-W24 6.1.0.135(SP60C00E100R13P3log) / API 24 / UiTest 6.0.2.3。

| 子目录 / profile | IDLE 详细日志 | Web 探针 | 最终缓冲 | helper 含焦点检查 ms | 总时长 ms |
| --- | --- | --- | --- | --- | --- |
| `logs-on-trace-off` / 5 | 开 | 关 | 180/180 精确 | 13408 | 45656 |
| `logs-off-trace-off` / 6 | 关 | 关 | 180/180 精确 | 13451 | 42910 |
| `logs-off-trace-on` / 7 | 关 | 开 | 180/180 精确 | 13454 | 43574 |

每组 arming 均 40/40、一次输入、一次 Enter，向量各一次输入、零 Enter；无重试或人工操作。
profile 7 的 token `9503342` 保留完整 2365 行/148 块，deadline 正常结束；DOM、onData、
Bridge post/所属 Surface 接收均 180 字符，180 次差分均在 input 后、每次发出 1 字符。
没有早期空回调、错序、端口缺失或前缀差异。input 至差分回调为 0.3–1.7 ms，仅描述该
带探针样本，不作性能结论。profile 5/6 没有 DOM 轨迹，不能为“证明零干扰”再加事件计时。

**结论：** 这次关闭详细日志和 Web 探针后仍未复现，因此没有支持“新增观察器是不能复现
的原因”的实测差异。但三组各一次、不是随机交叉或发生率样本，不能排除调度/日志效应。
helper 时长包含 UiTest、布局、焦点和跨进程等待，不能用 3 ms 或 43 ms 的整段差值估算
JavaScript 探针开销，更不能推断亚毫秒级竞态已排除。生产/ACK 日志、注入方式与节奏、
网络场景负载仍未隔离。单独输入成功与 Wi-Fi 测试中的自然失败可能并非同一运行条件。

按固定对照结束，没有继续增加样本或修改产品输入语义。三个临时 Tab 清空/关闭通过，
屏幕超时恢复，临时焦点布局删除，诊断 app 停止；原有 Tab、凭据与网络未作为清理目标。
后续回到原失败场景使用低干扰终态摘要；只有出现自然不一致，才按坏边界决定进一步轨迹
或上游最小复现。当前不确认 xterm、UiTest 或 Mosh 为根因，不把本轮升级为正式验收。

### 8.24 将合成单字符顺序搬到真机 ArkWeb（2026-09-06）

**问题与假设：** Chrome 原最小集仍为十页 10/10；真机 §8.23 的正常差分均在 input 后。
本轮检验相同的“229 keydown → 零延迟任务屏障 → input → keyup”在实际 ArkWeb/xterm
是否也让 DOM 有字而 onData 无字。textarea 由 DOM 拥有，键状态/差分由原版 xterm 拥有，
终端数据经所属 Bridge/Surface 进入 Session 的 commandLine。受控实验的首个错误边界预计
在 DOM→onData；自然故障目前仅知预期文本与最终缓冲不一致，中间错误边界仍未知。

**本轮调研：** 2026-09-06 检查以下来源，而非沿用旧链接直接改工具。

- [xterm #6045](https://github.com/xtermjs/xterm.js/issues/6045) 报告 229 延迟差分导致丢字/
  重复及合成触发方法；提供候选机制，不证明 HarmonyOS 上的原故障。
- [DOM 的 isTrusted 定义](https://dom.spec.whatwg.org/#dom-event-istrusted) 区分脚本派发与
  浏览器输入事件。本轮保留 `isTrusted=false`，不伪装物理输入。
- [Playwright 输入实践](https://playwright.dev/docs/input) 区分文本填入、逐键事件和脚本
  派发，作为对照设计参考，不作为 ArkWeb 行为保证。
- [OpenHarmony UiTest 源码](https://github.com/openharmony/testfwk_arkxtest/blob/master/uitest/core/ui_driver.cpp)
  为公开 master，不能直接等同设备 UiTest 6.0.2.3 的实现。本轮不改该注入路径。
- 检索华为开发者文档/社区的 ArkWeb、runJavaScript、229/input。未找到与该设备版本和
  顺序匹配的可复现社区报告；runJavaScript 指南抓取失败。使用仓库已有且已真机执行的
  WebviewController.runJavaScript→页面函数入口，不引入新的平台 API 或任意脚本参数。
  华为 [JsMessageExt 文档](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/arkts-apis-webview-jsmessageext)
  仅佐证脚本调用接口族，不能代替本次编译与物理验证。
  另核对本机 DevEco SDK 的 `@ohos.web.webview.d.ts`：`runJavaScript(script): Promise<string>`
  从 API 9 提供，执行当前页面上下文，需要已关联 Web 的 controller；脚本状态不跨导航。
  因此入口沿用当前 owner/页面并在每个异步屏障后检查身份，不把 Promise 返回值当异步
  实验完成。结果仍经既有带 token 的消息端口上报。

**有界方案：** 测试转换增加 attribution 8。一次精确 arming，固定十组、每组五个案例：
正常顺序、延迟 input、提前 keyup、只有 input、普通 textarea 的延迟 input。前四种直接
使用临时 Pane 的生产 Terminal/onData/Bridge；每例通过公开 textarea.value 清空 DOM，
不重建整个 Terminal、不清空 commandLine、不替换私有处理器。十组不是十个独立进程。
每例最多一字符、无 Enter；正常期望 xterm 共 40 个 `a`，普通 textarea 十个单字不进应用。
若机制成立，应用最终只有 30 个 `a`；这是故障特征，不是正确产品行为。

脚本使用真实零延迟定时器；仅只读 `_keyDownSeen` 检查起点和 input 前状态，不包裹差分。
最多 10 秒/51 数字行，完成后上报；沿用 23 秒所属 Session 缓冲摘要。安全输入、页面恢复、
Surface 替换/退出或并入真实输入时中止；报告不含用户内容。沿用原测试包构建恢复和正式包
符号排除。先验证 Chrome 同一触发器及边界，再选 policy/tooling/web、ARM64 签名构建和
单次真机命名探针；不跑 Rust、SSH/Mosh/Wi-Fi 或完整发布门禁。

**执行与结果：** 证据根目录 `build/verification/input-synthetic-device-20260906/`。
原最小页面、原 runner 和 xterm 资产哈希与 §8.21 相同；新增触发器先在 Chrome
152.0.7977.76 完成五组各十例及 secure/replay/cancel/owner-replaced 四项软件边界检查。
`policy,tooling,web` 通过；首次 helper 测试发现 OrderedDictionary 汇总字段读取错误，
改为直接累计已解析数字，并补充零例取消报告反例。最终 helper 复验通过后才上真机。

ARM64 debug HAP SHA-256：`67ADFD3AD239140756C1C76E6884B7790EB7E41AF9468890DD14A326BA955EAA`。
native 库仍为 `D9A71480…3A0`，没有重建；ArkTS 构建成功并保留原警告，未称零警告。
设备 HAD-W32，系统 HAD-W24 6.1.0.135(SP60C00E100R13P3log)，API 24，UiTest 6.0.2.3。

- `device/`：26396 ms，在 arming 文本注入后的焦点布局传输处停止，Enter=0，未启动
  合成实验，trace=null；临时 Tab 清理通过。保留 environment 失败，不计入复现样本。
- `recheck-preflight.json`：重新检查命令/序列化布局通道通过，未修改或修复工具。
- `device-r2/`：43206 ms，一次 arming 40/40 精确、一次 Enter；无向量 UiTest 调用、
  无向量 Enter。token `4252590`，完整 51 行/4 块，合成窗口在 1840 ms 完成。

| 受控案例 | DOM 为 `a` | 正常输出 `a` | 缺失输出 |
| --- | --- | --- | --- |
| xterm 正常顺序 | 10/10 | 10/10 | 0/10 |
| xterm 差分先执行、input 后到 | 10/10 | 0/10 | 10/10 |
| xterm 提前 keyup 再 input | 10/10 | 10/10 | 0/10 |
| xterm 只有 input | 10/10 | 10/10 | 0/10 |
| 普通 textarea 延迟 input | 10/10 | 10/10（DOM oracle） | 0/10 |

延迟组 input 前 `_keyDownSeen` 十次均为 true；正常组同样为 true，但 input 与 keydown
同任务，不让差分提前跑。其余对照 input 前为 false。四类 xterm 共 40 个 DOM 字符，
onData 共 30 个，所属 Surface 接收 30 包/30 字符，Session commandLine 为 30 个 `a`，
相对正常期望 40 个的首个不匹配在索引 30；后续链路没有额外丢失。所有事件合成且
不受信任，无私有处理器修改，无细粒度差分探针。完成轮询与合成期可能重叠，生产/ACK
日志仍开启；本次不隔离观察者开销。
原始设备 JSON 中继承的旧 `eventColumns/eventKinds` 与未使用的终态 textarea 字段不适用于
profile 8；本轮实际判据是 `syntheticCases`、DOM/onData 总量、Surface 和 native 摘要。
已修正解析器的 profile 8 字段说明，并将未测字段输出为 null，补充软件反例；保留原始
设备记录，不为更正元数据重跑真机或改写历史结果。

**结论与停止点：** 同一候选机制已从桌面 Chrome 搬到真实 ArkWeb 和实际 LeanTTY 输入
链路，固定触发条件下十次全失；无需模拟 Wi-Fi、系统重负载或远端协议。明确的受控错误
边界是 DOM→xterm.onData，不是 Bridge/ArkTS 队列或 Rust。它不证明 UiTest/IME 在自然
故障中产生了这条顺序，也不证明真实键盘 100% 丢字。普通 textarea 是 DOM oracle，
不是另一套 Bridge 对照。保持自然故障归因开放，不实施产品修复或追加随机样本。
两轮临时 Tab、缓冲、屏幕超时和焦点布局清理通过；诊断结束停止应用，原网络/凭据不变。

### 8.25 xterm 输入时序构建期修复（2026-09-06）

维护者授权先修复已独立复现的原因，暂缓其他自然输入故障归因。合同是非 composition
文本恰好发送一次且保持顺序；最后正确边界为 textarea，首个错误边界为 xterm.onData。
xterm CoreBrowserTerminal 的 held-key 门控与 CompositionHelper 的延迟差分共同拥有问题，
Bridge、ArkTS 命令缓冲与 Mosh 不承担补偿。原始自然坏样本缺少 DOM 轨迹，仍不能判定同因。

当日复核 [xterm #6045](https://github.com/xtermjs/xterm.js/issues/6045) 与
[#6009](https://github.com/xtermjs/xterm.js/pull/6009)：上游报告同时包含丢字与重复发送，
单独放宽门控不足；开放 PR 不是已验证修复。再次查看
[UiTest 官方指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)
和 [Playwright 输入文档](https://playwright.dev/docs/input)，保留语义注入、实际 IME 与合成
DOM 时序的证据区别。公开 master 不证明 API 24 / UiTest 6.0.2.3 的特定事件顺序；本轮没有
新增 HarmonyOS 注入方法，也没有从外部资料推断历史自然故障已定位。

**实现：** `tools/web-terminal/patches/xterm-input-order.mjs` 在现有资产构建边界修改四个
精确位置，锁定 xterm 6.0.0、上游提交与完整 npm 输入哈希。非 composing 的 insertText
使用事件数据并取消待处理差分；其他非 composing input 立即结算已有差分，防止删除被
下一次插入吞掉。每个 CompositionHelper 只持有一个待处理回调，其身份失效后旧定时器
不再发送。composition 与待完成的 finalizer 保留原所有权，屏幕阅读保留原差分路径。
无新 DOM listener、延时阈值、文本去重、运行时私有覆盖、依赖或下游补字。补丁包含可读
等价代码、升级失败关闭和上游修复后的删除条件。上次 WebGL 补丁保持不变。

证据根目录为 `build/verification/xterm-input-fix-20260906/`：

| 证据 | 结果 | 范围 |
| --- | --- | --- |
| `red-corrected/result.json` | 原版 32 例中 11 例失败 | 原始缺陷的固定红灯，非自然发生率 |
| `green/result.json` | 同一用例哈希，补丁版 32/32 | Chrome 152 的实际 DOM/定时器；无私有覆盖 |
| `web.json` | 通过 | 13 项生成 owner 用例、隔离、哈希拒绝、终端策略/回放/检索 |
| `policy.json` | 通过 | 源码政策和 diff 检查，不是真机验收 |
| `trigger-packaged-r2/result.json` | 50 例及 4 项取消/安全边界通过 | 既有 profile 8 触发器的浏览器验证 |
| `device-synthetic/text-input-diagnostic.json` | 45646 ms；五组各 10/10 | 实际 ArkWeb/终端受控修复与下游一致性 |
| `device-masked/text-input-diagnostic.json` | 34721 ms；普通/掩码各 32/32 | 实际 UiTest 与掩码 textarea 清理 |
| `device-panes/text-input-diagnostic.json` | 40180 ms；通过 | 分屏、关闭左 Pane、保留右侧、再分屏和输入隔离 |
| `device-ime/` | 无有效最终结果 | 单次零模型 TUI/真实 IME 检查受工具错误阻塞 |

`dev-pc.ps1 -RequireUsb -NoLaunch -NoDaemon -Offline` 完成 ARM64 debug 构建、测试签名
和安装。精确保留包为 `input-fix-signed.hap`，SHA-256：
`BC848D0D12C5A12248622924E180768CB51C4E009299A0C437568322CDA1D2E2`。
直接读取 HAP 内 xterm.js 确认为
`CF4E2B4CBD6EE30BF6008E8BA490C57AD7838D184F9C9BD7FDD7EB5EB5D13310`，
与浏览器/生成资产一致；native 继续复用 `D9A71480…5C2A13C3A0`。设备为 HAD-W32、API 24、
UiTest 6.0.2.3；源码仍为原有脏开发分支，未创建正式候选或进行 Git 写操作。

受控真机的延迟 input 十例均恢复为 `a`，其余四组各 10/10。四种 xterm 情形总计 DOM 40、
onData 40、所属 Surface 40 包/40 字符、最终缓冲 40 且逐字相等；完整 51 行报告，无向量
UiTest/Enter，arming 仅一次精确输入和一次 Enter。旧工具标题仍为
`different-controlled-synthetic-result`，它判断旧缺陷签名，不代表修复通过；本轮依据
逐例结果及各层总量断言。`privateHandlersPatched=false` 仅表示触发器没有运行时覆盖
处理器，不表示 HAP 中的 xterm 仍为原版。上述三个成功物理场景均完成自身清理。

**未成功的工具步骤也保留：** 最初浏览器红灯包含一个不合法的 keypress 构造：小写 keydown
已经被 xterm 处理，测试仍补发 keypress。改成上游明确委托 keypress 的 A-Z 路径后，重跑
原版得到 11 个有效失败；旧 `red/` 不作为最终对照。第一次 Web 组命令误用 EvidenceDirectory
参数，尚未执行检查；改用现有 EvidencePath 后通过。`trigger-packaged/` 首次断言仍期待
原版汇总的 exact=0，而实际为修复后的 1；仅修正该测试预期，保留首轮失败，r2 通过。
这些不是第二份产品补丁，也不是稳定性重试样本。

**真实 IME 尚未验收：** `verify-agent-compatibility-pc.ps1 -Agents codex -Modes direct
-InteractionOnlyProbe -DiagnosticHap` 只执行一次，计划模型请求为零。最后进度为
`codex-direct-complete`，但没有 PTY capture，也没有有效 result.json。结果工厂返回的
PSCustomObject 缺少 completedAt；finally 中赋值抛错，覆盖了内部失败信息。因此不能
推断 IME 已执行、通过或发生产品退化。本轮没有修这个工具、重新运行或改用另一种
物理 workaround。只读审计未见 HDC reverse mapping、同前缀临时目录或隔离 sshd；临时
known-host/Tab 身份及屏幕超时的完整收尾证据无法从残存报告确认，不删除无法归属的
历史条目。后续动作和这一证据缺口统一保留在 next-work。

受控机制修复已有 L1–L3 证据，真实 IME 兼容尚未闭合，不能宣布整体输入兼容或正式
发布验收完成。没有运行完整 Rust/发布/网络矩阵、模型请求、GitHub 发布或上架操作。

### 8.26 IME 前置工具修复与范围重审（2026-09-06）

目标仍是验证构建期输入补丁未破坏系统中文输入法，不是通过完整 Agent TUI 场景。
本轮先在 PowerShell 7.6.3 复现结果工厂缺少 `completedAt` 的实际赋值异常，再统一工厂
和 readiness 的字段定义。进度检查点现在原子保存完整结果、失败检查及专属资源身份，
清理中断仍尝试写最终报告，原始外层异常不被报告失败替换。软件回归覆盖对象生命周期、
未完成检查点、失败检查与清理失败同时保留；`harness-repair-software.json` 的 policy/tooling
组通过。没有重建或修改 HAP。

当日研究问题为“PSCustomObject 属性缺失为何使 finally 报告覆盖先前失败”。
[Microsoft 对象文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_pscustomobject?view=powershell-7.5)
与 [try/catch/finally 文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_try_catch_finally?view=powershell-7.5)
支持显式定义字段、分开保存原始失败和收尾失败；本地受控反例验证实际运行时。
此问题属于宿主 PowerShell，不据此推断 HarmonyOS 输入问题。

`device-ime-r2` 复用 §8.25 同一签名 HAP，只选 codex/direct InteractionOnlyProbe，模型请求
预算为零。104029 ms 后中断：检查等不到 `SSH session connected`，恢复等不到 SSH closed，
随后本地清理等不到 idle interrupt。没有启动 TUI 或输入 IME 向量。此次完整保存 result.json
及原始检查错误；旧脚本把连接日志超时标为 product，但这不证明产品连接缺陷，因为其
host-key 分支吞掉了注入/焦点错误，最后正确边界尚不足。该运行不计入 IME 通过。
独立 `post-run-audit.json` 确认本轮 endpoint 不存在，known_hosts 全部 108 行摘要未变，
反向映射与临时目录消失，专属 Tab 移除事件和屏幕覆盖归还已记录。历史条目不作删除。

**执行前重审：** 复合场景在待测 IME 之前依赖 SSH 信任、连接和 TUI 生命周期，违反“用最小
证据验证直接 owner”的目标。停止重跑 Agent/SSH，也不修补这些前置步骤。改用现有
diagnose-text-input 工具的独立临时 Tab，直接观察系统键盘事件→中文输入法→ArkWeb/xterm→
本地输入缓冲；向量不按 Enter、不联网、不使用模型。若该最小场景仍不能建立输入法初态，
保存证据并停止，不堆积自动切换或第三种注入方式。

当日复核 [OpenHarmony UiTest 指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)
和 [uinput 文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/dfx/uinput.md)：
按键模拟与直接文本注入是不同接口；本场景需要经过系统输入法，使用已有受控数字按键路径，
不把 UiTest 中文字符串注入视作 composition。公开 master 不保证 API 24 / UiTest 6.0.2.3
的候选词或事件顺序；未发现匹配本项目报告错误的 HarmonyOS 公开案例。产品结论以本机
实际输入结果为准，记录只保留固定公开向量的长度和相等性。

**最小场景通过：** `diagnose-text-input-pc.ps1 -Scenario ime-input -HapPath <同一保留包>
-EvidenceDirectory <证据根>/device-ime-local` 在 23184 ms 内完成一次检查。独立临时 Tab
通过系统按键路径输入英文 10 字符、拼音提交“中文”2 字符，再切回英文追加 `aa11`，本地
输入缓冲依次为 10/10、2/2、6/6 且逐字精确。没有向量 Enter、网络、模型或输入重试；
输入法恢复、专属 Tab 移除和屏幕覆盖归还均通过。设备、API、UiTest 和 HAP 与 §8.25 一致。
它证明实际系统 IME→ArkWeb/xterm→Bridge→本地缓冲的兼容路径，不是人工键盘自然发生率
或远端 Agent 验收。没有为该场景增加产品 hook、日志或采样。

工具复用普通/掩码探针的临时 Tab 生命周期，只新增有界 IME 阶段。SelfTest 执行真实探针
函数并替换设备服务，覆盖成功、中文不匹配后立即停止、两条路径恢复输入法及禁止 Enter；
`ime-local-tooling.json` 的 policy/tooling 组通过。报告修复、本地 IME 与既有受控/掩码/Pane
证据已闭合本次输入补丁的开发验证。旧 Agent SSH 前置故障进入 Next Work 的工具故障注入
项，不阻断直接 IME 结论，也不从正式 TUI 验收中删除。停止追加输入样本，回归既定主线。

### 8.27 离线指南预览与浏览器审查工具（2026-09-06）

本轮只实现 Next Work 的指南编辑入口，不改 HTML、产品代码或设备验收链。
`preview-user-guide.mjs` 用 Node 内置 HTTP 服务绑定 `127.0.0.1` 和动态端口，只提供固定指南的
内存快照；严格校验 Host、路径和方法，不解析请求提供的文件名，不开放目录、CORS 或写入。
允许先预览审查源再同步打包副本，原有 `test-user-guide.mjs` 仍要求打包时逐字节一致。
浏览器入口使用现有 Playwright 1.62.1、Chrome 152.0.7977.76 和 Node 24.18.0，无新增依赖。

**研究问题与边界：** 当日查阅 [Node 监听接口](https://github.com/nodejs/node/blob/main/doc/api/net.md)、
[Playwright 隔离与请求路由](https://playwright.dev/docs/api/class-browsercontext#browser-context-route)
及[截图接口](https://playwright.dev/docs/screenshots)，决定显式 loopback、单文件允许列表、
独立浏览器上下文、阻断非指南请求和分开清理浏览器/服务。公开 main 文档不是本机版本保证，
监听和拒绝行为另用真实 HTTP 请求验证。本轮 owner 是宿主 Node/Chrome，不新增 HarmonyOS
注入或等待方法，也不把桌面浏览器证据推广为 `help`、权限、文件导出或系统浏览器验收。

**工具失败与诊断：** 首轮在英文语言切换后的历史检查失败。预期应是 URL 和语言保持正确，
最后正确边界已是页面 URL/CSS 可见性；首个错误边界是工具额外要求章节标题在视口内。
最小 `diagnose-history.mjs` 记录切换、后退和刷新：后两者均保留 `#en-recovery` 与英文，但
滚动位置为 0。[HTML 历史恢复规范](https://html.spec.whatwg.org/dev/browsing-the-web.html)
将自动滚动恢复交给浏览器；[Playwright 点击](https://playwright.dev/docs/input#scrolling)
会先把页首语言按钮滚入视口。此证据排除了本样本的语言丢失，未发现相冲突的指南行为。
因此仅修正历史检查；显式点击目录仍须让目标标题进入视口，不改页面、不增加等待时间。

第二轮通过 53 项后耗尽 90 秒预算，单次窄页往返平滑滚动约 3 秒，没有新的行为断言失败。
重新核对目标是导航/版式审查，不是重复动画测量；依据
[Playwright reducedMotion 接口](https://playwright.dev/docs/api/class-browser#browser-new-context-option-reduced-motion)，
改用标准减少动态效果偏好，触发指南已有的 CSS 分支。所有检查、单步超时和总预算保留，
报告明确记录 `reducedMotion=reduce`；不声称覆盖完整平滑滚动动画。

证据目录为 `build/verification/guide-browser-review-20260906-r1`、`-r2`、`-r3`，前两轮不覆盖：

| 证据 | 结果 | 范围 |
| --- | --- | --- |
| `r1/result.json` 与 `history-observation.json` | 29253 ms 后历史滚动预期失败；最小诊断退出 0 | 原始失败与 oracle 定位 |
| `r2/result.json` | 90755 ms，53 项通过后预算停止 | 部分默认动画导航，不计整体通过 |
| `r3/result.json` | 5789 ms，59/59、8 张截图 | 中英双语、1280/800 宽度、各 10 个目录、关键任务、6 个恢复折叠块及历史导航 |

三轮均记录浏览器/服务关闭成功。r3 页面外部请求 0、脚本错误 0，审查源和打包副本均为
89607 字节，SHA-256 `45563132d069ef91f087e3682849a52ef59c072daf89918a767e1946fba2dd6f`。
报告增量原子落盘并保存输入/工具/截图哈希；自动通过仍为 `acceptanceEligible=false`，
`editorialReview=required-separately`。HTTP 边界测试 34 例通过并确认两个监听器均已关闭，
注册到 `web`/`tooling`；浏览器审查保持独立入口，不增加完整软件门的 Chrome 依赖。
`r3/software-focused.json` 的 `policy,tooling,web` 共 11 项通过，含指南字节一致性、预览
边界及 `git diff --check`；`releaseEligible=false`。工具 SelfTest 的模拟输入重试日志不是
真实设备操作或本轮输入重试。

已查看全部 8 张首页/连接/恢复截图，所见区域无重叠或横向溢出。内容审查发现双语页首仍是
1.5.0，而 HTML 标题和页脚是 1.6.0；连同尚待同步的 Mosh 内容保留在第 4 阶段，不在本轮
修改文案或宣布指南内容已完成验收。使用说明按简洁操作文档组织，明确自动检查、人工
内容审查与物理验收的区别。未重建 HAP、操作测试机、调用模型、执行 Git 写入或发布。

### 8.28 Agent SSH 前置门故障注入与软件修复（2026-09-06）

本轮只处理 §8.26 的工具故障，不重跑 Agent/IME 真机矩阵。目标是保留首个失败、停止
未获当前状态证据支持的后续动作。历史 `device-ime-r2` 的最后正确边界为普通命令提交；
报告没有 SSH connected/shell-ready 证据，随后却把等待超时归为 product，恢复再次等待
closed，外层仍提交 known-host 清理。源码证实首个错误边界是 host-key 的宽泛 catch：
没有提示、日志读取失败、焦点失败和确认注入失败都被当成“已信任”。这只定位工具缺陷，
不能从缺失轨迹反推当时实际是哪一种设备或 SSH 故障。

**当日研究：** [OpenHarmony UiTest 指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)
区分 UI 查找/模拟操作与操作后断言；[PowerShell 异常文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_try_catch_finally?view=powershell-7.5)
说明 catch 会处理 try 范围内的终止错误，不能把整个确认动作的异常当成可选提示缺席。
[Playwright 失败隔离](https://playwright.dev/docs/test-retries)支持停止失败上下文、隔离后续用例，
这里只借鉴隔离原则，不引入其自动重试。检索 Huawei 社区与上游记录未找到本脚本同症案例；
[arkxtest PR 1108](https://gitee.com/openharmony/testfwk_arkxtest/pulls/1108?skip_mobile=true)
涉及部分新事件观察器限制，不足以证明历史 API 24 / UiTest 6.0.2.3 的行为。本轮没有采用
新观察 API、增加设备重试或变更输入方式，直接在当前 PowerShell 7.6.3 验证脚本控制流。

**实现与所有权：** 应用仍拥有真实 SSH 状态；工具只保存当前尝试最后证明的边界。
`Connect-AgentServer` 同时等待 host-key prompt 或 connected，已连接时不补发 yes；
确认阶段任何错误直接传回。connected 加新鲜 shell-ready 文件才允许正常断开。每次连接
和 Ctrl+D 之前先使旧证据失效；断开清空旧日志并等待新 close 事件，成功才允许本地清理。
纯日志超时归 unknown，明确的产品断言、基础设施/环境错误保留原分类。

原有选定用例循环提取为 `Invoke-AgentSelectedChecks`，只在首个失败前推进；失败检查先写
检查点，随后停止其他 Agent/mode 和本地清理提交。OSC 99 探针遵循相同停止门。通知失败
不再强停整个应用，最终收尾仍只负责独立测试 Tab。状态不明时不会猜测恢复成功：
known-host 未确认移除继续使 cleanup 失败，报告保留 endpoint、Tab 等资源身份。
本轮不增加设备文件直接删除或跨工作区恢复；实体资源是否成功清理仍需 L3 证据。

`tools/test-agent-ssh-gate.ps1` 只载入上述真实函数，替换 HDC、输入、日志和 fixture 观察，
不执行设备脚本顶层、不访问私钥、不启动 SSH/Agent。证据位于
`build/verification/agent-ssh-gate-20260906/`：

- `diagnosis.md`：修改行为前记录预期、边界、owner、假设、研究和非目标。
- `red-corrected.json`：21 例中 17 例失败，直接复现吞错、超时误归因、无证据 Ctrl+D、
  失败后继续选择和清理。首版 `red.json` 的 trusted mock 错把不匹配日志返回给只等提示
  的调用；修正 mock 的匹配语义后重新建立基线，旧文件保留，不作为最终红灯计数。
- `green.json`：同一 21 例全部通过；`green-expanded.json` 的 25 例全部通过，额外覆盖
  重连使旧证据失效、成功 verdict 不能替代本地状态、探针失败及清理失败不标记已移除。
  后一轮测试体约 1224 ms，包含一次实际 1 秒超时；测试/工具哈希与运行时写入报告。
- 既有 `test-agent-compatibility.ps1` 通过，已纳入这 25 例和检查点 SSH 边界持久化断言。
  删除了要求保留整应用强停的旧静态断言；禁止跨测试 Tab 强停仍受边界测试保护。

本轮真实设备命令、实际输入重试和模型请求均为 0，`acceptanceEligible=false`。未修改产品
代码、重建 HAP、执行 Git 写入或发布。文档按简洁记录规范区分软件修复与待做物理验证。
定向门还发现 §8.27 的分组接线缺陷：`policy,tooling` 未初始化仅属于 web/ArkTS 的 Node
变量。`software-focused.json` 保留该红灯；上一轮同时选择 web，因而未覆盖此分支。
按 [Get-Command 文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/get-command?view=powershell-7.5)
改为按需解析应用命令后，`software-focused-r2.json` 又揭示本机两个 Node 路径被拼成一条
命令。先用最小查询确认实际多值结果，再选择首个命令；无 DevEco/已有 Node 两条真实
注册动作均通过 34 例预览测试，另补双路径受控回归。不为此引入 DevEco 或运行 Web 全组。
最终 `software-focused-r3.json` 的 `policy,tooling` 六项全部通过，含 25 个 SSH 反例、
Node 双路径回归、34 个 HTTP 边界检查和 `git diff --check`；耗时约 12 秒，
`releaseEligible=false`。前两份失败记录保留，原有换行转换警告未冒充为零警告。
下一步先盘点剩余故障测试，只补序列化/HAP 角色/汇总报告的缺口，再执行零模型 SSH 窄场景
及同一 PC 的 review smoke/最小输入；不把软件绿灯推广为历史故障或完整开发门已闭合。

### 8.29 证据工具故障闭合与零模型物理复核（2026-09-06）

本轮先盘点已有测试：Agent 检查点已覆盖首个失败及 cleanup 失败的并存；HAP 已覆盖构建
模式、签名 Profile 和验收能力错用。只补序列化失败、汇总误放行、ABI/Profile 身份缺口。
证据根为 `build/verification/release-evidence-faults-20260906/`，修改前假设见 `diagnosis.md`。

**研究与根因。** 当日核对 [PowerShell 7.6 序列化文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertto-json?view=powershell-7.6)
及[上游 #15397](https://github.com/PowerShell/PowerShell/issues/15397)：深度溢出默认只是警告；
WarningAction Stop 能终止，但仍可能打印警告。[File.Replace](https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace?view=net-10.0)
的 I/O 异常用实际 Windows 文件锁验证，不增设 I/O 抽象。[pytest 报告实现](https://docs.pytest.org/en/stable/_modules/_pytest/junitxml.html)
分别保留测试失败和 teardown 错误，仅作报告设计参照。Huawei 检索未找到对应 PowerShell
证据问题；ASON 和打包扫描文档不适用于此处。当前运行时为 PowerShell 7.6.3。

最后正确边界是内存结果/已解析 JSON；第一个错误边界分别是截断 JSON 仍被提交，以及
cleanup 任意文案默认 passed、汇总仅拒绝 failed/pending。所有者均为 `release-tooling.ps1`。
修复在写入前拒绝深度警告，已声明 cleanup 只接受明确 passed；旧字段缺席仍显式记为
not-separately-reported，不冒充执行成功。三个通知脚本只把结果改为 result/detail，不改
实际清理动作。故障测试直接执行写入/解析和生产者赋值，未启动通知或模型。

**软件证据。** `red.json` 的 27 例中 9 例失败；`green.json` 同组 27/27；
`green-expanded-r2.json` 为 31/31、460 ms，另覆盖生产者赋值及人读/JSON 汇总一致性。
第一份 expanded 报告保留测试自身的变量遮蔽错误，修正作用域命名后通过，不归因产品。
HAP 共 2 个准入、15 个拒绝用例通过；新加缺失/错误/混合 ABI 和 Profile/module 身份不符。
ZIP/策略真实执行，仅 SDK 验签边界 stub；实际签名验证由下面真机安装准入完成。

`software-focused.json` 和 `software-ssh-probe.json` 的 policy/tooling 六项均通过，耗时
13012 / 12946 ms；包括 31 个报告反例、HAP 角色、34 个指南 HTTP 用例和 diff 检查。
两次门之间只新增 SSH-only 选择接线，没有重跑全软件或发布门。软件模拟的短写重试日志
不是本轮实际输入重试；深度溢出的预期警告及既有换行提示均未隐藏。

**SSH 窄场景。** 新增仅诊断可用的 `-SshPrerequisiteProbe`，复用 Connect/Disconnect 和
最终资源 owner，跳过 Agent 配置、清点和启动，计划/实际模型请求明确为 0。实施前重查
[OpenHarmony UiTest](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)、
[OpenSSH ForceCommand](https://man.openbsd.org/sshd_config#ForceCommand) 和
[失败隔离参照](https://playwright.dev/docs/test-retries)：操作成功仍需实际状态证明，未知结果
不重发。软件接线 28/28；首个独立测试遗漏加载分类 helper，保留在 `ssh-probe-gate.json`，
补载真实 owner 后完整定向门通过。没有改 SDK API 或输入方式。

`ssh-prerequisite/result.json` 在 HAD-W32 ARM64、系统
`HAD-W24 6.1.0.135(SP60C00E100R13P3log)` / API 24 上通过，耗时 70276 ms，SSH 检查体
35033 ms。HAP 为已有输入修复包 `bc848d0d…a1d2e2`，真实签名准入后安装，不重建。
新鲜远端 shell-ready、实际 locale 命令 UTF-8 输出、当前 SSH close 均通过；3 条本地命令
和 1 条远端命令各一次输入/一次 Enter、无 mismatch。3 条本地命令已覆盖最小 UiTest 精确
输入/提交链，不追加普通输入 18 格对照或 Agent/IME 矩阵。`ssh-absence-audit.json` 独立核对
run endpoint、反向映射、WSL fixture 进程和目录均不存在；Tab 移除及屏幕租约返回来自本次
最终检查点。未读取/导出私钥，未修改用户密钥，没有扩大 known-host 删除范围。

**review smoke。** 随后同一 PC 串行运行现有脚本，使用专属 release-mode、debug Profile
HAP `8eecd666…f0f506266`；它不是本轮最新产品候选，不用来证明 xterm 修复。7 项在
26909 ms 内通过，工作区/Settings 不变，命令提交、输入重试和模型请求均为 0；证据为
`review-smoke/review-smoke.json`。此处验证工具和正常 UI 接线，不创建正式候选。
完成后已通过 `dev-pc.ps1 -SkipBuild` 恢复 `bc848d0d…a1d2e2` debug 输入修复包，安装/启动
成功；恢复安装只是环境归还，不计为新一轮行为验收。

本轮没有网络扰动、Agent 请求、Git 写入或发布。结果按简洁记录规范区分软件反例、真机
窄场景和正式验收。以上完成工具故障闭合项；下一项汇总既有 L0–L3 形成 development
go/no-go，不先扩大矩阵或直接进入性能优化。历史缺失 SSH 轨迹的具体原因仍不能反推。

### 8.30 development go/no-go（2026-09-06）

**决定：GO，进入性能诊断；不是发布 GO。** 当前开发前置门已有足够的分层证据支持继续
测量。旧正式矩阵仍为失败，不能拼接不同 HAP 的诊断结果宣布候选通过，也不要求先重跑
完整矩阵才能盘点或测量性能。历史自然输入归因继续按维护者决定暂缓。

本轮只审计现有记录和文件，不构建、不操作真机、不调用模型、不改产品或验收工具。
`build/verification/development-go-no-go-20260906/audit.json` 固定了 17 份原始报告及 2 个
诊断 HAP 的 SHA-256；同目录 `audit.ps1` 可重复执行这次只读证据检查。runtime-reclaim
结构化结果另经当前生产汇总器的 `Assert-LeanTTYRuntimeReclaimEvidence` 接受。

| 进入门 | 已有 L0–L3 依据 | 本次判断 |
| --- | --- | --- |
| 页面恢复的真实 owner | §8.8 / §8.11：snapshot 同时刻取基线，replace 完成、viewport 恢复后 ACK；六组尺寸/重放回归；异常退出 r6 与 Surface rebuild r1 的原始 JSON 均精确恢复、清理通过 | 开发修复有直接依据；跨尺寸 identity 不能直接比较，同几何 L3 不扩写成所有 resize 组合通过 |
| Pane 输入归属 | §8.10 布局投影修复；当前输入修复包的 Pane 诊断为 passed，各缓冲断言逐字精确 | 不再用瞬态 accessibilityId 或光标位置代替 Pane owner |
| xterm 受控时序 | §8.25 原版同组 32 例中 11 例失败、补丁全过，13 项生成代码 owner 检查；真机合成五组各十例、普通/掩码、Pane 及 §8.26 系统 IME 通过 | 已授权机制修复闭合；不是自然故障同因证明，也不是完整远端 Agent/IME 验收 |
| deterministic lifecycle | §8.17 runtime-reclaim 同进程/工作区保持，首字符拦截、本地缓冲 0、native cancel 1、server/PTY 消失及清理通过 | 可控正式合同已接线；旧包 L3 不冒充新依赖或系统 GC 证据 |
| Wi-Fi 用户价值 | §8.20 实际地址/路由变化，Mosh 同 Session/PTY 新命令与 SSH 断开重连对照通过，页面/Search/原网络及最终清理通过 | 业务 passed；原报告 `failed-harness` 保留。无新增网络修复依据，不追加切网抽样 |
| 工具与包边界 | §8.8 预热/离线/无 daemon/警告和 ZIP 边界；环境 readiness 8 项；§8.27 指南 HTTP 34 例及浏览器 59 项；§8.28–29 报告 31 例、SSH 门 28 例、包角色反例 | 开发 readiness 闭合；旧 1.5.1 checkout 的环境预检不能替代当前 release commit 预检 |
| 最小物理接线及清理 | §8.29 SSH 70276 ms，3 本地 + 1 远端命令首次精确，零模型；review 26909 ms；独立资源缺席审计通过 | 窄场景足够支持继续开发，不扩写成完整 Agent 或稳定输入发生率 |

**身份核对。** 本次直接读取留存文件确认输入修复 HAP 为
`bc848d0d12c5a12248622924e180768cb51c4e009299a0c437568322cda1d2e2`，review HAP 为
`8eecd666b09be07db693dcabe363266164cf11c6a21984bc7dbaa0bf0f506266`，与各自报告一致。
当前 xterm 资产与输入修复 HAP 内的 xterm 字节一致，SHA-256 为
`cf4e2b4cbd6ee30bf6008e8ba490c57ad7838d184f9c9bd7fdd7eb5eb5d13310`；旧 review 仍是
未含输入修复的资产，不能用其 smoke 证明该补丁。当前 `release-tooling.ps1` 与报告测试
哈希也与 §8.29 的最终 31 例报告一致。

输入诊断包的 terminal HTML 包含测试转换，不与当前还原后的源码宣称逐字相同；本次也
没有从脏工作树重建以证明全部 ArkTS 源码身份。两包内 native 字节均为
`caa9aa85f40bf17b54997c8afe819dd428bdf2fb03fa27b1b64d28c6b7855a85`；前文的
`d9a71480…13c3a0` 是当前 `entry/libs` 打包前文件，不能混写成 ZIP 内 native 哈希。
Cargo 仍固定 `v0.1.0` / `=0.1.0`。旧报告中的滚动 `entry/build` 路径不证明旧包仍留在原处；
本次只核验上面两个独立留存 HAP，不提升其他历史包的证据强度。

**未解除的门。** 正式候选的精确 release commit、离线输入、release-readiness、C2 后 QH、
完整 Agent/IME、八项 Mosh 矩阵及 production 交付仍待执行。历史输入故障未归因，Wi-Fi
旧轮工具失败未改判，指南版本/内容待同步。它们保留在 Next Work 的对应后续位置；任何
新核心正确性、安全、泄漏或不可恢复证据仍抢占性能诊断，只回到相关最小门。

工具盘点同时完成，详见 [`performance-diagnosis-1.6.md`](performance-diagnosis-1.6.md)：
现有测量入口可复用，RSS/PSS、端到端/renderer 时间及旧/新包必须分开。当前没有新的性能
结论，不增加插桩或优化。下一步为现有冷/温启动协议，再到连续输出与多 Pane/Tab 回收。

本轮文档 L0 门 `software-policy.json` 通过（public-source-policy、git-diff-check），新增盘点
与 Next Work 的 13 个本地文档链接存在；既有换行提示未改写成产品失败。按简洁记录规范
分开保留决定、证据强度和未解除门，不重跑与本次文档变更无关的软件组或物理矩阵。

### 8.31 发布前源码与工具合并收口（2026-09-08）

按维护者要求，将剩余审核包 smoke、已确认指南及其工具、规范和诊断记录合成一个 PR，
不再按单个文件交接。Next Work 只保留精确候选/正式验收、正式发布/商店交付两个 1.6
执行批次；版本元数据和 Changelog 日期必须先于候选构建冻结。Ghostty 预研不纳入本批。

证据根为 `build/verification/pr-slices-20260907/release-source/`。`software.json` 的
policy/tooling/web 共 11 项通过，包含 smoke 的 UI/包合同和 34 项真实 HTTP 边界检查。
Chrome 152.0.7977.76 的指南检查 63 项通过，20 张中英文、宽/窄截图逐张复核，浏览器和
预览服务均已关闭。源码和 rawfile 保持维护者已确认的 revision 9 / 97,952 bytes，SHA-256
`a6c680b669b3be2459de74f61343bb92cd4a89ce4917d0dc1b27c22938cb8ac4`。

同期将仅用于图标生成的 xmldom 0.9.10 升级为
[官方修复版 0.9.12](https://github.com/xmldom/xmldom/security/advisories/GHSA-6gmq-8vp8-gcm6)。
真实生成器配合同一 sharp 0.35.3 的七组 SVG/PNG hash 升级前后完全一致，PNG 也匹配
仓库原资产；不改图标、不扩大依赖升级。完整调研、检查方式和限制见证据根 `review.md`。

本批未构建或部署 HAP，没有 HDC、SSH、切网或模型调用。旧 review smoke 保留原候选
身份，未改写成当前正式验收。聚焦软件检查和浏览器通过均不等于 C2/C3/C4 或发布就绪。

### 8.32 精确版本预检的失败与报告修复（2026-09-08）

PR #171 冻结 1.6.0 的 Changelog 日期，四项 CI 通过；所有版本源原已一致，无产品或指南
字节变更。两个独立发布 checkout 已定位到该提交，设备只读预检通过。首次 readiness
在 64 秒后拒绝旧 review HAP 中的 `LTTY_PERF_PING_`。该包早于 PR #159 的诊断隔离
修复，拒绝正确；不得降低 marker 门或将旧包 smoke 当作当前包验证。对原预检所用的
1.5.1 production HAP 单独检查也命中同一标记，故停止寻找其他旧包。这个结果只证明
包内保留该字面量，不证明运行时记录了真实正文或 secret。后续预检需使用当前隔离策略
下新建的 release-mode 包；旧“readiness 通过”不能覆盖后来增加的包边界。

同次报告暴露一个真实工具缺陷：53,840-byte Agent 合成结果写入和读回成功，最终摘要却
为 `null`；旧 2026-09-05 报告也受影响。PowerShell 7.6.3 的回调创建子作用域，普通赋值
没有更新外层报告所有者，与当日核查的
[Microsoft 作用域说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_scopes?view=powershell-7.6)
和 [script block 说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_script_blocks?view=powershell-7.6)
一致。问题限于宿主脚本，不涉及鸿蒙接口、输入时序或模型行为。

修复让回调返回摘要，由报告所有者接收。新增测试运行实际入口、Agent 结果构造器和原子
JSON 写入器，只替换外部构建/软件命令；修复前复现空摘要，修复后成功及后续包拒绝两条
路径均保留正确 hash、大小、计数、零模型和原失败，且失败后不运行签名前置检查。
证据根为 `build/verification/release-1.6.0-20260908/`。原失败保留；该次预检失败时尚无
C1/C2/C3/C4 通过结果可复用。修复后的候选及正式批次续接见下一节。

### 8.33 精确候选与正式密钥场景停止（2026-09-08）

**结论：候选构建与正式 QH 通过；C3 因报告契约错误暂停，不是发布 GO。** PR #172 合并后，
独立 production/review checkout 均干净固定到 `28b104991c300fe1909f2b490c1d7b64b1fba86e`，
tree 为 `fa736ca4ea5bcc5687b5775f09cb00c552c310f6`。证据根仍为上一节目录。

当前源码的新 release-mode 测试签名包通过 marker 门和 SDK 签名检查；readiness 8 项通过，
53,840-byte Agent 合成结果摘要完整，零模型调用。该包 SHA-256 为
`30a04cb53cab0e0813a60a6e2852d253b8c50241f26539651aec724219e2a01b`，其配套 APP 仍为
测试 Profile，不作生产交付。`release-mode-package/manifest.json` 记录包角色和身份。

正式入口完成 C1 全部 26 项和 C2 clean ARM64 构建、测试签名、安装与启动。留存 C2 HAP
SHA-256 为 `b83f2218c274c7329d9138e980014f0e40512c9aa419481e5f3d2db5465d981e`；它是
acceptance-enabled 包，与上述 readiness 包不同。两包内提取/读取的指南均为 97,952 bytes，
匹配维护者确认的 revision 9 / `a6c680b669b3be2459de74f61343bb92cd4a89ce4917d0dc1b27c22938cb8ac4`。

正式 QH 绑定同一 C2 和干净 harness，通过三条普通命令、三次首次精确输入、零 mismatch、
三次 Enter、临时非回显 secret、串行 layout 和清理审计。随后 `key-passphrase` 的九项
检查均通过：加密、两类错误输入不修改、错误后恢复、Ctrl+C 清空、移除口令、删除临时密钥。
八条普通命令均一次提交，零 mismatch。真实文件缺席检查通过，awake lease 已恢复；没有
重试密钥命令，没有动现有 `id_ed25519`。

正式批次在约 598 秒时停止：生产者发布 `cleanup.result="verified-absent"`，共享汇总器
只接受标准 `passed`，因而 `formal/release-report.json` 为 failed；后续 17 个注册阶段仍
为 pending。Mosh、完整 Agent/IME、模型请求和 C4 尚未执行。candidate store 的
`device-behavior` 标签仅反映单场景报告，不能解释为完整 C3 通过。

**失败诊断。** 预期是清理的判定与细节分开；最后正确边界是实际密钥缺席检查，首个错误
边界是 `verify-key-passphrase-pc.ps1` 将成功细节写入结果枚举。真实汇总器对原报告的只读
重放复现同一拒绝，故归为宿主工具的生产者/消费者契约缺口，不涉及产品、输入时序或
HarmonyOS 清理失败。`audit-formal-stop.ps1` / `formal-stop-audit.json` 固定报告哈希，
确认原报告和候选未变，诊断未操作设备或调用模型。本次未修此错误，也未重启矩阵。

**下一批边界。** 在开发分支修生产者，保留实际缺席审计，并补正常删除、已不存在、失败、
未执行和未知值经真实报告到汇总器的反例；不增加成功字符串特判。一次检查注册场景的
cleanup 接口与精确候选兼容路径，防止逐项上机发现静态契约错误。旧 `-Resume` 明确拒绝
不同 harness；SSH 等脚本还有独立 allowlist，目前不能假定密钥工具修改后整轮自动兼容。
待这些前置条件证明后，优先按 R3 保留相同 C0–C2，以新干净工具重新 QH/C3，不手改失败
报告或拼接诊断结果。只有产品/构建输入或候选身份改变才按 R4 重建；当前未证明需要改产品。

### 8.34 密钥报告契约修复与候选重建取舍（2026-09-09）

密钥报告生产者保留实际缺席审计：只有清理已完成且细节为 `verified-absent` 或
`already-absent` 才输出 `cleanup.result=passed`；失败、剩余清理和未知值不通过，awake
恢复失败也不能被密钥删除成功掩盖。原细节单独保留，共享汇总器、设备操作和产品均未改动。

本轮先运行真实报告 writer、正常删除及 finally 清理分支，替换的只有设备副作用；实际
JSON 经原汇总器读取。旧实现 9/47 失败，修复后 47/47 通过。补齐注册生产者检查后覆盖
58 项：删除成功、已不存在、文件仍在、探测失败、未执行、无进程、环境恢复失败、未知
值及正常/失败报告。没有真实设备、模型或凭据参与，也没有把单场景报告改判成完整验收。

**注册输出检查。** 20 个阶段由 12 个脚本产生报告。密钥、SSH auth、Host Identity、两类
BEL、长任务、Agent 和 Mosh 汇总的判定均经实际生产者表达式到原消费者检查；uninstall
的布尔清理对象在 awake 未恢复时被拒绝、实际赋值恢复后被接受。C1、QH 和 SSH 汇总无
顶层 cleanup，仍明确显示 unreported；后两者的嵌套清理由各自现有门负责。测试固定了这份
注册覆盖，新增报告所有者时必须重新审查；这些软件检查不代替真实清理的物理证据。

**调研边界。** 2026-09-09 核查的 [JSON Schema enum](https://json-schema.org/understanding-json-schema/reference/enum)
将判定限制在声明的值集合，[pytest 安全清理](https://docs.pytest.org/en/stable/how-to/fixtures.html#safe-teardowns)
说明清理须与真实状态变更和异常路径配对。它们仅支持报告/测试设计，不证明鸿蒙行为。
Huawei/OpenHarmony UiTest 清理结果及该字面量的定向检索未发现匹配平台报告；字面量来自
本仓库。执行环境为 PowerShell 7.6.3，不改 SDK、输入等待或平台恢复策略。

**选择 R4，不扩张兼容规则。** 精确补丁经五个现有白名单检查，SSH auth、terminal search、
Mosh、长任务和 Agent 均拒绝工具/记录差异。上轮“优先 R3”以兼容性证明为前提，现有
入口不满足；跨新 harness 的旧 `-Resume` 也不合法。为了省一次构建去扩大五个独立场景的
接纳范围，会增加与本次报告修复无关的规则。上一轮 C1/C2 共约 248 秒，目前也没有已被
汇总器接受的 C3 前缀，故选择合并后从新身份完成 readiness/C1/C2/QH/C3。保留旧证据，
不解释为产品退化或清理失败，不新建兼容框架，不手改 JSON。

证据根为 `build/verification/key-cleanup-contract-20260909/`：`red.json`、`green.json`、
`registered-cleanup.json`、`compatibility.json` 和聚焦 `policy,tooling` 软件报告。
修复通过的是宿主工具层；新候选的完整正式验收仍在 Next Work，不在本次软件结果中宣告完成。

### 8.35 R4 候选与后台通知场景停止（2026-09-09）

**结论：新候选、正式 QH 和六组密钥/Host 场景通过；通知阶段停止，完整 C3 未通过。**
PR #173 合并后的独立 production/review clone 均干净固定到
`2063de224562e28ddcd7db98075d7db1a5ceb9ef`，tree 为
`607b617f2f7d84759374fe34c229ce8ba80aaa7d`。本地证据根为
`build/verification/release-1.6.0-r4-20260909/`，不覆盖上轮目录。

release-mode 测试签名 HAP 通过 SDK 签名及 signed/unsigned 隔离检查，SHA-256 为
`92ec02f4fc344afbf6b9da76d6357908018fd5cd5427e2bbf6df187c98c3c15e`。
readiness 八项通过，合成 Agent 结果完整回读 53,840 字节，零模型调用。
该包及配套测试 APP 单独留存，均不是 AppGallery 上传包。C1 全部 26 项通过，C2 HAP
SHA-256 为 `bf7028f641baa617e6a2088cff20d14fde288160a7dee06c1d3a0a1f38c75b12`。
两包内指南均匹配 revision 9 的 97,952 字节和既有 SHA-256。

正式入口约 1,550 秒后停止：C1/C2 约 250 秒，QH 约 102 秒，六组密钥/Host 约
1,180 秒，失败通知阶段约 17 秒。密钥口令九项检查及 `cleanup.result=passed` 被汇总器
接受，证实 PR #173 的真实链路闭合。默认 ECDSA 场景完成现有 `id_ed25519` 的产品导出、
临时移除和恢复；重启后的私钥字节、公钥指纹、Host 配置均一致，备份及测试材料缺席。
后续 11 个注册阶段未执行，Mosh、Agent/IME 和模型请求未启动；汇总的模型用量仍按原
schema 记为 `unavailable`，不手改成零。没有执行 C4、tag、Release 或 AppGallery 操作。

**已定位边界。** 正向通知场景预期后台 BEL 后发布通知，但没有建立“系统通知已开启”
前置条件。失败进程的固定日志显示 BEL fired，随后 `isNotificationEnabled()` 返回 false
对应的 deferred 分支执行。`BackgroundBellNotification` 在该状态下安排前台申请并返回，
未调用 publish；这符合产品合同，不能仅凭缺少发布日志判为产品退化。

`verify-background-bell-notification-pc.ps1` 的最后正确观察是 fired，首个错误判断是立即
要求同份日志已有 published。实际拒绝原因是权限关闭；异步发布等待缺口是源码发现，
尚未独立复现。相同脚本的 `pane-\d+` 只截取当前双段 Pane ID 的前缀，也未单独触发
一次实验；修复时需真实解析器反例，不能将这些静态发现都算成此次缺报的运行时原因。

**原失败与恢复分开。** 原 cleanup 布局含系统通知授权弹窗而无应用根节点，工具将其
写成“找到零 Pane”。独立清理使用新布局的唯一“不允许”按钮，保持原关闭状态，再通过
真实焦点清除该 Pane 的 attention。补充检查最初错误地要求取消成功日志；未发布通知时
这个要求不成立，未重发清理动作。改用通知中心的直接缺席检查，确认无 LeanTTY 卡片，
关闭面板后一个终端可见。结果留在 `formal/stages/background-bell/post-stop-cleanup.json`；
原 `attempt-1/result.json` 和正式总报告仍为失败。

本轮只读取既有失败日志/布局、检查所有者源码并清理，没有修改产品或冻结工具，也没有
重试 BEL、输入密钥或重启矩阵。下一批先做通知脚本的当日外部调研、实际入口反例及命名
真机验证，再核对候选兼容和 QH。原 cleanup 失败先按 R3 保守处理，只有证明作用范围与
恢复完整才能讨论更小续跑；若入口不支持兼容则 R4，不扩大白名单或改写失败证据。

### 8.36 通知验收前置状态与异步边界修复（2026-09-09）

**原因和方案。** 本轮只改宿主验收工具，未改产品、依赖、指南、版本或冻结候选。
OpenHarmony 官方 [NotificationManager 文档](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/reference/apis-notification-kit/js-apis-notificationManager.md)
明确区分通知使能状态、异步 `publish` 和前台授权请求；拒绝后不能用同一请求接口再次
拉起授权框，未存在的通知取消可返回 1600007。2026-09-09 查询的这些合同支持保留产品
deferred 分支、独立等待发布、使用设置入口建立测试前置状态，以及直接观察卡片缺席。
Huawei 指南页面未能完整获取，故不把搜索摘要当平台依据；平台实况由本轮真机补充。

两个入口复用 `notification-regression.ps1`，收拢原本重复的通知设置、窗口恢复和观察。
正向场景先保存系统开关，临时开启，确认后重新打开设置验证持久状态；失败清理也按
原状态恢复，不依赖点击后的缓存布尔值。完整 Pane ID 带字段边界匹配，fired 和 published
分别等待。已可见的单实例不再次启动；仅识别出的 LeanTTY 通知授权框可被拒绝，无关
弹窗不点击。清理直接检查通知中心缺席，并恢复屏幕超时；split 清理只在本轮发起过
创建时执行，不以全局隐藏 Tab 的输入数判定当前 Pane。

**软件证据。** 真实脚本的原发布判断在完整 ID、异步发布和同 epoch 双 Pane 三项反例
失败；修复后通过。新增 25 项宿主回归覆盖设置已开/已关、同值不切换、点击结果未知、
确认失败、持久回读不符、权限弹窗、无关弹窗、已可见窗口、日志通道失败、通知残留，
以及两个真实 finally 的正常、权限恢复失败和 awake 恢复失败。只替换设备 I/O，不复制
被测判断。既有源码位置断言已跟随共享所有者调整，没有放宽清理消费者。

**真机证据。** HAD-W32 / ARM64 / USB 使用原 C2 的精确签名 HAP，SHA-256 仍为
`bf7028f641baa617e6a2088cff20d14fde288160a7dee06c1d3a0a1f38c75b12`。
正向、权限开关、双 Pane suppression/reset 三组均单次通过，且原通知设置恢复为关闭、
卡片缺席、可见单 Pane 和屏幕超时恢复均通过。权限组观察到关闭时 deferred/零卡片、
开启后发布并返回；此次没有再次出现授权框，符合既有拒绝后的平台限制。弹窗恢复只有
软件反例和 §8.35 的旧运行时证据，未冒充本轮新真机覆盖；不清除用户数据强造弹窗。
ColdStale、LateHandled、LateDestroyed 和 ManualDismiss 未在本轮重跑，仍须正式验收。

本地证据根为 `build/verification/notification-harness-20260909/`。聚焦软件执行曾在沙箱
身份下无法调用已注册 WSL；这是执行身份错误，按规则切换桌面用户重跑，不修产品或
重试物理场景。既有 JSON 深度警告是报告拒绝测试的预期输入，并非物理结果截断。

**续跑边界。** 当前补丁被五个既有候选兼容门拒绝，旧正式报告也不允许跨 harness
直接 resume。选择修复合并后按 R4 建立新精确候选，再执行 QH 和注册矩阵，不新增白名单
或兼容框架。本轮是开发诊断闭合，未重写 §8.35 的正式失败，也未执行 C4 或发布操作。

### 8.37 R4 通知闭合与回收探针授权干扰（2026-09-09）

**结果与身份。** PR #174 合并后，两份独立发布 clone 干净固定到
`759937c3465692ef4f8539a6535f27041d4d2010`，tree 为
`0d4ec5023efa351b3cf904da84342f1f9953b06f`。本地证据根为
`build/verification/release-1.6.0-r4-pr174-20260909/`。新的 release-mode 测试签名包通过
签名及日志隔离检查，readiness 八项通过，合成 Agent 完整结果回读 53,840 字节、零模型。
该包只用于 readiness，不是 C2 或 production 交付包。

C1 全部 26 项、C2 和正式 QH 通过；C2 HAP SHA-256 为
`1331c584dbff2169f7cf01d62a6a4b967877e1329eafe032b89b386e4c4478d5`。
两种新包中的指南均匹配维护者确认的 revision 9、97,952 字节及既有 SHA-256。
正式入口运行约 3,007 秒：C1/C2 265 秒，QH 111 秒，六组密钥/Host 1,270 秒，七组通知
683 秒，卸载恢复 15 秒，Mosh 子矩阵 662 秒。顶层共 16 阶段 passed、1 failed、3 pending。

**通过范围。** 六组密钥/Host 场景及清理通过。现有 `id_ed25519` 的产品导出、临时移除、
重启后恢复和独立备份缺席审计通过；私钥字节、公钥指纹及 Host 配置一致。七组通知包含
正向、suppression、ColdStale、LateHandled、LateDestroyed、ManualDismiss 和权限开关，
均通过且各自恢复原通知设置、确认卡片缺席、应用可见和屏幕超时恢复，闭合 §8.36 的正式
补验范围。随后普通卸载/重装验证通过：普通偏好和工作区重置，精确候选重新安装；该脚本
不读取或修改持久 Asset Store SSH 资产。不能把卸载前的权限恢复观察当成卸载后开关审计。

Mosh `compatibility` 单次约 457 秒通过：Bash、tmux、Vim、less、512 字节输入、242 行
输出、宽字符与组合字符、临时屏幕、resize、关闭及原页面/搜索隔离；实际 Codex 0.149.1
TUI 零模型子探针也通过。Unicode、临时页活动和关闭截图已逐张复核；截图不单独证明
原页恢复，后者仍依赖原场景断言。设备状态、fixture、反向映射、临时目录清理通过，
持久测试网络保留。截图含其他桌面窗口，只保留本地，不作为可公开附件。

**停止边界。** `runtime-reclaim` 单次失败于
`[environment] HarmonyOS UI layout remained empty after two captures`。此前已观察到同一
应用 PID、运行图丢弃、首次输入拦截、工作区身份保持、空本地缓冲及一次 native cancel。
随后本地 `help` 精确输入 4/4 字符、一次 Enter、提交确认；日志中帮助正文已有输出 ACK。
首个错误观察是搜索帮助输出之前的应用过滤布局根节点为空。后续 `localCommandPassed`、
`serverAbsent`、`ptyAbsent` 尚未走到断言，其默认 false 不是对应产品行为失败的证据。
原报告保持 failed/environment，不将已通过的前半链路写成完整回收通过。

**一次最小诊断。** 源码所有者链为 `showTopLevelHelp → UserGuideManager.sync →
DownloadsAccessManager.ensure → requestPermissionsFromUser/requestPermissionOnSetting`。
顶层帮助会同步指南并申请 Downloads 权限；前序普通卸载已改变权限前置状态。
2026-09-09 核查的 OpenHarmony 官方
[用户授权说明](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/security/AccessToken/request-user-authorization.md)
说明 user-grant 权限通过系统 UI 动态请求，不能假定先前授权仍成立；具体界面影响以真机
为准。Huawei 对应指南未成功获取，不将其搜索摘要当依据。

停止后仅用同一候选执行一次本地 `help`：4/4 字符、一次 Enter，零网络会话、零模型、未
发送允许或拒绝。全局布局含 382 节点及 LeanTTY 的 Downloads 授权说明，应用过滤布局
却为零子节点；截图直接显示“文件夹权限”和未选中的“下载”文件夹。结果保存在独立的
`help-permission-probe/result.json`，标记不可作为验收。它确认了测试探针的权限副作用及
观察盲区，与原失败日志吻合；不证明 Mosh 本体有故障，也不回填原正式失败。

**清理和后续取舍。** 原失败场景通过 `app-relaunch` 恢复清理，设备测试状态、fixture
进程、反向映射和临时目录均报告缺席，持久测试网络保留。独立探针仅停止空闲测试应用以
取消待处理授权，再启动并确认一个终端可见、屏幕超时恢复，没有替用户选择权限。
本轮未修产品或冻结工具，未重跑 Mosh 或矩阵。后六个 Mosh 场景以及长任务、Agent/IME、
SSH 未执行；未切 WiFi、未合盖。正式模型预算仍为 9，模型阶段尚未开始，原汇总的实际
计量保持 `unavailable`；不将独立零模型检查冒充正式计量。完整 C3 未通过，未进入 C4、
tag、GitHub Release 或商店提交。

下一批先让恢复探针验证恢复本身：现有 `help mosh` 只输出命令帮助及提示符，不走指南
同步。需用实际脚本反例证明替换效果，并检查其他生命周期探针是否误带权限依赖；真正
验证顶层帮助/指南的场景保留其权限合同。不全局授权、不增加布局重试、不改产品策略。
清理和影响范围证明、现有候选兼容门、QH 共同决定 R1–R4，不能承诺不同 harness 直接
resume，也不因工具缺陷自动重建整个候选；停止报告与诊断证据保持各自身份。

收尾只读审计确认两份冻结 clone 仍干净且身份精确、C2 字节未变、上一轮五份报告哈希
未变，并固定本轮原报告哈希；`closing-audit.json` 不是新增验收资格。状态文档的聚焦
`policy` 两项检查通过，未追加完整软件或物理矩阵。

### 8.38 回收和搜索探针去除无关权限依赖（2026-09-09）

**原因与取舍。** 本轮修复 §8.37 已定位的验收探针副作用，不改产品、依赖、指南或权限
策略。当天核查的 OpenHarmony
[用户授权说明](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/security/AccessToken/request-user-authorization.md)
要求在需要权限时动态请求，并重新检查权限状态；
[UiTest 文档](https://github.com/openharmony/testfwk_arkxtest/blob/master/README_zh.md)
说明 `dumpLayout -b` 仅返回指定应用窗口。两者与原真机“系统授权界面可见、应用过滤布局
为空”的证据一致，不支持靠延长重试或假定卸载后仍有授权修复。未找到能直接解释并修复
同一案例的上游 issue，未据此升级 SDK。测试只需证明本地输入和生命周期恢复，无需借道
指南同步；真实顶层帮助和 Downloads 验证仍保留原权限合同。

**变更范围。** Mosh 的运行时回收、受控进程恢复及合盖后的两条恢复分支改用 `help mosh`；
运行时回收的输出断言同步改为 `Usage: mosh`。同类检查发现终端搜索的 Pane/Tab fixture
和 renderer 重建探针也使用顶层帮助，故一并修复。搜索 fixture 使用六份 topic help，
保留超过视口的内容，并成对调整六处查询输入及断言。不改 SSH `~?` 帮助、设备输入所有者、
布局等待、重试预算或清理逻辑，不新建公共抽象。新增规则进入 `quality-strategy.md`。

**软件证据。** 新增七项回归解析真实 PowerShell 场景并执行命令提交、fixture 构造和
查询边界，只替换设备 I/O；旧脚本七项失败，修复后七项通过。测试不等同于整个场景或
ArkTS 所有者执行；实际产品路径由下述真机补充。回归接入 `tooling`，聚焦 `policy,tooling`
六项注册检查通过。既有 JSON 深度警告和输入重试输出来自软件负例，不是本轮物理异常。

**真机证据。** HAD-W32 / ARM64 / USB，设备报告 OpenHarmony 6.1.1.135、UiTest 6.0.2.3，
HDC 3.2.0d。原保留 C2 HAP 字节未变，SHA-256 仍为
`1331c584dbff2169f7cf01d62a6a4b967877e1329eafe032b89b386e4c4478d5`。
运行时回收单次约 205 秒通过：同一进程内运行图丢弃、首次输入拦截、工作区身份保留、
本地缓冲清空、native cancel 一次、远端 server/PTY 缺席，以及新帮助输出可搜索均通过。
偏好一致、秘密检查及完整清理通过，本次无需 `app-relaunch` 清理恢复。

搜索 Pane/Tab 隔离与 renderer 生命周期单次合计约 161 秒通过。六份帮助提供滚屏命中，
另一 Pane 和 Tab 不串入历史；查询按切换、最小化及 renderer 重建合同清除，重建后可提交
本地命令。七次命令均一次输入、一次 Enter、零不匹配；运行时回收的自动化稳定性亦为
stable。截图复核了帮助滚屏、最终单 Pane 和重建后输入；像素不替代场景的归属及进程断言。
搜索关闭、单 Tab/Pane 和屏幕超时恢复通过。本轮零模型、未切 WiFi、未合盖，未重做密钥
导出/删除/恢复；其他受控进程和合盖分支只有本轮软件覆盖，仍需正式矩阵验证。

**证据身份与后续。** 本地证据根为 `build/verification/recovery-command-probes-20260909/`。
两份真机报告均为诊断，不具备正式验收资格；搜索入口使用 `DiagnosticHap`，报告按该模式
记录包来源，不因外层哈希审计而改写成正式 retained 验收。收尾审计确认候选字节、上一轮
正式报告及失败报告均未变，并固定本轮报告哈希。截图含其他桌面内容，仅本地保存。

五个现有候选兼容门均拒绝这七个变更路径，正式 resume 也要求相同 harness 身份。选择
合并后按 R4 建立新候选，再执行 readiness、C1/C2、QH 及完整 C3；不扩大白名单或新建
兼容框架。本轮不重跑 QH 或正式矩阵，不将原 16 个通过阶段拼接到新报告；完整 C3 仍未
通过，未执行 C4、tag、GitHub Release 或 AppGallery 操作。

### 8.39 R4 密钥导出授权边界停止（2026-09-09）

**结果与身份。** PR #175 合并后，两份独立发布 clone 干净固定到
`3a71c1ad96fb771d2cfd5473a8b00258bf876651`，tree 为
`01cb4ec59b7009f7be8cb3ff9ac4bf7d1111e466`。本地证据根为
`build/verification/release-1.6.0-r4-pr175-20260909/`。release-mode 测试签名包通过签名
及日志隔离检查，readiness 八项通过；合成 Agent 完整结果回读 53,840 字节、零模型。
readiness HAP SHA-256 为
`d4817e891ff0e4f56c07da67cf4ef3c28b820cb649509a7d257a40ed665d3132`，不是 C2 或上传包。

C1 全部 26 项、C2 和正式 QH 通过；C2 HAP SHA-256 为
`880c57f6ac999d46952b10ddfaec925b7b1d626fdf32c5bfc8d73717883c3733`。
两种包中的指南均匹配已确认的 revision 9、97,952 字节及既有摘要。正式入口单次运行
1,472,696 ms，约 24.5 分钟；7 阶段 passed、1 failed、12 pending，resume 次数为零。
C1/C2 约 262 秒，QH 116 秒，五组密钥/Host 1,039 秒，失败阶段 55 秒。

**通过与未运行范围。** HAD-W32 / ARM64 / USB 上，key-passphrase、key-comment-restart、
ecdsa-import-restart、host-identity、host-identity-openssh 及各自清理通过。随后
`host-identity-default-ecdsa` 停止；七组通知、卸载恢复、Mosh、长任务、Agent/IME 和 SSH
阶段未运行。未切 WiFi、未合盖、未调用模型；原正式计量仍记录计划 9、实际 `unavailable`、
自动重试 0，不用独立零模型检查改写汇总。持久测试网络保持原配置，未改变防火墙或代理。

**最后正确与首个错误边界。** `preserve-ed25519-export` 精确输入 58/58 字符、一次 Enter，
记录 `submission-acknowledged`。随后 `preserve-ed25519-observe` 尚未输入字符，就在
`ACCEPTANCE_IDLE_INTERRUPT cleared=true` 超时；finally 的 known-host 清理和再次观察
同样未输入或提交命令。报告为 `invalid/interrupted`、`failed-harness`，清理为 failed。
默认 false 的删除、恢复及摘要检查尚未执行，不是密钥丢失的证据。注册入口属于本轮正式
矩阵，但子脚本报告仍按其原格式记录 diagnostic / releaseEligible=false；不改写身份。

系统全局布局 382 节点及截图显示“文件夹权限”、未勾选的 Downloads 和待处理的导出
命令。截图已复核，仅本地保留。原失败日志因后续 reset 清空而不足以单独判断，完整
`commandAutomation` 才证明导出已经提交。执行中曾误读空字段而说“尚未导出”，核查后
立即更正：提交已发生，完成尚未确认。不得把输入 ACK 当成业务结果。

**所有者与原因。** `verify-host-identity-pc.ps1` 的
`Export-And-Remove-HostIdentityEd25519` 在提交导出后立即调用备份观察；观察的公共输入
reset 需要终端接收 Ctrl+C，但系统授权界面此时占有交互。`SshKeyManager.exportKeyPair`
先等待 `DownloadsAccessManager.ensure`，成功后才调用 native 导出写文件；key rm 则在
脚本备份验证之后，故本轮未到删除边界。这里的 Downloads 是真实导出所需权限，不同于
§8.38 已移除的无关帮助副作用；不能用换帮助命令或全局授权绕过。

**补充恢复及证据限制。** 正式矩阵已停止，没有修冻结工具或再次提交导出。先确认原
密钥对仍在，再关闭已识别的待处理授权界面一次；实际产品日志明确
“Downloads access was not granted; no files were exported”。结合上述所有者顺序，
可确认本次导出未到文件写入；未授权、未删除 key、未执行恢复导入。随后终端重新可见，
真实 Ctrl+C 的 idle ACK 成功；公钥和 Host 配置在这次恢复前后摘要一致。

普通 HDC 和应用调试命名空间均不可见 Downloads 父目录，因此不把 `No such file`
当成备份缺席审计。私钥摘要读取被调试权限拒绝，未绕过权限、改变 ACL 或换渠道读取；
没有私钥字节比对结论。收尾独立检查确认原密钥对存在、本轮 known-host 条目、反向映射
和临时目录缺席。`post-stop-recovery.json` 是不可作为验收的补充证据，原 failed 与
cleanup failed 保持不变；恢复前后摘要也不冒充整个场景前后的比对。

**后续取舍。** 下一批先修复实际脚本的权限初始状态、异步导出完成边界和受阻清理，
覆盖已有授权、待授权、拒绝、未知结果和清理失败反例，再做一次命名真机诊断。导出结果
未知时不重发，不删除原 key；未证实备份可用前不得继续默认 ECDSA 切换。官方权限资料
和现有实现需在修复时核查，不扩大本轮诊断成工具实现或整轮重试。

原清理失败默认按 R3 评估；候选身份仍精确，但补充取消并不自动满足正式 resume 门。
修复后由既有兼容门和 QH 判断能否保留 C0–C2，否则采用 R4；不放宽白名单、不拼接旧
通过前缀。完整 C3 未通过，未进入 C4、tag、GitHub Release 或 AppGallery。

收尾 `closing-audit.json` 确认两份冻结 clone 干净且身份精确、C2 字节和上一轮七份证据
哈希未变，并固定本轮原报告、观察与恢复证据摘要。指南独立审计首次误用沙箱身份触发
Git ownership 拒绝，改以桌面用户执行后通过；这是执行身份错误，没有改 safe.directory、
ACL 或正式结果。仅更新活动清单和本记录，聚焦 policy 两项及文本差异检查通过，未追加
物理矩阵；既有换行格式警告未作为产品故障处理。

### 8.40 密钥导出验收的权限与完成边界修复（2026-09-09）

**本轮结果。** 修复保存在独立开发 clone 的
`codex/fix-key-export-permission-harness`，基线为 §8.39 的 PR #175 commit。
35 项实际脚本边界回归通过；相关 policy/tooling/ArkTS 的 11 项注册软件检查和 ARM64 调试构建通过。
权限独立往返通过：原始 Downloads 未授权，临时开启后恢复为未授权，终端返回正常，
没有密钥操作。默认 ECDSA 完整命名诊断尚未开始：工具安全审批两次拒绝现有
`id_ed25519` 的临时删除，第二次说明此前明确授权后仍被拒绝。未换渠道执行。
需要维护者在当前交接中重新确认该具体操作；本轮未提交或合并 PR，未启动正式矩阵。

**实现边界。** 仅默认 ECDSA 的原密钥保留路径临时准备 LeanTTY Downloads 权限，先保存
原始状态，再经系统 UI 修改并以 scoped ATM 状态与 checkbox 双重回读。已有授权不操作。
产品的按需权限策略不变，不全局预授权、不使用 root/grant/revoke 工具。
产品导出所有者在 awaited export 成功后增加不含正文、路径或秘密的
`KEY_EXPORT result=success`；场景等待该结果，再由既有备份所有者验证字节，最后才允许
`key rm`。提交 ACK 不代表导出完成；拒绝或超时不重发、不删除。

finally 对“已尝试导出”而非仅“备份验证成功”恢复输入状态；不对尚未创建的映射清理
known-host。未知导出先停止原命令，再观察可能产生的备份，不重复导出。敏感备份未证明
清理前保留所需 Downloads 访问并将清理记为失败，避免撤权后无法恢复。报告分开记录
export completion、实际删除验证和权限恢复，未删除不能因为清理通过而报告删除通过。

**调研与设备适用性。** 查阅 OpenHarmony
[用户授权指南](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/security/AccessToken/request-user-authorization.md)、
[ATM 工具](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/tools/atm-tool.md)、
[UiTest 文档](https://raw.githubusercontent.com/openharmony/testfwk_arkxtest/master/README_zh.md)
及 Huawei [Settings ability 标识](https://developer.huawei.com/consumer/cn/doc/content/themes-engine-next-base-intentcommand-0000002471235064)。
HAD-W32 / ARM64 / USB，OpenHarmony 6.1.1.135、UiTest 6.0.2.3 的 ATM help 仅提供查询；
未采用其他版本或 Android 权限修改命令。Privacy URI 的社区资料仅作为假设，当前 PC 的
`aa start ... -U privacy_settings` 和实际页面才是采纳依据；不宣称它是稳定公共产品 API。

**导航失败与重构判断。** 两次只读前置失败分别揭示 Settings 保留子页面、sidebar
滚动使 Privacy 行不可见。检查点撤掉点击 sidebar 的假设，采用直达 Privacy 的已验证路径。
随后一轮成功授权、恢复失败：Privacy 异步插入访问卡片，Folders 按钮从 y=818 移到
y=1397；过期坐标点击未进入列表，下一次未限定页面的 LeanTTY 文本误选了访问记录。
另一次补充撤权观察证明应用运行时还会弹出强制退出确认。没有把这些错误归为产品密钥问题。

恢复时只确认当前系统对 LeanTTY Downloads 的精确撤权提示，原未授权状态已还原。
第一次补充恢复记录误用启动函数参数而过早写入 app-return；原文件保留，独立
`permission-recovery-closing-audit.json` 补齐真实终端可见证据，不将错误记录改为通过。
最终路径在更改权限前停止测试应用，finally 重启；每次导航检查页面身份，并要求连续两次
目标 bounds 一致，最多四次采样，未稳定不点击。这移除了运行中撤权确认分支，不增加
通用 Settings 框架或盲目重试。最后一轮独立权限往返及清理单次通过。

**证据及限制。** 本地根为 `build/verification/key-export-permission-20260909/`。
最初四项真实导出函数负例在修复前失败；最终 35 项覆盖完成/拒绝/未知、不稳定或错误页面、
权限状态歧义、停止失败、结果未知以及清理失败等边界。测试执行实际 PowerShell 函数或
finally 的 reset 条件，设备 I/O 使用替身；不冒充完整 finally 或真机密钥恢复测试。
软件负例中的 JSON 深度警告、输入重试输出不计为物理故障。
`permission-fixture-stable-route/result.json` 是权限往返诊断，不是默认 ECDSA 或正式验收。
原失败、补充恢复及最终诊断分别保留；含桌面信息的布局只在本地保存。

正常 `dev-pc.ps1 -NoDaemon -Offline` 完成签名调试包构建、安装和启动；原 ARM64 native
未变，复用经过增量校验的产物。新 HAP SHA-256 为
`2133ab5779aee14ddb741063d3a5d7d7af305f317f0ed6979af97804d02550eb`。
新增完成日志尚未得到真实导出路径的验证；构建和安装不替代该证据。由于修改了打包源码，
命名诊断和 PR 通过后应选 R4，重新建立精确候选，不复用旧 C3 前缀或扩大兼容白名单。
本轮零模型、未切 WiFi、未合盖、未运行 Mosh；未创建临时 ECDSA/WSL 账户或反向映射，
未导出、删除或恢复现有密钥。C3/C4、tag、GitHub Release 和 AppGallery 未推进。

收尾只读审计确认原密钥对存在、Downloads 已恢复未授权、终端输入可见；两份冻结 clone
仍干净且 commit/tree 不变，原 C2 HAP 与 §8.39 七份证据哈希未变。新调试 HAP 已独立保留，
本轮报告哈希写入 `closing-audit.json`。未读取或比较私钥正文，不将文件存在当成恢复验证。

### 8.41 授权后默认 ECDSA 命名验证通过（2026-09-09）

维护者在当前对话重新确认允许测试后，执行一次
`verify-host-identity-pc.ps1 -OpenSshCompatibility -DefaultEcdsa -PreserveExistingEd25519`。
使用 §8.40 已保留的精确调试 HAP，SHA-256 仍为
`2133ab5779aee14ddb741063d3a5d7d7af305f317f0ed6979af97804d02550eb`。
本地证据为 `build/verification/key-export-permission-20260909/default-ecdsa/`。
单次约 286.6 秒完成，11 个业务检查和清理通过，未修改运行中的验收脚本、未追加重试。

原 `id_ed25519` 先经产品导出，观察到 awaited export 成功标记；备份所有者确认私钥及公钥
匹配后，才通过产品删除。受控 OpenSSH 临时账户只安装当前 ECDSA 公钥，Host 显式绑定、
移除绑定后默认 ECDSA 的重启前后认证，以及恢复显式绑定均通过。
finally 经产品导入原密钥并重启，私钥字节、公钥指纹和 Host 配置摘要一致；临时 ECDSA、
导入源及敏感备份缺席审计通过。备份未保留，测试账户、Host/known-host、反向映射和屏幕
超时策略已清理或恢复，Downloads 恢复原始未授权状态，终端输入可见。

18 条普通命令均一次输入、一次 Enter、零不匹配，`harnessStability=stable`。成功记录为
`diagnostic / releaseEligible=false`，不是原正式失败的补填，也不构成完整 C3。
原报告 SHA-256 为
`04f132d3cd40a98a7680f8768239288a2c36d31cc15d1f01ae69af844b5f33c6`。
`authorized-run-closing-audit.json` 再次只读确认原密钥对存在、临时 ECDSA 缺席、
Downloads 未授权、终端可见，以及两份冻结 clone、既有正式证据和本轮 HAP 身份不变。
私钥字节一致性来自产品备份所有者，不从调试 shell 读取或打印私钥。

本轮重新运行 35 项导出/权限边界反例；产品与验收代码未再改变。修复与 §8.39–8.41 记录
组成同一个 PR，完成聚焦软件检查后合并。没有用户可见功能变化，不增改 Changelog 或指南。
下一批按 R4 建立合并后的精确候选，不扩大工具兼容白名单。未运行 Mosh、切 WiFi、
合盖或调用模型，未进入 C4、tag、GitHub Release 或 AppGallery。

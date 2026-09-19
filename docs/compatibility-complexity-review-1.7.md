# 1.7 兼容性复杂度审查

后续状态：下文是删除前的审查基线；09-19 替换批已移除 Web/Bridge/快照及 xterm
专用依赖，debug/release 均使用原生路径。当前实现和证据见
[迁移审计](native-terminal-migration-1.7.md)；不以保留历史分析授权恢复旧路径。

2026-09-19。只读审查当前 `codex/1.7-native-terminal-runtime` 工作树，HEAD 为
`1036320f3889d943a5e799bbd31776d8add30a63`，包含未提交的原生开发改动。
本文保存事实和取舍，执行任务只在 [Next Work](next-work.md)。未修改产品、工具实现或
上游依赖，未使用测试机；不是一次完整安全审计，也不证明所有历史措施都曾单独获批。

## 结论与优先级

最大的长期成本来自 Web/native 并存及 Web 专属的补丁、恢复和验证链。它们目前服务
已交付的 release 路径和分阶段替换，不是 native GPU 失败时的自动兜底。完整替换门通过后，
应成批删除旧链，而不是把双后端固化为产品能力。

当前原生 renderer 只创建 GLES 3 / RGBA8 路径，没有发现 CPU 显示后端、备用 VT 引擎、按
机型选择后端或降低 EGL 格式的分支。字体栅格化生成图集使用系统 Drawing 的 bitmap，
随后上传 GPU；这段正常文字路径不能误认为已撤销的 CPU 显示兜底。

低成本清理候选是旧归档缓存导入和旧部署入口。它们收益有限，不应打断搜索体验修复。
必要的标准语义、数据迁移和已验证生命周期恢复保留；没有确认依据的项目标明待核实，
不根据命名中的 fallback、legacy 或 compatibility 推定违规。

## 事实清单与建议

源码位置以文件和符号为准，避免行号随开发漂移。确认依据优先引用当前原则、合同和
已有决策记录；历史已合入只能证明措施存在，不能代替维护者对新增兼容成本的明确确认。

| 项目与源码位置 | 场景、证据及确认依据 | 成本与建议、删除影响和验证边界 |
| --- | --- | --- |
| 原生 GPU/CPU 后端：`TerminalRenderer.cpp::createGpu/draw/glyph` | §4.8 和 Next Work 的 09-19 决策明确撤销 CPU 显示兜底。当前只有一套 GLES 显示链，未发现 NativeBuffer 显示分支 | **已撤销，不恢复。** 保留系统字形栅格化与 GPU 图集。持续 GPU 失败允许不可用，不再扩大故障矩阵 |
| 原生有界恢复：`TerminalRenderer.cpp::draw`、`NativeTerminalController.ets::recoverDisplay/retryDisplay` | 最多两次局部绘制尝试；Surface 自动重建有 30 秒限流，用户显式重试复用同一路径。§4.8 保留正常生命周期和可恢复 context loss；已有 lifecycle-review/egl-recovery 证据 | **保留。** 维护代次、清理与限流有成本，但删除会损害已验证恢复。只在修改该链时重验；不新增后端或重试层 |
| Web/native 并存：`entry/build-profile.json5`、`TerminalPane.ets`、`TerminalSurfaceController.ets` | debug 选择 native、release 仍选择 Web；并非 native 失败后切 Web。Next Work 和 Changelog 明确完整替换门前保留旧 release | **替换后成批删除。高维护成本。** 双显示、Bridge/原生分派、两套工具证据持续分叉；替换前删除会失去当前 release 实现。届时核对 release 构建、资产/许可证及核心交互，不增加运行时后端设置 |
| WebGL→DOM：`rawfile/terminal.html::fallbackToDomRenderer/activateDefaultRenderer` | WebGL 初始化失败或 context loss 进入 DOM；产品原则 §4.8/§5.5 明确允许尚在交付的 Web 故障回退 | **随 Web 退出。** 当前删掉会撤回 Web 故障恢复合同；不把它迁移为 native CPU renderer，不为旧 Web 继续扩展设备覆盖 |
| xterm 默认背景补丁：`tools/web-terminal/patches/xterm-webgl-default-background.mjs` | 原则 §4.7/§5.5、固定版本/哈希/唯一命中及语义测试；修正非颜色属性导致的不透明背景 | **随 Web 退出，或在依赖升级时审查删除。** 是真实颜色正确性问题；提前删除会重现历史缺陷。未联网核对上游最新修复，不声称今天已可去补丁 |
| xterm 输入顺序补丁：`tools/web-terminal/patches/xterm-input-order.mjs` | 现有架构说明及固定真实输入语料；补丁内明确上游版本漂移时重审、同语料通过后删除。此次未重新调取最初授权对话 | **随 Web 退出。** 涉及组合输入和提交顺序，不能因是本地补丁就删除；确认记录范围有限，不等于未获授权。不复制其 DOM/textarea 补偿到原生 IME |
| Web 快照与 Mosh 页面替换：`TerminalSurfaceController.ets` 的 Web 分支及 `TerminalOutputBuffer` | Web renderer 进程重建需要快照/回放；原生 VT 已跨 Surface 保留。Web 的页面 ACK/回放顺序仍由旧 release 使用 | **删实现，保留结果合同。** 随 Web 清掉快照、重放和 Web 专属状态；保留 Session 隔离、尾部消费和页面恢复，不把 Web 恢复复制进原生 |
| 原生构建叠加：`tools/build-terminal-native.ps1` | 固定 Ghostty 静态安装入口、OHOS 最终 SDK runtime、`link_libc`、uucode 优化传递；09-18 构建修复及性能记录给出实际构建、回收和 Unicode 证据。无 SIMD 是原型既定进入基线 | **保留但明确升级审计责任。中等长期成本。** 属于唯一目标平台集成，不是支持额外平台。改上游输入时逐项复核锚点、宿主合同、ARM64 严格链接和受影响真机链；不称“没有 fork”就没有补丁维护成本 |
| 旧归档缓存导入：`tools/native-terminal-inputs.ps1::Get-LeanTTYNativeArchive` | 新缓存缺失时，从 `build/native-terminal/dist` 校验 SHA-256 后导入。属于旧开发缓存迁移；本轮未找到单独确认或永久保留要求 | **可删除候选，低优先级。** 删除后旧缓存用户需要一次正式预热；固定离线缓存与哈希校验保留。只需验证新缓存命中、缺失报错及预热，不需要产品真机 |
| 旧部署入口：`tools/deploy-usb.ps1` | 单纯转发 `dev-pc.ps1 -RequireUsb`，未复制部署实现。历史调用者是否还需要它，本轮未证实 | **待核实或保留薄包装，收益低。** 删除可能破坏旧命令/文档；先查调用者再决定，不为几十行包装发起全仓工具改造 |
| 持久化旧数据迁移：`DurableStateManager.ets::finishLegacyMigration`、`SshEnvironment.ets` | 架构明确第一次升级采集已验证 config/known_hosts/key 与设置，之后以 durable store 为权威 | **保留。** 有长期旧版本升级测试成本，但删除涉及用户配置、信任与密钥连续性。缺少旧版升级用户分布，不能以当前开发机已经迁移作为删除证据 |
| 平台能力失败处理：`EntryAbility.ets` 的标题按钮默认 140、透明度不可用转不透明、吸附度量缺失跳过 | 简单默认值/catch，沿同一 UI 路径；不是替代窗口系统。未找到每个默认值的单独批准记录 | **保留小型失败处理，确认依据待核实。** 不透明牺牲视觉效果但保留可用性；删默认留白可能遮挡系统按钮。未证实它们造成显著复杂度，不新增系统版本/机型分支 |
| 系统字体回退及颜色字形：`TerminalRenderer.cpp::glyph` | 系统 Typography 负责 Unicode shaping/fallback；LeanTTY 只管 cell span、图集、彩色 glyph tint。既有中英文/emoji/裁切证据 | **必要标准支持。** 删除会丢 Unicode/emoji 显示；不自行创建第二套字体引擎，也不把系统 fallback 视作 CPU 显示兜底 |
| Mosh 会话临时页：`TerminalSurfaceController.ets::beginMoshSessionPage`、`TerminalRuntime` regular/temporary VT | [MCRS-008](design/mosh-client-rs-integration-issues.md) 解释库输出是当前画面而非 SSH 字节流；现有产品合同要求整个 Mosh 会话结束后恢复原页，临时页零历史 | **已明确的协议差异，保留。** 两个 VT 是隔离不同页面，不是备用后端。删除会污染本地历史；保持共用核心，不分析应用名称或猜 Vim/less 边界 |
| SSH 认证与 SFTP 失败分支：`leantty_ssh/src/lib.rs::run_authentication`、`src/transfer.rs` | 当前认证委托 russh 和核心认证状态机；传输用独占临时文件、普通 rename 及失败分类/清理。本次检查未发现为 rename 不支持而直接覆盖目标的第二条写入路径 | **核心正确性，保留。** 不能以减少分支为由削弱信任、取消、文件冲突或清理。只检查项目自有实现，未对全部 russh/mosh 依赖内部算法做穷尽审计 |

## 实施边界

本次建议不授权立即删 Web、旧数据迁移或已发布能力。Web 退出属于既定原生替换收口，
先闭合体验和实体键鼠门；缓存/入口清理只有在实际触发且投入划算时再进入执行。
新增后端、平台特例、适配层或实现性兼容探针仍按产品原则第三节先确认。

本地源码身份与改动分类保存在 `build/verification/1.7-offline-migration-audit/`。
跨版本的已知证据保持原包身份；本审查未把旧测试提升为当前候选通过，也未重新运行正式矩阵。

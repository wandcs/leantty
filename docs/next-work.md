# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-22
>
> 当前 milestone：[`1.5 — SSH 连接可靠性、诊断与资产互操作`](roadmap.md)
>
> 当前工程阶段：1.5 产品开发范围已闭合；执行已授权的 Agent 可维护性重构，release preparation 仍需单独授权
>
> 上位规则：[`project-principles.md`](project-principles.md)
>
> 测试权威：[`quality-strategy.md`](quality-strategy.md)

本文件只保留尚未完成、已经授权的活动工作，并按实际依赖顺序执行。完成事实进入相应
规范、设计文档和 Git 历史；旧 checkbox、定向实现证据、WIP 技术方案及后续 milestone
不在这里维护第二份清单。

## 当前发布基线

`v1.3.0` 已于 2026-08-17 通过 AppGallery 审核并正式上架。`v1.4.0` 已由不可变签名
标签、精确发布源和 GitHub Release 冻结，production APP、review-test HAP、manifest、
哈希和发布材料已经完成；维护者于 2026-08-22 确认匹配的 production APP 已通过
AppGallery 审核并正式上架。当前工作不修改 `v1.4.0` 的发布身份，也不补做新的 1.4
产品范围。

1.4 发布复盘形成的验收与发布工具链优化是 1.5 的第一项工程基础：稳定规则写入
`quality-strategy.md`，研究、红绿证据和量化结果写入 `test-release-efficiency.md`。它不改变
用户可见产品源，也不能替代 1.5 产品范围确认。

## 1.5 当前状态

`ConnectTimeout`、基本 SSH escape、`ServerAliveInterval/ServerAliveCountMax`、安全 `ssh -v`、
受控 config import/export、`ssh-keygen -c` 和现有 OpenSSH ECDSA P-256/P-384/P-521 Identity
导入/使用已分别完成专项实现、映射软件门、签名 ARM64 debug HAP 与所需的物理 HarmonyOS PC
闭环。ECDSA 复用既有 Identity、口令、comment、durable asset、direct/ProxyJump、`put/get` 和
删除路径，不新增生成入口或第二套状态。

`AddressFamily` / `ssh -4/-6` 因当前设备没有可重复的全局 IPv6 fixture 路径而暂缓；
UpdateHostKeys 因 russh 缺少完整 proof request/reply、session binding 和验签公开 API 而按安全
停止条件裁剪。专项完成事实和重新进入条件保留在 roadmap 与对应设计文档，不在本文件复制历史
checklist。

当前没有继续授权的 1.5 产品开发项。ECDSA 生成、certificate、FIDO/PKCS#11 和通用算法覆盖仍
不进入范围。下面授权的是不改变产品范围的 Agent 可维护性重构。1.5 正式候选、版本元数据、完整
验证、production 签名、GitHub Release 和 AppGallery 交付必须由维护者单独启动 release
preparation；开发期签名 HAP 和局部真机诊断证据不能自动推导为正式候选或商店能力。推广手册
只提供稳定工作方法；未单独写入本文件的 Pxx 不属于活动任务。

## Agent 可维护性重构

按以下依赖顺序逐项执行；只有最前面的未完成分组是当前工作。每组先用现有行为建立回归基线，
再移动职责，完成后同步权威文档和验证证据并从本文件删除该分组。重构不得借机增加产品能力、
通用框架、第二套状态或无真实调用方的抽象。

### M2 Rust SSH Session 执行边界

- [ ] 在 M1 的上层生命周期契约稳定后，为 `leantty_ssh::run_session` 的握手、认证、channel 建立、
  steady-state I/O、控制请求、关闭和错误映射补齐阶段化行为测试。
- [ ] 按协议阶段拆分 `run_session`，让每个函数只有一个失败/清理责任，并保持结构化控制事件、
  backpressure、超时、ProxyJump 与 SFTP 交接契约不变；不引入新的传输抽象层。
- [ ] 通过 `rust-core`、`rust-native`、`ssh-flow`、ARM64 构建以及受影响 direct/ProxyJump 真机
  主路径，确认事件顺序、错误层级和资源关闭行为没有漂移。

可观察完成条件：顶层 `run_session` 只表达阶段顺序和统一收尾；阶段函数可以独立测试；任一错误
都能从唯一出口映射到既有事件契约，不靠复制清理分支维持行为。

### M3 Workspace 与 Pane 运行时所有权

- [ ] 为 tab/pane 创建、切换、分割、关闭、恢复、前后台和 Session 销毁建立 workspace 事件链测试，
  明确 `AppViewModel`、`PaneRuntime` 与页面状态当前各自承担的契约。
- [ ] 消除 `Index.ets` 与 `AppViewModel` 对活动 tab/pane、运行时集合和销毁顺序的重复所有权；保留
  一个 workspace 权威模型，页面只负责渲染、焦点和系统事件适配，Session 仍由各 Pane 独占。
- [ ] 通过 `arkts`、workspace/terminal 相关聚焦门，并对焦点、键盘、窗口、恢复和关闭场景运行
  最小物理 PC 验证。

可观察完成条件：给定任一 tab/pane ID 都只有一个位置决定其存在、活动状态和销毁；页面重建不会
复制运行时状态；关闭或恢复不会留下孤立 Session、surface 或事件订阅。

### M4 测试职责与行为契约

- [ ] 按 SSH lifecycle、workspace、terminal interaction、transfer、key management 和 formatting
  等真实所有者拆分 `InteractionFixes.test.ets`，同步 `List.test.ets`，保留问题来源但取消“历史修复
  大杂烩”作为测试边界。
- [ ] 盘点 PowerShell/ArkTS 中读取源码文本、私有名称或调用形状的断言；能由公开输出、状态转换、
  构建或真机行为证明的，改为行为测试。只保留安全策略、依赖边界和生成物契约所必需的静态扫描。
- [ ] 将保留的静态规则登记到聚焦测试组并写明它保护的稳定契约；删除重复测试和仅冻结偶然实现
  细节的断言，确保失败信息直接指出受损责任。

可观察完成条件：没有跨多个所有者的超大 catch-all 测试文件；行为重构不再因私有命名或调用顺序
变化误报；必要的安全/架构静态门仍可独立运行，且原有可观察覆盖不下降。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到权威文档和 Git 历史，并从本文件删除。
2. 每项任务必须说明可观察完成条件；代码修改、一次通过、构建、安装、窗口出现或 HDC 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

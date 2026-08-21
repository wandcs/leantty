# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-21
>
> 当前 milestone：[`1.5 — SSH 连接可靠性、诊断与资产互操作`](roadmap.md)
>
> 当前工程阶段：启动 1.5 第六个产品切片的 config import/export 进入门禁
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
哈希和发布材料已经完成；维护者已于 2026-08-21 在 AppGallery 提交审核，当前等待审核
结果。项目只有在维护者报告结果后才记录新的商店状态。当前工作不修改 `v1.4.0` 的发布
身份，也不补做新的 1.4 产品范围。

1.4 发布复盘形成的验收与发布工具链优化是 1.5 的第一项工程基础：稳定规则写入
`quality-strategy.md`，研究、红绿证据和量化结果写入 `test-release-efficiency.md`。它不改变
用户可见产品源，也不能替代 1.5 产品范围确认。

## 1.5 当前活动工作

### 第六个切片：受控 config import/export 进入门禁

用户从已有 OpenSSH 环境迁移到 HarmonyOS PC 时，应能把一份明确授权的 config 安全并入
LeanTTY 唯一 `~/.ssh/config`，并在需要时把这份资产导出备份；不能因此建立第二份配置权威、
静默忽略会改变连接安全或路由的 directive，或覆盖用户无法恢复的原文。本切片先建立真实样本、
文件授权边界、round-trip 合同和失败恢复门禁，再决定最小命令入口。

1. [ ] 收集受控真实 config 样本，覆盖注释、空白、重复 Host pattern、通配符、非默认端口、
   `ProxyJump`、当前受支持 directive、未知 directive、`Include`、`Match`、token expansion 与
   CRLF/LF；按“连接语义关键 / 可原样保留 / 必须拒绝”建立样本目录。
2. [ ] 审计 HarmonyOS 文件选择/保存授权与当前 Downloads/文件传输边界，决定 import/export 的
   单次用户动作、取消、同名冲突和可恢复失败语义；不得申请目录级常驻扫描权限或后台同步。
3. [ ] 验证当前 `SshConfig` parser/writer 能否在导入、后续 `host add|set|rm` 和导出后字节级保留
   非 LeanTTY 管理原文；建立 parse → validate → atomic replace → reopen 的故障注入与 round-trip
   fixture，禁止半写、重复权威和关键 directive 静默降级。
4. [ ] 基于证据形成专项方案并做进入/裁剪决定。若进入，只增加局部 `config import/export`，
   复用唯一 config 和现有文件授权；不支持 `ssh -F`、通用文件管理器、目录监听、云同步或第二套
   Host 数据库。

`ConnectTimeout`、基本 SSH escape 与 `ServerAliveInterval/ServerAliveCountMax` 已完成并归档到
专项设计。`AddressFamily` / `ssh -4/-6` 已完成标准基线，但当前物理 PC 没有全局 IPv6 默认
路由，HDC reverse 也没有提供可用的 `::1` SSH fixture；按真机进入门禁暂不实现，不能以 parser
或字段传播测试代替。UpdateHostKeys 已完成标准与 russh `0.62.5` 能力审计；依赖缺少完整 proof
request/reply、session binding 和验签公开 API，因此按安全停止条件裁剪，重新进入条件记录在
[`design/update-host-keys.md`](design/update-host-keys.md)。安全 `ssh -v` 已完成固定事件、脱敏、
direct/ProxyJump 真机闭环，见 [`design/ssh-diagnostics.md`](design/ssh-diagnostics.md)。除本节
晋级的 config import/export 门禁外，`ssh-keygen -c` 和 ECDSA 互操作仍是候选集合，不因 1.5
milestone 已启动而整体获得实现授权。
推广手册只提供稳定工作方法；没有单独写入本文件的 Pxx 不属于当前活动任务。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到权威文档和 Git 历史，并从本文件删除。
2. 每项任务必须说明可观察完成条件；代码修改、一次通过、构建、安装、窗口出现或 HDC 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

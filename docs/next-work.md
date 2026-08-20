# LeanTTY 当前工作

> 状态：唯一有效的项目 TODO
>
> 更新日期：2026-08-21
>
> 当前 milestone：[`1.5 — SSH 连接可靠性、诊断与资产互操作`](roadmap.md)
>
> 当前工程阶段：验证并配置化 1.5 第三个产品切片的现有 SSH keepalive
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

### 第三个切片：验证并配置化现有 SSH keepalive

用户在 Wi-Fi、休眠恢复、NAT 或链路黑洞导致 SSH 连接半开时，应在可理解的有限时间内得到
明确断开并沿用现有重连路径，而不是让 Pane 永久停在看似 connected 的状态。这个结果必须
使用 SSH 加密通道内的 server-alive 请求，不能以 TCP keepalive、定时写 shell 字节、自动重连
或后台 Session 代替。

LeanTTY 当前 direct、ProxyJump target 和文件传输连接已经由同一个 russh 配置固定启用
`30s` interval / `3` count；这不是待新增的第二套计时机制。OpenSSH 的配置默认是
`ServerAliveInterval 0` / `ServerAliveCountMax 3`，而 russh `0.62.5` 在达到 `max` 后的下一次
interval 才报告 `KeepaliveTimeout`，不能把两者当成已经等价。这个切片只考虑唯一 OpenSSH
config 中的标准 `ServerAliveInterval` 与
`ServerAliveCountMax`。它不增加通用 `-o`、网络自动切换、Session roaming、自动重试、全局
定时器框架或第二套连接状态；jump 和 target 是否分别需要 keepalive，必须由 russh 能力和受控
半开证据决定，不能从字段命名猜测。

1. [x] 建立 OpenSSH 与 russh 语义基线：OpenSSH 在未收到服务端数据后发送加密通道内请求，
   interval `0` 关闭、count 默认 `3`；russh 发送 `keepalive@openssh.com`、任意收到的 SSH packet
   都复位计数，并在 `alive_timeouts > keepalive_max` 时报告超时。现有固定 `30s/3` 配置覆盖
   direct、ProxyJump target 和文件传输连接；jump transport 仍须由受控半开证据决定。
2. [ ] 扩展仓库受控 SSH fixture，以传输层单向丢包分别模拟正常应答、目标半开、
   jump 半开和普通远端静默；先在桌面与物理 PC 上证明“仍连接但请求无应答”可重复，不能以
   主动 close、进程退出、端口拒绝或短 `ConnectTimeout` 冒充半开。direct target 已由桌面
   `100ms/3` 时序测试和物理 PC 未改动 `30s/3` 诊断证明；jump 分层与普通静默仍待闭合。
3. [ ] 形成专项方案并锁定最小 Host 入口、有效范围、错误文案、断开计时和 terminal 保留语义；
   若 russh 没有稳定的 SSH-level keepalive/应答可观察接口，或 fixture 不能证明真实黑洞路径，
   停在门禁并裁剪，不新增自定义协议或周期 shell 数据。
4. [ ] 门禁通过后才实现 config 解析/编辑和现有 russh 配置传播；不新增 ArkTS timer 或第二套
   connection lifecycle。未显式配置时先保留 LeanTTY 现有 `30s/3` 可靠性默认，显式 interval
   `0` 关闭；只有证据证明改变默认更可靠时才重新评估。
5. [ ] 补齐 ArkTS/Rust/fixture 自动化与最小 ARM64 build，再在物理 PC 上验证正常静默连接不被
   误断、确定半开按配置断开、现有默认与显式关闭、direct/ProxyJump 分层、休眠恢复、立即重连和双 Pane
   隔离；只有 server-alive 请求/应答与用户可见 Session 结果共同成立才算通过。

`ConnectTimeout` 与基本 SSH escape 已完成并归档到专项设计。`AddressFamily` / `ssh -4/-6`
已完成标准基线，
但当前物理 PC 没有全局 IPv6 默认路由，HDC reverse 也没有提供可用的 `::1` SSH fixture；按
真机进入门禁暂不实现，不能以 parser 或字段传播测试代替。除本节已经晋级的 keepalive 外，
路线图中的主机密钥轮换、诊断、config 导入导出和 ECDSA 互操作仍是候选集合，不因 1.5
milestone 已启动而整体获得
实现授权。推广手册也只提供稳定工作方法；没有单独写入本文件的 Pxx 不属于当前活动任务。

## 维护规则

1. 只保留未完成且已授权工作；完成后把事实同步到权威文档和 Git 历史，并从本文件删除。
2. 每项任务必须说明可观察完成条件；代码修改、一次通过、构建、安装、窗口出现或 HDC 成功
   都不能替代真实端到端证据。
3. `docs/archive/`、历史 checkbox、WIP 方案和未写入本文的候选不授权实现。

# 1.7 终端与会话架构边界

> 状态：Accepted；1.7 架构设计基线，尚未实现或通过运行验证
>
> 设计日期：2026-09-11；原型结果交接：2026-09-17
>
> 上位规则：[产品原则](../project-principles.md)、[编码规范](../coding-guide.md)、
> [1.7 路线图](../roadmap.md)。活动工作只在 [next-work.md](../next-work.md) 维护。
>
> 本文完成“明确架构边界”；平台与依赖可行性见 [Ghostty 原生终端预研](ghostty-native-terminal.md)。
> [architecture.md](../architecture.md) 继续描述当前 Web 实现，不能把本文当成已实现架构。

## 决策与范围

保留 `Tab → Pane → Session`，在一个 Pane 的运行时内分清三种责任：会话控制决定与谁
交互，终端运行时解释和保存终端状态，显示表面负责把当前状态画出来。SSH 和 Mosh
通过最小终端交互合同接入；渲染代码不读取协议类型、连接状态或认证信息。

这次拆分直接解决现有 SSH/Mosh 与原生终端替换的耦合。未来本地会话可以使用同一终端
边界，但 1.7 不实现本地进程、PTY、HSL 直连或通用 Transport 框架。API 24、官方
Ghostty 自行封装、鸿蒙官方基础能力优先和 GLES 主路径继续沿用已确认决定。

本文的名称表达责任，除有独立生命周期的原生终端运行时外，不要求每一行都新建一个类、
接口或目录。`SessionViewModel` 可以继续作为会话编排入口，已有状态机不因名称含 SSH
就先做通用化改写。

## 当前代码给出的拆分依据

核对范围为 2026-09-11 工作树，包含未提交的 1.6 改动，不是已冻结或发布的版本。

| 当前入口 | 已存在的责任 | 1.7 调整 |
| --- | --- | --- |
| [ApplicationWorkspace](../../entry/src/main/ets/viewmodel/ApplicationWorkspace.ets)、[PaneRuntime](../../entry/src/main/ets/viewmodel/PaneRuntime.ets) | 进程内持有工作区；Pane 成对拥有 SessionViewModel 和 SurfaceController | 保留稳定所有权；原生终端状态由 Pane 生命周期持有，页面解绑仅释放显示与输入资源 |
| [SessionViewModel](../../entry/src/main/ets/viewmodel/SessionViewModel.ets)：`handleBridgeMessage`、`handleTerminalInput`、`finishSessionTerminalOwnership` | 同时处理 Bridge 消息、输入路由、认证、协议选择和终端边界复位 | 移除 Bridge 类型依赖；保留输入所有者与会话切换策略，通过终端合同执行复位 |
| [SshSession](../../entry/src/main/ets/model/ssh/SshSession.ets)、SshClient、[MoshClient](../../entry/src/main/ets/model/mosh/MoshClient.ets) | SshSession 是现有共享业务生命周期权威；具体客户端关联 native handle、认证轮次、数据与结束事件 | 保留当前允许的状态转换；Mosh 库继续拥有预测、状态同步、可达性和关闭协议 |
| [TerminalSurfaceController](../../entry/src/main/ets/model/terminal/TerminalSurfaceController.ets)：`beginMoshSessionPage`、`writeMoshBytes`、`endMoshSessionPage` | 显示控制器含 Mosh 页面切换策略、快照捕获与待输出队列 | 页面选择归会话控制；终端运行时提供明确的页面操作，GPU 不认识 Mosh |
| [TerminalOutputBuffer](../../entry/src/main/ets/model/terminal/TerminalOutputBuffer.ets) 与 TerminalBridge | 保存快照、隐藏时字节和背压状态，以恢复被销毁的 Web 终端 | 原生 VT 存活时继续消费输出；删除仅为 Web 恢复存在的快照与重放路径 |
| [terminal.html](../../entry/src/main/resources/rawfile/terminal.html)：`term.onData`、`writeTerminalPacket` | xterm 编码输入与协议回写；write 回调发送 ACK | 输入来源在新边界显式区分；解析完成与帧显示完成分开报告 |

`writeAck` 当前来自 xterm 的 write 完成回调，证明解析完成，不证明画面已显示。
这一点也已记录在 [Session 状态隔离合同](terminal-session-state-isolation.md)。原生接入
不应把 GPU 提交或垂直同步变成接收下一批终端字节的前提。

## 所有权与依赖方向

```text
ApplicationWorkspace → AppViewModel → Tab → Pane
  └─ PaneRuntime（该 Pane 的 Session 业务边界与统一销毁入口）
       ├─ SessionViewModel：会话控制与输入所有权
       │    ├─ ltty 命令编辑、认证交互、已有业务生命周期
       │    └─ SshClient / MoshClient → 现有 Rust 协议实现
       ├─ TerminalRuntime：原生终端状态与有序操作
       │    ├─ 常规终端：ltty、SSH normal buffer 与 scrollback
       │    └─ 按需临时终端：Mosh 会话页面
       └─ TerminalSurface：当前窗口资源，可解绑重建
            └─ XComponent / NativeWindow / EGL / GLES / 帧回调

具体会话输出 → TerminalRuntime → RenderState → GPU 表面
用户意图 → 输入所有者 → 本地命令、认证回答或具体会话
TerminalRuntime 协议回复 → 原会话的发送入口
TerminalRuntime 系统效果 → 现有安全策略 → System Services
```

这里的 Session 是 Pane 内的业务边界，不等于一次 SSH/Mosh 连接，也不等于一个
Ghostty 对象。同一 Pane 可以先后建立多个连接；Mosh 临时终端不会增加一个 Pane 或
另一个业务 Session。

| 状态或资源 | 唯一权威 | 生命周期与其他层可见内容 |
| --- | --- | --- |
| Tab/Pane 身份、选中位置、布局与最终关闭 | AppViewModel / PaneRuntime | 进程内工作区；UI 只持投影和用户意图 |
| 连接配置、认证轮次、主机校验和业务状态 | 现有 SshSession 与具体客户端各自职责 | 每次连接；渲染层看不到密码、Host、网络状态和重连配置 |
| 当前输入所有者、连接切换、SSH reset 与 Mosh 页面策略 | SessionViewModel | Pane 内串行编排；界面状态由权威状态派生，不另建通用 Session 状态机 |
| VT parser、单元格、normal/alternate buffer、scrollback、模式与逻辑颜色 | TerminalRuntime 内的官方 Ghostty 对象 | 常规终端随 Pane，临时终端随 Mosh 页面；不依赖窗口存在 |
| 终端视口、选区、搜索查询及结果 | TerminalRuntime 的终端交互状态 | 绑定具体终端；索引和结果从 VT 派生，有界、可失效，不保存第二份完整正文 |
| 实际内容区域、字号对应的 cell 尺寸与已提交行列数 | 原生终端布局逻辑 | 从系统测量和文字度量计算；会话仅保存最近已提交尺寸用于连接和 resize |
| 帧数据、字形缓存、纹理和 GPU context | 原生 renderer / TerminalSurface | 可重建派生数据；缓存说明预算和失效条件，不成为 VT 权威 |
| 焦点与系统 IME 连接、预编辑文本 | App Shell 焦点权威与鸿蒙输入适配 | 绑定当前 Pane、输入所有者和 Surface；预编辑不进入 VT 历史或会话 |
| 资产、剪贴板、通知、浏览器与窗口配置 | 原有 System Services | 继续服从现有权限和持久化合同；原生库不能自行取得这些权限 |

## 最小终端交互合同

这是内部语义合同，不是可插拔传输 SDK，也不冻结 C ABI 的具体函数签名。连接、认证、
信任确认、重连配置和 Mosh 可达性仍通过具体对象调用；共同边界仅覆盖终端交互。

| 方向与操作 | 数据与完成条件 | 失败或过期处理 |
| --- | --- | --- |
| 会话 → 终端：追加输出 | 原始字节、来源连接、目标终端、有序位置；每批入队全部接受或全部拒绝，VT 消费完成另行报告 | 队列满时调用方保有未接受数据并按序等待；不能保留或无法确定接受状态时结束该来源并报告，不能静默漏字后继续 |
| 会话控制 → 终端：本地输出 | 已格式化的 ltty/状态文本、明确页面；与远端输出及边界操作排序 | 不是任意远端内容的特权通道；错误消息也不能越过旧输出的结束屏障 |
| 输入适配 → 输入所有者：用户意图 | 按键、IME 已提交文本、粘贴、鼠标/焦点事件，保留种类与目标 | 过期输入不迁移到新的 Pane、密码轮次或连接；发送队列拒绝后阻止后续 Enter，不重发不确定输入 |
| 终端 → 原会话：协议回复 | 编码后的字节与来源连接/终端；进入该会话同一有界发送入口 | 绕过 ltty 解析和用户 escape 识别；原连接结束后不得投递给下一连接 |
| 布局 → 终端与会话：resize | 当前 Surface 实测区域与 cell 度量产生的有效行列；VT 提交后才把同一行列交给具体客户端 | 零尺寸/过期测量不覆盖有效值；发送失败明确返回，不能让 UI 猜测远端已成功 |
| 终端 → 会话：输出消费压力 | 当前队列压力及最新 pause/resume 意图 | SSH 使用现有输出流控；Mosh 使用库的消费/重绘机制，不暂停其 UDP 定时器或复制 SSH 语义 |
| 会话 → 会话控制/终端：有序结束 | 原因与最后已接受输出的位置；终端消费到该位置才完成结束屏障 | error 提示不等同于最后一批数据已到；缺少正常结束时只承诺已接受数据，异常不能伪装成完整交付 |
| 会话控制 → 终端：复位/页面切换 | 结束屏障后复位常规终端，或激活/释放临时终端；回调绑定本次切换 | 幂等、过期完成无效；失败保持输入关闭并显式报告，不把输入交给半复位状态 |

输出边界保持字节，不对任意网络分块逐块转成字符串。交互输入先按终端模式编码，再交给
具体会话；现有 ArkTS/Rust 写入使用字符串的接口，需要在实际接入时核对无损映射及拒绝
语义，不能把当前 string API 写成已经具备任意二进制输入能力。

Mosh 的“有序输出”指库交付给 LeanTTY 的终端显示字节；不承诺恢复服务端每一字节或
完整远端 scrollback。库可以按自身状态同步语义合并更新，LeanTTY 不自行丢弃已接受
的显示字节或另建预测、增量重排规则。

跨 Node-API/C ABI 的异步数据，初始方案在返回“接受”前复制进接收方拥有的有界缓冲。
借用的 Ghostty 字符串、行/单元格指针和回调参数不能跨回调或下一次更新保存；以后只有
测量证明值得时才改为显式所有权转移。ArkTS 只持受控 handle 和结构化消息，不读写
Ghostty 内部结构，也不通过 JSON 往返整屏 cell 数据。

## 输入与终端回写

输入先由现有焦点规则决定 Pane，再由会话控制决定所有者。搜索框和 IME 组合输入按现有
键盘合同消费自己的事件；终端快捷键、按键事件与文本提交不能分别发送同一次输入。

| 当前所有者 | 处理入口 | 隔离规则 |
| --- | --- | --- |
| 本地 `ltty>` | 现有命令编辑、补全、历史和 CommandParser | 仅此处解释 LeanTTY 命令；界面里的 `ltty>` 文本不是状态判据 |
| 认证/密钥交互 | 对应连接、layer、round 的输入逻辑 | 秘密仅短期持有，提交或取消后清理；不回显到 VT、搜索、快照或日志 |
| SSH 交互 | Ghostty 按当前终端模式编码 → SSH 用户 escape 策略 → SshClient | `Ctrl+C` 是交互输入；`~.` 等已有主动断开语义留在会话侧 |
| Mosh 交互 | 相同终端编码边界 → Mosh 用户 escape 策略 → MoshClient | 预测、状态同步与终端能力限制归 Mosh；不能绕过库直接模拟向远端 PTY 写入 |
| 连接准备、传输、关闭或页面切换 | 现有允许的取消/控制意图 | 不积攒输入等待未来模式解释；切换前取消预编辑并让迟到提交失效 |

终端协议回复有独立来源标记，与用户文本走同一个具体发送队列，但不通过命令解析、
命令历史或 escape 识别。回复在生成时绑定原连接，不能在异步回调到达时才查询“当前
连接”。Mosh 如何处理回复仍经 MoshClient 和库，不把两种协议的能力声明强行统一。
终端模式产生的鼠标和焦点报告也保留来源种类，直接进入具体发送入口；用户 escape
策略只处理用户按键/文本输入，不能误消费这些协议报告。

Ghostty 官方 [terminal.h](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/include/ghostty/vt/terminal.h)
提供终端回写和系统效果回调；这支持分开接入的设计，但不证明现有全部输入/OSC 合同已被
覆盖。能力声明仍由已实现且验证的集成决定，不能仅因换库就改报 `xterm-ghostty`。

## 常规终端与 Mosh 临时页面

**采用一个常规终端，加至多一个按需创建的临时终端。** 两者使用相同的 TerminalRuntime
与 GPU 渲染实现；临时终端用于现有 Mosh 页面合同，不建立页面栈或任意终端池。

- 常规终端保留 `ltty>` 与 SSH 的 normal 内容和 scrollback。SSH 结束时，在同一终端上
  按 [既有状态隔离合同](terminal-session-state-isolation.md) 复位模式和本地输出位置，
  再输出结果与提示符；不能通过销毁常规终端丢掉 SSH 历史。
- Mosh bootstrap/认证仍使用常规终端；第一批 Mosh 显示输出前，会话控制建立临时
  终端并激活它。常规终端及视口留在内存，所有 Mosh 重绘进入临时终端。
- Mosh 的 normal/alternate buffer 都属于临时终端。不能借用一个 Ghostty 对象的
  alternate buffer 实现整个 Mosh 页面，否则远端 TUI 的备用屏幕切换会与应用页面策略竞争。
- 临时页面的协议输出、交互期间的 escape 帮助和窗口重绘均明确指向临时终端。Mosh
  结束后先排空已接受输出，再释放临时终端、恢复常规页面，最后写入本地结果与提示符。
- 切换终端时关闭搜索并清理当前选区等短期交互；保留既有常规页面的内容/视口合同。
  字号或窗口在 Mosh 期间变化时，恢复页面前按最新有效布局处理尺寸，不发送给旧连接。

代价是 Mosh 期间同时保留两个 VT 对象。它替代 Web 快照、页面替换与恢复拼接的复杂度，
不扩大可见功能。临时终端不增加额外历史承诺；具体 scrollback 配置、内存上限和回收
成本由原型验证。若内存代价不可接受，应重新比较状态保存机制，不能把两种方案同时留作
长期路径，也不能用丢失常规历史通过验收。

## 输出、渲染与线程

每个终端的写入、输入编码、resize、复位、选区和查询进入一个串行执行域。协议 I/O
继续由现有 Rust 实现负责；UI 线程不承担 VT 解析、字体排版或等待 GPU。具体 worker
数量与批量预算由原型决定，不能据此改变单一写入者和有界队列的合同。

渲染按需取得当前终端的 RenderState，在原生侧处理文字和 GPU 提交。官方
[render.h](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/include/ghostty/vt/render.h)
要求更新时独占终端，之后可在 RenderState 自有内存上继续工作；行数据在下一次更新后
失效。因此不能持终端锁等待 GPU，也不能一边更新 RenderState 一边让 renderer 使用其
借用指针。帧交接必须有明确占用/释放规则；不要无界排队每一帧。

区分三种完成：

1. **接受输出**：本层已拥有数据并计入队列预算，不代表已解析。
2. **消费输出**：VT 已处理到指定位置，必要效果已按序排入其目标路径；用于流控与结束屏障，
   不等待网络回复、系统弹窗或下一帧。
3. **提交画面**：指定终端/Surface 的渲染版本已完成提交；用于绘制和真机证据，不能代替
   字节完整性或“用户已看到”的证据。

隐藏、最小化或 Surface 丢失时可以停止绘制，VT 和协议继续按系统允许的调度运行。
恢复只重绘当前状态，不重放已消费字节，避免重复协议回复、剪贴板和通知效果。帧可以
合并或跳过；已接受的终端字节、用户输入和结束顺序不能为刷新率让步。

队列压力超过高水位时反馈给具体来源，降到低水位再恢复。关闭/取消控制不能被满的数据
队列挡住；终端消费屏障仍须排在已接受数据之后。硬上限、分配失败或回调失败必须产生
可观察故障，不能在失去输入/输出后继续显示正常状态。

## 生命周期与迟到事件

| 事件 | 会话/终端行为 | Surface 与输入行为 |
| --- | --- | --- |
| Tab 切换或失焦 | 保留连接与 VT；按现有规则处理终端 focus reporting | 更新焦点、取消预编辑，停止不必要的绘制 |
| WindowStage/Page 或 GPU Surface 重建，进程仍存活 | 保留同一个 Pane、连接与 VT；不 reset，不重连 | 作废旧 Surface generation，重建平台资源并全量重绘 |
| SSH 结束/失败并返回 ltty | 收到有序结束，消费已接受输出，执行一次模式复位并写提示符 | 复位完成后才接受本地输入；不依赖下一次 VSync 才完成 |
| Mosh Interrupted/Responsive | 更新现有连接状态，保留同一个 Mosh 会话与临时终端 | 警告或恢复由业务投影驱动；不回到 ltty，不新建连接 |
| Mosh 结束/取消/失败 | 排空后恢复常规页面并写结果；释放临时终端和该连接 | 禁止旧临时页面输入进入 ltty |
| 重连 | 按具体协议结束旧连接、完成终端边界，再创建新连接身份 | 新连接不接收旧输入、认证回答、协议回复或回调 |
| 关闭 Pane/应用 | 唯一 owner 先禁止新输入，关闭具体会话，有界完成已接受输出及资源清理 | 不要求显示最后一帧或无意义的本地提示符；销毁全部终端与 Surface |
| 整个进程退出/被杀 | 内存会话、VT 和历史全部结束 | 仅按现有异常恢复合同恢复无敏感数据的工作区结构 |

正常结束次序为：停止接收新用户输入 → 具体会话的最后输出与结束事件 → 终端消费屏障 →
模式复位/页面恢复 → 本地结果与提示符 → 开放新输入。提前到达的错误状态可以立即反馈，
但不据此丢弃仍属于本次结束的末尾输出。关闭失败和强制终止必须保留真实失败原因。

标识按生命周期校验，不新增全局注册中心：

- **Pane 身份**：防止跨 Pane 投递；进程重启后的恢复结构使用新身份。
- **连接身份/代次**：绑定字节、认证、回复和关闭结果；接收端还检查该来源是否已结束。
- **终端 handle 与输入所有权代次**：防止常规/临时页面错投，以及认证/交互模式切换后的
  IME 迟到提交；终端销毁后 handle 失效。
- **Surface generation**：只管平台输入、尺寸、帧与资源回调。输出不因窗口 generation
  变化而失效；终端回复也不依赖 Surface 是否存在。

解绑回调、取消任务和标识检查共同生效。NativeWindow、EGL 对象和 callback userdata
在正在执行的回调退出前不能释放；不能只增加一个 generation 比较就假定消除了悬空指针。

## 系统效果与数据边界

原生终端解析出的远端请求仍是不可信输入。迁移时保持 [security-model.md](../security-model.md)
中的现有合同：本地复制/粘贴、OSC 52 写入限制、无剪贴板读取、需用户激活的安全 HTTP(S)
链接、有限的终端注意力协议，以及不含远端正文的系统通知。

终端封装在 native 入口完成长度、编码、消息种类和来源校验，只将允许的结构化效果交给
原有策略与 System Services。通知正文在原生边界内丢弃；必要的剪贴板内容仅为获准操作
短期传递。查询回复归原连接，标题是经过清理的显示投影，二者都不成为连接身份或状态。
库中新出现的剪贴板读取、通知能力或 shell integration 回调不自动获得产品授权。

终端正文、搜索查询/结果、命令历史、认证秘密和 Mosh 临时页面仍只在必要内存中保存。
帧缓存和故障诊断不进入持久恢复记录；Surface 恢复不能再次触发历史副作用。

## 实施入口与验证边界

独立原型先实现可用的原生终端、文字/GLES 和输入链；生产接入前只做必要的会话解耦。
旧 SurfaceController 适配终端合同时可以继续使用现有 Bridge、快照和 Mosh 页面机制，
不为过渡版本重写一遍。新的 VT/Surface 生命周期、临时 VT 和字节消费确认随原生实现落地。

原生正式替换时，按验证后的实际行为同步 architecture、coding-guide、security-model
及产品原则中描述当前 Web renderer 的条款。当前 WebGL/DOM 故障恢复合同仍适用于现有
实现；本文不能用来提前删除恢复路径。

责任迁移的具体入口是 SessionViewModel 的 Bridge 消息分发、输入路由、finish/reset，
SurfaceController 的 Mosh 页面策略、快照及流控，以及 terminal.html 的输入编码、选区、
搜索和系统效果。SSH/Mosh 协议库、文件传输数据路径、资产和工作区模型继续沿用。

| 验证层级 | 必须证明的行为 |
| --- | --- |
| L1 合同与纯逻辑 | 分块 UTF-8/控制序列与整体输入等价；解析 ACK 与帧提交可分离；队列拒绝可见；旧连接/页面/IME 回调不串入新所有者；回复不进命令或 escape 解析；结束屏障后才输出 ltty |
| L1 既有语义 | 复用 WorkspaceOwnership、SshSessionLifecycle、TerminalInteraction 及会话 reset 测试的行为断言；Mosh 临时页不与远端 alternate buffer 冲突，常规历史保留 |
| L2 原生边界 | 固定 Ghostty 构建/ABI，缓冲与回调寿命，RenderState 并发访问，分配/销毁失败；不依赖 WebView 的合成输入输出链 |
| L3 物理 ARM64 PC | SSH/Mosh/合成来源驱动同一个终端与 GPU 实现；键盘/IME/粘贴/搜索、resize、双 Pane、窗口重建和 GPU 故障恢复；真实尾部输出、历史与系统效果合同 |

以上是后续实现的验收约束，不表示本轮运行过这些场景。本轮完成依据是现有代码、已发布
交互合同和固定上游头文件的静态核对，以及文档一致性检查。具体活动顺序只在 next-work
中维护。

独立原型已经验证技术可行性和受控 GPU 恢复，见[研究结论](ghostty-native-terminal.md#2026-09-16-第四至八轮与原型结论)及[追加诊断](ghostty-native-terminal.md#2026-09-16-gpu-恢复链追加诊断)。产品接入仍需确定生产队列/scrollback/缓存预算、线程数量、文字映射细节、具体 ABI，以及实际 GPU
故障下如何保持可用。它们不改变本轮确定的所有权；如平台无法实现这些边界，或只能通过
丢失历史、弱化安全、破坏输入或增加长期双路径实现，则停止产品接入并回到方案取舍。

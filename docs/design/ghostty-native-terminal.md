# Ghostty 原生终端替换预研

> 状态：Accepted；ARM64/API 24 原型支持技术可行性；GPU 恢复缺口已定向修复验证，完整替换验收未通过
>
> milestone：1.7.0；规划范围见 [roadmap](../roadmap.md)，正式替换仍受原型进入条件约束
>
> 更新日期：2026-09-16
>
> 上位规则：[project-principles.md](../project-principles.md)、[coding-guide.md](../coding-guide.md)
>
> 授权边界：深入调研、架构设计与独立真机原型；本轮已部署并清理独立测试模块，未修改产品实现。
> 后续执行入口仍为 [next-work.md](../next-work.md)，本文不维护第二套活动 TODO。

## 结论与用户目标

建议继续推进：**API 24 + 官方 libghostty-vt + 自有 C ABI/Node-API 封装 + XComponent +
EGL/GLES 3.x，文字处理优先验证鸿蒙官方接口**。目标是改善终端启动、输入和持续输出体验，
同时减少 Web 终端桥接与恢复成本；是否值得替换，最终取决于同一物理 HarmonyOS PC 上的
收益和可靠性证据。

用户已明确：基于官方 Ghostty 开源库自行封装，不复用 `libghostty-ohos`；直接使用系统
GPU API；1.7 最低 API 定为 24；新增基础能力优先采用鸿蒙官方方案，明确证明不足后才引入
第三方。这些选择符合仅面向现代 ARM64 鸿蒙 PC、减少依赖与维护负担的项目方向。

HarfBuzz/FreeType 从默认方案移为有条件的备选。我们仍负责终端网格绘制与鸿蒙平台适配，
但不应先假定字体回退、排版和字形生成必须自行组织第三方库。官方 VT 库并不包含这些适配。
下文新增的官方文字候选会使用 Native Drawing 的文字接口生成字形缓存，整屏由 GLES 绘制；
这确实使用了 Native Drawing API，不能描述成完全无 Native Drawing 的方案。

原型采用一个 GLES 后端。Vulkan 有真实鸿蒙设备成功案例，保留为比较对象；
目前没有证据表明终端的二维批量绘制值得额外承担其资源同步、交换链和内存管理成本。
“现代设备”能缩小能力范围，不能消除 Surface 销毁、GPU context 丢失或系统回收。

本轮不扩展设备范围，不迁移 SSH/Mosh 协议栈，不增加本地 shell、通用渲染框架、Kitty
图像功能或渲染器设置。替换过程中必须保持已有命令、数据、交互、通知和透明语义。
[versioning.md](../versioning.md) 已明确：保持用户合同的 renderer 替换可以是 MINOR 版本。

## 通用终端方向与会话边界

2026-09-11 已完成 [终端与会话架构边界](terminal-session-boundaries.md)，作为 1.7 的
设计基线。它定义现有代码到目标责任的映射、输入输出合同、Mosh 页面所有权、解析与
渲染完成的区别、结束屏障、线程/资源寿命及系统效果安全边界；不表示已经实现。

保留 Tab/Pane/Session，终端状态独立于 Surface 存活；会话控制决定 `ltty>`、认证和
交互输入的所有者，以及 SSH 结束复位和 Mosh 临时页面切换。原生方案采用一个常规 VT，
Mosh 期间至多增加一个临时 VT；具体协议的认证、预测、状态同步和恢复仍由原有实现负责。

合成数据源、SSH 和 Mosh 应能驱动同一终端核心与 GPU 实现，更换来源不修改渲染代码。
VT 状态与 GPU Surface 的实际拆分随原生接入落地；具体本地执行环境不在本版本实现。
执行顺序以 [next-work.md](../next-work.md) 为准。

## 研究时的项目基线与历史记录

本轮核对的是带有 1.6.0 开发改动的工作区，并非已冻结 release commit。当前 manifest 为
1.6.0；目标 SDK 为 `6.1.1(24)`，最低兼容为 `6.0.2(22)`；本机 Native SDK 为
`6.1.1.125 / API 24`。这是当前 1.6 配置的事实；1.7 的最低 API 24 决定取代新方案此前的
API 22 兼容约束。本轮更新研究设计，项目配置随独立的 1.7 实现切片调整。

现有事件链与替换边界见 [architecture.md](../architecture.md)：

```text
ApplicationWorkspace → Tab → PaneRuntime
  ├─ SessionViewModel → SSH / Mosh
  └─ TerminalSurfaceController → OutputBuffer → Bridge → ArkWeb / xterm
```

- Session 与 WindowStage/页面具有不同生命周期；新 Surface 不能成为连接所有者。
- `terminal.html` 目前还承载输入、搜索、选择、链接、BEL、OSC 通知及剪贴板策略。
  去掉 xterm 的工作量包括这些合同，不只是把字符画出来。
- Mosh 自己的状态同步与预测归协议库所有。Ghostty 接管显示，不能据此删除 Mosh 的终端状态。
  Mosh 退出恢复原 `ltty>` 页面和历史的行为仍须保留。
- 项目已打包 JetBrains Mono Nerd Font Mono 的 Regular/Bold TTF，版本、OFL 和哈希已见
  [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。优先继续使用这两份字体。
- 当前 SSH 请求的 `TERM` 是 `xterm-256color`。新库有更多能力不等于可以改报
  `xterm-ghostty`；远端 terminfo 和实际能力声明需要单独核对。

此前调研位于 Codex 归档任务 **《分析 fish-agent 技术方案》**，任务 ID
`01a0437c-1847-77d2-a2ca-ca47ad76caa6`，日期 2026-08-27。本轮重新读取该记录，并核对：

- fish-agent 是 Go PTY/WebSocket 路径；不是 LeanTTY 的 SSH Transport 替代。
- fish-term 在提交 `0cab2b20b76aa1e84571f5c2f266d4e6117bf488` 使用 Ghostty VT、
  XComponent TEXTURE 与 Native Drawing 位图路径；不代表移植了 Ghostty 桌面 GPU renderer。
- `libghostty-ohos` 只作为历史架构参考，不进入依赖、封装或代码复用方案。

[1.6 性能诊断](../performance-diagnosis-1.6.md) 的 debug 冷启动首字 P50/P95 为
1492/1537 ms，warm 为 504/545 ms，各 20 个样本。这些是调查线索；不能和另一个系统、
构建类型或原型样本直接相减，长期泄漏和 OOM 也尚未由该报告证明。

## API 24 决策与预估收益

**1.7 的 target 与 compatible SDK 均按 `6.1.1(24)` 设计，不再比较 API 23，也不为
API 22 保留新 renderer 的兼容分支。** 基线选择已经确定，不以先跑性能实验为前置条件。

预估收益主要来自系统接入和维护便利，而非提高 API 数字就会提升 GPU 速度：

- API 24 的 [字符/字形范围映射接口](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkgraphics2d/capi-drawing-text-typography-h.md)
  `OH_Drawing_TypographyGetGlyphRangeForCharacterRangeWithBuffer` 与反向接口可返回完整的
  组合字符/字形范围。预期能减少组合字符、连字与终端 cell 之间的自制映射；Ghostty 网格
  仍是列宽、选择和光标的权威。UTF-8 参数是字节范围，UTF-16 是代码单元，不能混用。
- 最低 24 可直接使用 [AttachWithUIContext](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-ime-kit/capi-inputmethod-controller-capi-h.md)
  绑定当前页面的输入法上下文，不再为旧 Attach 维护版本分支。该接口始于 API 23，属于
  升至 24 后可统一使用的能力；它不自动解决焦点、候选框位置或代理对象寿命。
- 统一使用 API 24 的 SDK、公开接口和真机基线，减少低版本编译/运行分支及验证组合。
  系统文字能力随 OS 提供，预期还能省去独立文字库的跨编译、打包和版本维护。

`WithBuffer` 的命名不证明零分配、零拷贝或可直接复用调用者缓冲区；文档要求按对应
`ReleaseRangeBuffer`/`ReleaseArrayBuffer` 释放返回对象。不把尚未测量的分配收益算入结论。
GPU 版本、驱动、Surface 合成和字体效果仍须由 API 24 真机验证；这是实现验证，不重开
最低版本选择。安装范围将要求设备达到 API 24，符合用户接受提高系统门槛的决定。

## 组件选型与自研边界

| 责任 | 建议复用 | 我们负责 |
| --- | --- | --- |
| VT 解析、网格、模式、scrollback、宽字符语义 | 官方 `libghostty-vt` | 固定版本、内存预算、错误与产品合同适配 |
| 搜索、选择、键鼠/粘贴编码 | 官方 C API 中已公开的能力 | 快捷键、焦点、组合输入、搜索条、剪贴板及结果呈现 |
| 字体、文字 shaping 与字形生成 | 优先官方 FontCollection、Typography、Run、Font/TextBlob/Bitmap 接口 | 注册已有字体、终端 cell 对齐、字形缓存和失效规则；验证系统 fallback |
| 窗口与 GPU 提交 | XComponent、NativeWindow、EGL、GLES、VSync | Surface 生命周期、渲染线程、帧调度、恢复与合成 |
| 终端画面 | 自有 GLES renderer | 背景、字形 atlas、光标、选择、下划线、链接与透明语义 |
| ArkTS/native 边界 | OHOS Node-API、官方 Ghostty C ABI | 少量有类型的命令/事件、句柄、字节所有权与销毁顺序 |
| 输入法、剪贴板、焦点和业务 UI | 官方 IME、Pasteboard、ArkUI/XComponent | 终端输入语义、候选位置、快捷键仲裁及产品策略 |
| 连接、信任、协议状态 | 当前 russh、SFTP、Mosh 与业务所有者 | 只改显示接入点，保留认证/信任和协议生命周期 |

推荐 C++ 负责紧邻 OHOS C API 的 Surface/renderer/Node-API 封装，Zig 限于上游库，Rust
继续负责现有协议。先让字节通过一个有界 binary 接口进入 native；不以“零拷贝”为由
提前建立 Rust/C++ 通用回调总线，也不把每个 cell 转成 JSON 经过 ArkTS。

不建议同时引入 Skia、Qt、Flutter、Fontconfig 或通用 GPU 抽象。这些方案扩大依赖和
所有权范围；当前优先组合是 VT、系统文字能力和一个 GPU 后端。ArkUI 自定义组件提供承载、
布局和事件入口，不能代替 VT 协议、终端网格和字形缓存；它与官方文字 API、自有 GLES
绘制是不同职责。Unicode 分词、OpenType shaping、字形解析等基础算法不自研。

第三方引入条件：针对一个已有产品需求，记录官方公开能力的具体缺口、来源及最小复现，
或者记录官方路径在目标 PC 上无法满足正确性、性能或合理维护成本的证据。先核对用法、
当前平台资料和开发者讨论，做有限且能产生新证据的验证；不无限堆官方方案的绕路补丁。
满足条件后只替换不足的层，逐项判断 HarfBuzz 或 FreeType，不默认成对引入。
“没找到示例”“我们更熟悉这个库”或普通段落的结果不适合终端，单独都不足以证明官方能力缺失。
系统内部即使用了某个开源库，也不代表应用可链接它的私有符号；只依赖公开 SDK ABI。
本规则约束新替换方案的增量依赖，不顺带重写现有 SSH/Mosh 库；官方 Ghostty 是用户已选定的
终端核心，不因它不是华为库而重新选型。

## 官方 Ghostty 的嵌入与构建

本轮源码固定为官方提交
[`82938b633ba646db38591d969c3c526332bd7e65`](https://github.com/ghostty-org/ghostty/tree/82938b633ba646db38591d969c3c526332bd7e65)。
它是研究快照，不是承诺长期使用的发布版本。VT API 仍在变化，不能跟随 `main` 自动更新。

### 已确认的构建边界

1. 官方已有 [CMake 包装](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/CMakeLists.txt)，
   底层仍调用 `zig build -Demit-lib-vt`，提供 static/shared target 和跨目标构建入口。
   我们应接入该入口或其最小等价构建，不重新维护一套 Ghostty 源文件列表。
2. [build.zig.zon](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/build.zig.zon)
   声明最低 Zig `0.16.0`；[官方发布页](https://ziglang.org/download/) 有对应稳定版。
   先以精确 0.16.0 分发包和哈希验证，不能套用旧移植脚本的 Zig 版本。
3. [GhosttyZig.zig](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/build/GhosttyZig.zig)
   的 VT 依赖与桌面应用分开。`-Dsimd=false` 去掉 SIMD C/C++ 依赖；Unicode 表仍需要生成。
   `-Dvt-features=-kitty-graphics` 可关闭本轮不需要的图像处理与相关依赖。
4. [静态库构建](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/build/GhosttyLibVt.zig)
   会打包 compiler/UBSan runtime；非 freestanding 目标启用 PIC。因此不能随意用
   freestanding archive 替代 OHOS 构建，再假定一定能链接进 `.so`。

构建实验首选 **Zig 生成 ARM64 OHOS 静态库，由 OHOS SDK Clang 完成应用 `.so` 链接**。
先核对精确 Zig 的 `aarch64-linux-ohos` 支持、sysroot/libc 配置和实际链接符号；不能因为
Linux/musl 与 OHOS 接近，就认定两者完全等价。Zig 的旧 GitHub 镜像已包含 `ohos` ABI
名称，但镜像在 2025 年迁往 Codeberg，不能作为当前完整工具链支持的证明。

首个实验使用无 SIMD 的功能基线。它通过后才比较 SIMD 的可构建性与吞吐收益，不能
把无 SIMD 原型的速度外推成最终方案。所有依赖由锁定源码与哈希准备，构建不临时追远端分支。

### 分配器和 C ABI 是实际进入门

[allocator.h](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/include/ghostty/vt/allocator.h)
允许宿主提供 allocator；默认分配器随是否链接 libc 改变。静态库“不依赖外部 C++ 库”
不等于“不使用操作系统”。要核对分配/释放配对、返回缓冲区寿命、对齐、OOM 和错误返回。

本轮还发现一个需上游核对的具体差异：头文件把 allocator callback 的 `alignment`
描述为字节对齐值，而
[Zig 转接实现](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/lib/allocator.zig)
传入 `@intFromEnum(std.mem.Alignment)`。先用最小 C 调用观察并对照精确 Zig 定义，不能直接
照文字说明实现 `posix_memalign`。这只是静态合同疑点，本轮尚未运行复现或向上游提单。

封装只持有 opaque handle，库分配的对象按对应 API 释放。任何 C++ 异常或 Rust panic
都不能穿越 C 边界；远端字节、分配失败和迟到回调都必须有明确失败行为。

### 可直接利用的 VT 能力

- [render.h](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/include/ghostty/vt/render.h)
  提供 RenderState、行级 dirty 和分段 update。需要访问 Terminal 的阶段保持独占，后续
  在 RenderState 自有数据上完成；成功提交后再清 dirty，不持有终端锁等待 GPU。
- [search.h](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/include/ghostty/vt/search.h)
  支持增量搜索和 scrollback/reflow；大小写折叠范围是 ASCII。必须与现有
  [搜索合同](terminal-search.md) 对照，不能只因 API 存在就认定行为等价。
- [selection.h](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/include/ghostty/vt/selection.h)
  及相关 gesture/tracked-grid API 可以复用选择语义；我们的坐标转换、鼠标仲裁和复制仍需实现。
- [terminal.h](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/include/ghostty/vt/terminal.h)
  的回写和副作用 callback 要显式接入。默认未接 callback 不等于 OSC、标题、BEL、颜色/设备
  查询以及通知合同已完成；回写字节须回到同一 Session 的正确通道。
- [snapshot.h](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/include/ghostty/vt/snapshot.h)
  可用于需要的状态搬运。首选让 Terminal 实例跨 Surface 重建存活；不要为了沿用 Web
  恢复模型先复制一份长期快照，也不增加跨进程重启的终端内容持久化。

## GPU 与 XComponent 路线

官方 [renderer.zig](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/renderer.zig)
当前列出 Metal、OpenGL、WebGL；桌面
[OpenGL.zig](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/renderer/OpenGL.zig)
要求 OpenGL 4.3，并与桌面 app runtime 关联。OpenGL ES 3.x 不是它的替换链接库。
因此建议复用 VT 渲染数据，自己实现有限的 GLES 终端 renderer。

| 决策 | 当前建议 | 仍需证据 |
| --- | --- | --- |
| GPU API | EGL + GLES 3.x，先按 GLES 3.0 必要特性设计 | PC 实际版本、扩展、纹理上限、驱动与格式 |
| Surface 类型 | 首先验证 XComponent SURFACE | Pane 透明、圆角、搜索浮层、菜单与窗口合成 |
| TEXTURE | 仅在 SURFACE 的真实合成限制出现后比较 | 性能和合成差异；TEXTURE 本身并不意味着 CPU 渲染 |
| 帧调度 | native VSync + dirty 驱动；隐藏时停止提交 | 空闲唤醒、光标闪烁、窗口恢复和回调销毁 |
| 多 Pane | 一条 renderer 工作线程串行管理可见 Surface 作为原型候选 | 慢 swap 是否阻塞另一 Pane；上下文隔离与资源寿命 |
| Vulkan | 有条件的替代比较对象 | GLES 存在无法局部修复的缺陷，或可测收益足以覆盖额外成本 |

[OpenHarmony GLES 文档](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/native-lib/opengles.md)
提供 EGL/GLES 接入入口；[XComponent 指导](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/ui/napi-xcomponent-guidelines.md)
区分 SURFACE/TEXTURE，并说明透明合成和 SurfaceHolder 生命周期。本机 SDK 的
`OH_ArkUI_SurfaceHolder` 创建/销毁事件接口从 API 19 可用，纳入 API 24 的统一实现。
不应为了沿用老示例选用一套不适合当前生命周期的全局 NativeXComponent 字典。

帧的建议顺序：更新 VT → 提取 RenderState → shaping/更新 glyph atlas → 绘制背景和字形
批次 → 光标/选择/装饰 → swap。官方文字候选只在缓存未命中时生成小块字形像素，GPU
合成整屏；不走每帧整屏 Bitmap 上传。这里的字形生成候选是 CPU 路径，不声称整个文字链
都在 GPU 执行。Native Drawing 本身也有 GPU 能力，不能笼统等同于 CPU；当前不选它负责
终端整屏提交。首版不做 GPU 字体轮廓栅格化、复杂自定义
shader 或依赖扩展的高级优化。

透明验收必须包括默认背景、显式背景、文字、光标、选择和 Off 档。只对终端整体设置
opacity 会破坏既有语义。原生恢复边界遵循
[产品原则 §4.8](../project-principles.md#48-终端-renderer-选择) 的 09-19 决策。

GPU 失败的候选行为：停止使用旧 Surface/context，保留 VT 与 Session，封闭旧帧回调，
重建 GPU 资源后全量重画。重建持续失败时，显示明确的本地故障状态并阻止向不可见终端盲输。
维护者已明确接受 GPU 持续不可用时整个 App 无法使用；保持单一 GPU 渲染路径，不建设
CPU renderer 或其他显示兜底。正常窗口生命周期与可恢复 context loss 继续有界恢复。

另一个可靠性变化是故障影响范围：原生 VT/FFI 与应用同进程，native crash 可能直接终止
连接和整个工作区，不能把少一个 ArkWeb 进程直接解释成更可靠。原型要覆盖非法字节、
尺寸/预算上限、分配失败与销毁竞态；也不为尚未证明的隔离收益预建子进程和 IPC 框架。

## 字体与文字链路

优先验证的链路：已有 TTF → 官方 FontCollection/Typography 做字体回退与 shaping →
提取 Run 的字形、位置和实际字体 → 按 Ghostty cell 放置 → 缓存未命中时生成字形小位图 →
上传自有 glyph atlas → GLES 批量绘制。这是公开 API 可组合性的判断，尚不是运行成功结论。

### 公开接口已能覆盖的步骤

| 步骤 | 已核对的官方入口 | 适用边界 |
| --- | --- | --- |
| 注册已有字体、使用系统字体 | [FontCollection](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkgraphics2d/capi-drawing-font-collection-h.md)、SDK `OH_Drawing_RegisterFontBuffer` | 从 HAP 资源读取已有 Regular/Bold 字体，不先枚举或读取所有系统字体文件；CJK/emoji 优先交给系统回退 |
| 取得排版后的字形和位置 | [GetRunGlyphs / GetRunPositions / GetRunFont](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkgraphics2d/capi-drawing-text-run-h.md) | 前两项始于 18，实际字体对象始于 20；支持从回退后的 run 继续处理，不需猜测字体路径 |
| 把组合字符范围对应到字形 | API 24 的 Typography 字符/字形双向范围接口 | 建立 UTF-8 字节、字形和 cell 的映射；字形数量不等于字符数或列数 |
| 使用指定字体、字形和位置 | [TextBlobBuilderAllocRunPos](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkgraphics2d/capi-drawing-text-blob-h.md) | SDK 的 RunBuffer 含 glyphs 与 pos；BuilderMake 后不得继续使用其临时指针 |
| 生成可上传的字形像素 | [CanvasBind / CanvasDrawTextBlob](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkgraphics2d/capi-drawing-canvas-h.md) + [BitmapGetPixels / BitmapCreateFromPixels](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkgraphics2d/capi-drawing-bitmap-h.md) | Canvas 绑定 Bitmap 明确是 CPU 绘制；可取得像素或使用应用申请的内存，再上传 GLES；尚未证明所有字体格式与透明效果都满足需求 |

`TextBlob` 本身不会替缺失字形完成字体回退。必须先用 Typography 得到实际字体和字形，
再构造 TextBlob；不能直接把所有 UTF-8 文本交给主字体的 TextBlob，然后把缺字误判为系统不足。
官方 Run 返回的字体按 `FontDestroy` 释放，字形和位置数组使用对应销毁接口。
多个排版构造器复用字体集时用 `CreateSharedFontCollection`；普通 `CreateFontCollection`
明确只供一个排版构造器使用。“可共享”不等于可跨线程无锁调用，原型先归一个工作线程。

### 需要由最小原型回答的问题

- 系统排版结果能否保持 Ghostty 的固定列、组合字符边界和已有文字顺序；按样式/run
  组织文字，避免逐 Unicode 码点 shaping 破坏上下文，也不让普通段落布局重新决定终端列宽。
- 实际回退字体能否通过 TextBlob 正确重绘 CJK、组合附加符、彩色 emoji/ZWJ、Nerd Font、
  Powerline 和块元素；核对粗斜体、基线、多个字号/DPI、透明背景及截图结果。
- 先采用灰度抗锯齿；彩色字形另按像素颜色处理。核对 RGBA/预乘 alpha、stride、负 bearing
  和裁切，不能只提取 alpha 后丢掉彩色 emoji。缓存按字体、字号/DPI、字形、变体与渲染模式
  区分并有界；不能把临时 Font 指针地址作为稳定字体身份。
- 重复字符、持续出现新字形和字号切换分别测量 shaping 次数、栅格化次数、缓存命中、
  CPU/PSS 与上传字节数。正常稳定画面只复用缓存；是否存在值得修复的系统开销由这些数据判断。

本轮未发现足以判定官方 shaping 或字形生成不能满足终端的证据。系统字体列表与
`FontInfo.path` 保留为必要时的诊断入口；公开列表可能不完整，首选路径不依赖读取系统字体文件。
不硬编码 `/system/fonts`，不扫描私有目录。

若出现明确缺口：shaping 问题只评估 [HarfBuzz](https://harfbuzz.github.io/what-is-harfbuzz.html)，
字形解析/栅格化问题只评估 [FreeType](https://freetype.org/)。两者都是成熟专项库，但尚未有
证据要求本项目打包它们。先证明单层替换可接回官方链路，再确定版本、许可证、构建与更新责任；
不预先建设双后端或同时打包备用实现。系统实现的修复节奏受 OS 更新约束，也属于维护成本评估。

### 单行塑形有官方示例，字符索引仍需核验

进一步找到官方的[自定义文本绘制与显示示例](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/graphics/text-custom-c.md)。
它通过 `CreateLineTypography` → `LineTypographyCreateLine` → `TextLineGetGlyphRuns`
取得单行塑形结果，再用实际 Font 和 TextBlob 自行设置字形位置。这是官方支持的使用方式，
比完整段落布局更贴合终端的固定行列；无需因为标准 Text 组件不适合终端就改用第三方 shaper。

但有一个必须先验证的合同疑点：

- [Run 接口文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkgraphics2d/capi-drawing-text-run-h.md)
  把 `GetRunStringIndices` 描述为字形对应的原文索引，偏移相对整个段落；单行接口的
  `startIndex/count` 则称为字符位置/数量，未清楚区分 UTF-8 字节、UTF-16 代码单元或码点。
- OpenHarmony 图形层快照 `6fac1a5738276d40f9610e78506ec146fbf97161` 的
  [转接实现](https://github.com/openharmony/graphic_graphic_2d/blob/6fac1a5738276d40f9610e78506ec146fbf97161/frameworks/text/adapter/skia/impl/run_impl.cpp)
  将索引请求转给底层 run。独立核对的 Skia 快照 `24dd414f90bbb579d7b63469ea985fd960a595e2`
  中，[RunBaseImpl](https://github.com/openharmony/third_party_skia/blob/24dd414f90bbb579d7b63469ea985fd960a595e2/m133/modules/skparagraph/src/RunBaseImpl.cpp)
  返回 `fVisitorGlobalPos + start + i` 的连续值，未在该方法里查询 cluster；其 range 长度
  也来自访问的 glyph 数量。不能直接据此把数组当作组合字符的原文映射。

这两份开源快照并非已确认配套的商用 API 24 系统源码，以上属于静态疑点，不是已复现的
HarmonyOS 缺陷。它足以改变验证顺序，不足以满足第三方引入条件。
API 24 的双向范围映射接收 `OH_Drawing_Typography*`，单行路径得到的是
`OH_Drawing_LineTypography*`；不能强制转换或假定直接互用。

首个真机文字实验先比较以下合成文本的字节、字形、原文索引和位置，随后再接 Ghostty cell：

| 输入 | UTF-8 字节 / UTF-16 单元 | 要区分的问题 |
| --- | --- | --- |
| `A中B` | 5 / 3 | ASCII 成功是否掩盖了字节与字符计数差异 |
| `Ae\u0301B`，其中转义展开为组合附加符 | 5 / 4 | 多个码点塑形成较少字形时，后续 B 能否仍映射回原文 |
| `A😀B` | 6 / 4 | 非 BMP 字符、代理对与字形计数是否混淆 |
| `A👩‍💻B` | 13 / 7 | ZWJ 序列、颜色与尾部 B 的定位 |
| 带 RTL 文字、不同颜色与字体回退的同一行 | 按实际输入记录 | run 的方向/顺序和样式边界是否改变终端逻辑顺序 |

不预设一字符等于一字形，不把码点数当作列数；最终列坐标取 Ghostty 网格。
若单行索引无法满足需求，下一步只比较官方完整 Typography 的 API 24 范围映射。
原型可以同时生成两个排版对象用于诊断，产品路径不因此默认每行重复排版两次。
当前 xterm 依赖没有 ligatures addon；不借这次替换增加编程连字功能或让其改变既有定位。

### 彩色字形与缓存验证方式

彩色 emoji 的证据应分三层取得：同一系统 Font 的官方文字绘制结果、提取 Run 后重建的
TextBlob 小位图、上传 atlas 后的 GLES 结果。先比较前两层的颜色和覆盖范围，再比较 GPU
上传与混合；这样能区分字体回退、字形重建与 alpha/stride 错误，避免笼统归因于官方不支持。
参考画面的排版位置不是终端列宽的权威，只用于核对字形形状和颜色。

开源[文字 painter](https://github.com/openharmony/graphic_graphic_2d/blob/6fac1a5738276d40f9610e78506ec146fbf97161/frameworks/text/adapter/skia/impl/drawing_painter_impl.cpp)
有针对 emoji 标记的 brush 分支，说明“Font + glyph 能取出”还不能证明重建画面完全等价。
该内部标记不进入应用 ABI；先用普通公开画笔，核对白色与彩色前景、透明和不透明背景，
不调用私有方法或复制系统内部实现。

另据 [C 转接源码](https://github.com/openharmony/graphic_graphic_2d/blob/6fac1a5738276d40f9610e78506ec146fbf97161/frameworks/text/interface/ndk_src/drawing_typography/drawing_text_run.cpp)，
GetRunGlyphs、GetRunPositions、GetRunStringIndices 会创建返回数组，GetRunFont 会创建 Font
包装对象。这里只证明该快照的分配行为，不代表已知实机成本。缓存需避免未变化的行每个
VSync 都重新塑形/取数组；脏行产生新字形时再处理。原型分别统计重复文本和持续新字形，
不提前建设多级缓存，也不把动态 Font 包装对象地址作为长期字体身份。

### 本轮 SDK 编译与链接证据

2026-09-07 完成独立 C 符号探针，生成物位于忽略目录 `build/research/ghostty-api24/`。
它导入 50 个强类型函数符号，覆盖单行塑形、Run 数据、API 24 双向范围映射、字形位图、
对象释放及 EGL/GLES 入口。它不调用这些函数，也不是可运行的终端原型。

- SDK：`6.1.1.125 / API 24`；OHOS Clang `15.0.4 / 99548401bd80576251755b185ab95945e5fe7884`。
- 目标：`aarch64-linux-ohos24.0.0`，使用 SDK sysroot；`-fPIC -shared -Werror`
  `-Werror=unguarded-availability -Wl,--no-undefined` 编译链接通过。
- `llvm-readelf` 确认 ELF64/AArch64/DYN，50 个预期动态导入均存在；NEEDED 仅为
  `libnative_drawing.so`、`libEGL.so`、`libGLESv3.so`、`libc.so`。
- 源码 SHA-256：`63DA621870AD1D55D78F631F756DA2D2E6292340E1F39C5F51A2A885652719B5`。
  `.so` SHA-256：`D4ABF554CE2479BC7AC1D8D82D62C14AA93E5F2B99241A1C683D72E923BDECC4`。
- 本地可复核材料：`official_text_symbols.c`、`run-link-probe.ps1`、`result.json`、`readelf.txt`。

这将证据推进到“当前 SDK 声明和链接可组合”，尚未证明设备动态加载、塑形结果、字形效果、
GPU 渲染、HAP 生命周期或 Ghostty 移植。没有运行或打包 SDK 中的 `.so` 到产品。

## 鸿蒙开发者资料带来的具体调整

资料检索是本轮的一部分，不是本地排错失败后的补救。以下只采用开发者原帖、上游 PR
或作者仓库；转载、搜索摘要和缺少版本/代码的“避坑文章”不作为已验证解决方案。

| 一手资料 | 环境与证据性质 | 对 LeanTTY 的影响 |
| --- | --- | --- |
| [MapLibre #3749 真机记录](https://github.com/maplibre/maplibre-native/issues/3749#issuecomment-4583908834)及[后续结果](https://github.com/maplibre/maplibre-native/issues/3749#issuecomment-4584791027) | 2026-05-30；MatePad Pro MRDI-W00，HarmonyOS 6.1.0.117 / API 23；作者报告 OpenGL/Vulkan 真机成功，并提供图与分支 | 原生 GPU 路径有实际案例；模拟器 stencil/Vulkan 差异不能变成 PC 兼容补丁 |
| [MapLibre #4315](https://github.com/maplibre/maplibre-native/pull/4315) | 本轮读取时 open、未合并；head `cb2ee8100a1f57e52fea00ff509c9a57f89adb7b`；有 EGL/Vulkan、窗口引用与 dirty 调度代码 | 学习 NativeWindow 引用寿命、RGBA/尺寸设置、EGL 能力日志；不照搬它的 RGB565/无 alpha 降级，也不把作者实测等同于上游正式支持 |
| [Boost.Core #187](https://github.com/boostorg/core/pull/187) | 已合并；提供 OHOS 编译错误与修复，处理不可用的 `pthread_setcancelstate` | “Linux API 大致相同”不足以判定可移植；遇到链接/线程问题优先查上游适配记录。LeanTTY 不因此引入 Boost |
| [深开鸿作者的 EGL Render 实践](https://forums.openharmony.cn/forum.php?mod=viewthread&tid=2687) | 2024-04-16；OpenHarmony 原创文章，有 NAPI/EGL 示例和生命周期时序；没有当前 PC 设备证明 | 用作 XComponent 接入与事件时序线索，再以当前 API 和真机校验；不复制其全局状态布局 |
| [Cocos 字体原帖](https://forum.cocos.org/t/topic/161353) | 2024-09-06；Creator 2.4、鸿蒙手机，作者给出 TTF/截图/修复代码；未给精确 OS/API | 系统字体、独立 FreeType 路径及 atlas 合批可能有可见差异；加入字体视觉/批次实验，不移植帖子补丁 |
| [Servo #32723](https://github.com/servo/servo/issues/32723) | 作者 jschwe，2024-07-08；本轮仍 open、无评论，未给精确设备/API；记录预览器与设备字体文件/配置不一致、文件名映射和语言回退问题 | 支持优先使用系统 FontCollection，让系统管理回退；不把扫描字体目录和维护文件名规则当作低成本方案。旧浏览器移植问题不证明 API 24 官方文字能力有缺陷 |
| [TexHarmony](https://github.com/panedioic/TexHarmony) 的 [FreeType](https://github.com/panedioic/TexHarmony/blob/main/hpkbuild/hpkbuild-freetype2)与[HarfBuzz 配方](https://github.com/panedioic/TexHarmony/blob/main/hpkbuild/hpkbuild-harfbuzz) | 作者面向鸿蒙 PC/HNP 的早期移植，公开 ARM64 OHOS CMake 配方；其 README 明示早期状态，本轮未复现 | 仅在官方文字能力出现明确缺口后用于跨编译参考；不因第三方有配方就优先采用，也不复制其 TeX/HNP 打包链 |

本轮没有找到足以证明 **API 24 的 HarmonyOS PC 上，透明多 Pane + 原生 IME +
Surface 重建 + 彩色 emoji 整条链均可靠** 的独立案例。Huawei 部分 FAQ 正文无法稳定读取，
未用其搜索摘要作结论。这个证据缺口必须由我们的最小真机原型补齐。

后续每个系统问题都记录：原始链接/提交、日期、HarmonyOS/OpenHarmony、机型/形态、
OS/API、复现步骤、作者观察、修复是否合并、对本项目的适用边界。出现分配器、输入法、
Surface 或驱动问题，先搜作者讨论和 Issue/PR，再选择能区分假设的最小实验。

## 建议的最小验证门

下表同时包含独立原型和产品接入后的条件，不能全部在隔离模块中完成。八轮原型已取得
技术可行性证据，汇总见[第四至八轮结论](#2026-09-16-第四至八轮与原型结论)；D 的真实
SSH/Mosh、完整交互以及 E 的端到端收益仍未通过。此处没有降低原替换条件，也不把解析
微基准当产品验收。任何新证据显示成本/收益不合适时，应重写方案。

| 门 | 最小实验与输出 | 能证明什么 / 停止条件 |
| --- | --- | --- |
| A：官方库与 ABI | 固定 Ghostty/Zig/SDK；构建静态 VT 与最小 OHOS `.so`；核对 ARM64、PIC、动态依赖/符号；C 调用 feed/resize/render-state、allocator 与 OOM；再在普通 HAP 调用同一库 | 本地测试证明 API 适配；ARM64 链接证明构建边界；设备调用证明加载与执行。任一缺口不能写成“鸿蒙移植完成” |
| B：GPU 与生命周期 | 同一 PC 创建两个简单 Surface；记录 EGL/GL 实际能力；绘制默认/显式背景和叠层；resize、隐藏/恢复、反复 detach/attach、主动重建 GPU 资源 | 证明合成和恢复路径；出现串 Pane、旧 window 使用、死锁或无法恢复立即停止。主动重建不能冒充真实驱动 context loss |
| C：官方文字链路 | SDK 符号链接子探针已通过；API 24 HAP 先核验单行字符索引与彩色字形的三层结果，再接 Ghostty cell 和 GLES atlas；覆盖 CJK、组合字符、emoji/ZWJ、Nerd Font、块元素、粗斜体及字号/DPI；记录内存和上传量 | 先判定官方路线是否满足合同；有具体缺口再定是否引入一个第三方库。缺字、列错位、基线或透明错误不能以“首帧已出现”放行 |
| D：交互和协议合同 | API 24 HAP 用 AttachWithUIContext 验证焦点/IME commit、预编辑与候选位置、按键去重；再验证搜索/选择/鼠标、合成输出驱动 VT，最后接真实 SSH/Mosh | IME 文本和物理按键必须各有唯一入口，输入/回复不串 Session；搜索查询、剪贴板内容不进入诊断日志 |
| E：收益与替换决定 | 同一 PC/OS/构建类型/字体/窗口/输出夹具，对比当前实现与候选的首个可用输入、持续输出完整性、CPU/PSS/GPU、空闲唤醒、恢复与资源释放 | 只有正确性和恢复成立后才比较收益。无可测核心收益、持续 fork 或复杂兼容分支时停止正式替换 |

优先在独立 API 24 测试界面验证 B/C 和 D 的最小输入法链，先回答官方文字能力是否可用；
A 的 Ghostty ABI 验证独立进行，汇合时再接 VT 数据。这些实验不必先改
`TerminalSurfaceController`，系统文字验证也不必等待 Zig 构建。D 是产品接入前的阻断门，
不能拖到“渲染完成后再补输入法”。E 衡量整次替换是否值得，不用于重新决定 API 等级。
字体与 GPU 原型不需要真实账号、生产服务器或 Agent 模型调用。

## 2026-09-16 首轮真机原型

结论：继续 **官方 Ghostty + 官方文字能力 + EGL/GLES** 路线，有初步构建和运行依据；
目前没有引入 HarfBuzz/FreeType 的充分理由。文字到终端网格、IME 完整交互与合成合同
仍有缺口，**尚不进入产品替换**。本轮是可行性实验，不是原生终端完成或性能验收。

### 固定输入与隔离

- 物理 ARM64 HarmonyOS PC，型号 HAD-W32；设备报告 API 24、
  `OpenHarmony-6.1.1.135`；GLES 实际报告 `OpenGL ES 3.2 B301 / Maleoon 916`。
- [官方 Ghostty 快照](https://github.com/ghostty-org/ghostty/tree/82938b633ba646db38591d969c3c526332bd7e65)
  `82938b633ba646db38591d969c3c526332bd7e65`，Zig 0.16.0，OHOS Native SDK 6.1.1.125。
  Zig Windows 包按官方 index 的 SHA-256 校验；下载锁定依赖后由 `zig fetch` 核对上游内容哈希。
- `zig build -Demit-lib-vt -Dtarget=aarch64-linux-ohos -Doptimize=ReleaseFast
  -Dsimd=false -Dvt-features=-kitty-graphics --summary all` 生成静态 VT 库。
  完整命令因 Windows 共享库符号链接权限失败；不能写成整个上游构建通过。
  静态产物编译成功，随后 OHOS clang 以 PIC/`--no-undefined` 链入研究 `.so`，再由签名 HAP 实际调用。
- 实验包为独立 `ghosttyprobe` feature HAP，最低和目标 API 都为 24，沿用本机调试签名
  允许的现有 bundle/version。未替换 `entry` HAP；运行前后核对模块清单。
  原型仅读取随包字体并写自身模块缓存，没有调用现有持久化、网络会话或账号服务。
- 根工作区与最新 main 存在其他任务正在处理的历史差异；本实验独立编译上游与研究代码，
  不将根工作区视为已发布 1.6 的可重建基线，也不据此做新旧性能对比。

### 实测结果与边界

| 实验 | 观察 | 仍不能推出的结论 |
| --- | --- | --- |
| Ghostty C ABI | ELF64/AArch64 `.so`，LOAD 对齐 16 KiB；创建、逐字节输入拆开的 UTF-8/控制序列、resize、RenderState 更新、plain formatter 返回成功；快照保留 CJK、组合字符和 emoji | 尚无长期压力、完整终端协议及 SSH/Mosh 回归 |
| 自有分配器 | 强制首次分配失败时创建返回 `-1`；恢复后创建成功。运行中拒绝分配共记录 54 次，`VT_PROCESSING_ERROR=true` 可读；销毁后计数分配存活数为 0 | 单个受控实验不证明所有 OOM 路径、零泄漏或系统 OOM 恢复；产品必须检查解析错误，不能把写调用返回当成功消费 |
| VT 与显示资源 | Surface 创建前完成 VT feed；保留同一 VT，在两个 EGL Context 主动重建前后，formatter 快照相同 | 尚未验证后台持续 feed、有界队列、解析/帧完成通知或退出屏障；静态快照相同不等于完整生命周期合同 |
| 两个 XComponent SURFACE | 两个窗口表面可同时显示；高度 722→798 px、第二表面销毁/重建、两个 Context 主动重建，swap 成功且 GL error=0 | 两个表面当前显示同一受控 atlas，未证明独立 Pane 隔离；未覆盖透明窗口、叠层、持续后台/前台、真实驱动 context loss |
| 官方文字与 GPU | 七组 ASCII/CJK/组合字符/emoji/ZWJ/RTL/Nerd fixtures，官方字体回退后取得 Run/Font，TextBlob 重建为 RGBA 字形位图，再由 GLES 上传/采样；五次 RGBA8 FBO 回读均为 0 个差异字节 | GPU 回读证明该纹理链无损，不能替代文字正确性。此时 atlas 整体缩放显示，未接 Ghostty cell 网格；不是最终字号、宽字符或 DPI 效果 |
| 原生 IME | `GetContextFromNapiValue`、`AttachWithUIContext`、detach 返回 0；受控物理 `nihao` + Space 显示系统中文候选，InsertText 收到一次 U+4F60 U+597D（你好） | 候选框仍在默认位置；本轮没有 SetPreviewText 回调，只观察到提交和 finish。尚无应用侧预编辑、光标定位、跨 Pane 焦点/失效回调或快捷键去重合同 |

字体小位图仍使用 Native Drawing 文字接口；最终表面为 GLES 渲染。不得称为完全不使用
Native Drawing，也没有复用 `libghostty-ohos` 或引入第三方文字栈。

### 文字接口对架构的具体影响

1. **不能直接把 Run 的 string indices 当原文字符位置。** `Ae\u0301B` 的三个 glyph 返回
   `[0,1,2]`，而 B 在 UTF-16 中位于 3；ZWJ fixture 的末尾 B 同样返回 glyph 序号 2，
   原文 UTF-16 位置为 6。这与此前 SDK/上游疑点相符。
2. API 24 `TypographyGetGlyphRangeForCharacterRangeWithBuffer(..., TEXT_ENCODING_UTF16)`
   在受控 fixture 中正确合并了组合字符 `[1,3)`、emoji 代理对 `[1,3)`、ZWJ `[1,6)`。
   因而优先继续验证 **Paragraph + 显式字符编码映射**，不让 Run 索引承担字符合同。
   RTL 的逻辑范围仍须结合视觉 glyph 顺序单独验证，不能从此表直接推定通用 cluster 映射正确。
3. 单行接口对这组输入用 Unicode scalar 数量创建成功；初次误传 UTF-16 数量时 emoji/ZWJ
   返回空 line。`TextLineGetTextRange` 在本机又呈 UTF-8 字节范围。封装必须区分字节、UTF-16、
   scalar、glyph 和终端 cell，不能使用一个通用整数 offset 混传。
4. TextBlob 重建需补齐 Run 局部坐标、行基线，并恢复直接绘制后的 brush 状态。
   纠正探针后字符、回退字体和彩色字形可见；与直接 TextLine 绘制仍有少量栅格像素差异，
   包括 CJK/RTL/Nerd 的约一像素边界差异。原因尚未闭合，不能把 GPU 回读一致当作这项通过。
   下一步先比较官方直接 Run/Line 栅格化与重建路径，决定是否可以减少自行重建步骤；
   不因探针自身坐标错误就认定官方字体能力不足。

### 证据与清理

完整本地证据位于忽略目录 `build/research/ghostty-runtime-20260916/`：

- `setup-hap.ps1`、`build-hap.ps1`、`run-hap.ps1` 及 `text_probe.c`、`probe.cpp`、
  `gpu_probe.cpp`、`ime_probe.cpp`，配合实际 `hap/` 工程；setup 是最初脚手架，
  后续 GPU/IME 界面以最终 `hap/` 为准，不能只运行 setup 视为完整复现。
- `hap-build.log`、`signature-verification.log`、`native-elf.txt`、`runtime-hilog.log`、
  `gpu-hilog.log`、`ime-hilog.log`，受控文字的 `app-results/` 原始像素与报告。
- `probe-screen.png`、`ime-preedit-screen.png`、`text-comparison.png`；截图含测试机桌面，
  仅作本地调试证据，不直接提交或发布。
- `module-after.json`、`module-data-cleanup.log`：模块已卸载，研究模块数据已删除，
  原有 entry 保留并重新启动，屏幕超时设置已恢复。

最初直接运行 `/data/local/tmp` ELF 被系统拒绝，随后改为正常签名 HAP，没有修改系统安全
策略。HDC `shell -b` 的工作目录是 debug sandbox，清理必须使用沙箱相对路径；初次误用
`/data/storage/...` 得到 permission denied，紧跟的 `test ! -e` 不能证明清理成功。
已改用可访问父目录、精确模块相对路径和卸载后清单共同核验；旧 `cache-cleanup.log` 不作
成功证据。此区别与 [OpenHarmony HDC 文档](https://github.com/openharmony/docs/blob/master/en/application-dev/dfx/hdc.md)
描述的调试沙箱入口一致。

设备已释放。下一轮仍是同一独立原型：先闭合字符→cell、直接/重建字形、光标/IME 与
双表面合成，再扩展无 Surface 持续消费、临时 VT 内存与完成/销毁合同；最后才能进行
产品接入及同机收益比较。活动工作只记在 Next Work，不另开清单。

建议所有权草图：

```text
PaneRuntime（Pane 的 Session 业务边界）
  ├─ 会话控制                   ltty 输入路由、具体会话与终端页面策略
  │    └─ SSH / Mosh            具体连接、信任与协议状态的唯一所有者
  ├─ TerminalRuntime            常规 VT、按需临时 VT，独立于 Surface 存活
  └─ Surface generation         NativeWindow/EGL/帧回调，可销毁重建

bytes / input intent → 有界且有序的 native 命令 → Terminal
Terminal → RenderState → font / glyph atlas → GLES → 当前 Surface
Terminal effect → 校验后的结构化事件 → 原有系统服务或同一会话
```

Surface generation 与 Session identity 必须分别校验；旧窗口回调不能操作新窗口或新连接。
显示帧可合并，协议字节和输入顺序不能丢弃。后台暂停的是 GPU 提交，不应无依据停止协议
处理。查询、终端内容、剪贴板和远端通知正文仍只在必要的短期内存中使用；不能因为跨了
Node-API 就进入日志、Preferences 或崩溃诊断明文。

## 2026-09-16 第二轮真机原型

结论：官方文字路线可继续，优先直接绘制 Run，停止修补 TextBlob 重建。真实 Ghostty
cell 已驱动 GLES 网格；IME 候选框定位已有实测依据。这里只闭合受控夹具中的问题，
不代表进入门通过或产品集成完成。上游、SDK、设备和隔离模块沿用首轮固定输入。

### 文字与网格

- 七组 ASCII/CJK/组合字符/emoji/ZWJ/RTL/Nerd 的 `OH_Drawing_RunPaint` 输出，与
  同行 `TextLinePaint` 的 RGBA 原始文件逐字节相同；每组比较 327,680 字节。Run 使用
  与 Line 相同的绘制原点，不自行累计 Run offset。彩色 emoji/ZWJ 仍保留颜色。
- [OpenHarmony Run 实现](https://github.com/openharmony/graphic_graphic_2d/blob/6fac1a5738276d40f9610e78506ec146fbf97161/frameworks/text/adapter/skia/impl/run_impl.cpp)
  与其 [Skia 绘制实现](https://github.com/openharmony/third_party_skia/blob/24dd414f90bbb579d7b63469ea985fd960a595e2/m133/modules/skparagraph/src/RunBaseImpl.cpp)
  表明直接绘制保留了内部偏移、paint 和裁剪上下文。当前证据支持省去手工重建，不能
  从公开 glyph positions 推断已拿到全部绘制状态。
- 最小链路为 `RenderState cell → 立即复制 cluster/宽度 → 官方单 cluster 排版 →
  RGBA atlas → GLES cell quad`。使用 Ghostty 的列和宽度，不让排版结果重算列数；
  宽字符尾部占位不单独绘制。41 个非空头 cell 的文本、行列和 span 符合独立手写预期。
- 两表面最终 1007×798 帧回读与 CPU 参考合成相比，每通道最大差异 1，超出 1 的通道
  数为 0；这是纹理与 quad 布局的量化误差界，不是文字美观或所有字体正确性的证明。
  resize、第二表面重建和主动 EGL 资源重建后有成功绘制；两者仍显示同一场景，不能
  声称 Pane 隔离通过。
- 首次网格中 ZWJ 被拆为两个宽 cell，独立预期不匹配。核对后发现库默认模式与完整
  Ghostty 应用配置不同；上游也有 [libghostty DEC 2027 默认值讨论](https://github.com/ghostty-org/ghostty/discussions/13474)。
  控制流显式开启 `CSI ? 2027 h` 后，`👩‍💻` 占两列；关闭后占四列，两个预期均通过。
  此次只是协议模式对照，尚未决定产品默认值、RIS 后默认恢复或 tmux 兼容策略。

原型固定 32 px 字号、24×64 px cell、4 MiB atlas，27 个唯一缓存项；这些是实验参数，
不是产品字号、缓存预算或性能结果。截图中框线/块元素尚未铺满 cell，需要下一轮验证
网格几何；粗斜体、字号/DPI、字体切换和跨 cell shaping 也未闭合。RTL 仅证明逻辑 cell
保留，不宣称实现双向段落排版。字形小位图使用 Native Drawing 文字接口，整屏仍由 GLES 绘制。

### IME 对照与清理

原生链路从 ArkUI 光标节点取得屏幕位置，经当前 UIContext 换算为物理像素，设置
`OH_CursorInfo_SetRect` 并调用 `NotifyCursorUpdate`；配置、attach、更新及 detach 均
返回 0。截图确认候选框位于黄色光标下方，受控 `nihao` + Space 得到一次“你好”提交。

同一输入法、同样物理按键再输入到启用 preview 的官方 TextInput，仍只观察到最终
`onChange`，没有应用侧预编辑内容。因此该场景没有证据证明原生接口缺少平台已有能力；
也不能将未产生预编辑误记为预编辑合同通过。失效回调、跨 Pane 焦点和物理键去重仍待验证。

本地证据目录为 `build/research/ghostty-runtime-round2-20260916/`：最终网格的签名 HAP、
源文件、`grid-verification.json`、`grid-hilog.log`、`app-results/` 和网格图；
`ime-comparison-evidence/` 单独保留实际 IME 对照的签名 HAP、日志和截图，不能以之后
重建的网格包冒充该输入证据。`grid-default-mode-evidence/` 保留最初不匹配的结果。
`verify-grid.py` 对 cell 合同、七组原始像素和 GPU 差异界执行断言。

首次 IME 编排发现 UiTest 同时报告主窗与无焦点辅助窗，原来“只能有一个 ProbeAbility
根节点”的守卫停止输入；确认窗口状态并完成清理后，改为要求唯一有焦点的原型窗口。
后续受控输入完成。各轮均卸载仅 `ghosttyprobe`，核验 entry 保留和模块数据删除，释放
屏幕常亮租约；未修改系统输入法设置或产品实现。本轮证据继续支持官方能力优先，
没有新增第三方文字库的理由。后续执行仍只由 Next Work 管理。

## 2026-09-16 第三轮真机原型

结论：继续 SURFACE/GLES 和官方文字路线。独立 VT 状态、字体尺寸变化、Surface 重建
与普通 ArkUI 叠层已有更强的受控证据；终端图形字符需要按 cell 几何处理。此次仅改独立
原型，没有开始产品集成，也没有证明性能收益或通过完整进入门。

沿用首轮 Ghostty/SDK/设备；第三轮签名 HAP 的 SHA-256 为
`3D64C3B3690FF1EFC31F9E44E7366C8BE57BD0698CBB9DDFA910E343D58928ED`。
收到共享设备交接后预检，再运行一次无键盘输入的场景。仅添加 `ghosttyprobe` feature，
保留主流程当前 entry 测试包。证据位于 `build/research/ghostty-runtime-round3-20260916/`。

### 实测结果

| 场景 | 独立观察 | 证据边界 |
| --- | --- | --- |
| 双 VT 与字号 | 左侧从 `LEFT-000`/24 px 更新为 `LEFT-111`/36 px；右侧仍为 `RIGHT-000`/32 px。四份实际 cell 快照与手写字符/宽度/行列预期一致 | 各 model 自有 VT、快照和 atlas；证明受控输出隔离，不含焦点、输入或真实 Session 路由 |
| 无右 Surface 的输入 | 日志确认仅剩一个 Surface 时，右 VT 接收 `RIGHT-222` 和 `FEED-WITHOUT-SURFACE`；恢复 Surface 后正确显示，左侧保持原内容 | 是短时合成输入，未覆盖持续高速输出、后台调度、队列背压或 EOF |
| GPU 重建与释放 | 10 帧原始回读符合字号、内容和几何预期；每通道最大量化差异 1，无超界通道。主动 EGL 重建后两侧内容仍正确；随后 Surface 数与 model 数归零 | 不等于真实驱动 context loss、无泄漏、并发退出屏障或 OOM 恢复 |
| ArkUI 叠层 | 在同一 Stack 中绘制跨越两个 SURFACE 的色条。系统截图四处取样：不透明色条与预期相同；半透明色条与参考混合每通道相差最多 1 | 覆盖普通兄弟组件合成；终端默认背景对桌面的透明、显式 SGR 背景、弹窗/菜单和输入命中尚未验证 |
| 图形字符 | 同场景上半部使用官方字体字形，下半部对 `█▀▄─│┌┐└┘` 用 GLES 矩形。后者连续块无细缝，框线按 cell 中心相接 | 仅九个实验字符，不是完整 Unicode 框线、斜线、Braille、Powerline 或样式实现；不是引入新字体库的依据 |

`verify-round3.py` 先核对四份 cell 快照，再按各字号和独立图形掩码检查 10 帧；
`verify-overlays.py` 使用当轮 UiTest 节点 bounds 定位系统截图取样区域。后者能观察
系统最终合成，不能用 `glReadPixels` 或 swap 成功代替。原始结果在 `verification.json`、
`overlay-verification.json`、`font-block-coverage.json` 和 `app-results/`，源码/包哈希在
`evidence-sha256.json`。截图包含设备桌面，仅保存在本地忽略目录。

### 对实现边界的影响

字体字形不保证填满终端 cell，这是网格几何职责，不能把通用排版当完整终端 renderer。
[上游 sprite 说明](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/font/sprite/draw/README.md)
按 cell 尺寸定义图形绘制；[使用者讨论](https://github.com/ghostty-org/ghostty/discussions/9622)
也记录了字体字形高度与 sprite 填满 cell 的差别。当前 `libghostty-vt` C API 不提供这套
应用 renderer，九字符探针仅用于验证本地 GPU 几何方向，没有复制整个上游字体后端。
正式覆盖范围与复用上游算法的成本仍需在产品接入前收敛。

官方文字继续负责普通字形和字体回退，我们负责 cell 位置、图形字符几何、缓存与 GPU
资源。此次字体采用固定物理像素和自定 cell 尺寸；24/32/36 px 运行正确不等于系统 DPI
变化、最终字体度量、粗斜体或裁剪都已验收。字号切换为方便观察主动重建 GPU 资源，
原型每个 model 分配 4 MiB atlas 并同步回读帧，不能拿其耗时或内存作为正式性能结论。

普通 SURFACE 上的 ArkUI 叠层已满足这个受控场景，暂无理由仅为此切换 TEXTURE。
仍需按[官方 XComponent 指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/ui/napi-xcomponent-guidelines.md)
区分组件、Surface 和窗口的合成层级，再验证已发布的默认/显式背景透明合同。外部开发
资料用于提出验证假设，本机截图和像素结果才是本项结论依据。

本轮结束时已卸载独立模块、删除其精确沙箱数据、恢复常亮策略并启动原 entry；设备与
构建/签名资源已通知主流程释放。输入去重、预编辑和跨 Pane 失效回调仍未闭合，不能因
显示结果正确就绕过最小输入门。后续工作只维护在 Next Work。

## 2026-09-16 第四至八轮与原型结论

**技术可行性成立，建议进入受控产品接入；正式替换尚未放行。** 固定官方 Ghostty 静态库、
API 24 官方文字/输入接口和 SURFACE/EGL/GLES 可以组成所需的最小链路。本轮没有发现必须
引入 HarfBuzz、FreeType、`libghostty-ohos` 或另一套 renderer 的技术缺口。原型追加诊断
先完善了可恢复场景；持续 GPU 故障的产品边界后来由维护者于 09-19 明确，见下文。
正式替换仍需既有交互和正常生命周期的产品证据，不能由实验通过数代替。

### 运行证据与限制

| 场景 | 结果 | 结论边界 |
| --- | --- | --- |
| 原生输入唯一入口 | 两个输入所有者各收到一次物理 `nihao` + Space 的“你好”；左侧 Ctrl+C、左箭头、Backspace、Enter 各一次，右侧没有这些字节；切换时四个迟到回调被拒绝 | `InsertText` 负责提交；PreIme 只消费约定的组合键，未消费特殊键才到后续入口。是隔离缓冲区，未连接 SSH |
| 预编辑 | 通过官方 Getter 取得已注册的真实回调，验证范围替换、非法范围返回 401、只提交一次以及旧代次拒绝 | 系统输入法本次没有产生预编辑回调；官方 TextInput 对照同样如此。只证明应用状态机，不写成真实系统预编辑通过 |
| 样式与透明 | regular/bold/italic 缓存不混用；十帧回读与参考每通道差异不超过 2。系统截图八个取样点精确符合默认半透明、显式同 RGB 背景、显式彩色背景及反色 | 验证背景身份由颜色模式决定。实验 alpha 属于原型合成夹具；产品仍须按 §4.7 让承载表面独占默认背景 alpha，并验证 Off、光标、选择和弹层 |
| 有界消费与关闭 | 64 KiB 队列触发生产者等待；300400 字节全部消费、100 次查询回复与顺序参考一致。队列满时关闭仍消费完已接收的 65536 字节，关闭后拒绝新输入 | 消费和完成屏障不依赖 GPU 帧；先 join 后销毁 VT。并非真实网络、Mosh 状态同步或生产 N-API 并发验收 |
| 搜索、选区与编码 | 中文搜索两处、UTF-8 选区内容、备用屏切换后搜索恢复、普通/应用光标、SGR 鼠标按下/释放及 focus 编码均符合独立字节预期；VT 销毁后的 search 返回 -2 | 库能力可用，不等于搜索面板、鼠标命中、剪贴板或会话路由已完成 |
| 后台文字准备 | N-API async work 在与调用者不同的线程完成官方文字、VT 快照及 atlas 准备，再回到调用线程交付；七类 Run/Line 像素仍相等 | 字体对象只由该工作线程使用；原型准备结束才创建 Surface。不是并发共享 FontCollection 的授权 |
| GPU 有界失败与恢复 | 两个 Surface 各注入两次创建失败，出现 ArkUI 故障提示；旧代次共四次绘制请求被拒绝；恢复后的两幅原始帧与失败前逐字节相同 | 注入走同一创建返回值和代次守卫；没有真实驱动 context loss，也未验证输入冻结或永久故障后的可用终端 |
| 畸形输入与边界 | 11100 字节受控语料覆盖非法 UTF-8、NUL、超长/畸形 CSI、未知 OSC 与取消；整段、1 字节、7 字节 feed 结果一致，RIS 后正常输出。五个越界请求在 ABI 前拒绝 | 是有限语料与原型尺寸/块大小限制，不能等同 fuzzing、内存安全证明或产品预算已定 |

输入选择依据[官方自定义编辑框指南](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/use-inputmethod-in-custom-edit-box-ndk)
与[预编辑范围 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-ime-7)，并以
当前物理按键证据核对。不能把组合键、IME 提交和后续 KeyEvent 三条入口同时写入会话。

### 内存、缓存和收益

分配器 ABI 疑点已用固定上游实现和设备调用核对：回调的 alignment 是
`std.mem.Alignment` 枚举的指数，按 `1 << alignment` 转换，设备观察到最大 4，即 16 字节。
不能直接照头文件的字节描述解释。生产封装需绑定该源码快照与构建版本；本轮没有修改上游。
同时发现 `PageList.zig` 非 Darwin 页面直接使用 `std.heap.page_allocator`，绕过调用者 allocator。
因此回调的 live/peak 只统计一部分内存，`liveAfterFree=0` 不能冒充整个 VT 无泄漏。

第七轮补充进程 `/proc/self/smaps_rollup` RSS：240×80 密集彩色 CJK/emoji、正常屏和备用屏
反复切换、零 scrollback 临时 VT，创建/释放 20 次；常规 VT 的历史保持不变。进程 RSS 从
320636 KiB 起，峰值 321624 KiB，结束 320944 KiB，分别增加 988/308 KiB；最后十次释放后
均为 320944 KiB。它支持“此夹具的额外成本有限且未持续增长”，不是完整产品 PSS、长时间
泄漏或内存硬上限的证明；进程中还含 ArkUI、字体和两块原型 atlas。

第八轮在后台使用同一官方栅格函数测量：

| 夹具 | 文字生成/命中 | 像素缓存与耗时 |
| --- | --- | --- |
| 64 个 ASCII 循环，6400 次请求 | 64 次 shaping/栅格，6336 次命中 | 缓存峰值 1 MiB；整段约 8.19 ms |
| 连续 512 个不同汉字 | 512 次 shaping/栅格，512 份位图均有像素 | 128 项容量，满后整批清空三次；像素峰值 2 MiB；约 35.52 ms |

新字形阶段累计产生 8 MiB 的 64×64 RGBA 位图，这只是上传候选量，没有上传 GPU，不能记作
已测上传耗时；正式 atlas 应只上传脏区域。原型 GPU 每次建资源上传完整 4 MiB atlas，属于
诊断实现。缓存上限只约束应用持有的像素，不约束系统字体缓存：连续新字形阶段进程 RSS
从 278772 KiB 到峰值 282200 KiB，清空后 279960 KiB，不能把 map 清空等同进程内存全释放。
这些结果足以支持按需缓存、后台准备和有界容量；不支持为此引入多级缓存或另一文字库。

同一第六轮 HAP 内，使用项目当前 `xterm.js` 的无 DOM parser 和 native Ghostty，固定
120×40、零 scrollback、相同 300400 字节、1024 字节分块。各跑六次，首轮作预热；两边
每轮都得到 100 次回复和相同最终屏幕哈希 `d570589c1d7cc7d4`。后五次中位数为
Ghostty **3.26453 ms**、xterm **13.0 ms**，本夹具约 3.98 倍差异。

这是 **VT 解析层微基准**：Ghostty ReleaseFast 静态库加 O1 包装，对照 xterm 的异步 write
完成回调。没有包含布局、GLES/ArkWeb 绘制、实际 SSH/Mosh、启动、可用输入、CPU/PSS 或
能耗；不能承诺应用快四倍。产品接入后仍按 E 门做同机端到端判断。

### 自研边界与后续验收

本轮收敛为：官方 Ghostty 负责 VT、屏幕/历史、搜索和协议编码；鸿蒙官方接口负责字体
回退/文字像素、IME、窗口与 GPU API；自研部分限于版本锁定的 C ABI 封装、有界数据交接、
会话输入所有权、终端 cell/图形字符绘制、缓存、Surface/资源代次和恢复。没有上游源码 fork，
但仍有 ABI 变化、同进程 native 故障范围、系统字体差异及终端图形字符覆盖的维护责任。

原型代码含固定网格/64 px tile、全量回读、直接定时器、简化清空缓存和实验 fault hook，
不能直接复制成产品实现。产品切片仍按已批准顺序：最小会话解耦和单 Pane SSH，随后
Mosh/双 Pane，再完成已有交互与同机验收。具体执行只由 Next Work 管理。

以下仍属于正式接入/替换条件，尚未获得通过证据：真实 SSH/Mosh 与末尾输出/退出合同；
系统实际预编辑；最终字体度量、系统 DPI 变化、完整图形字符与裁切；搜索/选择/剪贴板、
链接/通知/颜色查询等既有交互；产品透明 Off 与光标/选择；并发关闭/真实 context loss；
生产包端到端收益与长期资源观察。它们不是已发现的官方能力缺陷，也不授权降低原合同。

### GPU 持续不可用：09-19 维护者决策

瞬时故障的技术路径已有证据：保留 VT，失效旧资源代次，有限重建后全量重画。
[EGL 的 context-loss 定义](https://raw.githubusercontent.com/KhronosGroup/EGL-Registry/main/sdk/docs/man/eglSwapBuffers.xml)
也要求重新建立 context 和状态；它没有保证重建一定成功。
[Ghostty 上游讨论 #6073](https://github.com/ghostty-org/ghostty/discussions/6073) 有用户报告
GL context 不可用导致终端无法启动，并讨论软件后端。这是风险实例，不是鸿蒙发生率证据，
Linux 的 llvmpipe 方案也不能当作鸿蒙已有的公开能力。

维护者于 09-19 明确：GPU 不可用时接受整个 App 无法使用，要求精简相关逻辑，优先
保持代码简洁和可维护性。原生路径仅使用 GLES；不要求 CPU 兜底、另一套 VT 状态迁移，
也不继续扩大持续故障矩阵。该决策已写入
[产品原则 §4.8](../project-principles.md#48-终端-renderer-选择)，取代此前尚未闭合的
“持续 GPU 故障期间仍可操作终端”替换条件。

保留已有有界资源重建、故障状态及输入冻结，GPU 恢复后可通过现有入口重试。
正常 Surface 生命周期和可恢复 context loss 仍需成立；此决定不豁免普通窗口操作中的
黑屏、数据丢失或资源泄漏，也不要求故意终止 App。

### 证据身份与清理

沿用第一轮固定 Ghostty/Zig/SDK 和同一 ARM64/API 24 PC。第四至八轮各保留源码、签名
HAP、采集文件、截图、日志和 `evidence-sha256.json`，目录依次为
`build/research/ghostty-runtime-round4-20260916/` 至 `ghostty-runtime-round8-20260916/`。
签名 HAP 的 SHA-256：

| 轮次 | SHA-256 |
| --- | --- |
| 4 | `7fe208d5780ae7d409d5b61a5380a1be381f4c65e18f134948dc08f1f93139e2` |
| 5 | `258a818178e7916dfa758efc646ce66537bd9a0d21a73228318e27410b09b065` |
| 6 | `2460f512845759bb9bd62487e720c42b74c5138eb89f14feb91e0c74e6bb9158` |
| 7 | `10cc950fbcc11257ae56d8476b9c14af2a332b0ce41ac9b0abdeb03eec9b005f` |
| 8 | `497e186b28a14515f2f31af9ed1abb17e781446b3d50a95262eb825fe7bd5da4` |

`build/research/verify-prototype-closeout.py` 重放第四至八轮的原始文件断言，包括输入字节、
系统截图透明取样、14 帧参考合成、故障前后帧相等、线程、队列、协议、内存和缓存边界，
并核对部署 HAP 哈希、每轮模块/数据清理及 entry 恢复。汇总为
`build/research/ghostty-prototype-closeout-20260916.json`。数据仅为受控夹具；桌面截图及
原始证据留在本地忽略目录。各轮均卸载仅 `ghosttyprobe`、删除其沙箱数据、释放常亮租约
并重新启动原 entry；没有接触账号、真实会话或产品持久化路径。本轮未运行无关发布矩阵。

## 2026-09-16 GPU 恢复链追加诊断

**发现并修复的是独立原型的资源恢复缺口，尚未发现设备自发的 GPU/驱动故障。** 逐一
核对前八轮 `gpu-hilog.log`：初始化、makeCurrent、swap、GL 和 atlas 回读没有非注入
失败；仅第七轮四次 `controlled_create_failure`。先前直接要求维护者接受“持续 GPU
故障时停止交互”，过早跳过了应用层恢复诊断。本轮保持现有原则，不新增后备 renderer。

### 根因与修复

复现与修复都在原型资源所有者内部进行。VT/model 和 grid 内容不改动，使用同一固定
Ghostty/字体/GLES 路线；独立 feature 的数据和源代码与原产品隔离。

| 场景 | 旧逻辑的可重复结果 | 修复后设备结果 |
| --- | --- | --- |
| 一次初始化失败 | 先把 display 写入全局，再调用 initialize；失败后 display 非空，后续 Surface 跳过初始化/config。基线两侧成功帧均为零，手动清空状态后两侧恢复 | display/config 完整成功后才发布；失败清理部分资源，有界重试。一次注入失败后第二次 initialize 成功，两侧各有一帧 |
| 失效 EGLSurface | 先解除 current 并销毁 EGLSurface，再走原 draw；真实 makeCurrent 失败只记日志，不再出帧 | 读取准确错误码，`EGL_BAD_SURFACE`/`EGL_BAD_CURRENT_SURFACE` 在 NativeWindow 仍有效时只重建 EGLSurface，然后全量重画。恢复一帧；另五次重复失效均恢复 |
| swap 失败 | 让一次 swap 实际调用 `eglSwapBuffers(display, EGL_NO_SURFACE)`，平台返回 `EGL_BAD_SURFACE`；旧逻辑仍增加 frames，出现 4 次成功 swap 却报告 5 帧 | 只有 swap 成功才发布帧完成；失败转入 Surface 恢复并重试一次。该阶段新增一次成功 swap，累计帧与成功 swap 均为 8 |
| Context 丢失分支 | 第七轮只在 create 前返回失败，没有覆盖 swap 的 context-loss 分流 | 在同一 swap 边界注入 `EGL_CONTEXT_LOST`，销毁本 renderer 两个 Context 及其资源，重新创建纹理/程序并重画，两侧各恢复一帧 |
| NativeWindow 失效分支 | 仅重建 EGLSurface 不能使已经失效的 NativeWindow 重新有效 | 在 swap 边界注入 `EGL_BAD_NATIVE_WINDOW`，停止使用该 window，通知 ArkUI 卸载再挂载对应 XComponent；实际经历 Surface 销毁/创建回调后恢复双 Pane，另一 VT 保持原内容 |

最后两项的错误码为受控注入，后续资源重建和平台回调真实执行；不能写成实际驱动
context loss 或真实 NativeWindow 指针失效已复现。失效 EGLSurface 与失败 swap 则使用
真实 EGL API 返回错误。每条恢复路径均有界，没有反复重试未知错误或创建 CPU renderer。
图像回读发生在 swap 之前，故原始回读帧数不等于成功送显次数，二者在证据中分别记录。

创建失败的 Context/Surface 在返回前清理，销毁时清零全部 GL 对象 ID，并更新资源代次。
局部恢复不调用 `eglTerminate`：它会标记该 display 的全部 EGL 资源删除，不能把它当作
单 Pane 清理函数；默认 display 若与进程其他图形使用者共享，尤其不能随意终止。完整
display 生命周期归进程级所有者，原型只释放自己的 Surface/Context。此选择依据
[EGL terminate 定义](https://raw.githubusercontent.com/KhronosGroup/EGL-Registry/main/sdk/docs/man/eglTerminate.xml)。

### 鸿蒙资料和线程边界

[华为 XComponent 图形渲染定位指南](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-xcomponent-render-problem-guide)
明确记录了组件销毁后子线程仍用 NativeWindow/OH_NativeXComponent 的崩溃链，要求传给
子线程的 NativeWindow 配对加减引用，也建议评估 SurfaceHolder 接口。增加 window 引用
不会延长 OH_NativeXComponent 本身的寿命。产品 renderer 线程应只接收有明确所有权的
window、复制的尺寸和代次；销毁回调结束前必须完成旧资源交接，不能把组件指针长期排队。

本次原型 EGL 操作在同一回调线程串行完成，每次成功呈现后解除 current；它没有证明生产
renderer 工作线程交接已完成。[Khronos 的实际开发者讨论](https://community.khronos.org/t/opengl-es-calls-across-multiple-threads/1107)
及[eglMakeCurrent 定义](https://raw.githubusercontent.com/KhronosGroup/EGL-Registry/main/sdk/docs/man/eglMakeCurrent.xml)
都说明 Context/Surface 仍绑定其他线程会得到 `EGL_BAD_ACCESS`。这种所有权错误应修交接，
不应直接当作硬件不支持或盲目重建。鸿蒙二手讨论与其他芯片旧版本 Issue 只用于寻找线索，
未找到能证明本机 API 24/Maleoon 存在持续 EGL 故障的对应记录，不将其套用到本机。

### 验证身份与结论

定向 L2/L3 分别运行修复前、后签名 HAP；没有运行无关 Rust/SSH/Mosh 或发布矩阵。
修复后 21 幅原始回读与 CPU 参考合成每通道最大差异 1；同 Pane、同尺寸的各次原始图像
逐字节相同。系统截图显示恢复后的两侧内容、字号与叠层正确。最终 Surface/model 均为零，
两轮均证明仅卸载 `ghosttyprobe`、删除原型数据、恢复原 entry 并释放常亮租约。

- 基线：`build/research/ghostty-gpu-diagnostic-baseline-20260916/`，HAP SHA-256
  `cd4356e41e9413e38cdecd41e3863cd4a0a1a453dab68645bae34468806e13e9`。
- 修复：`build/research/ghostty-gpu-diagnostic-fixed-20260916/`，HAP SHA-256
  `9a16f6c33ac9403165e3bb64a6d955468f6866a5a5099dcaf94549663ed512f4`。
- 独立断言：`build/research/verify-gpu-recovery.py`；汇总：
  `build/research/ghostty-gpu-recovery-verification-20260916.json`。各目录保留源码、包、
  `diagnostic-*.json`、回读图像、系统截图、日志及 `evidence-sha256.json`。

采用上述分级恢复方向，原型的三个已复现缺口已关闭。接下来把这些责任纳入已批准的
最小产品接入，再验证真实 Session、后台/窗口变化、线程交接和故障可见性；此处不增加
第二套待办。没有证据要求改用 TEXTURE/Vulkan、增加软件后端或降低当前可用性承诺，
也不能据此承诺所有驱动故障都能在进程内恢复。

## 09-19 CPU 方向取消与清理

隔离探针已证明 NativeWindow 显式缓冲区提交的有限可行性；后续接入试验在窗口缩放时
触发 Surface 重建，尚未闭合原因。两者均不能证明 GPU 持续故障下的完整产品可用性。
原始证据保留在本地 `build/research/native-cpu-window-20260919/` 和
`build/verification/1.7-native-cpu-recovery/`，不将试验结果记为产品交付。

维护者随后明确接受 GPU 不可用时整个 App 无法使用，并要求精简逻辑。已取消 CPU
后端、缓冲区事务、专用测试和诊断标记，恢复单一 GLES 路径，停止该方向的接入与诊断。
保留既有正常生命周期的有界恢复，持续 GPU 故障不再是正式替换的可用性门。
今后为扩大兼容性而增加复杂度，按产品原则第三节先取得维护者明确确认。

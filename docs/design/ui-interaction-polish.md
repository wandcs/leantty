# 桌面终端界面与交互收敛

> 状态：Verified / 1.2–1.3
>
> milestone：1.2 基线；1.3 渲染与视觉修订
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 完成记录：1.2–1.3 对应实现与发布已闭合；后续变更须重新进入 [`next-work.md`](../next-work.md)
>
> 最近更新：2026-08-15

本文冻结 LeanTTY 1.2 的桌面终端界面与交互收敛方案，并记录 1.3 对透明 TUI 渲染、五档
参数和 Chrome 层级的兼容修订。它解决现有界面在多 Tab、BEL
提醒、内容层次、搜索密度和分屏反馈上的一致性问题，不改变 Tab → Pane → Session
所有权，只增加一个受控的五档全窗口透明度选择，不扩展为通用外观设置或设计框架。
唯一活动执行顺序与验收项仍以 `docs/next-work.md` 为准，本文不维护第二份 checkbox。

## 用户问题

当前界面已经具备专业终端的核心结构，但若干局部反馈没有形成一致语言：

- 多个非活动 Tab 连续排列时，透明底色之间缺少视觉边界，标题与关闭按钮容易被看成
  一整段内容。
- 服务器发送 BEL 后，Pane 四周持续出现黄色边框，面积过大、视觉权重过高，也没有把
  注意力准确引向对应 Tab。
- 终端内容区完全不透，和自定义窗口 Chrome 的层次关系偏硬；用户希望内容区有克制的
  轻透明，但不能牺牲正常使用、可靠性或性能。
- 搜索输入框与结果、导航、关闭按钮之间留白过多，占用终端内容且操作分组不紧密。
- Tab 铺满后，滚动区、固定的 `+`、可拖拽空白区和系统按钮之间缺少明确边界，剩余空间
  的用途不够直观。
- 分屏分界、Pane 关闭按钮、图标、键盘焦点和浅色主题仍有局部硬编码或反馈不统一。

## 目标

界面方向固定为：**安静、专业、内容优先的终端工作台**。

1. 在不增加操作概念的前提下，让 Tab、Pane、搜索和窗口 Chrome 的层次一眼可辨。
2. 把 BEL 从覆盖整个内容区的告警，收敛为准确、有限、可恢复的 Tab/Pane 注意力提示。
3. 让终端内容区呈现克制的轻透明；可读性、TUI 正确性、WebGL 稳定性和低性能负担是
   硬前提，任何一项不成立都回退为不透明。
4. 保持键盘优先，补齐可见焦点、hover、pressed、溢出和 reduced-motion 行为。
5. 优先复用现有 Catppuccin 色板、HarmonyOS Sans、JetBrains Mono、ArkUI/ArkWeb 和
   xterm WebGL，不引入新依赖或平行状态源。

## 非目标

- 不做高透明“玻璃展示”、壁纸可读背景、动态材质或持续背景动画。
- 不增加连续透明度滑杆、模糊强度、Tab 宽度、动画、图标或快捷键设置；五档全窗口透明度
  是本轮唯一新增的外观选择。
- 不做无限呼吸、全窗口闪烁、系统通知中心或通用提醒框架。
- 不改变已经接受的终端紧凑间距，不扩展搜索范围或重做 Terminal Surface。
- 不改变固定宽度 Tab、横向滚动、最多双 Pane、搜索所有权或 SSH 事件链。
- 不引入新图标包、主题系统、动画框架或为未来外观扩展预建抽象。

## 产品原则评估

### 用户信任与安全

本轮只改变本地渲染与交互反馈，不新增网络、遥测或秘密数据路径。透明窗口仅声明
HarmonyOS 的普通、系统授予权限 `ohos.permission.SET_WINDOW_TRANSPARENT`，不触发用户
授权提示，也不读取额外数据。BEL 只使用现有 Pane 注意力状态，搜索查询仍由当前
Terminal Surface 独占。透明效果不得暴露新的终端内容副本，也不得把窗口或终端内容
交给外部服务。

### 可靠

终端可读性、焦点、Tab/Pane 归属、TUI 背景色、selection、链接和 WebGL renderer
正确性高于视觉效果。透明度是可撤回的表现层增强；任一档在目标设备上无法稳定证明时，
不得用模糊或兼容 hack 强行维持，必要时回退到更低透明度。BEL 重复触发必须合并，不得
累积动画队列。

### 简洁高效

方案复用现有状态与主题 token，只增加局部视觉规则。固定 Tab 宽度与横向滚动继续作为
唯一多 Tab 模型；透明度只保留关、低、中、高、极限五个语义档位，不建立连续参数或外观设置页。
搜索条只压缩布局，不增加模式或按钮。

### 易用

非活动 Tab、`+`、拖拽区和分屏边界变得可辨；键盘焦点始终可见；BEL 同时提供动画与
静态标记，不要求用户依赖颜色或恰好看到动画。

## 当前事实与证据边界

- 活动窗口使用自定义 40vp Chrome；Tab 固定 172vp，Tab 间距 4vp，Tab 区横向滚动，
  `+` 位于滚动区外，标题栏保留至少 96vp 拖拽区域和约 140vp 系统按钮区域。
- 1.3 首轮实现让 Chrome 轨道使用 Catppuccin crust，非活动 Tab 直接露出轨道，活动/hover Tab
  使用一层 80% surface0。2026-08-14 真机复查证明这会把非活动 Tab 与轨道合并，并且不足以在
  Off/Medium/Extreme 下稳定区分活动表面；该实现是失败基线，不再作为完成证据。
- `needsAttention` 的原基线在 Pane 四周绘制 2px 黄色边框；当前实现已改为有限 Tab 强调、
  复用 Tab 前导状态点的静态标记，以及分屏来源侧的局部标记。
- 搜索条原基线固定约 420px；当前实现收敛为 344px，并固定结果区和三个操作按钮宽度。
- xterm 已使用 WebGL；WebGL 只负责终端渲染，不自动实现 HarmonyOS 窗口透明。透明需要
  窗口合成、ArkUI、ArkWeb 页面背景和 xterm 配置整条链同时成立。
- xterm 的 `allowTransparency` 必须在 `open` 前确定，并明确可能增加性能成本。当前实现
  让活动态 PC 容器和原生内容窗口透明，仅由不重叠的 ArkUI 区域 Surface 持有选定 alpha；
  ArkWeb、HTML/body 和 xterm 默认背景透明透传，显式终端内容保持上游语义，避免多层 alpha
  叠加。
  物理 PC 已证明五档
  Chrome/Content 分层合成链成立；正式候选同机性能和生命周期已完成，真实用户服务器
  TUI 与主观可读性也已由用户完成。
- 现有深浅主题已统一 Chrome、Terminal、divider、text、accent、attention、focus 与
  Pane 控件 token；生产路径中三个确认无引用的旧组件已删除。

上述实现事实与定向设备结果不替代正式候选的完整视觉、性能或生命周期证明。

### 2026-08-14 1.3 Tab 层级复开

用户在四个真实 Tab 和 Off/Medium/Extreme 下确认 Chrome rail、非活动 Tab 与活动 Tab 仍然过近。
失败不是单个 RGB 参数问题：`tabBackground` 的 alpha 为 `0`，因此非活动 Tab 在定义上就是 rail；
活动与 hover 又共用 80% surface0，既没有独立 hover 层，也会在更透明的系统材质上丢失相对差异。

2026-08-14 的后续浅色/深色背景走查又否定了“rail 连续五档、Tab 固定一组 surface”的方案：
Low 与 High 在浅色背景下仍会让 rail 和非活动 Tab 合成趋同，Medium 为补偿浅色背景而提升到
surface2 后又在深色背景中过亮。这不是继续微调单个 RGB 能稳定解决的问题，而是 Chrome 同时
跟随五档 alpha、Tab token 和桌面背景三组变量造成的组合爆炸。

最终合同把五档用户语义映射为三个内部 Chrome 模式。终端内容区继续按五档逐级透明；Chrome
只承担关闭透明、常规透明和高透明三种稳定视觉状态。同一模式内 rail、非活动、hover、活动
四层使用相同 alpha，避免不同 alpha 合成后在浅色背景趋同。后续日常观察确认三种模式的活动
Tab 仍然偏亮，因此先把三种模式收敛到低亮度角色；真机首次部署后又确认 B/C 与 rail 的间距
不足。最终只让 B/C 从低亮度基线各上提一小级，A 保持菜单选中行水平，不引入新色相、设置或
状态源：

| 模式 | 对应档位 | rail | 非活动 | hover | 活动 | 统一 alpha |
| --- | --- | --- | --- | --- | --- | ---: |
| A 不透明 | Off | base | base/surface0 50% | base/surface0 75% | surface0 | `1.00` |
| B 稳定 | Low / Medium | base | base/surface0 80% | surface0/surface1 15% | surface0/surface1 40% | `0.94` |
| C 高透明 | High / Extreme | base | surface0 | surface0/surface1 50% | surface0/surface1 75% | `0.86` |

产品只保留一套深色调色板，不表达可切换的 Light/System 主题。模式 A 使用 Mocha base
`#1E1E2E` 到 surface0 `#313244` 的同色系插值，非活动/hover 分别为 `#282839` / `#2C2D3F`；
B 模式非活动/hover/活动为 `#2D2E40` / `#343547` / `#393A4D`，C 模式三态为 `#313244` /
`#3B3D4F` / `#404255`。这些固定 token 仍需在浅色与深色桌面背景上验证透明合成后的可辨性，
但桌面背景差异不产生第二套应用 palette。文字、关闭按钮与焦点环继续提供状态反馈。Tab 仍使用现有形状、
4vp 间距、文字权重、状态点和焦点环；不增加
分隔线、阴影、渐变、主题选项或新状态源。完成条件是自动化锁定三模式映射，并用同一物理 PC
的四 Tab 在浅色与深色桌面背景下逐档确认 rail、非活动 Tab 和活动 Tab 稳定可辨。

此前 HAP `364a82850afbccacacfcffb6330d7f65ddce731a661e6af57451dd317feba7c0` 的截图只证明被后续
走查否定的旧方案，不再作为本项完成证据。新三模式映射必须重新构建并部署到物理 HAD-W32，
由用户在真实桌面背景下完成最终主观确认。

2026-08-14，新映射已通过 ArkTS 105/105，并构建、测试签名、安装和启动到物理 HAD-W32。
测试 HAP SHA-256 为 `23037d267a03e83ab31ead39d782883c0b91457a39ab091f025e29cdadf976ee`；
部署后 PID 为 `45959`，五 Tab 的 Medium 基线截图和布局保存在忽略目录
`build/verification/chrome-three-mode-20260814/`。这些事实证明实现已进入测试机，不替代用户对
真实浅色/深色桌面背景及五档切换的最终主观确认。

2026-08-15，用户在首轮真机观察中认为 A/B 活动 Tab 仍然过亮。活动态从 surface2 下压到
surface1，hover 复用 surface1 的 86% alpha；C 模式保持 surface1 / surface2 / overlay0 的
增强层级。调整后的 ArkTS 仍为 105/105，通过 ARM64 调试构建、测试签名、覆盖安装与启动；
HAP SHA-256 为 `71d701edbf74aa93528067eb88ee5b466f3eec97c7c5500ba739d40d646c2c2c`，
设备 PID 为 `49638`，Medium 真机截图为同一证据目录下的
`deployed-screen-calibration05.png`。2026-08-15，用户完成真机逐档观察并确认调整后没有问题；
该精确 HAP 的三模式 Chrome 方案成为 1.3 当前完成基线。

同日后续日常观察再次确认 A/B/C 三种模式的活动 Tab 都高于应用其余“当前项”表面，C 模式的
overlay0 尤其突出。根因是 Tab 角色使用 surface1/overlay0，而菜单当前选中行只使用 surface0。
首轮修订将三种模式活动态统一降至同主题 `commandBarBorder` / surface0，非活动与 hover 分别降至
base 和 surface0 的 50% / 75% 插值；rail 和三模式 `1.00 / 0.94 / 0.86` alpha 不变。部署后用户
澄清需要上提的是内部模式 B 和 C，而不是五档中的第二、第三档；实机观察显示这两种模式的 Tab
已与 rail 趋同。最终保留 A 的低亮度组，B/C 非活动升到 base→surface0 70%，hover 升到 surface0，
活动升到 surface0→surface1 25%；仍明显低于旧 surface1/overlay0 方案。旧 HAP `71d701ed...` 与
本次第一次低亮度 HAP 都不再代表当前完成基线，必须以最终重新部署结果确认。

修订后的 Web 视觉策略测试、ArkTS 107/107 与 ARM64 debug 构建通过；测试签名 HAP SHA-256 为
`8e451561ec5833d089edc85eb391af1f43a4988108fc4cdcf9031e8b76e1a4da`，已覆盖安装并启动到物理
HAD-W32，设备 PID 为 `52376`。这些事实证明 B/C 精确 token 已进入测试机；最终亮度仍由用户在
真实桌面背景和对应透明档位下确认。

该版本真机观察后，用户要求 B 只再提高一点、C 明显提高更多。最终 B 将非活动提高到
base→surface0 80%，hover/活动提高到 surface0→surface1 15%/40%；C 将非活动提高到 surface0，
hover/活动提高到 surface0→surface1 50%/75%。这保留了 B/C 不同的透明场景补偿强度，同时活动
Tab 仍低于完整 surface1，更不回到旧 overlay0。上述 `8e451561...` HAP 因产品 token 再次变化而
失效，必须重新构建部署。

最终分级通过 Web 视觉策略测试、ArkTS 107/107 与 ARM64 debug 构建；测试签名 HAP SHA-256 为
`13197f1ec1c2f9615ba737045f7731f484650b7647a68e41d728ff0d375dfab1`，已覆盖安装并启动到物理
HAD-W32，设备 PID 为 `54657`。等待用户对 B 的轻微上提和 C 的较大上提完成最终主观确认。

### 2026-08-07 二次走查决定（历史基线，已被五档扩展替代）

- Tab 间分隔线应位于 172vp Tab 之外的 4vp 间距正中，而不是贴在左侧 Tab 的内容边缘。
- 活动与非活动 Tab 的表面都延伸到内容区基线，底部不再留下使非活动 Tab 看似悬浮的
  Chrome 条带；状态仍通过表面、文字、关闭按钮与注意力标记区分。
- 搜索无结果使用紧凑的 `0/0`；该历史基线曾让空查询不显示计数，最终方案已统一为空查询
  也显示 `0/0`。空查询的可访问名称为 `Type to search`，非空无结果为 `No results`。
- 右上菜单恢复 HarmonyOS 既有的 2×2 四点图形，不用三点省略号替代；菜单内新增一行
  `透明度  高/中/低`，点击或 Enter 循环切换，菜单保持打开以便比较。
- 内容透明度固定为高透明 `0.78`、中透明 `0.88`、低透明 `0.96` 三档背景不透明度，默认
  中透明。只持久化这一语义档位，深浅主题共用同一档位语义，不使用 blur。
- 搜索面板与 Pane 关闭按钮增加安全间距；全高分屏线降低静态权重，hover、focus 和拖动
  时才增强；多 Tab 溢出继续保证活动 Tab 完整可见并保留轻量边缘淡出。
- 终端现有 `4px 2px 4px 10px` 内容留白保持不变。右侧 scrollbar 已形成视觉配重，因此
  不按纯几何对称重排内容，也不把该项纳入实现或验收。

## 已确认扩展：五档全窗口材质

> 提案日期：2026-08-08
>
> 状态：已实现；用户通过真机比较器选择并固定 Regular 材质
>
> 影响范围：只替换现有“三档内容透明度、单击循环、Chrome 不透明、无 blur”方案。
> 实现顺序与可观察完成条件已同步到 `docs/next-work.md`；后文的三档内容继续记录本次扩展
> 前的实现与设备证据，不再授权最终 1.2 行为。

### 确认结论

将透明度保留为一个设置，但把交互收敛为带明确增减方向的五档步进器：

```text
┌──────────────────────────────────────┐
│  ◐  Transparency       [−] Medium [+] │
└──────────────────────────────────────┘
```

- 使用左减右加，不使用左右箭头或上下箭头。`−` 表示降低“透明”强度，`+` 表示提高“透明”
  强度；箭头更容易被理解成焦点移动、菜单导航或展开方向。
- 中间只显示当前语义档位，固定 56vp 宽并居中，切换 `Off / Low / Medium / High / Extreme`
  时整行不位移。文档中的中文语义为“关 / 低 / 中 / 高 / 极限”，实际文案跟随应用现有
  语言。
- 两个可见按钮为 28vp，实际命中区至少 32vp，复用现有 hover、pressed、disabled 和
  focus token，不引入新图标。四点菜单图形保持 HarmonyOS 2×2 规范不变。
- 到达“关”后禁用减号，到达“极限”后禁用加号；不首尾循环。每次点击只移动一档，
  菜单保持打开，用户能连续比较且不会从极限意外跳回不透明。
- 整行是一个键盘复合控件和一个 Tab 焦点停靠点。焦点位于该行时，Left/Right 降低/提高
  一档；读屏名称包含当前档位和可用操作。两个可见符号仍分别提供
  `Decrease transparency`、`Increase transparency` 的可访问名称。

不采用单个按钮循环、连续滑杆或二级设置页。它们分别存在方向不可预期、难以回到相邻
状态和增加永久外观概念的问题，不符合简洁高效原则。

### 五档数值与默认值

档位表示“透明强度”，实现 token 使用“背景不透明度”。数值采用递增的透光跨度，前
三档覆盖公开终端配置中最常见的克制区间，极限档明确留给主动追求更强材质感的用户：

| 档位 | 内容背景不透明度 | 内容透光量 | Chrome 背景不透明度 | Chrome 透光量 | 角色 |
| --- | ---: | ---: | ---: | ---: | --- |
| 关 Off | `1.00` | `0%` | `1.00` | `0%` | 完全不透明基线与最终回退 |
| 低 Low | `0.82` | `18%` | `0.88` | `12%` | 采用旧 Medium 基线，避免与 Off 差异过小 |
| 中 Medium | `0.72` | `28%` | `0.80` | `20%` | 推荐默认；透明清楚可感知但终端内容仍主导 |
| 高 High | `0.60` | `40%` | `0.70` | `30%` | 采用旧 Extreme 基线，提供明显材质感 |
| 极限 Extreme | `0.45` | `55%` | `0.55` | `45%` | 更激进的主动选择；文字、焦点和 TUI 仍须可读 |

推荐默认保持“中”，避免改变已经确认的默认语义；新装、偏好缺失或非法值都回到中档。
现有 Low/Medium/High 偏好按语义原位迁移，不按旧 alpha 猜测用户意图；新增 Off 和 Extreme。

这组值不是把其他终端的单个示例直接复制过来：Ghostty、Windows Terminal、WezTerm 和
kitty 的正式默认都保持完全不透明，说明可靠阅读仍应是基线；公开配置示例则多落在
`0.80–0.95` 左右，但没有可信的跨产品使用率统计。首轮 Low 的 4% 透光在真机上与 Off
几乎无差异，因此最终把 Low 对齐到上一轮 Medium 的 `0.90`，其余档位按相同可感知跨度
展开，并把 `0.60` 单独命名为 Extreme，而不伪装成普通默认。

Chrome 不是独立设置。它由同一个语义档位派生，并且始终比内容区更实；档位
越强，两区仍保留明确差值。这能让 Tab、拖拽区、四点菜单和系统按钮保持稳定结构，
同时避免顶部形成一条与内容区割裂的不透明横条。活动 Tab、hover、pressed、focus、BEL
标记继续使用现有表面和状态 token，不再叠加第二个区域 alpha。

### 模糊调研与采用边界

| 产品/平台 | 正式默认与能力 | 对本提案的启示 |
| --- | --- | --- |
| Ghostty | 背景不透明度默认 `1.0`；背景模糊只在透明时生效，`true` 等价于半径 `20`，文档称其为合理值；显式 cell 背景默认不透明 | 模糊应只处理窗口背后，不模糊字形，也不让 TUI 显式背景漏底 |
| Windows Terminal | opacity 默认 `100`；Acrylic 是可选的模糊透明材质，默认关闭；系统可能因 GPU、远程桌面或节能策略禁用 Acrylic | 模糊必须是可撤回的系统能力，不能成为终端启动或正确性的前提 |
| WezTerm | opacity 默认 `1.0`，文档明确提示非默认透明可能影响渲染性能；Windows 系统 backdrop 独立、默认关闭 | 透明与模糊都需要同机性能证据，不能从“使用 WebGL”推导为免费 |
| kitty | opacity 默认 `1.0`、background blur 默认 `0`，文档提示高模糊值可显著影响性能；显式 TUI 背景默认保持不透明 | 不开放模糊强度，不把高斯效果应用到每个 Pane 或终端单元格 |
| HarmonyOS ArkUI | 当前 SDK 提供 `backgroundBlurStyle` 的系统材质预设，以及跟随窗口活动态的策略；原始 `backdropBlur` 是动态模糊，本机性能规则提示逐帧刷新可能带来重负载和掉帧 | 优先验证一个系统预设；不自行实现高斯核，不把大面积动态半径模糊作为默认路径 |

调研依据：

- [Ghostty 配置参考](https://ghostty.org/docs/config/reference)
- [Windows Terminal 配置文件外观设置](https://learn.microsoft.com/zh-cn/windows/terminal/customize-settings/profile-appearance)
- [Windows Terminal 故障排除中的 Acrylic 限制](https://learn.microsoft.com/en-us/windows/terminal/troubleshooting)
- [WezTerm 外观配置](https://wezterm.org/config/appearance.html)
- [WezTerm Windows 系统背景材质](https://wezterm.org/config/lua/config/win32_system_backdrop.html)
- [kitty 配置参考](https://sw.kovidgoyal.net/kitty/conf/)
- [OpenHarmony ArkTS 模糊效果指导](https://gitcode.com/openharmony/docs/blob/OpenHarmony-6.0-Release/zh-cn/application-dev/ui/arkts-blur-effect.md)
- Ghostty 公共配置样本：[0.95](https://github.com/ghostty-org/ghostty/discussions/7356)、
  [0.85 加半径 20](https://github.com/ghostty-org/ghostty/discussions/7630)。它们只证明常见
  取值实例，不代表使用率统计。

实现阶段在所有非 Off 档位只验证了同一个系统中等背景材质候选：
`BlurStyle.BACKGROUND_REGULAR`，活动策略使用
`BlurStyleActivePolicy.FOLLOWS_WINDOW_ACTIVE_STATE`。模糊强度不随五档变化，也不向用户
暴露第二个设置；五档只改变两组表面 alpha。这样用户只需要理解一个维度，性能和失效
范围也保持有界。

第一轮 HAD-W32 自动截图无法证明该预设对窗口后桌面的处理效果，因此曾按停止条件临时
撤回；这不是最终人工观感结论。随后用户在同一设备、同一透明档位下直接比较五种系统
材质并选择 Regular。最终产品只固定 `BACKGROUND_REGULAR`，仍不采用自定义 Gaussian、
CSS `filter`、WebGL shader、逐 Pane `backdropBlur` 或桌面截图方案。

为避免只依赖自动截图作最终判断，2026-08-08 另提供一次仅存在于 `ACCEPTANCE_TESTS` 调试
HAP 的人工比较器。它在四点菜单中以 `[−] 当前材质 [+]` 暴露 `None / Thin / Regular /
Thick / Ultra`，分别映射 `BlurStyle.NONE` 与四个 `BACKGROUND_*` 系统预设；状态不持久化，
启动固定回到 None。用户选择 Regular 后，该调试入口及其状态已删除；正式源码仅在窗口根
节点挂一次固定 Regular 材质，不向用户暴露第二个设置。

### 合成与状态所有权

```text
TransparencyLevel (唯一持久化语义：Off/Low/Medium/High/Extreme)
        │
        ├── derive chromeAlpha
        └── derive contentAlpha

Window compositor (active transparent; inactive opaque)
        └── Root material (Regular when non-Off, otherwise None)
        ├── Chrome sibling surface (chromeAlpha)
        └── Content sibling surface (contentAlpha)
              └── Pane / ArkWeb / HTML / xterm WebGL transparent pass-through
```

- `ThemeManager` 继续是运行时档位与派生 token 的唯一权威，`UserPreferences` 只持久化一个
  语义档位。Chrome alpha、内容 alpha 与固定 Regular 材质都不是独立用户状态。
- 现有“整个 ArkUI 根 Surface 是唯一 alpha 所有者”需要改为“Chrome 与内容两个不重叠的
  兄弟 Surface 各自拥有区域 alpha”。共同祖先不得再持有相同 alpha，否则会产生复合透明；
  Pane、ArkWeb、HTML/body 与 xterm 默认背景仍然透明透传，显式终端内容不叠加区域 alpha。
- 系统背景材质固定为一次根级 Regular。不得给 Chrome、每个 Pane 和 ArkWeb 分别做模糊，也
  不得让模糊进入终端 glyph、selection、search decoration 或显式 TUI cell background。
- 搜索条、弹出菜单和链接菜单是短期浮层，保持现有近不透明表面，不随 Extreme 降低；
  hover、pressed、focus 与系统按钮命中区也不通过区域 alpha 表达状态。
- 非活动窗口继续按 HarmonyOS 现有限制使用主题不透明容器。用户偏好不变，重新激活后
  恢复所选档位。

### 失败与降级顺序

透明是表现层偏好，模糊只是可选增强。任何失败都不得影响 Session、输入输出、Pane/Tab
状态、WebView 生命周期或启动：

1. 系统背景材质不支持、视觉不正确或性能不成立：移除 blur，保留所选五档透明度。
2. 系统透明窗口不支持或初始化失败：本次运行使用 Off 的完全不透明表现，但不改写用户
   持久化偏好；能力恢复后仍可还原。
3. 档位值缺失或非法：恢复 Medium；不通过猜测旧 ARGB 创建隐式第六档。
4. 切换档位只更新派生主题 token 和已挂载 Surface，不重建 ArkWeb，不重连 SSH，不刷新
   Terminal buffer。

Extreme 也必须在系统材质不可用的无 blur 回退下保持终端字形和显式 TUI 背景正确；模糊
不能成为弥补过低对比度的补丁。若 `0.60` 无法通过可读性验证，应提高 Extreme 的不透明度，而不是
增加更强模糊、阴影或文字描边。

### 最小验证结果与剩余边界

实现和可观察完成条件已同步到唯一活动清单 `docs/next-work.md`，已按以下顺序执行：

1. 已实现五档步进器、语义持久化、固定 Regular 根材质及 Chrome/Content 两个非重叠 alpha 区域；
   自动化覆盖边界禁用、非循环、键盘方向、派生值、迁移和不重建 WebView。
2. 目标 PC 已逐档确认当前产品深色主题 ARGB、按钮边界、菜单保持打开、非循环和重启恢复；
   窗口尺寸、双 Pane、常见 TUI 与性能/生命周期的完整矩阵仍按用户要求留到最终验收。生产
   入口当前固定深色，未暴露的浅色 token 只保留自动化约束，不为本轮验收新增主题入口。
3. 已通过调试比较器真机比较 None/Thin/Regular/Thick/Ultra；用户选择 Regular，比较器随后删除。
4. 已停止探索自定义算法。最终验收仍放在 1.2 所有实现工作的最后。

### 已确认决定

2026-08-08 已确认以下整组结论，不拆成多个长期设置：

1. 菜单采用 `[−] 当前档位 [+]`，边界禁用、不循环、菜单保持打开。
2. 五档采用内容 `1.00 / 0.82 / 0.72 / 0.60 / 0.45`，默认 Medium。
3. Chrome 由同档位派生 `1.00 / 0.88 / 0.80 / 0.70 / 0.55`，不允许独立调节。
4. 非 Off 固定系统 `BACKGROUND_REGULAR` 材质；Off 或透明能力失败时使用 None/不透明回退。
5. 不采用自定义 Gaussian、CSS/WebGL blur、逐 Pane 动态 blur、截图背景或模糊强度设置。

## 视觉系统

### 层次与材质

界面只保留三层：窗口 Chrome、终端内容、短期浮层。Chrome 比内容区略实，承担窗口与
工作区结构；Terminal 保持最高可读性；搜索条是唯一浮在 Terminal 上方的短期控件。
三层都使用现有主题色，不新增品牌渐变或高饱和装饰。

透明度使用关/低/中/高/极限五档固定值。内容背景不透明度为
`1.00/0.82/0.72/0.60/0.45`，Chrome 为 `1.00/0.94/0.94/0.86/0.86`，默认中档。
两区共用同一语义档位但持有不重叠的派生 alpha；搜索浮层、链接菜单和明确设置背景的
TUI 单元格保持稳定。显式 ANSI/TrueColor 单元格背景另用 `0.24/0.20/0.16/0.12/0.08`
的 renderer-only alpha，避免它们在透明窗口上形成实黑矩形；文字始终保持不透明。窗口根
仅使用一次系统 Regular 材质，不形成互相叠加的玻璃层。

### 颜色与字体

- 继续使用现有 Catppuccin 深浅色 token，不新增第二套 palette。
- Chrome 轨道使用深色 `#11111B` / 浅色 `#DCE0E8` crust，并继续承载五档区域 alpha；
  非活动 Tab 不再叠加几乎同色的表面，直接露出轨道；活动与 hover 使用 80% surface0
  `#313244` / `#BCC0CC`。Tab 不依赖会随档位塌缩的局部整体 opacity 表达层级。
- 结构边界优先使用 divider token 的低对比度变体；活动、hover、pressed 和键盘焦点
  逐级增强，但不使用纯白描边。
- attention 使用现有琥珀色 token；静态标记同时保留形状，不能只靠色相表达状态。
- UI 继续使用 HarmonyOS Sans，终端继续使用 JetBrains Mono；不改变字号层级。

### 顶部结构

```text
┌ [● host ×]  [○ ltty ×] │  +  │  可拖拽空白区  │ 2×2 四点 │ 系统按钮 ┐
└───────────────────────────────┬──────────────────┘
                                Terminal
```

Tab 多于可视宽度时仍横向滚动；边缘只在确实还有不可见 Tab 时显示短而轻的淡出提示。
`+` 固定在滚动区外，通过一条短分隔线与 Tab 区分开。其后至少 96vp 空白继续是窗口拖拽
区域，不用假内容填满，也不让 `+` 与系统按钮漂移。

## 已确认交互契约

### Tab 与溢出

- Tab 宽度保持 172vp，不做自适应压缩、最小/最大宽度算法或用户设置。
- 非活动 Tab 露出轨道，活动与 hover 使用 surface0；相邻 Tab 只通过 4vp crust 轨道间距与
  active/inactive/hover 表面差异区分，不绘制竖线。所有 Tab 表面延伸到内容区基线且底角
  不再圆角，活动 Tab 与 Terminal 形成连续层次，不增加完整外框。
- 关闭按钮默认低权重，hover、pressed 和键盘焦点时明确；不能因缩小标题空间而遮住
  状态图标或主机名。
- 当 Tab 区未溢出时不显示边缘淡出；溢出时淡出不能遮住可点击内容，也不能取代滚动。
- `+` 前的短分隔、固定位置和独立交互状态共同表达其不是最后一个 Tab。

### BEL 注意力

BEL 是本轮唯一允许具有明显运动的元素。

- 当前获得焦点的 Pane 收到 BEL：在对应 Tab 上播放一次短促、低幅呼吸，不建立待处理
  状态；用户已经在看该内容，因此动画结束后不保留标记。
- 非活动 Tab 的 Pane 收到 BEL：对应 Tab 播放两次柔和呼吸，之后保留静态琥珀标记，
  直到用户明确进入产生 BEL 的 Pane 或在该 Pane 输入。
- 当前 Tab 的非焦点分屏 Pane 收到 BEL：Tab 使用相同有限呼吸与静态标记；对应 Pane 在
  分隔线一侧显示小型局部标记，帮助用户判断来源。切到该 Pane 或在其中输入后清除。
- 多次 BEL 在一个动画窗口内合并，重新开始有限动画但不排队、不无限延长。
- 移除 Pane 四周的黄色边框。reduced-motion 下跳过呼吸，仅使用静态标记和状态变化。
- 动画只改变小范围 opacity/强调程度，不缩放 Tab、不改变布局，也不闪烁 Terminal 内容。

### 五档透明与回退

- 整个活动窗口使用协调的分区透明：Chrome 比内容区更实。只提供关、低、中、高、极限五个
  固定档位，默认中档；入口位于四点菜单内，不在标题栏增加常驻图标。
- 菜单使用 `[−] 当前档位 [+]` 非循环步进器；边界按钮禁用，每次只移动一档。切换后菜单
  保持打开，Escape 或点击外部才关闭；该行获得焦点时 Left/Right 调整。
- `ThemeManager` 是运行时档位和 alpha 的唯一权威，`UserPreferences` 只保存语义档位；
  正常重启恢复，卸载后不承诺保留。切换通过现有主题桥更新所有已挂载 Pane，不重建
  WebView，不改变 Session、Tab 或 Pane 状态。
- 非 Off 档只在窗口根挂一次固定 `BACKGROUND_REGULAR`，跟随窗口活动态；Off 或透明能力
  失败时使用 None/不透明回退。材质不是用户设置，也不随五档改变强度。
- 原生窗口在页面加载后设置透明背景；PC 容器只把活动态设为透明，非活动态按 HarmonyOS
  限制保持主题不透明色。平台拒绝透明设置时，能力标记保持 false，ArkUI 根 Surface
  自动使用完全不透明的主题背景，启动与终端功能不受影响。
- Chrome 与 Content 两个不重叠兄弟 Surface 是区域 alpha 的唯一所有者；共同祖先、
  Pane/Web 组件、HTML/body 与 xterm 默认背景全部透明透传。xterm WebGL 只对显式单元格
  背景、字形、光标和 selection 保留上游颜色与不透明语义，不再拥有独立 alpha。
- Shell、tmux、vim、less 和主流 Agent TUI 显式设置的 cell/background 必须保持正确；
  不得出现块状漏底、文字对比不足、selection/search decoration 异常或残影。
- 大持续输出、滚动、窗口缩放、主题切换、最小化/恢复、renderer 退出与重建不能出现
  明显掉帧、输入延迟、GPU/内存异常增长或背景状态漂移。
- 用户通过真机比较选择固定 Regular；若后续完整矩阵证明材质或轻透明不成立，则先撤
  Regular、再回退完全不透明 Terminal。这是成功的裁剪路径，不新增兼容框架。

### 搜索条

搜索条目标宽度约 344px，按以下紧密分组：

```text
[ Find…              1/7 ][↑|↓] [×]
```

- 查询输入可用宽度保持约 190–220px；结果区固定约 48px；按钮为 26–28px，按钮间距 2px。
- 空查询和非空无结果都显示 `0/0`；普通结果显示当前位置/总数；超出上限显示 `1000+`。
  空查询的可访问说明为 `Type to search`，非空无结果为 `No results`。
- Previous/Next 是同一搜索导航任务，共用一条外框并以中线分隔；Close 是退出动作，使用
  独立外框和 2px 额外间距。三个按钮都保留 26px 命中尺寸、可见 focus ring，并以统一的
  300ms 深色 Tips 显示 `Shift+Enter`、`Enter`、`Esc`。禁用导航只弱化图标颜色，不降低
  整个按钮 opacity，避免连带削弱 Tips 可读性。
- 面板仍位于当前 Terminal Surface 右上角，但必须避开 Pane 关闭按钮、scrollbar 和分屏
  边界；窄 Pane 时输入区先收缩，按钮与结果反馈保持可操作。
- 不改变 `Ctrl+Alt+F`、Enter、Shift+Enter、Escape、输入法、焦点和搜索所有权语义。

### 分屏、图标与焦点

- 分屏使用全高低对比分隔线，中点保留短手柄；hover/拖动时只强调手柄和邻近边界。
- Pane 关闭按钮改用主题 token，避开搜索条与 scrollbar，并具有清楚的 hover、pressed
  和键盘焦点状态。
- Tab、关闭、`+`、菜单、搜索与分屏控件均提供可见 focus ring；焦点不能只靠底色变化。
- 菜单使用 HarmonyOS 既有 2×2 四点图形，不用三点省略号替代，也不新增图标依赖。
- 移除确认无引用的重复 UI 组件和深色硬编码前，必须先证明其不在生产路径；不借本轮
  进行目录或架构重构。

## 所有权与事件链

```text
SSH byte stream -- BEL --> Session/Pane existing attention state
                              ├─ ChromeBar: finite tab pulse + marker
                              └─ focused split: local pane marker

Window compositor(active transparent; inactive opaque)
              --> ArkUI root(fixed Regular material, no regional alpha)
                    ├─ Chrome surface(chrome alpha)
                    └─ Content surface(content alpha)
                          --> ArkWeb page(transparent) --> xterm WebGL(transparent)
                    visual tokens only; no new business state
```

- Pane 继续拥有 attention 状态，Tab 只聚合并渲染所属 Pane 的结果。不得以 Tab index、
  WebView 实例或动画状态替代稳定 Pane ID。
- 动画运行状态是短生命周期 UI 状态，不持久化、不进入 Session、不经过 SSH Bridge。
- 搜索查询与布局继续由 Terminal Surface 独占；本轮只改变其 CSS/布局。
- 四点菜单 Search 只调用当前活动 Pane 的既有 `openSearch`；Transparency 和 Font Size 都是
  单焦点 `[−] 当前值 [+]` 复合行，Left/Right 调整且不关闭菜单。字号全局使用
  `Ctrl+-` / `Ctrl+=`，透明度使用同一增减语义的 `Ctrl+Alt+-` / `Ctrl+Alt+=`，Alt 层必须
  阻止透明度调整误入字号分支；`Ctrl+0` 保留字号重置。四个按钮使用平台原生 hover Tips
  显示各自快捷键，并在无障碍说明中包含同一键位。
- 主题 token 是颜色与层次的唯一来源；`ThemeManager` 统一派生 Chrome/Content 两个
  非重叠 ArkUI Surface 的 ARGB，Web/xterm 背景保持透明，透明能力检测与回退只决定表现，
  不改变业务状态。
- Surface 销毁、Tab/Pane 关闭、warm 淘汰和 renderer 重建必须取消动画计时器，不让迟到
  回调驱动已销毁的 Pane。

## 失败行为

- 动画或 marker 渲染失败不能阻塞终端输入、输出、切换或关闭。
- BEL flood 只更新现有注意力状态并合并动画；不得创建无界 timer、Promise 或事件队列。
- 透明偏好缺失或非法时回到中透明；初始化失败、renderer 不支持或性能证据不成立时，
  静默降低透明度或回到不透明表现，不阻断启动或向用户暴露不完整设置。
- 窄窗口或系统字体变化时，优先保证 Tab 标题、`+`、系统按钮、搜索操作和拖拽区可用；
  淡出、装饰分隔和局部 Pane 标记可以裁剪。
- 浅色与深色主题都必须维持文字、焦点和边界可辨；不能用深色硬编码补偿某一主题。

## 实现约束

二次走查按依赖顺序推进：先修正 Tab 基线/间距、搜索反馈/间距、四点菜单和分屏静态层次，
再增加五档透明度状态、持久化与已挂载 Surface 同步，之后运行定向软件门禁和 ARM64 构建，
最后在实体机完成 UI 与交互验收。透明验证不得阻塞其余已确认改进。

优先在现有 `ChromeBar`、`TerminalPane`、`terminal.html` 和主题常量中局部实现。只有
同时拥有独立状态或可测试策略时才新增类型；不建立 DesignSystem、AnimationManager、
AttentionService 或 SurfaceEffect 抽象。无引用旧组件的删除必须独立、可证明且不混入
行为规则。

## 当前实现与定向证据

2026-08-08 已采用以下实现：

- Tab 保持 172vp；非活动项使用轻表面且不再绘制相邻竖线，溢出使用平台淡出，`+` 固定在滚动区外并
  以短分隔区分，拖拽区仍保留至少 96vp。
- BEL 继续由 Pane 拥有状态。活动来源一次、非活动来源两次的有限 opacity 强调由 Tab
  渲染；持久提醒复用 Tab 前导状态点，避免标题尾部在溢出时被裁掉；分屏来源只在分隔线
  一侧显示小点。旧的整 Pane 黄色边框已移除。
- 已实现 Off/Low/Medium/High/Extreme 五档非循环步进器，内容背景不透明度为
  `1.00/0.82/0.72/0.60/0.45`，Chrome 为 `1.00/0.88/0.80/0.70/0.55`，默认 Medium。
  页面加载后把活动态 PC 容器和原生内容窗口设为透明，非活动态容器保持主题不透明色；
  Chrome 与 Content 两个不重叠 ArkUI Surface 分别独占区域 alpha，ArkWeb/HTML/xterm 默认
  背景透明透传，显式终端内容保持上游语义；`allowTransparency` 在 `term.open` 前启用。
  切换复用既有主题桥且不重建
  WebView；平台能力失败时两区都回退不透明。语义档位写入本地 Preferences，未采用连续
  滑杆或外观设置页。非 Off 档在窗口根固定一次 `BACKGROUND_REGULAR` 并跟随窗口活动态，
  不存在材质设置、持久化材质状态或逐 Pane 模糊。
- Tab 间竖线已移除，所有 Tab 表面接到内容区基线；搜索条仍为 344px，结果区改为 48px，
  空查询和无结果都显示 `0/0`，右侧安全间距增加到 54px；HarmonyOS 2×2 四点菜单已恢复，
  并包含正式 Search、Transparency/Font Size 两个复合步进器；全高分屏线静态 opacity 为 0.64。
- 字号步进器沿用 `Ctrl+-` / `Ctrl+=`，透明度步进器新增 `Ctrl+Alt+-` / `Ctrl+Alt+=`；四个
  全局快捷键在菜单打开或关闭时都由工作区优先处理。四个按钮使用 300ms 延迟的原生
  `bindTips`，鼠标悬停时显示对应键位；没有引入自定义 Tooltip、计时器或覆盖层框架。
- 删除生产路径确认无引用的 `TabBar.ets`、`PaneHeader.ets` 和 `ToolMenu.ets`，未引入依赖
  或新的状态/服务层。

二次走查实现已通过 Web terminal policy 测试与 ArkTS 单元门禁；ARM64 开发 HAP 也已
完成构建、安装与启动。这些证据不替代本节最终实体机视觉、交互与性能验收。

定向自动化通过 Web 终端策略测试、77 项 ArkTS 单元测试和 repository-only SSH fixture
的 15 项 Rust 测试。ARM64 开发 HAP 在 HAD-W32（USB，`arm64-v8a`）构建、测试签名、安装
和启动成功；最后一次工作树 HAP SHA-256 为
`E456D477E5767C479D5A778FA598F7665FED352BF6BDCF60E93578273B955BB7`，基线提交为
`d36dad54eb2570985cd4ea415ca87e3a10bcb375`。

最终交互与材质实现的 HAD-W32（USB、ARM64）定向证据位于
`build/verification/ui-polish-final-20260808`。工作树调试 HAP SHA-256 为
`4717B74F83088713003D45663279D9BA6D54543990A7D132FF0C0F5BEACF51F8`。layout/截图确认正式
Search、Transparency/Font Size 两个步进器、Medium→Extreme→Medium、16→17→16 px、空查询
`0/0` 与输入焦点，以及 3 Tab 只靠表面差异区分且 `+` 前短分隔保留；固定 Regular 的 Extreme
截图也被保留。结束后恢复 Medium、16 px、单 Tab、菜单关闭及原屏幕超时。该证据不替代
正式候选的双 Pane、TUI、性能、当前产品深色主题和生命周期矩阵。

设备截图与 layout/hilog 位于
`C:\tmp\leantty-ui-polish-20260807`。定向场景确认多 Tab 边界、固定 `+`、双 Pane、紧凑
搜索、无 blur 的轻透明、非活动 Tab 琥珀状态点、非焦点分屏局部来源点、进入来源后清除，
并确认不存在整 Pane 黄框；真实 SSH 链路由临时端口和一次性 credential 驱动，结束后
两个 known_hosts 端点、HDC reverse、fixture 进程/控制目录、额外 Tab 和屏幕常亮租约均
已清理。

这些是实现与定向验收证据。后续正式候选结果见下一节；历史调试 HAP 不因最终候选通过而
改写为发布证据。

## 2026-08-14 1.3 渲染与视觉修订

用户在 HSL 中运行 Codex 和其他 TUI 时观察到大面积黑色背景块。真机失败截图证明默认
Terminal 背景仍然透明，只有应用通过 ANSI 或 TrueColor 明确设置背景色的单元格变成全黑。
锁定的 `@xterm/addon-webgl 0.19.0` 源码进一步把根因定位到 `RectangleRenderer`：默认背景
保留主题 alpha，但显式单元格矩形把 alpha 写死为 `1`。这排除了字体、SSH 字节、ArkTS、
Bridge 和窗口材质作为根因。

LeanTTY 在固定版本的 WebGL 资产生成步骤中只替换这一处 alpha 来源，并要求精确匹配一次；
若升级 xterm 后代码位置变化，构建会失败并要求重新审计。主题桥传入五档派生的
`cellBackgroundOpacity`，Web 侧先限制到 `0..1`，从传给上游 xterm 的主题对象中删除该元数据，
再刷新现有行。前景字形、光标、selection 和默认背景不变。用户在同一物理 PC 的
Codex 页面确认黑块消失；五档同页截图位于
`build/verification/transparency-ladder-20260814/`，普通 shell、Codex 深浅显式表面、文字和
状态行从 Off 到 Extreme 均保持正确。

2026-08-15 的后续日常使用发现 Off 仍会复发。物理机同一 SSH/Codex buffer 的受控对照证明：
Off 出现实黑矩形，切到 Medium 立即消失，恢复 Off 后再次出现；唯一变化是
`cellBackgroundOpacity(OFF)` 从其他档位的有界值跳到 `1.00`。这说明此前把“窗口内容表面完全
不透明”和“显式 ANSI cell 也必须完全不透明”错误绑定。修订后 Off 的内容与 Chrome 表面仍为
`1.00`，只把 renderer 内部显式 cell alpha 设为阶梯最高值 `0.24`。修复版物理 HAD-W32 在明确
读取菜单为 Off 后重新运行 `ssh hsl` 和 `./run-codex`，欢迎卡片、输入区和状态栏不再形成黑块；
同一会话的 ANSI 41/42/44 红绿蓝背景仍清楚可辨。失败、Medium 对照、修复后 Codex 和 ANSI
截图位于 `build/verification/off-black-block-investigation/`。测试 HAP SHA-256 为
`2f341ae228ae78afbe35d4460b1eb5c4509f3f0fd7b9d8cb7a079ced3ed68d02`。

2026-08-22 对 OpenCode 输入区下方横条的跨终端对照推翻了上述 renderer alpha 方案作为长期
规则。OpenCode 用同色显式背景和 `▀` 前景字形组合一行边界；LeanTTY 只降低显式背景矩形
alpha、保持前景字形不透明，破坏了两种图元原本应当融合的颜色关系。更广泛的官方终端对照
也表明，Ghostty、WezTerm 和 Alacritty 默认把“窗口/默认背景透明”与“显式单元格背景透明”
分开，后者是默认关闭的独立策略；Kitty 默认只透明与终端默认背景匹配的颜色。

维护者在明确接受全屏 TUI 主动画出的背景区域可能保持不透明这一代价后，选择标准优先的
方案 A，并将其提升到 `project-principles.md`：透明只作用于 LeanTTY 拥有的 Chrome 与内容
承载 Surface；xterm 默认背景透明透传；显式 ANSI/TrueColor 单元格背景、前景字形、光标和
selection 恢复上游语义。`cellBackgroundOpacity`、主题私有元数据和对固定 WebGL 压缩代码的
alpha 替换随之删除。上述 2026-08-14/15 截图与 HAP 仍是历史调查证据，但不再定义当前产品
契约，也不能授权重新加入按字形或应用内容猜测的兼容补丁。

方案 A 部署后的 Codex 复测暴露了另一层语义错误：xterm 的 OSC 11 查询会读取默认背景的
RGB，而 `rgba(0, 0, 0, 0)` 虽然完全透明，仍会被上报为黑色。Codex 根据该值把白色以 12%
混入默认背景并绘制输入区、消息框等显式表面，于是标准的不透明显式背景把错误的近黑色
完整显示出来。Windows Terminal 与 Ghostty 的共同模型是把逻辑默认背景色和窗口合成透明度
分开，而不是把逻辑颜色改成黑色或降低全部显式单元格 alpha。

维护者确认 A+ 后，LeanTTY 以唯一配色的 `#1E1E2E` 作为逻辑默认背景，并以
`rgba(30, 30, 46, 0)` 交给 xterm：视觉仍由 ArkUI Surface 透出，OSC 11 则报告正确的配色
背景。透明度档位不参与该 RGB，显式 ANSI/TrueColor 背景继续不透明；不为此增加主题、模式、
应用识别或 OSC 拦截。潜伏的亮色代码不构成产品主题契约，也不在本修复中顺带清理。

A+ 的 `web,arkts,policy` 聚焦软件门通过，并直接约束 xterm 对该零 alpha 颜色的 OSC 11 回复为
`rgb:1e1e/1e1e/2e2e`。测试签名 ARM64 HAP SHA-256 为
`5EE1C3964B4A3F74432EE3AD5B63CCA799D36C57B92B0EAB02373EAB82457E44`。在同一 HAD-W32、
同一 WSL 与 Codex 0.149.0 页面中，修复前终端窗口裁剪区含 161143 个纯黑像素和 161338 个
近黑像素；修复后两项均为 0。修复后输入框仍显示 Codex 自己绘制的灰色显式表面，这是方案 A
保留的终端内容语义，不是背景泄漏。修复前后截图与布局分别保存在忽略目录
`build/verification/codex-black-blocks-20260822T144155658Z/` 和
`build/verification/a-plus-codex-device/`；设备屏幕超时覆盖已恢复，Codex 保持打开供维护者复核。

继续对 Codex 欢迎区中的版本、模型和目录黑块做属性级追踪后，确认 A+ 只修正了逻辑默认颜色，
仍有独立的 xterm WebGL 缺陷：render model 的 `bg` 整数同时承载背景颜色和 dim、italic、
`HAS_EXTENDED`、protected、overline 等非颜色位，`RectangleRenderer.updateBackgrounds` 却以完整
整数是否为零判断是否绘制背景矩形。因此默认背景上的 dim、各 underline 样式、OSC 8 hyperlink
等会被误画成不透明 `#1E1E2E`；Windows Terminal、Ghostty 没有把这些文字属性提升为背景身份。

维护者决定不升级 xterm master、不提交本轮上游 PR，也不主动降级到 DOM。采用的局部补丁只在
vendored addon 生成时把该读取归一化为 `CM_MASK | RGB_MASK`，不改显式 ANSI/256/TrueColor、
inverse、selection、decoration 和清屏路径。补丁模块锁定 `@xterm/addon-webgl@0.19.0`、xterm
6.0.0 提交、完整 npm 输入哈希和唯一压缩代码命中，并记录可读 TypeScript 等价改动与删除条件；
未来升级必须先检查上游是否已修复，不能静默迁移压缩替换。普通路径继续请求并验证 WebGL，DOM
仅保留给初始化失败、context loss 或目标真机已证明无法可靠绘制的可观察故障恢复。

实现后的 `web,policy,tooling` 聚焦软件门通过，记录为
`build/verification/software-focused-20260822T155316934Z.json`。自动化覆盖 plain、dim、italic、
单/双/curly/dotted/dashed underline、overline、OSC 8 hyperlink、DECSCA protected、inverse 与
默认/显式背景清屏，并把每种属性分别与 ANSI、256 色、TrueColor 背景组合；输入版本、完整哈希、
唯一命中、生成资产哈希和许可证也在同一生成链失败关闭。

测试签名 ARM64 HAP SHA-256 为
`EBFE7CD9B93DCF20004591A9ED29BD8B5E401CAAECFE942B3012C9B9A07F5D98`。同一物理 PC、同一
WSL 和同一应用进程报告 `requested=webgl, actual=webgl, fallbackReason=none`。真机属性矩阵中，
默认背景的 DIM/ITALIC/UNDERLINE/OVERLINE/HYPERLINK 不再出现背景块，三类显式背景仍完整；
Codex 0.149.0 的版本、模型和目录欢迎框不再带不透明黑底，OpenCode 1.18.21 输入区下方不再有
额外异色横条。Codex 在 Off/Medium/Extreme 的内容 Surface 分别为 `#FF1E1E2E`、`#B81E1E2E`、
`#731E1E2E` 且结果一致，结束后恢复用户原有 Extreme。既有 `window-renderer-lifecycle` 场景也
通过 renderer 销毁、Bridge 重建、焦点恢复和清理，诊断记录分别位于
`build/verification/webgl-background-20260822T155449808Z/` 与
`build/verification/webgl-renderer-lifecycle-20260822T160350154Z/`；这些是当前脏工作树测试 HAP
的开发证据，不是正式候选或发布验收。

同轮按用户决定把透明参数整体前移一档，并新设更激进 Extreme。之后对单 Tab、多 Tab、双
Pane、活动/非活动窗口与 Off/Medium/Extreme 做走查。结论是不增加装饰或新状态：非活动 Tab
直接露出 Chrome rail，活动/hover Tab 使用 80% surface0；`+` 和四点菜单的静止态从 placeholder
提升到 status text 的 72%，全高一像素分屏线从 50% 提到 64%。真机截图位于
`build/verification/visual-hierarchy-20260814/`；活动 Tab、非活动 Tab、Chrome、内容、焦点 Pane、
非焦点 Pane 和分屏边界在四种场景均可辨，测试结束后设备恢复 Medium 和应用焦点。

定向门禁包括 Web terminal policy、104/104 ArkTS 单元测试、干净 ARM64 debug HAP 构建、
测试签名、安装和启动。生成截图是本地忽略证据，不进入发布包；本节不把 1.2 历史候选的
旧 alpha、性能分布或签名哈希改写成 1.3 正式候选证据。

## 2026-08-08 1.2 保留候选验收

正式候选来自已推送提交 `59a8cbfb50f7c67931881169a8695a303f22a718`、tree
`9b3a4437058d27f621bb41c1b0b5c04b90d0be16`；测试签名 ARM64 HAP 为 10,261,825 bytes，
SHA-256 `3f9e20b195d1353fdd2f59eb2134dbafb018d9baeac06b775dc0f68cbbf9119b`。所有下述设备证据
都复用这个 HAP；候选后的提交只修改仓库验收 fixture、脚本和文档，候选兼容检查没有发现
产品输入变化。

### UI、搜索、透明与 BEL

- UI/window 证据位于 `C:\tmp\leantty-1.2-final-ui-window-20260808`。普通、最大化和窄窗
  分别可见 7/8/3 个裁剪 Tab，固定 `+`、四点菜单、系统按钮、表面区分、空搜索 `0/0`、
  双 Pane 全高分隔及窗口恢复均可见。原 `device-ui-window.json` 的总结果作废，因为它把
  “可见 Tab”当总 Tab、把空查询的可访问说明 `Type to search` 当作可视计数、把隐藏 warm
  WebView 当活动 Pane，并漏掉关闭确认；没有覆盖该文件。校正后的 layout/截图复核和截图
  SHA-256 写入 `device-ui-window-reviewed.json`，结果为 `passed`。
- 保留候选搜索全矩阵位于
  `C:\tmp\leantty-1.2-final-search-retained-20260808-rerun2\device-terminal-search.json`，
  `device-behavior / acceptance / passed`；五个命名阶段、单 Tab/Pane恢复和常亮租约清理均通过。
- 五档透明证据位于
  `C:\tmp\leantty-1.2-final-transparency-20260808-rerun1\device-transparency.json`，结果
  `passed`。设备实测 Content/Chrome alpha 为 Off `FF/FF`、Low `E6/F0`、Medium `D1/E0`、
  High `B8/CC`、Extreme `99/B3`；Extreme 加号禁用、重启保持 Extreme、边界不循环，最后
  恢复 Medium 并关闭菜单。
- BEL 证据位于
  `C:\tmp\leantty-1.2-final-bell-20260808-rerun4\device-ssh-auth.json`，结果 `passed`。
  活动 Pane 瞬时提示、后台 Tab 持久标记与进入清除、分屏局部来源与聚焦清除、重复 BEL
  合并全部由真实 `SSH → Rust/N-API → ArkTS → Tab/Pane` 链路确认；截图保留活动、后台 Tab
  和分屏三种状态，cleanup 与 Preferences 不变检查通过。

### 五档持续输出分布

HAD-W32 使用 HUAWEI Maleoon 916、OpenGL ES 3.2 B289。证据位于
`C:\tmp\leantty-1.2-final-performance-20260808-rerun12\device-ssh-auth.json`；每档连续三次
12,000 × 80 流均为 100% 完整，三个 hitch 计数档位的增量全部为 0：

| 档位 | rendered min / P50 / max | 完整度 | 主进程 RSS 采样范围 |
| --- | ---: | ---: | ---: |
| Off | 2647.5 / 2682.4 / 2752.6 ms | 3 × 100% | 268,636–277,544 KiB |
| Low | 2602.5 / 2687.3 / 2738.8 ms | 3 × 100% | 283,684–292,372 KiB |
| Medium | 2793.5 / 2824.5 / 2826.5 ms | 3 × 100% | 298,688–305,320 KiB |
| High | 2589.8 / 2610.8 / 2764.3 ms | 3 × 100% | 310,396–314,512 KiB |
| Extreme | 2749.4 / 2762.8 / 2875.3 ms | 3 × 100% | 317,708–321,188 KiB |

RSS 是同一进程按 Off→Extreme 顺序累计输出后的采样，不能解释成透明度本身的档位成本；
renderer RSS 约 239,928–250,676 KiB，RenderService GPU 样本通常为 2 MiB。时延没有随
透明强度单调恶化，Extreme 仍在同轮总体分布内，未出现输出缺失、renderer 中断或 hitch
累计，因此没有触发撤 Regular 或降低透明度的停止条件。

性能阶段本身和资源清理均为 `passed`，但该 JSON 的顶层结果保留为 `failed`：完成采样后
HDC 吞掉最终 `ssh-keygen -R` 的 Enter 提交遥测。该假阴性促使断开态命令也采用三次有界
重试；随后短场景
`C:\tmp\leantty-1.2-final-cleanup-20260808-rerun1\device-ssh-auth.json` 完整通过候选预检、
密码连接、Preferences 不变、known_hosts 删除及 key/reverse/fixture 独立清理。失败记录仍
保留，不把顶层字段改写成通过。

### 人工验收结果

客观设备矩阵已经覆盖当前深色主题的窗口尺寸、Tab/Pane、搜索、五档 alpha/Regular、BEL
状态、持续输出、最小化/恢复和 renderer 生命周期。2026-08-08，用户进一步用真实物理键盘、
中英文 IME 和实际 SSH 服务器完成人工验收，覆盖 Tab/Shift+Tab focus ring、
tmux/vim/less/Agent TUI、Extreme 可读性及 BEL 节奏，均未发现问题。当前 HAD-W32 设置搜索
对“减少动态效果”无结果，
“动画”只找到“开发者选项 → 过渡动画缩放”；SDK 只提供状态读取、没有设置接口，因此用户级
reduced-motion 在当前目标系统记为不适用。没有改动开发者动画倍率，也不拿它冒充该场景。

### 2026-08-08 Low 档 Tab 层级修复

用户在最终人工走查中确认 Low 档 Chrome 轨道与 Tab 表面色差不足。根因是所有 Tab 都使用
`#1E1E2E`，非活动/hover 仅叠加 `0.42/0.72` opacity，而 Low Chrome 又是几乎不透明的
`#F0181825`；局部 alpha 合成后，非活动 Tab 与底色的差异接近消失。其他透明档位只是因
桌面透入更多而偶然放大色差，不能作为稳定的状态表达。

修复删除两个局部 opacity token，把 Chrome 轨道 RGB 改为 crust，非活动 Tab 固定 mantle，
活动与 hover 固定 base；不增加分隔线、描边、设置或状态源。测试签名诊断 HAP SHA-256 为
`17c327dfb670ca6a3991d05a48e7f0915a539804b7c835fe60f588c23a44c253`。HAD-W32 五档证据位于
`C:\tmp\leantty-tab-contrast-20260808`：Off/Low/Medium/High/Extreme 的 Chrome 分别实际报告
`#FF11111B/#F011111B/#E011111B/#CC11111B/#B311111B`，每档布局均为三个
`#FF181825` 非活动 Tab 和一个 `#FF1E1E2E` 活动 Tab；截图确认 4vp 间距、活动 Tab 连续层次、
`+` 前短分隔与四点菜单保持不变。设备结束时恢复 Low。该 HAP 只证明本次定向修复，不替代
从新精确提交重建的正式发布候选。

### 2026-08-08 步进按钮快捷键与 hover 提示

字号保留既有 `Ctrl+-` / `Ctrl+=`，透明度采用相同的减/加键并增加 Alt 层：
`Ctrl+Alt+-` / `Ctrl+Alt+=`。纯策略分别返回两个目标的调整方向，字号策略明确拒绝 Alt，
避免透明度键位同时修改字号；路由位于菜单捕获之前，因此菜单开关不改变快捷键语义。
四个按钮的无障碍说明包含键位，视觉提示采用 HarmonyOS 原生 `bindTips`，300ms 后出现、
离开后 100ms 消失。早期 `bindPopup` 诊断节点会被菜单层遮挡，已由真机截图否决并删除，
没有保留第二套提示实现。

Web terminal policy、静态 UI 契约和 78 项 ArkTS 单元测试通过；HAD-W32（USB、ARM64）debug
HAP 构建、测试签名、安装和启动成功，SHA-256 为
`A988DFA2089A5A549FB321A506650F8F86395DF5EC23F4A0ED0EC94624C7FB26`，源码基线提交为
`cd60a83342c08e21111e57c850c9b0eaf9e34e3e` 加当前工作树改动。菜单打开和关闭两种状态都
实测得到 `Medium/16 → Low/16 → Medium/16 → Medium/15 → Medium/16`，证明四个键位生效
且互不串线；真实鼠标逐个悬停后，layout 中四个 Popup 均为 visible、opacity 1，并分别显示
`Ctrl+Alt+-`、`Ctrl+Alt+=`、`Ctrl+-`、`Ctrl+=`。最终字号加提示的屏幕可见截图及逐按钮
layout 位于 `C:\tmp\leantty-shortcut-buttons-20260808-r1`。该 debug HAP 只证明本次定向
改动，不替代从新精确提交重建的正式发布候选。

### 2026-08-14 ArkWeb 终端按键分发回归

真实 OpenCode TUI smoke 发现左右方向键、`Ctrl+P` 和 `Ctrl+V` 未到达远端，而显式产品
路径中的 `Ctrl+C` 和 Tab 仍可用。服务器边界 fixture 逐次记录输入字节，确认旧候选
`0d38130f...19edc` 只收到 `0x03` 和 `0x09`；问题不是 WSL、OpenCode 或 SSH 编码差异。
根因是文件传输改动同时在 TerminalPane 注册 `onKeyPreIme`、Web 专用
`onInterceptKeyEvent` 和通用 `onKeyEventDispatch`，最后一层抢先结束了原本应继续交给
ArkWeb/xterm 的未处理按键分发。

修复仅移除重复的 `onKeyEventDispatch`，保留 `onKeyPreIme` 与
`onInterceptKeyEvent`：前者继续承载 Tab、`Ctrl+C` 和产品快捷键，后者继续让 Web 在产品
未消费时按原生路径处理终端输入和可信剪贴板事件。不增加逐键映射、模拟粘贴或第二套输入
通道。修复后的诊断 HAP SHA-256 为
`b95a2ad0aa5b1c3a12b3b2314e4e359c29f8a5de2fc3593cbc8c6f044297da66`，同一 fixture 精确收到
Left `ESC [ D`、Right `ESC [ C`、`Ctrl+P` `0x10`、`Ctrl+C` `0x03`、Tab `0x09`，以及
`Ctrl+V` 触发的 17 字节 OSC 52 剪贴板内容；搜索开关、Pane/Tab 所有权和清理审计同时通过。
该诊断包用于证明因果关系。正式候选随后从干净提交
`35aa36e442286219ee4dbd184107566465eaa8a6` 重建，保留 HAP SHA-256 为
`0116b6ecf02f7501541acf7ef654beb4c57246833a28d0de7a8f7240e7826c99`；同包重新通过六种按键
精确字节、搜索打开/关闭/焦点、Pane/Tab 所有权和 production PUT/GET 往返门禁。PUT/GET
harness 的 reverse 映射清理命令同时在 `6556839` 中纠正，并以新端口复跑和独立映射审计闭合。

### 2026-08-15 SSH 连接标题回归

主流终端通常不把“SSH 后必须显示某个固定标题”写死在终端本身，而是让活动 Shell/应用通过
OSC 0/2 或 Shell integration 提供标题：[Windows Terminal](https://learn.microsoft.com/en-us/windows/terminal/tutorials/tab-title)
以活动 Pane 的应用标题为 Tab 标题，[kitty](https://sw.kovidgoyal.net/kitty/shell-integration/)
以活动 window 标题为 Tab 标题并可通过远端 shell integration 更新，
[Ghostty](https://ghostty.org/docs/vt/osc/2) 支持 OSC 0/2 与显式 Tab 标题覆盖，
[iTerm2](https://iterm2.com/documentation-session-title.html) 的 Session Title 则能通过 Shell
integration 组合 User、Host、PWD。共同点是标题表达当前会话，但动态程度和信任边界由产品决定。

LeanTTY 是拥有 SSH 连接模型的键盘优先客户端，不需要依赖远端 Shell 配置才能识别会话。因此
1.3 固定采用连接成功后的稳定身份 `user@displayHost`：通过 OpenSSH `Host` alias 连接时保留用户
实际输入并认识的 alias，例如 `ssh hsl` 显示 `user@hsl`；直接连接域名或 IP 时显示直接目标。
当远端正常 `exit`、连接失败或取消连接后重新出现本地 `ltty>` 时，Tab 同步恢复为 `ltty`；
重连过程尚未回到本地提示符，因此继续保留原连接身份。标题由当前可交互环境决定，不把已经
结束的服务器名称当作历史标签长期保留。
当前不接入远端 OSC 动态改写 Tab，避免未建立清洗、长度、控制字符和生命周期边界前让远端内容
控制 Chrome，也避免 PWD/前台程序频繁变化造成 Tab 抖动。未来若需要动态标题，必须单独定义可信
输入、清洗、截断、用户覆盖和分屏所有权合同。

回归根因不是 SSH 标题生成丢失。真机日志已证明 Session 在 CONNECTED 时生成标题并调用
Index/AppViewModel；问题来自 `e4dac57` 将 `ForEach` key 收敛为稳定 `tab.id` 后，ChromeBar 又以
`@Prop` 接收 Tab 数组，ArkUI V1 的嵌套对象观察链在中间层断开。模型继续更新，但稳定 key 复用的
ChromeTab 没有收到重绘。最终保持稳定 `tab.id`，将数据链改为
`Index @State tabs → ChromeBar @Link tabs → ChromeTab @ObjectLink tab`，TabInfo 使用
`@Observed`，Pane 的 state/title/attention 变化由所属 Tab 的一层 `panes` 赋值发布。这样无需把
title 放回 key、无需重建 Tab，也不会在连接完成时打断 Tab 或关闭按钮的焦点/动画状态。

连接标题定向自动化通过 114/114 ArkTS 单元测试与 Web terminal policy。当前源码构建的 ARM64 测试签名
HAP SHA-256 为 `F96EC145ADEE6FEBD0BBBBE5ECE5FB22B2E9AE9A671FFCE0C2E0CD8AC94BE765`；
在 HAD-W32（USB、ARM64）输入 `ssh hsl` 后，hilog 记录
`Connected tab title=user@hsl`，layout 与截图均实际显示 `user@hsl`。证据保存在忽略目录
`build/verification/tab-title-regression/after-linked-object-fix.{log,png}` 及对应 layout JSON；验证后
已退出测试 SSH 会话。2026-08-16 又补齐“任何非 IDLE 状态回到本地 IDLE 时发布 `ltty` 标题”的
状态机约束和自动化；因测试机充电，`ssh hsl → exit → ltty` 的真机标题变化按用户决定暂缓到
最终精确候选 smoke。上述旧包只证明连接后标题，不证明本次退出修复，也不替代正式发布候选。

## 验证边界

### 自动化证明

- Tab 固定宽度、滚动区与 `+`/拖拽区结构，溢出淡出的显示条件和键盘焦点状态。
- BEL 的 Pane 归属、活动/非活动/分屏清除语义、重复合并、有限次数和销毁清理。
- 搜索条尺寸、`0/0` 与可访问说明、窄 Pane 收缩、按钮顺序，以及查询不会进入
  Terminal/SSH 输入路径。
- 深浅主题都只使用约定 token；release 代码不包含验收标记、无限动画或在线资源。
- 五档透明度的数值/非循环边界/默认与深浅主题派生、Chrome/Content 分区所有权、Preferences
  恢复、已挂载 Pane 同步、xterm 初始化时机、renderer 重建策略，以及生产只含一次固定
  Regular 根材质且不含其他材质选择或自定义 blur 路径。
- 四个步进快捷键的目标隔离、菜单开关一致性、按钮与 hover Tips 文本一一对应。

自动化不能证明视觉观感、系统合成成本、物理键盘焦点或 ArkWeb/WebGL 真机行为。

### ARM64 构建证明

干净 ARM64 HAP 构建只证明 ArkTS、资源、Web 资产和目标 ABI 能集成；不证明透明、模糊、
动画节奏、输入延迟或 TUI 背景在物理 PC 上成立。

### 物理 HarmonyOS PC 证明

保留候选已完成的客观物理门禁包括：

- 当前产品深色主题下的普通/最大化/窄窗口、多 Tab 溢出、`+`、拖拽区、双 Pane 和搜索条
  可见边界；浅色 token 由自动化约束，不为验收增加产品入口。
- 活动 Pane、非活动 Tab、非焦点分屏和连续 BEL 的状态、重复合并、清除与销毁。
- 轻透明下普通 Shell、搜索高亮、大持续输出、resize、最小化/恢复和 renderer 重建。
- 菜单打开/关闭时四个步进快捷键的真实状态变化，以及四个按钮的鼠标 hover Tips 可见性。
- 记录目标设备、精确 HAP/commit、截图或录屏、layout/hilog、重试和清理结果；先比较
  不透明与候选透明的分布和失败域，不用单次主观感受代替证据。

真实物理键盘 focus ring、中英文输入法、用户服务器 TUI 和主观可读性/BEL 节奏已由用户
完成；当前系统未暴露的用户级 reduced-motion 记为不适用，不阻塞发布。

## 裁剪与停止条件

出现以下任一情况时停止扩大方案：

- 轻透明需要大面积 CSS blur、新 renderer、额外依赖、连续参数设置或跨层兼容框架。
- 透明导致终端/TUI 错误、可读性下降、明显输入/渲染负担或生命周期不稳定。
- BEL 需要新的业务状态、系统通知服务、无限队列或改变 Pane 所有权才能工作。
- 多 Tab 改进需要自适应宽度模型、第二套工作区布局或压缩系统拖拽区。
- 搜索紧凑化需要改变已确认的搜索语义、输入法路径或 Terminal Surface 所有权。

按最小裁剪顺序处理：先撤掉 blur，再撤掉 Terminal 透明，再裁掉溢出淡出等装饰；保留
清楚边界、静态注意力标记、紧凑搜索、可见焦点和主题一致性这些低风险核心收益。

## 决策记录

- 2026-08-15–16：SSH 连接成功后的 Tab 标题固定为 `user@displayHost`；OpenSSH alias 优先于解析后的
  hostname/IP；回到本地 `ltty>` 时标题恢复 `ltty`，重连未返回本地提示符时保留连接身份。保留
  稳定 Tab ID，通过 ArkUI V1 的 `@State → @Link → @ObjectLink` 状态链刷新，当前不允许远端
  OSC 动态改写 Chrome 标题。
- 2026-08-08：字号沿用 `Ctrl+-` / `Ctrl+=`，透明度采用 `Ctrl+Alt+-` / `Ctrl+Alt+=`；四个
  按钮用平台原生 hover Tips 展示键位。真机否决会被菜单遮挡的普通 Popup 实现，不建立
  自定义 Tooltip 或覆盖层。
- 2026-08-08：Low 档不再用局部 opacity 区分 Tab；采用 Catppuccin
  `crust → mantle → base` 的显式表面层级，并在 HAD-W32 上逐档确认。保持无 Tab 间竖线、
  固定 4vp 间距、活动 Tab 连接内容区和单一透明度设置。
- 2026-08-08：精确保留候选完成 UI/window 证据复核、搜索、SSH 主路径、BEL、五档透明与
  五档持续输出分布；候选客观停止条件均未触发。用户随后完成真实键盘/IME、用户服务器
  TUI 和主观观感验收，未发现问题；当前目标系统未暴露用户级 reduced-motion，该场景记为
  不适用并保留静态自动化约束。
- 2026-08-08：提交前审查保持 `tab.id` 为稳定渲染身份，BEL 呼吸由瞬时 token/Prop 触发，
  不再通过改变 ForEach key 重建整个 Tab，避免提示动画干扰 Tab/关闭按钮焦点与组件状态。
- 2026-08-08：用户通过调试比较器选择 Regular；正式实现固定一次根级
  `BACKGROUND_REGULAR`，删除材质调试入口，并重新标定 Content/Chrome 五档。四点菜单新增
  Search 并把字号收敛为复合步进器；移除 Tab 间竖线，空搜索统一显示 `0/0`。
- 2026-08-08：确认五档全窗口材质扩展；菜单改为左减右加的非循环步进器，内容/Chrome
  使用同一语义档位的两组派生 alpha，并仅把 HarmonyOS 系统中等背景材质作为可裁剪候选；
  实现与完成条件已同步到 `next-work.md`。
- 2026-08-07：确认内容区域采用克制的轻透明方向，但正常使用、可靠性与低性能负担是
  前提；候选不成立时降低透明度或回退不透明，不建立通用外观设置。
- 2026-08-07：确认 BEL 采用有限 Tab 呼吸加静态标记；活动 Pane 只短促提示，非活动
  Tab 两次呼吸后保留标记，非焦点分屏增加局部来源标记，禁止无限动画。
- 2026-08-07：确认 Tab 继续固定 172vp 并横向滚动；`+` 固定在滚动区外，保留至少
  96vp 拖拽区，通过分隔和条件淡出表达边界。
- 2026-08-07：确认搜索条紧凑化、分屏/图标/焦点/主题一致性进入同一 1.2 收敛切片。
- 2026-08-07：首轮采用 0.97、无 blur 的轻透明候选；采用有限 Tab 强调、前导状态点和
  分屏来源点；当时定向自动化、ARM64 构建与物理 PC 场景通过，正式候选矩阵尚未执行。
- 2026-08-07：二次走查确认终端现有留白与右侧 scrollbar 的视觉平衡成立，不作修改；
  修正 Tab 间分隔与内容基线、`0/0` 搜索反馈、搜索/Pane 关闭间距、四点菜单和分屏线权重，
  并采用高 `0.78`、中 `0.88`、低 `0.96` 三档内容透明度及本地重启持久化。
- 2026-08-08：用活动态透明、非活动态不透明的 PC 容器配置闭合系统合成层；ArkUI 根
  Surface 成为唯一 alpha 所有者，ArkWeb/xterm WebGL 全透明透传，能力失败回退为不透明。
  HAD-W32 当时已确认三档标签/alpha 一致、菜单连续循环和 Low 重启恢复；该历史矩阵后来
  被五档保留候选验收取代。

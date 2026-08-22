# 工作区键盘导航技术方案

> 状态：Verified；`v1.1.1` 已通过 GitHub、AppGallery 发布
>
> 目标 milestone：1.1.0
>
> 更新日期：2026-08-05
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 完成记录：实现与验证已闭合；后续变更须重新进入 [`next-work.md`](../next-work.md)

## 用户问题与目标

LeanTTY 已支持少量 Tab 和最多双 Pane，但高频切换仍需要鼠标。目标是在不引入工作区
模式、MRU 列表、自定义快捷键或第二份活动状态的前提下，给现有视觉结构增加固定、
可预测的键盘路径。

## 范围

| 操作 | 快捷键 | 范围 |
| --- | --- | --- |
| 下一个 Tab | `Ctrl+Tab` | 1.1 已授权，按视觉顺序循环 |
| 上一个 Tab | `Ctrl+Shift+Tab` | 1.1 已授权，按视觉顺序循环 |
| 左 Pane | `Ctrl+Alt+Left` | 条件范围，先过真机冲突门禁 |
| 右 Pane | `Ctrl+Alt+Right` | 条件范围，先过真机冲突门禁 |

快捷键固定，不提供自定义、别名、命令面板或新的工作区 UI。

## 交互规则

### Tab

- 按屏幕排列顺序循环，不引入 MRU 状态或临时切换界面。
- 最后一个 Tab 的下一项是第一个；第一个的上一项是最后一个。
- 单 Tab 时不改变状态但消费按键，避免组合键进入远端。
- 切换后恢复目标 Tab 自己的 `activePaneId`，不默认回左 Pane。
- 普通 `Tab`、`Shift+Tab` 和其他未命中组合继续交给终端。

### Pane

- 当前产品只有横向双 Pane，因此动作是明确聚焦左/右，不是“循环下一个 Pane”。
- 单 Pane 时不改变状态且不消费，完整组合交给当前终端和远端程序。
- 双 Pane 时始终消费精确的 `Ctrl+Alt+Left/Right`；目标已经活动时只做幂等焦点恢复。
- 缺少必要修饰键或额外带 `Shift` 时不拦截；普通方向键继续透传。
- 若 HarmonyOS、输入法、内置/外接键盘或关键 TUI 不能稳定交付组合键，从 1.1 裁剪
  Pane 快捷键，不增加替代组合、设置或特殊兼容分支。

## 原则评估

- 直接服务已有少量 Tab/双 Pane 的高频切换，不增加新的会话组织模型。
- 复用 `Tab → Pane → Session` 所有权和已有焦点恢复链，不新建活动 Pane 状态。
- Tab 组合沿用主流 Tab 控件心智；Pane 组合避开普通方向、`Alt+方向` 的按词移动和
  `Ctrl+Shift+方向` 的选择/输入法冲突，但“看起来未占用”不能替代真机证据。
- 失败时裁剪增强，不牺牲终端输入兼容性补救。

## 所有权与事件链

```text
TerminalPane.onInterceptKeyEvent
  → Index.handleKeyEvent
  → InteractionPolicy: fixed WorkspaceNavigationAction
  → Index.selectTab / AppViewModel.setActivePane
  → syncWorkspace
  → restoreActivePaneFocus
```

`Index.ets` 继续拥有 Tab、Pane 和焦点编排。`InteractionPolicy.ets` 只增加纯动作解析与
Tab 循环索引，不建立命令框架：

```text
WorkspaceNavigationAction
  NONE
  NEXT_TAB
  PREVIOUS_TAB
  FOCUS_LEFT_PANE
  FOCUS_RIGHT_PANE
```

事件处理顺序：

1. 忽略非 `KeyType.Down`。
2. 读取完整 Ctrl、Shift、Alt 状态。
3. 解析精确工作区组合；命中后按上述规则决定是否消费。
4. 再处理现有新建 Tab、关闭 Pane、分屏、菜单和字号快捷键。
5. 未命中返回 `false`，交给 WebView/xterm。

Tab 切换复用 `selectTab(index)`；Pane 切换复用
`AppViewModel.setActivePane(tabId, paneId)`、`syncWorkspace()` 与
`restoreActivePaneFocus()`。不得通过数组相邻关系跨 Tab 查找 Session。

## 已确认决策

- Tab 使用视觉顺序并循环。
- 切换 Tab 后恢复其 `activePaneId`。
- 单 Tab 消费 Tab 组合；单 Pane 透传 Pane 组合。
- 不采用 `Alt+Left/Right` 或 `Ctrl+Shift+Left/Right`。
- 不增加自定义快捷键、MRU 模式或通用动作框架。

## 已完成验证与证据边界

- 纯策略测试覆盖精确组合、额外/缺少修饰键、零/单/多 Tab、首尾回绕、单双 Pane
  消费规则和活动 Pane 索引，共同随当前 ArkTS 测试运行。
- 物理 ARM64 HarmonyOS PC 前置门禁确认 `Ctrl+Alt+Left/Right` 到达 SSH 终端时分别为
  `1b 5b 31 3b 37 44` / `1b 5b 31 3b 37 43`，未触发系统动作，因此保留 Pane 导航。
- 物理机三连接 Tab、双 Pane 场景已验证正反向首尾循环、目标 Tab 活动 Pane 恢复、
  单 Pane 组合透传以及普通 Tab 的 `09` 字节透传。诊断证据位于
  `build/verification/workspace-navigation-20260804T202847035Z/`。
- 中英文输入法、不同外接键盘、vim/tmux/less、选择与剪贴板、断线与重连的组合矩阵
  留到正式 1.1 候选的唯一全量发布门禁，不在日常功能迭代中重复执行。

## 验证门禁

### 自动化

- 精确组合、额外/缺少修饰键和非 Down 事件。
- 零/单/多 Tab、首尾回绕和每个 Tab 的 `activePaneId`。
- Pane 动作只改变当前 Tab，不改变其他 Tab 的 Pane/Session 所有权。
- Tab 组合消费；Pane 组合只在双 Pane 消费；普通 Tab/方向键不消费。

### 物理 HarmonyOS PC

1. 至少三个已连接 Tab 正反向循环，标题、输出、状态和输入目标不串联。
2. 双 Pane Tab 切出再切回，仍恢复原活动 Pane。
3. 远端可观察按键程序中确认 Tab 组合不进入 SSH，普通 Tab 正常进入。
4. Pane 前置门禁先独立确认系统、输入法和键盘交付；只有通过才实现/保留。
5. 双 Pane 反复切换与单 Pane 透传覆盖焦点、选择、TUI、复制粘贴、断线和重连。

## 裁剪条件

- Tab 导航若破坏输入、选择、焦点或 Session 所有权，从 1.1 裁剪，不延伸状态或设置。
- Pane 前置门禁或实施后矩阵任一关键场景失败，删除 Pane 动作及未使用代码，不用别名
  或自定义快捷键掩盖平台冲突。

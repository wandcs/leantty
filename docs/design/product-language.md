# 产品语言边界与中英文界面

> 状态：Verified；1.5 实现与中英文实体 PC 门禁已闭合
>
> milestone：1.5
>
> 更新日期：2026-08-25
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 实现授权：1.5 已完成并从 [`next-work.md`](../next-work.md) 活动项移除

## 结论

LeanTTY 只维护英文默认资源和简体中文资源。HarmonyOS 原生界面与 LeanTTY 自有图形控件
仅在系统语言明确属于 `zh` 时显示中文；英文及其他或未知语言均使用英文默认资源。应用不在
菜单或设置中提供语言切换，也不保存第二套应用语言偏好。

终端字符表面保持英文技术语言：本地命令、参数、路径、提示符、Help、错误、风险、警告、
建议和状态不翻译，不提供中文命令别名或双语重复输出。远端 TTY 字节、OSC title 与 SSH
服务器返回内容原样透传。应用日志、自动化标识和诊断证据继续使用稳定英文。

中文用户可见术语使用“标签页”“分屏”“SSH 连接”；不引入“窗格”。英文继续使用
Tab、Pane 和 SSH connection。内部代码与协议仍使用 `Tab`、`Pane`、`Session`，不得用显示
字符串判断行为或持久化状态。

## 实现边界

事件链固定为：

```text
系统语言
→ HarmonyOS base / zh_CN 字符串资源
→ 原生 ArkUI、通知与确认框
→ Bridge localization 控制消息
→ 当前 Terminal Surface 的查找控件
→ 用户可见文本和无障碍语义
```

- 原生菜单、透明度与字号、通知、短反馈、确认框、权限说明和无障碍说明从资源取值。
- Web 终端只接收查找浮层所需的固定结构化文案，不把业务状态或远端内容送入本地化消息。
- 离线指南本身保留中文和 English 链接；打开时只追加 `#guide-zh` 或 `#guide-en`，不改写
  指南文件，也不保存选择。
- 运行中系统语言变化由 HarmonyOS 应用生命周期和资源重建决定；本期不建立常驻语言观察器
  或自行重启应用。
- 系统语言不可识别时由 `base` 使用英文默认值；中英文资源键不完整必须在构建前失败。
  Bridge 消息非法或缺项时保留已加载的英文默认查找文案，不阻断终端初始化。

## 中文用词

| English | 中文 |
| --- | --- |
| New Tab | 新建标签页 |
| Split Pane | 新建分屏 |
| Close Pane | 关闭分屏 |
| Find | 查找 |
| Transparency | 透明度 |
| Font Size | 字号 |
| Maximum | 最高 |
| SSH connection | SSH 连接 |

## 平台依据与证据边界

2026-08-23 针对 HarmonyOS SDK `6.1.1(24)` 核对：

- HarmonyOS 的[多语言资源](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V13/l10n-multilingual-resources-V13)
  由默认资源和限定目录共同承担匹配与回退，因此英文放在 `base`，中文放在 `zh_CN`，无需自建
  语言持久化或回退框架。
- HarmonyOS 的[应用国际化概述](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/l10n)
  将资源分离作为应用多语言的标准路径。
- 资源字符串支持[格式化占位符](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V2/resource-categories-and-access-0000001544463977-V2)，
  动态标签页名、密钥名与数值继续作为参数，不拼接成可翻译句子片段。

这些文档证明资源模型和 API 用法，不证明目标 PC 上实际选择了正确语言，也不证明 ArkWeb
可访问树、系统通知卡片或离线指南锚点正确；后者必须由签名 ARM64 debug HAP 的中英文命名
场景验证。

同日首次中文查找诊断暴露验收脚本把终端内容顶部写死为 `100`，而当前原生窗口布局为 `98`。
OpenHarmony 的 [ArkXTest 指南](https://gitee.com/openharmony/docs/blob/ca4467409329c262b239693b7ba5e96185122ff6/en/application-dev/application-test/arkxtest-guidelines.md)
将 UiTest 布局作为当前控件树观察结果，并未给 LeanTTY 的内容区承诺固定屏幕坐标。因此验收脚本
改为复用同一布局中已经解析出的 Terminal Surface 顶部边界，不为 `98` 增加设备特例。原运行的
主体 `open-close-focus` 已通过，但清理记录失败，整次证据仍按无效处理，修正后必须从干净状态
完整重跑。

英文系统首轮诊断又证明显示字符串不能充当单语测试状态：新版英文资源把查找输入的无障碍名
从历史候选的 `Search text` 收敛为 `Find text`，旧选择器因此漏识别已经正常打开并获得焦点的
浮层。验收脚本改为同时接受当前中英文资源和历史英文候选值；业务状态仍由控件类型、可见性、
焦点与工作区结果共同判断。该轮主体和清理均作为无效证据，修正后从已确认状态完整重跑。

## 验证与停止条件

- L1：英文/中文资源键完全一致；中文资源不包含“窗格”；语言标签仅明确 `zh` 命中中文。
- L2：Web 查找本地化走结构化 Bridge；非法或缺项 payload 不改变终端；英文默认仍可用。
- L3：中文系统和英文系统分别核对菜单、分屏、透明度/字号、确认框、通知、查找与离线指南；
  同时确认终端 Help、错误、命令和远端输出仍是英文或原始内容。
- 如果中文资源选择、Bridge 初始化或 ArkWeb 锚点在目标 PC 上不可靠，优先回退到英文默认或
  仅保留原生资源，不增加轮询、语言设置页、Web 存储或第三套本地化框架。

## 2026-08-23 完成证据

聚焦软件门运行：

```powershell
.\tools\test-regression.ps1 -Group policy,web,arkts,tooling
.\tools\dev-pc.ps1
```

资源键一致性、“分屏”术语、非法 Bridge payload、英文默认查找文案、中文查找文案、离线指南
双语结构、ArkTS 单元测试、资源编译和 ARM64 debug HAP 构建均通过。最终测试签名 HAP 的
SHA-256 为：

```text
06fc2184e3afae3de47c77704415b32850942eb0b1f43f11c1e4f0137db3dd97
```

同一个 HAP 在物理 HAD-W32 ARM64 HarmonyOS PC 上完成以下命名场景：

- `zh-Hans`：`terminal-search/open-close-focus`、后台 BEL 通知发布/点击返回/清理通过；菜单语义
  布局显示“新建标签页 / 新建分屏 / 关闭分屏 / 查找 / 透明度 / 字号”。
- `en-Latn-US`：同样的 `terminal-search/open-close-focus` 与后台 BEL 通知场景通过；菜单语义
  布局显示 `New Tab / Split Pane / Close Pane / Find / Transparency / Font Size`。
- 恢复 `zh-Hans` 后，`terminal-search/pane-tab-ownership` 通过：本地 `help` 的英文 `Syntax`
  能在中文系统下被实际搜索命中，分屏/标签页切换与关闭不依赖显示字符串，场景清理恢复单
  标签页、单分屏。

英文系统首轮因测试选择器仍只识别历史 `Search text` 而无效；布局证明当前 `Find text` 已经
正常打开并获得焦点。修正选择器、通过 tooling 回归并从已知状态重跑后才记录通过。测试 PC
最终恢复 `persist.global.language=zh-Hans`，并通过系统“语言和地区”界面删除临时加入的
English，只保留原有“简体中文”。这些是开发期 diagnostic HAP 的 L3 证据，不是正式候选或
AppGallery 交付证据；L4 仍服从单独的 release preparation。

## 2026-08-25 离线指南页内语言复验

Agent 指南真机走查发现，文档切到 English 后点击 `Agent workflow` 会把 URL 改为
`#en-agent`，但旧 CSS 只把 `#guide-en` 根节点识别为英文状态，因而回落中文。修复后的规则
同时识别语言页自身和其任一后代 target；相同修复也明确覆盖中文页内锚点。`web` 聚焦门和
测试签名 ARM64 HAP `2DB93C2D...B5A167` 的红绿真机复验均通过：中文系统仍默认中文，文档内
切到英文后，英文目录点击准确保持英文并滚到 `Agent workflow`。终端 `help` 继续使用英文技术
语言，应用没有新增语言设置、脚本、存储或第三套本地化状态。

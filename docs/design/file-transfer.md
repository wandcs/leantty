# LeanTTY 最小文件传输技术方案

> 状态：活动实现；产品边界与实现前可靠性决策已冻结，当前执行实现和验证
>
> 当前 milestone：1.3；版本号在保留候选准备阶段再按版本规则推进
>
> 初稿日期：2026-07-26；最近更新：2026-08-09
>
> 上位规则：[`project-principles.md`](../project-principles.md)
>
> 版本顺序：[`roadmap.md`](../roadmap.md)
>
> 工作排期仍以 [`next-work.md`](../next-work.md) 为唯一有效 TODO。本文记录为什么值得
> 做、如何限制复杂度、已经取得的证据和后续验收门槛，不维护第二份活动清单。
>
> 命令面治理：[`command-system.md`](command-system.md)

## 一、当前结论

LeanTTY 值得在拟议 1.3 中继续推进一个**最小、命令行式、单文件传输能力**，但不做
SFTP 文件管理器。用户命令确定为 `put` 和 `get`，分别表示上传和下载；内部使用
SSH 的 SFTP 子系统传输。

文件传输只能从当前 Pane 尚未连接服务器时的本地 `ltty>` 提示符发起，一次只传一个
文件，完成或失败后立即释放独立传输 Session。`put/get` 复用 OpenSSH SFTP 已有的
方向认知，但不是完整 SFTP 交互式命令集。

本地文件根目录固定为 HarmonyOS 向应用授权的公共 **Downloads（下载）目录本身**：

```text
用户看到：Downloads
真机路径：/storage/Users/currentUser/Download
```

不再创建或要求用户理解 `Downloads/LeanTTY` 子目录。Downloads 是固定安全根，但 1.3
允许用户在其中引用任意层级的**既有相对子目录**；命令不创建目录，也不引入本地当前目录。
目录目标必须用尾部 `/` 明确表达，文件路径没有尾部 `/` 时始终按最终文件名解释。

文件冲突统一按最终名称的选择者处理：用户明确指定目标名时失败且不修改已有文件；
`get` 省略本地目标或明确指向既有本地目录时，由 LeanTTY 采用远端 basename，冲突自动
生成 `name (n).ext` 并保留两份。`put` 的远端名称即使来自目录加本地 basename，也不自动
编号。1.3 不提供覆盖选项或确认对话框。

该选择是在目标 HarmonyOS PC 上实际验证 Picker 后作出的产品决策，不是因为 Picker
不可用：

- Picker 可以在不申请 Downloads 权限的情况下选择并读取 Images 中的单个文件。
- Picker 可以创建保存目标，应用能够写入，结果在文件管理器中可见并可正常打开。
- 但 Picker 会让每次上传和下载都进入系统界面，使命令历史无法直接重放，并让 `.`
  从本地目录语义变成“打开 Picker”。
- Picker URI 还会增加 ArkTS、文件描述符与 Rust 之间的生命周期所有权；保存目标的
  冲突、删除和重命名能力也不再完全由 LeanTTY 控制。
- “上传用 Picker、下载用 Downloads”会形成两套本地文件模型，不进入 1.3。

因此 1.3 接受“上传前偶尔需要把文件移动或复制到 Downloads”的成本，换取稳定、
键盘优先、可预测且可重复执行的路径式命令。

2026-08-08，1.2.0 提交 AppGallery 审核后，用户确认开始 1.3 开发；最小文件传输已经进入
`next-work.md`。同日，本地无覆盖提交、SFTP/OpenSSH 互操作和 FD/no-follow 能力边界门禁
均已闭合，剩余生命周期与路径语义也已冻结；产品 PUT/GET 实现已经开始。尚未完成的自动化
与物理机矩阵仍以唯一工作清单为准，构建或安装成功不等于能力完成。

## 二、为什么值得做

### 2.1 它服务远程终端的直接任务

远程终端用户经常需要把一个本地构建产物、配置文件或诊断材料传到服务器，或把一个
远端日志、归档和结果文件取回本地。没有文件传输时，用户只能离开 LeanTTY，再寻找
其他工具，或者在远端临时使用 HTTP、邮件、网盘等绕行方案。

单文件上传和下载不是本地 shell、文件管理器或资产管理平台；它是 SSH 日常工作中
与 `ssh`、`ssh-keygen`、`ssh-copy-id` 相邻的操作。只支持单文件交换，可以补齐
核心路径附近的真实缺口，而不改变 LeanTTY 的终端产品心智。

### 2.2 `put/get` 准确复用 SFTP 的方向认知

OpenSSH SFTP 已经使用以下交互命令：

```text
put <local-path> [remote-path]
get <remote-path> [local-path]
```

LeanTTY 复用 `put` 表示上传、`get` 表示下载，并在远端路径中补上 Host：

```text
put demo.jpeg prod:/tmp/demo.jpeg
get prod:/var/log/app.log
```

选择两个方向明确的动词，可以删除“恰好哪一端是远端”的推断，也不会让用户期待
OpenSSH `scp` 的多源、递归、远端到远端、完整选项和任意本地路径。`put/get` 虽然
是两个命令，但上传和下载本来就是两个不同方向的任务，不是同一任务的重复入口。

不再增加 `upload`、`download`、`transfer`、`copy` 或 `sftp` 等别名：

- `upload/download` 没有复用 Linux/SFTP 既有认知。
- `transfer` 仍需根据参数推断方向。
- `copy/cp` 会让 Linux 用户期待本地文件复制语义。
- `sftp` 会让用户期待进入包含 `ls`、`cd`、`rm` 等能力的交互式文件会话。
- `file put/get` 多增加一个没有真实状态所有权的命名空间。

用户输入 `scp` 时只显示迁移提示，不作为别名执行，避免保留第二套等价模型。
### 2.3 Downloads 根目录比 Downloads/LeanTTY 更易用

原方案把本地根设为 `Downloads/LeanTTY`，安全边界清楚，但增加了一层用户必须
理解和操作的目录：

- 上传前，即使文件已经在 Downloads，用户仍要把它移动到 LeanTTY 子目录。
- 下载后，用户需要在文件管理器中再进入一层目录。
- 帮助和错误信息必须反复解释 `Downloads/LeanTTY`。

直接使用 Downloads 后：

- 已经下载到 PC 的常见文件可以直接上传。
- `get prod:/path/file` 的结果就在文件管理器默认可发现的 Downloads。
- 完成提示只需说 `Open Files and go to Downloads`。
- 用户只理解 HarmonyOS 已经存在的系统目录，不学习产品专用目录。

代价是 Downloads 中更容易出现同名文件和未完成临时文件。已经确定的约束和仍待
讨论的实现门禁是：

- 永不静默覆盖已有文件。用户明确指定最终目标名时冲突失败；`get` 省略本地目标、
  由 LeanTTY 采用远端 basename 时，冲突自动生成唯一名称并保留两份。
- 最终名称不能暴露损坏内容；临时文件和最终提交方式是实现前门禁。
- 失败和受控取消只删除当前任务记录的精确临时对象；应用启动不按文件名前缀扫描或删除。
  强制终止可能留下隐藏临时文件，但绝不能留下损坏的最终名称。
- 不扫描、索引或展示 Downloads 的其他内容。

这些问题不改变 Downloads 与专用子目录的取舍，但必须在实现前闭合，不能用
Downloads 更易用作为降低可靠性要求的理由。

## 三、为什么不做更大的 SFTP 功能

以下方案都不进入 1.3：

| 方案 | 不采用原因 |
| --- | --- |
| SFTP 文件管理器 | 引入目录树、选择状态、多选、重命名、删除、刷新和大量错误分支，已经成为第二个产品 |
| `scp` | 会暗示多源、递归、完整选项和任意本地路径；只提供迁移提示，不作为别名 |
| `upload` / `download` | 没有复用 SFTP 的 `put/get` 方向认知，且与已选命令形成重复入口 |
| 文件选择器 | 真机已证明可选取和保存单个文件，但每次传输都会进入 GUI，破坏路径重放并增加 URI/FD 生命周期；1.3 拟采用 Downloads 单一路径模型 |
| 任意本地绝对路径 | 真机已经证明普通应用不能仅凭路径访问 Images 等公共目录 |
| 远端路径自动补全 | 会在 Tab 时引入连接、认证、目录读取与网络时序；1.3 只补本地 Downloads、Host 和 LeanTTY 密钥名 |
| 连接后复用当前 SSH Session | 让交互式 PTY 与 SFTP channel 共享生命周期、取消和错误状态 |
| 自动打开文件管理器 | HarmonyOS 没有已经确认的稳定“打开并定位目录”接口，也会打断终端操作 |
| 目录、通配符和多文件 | 需要递归、批次、部分成功、冲突和恢复模型 |
| 后台队列和断点续传 | 引入跨 Pane、跨生命周期状态和持久任务管理 |

明确排除这些能力，才能使文件传输仍然是终端中的一个小型 SSH 操作，而不是 SFTP
产品的起点。

## 四、用户模型

### 4.1 唯一持久对象仍然是 Host

Host 是唯一的持久连接配置：

```text
Host prod
  HostName example.com
  User deploy
  Port 22
  IdentityFile ~/.ssh/deploy
```

`ssh prod`、`put file prod:/tmp/file` 和 `get prod:/tmp/file` 必须使用同一个解析
入口，共享：

- HostName
- User
- Port
- IdentityFile
- 主机指纹校验
- 密钥口令、密码和 `keyboard-interactive` 认证

不存在 Transfer Identity、SFTP Host、传输凭据或单独的服务器列表。

1.3 文件传输不扩展 Host 管理命令：

- 不为 `host add` 或 `host set` 增加 `-i`、`--no-identity`。
- 不为 `host list` 增加 Identity 列，也不新增 `host show`。
- 不建立新的 Identity 持久字段或迁移现有 Host 数据。
- `put/get -i <identity>` 只覆盖本次命令，不修改 Host。

SSH 配置中的 `IdentityFile` 当前存在“文件路径”和“LeanTTY key store 名称”的
语义差异。文件传输不得在内部建立一套修正规则；`put/get` 必须复用 `ssh` 的同一
解析结果和错误边界。如果该差异需要修复，应作为所有 SSH 命令共同的连接配置问题
单独决策，而不是借文件传输扩展 Host 产品面。

### 4.2 `put/get` 命令

上传语法：

```text
put [-p port] [-i identity] [--] <local-file> <host>:<remote-path>
```

```shell
put demo.jpeg prod:/tmp/demo.jpeg
put reports/demo.jpeg prod:/tmp/inbox/
put reports/demo.jpeg prod:
put demo.jpeg deploy@example.com:/tmp/demo.jpeg
```

下载语法：

```text
get [-p port] [-i identity] [--] <host>:<remote-file> [local-path]
```

```shell
get prod:/var/log/app.log
get prod:/var/log/app.log reports/
get prod:/var/log/app.log app-local.log
```

带空格的路径使用 macOS/Linux 用户熟悉的引号或反斜杠：

```shell
put "Quarterly report.pdf" "prod:/tmp/Quarterly report.pdf"
put Quarterly\ report.pdf prod:/tmp/report.pdf
get "prod:/tmp/Quarterly report.pdf" "Quarterly report.pdf"
```

本地命令分词只支持完成该需求所需的单引号、双引号和反斜杠转义；不实现环境变量、
命令替换、管道、重定向、`~` 展开或通配符展开。`--` 终止选项解析，用于明确传递以
`-` 开头的文件名；它不改变路径安全边界。

用户输入 `scp` 时不执行传输，只给出迁移提示：

```text
`scp` is not supported. Use:
  put <local-file> <host>:<remote-file>
  get <host>:<remote-file> [local-path]
```

不提供 `scp`、`upload`、`download` 或其他等价别名。

### 4.3 路径与目标解析

方向由命令决定，不再根据两个位置参数猜测：

- `put` 的第一个位置参数是 Downloads 内的本地相对文件，第二个必须是远端文件或目录。
- `get` 的第一个位置参数必须是远端文件；第二个是可选的 Downloads 内相对文件或目录。
- `get` 省略本地目标时，使用远端文件的 basename 保存到 Downloads 根。
- 目录意图必须由尾部 `/` 明示。`get ... reports/` 保存到
  `Downloads/reports/<remote-basename>`；`put reports/app.log prod:/srv/inbox/` 上传到
  `/srv/inbox/app.log`。`put ... prod:` 等价于目标 SFTP Session 初始目录 `prod:./`。
- 没有尾部 `/` 的路径永远按最终文件名处理。如果它实际是目录，命令失败并提示补上 `/`，
  不根据文件系统状态静默切换解释。

- `prod:/path`：优先按现有 Host 别名解析。
- `deploy@example.com:/path`：一次性直接目标。
- 远端绝对路径保持绝对。
- 远端相对路径相对于 SFTP 登录后的初始目录。
- 1.3 不承诺远端 `~` 展开。
- 本地路径只接受 Downloads 内的相对路径；接受既有子目录但不创建目录，不接受 HarmonyOS
  内部绝对路径、盘符、反斜杠、空组件、`.` 或 `..`。
- 目录源、递归、多个源、远端到远端和命令方向不匹配全部拒绝。

`put/get` 的连接选项与现有 LeanTTY `ssh` 和 `ssh-copy-id` 一致，使用小写 `-p`
覆盖 SSH 端口。由于命令不叫 `scp`，不继承 SCP 为避让“保留时间和权限”而使用
大写 `-P` 的历史规则。

### 4.4 Identity 优先级

`put/get -i` 与现有 `ssh -i` 使用同一个 key store 引用语义，只覆盖当前命令，
不修改 Host：

```text
命令行 -i > Host IdentityFile > 正常认证回退
```

主要帮助和示例优先使用 Host 别名。`help put` 和 `help get` 再介绍 `-p` 和 `-i`，
避免把高级覆盖呈现成第二套配置。

## 五、本地文件规则

### 5.1 唯一本地根

首次使用 `put` 或 `get` 时，LeanTTY 按需申请：

```text
ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY
```

用户允许后，通过 HarmonyOS 文件环境 API 取得公共 Download 目录。产品中统一显示
为 `Downloads`，不向用户展示 `/storage/Users/currentUser/...` 内部路径。

路径规则：

- Downloads 是唯一且隐含的本地根，不建立可切换的本地当前目录。
- `demo.jpeg` 表示 `Downloads/demo.jpeg`。
- `logs/app.log` 表示 `Downloads/logs/app.log`；`logs/` 必须已经存在，命令不创建或进入
  持久当前目录。
- 每个路径组件必须非空且不是 `.` 或 `..`；单个组件按 UTF-8 编码不得超过 255 字节，
  整体路径另设有界长度。
- `get` 省略本地目标时直接保存到 Downloads 根；目标以 `/` 结尾时，在该既有目录中采用
  远端 basename。
- 拒绝所有本地绝对路径、`..` 逃逸、符号链接逃逸、设备文件和目录源。
- 解析与实际打开逐组件约束中间目录不得是 symlink，并在最终操作时重新验证；字符串检查
  不是访问授权，最终对象仍使用 no-follow / 排他创建边界。
- Tab 只为当前输入组件执行一次有界的本地目录枚举，不递归、不建立浏览状态，也不触发
  Downloads 授权；实际 `put/get` 才能请求权限。

如果用户输入：

```text
/storage/Users/currentUser/Images/demo.jpeg
```

应提示：

```text
Local files must be in Downloads.
Move demo.jpeg to Downloads, then run:
  put demo.jpeg prod:/tmp/demo.jpeg
```

不得为完成这条命令临时弹出文件选择器或申请 Images、Documents、Desktop 权限。

### 5.2 上传

- 源必须是 Downloads 中一个明确存在、可读的普通文件。
- 远端目标可以是明确文件名，也可以用尾部 `/` 明示一个既有目录；目录目标使用本地源的
  basename。`host:` 表示该独立 SFTP Session 的初始目录，等价于 `host:./`。
- 无论远端最终名称由用户直接输入还是从目录和本地 basename 推导，连接并确认它已经存在
  时都在传输文件数据前失败，不覆盖，也不擅自生成另一个远端名称。
- 不创建远端目录，不支持目录源、递归和通配符。
- 上传使用目标所在远端目录中的唯一临时名称，并以
  `CREATE | EXCL | WRITE` 排他创建；不能使用会截断已有文件的高层 `create()`。
- 临时文件完整写入并成功关闭后，使用标准 `SSH_FXP_RENAME` 提交为最终名称。不能
  使用具有覆盖语义的 `posix-rename@openssh.com`。
- 失败或取消时尽力删除远端临时文件。

远端目标冲突时显示：

```text
Remote file already exists:
  prod:/tmp/demo.zip

No files were changed.
Use another remote name, or remove the existing file on the server first.
ltty>
```

预检查只用于尽早报错，不能替代最终提交时的无覆盖保证；检查与提交之间出现并发
冲突时同样失败，已有远端文件保持不变，临时文件按本次任务身份清理。服务器不能
提供可靠的无覆盖提交时安全失败，不能退化为直接写入最终名称。

完成提示：

```text
Uploaded 15.3 MiB
  demo.zip -> prod:/tmp/demo.zip
ltty>
```

### 5.3 下载

- 下载目标只能位于 Downloads。
- `get <host>:<remote-file>` 省略本地目标时，由 LeanTTY 采用远端 basename。
  如果该名称已存在，自动生成不冲突的新名称，保留已有文件和新下载。
- `get <host>:<remote-file> <local-directory>/` 明确指向既有本地目录时，也由 LeanTTY 在
  该目录中采用远端 basename，并使用相同的自动编号规则。
- `get <host>:<remote-file> <local-file>` 明确指定本地目标时，如果该名称已存在，
  在传输文件数据前失败，不覆盖，也不自动改名。
- 省略本地目标或指向目录，且预检查发现 basename 冲突时，开始前只说明完成时将选择
  唯一名称，不提前承诺某个可能被其他 Pane 或应用抢占的最终名称。
- 先在最终目标所在目录写入 `.leantty-<random>.part` 一类 LeanTTY 可识别的唯一
  临时文件。
- 完成写入、关闭并核对已传输长度后，才以“目标存在则失败”的方式提交最终名称。
- 取消、失败和恢复清理只能删除符合本次任务身份的临时文件。

统一判断规则是：

> 用户明确选择最终目标名时，冲突失败；LeanTTY 选择默认最终名称时，冲突生成
> 唯一名称。

这不是上传和下载各自拥有一套任意策略。`put` 的远端最终名称属于上传目标，冲突始终
失败；`get` 的明确本地文件名也冲突失败。只有省略本地参数或指向本地目录的 `get` 由
LeanTTY 负责最终 basename，因此自动保留两份。1.3 不弹确认对话框，也不提供 `--force`、
`--overwrite` 或持久冲突设置。

#### 5.3.1 LeanTTY 选择本地名称时的冲突规则

采用 macOS/Windows 下载器常见的扩展名前数字去重形式：

```text
<主文件名> (<序号>)<后缀>
```

序号从 `1` 开始，选择当前目录中最小的可用正整数：

| 远端 basename | 已存在 | 实际保存名称 |
| --- | --- | --- |
| `app.log` | `app.log` | `app (1).log` |
| `app.log` | `app.log`、`app (1).log` | `app (2).log` |
| `report.final.pdf` | `report.final.pdf` | `report.final (1).pdf` |
| `archive.tar.gz` | `archive.tar.gz` | `archive.tar (1).gz` |
| `README` | `README` | `README (1)` |
| `.env` | `.env` | `.env (1)` |

算法规则：

1. 临时文件完整写入并关闭后，先以无覆盖方式尝试远端 basename；提交成功就保持
   原名。
2. “后缀”定义为最后一个非首字符 `.` 开始的部分，包括点本身。序号插在它之前；
   后缀的文字、大小写和字节内容完全不变。
3. 没有后缀的文件直接在完整名称后增加 ` (n)`。只有首字符点的 Unix 隐藏文件也
   按无后缀处理，因此 `.env` 变成 `.env (1)`。
4. 不尝试解析原名称末尾已有的 `(n)`。例如请求名称本来就是 `app (1).log`，再次
   冲突时生成 `app (1) (1).log`，避免隐藏的重命名猜测。
5. basename 提交因目标存在而失败时，继续以同样的无覆盖方式依次尝试最小可用序号；
   已经下载完成的临时文件不需要重新传输。
6. 如果增加序号会超过平台文件名长度，只在 Unicode 字符边界截短主文件名，为
   ` (n)` 和原后缀保留空间；不得截短或改写后缀。
7. 从 `1` 检查到 `9999` 仍没有可用名称，或主文件名无法安全截短时，传输失败并
   提示 Downloads 中同名文件过多，不再使用时间戳或随机最终名称。

选择该规则的原因：

- Chromium 的跨平台下载模型把数字计数器放在文件扩展名前，并用最小可用序号避免
  覆盖；同一实现覆盖 Windows 和 macOS。
- Apple 的文件冲突行为同样采用保留原文件并给额外版本增加数字的心智。
- `copy`、`副本` 等文字会涉及本地化；纯数字形式稳定、短且容易预测。
- 最终文件名仍保留原后缀，文件管理器和关联应用可以继续按类型识别。

该自动改名只适用于**省略本地目标或目标为目录的下载**。它不适用于上传，也不适用于
用户明确输入本地最终文件名的下载。

预检查检测到冲突后，在传输开始前显示：

```text
File already exists: Downloads/app.log
A unique name will be chosen when the download completes.
```

完成时显示实际目录、实际名称和改名事实，例如：

```text
● Downloaded 15.3 MiB in 2.4s
  prod:/logs/app.log -> Downloads/reports/app (1).log (Renamed)
```

### 5.4 Tab 补全

Tab 补全只优化已经授权的键盘主路径，不把命令栏变成文件管理器：

- `put` 的本地源补全 Downloads 中当前一层的普通文件和既有目录；目录候选追加 `/`。
- `get` 的可选本地目标只补既有目录；已有文件不能作为目标候选，因为明确文件名不覆盖。
- `put/get` 的远端操作数只补已有 Host 别名；`-i` 只补 LeanTTY 自己管理的密钥名。
- 不补远端路径。按 Tab 不连接、认证或列出服务器目录，也不触发 Downloads 权限请求。
- 唯一文件候选完成后追加空格，唯一目录候选追加 `/`；多候选第一次只扩展公共前缀，
  再次 Tab 才显示候选。
- 每次只列当前目录一层；默认隐藏以 `.` 开头的项，除非当前组件本身以 `.` 开头；候选最多
  显示 100 项，超出时提示 `100+ matches; type more`。
- 匹配保持原始大小写和 Unicode，不做大小写折叠或额外规范化；空格、引号和反斜杠必须
  转义成现有解析器可重新读取的命令文本。
- 列表输出、错误和完成摘要都必须净化控制字符，不能让文件名或远端路径向终端注入控制
  序列。文件名不进入日志。
- `--` 终止选项解析，使以 `-` 开头的合法本地文件名能被明确输入和补全。

完成提交后才显示确定的实际名称：

```text
Downloaded 15.3 MiB
  Renamed: app.log -> app (2).log
  Saved to Downloads/app (2).log

Open Files and go to Downloads to view it.
ltty>
```

如果预检查和最终提交都没有冲突，不显示 `File already exists` 或 `Renamed`，只
显示正常保存路径。如果预检查后才发生并发冲突，开始时不补发过时提示，完成时直接
显示最终名称和 `Renamed`。冲突提示遵循以下规则：

- 使用独立完整行，不能只在进度行中短暂闪现。
- 开始提示只说明存在冲突和稍后选择唯一名称；完成提示必须包含原名称和最终名称，
  便于用户在 Downloads 中定位。
- 可以使用现有终端警告色增强识别，但文字是唯一语义来源，不能只靠颜色或图标。
- 不使用 Toast、对话框或确认按钮，不阻塞传输。
- 文件名中的控制字符必须转义或替换，远端文件名不能借提示注入终端控制序列。
- 不响铃，不制造持续通知；只有预检查已经发现冲突时才在开始和完成两个时点提示。

这种交互对应成熟下载器的“保留两个文件并显示最终名称”，但适配了终端没有常驻
下载列表的特点：用户无需干预，同时不会错过文件已经改名的事实。LeanTTY 不自动
打开文件管理器，不打开下载文件，也不增加 `open` 命令。

#### 5.3.2 明确本地目标时的冲突规则

用户输入：

```text
get prod:/var/log/app.log latest.log
```

如果 `Downloads/latest.log` 已存在，显示：

```text
Local file already exists:
  Downloads/latest.log

No files were changed.
Choose another local name:
  get prod:/var/log/app.log latest-2.log
ltty>
```

错误必须包含冲突路径和一条可以直接修改后重试的完整命令。预检查之后、最终提交
之前才出现的并发冲突使用相同错误；LeanTTY 删除本次临时文件，但不询问是否覆盖、
不删除已有文件，也不把明确目标悄悄改成 `latest (1).log`。

### 5.4 权限被拒绝

权限只在用户执行首条 `put` 或 `get` 时申请，不在应用启动时申请。拒绝后：

- 取消本次传输。
- 回到 `ltty>`。
- SSH 终端其他功能保持可用。
- 不循环弹窗。
- 用户再次执行 `put` 或 `get` 时可以重新尝试，并显示申请原因。

## 六、传输生命周期与技术边界

### 6.1 Pane 与 Session

只能从当前 Pane 的本地 `ltty>` 提示符发起。其他 Tab 或 Pane 可以保持已连接；
“未连接”不表示整个应用必须断开。

当前 Pane 在传输期间进入独占状态：

```text
IDLE
  -> CONNECTING
  -> VERIFYING_HOST
  -> AUTHENTICATING
  -> OPENING_SFTP
  -> TRANSFERRING
  -> FINALIZING
  -> COMPLETED | FAILED | CANCELLED
  -> IDLE
```

传输 Session：

- 不创建 PTY 或 shell。
- 不复用其他 Pane 的已连接 SSH Handle。
- 不保留为可重连 Session。
- 完成、失败或取消后立即释放。
- 传输期间当前 Pane 不启动第二条本地命令。
- `Ctrl+C`、关闭 Pane、超时和断网进入同一取消清理路径。

独立传输生命周期是真实状态边界，因此可以有一个局部、可测试的传输状态类型；不再
增加 TransferManager、任务队列或持久后台服务。

### 6.2 ArkTS、N-API 与 Rust

职责划分：

| 边界 | 职责 |
| --- | --- |
| `CommandParser` | `put/get` 分词、参数、方向和本地/远端位置验证 |
| `SshConfig` | HostName、User、Port、IdentityFile 的唯一解析 |
| `TransferFileManager` | Downloads 授权后的 basename 边界、打开、临时文件和无覆盖提交 |
| `SessionViewModel` | 当前 Pane 的前台状态、提示、取消和完成文案 |
| Rust/russh | SSH 连接、主机校验、认证和 channel 生命周期 |
| `russh-sftp` | SFTP 文件操作和流式读写 |
| N-API | 启动、取消和带总量的结构化传输事件 |

文件字节不得经过 ArkTS、WebView H2 Bridge 或终端输出中转。Rust 从已验证的本地
受控路径流式读写；ArkTS 只接收进度、完成和安全错误类别。

7.7 已把检查时最新的 `russh-sftp 2.4.0` 接入产品并锁定依赖；`russh 0.62.5` 共存、
WSL/OpenSSH E2E、产品 Rust 测试和 OHOS ARM64 调试 HAP 构建已经通过。7.9 又闭合了实际
PUT/GET 小/大文件真机主链；错误矩阵和正式发布许可证门禁仍须闭合。

### 6.3 进度与错误

进度采用固定 30 格的轻量线条 thermometer，在同一终端行节流更新：

```text
[━━━━━━━━━━━━━━━╸──────────────]  50% 7.7/15.3 MiB  4.2 MiB/s  ETA 00:02
```

选择该形态前对照了常见 CLI 的正式定义：curl 默认表格同时展示百分比、平均/当前速度和
总计/已用/剩余时间；Wget 默认使用 ASCII bar，非 TTY 则退化为 dot；aria2 的紧凑 readout
使用 `完成量/总量(百分比) + DL/UL 速度 + ETA`；rsync 每个文件显示已完成字节、百分比、
速度和 ETA，完成行改为全程平均速度与耗时；OpenSSH 进度实现以 80 列作为默认窗口宽度，
每秒更新并响应终端宽度变化。共同点不是“条越长越好”，而是在经典终端宽度中优先保留
完成量、速度和时间。

LeanTTY 因而把整行目标控制在典型 80 列附近：30 格条使用 `━`、`╸` 与 `─`，比实心块更轻，
又比 `=>-` 更连贯。应用不允许更换终端字体，三个字形与完成标记 `●` 都固定由随包字体提供，
并由 Regular/Bold 字形存在、advance width 与 ASCII 单 cell 完全一致的回归锁定。线条字形只
允许字体原生不超过 4% 的连接性轮廓延伸，其他图标仍限制为 2%；不支持任意未验证 Unicode。
进度行不重复占用文件名列，因为开始和完成提示已经给出源/目标。
ArkTS 使用 `CR + EL`（回车和清除当前行）原地刷新，250ms 内不重复写终端；速度以约 1 秒
字节窗口采样并轻度平滑，既保持实时感，也避免 SFTP 分块造成闪跳。无法可靠取得总大小时
保留已传输量和实时速度，但显示 `--%` 与 `ETA --:--`，不伪造完成比例。复制结束后先显示
`Finalizing...`，只有关闭、同步和无覆盖最终提交成功后才输出完成提示：

```text
Downloaded ... (112.9 MiB in 00:22, avg 5.1 MiB/s).
```

完成、失败或取消前清除进度行；完成摘要中的耗时从首个数据阶段事件算到最终提交完成，
不包含用户输入命令、主机确认或认证凭据所花时间。

颜色遵循“文字是唯一语义、颜色只帮助扫描”的边界：活动条形条、百分比和 `Preparing`
使用终端 ANSI cyan，`Finalizing` 与 `Cancelled` 使用 yellow，失败继续复用既有 red；路径、
大小、速度、ETA 和解释文字保持默认前景色。最终文件已经安全提交后，完成行只增加一个
green `●`，不使用容易被理解为展开控件的 `[+]`。该符号由应用固定打包的 JetBrains Mono
Nerd Font Mono 提供，Regular/Bold 的字体回归已验证 U+25CF 字形存在且轮廓限定在一个等宽
cell 内。即便剥离 ANSI 和 `●`，`Downloaded` / `Uploaded`、`Finalizing`、`Cancelled` 与错误
句子仍提供完整语义；不使用整行高饱和着色、闪烁或动画。

错误至少区分：

- Download 权限被拒绝。
- 本地文件不存在或在允许目录外。
- 远端上传目标已存在、明确指定的本地下载目标已存在，或省略目标时无法分配唯一
  下载名称。
- 最终提交不支持无覆盖语义，或提交期间目标被并发抢占。
- 主机指纹或 SSH 认证失败。
- 服务器不支持 SFTP。
- 远端权限拒绝。
- 本地空间不足或写入失败。
- 网络断开、超时和用户取消。
- 清理失败。

错误说明下一步，不记录文件内容、凭据或不必要的完整敏感路径。

## 七、已经完成的验证

### 7.1 验证环境

2026-07-26 在物理 HarmonyOS PC 上进行了临时文件访问探针：

| 项目 | 环境 |
| --- | --- |
| 设备 | HAD-W32 |
| CPU | ARM64 |
| 系统 | HarmonyOS 6.0.0 |
| 设备 API | API 22 |
| SDK 核对 | 本机 API 24 SDK 声明 |
| 测试文件 | `/storage/Users/currentUser/Images/demo.jpeg` |

探针使用 LeanTTY 应用身份运行，不用 HDC shell 权限代替应用权限。

### 7.2 SDK 与权限验证

本机 API 24 SDK 中确认：

- `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` 是 `normal` 级别、
  `user_grant` 模式，从 API 11 提供。
- `Environment.getUserDownloadDir()` 需要该权限并返回公共 Download 目录。
- Documents 使用独立的普通用户授权。
- Desktop 对应权限为 `system_basic`，不适合普通三方应用。

这证明 HarmonyOS 的模型是目录级明确授权，而不是给普通应用一个可遍历全部用户
文件的全盘读写权限。

### 7.3 真机结果

| 验证项 | 结果 | 支持的结论 |
| --- | --- | --- |
| 未声明目录权限，读取 `/storage/Users/currentUser/Images/demo.jpeg` | `Operation not permitted` | 仅凭用户输入任意路径不可行 |
| 未声明目录权限，取得 Download/Documents/Desktop | 全部 `Operation not permitted` | 公共目录不是默认开放 |
| 申请 Download 权限 | 系统显示明确授权弹窗，用户选择允许 | 权限不是静默获得 |
| 获得 Download 权限后取得目录映射 | 返回 `/storage/Users/currentUser/Download` | Downloads 可以成为唯一公开本地根 |
| 在 `Download/LeanTTY` 创建、写入、关闭后重开测试文件 | 成功，测试文件随后清理 | 已授权 Download 范围可以稳定读写 |
| Download 授权后再次读取原始 Images 文件 | 仍为 `Operation not permitted` | Download 权限不会扩散到 Images |
| 用户把 `demo.jpeg` 复制到 `Download/LeanTTY` 后读取 | 成功；大小 15,682 字节，读取前 16 字节 | 用户移动到已授权 Download 范围后的上传源模型成立 |
| 应用重启和同签名覆盖安装 | 授权仍有效，没有重复弹窗 | 当前真机上授权可跨这两个生命周期保持 |

探针没有修改原始 `Images/demo.jpeg`，也没有修改或删除用户复制的
`Download/LeanTTY/demo.jpeg`。

### 7.4 Picker 真机验证

2026-07-27 又在同一物理 PC 上验证了 `DocumentViewPicker`，目的是在决定本地文件
模型前证明替代方案的真实能力，而不是只根据文档推测：

| 验证项 | 结果 | 支持的结论 |
| --- | --- | --- |
| 未声明 Downloads 权限，通过 Picker 选择 `Images/demo.jpeg` | 成功返回 `file://docs/.../Images/demo.jpeg` URI | Picker 可以提供单文件读取授权 |
| 读取所选文件 | 15,682 字节；前 16 字节为 `ff d8 ff e0 00 10 4a 46 49 46 00 01 01 00 00 01` | 选择到的是此前 JPEG/JFIF 测试文件 |
| 连续选择两次 | 文件名、大小和文件头一致 | 选择和读取行为可重复 |
| 通过系统保存界面创建副本并写入 | 文件管理器可见，用户确认可以正常打开 | Picker 保存 URI 的用户可见成功路径成立 |
| 保存测试期间的安装权限 | 未声明 `READ_WRITE_DOWNLOAD_DIRECTORY` | Picker 不依赖整个 Downloads 授权 |
| 尝试删除保存 URI | 副本仍然存在；SDK 的 `unlinkSync` 也只承诺应用沙箱路径 | 不能把 Picker URI 的删除或重命名能力当作已证明前提 |

保存探针包含写后回读比较，但对应 hilog 在应用退出后被高频设备日志覆盖，未保留可
审计的逐字节一致性记录。因此本轮只确认文件可见且可正常打开，不把“保存副本哈希
一致”列为已完成证据。该证据边界不影响 Picker 与 Downloads 的交互取舍。

Picker 探针结束后，临时代码和权限声明均已移除，正常签名 LeanTTY 已重新构建、
覆盖安装并启动。测试副本需要由用户从文件管理器删除，不能声称应用已经自动清理。

### 7.5 收尾验证

Downloads 权限探针完成后：

- 临时探针源码已恢复到测试前状态。
- 临时 Download 权限声明已撤销。
- 正常 LeanTTY 已重新构建并安装。
- 设备新进程中没有 `FILE_PROBE` 日志。
- 安装包不再声明测试权限。

Picker 探针完成后也重新执行了相同恢复流程；新的正常进程无
`PICKER_SAVE_PROBE`，安装包无 Downloads 权限，仓库无 Picker 探针源码差异。

### 7.6 2026-08-08 Downloads 根目录无覆盖提交门禁

1.3 启动后，仓库在现有 debug acceptance 构建期注入机制中加入了一个克制的
`Downloads No-Replace` 探针，并用 `tools/verify-file-transfer-pc.ps1` 在物理 HAD-W32
（ARM64、API 22、HarmonyOS `6.0.0.130`）执行。探针只在公共 Downloads 根目录创建四个
带随机 token 的精确路径，release 包继续由 marker 门禁拒绝验收专用代码。

| 验证项 | 结果 | 支持的结论 |
| --- | --- | --- |
| 完整写入、`fsync`、关闭同目录临时文件后执行 `fs.moveFileSync(temp, final, 1)` | 成功；源消失，最终文件逐字节等于完整输入 | 公共 Downloads 根上的 mode 1 成功提交路径成立 |
| 预检查目标不存在后，由另一对象在提交前创建最终名称 | mode 1 返回 `File exists` | 提交期竞态不会退化为覆盖 |
| 冲突后的最终目标与传入临时文件 | 两者逐字节分别保持原有内容 | 已有目标不变，失败任务仍拥有自己的临时对象 |
| finally 精确删除四个探针路径后由应用再次检查 | 四个路径均不存在；`cleanupComplete=true` | 不依赖前缀扫描，也未留下本轮一次性数据 |

调试 HAP 构建、安装、启动和脚本化重跑均通过；被测 marker 为
`ACCEPTANCE_DOWNLOADS_NOREPLACE`。该结果证明当前目标系统和授权目录上的候选提交原语，
不是完整下载实现，也不替代后续 FD/no-follow、取消、跨重启或 SFTP 验证。

### 7.7 2026-08-08 `russh-sftp` / OpenSSH 互操作门禁

仓库新增了独立 workspace `leantty_ssh/sftp-interop-fixture`，只验证协议原语，不接入产品
crate、N-API 或 HAP。fixture 精确锁定 `russh 0.62.5` 和检查时最新的
`russh-sftp 2.4.0`，每次运行创建临时 host/client key、临时 localhost OpenSSH 配置和临时
远端目录，退出时终止服务器并删除整个临时根。

| 验证项 | 结果 | 支持的结论 |
| --- | --- | --- |
| WSL Ubuntu 26.04、Rust 1.96、OpenSSH 10.2p1 E2E | 连续两次通过 | 当前工具链与受控 OpenSSH 基线可重复 |
| `OpenFlags::CREATE | EXCLUDE | WRITE` 创建临时文件 | 新名称成功；已有名称失败 | 不需要调用会 truncate 的高层 `create()` |
| 完整关闭后调用 `SftpSession.rename()` | 新目标成功且内容一致 | `russh-sftp` 的标准 SFTP v3 rename 路径可用 |
| 预检查后创建最终目标，再执行标准 rename | rename 失败；目标和临时文件内容分别保持 | OpenSSH 基线的提交期竞态不会覆盖 |
| 精确删除本轮四个远端路径并复查目录 | `cleanupComplete=true`，临时目录为空 | 失败与成功路径可以只清理任务所有对象 |
| `cargo fmt --check`、clippy `-D warnings` | 通过 | fixture 源码门禁通过 |
| `aarch64-unknown-linux-ohos` 交叉 `cargo check --locked` | 通过 | crate 与传递依赖可由当前 OHOS NDK/Rust 工具链编译 |

`russh-sftp 2.4.0` 使用 Apache-2.0；与当前产品锁文件相比，除 fixture 自身和测试用
`anyhow` 外，新增包名为 `russh-sftp`、`dashmap`、`gloo-timers`、`serde_bytes`、
`tokio-util` 及其锁/容器传递依赖，声明许可证均为 MIT、Apache-2.0 或二者任选。
它不直接依赖某个 `russh` 版本，而是接收 `AsyncRead + AsyncWrite` stream；本次实际编译和
E2E 已证明可与 0.62.5 共存。

该 fixture 本身不是产品依赖。初始协议门禁完成后，产品已把精确 `russh-sftp` 依赖写入
`Cargo.lock`、更新许可证材料并通过 ARM64 HAP 构建；7.9 已补上生产事件链真机主路径。
无 SFTP、权限拒绝、取消、断线和服务器差异仍须单独验收，本节不能替代这些矩阵。

### 7.8 2026-08-08 FD/no-follow 能力边界门禁

`tools/verify-file-transfer-pc.ps1` 在同一物理 ARM64 PC 上追加了 debug-only FD 边界探针。
ArkTS 以 `lstat` 拒绝非普通文件并用 `READ_ONLY | NOFOLLOW` 打开 Downloads 源文件；随后把
原路径移走并在同名路径写入不同内容，再由 native 复制 FD、`fstat` 并读取。native 读到的
仍是原始已打开对象，证明上传不会在验证后按字符串路径重新打开替换对象。

系统拒绝在公共 Downloads 和应用私有 cache 中创建符号链接，因此本机没有构造出可直接
观察 `NOFOLLOW` 拒绝 symlink 的对象；可观察结论是当前系统在两个应用可写位置都禁止创建
该对象。产品仍保留 `lstat + NOFOLLOW + native fstat` 三层规则，不能把系统当前的创建拒绝
当作未来平台可省略 no-follow 的理由。探针全部使用随机精确路径并确认清理完成。

### 7.9 2026-08-09 产品 PUT/GET 大文件主链

`tools/verify-put-get-pc.ps1` 使用生产 `get` / `put` 命令、认证状态机、结构化事件和本地提交
路径，在同一物理 ARM64 PC 上对下载目录中的
`DoubaoIME_Installer_0.6.3.07271.exe` 连续执行两轮 `GET → Downloads → PUT`。源文件为
118,349,760 字节（112.9 MiB），SHA-256 为
`3cb7d8f41e6815992b0208552ad4626fd9ad0e4e159beaecba1afe34d494c613`。

两轮稳定性复验复用同一个 HAP（SHA-256
`0524c04d7d4a143ba828f85b98a95a767d645dec649b04cd454fc3bb4cd9a018`）；线条字形收敛后又构建
最终视觉候选（SHA-256 `420e36acfd02f55def662c03a721e68debcd85725d9675411e97876fa889e7c1`）
并执行第三轮。结果如下：

| 轮次 | GET | PUT | 完整性与清理 |
| --- | --- | --- | --- |
| 1 | 6.232 秒，18.11 MiB/s | 1.942 秒，58.12 MiB/s | 双向 SHA-256 一致；本地一次性文件与远端临时对象精确清理 |
| 2 | 6.254 秒，18.05 MiB/s | 1.917 秒，58.87 MiB/s | 双向 SHA-256 一致；本地一次性文件与远端临时对象精确清理 |
| 最终视觉候选 | 6.198 秒，18.21 MiB/s | 2.202 秒，51.24 MiB/s | 双向 SHA-256 一致；本地一次性文件与远端临时对象精确清理 |

三轮都观察到正字节进度、实时速度和独立 `FINALIZING` 阶段。最终视觉候选把条形字形改为
`━`、`╸`、`─`；它们与 `●` 一起通过固定打包字体 Regular/Bold 的单 cell advance 回归，并
再次通过同一大文件主链。重复验证还暴露了
HarmonyOS `uinput` 单次长文本在 50 字符处截断的测试基础设施边界，验证器已改为每 40 字符
分批注入；修复后重复候选和最终视觉候选的命令均完整进入传输。该问题发生在测试命令注入阶段，
不是 SFTP 或产品传输失败。

#### 7.9.1 子目录、自动命名与 Tab 补全主链

路径语义和 Tab 补全收敛后，验证器又分别使用 131,089 字节定向文件和用户指定的
`DoubaoIME_Installer_0.6.3.07271.exe` 完成真实生产事件链。大文件为 118,349,760 字节，
SHA-256 为 `3cb7d8f41e6815992b0208552ad4626fd9ad0e4e159beaecba1afe34d494c613`；结果如下：

| 文件 | GET | PUT | 路径、补全与冲突证据 |
| --- | --- | --- | --- |
| 131,089 字节 | 0.078 秒 | 0.076 秒 | 已存在本地/远端目录；GET 目录和 PUT 文件经 Tab 完成；自动编号且原文件不变；双向 SHA-256 一致 |
| 118,349,760 字节 | 6.550 秒，17.23 MiB/s | 1.959 秒，57.59 MiB/s | 同上；空格转义、正字节进度、实时速度、`FINALIZING` 和精确清理均通过 |

GET 的本地目录候选完成后保留目录意图，最终在同一既有目录中把远端 basename 提交为
`source (1).bin`，预置的 `source.bin` 内容保持不变；PUT 的本地文件候选包含空格，补全后正确
转义，远端目录目标沿用本地 basename。Tab 阶段没有建立网络连接，命令也没有创建本地或远端
目录。大文件门禁证据保存在
`build/verification/put-get-20260809-102025/device-put-get.json`。

HDC bundle shell 无法直接在应用已获授权的公共 Download 中准备验收状态，且权限失败不会反映为
非零 HDC 退出码。验证器因此改用仅在调试构建中编译注入的验收 action 创建和精确清理固定测试
目录与冲突文件；产品命令仍是被测路径，正式包沿用现有策略排除所有验收 action 和标记。SSH
fixture 同时补齐了受约束的相对子目录解析，并拒绝空组件、`.`、`..` 和反斜杠，避免 fixture
自身把产品的合法嵌套路径误报为权限错误。

### 7.10 证据边界

已经验证的是 HarmonyOS 的公共目录授权模型、“用户移动到 Download 后应用可读写”路径、
Picker 的单文件选择与用户可见保存路径，以及密码认证下显式 basename、既有一级相对子目录、
目录目标、自动编号冲突和 Tab 补全的生产 PUT/GET 小文件与 112.9 MiB 大文件主链；这些定向
证据仍不是完整文件传输验收矩阵。

以下内容**尚未验证**：

- 未授权/拒绝/恢复，以及明确文件名冲突、提交期并发抢占和序号耗尽的完整 Download 交互。
- 与其他实际 OpenSSH 服务器的认证方式、无 SFTP、权限拒绝、取消、断线和错误互操作。
- 产品事件链中的并发抢占、错误映射、取消、断线和崩溃清理。
- 空文件、多级/Unicode/长路径、中间 symlink，以及完整尺寸和生命周期矩阵。

此前权限验证主要在 `Download/LeanTTY` 子目录执行；7.6、7.8、7.9 和 7.9.1 已依次补齐
Download 根目录提交原语、已打开对象能力边界、生产 `put/get` 定向端到端主链，以及既有
相对子目录/自动编号/Tab 补全主链。仓库保留编译期隔离的聚焦门禁脚本；后续验收继续复用生产
传输事件链，不能把探针扩展为第二套传输实现。

## 八、后续讨论清单与实现前门禁

本节是后续讨论的权威清单。标记为“待讨论”的条目没有被本文其他详细候选规则自动
批准；标记为“实现前门禁”的条目必须先取得平台或协议证据，不能留到功能完成后再
补救。

### 8.1 已确认的产品决策

#### 8.1.1 Downloads 与 Picker

1. 1.3 只保留 Downloads 一个本地文件根。
2. 不采用每次传输弹出的 Picker，也不做“上传 Picker、下载 Downloads”的混合模型。
3. 选择 Downloads 的主要理由是保持路径式命令、键盘优先、历史可重放、冲突行为
   可控和 Rust 直接流式读写。
4. 已接受的代价是整个 Downloads 授权范围更大，且上传其他目录中的文件前可能需要
   用户先移动或复制。
5. Picker 的能力验证作为替代方案证据保留，但不转化为 1.3 产品入口。

#### 8.1.2 `put/get` 命令模型

1. 上传使用 `put`，下载使用 `get`，复用 OpenSSH SFTP 的既有方向认知。
2. 不把功能命名为 `scp`，避免暗示多源、递归、远端到远端、完整选项和任意本地
   路径兼容性。
3. 不增加 `upload`、`download`、`transfer`、`copy`、`sftp` 或 `file put/get`
   等价入口。
4. 用户输入 `scp` 时只显示 `put/get` 迁移提示，不作为别名执行。
5. `put/get` 使用与现有 `ssh` 一致的小写 `-p` 和 `-i` 连接选项。
6. `get` 省略本地目标时使用远端 basename；`get` 的远端源必须是文件。`put` 的远端
   目标可以明确到文件名，也可以用尾部 `/` 明示既有目录并沿用本地 basename；`host:`
   表示 SFTP 初始目录。
7. 本地相对路径允许穿过 Downloads 内的既有子目录；目录意图必须以 `/` 明示，命令不创建
   目录，也不维持本地或远端当前目录。

#### 8.1.3 文件冲突与目标名称所有权

1. 上传和下载都不静默覆盖已有文件。
2. 用户明确选择最终目标名时冲突失败；LeanTTY 选择默认最终名称时冲突生成唯一
   名称。这是上传和下载共同使用的唯一判断规则。
3. `put` 的远端目标无论明确给出文件名还是由目录和本地 basename 推导，同名对象存在时
   都失败。
4. `get` 明确提供本地目标时，本地同名文件存在则失败。
5. `get` 省略本地目标或明确指向既有目录时由 LeanTTY 采用远端 basename；冲突使用最小
   可用的 `name (n).ext`。开始时不承诺可能被并发抢占的名称，完成时显示实际保存名称和
   `Renamed`。
6. 1.3 不增加确认对话框、`--force`、`--overwrite` 或可配置冲突策略。

选择原因：

- OpenSSH SFTP、`scp` 和 `rsync` 的普通传输路径偏向更新已有目标，而 Wget、curl
  和 Transmit 也提供保留两份、跳过、询问或覆盖等不同策略；不存在必须照搬的唯一
  行业默认。
- LeanTTY 可靠性优先，不能把破坏性覆盖作为默认行为，也不在 1.3 增加覆盖能力。
- 对明确名称失败，尊重命令行用户的目标意图；对省略名称自动去重，避免用户为一次
  普通下载手工重输命令。
- 按“谁选择名称”判断比按上传/下载方向硬编码两个例外更容易解释，也不需要对话框、
  持久设置或第二套操作模式。

未采用的替代方案：

- 全部冲突失败：规则最少，但让最常见的省略目标下载产生不必要的重输。
- 所有下载都自动改名：会忽略用户明确输入本地目标名的意图。
- 每次询问：引入等待输入的额外状态，并使脚本式重复执行变得不可预测。
- 允许覆盖：既增加破坏性能力，也要求先证明原子替换、取消和崩溃恢复，不属于 1.3
  的最小可靠路径。

#### 8.1.4 Host/Identity 最小复用范围

1. `put/get` 复用现有 Host、认证、主机指纹、key store 和 `ssh` 的配置解析入口。
2. 命令级 `put/get -i <identity>` 与现有 `ssh -i` 使用相同语义，只覆盖本次传输，
   不修改 Host。
3. 1.3 不为 `host add/set` 增加 `-i` 或 `--no-identity`，不为 `host list` 增加
   Identity 列，也不新增 `host show`。
4. 不建立 Transfer Identity、SFTP Host、第二套凭据或新的持久字段。
5. `IdentityFile` 的路径与 key store 名称差异不在文件传输内部修补；若要修复，
   必须作为 `ssh`、`ssh-copy-id` 和 `put/get` 共同的连接配置问题另行决策。

选择该范围是为了让文件传输只增加一次性操作，不顺带扩大持久配置、列表界面和数据
迁移。已有 Host 可以直接复用；临时选择其他密钥时使用命令级 `-i` 已足够完成核心
路径。

### 8.2 实现前可靠性门禁

#### 8.2.1 本地与远端无覆盖提交

已确定的共同提交模型是：

```text
预检查目标
  -> 在最终目标所在目录排他创建唯一临时文件
  -> 完整传输并关闭临时文件
  -> 以“目标存在则失败”的方式提交最终名称
  -> 清理本次任务拥有的临时文件
```

预检查只用于尽早给出冲突错误；它和最终提交之间存在竞态，不能作为可靠性保证。
产品保证限定为：

- 已有目标内容绝不被修改。
- 最终名称只在完整传输成功后出现。
- 并发抢占明确目标时安全失败；省略下载目标时改试下一个唯一名称。
- 取消、失败或断线不会把不完整内容暴露为最终名称。
- 1.3 不承诺远端服务器断电后的磁盘持久化；这不是普通 SFTP 传输能够统一保证的
  能力。

本地下载的推荐实现：

1. 临时文件和最终文件位于 Downloads 的同一目录。
2. 临时文件完整写入并关闭后，候选使用 HarmonyOS
   `fs.moveFile(temp, final, 1)` 提交；API 24 SDK 声明 `mode = 1` 在目标同名文件
   存在时抛出 `File exists`，而不是覆盖。
3. 明确本地目标只尝试一次；提交冲突时删除本次临时文件并失败。
4. 省略本地目标或明确指向既有目录时，在传输完成后依次尝试 basename、
   `name (1).ext`、`name (2).ext`，直到无覆盖提交成功；不提前占用或承诺最终名称。

2026-08-08 的 7.6 物理机门禁已经证明，当前目标系统的公共 Downloads 根目录上，
`moveFileSync(..., 1)` 可以在完整关闭临时文件后成功提交，并在提交前被并发抢占时返回
`File exists`、保持两侧内容不变。当前不需要引入 native
`renameat2(RENAME_NOREPLACE)` 回退；若后续支持的目标系统出现不同结果，应安全失败并重新
评估，而不是静默切换为覆盖语义。

远端上传的推荐实现：

1. 在目标目录使用 `CREATE | EXCL | WRITE` 排他创建随机临时文件；不得使用
   `russh-sftp` 会截断已有文件的高层 `create()`。
2. 完整写入并成功关闭后，使用 SFTP v3 标准 `SSH_FXP_RENAME` 提交。标准语义要求
   `newpath` 已存在时报错；不能使用具有覆盖语义的
   `posix-rename@openssh.com`。
3. 当前 OpenSSH 对普通文件的标准 rename 优先使用 link/unlink 做无竞态提交。7.7 已用
   实际 `russh-sftp 2.4.0` 客户端和 OpenSSH 10.2p1 验证成功、目标冲突、内容保持与临时文件
   清理；产品实现仍须复用该原语并补齐结构化错误映射和实际目标服务器差异。
4. 服务器不支持可靠无覆盖提交时，本次上传安全失败；不能退化成直接写最终名称、
   删除已有目标或覆盖 rename。

本地 Downloads、受控 OpenSSH 协议原语和 FD/no-follow 门禁均已闭合；产品实现已接入，
但实际服务器上的完整传输、取消与错误矩阵仍未验证，本节不能据此把 `put/get` 写成完成能力。

#### 8.2.2 路径验证与打开之间的 TOCTOU

唯一实现已经冻结：上传由 ArkTS 在已授权 Downloads 根中逐组件验证相对路径；每个中间
目录必须已经存在、是目录且不是 symlink，最终对象执行 `lstat`，再用
`READ_ONLY | NOFOLLOW` 打开。N-API 在同步返回前复制 FD 并 `fstat` 为普通文件，Rust 只从
复制后的已打开对象流式读取，不再按路径打开。7.8 已在真机证明根目录源路径被替换后，
native 仍读取原始对象；子目录逐组件边界仍须补齐定向真机验证。

下载不会打开既有用户文件：ArkTS 在逐组件验证的最终既有目录中生成随机精确临时路径，
native 使用 `create_new` 排他创建本任务的新对象；完成后关闭并 `sync_all`，ArkTS 再在同一
目录以 mode 1 提交。最终提交前重新验证目录链；任何中间目录被替换为 symlink、移出
Downloads 或改变类型时安全失败，不把临时文件跨目录提交。

字符串规范化只负责拒绝越界输入，不充当访问授权；文件字节不经过 ArkTS 字符串、WebView
或终端流。

#### 8.2.3 临时文件所有权与跨重启清理

文件名符合 `.leantty-*.part` 不足以证明归 LeanTTY 所有。1.3 选择不持久记录、不在启动时
扫描 Downloads：正常失败、取消和受控 Pane/应用关闭只删除当前内存任务记录的精确临时
路径；进程被强制终止时可能留下隐藏 `.part`，但提交模型保证它不会以最终名称出现。
LeanTTY 不按前缀认领、删除或恢复任何跨重启对象。

#### 8.2.4 `Ctrl+C` 与终端复制

现有终端在有选区时把 `Ctrl+C` 用于复制。传输取消应保持同一优先级：

- 有选区时复制，不取消。
- 无选区时取消当前传输。

提示保留现有终端规则，不增加常驻说明；选区、焦点和取消事件仍须真机验证。

#### 8.2.5 生命周期、并发与迟到事件

唯一行为已经冻结：

- Downloads 权限请求由进程内 static Promise 跨 Pane single-flight；同一时刻只存在一条系统
  授权流程，拒绝后 Promise 清除，下一条显式命令可以重试。
- 关闭 Pane 或应用的受控关闭先发送 native 取消并等待该任务的最终事件与精确清理，再释放
  Pane 所有者；不把清理交给迟到的 UI 回调猜测。
- 每个 N-API 事件携带并校验 `transferId + paneId + generation`；取消后或旧 Pane 的迟到事件
  被丢弃，不得写入新 Session。
- 最小化不主动暂停或取消，前台任务在系统仍调度进程且网络可用时继续；休眠、网络切换或
  系统挂起导致 I/O 失败时进入统一失败清理。1.3 不增加后台服务、断点续传或恢复队列。
- 强制终止不能保证清理；依靠 8.2.3 的临时对象规则保证半文件不暴露为最终名称。

#### 8.2.6 路径语义

- 下载对远端源先 `lstat`，拒绝 symlink 和非普通文件；打开后再次 `fstat`，不跟随被替换的
  符号链接。上传目标预检查也使用 `lstat`，任何已有对象都按冲突处理。
- 直接 IPv6 目标必须写成 `user@[2001:db8::1]:/path/file`；方括号内冒号不作为
  `host:path` 分隔符。Host 别名继续由现有 `SshConfig` 解析。
- 1.3 的 ArkTS/N-API 字符串边界只支持有效 UTF-8 名称；无法表示为字符串的非 UTF-8 远端
  名称不支持，也不增加字节路径入口。
- 本地只接受 Downloads 内由 `/` 分隔的相对路径，允许但不创建既有子目录。拒绝绝对路径、
  盘符、`\\`、空组件、`.`、`..` 和 NUL；每个中间对象必须是非 symlink 目录。
- `get` 的远端源必须是普通文件，不能以 `/` 结尾。`put` 的远端目标以 `/` 结尾或路径为空
  时表示目录；否则表示最终文件名。远端相对路径始终相对于本次 SFTP Session 初始目录，
  不承诺 `~` 展开，也不创建目录。
- 本地单组件超过 255 UTF-8 字节、整体相对路径超过 4096 字节或远端路径超过 4096 字符均
  失败。自动编号若超过 255 UTF-8 字节，只在 Unicode 边界截短 stem，保留 ` (n)` 与原
  后缀；basename 与 `1..9999` 均冲突则失败。
- 文件名与远端路径中的 NUL、ESC、C0/C1 控制字符和换行拒绝进入命令执行；补全候选和用户
  可见路径在写入终端前再次转义，避免控制序列注入。

### 8.3 决策状态

实现前门禁与剩余语义已于 2026-08-09 冻结。新的路径根、覆盖语义、后台生命周期或恢复
策略必须先回到 `next-work.md` 和产品原则重新授权，不能在实现中增加隐式候选。

## 九、仍需完成的验证

### 9.1 自动化

Host/Identity 用例按 8.1.4 的最小复用范围实现；冲突用例按 8.1.3 已确认的唯一
规则实现，不能额外增加 Host 扩展、对话框或覆盖分支。

- `put/get` 分词覆盖引号、反斜杠、`--`、缺少参数、未知选项和未闭合引号。
- `put` 只接受本地到远端，`get` 只接受远端到本地。
- `get` 省略本地目标时正确提取远端 basename。
- `get` 远端源尾部 `/`、目录源、多个源、方向不匹配和本地绝对路径均被拒绝；`put` 的
  远端尾部 `/` 和 `host:` 正确使用本地 basename，路径不带 `/` 时不会因同名目录静默改义。
- `scp` 只返回迁移提示，不启动连接；其他别名不被接受。
- Host 与直接目标解析结果和 `ssh` 一致。
- `-i`、Host IdentityFile、默认认证回退优先级一致。
- `put/get -i` 只覆盖当前命令，不改变后续 `ssh` 或 `put/get`。
- `host add/set/list` 的语法和输出不因文件传输改变；文件传输不新增持久 Identity。
- 本地多级相对路径规范化后不能逃出 Downloads；空组件、`.`、`..`、反斜杠、盘符、超长
  组件与超长路径均失败。
- 既有子目录可用但不由命令创建；任何中间 symlink、最终 symlink、目录上传源和目录类型
  竞态都安全失败。
- `put` 目标已存在时在传输数据前失败，错误包含远端冲突路径，已有文件内容不变。
- `get` 明确本地目标且已存在时在传输数据前失败，错误包含冲突路径和指定新名称的
  可执行示例，已有文件内容不变。
- `get` 省略本地目标或目标为既有目录，且 basename 已存在时，验证最小可用序号、后缀、
  隐藏文件、Unicode、长度、序号耗尽、并发抢占、开始时不承诺最终名称以及完成时显示
  实际名称和改名事实。
- 检查与最终提交之间发生并发冲突时仍不覆盖，并返回与名称所有权一致的结果。
- 下载最终名称在临时文件完整关闭前不可见；明确目标提交冲突时只清理本次临时文件。
- 上传临时文件使用 `CREATE | EXCL | WRITE`；标准 rename 冲突不改动已有远端目标。
- 禁止使用 `russh-sftp.create()`、`posix-rename@openssh.com` 或直接写最终名称作为
  无覆盖路径的回退。
- `--force`、`--overwrite` 和任何冲突确认输入都不被接受。
- 下载临时文件成功提交；失败和取消清理。
- 小文件、空文件和大文件内容哈希一致。
- 进度事件节流，两个 Pane 的传输状态不串联。
- Tab 覆盖 `put` 本地文件/目录、`get` 本地目录、Host、`-i`、公共前缀、再次 Tab 列表、
  隐藏项、候选上限、转义和控制字符净化；证明不触发权限请求、远端连接或递归枚举。

### 9.2 物理 HarmonyOS PC

1. 在未授权状态执行首条 `put/get`，确认只出现真实系统 Download 权限弹窗。
2. 允许后直接从 `Downloads/demo.jpeg` 上传，不使用 LeanTTY 子目录。
3. 在没有同名文件时省略本地目标下载 `app.log`，从系统文件管理器确认
   `Downloads/app.log` 可见且哈希一致。
4. 拒绝权限后确认终端仍可用，再次执行时可以恢复。
5. 验证空格、Unicode、长名称和 Downloads 内既有多级子目录；确认不存在的目录不会被
   创建，中间 symlink/类型替换安全失败，临时文件和最终文件始终位于同一目标目录。
6. 分别预置远端上传目标、明确指定的本地下载目标，以及省略目标或指向目录的 basename：
   前两者必须失败且原文件哈希不变；LeanTTY 选择的本地名称必须使用最小可用的
   `name (n).ext`、不修改后缀，开始时不承诺最终名称，完成时显示原名称与实际名称。
7. 在预检查后、最终提交前抢占目标名称：明确目标必须失败且已有文件哈希不变；
   省略下载目标必须使用下一个名称，不能重新传输文件。
8. 中途 `Ctrl+C`、断网、关闭 Pane 和关闭应用，不留下最终名称的损坏文件。
9. 验证启动时不会按文件名前缀触碰 Downloads 内容；受控取消只删除本任务精确临时路径，
   强制终止后即使留下隐藏临时文件，也不得出现损坏最终名称。
10. 使用密码、未加密密钥、加密密钥和 `keyboard-interactive` Host 各完成传输。
11. 验证 `put/get -i other` 只临时覆盖，不改变后续 `ssh prod` 或
    `put/get ... prod:...`。
12. 服务器没有 SFTP、远端权限拒绝和本地空间不足时错误清楚且可恢复。
13. 检查 hilog、命令历史和错误快照不包含凭据或文件内容。
14. 在未授权和已授权状态分别验证 Tab：不弹权限、不连接服务器；文件/目录、空格、Unicode、
    公共前缀和有界候选列表可用，控制字符不能改变终端布局。

没有完成自动化、ARM64 干净构建和上述真机矩阵前，不得把文件传输标为完成或写入
发布宣传。

## 十、如何满足产品原则

| 产品原则 | 文件传输方案如何满足 |
| --- | --- |
| 可靠是底线 | 独立短生命周期 Session；明确 `TRANSFERRING` 与 `FINALIZING`；同目录临时文件和禁止替换提交；统一取消和错误分类；真机验收 |
| 简洁是默认选择 | `put/get` 方向明确；一个 Downloads 根；按目标名称所有权使用一条冲突规则；复用现有 Host 而不扩展管理命令；单文件；无 GUI、远端补全、队列和后台状态 |
| 易用只优化核心路径 | 复用 SFTP 的 `put/get` 认知；允许既有子目录和显式目录目标；LeanTTY 选择下载名称时自动保留两份；只为本地路径、Host 和密钥提供有界 Tab 补全 |
| 不并存等价模型 | 不提供 `scp` 等别名；`ssh` 与 `put/get` 共用 Host、Identity、主机指纹和认证解析 |
| 优先复用标准 | 用户表面复用 OpenSSH SFTP 的 `put/get` 方向；传输复用 SSH SFTP 子系统；权限复用 HarmonyOS Download 授权 |
| 明确安全边界 | 不访问任意用户路径；不扩大到 Images/Documents/Desktop；文件字节不经过 WebView；不记录秘密 |
| 不为架构而架构 | 只为真实独立生命周期增加局部传输状态；不建立 Manager、通用任务框架或插件接口 |
| 验证是设计的一部分 | 已用应用身份做真机权限探针；明确区分已验证平台事实和待验证传输实现 |

该能力与“默认不做 SFTP 文件管理器”的原则不冲突：禁止的是第二套文件管理产品，
不是通过两个方向明确的 SFTP 风格命令完成一次单文件交换。

## 十一、停止条件

出现以下任一情况时，应停止把文件传输纳入 1.3，而不是继续扩大方案：

- `russh-sftp` 不能在目标 ARM64 HAP 中可靠构建或运行。
- 复用现有认证状态机需要破坏交互式 SSH Session 的稳定性。
- HarmonyOS Download 权限在目标发布环境中无法通过普通三方应用审核或稳定使用。
- 取消和断线无法避免把损坏文件暴露为最终名称。
- 实现必须增加文件管理器、后台服务、持久队列或第二套 Host/Identity 数据。
- 真机用户路径仍然难以理解，且需要不断增加特殊规则才能工作。

届时应保留现有 SSH 终端能力并推迟文件传输，不用路线图倒逼产品原则让步。

## 十二、设计依据

- [LeanTTY 产品与技术原则](../project-principles.md)
- [LeanTTY milestones](../roadmap.md)
- [OpenSSH `sftp` 手册](https://man.openbsd.org/sftp.1)
- [OpenSSH `scp` 手册：未采用命令名的兼容性对照](https://man.openbsd.org/scp.1)
- [OpenSSH `progressmeter.c`：80 列默认宽度与 1 秒更新间隔](https://github.com/openssh/openssh-portable/blob/master/progressmeter.c)
- [curl 进度表：百分比、速度与时间字段](https://curl.se/docs/tutorial.html#Progress-Meter)
- [GNU Wget 进度类型：ASCII bar 与非 TTY dot](https://www.gnu.org/software/wget/manual/wget.html#index-progress_002dtype)
- [aria2 console readout：完成量、速度与 ETA](https://aria2.github.io/manual/en/html/aria2c.html#console-readout)
- [rsync `--progress`：速度、ETA 与完成摘要](https://download.samba.org/pub/rsync/rsync.1)
- [SFTP v3 rename：目标存在属于错误](https://datatracker.ietf.org/doc/html/draft-spaghetti-sshm-filexfer-00)
- [OpenSSH `sftp-server` 当前无覆盖 rename 实现](https://github.com/openssh/openssh-portable/blob/master/sftp-server.c)
- [rsync 官方手册：更新、跳过和备份已有目标](https://download.samba.org/pub/rsync/rsync.1)
- [GNU Wget 手册：重复下载编号与 `--no-clobber`](https://www.gnu.org/software/wget/manual/wget.pdf)
- [curl 手册：`--no-clobber` 与 `--skip-existing`](https://curl.se/docs/manpage.html)
- [Panic Transmit：上传和下载的冲突处理](https://help.panic.com/transmit/transmit5/transfers/)
- [Chromium：下载冲突使用扩展名前的数字计数器](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/download/internal/common/download_path_reservation_tracker.cc)
- [Chromium Downloads API：`uniquify` 冲突行为](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/common/extensions/api/downloads.webidl)
- [Apple：保留多个冲突版本时为额外版本增加数字](https://support.apple.com/guide/mac-help/mh40780/mac)
- [russh 0.62.5 SFTP client 示例](https://docs.rs/crate/russh/0.62.5/source/examples/sftp_client.rs)
- [`russh-sftp` 2.4.0 文档](https://docs.rs/russh-sftp/2.4.0/russh_sftp/)
- [`russh-sftp` `SftpSession`：create、open flags 与 rename](https://docs.rs/russh-sftp/2.4.0/russh_sftp/client/struct.SftpSession.html)
- [HarmonyOS 文件授权持久化](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/native-fileshare-guidelines)
- [HarmonyOS 应用隐私保护](https://developer.huawei.com/consumer/cn/doc/doccenter-architecture/bpta-app-privacy-protection)

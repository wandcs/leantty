# 远端光标与会话隔离诊断（2026-09-23）

状态：受控样本调查；维护者现场尚未复现，不能称为产品修复完成。

## 问题与判断边界

维护者观察到远端使用时仍是短竖线，要求本地保留默认光标、活跃 SSH/远端应用尊重
服务器控制，并避免旧服务器的光标配置延续到本地、下一服务器或其他 Pane。
这沿用 [Session 状态隔离合同](terminal-session-state-isolation.md)，不增加 Vim 识别、
强制块状光标或新的兼容分支。正式发布验收继续暂停，本轮仅零模型定向诊断。

首个待区分假设：远端已经发出形状序列，但原生 VT 或绘制持续覆盖为默认竖线。
最后已知正确边界是服务器输出，下一步同时观察实际 Vim 的 PTY 序列和真机像素，
以区分未发送、解析错误、绘制错误。光标协议由每个 Pane 的 Ghostty VT 持有；
SessionViewModel 管理远端输出所有权，TerminalSurfaceController 负责退出重置。

## 源码与主源

- `TerminalRuntime::create` 只在新 VT 初始化默认 bar/blink；活跃输出交给 Ghostty。
- `TerminalRenderer::paint` 读取 VT 的形状、闪烁和可见状态；失焦时画空心光标。
- `finishSessionTerminalOwnership` 先拒绝旧远端输出并推进 generation，再执行统一
  reset，定位后写本地输出，等待消费完成才解除输入门禁。正常关闭和 SSH error 共用此链。
- reset 包含 `CSI 5 SP q` 和显示光标；不以新建终端或删除历史实现隔离。
- [Ghostty DECSCUSR 文档](https://ghostty.org/docs/vt/csi/decscusr) 定义 1–6 为具体
  形状/闪烁，0 为终端配置的默认值。不能把 0 当作所有终端都必须显示块状。
- [Vim 官方终端说明](https://github.com/vim/vim/blob/master/runtime/doc/term.txt)
  `termcap-cursor-shape` 说明 `t_SI`、`t_SR`、`t_EI` 控制终端插入、替换和返回普通模式。
  这些不是标准 terminfo 项；`t_EI` 未设置时，另外两项也不会发送。
  [实际实现](https://github.com/vim/vim/blob/master/src/term.c) 的 `term_cursor_mode`
  在此条件下返回。因此不能仅依据 `guicursor` 的文本值认定终端已请求模式形状。

## 固定样本与可核对证据

产品源码为 PR #231 合入 `45b3aef47cf3b58e37809a95e13ddcf533d0933f`。
复用无计时探针的签名开发包，SHA-256
`c283aec95f9eb50826cb8d55bc3730b49fb090f279d87c52e341a8022a970b1b`。
本轮没有修改产品代码或构建新的 HAP。

本地证据根目录：`build/verification/remote-cursor-20260923/`。
诊断复用现有 OpenSSH 零模型入口的隔离 Tab、连接、输入确认和 finally 清理，
命名扩展只保留在忽略目录；不作为正式工具资格。服务器为默认 WSL 中的独立临时
OpenSSH，`TERM=xterm-256color`，Vim 9.1（补丁 1–948、950–2141）。不读取或修改
维护者的 `.vimrc`，受控配置和文件只在本轮临时目录。

`baseline/result.json` 记录过程与清理通过，`baseline/captures/` 保存白名单模式序列、
Vim 选项和模式标记。屏幕帧、原生 Pane 布局与 `cursor-pixels.json` 独立保存，按光标
颜色统计真实像素，不能仅从脚本退出码推导视觉通过。

| 场景 | 远端事实 | 真机结果 |
| --- | --- | --- |
| 直接发送 DECSCUSR 1–6 | 请求块状、下划线、竖线及闪烁/常亮 | 分别为 18×40、18×2、2×40 像素；奇数样本含亮/灭帧，偶数连续可见 |
| 原始 Vim 终端配置 | `t_SI/t_EI/t_SR` 都为空；进入插入/替换不发形状序列 | 保留进入前的竖线 |
| 同一 Vim 明确配置 6/2/4 | 插入请求竖线、离开插入请求块状、替换请求下划线 | 插入竖线、返回普通块状、替换下划线 |
| SSH 结束前远端保持常亮块状 | 结束远端 Session | 本地提示符恢复 2×40 竖线 |

首轮 Vim 的模式/序列元数据在截图前采集；Esc 可能在 Vim 自身的等待期结束后才生效，
因此 `normal-return` 的早期模式标记不是最终屏幕状态。该阶段以四帧一致的块状像素
证明显示，不能把早期序列列表当完整 PTY 记录。原始 PTY 内容不保留。
首轮重连的四帧均未采到光标亮相，单凭它们不能证明重连后的形状；后续使用不等间隔
采样补齐生命周期检查，不改写首轮证据。

`lifecycle/` 的新 Pane 亮/灭帧为默认竖线，关闭该 Pane 后原远端块状仍为 18×40。
该轮随后在断连命令提交前发现输入快照 16/15 字符不一致，Enter 为 0，整轮保持
`invalid/interrupted`。清理遗漏的自有临时信任由独立一次删除补齐，见
`lifecycle-supplemental-cleanup.json`；不能声称原脚本自行完整清理。

`lifecycle-r2/` 关联原 attempt，只补未完成生命周期。断连动作在本轮自有服务器内
预置成固定函数，仍通过 Readline 确认后单次触发；不修改产品输入或放宽输入检查。
实际 SSH 连接异常关闭为 `exitCode=-1`，统一 reset 完成；本地与随后重连均出现
2×40 竖线亮/灭帧。再将第一台服务器设置为下划线后正常退出，同一 Pane 连接第二个
独立 sshd（不同端口、不同临时 Host Key）：默认竖线不继承前者下划线，其自身的
块状控制有效，退出后本地再次恢复闪烁竖线。

22 项具名像素核对保存为 `pixel-checks.json`，只表示受控观察，不晋升为整轮正式
验收。`lifecycle-r2/result.json` 与第二服务器清理记录通过，最后的
`final-resource-audit.json` 独立确认三轮夹具进程/目录不存在、HDC 映射为空、原 Tab、
通知设置和屏幕策略恢复，设备已释放。全部使用同一包，零模型请求。

## 回归覆盖

扩展既有 `runtime-test.cpp`，将真实生产 reset 序列送入固定 Ghostty 和 C++ worker：
主屏及 47/1047/1049 三种备用屏入口 × 六种远端形状，叠加隐藏光标后都恢复可见
闪烁竖线；下一 PTY 的 DECRQSS 查询返回 `5 q`，下一次进入备用屏仍干净，另一个
Pane 的远端下划线保持不变。`terminal-native` 三项检查通过，证据
`software-native.json`，不要求 GPU，也不替代像素观察。

扩展现有 `test-terminal-session-events.cjs`，执行实际 Session/Surface 回调：正常退出
和错误退出都撤销旧远端 owner，等重置定位后才写本地输出；重置前后迟到的远端字节
均被拒绝。8 项合同通过，另有受影响源码政策检查。仅增加合同证据，不改变产品字节。

## 当前结论与剩余缺口

已反驳受控样本中的“本地默认持续覆盖远端形状”假设。真实协议和明确配置的 Vim 能
改变原生显示；原始 Vim 的空终端选项能解释该受控样本为何保持竖线。
这不是维护者现场的根因结论；仍需现场 Host、SSH/Mosh、Vim/Neovim 和配置事实。
没有失败反例就不制造产品补丁。后续只针对新事实定位，不重复已通过的六样式矩阵，
也不扩大正式验收或消耗模型请求。

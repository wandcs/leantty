# Known Hosts 单一文件权威

2026-09-23，维护者接受卸载后不再恢复主机信任，以移除普通增删中约 2.8 秒的 Asset
读写等待；明确作为狭义版本例外纳入未发布 1.7.0。config、密钥对和字号仍使用 Asset。
活动工作和验证状态只在 [Next Work](../next-work.md) 维护。

## 所有权与迁移

`DurableStateManager` 保留单一串行事务队列；`KnownHostsFile` 只隔离平台文件边界。
普通读取、新增及 `ssh-keygen -R/-F` 使用私有 `.ssh/known_hosts`，不再双写 Asset，
也不增加内容缓存。读取只有明确的文件不存在才返回空，其他失败向上层传播。

第一次需要 SSH 时，在同一队列内读取并校验旧 Asset，先提交文件，再删除旧指针，
最后删除该路径剩余记录；确认全部清退前不放行信任增删。失败后保留错误并允许重试：
文件失败时旧 Asset 尚在；指针已删除但清理失败时文件已经同步，下次不以空值覆盖。
旧的、从未进入 Asset 的本地文件也保留。正常重启不重建信任投影，删除后不复活。

旧包没有足以可靠区分“投影失败的升级安装”和“旧包卸载后首次安装”的标记，不能用
文件缺失来丢弃已提交信任。因此第一次版本切换也可能迁入旧卸载留下的数据；完成
清退后，后续卸载重装不恢复信任。该一次性边界已经统筹审阅接受，不建安装身份层。
旧版回退不属于该迁移合同；不为回退重建 Asset 双写。

## 文件提交与安全边界

在应用私有目录创建临时文件，检查写入字节数，`fsync` 文件、关闭、同目录 `rename`，
再同步 `.ssh` 及其父目录。完整事务成功后才能放行 SSH/给出删除成功。若 rename 后的
目录同步失败，明确报告失败；先前明确批准的决定可能已经可见，不伪称回滚。
临时文件不作为信任读取来源，失败清理不会删除旧的正式文件。

平台依据：[CoreFileKit API](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/reference/apis-core-file-kit/js-apis-file-fs.md)
声明文件同步接口；上游 [rename](https://github.com/openharmony/filemanagement_file_api/blob/master/interfaces/kits/js/src/mod_fs/properties/rename.cpp)
和 [fsync](https://github.com/openharmony/filemanagement_file_api/blob/master/interfaces/kits/js/src/mod_fs/properties/fsync.cpp)
实现调用 libuv 对应文件系统操作。采用该平台边界，不承诺对故障硬件或任意掉电时序
作穷尽证明；实际目标设备的目录打开/同步、替换和恢复已由下述定向场景验证。

公钥并非私钥，但主机名/IP 属于用户数据。使用系统应用隔离及文件 owner/group 权限，
不描述为 Asset 加密。当前 SDK 没有 CoreFileKit `chmod`，不为公钥文件扩大 native API；
平台 [open 实现](https://github.com/openharmony/filemanagement_file_api/blob/master/interfaces/kits/js/src/mod_fs/properties/open.cpp)
使用 owner/group 读写模式。升级前目标机文件为 0660、目录为 0770，属同一应用 UID/GID；
未放到公共 Downloads，也不改系统权限。

## 软件证据与验证边界

34 项实际所有者/平台替身测试覆盖迁入、损坏拒绝、文件与清退失败、重试、其他资产
隔离、并发增删、短写/同步/重命名失败、删除后重启及模拟安装数据清除、SSH/Mosh/
传输等待提交和取消。平台替身不代替设备证据。

14 项受影响 `policy,arkts` 检查及离线指南检查通过。第一次编译发现不存在的 `chmod`
接口，已移除；随后补齐目录同步的异常传播。保留 47 条既有警告；将两处旧 Asset 同步
调用行号还原后，警告摘要与旧基线完全相同，因此只更新行号指纹，不新增警告豁免。
记录位于本地忽略的 `build/verification/known-hosts-file-20260923/`，早期失败保留。

首次真机迁移在文件提交及指针删除之后失败。临时阶段探针定位剩余分片按 critical-label
条件删除返回 401；上游 [JS 删除参数检查](https://github.com/openharmony/security_asset/blob/master/frameworks/asset/js/napi/src/asset_napi_remove.cpp)
的 `CheckRemoveArgs` 未包含 critical-label 白名单。修复复用带 namespace/path 的分页查询，
收集别名后逐条删除；先收集再删除避免偏移分页漏项。失败不当成清理完成，指针消失后
也继续扫描该路径的孤立分片。测试替身增加真实参数拒绝、跨页残留和枚举失败反例。

设备证据记录最终包摘要、既有 10,659 字节信任迁移、增删/重启/重连与清理。
前后耗时采用同一个零模型场景、最终无探针包的交互往返时间，包含注入/观察成本，
不能与旧探针内部提交耗时混为同一指标。真实卸载可能破坏无关工作区；只有可安全
保存与恢复时执行，否则明确列为未验证，不用软件模拟或重启冒充卸载验收。

## 清退后日常使用：已取得的设备证据

最终无临时探针包 SHA-256：
`6d8a4efe5dff37e87927880cf6470631080558e4224a4219c4f174925d78cc92`。
`file-authority-steady/result.json` 的零模型 SSH 前置场景及清理通过。在相同原始
10,659 字节数据和同一观测方法下，信任确认到连接完成由 3962 ms 降至 620 ms；
删除命令输入到完成观察由 11265 ms 降至 8591 ms。后者包含自动输入和观察成本，
不能当作产品文件删除耗时，也不与先前内部 Asset 提交计时直接比较。

早期失败仍保留：修复后的一个无探针进程曾持续停在 SSH 准备，其具体等待边界未知。
随后一次临时阶段诊断证明该时点旧指针/分片均不存在，新进程准备约 374 ms 返回。
稳态通过不证明首次迁移链完整通过；后续另行执行下述维护者批准的首次迁移补证，
没有增加产品重试、后备路径或延长超时，也不将早期失败改写为原因已定位。

同包九项生命周期检查及清理通过：保存 Host/公钥认证、重启保留、身份删除后回退、
恢复绑定，以及信任删除后立即和重启重连均要求重新确认，明确接受后恢复连接。
`lifecycle/device-host-identity.json` 保留逐项结果。无新模型请求。

早期文件缺失验证未取得真机前提：第一次临时脚本未检查移动输出，随后一次 checked
应用作用域调用明确返回 Permission denied；两次均保留未验证结论，没有修改权限、
新增平台适配或再试。原信任文件始终保留原摘要和长度；备份路径不存在。最终无探针
App 已启动，两个 Tab、焦点和空反向映射已审计，临时日志采集已停止。这两次不声明
文件缺失通过；后续应用内受控入口的独立证据见下节，真实整包卸载始终未执行。

## 首次迁移和文件缺失补证

维护者批准 25–40 分钟有界补证后，21:41–21:56 实际约 15 分钟完成准备、三种一次性
工具构建及设备操作。应用内工具约 60 行，产品代码无额外增量；恢复包预先构建，
只访问 `ssh/known-hosts` 记录及其私有文件、备份和一次性标记，不写其他 Asset，
不改权限。工具源码、备份及原始运行证据不进入公共提交。

1. 首次启动曾被锁屏拒绝（10106102、PID 空、标记/备份缺失），未执行种子；复用
   项目既有解锁入口后，只生成一次 12 条旧记录（11 个分片和指针），内容仍为原
   10,659 字节/SHA。先同步原内容备份，再移除正式文件，读回确认缺失。
2. 安装上述最终无探针包并首次启动（PID 16998）。布局传输失败发生在查询提交前；
   正式文件已恢复原摘要。没有再次造数据、重装或重启；在同一 PID 使用已支持的
   相对布局路径提交尚未执行的只读查询，获得 `known-host-command-completed`。
3. 独立审计确认 namespace/path 对应记录数为零、指针为空、正式文件与原摘要一致。
   此审计不执行迁移或删除旧记录，因此不代替最终包消耗种子的首次迁移证据。
4. 同一受控工具保留已校验备份并移除正式文件；再次启动最终无探针包，查询完成且
   文件仍缺失，证明清退后的旧信任未复活。恢复工具随后恢复原摘要、核对 records=0，
   移除标记/备份；再次换回最终无探针包后只读查询完成，原文件摘要一致。

本地证据：`migration-seed-unlocked-result.json`、`first-same-process-input.json`、
`migration-absence-result.json`、`migration-absent-final-result.json`、
`migration-restore-result.json`、`migration-restored-final-result.json` 及对应限定日志。
首次包的环境失败报告 `migration-first-result.json` 原样保留；成功由同进程补充证据
和只读审计共同支持，不覆盖失败报告。启动/查询日志按 PID 和时间区分，诊断包主动
阻止 SSH 准备的历史警告不算最终包错误。原信任 SHA-256：
`718a9c22652ce902f414f18d87e7afcd05935357285f56928c35cc127eb0f21b`。

# LeanTTY 文档入口

> 更新日期：2026-08-22

`docs/` 根目录保留当前规则、用户契约、版本路线、跨版本验收、唯一工作清单和稳定
工程手册；`design/` 为每个大的功能点保存一份专项技术方案。私有证据和机器记录不
进入仓库。

## 阅读顺序

| 顺序 | 文档 | 用途 |
|---:|---|---|
| 1 | [`project-principles.md`](project-principles.md) | 最高层产品定位、功能边界和技术规则 |
| 2 | [`roadmap.md`](roadmap.md) | 当前与后续 milestone 的用户结果、范围和进入条件 |
| 3 | [`vision-acceptance.md`](vision-acceptance.md) | 跨 milestone 核心质量门禁和愿景结果验收 |
| 4 | [`next-work.md`](next-work.md) | 唯一有效的 TODO、依赖顺序和当前完成定义 |
| 5 | [`design/README.md`](design/README.md) | 单功能技术方案、WIP 状态和方案模板 |
| 6 | [`coding-guide.md`](coding-guide.md) | 所有权、编码边界、Agent 可维护性和日常验证约束 |

## 用户与工程基线

| 文档 | 用途 |
|---|---|
| [`user-guide.md`](user-guide.md) | 当前源码的用户模型、命令、交互、数据保留和恢复方法 |
| [`architecture.md`](architecture.md) | 当前组件、所有权、事件链、生命周期和持久状态架构 |
| [`security-model.md`](security-model.md) | 受保护资产、信任边界、残余风险和安全证据要求 |
| [`quality-strategy.md`](quality-strategy.md) | 所有开发必须遵守的回归流程、测试层级、真机自动化和证据门禁 |
| [`test-release-efficiency.md`](test-release-efficiency.md) | 测试与发布耗时原因、减重边界、候选方向和效果度量 |
| [`promotion-playbook.md`](promotion-playbook.md) | 推广工作目录、逐项全网调研门禁、执行建议和完成证据 |

## 稳定手册与合规文件

| 文档 | 用途 |
|---|---|
| [`dev-environment.md`](dev-environment.md) | 工具链、SDK、依赖和目标环境 |
| [`release-process.md`](release-process.md) | 发布分支、构建、签名、提审、tag 和校验程序 |
| [`versioning.md`](versioning.md) | 版本号、分支、Unreleased 和商店审核规则 |
| [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) | 静态资源、Rust 和 ArkTS 依赖声明 |

根目录 [`../PRIVACY.md`](../PRIVACY.md)、[`../SECURITY.md`](../SECURITY.md)、
[`../SUPPORT.md`](../SUPPORT.md) 和 [`../CONTRIBUTING.md`](../CONTRIBUTING.md) 分别负责
公开隐私、安全报告、支持和贡献边界。

`OFL-1.1.txt` 是字体许可证正文，`assets/icon.svg` 是图标源文件，必须保留。
被拒绝且未发布的 1.0.0 历史由根 `README.md`、`CHANGELOG.md`、不可变标签和仓库外
私有发布证据共同记录。

## 文档规则

1. [`project-principles.md`](project-principles.md) 是最高规则；[`roadmap.md`](roadmap.md)
   只维护 milestone；[`vision-acceptance.md`](vision-acceptance.md) 维护跨版本质量与愿景
   验收；[`next-work.md`](next-work.md) 是唯一活动 TODO。
2. 功能范围和 milestone 状态以 [`roadmap.md`](roadmap.md) 为准，版本变更与公开交付
   事实以根 [`CHANGELOG.md`](../CHANGELOG.md) 为准，实施与验证完成事实以已经合并的
   Pull Request 为准。三者出现冲突时，检查当前代码和测试来裁决技术实现状态；代码、
   测试包或本地构建不能单独证明 GitHub Release 或 AppGallery 已发布。其他方案、手册
   和历史记录不得反向覆盖这三类权威来源。
3. 每个大的功能点在 [`design/`](design/README.md) 中最多保留一份当前技术方案；WIP
   方案可以记录待讨论和待验证内容，但不授权实现，也不得复制任务勾选。
4. 当前源码手册默认描述 `main` 中 `Unreleased` 或已选择版本的 `In development` 行为，
   正式版行为以对应 GitHub Release、Changelog 和明确标注的适用版本为准；WIP、Roadmap
   和 Next Work 不得写成已交付。
5. 当前手册只描述稳定事实和执行方法，不混入活动 checkbox 或单次验证状态。
6. 首次公开前的私有归档不进入公开仓库；完成或被取代的公开方案通常从当前树
   删除，通过 Git 历史追溯。
7. [`archive/`](archive/README.md) 只保留归档政策和确有长期证据价值的例外材料；
   归档内容不自动恢复为当前任务。
8. 删除或移动文档时同步修正当前文档引用。

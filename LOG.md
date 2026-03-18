# iostmux - 操作日志

## 2026-03-18
- 08:59 [project-new] 创建项目 (area: coding)
- 08:59 设计文档已完成: docs/superpowers/specs/2026-03-17-iostmux-design.md
- 08:59 实施计划已完成: docs/superpowers/plans/2026-03-18-iostmux-implementation.md (12 tasks)
- 10:23 [project-adhoc] 计划外: 修改 /project-next 技能 + 创建 /auto-gtd 技能
  - project-next: Research 阶段新增 Step 2a-2，自动检查 docs/superpowers/plans/ 下的实施计划并作为拆子任务依据
  - auto-gtd: 新建技能，全自动连续推进 GTD 项目（循环调用 /project-next）
  - 起因: iostmux 项目有 superpowers plan，需确保后续 /project-next 拆子任务时参照 plan
- 10:43 [project-next] 完成「Xcode 项目搭建 + 依赖集成」, 设置 NEXT=SSH 服务层
  - xcodegen 生成项目，SwiftTerm + Citadel 依赖编译通过
  - [决策] SSH 库从 SwiftSH 改回 Citadel（SwiftSH 不支持 SPM）
- 11:30 [project-next] 完成「SSH 服务层」, 设置 NEXT=项目列表页
  - SSHService: connect + executeCommand + fetchProjects + withTTY shell
  - Citadel withTTY 替代 withPTY（PseudoTerminalRequest init 为 internal）
  - Swift 6 strict concurrency 降级为 Swift 5（v1 快速原型）
- 11:32 [project-next] 完成「项目列表页」, 设置 NEXT=终端视图
- 11:37 [project-next] 完成「终端视图」, 设置 NEXT=输出过滤状态机

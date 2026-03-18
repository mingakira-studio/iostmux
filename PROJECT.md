# iostmux — iOS Claude Code Session Viewer

## Meta
- **Area**: coding
- **Path**: ~/Projects/iostmux
- **Created**: 2026-03-18
- **Status**: active

## 目标
在 iPhone 上通过 SSH（Tailscale）连接 Mac Studio，浏览项目列表并接入 Claude Code tmux session。优化阅读体验（过滤工具调用细节），语音优先输入，后台检测 Claude 空闲并推送通知。

## 设计原则
- 快速完成，v1 功能最小化
- iOS 原生风格（SwiftUI，跟随系统配色）
- 语音为主，键盘为辅（手势呼出）
- 阅读优化：隐藏开发细节，只显示 Claude 文字回复

## 任务大纲

- [>] Xcode 项目搭建 + 依赖集成（SwiftTerm, SwiftSH）
  - [ ] 创建 Xcode 项目，配置 iOS 17+, portrait only
  - [ ] 添加 SwiftTerm SPM 依赖
  - [ ] 添加 SwiftSH SPM 依赖
  - [ ] 创建 Config.swift 硬编码 SSH 参数
  - [ ] 验证 build 通过
- [ ] SSH 服务层（SSHService: 命令执行 + 交互 shell）
- [ ] 项目列表页（ProjectListView: 目录列表 + session 状态）
- [ ] 终端视图（SwiftTerm UIViewRepresentable + SessionView）
- [ ] 输出过滤状态机（compact/raw 双缓冲切换）
- [ ] SSH Key 认证 + Keychain 存储 + 首次设置页
- [ ] 用户输入接线 + PTY 尺寸协商
- [ ] 语音输入（Speech framework, 中英自动识别）
- [ ] 手势键盘（底部上滑呼出，特殊键 + 快捷命令）
- [ ] 断线重连（3 次自动重试 + 手动重连按钮）
- [ ] 后台 Claude 空闲检测 + 本地通知
- [ ] 最终打磨 + 全设备测试

## 操作指南

### 工作流提醒
- 完成子任务的实际工作后 → 主动提醒用户: "子任务「xxx」已完成，要标记吗？(/project-done)"
- 所有子任务完成后 → 自动触发 /project-next
- 遇到阻塞/方案变更 → 记录到「项目备忘」并告知用户

### 项目备忘
<!-- 项目过程中的问题、决策、解决方案 -->
- 设计文档: docs/superpowers/specs/2026-03-17-iostmux-design.md
- 实施计划: docs/superpowers/plans/2026-03-18-iostmux-implementation.md
- SSH 库从 Citadel 改为 SwiftSH（Citadel 不支持交互式 shell）
- SwiftSH 可能较旧，如编译不过需 fork 或换 libssh2 直接绑定
- [adhoc] 修改了 /project-next 技能（Step 2a-2: 自动检查 superpowers plan）和新建了 /auto-gtd 技能

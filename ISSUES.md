# iostmux - Issues

## 问题 (Issues)

| ID | 来源 | 描述 | 原计划 | 新方案 | 状态 | 日期 |
|----|------|------|--------|--------|------|------|
| I-001 | brainstorming | Citadel 不支持交互式 shell/PTY | 用 Citadel (SwiftNIO SSH) | 改用 SwiftSH (libssh2) | superseded by I-002 | 2026-03-18 |
| I-002 | project-next | SwiftSH 无 Package.swift，不支持 SPM | 用 SwiftSH (libssh2) | 改回 Citadel，交互 shell 问题后续用底层 SwiftNIO SSH channel 解决 | resolved | 2026-03-18 |

## 决策 (Decisions)

| ID | 来源 | 描述 | 原方案 | 新方案 | 状态 | 日期 |
|----|------|------|--------|--------|------|------|

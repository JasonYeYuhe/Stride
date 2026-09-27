# Code Review TODO (Gemini + Codex Combined)

Based on reviews from Gemini (2.5 Pro) and Codex on 2026-04-01.

## Critical

- [ ] **1. 移除脚本中硬编码的 API 密钥** (Codex)
  - Files: `scripts/asc_api.py`, `setup_iap.py`, `push_metadata.py`
  - API_KEY_ID, ISSUER_ID 硬编码在代码里，改为从环境变量或 `.env` 读取
  - 确保 `.gitignore` 包含这些敏感文件

- [ ] **2. 修复 /login 页面 XSS 风险** (Codex)
  - File: `server/index.js` (~line 95)
  - token 的 sanitization 用 strip 而不是 escape，应该用 HTML entity encoding
  - 考虑用 `he.encode(token)` 库

- [ ] **3. 修复 Helmet 安全中间件 bypass** (Gemini + Codex)
  - File: `server/index.js` (~line 9-12)
  - /login 路由完全跳过了所有 Helmet headers，应只禁用必要的 CSP directive
  - Codex 指出 login 页面实际上没有 inline JS，bypass 可能完全不必要

## High

- [ ] **4. Session token 存储前需验证** (Codex)
  - File: `Stride/Sources/Services/AuthService.swift` (~line 65-69)
  - `loginWithSessionToken()` 直接存 Keychain 没做任何验证
  - 添加格式校验，确保 `checkSession()` 失败时清除 token

- [ ] **5. 检查 CJK metadata 编码是否正确** (Codex)
  - Files: `metadata/ja/`, `ko/`, `zh-Hans/`, `zh-Hant/` description.txt
  - 韩文文件疑似有编码损坏，需要手动确认内容可读性

## Medium

- [ ] **6. ModelContainer fallback 静默切换问题** (Codex)
  - File: `Shared/SharedModelContainer.swift` (~line 26-31)
  - fallback 到默认位置会导致用户数据"消失"，至少要加 log

- [ ] **7. StoreService retry 逻辑优化** (Codex)
  - File: `Stride/Sources/Services/StoreService.swift` (~line 50-74)
  - 固定 2s delay 改为 exponential backoff
  - 检查 `Task.isCancelled`，不要吞掉 cancellation

- [ ] **8. 确认 loadError 的观察机制** (Codex)
  - File: `Stride/Sources/Services/StoreService.swift` (~line 36)
  - 如果用 `ObservableObject` 需要加 `@Published`，`@Observable` 则没问题

- [ ] **9. OnboardingView 手势改进** (Gemini + Codex)
  - File: `Stride/Sources/Views/OnboardingView.swift` (~line 58-66)
  - 自定义 DragGesture 缺少交互式拖拽跟踪、边缘回弹、VoiceOver 支持
  - 考虑 iOS 用 TabView(.page)，macOS 用自定义方案

- [ ] **10. 移除 asyncAfter hack** (Codex)
  - File: `Stride/Sources/Views/OnboardingView.swift` (~line 161-164)
  - 用 `withAnimation` 替代 `DispatchQueue.main.asyncAfter`

## Low

- [ ] **11. .gitignore 清理** (Codex)
  - 添加: `__pycache__/`, `*.db-shm`, `*.db-wal`, `Stride *.xcodeproj/`
  - 删除多余的 `Stride 3/4/5.xcodeproj/` 目录

- [ ] **12. metadata 文件末尾换行符** (Codex)
  - 所有 `description.txt` 和 `keywords.txt` 缺少 trailing newline

- [ ] **13. 西班牙语描述多余前导空格** (Codex)
  - File: `metadata/es-ES/description.txt`
  - emoji 移除后 section headers 前有多余空格

- [ ] **14. 确认 keywords 删减合理性** (Codex)
  - 各语言 keywords 都删了一个词，确认删的是最低价值的

## Backlog

- [ ] **15. 添加 Service 层测试** (Gemini + Codex)
  - StoreService, AuthService 的核心逻辑需要测试覆盖
  - 用 mock protocol 测试 retry、auth flow

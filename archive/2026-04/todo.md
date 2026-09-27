# Code Review TODO

Based on reviews from Gemini (2.5 Pro) and Codex on 2026-04-01.
Reviewed and validated by Claude on 2026-04-01.

## Critical

- [x] **1. 移除脚本中硬编码的 API 密钥**
  - Files: `scripts/asc_api.py`, `setup_iap.py`, `push_metadata.py`
  - API_KEY_ID, ISSUER_ID 改为从环境变量或 `.env` 读取
  - 添加 `scripts/.env.example`，`.gitignore` 加上 `scripts/.env`

- [x] **2. 修复 /login 页面 XSS 风险**
  - File: `server/index.js` (line 98)
  - token 的 sanitization 用 strip (`replace(/[<>&"']/g, '')`) 而不是 escape
  - 改用 HTML entity encoding

- [x] **3. 修复 Helmet 安全中间件 bypass**
  - File: `server/index.js` (line 12-15)
  - /login 路由完全跳过了所有 Helmet headers，应只禁用必要的 CSP directive
  - login 页面没有 inline script，只需放宽 inline style

## High

- [x] **4. Session token 存储前需验证**
  - File: `Stride/Sources/Services/AuthService.swift` (line 66-68)
  - `loginWithSessionToken()` 直接存 Keychain 没做任何验证
  - 添加格式校验，`checkSession()` 失败时清除 token

- [x] **5. 修复 CJK metadata 编码损坏** (比原 review 更严重)
  - Files: `metadata/ko/`, `ja/`, `zh-Hans/`, `zh-Hant/` description.txt
  - 所有 4 个 CJK 文件都被损坏：emoji 移除过程同时删除了所有 CJK 字符
  - 需要从 git 恢复原文，正确移除 emoji，重新添加订阅信息

## Medium

- [x] **6. ModelContainer fallback 静默切换问题**
  - File: `Shared/SharedModelContainer.swift` (line 26-31)
  - fallback 到默认位置会导致用户数据"消失"，至少要加 log

- [x] **7. StoreService retry 逻辑优化**
  - File: `Stride/Sources/Services/StoreService.swift` (line 56-84)
  - 固定 2s delay 改为 exponential backoff
  - 检查 `Task.isCancelled`

- [x] **8. 确认 loadError 的观察机制** ✅ 已确认无问题
  - File: `Stride/Sources/Services/StoreService.swift` (line 38)
  - 使用 `@Observable` 宏，不需要 `@Published`，机制正确

- [x] **9. OnboardingView 手势改进**
  - File: `Stride/Sources/Views/OnboardingView.swift` (line 61-69)
  - 添加 VoiceOver accessibility actions

- [x] **10. 移除 asyncAfter hack**
  - File: `Stride/Sources/Views/OnboardingView.swift` (line 164)
  - 用 `withAnimation` 替代 `DispatchQueue.main.asyncAfter`

## Low

- [x] **11. .gitignore 清理**
  - 添加: `__pycache__/`, `*.db-shm`, `*.db-wal`, `Stride *.xcodeproj/`, `scripts/.env`
  - 删除多余的 `Stride 3/4/5.xcodeproj/` 目录

- [x] **12. metadata 文件末尾换行符**
  - 所有 `description.txt` 和 `keywords.txt` 缺少 trailing newline

- [x] **13. 西班牙语描述多余前导空格**
  - File: `metadata/es-ES/description.txt`
  - emoji 移除后 section headers 前有多余空格

- [x] **14. 确认 keywords 删减合理性** ✅ 已确认合理
  - 各语言删除的均为最低价值关键词（en: discipline, ja: 習慣化+ヒートマップ, ko: 작심삼일, zh: 早起）
  - 删减后仍在 100 字符限制内

## Backlog (跳过)

- [ ] **15. 添加 Service 层测试**

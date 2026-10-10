# Stride — 交接 prompt（复制整段发给新会话）

你接手 Stride（iOS/macOS 习惯追踪 App，SwiftUI + SwiftData；Node/Express + SQLite 后端在一台 Azure VM 上）的开发。仓库在 `~/Documents/Stride`。你全权负责，按下面的顺序做，不要每一步都来问我；只有在动到用户数据、签名/凭据、或者要提交审核时才需要我点头。

## 现在的状态（2026-10-10）

- **1.3.0（build 19）已上架** iOS + macOS（M1），tag `v1.3.0`；PR JasonYeYuhe/Stride#4 已于 2026-10-03 合并进 `main`。
- **1.3.1 的服务端部分已部署到生产**（2026-09-29 16:25 UTC，服务端代码树 `5dca011`），验收 (7) 已在生产上验证。内容：毫秒级 pull、LWW re-feed、id aliases、`deletionsSince`、对 1.3.1 以下旧 App 扣住"删除+同日替换"、`no-store` 响应头、tombstone 两个新列、365 天清扫下限。
- **1.3.1（M2，增量推送）build 21 已过审（两个平台）。**
  - iOS 已由我在 ASC 发布（READY_FOR_SALE，2026-10-10 确认）。Sentry 生产环境 7 天：1.3.1+21 有 8 个会话、5 台设备，0 崩溃。
  - **macOS 1.3.1 是 PENDING_DEVELOPER_RELEASE**：等我点头再 `release.py release 1.3.1`（或我在 ASC 点发布）。
  - 第三轮直接测试发现并修复了首启升级竞态：widget 和 App 同时迁移存储，导致 App 退回一个空 store。修复见 `ac1fbec` 和 `7ee5f8f`。用真实 1.2.3/1.3.0 构建原地升级 6 次全部通过。build 20 作废，从未提交。
  - PR JasonYeYuhe/Stride#6 已合并进 `main`，tag `v1.3.1`。
  - Codex 没有审到 1.3.1：额度用完，最后一次文件工具超时，我允许跳过。

## 先读什么（按顺序）

1. `RELEASE-1.4.0.md` —— M3 的进度记录（做了什么、审查改了什么、测试结果、还剩什么）。
2. `DEV-PLAN-1.3.md` —— 计划本体：M3 小节是规格，M2 小节末尾的 progress log 记录了同步设计的每个决定。`RELEASE-1.3.1.md` 是 M2 的完整记录（模拟器端到端的做法、已知限制）。
3. `RELEASE-1.3.0.md`，尤其是「Known limitations found after the resubmission」。
4. `server/DEPLOY.md` —— 部署五步：测试 → 主机 diff → 生产库副本演练 → 备份 → rsync + 验证。
5. 记忆目录 `~/.claude/projects/-Users-jason-Documents-Stride/memory/`（自动加载）。

## 接下来做什么：M3（1.4.0）

M3 = iPad/Mac 外壳、通知"完成"动作、后台同步，外加积压项"导出先写文件再弹分享面板"。DEV-PLAN-1.3.md 的 M3 小节就是规格。分支 `m3/1.4.0`，从合并后的 `main` 切出。进度记在 `RELEASE-1.4.0.md`。

1. **不需要 TestFlight，也不需要我做真机检查**（2026-10-07 起所有版本都省略）：由你自己测试。具体是模拟器端到端（`scripts/sim_e2e/`）、用真实旧版构建原地升级、在旧版 App 写出的 store 上跑真实容器迁移测试，以及 Release 构建冒烟。
2. 审查：Codex（额度够时）+ Gemini（MCP bridge，workspace 只能是一次性副本）。每条都要对照代码核实后再采纳。
3. 打包前的固定动作：
   - `scripts/sync_rehearsal.sh` 和 `scripts/check_demo_account.sh` 在要发布的构建上跑绿；
   - `verify_archive.sh --exported`；
   - 用 `release.py` 写六种语言的 What's New；
   - `build-appstore.sh all --upload`；
   - `release.py prepare <版本>`；
   - **发布门禁**：`scripts/sim_e2e/upgrade.sh`，从每个在用的旧版本（现在包括 1.3.1）原地升级，带 widget。
   - **提交（`release.py finish`）必须等我点头。**
   - 版本是 MANUAL 发布，过审后等我说再 `release.py release`。

## 已知的机器/流程陷阱

- **签名**：锁屏时 codesign 可能失败（`errSecInternalComponent`）。打包前先跑 `security show-keychain-info ~/Library/Keychains/login.keychain-db` 和一个 1 秒的 codesign 探测。
- **Xcode**：大版本更新后要重新接受许可，这只有我能做。
- **模拟器**：复用 iPhone 17 Pro / 17 Pro Max，其他项目也在用；用 `mkdir /tmp/lock-iphone-17-pro` 这类锁互斥。CoreSimulatorService 卡死时 `killall -9 com.apple.CoreSimulator.CoreSimulatorService`。未签名（`CODE_SIGNING_ALLOWED=NO`）的构建存不了 Keychain token：会显示"已登录"但从不同步，模拟器端到端要用 ad-hoc 签名（`CODE_SIGN_IDENTITY=-`）。
- **本地化**：
  - 运行时 key 规则：Int→`%lld`、String→`%@`、Double→`%lf`。
  - 复数用 `.stringsdict`，key 带 "(%lld held)" 这类后缀只用来选形式。
  - 插值里的三元表达式不会被翻译。
  - 界面代码用 `appLocalized` / `appCalendar`。
  - `LocalizationSourceScanTests` 认不出 `\(a.b.c)` 这种插值，要先赋给局部变量。
- **服务端 `.env`**：含 `<>`，不要 `source`。SSH 一律加 `-o IdentityAgent=none`。
- **审查工具**：
  - Gemini 用 gemini MCP bridge（`mcp__gemini__ask_gemini`），`workspace` 只能指向一次性副本目录，绝不能指向仓库，因为它会以 `--dangerously-skip-permissions` 运行。
  - 子 agent 可能因 API 用量上限中途停下：额度恢复后用 SendMessage 让它从原处继续，不要重开。
- **端到端的做法**：Debug 构建连 `localhost:3002`。起一个 `server/` 的副本（全新 DB、`NODE_ENV=test`、不带 `.env`），直接插入 `magic_link_tokens` 行，在 App 的"I have a login token"输入框粘贴 token 登录。上次的脚本套件在会话临时目录里，没进仓库；RELEASE-1.3.1.md 描述了做法。

## 需要我做的事（你做不了）

- 同意发布 macOS 1.3.1（PENDING_DEVELOPER_RELEASE）。
- Sentry：建 `stride-server` 项目，把 `SENTRY_DSN` 写进 `/root/stride-server/.env`，加 1 分钟的 uptime 监控（DEPLOY.md 有步骤）。
- 把 iCloud Drive `Downloads/` 里的两份 ASC `.p8` 移到 `~/Library/Application Support/CLI-Pulse-Secrets/`，再 `chmod 600 ~/private_keys/AuthKey_*.p8`。
- 可选：给 stride.colorarchive.me 加 DMARC 记录；`ssh-keygen -R 143.198.85.72`（旧 DO 主机已销毁，没有要清的）。
- ASC 首购优惠：已确认没有配置，无需处理。

先看 `RELEASE-1.4.0.md` 的进度，再接着做。

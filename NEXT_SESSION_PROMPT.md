# Stride — 交接 prompt（复制整段发给新会话）

你接手 Stride（iOS/macOS 习惯追踪 App，SwiftUI + SwiftData；Node/Express + SQLite 后端在一台 Azure VM 上）的开发。仓库在 `~/Documents/Stride`。你全权负责，按下面的顺序做，不要每一步都来问我；只有在动到用户数据、签名/凭据、或者要提交审核时才需要我点头。

## 现在的状态（2026-10-14）

- **1.4.0（M3，build 22）**，分支 `m3/1.4.0`，草稿 PR JasonYeYuhe/Stride#7，完整记录在 `RELEASE-1.4.0.md`：
  - **iOS 1.4.0 已上架**（READY_FOR_SALE）。新的商店截图（iPhone 6.9/6.5、iPad 13/12.9）和描述都已推送。
  - **macOS 1.4.0 已于 2026-10-14 提交审核**（提交 `e785e2d9…`，WAITING_FOR_REVIEW，MANUAL）。我说了"mac版本也发布"，所以**过审后直接 `release.py release 1.4.0 --platform MAC_OS`**，不用再问。然后合并 PR #7、打 tag `v1.4.0`（照 1.3.1 的先例：两个平台都过审后再合并和打 tag；Mac 若被拒要改代码，build 23 会来自新的提交）。
  - Mac 专属界面（菜单、⌘0、设置窗口、Dock 角标、恢复/导出面板、Mac 横幅动作）**始终没有实际跑过**：computer use 三次都被拒。提交前跑了一个只读的就绪检查（ASC 记录、归档、v1.3.1 以来的 Mac 改动），没有 blocker 或 major；Mac 的审核备注已改成 Stride > Settings…（⌘,）→ Account → Sign In。
  - 1.4.1 要跟进的小问题和 13 条 Mac 界面检查清单：`RELEASE-1.4.0.md` 的「Follow-ups for 1.4.1」。
  - Mac 商店截图仍是 1.3.1 的（侧栏里还有已移除的 Settings 行），更换需要我点头，并且要先实际跑一遍测试版。
- **1.3.1 两个平台都已上架**，PR #6 已合并，tag `v1.3.1`。
- **磁盘**：2026-10-11 曾满到 100%。见记忆 `feedback_disk_space`：每个会话只用一个 derived data 目录；trash 不释放空间；`$TMPDIR` 会被系统清理。

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

- Mac 界面检查（1.4.0 已提交，现在是补做）：允许 computer use 操作测试版 `yyh.stride.habittracker.mactest`，或者自己按 `RELEASE-1.4.0.md` 里的 13 条清单点一遍。
- Sentry：建 `stride-server` 项目，把 `SENTRY_DSN` 写进 `/root/stride-server/.env`，加 1 分钟的 uptime 监控（DEPLOY.md 有步骤）。
- 把 iCloud Drive `Downloads/` 里的两份 ASC `.p8` 移到 `~/Library/Application Support/CLI-Pulse-Secrets/`，再 `chmod 600 ~/private_keys/AuthKey_*.p8`。
- 可选：给 stride.colorarchive.me 加 DMARC 记录；`ssh-keygen -R 143.198.85.72`（旧 DO 主机已销毁，没有要清的）。
- ASC 首购优惠：已确认没有配置，无需处理。

先看 `RELEASE-1.4.0.md` 末尾的「Submission checklist」和「Follow-ups for 1.4.1」，再接着做：查 macOS 审核结果，过审后 `release.py release 1.4.0 --platform MAC_OS`，合并 PR #7，打 tag `v1.4.0`，然后进入 M4（`DEV-PLAN-1.3.md` 的 M4 小节，1.4.1），并把 1.4.1 跟进项并进去。

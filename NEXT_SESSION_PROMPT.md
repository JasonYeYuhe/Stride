# Stride — 交接 prompt（复制整段发给新会话）

你接手 Stride（iOS/macOS 习惯追踪 App，SwiftUI + SwiftData；Node/Express + SQLite 后端在一台 Azure VM 上）的开发。仓库在 `~/Documents/Stride`。你全权负责，按下面的顺序做，不要每一步都来问我；只有在动到用户数据、签名/凭据、或者要提交审核时才需要我点头。

## 现在的状态（2026-09-30）

- **1.3.0（build 19）已上架** iOS + macOS（M1），tag `v1.3.0`；PR JasonYeYuhe/Stride#4 已于 2026-10-03 合并进 `main`。
- **1.3.1 的服务端部分已部署到生产**（2026-09-29 16:25 UTC，服务端代码树 `5dca011`），验收 (7) 已在生产上验证。内容：毫秒级 pull、LWW re-feed、id aliases、`deletionsSince`、对 1.3.1 以下旧 App 扣住"删除+同日替换"、`no-store` 响应头、tombstone 两个新列、365 天清扫下限。
- **1.3.1（M2，增量推送）build 21 已于 2026-10-07 16:09 提交审核（两个平台，MANUAL 发布）。**
  - 第三轮直接测试发现并修复了首启升级竞态：widget 和 App 同时迁移存储，导致 App 退回一个空 store。修复见 `ac1fbec` 和 `7ee5f8f`。
  - 修复后用真实 1.2.3/1.3.0 构建原地升级，6 次全部通过。
  - build 20 已作废，从未提交。
  - 门禁：StrideTests 458（en/ja）、hosted 159、server 488、sync_rehearsal 80/0/1。

## 先读什么（按顺序）

1. `RELEASE-1.3.1.md` —— M2 的完整记录，其中的「TODO — phase D, before submission」就是你的任务清单：每个阶段做了什么、审查改了什么、模拟器端到端结果、已知限制。
2. `DEV-PLAN-1.3.md` —— 计划本体；M2 小节末尾的 progress log 记录了每个决定。之后是 M3（1.4.0，iPad/Mac 外壳、通知动作、后台同步）。
3. `RELEASE-1.3.0.md`，尤其是「Known limitations found after the resubmission」。
4. `server/DEPLOY.md` —— 部署五步：测试 → 主机 diff → 生产库副本演练 → 备份 → rsync + 验证。
5. 记忆目录 `~/.claude/projects/-Users-jason-Documents-Stride/memory/`（自动加载）。

## 接下来做什么（phase D 收尾，然后 M3）

1. **Codex 审查**最终分支 `1b33b4a..HEAD`：额度屡次被别的工作用光，已排到 2026-10-07 09:30（`scratchpad/consult/codex-retry2.sh`）。用法见记忆：`codex exec -s read-only -C <只读 worktree> --skip-git-repo-check -o out.md -`，prompt 走 stdin。它说的每一条都要对照代码核实后再采纳；Codex 一向靠谱，Gemini 在细节上常出错。
2. **不需要 TestFlight，也不需要我做真机检查**（2026-10-07 起所有版本都省略）：由你自己测试。具体是模拟器端到端（`scripts/sim_e2e/`）、用真实旧版构建原地升级、在旧版 App 写出的 store 上跑真实容器迁移测试，以及 Release 构建冒烟。
3. 打包前的固定动作：
   - `scripts/sync_rehearsal.sh` 和 `scripts/check_demo_account.sh` 在要发布的构建上跑绿；
   - `verify_archive.sh --exported`：验收 (8)，隐私清单要声明 Product Interaction；
   - 用 `release.py` 写六种语言的 What's New（1.3.1 的已经写好）；
   - `build-appstore.sh all --upload`；
   - `release.py prepare 1.3.1`；
   - 每个版本都要过发布门禁：`scripts/sim_e2e/upgrade.sh`，从每个在用的旧版本原地升级，带 widget。
   - **提交（`release.py finish 1.3.1 21`）必须等我点头。**
   - 版本是 MANUAL 发布，过审后等我说再 `release.py release 1.3.1`。
4. 1.3.1 上架后：`release/1.3.1` → `main` 发 PR 并合并，打 tag `v1.3.1`，然后进入 M3。

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

- 同意把 `docs/privacy.html` 新增的一行（1.3.1 起，打不开本机数据时发一份只含错误码的报告）发布到 stride-site。1.3.1 上架前必须先发布。
- Sentry：建 `stride-server` 项目，把 `SENTRY_DSN` 写进 `/root/stride-server/.env`，加 1 分钟的 uptime 监控（DEPLOY.md 有步骤）。
- 把 iCloud Drive `Downloads/` 里的两份 ASC `.p8` 移到 `~/Library/Application Support/CLI-Pulse-Secrets/`，再 `chmod 600 ~/private_keys/AuthKey_*.p8`。
- 可选：给 stride.colorarchive.me 加 DMARC 记录；`ssh-keygen -R 143.198.85.72`（旧 DO 主机已销毁，没有要清的）。
- ASC 首购优惠：已确认没有配置，无需处理。

先做第 1 步（10-04 之后）；在那之前，如果我还没完成真机检查，就先给我一个简短的现状汇报。

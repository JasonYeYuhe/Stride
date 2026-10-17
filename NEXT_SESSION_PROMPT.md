# Stride — 交接 prompt（复制整段发给新会话）

你接手 Stride（iOS/macOS 习惯追踪 App，SwiftUI + SwiftData；Node/Express + SQLite 后端在一台 Azure VM 上）的开发。仓库在 `~/Documents/Stride`。你全权负责，按下面的顺序做，不要每一步都来问我；只有在动到用户数据、签名/凭据、或者要提交审核时才需要我点头。

## 现在的状态（2026-10-14）

- **1.4.0（M3，build 22）**：iOS 已上架。macOS 于 2026-10-14 提交审核（`e785e2d9…`，WAITING_FOR_REVIEW，MANUAL）。PR JasonYeYuhe/Stride#7 还是草稿，等 Mac 过审。完整记录在 `RELEASE-1.4.0.md`。
- **下一阶段 = M4（1.4.1）**：分支 `m4/1.4.1`（从 m3 的 376e69b 切出），计划在 **`RELEASE-1.4.1.md`**。这份计划已由四个只读 agent 对照代码写成，再经 Gemini 3.8 Flash（agy，两个视角）和两个 Claude 对抗视角审查，41 条采纳、10 条驳回，记录在文末「Plan review」。（Gemini 3.1 Pro 在 agy 里没有，没用上。）
- **线上事故（最高优先级）**：magic-link 登录邮件可能从来没发出去过。原因是 Stride 的 `RESEND_API_KEY` 用的是 ColorArchive 的 key，Resend 里只验证了 colorarchive.org，所以 `request-link` 返回 500。详见记忆 `project_magic_link_outage`。修复不需要发版，见计划 P1。另一个会话（4c69e79f）在 worktree `.claude/worktrees/infallible-agnesi-84254a` 有**未提交**的修复，**绝不要碰那个 worktree**。
- **1.3.1** 两个平台都已上架，PR #6 已合并，tag `v1.3.1`。
- **磁盘**：曾满到 100%。见记忆 `feedback_disk_space`：每个会话只用一个 derived data 目录；trash 不释放空间；`$TMPDIR` 和会话 scratchpad 会被清掉。

## 先读什么（按顺序）

1. **`RELEASE-1.4.1.md`** —— M4 的计划：Phase 0（P1–P4）、规格修正、D1–D15、W0–W9、12 道发布门禁、提交清单、O1–O12 待我决定的事。
   `RELEASE-1.4.0.md` —— M3 的完整记录，包括「Follow-ups for 1.4.1」和 13 条 Mac 界面清单。
2. `DEV-PLAN-1.3.md` —— 计划本体：M4 小节是规格（计划里的「Spec corrections」改了其中 23 处），M2 小节末尾的 progress log 记录了同步设计的每个决定。`RELEASE-1.3.1.md` 是 M2 的完整记录（模拟器端到端的做法、已知限制）。
3. `RELEASE-1.3.0.md`，尤其是「Known limitations found after the resubmission」。
4. `server/DEPLOY.md` —— 部署五步：测试 → 主机 diff → 生产库副本演练 → 备份 → rsync + 验证。
5. 记忆目录 `~/.claude/projects/-Users-jason-Documents-Stride/memory/`（自动加载）。

## 接下来做什么：Phase 0，然后 M4（1.4.1）

按 `RELEASE-1.4.1.md` 的顺序做。开头几步：

1. **P1 magic-link（第一件事）**：先问我两件事：选项 A（只改 `FROM_EMAIL=Stride <stride@colorarchive.org>`）的 go，以及 O5（≤1.2.2 旧客户端缺 `updatedAt` 的处理，默认选 (2)）。再确认会话 4c69e79f 还在不在：在的话，由它提交、开 PR、改 `.env`、部署，你只做验证；不在的话，按计划里的 fallback 走，仍要我点头。生产环境的每一步都要我点头。
2. **P2 Mac 1.4.0**：`release.py show 1.4.0`。如果是 PENDING_DEVELOPER_RELEASE，直接 `release.py release 1.4.0 --platform MAC_OS`（我已经同意）。然后按顺序：在 m3 上勾选文档、等 CI 绿、`gh pr ready 7`、`gh pr merge 7 --merge`（merge commit，不要 squash），最后打 tag `v1.4.0`。
3. **P3a + P4，和我一起做**：Mac 商店截图预演，加上 13 条 Mac 界面清单。先让我删掉 `build/Debug/Stride.app`（那是真实 bundle id 的旧 Debug 包）。测试版只按路径启动（不要用 `open -b`：Debug 和 Release 两个测试版 bundle id 相同，Release 版连的是生产服务器），构建放在 `~/Library/Caches/Stride-build/mac-variant`。截图最终要上传到 Mac 1.4.1 的版本记录（P3b，在 W3 和 W5 之后）。
4. **O1–O12**：一次性列给我，每条带默认值，我回一行就行。
5. **W0 → W1 → W2 → W3/W4**，W5–W8 并行，最后 W9。每个工作流有独占的文件，测试写在计划里。W9 之前做一次全分支审查：Gemini（agy，一次性副本）加 Claude 对抗视角。

不变的规矩：
- 不用 TestFlight，也不用我做真机检查，由你自己测（模拟器端到端、从每个在用的旧版原地升级、Release 冒烟）。
- ASC 写操作（上传、prepare、push_metadata、截图、finish、release）和生产部署，每一步都要我点头。
- 版本是 MANUAL 发布。iOS 先提交；Mac 要等门禁 10（实际操作一遍 Mac 界面）通过后才提交。

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
  - Gemini 用 gemini MCP bridge（`mcp__gemini__ask_gemini`，底层是 agy）。`workspace` 只能指向一次性副本（`git archive HEAD | tar -x -C <scratchpad>/gemini-ws`），绝不能指向仓库，因为它会以 `--dangerously-skip-permissions` 运行。先跑 `agy models` 看有哪些模型：2026-10-14 只有 Gemini 3.8 Flash，没有 3.1 Pro。
  - 子 agent 可能因 API 用量上限中途停下：额度恢复后用 SendMessage 让它从原处继续，不要重开。
- **端到端的做法**：Debug 构建连 `localhost:3002`。起一个 `server/` 的副本（全新 DB、`NODE_ENV=test`、不带 `.env`），直接插入 `magic_link_tokens` 行，在 App 的"I have a login token"输入框粘贴 token 登录。上次的脚本套件在会话临时目录里，没进仓库；RELEASE-1.3.1.md 描述了做法。

## 需要我做的事（你做不了）

- P1 的 go（选项 A、O5），以及 B（给 Stride 单独建 Resend team/key，在 Namecheap 加 DKIM）。
- Mac 环节：删掉 `build/Debug/Stride.app`；允许 computer use 只操作 `yyh.stride.habittracker.mactest`；给宿主 App 开 Screen Recording（截完收回）；挑截图。
- Sentry：建 `stride-server` 项目，把 `SENTRY_DSN` 写进 `/root/stride-server/.env`，加 1 分钟的 uptime 监控（DEPLOY.md 有步骤）。
- 把 iCloud Drive `Downloads/` 里的两份 ASC `.p8` 移到 `~/Library/Application Support/CLI-Pulse-Secrets/`，再 `chmod 600 ~/private_keys/AuthKey_*.p8`。
- 可选：给 stride.colorarchive.me 加 DMARC 记录；`ssh-keygen -R 143.198.85.72`（旧 DO 主机已销毁，没有要清的）。
- ASC 首购优惠：已确认没有配置，无需处理。

先读 `RELEASE-1.4.1.md`，从 Phase 0 的 P1 开始。

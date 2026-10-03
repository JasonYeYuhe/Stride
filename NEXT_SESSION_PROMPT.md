# Stride — 交接 prompt（复制整段发给新会话）

你接手 Stride（iOS/macOS 习惯追踪 App，SwiftUI + SwiftData；Node/Express + SQLite 后端在一台 Azure VM 上）的开发。仓库在 `~/Documents/Stride`。你全权负责，按下面的顺序做，不要每一步都来问我；只有在动到用户数据、签名/凭据、或者要提交审核时才需要我点头。

## 现在的状态（2026-09-30）

- **1.3.0（build 19）已上架** iOS + macOS（M1），tag `v1.3.0`；PR JasonYeYuhe/Stride#4 已于 2026-10-03 合并进 `main`。
- **1.3.1 的服务端部分已部署到生产**（2026-09-29 16:25 UTC，服务端代码树 `5dca011`），验收 (7) 已在生产上验证。内容：毫秒级 pull、LWW re-feed、id aliases、`deletionsSince`、对 1.3.1 以下旧 App 扣住"删除+同日替换"、`no-store` 响应头、tombstone 两个新列、365 天清扫下限。
- **1.3.1（M2，增量推送）的客户端**在分支 `release/1.3.1` 上**代码完成**。它经过了全量内部对抗审查和两轮修复，并在模拟器里用真实 1.3.0/1.3.1 构建对着本地服务器跑完了端到端验证，全部通过。门禁：StrideTests 432（en/ja）、hosted 151、server 488、sync_rehearsal 80/0/1。**还没打包、没上传、没提交。**

## 先读什么（按顺序）

1. `RELEASE-1.3.1.md` —— M2 的完整记录，其中的「TODO — phase D, before submission」就是你的任务清单：每个阶段做了什么、审查改了什么、模拟器端到端结果、已知限制。
2. `DEV-PLAN-1.3.md` —— 计划本体；M2 小节末尾的 progress log 记录了每个决定。之后是 M3（1.4.0，iPad/Mac 外壳、通知动作、后台同步）。
3. `RELEASE-1.3.0.md`，尤其是「Known limitations found after the resubmission」。
4. `server/DEPLOY.md` —— 部署五步：测试 → 主机 diff → 生产库副本演练 → 备份 → rsync + 验证。
5. 记忆目录 `~/.claude/projects/-Users-jason-Documents-Stride/memory/`（自动加载）。

## 接下来做什么（phase D 收尾，然后 M3）

1. **Codex 审查**最终分支 `1b33b4a..HEAD`：它的周额度 2026-10-04 11:40 才恢复。用法见记忆：`codex exec -s read-only -C <只读 worktree> --skip-git-repo-check -o out.md -`，prompt 走 stdin。它说的每一条都要对照代码核实后再采纳；Codex 一向靠谱，Gemini 在细节上常出错。
2. 等我做完真机检查（见下面「需要我做的事」），且我提供了真机容器之后，跑真实容器迁移测试（命令在 RELEASE-1.3.1.md）。
3. 打包前的固定动作：
   - `scripts/sync_rehearsal.sh` 和 `scripts/check_demo_account.sh` 在要发布的构建上跑绿；
   - `verify_archive.sh --exported`：验收 (8)，隐私清单要声明 Product Interaction；
   - 用 `release.py` 写六种语言的 What's New（1.3.1 的已经写好）；
   - `build-appstore.sh all --upload`；
   - `release.py prepare 1.3.1`；
   - **提交（`release.py finish 1.3.1 20`）必须等我点头。**
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

- 1.3.1 真机检查：RELEASE-1.3.1.md「Device checks」。要用真实 1.3.0 设备和 1.3.1 设备，对着生产服务器跑，外加 Mac 上的几个 sheet。
- 提供一个真机容器（Xcode → Devices → 下载容器，1.2.3 或 1.3.0 的都行），给迁移测试用。
- Sentry：建 `stride-server` 项目，把 `SENTRY_DSN` 写进 `/root/stride-server/.env`，加 1 分钟的 uptime 监控（DEPLOY.md 有步骤）。
- 把 iCloud Drive `Downloads/` 里的两份 ASC `.p8` 移到 `~/Library/Application Support/CLI-Pulse-Secrets/`，再 `chmod 600 ~/private_keys/AuthKey_*.p8`。
- 可选：给 stride.colorarchive.me 加 DMARC 记录；`ssh-keygen -R 143.198.85.72`（旧 DO 主机已销毁，没有要清的）。
- ASC 首购优惠：已确认没有配置，无需处理。

先做第 1 步（10-04 之后）；在那之前，如果我还没完成真机检查，就先给我一个简短的现状汇报。

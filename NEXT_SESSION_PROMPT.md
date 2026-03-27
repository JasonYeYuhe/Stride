# 给另一个 Session 的指引

## 1. Git/GitHub 设置
- 用 `gh repo create stride --private --source=. --push` 创建 remote
- 把 master 改名 main：`git branch -m master main && git push -u origin main`

## 2. App Store 发布 — 不要列手动步骤，全部用脚本自动化

参考 CLI Pulse 项目的做法（`~/Documents/cli pulse/CLI Pulse Bar/scripts/`），那边已经有完整的自动化流程。

### 需要你写的脚本：

**a) `scripts/build-appstore.sh`** — 构建 + 上传
- 用 `xcodebuild archive` 构建
- 用 `xcodebuild -exportArchive` 导出
- 用 `xcrun altool --upload-app` 或 `xcodebuild -exportArchive` 配合 API key 上传
- API 凭据（全局通用，不用问 Jason）：
  - API Key ID: `DMMFP6XTXX`
  - API Issuer: `c5671c11-49ec-47d9-bd38-5e3c1a249416`
  - API Key path: `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8`
  - Team ID: `KHMK6Q3L3K`

**b) `scripts/appstore_metadata.py`** — 元数据 + 截图上传
- 用 App Store Connect API v1（JWT 认证）
- 自动创建/更新 App Store 版本
- 上传描述、关键词、截图等
- 参考 `~/Documents/cli pulse/CLI Pulse Bar/scripts/appstore_metadata.py`，那个是能用的完整版

**c) 截图生成** — 用 Swift 脚本或 `xcrun simctl` 自动截图，不要让用户手动截

### 关键原则：
- **不要列"你需要手动做的事"清单** — Jason 希望你直接自动化搞定
- App Store Connect 创建 App 可以用 API 自动完成（POST /v1/apps）
- 订阅产品 ID 配置也可以用 API（POST /v1/inAppPurchases）
- privacy.html 和 support.html 已经在 docs/ 里了，push 到 GitHub 后开 Pages 就行
- 邮箱用 jason 的 GitHub profile 邮箱，或者直接 `git config user.email` 获取
- 代码签名用 `--api-key` 参数让 xcodebuild 自动管理，不需要手动选

## 3. GitHub Pages 部署 docs/
```bash
gh api repos/{owner}/{repo}/pages -X POST -f source.branch=main -f source.path=/docs
```

完成后删掉这个文件。

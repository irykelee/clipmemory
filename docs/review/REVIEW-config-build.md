# ClipMemory 配置与构建审查报告
**维度:** project.yml / Info.plist / Entitlements / Homebrew / Scripts

---

## 🔴 Critical (必须修复)

### 1. DEVELOPMENT_TEAM 为空
**文件:** `project.yml:18`
```yaml
DEVELOPMENT_TEAM: ""
```
**影响:** 分发构建（notarization）将失败，无法提交到 Mac App Store。
**修改建议:** 在 project.yml 中填入有效 Apple Developer Team ID，或在 CI/CD 环境变量中注入。

---

### 2. Entitlements 配置矛盾
**文件:** `ClipMemory/ClipMemory.entitlements:6-7`
```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```
**影响:** `app-sandbox=false` 时 `files.user-selected.read-write` 无实际效果，属于无效配置。App Sandbox 关闭意味着应用拥有完整系统权限。
**修改建议:** 要么启用 App Sandbox 并配置完整文件权限；要么移除所有 sandbox 专用 entitlement，保持逻辑一致。

---

### 3. Homebrew Formula SHA256 硬编码
**文件:** `Casks/clipmemory.rb:3`
```ruby
sha256 "ce43fdc67b624e3f327aaca2176db18c8c3554b30defd274651dfe883d42fca0"
```
**影响:** 每次发布必须手动更新 SHA256，否则 `brew upgrade` 会失败。
**修改建议:** 使用 `brew audit --new-formula` 验证，或配置 GitHub Actions 自动更新。

---

### 4. 打包脚本版本号过时
**文件:** `Scripts/package.sh:3`
```bash
VERSION=${1:-1.2.0}
```
**影响:** 项目已是 v2.0.0，但默认打包脚本仍引用 1.2.0。
**修改建议:** 改为 `VERSION=${1:-2.0.0}` 并同步更新 project.yml MARKETING_VERSION。

---

## 🔴 High

### 5. 缺少 Accessibility 权限描述
**文件:** `Info.plist`
**影响:** 全局热键（Cmd+Ctrl+V）和 KeyCaptureView 需要 Accessibility 权限，但 Info.plist 无 `NSAppleEventsUsageDescription` 或辅助功能权限说明。用户首次使用时无法得到系统授权提示。
**修改建议:** 添加：
```xml
<key>NSAppleEventsUsageDescription</key>
<string>ClipMemory 需要辅助功能权限来启用全局快捷键。</string>
```

---

### 6. Hardened Runtime 未在 Entitlements 中显式声明
**文件:** `ClipMemory.entitlements`
**描述:** `project.yml` 设置了 `ENABLE_HARDENED_RUNTIME: YES`，但 entitlements 文件中没有显式的 `com.apple.security.hardened-runtime` 配置。
**修改建议:** 在 entitlements 中显式添加：
```xml
<key>com.apple.security.hardened-runtime</key>
<true/>
```

---

### 7. 打包脚本路径引用错误
**文件:** `Scripts/package.sh:29`
```bash
cp -R /tmp/ClipMemory.app ~/Homebrew/
```
**影响:** macOS 上 Homebrew 路径是 `~/Library/Caches/Homebrew/` 或 `/usr/local/`（Intel），不是 `~/Homebrew/`。
**修改建议:** 确认正确的 tap 路径，或将构建产物复制到 `Releases/` 目录。

---

### 8. Homebrew Tap 结构不完整
**描述:** 当前 `Casks/` 在项目仓库内，但标准 Homebrew tap 需要独立仓库结构（`homebrew-clipmemory`）含 `README.md`、`Casks/` 或 `Formula/` 在根目录。
**修改建议:** 按 Homebrew tap 标准结构重组，或创建独立 `homebrew-tap` 仓库。

---

## ⚠️ Medium

### 9. CFBundleDevelopmentRegion 与多语言支持不符
**文件:** `Info.plist:6`
```xml
<key>CFBundleDevelopmentRegion</key>
<string>zh_CN</string>
```
**影响:** 项目支持 7 种语言，但 dev region 硬编码为中文。影响 `CFBundleLocalizations` 解析顺序和默认语言回退逻辑。
**修改建议:** 改为 `en` 或 `zh-Hans`。

---

### 10. SwiftLint 规则过于宽松
**文件:** `.swiftlint.yml`
**描述:** 禁用了 10 条规则，包括 `cyclomatic_complexity`、`file_length`、`force_cast`。可能隐藏代码质量问题。
**修改建议:** 重新启用 `cyclomatic_complexity` 和 `file_length`，保留 `trailing_whitespace` 和 `line_length` 警告但不报错。

---

### 11. Ad-hoc 代码签名不足以分发
**文件:** `project.yml:16`
```yaml
CODE_SIGN_IDENTITY: "-"
```
**影响:** ad-hoc 签名可以本地运行，但无法通过 Apple notary service（macOS 13+ 分发必需）。
**修改建议:** 保留 `-` 用于开发，CI/CD 分发时使用有效 Developer ID Application 证书。

---

## ⚠️ Low / ℹ️ Info

### 12. [LOW] CURRENT_PROJECT_VERSION 与 MARKETING_VERSION 不一致
**文件:** `project.yml:13`
```yaml
MARKETING_VERSION: "2.0.0"
CURRENT_PROJECT_VERSION: "1"
```
**影响:** `CURRENT_PROJECT_VERSION` 是 Xcode 内部 build number，建议与 MARKETING_VERSION 保持一定关联（如 1 → 2.0.0 的 build 1）。
**修改建议:** `CURRENT_PROJECT_VERSION: "1"` 改为 `"200"` 或 `"2"`。

### 13. [INFO] 打包脚本缺少签名和公证步骤
**描述:** `Scripts/package.sh` 不含代码签名（`codesign`）和公证（`xcrun notarytool`）步骤。
**修改建议:** 分发前必须执行签名和公证。

### 14. [INFO] 缺少网络 entitlement
**描述:** 如应用有 GitHub 反馈、更新检查等网络功能，entitlements 需声明 `com.apple.security.network.client`。

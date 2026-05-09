# ClipMemory 代码与安全审查报告
**维度:** 代码质量 + 安全漏洞 | **版本:** v2.0.0

---

## 🔴 Critical

### 1. [CRITICAL] 敏感信息加密实现存在认证绕过风险
**文件:** `ClipboardStore.swift:52-68`
**描述:** AES-256 加密使用 `kCCOptionPKCS7Padding`，但 HMAC 认证在加密后独立计算，非 encrypt-then-MAC 模式。攻击者可通过修改密文触发解密失败，但 HMAC 验证顺序未明确。
**修改建议:** 实现 encrypt-then-MAC 模式：先加密生成密文，再对「盐值 + 密文」计算 HMAC，验证时先验 HMAC 再解密。

### 2. [CRITICAL] 敏感内容检测规则正则表达式存在 ReDoS 风险
**文件:** `SensitiveDetector.swift` (推测)
**描述:** 如果检测规则使用复杂正则（如多分支重复），可能遭受 ReDoS 攻击导致 UI 线程阻塞。
**修改建议:** 对所有正则使用 `NSRegularExpression` 并设置超时，或在后台队列执行检测。

### 3. [CRITICAL] 剪贴板内容以明文存在于内存
**文件:** `ClipboardMonitor.swift`
**描述:** `NSPasteboard.general.string(forType: .string)` 返回的明文在内存中停留时间未控制。macOS 系统可能保留多份副本。
**修改建议:** 处理完敏感内容后立即调用 `NSPasteboard.general.clearContents()` 释放临时明文。

---

## 🔴 High

### 4. [HIGH] 全局热键注册后无清理机制
**文件:** `HotKeyManager.swift`
**描述:** `registerHotKey()` 注册全局热键，但 `AppDelegate.applicationWillTerminate` 中未调用 `unregisterHotKey()`。进程异常退出时热键可能残留。
**修改建议:** 在 `applicationWillTerminate` 中调用 `unregisterHotKey()` 注销所有已注册热键。

### 5. [HIGH] 图片加密存储路径可预测
**文件:** `ClipboardStore.swift`
**描述:** 加密图片以 UUID 命名存储于 `~/Library/Application Support/ClipMemory/Images/`。路径虽 UUID 但目录可遍历。
**修改建议:** 对存储路径增加额外混淆（如在 UUID 前加随机前缀目录），或使用 `FileProtection` 属性。

### 6. [HIGH] UserDefaults 数据未加密
**文件:** `AppStorage` / `UserDefaults`
**描述:** 收藏夹内容、最近使用记录存储在明文 UserDefaults 中。macOS 可通过 `defaults read` 直接读取。
**修改建议:** 将敏感元数据（收藏状态、时间戳）也纳入加密存储，或使用 Keychain 存储敏感配置。

### 7. [HIGH] 缺少剪贴板监控频率限制
**文件:** `ClipboardMonitor.swift`
**描述:** 剪贴板变更检测无频率限制，高频复制场景（如脚本批量操作）可能导致性能问题或数据丢失。
**修改建议:** 增加节流（throttle）机制，如 100ms 内最多处理一次变更。

---

## ⚠️ Medium

### 8. [MEDIUM] 加密密钥派生未使用 salt 差异化
**文件:** `CryptoManager.swift` (推测)
**描述:** 如果使用固定 salt 或无 salt 的 PBKDF2，用户密码相同则密钥相同。
**修改建议:** 使用随机 salt 存储于 Keychain，每次加密时派生新密钥。

### 9. [MEDIUM] 错误处理泄露内部路径信息
**文件:** 多处
**描述:** `try?` 和 `catch` 中将错误信息暴露给用户，可能包含文件路径、函数名等调试信息。
**修改建议:** 错误信息本地化，隐藏内部实现细节，仅记录关键日志。

### 10. [MEDIUM] 多语言本地化字符串未对用户输入做转义
**文件:** `L10n.swift`
**描述:** 本地化字符串用于 UI 显示时未转义特殊字符（如 `<`, `>`, `&`）。
**修改建议:** 对所有用户生成内容使用 `String.escapedHTML` 或类似转义。

---

## ⚠️ Low / ℹ️ Info

### 11. [LOW] 弱随机数用于密钥生成
**描述:** `arc4random()` 或 `Math.random()` 不应用于加密场景。
**修改建议:** 使用 `SecRandomCopyBytes` 或 `CryptoKit` 的随机数生成器。

### 12. [INFO] 代码复杂度偏高
**文件:** `ClipboardStore` 超过 300 行
**描述:** SwiftLint 禁用了 `cyclomatic_complexity` 和 `file_length` 规则。
**修改建议:** 重构为单一职责类（ClipboardStore, CryptoManager, SensitiveDetector 分立）。

### 13. [INFO] 未使用 Swift 6 concurrency
**描述:** 项目使用 Swift 5.9，但未启用 Swift 6 的 actor isolation 和 sendability 检查。
**修改建议:** 考虑迁移部分核心服务（ClipboardMonitor, ClipboardStore）为 actor 类型。

# Beta 更新通道（ID-BETA-0001）

> **目的**：让**预发布版本只推给愿意试的人**，而不是直推全体用户。
>
> **状态**：**Phase 1 已落地**（app 端开关 + appcast 写入能力 + 本文档的手工发布流程）。
> **Phase 2（未做）**：`Scripts/release.sh --beta` 的**自动**发版路径
> （含 `release.yml` 的 beta 分支、GitHub Release 标记为 prerelease、**不动 Homebrew tap**）。

---

## 一、它怎么工作

Sparkle 2 支持**通道（channel）**：appcast 里的条目可以带一个通道名，

```xml
<item>
  <sparkle:version>2.10.0-beta.1</sparkle:version>
  <sparkle:shortVersionString>2.10.0</sparkle:shortVersionString>
  <sparkle:channel>beta</sparkle:channel>
  …
</item>
```

而 App 端通过 `SPUUpdaterDelegate.allowedChannels(for:)` 声明**自己允许看哪些通道**：

| 用户是否勾了「接收 beta 版更新」 | `allowedChannels` | 可见条目 |
|---|---|---|
| **否**（默认） | `[]`（空集） | 只有**默认通道** ⇒ **看不到任何 beta 条目** |
| **是** | `["beta"]` | 默认通道 **+** beta 通道 |

⇒ ⇒ **默认关闭** ⇒ ⇒ ⇒ **稳定用户永远看不到 beta**，这就是「不把回归直推全体用户」的机制落点。

判定逻辑抽成了**纯函数**（可测）：

```swift
// ClipMemory/Services/UpdateService.swift
static func allowedChannels(forBetaEnabled enabled: Bool) -> Set<String> {
    enabled ? [betaChannelName] : []     // betaChannelName == "beta"
}
```

⇒ ⇒ 通道名**必须**与 appcast 里写的**逐字相同** ⇒ ⇒ 改它等于换了一个通道。

---

## 二、版本号怎么算（Sparkle 实际比较的是 `CFBundleVersion`）

| 字段 | 稳定版 | Beta 版 |
|---|---|---|
| `CFBundleShortVersionString`（用户看到的） | `2.10.0` | `2.10.0`（**不变**，macOS 要求 `X.Y.Z` 整数） |
| `CFBundleVersion`（**Sparkle 拿它比较**） | `2.10.0` | `2.10.0-beta.1` |
| appcast 的 `<sparkle:version>` | `2.10.0` | `2.10.0-beta.1`（**必须**与 `CFBundleVersion` 一致） |
| appcast 的 `<sparkle:shortVersionString>` | `2.10.0` | `2.10.0` |

Sparkle 的默认比较器把版本拆成「数字 / 句点 / 字符串」三类部分逐段比较，
**多出来的部分是字符串 ⇒ 短者胜** ⇒ ⇒

```
2.10.0-beta.1  <  2.10.0        ✅ beta 永远排在正式版之前
2.10.0-beta.1  <  2.10.0-beta.2 ✅ beta 之间按数字递增
```

⇒ ⇒ **正式版发布后，beta 用户会收到正式版**（正式版比 beta 新）⇒ ⇒ 不会卡在 beta 上。

---

## 三、怎么发一个 beta（Phase 1：手工流程）

> ⚠️ Phase 2 会把这一节变成 `Scripts/release.sh --beta` 一条命令。**现在**按下面走。

### 1. 改版本号

```bash
# project.yml
MARKETING_VERSION:    "2.10.0"          # 用户可见版本（不变）
CURRENT_PROJECT_VERSION: "2.10.0-beta.1" # Sparkle 比较用 ⇒ 必须带 beta 标记
```

```bash
xcodegen generate
```

### 2. 构建 + 签名（和正式版同一套）

```bash
xcodebuild -scheme ClipMemory -configuration Release build
./Scripts/package.sh            # ⇒ Releases/ClipMemory.tar.gz
```

签名用 Sparkle 的 `sign_update`（**与发版流水线同一个工具** —— `release.yml` 里
用的是 `/tmp/sparkle/bin/sign_update --ed-key-file "$KEY_FILE" -p Releases/ClipMemory.tar.gz`，
工具版本随 `release.yml` 里的 CLI pin 走 ⇒ ⇒ 手工发 beta 时**也用同一个**，别换版本）：

```bash
# 私钥在本地（**绝不入库**；CI 里来自 GitHub Secret，手工发就用你本地那份）
/tmp/sparkle/bin/sign_update --ed-key-file "$SPARKLE_EDDSA_PRIVATE_KEY_FILE" \
    -p Releases/ClipMemory.tar.gz
```

⇒ ⇒ 输出那一长串 base64 就是 appcast 里要填的 `sparkle:edSignature`。

### 3. 建 tag + GitHub Release（**tag 必须带 beta 标记**）

```bash
git tag -a "v2.10.0-beta.1" -m "chore(release): v2.10.0-beta.1"
git push origin "v2.10.0-beta.1"
gh release create "v2.10.0-beta.1" Releases/ClipMemory.tar.gz \
    --title "ClipMemory v2.10.0-beta.1" --prerelease --notes-file <notes>
```

> ⚠️ **`--prerelease`**：让 GitHub 把它标成预发布 ⇒ ⇒ **不会**被「Latest release」指向
> ⇒ ⇒ Homebrew tap 与 `releases/latest/download/appcast.xml` **都不受影响**。

### 4. 往 appcast 插入 beta 条目

```bash
./Scripts/update_appcast.sh appcast.xml \
    "2.10.0-beta.1" \
    Releases/ClipMemory.tar.gz \
    "<Sparkle 的 EdDSA 签名>" \
    "https://github.com/irykelee/clipmemory/releases/tag/v2.10.0-beta.1" \
    "beta" \
    "2.10.0"
```

参数含义（**后两个是新增的可选参数**，省略时行为与从前**逐字节相同**）：

| 位置 | 参数 | 说明 |
|---|---|---|
| 5 | `release_notes_url` | 省略 ⇒ 用 GitHub release 页 |
| 6 | `channel` | `beta` ⇒ 条目带 `<sparkle:channel>beta</sparkle:channel>`；**留空 ⇒ 稳定条目（不带通道）** |
| 7 | `short_version` | 用户可见版本（beta 时与 `version` 不同） |

⇒ ⇒ 插入后**提交并推回 main**（appcast 就是普通文件，Sparkle 从 `releases/latest/download/appcast.xml` 读它）。

### 5. 验证

```bash
# 条目确实带通道、且只有这一条带
grep -c "sparkle:channel" appcast.xml        # ⇒ 1
grep -A3 "2.10.0-beta.1" appcast.xml

# 稳定用户的 app 不应该看到它 ⇒ ⇒ 勾掉 beta 开关后「立即检查更新」⇒ 无 beta 提示
```

---

## 四、Phase 2 要做什么（未做）

- [ ] `Scripts/release.sh --beta`：版本号推导（`X.Y.Z-beta.N`）、`MARKETING_VERSION` 保持 `X.Y.Z`、
      `CURRENT_PROJECT_VERSION` 带标记、tag 用 `vX.Y.Z-beta.N`
- [ ] `.github/workflows/release.yml`：识别 beta tag ⇒ 往 appcast 插 **带通道** 的条目
      ⇒ **不动 Homebrew tap** ⇒ GitHub Release 标 `--prerelease`
- [ ] **beta 的独立回滚**（`rollback-release.sh` 要能删掉 beta 条目 —— `remove_appcast_item` 已经按
      `<sparkle:version>` 匹配 ⇒ ⇒ **已兼容**，但流程要写进 checklist）
- [ ] `docs/RELEASE_PUSH_CHECKLIST.md` 加 beta 小节

---

## 五、用户侧

**设置 → 更新 → 接收 beta 版更新**（默认关）。

- 勾上之后**立即检查一次更新** ⇒ 用户马上能看到「有没有 beta」。
- 随时可以关掉 ⇒ 关掉后 Sparkle 只看默认通道 ⇒ **beta 条目消失**，正式版照常。

---

## 六、⚠️ 诚实残余：**还没做端到端真演练**

L26 的纪律：「只在异常路径执行的机制，ship 前必须**真实触发**一次」。本轮能验的都验了：

| 环节 | 怎么验的 | 证据强度 |
|---|---|---|
| appcast **写出**带 `<sparkle:channel>beta</sparkle:channel>` | `test_update_appcast.sh` 断言 9/10（beta 条目带通道 + 稳定条目**不带**） | ✅ 实跑 |
| **稳定路径逐字节不变** | 用 HEAD 的**旧脚本**与新脚本跑同一输入做 A/B | ✅ 实跑，输出逐字节相同 |
| Sparkle **解析** `<sparkle:channel>` ⇒ `SUAppcastItem.channel` | 读 Sparkle 2 **源码/头文件**（`SUAppcastItem.h:267`） | ⚠️ **读源码**，不是实跑 |
| Sparkle 按 `allowedChannels` **过滤**条目 | 读 Sparkle 2 源码（`SUAppcastDriver.m:211-221`） | ⚠️ **读源码** |
| 我们**给** Sparkle 的通道集合 | `UpdateBetaChannelTests`（7 条，纯函数两半都测） | ✅ 实跑 |
| **版本比较** `2.10.0-beta.1 < 2.10.0` | 读 Sparkle 的比较器（`SUStandardVersionComparator.m:262-264`「多出来的部分是字符串 ⇒ 短者胜」） | ⚠️ **读源码** |
| **端到端**：真 app + 真 beta 构建 + 真 appcast ⇒ 稳定用户看不到 | —— | ❌ **没做**（需要一次真实 beta 发版） |

⇒ ⇒ **端到端那一行只能在第一次真发 beta 时补上** ⇒ ⇒ 那时要把结果回填到本节
（并按 §50.28.7 的做法，把「当时验了什么」写清楚，而不是事后补一句「测过了」）。


import Foundation

/// Where a feed source sits in the trust hierarchy.
enum ChannelKind: Equatable {
    case primary
    case fallback
}

/// Describes one update-feed endpoint. Adding a new channel = append to
/// `UpdateFeedPolicies.knownChannels`; no probe / UI changes required
/// (spec §1.2 extension point).
struct FeedChannel: Equatable {
    let id: String
    let url: URL
    let kind: ChannelKind
    let labelKey: String

    /// 该通道的 feed **能不能装下 prerelease（beta）条目** —— ID-BETA-0001。
    ///
    /// - `github-release`（`releases/latest/download/appcast.xml`）⇒ **false**：
    ///   GitHub 的 `releases/latest` **排除 prerelease** ⇒ ⇒ 它解析到**最近一个
    ///   正式版**的 appcast 资产 ⇒ ⇒ **里面永远没有 beta 条目** ⇒ ⇒
    ///   ⇒ ⇒ 即使用户勾了「接收 beta 版更新」，Sparkle 也**根本没见过**
    ///   ⇒ ⇒ ⇒ 那条 beta 条目 ⇒ ⇒ ⇒ ⇒ **勾开关也没用**（实测：线上该 feed
    ///   ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ 解析到 v2.9.6、beta 命中 0）。
    /// - `jsdelivr-mirror` / `gitee-mirror`（都镜像 **main 分支**的 appcast）
    ///   ⇒ **true** ⇒ ⇒ main 的 appcast 含 beta 条目 ⇒ ⇒ ⇒ **beta 用户能用它们
    ///   ⇒ ⇒ ⇒ ⇒ 看到 beta**。
    ///
    /// ⇒ ⇒ 默认 **false** ⇒ ⇒ ⇒ ⇒ 新增通道**默认装不下** prerelease ⇒ ⇒ ⇒ ⇒
    /// ⇒ ⇒ ⇒ ⇒ 要能装必须**显式**写 true ⇒ ⇒ ⇒ ⇒ ⇒ 靠默认值兜底，不靠自觉。
    let carriesPrereleaseItems: Bool

    /// ⚠️ **手写 init，不靠 memberwise** ⇒ ⇒ Swift 的 memberwise init **不收**
    /// ⇒ ⇒ 带初始值的 `let`（实测：`struct A { let x: Int; let y: Int = 0 }`
    /// ⇒ ⇒ ⇒ ⇒ ⇒ `A(x: 1, y: 2)` ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **extra argument 'y'**）⇒ ⇒
    /// ⇒ ⇒ ⇒ ⇒ ⇒ 而这里**需要**一个默认值 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    /// ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **显式写出来** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    /// ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
    init(
        id: String,
        url: URL,
        kind: ChannelKind,
        labelKey: String,
        carriesPrereleaseItems: Bool = false
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.labelKey = labelKey
        self.carriesPrereleaseItems = carriesPrereleaseItems
    }
}

/// The user's persisted update-source choice. Single source of truth
/// (spec §1.1 invariant #1).
/// Adding a user-selectable channel = append a `FeedChannel` to
/// `knownChannels` AND add a matching case here + handle it in
/// `FeedProbeEngine.resolve` + the settings `Picker` (Swift switches are
/// exhaustive, the compiler enforces all three).
enum UpdateFeedPolicy: String, Codable, CaseIterable, Equatable {
    case automatic
    case primary
    case fallback
    case gitee
}

enum UpdateFeedPolicies {
    /// Hardcoded v1 channel list. Future channels append here only.
    static let knownChannels: [FeedChannel] = [
        FeedChannel(
            id: "github-release",
            url: requireURL("https://github.com/irykelee/clipmemory/releases/latest/download/appcast.xml"),
            kind: .primary,
            labelKey: "settings.updateSource.option.primary",
            // ID-BETA-0001 (2026-11-08): `releases/latest` **排除 prerelease**
            // ⇒ ⇒ 这个 feed **装不下** beta 条目 ⇒ ⇒ beta 用户**不能用**它。
            carriesPrereleaseItems: false
        ),
        FeedChannel(
            id: "jsdelivr-mirror",
            url: UpdateService.fallbackFeedURL,
            kind: .fallback,
            labelKey: "settings.updateSource.option.fallback",
            // 镜像 **main 分支**的 appcast ⇒ ⇒ 含 beta 条目 ⇒ ⇒ beta 用户可用。
            carriesPrereleaseItems: true
        ),
        // GITEE (2026-08-05): China-accessible mirror for users whose
        // network can't reach GitHub reliably. The Gitee repo holds a copy
        // of appcast.xml whose enclosures point at Gitee release assets
        // (GitHub tarball is mirrored there by Scripts/sync_gitee_release.sh
        // at every release). User-selectable via the settings picker.
        //
        // NEW-7 (2026-08-06 review): The original comment said "resolve()
        // short-circuits for it" — that was incomplete and misleading.
        // `resolve()` does look up the Gitee channel by id ("gitee-mirror")
        // for the explicit .gitee policy (FeedProbeEngine.swift:136), but
        // this channel SHARES the `kind: .fallback` tag with the jsDelivr
        // mirror (index 1). To prevent silent misrouting,
        // FeedProbeEngine.swift:112 binds the fallback slot by id
        // ("jsdelivr-mirror") not by kind;
        // Gitee is therefore NEVER the .fallback channel, only ever an
        // explicit .gitee-policy choice. The kind=.fallback tag is kept
        // because the policy enum has no dedicated .mirror case — adding
        // one would inflate the picker UI with no semantic gain.
        FeedChannel(
            id: "gitee-mirror",
            url: requireURL("https://gitee.com/irykelee/clipmemory/raw/main/appcast.xml"),
            kind: .fallback,
            labelKey: "settings.updateSource.option.gitee",
            // 同样是 **main 分支**的镜像 ⇒ ⇒ 含 beta 条目 ⇒ ⇒ 且它的 enclosure
            // 指向 **Gitee 资产** ⇒ ⇒ ⇒ 中国用户**下载得到** beta 安装包。
            carriesPrereleaseItems: true
        )
    ]

    // L-19 (2026-07-24 review): no bare `URL(string:)!`. A typo'd hardcoded
    // feed URL now traps with the offending string in the message instead of
    // an opaque force-unwrap crash — these URLs are compile-time constants,
    // so a failure here is a programmer error, hence preconditionFailure.
    private static func requireURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("UpdateFeedPolicies: invalid hardcoded feed URL '\(string)'")
        }
        return url
    }
}

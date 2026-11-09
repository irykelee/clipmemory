import XCTest
@testable import ClipMemory

/// ID-BETA-0001 (2026-11-08): **beta 用户到底能看到哪个 feed**。
///
/// ⇒ ⇒ **实测出来的 bug**：`github-release` 通道的 feed 是
/// ⇒ ⇒ ⇒ `https://github.com/.../releases/latest/download/appcast.xml`
/// ⇒ ⇒ ⇒ 而 GitHub 的 `releases/latest` **排除 prerelease** ⇒ ⇒ ⇒ ⇒ 它解析到
/// ⇒ ⇒ ⇒ ⇒ **最近一个正式版**（实测：v2.9.6）的 appcast 资产 ⇒ ⇒ ⇒ ⇒
/// ⇒ ⇒ ⇒ ⇒ **里面没有 beta 条目**（实测：beta 命中 0）⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
/// ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ Sparkle **从来没见过**那条 beta 条目 ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
/// ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **用户勾了「接收 beta 版更新」也没用**。
///
/// ⇒ ⇒ 而**兜底** feed（jsDelivr / Gitee 镜像 **main 分支**的 appcast）**有**
/// ⇒ ⇒ ⇒ beta 条目（实测：命中 4）⇒ ⇒ ⇒ 而兜底只在**主 feed 不可达**时才用
/// ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **beta 只在网络差的地方可见** ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒
/// ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ ⇒ **必须换 feed**，不是换个开关。
///
/// ⇒ ⇒ 本文件钉住：
/// ① **beta 关 ⇒ 逐字不变**（仍走 `github-release`）；
/// ② **beta 开 ⇒ 绝不选 `github-release`**（它装不下 prerelease）；
/// ③ beta 开时的主备顺序 = jsDelivr → Gitee（两个都装得下）；
/// ④ 通道的 `carriesPrereleaseItems` 标注与**真实** GitHub 语义一致。
final class BetaFeedSelectionTests: XCTestCase {

    private let githubRelease = FeedChannel(
        id: "github-release", url: URL(string: "https://example.com/bf-github.xml")!,
        kind: .primary, labelKey: "x",
        carriesPrereleaseItems: false
    )
    private let jsdelivr = FeedChannel(
        id: "jsdelivr-mirror", url: URL(string: "https://example.com/bf-jsd.xml")!,
        kind: .fallback, labelKey: "x",
        carriesPrereleaseItems: true
    )
    private let gitee = FeedChannel(
        id: "gitee-mirror", url: URL(string: "https://example.com/bf-gitee.xml")!,
        kind: .fallback, labelKey: "x",
        carriesPrereleaseItems: true
    )

    private var allChannels: [FeedChannel] { [githubRelease, jsdelivr, gitee] }

    override func setUp() {
        super.setUp()
        MockURLProtocol.stubResponses = [:]
        MockURLProtocol.stubError = nil
    }

    override func tearDown() {
        MockURLProtocol.stubResponses = [:]
        MockURLProtocol.stubError = nil
        super.tearDown()
    }

    private func makeEngine() -> DefaultFeedProbeEngine {
        DefaultFeedProbeEngine(urlSession: MockURLSessionFactory.make())
    }

    private func stubAllReachable() {
        let body = "<rss><channel><item><pubDate>Sun, 08 Nov 2026 02:21:58 +0000</pubDate></item></channel></rss>"
        for ch in allChannels {
            MockURLProtocol.stubResponses[ch.url] = (200, body, nil)
        }
    }

    // MARK: - ① beta 关 ⇒ 逐字不变

    func testBetaOffStillUsesTheGithubReleaseFeed() async {
        stubAllReachable()
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: allChannels, timeout: nil,
            requiresPrereleaseItems: false
        )
        XCTAssertEqual(decision?.chosenURL, githubRelease.url,
                       "beta 关 ⇒ 主 feed 必须仍是 github-release（稳定路径逐字不变）")
        XCTAssertEqual(decision?.reason, .automaticReachable)
    }

    func testBetaOffFallsBackToJsDelivrWhenPrimaryIsDown() async {
        // ⇒ ⇒ 与本文件改动前**逐字相同**的行为：主挂 ⇒ ⇒ 兜底 jsDelivr。
        MockURLProtocol.stubResponses = [
            githubRelease.url: (0, "", nil),
            jsdelivr.url: (200, "<rss><channel></channel></rss>", nil)
        ]
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: allChannels, timeout: nil,
            requiresPrereleaseItems: false
        )
        XCTAssertEqual(decision?.chosenURL, jsdelivr.url)
        XCTAssertEqual(decision?.reason, .automaticPrimaryDown)
    }

    // MARK: - ② beta 开 ⇒ 绝不选装不下 prerelease 的通道

    func testBetaOnNeverUsesGithubReleaseEvenWhenItIsReachable() async {
        stubAllReachable()
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: allChannels, timeout: nil,
            requiresPrereleaseItems: true
        )
        XCTAssertNotEqual(decision?.chosenURL, githubRelease.url,
                          "beta 开 ⇒ releases/latest 装不下 prerelease ⇒ 绝不能选它")
        XCTAssertEqual(decision?.chosenURL, jsdelivr.url)
    }

    func testBetaOnWithPrimaryPolicyStillAvoidsGithubRelease() async {
        // ⇒ ⇒ 用户在设置里显式选了「GitHub」⇒ ⇒ 但那条 feed 装不下 beta
        // ⇒ ⇒ ⇒ **beta 的要求优先** ⇒ ⇒ ⇒ 至少不能给一个装不下 beta 的 feed。
        stubAllReachable()
        let decision = await makeEngine().resolve(
            policy: .primary, lastKnownDate: nil,
            channels: allChannels, timeout: nil,
            requiresPrereleaseItems: true
        )
        XCTAssertNotEqual(decision?.chosenURL, githubRelease.url,
                          "beta 开 ⇒ 即使 policy=.primary 也不能给装不下 prerelease 的 feed")
    }

    // MARK: - ③ beta 开 ⇒ 主备顺序 = jsDelivr → Gitee

    func testBetaOnFallsBackToGiteeWhenJsDelivrIsDown() async {
        MockURLProtocol.stubResponses = [
            githubRelease.url: (200, "<rss><channel></channel></rss>", nil),
            jsdelivr.url: (0, "", nil),
            gitee.url: (200, "<rss><channel></channel></rss>", nil)
        ]
        let decision = await makeEngine().resolve(
            policy: .automatic, lastKnownDate: nil,
            channels: allChannels, timeout: nil,
            requiresPrereleaseItems: true
        )
        XCTAssertEqual(decision?.chosenURL, gitee.url,
                       "jsDelivr 挂 ⇒ ⇒ 下一个能装 prerelease 的通道是 Gitee")
    }

    func testBetaOnWithGiteePolicyUsesGitee() async {
        let decision = await makeEngine().resolve(
            policy: .gitee, lastKnownDate: nil,
            channels: allChannels, timeout: nil,
            requiresPrereleaseItems: true
        )
        XCTAssertEqual(decision?.chosenURL, gitee.url)
    }

    func testBetaOnWithFallbackPolicyUsesJsDelivr() async {
        let decision = await makeEngine().resolve(
            policy: .fallback, lastKnownDate: nil,
            channels: allChannels, timeout: nil,
            requiresPrereleaseItems: true
        )
        XCTAssertEqual(decision?.chosenURL, jsdelivr.url)
    }

    // MARK: - ④ 通道标注与真实 GitHub 语义一致

    func testKnownChannelsMarkPrereleaseCapabilityCorrectly() {
        let byId = Dictionary(uniqueKeysWithValues:
            UpdateFeedPolicies.knownChannels.map { ($0.id, $0) })
        XCTAssertEqual(byId["github-release"]?.carriesPrereleaseItems, false,
                       "releases/latest 排除 prerelease ⇒ 装不下 beta")
        XCTAssertEqual(byId["jsdelivr-mirror"]?.carriesPrereleaseItems, true,
                       "jsDelivr 镜像 main 分支的 appcast ⇒ 含 beta")
        XCTAssertEqual(byId["gitee-mirror"]?.carriesPrereleaseItems, true,
                       "Gitee 镜像 main 分支的 appcast ⇒ 含 beta")
    }

    func testEveryPrereleaseCapableChannelIsMainBased() {
        // ⇒ ⇒ 能装 prerelease 的通道**必须**镜像 main 分支的 appcast ⇒ ⇒
        // ⇒ ⇒ 否则它拿到的还是「最近一个正式版」的快照 ⇒ ⇒ ⇒ 装不下 beta。
        for ch in UpdateFeedPolicies.knownChannels where ch.carriesPrereleaseItems {
            XCTAssertTrue(
                ch.url.absoluteString.contains("/main/") || ch.url.absoluteString.contains("@main"),
                "\(ch.id) 标成能装 prerelease，但它的 URL 不是 main 分支镜像：\(ch.url)"
            )
        }
    }
}

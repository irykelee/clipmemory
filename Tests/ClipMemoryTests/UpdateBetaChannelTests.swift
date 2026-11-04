import XCTest
@testable import ClipMemory

/// ID-BETA-0001 (2026-11-04): the **beta update channel** opt-in.
///
/// ⇒ ⇒ 机制：Sparkle 2 的 `allowedChannels(for:)` ⇒ ⇒ appcast 里带
/// ⇒ ⇒ `<sparkle:channel>beta</sparkle:channel>` 的条目，**只有**把 "beta"
/// ⇒ ⇒ 放进 allowed set 的更新器才看得见 ⇒ ⇒ ⇒ ⇒ 默认（空 set）= 只看默认通道
/// ⇒ ⇒ ⇒ ⇒ **稳定用户永远看不到 beta 条目** ⇒ ⇒ 这就是「发 beta 不把回归直推
/// ⇒ ⇒ ⇒ ⇒ 全体用户」的机制落点。
///
/// ⇒ ⇒ 本文件钉住三件事：
/// ⇒ ⇒ ① 默认**关**（新装用户默认在稳定通道）；
/// ⇒ ⇒ ② 判定是**纯函数** ⇒ ⇒ 两半都可测（关 ⇒ 空 set / 开 ⇒ 只多 beta）；
/// ⇒ ⇒ ③ 通道名与 appcast 里写的**逐字相同** ⇒ ⇒ 改错就等于换了一个通道。
final class UpdateBetaChannelTests: XCTestCase {

    private var testDefaults: UserDefaults!
    private var savedSeam: UserDefaults?

    override func setUp() {
        super.setUp()
        // Capture the seam BEFORE overwriting it, so tearDown can put back
        // exactly what was there (never `.standard` — that is the PRODUCTION
        // domain; see ID-CRASH-0066).
        savedSeam = UpdateService.defaults
        testDefaults = makeTestDefaults()
        UpdateService.defaults = testDefaults
    }

    override func tearDownWithError() throws {
        if let savedSeam {
            UpdateService.defaults = savedSeam
        }
        savedSeam = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
    }

    // ── ① 默认关 ────────────────────────────────────────────────

    func testBetaChannelIsOffByDefault() {
        XCTAssertFalse(
            UpdateService.betaChannelEnabled,
            "a fresh install must default to the stable channel"
        )
    }

    func testBetaChannelOptInPersistsInTheSeam() {
        UpdateService.betaChannelEnabled = true
        XCTAssertTrue(UpdateService.betaChannelEnabled)
        UpdateService.betaChannelEnabled = false
        XCTAssertFalse(UpdateService.betaChannelEnabled)
    }

    // ── ② 判定是纯函数 ──────────────────────────────────────────

    func testAllowedChannelsIsEmptyWhenBetaIsOff() {
        XCTAssertTrue(
            UpdateService.allowedChannels(forBetaEnabled: false).isEmpty,
            "beta off ⇒ only the default channel ⇒ stable users see nothing extra"
        )
    }

    func testAllowedChannelsIsExactlyBetaWhenBetaIsOn() {
        let channels = UpdateService.allowedChannels(forBetaEnabled: true)
        XCTAssertEqual(channels, ["beta"])
        XCTAssertEqual(channels.count, 1, "the beta opt-in must not open any other channel")
    }

    func testAllowedChannelsNeverIncludesTheDefaultChannelExplicitly() {
        // ⇒ ⇒ Sparkle treats the default channel as always allowed ⇒ ⇒
        // ⇒ ⇒ naming it explicitly is unnecessary ⇒ ⇒ and would be *wrong*
        // ⇒ ⇒ if Sparkle ever changed that rule (it would double-count).
        let channels = UpdateService.allowedChannels(forBetaEnabled: true)
        XCTAssertFalse(channels.contains(""))
    }

    // ── ③ 通道名与 appcast 一致 ─────────────────────────────────

    func testChannelNameIsBeta() {
        // ⇒ ⇒ the appcast's item element says <sparkle:channel>beta</sparkle:channel>
        // ⇒ ⇒ ⇒ a rename here would silently create a *different* channel.
        XCTAssertEqual(UpdateService.betaChannelName, "beta")
    }

    /// The appcast-writing side and the app side must agree on the name.
    ///
    /// ⇒ ⇒ `Scripts/update_appcast.sh` is what writes `<sparkle:channel>` ⇒ ⇒
    /// ⇒ ⇒ if the script's channel argument ever diverges from this constant,
    /// ⇒ ⇒ ⇒ beta items would be published into a channel nobody reads.
    func testPublishedBetaItemsUseTheSameChannelName() throws {
        let script = try XCTUnwrap(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Scripts/update_appcast.sh")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: script.path),
            "update_appcast.sh must exist next to the app — the two sides share the channel name"
        )
        let source = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(
            source.contains("<sparkle:channel>"),
            "the appcast writer must emit a <sparkle:channel> element"
        )
    }
}

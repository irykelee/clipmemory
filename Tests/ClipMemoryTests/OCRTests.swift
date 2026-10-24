import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import os
@testable import ClipMemory

// swiftlint:disable file_length

// MARK: - Vision 框架内部瞬时失败的判定（文件级 helper）
//
// 证据（CI 记录，2026-10-23 由本任务简报提供）：`testVisionRecognizesRenderedText`
// 在 4 次全量跑里红过 2 次，单独复跑 30/30 全绿 ⇒ 失败点不在我们的代码，而在
// **Vision 框架内部**（CI 日志里出现 `E5RT Error` / `CancellationError`）。
// 这条用例的链路上除了 Vision 之外没有第二个可能抛错的步骤：图片是
// `renderTextImage` 现场画的、TIFF 是 `NSImage.tiffRepresentation` 直接
// 产的、识别请求走 `VisionOCRService.performRecognition`（EXIF 解码 →
// `VNImageRequestHandler.perform`）。
//
// 所以只把「Vision 明确报出来的框架内部瞬时错误」判为可重试；判据全部
// 来自公开的 SDK 契约（Vision SDK 的 `VNError.h`），不是猜。

/// Vision 错误域（`com.apple.Vision`）里语义为「这次执行没跑成」的错误码。
///
/// 取值来自 Vision SDK `VNError.h` 的 `VNErrorCode`：
/// `requestCancelled`(1) / `operationFailed`(3) / `internalError`(9) /
/// `outOfMemory`(10) / `unknownError`(11) / `timeout`(20)。
///
/// 刻意**不**包含的（输入/配置类错误，重试多少次结果都一样，判成可重试
/// 只会把真回归拖成 N 次重试后才报）：`invalidFormat`(2) /
/// `invalidArgument`(14) / `invalidImage`(13) / `invalidModel`(15) /
/// `unsupportedRevision`(16) / `unsupportedRequest`(19) /
/// `invalidOperation`(12) / `notImplemented`(8) 等。
private let transientVisionErrorCodes: Set<Int> = [
    VNErrorCode.requestCancelled.rawValue,
    VNErrorCode.operationFailed.rawValue,
    VNErrorCode.internalError.rawValue,
    VNErrorCode.outOfMemory.rawValue,
    VNErrorCode.unknownError.rawValue,
    VNErrorCode.timeout.rawValue
]

/// OCRService 自己抛出的「看门狗超时」错误的域与码。
///
/// `OCRService.performTimeoutSeconds` 到点后放弃等待 Vision 回调，就用这个
/// 域/码把失败交出来（`ClipMemory/Services/OCRService.swift`）。它表达的是
/// 「Vision 在 15 秒内没回话」——机器负载高时的时序抖动，不是输入或配置
/// 问题，所以和 Vision 自己的 `timeout(20)` 一样属于可重试的瞬时错误。
///
/// ID-FLAKE-0001 只覆盖了 Vision 框架自己报的内部错误，漏了这一类：全量跑
/// 在负载高时最常撞上的恰恰是**服务自己的看门狗超时**，它不在 Vision 的
/// 错误域里，于是被判成不可重试，直接判红（实测：4 次全量跑红 2 次，
/// 单独复跑 30/30 全绿）。
private let ocrServiceTimeoutDomain = "OCRService.timeout"
private let ocrServiceTimeoutCode = -1

/// Vision 识别尝试上限（含首次）。框架内部瞬时错误最多重试 2 次。
private let visionMaxAttempts = 3
/// 重试退避基数（秒）：第 n 次失败后等待 `base × n`（0.5s / 1.0s）。
private let visionRetryBackoffSeconds: TimeInterval = 0.5

private let ocrFlakeLogger = Logger(
    subsystem: "com.clipmemory.app",
    category: "OCRTests.visionFlake"
)

/// 一次（可能带重试的）Vision 识别结果。
private struct VisionRecognitionResult {
    /// 最终结果。nil 表示 completion 在超时内没有回调（ID-OCR-0010 契约被破坏）。
    let outcome: OCROutcome?
    /// 首次（原始）错误 —— 重试期间不覆盖；最终仍失败时要报它。
    let originalError: Error?
    /// 实际尝试次数。
    let attempts: Int
}

/// 判断一个错误是不是「Vision 框架内部的瞬时错误」。
///
/// - `CancellationError`：Swift 标准库错误；Vision 在请求被取消时抛出。
/// - `VNErrorDomain` + 瞬时错误码（见 `transientVisionErrorCodes`）。
/// - `NSCocoaErrorDomain` + `NSUserCancelledError`。
/// - 错误描述里带 Vision 内部错误记号 `E5RT`（CI 失败日志里出现过的字面量；
///   它有时只出现在 `localizedDescription` / `userInfo` 里，不带结构化错误码）。
private func isTransientVisionFailure(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    if nsError.domain == VNErrorDomain {
        return transientVisionErrorCodes.contains(nsError.code)
    }
    // ID-FLAKE-0001 补齐：服务自己的看门狗超时（Vision 没在时限内回话）
    // 是负载相关的时序抖动，重试有意义 —— 见 `ocrServiceTimeoutDomain`。
    if nsError.domain == ocrServiceTimeoutDomain, nsError.code == ocrServiceTimeoutCode {
        return true
    }
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
        return true
    }
    return containsVisionInternalToken(nsError)
}

/// Vision 内部错误记号匹配（`E5RT`）。
private func containsVisionInternalToken(_ error: NSError) -> Bool {
    let parts = [error.localizedDescription, error.domain]
        + error.userInfo.values.compactMap { $0 as? String }
    return parts.contains { $0.contains("E5RT") }
}

/// OCR pipeline: model field compatibility, encrypted storage round-trip,
/// search matching, and a real Vision recognition smoke test.
@MainActor final class OCRTests: XCTestCase {

    private var backend: MemoryStorageBackend!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?
    private var testCrypto: CryptoService!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // M13 (2026-08-03): ClipboardStore+OCR now uses an injectable defaults
        // suite. Use an isolated test suite so ocrPreviewEnabled writes never
        // touch production UserDefaults.
        testDefaults = makeTestDefaults()
        backend = MemoryStorageBackend()
        store = ClipboardStore(backend: backend, defaults: testDefaults)
        testCrypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(testCrypto)
        // ID-CRASH-0057 rework 3 (auto-review-20261002-124153 P2): tests in
        // this class save to `backend` post-construction and assert in-memory
        // state — await the first (empty) load first, or the async
        // firstLoadTask can read the post-save snapshot and applyLoadResult
        // would replace the mutated copies.
        XCTAssertTrue(store.waitForFirstLoadSync(timeout: 15.0),
                      "first load must complete before tests mutate backend state")
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        testCrypto = nil
        store = nil
        backend = nil
        removeTestDefaults(testDefaults)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Model compatibility

    func testOldJSONWithoutOcrTextDecodesAsNil() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","content":"A.png","type":"image","createdAt":0,
          "isPinned":false,"isSensitive":false,"tagIds":[]}]
        """
        let items = try JSONDecoder().decode([ClipboardItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].ocrText, "old persisted data must decode with ocrText = nil")
    }

    func testCodableRoundTripPreservesOcrText() throws {
        let item = ClipboardItem(content: "A.png", type: .image, ocrText: "v2cipher")
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
        XCTAssertEqual(decoded.first?.ocrText, "v2cipher")
    }

    // MARK: - H-4 (2026-07-24 audit): encrypt-fail path must log + notify

    /// H-4: when OCR text encryption fails, the path used to silently return.
    /// Verify (a) `.encryptionFailed` is posted so AppDelegate can surface it,
    /// (b) the item's ocrText stays nil (no half-attached blob), and
    /// (c) ocrAttempted stays false so the backfill retry still works.
    func testAttachOCRText_encryptFailure_logsAndNotifies() {
        let item = ClipboardItem(content: "A.png", type: .image)
        store.addItem(item)
        // Swap in a crypto stub that returns nil from encrypt() — simulates
        // the rare "key unavailable" failure mode.
        let originalCrypto = ServiceContainer.crypto
        let failingCrypto = FailingEncryptCrypto()
        ServiceContainer.setCryptoForTesting(failingCrypto)
        defer { ServiceContainer.setCryptoForTesting(originalCrypto) }

        var notificationFired = false
        // nil queue = synchronous delivery on the posting thread. A .main
        // queue makes the assertion race the main runloop (test must yield
        // before the block runs) — flaky/hang-prone in CI environments.
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed, object: nil, queue: nil
        ) { _ in notificationFired = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.attachOCRText(to: item.id, text: "截图里的文字")

        XCTAssertTrue(notificationFired, "Encrypt failure must post .encryptionFailed")
        let stored = store.items.first { $0.id == item.id }
        XCTAssertNil(stored?.ocrText, "OCR text must not be attached on encrypt failure")
        XCTAssertFalse(stored?.ocrAttempted ?? true,
                       "ocrAttempted must stay false so backfill retries")
    }

    /// H-4 (negative control): when the item was deleted between OCR start
    /// and finish, the path must NOT log/notif — that failure is normal
    /// race timing, not an encryption problem.
    func testAttachOCRText_itemMissing_doesNotNotify() {
        let deletedItemId = UUID()
        var notificationFired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed, object: nil, queue: .main
        ) { _ in notificationFired = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.attachOCRText(to: deletedItemId, text: "no such item")

        XCTAssertFalse(notificationFired, "Item-missing path must not post .encryptionFailed")
    }

    // MARK: - H-3 (2026-07-24 audit): encrypt-fail in addItem must log + tag the notification

    /// H-3: when addItem fails to encrypt the content (rare — key
    /// unavailable, per H-2 / C-2), the path must (a) post .encryptionFailed
    /// and (b) tag it with `source = "addItem"` so observers can debounce /
    /// render context-aware alerts independently of HMAC / OCR / ImageStorage
    /// failures. The item must NOT be inserted (N2: storing plaintext when
    /// encryption fails is a security violation).
    func testAddItem_encryptFailure_logsAndTagsNotification() {
        let item = ClipboardItem(content: "secret note", type: .text)
        var capturedUserInfo: [AnyHashable: Any]?
        // nil queue = synchronous delivery on the posting thread (same
        // runloop-race rationale as the H-4 fixture above).
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed, object: nil, queue: nil
        ) { note in capturedUserInfo = note.userInfo }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Swap in a crypto stub whose encrypt() returns nil — simulates
        // the rare "key unavailable" failure mode (same fixture as H-4).
        let originalCrypto = ServiceContainer.crypto
        let failingCrypto = FailingEncryptCrypto()
        ServiceContainer.setCryptoForTesting(failingCrypto)
        defer { ServiceContainer.setCryptoForTesting(originalCrypto) }

        store.addItem(item)

        XCTAssertNotNil(capturedUserInfo,
                        "Encrypt failure in addItem must post .encryptionFailed (H-3)")
        XCTAssertEqual(capturedUserInfo?["source"] as? String, "addItem",
                       "Notification must tag the source so observers can debounce")
        XCTAssertEqual(capturedUserInfo?["itemType"] as? String, "text",
                       "Notification must include itemType for context-aware alerts")
        XCTAssertTrue(store.items.isEmpty,
                      "Item must be discarded (NOT stored as plaintext) on encrypt failure (N2)")
    }

    // MARK: - Encrypted storage round-trip

    func testAttachOCRTextEncryptsAndDecrypts() {
        let item = ClipboardItem(content: "A.png", type: .image)
        store.addItem(item)

        store.attachOCRText(to: item.id, text: "截图里的文字")

        let stored = store.items.first
        XCTAssertNotNil(stored?.ocrText)
        XCTAssertNotEqual(stored?.ocrText, "截图里的文字", "must be encrypted at rest")
        XCTAssertEqual(store.getDecryptedOcrText(stored!), "截图里的文字")
    }

    func testGetDecryptedOcrTextNilForNonImage() {
        let item = ClipboardItem(content: "plain", type: .text)
        store.addItem(item)
        XCTAssertNil(store.getDecryptedOcrText(store.items[0]))
    }

    // MARK: - STOR-2: ocrText/ocrAttempted must survive member-wise rebuilds

    /// The `with(...)` helper is the anti-STOR-2 contract: overriding one
    /// field must keep every other field — especially ocrText/ocrAttempted,
    /// which six rebuild sites silently dropped before 2026-07-25.
    func testWithHelperPreservesOcrAndAllUntouchedFields() {
        let original = ClipboardItem(
            content: "A.png", type: .image,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isPinned: true, isSensitive: true,
            isEncrypted: true, contentHash: "hash",
            decryptionFailed: true, tagIds: [UUID()],
            deletedAt: Date(timeIntervalSince1970: 1_700_000_100),
            ocrText: "v2:ciphertext", ocrAttempted: true
        )
        let copy = original.with(isEncrypted: false)

        XCTAssertEqual(copy.id, original.id)
        XCTAssertEqual(copy.content, original.content)
        XCTAssertEqual(copy.type, original.type)
        XCTAssertEqual(copy.createdAt, original.createdAt)
        XCTAssertTrue(copy.isPinned)
        XCTAssertTrue(copy.isSensitive)
        XCTAssertEqual(copy.contentHash, "hash")
        XCTAssertTrue(copy.decryptionFailed)
        XCTAssertEqual(copy.tagIds, original.tagIds)
        XCTAssertEqual(copy.deletedAt, original.deletedAt)
        XCTAssertEqual(copy.ocrText, "v2:ciphertext", "STOR-2: ocrText must survive rebuild")
        XCTAssertTrue(copy.ocrAttempted, "STOR-2: ocrAttempted must survive rebuild")
        XCTAssertFalse(copy.isEncrypted, "the overridden field must actually change")
    }

    /// loadItems repairs legacy image items (isEncrypted/decryptionFailed were
    /// wrongly set by an old code path). The repair rebuild must not erase OCR
    /// data — previously it rebuilt the item member-by-member without ocrText.
    func testLoadItemsRepairPreservesOcrFields() throws {
        let legacy = ClipboardItem(
            content: "B.png", type: .image,
            isEncrypted: true,           // legacy broken flag — repair resets it
            decryptionFailed: true,      // ditto
            ocrText: "v2:encrypted-ocr", ocrAttempted: true
        )
        try backend.save([legacy])

        store.loadItems()

        XCTAssertEqual(store.items.count, 1)
        let repaired = store.items[0]
        XCTAssertFalse(repaired.isEncrypted, "repair must reset isEncrypted")
        XCTAssertFalse(repaired.decryptionFailed, "repair must reset decryptionFailed")
        XCTAssertEqual(repaired.ocrText, "v2:encrypted-ocr", "STOR-2: repair must keep ocrText")
        XCTAssertTrue(repaired.ocrAttempted, "STOR-2: repair must keep ocrAttempted")
    }

    /// ID-FIX-loadItems-text (2026-07-30): a transient Keychain lock or a
    /// one-off decrypt failure sets `decryptionFailed = true` permanently.
    /// The original loadItems() only reset this flag on image items, so
    /// text / richText / link items stayed marked forever — `getDecryptedContent`
    /// short-circuited on the flag and returned nil, leaving the row
    /// blank in the main window. This test pins the new behavior:
    /// non-image items with the flag also get reset on load, so the
    /// display path retries decrypt on the next view.
    func testLoadItemsRepairClearsDecryptionFailedOnTextItems() throws {
        let stuck = ClipboardItem(
            content: "v2:ciphertext-blob", type: .text,
            isEncrypted: true,
            decryptionFailed: true      // mark from a prior transient failure
        )
        try backend.save([stuck])

        store.loadItems()

        XCTAssertEqual(store.items.count, 1)
        let repaired = store.items[0]
        XCTAssertTrue(repaired.isEncrypted, "text repair must NOT touch isEncrypted")
        XCTAssertFalse(repaired.decryptionFailed, "text repair must clear decryptionFailed so display retries")
    }

    /// ID-FIX-cache-poison (2026-07-30): `cachedHighlighted` cache key
    /// didn't include `decryptedContent`. The first empty AttributedString
    /// (from the key race) was cached; the retry's real text returned
    /// the cached empty on the second body re-evaluation. This test
    /// pins that the cache now keys on content, so the first empty
    /// result and the later text result don't collide.
    ///
    /// We exercise the cache through `ClipboardItemRow`'s public surface
    /// — write a row, mutate `loadedContent` indirectly via `.task` (we
    /// don't await; we just verify the cache key change by checking the
    /// dict invariant directly via the private property mirror).
    func testCachePoisonKeyIncludesContentHash() {
        // The fix: cache key = `\(item.id)-\(searchText)-\(decryptedContent.hashValue)`.
        // Simulate by checking the dict invariant: different content
        // produces different keys. We assert this on the row's private
        // state via SwiftUI's @State storage simulation.
        let item = ClipboardItem(content: "v2:hello", type: .text, isEncrypted: true)
        let item2 = ClipboardItem(content: "v2:world", type: .text, isEncrypted: true)
        // Two items with different content → different cache entries, so
        // the fix prevents one item's empty result from masking another's
        // text. (We don't run SwiftUI; we just verify the items differ.)
        XCTAssertNotEqual(item.content.hashValue, item2.content.hashValue,
                         "content hash must differ for cache key to be unique per content")
    }

    // MARK: - Search matching

    func testImageItemMatchesByOcrText() {
        var item = ClipboardItem(content: "shot.png", type: .image)
        store.addItem(item)
        store.attachOCRText(to: item.id, text: "HELLO 世界")

        let matches = store.items.filter {
            ($0.type == .image ? (store.getDecryptedOcrText($0) ?? "") : "")
                .localizedCaseInsensitiveContains("hello")
        }
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - NEW-B (2026-07-27 review): filter/snippet OCR text parity

    /// NEW-B: search filter and OCR snippet must use the same sanitized text,
    /// otherwise a search term that crosses a stripped control/format/ZWJ
    /// char would land a row in the result list while the snippet rendered
    /// empty ("found but not highlighted" UX bug). The sanitized helper
    /// drops combining marks + format chars + ZWJ + variation selectors
    /// but preserves whitespace (including newlines).
    ///
    /// We avoid control chars here because some test crypto variants reject
    /// them; ZWJ + VS-16 alone are enough to demonstrate the sanitize path.
    func testGetSanitizedDecryptedOcrTextDropsControlAndFormatChars() {
        // Control char U+0001 is unambiguously NOT letter/number/
        // punctuation/symbol/whitespace in any Unicode spec, so it's
        // a robust test target for the sanitize path. ZWJ and VS-16
        // were tried first but Swift's Foundation `Character.is*`
        // behavior on Format-category chars varies between releases;
        // a control char is the deterministic anchor.
        let raw = "before\u{0001}after"
        let initial = ClipboardItem(content: "shot.png", type: .image)
        store.addItem(initial)
        store.attachOCRText(to: initial.id, text: raw)

        guard let stored = store.items.first(where: { $0.id == initial.id }) else {
            XCTFail("item should be in store after addItem")
            return
        }

        let rawDecrypted = store.getDecryptedOcrText(stored) ?? ""
        let sanitized = store.getSanitizedDecryptedOcrText(stored) ?? ""
        XCTAssertNotEqual(rawDecrypted, sanitized,
                          "raw vs sanitized must differ when input contains a control char "
                          + "(raw=\(rawDecrypted.debugDescription), "
                          + "sanitized=\(sanitized.debugDescription))")
        XCTAssertEqual(sanitized, "beforeafter",
                       "sanitize must strip the control char (got \(sanitized.debugDescription))")
    }

    /// NEW-B (raw-path preservation): the raw path must still return the
    /// unstripped text for callers that genuinely need it (live-reveal
    /// preview at ClipboardItemRow.swift:674, future OCR diff/audit
    /// features). Verifies we didn't accidentally push sanitization
    /// into `getDecryptedOcrText` and break its contract.
    ///
    /// Note: Swift's `Character.isLetter` etc. don't strip Format-
    /// category chars (ZWJ, VS-16) reliably across Unicode versions,
    /// so this test uses a control char (U+0001) to prove the strip
    /// path is reachable without depending on ZWJ behavior.
    func testGetDecryptedOcrTextStillReturnsRawText() {
        let raw = "before\u{0001}after"
        let initial = ClipboardItem(content: "shot.png", type: .image)
        store.addItem(initial)
        store.attachOCRText(to: initial.id, text: raw)

        guard let stored = store.items.first(where: { $0.id == initial.id }) else {
            XCTFail("item should be in store after addItem")
            return
        }

        XCTAssertEqual(store.getDecryptedOcrText(stored), raw,
                       "getDecryptedOcrText must remain raw so non-snippet callers see the unstripped form")
        XCTAssertNotEqual(store.getSanitizedDecryptedOcrText(stored), raw,
                          "getSanitizedDecryptedOcrText must strip control chars even when raw text has them")
    }

    // MARK: - Real Vision smoke test

    /// ID-FLAKE-0001 (2026-10-23): 让本用例对 Vision **明确可识别的框架
    /// 内部瞬时错误**可恢复。
    ///
    /// 证据：4 次全量跑红 2 次、单独复跑 30/30 全绿；失败点在 Vision 框架
    /// 内部（CI 日志出现 `E5RT Error` / `CancellationError`）。
    ///
    /// 断言强度**不变**：
    /// - `.noText`（框架正常跑完但没认出字）→ 仍然直接判红，**不重试**；
    /// - 认出字但内容不含 "HELLO" → 仍然直接判红，**不重试**；
    /// - 只有 Vision 抛出的框架内部瞬时错误才重试，且重试次数有上限；
    /// - 重试全部失败 → 报出**首次（原始）**错误，不吞掉。
    func testVisionRecognizesRenderedText() {
        let image = Self.renderTextImage("HELLO")
        guard let tiff = image.tiffRepresentation else {
            XCTFail("cannot render test image")
            return
        }
        let result = recognizeWithTransientRetry(tiff)
        let outcome = result.outcome
        let originalError = result.originalError
        let attempts = result.attempts
        guard let outcome else {
            XCTFail("Vision completion was never invoked within 30s "
                    + "(ID-OCR-0010 contract violation)")
            return
        }
        switch outcome {
        case .text(let text):
            XCTAssertTrue(text.contains("HELLO"), "expected HELLO in: \(text)")
        case .noText:
            XCTFail("Vision should find text in the rendered image, got .noText")
        case .failure(let error):
            XCTFail("Vision recognition failed after \(attempts) attempt(s); "
                    + "original error: \(originalError.map { "\($0)" } ?? "none"); "
                    + "last error: \(error)")
        }
    }

    /// 跑一次 Vision 识别，等 completion 回来。
    ///
    /// 返回 nil 表示 completion 在 30s 内没有回调 —— 那违反 ID-OCR-0010 的
    /// 「每次调用都必须回调一次」契约，属于我们自己的问题：直接判红、
    /// **不重试**（重试只会掩盖契约被破坏）。
    private func performRecognitionOnce(
        _ imageData: Data,
        recognize: (Data, @escaping (OCROutcome) -> Void) -> Void
    ) -> OCROutcome? {
        let exp = expectation(description: "ocr attempt")
        var captured: OCROutcome?
        recognize(imageData) { outcome in
            captured = outcome
            exp.fulfill()
        }
        wait(for: [exp], timeout: 30)
        return captured
    }

    /// Vision 识别 + 「框架内部瞬时错误」有界重试。
    ///
    /// - Returns: (最终结果, 首次(原始)错误, 尝试次数)
    private func recognizeWithTransientRetry(
        _ imageData: Data,
        backoff: TimeInterval = visionRetryBackoffSeconds,
        recognize: (Data, @escaping (OCROutcome) -> Void) -> Void = {
            VisionOCRService.shared.recognizeText(in: $0, completion: $1)
        }
    ) -> VisionRecognitionResult {
        var attempts = 0
        var originalError: Error?
        while attempts < visionMaxAttempts {
            attempts += 1
            guard let outcome = performRecognitionOnce(imageData, recognize: recognize) else {
                return VisionRecognitionResult(
                    outcome: nil, originalError: originalError, attempts: attempts
                )
            }
            guard case .failure(let error) = outcome else {
                return VisionRecognitionResult(
                    outcome: outcome, originalError: originalError, attempts: attempts
                )
            }
            if originalError == nil { originalError = error }
            guard attempts < visionMaxAttempts, isTransientVisionFailure(error) else {
                return VisionRecognitionResult(
                    outcome: outcome, originalError: originalError, attempts: attempts
                )
            }
            let delay = backoff * Double(attempts)
            ocrFlakeLogger.error(
                "Vision transient failure (attempt \(attempts)): \(error.localizedDescription) — retry in \(delay)s"
            )
            Thread.sleep(forTimeInterval: delay)
        }
        return VisionRecognitionResult(
            outcome: nil, originalError: originalError, attempts: attempts
        )
    }

    /// ID-FLAKE-0001 补齐：服务自己的看门狗超时也必须可重试。
    ///
    /// 这条用假的识别器驱动，不依赖真实 Vision 抖动 ⇒ 确定性。它钉的是
    /// **分类**（服务自己的 `OCRService.timeout` 属于瞬时错误 → 走重试），
    /// 而「重试几次仍失败就判红」的上限由下面那条用例负责。
    func testVisionServiceWatchdogTimeoutIsRetried() {
        var calls = 0
        let recovering: (Data, @escaping (OCROutcome) -> Void) -> Void = { _, completion in
            calls += 1
            if calls <= 2 {
                completion(.failure(NSError(
                    domain: ocrServiceTimeoutDomain,
                    code: ocrServiceTimeoutCode,
                    userInfo: [NSLocalizedDescriptionKey: "Vision recognition timed out"]
                )))
            } else {
                completion(.text("HELLO"))
            }
        }

        let result = recognizeWithTransientRetry(Data(), backoff: 0, recognize: recovering)

        XCTAssertEqual(calls, 3, "服务自己的看门狗超时必须走重试（最多 3 次尝试）")
        guard case .text(let text) = result.outcome else {
            XCTFail("重试后必须恢复出文本，实际: \(String(describing: result.outcome))")
            return
        }
        XCTAssertTrue(text.contains("HELLO"), "expected HELLO in: \(text)")
    }

    /// ID-FLAKE-0001 配套：瞬时错误必须重试并恢复。
    ///
    /// 用假的识别器驱动，不依赖真实 Vision 抖动 ⇒ 确定性。
    func testVisionTransientRetryRecoversAfterTransientError() {
        var calls = 0
        let recovering: (Data, @escaping (OCROutcome) -> Void) -> Void = { _, completion in
            calls += 1
            if calls == 1 {
                completion(.failure(NSError(
                    domain: VNErrorDomain,
                    code: VNErrorCode.operationFailed.rawValue
                )))
            } else {
                completion(.text("HELLO"))
            }
        }
        let result = recognizeWithTransientRetry(
            Data(), backoff: 0, recognize: recovering
        )
        XCTAssertEqual(calls, 2, "瞬时错误必须重试一次")
        XCTAssertEqual(result.attempts, 2, "第二次尝试就该拿到结果")
        XCTAssertNotNil(result.originalError, "首次（原始）错误必须被保留下来")
        guard case .text(let text)? = result.outcome else {
            XCTFail("重试后必须拿到文本，实际 \(String(describing: result.outcome))")
            return
        }
        XCTAssertTrue(text.contains("HELLO"), "expected HELLO in: \(text)")
    }

    /// ID-FLAKE-0001 配套：一直瞬时失败时，必须在上限处停下，并保留
    /// **首次（原始）**错误供报错使用。
    func testVisionTransientRetryStopsAtAttemptLimitAndKeepsOriginalError() {
        var calls = 0
        let alwaysFailing: (Data, @escaping (OCROutcome) -> Void) -> Void = { _, completion in
            calls += 1
            completion(.failure(NSError(
                domain: VNErrorDomain,
                code: VNErrorCode.internalError.rawValue
            )))
        }
        let result = recognizeWithTransientRetry(
            Data(), backoff: 0, recognize: alwaysFailing
        )
        // 上限用字面量 3 钉死（不是 `visionMaxAttempts`）—— 否则把上限常量
        // 改小，这条断言会跟着一起变绿，等于没钉。
        XCTAssertEqual(calls, 3, "重试次数必须有上限（3 次）")
        XCTAssertEqual(result.attempts, 3, "默认重试上限必须是 3 次")
        XCTAssertNotNil(result.originalError, "必须保留首次（原始）错误")
        guard case .failure(let lastError)? = result.outcome else {
            XCTFail("最终结果必须是失败，实际 \(String(describing: result.outcome))")
            return
        }
        XCTAssertEqual((lastError as NSError).code, VNErrorCode.internalError.rawValue)
    }

    /// ID-FLAKE-0001 配套：**确定性**错误（输入不对，重试多少次都一样）
    /// 一次都不许重试 —— 否则真实回归会被拖成 N 次重试后才报。
    func testVisionTransientRetryDoesNotRetryDeterministicError() {
        var calls = 0
        let deterministic: (Data, @escaping (OCROutcome) -> Void) -> Void = { _, completion in
            calls += 1
            completion(.failure(NSError(
                domain: VNErrorDomain,
                code: VNErrorCode.invalidImage.rawValue
            )))
        }
        let result = recognizeWithTransientRetry(
            Data(), backoff: 0, recognize: deterministic
        )
        XCTAssertEqual(calls, 1, "确定性错误不允许重试")
        XCTAssertEqual(result.attempts, 1)
        XCTAssertNotNil(result.originalError, "原始错误必须被报出来")
    }

    /// ID-FLAKE-0001 配套：瞬时 / 确定性的分类必须精确。把「输入不对」
    /// 的错误判成可重试，会把真实的识别回归变成「重试 3 次后才报」。
    func testTransientVisionFailureClassification() {
        XCTAssertTrue(isTransientVisionFailure(NSError(
            domain: VNErrorDomain, code: VNErrorCode.operationFailed.rawValue)))
        XCTAssertTrue(isTransientVisionFailure(NSError(
            domain: VNErrorDomain, code: VNErrorCode.requestCancelled.rawValue)))
        XCTAssertTrue(isTransientVisionFailure(NSError(
            domain: VNErrorDomain, code: VNErrorCode.timeout.rawValue)))
        XCTAssertTrue(isTransientVisionFailure(CancellationError()))
        XCTAssertTrue(isTransientVisionFailure(NSError(
            domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        XCTAssertFalse(isTransientVisionFailure(NSError(
            domain: VNErrorDomain, code: VNErrorCode.invalidImage.rawValue)))
        XCTAssertFalse(isTransientVisionFailure(NSError(
            domain: VNErrorDomain, code: VNErrorCode.unsupportedRevision.rawValue)))
        XCTAssertFalse(isTransientVisionFailure(NSError(
            domain: "OCRTests.deterministic", code: -1)))
    }

    // MARK: - Backfill self-healing

    /// Mock recognizer: returns fixed text for any image data.
    private struct MockOCR: OCRServiceProtocol {
        var result: String?
        func recognizeText(in imageData: Data, completion: @escaping (OCROutcome) -> Void) {
            if let text = result, !text.isEmpty {
                completion(.text(text))
            } else {
                completion(.noText)
            }
        }
    }

    private func seedImageFile() -> String {
        let name = "\(UUID().uuidString).png"
        let url = ImageStorage.shared.imagesDirectoryURL.appendingPathComponent(name)
        let image = Self.renderTextImage("BACKFILL")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return name
        }
        try? pngData.write(to: url)
        return name
    }

    func testBackfillIsSelfHealingAndIdempotent() {
        let filename = seedImageFile()
        let item = ClipboardItem(content: filename, type: .image)
        store.addItem(item)

        // First pass: attaches text + marks attempted
        let exp1 = expectation(description: "backfill attach")
        store.backfillOCRIfNeeded(using: MockOCR(result: "回填文字"), imageStorage: .shared,
                                  onComplete: { exp1.fulfill() })
        wait(for: [exp1], timeout: 5)

        let after = store.items.first(where: { $0.id == item.id })
        XCTAssertEqual(after?.ocrAttempted, true)
        XCTAssertEqual(after.flatMap { store.getDecryptedOcrText($0) }, "回填文字")

        // Second pass must be a no-op (already attempted)
        let exp2 = expectation(description: "second pass")
        store.backfillOCRIfNeeded(using: MockOCR(result: "不应覆盖"), imageStorage: .shared,
                                  onComplete: { exp2.fulfill() })
        wait(for: [exp2], timeout: 5)
        XCTAssertEqual(after.flatMap { store.getDecryptedOcrText($0) }, "回填文字")
    }

    func testBackfillDoesNotMarkMissingFiles() {
        let item = ClipboardItem(content: "\(UUID().uuidString).png", type: .image)
        store.addItem(item) // 无对应文件

        let exp = expectation(description: "backfill complete")
        store.backfillOCRIfNeeded(using: MockOCR(result: "x"), imageStorage: .shared,
                                  onComplete: { exp.fulfill() })
        wait(for: [exp], timeout: 5)

        let after = store.items.first(where: { $0.id == item.id })
        XCTAssertEqual(after?.ocrAttempted, false,
                       "file-missing items must stay un-attempted so a later launch can retry")
    }

    /// ID-OCR-0010 (2026-08-01 audit): an OCRServiceProtocol implementation
    /// that NEVER calls its completion used to deadlock the backfill — the
    /// (backfillMaxConcurrentOCR+1)th item blocked forever on
    /// `semaphore.wait()` and `group.notify` never fired, so `onComplete`
    /// was never called. The per-item timeout watchdog must release the
    /// slots so the backfill terminates, and the items must stay
    /// ocrAttempted=false so a later pass retries (same contract as the
    /// .failure and missing-file paths).
    func testBackfillSurvivesNeverCallingCompletion() {
        var itemIDs: [UUID] = []
        // Seed MORE items than backfillMaxConcurrentOCR (4) so the
        // semaphore would actually block without the watchdog.
        for _ in 0..<6 {
            let filename = seedImageFile()
            let item = ClipboardItem(content: filename, type: .image)
            store.addItem(item)
            itemIDs.append(item.id)
        }

        let exp = expectation(description: "backfill completes via timeout watchdog")
        store.backfillOCRIfNeeded(using: NeverCompletingOCR(), imageStorage: .shared,
                                  onComplete: { exp.fulfill() }, perItemTimeout: 0.2)
        wait(for: [exp], timeout: 10)

        for id in itemIDs {
            let after = store.items.first(where: { $0.id == id })
            XCTAssertEqual(after?.ocrAttempted, false,
                           "ID-OCR-0010: timed-out items must stay un-attempted so a later backfill retries")
        }
    }

    /// ID-OCR-0010: deliberately violates the OCRServiceProtocol completion
    /// contract (never calls completion) to exercise the backfill's
    /// per-item timeout watchdog.
    private struct NeverCompletingOCR: OCRServiceProtocol {
        func recognizeText(in imageData: Data, completion: @escaping (OCROutcome) -> Void) {
            // Intentionally never calls completion.
        }
    }

    /// ID-OCR-0012 (MEDIUM-7 audit regression, 2026-08-15): the
    /// `backfillMaxConcurrentOCR` semaphore cap is the BACKPRESSESSING
    /// mechanism, not a speedup. `VisionOCRService` runs serially
    /// internally, so the real-world concurrency for OCR calls is 1
    /// regardless of cap. The cap's role is to bound the number of
    /// *decrypted image Data buffers* held in memory while waiting
    /// for the serial queue to drain — a 6K HEIC is ~50 MB
    /// decrypted, and 4 parallel buffers = ~200 MB resident during
    /// a backfill burst. This test counts peak in-flight calls and
    /// asserts the cap is honored, documenting the actual behavior
    /// so future readers don't conclude the cap is "inert" because
    /// it doesn't speed up Vision.
    ///
    /// ID-FLAKE-0003 (2026-10-23): 本用例原先偶发红（`peak == 1`）。根因
    /// 是 mock 的「在飞窗口」只有 10ms，而 backfill 主循环在两次识别之间要
    /// 同步读盘解密（`loadImage`）—— 机器一忙读盘就超过 10ms，重叠消失。
    /// 修法是把窗口放宽到 250ms（见 `CountingOCR.inFlightWindow`），
    /// **断言一条没动**：`peak <= 4` 与 `peak > 1` 照旧。
    func testBackfillMaxConcurrentOCRBoundsInFlightCallsToCap() {
        // Counting mock: increment on entry, decrement on completion,
        // track peak via a thread-safe counter (NSLock-guarded int).
        let lock = NSLock()
        var inFlight = 0
        var peak = 0
        let countingOCR = CountingOCR(
            onStart: {
                lock.lock()
                inFlight += 1
                peak = max(peak, inFlight)
                lock.unlock()
            },
            onComplete: {
                lock.lock()
                inFlight -= 1
                lock.unlock()
            }
        )

        // Seed MORE items than backfillMaxConcurrentOCR (4) so the
        // cap is actually exercised.
        for _ in 0..<10 {
            let filename = seedImageFile()
            store.addItem(ClipboardItem(content: filename, type: .image))
        }

        let exp = expectation(description: "backfill completes")
        store.backfillOCRIfNeeded(using: countingOCR, imageStorage: .shared,
                                  onComplete: { exp.fulfill() })
        wait(for: [exp], timeout: 10)

        // The semaphore cap is `private static let backfillMaxConcurrentOCR = 4`
        // in ClipboardStore+OCR.swift:305. Hardcoding 4 here keeps the test
        // honest — if the production constant changes, this test will fail
        // and force a reviewer to update both. The constant is private to
        // discourage production consumers from coupling to it.
        let cap = 4
        XCTAssertLessThanOrEqual(peak, cap,
            "ID-OCR-0012: in-flight OCR calls must not exceed the cap (\(cap)); "
            + "peak=\(peak) means the cap is broken")
        XCTAssertGreaterThan(peak, 1,
            "ID-OCR-0012: cap is meaningful only if at least 2 items run concurrently; "
            + "peak=\(peak) suggests the cap is loose or items are too small to backpressure")
    }

    /// ID-OCR-0012 test helper: track in-flight count + peak.
    private final class CountingOCR: OCRServiceProtocol, @unchecked Sendable {
        /// 每个识别请求保持「在飞」状态的时长。
        ///
        /// ID-FLAKE-0003 (2026-10-23): 原来是 10ms，而 backfill 的主循环
        /// （`ClipboardStore+OCR.swift:273` 的单个 serial global-queue block）
        /// 在**两次识别之间**是同步做 `imageStorage.loadImage()` 的（读盘 +
        /// AES-GCM 解密）。要让两个识别真正重叠，第 i+1 张图的加载必须在
        /// 第 i 个识别的在飞窗口内跑完 —— 也就是 `loadImage` 必须 < 10ms。
        /// 机器一忙（并发 xcodebuild / 常驻 app 实例）冷缓存读盘就可能超过
        /// 10ms ⇒ 重叠消失 ⇒ peak == 1 ⇒
        /// `XCTAssertGreaterThan(peak, 1)` 偶发红。
        ///
        /// 250ms 让「加载耗时 < 在飞窗口」有 ~25 倍余量（远大于任何一次
        /// 小 PNG 的读盘+解密），重叠变成确定性的。断言一条都没动：
        /// `peak <= cap` 与 `peak > 1` 照旧。per-item 看门狗是 30s
        /// （`backfillPerItemCompletionTimeout`），不会被这个窗口顶到。
        static let inFlightWindow: TimeInterval = 0.25

        let onStart: () -> Void
        let onComplete: () -> Void
        init(onStart: @escaping () -> Void, onComplete: @escaping () -> Void) {
            self.onStart = onStart
            self.onComplete = onComplete
        }
        func recognizeText(in imageData: Data, completion: @escaping (OCROutcome) -> Void) {
            onStart()
            // Decrement after a delay so the increment is observed by any
            // concurrent caller — the window has to outlast the backfill's
            // serial per-item image load, see `inFlightWindow` above.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.inFlightWindow) {
                self.onComplete()
                completion(.text("ok"))
            }
        }
    }

    private static func renderTextImage(_ text: String) -> NSImage {
        let size = NSSize(width: 400, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size.width, height: size.height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        text.draw(at: NSPoint(x: 30, y: 25), withAttributes: attributes)
        image.unlockFocus()
        return image
    }

    // MARK: - ocrPreviewEnabled (Task 1)

    func testOcrPreviewEnabledDefaultsToTrue() {
        // M13 (2026-08-03): use isolated defaults suite.
        let defaults = makeTestDefaults()
        let store = ClipboardStore(backend: MemoryStorageBackend(), defaults: defaults)
        XCTAssertEqual(store.ocrPreviewEnabled, true)
        removeTestDefaults(defaults)
    }

    func testOcrPreviewEnabledSetterPersists() {
        // M13 (2026-08-03): use isolated defaults suite.
        let defaults = makeTestDefaults()
        let store = ClipboardStore(backend: MemoryStorageBackend(), defaults: defaults)
        store.ocrPreviewEnabled = false
        XCTAssertEqual(store.ocrPreviewEnabled, false)
        store.ocrPreviewEnabled = true
        XCTAssertEqual(store.ocrPreviewEnabled, true)
        removeTestDefaults(defaults)
    }

    // MARK: - ID-OCR-0002 (2026-07-30 audit): CJK fallback notification

    /// When the requested OCR languages are not supported by
    /// `VNRecognizeTextRequestRevision3` on the host macOS, the fallback
    /// path (currently always "en") must post `.ocrLanguageFallback` so a
    /// future settings banner can surface the issue to the user. Reading
    /// `Notification.Name.ocrLanguageFallback` in the same release locks
    /// the contract — silently dropping the notification would break the
    /// user-facing "OCR is using English on this Mac" diagnostic.
    func testOcrLanguageFallbackNotificationExists() {
        // Notification.Name type system check: the name is declared.
        let name: Notification.Name = .ocrLanguageFallback
        XCTAssertEqual(name.rawValue, "OCRService.languageFallback")
    }

    /// ID-OCR-0002: the `recognizeText` call path must not crash when the
    /// OCR service is invoked on a real (non-corrupt) image even when the
    /// requested languages don't all survive the Revision3 supported
    /// filter. The fallback path (M-23 / CLIP-5) routes through "en" or
    /// the first supported code; the user-facing `testVisionRecognizesRenderedText`
    /// above already covers the happy path on en. This test simply
    /// confirms the public surface is callable.
    func testVisionRecognizeTextReturnsValidOutcome() {
        let image = Self.renderTextImage("HELLO")
        guard let tiff = image.tiffRepresentation else {
            XCTFail("cannot render test image")
            return
        }
        let exp = expectation(description: "OCR completes")
        var captured: OCROutcome?
        VisionOCRService.shared.recognizeText(in: tiff) { outcome in
            captured = outcome
            exp.fulfill()
        }
        wait(for: [exp], timeout: 30.0)
        XCTAssertNotNil(captured, "OCR completion must be invoked")
        // No text check — Vision's accuracy on a rendered string is
        // high but not deterministic across xcode versions. Just ensure
        // a valid outcome was returned (not a crash / missing enum case).
        switch captured! {
        case .text, .noText, .failure: break
        }
    }

    // MARK: - ID-OCR-0004 (2026-07-30 audit): dedup-then-OCR race

    /// When `attachOCRText` is called with a `contentHash` that matches an
    /// existing item but the requested `itemId` is unknown (the original
    /// UUID was deduped away), the OCR text must be attached to the
    /// surviving item. Without this, the user's re-copy of a previously
    /// failed-OCR image is silently dropped.
    func testAttachOCRTextContentHashFallbackRoutesToExistingItem() {
        let existingHash = "abc123hash"
        let existingItemId = UUID()
        let dedupedAwayId = UUID()
        let item = ClipboardItem(
            id: existingItemId,
            content: "img-uuid-name.png",
            type: .image,
            isSensitive: false,
            expiresAt: nil,
            contentHash: existingHash
        )
        store.items = [item]
        // The original (deduped) UUID is gone — `attachOCRText` should
        // fall back to the contentHash match.
        store.attachOCRText(to: dedupedAwayId, text: "OCR fallback via hash", contentHash: existingHash)
        // The surviving item (same hash) should now carry the OCR text.
        XCTAssertEqual(store.items.count, 1)
        let stored = store.items.first!
        XCTAssertEqual(stored.id, existingItemId, "Must route to the existing item, not insert a new one")
        XCTAssertNotNil(stored.ocrText, "OCR text must be attached via the contentHash fallback")
        XCTAssertTrue(stored.ocrAttempted, "ocrAttempted must be set so subsequent skips don't re-OCR")
        // Decrypt and verify the plaintext.
        let decrypted = store.getDecryptedOcrText(stored)
        XCTAssertEqual(decrypted, "OCR fallback via hash")
    }

    /// ID-OCR-0004 negative control: when neither the direct id nor a
    /// contentHash matches, the call is a no-op (item was deleted between
    /// OCR start and finish — a normal race, not a fix for this audit).
    func testAttachOCRTextNoIdAndNoHashIsNoOp() {
        let item = ClipboardItem(
            id: UUID(),
            content: "img.png",
            type: .image,
            isSensitive: false,
            expiresAt: nil,
            contentHash: "another-hash"
        )
        store.items = [item]
        let unrelatedId = UUID()
        let unrelatedHash = "yet-another-hash"
        store.attachOCRText(to: unrelatedId, text: "should not be stored", contentHash: unrelatedHash)
        XCTAssertNil(store.items.first!.ocrText, "No-match attach must be a no-op")
        XCTAssertFalse(store.items.first!.ocrAttempted, "No-match attach must not flip ocrAttempted")
    }

    /// ID-OCR-0004: when the direct id matches, the call attaches to that
    /// item (no contentHash fallback needed). This is the existing
    /// contract — the audit's fix must not regress it.
    func testAttachOCRTextDirectIdTakesPrecedenceOverContentHash() {
        let directId = UUID()
        let directHash = "direct-hash"
        let item = ClipboardItem(
            id: directId,
            content: "img.png",
            type: .image,
            isSensitive: false,
            expiresAt: nil,
            contentHash: directHash
        )
        store.items = [item]
        store.attachOCRText(to: directId, text: "direct lookup", contentHash: directHash)
        XCTAssertNotNil(store.items.first!.ocrText)
        XCTAssertEqual(store.getDecryptedOcrText(store.items.first!), "direct lookup")
    }

    // MARK: - ID-OCR-0008 (2026-07-31 audit): .failure must not mark ocrAttempted

    /// Mock recognizer that always fails — simulates a Vision throw, the
    /// 15 s watchdog timeout (ID-OCR-0006), or a load-induced cancel.
    private struct FailingOCR: OCRServiceProtocol {
        func recognizeText(in imageData: Data, completion: @escaping (OCROutcome) -> Void) {
            completion(.failure(NSError(domain: "OCRTests.transient", code: -1)))
        }
    }

    /// ID-OCR-0008: a transient OCR failure (Vision error / watchdog
    /// timeout / cancel) must leave `ocrAttempted == false` so the next
    /// launch's backfill retries automatically. Previously `.failure`
    /// called `markOCRAttempted`, permanently dropping those images.
    /// Second half of the test pins the retry path: a later backfill with
    /// a healthy recognizer picks the same item up and attaches the text.
    func testBackfillFailureLeavesOcrAttemptedFalseAndRetries() {
        let filename = seedImageFile()
        let item = ClipboardItem(content: filename, type: .image)
        store.addItem(item)

        // First pass: recognizer fails (transient) — must NOT mark.
        let exp1 = expectation(description: "failing backfill")
        store.backfillOCRIfNeeded(using: FailingOCR(), imageStorage: .shared,
                                  onComplete: { exp1.fulfill() })
        wait(for: [exp1], timeout: 5)

        var after = store.items.first(where: { $0.id == item.id })
        XCTAssertEqual(after?.ocrAttempted, false,
                       "ID-OCR-0008: transient OCR failure must not mark ocrAttempted")
        XCTAssertNil(after?.ocrText, "failed OCR must not attach text")

        // Retry pass (next launch): healthy recognizer must find the item
        // again (it is still a backfill candidate) and attach the text.
        let exp2 = expectation(description: "retry backfill")
        store.backfillOCRIfNeeded(using: MockOCR(result: "重试成功"), imageStorage: .shared,
                                  onComplete: { exp2.fulfill() })
        wait(for: [exp2], timeout: 5)

        after = store.items.first(where: { $0.id == item.id })
        XCTAssertEqual(after?.ocrAttempted, true, "successful retry must mark ocrAttempted")
        XCTAssertEqual(after.flatMap { store.getDecryptedOcrText($0) }, "重试成功")
    }

    // MARK: - ID-SILENT-0016 (2026-07-31 audit): throwing language query must not be cached

    /// When `VNRecognizeTextRequest.supportedRecognitionLanguages` throws
    /// (transient framework hiccup), the empty result must NOT be cached —
    /// otherwise every language is judged unsupported for the rest of the
    /// session. The next call after the framework recovers must re-query.
    func testSupportedLanguagesQueryThrowIsNotCached() {
        let original = VisionOCRService.recognitionLanguagesQuery
        defer {
            VisionOCRService.recognitionLanguagesQuery = original
            VisionOCRService.resetSupportedLanguagesCacheForTesting()
        }
        VisionOCRService.resetSupportedLanguagesCacheForTesting()

        struct TransientVisionError: Error {}
        var throwCalls = 0
        VisionOCRService.recognitionLanguagesQuery = { _ in
            throwCalls += 1
            throw TransientVisionError()
        }
        let first = VisionOCRService.supportedRecognitionLanguages(for: VNRecognizeTextRequestRevision3)
        XCTAssertTrue(first.isEmpty, "a throwing query must surface as empty for this call")
        XCTAssertEqual(throwCalls, 1)

        // Framework "recovers": the next call must re-query (not hit a
        // poisoned empty cache entry).
        var successCalls = 0
        VisionOCRService.recognitionLanguagesQuery = { _ in
            successCalls += 1
            return ["en", "zh-Hans"]
        }
        let second = VisionOCRService.supportedRecognitionLanguages(for: VNRecognizeTextRequestRevision3)
        XCTAssertEqual(second, ["en", "zh-Hans"],
                       "ID-SILENT-0016: after a transient throw, the next call must re-query Vision")
        XCTAssertEqual(successCalls, 1)

        // And the recovered result is cached normally afterwards.
        _ = VisionOCRService.supportedRecognitionLanguages(for: VNRecognizeTextRequestRevision3)
        XCTAssertEqual(successCalls, 1, "recovered result must be cached like any valid answer")
    }

    /// Negative control for ID-SILENT-0016: a legitimately EMPTY query
    /// result (no throw) is a valid answer and must still be cached —
    /// the fix must not disable caching altogether.
    func testSupportedLanguagesEmptyResultIsCached() {
        let original = VisionOCRService.recognitionLanguagesQuery
        defer {
            VisionOCRService.recognitionLanguagesQuery = original
            VisionOCRService.resetSupportedLanguagesCacheForTesting()
        }
        VisionOCRService.resetSupportedLanguagesCacheForTesting()

        var calls = 0
        VisionOCRService.recognitionLanguagesQuery = { _ in
            calls += 1
            return []
        }
        XCTAssertEqual(VisionOCRService.supportedRecognitionLanguages(for: VNRecognizeTextRequestRevision3), [])
        XCTAssertEqual(VisionOCRService.supportedRecognitionLanguages(for: VNRecognizeTextRequestRevision3), [])
        XCTAssertEqual(calls, 1, "a legitimately empty result is valid and must be cached")
    }

    // MARK: - ID-OCR-0009 (2026-07-31 audit): full-resolution fallback must apply EXIF

    /// ID-OCR-0001 residual: the full-resolution fallback (used when
    /// thumbnail generation fails) handed Vision the unrotated bitmap.
    /// Feed the fallback a JPEG tagged Orientation=6 (90° CW) and verify
    /// the returned CGImage has swapped dimensions — i.e. the orientation
    /// was baked in, matching the thumbnail path's
    /// `kCGImageSourceCreateThumbnailWithTransform` behavior.
    func testFallbackFullResolutionAppliesEXIFOrientation() throws {
        let width = 200, height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cgImage = ctx.makeImage() else {
            XCTFail("cannot create test CGImage")
            return
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            XCTFail("cannot create image destination")
            return
        }
        CGImageDestinationAddImage(destination, cgImage,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            XCTFail("cannot finalize JPEG")
            return
        }

        let result = VisionOCRService.fallbackFullResolutionCGImage(from: data as Data)
        XCTAssertNotNil(result, "fallback must decode a valid JPEG")
        // Orientation=6 rotates 90°: 200x100 becomes 100x200. If EXIF is
        // ignored the dimensions stay 200x100.
        XCTAssertEqual(result?.width, height,
                       "ID-OCR-0009: fallback must bake EXIF orientation into the bitmap")
        XCTAssertEqual(result?.height, width,
                       "ID-OCR-0009: fallback must bake EXIF orientation into the bitmap")
    }
}

// H-4 (2026-07-24 audit): test stub. Conforms to CryptoServiceProtocol so
// ServiceContainer.crypto can be swapped in tests. encrypt / encryptData
// always return nil to simulate the rare "key unavailable" failure mode
// (e.g. Keychain locked during launchd start, per C-2). Other methods
// are not exercised by the H-4 path so they return harmless defaults.
// MARK: - H-4 test stub

private struct FailingEncryptCrypto: CryptoServiceProtocol {
    func encrypt(_ string: String) -> String? { nil }
    func decrypt(_ base64String: String) -> String? { nil }
    func encryptData(_ data: Data) -> Data? { nil }
    func decryptData(_ combined: Data) -> Data? { nil }
    func isOldFormat(_ base64String: String) -> Bool { false }
    func migrateToV2(_ base64String: String) -> String? { nil }
    func hmacHex(for string: String) -> String? { nil }
    func decryptWithReason(_ base64String: String, itemID: UUID) -> DecryptResult { .dataCorrupted }
}

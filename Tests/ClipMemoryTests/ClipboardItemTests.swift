import XCTest
@testable import ClipMemory

final class ClipboardItemTests: XCTestCase {

    // MARK: - B.1 Default Initialization

    func testDefaultInitialization() {
        let item = ClipboardItem(content: "Hello", type: .text)

        XCTAssertNotNil(item.id, "id should be auto-generated")
        XCTAssertEqual(item.content, "Hello")
        XCTAssertEqual(item.type, .text)
        XCTAssertFalse(item.isPinned, "isPinned should default to false")
        XCTAssertFalse(item.isSensitive, "isSensitive should default to false")
        XCTAssertNil(item.expiresAt, "expiresAt should default to nil")
        XCTAssertFalse(item.isEncrypted, "isEncrypted should default to false")
        XCTAssertNil(item.contentHash, "contentHash should default to nil")
        XCTAssertFalse(item.isExpired, "item without expiry should not be expired")
    }

    // MARK: - B.2 Custom Values Initialization

    func testCustomInitialization() {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let expiresAt = Date(timeIntervalSince1970: 2_000_000)

        let item = ClipboardItem(
            id: id,
            content: "Secret content",
            type: .text,
            createdAt: createdAt,
            isPinned: true,
            isSensitive: true,
            expiresAt: expiresAt,
            isEncrypted: true,
            contentHash: "abc123"
        )

        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.content, "Secret content")
        XCTAssertEqual(item.type, .text)
        XCTAssertEqual(item.createdAt, createdAt)
        XCTAssertTrue(item.isPinned)
        XCTAssertTrue(item.isSensitive)
        XCTAssertEqual(item.expiresAt, expiresAt)
        XCTAssertTrue(item.isEncrypted)
        XCTAssertEqual(item.contentHash, "abc123")
    }

    // MARK: - B.3 isExpired Computed Property

    func testIsExpiredWithNoExpiry() {
        let item = ClipboardItem(content: "No expiry", type: .text)
        XCTAssertFalse(item.isExpired)
    }

    func testIsExpiredWithFutureExpiry() {
        let future = Date().addingTimeInterval(3600)  // 1 hour from now
        let item = ClipboardItem(content: "Expires later", type: .text, expiresAt: future)
        XCTAssertFalse(item.isExpired)
    }

    func testIsExpiredWithPastExpiry() {
        let past = Date().addingTimeInterval(-3600)  // 1 hour ago
        let item = ClipboardItem(content: "Already expired", type: .text, expiresAt: past)
        XCTAssertTrue(item.isExpired)
    }

    func testIsExpiredWithExactNow() {
        // Simulate: expiresAt was set to "now" a tiny bit ago
        // Since Date() > Date() is always false for same-instant calls,
        // we use a slightly past time to verify the > comparison works
        let justPast = Date().addingTimeInterval(-0.001)
        let item = ClipboardItem(content: "Just past", type: .text, expiresAt: justPast)
        XCTAssertTrue(item.isExpired, "item past expiry should be expired")
    }

    // MARK: - B.4 ClipboardItemType Enum Cases

    func testClipboardItemTypeAllCases() {
        let textItem = ClipboardItem(content: "text content", type: .text)
        let imageItem = ClipboardItem(content: "image.png", type: .image)
        let linkItem = ClipboardItem(content: "https://example.com", type: .link)

        XCTAssertEqual(textItem.type, .text)
        XCTAssertEqual(imageItem.type, .image)
        XCTAssertEqual(linkItem.type, .link)
    }

    func testClipboardItemTypeRawValues() {
        XCTAssertEqual(ClipboardItemType.text.rawValue, "text")
        XCTAssertEqual(ClipboardItemType.image.rawValue, "image")
        XCTAssertEqual(ClipboardItemType.link.rawValue, "link")
    }

    func testClipboardItemTypeIsCodable() {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for type in [ClipboardItemType.text, .image, .link] {
            guard let data = try? encoder.encode(type),
                  let decoded = try? decoder.decode(ClipboardItemType.self, from: data) else {
                XCTFail("Codable round-trip failed for \(type)")
                continue
            }
            XCTAssertEqual(decoded, type)
        }
    }

    // MARK: - B.5 ClipboardItem Codable and contentHash

    func testClipboardItemIsCodable() throws {
        let original = ClipboardItem(
            id: UUID(),
            content: "Test content",
            type: .link,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            isPinned: true,
            isSensitive: true,
            expiresAt: Date(timeIntervalSince1970: 2_000_000),
            isEncrypted: true,
            contentHash: "def456"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(original) else {
            XCTFail("Failed to encode ClipboardItem")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ClipboardItem.self, from: data) else {
            XCTFail("Failed to decode ClipboardItem")
            return
        }

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.isPinned, original.isPinned)
        XCTAssertEqual(decoded.isSensitive, original.isSensitive)
        XCTAssertEqual(decoded.expiresAt, original.expiresAt)
        XCTAssertEqual(decoded.isEncrypted, original.isEncrypted)
        XCTAssertEqual(decoded.contentHash, original.contentHash)
    }

    func testClipboardItemContentHashNil() {
        let item = ClipboardItem(content: "No hash", type: .text)
        XCTAssertNil(item.contentHash)
    }

    func testClipboardItemContentHashSet() {
        let item = ClipboardItem(content: "With hash", type: .text, contentHash: "sha256abc")
        XCTAssertEqual(item.contentHash, "sha256abc")
    }

    // MARK: - Equatable Conformance

    func testClipboardItemEquatable() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000_000)

        let item1 = ClipboardItem(
            id: id,
            content: "Same",
            type: .text,
            createdAt: date,
            isPinned: false,
            isSensitive: false,
            expiresAt: nil,
            isEncrypted: false,
            contentHash: nil
        )

        let item2 = ClipboardItem(
            id: id,
            content: "Same",
            type: .text,
            createdAt: date,
            isPinned: false,
            isSensitive: false,
            expiresAt: nil,
            isEncrypted: false,
            contentHash: nil
        )

        let item3 = ClipboardItem(
            id: UUID(),  // Different id
            content: "Same",
            type: .text,
            createdAt: date,
            isPinned: false,
            isSensitive: false,
            expiresAt: nil,
            isEncrypted: false,
            contentHash: nil
        )

        XCTAssertEqual(item1, item2, "Items with same id should be equal")
        XCTAssertNotEqual(item1, item3, "Items with different id should not be equal")
    }

    // MARK: - Expiry boundary

    func testItemExpiryBeforeDate() {
        let past = Date(timeIntervalSinceNow: -3600)
        let item = ClipboardItem(content: "Expired", type: .text, expiresAt: past)
        XCTAssertTrue(item.isExpired)
    }

    func testItemExpiryAfterDate() {
        let future = Date(timeIntervalSinceNow: 3600)
        let item = ClipboardItem(content: "Valid", type: .text, expiresAt: future)
        XCTAssertFalse(item.isExpired)
    }

    func testItemWithNoExpiryNeverExpires() {
        let item = ClipboardItem(content: "Forever", type: .text)
        XCTAssertFalse(item.isExpired)
    }

    // MARK: - Rich Text

    func testRichTextTypeRoundTrip() throws {
        let rtfData = try XCTUnwrap("{\\rtf1\\ansi Hello \\b World\\b0}".data(using: .utf8))
        let nsAttr = try XCTUnwrap(NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        XCTAssertEqual(nsAttr.string, "Hello World")
    }

    func testRichTextItemPlainTextFallback() {
        let rtf = "{\\rtf1\\ansi \\b Bold\\b0  text}"
        let item = ClipboardItem(content: Data(rtf.utf8).base64EncodedString(), type: .richText)
        let plain = item.plainTextFromRTFFallback
        XCTAssertTrue(plain.contains("Bold"))
        XCTAssertTrue(plain.contains("text"))
    }

    func testRichTextNotText() {
        let item = ClipboardItem(content: "plain", type: .text)
        XCTAssertTrue(item.plainTextFromRTFFallback.isEmpty)
    }

    func testRichTextEncodingRoundTrip() throws {
        let originalRTF = "{\\rtf1\\ansi \\b Bold\\b0  text}"
        let base64 = Data(originalRTF.utf8).base64EncodedString()
        let decoded = try XCTUnwrap(Data(base64Encoded: base64))
        let rtf = try XCTUnwrap(String(data: decoded, encoding: .utf8))
        XCTAssertEqual(rtf, originalRTF)
    }
}

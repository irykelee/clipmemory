import XCTest
@testable import ClipMemory

final class SensitiveDetectorTests: XCTestCase {

    // MARK: - D.1 Password/Credential Pattern Detection

    func testPasswordPatterns() {
        // Should match — regex patterns catch key=value format
        let matching = [
            "password=secret123",
            "password: mypass",
            "pwd12345",
            "passcode=0000",
            "api_key=FAKE_AKIAIOSFODNN7EXAMPLE",
            "apikey: Bearer faketokenvaluestringfortest",
            "api-key: bearer fakejwttokenforexampletesting",
            "secret: extremelylongsecretvaluethatexceeds20chars",
            "token: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        ]
        for text in matching {
            let item = makeItem(content: text)
            XCTAssertTrue(item.isSensitive, "Should detect sensitive in: \(text.prefix(30))")
        }

        let nonMatching = [
            "Hello world",
            "My password is not in the text",
            "api documentation",
            "Authentication required",
            "Enter your username"
        ]
        for text in nonMatching {
            let item = makeItem(content: text)
            XCTAssertFalse(item.isSensitive, "Should NOT detect in: \(text.prefix(30))")
        }
    }

    func testPrivateKeyPatterns() {
        let matching = [
            "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAL...",
            "-----BEGIN EC PRIVATE KEY-----\nMHQCAQEE...",
            "-----BEGIN OPENSSH PRIVATE KEY-----\n...",
            "-----BEGIN PRIVATE KEY-----\nMIIEv..."
        ]
        for text in matching {
            let item = makeItem(content: text)
            XCTAssertTrue(item.isSensitive, "Should detect private key in: \(text.prefix(30))")
        }
    }

    // MARK: - D.2 API Key/Token Pattern Detection

    func testAWSKeyPatterns() {
        // Should match AWS access key format (AKIA prefix + 16 uppercase alphanumeric chars)
        let awsKeys = [
            "AKIA0000000000000000",
            "AKIAIOSFODNN7EXAMPLE"
        ]
        for key in awsKeys {
            let item = makeItem(content: "AWS_ACCESS_KEY=\(key)")
            XCTAssertTrue(item.isSensitive, "Should detect AWS key: \(key)")
        }
    }

    func testGitHubTokenPatterns() {
        // ghp_ and github_pat_ prefixes indicate GitHub token format
        // Test with clearly fake values that won't trigger secret scanning
        let tokens = [
            "ghp_000000000000000000000000000000000000",
            "github_pat_0000000000000000000000000000000000000000"
        ]
        for token in tokens {
            let item = makeItem(content: token)
            XCTAssertTrue(item.isSensitive, "Should detect GitHub token")
        }
    }

    func testJWTPatterns() {
        // JWT format: eyJ...base64...base64...signature
        let tokens = [
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
            + "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ."
            + "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        ]
        for token in tokens {
            let item = makeItem(content: token)
            XCTAssertTrue(item.isSensitive, "Should detect JWT")
        }
    }

    func testGoogleAPIKeyPatterns() {
        // AIzaSyD + 35 chars = 39-char Google API key format
        let key = "AIzaSyDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"  // 39 chars after AIza
        let item = makeItem(content: key)
        XCTAssertTrue(item.isSensitive, "Should detect Google API key: \(key.prefix(10))...")
    }

    // MARK: - D.3 Personal Identity Information Detection

    func testChineseIDCardPatterns() {
        // 18-digit Chinese ID: region(6) + year(4) + month(2) + day(2) + seq(3) + checksum(1)
        let validIDs = [
            "110101199003074517",
            "31011219850101231X"
        ]
        for id in validIDs {
            let item = makeItem(content: "ID: \(id)")
            XCTAssertTrue(item.isSensitive, "Should detect Chinese ID: \(id)")
        }

        // 15-digit Chinese ID: region(6) + birthdate(6) + seq(3)
        let valid15 = [
            "110101930101123"
        ]
        for id in valid15 {
            let item = makeItem(content: "ID: \(id)")
            XCTAssertTrue(item.isSensitive, "Should detect 15-digit Chinese ID: \(id)")
        }
    }

    func testChineseIDCardNegative() {
        // ID-CRASH-0017 (2026-09-28 code-review P2-4): was a zero-
        // assertion test (`_ = item.isSensitive` discarded the
        // result). The original code review noted: "删掉全部敏感
        // 检测逻辑此测试仍绿". Now asserts `isSensitive` is false
        // for invalid 18-digit IDs — matching the positive-case
        // loop above (line 116) which asserts true for valid IDs.
        let invalid = [
            "123456789012345678",
            "000000000000000000"
        ]
        for id in invalid {
            let item = makeItem(content: "code: \(id)")
            XCTAssertFalse(item.isSensitive, "Should NOT detect invalid ID: \(id)")
        }
    }

    func testBankCardPatterns() {
        let cards = [
            "4532015112830366",
            "5425233430109903",
            "378282246310005",
            "6011111111111117"
        ]
        for card in cards {
            let item = makeItem(content: "card: \(card)")
            XCTAssertTrue(item.isSensitive, "Should detect bank card: \(card)")
        }
    }

    func testUSSSNPatterns() {
        let ssns = [
            "123-45-6789",
            "078-05-1120"
        ]
        for ssn in ssns {
            let item = makeItem(content: "SSN: \(ssn)")
            XCTAssertTrue(item.isSensitive, "Should detect SSN: \(ssn)")
        }
    }

    func testSSNNegative() {
        // ID-CRASH-0017 (2026-09-28 code-review P2-4): the data was
        // bogus ("000-00-0000" and "123-456-789" both matched the
        // SSN regex `\d{3}-\d{2}-\d{4}`, so the original zero-
        // assertion test would have caught a regression if the
        // assertion had been there). Picked strings that LOOK like
        // SSN-shaped input but don't satisfy the regex: "123-45"
        // has only 5 digits, "12-345-6789" has wrong digit grouping
        // (2-3-4 not 3-2-4), and "abc-def-ghi" has letters.
        let invalid = [
            "123-45",         // too few digits
            "12-345-6789",   // wrong digit grouping
            "abc-def-ghi"     // letters, not digits
        ]
        for ssn in invalid {
            let item = makeItem(content: "code: \(ssn)")
            XCTAssertFalse(item.isSensitive, "Should NOT detect invalid SSN: \(ssn)")
        }
    }

    // MARK: - Negative Cases

    func testNormalTextNotFlagged() {
        let safe = [
            "Hello, this is a normal message",
            "Check out https://example.com",
            "Meeting at 3pm tomorrow",
            "password123 is not the real password",
            "My API documentation link: api.example.com",
            "The token expires in 24 hours"
        ]
        for text in safe {
            let item = makeItem(content: text)
            XCTAssertFalse(item.isSensitive, "Should NOT detect in normal text: \(text.prefix(30))")
        }
    }

    func testVeryLongContentSkipsRegex() {
        // P1-AUDIT-2026-09-22 (P2-6): formerly asserted that long content
        // without patterns is NOT flagged — that codified the audit bug.
        // Conservative "likely sensitive" wins: large pastes (password
        // dumps, API key lists, JSON blobs) cannot be regex-scanned in
        // full, so they are conservatively flagged. False positives are
        // user-recoverable (un-flag in UI); false negatives leak data.
        let longContent = String(repeating: "normal text ", count: 5000)
        let item = makeItem(content: longContent)
        XCTAssertTrue(item.isSensitive,
                     "P1-AUDIT-2026-09-22 P2-6: >50KB content conservatively flagged even without patterns")
    }

    func testPureAlphanumericNotFlagged() {
        // Audit fix: PagerDuty pattern `[A-Za-z0-9]{20}` matched every 20+ char
        // alphanumeric string (URL params, base64 chunks, JSON keys, hash IDs).
        // Pattern removed; pure alphanumeric should never trigger detection.
        let safe = [
            "abcdefghijklmnopqrst",                              // exactly 20 chars
            "thisIsAVeryLongAlphanumericString1234567890",        // 41 chars mixed
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",               // 36 chars uppercase+digits
            "https://example.com/abc123def456ghi789jkl012mno345"  // URL with 20+ char paths
        ]
        for text in safe {
            let item = makeItem(content: text)
            XCTAssertFalse(item.isSensitive, "Should NOT detect pure alphanumeric: \(text.prefix(40))")
        }
    }

    // MARK: - Helper

    private func makeItem(content: String) -> ClipboardItem {
        // ID-REVIEW-1005 follow-up: `detectSensitive` was promoted to
        // static in ClipboardMonitor (it has no instance dependencies —
        // only the static `sensitivePatterns` table). Call it as a type
        // method now; the local `let monitor = ClipboardMonitor()` was
        // a leftover from when the call needed an instance.
        let isSensitive = ClipboardMonitor.detectSensitive(content)
        return ClipboardItem(
            content: content,
            type: .text,
            isSensitive: isSensitive
        )
    }
}

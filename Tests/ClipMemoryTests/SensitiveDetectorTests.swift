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
            // ID-REVIEW-1017: "My password is not in the text" used to be
            // in this list — it asserted that the literal phrase "password
            // is" should NOT trigger detection. The audit's natural-
            // language-password fix deliberately flips this: any text
            // containing the "password is" trigger IS treated as
            // potentially sensitive (per the conservative-flag bias in
            // P2-6 / report §六 P2-1). The replacement cases below cover
            // the same semantic shape ("talks about passwords in normal
            // prose") without matching the new keyword triggers.
            "I changed my password yesterday",
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

    // MARK: - ID-REVIEW-1017 normalization regressions
    //
    // Each test below targets one of the four audit bypass vectors
    // (code-review-2026-10-01 §六 P2-1). Acceptance is "paste form that
    // evaded the old detector is now flagged".

    /// (1) 16-digit card with space separators — common paste form
    /// `4111 1111 1111 1111`. The old bank-card regex required bare
    /// digit runs; now `stripCardSeparators` collapses the spaces and
    /// the Luhn filter confirms the candidate is a real card.
    func testSpaceSeparatedCardNumberIsFlagged() {
        let cases = [
            "4111 1111 1111 1111",        // Visa test number (Luhn valid)
            "5500 0000 0000 0004",        // Mastercard test (Luhn valid)
            "3400 0000 0000 009",         // Amex 15-digit test
            "6011 0000 0000 0004"         // Discover test (Luhn valid)
        ]
        for card in cases {
            let item = makeItem(content: "card \(card)")
            XCTAssertTrue(item.isSensitive, "Space-separated card should be flagged: \(card)")
        }
    }

    /// (1 cont.) Hyphen-separated card numbers — same collapse logic as
    /// the space case.
    func testHyphenSeparatedCardNumberIsFlagged() {
        let cases = [
            "4111-1111-1111-1111",
            "5500-0000-0000-0004"
        ]
        for card in cases {
            let item = makeItem(content: "PAN: \(card)")
            XCTAssertTrue(item.isSensitive, "Hyphen-separated card should be flagged: \(card)")
        }
    }

    /// (1 cont.) Random 16-digit run that matches the prefix regex
    /// but FAILS Luhn must NOT be flagged — the regex catch + Luhn
    /// filter is the audit's "real card" contract. The prefix `4` here
    /// is non-Luhn-valid (4111111111111112 sum ≠ 0 mod 10).
    func testNonLuhnValidDigitRunNotFlagged() {
        let fakeCard = "4111111111111112"   // matches Visa prefix + 16 digits, fails Luhn
        let item = makeItem(content: "ref: \(fakeCard)")
        XCTAssertFalse(item.isSensitive, "Non-Luhn-valid 16-digit run must not be flagged as a card")
    }

    /// (2) Zero-width-character bypass. `password=x` with U+200B
    /// inserted between letters is byte-different from `password=`,
    /// but NFKC + the explicit zero-width strip pass turns it back into
    /// the trigger that matches the keyword + value regex.
    func testZeroWidthCharBypassIsFlagged() {
        let payload = "p\u{200B}assword=secret123"
        let item = makeItem(content: payload)
        XCTAssertTrue(item.isSensitive,
                      "Zero-width char in `password=` must not bypass detection: \(payload.debugDescription)")
    }

    /// (3) Natural-language password trigger — "password is X" / "passphrase X"
    /// were silently missed by the old keyword table; now they're first-class
    /// triggers.
    func testNaturalLanguagePasswordTriggerIsFlagged() {
        let cases = [
            "the password is secret123",
            "my passphrase is hunter2",
            "password is my birthday"
        ]
        for phrase in cases {
            let item = makeItem(content: phrase)
            XCTAssertTrue(item.isSensitive, "Natural-language password should be flagged: \(phrase)")
        }
    }

    /// (4) Chinese password pattern — `密码` / `口令` keywords added to
    /// `sensitivePatterns` per audit §六 P2-1.
    func testChinesePasswordPatternIsFlagged() {
        let cases = [
            "登录密码 123456",
            "密码: hunter2",
            "我的口令是 secret"
        ]
        for phrase in cases {
            let item = makeItem(content: phrase)
            XCTAssertTrue(item.isSensitive, "Chinese password pattern should be flagged: \(phrase)")
        }
    }

    /// NFKC side-effect: full-width digits in a card number should also
    /// be detected (they fold to ASCII under NFKC). Belt-and-suspenders
    /// for the normalization pass — if a future change drops NFKC, this
    /// test fails.
    func testFullWidthCardNumberIsFlagged() {
        let fullWidthCard = "４１１１ １１１１ １１１１ １１１１"
        let item = makeItem(content: "card \(fullWidthCard)")
        XCTAssertTrue(item.isSensitive, "Full-width-digit card must be flagged after NFKC")
    }

    /// No-false-positive regression. Text mentioning "password" in
    /// normal prose (without the new trigger keywords / card shapes)
    /// must NOT be flagged. The pre-existing `testNormalTextNotFlagged`
    /// already covers most of these; this is the ID-REVIEW-1017-specific
    /// set focusing on the new triggers (so a regression here points
    /// squarely at this commit, not at the audit-era keyword table).
    func testIDReview1017NoFalsePositiveRegression() {
        let safe = [
            "I changed my password yesterday",
            "password strength is important",                       // "password" alone, NOT the new "password is" trigger
            "Set up password reset link",                           // "password" alone
            "My password was rotated last month",                    // "password" + past tense, not "password is"
            "We use a credential manager to store them all",         // generic prose, no password pattern
            "今天的天气不错",                                         // Chinese prose without password trigger
            "the documentation is incomplete"                       // "the ... is ..." pattern, no password trigger
        ]
        for text in safe {
            let item = makeItem(content: text)
            XCTAssertFalse(item.isSensitive, "Should NOT detect in normal text: \(text.prefix(30))")
        }
    }
}

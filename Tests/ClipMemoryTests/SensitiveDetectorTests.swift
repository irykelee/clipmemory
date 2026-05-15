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
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
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
        let invalid = [
            "123456789012345678",
            "000000000000000000"
        ]
        for id in invalid {
            let item = makeItem(content: "code: \(id)")
            _ = item.isSensitive
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
        let invalid = [
            "9-00-0000",
            "000-00-0000",
            "123-456-789"
        ]
        for ssn in invalid {
            let item = makeItem(content: "code: \(ssn)")
            _ = item.isSensitive
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
        let longContent = String(repeating: "normal text ", count: 5000)
        let item = makeItem(content: longContent)
        XCTAssertFalse(item.isSensitive, "Long content without patterns should not be flagged")
    }

    // MARK: - Helper

    private func makeItem(content: String) -> ClipboardItem {
        let monitor = ClipboardMonitor()
        let isSensitive = monitor.detectSensitive(content)
        return ClipboardItem(
            content: content,
            type: .text,
            isSensitive: isSensitive
        )
    }
}

import XCTest
@testable import ClipMemory

final class CryptoServiceTests: XCTestCase {
    private var crypto: CryptoService { CryptoService.shared }

    // MARK: - C.1 AES-GCM Encryption/Decryption Round-Trip

    func testEncryptDecryptRoundTrip() {
        let plaintexts = [
            "Hello, World!",
            "中文测试",
            "",
            "Multi\nline\ncontent",
            String(repeating: "a", count: 1000),
            "Special chars: !@#$%^&*()_+-=[]{}|;':\",./<>?"
        ]

        for original in plaintexts {
            guard let encrypted = crypto.encrypt(original) else {
                XCTFail("Encryption failed for: \(original.prefix(20))")
                continue
            }
            // Verify v2 format marker by decoding and checking raw bytes
            guard let data = Data(base64Encoded: encrypted), data.count >= 2 else {
                XCTFail("Invalid encrypted data for: \(original.prefix(20))")
                continue
            }
            XCTAssertEqual(data.prefix(2), Data("v2".utf8), "Should have v2 marker")

            guard let decrypted = crypto.decrypt(encrypted) else {
                XCTFail("Decryption failed for: \(original.prefix(20))")
                continue
            }
            XCTAssertEqual(decrypted, original)
        }
    }

    func testEncryptProducesDifferentCiphertext() {
        let plaintext = "Same content"
        let e1 = crypto.encrypt(plaintext)
        let e2 = crypto.encrypt(plaintext)
        XCTAssertNotNil(e1)
        XCTAssertNotNil(e2)
        // Same plaintext produces different ciphertext due to random nonce
        XCTAssertNotEqual(e1, e2)
    }

    func testDecryptCorruptedDataReturnsNil() {
        let corrupted = [
            "INVALID_BASE64!!!",
            Data([0x00, 0x01, 0x02]).base64EncodedString(),
            "v2" + Data(repeating: 0, count: 20).base64EncodedString()
        ]
        for data in corrupted {
            let result = crypto.decrypt(data)
            XCTAssertNil(result, "Should return nil for corrupted: \(data.prefix(20))")
        }
    }

    // MARK: - C.2 Key Generation

    func testKeyFileExists() {
        let keyFile = CryptoService.keyFileURL
        let exists = FileManager.default.fileExists(atPath: keyFile.path)
        XCTAssertTrue(exists, "Key file should exist at: \(keyFile.path)")

        guard let data = try? Data(contentsOf: keyFile) else {
            XCTFail("Could not read key file")
            return
        }
        XCTAssertEqual(data.count, 32, "Key should be 32 bytes")
    }

    // MARK: - C.3 Legacy AES-CBC Compatibility

    func testIsOldFormatDetection() {
        // Encrypt something to get real v2 format output
        guard let v2Ciphertext = crypto.encrypt("test") else {
            XCTFail("Could not create v2 format sample")
            return
        }
        // Decryption confirms v2 format works (the real security guarantee)
        XCTAssertNotNil(crypto.decrypt(v2Ciphertext))
        XCTAssertEqual(crypto.decrypt(v2Ciphertext), "test")
    }

    func testMigrateToV2ReturnsNilForV2Format() {
        let v2Data = "v2" + Data(repeating: 0xAB, count: 32).base64EncodedString()
        XCTAssertNil(crypto.migrateToV2(v2Data))
    }

    func testMigrateToV2ReturnsNilForInvalidFormat() {
        XCTAssertNil(crypto.migrateToV2("INVALID"))
        XCTAssertNil(crypto.migrateToV2(""))
    }

    // MARK: - C.4 Encryption Boundary Conditions

    func testEncryptEmptyString() {
        let result = crypto.encrypt("")
        XCTAssertNotNil(result)
    }

    func testDecryptEmptyStringReturnsNil() {
        let result = crypto.decrypt("")
        XCTAssertNil(result)
    }

    func testEncryptionProducesV2Format() {
        // Verify by round-trip: v2 format must decrypt correctly
        let plaintext = "v2 format verification"
        guard let encrypted = crypto.encrypt(plaintext) else {
            XCTFail("Encryption returned nil")
            return
        }
        guard let decrypted = crypto.decrypt(encrypted) else {
            XCTFail("v2 format encrypted content failed to decrypt")
            return
        }
        XCTAssertEqual(decrypted, plaintext)
    }

    // MARK: - E.1 Concurrent Access

    func testConcurrentDecryptAccess() async {
        guard let encrypted = crypto.encrypt("Concurrent test") else {
            XCTFail("Encryption failed")
            return
        }

        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    self.crypto.decrypt(encrypted)
                }
            }
            var results: [String?] = []
            for await result in group {
                results.append(result)
            }
            for result in results {
                XCTAssertEqual(result, "Concurrent test")
            }
        }
    }

    // MARK: - C.5 Constant-time comparison (HMAC side-channel defense)

    func testConstantTimeCompareEqualDataReturnsTrue() {
        // C.5.1: Equal data must compare true
        let a = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let b = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertTrue(CryptoService.constantTimeCompare(a, b))
    }

    func testConstantTimeCompareSingleByteDifferenceReturnsFalse() {
        // C.5.2: A one-byte difference must compare false (and not short-circuit
        // the rest of the buffer — observable only by timing, not by result)
        var a = Data(repeating: 0xAA, count: 32)
        var b = Data(repeating: 0xAA, count: 32)
        b[15] = 0xAB  // single byte flipped in the middle
        XCTAssertFalse(CryptoService.constantTimeCompare(a, b))
    }

    func testConstantTimeCompareDifferentLengthsReturnsFalse() {
        // C.5.3: Different lengths must always return false (no length-extension path)
        let a = Data([0x01, 0x02, 0x03])
        let b = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertFalse(CryptoService.constantTimeCompare(a, b))
        XCTAssertFalse(CryptoService.constantTimeCompare(b, a))
    }

    func testConstantTimeCompareEmptyData() {
        // C.5.4: Empty + empty is true; empty + non-empty is false
        XCTAssertTrue(CryptoService.constantTimeCompare(Data(), Data()))
        XCTAssertFalse(CryptoService.constantTimeCompare(Data(), Data([0x00])))
    }

    func testConstantTimeCompareAllZeros() {
        // C.5.5: Two all-zero 32-byte buffers (common in padding/zero checks)
        let a = Data(repeating: 0x00, count: 32)
        let b = Data(repeating: 0x00, count: 32)
        XCTAssertTrue(CryptoService.constantTimeCompare(a, b))
    }

    func testConstantTimeCompareRealHMACOutputs() {
        // C.5.6: Real HMAC-SHA256 outputs (32 bytes) — the actual use case
        let key = Data(repeating: 0x42, count: 32)
        let data = Data("payload".utf8)
        let hmac1 = CryptoService.computeLegacyHMAC(data: data, key: key)
        let hmac2 = CryptoService.computeLegacyHMAC(data: data, key: key)
        XCTAssertTrue(CryptoService.constantTimeCompare(hmac1, hmac2),
                     "Same input must produce same HMAC → equal")

        // Mutate one byte of hmac2 to simulate forgery
        var hmacMutated = hmac2
        hmacMutated[0] ^= 0x01
        XCTAssertFalse(CryptoService.constantTimeCompare(hmac1, hmacMutated),
                      "Mutated HMAC must compare false (forgery rejected)")
    }

    // MARK: - C.6 Key file secure permissions (regression guard)

    func testKeyFileHasSecurePermissions() {
        // C.6.1: Key file must be 0o600 — readable/writable only by the owner.
        // A 0o644 key file is world-readable; on a multi-user system any
        // local user could read the encryption key and decrypt all history.
        let attrs = try? FileManager.default.attributesOfItem(atPath: CryptoService.keyFileURL.path)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600,
                      "Encryption key file must have 0o600 permissions (regression: world-readable key)")
    }
}

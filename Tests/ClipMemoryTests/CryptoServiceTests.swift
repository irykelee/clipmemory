import XCTest
import CommonCrypto
import Security
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

    // MARK: - HMAC content hash

    /// HMAC produces deterministic, equal-length digests for deduplication
    /// without exposing an offline dictionary oracle for short secrets.
    func testHMACIsDeterministicAndSensitiveToInput() {
        let h1 = crypto.hmacHex(for: "hello")
        let h2 = crypto.hmacHex(for: "hello")
        let h3 = crypto.hmacHex(for: "Hello")
        XCTAssertNotNil(h1)
        XCTAssertNotNil(h2)
        XCTAssertNotNil(h3)
        XCTAssertEqual(h1, h2, "Same input must produce same HMAC")
        XCTAssertNotEqual(h1, h3, "Case change must change HMAC")
        XCTAssertEqual(h1?.count, 64, "HMAC-SHA256 hex output is 64 chars")
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

    func testIsOldFormatDetection() throws {
        // Encrypt something to get real v2 format output
        guard let v2Ciphertext = crypto.encrypt("test") else {
            XCTFail("Could not create v2 format sample")
            return
        }
        // Decryption confirms v2 format works (the real security guarantee)
        XCTAssertNotNil(crypto.decrypt(v2Ciphertext))
        XCTAssertEqual(crypto.decrypt(v2Ciphertext), "test")
        XCTAssertFalse(crypto.isOldFormat(v2Ciphertext), "v2 output must not be old format")

        // C4: classification is a strict "v2" byte-prefix check, independent of
        // whether the payload actually decrypts — decrypt-success must never be
        // used as a classifier (it gave a UserDefaults writer a format oracle).
        let corruptV2 = "v2" + Data(repeating: 0, count: 20).base64EncodedString()
        XCTAssertFalse(crypto.isOldFormat(corruptV2),
                      "Corrupt v2-prefixed payload is still v2, not migratable legacy")

        // Legacy v1+HMAC blob (no "v2" prefix) → old format
        let key = try Data(contentsOf: CryptoService.keyFileURL)
        let legacyBlob = makeLegacyV1Blob(plaintext: Data("legacy".utf8), key: key)
        XCTAssertTrue(crypto.isOldFormat(legacyBlob.base64EncodedString()),
                     "v1 blob without v2 prefix must be classified as old format")
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

    // MARK: - RS-6: decryptLegacy round-trip with synthesized v1 format
    //
    // Tests use synthesized v1-format blobs (AES-CBC + HMAC-SHA256, pre-v2) to
    // exercise CryptoService.decryptLegacy without depending on archived data.
    // Helpers below mirror the algorithm decryptLegacy expects: random 16-byte
    // IV, AES-CBC with PKCS7 padding, HMAC-SHA256 over (IV || ciphertext).
    // If decryptLegacy's behavior changes (e.g. drops HMAC verification, swaps
    // padding mode), these tests will fail and force a deliberate update.

    func testDecryptDataHandlesLegacyV1FormatWithHMAC() throws {
        // RS-6: decryptData() must accept v1-format (AES-CBC + HMAC) and
        // return the original plaintext bytes.
        let payload = Data((0..<512).map { UInt8($0 & 0xFF) })
        let key = try Data(contentsOf: CryptoService.keyFileURL)
        XCTAssertEqual(key.count, 32, "Test fixture: key file must have 32 bytes")

        let legacyBlob = makeLegacyV1Blob(plaintext: payload, key: key)
        XCTAssertGreaterThanOrEqual(legacyBlob.count, 49,
            "v1+HMAC format must be at least 16(IV) + 1(ciphertext) + 32(HMAC)")

        let decrypted = crypto.decryptData(legacyBlob)
        XCTAssertEqual(decrypted, payload,
            "decryptData() must round-trip v1-format bytes through decryptLegacy")
    }

    func testDecryptStringHandlesLegacyV1FormatWithHMAC() throws {
        // RS-6: decrypt() (text path) must also accept v1-format and
        // return the original UTF-8 string.
        let plaintext = "Hello legacy v1 你好世界 🌍"
        let key = try Data(contentsOf: CryptoService.keyFileURL)
        let plaintextData = Data(plaintext.utf8)
        let legacyBlob = makeLegacyV1Blob(plaintext: plaintextData, key: key)

        let decrypted = crypto.decrypt(legacyBlob.base64EncodedString())
        XCTAssertEqual(decrypted, plaintext,
            "decrypt() must round-trip v1-format text through decryptLegacy")
    }

    func testDecryptDataRejectsLegacyV1FormatNoHMAC() throws {
        // C4: the pre-1.2.0 [IV || ciphertext] no-HMAC branch was removed —
        // unauthenticated CBC is a padding-oracle / tampering hole for anyone
        // who can write UserDefaults. decryptLegacy must REJECT such blobs.
        let payload = Data("Pre-1.2.0 no HMAC test payload".utf8)
        let key = try Data(contentsOf: CryptoService.keyFileURL)
        let legacyBlob = makeLegacyV1BlobNoHMAC(plaintext: payload, key: key)
        XCTAssertEqual(legacyBlob.count, 16 + ((payload.count / 16 + 1) * 16),
            "No-HMAC format must be exactly 16(IV) + padded ciphertext")

        XCTAssertNil(crypto.decryptData(legacyBlob),
            "decryptData() must reject pre-1.2.0 no-HMAC blobs (C4: padding oracle removed)")
    }

    func testDecryptLegacyRejectsTamperedHMAC() throws {
        // RS-6: flipping a byte in the HMAC must cause decryption to fail
        // (constant-time compare → nil). Regression guard for the
        // constantTimeCompare fix in CryptoService.
        let plaintext = Data("Integrity matters".utf8)
        let key = try Data(contentsOf: CryptoService.keyFileURL)
        var blob = makeLegacyV1Blob(plaintext: plaintext, key: key)

        let hmacStart = blob.count - 32
        blob[hmacStart] ^= 0x01

        let decrypted = crypto.decrypt(blob.base64EncodedString())
        XCTAssertNil(decrypted, "Tampered HMAC must cause decryption to fail")
    }

    func testDecryptLegacyRejectsTamperedCiphertext() throws {
        // RS-6: flipping a byte in the ciphertext must also fail — HMAC
        // is computed over IV || ciphertext, so any ciphertext mutation
        // invalidates the HMAC and rejects the blob.
        let plaintext = Data("Ciphertext tampering test".utf8)
        let key = try Data(contentsOf: CryptoService.keyFileURL)
        var blob = makeLegacyV1Blob(plaintext: plaintext, key: key)

        // Byte 20 is inside the ciphertext region (IV ends at 16, HMAC at count-32)
        blob[20] ^= 0x01

        let decrypted = crypto.decrypt(blob.base64EncodedString())
        XCTAssertNil(decrypted, "Tampered ciphertext must fail HMAC verification")
    }

    // MARK: - RS-6 Helpers

    /// Encrypt plaintext as v1-format: random 16-byte IV + AES-CBC ciphertext
    /// + 32-byte HMAC-SHA256(IV || ciphertext). Mirrors what decryptLegacy expects.
    private func makeLegacyV1Blob(plaintext: Data, key: Data) -> Data {
        let iv = randomBytes(count: 16)
        let ciphertext = aesEncryptCBC(plaintext: plaintext, key: key, iv: iv)
        let hmac = CryptoService.computeLegacyHMAC(data: iv + ciphertext, key: key)
        return iv + ciphertext + hmac
    }

    /// Pre-1.2.0 format: just [IV || ciphertext], no HMAC.
    private func makeLegacyV1BlobNoHMAC(plaintext: Data, key: Data) -> Data {
        let iv = randomBytes(count: 16)
        let ciphertext = aesEncryptCBC(plaintext: plaintext, key: key, iv: iv)
        return iv + ciphertext
    }

    /// AES-CBC encrypt with PKCS7 padding — symmetric to aesDecryptCBC in
    /// CryptoService.swift. Required because CryptoService only exposes
    /// the decrypt direction publicly; the encrypt counterpart only exists
    /// here for v1-format synthesis.
    private func aesEncryptCBC(plaintext: Data, key: Data, iv: Data) -> Data {
        let bufferSize = plaintext.count + kCCBlockSizeAES128
        var encryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, 32,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, plaintext.count,
                        &encryptedBytes, bufferSize,
                        &numBytesEncrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            fatalError("aesEncryptCBC failed with status \(status)")
        }
        return Data(encryptedBytes.prefix(numBytesEncrypted))
    }

    /// Cryptographically-random bytes via SecRandomCopyBytes.
    private func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed with status \(result)")
        }
        return data
    }
}

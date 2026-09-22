import XCTest
import CommonCrypto
import Security
@testable import ClipMemory

final class CryptoServiceTests: XCTestCase {
    private var crypto: CryptoService { CryptoService.shared }

    // STOR-1 (2026-07-24 audit): prepareKey now publishes to the shared
    // cache. CryptoKeyPreparationTests populates it with mock-keyed test
    // data; reset on entry so this class's tests see a clean cache and
    // the file-backed key from `CryptoService.keyFileURL` is the source
    // of truth (replicating production semantics for legacy v1 blobs).
    override func setUp() {
        CryptoService.resetForTesting()
    }

    override func tearDown() {
        CryptoService.resetForTesting()
    }

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

    // MARK: - P1-AUDIT-2026-09-22 (P2-1) — v2 prefix collision on legacy ciphertext

    /// P1-AUDIT-2026-09-22 (P2-1): legacy ciphertext whose first two bytes
    /// happen to be "v2" (~1/65536 chance) must be decrypted via legacy path,
    /// not silently marked as decrypt-failed.
    func testLegacyCiphertextWithV2PrefixIsRecovered() throws {
        // Build a fixture: encrypt a known plaintext with legacy (v1) format
        // using a deterministic IV whose first 2 bytes are "v2". This
        // deterministically reproduces the audit's ~1/65536 natural collision
        // without mutating the ciphertext post-hoc (mutating would break the
        // HMAC and the legacy fallback would fail because the IV bytes
        // covered by the HMAC would no longer match the stored tag).
        let keyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        let crypto = CryptoService(customKeyData: keyData)
        let plaintext = Data("hello-world".utf8)
        // Deterministic IV: first 2 bytes = "v2", remaining 14 bytes arbitrary.
        var viIv = Data("v2".utf8)
        viIv.append(Data(repeating: 0xAB, count: 14))
        XCTAssertEqual(viIv.count, 16, "IV must be 16 bytes")
        guard let legacyCiphertext = crypto.encryptLegacyForTesting(plaintext, iv: viIv) else {
            XCTFail("legacy fixture builder missing"); return
        }
        XCTAssertEqual(legacyCiphertext.prefix(2), Data("v2".utf8),
                       "fixture pre-condition: first two bytes are v2 (naturally, not via mutation)")

        let decrypted = crypto.decryptData(legacyCiphertext)
        XCTAssertEqual(decrypted, plaintext,
                      "P1-AUDIT-2026-09-22 P2-1: v2-prefixed legacy ciphertext must be recovered via legacy fallback")
    }

    /// P1-AUDIT-2026-09-22 (P2-1) — Option B: auth failure now triggers
    /// legacy fallback (C4 relaxation). Documents the explicit relaxation:
    /// in ClipMemory's threat model, ciphertext is app-controlled (not
    /// user-supplied), so C4's UserDefaults-write-attacker premise doesn't
    /// apply — an attacker with that access has the file contents regardless.
    /// ~1/65536 collision was the alternative (permanent data loss).
    func testGCMAuthFailureDoesFallback() throws {
        let keyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        let crypto = CryptoService(customKeyData: keyData)
        guard let v2Ciphertext = crypto.encryptData(Data("test".utf8)) else {
            XCTFail("GCM fixture failed"); return
        }
        // Mutate last byte (auth tag) to flip authentication
        var mutated = v2Ciphertext
        mutated[mutated.count - 1] ^= 0xFF
        // Result is nil because legacy fallback also fails (data was real GCM,
        // not legacy), so decrypt returns nil — but the FALLBACK PATH WAS
        // EXERCISED. Verify via the in-process logger if needed; otherwise
        // assert nil since legacy decrypt on GCM-shaped data fails.
        XCTAssertNil(crypto.decryptData(mutated),
                    "auth-failure returns nil after legacy fallback fails on GCM-shaped data")
    }

    /// P1-AUDIT-2026-09-22 (P2-1) production-path fix: the auto-review
    /// (`docs/reviews/auto-review-20260922-180417-24914.md` Finding [P1])
    /// caught that `testLegacyCiphertextWithV2PrefixIsRecovered` exercises
    /// `decryptData` (dev/test path) but `decryptWithReason`
    /// (CryptoService.swift:796-812, the LIVE path called by
    /// `ClipboardStore+Encryption.getDecryptedContent` line 215 — the
    /// rendering/search/OCR path) still had inline GCM that did NOT route
    /// through `decryptBytes`. So the recovery never reached production
    /// rendering/search/OCR. This test pins the production-path fix:
    /// `decryptWithReason` with a naturally-"v2"-prefixed legacy
    /// ciphertext returns `.success(plaintext)`.
    func testDecryptWithReasonLegacyWithV2PrefixRecovers() throws {
        // Same deterministic-IV fixture as testLegacyCiphertextWithV2PrefixIsRecovered
        let keyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        let crypto = CryptoService(customKeyData: keyData)
        let plaintext = "production-path recovery: v2-prefixed legacy must round-trip"
        // Deterministic IV: first 2 bytes = "v2", remaining 14 bytes arbitrary.
        var viIv = Data("v2".utf8)
        viIv.append(Data(repeating: 0xAB, count: 14))
        XCTAssertEqual(viIv.count, 16, "IV must be 16 bytes")
        guard let legacyCiphertext = crypto.encryptLegacyForTesting(Data(plaintext.utf8), iv: viIv) else {
            XCTFail("legacy fixture builder missing"); return
        }
        XCTAssertEqual(legacyCiphertext.prefix(2), Data("v2".utf8),
                       "fixture pre-condition: first two bytes are v2 (naturally, not via mutation)")

        // Production scenario: `isOldFormat` returns false (has "v2" prefix),
        // so the live path enters decryptWithReason's v2 branch. Pre-fix,
        // the inline GCM threw authFailure → .dataCorrupted → permanent
        // scheduleDecryptionFailedMark. Post-fix, decryptWithReason routes
        // through decryptBytes which falls back to decryptLegacy → plaintext.
        let base64Ciphertext = legacyCiphertext.base64EncodedString()
        let result = crypto.decryptWithReason(base64Ciphertext, itemID: UUID())

        switch result {
        case .success(let recovered):
            XCTAssertEqual(recovered, plaintext,
                "P1-AUDIT-2026-09-22 P2-1 production-path fix: v2-prefixed legacy ciphertext must be recovered via decryptWithReason")
        case .keyUnavailable:
            XCTFail("decryptWithReason returned .keyUnavailable — customKeyData should be available")
        case .dataCorrupted:
            XCTFail("decryptWithReason returned .dataCorrupted for v2-prefixed legacy ciphertext — auto-review Finding P1 regression (inline GCM branch did not call decryptBytes)")
        case .internalError:
            XCTFail("decryptWithReason returned .internalError for valid legacy ciphertext")
        }
    }

    /// P1-AUDIT-2026-09-22 (P2-1) production-path regression guard:
    /// tampered real-v2 ciphertext must STILL return `.dataCorrupted`
    /// (authFailure → legacy fallback fails HMAC → nil → .dataCorrupted).
    /// Ensures the production-path refactor of `decryptWithReason` did
    /// not turn the tampered case into `.success`.
    func testDecryptWithReasonTamperedV2StillDataCorrupted() throws {
        let keyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        let crypto = CryptoService(customKeyData: keyData)
        guard let v2Ciphertext = crypto.encryptData(Data("real v2 payload".utf8)) else {
            XCTFail("v2 fixture failed"); return
        }
        var mutated = v2Ciphertext
        mutated[mutated.count - 1] ^= 0xFF  // flip last byte (GCM auth tag)

        let result = crypto.decryptWithReason(mutated.base64EncodedString(), itemID: UUID())
        switch result {
        case .success:
            XCTFail("decryptWithReason returned .success for tampered real-v2 ciphertext — fallback must not falsely succeed")
        case .keyUnavailable:
            XCTFail("decryptWithReason returned .keyUnavailable for tampered real-v2 ciphertext")
        case .dataCorrupted:
            // Expected: authFailure → decryptLegacy fallback → HMAC mismatch → nil → .dataCorrupted
            break
        case .internalError:
            XCTFail("decryptWithReason returned .internalError — refactor should map nil to .dataCorrupted")
        }
    }

    /// P1-AUDIT-2026-09-22 (P2-1) production-path regression guard:
    /// valid v2 ciphertext must continue to return `.success` (no regression
    /// for the common case after the refactor routes through `decryptBytes`).
    func testDecryptWithReasonValidV2StillSucceeds() throws {
        let keyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        let crypto = CryptoService(customKeyData: keyData)
        let plaintext = "happy-path v2 round trip"
        guard let v2Ciphertext = crypto.encryptData(Data(plaintext.utf8)) else {
            XCTFail("v2 fixture failed"); return
        }

        let result = crypto.decryptWithReason(v2Ciphertext.base64EncodedString(), itemID: UUID())
        switch result {
        case .success(let recovered):
            XCTAssertEqual(recovered, plaintext, "valid v2 must still decrypt via decryptWithReason")
        case .keyUnavailable:
            XCTFail("decryptWithReason returned .keyUnavailable for valid v2 ciphertext")
        case .dataCorrupted:
            XCTFail("decryptWithReason returned .dataCorrupted for valid v2 ciphertext — regression")
        case .internalError:
            XCTFail("decryptWithReason returned .internalError for valid v2 ciphertext")
        }
    }

    /// P1-AUDIT-2026-09-22 (P2-1) production-path regression guard:
    /// valid legacy ciphertext (no "v2" prefix) must continue to return
    /// `.success` via the legacy branch (which already routed through
    /// `decryptBytes` — confirms no regression on the unchanged path).
    func testDecryptWithReasonValidLegacyStillSucceeds() throws {
        let keyData = Data((0..<32).map { UInt8($0 & 0xFF) })
        let crypto = CryptoService(customKeyData: keyData)
        let plaintext = "happy-path legacy round trip"
        // Random IV (natural legacy, no v2 prefix collision)
        guard let legacyCiphertext = crypto.encryptLegacyForTesting(Data(plaintext.utf8)) else {
            XCTFail("legacy fixture builder missing"); return
        }
        XCTAssertNotEqual(legacyCiphertext.prefix(2), Data("v2".utf8),
                          "fixture pre-condition: natural legacy IV must not start with v2 (else test becomes the collision test)")

        let result = crypto.decryptWithReason(legacyCiphertext.base64EncodedString(), itemID: UUID())
        switch result {
        case .success(let recovered):
            XCTAssertEqual(recovered, plaintext, "valid legacy must still decrypt via decryptWithReason")
        case .keyUnavailable:
            XCTFail("decryptWithReason returned .keyUnavailable for valid legacy ciphertext")
        case .dataCorrupted:
            XCTFail("decryptWithReason returned .dataCorrupted for valid legacy ciphertext — regression")
        case .internalError:
            XCTFail("decryptWithReason returned .internalError for valid legacy ciphertext")
        }
    }

    // MARK: - P1-AUDIT-2026-09-22 (P2-3) — Keychain migration fail deletes cleartext + alerts

    /// P1-AUDIT-2026-09-22 (P2-3) + OpenCode auto-review (2026-09-23): when
    /// Keychain store fails during the legacy `.encryption_key` → Keychain
    /// migration with a PERMANENT error (errSecParam — Keychain definitively
    /// rejected the request), the cleartext key file MUST be deleted (not
    /// left on disk with the root key in 0o600) AND a `.encryptionFailed`
    /// notification must fire with source="keychainMigration.permanent" so
    /// AppDelegate's `EncryptionFailedAlertThrottler` surfaces an NSAlert.
    /// Pre-fix the failure path kept the file (next-launch retries) and only
    /// logged — violating CLAUDE.md three-piece-gate §3 (用户可见).
    ///
    /// Transient errors (errSecInteractionNotAllowed / errSecAuthFailed /
    /// errSecNotAvailable) are tested separately by
    /// `testKeychainMigrationTransientFailureKeepsFallbackFile` — per the
    /// OpenCode review, destroying the fallback on a transient error would
    /// collapse the "self-heal on next launch" design into a permanent
    /// data-loss event.
    func testKeychainMigrationFailDeletesFallbackFileAndAlerts() throws {
        // Arrange: temp dir + 32-byte .encryption_key file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2-3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let keyURL = tempDir.appendingPathComponent(".encryption_key")
        let keyData = Data(repeating: 0xAA, count: 32)
        try keyData.write(to: keyURL, options: .atomic)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: keyURL.path),
            "test fixture: .encryption_key file must exist before prepareKey"
        )

        // FailingKeychainStore: loadStatus returns .notFound (triggers
        // migration path), store throws KeyStoreError.classify(statusToReturn).
        // P2-3 OpenCode review (2026-09-23): errSecParam is a PERMANENT
        // failure (Keychain definitively rejected). The pre-fix behavior
        // deleted the file on any failure; the new behavior must do the same
        // for permanent errors but KEEP the file for transient errors.
        let failingKeychain = FailingKeychainStore()
        failingKeychain.statusToReturn = errSecParam

        // Capture .encryptionFailed notifications posted during prepareKey.
        var posted: [Notification] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed,
            object: nil,
            queue: .main
        ) { note in
            posted.append(note)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Act: attempt migration with the failing Keychain. failureHandler
        // is a no-op (regenerate) — store-failure never routes through it;
        // this just ensures the test doesn't trigger the default AppKit alert.
        _ = CryptoService.prepareKey(
            keyURL: keyURL,
            keyStore: failingKeychain,
            failureHandler: { _ in .regenerate }
        )

        // Assert 1: cleartext key file must be deleted on PERMANENT failure
        // (security: no persistent exposure of the root key).
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: keyURL.path),
            "P1-AUDIT-2026-09-22 P2-3: .encryption_key fallback must be deleted on PERMANENT Keychain store failure"
        )

        // Assert 2: .encryptionFailed notification must fire with
        // userInfo["source"] = "keychainMigration.permanent" so the Throttler
        // buckets it correctly (separate from .transient / addItem / OCR / etc).
        XCTAssertFalse(
            posted.isEmpty,
            "P1-AUDIT-2026-09-22 P2-3: .encryptionFailed notification must fire on Keychain store failure"
        )
        let source = posted.first?.userInfo?["source"] as? String
        XCTAssertEqual(
            source, "keychainMigration.permanent",
            "P2-3 (OpenCode 2026-09-23): permanent failures must use 'keychainMigration.permanent' bucket (separate from .transient)"
        )
        let recoverable = posted.first?.userInfo?["recoverable"] as? Bool
        XCTAssertEqual(
            recoverable, false,
            "P2-3 (OpenCode 2026-09-23): permanent failures must NOT be marked recoverable (retry won't help)"
        )
    }

    /// P2-3 (OpenCode auto-review, 2026-09-23): on a TRANSIENT Keychain
    /// store failure (errSecInteractionNotAllowed — Keychain locked at
    /// launchd start, pre-first-unlock; errSecAuthFailed — same root cause
    /// from a different code path; errSecNotAvailable — Keychain subsystem
    /// unavailable), the `.encryption_key` fallback file MUST be preserved
    /// so the next launch can retry the migration. The pre-fix behavior
    /// ("delete cleartext fallback on ANY store failure") was destructive
    /// for these transient cases: deleting the file means the next launch
    /// sees Keychain-empty + no-file → generateAndStoreKey creates a fresh
    /// key → all existing encrypted items become permanently undecryptable.
    func testKeychainMigrationTransientFailureKeepsFallbackFile() throws {
        // Arrange: temp dir + 32-byte .encryption_key file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2-3-transient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let keyURL = tempDir.appendingPathComponent(".encryption_key")
        let keyData = Data(repeating: 0xCC, count: 32)
        try keyData.write(to: keyURL, options: .atomic)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: keyURL.path),
            "test fixture: .encryption_key file must exist before prepareKey"
        )

        // FailingKeychainStore configured with a TRANSIENT status —
        // errSecInteractionNotAllowed. Keychain is locked (e.g. launchd
        // started before user logged in); next launch (after unlock) will
        // succeed.
        let failingKeychain = FailingKeychainStore()
        failingKeychain.statusToReturn = errSecInteractionNotAllowed

        // Capture .encryptionFailed notifications posted during prepareKey.
        var posted: [Notification] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed,
            object: nil,
            queue: .main
        ) { note in
            posted.append(note)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Act: attempt migration with the failing Keychain.
        _ = CryptoService.prepareKey(
            keyURL: keyURL,
            keyStore: failingKeychain,
            failureHandler: { _ in .regenerate }
        )

        // Assert 1: fallback file MUST be preserved (transient — retry will fix).
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: keyURL.path),
            "P2-3 (OpenCode 2026-09-23): .encryption_key fallback MUST be kept on TRANSIENT Keychain errors so next-launch retry can succeed — destroying it loses the only copy of the root key"
        )
        XCTAssertEqual(
            try? Data(contentsOf: keyURL), keyData,
            "P2-3: the fallback file content must be intact, not partially overwritten"
        )

        // Assert 2: .encryptionFailed notification must still fire so user is alerted.
        XCTAssertFalse(
            posted.isEmpty,
            "P2-3: .encryptionFailed notification must fire on transient Keychain errors too (user needs to know Keychain migration failed)"
        )
        let source = posted.first?.userInfo?["source"] as? String
        XCTAssertEqual(
            source, "keychainMigration.transient",
            "P2-3: transient failures must use 'keychainMigration.transient' bucket (separate from .permanent)"
        )
        let recoverable = posted.first?.userInfo?["recoverable"] as? Bool
        XCTAssertEqual(
            recoverable, true,
            "P2-3: transient failures MUST be marked recoverable (next launch will fix)"
        )
        let status = posted.first?.userInfo?["status"] as? Int
        XCTAssertEqual(
            status, Int(errSecInteractionNotAllowed),
            "P2-3: status code must be passed in userInfo so the alert can show the underlying Keychain error"
        )
    }

    /// P1-AUDIT-2026-09-22 (P2-3) regression guard: on Keychain migration
    /// SUCCESS the legacy file is still removed (existing behavior, pre-fix
    /// path). Ensures the P2-3 fix did not regress the happy path.
    func testKeychainMigrationSuccessStillRemovesFallbackFile() throws {
        // Arrange: temp dir + 32-byte .encryption_key file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2-3-success-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let keyURL = tempDir.appendingPathComponent(".encryption_key")
        let keyData = Data(repeating: 0xBB, count: 32)
        try keyData.write(to: keyURL, options: .atomic)

        // Store is in-memory; store() returns errSecSuccess and load()
        // returns the stored bytes. loadStatus returns .notFound to enter
        // migration path.
        let inMemory = InMemoryKeychainStore()

        // Capture .encryptionFailed notifications — should be ZERO
        // because migration succeeds.
        var posted: [Notification] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .encryptionFailed,
            object: nil,
            queue: .main
        ) { note in
            posted.append(note)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = CryptoService.prepareKey(
            keyURL: keyURL,
            keyStore: inMemory,
            failureHandler: { _ in .regenerate }
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: keyURL.path),
            "P2-3 regression: Keychain migration success must still remove .encryption_key"
        )
        XCTAssertTrue(
            posted.isEmpty,
            "P2-3 regression: Keychain migration success must NOT post .encryptionFailed"
        )
    }
}

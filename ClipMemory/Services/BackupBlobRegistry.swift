import Foundation

/// P1-AUDIT-2026-09-22 (P2-10): centralized registry of backup blob
/// types. Pre-fix: `BackupService.swift` + `BackupPackage.swift` each
/// maintained a private blobs table — adding a new blob type required
/// changes in 2 places (and drifted). Centralized here.
///
/// The actual backup flow serializes 3 blobs (items / tags / trash); the
/// earlier audit brief listed 5 candidate cases (`settings`, `ocrCache`)
/// that aren't part of the current backup contract — not added (would
/// fabricate data the backup pipeline doesn't actually produce).
///
/// Each case carries all the info the call sites need:
/// 1. `filename` — name used inside the backup archive / staging dir.
/// 2. `userDefaultsKey` — `UserDefaults` key whose `data(forKey:)` value
///    gets serialized. Comes from the central `UserDefaultsKey` registry
///    (P2-9), so the UserDefaults key string itself is also centralized.
/// 3. `decodeType` — `any Decodable.Type` used by `BackupPackage` to
///    build the manifest count without string-dispatching on
///    `UserDefaultsKey.rawValue`. P1-AUDIT-2026-09-22 (P2-10) Round-2.
///
/// Adding a new blob type = add one `case` here + the three `switch` arms
/// in the `filename` / `userDefaultsKey` / `decodeType` properties.
/// Iteration is registry-driven; `BackupPackage`'s decode dispatch is
/// also registry-driven (via `BlobKey.decodeType`). Both backup paths
/// (timestamped `BackupService` directory + `.clipmemory` `BackupPackage`
/// zip) iterate `allBlobKeys` and pick up the new blob automatically.
enum BackupBlobRegistry {
    /// All known backup blob types. Adding a new blob type = add one
    /// case here; both backup paths read from this enum.
    enum BlobKey: CaseIterable {
        case items
        case tags
        case trash

        /// Filename used inside the backup archive / staging directory.
        var filename: String {
            switch self {
            case .items: return "items.json"
            case .tags: return "tags.json"
            case .trash: return "trash.json"
            }
        }

        /// UserDefaults key whose `data(forKey:)` value gets serialized.
        /// Sourced from the central `UserDefaultsKey` registry (P2-9) so
        /// this stays the single source of truth end-to-end.
        var userDefaultsKey: String {
            switch self {
            case .items: return UserDefaultsKey.clipboardItems.rawValue
            case .tags: return UserDefaultsKey.clipboardTags.rawValue
            case .trash: return UserDefaultsKey.trashedItems.rawValue
            }
        }

        /// Type to feed `JSONDecoder.decode(_:from:)` when computing the
        /// manifest count for this blob. P1-AUDIT-2026-09-22 (P2-10)
        /// Round-2: replaces the inner `switch key` string-dispatch in
        /// `BackupPackage.exportPackage` — adding a new blob type now
        /// requires only adding the decode arm here, not editing
        /// `BackupPackage`.
        var decodeType: any Decodable.Type {
            switch self {
            case .items: return [ClipboardItem].self
            case .tags: return [Tag].self
            case .trash: return [ClipboardItem].self
            }
        }
    }

    /// Returns the keys a backup must serialize. Used by both
    /// `BackupService.exportBackup` and `BackupPackage.exportPackage`.
    static var allBlobKeys: [BlobKey] {
        BlobKey.allCases
    }

    // MARK: - 隔离副本（quarantine）

    /// ID-BACKUP-0006 (2026-10-23): 损坏 blob 的隔离副本收集路径。
    ///
    /// 背景：`quarantineCorruptBlob`（`ClipboardStore+Utilities.swift` /
    /// `TrashStore.swift`）把解码失败的 blob **复制**到
    /// `<原 key>.corrupt-<ISO8601 时间戳>` 并**移除原 key**。那份副本是
    /// 用户原始字节的唯一留存；改动前它不在备份白名单里 —— blob 损坏后
    /// 备份不会带走它，用户的原始数据可能永久丢失。
    ///
    /// 隔离副本的 key 是**动态**的（带时间戳），无法进 `BlobKey` 枚举，
    /// 因此另设一条收集路径：按 key 形态匹配 + 运行时枚举 defaults。

    /// 备份目录 / 导出包内隔离副本的子目录名。
    static let quarantineDirectoryName = "Quarantine"

    /// 隔离副本 key 的中缀：`<原 key>.corrupt-<ISO8601 时间戳>`。
    /// 拼法见 `ClipboardStore.quarantineCorruptBlob` 与
    /// `TrashStore.quarantineCorruptBlob`（两处都是
    /// `"\(key).corrupt-\(timestamp)"`）。
    static let quarantineKeyInfix = ".corrupt-"

    /// 可能被隔离的源 key —— 与 `quarantineCorruptBlob` 的调用点一一对应：
    /// `ClipboardStore.itemsStorageKey`（items）、
    /// `ClipboardStore.tagStorageKey`（tags）、
    /// `TrashStore.trashedItemsStorageKey`（trash）。
    /// 派生自 blob 注册表，新增 blob 类型自动纳入。
    static var quarantineSourceKeys: [String] {
        allBlobKeys.map(\.userDefaultsKey)
    }

    /// 隔离副本 key 的**时间戳部分**允许的字符集。
    /// ISO8601（带小数秒）形如 `2026-10-20T12:34:56.789Z`，因此除字母
    /// 数字外额外放行 `-` `:` `.`。
    ///
    /// **不放行**路径分隔符 / 空格 / 其它字符 —— 隔离副本的 key 会**原样**
    /// 当作备份文件名使用，宽松的字符集等于把 defaults 里的一个 key 变成
    /// 目录穿越（`ClipboardItems.corrupt-../../…`）。
    private static let quarantineSuffixAllowedCharacters: Set<Character> = {
        var allowed = Set<Character>("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.formUnion(["-", ":", "."])
        return allowed
    }()

    /// 判定 `key` 是否是结构合法的隔离副本 key。
    ///
    /// 同时承担**文件名安全校验**（见 `quarantineSuffixAllowedCharacters`
    /// 的说明）：非法字符的 key 一律不认，宁可漏备份也不写出一个越界的
    /// 备份路径。
    static func isQuarantineKey(_ key: String) -> Bool {
        for sourceKey in quarantineSourceKeys {
            let prefix = sourceKey + quarantineKeyInfix
            guard key.hasPrefix(prefix) else { continue }
            let suffix = String(key.dropFirst(prefix.count))
            guard !suffix.isEmpty else { continue }
            guard suffix.allSatisfy({ quarantineSuffixAllowedCharacters.contains($0) }) else { continue }
            // 双点会被 `appendingPathComponent` 当成路径片段的一部分 ——
            // 单独再挡一次，不依赖上面的字符集推理。
            guard !suffix.contains("..") else { continue }
            return true
        }
        return false
    }

    /// 收集 defaults 里所有隔离副本 key（升序，保证备份产物可复现）。
    ///
    /// 只收**值是 Data** 的 key —— 隔离副本一定是 blob 字节；值类型不对的
    /// 畸形 key 跳过（否则备份端声明的份数与实际写入的文件数会对不上，
    /// 导入端的份数校验会误判包被篡改）。
    static func quarantineKeys(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { isQuarantineKey($0) }
            .filter { defaults.data(forKey: $0) != nil }
            .sorted()
    }
}

import Foundation

/// Application Support directory resolution (H7).
///
/// `FileManager.urls(for:in:)` is documented to return the user-domain
/// Application Support path, but the result is an array — force-unwrapping
/// `.first` traps if the lookup ever comes back empty. Fall back to the
/// deterministic `~/Library/Application Support` instead of crashing.
enum AppDirectories {
    /// The user's Application Support directory. Never traps.
    static var applicationSupport: URL {
        resolve(
            candidates: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask),
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// First system candidate, or `~/Library/Application Support` when the
    /// system lookup returned nothing. Internal (not private) for tests.
    static func resolve(candidates: [URL], home: URL) -> URL {
        candidates.first ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}

import Foundation

enum AppVersion {
    // BUG-052 (2026-07-21): redundant fallback — infoDictionary subscript
    // and object(forInfoDictionaryKey:) read the same source. If the
    // first is nil, the second is also nil. Keep the explicit accessor
    // (more readable) + fallback to "1.0.0".
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0"
    }
}

import Foundation
import AppKit
import os

/// P1-AUDIT-2026-09-22 (P1-5 audit): app discovery moved from
/// HistoryCaptureSettingsView (line 505-539) to a dedicated service.
/// The View no longer holds FileManager references or
/// NSHomeDirectory() concatenation — those are now owned here.
///
/// **In-process cache** (per project convention seen in ClipStore/BackupSettings):
/// the first `discoverInstalledApps` call scans the filesystem; subsequent
/// calls return the cached result without re-scanning. `clearCache()` forces
/// a fresh scan. The cache is per-instance; tests use a fresh instance per case.
final class AppDiscoveryService {
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "AppDiscovery")
    private let searchDirectories: [String]
    private let excludedBundleIds: Set<String>
    private let cacheLock = NSLock()
    private var cachedResult: [AppPickerItem]?

    init(searchDirectories: [String] = ["/Applications", "\(NSHomeDirectory())/Applications"],
         excludedBundleIds: Set<String> = []) {
        self.searchDirectories = searchDirectories
        // Lowercase on init: filter comparison (`lowercased().contains`) only
        // works if callers can hand us bundle IDs in any case. Production
        // callers already pass lowercase (e.g. `com.apple.finder`), but the
        // unit test fixture uses mixed-case ids; normalizing here keeps both
        // paths coherent.
        self.excludedBundleIds = Set(excludedBundleIds.map { $0.lowercased() })
    }

    /// Async via completion handler (matches HistoryCaptureSettingsView's
    /// existing DispatchQueue.global + DispatchQueue.main pattern).
    func discoverInstalledApps(completion: @escaping ([AppPickerItem]) -> Void) {
        cacheLock.lock()
        if let cached = cachedResult {
            cacheLock.unlock()
            completion(cached)
            return
        }
        cacheLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var results: [AppPickerItem] = []
            let fileManager = FileManager.default
            let selfBundleId = Bundle.main.bundleIdentifier?.lowercased()

            for appDir in self.searchDirectories {
                guard let apps = try? fileManager.contentsOfDirectory(atPath: appDir) else { continue }
                for app in apps where app.hasSuffix(".app") {
                    let appPath = (appDir as NSString).appendingPathComponent(app)
                    guard let bundleId = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
                    else { continue }
                    let lowercasedId = bundleId.lowercased()
                    if self.excludedBundleIds.contains(lowercasedId) { continue }
                    if lowercasedId == selfBundleId { continue }
                    let name = (app as NSString).deletingPathExtension
                    // ID-PERF-0011 (2026-09-26): load the app icon here so
                    // the AppPickerRow renders a real image instead of an
                    // empty space. Previously `icon: nil` was hardcoded —
                    // AppPickerItem.icon had no producer anywhere in the
                    // codebase, so the picker showed no icons at all.
                    // NSWorkspace.icon(forFile:) is fast (LaunchServices
                    // caches results) and safe to call off-main.
                    let icon = NSWorkspace.shared.icon(forFile: appPath)
                    results.append(AppPickerItem(
                        name: name,
                        bundleId: bundleId,
                        icon: icon,
                        isRunning: false
                    ))
                }
            }

            self.cacheLock.lock()
            self.cachedResult = results
            self.cacheLock.unlock()

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    func clearCache() {
        cacheLock.lock()
        cachedResult = nil
        cacheLock.unlock()
    }
}

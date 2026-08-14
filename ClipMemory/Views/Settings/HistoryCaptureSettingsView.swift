import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// History & Capture settings tab: history limits, capture toggles,
/// sensitive-content auto-clear, and the excluded-apps list.
///
/// Self-contained — the maxItems reduction confirmation is presented as a
/// modal NSAlert on the settings window (the settings window is always in
/// the view tree, unlike the old sidebar-embedded Settings tab that hit
/// CLIP-3's dangling-alert bug), and the app picker sheet owns its own
/// search/loading state.
struct HistoryCaptureSettingsView: View {
    @ObservedObject var store: ClipboardStore
    // 2026-07-25: font-scale invalidation trigger. MUST be read in body —
    // an unread @AppStorage creates no SwiftUI dependency, so font-size
    // changes never re-rendered views that size via sz().
    @AppStorage("fontScale") private var fontScale: Double = 1.0

    @ObservedObject private var languageManager = LanguageManager.shared

    // Excluded-apps chips (M-12 pattern: cached lookup, refreshed on
    // appear + when excludedBundleIdsString changes).
    @State private var excludedApps: [(name: String, bundleId: String)] = []

    // App picker sheet state.
    @State private var showingAppPicker = false
    @State private var appPickerSearch = ""
    @State private var appPickerSearchDebounced = ""
    @State private var searchDebounce: DispatchWorkItem?
    @State private var installedApps: [AppPickerItem] = []
    @State private var isLoadingApps = false

    // ID-VIEW-0039: drag-and-drop rejection feedback, auto-clearing.
    @State private var dropHint: String?
    @State private var dropHintDismiss: DispatchWorkItem?

    var body: some View {
        let _ = fontScale  // 2026-07-25: subscribe to font-scale changes (see declaration)
        Form {
            // History
            Section {
                Picker(L10n.settingsMaxItems, selection: Binding(
                    get: { store.maxItems },
                    set: { newValue in
                        if newValue < store.maxItems, store.items.count > newValue {
                            confirmTrimReduction(old: store.maxItems, new: newValue)
                        } else {
                            store.maxItems = newValue
                        }
                    }
                )) {
                    ForEach([100, 500, 1000], id: \.self) { Text(L10n.settingsMaxItemsCount($0)).tag($0) }
                }.id(languageManager.selectedLanguage)
                Picker(L10n.trashRetentionDays, selection: $store.trashRetentionDays) {
                    // ID-L10N-0009 (2026-07-30 audit): see BackupSettingsView.
                    ForEach([3, 7, 14, 30], id: \.self) { Text(L10n.trashRetentionDaysCount($0)).tag($0) }
                }
            } header: { Text(L10n.settingsSectionHistory) }
            footer: { Text(L10n.settingsHistoryFooter).foregroundColor(.secondary) }

            // Capture
            Section {
                Toggle(L10n.settingsCaptureRichText, isOn: $store.captureRichText)
            } footer: { Text(L10n.settingsCaptureRichTextHint).foregroundColor(.secondary) }
            Section {
                Toggle(L10n.settingsOcrEnabled, isOn: Binding(
                    get: { store.ocrEnabled },
                    set: { store.ocrEnabled = $0 }
                ))
                Toggle(L10n.settingsHistoryCaptureOcrPreview, isOn: Binding(
                    // ID-VIEW-0005 (2026-07-31 audit): use the injected store
                    // instead of bypassing DI via ClipboardStore.shared.
                    get: { store.ocrPreviewEnabled },
                    set: { store.ocrPreviewEnabled = $0 }
                ))
            } footer: { Text(L10n.settingsOcrHint).foregroundColor(.secondary) }

            // Sensitive content — explanatory footer is split into its own
            // headerless Section so it renders outside the picker card
            // (Grouped Form draws footers inside the same section's card;
            // a headerless footer-only Section shows as a small outer
            // paragraph, matching the other explanatory footers above).
            Section {
                Picker(L10n.settingsAutoClear, selection: $store.sensitiveClearHours) {
                    // L-5 (2026-07-25 audit): use array index as ForEach identity
                    // rather than the semantic `hours` value, so two options can
                    // never collide even if the list ever maps different labels
                    // to the same hour.
                    ForEach(Array(SensitiveClearOption.options.enumerated()), id: \.offset) { _, option in
                        Text(option.label).tag(option.hours)
                    }
                }.id(languageManager.selectedLanguage)
            } header: { Text(L10n.settingsSectionSensitive) }
            Section {
                EmptyView()
            } footer: { Text(L10n.settingsSensitiveHint).foregroundColor(.secondary) }

            // Excluded apps
            Section {
                // ID-VIEW-0039 (2026-08-14): the whole section is one drop
                // target, so the VStack exists to give .onDrop a single frame
                // covering both the chips and the Add button.
                VStack(alignment: .leading, spacing: 8) {
                    exclusionUpdateNotice
                    excludedAppsTags
                    Button(action: { showingAppPicker = true }, label: {
                        Label(L10n.settingsAddExcludedApp, systemImage: "plus.circle")
                    }).buttonStyle(.link)
                    if let dropHint {
                        Text(dropHint)
                            .font(.system(size: sz(11)))
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleAppDrop(providers)
                }
            } header: { Text(L10n.settingsSectionExcludedApps) }
            footer: { Text(L10n.settingsExcludedAppsFooter).foregroundColor(.secondary) }
        }
        .formStyle(.grouped)
        .onAppear { refreshExcludedApps() }
        .onChange(of: store.excludedBundleIdsString) { _ in refreshExcludedApps() }
        .sheet(isPresented: $showingAppPicker) {
            appPickerSheet.onAppear {
                appPickerSearchDebounced = appPickerSearch
                loadInstalledAppsIfNeeded()
            }
        }
    }

    // MARK: - maxItems Reduction Confirmation

    /// The picker only stages the reduction; an NSAlert confirms it because
    /// confirming evicts real history items. On cancel nothing is written
    /// (the Binding's get still reads the old store.maxItems, so the picker
    /// snaps back on its own).
    private func confirmTrimReduction(old: Int, new: Int) {
        let alert = NSAlert()
        alert.messageText = L10n.alertTrimTitle
        alert.informativeText = L10n.alertTrimMessage(store.items.count, new)
        alert.addButton(withTitle: L10n.alertTrimConfirm)
        alert.addButton(withTitle: L10n.alertTrimCancel)
        if alert.runModal() == .alertFirstButtonReturn {
            ContentView.applyTrimConfirmation(pair: PendingMaxItemsReduction(old: old, new: new), store: store)
        }
    }

    // MARK: - Drag & Drop (ID-VIEW-0039)

    /// What one batch of dropped URLs resolved to.
    struct AppDropClassification: Equatable {
        var bundleIds: [String] = []
        var notAppCount = 0
        var unreadableCount = 0
        var containsSelf = false
    }

    /// Pure — the `resolveBundleId` seam keeps this testable without needing
    /// real .app bundles on disk.
    ///
    /// Rejection is explained after the drop rather than blocked mid-drag:
    /// SwiftUI's `.onDrop` can only filter by UTType while dragging, and a
    /// folder is as much a `.fileURL` as an app is. So everything lands, and
    /// whatever wasn't usable is reported.
    static func classifyDroppedURLs(
        _ urls: [URL],
        selfBundleId: String?,
        resolveBundleId: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    ) -> AppDropClassification {
        var result = AppDropClassification()
        for url in urls {
            // Dragging from the Dock or an alias can hand over a link.
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.pathExtension.lowercased() == "app" else {
                result.notAppCount += 1
                continue
            }
            guard let bundleId = resolveBundleId(resolved) else {
                result.unreadableCount += 1
                continue
            }
            if let selfBundleId, bundleId.lowercased() == selfBundleId.lowercased() {
                // Excluding ourselves would only suppress copies made while
                // ClipMemory is frontmost — near-zero benefit, and it reads as
                // the app switching itself off. loadInstalledAppsIfNeeded
                // hides it from the picker for the same reason; both entry
                // points must agree or one would offer what the other refuses.
                result.containsSelf = true
                continue
            }
            result.bundleIds.append(bundleId)
        }
        return result
    }

    /// Merge accepted ids into the stored list, preserving existing entries and
    /// their order. Returns the new comma-joined value, or nil when nothing
    /// changed (every dropped app was already excluded) so no write fires.
    static func mergeExcludedIds(existing: String, adding: [String]) -> String? {
        let current = existing
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var present = Set(current.map { $0.lowercased() })
        var merged = current
        for id in adding where present.insert(id.lowercased()).inserted {
            merged.append(id)
        }
        return merged.count == current.count ? nil : merged.joined(separator: ",")
    }

    private func handleAppDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        // Provider callbacks arrive on arbitrary queues, so serialize appends.
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            applyDrop(Self.classifyDroppedURLs(urls, selfBundleId: Bundle.main.bundleIdentifier))
        }
        return true
    }

    @MainActor
    private func applyDrop(_ classification: AppDropClassification) {
        if let merged = Self.mergeExcludedIds(
            existing: store.excludedBundleIdsString,
            adding: classification.bundleIds
        ) {
            store.excludedBundleIdsString = merged
        }
        // One line, most specific reason first. Dropping an app that was
        // already excluded is not a rejection and says nothing.
        if classification.containsSelf {
            showDropHint(L10n.settingsExcludedDropSelf)
        } else if classification.notAppCount > 0 {
            showDropHint(L10n.settingsExcludedDropNotApp)
        } else if classification.unreadableCount > 0 {
            showDropHint(L10n.settingsExcludedDropUnreadable)
        }
    }

    @MainActor
    private func showDropHint(_ message: String) {
        dropHintDismiss?.cancel()
        withAnimation { dropHint = message }
        let dismiss = DispatchWorkItem { withAnimation { dropHint = nil } }
        dropHintDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismiss)
    }

    // MARK: - Exclusion List Update Notice (ID-EXCLUDE-0002)

    /// Offers the corrected/expanded curated list to an existing install.
    ///
    /// Deliberately a prompt and not a migration. The list is a user setting;
    /// rewriting it from an app update — even to fix a default we shipped
    /// wrong — is not ours to do silently. So the user is told and decides.
    @ViewBuilder
    private var exclusionUpdateNotice: some View {
        let update = KnownExcludedApps.pendingUpdate(
            current: currentExcludedIds,
            dismissed: store.excludedUpdateDismissedIds
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        if !update.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: sz(11)))
                    .foregroundColor(.accentColor)
                Text(L10n.settingsExcludedUpdateNotice)
                    .font(.system(size: sz(11)))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.settingsExcludedUpdateApply) {
                    let applied = KnownExcludedApps.applying(update, to: currentExcludedIds)
                    store.excludedBundleIdsString = applied.joined(separator: ",")
                }
                .font(.system(size: sz(11)))
                Button(L10n.settingsExcludedUpdateDismiss) {
                    dismissExclusionUpdate(update)
                }
                .buttonStyle(.plain)
                .font(.system(size: sz(11)))
                .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.08))
            .cornerRadius(6)
            // Names the notice can't fit, so "what exactly changes?" is
            // answerable before committing to it.
            .help(update.introducedIds
                .map { KnownExcludedApps.displayName(for: $0) ?? $0 }
                .joined(separator: ", "))
        }
    }

    private var currentExcludedIds: [String] {
        store.excludedBundleIdsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Record exactly which ids were declined, so this dismissal doesn't
    /// suppress a future release's additions.
    private func dismissExclusionUpdate(_ update: KnownExcludedApps.PendingUpdate) {
        let existing = store.excludedUpdateDismissedIds
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set(existing.map { $0.lowercased() })
        var merged = existing
        for id in update.introducedIds where seen.insert(id.lowercased()).inserted {
            merged.append(id)
        }
        store.excludedUpdateDismissedIds = merged.joined(separator: ",")
    }

    // MARK: - Excluded Apps Chips

    /// Local copy of the chips view (see SettingsView's excludedAppsTags).
    /// L-14 (2026-07-25 audit): @ViewBuilder instead of AnyView to preserve
    /// SwiftUI identity/diffing.
    @ViewBuilder
    private var excludedAppsTags: some View {
        if excludedApps.isEmpty {
            EmptyView()
        } else {
            let excludedIds = store.excludedBundleIdsString
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            FlowLayout(spacing: 6) {
                ForEach(excludedApps, id: \.bundleId) { app in
                    ExcludedAppChip(name: app.name, bundleId: app.bundleId) {
                        let newIds = excludedIds.filter { $0 != app.bundleId }
                        store.excludedBundleIdsString = newIds.joined(separator: ",")
                    }
                }
            }
        }
    }

    /// M-12 (2026-07-24 audit): rebuild the cached `excludedApps` array from
    /// the store's excluded bundle ids. Called on appear + whenever the
    /// excludedBundleIdsString changes.
    private func refreshExcludedApps() {
        let rawIds = store.excludedBundleIdsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let excludedIds = rawIds.filter { seen.insert($0).inserted }
        excludedApps = excludedIds.map { bundleId in
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                return (app.localizedName ?? bundleId, bundleId)
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return (url.deletingPathExtension().lastPathComponent, bundleId)
            }
            // ID-VIEW-0040 (2026-08-14): an id that resolves nowhere is the
            // COMMON case here, not the exception — the seeded password
            // managers usually aren't installed. Prefer a curated name so the
            // chip reads "1Password 7" rather than a bundle id.
            if let curated = KnownExcludedApps.displayName(for: bundleId) {
                return (curated, bundleId)
            }
            // CLIP-4 (2026-07-24 review): with no curated name either, show the
            // raw bundle id — an unresolvable id must NOT be dropped, it stays
            // visible and removable. ExcludedAppChip truncates it and exposes
            // the full value as a tooltip.
            return (bundleId, bundleId)
        }
    }

    // MARK: - App Picker Sheet

    private var appPickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.settingsAddExcludedApp).font(.system(size: sz(14), weight: .semibold))
                Spacer()
                Button(L10n.buttonDone) { showingAppPicker = false }
                    .buttonStyle(.plain)
                    .font(.system(size: sz(12)))
                    .foregroundColor(.accentColor)
            }
            .padding()
            Color.clear.frame(height: 1)
            TextField(L10n.settingsAppPickerSearch, text: $appPickerSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onChange(of: appPickerSearch) { newValue in
                    DispatchQueue.main.async {
                        searchDebounce?.cancel()
                        let item = DispatchWorkItem { appPickerSearchDebounced = newValue }
                        searchDebounce = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
                    }
                }
            Color.clear.frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let excludedIds = Set(store.excludedBundleIdsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    let allApps = installedApps.sorted { $0.name < $1.name }

                    let search = appPickerSearchDebounced.lowercased()
                    let filtered = allApps.filter {
                        search.isEmpty || $0.name.lowercased().contains(search)
                    }

                    // ID-VIEW-0006 (2026-07-31 audit): only show the spinner
                    // when there is nothing to display — during a background
                    // revalidation the cached list stays visible.
                    if isLoadingApps && installedApps.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().scaleEffect(0.8)
                            Spacer()
                        }
                        .padding()
                    } else if filtered.isEmpty {
                        Text(L10n.settingsAppPickerNoResults).font(.system(size: sz(12))).foregroundColor(.secondary).padding()
                    } else {
                        // BUG-006 (2026-07-21): use \.bundleId (stable across
                        // re-filter), not \.self on indices.
                        ForEach(filtered, id: \.bundleId) { app in
                            AppPickerRow(
                                name: app.name,
                                bundleId: app.bundleId,
                                icon: app.icon,
                                isExcluded: excludedIds.contains(app.bundleId),
                                onToggle: {
                                    var ids = Array(excludedIds)
                                    if excludedIds.contains(app.bundleId) {
                                        ids.removeAll { $0 == app.bundleId }
                                    } else {
                                        ids.append(app.bundleId)
                                    }
                                    store.excludedBundleIdsString = ids.joined(separator: ",")
                                }
                            )
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 450)
    }

    /// M-10 (2026-07-25 audit): the static app cache is read on the main
    /// thread but written from a `DispatchQueue.main.async` callback. Use a
    /// lock so a future caller can't race the read/write.
    private static var cachedApps: [AppPickerItem]?
    private static let cachedAppsLock = NSLock()

    /// Kick off a background fetch of installed applications. Icons are loaded
    /// lazily by AppPickerRow via NSImage, so only the directory scan and bundle
    /// ID lookup run on the background queue. Results are cached statically.
    ///
    /// ID-VIEW-0006 (2026-07-31 audit): the static cache previously never
    /// expired within the process lifetime, so apps installed/uninstalled
    /// after the first picker open stayed stale until app restart. Now
    /// stale-while-revalidate: serve the cache instantly (no flicker), but
    /// always kick a fresh background scan on every sheet open and swap in
    /// the new results when they land.
    private func loadInstalledAppsIfNeeded() {
        guard !isLoadingApps else { return }
        Self.cachedAppsLock.lock()
        let cached = Self.cachedApps
        Self.cachedAppsLock.unlock()
        if let cached = cached, installedApps.isEmpty {
            installedApps = cached
        }
        isLoadingApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [AppPickerItem] = []
            let fileManager = FileManager.default
            let appDirs = ["/Applications", NSHomeDirectory() + "/Applications"]

            for appDir in appDirs {
                guard let apps = try? fileManager.contentsOfDirectory(atPath: appDir) else { continue }
                for app in apps where app.hasSuffix(".app") {
                    let appPath = (appDir as NSString).appendingPathComponent(app)
                    let name = (app as NSString).deletingPathExtension
                    if let bundleId = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier {
                        // ID-VIEW-0039: hide ClipMemory itself — see
                        // classifyDroppedURLs for why self-exclusion is refused.
                        if bundleId.lowercased() == Bundle.main.bundleIdentifier?.lowercased() { continue }
                        results.append(AppPickerItem(name: name, bundleId: bundleId, icon: nil, isRunning: false))
                    }
                }
            }
            DispatchQueue.main.async {
                Self.cachedAppsLock.lock()
                Self.cachedApps = results
                Self.cachedAppsLock.unlock()
                self.installedApps = results
                self.isLoadingApps = false
            }
        }
    }
}

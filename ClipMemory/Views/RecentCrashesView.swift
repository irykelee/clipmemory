import SwiftUI
import AppKit
import os

/// ID-CRASH-0002 (2026-08-16 audit MEDIUM-1 fix): the "View Recent Crashes"
/// window. Lists every crash report for ClipMemory that macOS has
/// written to `~/Library/Logs/DiagnosticReports/`, sorted newest-first.
///
/// The window is intentionally read-only — the .ips files are owned
/// by macOS and the user should not edit them. The only actions are
/// "Reveal in Finder" (so the user can drag the .ips file into an
/// issue or DM) and "Open in Console.app" (so the user gets the
/// formatted symbolicated view Console.app offers). Actual post-mortem
/// symbolication (matching image offsets to function names) is a
/// separate offline step using the dSYM shipped via ID-CRASH-0001 +
/// `atos`; this window surfaces enough metadata for the user to copy
/// the relevant identifiers into that command themselves.
struct RecentCrashesView: View {
    private static let logger = Logger(subsystem: "com.clipmemory.app", category: "RecentCrashesView")

    @State private var reports: [CrashReport] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    var body: some View {
        VStack(spacing: 0) {
            // ID-CRASH-0006 (2026-09-26): always surface the load error
            // as a banner above the table, even when `reports` is
            // non-empty from a prior successful load. Previously the
            // errorView only rendered when `reports.isEmpty`, so a
            // failed refresh on a previously-populated list silently
            // kept showing stale data — the user had no signal that
            // the list was outdated. The banner is the third leg of
            // the per-CLAUDE.md three-piece gate (log via the catch
            // in `loadReports`; retry via `.task` re-fire on next
            // window appear; user-visible here).
            if let err = loadError, !reports.isEmpty {
                errorBanner(message: err)
            }
            Group {
                if isLoading && reports.isEmpty {
                    ProgressView(L10n.crashLoadingPlaceholder)
                        .controlSize(.small)
                } else if let err = loadError, reports.isEmpty {
                    errorView(message: err)
                } else if reports.isEmpty {
                    emptyView
                } else {
                    reportsTable
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .task(id: hasLoadedOnce) {
            // ID-CRASH-0002: load on first appearance and refresh when
            // the window re-appears (Cmd+W then re-open). Using `task(id:)`
            // keyed on hasLoadedOnce lets us re-trigger via .onAppear.
            await loadReports()
        }
        .onAppear {
            // .task(id:) only re-fires when the id changes, so we bump
            // it manually on every window-appear to refresh the list.
            // The actual FileManager hit is cheap (filter + sort + JSON
            // parse on a directory with at most a few dozen files).
            hasLoadedOnce.toggle()
        }
    }

    /// Compact error banner shown above the table when a refresh fails
    /// on a previously-populated list. Full-screen `errorView` is kept
    /// for the first-load failure case (when there's nothing else to
    /// show). See ID-CRASH-0006.
    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: sz(11)))
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    private var reportsTable: some View {
        Table(reports) {
            TableColumn(L10n.crashColumnDate) { report in
                Text(report.date, style: .date)
                    .font(.system(size: sz(12)))
                    + Text("  ")
                    + Text(report.date, style: .time)
                    .font(.system(size: sz(12)))
            }
            .width(min: 140, ideal: 160)

            TableColumn(L10n.crashColumnProcess) { report in
                Text(report.processName)
                    .font(.system(size: sz(12), weight: .medium))
            }
            .width(min: 120, ideal: 140)

            TableColumn(L10n.crashColumnException) { report in
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.exceptionType)
                        .font(.system(size: sz(12)))
                    if let signal = report.signal {
                        Text(signal)
                            .font(.system(size: sz(11)))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn(L10n.crashColumnFirstFrame) { report in
                Text(report.firstFrameLine)
                    .font(.system(size: sz(11), design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .width(min: 200, ideal: 320)

            TableColumn("") { report in
                HStack(spacing: 6) {
                    Button(L10n.crashActionRevealInFinder) {
                        revealInFinder(report)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L10n.crashActionRevealInFinder)

                    Button(L10n.crashActionOpenInConsole) {
                        openInConsole(report)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L10n.crashActionOpenInConsole)
                }
            }
            .width(min: 160, ideal: 180)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: sz(48)))
                .foregroundColor(.secondary)
            Text(L10n.crashEmptyHeading)
                .font(.system(size: sz(15), weight: .semibold))
            Text(L10n.crashEmptyBody)
                .font(.system(size: sz(12)))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: sz(40)))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: sz(12)))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func loadReports() async {
        isLoading = true
        loadError = nil
        let service = CrashReportService.shared
        // Per CLAUDE.md 2026-08-08 three-piece gate (extended to non-
        // persistence paths in ID-CRASH-0006): surface I/O errors
        // loudly via (1) the `logger.error` below, (2) the auto-retry
        // via `.task(id:)` re-fire on the next window-appear, and
        // (3) the user-visible banner in `body` (above) when reports
        // are non-empty, or the full-screen `errorView` when reports
        // is empty (first-load failure). The service throws for
        // permission-revoked / unexpected I/O; empty directory is
        // a happy-path empty array.
        do {
            reports = try service.listRecentCrashReports()
        } catch {
            // ID-CRASH-0006: log part of the three-piece gate. Without
            // this, a failed refresh on a populated list was completely
            // invisible (stale data + silent error), so the user (and
            // any CI failure log) had no way to know the list was
            // outdated. logger.error is the durable record.
            Self.logger.error("RecentCrashesView: load failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Reveal the .ips file in Finder. Selecting the parent dir
    /// keeps the file highlighted — bare `NSWorkspace.open(url)`
    /// would launch Console.app via UTI, which is not what the user
    /// wants from this button.
    private func revealInFinder(_ report: CrashReport) {
        NSWorkspace.shared.activateFileViewerSelecting([report.fileURL])
    }

    /// Open the .ips file in Console.app via Launch Services. Console.app
    /// knows how to render the JSON-crash format with header / threads /
    /// symbolicated frames in its own structured viewer.
    private func openInConsole(_ report: CrashReport) {
        NSWorkspace.shared.open(report.fileURL)
    }
}
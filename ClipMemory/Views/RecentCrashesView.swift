import SwiftUI
import AppKit

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
    @State private var reports: [CrashReport] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    var body: some View {
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
        // Per CLAUDE.md 2026-08-08 three-piece gate: surface I/O errors
        // loudly rather than silently swallowing. The service throws
        // for permission-revoked / unexpected I/O; empty directory is
        // a happy-path empty array.
        do {
            reports = try service.listRecentCrashReports()
        } catch {
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
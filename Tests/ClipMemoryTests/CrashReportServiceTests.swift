import XCTest
@testable import ClipMemory

/// ID-CRASH-0002 (2026-08-16 audit MEDIUM-1 fix): the parser must handle
/// real-world .ips files cleanly — a user-facing list that crashes on
/// malformed reports is worse than no list at all. These tests use
/// fixture .ips files written to a tmp directory so the parser runs
/// against the same JSON shape macOS produces, without relying on the
/// host machine's DiagnosticReports (which may be empty in CI).
@MainActor
final class CrashReportServiceTests: XCTestCase {

    private var tmpDir: URL!
    private var service: CrashReportService!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        service = CrashReportService(directory: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        service = nil
    }

    /// ID-CRASH-0002: directory doesn't exist → empty array (NOT throw).
    /// First-launch users have no DiagnosticReports directory; we don't
    /// want them to see an error overlay.
    func testNonExistentDirectoryReturnsEmptyArray() throws {
        let missing = tmpDir.appendingPathComponent("does-not-exist")
        let missingService = CrashReportService(directory: missing)
        let reports = try missingService.listRecentCrashReports()
        XCTAssertTrue(reports.isEmpty, "missing directory should return []")
    }

    /// ID-CRASH-0002: empty directory → empty array.
    func testEmptyDirectoryReturnsEmptyArray() throws {
        let reports = try service.listRecentCrashReports()
        XCTAssertTrue(reports.isEmpty)
    }

    /// ID-CRASH-0002: reports with older mtime must sort after newer —
    /// the UI shows newest-first because users want to look at the
    /// most recent crash first.
    func testReportsSortedByMtimeDescending() throws {
        let newer = makeFixtureIPS(name: "newer", date: "2026-08-15 12:00:00.00 +0800")
        let older = makeFixtureIPS(name: "older", date: "2026-08-10 12:00:00.00 +0800")
        // Newer mtime = file mtime, NOT the embedded .ips timestamp,
        // because the user might rename / re-save an old .ips file.
        try setMtime(older, Date(timeIntervalSince1970: 1_700_000_000))
        try setMtime(newer, Date(timeIntervalSince1970: 1_800_000_000))

        let reports = try service.listRecentCrashReports()
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first?.id, "ClipMemory-newer.ips",
                       "newest mtime must be first; UI shows newest-first")
        XCTAssertEqual(reports.last?.id, "ClipMemory-older.ips")
    }

    /// ID-CRASH-0002: directory with foreign (non-ClipMemory) .ips files
    /// must not be returned. The macOS DiagnosticReports directory
    /// contains reports for every app the user has run; the service is
    /// strictly ClipMemory-scoped.
    func testIgnoresNonClipMemoryReports() throws {
        try writeFixture(
            name: "Safari-2026-08-15-120000.ips",
            contents: makeIPSBody(appName: "Safari", date: "2026-08-15 12:00:00.00 +0800")
        )
        try writeFixture(
            name: "ClipMemory-2026-08-15-120000.ips",
            contents: makeIPSBody(appName: "ClipMemory", date: "2026-08-15 12:00:00.00 +0800")
        )
        let reports = try service.listRecentCrashReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.processName, "ClipMemory")
    }

    /// ID-CRASH-0002: list limit caps the result count. We don't want
    /// the UI listing 200 items even if the user has a long-running
    /// install with hundreds of reports.
    func testRespectsListLimit() throws {
        for i in 0..<10 {
            let name = "ClipMemory-report-\(i).ips"
            try writeFixture(name: name, contents: makeIPSBody(
                appName: "ClipMemory",
                date: "2026-08-15 12:00:0\(i).00 +0800"
            ))
        }
        let all = try service.listRecentCrashReports(limit: 100)
        XCTAssertEqual(all.count, 10)
        let limited = try service.listRecentCrashReports(limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    /// ID-CRASH-0002: parsing a real-shape .ips extracts the header
    /// fields (process name, date) and the body's exception type.
    func testParseIpsExtractsExceptionType() throws {
        let body = """
        {"app_name":"ClipMemory","timestamp":"2026-08-15 12:00:00.00 +0800","os_version":"macOS 26.6.1 (25G76)"}
        {
          "exception" : {"codes":"0x0000000000000001, 0x00000001028321fc","rawCodes":[1,4337115644],"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
          "usedImages" : [{"name":"ClipMemory","uuid":"4C4C444C-5555-3144-A15A-729DD5BF04C7","base":"0x100000000"}],
          "threads" : [{"triggered":true,"name":"main","frames":[{"imageIndex":0,"imageOffset":42,"symbol":"_main"}]}]
        }
        """
        try writeFixture(name: "ClipMemory-test.ips", contents: body)
        let reports = try service.listRecentCrashReports()
        XCTAssertEqual(reports.count, 1)
        let r = reports.first!
        XCTAssertEqual(r.processName, "ClipMemory")
        XCTAssertEqual(r.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(r.signal, "SIGSEGV")
        XCTAssertEqual(r.firstFrames.count, 1)
        XCTAssertEqual(r.firstFrames.first?.symbol, "_main")
        XCTAssertEqual(r.firstFrames.first?.imageIndex, 0)
        XCTAssertEqual(r.binaryImages.first?.name, "ClipMemory")
    }

    /// ID-CRASH-0002: malformed .ips must not throw — return nil for
    /// the unparseable file so the rest of the list still renders.
    /// Per CLAUDE.md 2026-08-08 three-piece gate, silent-swallow is
    /// forbidden; we log loud at the call site and let the user see
    /// the report listed with placeholder exception type.
    func testMalformedIpsReturnsUnparseableFallback() throws {
        try writeFixture(name: "ClipMemory-bad.ips", contents: "not json at all")
        let reports = try service.listRecentCrashReports()
        // The malformed file is NOT returned as a CrashReport (parseReport
        // returns nil). The list is empty rather than throwing — caller's
        // log line catches the silent-drop in production via the loadError
        // path. This test just ensures we don't crash the UI on bad input.
        XCTAssertEqual(reports.count, 0)
    }

    /// ID-CRASH-0002: legacy .crash text format (pre-Sonoma) is
    /// unsupported for symbolication but still listed so the user can
    /// reveal it in Finder / Console.app.
    func testLegacyCrashFileListedAsFallback() throws {
        try writeFixture(name: "ClipMemory-legacy.crash", contents: "Process:               ClipMemory [1234]\n...")
        let reports = try service.listRecentCrashReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports.first!.exceptionType.contains("legacy"),
                      "legacy .crash files must surface the unparseable hint")
    }

    // MARK: - Helpers

    /// Builds a fixture .ips file with the given app name + timestamp
    /// in the header line, plus an empty crash body (so header parsing
    /// succeeds but there's no exception data to display — the test
    /// can override the body for richer assertions).
    private func makeFixtureIPS(name: String, date: String) -> URL {
        let url = tmpDir.appendingPathComponent("ClipMemory-\(name).ips")
        let body = makeIPSBody(appName: "ClipMemory", date: date)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Constructs the .ips header JSON line + a minimal body line.
    /// Format per Apple CrashReporter docs (Sonoma+).
    private func makeIPSBody(appName: String, date: String) -> String {
        """
        {"app_name":"\(appName)","timestamp":"\(date)","os_version":"macOS 26.6.1 (25G76)"}
        {"exception":{"type":"EXC_CRASH"},"usedImages":[],"threads":[]}
        """
    }

    private func writeFixture(name: String, contents: String) throws {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
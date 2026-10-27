import Foundation
import XCTest

/// ID-REVIEW-1040 (2026-10-27): destroying a `UserDefaults` suite has to
/// remove its **file**, not only its values — and it has to remove it in
/// the one order that stops `cfprefsd` from writing it back.
///
/// ## The defect (measured, not inferred)
///
/// `removePersistentDomain(forName:)` clears a suite's values but leaves
/// `~/Library/Preferences/<suite>.plist` on disk — a ~42-byte empty shell
/// that still occupies a whole 4 KB block. Measured on the developer's
/// machine: **199 536** such files, **819 MB** of blocks (the bytes
/// themselves are only 21.8 MB — the 4 KB block rounding is the whole
/// cost), and one full test run added **339** more.
///
/// The leftovers are **empty shells**: a sampled `plist` decodes to `{}` —
/// the values were removed long ago, only the file survived. So they carry
/// no data; they are pure litter that makes the directory expensive to
/// enumerate (199 k entries).
///
/// Every suite-creating site leaked, whether or not it called
/// `removePersistentDomain` — because the **file** was never touched.
///
/// ## The order matters (measured, 40 iterations per strategy)
///
/// | strategy | file came back (in-process) |
/// |---|---|
/// | `removePersistentDomain` → delete file | **5/40** (empty shell) |
/// | `removePersistentDomain` → `removeSuite` → delete file | **5/40** |
/// | `removeSuite` → delete file | **0/40** ✅ |
/// | `removeSuite` → delete file → `removePersistentDomain` | **40/40** |
///
/// Three facts fall out of that table, and all of them are load-bearing:
///
/// 1. `removePersistentDomain` alone is **not** enough — it leaves a
///    **pending write** in `cfprefsd`, and `cfprefsd` then writes the
///    (now empty) domain back to disk roughly one time in eight.
/// 2. Calling it **last** is worse, not better: the pending write is
///    still outstanding, so the empty shell comes back in **every** run.
///    ⇒ `destroy` must not call it at all.
/// 3. `removePersistentDomain` **before** `removeSuite` neutralises the
///    `removeSuite` (row 2 is as bad as row 1).
///
/// `removeSuite(named:)` makes `cfprefsd` forget the domain; the explicit
/// file delete then removes what is on disk. Neither step alone is enough:
/// `removeSuite` does **not** delete the file (measured: the file was
/// still there in 40/40 runs, with its old bytes and an unmoved mtime),
/// and the file delete alone is undone by the write-back above.
///
/// ## What `destroy` deliberately does NOT do
///
/// It does **not** clear the suite's values in `cfprefsd`'s memory.
/// `removePersistentDomain` is the only API that does that, and calling it
/// is exactly what produces the empty-shell write-back (rows 1, 2 and 4 of
/// the table). Measured consequence of not clearing: after
/// `removeSuite` + file delete, a FRESH `UserDefaults(suiteName:)` still
/// reads the old values back (40/40), and writing to the old instance
/// recreates the file (40/40).
///
/// That is acceptable **because every suite this file manages carries a
/// UUID in its name**, so the name is never reused — and the persistent
/// copy (the file) is gone, so nothing survives the process. The one case
/// that would break is "destroy a suite, then create one with the SAME
/// name" — `makeSuite(named:)` therefore clears the domain when it sees a
/// name this process already used.
///
/// ## The domain is not flushed back at process exit
///
/// Measured (20 suites per strategy, then the process exits and the files
/// are checked afterwards): `removePersistentDomain` → delete,
/// `removeSuite` → delete, `defaults delete`, and the other three
/// strategies all came back **0/20** after the process exited. ⇒ `cfprefsd`
/// does not re-persist a cached domain when its client goes away, so
/// deleting the file while the process runs is enough.
///
/// ## Why a registry, not just a better `removeTestDefaults`
///
/// A precise `destroy` only covers the suites a test remembers to clean
/// up. Two things escape it:
///
/// * a suite created but never destroyed — measured: **15 test files** do
///   exactly that, and they were the ones still leaking after the fix,
/// * a test host that dies before its `tearDown` runs — the exact failure
///   mode this repo has already been bitten by twice (CI run 40186263416).
///
/// So every suite this process creates is **registered**, and a sweep
/// destroys whatever is left. The sweep runs **after every test case**
/// (`testCaseDidFinish`), NOT at the end of the bundle: measured
/// 2026-10-27, `testBundleWillFinish` is **never called** in this repo's
/// app-hosted test host — the bundle-level observer's body never ran
/// through a full 1294-test run. The per-case hook does fire (the repo's
/// own shared-suite write guard is built on it).
///
/// The observer is installed from the **first suite creation**, not from a
/// test class's `setUp` — the ID-REVIEW-1034 lesson is that a guard whose
/// registration lives in a class hook dies silently when that class does
/// not run.
enum TestSuiteCleanup {

    // MARK: - The file

    /// The file `UserDefaults` persists a suite into.
    ///
    /// `UserDefaults` exposes no public "what is my suite name" accessor,
    /// so the name is carried alongside the instance everywhere.
    static func preferencesFileURL(for suiteName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(suiteName).plist")
    }

    /// Whether the suite still has a file on disk.
    static func hasPreferencesFile(for suiteName: String) -> Bool {
        FileManager.default.fileExists(atPath: preferencesFileURL(for: suiteName).path)
    }

    // MARK: - Destroying

    /// Destroys a suite: its **file** goes away.
    ///
    /// ⚠️ The order is load-bearing — see the table at the top of this file.
    ///
    /// ⚠️ It does **not** clear the values in `cfprefsd`'s memory — see
    /// "What `destroy` deliberately does NOT do" above. The persistent copy
    /// (the file) is what leaks onto the user's disk, and that is what this
    /// removes.
    static func destroy(suiteName: String) {
        guard mayDestroy(suiteName: suiteName) else {
            // Never touch the production domain: `removeSuite` on the app's
            // own bundle id would delete the USER's real preferences. The
            // test host shares `com.clipmemory.app` with the shipping app
            // (ID-REVIEW-1039), so this is a live hazard, not a theoretical
            // one.
            assertionFailure(
                "ID-REVIEW-1040: refusing to destroy the production domain "
                + "(\(suiteName)) — `removeSuite` would delete the user's real preferences"
            )
            return
        }
        // 1. make cfprefsd FORGET the domain, so it cannot write it back.
        UserDefaults.standard.removeSuite(named: suiteName)
        // 2. `removeSuite` does not delete the file — do it explicitly.
        //
        //    ⚠️ Do NOT add a `synchronize()` here. It looks like a safety
        //    measure ("flush the pending write before deleting the file"),
        //    but it PERSISTS the domain into cfprefsd — which cfprefsd then
        //    re-flushes when the client goes away. Measured by the
        //    independent verifier (2026-10-27): with `synchronize()` the
        //    residue was +18 per run, without it **+2**.
        try? FileManager.default.removeItem(at: preferencesFileURL(for: suiteName))
        registry.forget(suiteName: suiteName)
    }

    /// Destroys a suite instance, looking its name up in the registry.
    ///
    /// Returns `false` when the instance was not created through this
    /// helper — the caller then has no name to remove and the file (if
    /// any) stays. That is reported rather than swallowed, because a suite
    /// that is not registered is a suite nobody will ever clean up.
    @discardableResult
    static func destroy(_ defaults: UserDefaults) -> Bool {
        guard let suiteName = registry.name(for: defaults) else { return false }
        destroy(suiteName: suiteName)
        return true
    }

    // MARK: - Creating

    /// Creates a suite and registers it for the per-test-case sweep.
    ///
    /// ⚠️ A suite name that `UserDefaults` rejects would be a programming
    /// error. It used to fall back to `.standard` at some call sites — but
    /// inside the test host `.standard` **is** the user's real
    /// `com.clipmemory.app` domain (ID-REVIEW-1039), so that fallback is a
    /// production-data hazard, not a convenience. Failing loudly is the
    /// safe direction.
    static func makeSuite(named suiteName: String) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure(
                "ID-REVIEW-1040: `UserDefaults` rejected the suite name \(suiteName)"
            )
        }
        if registry.wasCreated(suiteName) {
            // Same name, second time in this process. `destroy` deliberately
            // does NOT clear the values in cfprefsd's memory (doing so is
            // what produces the empty-shell write-back), so a name this
            // process already used can still carry its old values.
            // Clearing them here is safe: a fresh suite has never been
            // written, so there is nothing to lose.
            defaults.removePersistentDomain(forName: suiteName)
        }
        register(defaults, suiteName: suiteName)
        return defaults
    }

    /// Registers a suite instance under its name.
    static func register(_ defaults: UserDefaults, suiteName: String) {
        _ = observerInstalled
        _ = idleSweeper
        // The same production-domain refusal as `destroy`: a registered
        // suite's FILE is deleted by the sweeps, so registering the
        // production domain would delete the user's real preferences.
        guard mayDestroy(suiteName: suiteName) else {
            assertionFailure(
                "ID-REVIEW-1040: refusing to register the production domain "
                + "(\(suiteName)) — its file is deleted by the sweep"
            )
            return
        }
        registry.remember(defaults, suiteName: suiteName)
    }

    // MARK: - The process-end sweep

    /// Destroys every suite this process created and has not destroyed yet.
    ///
    /// The safety net for "the host died before `tearDown`" and for the
    /// call sites that create a suite and never remove it.
    @discardableResult
    static func destroyAllRegistered() -> Int {
        let names = registry.allNames()
        for name in names {
            destroy(suiteName: name)
        }
        return names.count
    }

    /// Deletes the file of every suite this process ever created.
    ///
    /// The second half of the sweep. `destroy` removes the file, but a
    /// suite destroyed **mid-run** can still have its file written back
    /// afterwards (measured: ~1 in 8 with `removePersistentDomain`; 0 in 40
    /// with the `removeSuite` order this file uses). Re-deleting at the end
    /// of the bundle catches whatever landed after the individual destroy,
    /// so the run leaves no trace behind.
    @discardableResult
    static func deleteAllCreatedFiles() -> Int {
        var deleted = 0
        for name in registry.allCreatedNames() {
            guard mayDestroy(suiteName: name) else { continue }
            guard hasPreferencesFile(for: name) else { continue }
            if (try? FileManager.default.removeItem(at: preferencesFileURL(for: name))) != nil {
                deleted += 1
            }
        }
        return deleted
    }

    /// Deletes the file of every suite that was already **destroyed**.
    ///
    /// The live suites are left alone: their file may be about to be
    /// written by the test that owns them.
    @discardableResult
    static func deleteDestroyedFiles() -> Int {
        var deleted = 0
        for name in registry.allDestroyedNames() {
            guard mayDestroy(suiteName: name) else { continue }
            guard hasPreferencesFile(for: name) else { continue }
            if (try? FileManager.default.removeItem(at: preferencesFileURL(for: name))) != nil {
                deleted += 1
            }
        }
        return deleted
    }

    /// The suites this process has registered and not yet destroyed.
    static var registeredSuiteNames: [String] { registry.allNames() }

    /// Every suite name this process has created.
    static var createdSuiteNames: [String] { registry.allCreatedNames() }

    /// Installs the observer exactly once per process.
    ///
    /// Triggered from the first registration, so it does not depend on any
    /// test class running first.
    private static let observerInstalled: Void = {
        XCTestObservationCenter.shared.addTestObserver(ProcessEndObserver())
        XCTestObservationCenter.shared.addTestObserver(TestCaseScopeObserver())
    }()

    /// The observer that runs the sweep when the test bundle finishes.
    ///
    /// ⚠️ **This one does not fire in this repo's test host.** Measured
    /// 2026-10-27: the observer's body never ran (it writes a report file
    /// and the file was not there after a full run), so the bundle-end
    /// sweep is a **second** layer, not the primary one. The primary layer
    /// is `TestCaseScopeObserver` below.
    private final class ProcessEndObserver: NSObject, XCTestObservation {
        func testBundleWillFinish(_ testBundle: Bundle) {
            TestSuiteCleanup.destroyAllRegistered()
            Thread.sleep(forTimeInterval: 0.3)
            TestSuiteCleanup.deleteAllCreatedFiles()
        }
    }

    /// The observer that cleans up after **every test case**.
    ///
    /// This is the layer that actually works here, and it is not a
    /// substitute — it is the mechanism:
    ///
    /// * `XCTestObservation.testBundleWillFinish(_:)` is **never called**
    ///   in this repo's app-hosted test host (the test bundle is injected
    ///   into the app binary). Measured 2026-10-27: a report file the
    ///   bundle-level observer was supposed to write did not exist after a
    ///   full 1294-test run.
    /// * `testCaseWillStart` / `testCaseDidFinish` **do** fire — the repo
    ///   already depends on them (`XCTestIsolationSuiteBootstrap`'s write
    ///   guard is built on `testCaseDidFinish`, and it catches violations
    ///   in CI).
    ///
    /// So the sweep runs after every test case, which is also *finer* than
    /// a bundle-end sweep: a suite is destroyed when the case that made it
    /// is over, not when the whole run is over. That covers the sites that
    /// create a suite and never destroy it — the very pattern that leaked
    /// 199 822 files.
    private final class TestCaseScopeObserver: NSObject, XCTestObservation {
        func testCaseWillStart(_ testCase: XCTestCase) {
            TestSuiteCleanup.beginTestCase()
        }

        func testCaseDidFinish(_ testCase: XCTestCase) {
            TestSuiteCleanup.endTestCase()
        }
    }

    /// Starts a test case's scope.
    ///
    /// The scope counter is what keeps the idle sweeper away while a test
    /// is running: the sweeper deletes files, and a test that has just
    /// written one needs it to still be there.
    static func beginTestCase() {
        registry.beginScope()
    }

    /// Ends a test case: every suite this process still holds is destroyed,
    /// and the file of every suite it ever created is deleted again.
    ///
    /// The second half is not belt-and-braces — it is the part that closes
    /// the leak. A service can hold a suite **past** the test that injected
    /// it (a store kept in a container, a language manager bound to a
    /// suite). Its next write re-creates the domain, and therefore the
    /// file, **after** the destroy — measured: that was 53 leftover files
    /// per full run, with the values still in them (the domain's own keys:
    /// `ImageStorageMigrationComplete`, `UpdateFeedPolicy`,
    /// `AppleLanguages`/`appLanguage`, `safeMode.*`).
    ///
    /// Deleting the file again at the END of the next test case removes
    /// those. The domain stays alive in `cfprefsd` (so a retained service
    /// keeps working), only its file on disk goes.
    static func endTestCase() {
        registry.endScope()
        destroyAllRegistered()
        deleteAllCreatedFiles()
    }

    // MARK: - The idle sweeper

    /// Deletes the file of every **destroyed** suite, whenever no test case
    /// is running.
    ///
    /// The last batch of writes lands after the last test case ends:
    /// measured, the 15 files that survived the per-case sweep were all
    /// written in the SAME SECOND, at the very end of the run — a service
    /// that outlived every test flushing its settings on the way out. No
    /// per-case hook can catch those, because there is no next case.
    ///
    /// So a timer sweeps while the suite is idle. It only touches suites
    /// that were already destroyed (never a live one), and it does nothing
    /// at all while a test case is open — so it cannot delete a file a
    /// running test is about to assert on.
    private static let idleSweeper: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler {
            guard TestSuiteCleanup.registry.isIdle else { return }
            TestSuiteCleanup.deleteDestroyedFiles()
        }
        timer.resume()
        return timer
    }()

    /// Starts the idle sweeper. Idempotent.
    static func startIdleSweeper() {
        _ = idleSweeper
    }

    /// The name of the suite `defaults` was created under, if it is known.
    ///
    /// `UserDefaults` exposes no suite-name accessor, so the name lives in
    /// the registry — which is the only place that knows it.
    static func registeredName(for defaults: UserDefaults) -> String? {
        registry.name(for: defaults)
    }

    // MARK: - Safety

    /// The production domain — the user's real preferences.
    ///
    /// The test host IS the app (ID-REVIEW-1039), so `UserDefaults.standard`
    /// inside a test process addresses the shipping app's domain.
    static let productionDomainName = "com.clipmemory.app"

    /// Whether `destroy(suiteName:)` may touch this suite.
    ///
    /// The production domain is the only forbidden target: `removeSuite`
    /// on the app's own bundle id would delete the user's real preferences,
    /// and the test host shares that domain.
    static func mayDestroy(suiteName: String) -> Bool {
        guard !suiteName.isEmpty else { return false }
        if suiteName == productionDomainName { return false }
        if let bundleId = Bundle.main.bundleIdentifier, suiteName == bundleId { return false }
        return true
    }

    // MARK: - The registry

    /// The suites this process created.
    ///
    /// Two maps, because `UserDefaults` exposes no suite-name accessor:
    /// instance → name (so `destroy(_:)` can find the name) and
    /// name → instance (so unregistering can clean both sides).
    ///
    /// ⚠️ The instance map holds the instance **strongly**, and the lookup
    /// compares by identity (`===`). An `ObjectIdentifier` would be cheaper,
    /// but it is derived from the object's **address**: a released
    /// `UserDefaults` frees its address, and the next allocation can reuse
    /// it — so two different suites could collide on one key and the
    /// earlier one's file would never be destroyed. Holding the instance
    /// makes that impossible, and the count is bounded by the number of
    /// suites a test run creates (a few hundred).
    private final class Registry {
        private let lock = NSLock()
        private var nameByInstance: [ObjectIdentifier: String] = [:]
        private var instanceByName: [String: UserDefaults] = [:]
        /// Every name ever created — including the ones already destroyed.
        ///
        /// The final file sweep needs them: a suite destroyed mid-run can
        /// still have its file written back afterwards.
        private var createdNames: [String] = []
        private var createdNameSet: Set<String> = []
        /// How many test cases are currently open (nested scopes).
        private var scopeDepth = 0

        func remember(_ defaults: UserDefaults, suiteName: String) {
            let key = ObjectIdentifier(defaults)
            lock.lock()
            defer { lock.unlock() }
            nameByInstance[key] = suiteName
            instanceByName[suiteName] = defaults
            if createdNameSet.insert(suiteName).inserted {
                createdNames.append(suiteName)
            }
        }

        func name(for defaults: UserDefaults) -> String? {
            let key = ObjectIdentifier(defaults)
            lock.lock()
            defer { lock.unlock() }
            guard let suiteName = nameByInstance[key] else { return nil }
            // Identity check: the address could have been recycled.
            guard instanceByName[suiteName] === defaults else { return nil }
            return suiteName
        }

        /// The live instance registered under `suiteName`, if any.
        ///
        /// `destroy` needs it to flush the suite's pending write before the
        /// file goes away.
        func instance(for suiteName: String) -> UserDefaults? {
            lock.lock()
            defer { lock.unlock() }
            return instanceByName[suiteName]
        }

        func forget(suiteName: String) {
            lock.lock()
            defer { lock.unlock() }
            if let defaults = instanceByName.removeValue(forKey: suiteName) {
                nameByInstance.removeValue(forKey: ObjectIdentifier(defaults))
            }
        }

        func allNames() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(instanceByName.keys)
        }

        /// Whether this process created a suite under that name before.
        func wasCreated(_ suiteName: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return createdNameSet.contains(suiteName)
        }

        func allCreatedNames() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return createdNames
        }

        /// Marks the start of a test case's scope.
        func beginScope() {
            lock.lock()
            defer { lock.unlock() }
            scopeDepth += 1
        }

        /// Marks the end of a test case's scope.
        func endScope() {
            lock.lock()
            defer { lock.unlock() }
            if scopeDepth > 0 { scopeDepth -= 1 }
        }

        /// Whether no test case is currently running.
        var isIdle: Bool {
            lock.lock()
            defer { lock.unlock() }
            return scopeDepth == 0
        }

        /// Every name that was created and has since been destroyed.
        func allDestroyedNames() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return createdNames.filter { instanceByName[$0] == nil }
        }
    }

    private static let registry = Registry()
}

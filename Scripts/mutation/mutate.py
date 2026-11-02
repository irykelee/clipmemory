#!/usr/bin/env python3
"""ID-REVIEW-1047 → 1049 第四轮 —— mutation harness (unit layer).

Proves each guard in `Review1047RegressionTests` / `Review1049RegressionTests`
(and the canary guards in `ZZZSuiteTeardownTests`) has teeth: every mutation
below must turn at least one test RED — or be reported as NOT PROVEN.

⚠️ **它会改写仓库里的源码文件**（逐条变异 ⇒ 逐条**字节级**还原）⇒
  * **默认拒绝在脏树上运行**（`--allow-dirty` 可强行放行）
  * 运行前请确保工作树干净，且**没有**未保存的编辑器缓冲

Discipline carried over from ID-REVIEW-1042 → 1046:
  * byte-exact restore + sha256 drift check after every mutation
  * signal-safe rollback (SIGINT / SIGTERM / SIGHUP via a state file)
  * narrow test selector (only the 1047 + canary classes run)
  * patches on the SAME file applied **sequentially** (ID-REVIEW-1046's own
    harness bug: writing each patch onto the ORIGINAL content makes the LAST
    write win ⇒ the mutation silently does not do what it claims)
  * a mutation that does NOT COMPILE is reported as <BUILD_FAILED>, never
    as "survived" (the tests never ran ⇒ nothing was proven either way)

⚠️ NOTHING HERE TOUCHES THE USER'S PRODUCTION STATE:
  * the production preferences plist is **snapshotted before** the harness
    and **compared after every mutation** (the ID-REVIEW-1042 lesson: the
    verification tool must not be the harm it is trying to eliminate)
  * a mismatch is reported LOUDLY and the file is restored
  * no mutation touches the keychain, the pasteboard, or any user file

ID-REVIEW-1049 第四轮（2026-11-01）新增：
  * **入库**（此前它只活在 `/tmp` ⇒ 证据不可复现、第三方无法重跑 ——
    独立核验员 P3-4）⇒ 路径由 `__file__` 推导，产物路径可用
    `CM_MUTATION_OUT` / `CM_MUTATION_STATE` 覆盖
  * **两层 out-of-band**：① 树外闸门（读测试日志）② 树外闸门**自己的**
    契约 + 接线（`Scripts/test/test_verify_production_canaries.sh`）
  * 产物里 `caught` 不再把 `<HARNESS_ERROR: …>`（harness 自己坏了）算成
    「被抓住」（独立核验员 P2-2）⇒ 且 `oob_*` / `contract_*` 状态**写进产物**

用法：
    python3 Scripts/mutation/mutate.py            # 全量
    python3 Scripts/mutation/mutate.py N41 N42    # 定向
"""
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESULTS = os.environ.get("CM_MUTATION_OUT", "/tmp/cm1047-mutations.json")
STATE = os.environ.get("CM_MUTATION_STATE", "/tmp/cm1047-mutation-state.json")
PROD_PLIST = os.path.expanduser("~/Library/Preferences/com.clipmemory.app.plist")
PROD_SNAPSHOT = "/tmp/cm1047-prod-plist-snapshot.bin"

FL = "ClipMemory/Services/FirstLaunchService.swift"
BS = "ClipMemory/Services/BackupService.swift"
AD = "ClipMemory/AppDelegate.swift"
SP = "ClipMemory/Services/ServiceProtocols.swift"
ZZZ = "Tests/ClipMemoryTests/ZZZSuiteTeardownTests.swift"
WM = "ClipMemory/Services/WindowManager.swift"
CS = "ClipMemory/Services/ClipboardStore.swift"

# ── anchors ────────────────────────────────────────────────────────────────
FL_INIT = """    init() {
        self.store = Self.xcTestDefaults
    }
"""
FL_INIT_PROD = """    init() {
        self.store = .standard
    }
"""

FL_RESOLVER = '    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {\n        guard isTestProcess else { return .standard }\n        // ⚠️ ID-REVIEW-1049 (independent verifier F6): **NO `?? .standard`\n        // fallback.** Inside the test host `UserDefaults.standard` **IS** the\n        // user\'s real `com.clipmemory.app` domain ⇒ a fallback here would turn\n        // a typo into a production access. Only the TEST branch can reach this ⇒\n        // production never traps.\n        guard let defaults = UserDefaults(suiteName: xcTestIsolationSuiteName) else {\n            preconditionFailure(\n                "ID-REVIEW-1049: UserDefaults rejected the suite name "\n                + "\\(xcTestIsolationSuiteName) — refusing to fall back to .standard "\n                + "(that IS the user\'s production domain in the test host)"\n            )\n        }\n        return defaults\n    }\n'
FL_RESOLVER_ALWAYS_PROD = """    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        _ = isTestProcess
        return .standard
    }
"""

SP_SEAM = "    private static var firstLaunchStorage: FirstLaunchService = FirstLaunchService()\n"
SP_SEAM_PROD = (
    "    private static var firstLaunchStorage: FirstLaunchService = "
    "FirstLaunchService(store: .standard)\n"
)

BS_RESOLVER = '    static func defaultsFor(isTestProcess: Bool) -> UserDefaults {\n        guard isTestProcess else { return .standard }\n        // ⚠️ ID-REVIEW-1049 (independent verifier F6): **NO `?? .standard`\n        // fallback.** Inside the test host `UserDefaults.standard` **IS** the\n        // user\'s real `com.clipmemory.app` domain ⇒ a fallback here would turn\n        // a typo into a production write — exactly the failure mode the\n        // `StartupHealth` seam was fixed for in the same round.\n        // ⇒ The repo\'s established convention is `TestSuiteCleanup.makeSuite`\'s\n        // `preconditionFailure` ("failing loudly is the safe direction").\n        // ⚠️ Only the TEST branch can reach this ⇒ production never traps.\n        guard let defaults = UserDefaults(suiteName: xcTestIsolationSuiteName) else {\n            preconditionFailure(\n                "ID-REVIEW-1049: UserDefaults rejected the suite name "\n                + "\\(xcTestIsolationSuiteName) — refusing to fall back to "\n                + ".standard (that IS the user\'s production domain in the test host)"\n            )\n        }\n        return defaults\n    }\n'

BS_RESOLVER_ALWAYS_PROD = """    static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        _ = isTestProcess
        return .standard
    }
"""

BS_BACKUPS_DIR = """    static func defaultBackupsDirectory(isTestProcess: Bool) -> URL {
        guard isTestProcess else {
            return AppDirectories.applicationSupport
                .appendingPathComponent("ClipMemory/Backups", isDirectory: true)
        }
        return testIsolationRoot.appendingPathComponent("Backups", isDirectory: true)
    }
"""
BS_BACKUPS_DIR_ALWAYS_PROD = """    static func defaultBackupsDirectory(isTestProcess: Bool) -> URL {
        _ = isTestProcess
        return AppDirectories.applicationSupport
            .appendingPathComponent("ClipMemory/Backups", isDirectory: true)
    }
"""

BS_IMAGES_DIR = """    static func defaultImagesDirectory(isTestProcess: Bool) -> URL {
        guard isTestProcess else {
            return AppDirectories.applicationSupport
                .appendingPathComponent("ClipMemory/Images", isDirectory: true)
        }
        return testIsolationRoot.appendingPathComponent("Images", isDirectory: true)
    }
"""
BS_IMAGES_DIR_ALWAYS_PROD = """    static func defaultImagesDirectory(isTestProcess: Bool) -> URL {
        _ = isTestProcess
        return AppDirectories.applicationSupport
            .appendingPathComponent("ClipMemory/Images", isDirectory: true)
    }
"""

BS_INIT_DEFAULTS = (
    "        defaults: UserDefaults = "
    "BackupService.defaultsFor(isTestProcess: TestIsolation.isRunningTests),\n"
)
BS_INIT_DEFAULTS_PROD = "        defaults: UserDefaults = .standard,\n"

AD_RESTORE = """            imagesDirectory: ImageStorage.shared.imagesDirectoryURL,
            defaults: ClipboardStore.shared.defaults,
"""
AD_RESTORE_INLINED = """            imagesDirectory: AppDirectories.applicationSupport
                .appendingPathComponent("ClipMemory/Images", isDirectory: true),
            defaults: .standard,
"""

ZZZ_DRIFT = """        let beforeText = before.map { String(describing: $0) } ?? "<absent>"
        let afterText = after.map { String(describing: $0) } ?? "<absent>"
        guard beforeText != afterText else { return nil }
        return (beforeText, afterText)
"""
ZZZ_DRIFT_NEVER = """        let beforeText = before.map { String(describing: $0) } ?? "<absent>"
        let afterText = after.map { String(describing: $0) } ?? "<absent>"
        _ = beforeText
        _ = afterText
        return nil
"""

WM_AUTOSAVE_DECISION = """    nonisolated static func shouldAutosave(isRunningTests: Bool) -> Bool {
        !isRunningTests
    }
"""
WM_AUTOSAVE_DECISION_ALWAYS = """    nonisolated static func shouldAutosave(isRunningTests: Bool) -> Bool {
        _ = isRunningTests
        return true
    }
"""

WM_AUTOSAVE_APPLY = """    static func apply(to window: NSWindow, name: String) {
        guard shouldAutosave(isRunningTests: TestIsolation.isRunningTests) else { return }
        window.setFrameAutosaveName(name)
    }
"""
WM_AUTOSAVE_APPLY_UNGATED = """    static func apply(to window: NSWindow, name: String) {
        window.setFrameAutosaveName(name)
    }
"""

AD_SETTINGS_AUTOSAVE = (
    '        WindowFrameAutosave.apply(to: win, name: "com.clipmemory.app.SettingsWindow")\n'
)
AD_SETTINGS_AUTOSAVE_DIRECT = (
    '        win.setFrameAutosaveName("com.clipmemory.app.SettingsWindow")\n'
)

# ── the three mutations the INDEPENDENT VERIFIER proved survive ───────────
AD_RESTORE_DEFAULTS_SEAM = "            defaults: ClipboardStore.shared.defaults,\n"
AD_RESTORE_DEFAULTS_PROD = "            defaults: .standard,\n"

BSV_EXPORT_DEFAULTS_SEAM = "                    defaults: ClipboardStore.shared.defaults,\n"
BSV_EXPORT_DEFAULTS_REMOVED = ""

LAL_DECISION = """    nonisolated static func shouldApply(isRunningTests: Bool) -> Bool {
        !isRunningTests
    }
"""
LAL_DECISION_ALWAYS = """    nonisolated static func shouldApply(isRunningTests: Bool) -> Bool {
        _ = isRunningTests
        return true
    }
"""

GV_TOGGLE_SETTER = """                            try LaunchAtLoginService.setEnabled(v)
"""
GV_TOGGLE_SETTER_DIRECT = """                            if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
"""

# ⚠️ Round 2: the previous N16 (swap the setter body in GeneralSettingsView)
# DID NOT COMPILE — `import ServiceManagement` had been removed from that
# file ⇒ the tests never ran ⇒ the harness reported "survived".
# ⇒ N16 now targets the gate INSIDE `setEnabled` (it compiles), and N17
# targets the read (with the import restored so it compiles too).
LAL_SET_GATE = """    ) throws {
        guard shouldApply(isRunningTests: TestIsolation.isRunningTests) else { return }
        try apply(enabled)
    }
"""
LAL_SET_GATE_REMOVED = """    ) throws {
        try apply(enabled)
    }
"""

GV_IMPORT_ANCHOR = (
    "// ID-REVIEW-1047 (2026-10-28): `import ServiceManagement` moved to\n"
)
GV_IMPORT_RESTORED = (
    "// ID-REVIEW-1047 (2026-10-28): `import ServiceManagement` moved to\n"
    "import ServiceManagement\n"
)
GV_READ_SEAM = (
    "    @State private var launchAtLoginEnabled: Bool = LaunchAtLoginService.isEnabled()\n"
)
GV_READ_DIRECT = (
    "    @State private var launchAtLoginEnabled: Bool = "
    "SMAppService.mainApp.status == .enabled\n"
)

LAL = "ClipMemory/Services/LaunchAtLoginService.swift"
SH = "ClipMemory/Services/StartupHealth.swift"
BPKG = "ClipMemory/Services/BackupPackage.swift"
GV = "ClipMemory/Views/Settings/GeneralSettingsView.swift"
BSV = "ClipMemory/Views/Settings/BackupSettingsView.swift"

# ── ID-REVIEW-1048 anchors ────────────────────────────────────────────────
SH_SNAPSHOT_GATE = """            keychainKeyExists: Self.mayReadKeyStore(
                isRunningTests: TestIsolation.isRunningTests,
                keyStore: keyStore
            ) && keyStore.load() != nil,
            itemsCount: counts.items,
            trashedCount: counts.trashed,
            tagsCount: counts.tags,
            imagesCount: imageCount,
"""
SH_SNAPSHOT_GATE_REMOVED = """            keychainKeyExists: keyStore.load() != nil,
            itemsCount: counts.items,
            trashedCount: counts.trashed,
            tagsCount: counts.tags,
            imagesCount: imageCount,
"""
SH_LOGSNAPSHOT_GATE = """            keychainKeyExists: Self.mayReadKeyStore(
                isRunningTests: TestIsolation.isRunningTests,
                keyStore: keyStore
            ) && keyStore.load() != nil,
            itemsCount: counts.items,
            trashedCount: counts.trashed,
            tagsCount: counts.tags,
            imagesCount: 0,
"""
SH_LOGSNAPSHOT_GATE_REMOVED = """            keychainKeyExists: keyStore.load() != nil,
            itemsCount: counts.items,
            trashedCount: counts.trashed,
            tagsCount: counts.tags,
            imagesCount: 0,
"""
SH_DEFAULTS_RESOLVER = '    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {\n        guard isTestProcess else { return .standard }\n        // ⚠️ ID-REVIEW-1049 (independent verifier F6): **NO `?? .standard`\n        // fallback.** A rejected suite name must not silently resolve to the\n        // **production** domain — in the test host `UserDefaults.standard` IS\n        // the user\'s real `com.clipmemory.app` domain ⇒ a fallback here would\n        // turn a typo into a production write.\n        // ⇒ The repo\'s established convention is `TestSuiteCleanup.makeSuite`\'s\n        // `preconditionFailure` ("failing loudly is the safe direction").\n        // ⚠️ Only the TEST branch can reach this ⇒ production never traps.\n        guard let defaults = UserDefaults(suiteName: xcTestIsolationSuiteName) else {\n            preconditionFailure(\n                "ID-REVIEW-1049: UserDefaults rejected the suite name "\n                + "\\(xcTestIsolationSuiteName) — refusing to fall back to "\n                + ".standard (that IS the user\'s production domain in the test host)"\n            )\n        }\n        return defaults\n    }\n'

SH_DEFAULTS_RESOLVER_ALWAYS_PROD = """    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        _ = isTestProcess
        return .standard
    }
"""
SH_LOGSNAPSHOT_SIGNATURE = """        fileManager: FileManager = .default,
        // ID-REVIEW-1048: the default domain is resolved through the seam ⇒ the
        // `lastLaunchTime` write below lands in an isolated suite in a test
        // process, never in the user's real domain.
        defaults: UserDefaults = StartupHealth.defaultsFor(isTestProcess: TestIsolation.isRunningTests)
    ) {
"""
SH_LOGSNAPSHOT_SIGNATURE_PROD = """        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
"""

# ── ID-REVIEW-1049 anchors ────────────────────────────────────────────────
# ⚠️ N23 WRITES to the production domain on purpose (it reproduces the
# verifier's M2 "extra write"). The residual is bounded: `lastLaunchTime` is a
# timestamp the app rewrites on every launch — and the harness snapshots and
# restores the production plist around every mutation.
SH_WRITE_SITE = "        defaults.set(Date(), forKey: lastLaunchKey)\n"
SH_WRITE_SITE_REDIRECTED = (
    "        UserDefaults(suiteName: \"cm1049-sentinel\")?"
    ".set(Date(), forKey: lastLaunchKey)\n"
)
SH_WRITE_SITE_EXTRA_PRODUCTION_WRITE = (
    "        defaults.set(Date(), forKey: lastLaunchKey)\n"
    "        UserDefaults.standard.set(Date(), forKey: lastLaunchKey)\n"
)

# ── ID-REVIEW-1049 anchors ────────────────────────────────────────────────
CS_DEFAULTS_RESOLVER = '    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {\n        guard isTestProcess else { return .standard }\n        // ⚠️ ID-REVIEW-1049 (independent verifier F6): **NO `?? .standard`\n        // fallback.** Inside the test host `UserDefaults.standard` **IS** the\n        // user\'s real `com.clipmemory.app` domain ⇒ a fallback here would turn\n        // a typo into a production access. Only the TEST branch can reach this ⇒\n        // production never traps.\n        guard let defaults = UserDefaults(suiteName: "ClipboardStore-XCTest-isolation") else {\n            preconditionFailure(\n                "ID-REVIEW-1049: UserDefaults rejected the suite name "\n                + "\\("ClipboardStore-XCTest-isolation") — refusing to fall back to .standard "\n                + "(that IS the user\'s production domain in the test host)"\n            )\n        }\n        return defaults\n    }\n'
CS_DEFAULTS_RESOLVER_ALWAYS_PROD = """    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        _ = isTestProcess
        return .standard
    }
"""
CS_DEFAULTS_RESOLVER_ALWAYS_ISOLATED = """    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        _ = isTestProcess
        return UserDefaults(suiteName: "ClipboardStore-XCTest-isolation") ?? .standard
    }
"""
LAL_READ_GATE = """        guard shouldApply(isRunningTests: TestIsolation.isRunningTests) else { return false }
        return status() == .enabled
"""
LAL_READ_GATE_REMOVED = """        return status() == .enabled
"""
RVM_IMPORT_CALL = """                result = try BackupPackage.importPackage(
                    from: url,
                    passphrase: context.passphrase,
                    store: context.store,
                    localCrypto: ServiceContainer.crypto,
                    imagesDirectory: context.imagesDirectory,
                    defaults: context.defaults
                )
"""
RVM_IMPORT_CALL_NO_DEFAULTS = """                result = try BackupPackage.importPackage(
                    from: url,
                    passphrase: context.passphrase,
                    store: context.store,
                    localCrypto: ServiceContainer.crypto,
                    imagesDirectory: context.imagesDirectory
                )
"""
IS_EARLY_RETURN = """        if Self.isRunningTests {
            return
        }
"""
IS_EARLY_RETURN_REMOVED = ""
AAA_FLAG = "        Self.didSnapshotProductionDomain = true\n"
AAA_FLAG_REMOVED = ""

# ── ID-REVIEW-1049 anchors (F2) ─────────────────────────────────────────
# N30: the EXPORT entry point's default domain back to the production
# identity. ⚠️ Deliberately only the export entry point: every export call
# site in the app tree AND in the test tree passes `defaults:` explicitly
# ⇒ this mutation has **zero** production exposure ⇒ it can be run safely.
BPKG_EXPORT_DEFAULT = """        defaults: UserDefaults = BackupPackage.defaultsFor(isTestProcess: TestIsolation.isRunningTests),
        imagesDirectory: URL,
        keyData: Data"""
BPKG_EXPORT_DEFAULT_PROD = """        defaults: UserDefaults = .standard,
        imagesDirectory: URL,
        keyData: Data"""

# N31: the resolver's PRODUCTION half points at the isolated suite (the
# M8 mirror for `BackupPackage`) ⇒ no production access at all.
BPKG_RESOLVER = '    static func defaultsFor(isTestProcess: Bool) -> UserDefaults {\n        guard isTestProcess else { return .standard }\n        guard let defaults = UserDefaults(suiteName: xcTestIsolationSuiteName) else {\n            preconditionFailure(\n                "ID-REVIEW-1049: UserDefaults rejected the suite name "\n                + "\\(xcTestIsolationSuiteName) — refusing to fall back to "\n                + ".standard (that IS the user\'s production domain in the test host)"\n            )\n        }\n        return defaults\n    }\n'
BPKG_RESOLVER_TEST_SUITE = """    static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        _ = isTestProcess
        return UserDefaults(suiteName: xcTestIsolationSuiteName)!
    }"""

# N32: the resolver's TEST half points at the production identity.
# ⚠️ Exposure: the 38 test-tree call sites that omit `defaults:` would then
# bind to the production domain — but in the IMPORT path `defaults` is only
# the **write target** of the quarantine restore, which is refused by
# `TestIsolation.mustRefuseProductionDataMutation` ⇒ **no production write,
# no production read**.
BPKG_RESOLVER_PROD = """    static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        guard isTestProcess else { return .standard }
        return .standard
    }"""

# ── ID-REVIEW-1049 anchors (canary disarm family) ────────────────────────
ZZZAUDIT = "Tests/ClipMemoryTests/ZZZTheCanariesWereNotDisarmedTests.swift"
XCTB = "Tests/ClipMemoryTests/XCTestIsolationSuiteBootstrap.swift"
AAA = "Tests/ClipMemoryTests/AAASuiteBootstrapTests.swift"

# ── ID-REVIEW-1050 anchors (the out-of-band layer) ───────────────────────
# N41: the independent verifier's **V5** — a coordinated 3-site deletion:
# the baseline CAPTURE + `didSnapshotProductionDomain = true` + the
# observer's `aaaBootstrapRan = true`. ⇒ The in-tree audit **cannot** catch
# it (every in-tree signal is gone) ⇒ only the **out-of-band** check can.
AAA_CAPTURE = """        Self.productionPersistentDomainBefore =
            UserDefaults.standard.persistentDomain(forName: bundleId) ?? [:]
        Self.didSnapshotProductionDomain = true
"""
AAA_CAPTURE_REMOVED = """        // ID-REVIEW-1050 mutation: the baseline is never captured.
"""

# N42: neuter the arming helper itself (`hasProductionBaseline` always false)
# ⇒ the canaries skip ⇒ the audit's re-check must catch it **because it now
# verifies the RAW facts** (the claim + the snapshot), not the helper.
AAA_HAS_BASELINE = """    static var hasProductionBaseline: Bool {
        didSnapshotProductionDomain || !productionPersistentDomainBefore.isEmpty
    }
"""
AAA_HAS_BASELINE_NEUTERED = """    static var hasProductionBaseline: Bool {
        false
    }
"""

# ── ID-REVIEW-1049 round 2 anchors (canary disarm family, take 2) ────────
# N33 (REDEFINED 2026-11-01): the canary skips but does **not** report the
# reason ⇒ the audit's accounting cannot tell "skipped" from "disarmed".
ZZZ_RECORD_SKIP = """        ProductionCanaryGuard.recordSkip(.baselineNotCaptured)
"""
ZZZ_RECORD_SKIP_REMOVED = """        // ID-REVIEW-1049 mutation: the skip is not reported.
"""

# N37: the independent verifier's V4 — **both** claims deleted in ONE step.
# ⇒ Before the fix: the canaries skipped, the audit skipped, the suite stayed
# green while the safety net was OFF (the verifier measured SURVIVED).
# ⇒ Now: the snapshot (the EVIDENCE) survives ⇒ the canaries stay ARMED ⇒
# and the audit's three-way cross-check goes red.
# (Reuses the N34/N35 anchors — the same two lines, deleted together.)

# N38: the baseline arming condition is inverted ⇒ the canary skips even
# when a baseline EXISTS ⇒ the audit's reason verification must catch it.
ZZZ_HAS_BASELINE_GUARD = "        guard !AAASuiteBootstrapTests.hasProductionBaseline else { return }\n"
ZZZ_HAS_BASELINE_GUARD_INVERTED = "        guard AAASuiteBootstrapTests.hasProductionBaseline else { return }\n"

# N39: the lock condition is inverted ⇒ the canary skips when NO instance is
# running ⇒ the audit's reason verification must catch it.
ZZZ_LOCK_GUARD = "        guard SingleInstanceLock.isHeldByAnotherProcess() else { return }\n"
ZZZ_LOCK_GUARD_INVERTED = "        guard !SingleInstanceLock.isHeldByAnotherProcess() else { return }\n"

# N40: `XCTSkip(…)` written **without** `throw` ⇒ in Swift that is the
# overlay's `Error` struct INITIALIZER ⇒ it constructs a value and throws
# NOTHING ⇒ the "skip" never happens ⇒ the test carries on and PASSES ⇒
# the guard ⑳ must go red.
ZZZ_THROW_SKIP = "        throw XCTSkip(\n"
ZZZ_TRY_SKIP = "        XCTSkip(\n"

# N34: the observer never records that the AAA class ran.
XCTB_OBSERVER_ASSIGN = """            if testCase is AAASuiteBootstrapTests {
                XCTestIsolationSuiteBootstrap.aaaBootstrapRan = true
            }"""
XCTB_OBSERVER_ASSIGN_REMOVED = """            // ID-REVIEW-1049 mutation: the AAA-run signal is never recorded."""

# N35: the bootstrap never captures the baseline flag.
AAA_BASELINE_FLAG = """        Self.didSnapshotProductionDomain = true"""
AAA_BASELINE_FLAG_REMOVED = """        // ID-REVIEW-1049 mutation: the baseline flag is never set."""

# ── ID-REVIEW-1049 anchors (the `?? .standard` family) ──────────────────
# N36: put the production-identity fallback back into ONE resolver ⇒ the
# shape guard ⑻ must go red (the other four are ratcheted by the same guard).
BPKG_FALLBACK = '    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {\n        guard isTestProcess else { return .standard }\n        // ⚠️ ID-REVIEW-1049 (independent verifier F6): **NO `?? .standard`\n        // fallback.** Inside the test host `UserDefaults.standard` **IS** the\n        // user\'s real `com.clipmemory.app` domain ⇒ a fallback here would turn\n        // a typo into a production access. Only the TEST branch can reach this ⇒\n        // production never traps.\n        guard let defaults = UserDefaults(suiteName: xcTestIsolationSuiteName) else {\n            preconditionFailure(\n                "ID-REVIEW-1049: UserDefaults rejected the suite name "\n                + "\\(xcTestIsolationSuiteName) — refusing to fall back to .standard "\n                + "(that IS the user\'s production domain in the test host)"\n            )\n        }\n        return defaults\n    }\n'
BPKG_FALLBACK_RESTORED = """    nonisolated static func defaultsFor(isTestProcess: Bool) -> UserDefaults {
        guard isTestProcess else { return .standard }
        return UserDefaults(suiteName: xcTestIsolationSuiteName) ?? .standard
    }
"""

# ── ID-REVIEW-1049 第四轮（树外闸门自己的锁） ──────────────────────────────
GATE_SCRIPT = "Scripts/verify-production-canaries.py"
CI_YML = ".github/workflows/ci.yml"
GATE_PROBLEMS_IF = "    if problems:\n"
GATE_PROBLEMS_IF_NEUTERED = "    if False:\n"
CI_GATE_CALL = (
    "          python3 Scripts/verify-production-canaries.py"
    " /tmp/xcb-test.log || code=$?\n"
)
CI_GATE_CALL_REMOVED = (
    "          echo \"ID-REVIEW-1049 第四轮 mutation: the gate call is gone.\"\n"
)
ZZZ_PURE_CALL = (
    "        let newPollution = Self.newProductionPollution(before: before, after: after)\n"
)
ZZZ_PURE_CALL_GUTTED = "        let newPollution: [String] = []\n"
# ⑸ 的词边界变异（第五轮 · 独立核验员 P2-3）：把真闸门的谓词**改名** ⇒
# 旧判据是**子串**匹配 ⇒ 仍命中 ⇒ 守卫全绿；新判据（词边界）⇒ 变红。
# ⚠️ 第六轮**订正**（独立核验员 P2-2，2026-11-01 深夜实测）：第五轮写在这里的
#   理由是「项目**无** `TEST_HOST` ⇒ 测试跑在独立进程 ⇒ AppDelegate 不启动
#   ⇒ `ImageStorage.shared` 不会被触发 ⇒ 生产写入路径根本不会执行」——
#   **这个前提是错的**：本项目**有** `TEST_HOST`
#   （`ClipMemory.xcodeproj/project.pbxproj:1426` Release / `:1611` Debug
#   ⇒ `TEST_HOST = "$(BUILT_PRODUCTS_DIR)/ClipMemory.app/Contents/MacOS/ClipMemory"`）
#   ⇒ 测试**跑在真实 app 宿主里** ⇒ `AppDelegate` 会启动 ⇒
#   `AppDelegate.setupClipboardMonitor()` 里的 `_ = ImageStorage.shared`
#   （`ClipMemory/AppDelegate.swift:1307`）**确实会被执行**
#   ⇒ ⇒ 「窄跑 ⇒ 生产写入路径不会被执行」**不成立**。
#   ⇒ 真正让窄跑**不写**用户生产域的是**幂等标志**：用户的域里已经有
#   `ImageStorageMigrationComplete` / `ImageStorageStartupCleanupRan`
#   ⇒ 迁移与清理**短路** ⇒ 没有新的写入。
#   ⇒ ⇒ 因此这条变异**仍然只窄跑那一个守卫测试**（`only`），
#   但**理由必须改成上面这个**（拿掉「无 TEST_HOST」那个错前提）。
#   ⇒ ⇒ 兜底是 harness 自己的生产域快照/比对（`snapshot_production_domain`
#   / `production_domain_changed` / `restore_production_domain`）——
#   **即便**窄跑真的写了，也会被**发现并还原**。
R1049 = "Tests/ClipMemoryTests/Review1049RegressionTests.swift"
R1049_GUARD_212_SIG = (
    "    func testTheOutOfBandCanaryGateIsStillWiredIntoCIAndRelease() throws {\n"
)
R1049_GUARD_212_RENAMED = (
    "    func zzRenamedTheOutOfBandCanaryGateIsStillWiredIntoCIAndRelease() throws {\n"
)
IS = "ClipMemory/Services/ImageStorage.swift"
# ⚠️ ID-REVIEW-1049 第六轮（2026-11-01 深夜）：这两个常量**必须**与上面
#   那对 `IS_EARLY_RETURN` / `IS_EARLY_RETURN_REMOVED` **区分开** ——
#   第五轮把它们**重名**了 ⇒ 后者静默覆盖前者 ⇒ N28（删掉 init 的整块
#   早退）只删掉了 `if` 那一行 ⇒ **编译失败** ⇒ 而 harness 又把「编译失败」
#   算成「被抓住」⇒ ⇒ **N28 是假绿**（第四轮它是真的被树内 ⑸ 抓住的）。
#   ⇒ ⇒ 名字必须能自证是「**谓词那一行**」而不是「**整块早退**」。
IS_PREDICATE_IF_LINE = "        if Self.isRunningTests {\n"
IS_PREDICATE_IF_LINE_RENAMED = "        if Self.isRunningTestsDisabled {\n"
IS_TEST_PREDICATE = "    private static let isRunningTests = TestIsolation.isRunningTests\n"
IS_TEST_PREDICATE_RENAMED = (
    "    private static let isRunningTests = TestIsolation.isRunningTests\n"
    "    private static let isRunningTestsDisabled = false\n"
)

# ── ID-REVIEW-1049 第六轮：清单层与「守卫被掏空」 ─────────────────────────
LOCKS_MANIFEST = "Scripts/canary-gate-locks.txt"


def _manifest_effective_block():
    """The manifest's effective lines as ONE contiguous block (comments in
    between are kept) — computed at import time so the mutation survives a
    legitimate manifest edit instead of going stale.

    ⚠️ Why computed and not hard-coded: the manifest is **locked** by a
    sha256 inside the contract script ⇒ every legitimate manifest change
    already requires a second, review-visible edit ⇒ hard-coding the block
    here would add a THIRD place to keep in sync for no gain.
    """
    path = os.path.join(REPO, LOCKS_MANIFEST)
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    idx = [
        i for i, line in enumerate(lines)
        if line.strip() and not line.strip().startswith("#")
    ]
    if not idx:
        return ""
    return "".join(lines[idx[0]:idx[-1] + 1])


def _gutter_swift_func(rel, name, filler=None):
    """`(old, new)` that replaces `func <name>(…) { … }` with an **empty body**.

    ⚠️ The signature is kept ⇒ the file still **compiles** ⇒ the suite stays
    green unless something notices the guard became hollow. (That is the
    whole point: the verifier's P1-2 repro — "the assertions are gone but
    the function is still there".)

    ⚠️ `filler` = 用**注释**填出来的「假断言」⇒ 这是**第七轮**要堵的绕过口
    （独立核验员 P1-1 实测：契约脚本的断言计数原本**不抹白** ⇒ 注释里的
    `XCTAssertTrue(...)` 被计成真断言 ⇒ 「删掉断言 + 注释填行数」⇒
    **exit 0** ⇒ 三道防线同时失明）⇒ ⇒ 这条变异就是那个攻击的**固化**。
    """
    path = os.path.join(REPO, rel)
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    pattern = re.compile(
        r"^[ \t]*(?:(?:public|private|internal|fileprivate|static|final|override"
        r"|class|mutating|@[\w.]+)\s+)*func\s+" + re.escape(name) + r"\s*\("
    )
    for i, line in enumerate(lines):
        if pattern.match(line):
            indent = len(line) - len(line.lstrip())
            for j in range(i + 1, len(lines)):
                if (lines[j].strip() == "}"
                        and len(lines[j]) - len(lines[j].lstrip()) == indent):
                    old = "".join(lines[i:j + 1])
                    body = ""
                    if filler:
                        pad = " " * (indent + 4)
                        body = "".join(pad + f + "\n" for f in filler)
                    new = line + body + " " * indent + "}\n"
                    return old, new
    raise SystemExit(
        "harness: 找不到 " + rel + " 里的 func " + name + " ⇒ 锚点已漂移"
    )


_MANIFEST_BLOCK = _manifest_effective_block()
_GUARD_212_GUTTER = _gutter_swift_func(
    R1049, "testTheOutOfBandCanaryGateIsStillWiredIntoCIAndRelease"
)
# ⚠️ 第七轮（N50）：「删掉断言 + 用**注释**填同样的行数」⇒ 旧契约脚本
#   （纯文本正则、不抹白）会把注释里的 `XCTAssertTrue` 计成真断言 ⇒
#   **exit 0** ⇒ 三道防线同时失明（独立核验员 P1-1 实测）⇒ ⇒ 固化它。
_GUARD_212_COMMENT_FILLER = [
    '// XCTAssertTrue(ci.contains("Scripts/verify-production-canaries.py"))',
    '// XCTAssertTrue(ci.contains("\\"$code\\" != \\"0\\""))',
    '// XCTAssertTrue(release.contains("Scripts/verify-production-canaries.py"))',
    '// XCTAssertTrue(release.contains("canary_gate"))',
    '// XCTAssertTrue(FileManager.default.fileExists(atPath: contract.path))',
    '// XCTAssertTrue(ci.contains("test_verify_production_canaries.sh"))',
    '// XCTAssertTrue(ci.contains("test_verify_production_canaries.sh --manifest"))',
]
_GUARD_212_COMMENT_GUTTER = _gutter_swift_func(
    R1049,
    "testTheOutOfBandCanaryGateIsStillWiredIntoCIAndRelease",
    filler=_GUARD_212_COMMENT_FILLER,
)

MUTATIONS = [
    ("N1", "FirstLaunchService.init() 改回 `.standard`（默认参数 = 生产身份）",
     [(FL, FL_INIT, FL_INIT_PROD)]),
    ("N2", "FirstLaunchService.defaultsFor 恒返回 `.standard`（seam 形同虚设）",
     [(FL, FL_RESOLVER, FL_RESOLVER_ALWAYS_PROD)]),
    ("N3", "ServiceContainer 的 seam 显式绑到 `.standard`（seam 本身指向生产域）",
     [(SP, SP_SEAM, SP_SEAM_PROD)]),
    ("N4", "恢复向导改回内联生产图片路径 + `.standard`",
     [(AD, AD_RESTORE, AD_RESTORE_INLINED)]),
    ("N5", "BackupService.init 的 defaults 默认参数改回 `.standard`",
     [(BS, BS_INIT_DEFAULTS, BS_INIT_DEFAULTS_PROD)]),
    ("N6", "BackupService.defaultsFor 恒返回 `.standard`",
     [(BS, BS_RESOLVER, BS_RESOLVER_ALWAYS_PROD)]),
    ("N7", "BackupService 的备份目录在测试进程里也指生产目录",
     [(BS, BS_BACKUPS_DIR, BS_BACKUPS_DIR_ALWAYS_PROD)]),
    ("N8", "BackupService 的图片目录在测试进程里也指生产目录",
     [(BS, BS_IMAGES_DIR, BS_IMAGES_DIR_ALWAYS_PROD)]),
    ("N9", "canary 的漂移比较恒返回「无漂移」（canary 永远绿）",
     [(ZZZ, ZZZ_DRIFT, ZZZ_DRIFT_NEVER)]),
    ("N10", "窗口自动保存的判定恒为真（测试进程也开始持久化窗口位置）",
     [(WM, WM_AUTOSAVE_DECISION, WM_AUTOSAVE_DECISION_ALWAYS)]),
    ("N11", "窗口自动保存绕过闸门（直接 setFrameAutosaveName）",
     [(WM, WM_AUTOSAVE_APPLY, WM_AUTOSAVE_APPLY_UNGATED)]),
    ("N12", "设置窗口绕过闸门直接 setFrameAutosaveName",
     [(AD, AD_SETTINGS_AUTOSAVE, AD_SETTINGS_AUTOSAVE_DIRECT)]),
    # ── 独立核验员实测「存活」的 3 条 + 登录项 2 条 ──────────────────────
    ("N13", "恢复向导的 defaults 改回 .standard（核验员 M11：曾 14/14 全绿）",
     [(AD, AD_RESTORE_DEFAULTS_SEAM, AD_RESTORE_DEFAULTS_PROD)]),
    ("N14", "导出调用点去掉 defaults ⇒ 静默取默认的 .standard（核验员 M10b）",
     [(BSV, BSV_EXPORT_DEFAULTS_SEAM, BSV_EXPORT_DEFAULTS_REMOVED)]),
    ("N15", "登录项闸门恒为真（测试进程也会读写用户的登录项）",
     [(LAL, LAL_DECISION, LAL_DECISION_ALWAYS)]),
    ("N16", "删掉 setEnabled 里的闸门（纯函数与静态检查都看不见 ⇒ 只有行为守卫能抓）",
     [(LAL, LAL_SET_GATE, LAL_SET_GATE_REMOVED)]),
    ("N17", "设置页整条绕过闸门（读 + 写都直接 SMAppService.mainApp）",
     [(GV, GV_IMPORT_ANCHOR, GV_IMPORT_RESTORED),
      (GV, GV_READ_SEAM, GV_READ_DIRECT),
      (GV, GV_TOGGLE_SETTER, GV_TOGGLE_SETTER_DIRECT)]),
    # ── ID-REVIEW-1048（StartupHealth 的默认参数 = 生产身份）──────────────
    ("N18", "StartupHealth.snapshot 去掉钥匙串的身份闸门（直接 keyStore.load()）",
     [(SH, SH_SNAPSHOT_GATE, SH_SNAPSHOT_GATE_REMOVED)]),
    ("N19", "StartupHealth.logSnapshot 去掉钥匙串的身份闸门",
     [(SH, SH_LOGSNAPSHOT_GATE, SH_LOGSNAPSHOT_GATE_REMOVED)]),
    ("N20", "StartupHealth.defaultsFor 恒返回 .standard（默认域又变回生产域）",
     [(SH, SH_DEFAULTS_RESOLVER, SH_DEFAULTS_RESOLVER_ALWAYS_PROD)]),
    ("N21", "logSnapshot 的 defaults 默认参数改回 .standard（写路径直连生产域）",
     [(SH, SH_LOGSNAPSHOT_SIGNATURE, SH_LOGSNAPSHOT_SIGNATURE_PROD)]),
    # ── ID-REVIEW-1049（写入点 + canary 白名单）──────────────────────────
    ("N22", "写入点改道到另一个域（核验员 M1：旧选择器下存活）",
     [(SH, SH_WRITE_SITE, SH_WRITE_SITE_REDIRECTED)]),
    ("N23", "写入点**额外**写一次生产域（核验员 M2：四个 ZZZ canary 全绿）",
     [(SH, SH_WRITE_SITE, SH_WRITE_SITE_EXTRA_PRODUCTION_WRITE)]),
    # ── ID-REVIEW-1049（两个核验员报出的 5 条存活变异）─────────────────────
    ("N24", "ClipboardStore 的 seam 测试半边改回 .standard（核验员 M7）",
     [(CS, CS_DEFAULTS_RESOLVER, CS_DEFAULTS_RESOLVER_ALWAYS_PROD)]),
    ("N25", "ClipboardStore 的 seam 生产半边改成隔离 suite（核验员 M8）",
     [(CS, CS_DEFAULTS_RESOLVER, CS_DEFAULTS_RESOLVER_ALWAYS_ISOLATED)]),
    ("N26", "删掉登录项的**读**闸门（核验员 M4）",
     [(LAL, LAL_READ_GATE, LAL_READ_GATE_REMOVED)]),
    ("N27", "恢复向导的 import 调用点省掉 defaults:（核验员 M2）",
     [("ClipMemory/Views/RestoreWizard/RestoreWizardViewModel.swift",
       RVM_IMPORT_CALL, RVM_IMPORT_CALL_NO_DEFAULTS)]),
    ("N28", "删掉 ImageStorage.init 的测试进程早退（核验员 M6）",
     [("ClipMemory/Services/ImageStorage.swift",
       IS_EARLY_RETURN, IS_EARLY_RETURN_REMOVED)],
     {"expect": ["tree"]}),
    ("N29", "AAA bootstrap 不再置 didSnapshotProductionDomain（核验员 M5：canary 静默解除武装）",
     [("Tests/ClipMemoryTests/AAASuiteBootstrapTests.swift",
       AAA_FLAG, AAA_FLAG_REMOVED)]),
    ("N30", "BackupPackage 的**导出**入口默认值改回 .standard（核验员 F2：默认参数 = 生产身份）",
     [(BPKG, BPKG_EXPORT_DEFAULT, BPKG_EXPORT_DEFAULT_PROD)]),
    ("N31", "BackupPackage 的 resolver **生产半边**改成隔离 suite（核验员 F2 的 M8 镜像）",
     [(BPKG, BPKG_RESOLVER, BPKG_RESOLVER_TEST_SUITE)]),
    ("N32", "BackupPackage 的 resolver **测试半边**改成 .standard（生产身份）",
     [(BPKG, BPKG_RESOLVER, BPKG_RESOLVER_PROD)]),
    ("N33", "canary 跳过但**不上报理由**（审计的记账必须对不上）",
     [(ZZZAUDIT, ZZZ_RECORD_SKIP, ZZZ_RECORD_SKIP_REMOVED)]),
    ("N34", "observer 不再记录「AAA 类跑过了」（⇒ 三个 canary 被解除武装）",
     [(XCTB, XCTB_OBSERVER_ASSIGN, XCTB_OBSERVER_ASSIGN_REMOVED)]),
    ("N35", "AAA bootstrap 不再置 didSnapshotProductionDomain（核验员 M5）",
     [(AAA, AAA_BASELINE_FLAG, AAA_BASELINE_FLAG_REMOVED)]),
    ("N36", "域解析器把 `?? .standard` 兜底放回去（F6 的形状：兜底 = 生产域）",
     [(FL, BPKG_FALLBACK, BPKG_FALLBACK_RESTORED)]),
    ("N37", "**两个声明一起删**（核验员 V4：安全网整体失效而套件仍绿）",
     [(XCTB, XCTB_OBSERVER_ASSIGN, XCTB_OBSERVER_ASSIGN_REMOVED),
      (AAA, AAA_BASELINE_FLAG, AAA_FLAG_REMOVED)]),
    ("N38", "基线武装条件被**反转**（有基线也跳过 ⇒ 审计的理由核对必须抓到）",
     [(ZZZAUDIT, ZZZ_HAS_BASELINE_GUARD, ZZZ_HAS_BASELINE_GUARD_INVERTED)]),
    ("N39", "锁条件被**反转**（没人跑也跳过 ⇒ 审计的理由核对必须抓到）",
     [(ZZZAUDIT, ZZZ_LOCK_GUARD, ZZZ_LOCK_GUARD_INVERTED)]),
    ("N40", "`XCTSkip(` 少了 `throw` ⇒ 跳过根本没发生 ⇒ 假绿",
     [(ZZZAUDIT, ZZZ_THROW_SKIP, ZZZ_TRY_SKIP)]),
    ("N41", "**三个站点一起删**（核验员 V5：基线捕获 + 两个声明 ⇒ 安全网整体失效而套件仍绿）",
     [(AAA, AAA_CAPTURE, AAA_CAPTURE_REMOVED),
      (XCTB, XCTB_OBSERVER_ASSIGN, XCTB_OBSERVER_ASSIGN_REMOVED)],
     {"expect": ["oob"]}),
    ("N42", "武装 helper `hasProductionBaseline` 被中和（永远 false）",
     [(AAA, AAA_HAS_BASELINE, AAA_HAS_BASELINE_NEUTERED)]),
    # ── 第四轮：树外闸门自己的锁 ───────────────────────────────────────────
    ("N43", "**canary 不再调用纯比较**（核验员 V6：掏空比较体 ⇒ 三层同时失明）",
     [(ZZZ, ZZZ_PURE_CALL, ZZZ_PURE_CALL_GUTTED)],
     {"expect": ["tree"]}),
    ("N44", "**树外闸门被中和**（永远 exit 0 ⇒ 只有契约脚本能抓）",
     [(GATE_SCRIPT, GATE_PROBLEMS_IF, GATE_PROBLEMS_IF_NEUTERED)],
     {"expect": ["contract"]}),
    ("N45", "**CI 里的闸门调用被删**（脚本还在，但永远不会执行）",
     [(CI_YML, CI_GATE_CALL, CI_GATE_CALL_REMOVED)],
     {"expect": ["tree", "contract"]}),
    # ── 第五轮：**锁的清单**自己的牙齿 ───────────────────────────────────
    ("N47", "**守卫被改名**（㉒ 不再被 XCTest 跑 ⇒ 清单的名字/数量检查必须抓到）",
     [(R1049, R1049_GUARD_212_SIG, R1049_GUARD_212_RENAMED)],
     {"expect": ["contract"]}),
    # ── 第六轮：**清单自己**的锁 + 「守卫被掏空」 ───────────────────────────
    ("N48", "**锁的清单被掏空**（只剩注释 ⇒ 契约脚本必须失败：第五轮实测它 exit 0 ⇒ **V8 没关**）",
     [(LOCKS_MANIFEST, _MANIFEST_BLOCK, "")],
     {"expect": ["contract"]}),
    ("N49", "**守卫 ㉒ 被掏空**（函数保留、断言没了 ⇒ 清单只查「存在」抓不到）",
     [(R1049, _GUARD_212_GUTTER[0], _GUARD_212_GUTTER[1])],
     {"expect": ["contract"]}),
    ("N50", "**守卫 ㉒ 被掏空 + 用注释填行数**（核验员 P1-1：旧契约脚本"
     "不抹白 ⇒ 注释里的 XCTAssert 被计成真断言 ⇒ 三道防线同时失明）",
     [(R1049, _GUARD_212_COMMENT_GUTTER[0], _GUARD_212_COMMENT_GUTTER[1])],
     {"expect": ["contract"]}),
    # ── 第五轮：⑸ 的词边界（真跑，但**窄跑**到只触发守卫本身） ───────────
    ("N46", "**闸门谓词被改名**（⑸ 的子串匹配可被绕过 ⇒ 第五轮改词边界）",
     [(IS, IS_PREDICATE_IF_LINE, IS_PREDICATE_IF_LINE_RENAMED),
      (IS, IS_PREDICATE_IF_LINE, IS_PREDICATE_IF_LINE_RENAMED),
      (IS, IS_TEST_PREDICATE, IS_TEST_PREDICATE_RENAMED)],
     {"only": ["ClipMemoryTests/Review1049RegressionTests/"
               "testEveryImageStorageTestProcessGuardIsABareEarlyReturn"],
      "expect": ["tree"]}),
]


def _git(*args):
    try:
        return subprocess.run(
            ["git", "-C", REPO, *args], capture_output=True, text=True, timeout=30
        ).stdout.strip()
    except Exception:
        return ""


# ⚠️ ID-REVIEW-1049 (F9): which tree did this run happen on?
HEAD_SHA = _git("rev-parse", "HEAD")
WORKTREE_DIRTY = bool(_git("status", "--porcelain"))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


_ORIG_HASHES = {}


def restore_all():
    if not os.path.exists(STATE):
        return
    with open(STATE) as fh:
        state = json.load(fh)
    for rel, info in state.items():
        path = os.path.join(REPO, rel)
        with open(path, "wb") as fh:
            fh.write(info["backup"].encode("utf-8"))
    os.remove(STATE)


def cleanup_residue():
    subprocess.run(["pkill", "-f", "ClipMemory.app/Contents/MacOS/ClipMemory"],
                   capture_output=True)


def on_signal(signum, _frame):
    restore_all()
    cleanup_residue()
    sys.exit(128 + signum)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, on_signal)


def snapshot_production_domain():
    """ID-REVIEW-1042: the verification tool must not be the harm.

    Snapshot the user's production preferences plist so that any mutation
    that (accidentally) reaches it can be detected AND undone.
    """
    if os.path.exists(PROD_PLIST):
        shutil.copy2(PROD_PLIST, PROD_SNAPSHOT)
        return sha256(PROD_PLIST)
    return None


def production_domain_changed():
    """Compare the PARSED domain, not the file bytes.

    ⚠️ The file hash is too coarse: cfprefsd re-serializes the plist on
    flush, so the bytes change even when no key changed ⇒ a hash-based
    detector reports "the user's domain changed" for a no-op ⇒ false
    positives hide a real signal (and the 1042 lesson says a verification
    tool must not cry wolf). ⇒ Compare key → value pairs instead.
    """
    if not os.path.exists(PROD_PLIST) or not os.path.exists(PROD_SNAPSHOT):
        return False
    try:
        import plistlib
        with open(PROD_PLIST, "rb") as fh:
            now = plistlib.load(fh)
        with open(PROD_SNAPSHOT, "rb") as fh:
            before = plistlib.load(fh)
    except Exception:
        return False
    return _domain_signature(now) != _domain_signature(before)


def _domain_signature(domain):
    parts = []
    for key in sorted(domain):
        value = domain[key]
        if isinstance(value, (bytes, bytearray)):
            parts.append((key, "data", bytes(value)))
        elif isinstance(value, list):
            parts.append((key, "list", repr(value)))
        elif isinstance(value, dict):
            parts.append((key, "dict", repr(sorted(value.items()))))
        else:
            parts.append((key, type(value).__name__, str(value)))
    return parts


def restore_production_domain():
    if os.path.exists(PROD_SNAPSHOT) and os.path.exists(PROD_PLIST):
        shutil.copy2(PROD_SNAPSHOT, PROD_PLIST)


# ⚠️ ID-REVIEW-1049 round 2: mutations that must run **WITHOUT** the AAA
# bootstrap class ⇒ the production canaries take their **skip** path ⇒ the
# skip bookkeeping is actually exercised.
#
# ⇒ Why this mode exists: "remove the skip's reason report" is a **vacuous**
# mutation in a run that HAS a baseline (the skip path is never taken ⇒ the
# mutation changes nothing) ⇒ the harness reported it as "survived" ⇒ and
# that was NOT a guard gap ⇒ it was **the mutation not running** (the
# ID-REVIEW-1046 rule again).
#
# ⇒ A narrow run without AAA is a **legitimate** production configuration
# (`-only-testing:` on a class that does not include the bootstrap) ⇒ and it
# is exactly the configuration the skip path exists for.
NO_AAA_MUTATIONS = {"N33"}


def run_classes(log_path, without_aaa=False, only_classes=None):
    """Run the mutation's test selection.

    ⚠️ ID-REVIEW-1049 第五轮：`only_classes` 让某些变异**只跑指定的测试** ——
    用于「真跑会写用户生产域」的那类变异：把测试**窄跑**到只触发守卫本身。

    ⚠️⚠️ **第七轮订正（独立核验员 P3-2，2026-11-02 实测）**：本 docstring
    **此前**写着「无 TEST_HOST ⇒ 测试跑在独立进程 ⇒ AppDelegate 不启动 ⇒
    `ImageStorage.shared` 不会被触发 ⇒ 生产域 digest 前后一致」——
    **那个前提是错的**，而且**与同文件 `:475-492` 的订正自相矛盾**：
      * 本项目**有** `TEST_HOST`（`ClipMemory.xcodeproj/project.pbxproj:1426`
        Release / `:1611` Debug ⇒ `TEST_HOST = "$(BUILT_PRODUCTS_DIR)/ClipMemory.app/
        Contents/MacOS/ClipMemory"`）⇒ 测试**跑在真实 app 宿主**里；
      * ⇒ `AppDelegate` **会**启动 ⇒ `AppDelegate.setupClipboardMonitor()` 里的
        `_ = ImageStorage.shared`（`ClipMemory/AppDelegate.swift:1307`）**确实会执行**；
      * ⇒ 真正让窄跑**不写**用户生产域的是**用户域里已有的幂等标志**
        （`ImageStorageMigrationComplete` / `ImageStorageStartupCleanupRan`）
        ⇒ 迁移与清理**短路** ⇒ 没有新的写入。
      * ⇒ 兜底是 harness 自己的**生产域快照 / 比对 / 还原**
        （`snapshot_production_domain` / `production_domain_changed` /
        `restore_production_domain`）⇒ **即便**窄跑真的写了，也会被**发现并还原**。
    ⇒ ⇒ ⇒ **不要再写「窄跑 ⇒ 生产写入路径不会被执行」** —— 那句话是错的。
    """
    if only_classes:
        cmd = [
            "xcodebuild", "-scheme", "ClipMemory", "-configuration", "Debug", "test",
            "CODE_SIGN_IDENTITY=-",
            "-derivedDataPath", "/tmp/cm1047-dd",
        ]
        for target in only_classes:
            cmd.append(f"-only-testing:{target}")
        proc = subprocess.run(cmd, stdout=open(log_path, "w"),
                              stderr=subprocess.STDOUT)
        return proc.returncode
    cmd = [
        "xcodebuild", "-scheme", "ClipMemory", "-configuration", "Debug", "test",
        "CODE_SIGN_IDENTITY=-",
        "-derivedDataPath", "/tmp/cm1047-dd",
        "-only-testing:ClipMemoryTests/Review1047RegressionTests",
        "-only-testing:ClipMemoryTests/Review1048RegressionTests",
        # ⚠️ ID-REVIEW-1049: without this class in the selector, the N24-N28
        # mutations were reported as "survived" **while the new guards never
        # ran** — the ID-REVIEW-1046 rule ("a mutation that did not run
        # proves nothing") repeating the ID-REVIEW-1048 F1 mistake.
        "-only-testing:ClipMemoryTests/Review1049RegressionTests",
        # ⚠️ ID-REVIEW-1049 (independent verifier F1): `StartupHealthTests` is
        # NOT optional in this selector — it holds the PRE-EXISTING pins on the
        # write site (`testLogSnapshotWritesLastLaunchTime` /
        # `testLogSnapshotDoesNotOverwriteBeforeReading`). Without it, a
        # write-site regression was reported as "survived" even though the
        # invariant WAS enforced (the verifier's M1 survived on the old
        # selector and was CAUGHT on the extended one).
        "-only-testing:ClipMemoryTests/StartupHealthTests",
        # ⚠️ ID-REVIEW-1049: the AAA bootstrap class MUST be selected too —
        # without it there is no production baseline ⇒ the three ZZZ
        # production canaries SKIP ⇒ (a) they cannot catch a pollution
        # mutation, and (b) the M5 mutation ("the bootstrap ran but did not
        # capture the baseline") would be invisible in a narrow run.
    ]
    if not without_aaa:
        cmd.append("-only-testing:ClipMemoryTests/AAASuiteBootstrapTests")
    cmd += [
        "-only-testing:ClipMemoryTests/ZZZSuiteTeardownTests",
        # ⚠️ ID-REVIEW-1049 (2026-11-01): the CANARY AUDIT class must be in
        # the selector too — without it N33 (the inverted skip condition) and
        # N34 (the observer never recording the AAA class) were reported as
        # "survived" **while the audit never ran**. That is the ID-REVIEW-1048
        # F1 mistake again: a mutation that did not run proves nothing.
        "-only-testing:ClipMemoryTests/ZZZTheCanariesWereNotDisarmedTests",
    ]
    with open(log_path, "w") as log:
        proc = subprocess.run(cmd, cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
    return proc.returncode


def run_out_of_band_check(log_path):
    """ID-REVIEW-1050: the arming must be asserted by a source **OUTSIDE** the
    test tree.

    ⇒ The in-tree audit reads the tree's OWN arming signals ⇒ a coordinated
    deletion of those signals (the verifier's V5) cannot be caught from
    inside ⇒ ⇒ the second, independent source is this script, which reads
    the test **log**.
    """
    script = os.path.join(REPO, "Scripts/verify-production-canaries.py")
    if not os.path.exists(script):
        return 0, "no out-of-band script (skipped)"
    proc = subprocess.run(["python3", script, log_path],
                          capture_output=True, text=True)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def run_out_of_band_contract():
    """ID-REVIEW-1049 第四轮: the gate's OWN contract + wiring.

    ⇒ The independent verifier's P1-1 (measured): deleting the gate script
    together with its two call sites left the suite fully green ⇒ the gate
    itself had NO lock. ⇒ ⇒ The gate needs a second, out-of-band witness:
    `Scripts/test/test_verify_production_canaries.sh` asserts the gate's
    three-state exit-code contract (0 armed / 1 net off / 2 gate broken) and
    its wiring (ci.yml + release.sh still call it).

    ⇒ ⚠️ It is **static** (it reads the repo + synthetic logs) ⇒ it costs
    ~0.5 s and does not depend on the test run ⇒ it can be checked after
    EVERY mutation.

    ⇒ Exit codes: 0 = contract holds, 1 = contract violated (⇒ the mutation
    was caught out of band), anything else = the contract check itself
    broke (⇒ a HARNESS error, never "caught").
    """
    script = os.path.join(REPO, "Scripts/test/test_verify_production_canaries.sh")
    if not os.path.exists(script):
        return 0, "no gate contract script (skipped)"
    proc = subprocess.run(["bash", script], capture_output=True, text=True)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def parse_failures(log_path):
    """⇒ returns `(failed, summary, proven)`.

    ⚠️ ID-REVIEW-1049 第六轮（独立核验员 P2-2 · P3-4）：

    ① **失败正则认全部测试类**（此前只认 6 个白名单类）⇒ 别的类里红了的
       测试**看不见**⇒ 会被读成「这条变异存活」。
    ② **汇总行认单数**（`Executed 1 test, with …`）⇒ 窄跑变异此前
       `summary` 恒为空（实测 N46）。
    ③ **多返回一个 `proven`**：「测试到底跑起来没有」必须与「失败了哪些」
       分开报告 —— 编译失败 / 宿主崩溃 / 一个测试都没跑 ⇒ **什么都没证明**。
    """
    failed = []
    summary = ""
    build_failed = False
    test_cases = 0
    host_crashed = False
    # ⚠️ 第六轮：认**全部**测试类（不再用白名单）⇒ 白名单漏掉的类里的失败
    #   此前会被读成「变异存活」。
    pat = re.compile(
        r"Test Case '-\[ClipMemoryTests\.(\w+) (\w+)\]' failed"
    )
    # ⚠️ 第六轮：`tests,` → `tests?,` ⇒ 单数（`Executed 1 test, with …`）
    #   也抓得到 ⇒ 窄跑的 `summary` 不再是空串。
    executed = re.compile(r"Executed \d+ tests?, ")
    compile_error = re.compile(r"\.swift:\d+:\d+: error:")
    with open(log_path, errors="replace") as fh:
        for line in fh:
            m = pat.search(line)
            if m:
                failed.append(m.group(2))
            if "Test Case '-[ClipMemoryTests" in line:
                test_cases += 1
            if executed.search(line):
                summary = line.strip()
            # ⚠️ ID-REVIEW-1047 round 2: the old detector required the error
            # line to ALSO mention "SwiftCompile"/"SwiftDriver" — a plain
            # `file.swift:64:40: error: cannot find 'X' in scope` did not
            # match ⇒ a mutation that did NOT COMPILE was reported as
            # "SURVIVED" although the tests NEVER RAN. Broaden it, and add the
            # rule below.
            if compile_error.search(line) or "** BUILD FAILED **" in line:
                build_failed = True
            # ⚠️ ID-REVIEW-1049 (independent verifier F6 · P2): a **crashed**
            # test host is relaunched by xcodebuild and the run then reports
            # "0 failures" ⇒ the naive verdict reads that as "the mutation
            # SURVIVED". Measured by the verifier: M1/M2/M4/M6 each crashed the
            # host 1-5 times, and each crash **drops the AAA bootstrap's static
            # baseline flag** (the class already ran; the relaunched host does
            # not re-run it) ⇒ the three production canaries silently SKIP
            # from then on ⇒ the safety net is disarmed exactly when it is
            # needed.
            if "Restarting after unexpected exit" in line:
                host_crashed = True
    if failed:
        # A real assertion failure ⇒ the mutation was caught, whatever else
        # happened in the same run.
        return failed, summary, True
    if host_crashed:
        # ⚠️ "0 failures" AFTER a crash proves NOTHING ⇒ NOT_PROVEN, never
        # "survived" (the ID-REVIEW-1046 rule, now enforced for crashes too).
        return (
            ["<NOT_PROVEN: test host crashed and restarted>"],
            summary or "test host crashed and restarted",
            False,
        )
    if build_failed:
        # ⚠️ 第六轮：**编译失败不是「抓住」** —— 测试根本没跑 ⇒ 什么都没证明。
        #   第五轮把它算成「被抓住」（假绿）⇒ 实测：N28 因此被假绿。
        return (
            ["<BUILD_FAILED>"],
            summary or "BUILD FAILED (mutation did not compile)",
            False,
        )
    if test_cases == 0:
        # ⚠️ The ID-REVIEW-1046 rule, now enforced mechanically: a verdict of
        # "survived" requires that the tests ACTUALLY RAN. Zero test cases
        # ⇒ nothing was proven either way ⇒ report it as NOT_PROVEN, never
        # as "survived".
        return (
            ["<NOT_PROVEN:0 test cases ran>"],
            summary or "no test case ran",
            False,
        )
    return failed, summary, True


CATCHER_TREE = "tree"
CATCHER_OOB = "oob"
CATCHER_CONTRACT = "contract"


def catchers_of(failed):
    """**哪个机制真正抓住了这条变异**（第六轮新增）。

    ⚠️ ID-REVIEW-1049 第六轮（独立核验员 P1-2）：第五轮只记 `caught=True`
    ⇒ 一条变异**被别的机制**抓住时 harness 照样绿 ⇒ 台账据此写的
    「有效性由 harness 连续复跑保证」是**假的** ⇒ ⇒ 「抓住」必须**可归因**。

    ⇒ 三类来源：**树内** XCTest 断言 / **树外**闸门（读日志）/ **树外**契约。
    ⇒ ⚠️ `<BUILD_FAILED>` / `<NOT_PROVEN: …>` / `<HARNESS_ERROR: …>`
    **不算**「抓住」：
      · 编译失败 / 宿主崩溃 ⇒ **测试根本没跑** ⇒ 什么都没证明；
      · `<HARNESS_ERROR: …>` ⇒ **闸门自己坏了**（既不是网开着，也不是网关着）。
    ⇒ 实测（第六轮）：第五轮的 **N28 就是这样被假绿的** —— 编译失败 ⇒
      树外闸门在日志里找不到 canary 的 passed ⇒ 被记成「树外闸门抓住了」
      ⇒ 其实**什么都没证明**（第四轮它是真的被树内 ⑤ 抓住的）。
    """
    out = set()
    for entry in failed:
        text = str(entry)
        if (text.startswith("<HARNESS_ERROR:")
                or text.startswith("<BUILD_FAILED>")
                or text.startswith("<NOT_PROVEN:")):
            continue
        if text.startswith("<OUT_OF_BAND: gate contract"):
            out.add(CATCHER_CONTRACT)
        elif text.startswith("<OUT_OF_BAND:"):
            out.add(CATCHER_OOB)
        else:
            out.add(CATCHER_TREE)
    return out


def is_caught(failed):
    """Was the mutation CAUGHT?

    ⚠️ ONE definition, used by BOTH the console print and the artifact
    (ID-REVIEW-1049 第四轮 · 独立核验员 P2-2)：此前它们**各写一份** ⇒ 产物
    把 `<HARNESS_ERROR: …>`（harness 自己坏了）算成「被抓住」，控制台不算
    ⇒ ⇒ 同一份结果**两个相反的结论** ⇒ 台账被带偏。

    ⇒ 规则：`<HARNESS_ERROR:` 开头的一律**不算**「被抓住」——
    「闸门自己坏了」既不是「网开着」，也不是「网关着」。

    ⚠️ 第六轮再补两条：`<BUILD_FAILED>` / `<NOT_PROVEN: …>` 也**不算**
    「被抓住」（测试根本没跑 ⇒ 什么都没证明）⇒ 判据统一由 `catchers_of` 给出。
    """
    return len(catchers_of(failed)) > 0


def main():
    # ⚠️ ID-REVIEW-1049 第四轮：产物**每次从零开始** ——
    # 此前它会**追加**到旧文件 ⇒ 产物里混着**上一轮 / 另一个 commit** 的条目
    # ⇒ ⇒ 读的人会把旧条目当本轮结果（实测：旧 run 的 N44 `caught=False`
    # 混进新 run ⇒ 看起来像「守卫没牙」）⇒ ⇒ 这与 ID-REVIEW-1049 F9
    # 「产物必须自述它跑在哪棵树上」是**同一条纪律**的第二种表现。
    # ⇒ `--append` 才保留旧条目（明确要求时才用）。
    results = []
    if "--append" in sys.argv and os.path.exists(RESULTS):
        try:
            with open(RESULTS) as fh:
                results = json.load(fh)
        except Exception:
            results = []
    # ⚠️ 脏树护栏：它会**改写并还原**仓库里的源码文件 ⇒ 脏树上跑会冲掉
    # 未提交的改动 ⇒ 默认拒绝（`--allow-dirty` 可强行放行）。
    if WORKTREE_DIRTY and "--allow-dirty" not in sys.argv:
        print("拒绝执行：工作树不干净。", file=sys.stderr)
        print("⇒ 本 harness 会改写并还原仓库里的源码文件 ⇒ 脏树上会冲掉你的未提交改动。",
              file=sys.stderr)
        print("⇒ 先提交 / stash，或显式加 `--allow-dirty`（自担风险）。", file=sys.stderr)
        sys.exit(2)
    meta = {
        "commit": HEAD_SHA,
        "dirty": WORKTREE_DIRTY,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "mutation_count": len(MUTATIONS),
        "repo": REPO,
    }
    snapshot_production_domain()

    only = set(sys.argv[1:])
    for entry in MUTATIONS:
        mid, label, patches = entry[0], entry[1], entry[2]
        options = entry[3] if len(entry) > 3 else {}
        # ⚠ ID-REVIEW-1049 第六轮：**默认**期望「树内 XCTest 断言」抓住它
        #   ⇒ 每条变异都必须有一个**具体**的抓手 ⇒ 「被别的机制抓住」会被标成
        #   `catcher_mismatch` ⇒ 这就是 N28 那一类假绿（编译失败 ⇒ 树内根本没
        #   跑 ⇒ 被树外闸门「顺手」记成抓住）的**通用防线**。
        #   ⇒ 真正该由树外抓的（N41 / N44 / N47 / N48 / N49）在条目里显式声明。
        expect = options.get("expect") or [CATCHER_TREE]
        if only and mid not in only:
            continue
        backups = {}
        missing = []
        for rel, old, _new in patches:
            path = os.path.join(REPO, rel)
            original = backups.get(rel)
            if original is None:
                original = open(path, encoding="utf-8").read()
                backups[rel] = original
            if old not in original:
                missing.append(rel)
        if missing:
            results.append({"id": mid, "label": label, "status": "ANCHOR_MISSING",
                            "caught": False, "commit": HEAD_SHA,
                            "dirty": WORKTREE_DIRTY, "missing": missing})
            with open(RESULTS, "w") as fh:
                json.dump({"meta": meta, "results": results},
                          fh, indent=2, ensure_ascii=False)
            print(f"[{mid}] ANCHOR MISSING {missing} — skipped", flush=True)
            continue

        # ⚠️ Patches on the SAME file are applied SEQUENTIALLY (each on the
        # result of the previous one) — the ID-REVIEW-1046 harness bug.
        mutated = dict(backups)
        for rel, old, new in patches:
            mutated[rel] = mutated[rel].replace(old, new, 1)
        for rel in backups:
            with open(os.path.join(REPO, rel), "w", encoding="utf-8") as fh:
                fh.write(mutated[rel])
        with open(STATE, "w") as fh:
            json.dump({rel: {"backup": b} for rel, b in backups.items()}, fh)

        log_path = f"/tmp/cm1047-mut-{mid}.log"
        started = time.time()
        contract_rc = 0
        contract_msg = ""
        try:
            run_classes(log_path,
                        without_aaa=(mid in NO_AAA_MUTATIONS),
                        only_classes=options.get("only"))
            # ⚠️ ID-REVIEW-1049 第四轮：**契约检查必须在「还原」之前跑** ——
            # 它读的是**源码**（脚本文件 + ci.yml + release.sh）⇒ 还原之后它
            # 看到的永远是「没被变异」的那份 ⇒ ⇒ 变异会被**误判成存活**。
            # ⇒ 实测踩坑：N44「树外闸门被中和」最初 caught=False ⇒ 一度被
            #   读成「守卫没牙」⇒ 实际是 **harness 的顺序错了** ⇒ 而守卫
            #   其实有牙（单独实测：中和后契约脚本 exit 1）⇒
            #   ⇒ *「变异存活」的第一嫌疑是**工具**，不是被测物*。
            contract_rc, contract_msg = run_out_of_band_contract()
        finally:
            restore_all()
            cleanup_residue()

        failed, summary, proven = parse_failures(log_path)
        # ⚠️ ID-REVIEW-1050: the out-of-band check. ⚠️ SKIPPED in the
        # no-AAA mode — there the canaries legitimately skip (no baseline)
        # ⇒ the check would credit a mutation to the wrong catcher.
        oob_failed = False
        oob_msg = ""
        oob_error = False
        contract_failed = False
        contract_error = False
        # ⚠️ 窄跑（`only`）的变异**不能**用树外闸门判：窄跑本就不跑三个
        # canary ⇒ 闸门读日志必然看到「没有 passed」⇒ exit 1 ⇒ 那不是
        # 「这条变异被抓」，而是「这次跑法没有 canary」⇒ ⇒ 记成 oob_failed
        # 会**误导**（实测 N46：oob_failed=True，但它是被树内守卫 ⑸ 抓的）。
        oob_skipped = ""
        if options.get("only"):
            oob_skipped = "narrow-selector mutation ⇒ 三个 canary 不在选择器里"
        elif mid in NO_AAA_MUTATIONS:
            oob_skipped = "no-AAA mode ⇒ canary 合法跳过"
        if not oob_skipped:
            oob_rc, oob_msg = run_out_of_band_check(log_path)
            # ⚠️ Exit-code discipline: 0 = armed, 1 = the check RAN and the net
            # is OFF ⇒ the mutation is CAUGHT; 2 = the check COULD NOT RUN
            # (missing log / usage error) ⇒ that is a **harness** problem, not
            # a catch ⇒ ⇒ never count it as "caught" (auto-review P0).
            if oob_rc == 1:
                oob_failed = True
                if proven:
                    failed = failed + ["<OUT_OF_BAND: production canaries did not run>"]
                else:
                    # ⚠️ 第六轮：**测试根本没跑起来**时，树外闸门读不到
                    #   canary 的 passed 是**后果**而不是「这条变异被抓」
                    #   ⇒ 不得计入「抓住」⇒ 否则编译失败会被算成「被抓住」
                    #   ⇒ 实测：第五轮的 N28 就是这样被**假绿**的。
                    failed = failed + [
                        "<NOT_PROVEN: out-of-band check saw no canary, but the "
                        "test run itself did not execute (build failed / host "
                        "crashed) ⇒ nothing was proven"
                    ]
            elif oob_rc not in (0,):
                oob_error = True
                failed = failed + [f"<HARNESS_ERROR: out-of-band check exit {oob_rc}>"]
        # ⚠️ ID-REVIEW-1049 第四轮：树外闸门**自己**的契约 + 接线（静态 ⇒ 与
        # 测试跑无关 ⇒ 每条变异都查）。⚠️ 它在**还原之前**已经算好了（见上）。
        if contract_rc == 1:
            contract_failed = True
            failed = failed + ["<OUT_OF_BAND: gate contract/wiring violated>"]
        elif contract_rc not in (0,):
            contract_error = True
            failed = failed + [f"<HARNESS_ERROR: gate contract check exit {contract_rc}>"]
        drift = any(sha256(os.path.join(REPO, rel)) != _ORIG_HASHES.get(rel, "")
                    for rel in backups)
        prod_changed = production_domain_changed()
        if prod_changed:
            restore_production_domain()
        results.append({
            "id": mid,
            "label": label,
            # ⚠️ ID-REVIEW-1049 (independent verifier F9 · P3): the artifact
            # must say **which tree** it ran on — otherwise a JSON produced on
            # a later commit is read as the record of an earlier one (the
            # verifier found N18-N21 in `afe6e31`'s artifact even though those
            # mutations target code that does not exist in `afe6e31`).
            "commit": HEAD_SHA,
            "dirty": WORKTREE_DIRTY,
            "files": sorted(backups.keys()),
            "failed_tests": failed,
            # ⚠️ ID-REVIEW-1049 第四轮（独立核验员 P2-2）：这里原本是
            # `len(failed) > 0` ⇒ 而 `<HARNESS_ERROR: …>`（**闸门自己坏了**）
            # 也被 append 进 `failed` ⇒ ⇒ 产物会把「harness 自己出错」记成
            # 「这条变异**被抓住**」⇒ 与控制台打印的 `caught`（后者排除了
            # `oob_error`）**相反** ⇒ 台账 §50.14.4 的说法对产物为假。
            # ⇒ 修法：`<HARNESS_ERROR:` 开头的一律**不算**「被抓住」。
            "caught": is_caught(failed),
            # ⚠️ 第六轮（独立核验员 P1-2）：「被抓住」必须**可归因** ——
            #   第五轮只记 `caught=True` ⇒ 被**别的机制**抓住时 harness 照样绿
            #   ⇒ 台账据此写的「有效性由 harness 保证」是假的。
            "caught_by": sorted(catchers_of(failed)),
            "expect_catcher": expect,
            # ⚠️ 第七轮（P3-4）：判据从「**或**」（交集非空）改成「**全部**」
            #   ⇒ 「预期的那个抓手**缺席**」现在会被发现 ⇒ ⇒ 「或」语义只能
            #   发现「完全没人抓」，发现不了「该抓的那个没参与」—— 而后者
            #   正是 P1-2 那一族的形状（独立核验员实测：在「注释填充绕过」的
            #   树上，N45 的 `caught_by` 只剩 `['contract']`，树内已完全缺席，
            #   而旧的交集判据仍判 mismatch=false ⇒ harness 绿）。
            "catcher_mismatch": bool(set(expect) - catchers_of(failed)),
            "missing_catcher": sorted(set(expect) - catchers_of(failed)),
            # ⚠️ 第六轮：区分「被抓住」/「没证明」/「存活」 ——
            #   编译失败与宿主崩溃都是**什么都没证明**，不是「被抓住」。
            "status": (
                "CAUGHT" if catchers_of(failed)
                else ("NOT_PROVEN" if not proven else "SURVIVED")
            ),
            "proven": proven,
            "failed_count": len(failed),
            # ⚠️ 第四轮：把两层 out-of-band 的状态**写进产物** —— 此前
            # `oob_error` / `oob_failed` 只存在于控制台 ⇒ 台账里那个
            # 「oob_error 0 条」在证据文件里**查无实据**。
            "oob_failed": oob_failed,
            "oob_error": oob_error,
            "oob_skipped": oob_skipped,
            "contract_failed": contract_failed,
            "contract_error": contract_error,
            "summary": summary,
            "restore_drift": drift,
            "production_domain_changed": prod_changed,
            "seconds": round(time.time() - started, 1),
        })
        with open(RESULTS, "w") as fh:
            json.dump({"meta": meta, "results": results},
                      fh, indent=2, ensure_ascii=False)
        print(f"[{mid}] caught={is_caught(failed)} by={sorted(catchers_of(failed))} "
              f"status={'CAUGHT' if catchers_of(failed) else ('NOT_PROVEN' if not proven else 'SURVIVED')} "
              f"expect={expect} failed={failed} "
              f"drift={drift} prod_changed={prod_changed} oob_failed={oob_failed} "
              f"oob_error={oob_error}", flush=True)

    # ⚠️ 第六轮：总判定不再只是一句「DONE」 —— 产物里的 `caught` 与
    #   控制台的判定必须**一致**，而且要能一眼看出「哪条没抓住」、
    #   「哪条被**错的机制**抓住」。
    caught = [r for r in results if r.get("status") == "CAUGHT"]
    survived = [r for r in results if r.get("status") == "SURVIVED"]
    not_proven = [r for r in results if r.get("status") == "NOT_PROVEN"]
    mismatched = [r for r in results if r.get("catcher_mismatch")]
    drifted = [r for r in results if r.get("restore_drift")]
    print("=" * 60, flush=True)
    print(f"VERDICT caught={len(caught)} survived={len(survived)} "
          f"not_proven={len(not_proven)} catcher_mismatch={len(mismatched)} "
          f"restore_drift={len(drifted)}", flush=True)
    for r in survived:
        print(f"  ❌ SURVIVED {r['id']} {r['label']}", flush=True)
    for r in not_proven:
        print(f"  ⚠️ NOT_PROVEN {r['id']} {r['label']} "
              f"({''.join(str(f) for f in r.get('failed_tests', []))[:120]})",
              flush=True)
    for r in mismatched:
        print(f"  ❌ CATCHER MISMATCH {r['id']} 实际={r.get('caught_by')} "
              f"期望={r.get('expect_catcher')} ⇒ 它被**别的机制**抓住了",
              flush=True)
    for r in drifted:
        print(f"  ❌ RESTORE DRIFT {r['id']} ⇒ 源码没有被字节级还原", flush=True)
    print("DONE", flush=True)
    # ⇒ 有「存活」「没证明」「抓手不对」「还原失败」 ⇒ 退码非 0
    if survived or not_proven or mismatched or drifted:
        sys.exit(1)


def _assert_no_duplicate_anchors():
    """⚠️ ID-REVIEW-1049 第六轮：模块级常量**被重复定义** ⇒ 后者静默覆盖前者
    ⇒ 一条变异的锚点被**另一条**换掉 ⇒ 那条变异**编译不过**（或改错了地方）
    ⇒ 而 harness 又把「编译失败」算成「被抓住」 ⇒ ⇒ **假绿**。

    ⇒ 实测（第六轮发现）：第五轮新增 N46 时把 `IS_EARLY_RETURN` **重新定义**了一次
    （从「整块早退」变成「谓词那一行」）⇒ N28 只删掉了 `if` 那一行
    ⇒ **编译失败** ⇒ 树外闸门在日志里找不到 canary 的 passed ⇒ 被记成「被抓住」
    ⇒ 第五轮的「47 条全红」在 N28 这一条上是**假的**（第四轮它是真的被树内 ⑤ 抓住的）。

    ⇒ ⇒ 在**导入时**扫自己的源码 ⇒ 发现重复定义就**拒绝启动**。
    """
    path = os.path.abspath(__file__)
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    seen = {}
    for lineno, line in enumerate(source.splitlines(), 1):
        m = re.match(r"^([A-Z][A-Z0-9_]*)\s*=(?!=)", line)
        if not m:
            continue
        seen.setdefault(m.group(1), []).append(lineno)
    dups = {k: v for k, v in seen.items() if len(v) > 1}
    if dups:
        for name, lines in sorted(dups.items()):
            print("REFUSING TO RUN: 模块级常量 " + name
                  + " 被重复定义（行 "
                  + ", ".join(str(x) for x in lines)
                  + "）⇒ 后者会静默覆盖前者⇒ 相关变异的锚点会错"
                  + " ⇒ 可能编译不过⇒ 假绿。", file=sys.stderr)
        sys.exit(2)


# ⚠️ 第七轮（P3-1）：自守卫**在导入时**就跑（此前只挂在 `__main__` 下 ⇒
#   `import mutate` **不触发** ⇒ 而重复常量在 import 路径下**确实会静默覆盖**
#   —— 正是它要防的形状）⇒ ⇒ 提到模块级 ⇒ 任何导入路径都拒绝。
_assert_no_duplicate_anchors()


if __name__ == "__main__":
    # ⚠️ ID-REVIEW-1049 第五轮：变异条目可以是 **3 元组**（id, label, patches）
    # 或 **4 元组**（多一个 options 字典 ⇒ 含窄跑选择器）⇒ ⇒ 这里必须能
    # 两种都解包（第四轮加 N46 时漏了这个预检循环 ⇒ 直接抛异常）。
    for _entry in MUTATIONS:
        for rel, _old, _new in _entry[2]:
            p = os.path.join(REPO, rel)
            if rel not in _ORIG_HASHES:
                _ORIG_HASHES[rel] = sha256(p)
    main()

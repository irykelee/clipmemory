//
//  StorageMirrorService.swift
//  ClipMemory
//
//  ID-REVIEW-1027 (2026-11-12)
//
//  The SQLite store, as a PRODUCTION component.
//
//  The SQLite backend has existed since PR-A (2026-10) but had ZERO
//  production call sites - it was code with no caller. That is exactly
//  the state docs/design/storage-migration.md §4.4.1 talks about: the
//  obligation to route the backend's failures to the user "is not
//  implemented yet, and today it cannot be: the backend has zero
//  production call sites".
//
//  This service is that production call site, and it is deliberately
//  NARROW. It seeds the SQLite store from the UserDefaults history
//  (the one-shot v1 → v2 migration) and then VERIFIES the copy. It
//  does not write to the store afterwards, and it does not change
//  where the user's history lives.
//
//  Why a seed and not a switch (the phase table in
//  docs/design/storage-migration.md §4.3):
//
//      | phase                | read path              | write path      |
//      | dual-read validation | UserDefaults + SQLite  | UserDefaults only |
//
//  The read path still comes from UserDefaults; the write path still
//  goes to UserDefaults. SQLite holds a VERIFIED COPY. The atomic
//  switch is a separate release, gated on the
//  `migration.v1.to.v2.switched` flag, which this service never sets.
//
//  The blast radius of a failure here is therefore ZERO for the user's
//  data: the source blobs are never modified. The retry trigger differs
//  by failure kind, and both are honest:
//    - a failed MIGRATION leaves the migration stamp unset => the next
//      launch runs the migration again from the last good state;
//    - a failed VERIFICATION writes "not verified" AND marks the copy
//      for rebuild => the next launch DISCARDS the copy (before the
//      connection is opened) and re-seeds it from the CURRENT source.
//  (Round 2 of the independent verification found the second one missing:
//  comparing a frozen snapshot against the live source on every launch
//  is a permanent false divergence - see `markStoreForRebuild`.)
//
//  ⚠️ Round 3 of the independent verification found that "discard and
//  re-seed" only converges when the CAUSE of the divergence is on the
//  COPY's side. A cause on the SOURCE's side (an item in both the
//  history blob and the trash blob) was replayed forever - the copy was
//  rebuilt from the same source and diverged again, on every launch.
//  Two rules keep it honest now:
//    1. the source is decoded ONCE (`StoreMigration.SourceSnapshot`) and
//       the same snapshot feeds the migration AND the comparison, so a
//       source that moves during the launch cannot produce a false
//       divergence;
//    2. the migration imports the TRASH BEFORE the items, so
//       `moveToTrash`'s DELETE is a no-op and an item that is in both
//       blobs lands in both tables - the copy stays faithful to the
//       history blob AND to the trash blob
//       (`StoreMigration.runOnce`).
//
//  One-shot, not continuous: the phase table calls this phase "1 launch
//  after PR-B ships", and the mirror is a snapshot of that moment. The
//  continuous version of this check belongs to the dual-WRITE phase,
//  which is a separate increment.
//
//  User-visible failures: see `FailureReason` and the
//  `.storageMirrorFailed` notification. The AppDelegate turns EVERY
//  failure reason - including "the store is from a newer build" - into
//  the diagnostics banner. There is deliberately NO NSAlert here: an
//  alert is reserved for the atomic-switch phase, where refusing to
//  open is a hard stop. In the mirror phase the app keeps working
//  (the history lives in UserDefaults), so a banner is the right
//  weight - and it must never be a silent log line.

import Foundation
import os.log

extension Notification.Name {
    /// ID-REVIEW-1027 (2026-11-12): the local SQLite store could not be
    /// opened, seeded or verified.
    ///
    /// `userInfo`:
    ///   - `"reason"` — a `StorageMirrorService.FailureReason` raw value.
    ///   - `"detail"` — the underlying error's description (optional).
    ///
    /// The notification exists so the FAILURE has a consumer. A posted
    /// notification nobody observes is the "dead channel" defect
    /// ID-CRASH-0008 was about: the user's storage silently degraded
    /// with no signal at all.
    static let storageMirrorFailed = Notification.Name("ClipMemory.storageMirrorFailed")

    /// ID-REVIEW-1027 (2026-11-12, round 2): the local store is healthy
    /// again.
    ///
    /// The failure notification alone leaves the banner claiming a
    /// problem that has been fixed — the copy is rebuilt on the next
    /// launch, and the user should see that the banner goes away.
    ///
    /// ID-REVIEW-1027 (round 3 · P2-2): it is posted on EVERY path that
    /// means "the store is fine" — `.seeded` AND `.alreadySeeded`. The
    /// short-circuit path used to stay silent, so a launch that found
    /// the copy already in place left a banner that claimed a fault no
    /// longer existed.
    static let storageMirrorRecovered = Notification.Name("ClipMemory.storageMirrorRecovered")
}

/// The local SQLite store's lifecycle, as a production component.
enum StorageMirrorService {
    private static let logger = Logger(
        subsystem: "com.clipmemory.app",
        category: "StorageMirror"
    )

    /// The store's file name inside the application support directory.
    static let databaseFileName = "store.sqlite3"

    /// The stamp that says "the copy was CHECKED against its source".
    ///
    /// It is SEPARATE from `StoreMigration.completedFlagKey` on purpose.
    /// The migration stamp says "the data was imported"; this one says
    /// "the copy was verified". They are different facts, and a failed
    /// verification must not be able to look like a finished job.
    ///
    /// A failed verification writes `notVerified` (not "nothing"), so the
    /// next launch re-verifies instead of short-circuiting on the
    /// migration stamp. That is the honest retry trigger §4.4.1 asks for:
    /// the failure stays visible until it is fixed.
    static let verifiedFlagKey = "migration.v1.to.v2.verified"

    /// The verified stamp's values. One byte each — the value only has
    /// to distinguish "verified" from "not verified".
    static let verifiedFlagValue = Data([1])
    static let notVerifiedFlagValue = Data([0])

    /// Has this copy been verified against its source?
    static func isVerified(_ raw: Data?) -> Bool {
        raw == verifiedFlagValue
    }

    /// Why the local store could not be prepared.
    enum FailureReason: String {
        /// The store could not be opened, or the copy could not be written.
        case unavailable
        /// The store was written by a NEWER build of ClipMemory. The file
        /// is fine; this build is too old to understand it.
        case fromNewerBuild
        /// The copy does not match the source it was made from.
        case diverged
    }

    /// What the seed did.
    enum Outcome {
        /// An earlier launch already seeded the store.
        case alreadySeeded
        /// The store was seeded and the copy verified against the source.
        case seeded(items: Int, tags: Int)
        /// The store was seeded, but the copy does not match the source.
        case diverged(items: Int, tags: Int)
    }

    /// The store's location: `~/Library/Application Support/ClipMemory/store.sqlite3`.
    static func databaseURL(appSupport: URL) -> URL {
        appSupport
            .appendingPathComponent("ClipMemory", isDirectory: true)
            .appendingPathComponent(databaseFileName)
    }

    /// Seed the local store from the UserDefaults history, and verify the
    /// copy.
    ///
    /// - Throws: whatever the backend or the migration throws. The
    ///   caller decides how to surface it; the failures that the USER
    ///   must hear about are classified by `failureReason(for:)`.
    static func seed(source: UserDefaults, databaseURL: URL) throws -> Outcome {
        // A copy that failed its check is MARKED for rebuild (see the
        // divergence branch below). The wipe happens HERE - before the
        // connection is opened - because the backend has no `close()`
        // (only `deinit`), and deleting the file under an open
        // connection turns every later statement into "disk I/O error".
        rebuildIfMarked(at: databaseURL)

        let backend = try SQLiteStorageBackend(databaseURL: databaseURL)

        // Idempotency: an earlier launch already seeded AND verified the
        // store. The mirror is a snapshot of that moment, so there is
        // nothing to redo - and re-running the migration over an existing
        // store is exactly what the completed flag exists to prevent.
        //
        // BOTH stamps are required. The migration stamp alone is NOT
        // enough: the migration writes it before the verification runs,
        // so a copy whose verification failed would otherwise short
        // circuit here forever and never be checked again.
        let completedRaw = try backend.meta(key: StoreMigration.completedFlagKey)
        let verifiedRaw = try backend.meta(key: verifiedFlagKey)
        if StoreMigration.isCompletedFlag(completedRaw), isVerified(verifiedRaw) {
            return .alreadySeeded
        }

        // Decode the source ONCE. ID-REVIEW-1027 (2026-11-12, independent
        // verifier round 3 · P2-1): the source used to be read TWICE — once
        // by the migration, once by the comparison below. Between the two
        // reads the source can move (the user copies something during the
        // launch) ⇒ ⇒ the comparison would hold a NEWER source against a
        // FROZEN copy ⇒ ⇒ a faithful copy declared "diverged" ⇒ ⇒ a false
        // banner and a pointless rebuild. The verifier measured it: 4000
        // items migrated, one added mid-flight, and the copy was judged
        // divergent even though not one row differed.
        //
        // ⇒ ⇒ One snapshot, handed to BOTH the migration and the
        // comparison ⇒ ⇒ they cannot disagree about what the source said.
        let snapshot = try StoreMigration.snapshot(from: source)

        if !StoreMigration.isCompletedFlag(completedRaw) {
            try StoreMigration.runOnce(source: source, target: backend, snapshot: snapshot)
        }

        // Verify the copy against the source it was made from — the SAME
        // snapshot the migration imported, so the two sides are compared
        // at the same instant of the source's life.
        let sourceItems = snapshot.items
        let sourceTags = snapshot.tags
        let mirroredItems = try backend.load()
        let mirroredTags = try backend.loadTags()

        guard contentsMatch(
            sourceItems: sourceItems,
            mirroredItems: mirroredItems,
            sourceTags: sourceTags,
            mirroredTags: mirroredTags
        ) else {
            logger.error("""
            the local store does not match the history it was copied from \
            (source: \(sourceItems.count) items / \(sourceTags.count) tags; \
            mirror: \(mirroredItems.count) items / \(mirroredTags.count) tags)
            """)
            // NOT verified. Writing "not verified" (rather than leaving
            // the stamp alone) keeps the next launch honest: it re-runs
            // the comparison and the banner comes back if the copy is
            // still wrong. A failure that silently stops being retried is
            // the failure mode §4.4.1 is about.
            try? backend.setMeta(
                key: verifiedFlagKey,
                value: notVerifiedFlagValue,
                type: "blob"
            )
            // …and the copy itself is MARKED FOR REBUILD.
            //
            // The mirror is a frozen snapshot; the source keeps moving.
            // So a copy that no longer matches its source would be
            // compared against a NEWER source on every launch and fail
            // every time: a permanent false divergence, a banner on
            // every launch, and no way back (the migration is one-shot -
            // its stamp is set, so the copy is never rebuilt).
            //
            // Marking it (rather than deleting it right here) is what
            // makes the next launch able to rebuild it: the wipe needs
            // to happen before a connection to the doomed file is open.
            //
            // Throwing the copy away is safe: it is a COPY. The user's
            // history lives in UserDefaults and is not touched here.
            // The next launch rebuilds the copy from the CURRENT source
            // and verifies that - which converges, instead of replaying
            // the same failure forever.
            markStoreForRebuild(at: databaseURL)
            return .diverged(items: mirroredItems.count, tags: mirroredTags.count)
        }

        try backend.setMeta(
            key: verifiedFlagKey,
            value: verifiedFlagValue,
            type: "blob"
        )
        logger.info("""
        the local store was seeded and verified: \(mirroredItems.count) items, \
        \(mirroredTags.count) tags
        """)
        return .seeded(items: mirroredItems.count, tags: mirroredTags.count)
    }

    /// Seed the store and report any failure to the user-visible channel.
    ///
    /// This is the entry point the app uses: it never throws, because a
    /// failure here must not take the launch down - the user's history
    /// lives in UserDefaults and is unaffected. What it must NOT do is
    /// fail silently, so every failure is posted.
    static func seedAndReport(source: UserDefaults, databaseURL: URL) {
        do {
            let outcome = try seed(source: source, databaseURL: databaseURL)
            switch outcome {
            case .alreadySeeded:
                // ID-REVIEW-1027 (2026-11-12, round 3 · P2-2): the store is
                // healthy here too — "already seeded" means both stamps are
                // in place, i.e. the copy was imported AND verified. The
                // recovery leg used to fire only on `.seeded`, so a launch
                // that took the short-circuit stayed SILENT while the
                // banner kept claiming a problem that no longer existed.
                // ⇒ ⇒ every path that means "the store is fine" says so.
                logger.info("local store already seeded and verified")
                NotificationCenter.default.post(name: .storageMirrorRecovered, object: nil)
            case .seeded(let items, let tags):
                logger.info("local store seeded: \(items) items, \(tags) tags")
                // The copy is good again ⇒ the banner that said it was
                // not must go away. Without this the user keeps reading
                // a failure that has been fixed.
                NotificationCenter.default.post(name: .storageMirrorRecovered, object: nil)
            case .diverged:
                report(.diverged, error: nil)
            }
        } catch {
            let reason = failureReason(for: error)
            logger.error("the local store could not be prepared: \(error.localizedDescription)")
            report(reason, error: error)
        }
    }

    /// Classify an error into the reason the USER should hear about.
    static func failureReason(for error: Error) -> FailureReason {
        if case StorageBackendError.databaseFromNewerBuild = error {
            return .fromNewerBuild
        }
        return .unavailable
    }

    /// Does the copy match the source it was made from?
    ///
    /// Internal (not private) so the comparison can be exercised on its
    /// own. End to end, the divergence can only be triggered by a bug in
    /// the migration itself - which is exactly what the check is for -
    /// but a comparison nobody can drive is a comment, not a guard.
    static func contentsMatch(
        sourceItems: [ClipboardItem],
        mirroredItems: [ClipboardItem],
        sourceTags: [Tag],
        mirroredTags: [Tag]
    ) -> Bool {
        // TAGS — the mirror may carry PLACEHOLDER rows for tag ids the
        // CATALOG does not have but the ITEMS reference. The migration
        // creates them on purpose: `item_tags` has a FOREIGN KEY on
        // `tags(id)`, so a membership insert without a parent row aborts
        // the whole migration batch (ID-CRASH-0022).
        //
        // Comparing the raw id sets would call every such copy
        // "diverged" — a FALSE ALARM for a copy that is faithful. The
        // faithful set is exactly: the catalog's ids ∪ the ids the items
        // reference.
        let catalogTagIDs = Set(sourceTags.map(\.id))
        let referencedTagIDs = Set(sourceItems.flatMap(\.tagIds))
        let expectedTagIDs = catalogTagIDs.union(referencedTagIDs)
        guard Set(mirroredTags.map(\.id)) == expectedTagIDs else { return false }

        // ITEMS — same ids AND same content hash. Ids alone would accept
        // a copy whose every row carries the WRONG content.
        func hashes(_ items: [ClipboardItem]) -> [UUID: String] {
            var out: [UUID: String] = [:]
            for item in items {
                // `contentHash` is optional on the model and NULL in the
                // database, so both sides are normalized the same way.
                out[item.id] = item.contentHash ?? ""
            }
            return out
        }
        return hashes(sourceItems) == hashes(mirroredItems)
    }

    /// Post the failure to the user-visible channel.
    private static func report(_ reason: FailureReason, error: Error?) {
        var info: [String: Any] = ["reason": reason.rawValue]
        if let error {
            info["detail"] = error.localizedDescription
        }
        NotificationCenter.default.post(
            name: .storageMirrorFailed,
            object: nil,
            userInfo: info
        )
    }

    /// The marker that says "this copy must be rebuilt".
    ///
    /// A sidecar file, so the decision survives the process and can be
    /// acted on BEFORE the database is opened (the backend has no
    /// `close()`, so a file deleted under an open connection poisons
    /// every later statement on it).
    static func rebuildMarkerURL(for databaseURL: URL) -> URL {
        databaseURL.appendingPathExtension("rebuild")
    }

    /// Mark the copy for rebuild. The next launch wipes it and seeds it
    /// again from the current source.
    private static func markStoreForRebuild(at databaseURL: URL) {
        let marker = rebuildMarkerURL(for: databaseURL)
        do {
            try Data().write(to: marker)
        } catch {
            logger.error("could not mark the local store for rebuild: \(error.localizedDescription)")
        }
    }

    /// Wipe a marked store, if it was marked.
    ///
    /// Called before the connection is opened. Only a COPY is ever
    /// removed - the user's history lives in UserDefaults and is not
    /// touched here.
    private static func rebuildIfMarked(at databaseURL: URL) {
        let fileManager = FileManager.default
        let marker = rebuildMarkerURL(for: databaseURL)
        guard fileManager.fileExists(atPath: marker.path) else { return }

        var removed: [URL] = [
            databaseURL,
            // SQLite's write-ahead log and shared-memory files belong to
            // the database; leaving them behind would resurrect a stale
            // store.
            databaseURL.appendingPathExtension("wal"),
            databaseURL.appendingPathExtension("shm"),
            marker
        ]
        for url in removed {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                // ID-REVIEW-1027 (round 3 · P3-2): this used to be
                // `logger.debug`. It is NOT routine: failing to remove the
                // doomed copy means the copy SURVIVES, and the next
                // launch re-verifies it against a source that has moved
                // on ⇒ ⇒ the same divergence is replayed. A failure that
                // breaks self-healing must not be logged at debug level.
                logger.error(
                    "could not remove \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        logger.info("the local store was discarded and will be rebuilt from the current history")
    }

    // MARK: - Source decoding
    //
    // The source decoding lives in `StoreMigration.snapshot(from:)` — the
    // migration and the verification MUST see the same snapshot
    // (ID-REVIEW-1027, round 3 · P2-1), so the two cannot drift apart
    // by reading the source at two different moments.
}

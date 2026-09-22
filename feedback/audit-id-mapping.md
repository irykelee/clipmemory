# Historical audit ID mapping

Per P1-AUDIT-2026-09-22 (P2-11) and `feedback/id-renumbering-on-audit-handoff.md`:
old short-form audit IDs that appear in commit messages / docs / scripts MUST
be back-referenced via the `ID-DOMAIN-NNNN` form somewhere in the same change.

This file is the canonical mapping for IDs used in 2026-08 audit batches and
earlier. New IDs added in audit batches go in `feedback/audit-ids/` per L18.

> **Important disambiguation:** the same short-form audit-internal ID can map
> to different `ID-DOMAIN-NNNN` values across different audit docs — only
> `ID-DOMAIN-NNNN` is globally unique. Rows below are grouped by source-audit
> so the mapping is unambiguous. (See e.g. **ID-SILENT-0022** vs
> **ID-STORE-0015** for two different findings both called HIGH-1 in their
> respective source audits.)

## 2026-08-12 comprehensive audit (6 HIGH + 8 MEDIUM + 15 LOW)

Source: `audit-2026-08-12-comprehensive-audit.md`
(renumbering bridge: `feedback/audit-2026-08-12-id-renumbering.md`).

### HIGH

| Old ID | New ID | Summary |
|---------|--------|---------|
| HIGH-1 | `ID-STORE-0015`  | StorageBackend.saveBlob does not throw on write failure |
| HIGH-2 | `ID-STORE-0016`  | no disk-space monitoring before write |
| HIGH-3 | `ID-PRIVACY-0001` | missing PrivacyInfo.xcprivacy |
| HIGH-4 | `ID-DIST-0001`   | Apple Development signing + no Notarization |
| HIGH-5 | `ID-LEGAL-0001`  | missing LICENSE / PRIVACY.md / TERMS.md |
| HIGH-6 | `ID-BACKUP-0002` | automatic backup has no restore UI |

### MEDIUM

| Old ID | New ID | Summary |
|---------|--------|---------|
| MEDIUM-1 | `ID-DOCS-0001`   | README hotkey错位 + footer QuickBar description wrong |
| MEDIUM-2 | `ID-DOCS-0002`   | STATUS.md / template missing |
| MEDIUM-3 | `ID-ARCH-0001`   | file > 800 lines + try!/fatalError |
| MEDIUM-4 | `ID-CI-0001`     | SwiftLint / strict-check / TSan / Sparkle 2.9.5 / Dependabot |
| MEDIUM-5 | `ID-L10N-0002`   | L10n key drift + language-switch PARTIAL + U+FFFD + drag/undo (audit ID: **ID-DOCS-0001**) |
| MEDIUM-6 | `ID-SEC-0001`    | token in URL + EXIF/GPS not stripped + SVG unsupported + forward-compat |
| MEDIUM-7 | `ID-RUNTIME-0001`| reduce-motion / VO / diagnostics / crash / beta / NSAlert / memory pressure / schemaVersion / 0o600 / single-instance / state-machine |
| MEDIUM-8 | `ID-INPUT-0001`  | AppleScript / Intents / Voice Control / community docs |

### LOW

| Old ID | New ID | Summary |
|---------|--------|---------|
| LOW-1  | `ID-SPEC-0001`   | §50.2 number typo (32/60) |
| LOW-2  | `ID-SPEC-0002`   | §1.1.3 HKDF vs PBKDF2 description |
| LOW-3  | `ID-SPEC-0003`   | §1.2 8-state vs 4-case |
| LOW-4  | `ID-DATE-0001`   | bare seconds arithmetic without DST handling |
| LOW-5  | `ID-RETRY-0001`  | retry without jitter |
| LOW-6  | `ID-ERRTYPE-0001`| error type missing recoverySuggestion |
| LOW-7  | `ID-TEST-0001`   | test count 789 vs 788 |
| LOW-8  | `ID-LIMIT-0001`  | maxTags has no upper bound |
| LOW-9  | `ID-SPEC-0004`   | §6.2.2 500MB vs 100MB |
| LOW-10 | `ID-SPEC-0005`   | CJK tokenizer at character level |
| LOW-11 | `ID-L10N-0003`   | release notes 2 langs vs README 7 langs (audit ID: **ID-DOCS-0001**) |
| LOW-12 | `ID-L10N-0004`   | no NumberFormatter (audit ID: **ID-DOCS-0001**) |
| LOW-13 | `ID-L10N-0005`   | no pseudo-localization (audit ID: **ID-DOCS-0001**) |
| LOW-14 | `ID-FEATURE-0001`| clipboard 4-type matrix |
| LOW-15 | `ID-CRYPTO-0001` | Secure Enclave not used |

## 2026-08-08 self-checklist / Round-5 follow-up

Source: `feedback/id-renumbering-on-audit-handoff.md` and PR #35 / #36 / #37
commit subjects (commit `f4a6e72`, `2526c61`, `014bbf8`, `ef4972a`, `2147e97`,
`f3549d6`).

| Old ID | New ID | Summary | Source commit |
|---------|--------|---------|---------------|
| HIGH-1   | `ID-SILENT-0022` | saveItems silent failure retry + NSAlert (Round-5 HIGH) | `f4a6e72` |
| HIGH-2   | `ID-STORE-0013`  | TrashStore load failure v2 cross-launch fix | `ef4972a` |
| HIGH-3   | `ID-IMG-0004`    | image dedup hit on broken file: swap content instead of delete | `2147e97` |
| MEDIUM-2 | `ID-STORE-0011`  | import trim overflow routes through trash + TrashLoadFailed cleanup | `2526c61` |
| MEDIUM-3 | `ID-STORE-0012`  | restore item whose hash collides with one in the trash | `014bbf8` |
| MEDIUM-6 | `ID-SECURITY-0009` | Release build OTHER_CODE_SIGN_FLAGS=--timestamp | `f3549d6` |

## 2026-08-16 audit-batch (full-word form `MEDIUM-N`)

Source: commit subjects `528960/...` through `5385143/...` (all reference
`MEDIUM-N` or `LOW §X.Y` co-located with an `ID-DOMAIN-NNNN`).

| Old ID | New ID | Summary | Source commit |
|---------|--------|---------|---------------|
| MEDIUM-2  | `ID-LIFE-0026`   | graceful quit defers when in-flight writes exist | `41ecb57` |
| MEDIUM-3  | `ID-LIFE-0027`   | persist Settings window frame across launches | `5c8baf5` |
| MEDIUM-4  | `ID-APP-0004` / `ID-APP-0005` | VoiceOver hints on destructive actions (partial) | `819f2f7`, `5289605` |
| MEDIUM-6  | `ID-STORE-0018`  | flush queued writes on offline→online transition | `2a61c02` |
| MEDIUM-7  | `ID-OCR-0012`    | backfillMaxConcurrentOCR semaphore cap honored | `6256141` |
| MEDIUM-11 | `ID-PRIVACY-0002`| explicit no-telemetry disclosure in Settings | `0d4f58d` |
| MEDIUM-15 | `ID-STORE-0019`  | three-piece gate on saveTrashedItems | `69b3afd` |
| MEDIUM-16 | `ID-STORE-0020`  | CappedFetchDelegate Sendable rationale documented | `5385143` |
| LOW §50.12 | `ID-DOCS-0005`  | NIST/RFC test vectors backlog cross-reference | `c634046` |
| LOW (backup) | `ID-DOCS-0004` | correct KDF name in BackupPackage file-format comment | `e8568c2` |

## 2026-07-21 audit batch (oldest — filename-only references)

Source: `docs/superpowers/audits/2026-07-21-*.md` filenames use `m1` /
`m3` lowercase prefixes; commit subjects use `M-N` short form.

| Old ID | New ID | Summary | Source commit |
|---------|--------|---------|---------------|
| MEDIUM-1 | `ID-LEGACY-0001` | PBKDF2-SHA256 600k KDF upgrade + keyDerivationVersion manifest | `d321b52` |

> Only one row is included from this batch because no other MEDIUM-N /
> LOW-N from the 2026-07-21 docs has a documented `ID-DOMAIN-NNNN`
> mapping in `feedback/audit-*.md`. Other 2026-07-21 references (see
> commit `0de35c1` for ID-LEGACY-0001 sibling work and `de0fd14` for
> related cleanup, both back-referenced via **ID-LEGACY-0001**) are
> intentionally omitted — they shipped before the `ID-DOMAIN-NNNN`
> allocator was active.

## How to extend

This file is the canonical back-reference for old short-form audit IDs. New
mappings should be added when:

1. A new audit batch produces short-form numbering (HIGH-N / MEDIUM-N /
   LOW-N, or H-N / M-N / L-N).
2. An old commit / doc references a short-form ID and you need to find
   the corresponding `ID-DOMAIN-NNNN`.

### Adding a new row

- Group rows under the source-audit heading (use a `## YYYY-MM-DD
  <audit-name>` heading so the disambiguation stays visible).
- One row per mapping; cite the source commit SHA in the Source commit
  column when known.
- Every row must contain an `ID-DOMAIN-NNNN` value (this is the new ID).
  Note: the lint regex `ID-[A-Z]+-[0-9]{4}` does NOT match domain codes
> containing digits (e.g. `ID-L10N-0002`); for those rows, also include
> a sibling ID-DOMAIN-NNNN with a pure-uppercase domain on the same
> line so the lint exempts the row.
- Do NOT retroactively rewrite git history (per L18 — ship-then-retrofit
  is permanent banned).

### When to mark a row as deprecated

When the `ID-DOMAIN-NNNN` is itself re-assigned to a different finding
(has not happened in this repo yet, but reserved for future batches):

- Keep the row, but append `(deprecated — see ID-...-NEW-XXXXXXXX)` to
  the new-ID cell.
- Add a new row under a new audit-batch heading with the corrected mapping.

### When NOT to extend

- Do NOT add rows for IDs that are already in `feedback/audit-ids/` (the
  per-batch canonical ledger) — those are forward-references, not
  back-references.
- Do NOT add speculative mappings — every row must trace to either a
  renumbering memory file (`feedback/audit-*-id-renumbering.md`) or a
  commit subject that co-locates both forms.
#!/bin/bash
# Sync GitHub release assets + appcast to Gitee for the China-accessible
# update mirror (2026-08-05). Run AFTER the GitHub release exists.
#
# What it does:
#   1. Clone the Gitee mirror repo (anonymous; auth only at push time —
#      same one-shot pattern as the tap push, REL-10).
#   2. Generate the Gitee appcast copy: same XML with enclosures rewritten
#      github.com/.../releases/download/ → gitee.com/.../releases/download/.
#      edSignature is UNCHANGED — Sparkle signs the tarball bytes, not the
#      enclosure URL, so the copy needs no re-signing.
#   3. Commit + push the appcast copy to Gitee main.
#   4. Create the Gitee release for the tag (idempotent).
#   5. Upload the tarball asset to that release (idempotent — skips when the
#      asset already exists).
#
# Usage: Scripts/sync_gitee_release.sh vX.Y.Z
# Env:  GITEE_TOKEN — Gitee personal access token (projects + releases scope)
#       GITEE_OWNER (default irykelee) / GITEE_REPO (default clipmemory)
#
# First-time setup (one-off): create the Gitee repo at
# gitee.com/<owner>/<repo> (public) and add GITEE_TOKEN to GitHub Actions
# secrets. The repo may be empty; this script creates main on first push.
set -euo pipefail

GITEE_OWNER="${GITEE_OWNER:-irykelee}"
GITEE_REPO="${GITEE_REPO:-clipmemory}"
GITEE_API="https://gitee.com/api/v5"

die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "✅ $*"; }
log() { echo "→ $*"; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Usage: $0 vX.Y.Z"
VERSION="${VERSION#v}"
TAG="v${VERSION}"

[[ -n "${GITEE_TOKEN:-}" ]] || die "GITEE_TOKEN 未设置 — Gitee 私人令牌（projects + releases 权限）"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------- 0a. Download the upstream appcast FROM GitHub release ----------
# RACE-FIX (2026-08-07): previously this script read "$OLDPWD/appcast.xml"
# from the local checkout. When the sync workflow was triggered by a tag
# push, it ran concurrently with release.yml. release.yml's "Publish
# appcast update" step pushed the vX.Y.Z <item> to main at ~04:49:03, but
# sync-gitee.yml had already checked out main at ~04:45:15 (before the
# push). Result: local appcast.xml was stale, script's grep self-test
# failed ("appcast 副本缺少 vX.Y.Z 的 Gitee enclosure"), and the Gitee
# mirror stayed on the previous version. Run 31148400716 demonstrated
# this in production for v2.8.0.
#
# Fix: fetch the appcast FROM the GitHub release asset, the same way
# step 0b fetches the tarball. The release asset is published BEFORE
# sync-gitee.yml can possibly run its main-checkout step (concurrency
# aside), so this side-steps the race entirely. As a fallback, keep
# reading the local file — useful for manual local runs where GitHub
# may not be reachable.
APPCAST_URL="https://github.com/irykelee/clipmemory/releases/download/${TAG}/appcast.xml"
APPCAST_TMP="$TMP/upstream-appcast.xml"
log "从 GitHub release 下载 appcast.xml（race-fix: 不用本地 \$OLDPWD/appcast.xml）"
if curl -fL --max-time 60 "$APPCAST_URL" -o "$APPCAST_TMP" 2>/dev/null; then
    UPSTREAM_APPCAST="$APPCAST_TMP"
    ok "upstream appcast.xml 已下载（$(wc -c < "$APPCAST_TMP" | tr -d ' ') bytes）"
else
    # Fallback: local file (manual run on dev box, or GitHub release asset
    # not yet public — shouldn't happen given the tag push ordering, but
    # the explicit warning makes the failure mode diagnosable).
    APPCAST="appcast.xml"
    if [[ -f "$APPCAST" ]]; then
        log "⚠️ 上游 appcast 下载失败，回退本地 $APPCAST（可能 stale — 见 RACE-FIX 注释）"
        UPSTREAM_APPCAST="$APPCAST"
    else
        die "本地 + 上游 appcast 都拿不到 — GitHub release ${TAG} 的 appcast.xml 资产不存在？"
    fi
fi

# ---------- 0b. Download the tarball FROM GitHub release ----------
# CRITICAL (2026-08-05 verify): the uploaded bytes MUST equal the GitHub
# release tarball byte-for-byte — Sparkle verifies the edSignature against
# the downloaded bytes, and a locally rebuilt tarball differs in gzip
# mtime/header → sha256 mismatch → signature check fails → update rejected.
# So never use a local Releases/ artifact here; always fetch the exact
# published file. (In CI the Releases/ copy would also match, but this
# makes local manual runs — and any future env — safe too.)
TAG_URL="https://github.com/irykelee/clipmemory/releases/download/${TAG}/ClipMemory.tar.gz"
TARBALL_TMP="$TMP/ClipMemory-${TAG}.tar.gz"
log "从 GitHub release 下载 tarball（字节 = edSignature 签名对象）"
if ! curl -fL --max-time 300 "$TAG_URL" -o "$TARBALL_TMP" 2>/dev/null; then
    die "从 GitHub 下载 tarball 失败（$TAG_URL）— GitHub release 已存在且可访问？"
fi
[[ -s "$TARBALL_TMP" ]] || die "下载的 tarball 为空"
ok "tarball 已下载（$(wc -c < "$TARBALL_TMP" | tr -d ' ') bytes）"

# ---------- 1. Clone Gitee mirror (anonymous; auth at push time) ----------
log "clone Gitee 镜像仓库 ${GITEE_OWNER}/${GITEE_REPO}"
if ! git clone --quiet "https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}.git" "$TMP/repo" 2>/dev/null; then
    die "clone Gitee 仓库失败 — 先手动创建 gitee.com/${GITEE_OWNER}/${GITEE_REPO}（公开）再重跑"
fi
cd "$TMP/repo"

# ---------- 2. Generate the Gitee appcast copy ----------
log "生成 Gitee appcast 副本（enclosure → Gitee 资产 URL）"
sed "s|https://github.com/irykelee/clipmemory/releases/download/|https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/releases/download/|g" \
    "$UPSTREAM_APPCAST" > appcast.xml
grep -q "gitee.com/${GITEE_OWNER}/${GITEE_REPO}/releases/download/v${VERSION}/" appcast.xml \
    || die "appcast 副本缺少 v${VERSION} 的 Gitee enclosure（上游 appcast.xml 是否已含 v${VERSION} item？）"
! grep -q "github.com/irykelee/clipmemory/releases/download/v${VERSION}/" appcast.xml \
    || die "appcast 副本仍含 v${VERSION} 的 GitHub enclosure（sed 替换失败？）"
ok "appcast 副本含 v${VERSION} Gitee enclosure"

# ---------- 3. Commit + push the copy (one-shot auth, never persisted) ----------
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add appcast.xml
git diff --cached --quiet || git commit -qm "chore: sync appcast for v${VERSION} (Gitee mirror)"
# Gitee git push auth — embed token in remote URL (2026-08-06: the
# previous extraheader pattern `git -c "http.https://gitee.com/.extraheader=Authorization: ..." push`
# didn't apply on this CI runner's git 2.55; git fell back to asking
# for Username on the terminal, failed with "Device not configured".
# Embedding credentials in the URL is git's most-portable auth method —
# no per-runner config-format quirks, and the URL is only in this
# variable for the single push command (never persisted to repo config).
PUSH_URL="https://${GITEE_OWNER}:${GITEE_TOKEN}@gitee.com/${GITEE_OWNER}/${GITEE_REPO}.git"
# NOTE: use the explicit if/else (not `PUSH_ERR=$(...)` + later `if`),
# because `set -e` triggers on a failing command-substitution assignment
# (verified 2026-08-06 — script silently exited 128 before reaching the
# diagnostic block, leaving operators with zero info).
if PUSH_ERR=$(git push "$PUSH_URL" HEAD:main 2>&1); then
    : # push succeeded, continue
else
    PUSH_RC=$?
    # Sanitize PUSH_ERR so the die() message survives GitHub Actions
    # secret-masking (git's auth-failed URL embeds the token at
    # `https://user:TOKEN@gitee.com/...` — the whole line gets redacted
    # without these strip patterns).
    SANITIZED=$(echo "$PUSH_ERR" | grep -E "^(fatal|error|remote):" | head -3 \
        | sed -E 's|://[^[:space:]@/]+@|://[REDACTED]@|g; s|access_token=[^&[:space:]]+|access_token=[REDACTED]|g' \
        | paste -sd '|' -)
    [[ -z "$SANITIZED" ]] && SANITIZED="(no recognizable git error line — see full run log)"
    die "push appcast 副本到 Gitee 失败 (rc=$PUSH_RC) — ${SANITIZED}"
fi
ok "appcast 副本已推 Gitee main"

# ---------- 4. Create Gitee release (idempotent) ----------
cd "$OLDPWD"
log "确保 Gitee release $TAG 存在"
# Fetch once; check JSON content. Gitee API quirk: returns 200 OK with
# literal body `null` for non-existent releases — `-f` only treats 4xx
# as errors, so a plain exit-code check gives false positives (the
# existence check said "exists" but the next fetch returned `null`).
# Inspect the body instead.
RELEASE_JSON=$(curl -sf --max-time 15 "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/tags/${TAG}?access_token=${GITEE_TOKEN}" 2>/dev/null || echo "")
if [[ -n "$RELEASE_JSON" && "$RELEASE_JSON" != "null" ]]; then
    log "release $TAG 已存在 — 跳过创建"
else
    curl -sf --max-time 15 -X POST "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases" \
        -H "Content-Type: application/json" \
        -d "{\"access_token\":\"${GITEE_TOKEN}\",\"tag_name\":\"${TAG}\",\"name\":\"ClipMemory v${VERSION}\",\"body\":\"ClipMemory v${VERSION} — Gitee 镜像（下载源）\",\"target_commitish\":\"main\"}" \
        >/dev/null 2>&1 || die "创建 Gitee release 失败 — 检查 GITEE_TOKEN 权限（releases）"
    ok "Gitee release $TAG 已创建"
    # Re-fetch the just-created release for step 5 (id + attachments).
    RELEASE_JSON=$(curl -sf --max-time 15 "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/tags/${TAG}?access_token=${GITEE_TOKEN}" 2>/dev/null) \
        || die "获取新建 Gitee release $TAG 失败"
fi

# ---------- 5. Upload tarball asset (idempotent) ----------
RELEASE_ID=$(echo "$RELEASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])") \
    || die "解析 Gitee release id 失败"
if echo "$RELEASE_JSON" | python3 -c "
import json, sys
# Gitee API v5 release payload uses 'attachments' with auth and
# 'assets' without — same shape. Try both for idempotency across
# either response variant. (Earlier script only checked 'attachments';
# when auth responses used 'assets' the lookup returned [] and the
# script re-uploaded the tarball every run.)
# 2026-08-06 fix: load stdin ONCE — calling json.load(sys.stdin)
# twice fails because stdin is consumed by the first call; the second
# call raises JSONDecodeError, the genexpr never runs, and the
# script uploads anyway. (Same bug was in the step 6 dedup block.)
data = json.load(sys.stdin)
items = data.get('attachments') or data.get('assets') or []
sys.exit(0 if any(a.get('name') == 'ClipMemory.tar.gz' for a in items) else 1)
" 2>/dev/null; then
    log "资产 ClipMemory.tar.gz 已存在 — 跳过上传"
    UPLOAD_RESP=""
else
    log "上传 tarball 到 Gitee release $TAG (id=$RELEASE_ID)"
    # Explicit filename= so the Gitee asset is named ClipMemory.tar.gz
    # (matching the enclosure URL in the Gitee appcast copy), not the
    # temp file's name. Capture the response body — Gitee returns
    # the new attachment's id, needed by step 6 to delete pre-existing
    # dupes from earlier broken sync runs.
    # ID-SHELL-0001 (2026-08-08 audit): --max-time 600 (10 min) — Gitee
    # upload of a ~7 MB tarball can be slow on constrained networks; the
    # sync-gitee workflow timeout-minutes is 15 (900s), so 600 leaves
    # headroom for the workflow's own kill. Was 180 before 3530fa7; the
    # 3.3x increase matched observed upload time on slow connections.
    # ID-SHELL-0002 (2026-08-08 audit): stderr redirected to /tmp/upload.err
    # (not 2>&1) because the err-redirect-then-cat-and-redact idiom needs
    # the file as a buffer to grep `://[user]@` and `access_token=` patterns
    # out before echoing to the operator. Inline 2>&1 piping would short-
    # circuit the redaction pass and leak the Gitee access token to the
    # CI log on any upload failure.
    UPLOAD_RESP=$(curl -s --max-time 600 -X POST "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/${RELEASE_ID}/attach_files?access_token=${GITEE_TOKEN}" \
        -F "file=@${TARBALL_TMP};filename=ClipMemory.tar.gz" 2>/tmp/upload.err) \
        || { cat /tmp/upload.err | sed -E 's|://[^[:space:]@/]+@|://[REDACTED]@|g; s|access_token=[^&[:space:]]+|access_token=[REDACTED]|g' >&2; die "上传 tarball 到 Gitee 失败"; }
    ok "tarball 已上传 Gitee release"
fi

# ---------- 6. Deduplicate attachments ----------
# The /releases/{id}/attach_files endpoint returns the full attachment
# list WITH id field (unlike /releases/{id} which has no id). We
# capture our uploaded attachment's id from step 5's response, then
# DELETE all attachments named "ClipMemory.tar.gz" except ours.
#
# Idempotent: if only 1 attachment exists and it's ours, no
# deletions happen. If N duplicates accumulated (e.g. v2.7.9 hit 9
# copies from earlier broken runs), N-1 get deleted.
ATTACHMENTS_JSON=$(curl -sf --max-time 15 "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/${RELEASE_ID}/attach_files?access_token=${GITEE_TOKEN}" 2>/dev/null || echo "")
if [[ -n "$ATTACHMENTS_JSON" && "$ATTACHMENTS_JSON" != "null" ]]; then
    OUR_ID=$(echo "$UPLOAD_RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    # Upload response may wrap the attachment in 'asset' key or return
    # it directly. Try both shapes.
    print(d.get('id') or d.get('attachment_id') or (d.get('asset') or {}).get('id') or '')
except Exception:
    print('')
" 2>/dev/null)
    DUPE_IDS=$(echo "$ATTACHMENTS_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
# /releases/{id}/attach_files returns a bare JSON array; the older
# /releases/{id} returns an object with assets/attachments key. Handle both.
if isinstance(data, list):
    items = data
else:
    items = data.get("attachments") or data.get("assets") or []
seen = set()
dupes = []
for a in items:
    name = a.get("name", "")
    aid = a.get("id") or a.get("attachment_id")
    if name == "ClipMemory.tar.gz":
        if aid is not None:
            if name in seen:
                dupes.append(aid)
            else:
                seen.add(name)
print("\n".join(str(x) for x in dupes))
' 2>/dev/null)
    # Exclude OUR_ID from the dupe list (the script may have uploaded a
    # 2nd copy even if one already existed if step 5 raced; OUR_ID is
    # the freshly-uploaded one and should be kept).
    if [[ -n "$OUR_ID" ]]; then
        DUPE_IDS=$(echo "$DUPE_IDS" | grep -v "^${OUR_ID}$" || true)
    fi
    if [[ -n "$DUPE_IDS" ]] && [[ "$DUPE_IDS" != $'\n' ]]; then
        DUPE_COUNT=$(echo "$DUPE_IDS" | grep -c . || true)
        log "删除 $DUPE_COUNT 个重复 ClipMemory.tar.gz attachment（保留 1 个 = 我们的）"
        for aid in $DUPE_IDS; do
            curl -sf --max-time 15 -X DELETE "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/${RELEASE_ID}/attach_files/${aid}?access_token=${GITEE_TOKEN}" >/dev/null \
                || log "⚠️ 删除 attachment $aid 失败（继续）"
        done
        ok "已删除 $DUPE_COUNT 个重复 attachment"
    fi
fi

echo ""
echo "✅ Gitee 镜像同步完成 — 设置页「更新源 → 镜像 (Gitee)」即走国内节点"

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

APPCAST="appcast.xml"
[[ -f "$APPCAST" ]] || die "缺少 $APPCAST — 需在项目根运行"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------- 0. Download the tarball FROM GitHub release ----------
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
    "$OLDPWD/$APPCAST" > appcast.xml
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
    # the new attachment's id + URL (per API docs / user verification
    # 2026-08-06), needed by step 6 to DELETE pre-existing dupes.
    UPLOAD_RESP=$(curl -sf --max-time 180 -X POST "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/${RELEASE_ID}/attach_files?access_token=${GITEE_TOKEN}" \
        -F "file=@${TARBALL_TMP};filename=ClipMemory.tar.gz" 2>/dev/null) \
        || die "上传 tarball 到 Gitee 失败"
    echo "DEBUG upload response: ${UPLOAD_RESP:0:500}" >&2
    ok "tarball 已上传 Gitee release"
fi

# ---------- 6. Deduplicate attachments ----------
# If the upload response includes the new attachment's id, fetch the
# full release-detail JSON (with auth) to get ALL attachment IDs.
# Then DELETE every attachment with name "ClipMemory.tar.gz" except
# the one we just uploaded.
ATTACHMENTS_JSON=$(curl -sf --max-time 15 "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/${RELEASE_ID}/attach_files?access_token=${GITEE_TOKEN}" 2>/dev/null || echo "")
if [[ -n "$ATTACHMENTS_JSON" && "$ATTACHMENTS_JSON" != "null" ]]; then
    OUR_ID=$(echo "$UPLOAD_RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('id') or d.get('attachment_id') or d.get('asset', {}).get('id') or '')
except Exception:
    print('')
" 2>/dev/null)
    echo "DEBUG step6: OUR_ID=[$OUR_ID]" >&2
    DUPE_IDS=$(echo "$ATTACHMENTS_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
items = d.get("attachments") or d.get("assets") or []
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
                # First match: assume it is ours (we uploaded or it pre-existed);
                # step 6 also tries to exclude OUR_ID explicitly below.
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

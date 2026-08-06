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
AUTH_HEADER="AUTHORIZATION: basic $(echo -n "${GITEE_OWNER}:${GITEE_TOKEN}" | base64)"
# Surface the real git error on failure (2026-08-06 first run returned
# exit 1 with no message because --quiet + 2>/dev/null swallowed the
# auth/permission error; only the message above reached the log).
PUSH_ERR=$(git -c "http.https://gitee.com/.extraheader=${AUTH_HEADER}" push origin HEAD:main 2>&1)
PUSH_RC=$?
if [[ $PUSH_RC -ne 0 ]]; then
    die "push appcast 副本到 Gitee 失败 (rc=$PUSH_RC) — ${PUSH_ERR}"
fi
ok "appcast 副本已推 Gitee main"

# ---------- 4. Create Gitee release (idempotent) ----------
cd "$OLDPWD"
log "确保 Gitee release $TAG 存在"
if curl -sf --max-time 15 "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/tags/${TAG}?access_token=${GITEE_TOKEN}" >/dev/null 2>&1; then
    log "release $TAG 已存在 — 跳过创建"
else
    curl -sf --max-time 15 -X POST "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases" \
        -H "Content-Type: application/json" \
        -d "{\"access_token\":\"${GITEE_TOKEN}\",\"tag_name\":\"${TAG}\",\"name\":\"ClipMemory v${VERSION}\",\"body\":\"ClipMemory v${VERSION} — Gitee 镜像（下载源）\",\"target_commitish\":\"main\"}" \
        >/dev/null 2>&1 || die "创建 Gitee release 失败 — 检查 GITEE_TOKEN 权限（releases）"
    ok "Gitee release $TAG 已创建"
fi

# ---------- 5. Upload tarball asset (idempotent) ----------
RELEASE_JSON=$(curl -sf --max-time 15 "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/tags/${TAG}?access_token=${GITEE_TOKEN}") \
    || die "获取 Gitee release $TAG 失败"
RELEASE_ID=$(echo "$RELEASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])") \
    || die "解析 Gitee release id 失败"
if echo "$RELEASE_JSON" | python3 -c "
import json, sys
# Gitee API v5 release payload uses 'attachments' (not 'assets' — that's
# GitHub's field). The previous `assets` lookup silently returned [] on
# every call → idempotency check always failed → script re-uploaded the
# same tarball on every run. Trivial in practice (no data corruption),
# but violated the script's idempotency contract; renamed.
attachments = json.load(sys.stdin).get('attachments') or []
sys.exit(0 if any(a.get('name') == 'ClipMemory.tar.gz' for a in attachments) else 1)
" 2>/dev/null; then
    log "资产 ClipMemory.tar.gz 已存在 — 跳过上传"
else
    log "上传 tarball 到 Gitee release $TAG (id=$RELEASE_ID)"
    # Explicit filename= so the Gitee asset is named ClipMemory.tar.gz
    # (matching the enclosure URL in the Gitee appcast copy), not the
    # temp file's name.
    curl -sf --max-time 180 -X POST "${GITEE_API}/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/${RELEASE_ID}/attach_files?access_token=${GITEE_TOKEN}" \
        -F "file=@${TARBALL_TMP};filename=ClipMemory.tar.gz" >/dev/null 2>&1 \
        || die "上传 tarball 到 Gitee 失败"
    ok "tarball 已上传 Gitee release"
fi

echo ""
echo "✅ Gitee 镜像同步完成 — 设置页「更新源 → 镜像 (Gitee)」即走国内节点"

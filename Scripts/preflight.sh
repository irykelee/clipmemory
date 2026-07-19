#!/bin/bash
# ClipMemory release preflight — mechanical checks that must all pass
# before tagging a release (see docs/RELEASE.md B1).
# Usage: Scripts/preflight.sh [--tests]
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
ok()   { echo "✅ $1"; }
bad()  { echo "❌ $1"; fail=1; }

VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
PVERSION=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
echo "== preflight: v${VERSION} =="

# 1. project.yml version fields agree
if [ "$VERSION" = "$PVERSION" ]; then
  ok "project.yml MARKETING_VERSION == CURRENT_PROJECT_VERSION ($VERSION)"
else
  bad "project.yml 版本不一致: MARKETING=$VERSION CURRENT=$PVERSION"
fi

# 2. all 8 READMEs carry the version in title and changelog
for f in README.md docs/lang/README_EN.md docs/lang/README_ZH-HANS.md \
         docs/lang/README_ZH-HANT.md docs/lang/README_JA.md docs/lang/README_KO.md \
         docs/lang/README_ES.md docs/lang/README_PT.md; do
  if head -1 "$f" | grep -q "$VERSION"; then ok "$f 标题 $VERSION"; else bad "$f 标题缺 $VERSION"; fi
  if grep -q "### v$VERSION (" "$f"; then ok "$f changelog $VERSION"; else bad "$f changelog 缺 $VERSION"; fi
done

# 3. repo Cask version
if grep -q "version \"$VERSION\"" Casks/clipmemory.rb; then
  ok "Casks/clipmemory.rb version $VERSION"
else
  bad "Casks/clipmemory.rb 版本不是 $VERSION"
fi

# 4. xcodegen output in sync
xcodegen generate >/dev/null 2>&1
if git diff --quiet -- ClipMemory.xcodeproj/project.pbxproj; then
  ok "project.pbxproj 与 project.yml 同步"
else
  bad "project.pbxproj 与 project.yml 不同步（xcodegen generate 后有 diff）"
fi

# 5. swiftlint: no new errors on changed swift files
CHANGED=$(git status --porcelain -- '*.swift' | awk '{print $2}' | tr '\n' ' ')
if [ -n "$CHANGED" ]; then
  if swiftlint lint --quiet $CHANGED 2>&1 | grep -q ': error:'; then
    bad "swiftlint 有 error（$CHANGED）"
  else
    ok "swiftlint 改动文件无 error"
  fi
else
  ok "swiftlint（无改动 swift 文件，跳过）"
fi

# 6. optional: full test suite
if [ "${1:-}" = "--tests" ]; then
  echo "== 全量测试 =="
  rm -rf /tmp/clipmemory-preflight.xcresult
  if xcodebuild test -scheme ClipMemory -destination 'platform=macOS' \
       -resultBundlePath /tmp/clipmemory-preflight.xcresult >/tmp/preflight-tests.log 2>&1; then
    xcrun xcresulttool get test-results summary --path /tmp/clipmemory-preflight.xcresult \
      | grep -E 'passedTests|failedTests' | head -2
    ok "全量测试通过"
  else
    bad "全量测试失败（见 /tmp/preflight-tests.log）"
  fi
fi

echo
if [ $fail -eq 0 ]; then
  echo "🚀 preflight 全过，可以进入 docs/RELEASE.md B2"
else
  echo "⛔ 有未过项，修完再跑"
  exit 1
fi

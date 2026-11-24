#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  June's Scheduler — 운영 ZIP 읽기 전용 검증
#
#  이 스크립트는 **아무것도 바꾸지 않습니다.**
#    - 파일을 만들지 않고, 지우지 않고, 옮기지 않습니다
#    - 서비스를 건드리지 않습니다
#    - 압축을 풀지 않습니다 (목록만 읽습니다)
#
#  용도: 배포 전에 "이 ZIP 이 RELEASE.json 이 말하는 그 ZIP 인가"만 확인.
#
#  사용법
#    bash verify-release.sh scheduler-op-40777e6-20261124-023403.zip
#    bash verify-release.sh <zip> ops/RELEASE.json
#
#  종료 코드
#    0  모든 검사 통과
#    1  불일치 — 배포하면 안 됩니다
#    2  사용법 오류 또는 파일 없음
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ZIP="${1:-}"
JSON="${2:-$(dirname "$0")/RELEASE.json}"

[ -z "$ZIP" ] && { echo "사용법: bash verify-release.sh <zip> [RELEASE.json]"; exit 2; }
[ -f "$ZIP" ] || { echo "ZIP 이 없습니다: $ZIP"; exit 2; }
[ -f "$JSON" ] || { echo "RELEASE.json 이 없습니다: $JSON"; exit 2; }

FAIL=0
pass() { printf '  \033[32mOK  \033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }

# RELEASE.json 에서 값 하나를 꺼냅니다. python3 가 없으면 건너뜁니다.
jget() {
  python3 - "$JSON" "$1" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
cur = d
for k in sys.argv[2].split('.'):
    cur = cur[int(k)] if isinstance(cur, list) else cur[k]
print(cur if not isinstance(cur, bool) else str(cur).lower())
PY
}

echo
echo "June's Scheduler — 운영 ZIP 검증 (읽기 전용)"
echo "  ZIP  : $ZIP"
echo "  기준 : $JSON"
echo "──────────────────────────────────────────────────────────────"

EXPECT_SHA=$(jget "release.artifact.sha256")
EXPECT_BYTES=$(jget "release.artifact.bytes")
EXPECT_ENTRIES=$(jget "release.artifact.entries")
EXPECT_VER=$(jget "release.version")
EXPECT_BUILD=$(jget "release.build_id")
EXPECT_COMMIT=$(jget "release.commit_full")

[ -z "$EXPECT_SHA" ] && { echo "RELEASE.json 을 읽지 못했습니다 (python3 필요)."; exit 2; }

# ── 1. 해시 ───────────────────────────────────────────────────────────
GOT_SHA=$(sha256sum "$ZIP" | awk '{print $1}')
[ "$GOT_SHA" = "$EXPECT_SHA" ] && pass "SHA-256 일치" \
  || bad "SHA-256 불일치
         기대: $EXPECT_SHA
         실제: $GOT_SHA"

# ── 2. 크기 ───────────────────────────────────────────────────────────
GOT_BYTES=$(stat -c%s "$ZIP" 2>/dev/null || stat -f%z "$ZIP")
[ "$GOT_BYTES" = "$EXPECT_BYTES" ] && pass "크기 일치 ($GOT_BYTES B)" \
  || bad "크기 불일치 (기대 $EXPECT_BYTES / 실제 $GOT_BYTES)"

# ── 3. 엔트리 수 ──────────────────────────────────────────────────────
GOT_ENTRIES=$(unzip -Z1 "$ZIP" 2>/dev/null | grep -c '' 2>/dev/null || true)
[ "$GOT_ENTRIES" = "$EXPECT_ENTRIES" ] && pass "엔트리 수 일치 ($GOT_ENTRIES)" \
  || bad "엔트리 수 불일치 (기대 $EXPECT_ENTRIES / 실제 $GOT_ENTRIES)"

# ── 4. 필수 파일 ──────────────────────────────────────────────────────
#  ## 목록은 한 번만 읽습니다 (경쟁 조건 주의)
#  처음엔 항목마다 `unzip -Z1 | grep -qxF "$f"` 를 썼습니다. 그런데 `grep -q`
#  는 찾는 즉시 종료하고, 그러면 unzip 이 SIGPIPE(141) 로 죽습니다.
#  `set -o pipefail` 아래에서는 파이프라인 전체가 실패로 판정되어,
#  **실제로 있는 파일을 "없음"으로 보고**했습니다. 게다가 unzip 이 먼저
#  끝났는지에 따라 결과가 달라져 같은 ZIP 이 통과/실패를 오갔습니다.
#  목록을 변수에 한 번 담고 그 변수를 상대합니다.
ENTRIES=$(unzip -Z1 "$ZIP" 2>/dev/null)

for f in \
  "build/web/index.html" \
  "build/web/version.json" \
  "server/gateway/server.js" \
  "server/gateway/june-gateway.service" \
  "server/gateway/nginx-scheduler-sch.conf" \
  "DEPLOYED_COMMIT.txt"
do
  if printf '%s\n' "$ENTRIES" | grep -qxF -- "$f"; then
    pass "필수: $f"
  else
    bad "필수 파일 없음: $f"
  fi
done

# ── 5. 있으면 안 되는 것 ──────────────────────────────────────────────
#  운영 자료·비밀값·개인키는 ZIP 에 절대 들어가면 안 됩니다.
LEAK=$(printf '%s\n' "$ENTRIES" | grep -Ei \
  '(^|/)\.env$|(^|/)data/|node_modules/|\.key$|\.pem$|id_rsa|^\.htaccess$|(^|/)CNAME$')
if [ -z "$LEAK" ]; then
  pass "비밀값·운영자료·개인키 없음"
else
  bad "있으면 안 되는 항목이 들어 있습니다:
$(echo "$LEAK" | sed 's/^/         /')"
fi

# ── 6. version.json 내용 ──────────────────────────────────────────────
VJSON=$(unzip -p "$ZIP" build/web/version.json 2>/dev/null)
GOT_VER=$(printf '%s' "$VJSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
GOT_BUILD=$(printf '%s' "$VJSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('build',''))" 2>/dev/null)
[ "$GOT_VER" = "$EXPECT_VER" ] && pass "version.json version = $GOT_VER" \
  || bad "version.json version 불일치 (기대 $EXPECT_VER / 실제 ${GOT_VER:-<없음>})"
[ "$GOT_BUILD" = "$EXPECT_BUILD" ] && pass "version.json build = $GOT_BUILD" \
  || bad "version.json build 불일치 (기대 $EXPECT_BUILD / 실제 ${GOT_BUILD:-<없음>})"

# ── 7. 커밋 표식 ──────────────────────────────────────────────────────
DCOMMIT=$(unzip -p "$ZIP" DEPLOYED_COMMIT.txt 2>/dev/null | \
  grep -oE 'commit_full=[0-9a-f]+' | cut -d= -f2)
[ "$DCOMMIT" = "$EXPECT_COMMIT" ] && pass "DEPLOYED_COMMIT = ${DCOMMIT:0:12}…" \
  || bad "DEPLOYED_COMMIT 불일치 (기대 ${EXPECT_COMMIT:0:12}… / 실제 ${DCOMMIT:0:12}…)"

# ── 8. 압축 무결성 ────────────────────────────────────────────────────
if unzip -tq "$ZIP" >/dev/null 2>&1; then
  pass "압축 무결성 (unzip -t)"
else
  bad "압축이 손상되었습니다 (unzip -t 실패)"
fi

echo "──────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m통과 — 배포해도 되는 ZIP 입니다.\033[0m\n\n'
  exit 0
else
  printf '\033[1;31m실패 — 배포하지 마십시오.\033[0m\n\n'
  exit 1
fi

#!/usr/bin/env bash
# =============================================================================
# version.json 빌드 식별자 주입 시험
# -----------------------------------------------------------------------------
# 이 시험이 지키려는 것: **업데이트 알림이 실제로 동작하는가**
#
# ## 왜 이 시험이 필요한가
#
# 앱은 `version.json` 의 `build` 와 자기 안의 `BUILD_ID` 를 비교해서
# "새 빌드가 떴나" 를 판단합니다. 그런데 Flutter 가 만드는 기본
# version.json 에는 `build` 가 없습니다. 배포 스크립트가 이 필드를
# 심지 않으면:
#
#     앱 안 BUILD_ID = 2026.11.21.0100
#     서버 version.json = {"app_name":...}   ← build 없음
#     → check() 가 null → 사용자는 영원히 "최신입니다"
#
# 2026-11-21 에 운영 서버에서 정확히 이 상태를 확인했습니다.
#
# ## 실제로 있었던 일
#
# 첫 시험에서 `write_version_json.py` 가 `--build-dir` 을 안 받아서
# **기본값(실제 프로젝트 build/web)** 에 썼습니다. 검사 장치가 불일치를
# 잡아 배포를 중단시켰기 때문에 망정이지, 없었으면 "심었다"고 보고하고
# 빈 파일을 배포했을 것입니다. 그래서 이 시험은 두 가지를 봅니다:
#   ① 올바른 경로에 심는가
#   ② 엉뚱한 경로에 썼을 때 **중단**하는가
#
# ## 실행
#     bash scripts/test_deploy_version_json.sh
#
# 격리된 임시 디렉터리만 씁니다. 실제 build/web 은 건드리지 않습니다.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITER="$PROJECT_DIR/scripts/write_version_json.py"

PASS=0
FAIL=0
ok(){   printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# 이 시험이 실제 배포본을 오염시키지 않았는지 비교할 기준값.
# 값 자체가 아니라 "건드렸는가" 를 봅니다 (배포하면 build 는 당연히 바뀝니다).
REAL="$PROJECT_DIR/build/web/version.json"
REAL_SHA_BEFORE=""
[ -f "$REAL" ] && REAL_SHA_BEFORE="$(sha256sum "$REAL" | cut -d' ' -f1)"

TMP="$(mktemp -d)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# Flutter 가 실제로 만드는 모양 그대로 (build 필드 없음)
DEFAULT_JSON='{"app_name":"june_scheduler","version":"1.0.0","build_number":"1","package_name":"june_scheduler"}'

BUILD_ID="2026.11.21.0100"

echo "=========================================="
echo " version.json 빌드 식별자 주입 시험"
echo "=========================================="

# ---------------------------------------------------------------------------
echo "=== 1) 원본에는 build 가 없다 (전제 확인) ==="
# ---------------------------------------------------------------------------
D1="$TMP/d1"; mkdir -p "$D1"
printf '%s' "$DEFAULT_JSON" > "$D1/version.json"

if python3 -c "
import json,sys
d=json.load(open('$D1/version.json',encoding='utf-8'))
sys.exit(0 if 'build' not in d else 1)
"; then
  ok "Flutter 기본 version.json 에 build 없음"
else
  bad "전제가 틀렸습니다 — 기본 파일에 이미 build 가 있습니다"
fi

# ---------------------------------------------------------------------------
echo "=== 2) --build-dir 로 지정한 곳에 심는다 ==="
# ---------------------------------------------------------------------------
if python3 "$WRITER" --build-id "$BUILD_ID" --build-dir "$D1" >/dev/null 2>&1; then
  ok "종료코드 0"
else
  bad "종료코드가 0 이 아닙니다"
fi

GET_BUILD='
import json,sys
try:
    print(json.load(open(sys.argv[1],encoding="utf-8")).get("build",""))
except Exception:
    print("")
'
GOT="$(python3 -c "$GET_BUILD" "$D1/version.json")"
if [ "$GOT" = "$BUILD_ID" ]; then
  ok "build 값 일치 ($BUILD_ID)"
else
  bad "build 값 불일치: 기대 '$BUILD_ID' 실제 '$GOT'"
fi

# 기존 필드가 보존되어야 합니다 (version/build_number 를 잃으면 앱이 깨짐)
if python3 -c "
import json,sys
d=json.load(open('$D1/version.json',encoding='utf-8'))
need=['app_name','version','build_number','package_name','build']
missing=[k for k in need if k not in d]
sys.exit(0 if not missing else 1)
"; then
  ok "기존 필드 보존됨"
else
  bad "기존 필드가 사라졌습니다"
fi

# ---------------------------------------------------------------------------
echo "=== 3) --notes 가 기록된다 ==="
# ---------------------------------------------------------------------------
D2="$TMP/d2"; mkdir -p "$D2"
printf '%s' "$DEFAULT_JSON" > "$D2/version.json"
python3 "$WRITER" --build-id "$BUILD_ID" --notes "반복 일정 버그 수정" --build-dir "$D2" >/dev/null 2>&1

NOTES="$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8")).get("notes",""))
' "$D2/version.json")"
if [ "$NOTES" = "반복 일정 버그 수정" ]; then
  ok "notes 기록됨"
else
  bad "notes 불일치: '$NOTES'"
fi

# ---------------------------------------------------------------------------
echo "=== 4) --build-dir 이 없으면 엉뚱한 곳에 쓴다 (그래서 검사가 필요) ==="
# ---------------------------------------------------------------------------
# 이건 "나쁜 동작" 을 고정하는 시험이 아니라, 왜 --build-dir 을 반드시
# 넘겨야 하는지를 기록하는 시험입니다. 생략하면 기본값(프로젝트 build/web)
# 으로 가므로, 배포 스크립트는 항상 명시해야 합니다.
D3="$TMP/d3"; mkdir -p "$D3"
printf '%s' "$DEFAULT_JSON" > "$D3/version.json"

# 기본값이 프로젝트 경로인지 확인 (경로만 검사, 실행하지 않음)
DEFAULT_DIR="$(python3 -c "
import sys
sys.path.insert(0, '$PROJECT_DIR/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wv', '$WRITER')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.DEFAULT_BUILD_DIR)
")"
if [ "$DEFAULT_DIR" = "$PROJECT_DIR/build/web" ]; then
  ok "기본값이 프로젝트 build/web 임을 확인 (→ --build-dir 필수)"
else
  bad "기본값이 예상과 다릅니다: $DEFAULT_DIR"
fi

# ---------------------------------------------------------------------------
echo "=== 5) 검사 장치: 불일치를 잡아낸다 ==="
# ---------------------------------------------------------------------------
# 배포 스크립트 안의 검사 로직을 그대로 재현합니다.
# 파일에 다른 값이 들어 있으면 exit 1 이어야 합니다.
check_build() { # $1=파일 $2=기대값
  python3 - "$1" "$2" <<'PYCHECK'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    got = json.load(open(path, encoding="utf-8")).get("build")
except Exception as e:
    print(f"   version.json 을 읽을 수 없습니다: {e}", file=sys.stderr)
    sys.exit(1)
if got != want:
    print(f"   build 불일치: 파일={got!r} 기대={want!r}", file=sys.stderr)
    sys.exit(1)
PYCHECK
}

if check_build "$D1/version.json" "$BUILD_ID" >/dev/null 2>&1; then
  ok "일치 → 통과"
else
  bad "일치하는데 실패했습니다"
fi

if check_build "$D3/version.json" "$BUILD_ID" >/dev/null 2>&1; then
  bad "불일치인데 통과시켰습니다 (검사가 무력)"
else
  ok "불일치 → 중단"
fi

if check_build "$TMP/없는파일.json" "$BUILD_ID" >/dev/null 2>&1; then
  bad "없는 파일인데 통과시켰습니다"
else
  ok "파일 없음 → 중단"
fi

# ---------------------------------------------------------------------------
echo "=== 6) 깨진 JSON 을 만나도 예외로 죽지 않는다 ==="
# ---------------------------------------------------------------------------
D4="$TMP/d4"; mkdir -p "$D4"
printf '%s' 'not json at all' > "$D4/version.json"
if check_build "$D4/version.json" "$BUILD_ID" >/dev/null 2>&1; then
  bad "깨진 JSON 인데 통과시켰습니다"
else
  ok "깨진 JSON → 중단 (예외 던지지 않음)"
fi

# ---------------------------------------------------------------------------
echo "=== 7) 배포 스크립트가 --build-dir 을 명시하는가 ==="
# ---------------------------------------------------------------------------
# 이게 이 파일에서 가장 중요한 단정입니다. 3-3 블록이 --build-dir 없이
# write_version_json 을 부르면 4) 의 사고가 재발합니다.
DP="$PROJECT_DIR/deploy_pages.sh"
if [ -f "$DP" ]; then
  if grep -q -- '--build-dir' "$DP"; then
    ok "deploy_pages.sh 가 --build-dir 을 넘긴다"
  else
    bad "deploy_pages.sh 에 --build-dir 이 없습니다 (엉뚱한 경로에 쓸 수 있음)"
  fi

  if grep -q 'write_version_json' "$DP"; then
    ok "deploy_pages.sh 가 version.json 주입을 호출한다"
  else
    bad "deploy_pages.sh 가 version.json 주입을 호출하지 않는다 (알림 동작 불가)"
  fi
else
  bad "deploy_pages.sh 가 없습니다"
fi

# ---------------------------------------------------------------------------
echo "=== 8) 실제 프로젝트 build/web 은 건드리지 않았다 ==="
# ---------------------------------------------------------------------------
# 시험이 실수로 실제 배포본을 오염시키면, 다음 배포에서 그 값이 그대로
# 나가 사용자에게 거짓 알림이 갑니다.
if [ -f "$REAL" ]; then
  # ## 값을 하드코딩하면 안 됩니다
  # 처음엔 특정 빌드 ID 를 기대값으로 박아두었습니다. 그런데 배포할 때마다
  # build 값은 당연히 바뀌므로, 정상적인 배포가 시험을 실패시킵니다.
  # 확인해야 하는 것은 "값이 특정 문자열인가"가 아니라
  # **"이 시험이 파일을 건드리지 않았는가"** 입니다.
  # 그래서 시험 시작 시점의 해시와 비교합니다.
  if [ "$(sha256sum "$REAL" | cut -d' ' -f1)" = "$REAL_SHA_BEFORE" ]; then
    ok "실제 version.json 무변경 (build=${R:-없음})"
  else
    bad "실제 version.json 이 변경되었습니다 (build='$R')"
  fi
else
  ok "실제 build/web 없음 (검사 생략)"
fi

echo
echo "=========================================="
printf ' 통과 %d / 실패 %d\n' "$PASS" "$FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1

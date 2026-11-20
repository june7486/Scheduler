#!/usr/bin/env bash
# =============================================================================
# June Scheduler — 샌드박스 원상복구 (resurrect.sh)
# =============================================================================
# ## 이 스크립트가 존재하는 이유
# 샌드박스는 언제든 사라질 수 있습니다. 오류로 멈추거나, 세션이 끝나거나,
# 메모리가 바닥나거나. 그때 "무엇이 남고 무엇이 사라지는지"를 모르면 매번
# 처음부터 다시 세팅하게 됩니다.
#
# 실제로 있었던 일입니다: /home/user/flutter_app 은 살아남는데
# build/web 은 날아가고, 5060 미리보기 서버는 죽고, gateway 는 설정을
# 잊어버립니다. 파일은 git 에 있으니 살아나지만 **"지금 띄워진 상태"는
# 아무 데도 저장되지 않습니다.** 이 스크립트가 그 상태를 복원합니다.
#
# ## 무엇이 사라지고 무엇이 남는가
#
#   남는다 (disk)          : /home/user 전체 — 소스, git 기록, 문서
#                            단 build/ 는 git 에 없으므로 "파일이 남는" 것과
#                            "빌드가 남는" 것은 다릅니다
#   사라진다 (memory)      : 돌아가던 프로세스 전부 — 5060, 5077, gateway
#   사라진다 (session)     : 환경변수, 셸 상태, 백그라운드 작업
#
# 그래서 복구는 두 단계입니다:
#   ① 파일이 온전한가   (git status, build 존재 여부)
#   ② 돌아가는 상태인가 (포트, HTTP 응답)
#
# ## 사용법
#   ./scripts/resurrect.sh              복구 (필요한 것만)
#   ./scripts/resurrect.sh --check      진단만, 아무것도 안 바꿈
#   ./scripts/resurrect.sh --force      build/web 도 무조건 다시 만듦
#   ./scripts/resurrect.sh --no-preview 미리보기 서버는 안 띄움
# =============================================================================
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

MODE="resurrect"
FORCE_BUILD=0
START_PREVIEW=1
for arg in "$@"; do
  case "$arg" in
    --check)       MODE="check" ;;
    --force)       FORCE_BUILD=1 ;;
    --no-preview)  START_PREVIEW=0 ;;
    -h|--help)     sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $arg"; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✅\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠️ \033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m❌\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }

PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS + 1)); }

# =============================================================================
hdr "① 파일 상태 — 소스와 git 기록"
# =============================================================================
# 이건 샌드박스가 아니라 디스크의 문제입니다. 여기가 깨졌으면 복구가 아니라
# 백업에서 되살려야 합니다.

if [ -d .git ]; then
  ok "git 저장소 있음"

  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  info "브랜치: $BRANCH"

  HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  HEAD_MSG="$(git log -1 --pretty=%s 2>/dev/null | cut -c1-60 || echo '?')"
  info "HEAD: $HEAD_SHA — $HEAD_MSG"

  # ## 커밋 안 된 변경이 있는가
  # 있으면 복구 전에 알려야 합니다. 여기서 자동으로 뭘 하면 안 됩니다 —
  # 작업 중인 코드를 말없이 stash 하거나 버리면 안 되니까요.
  DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$DIRTY" = "0" ]; then
    ok "커밋 안 된 변경 없음"
  else
    warn "커밋 안 된 변경 ${DIRTY}건 — 확인하세요"
    git status --short 2>/dev/null | head -8 | while read -r l; do info "$l"; done
    note_problem
  fi
else
  bad "git 저장소 없음 — 백업에서 복원해야 합니다"
  note_problem
fi

# =============================================================================
hdr "② 빌드 상태 — build/web"
# =============================================================================
# ## build/ 는 git 에 없습니다
# .gitignore 대상이라 샌드박스 리셋 후 살아남지 않을 수 있습니다.
# 소스는 있는데 build/web 이 없으면 "복구"가 아니라 "재빌드"입니다.
# 이 구분을 모르면 "왜 앱이 안 뜨지"로 한참 헤매게 됩니다.

NEED_BUILD=0
if [ -f build/web/main.dart.js ] && [ -f build/web/index.html ]; then
  JS_SIZE=$(stat -c%s build/web/main.dart.js 2>/dev/null || echo 0)
  JS_HASH=$(sha256sum build/web/main.dart.js 2>/dev/null | cut -c1-16 || echo '?')
  ok "build/web 있음"
  info "main.dart.js ${JS_SIZE} 바이트, sha256 ${JS_HASH}…"

  # 빈 껍데기만 남는 경우가 있습니다 (중간에 죽은 빌드)
  if [ "$JS_SIZE" -lt 100000 ]; then
    bad "main.dart.js 가 너무 작습니다 (${JS_SIZE}B) — 빌드가 중간에 죽은 것으로 보임"
    NEED_BUILD=1
    note_problem
  fi
else
  warn "build/web 없음 또는 불완전 — 재빌드가 필요합니다"
  NEED_BUILD=1
fi

# wasm 이 없으면 흰 화면입니다. 이건 놓치기 쉬워서 따로 봅니다.
WASM_COUNT=$(find build/web -name '*.wasm' 2>/dev/null | wc -l | tr -d ' ')
if [ "$WASM_COUNT" -gt 0 ]; then
  WASM_MB=$(find build/web -name '*.wasm' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s/1048576}')
  ok "wasm ${WASM_COUNT}개, ${WASM_MB}MB"
else
  warn "wasm 없음 — CanvasKit 이 로드되지 않아 흰 화면이 됩니다"
  NEED_BUILD=1
fi

if [ "$FORCE_BUILD" = "1" ]; then
  NEED_BUILD=1
  info "--force — 강제 재빌드"
fi

# =============================================================================
hdr "③ 환경 — Flutter / Node"
# =============================================================================
if command -v flutter >/dev/null 2>&1; then
  FL_VER="$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')"
  ok "Flutter ${FL_VER:-?}"
  # ## 버전이 다르면 경고합니다
  # 이 프로젝트는 3.35.4 로 잠겨 있습니다. 다른 버전으로 빌드하면
  # 예상 못 한 차이가 생깁니다. 막지는 않습니다 — 경고만 합니다.
  # (샌드박스가 새로 뜨면 버전이 다를 수 있고, 그때 빌드를 아예 못 하면
  #  더 곤란합니다. 판단은 사람이 합니다.)
  case "${FL_VER:-}" in
    3.35.*) ;;
    *) warn "Flutter ${FL_VER:-?} — 이 프로젝트는 3.35.4 기준입니다" ;;
  esac
else
  bad "Flutter 없음 — 빌드 불가"
  note_problem
fi

if command -v node >/dev/null 2>&1; then
  ok "Node $(node --version 2>/dev/null)"
else
  warn "Node 없음 — 게이트웨이는 못 띄웁니다 (웹 앱은 무관)"
fi

# =============================================================================
hdr "④ 포트 상태 — 미리보기와 게이트웨이"
# =============================================================================
# ## 여기서 "죽었다"를 판정하는 기준
# 포트가 LISTEN 인지만 봅니다. 프로세스 이름은 신뢰하지 않습니다.
# 실제로 socat 같은 포워더가 대신 잡고 있을 수 있어서, 이름으로 판단하면
# "서버가 살아 있다"고 착각합니다. HTTP 응답까지 봐야 확실합니다.

check_port() {
  local port="$1" label="$2"
  if ss -tln 2>/dev/null | grep -q ":${port} "; then
    local code
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
    ok "${label} (${port}) LISTEN — HTTP ${code}"
    return 0
  else
    warn "${label} (${port}) 없음"
    return 1
  fi
}

PREVIEW_UP=0
GW_UP=0
check_port 5060 "미리보기" && PREVIEW_UP=1
check_port 5077 "다운로드" || true
check_port 8097 "게이트웨이" && GW_UP=1

# =============================================================================
# 진단 모드면 여기서 끝
# =============================================================================
if [ "$MODE" = "check" ]; then
  hdr "진단 결과"
  if [ "$PROBLEMS" = "0" ] && [ "$NEED_BUILD" = "0" ]; then
    ok "문제 없음"
  else
    warn "문제 ${PROBLEMS}건, 재빌드 필요 ${NEED_BUILD}"
    info "복구하려면: ./scripts/resurrect.sh"
  fi
  exit 0
fi

# =============================================================================
hdr "⑤ 재빌드"
# =============================================================================
if [ "$NEED_BUILD" = "1" ]; then
  say "  빌드 중... (1~2분)"

  # ## SYNC_URL / SYNC_KEY 를 일부러 넘기지 않습니다
  # 넘기면 값이 main.dart.js 에 평문으로 박혀 공개됩니다.
  # 2026-11-20 사건이 그것이었습니다. 복구 빌드에서 같은 실수를 반복하면
  # 복구가 아니라 재발입니다.
  unset SYNC_URL SYNC_KEY 2>/dev/null || true

  BUILD_ID="$(date -u +%Y.%m.%d.%H%M)"

  if flutter pub get >/tmp/resurrect_pub.log 2>&1 \
     && flutter build web --release --base-href "/" \
          --dart-define=BUILD_ID="$BUILD_ID" >/tmp/resurrect_build.log 2>&1; then
    ok "빌드 완료 (BUILD_ID=$BUILD_ID)"

    # 누출 검사 — 빌드했다고 끝이 아닙니다
    if [ -f scripts/check_bundle_secrets.py ]; then
      if python3 scripts/check_bundle_secrets.py --strict >/tmp/resurrect_scan.log 2>&1; then
        ok "누출 검사 통과"
      else
        bad "누출 검사 실패 — 아래를 확인하세요"
        tail -20 /tmp/resurrect_scan.log | while read -r l; do info "$l"; done
        note_problem
      fi
    fi
  else
    bad "빌드 실패"
    info "로그: /tmp/resurrect_build.log"
    tail -15 /tmp/resurrect_build.log 2>/dev/null | while read -r l; do info "$l"; done
    note_problem
  fi
else
  ok "빌드 그대로 사용 (재빌드 불필요)"
fi

# =============================================================================
hdr "⑥ 미리보기 서버"
# =============================================================================
if [ "$START_PREVIEW" = "0" ]; then
  info "--no-preview — 건너뜀"
elif [ "$PREVIEW_UP" = "1" ]; then
  ok "이미 돌고 있음"
else
  if [ -f build/web/index.html ]; then
    say "  5060 에 띄우는 중..."

    # ## setsid -f 로 띄우는 이유
    # 그냥 & 로 띄우면 이 스크립트가 끝날 때 같이 죽습니다(같은 세션).
    # setsid 로 세션을 분리해야 스크립트가 끝나도 살아남습니다.
    # 리다이렉트를 전부 붙이는 것도 같은 이유 — 부모의 stdout 이 닫히면
    # 자식이 SIGPIPE 로 죽습니다.
    ( cd build/web && setsid -f python3 -m http.server 5060 \
        > "$PROJECT_DIR/server.log" 2>&1 < /dev/null )

    sleep 2
    if curl -s -m 3 -o /dev/null http://127.0.0.1:5060/; then
      ok "미리보기 5060 기동"
    else
      bad "미리보기 기동 실패 — server.log 확인"
      note_problem
    fi
  else
    warn "build/web 이 없어 미리보기를 못 띄웁니다"
  fi
fi

# =============================================================================
hdr "⑦ 게이트웨이 (선택)"
# =============================================================================
# 게이트웨이는 앱 동작에 필수가 아닙니다. 동기화를 쓸 때만 필요합니다.
# 그래서 여기서는 "설정이 있으면 띄운다" 정도만 합니다.
if [ "$GW_UP" = "1" ]; then
  ok "이미 돌고 있음"
elif [ -f server/gateway/.env ]; then
  info "server/gateway/.env 있음 — start.sh 로 띄울 수 있습니다"
  info "  ( cd server/gateway && ./start.sh )"
else
  info "게이트웨이 설정 없음 — 동기화를 안 쓰면 그대로 두세요"
fi

# =============================================================================
hdr "결과"
# =============================================================================
if [ "$PROBLEMS" = "0" ]; then
  ok "복구 완료 — 눈에 띄는 문제 없음"
else
  warn "복구했지만 확인할 것 ${PROBLEMS}건 (위 로그 참고)"
fi

say ""
info "미리보기: http://127.0.0.1:5060/"
info "진단만:   ./scripts/resurrect.sh --check"
info "전체 재빌드: ./scripts/resurrect.sh --force"
say ""

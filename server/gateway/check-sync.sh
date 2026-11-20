#!/usr/bin/env bash
# 나스 게이트웨이가 실제로 닿는지 한 번에 확인한다.
#
# 프록시를 세팅한 뒤 "됐는지 안 됐는지"를 눈으로 판정하기 위한 스크립트입니다.
# 앱 설정 화면의 [테스트] 버튼과 같은 판단을 하지만, 브라우저 캐시나 로그인
# 상태에 영향받지 않아 배포 전 확인용으로 더 믿을 만합니다.
#
# 사용법:
#   ./check-sync.sh                                  # 기본 주소로 확인
#   ./check-sync.sh https://sync.example.com KEY     # 주소·키 직접 지정
#
# 종료 코드: 0 = 정상, 1 = 실패(원인 출력)

set -uo pipefail

# 기본값으로 실제 주소를 박아두지 않습니다. 이 스크립트는 배포물에
# 포함될 수 있고, 그러면 주소가 다시 유통됩니다. 인자나 환경변수로 받습니다.
URL="${1:-${SYNC_URL:-}}"
if [ -z "$URL" ]; then
  printf '사용법: %s <URL> [KEY]   또는   SYNC_URL=... %s [KEY]\n' "$0" "$0" >&2
  printf '예: %s https://sync.example.com <KEY>\n' "$0" >&2
  exit 1
fi
KEY="${2:-}"
URL="${URL%/}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '%s✔%s %s\n' "$c_grn" "$c_off" "$1"; }
bad()  { printf "%s✘%s %s\n" "$c_red" "$c_off" "$1"; }
warn() { printf '%s!%s %s\n' "$c_yel" "$c_off" "$1"; }
note() { printf '%s  %s%s\n' "$c_dim" "$1" "$c_off"; }

printf '\n%s주소%s %s\n\n' "$c_dim" "$c_off" "$URL"

command -v curl >/dev/null || { bad "curl 이 없습니다"; exit 1; }

# ---- 1) /health ----------------------------------------------------------
# 본문과 상태 코드를 함께 받아온다. 나스가 잠들어 있으면 여기서 오래 걸린다.
body="$(curl -s --max-time 25 -w '\n%{http_code}' "$URL/health" 2>/dev/null)"
code="$(printf '%s' "$body" | tail -n1)"
payload="$(printf '%s' "$body" | sed '$d')"

if [ "$code" = "000" ]; then
  bad "응답 없음 — HTTPS 연결이 완성되지 않았습니다"
  note "TCP 는 연결되는데 TLS 가 실패하는 경우가 대부분입니다."
  # 실패한 TLS 핸드셰이크에서 서버가 내려준 인증서를 들여다본다.
  local_cert="$(echo | timeout 12 openssl s_client -connect "${URL#https://}:443" \
      -servername "${URL#https://}" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"
  if [ -n "$local_cert" ]; then
    bad "서버가 내려준 인증서: ${local_cert#subject=}"
    note "이 이름에 맞는 인증서가 아닙니다 → 제어판 → 보안 → 인증서 에서"
    note "'${URL#https://}' 에 인증서를 지정하세요. (SNI 로 골라집니다)"
  else
    note "확인: 주소 오타 / 나스 꺼짐 / 방화벽 / 프록시 규칙 미저장"
  fi
  exit 1
fi

if [ "$code" = "502" ] || [ "$code" = "503" ]; then
  ok "프록시 규칙은 살아 있습니다 (HTTPS 인증서도 통과)"
  bad "HTTP $code — 프록시가 대상을 찾지 못했습니다"
  note "즉, 게이트웨이가 8097 에서 돌고 있지 않습니다."
  printf '\n'
  note "나스에서 실행하세요:"
  note "  cd /volume1/92_Scheduler/scheduler-sync && sudo ./setup-nas.sh"
  printf '\n'
  note "그다음 다시 이 스크립트를 돌리면 통과합니다."
  exit 1
fi

if [ "$code" = "401" ]; then
  bad "401 — 게이트웨이는 살아 있지만 키가 필요합니다"
  note "프록시는 정상입니다. 키를 확인하세요."
  exit 1
fi

if [ "$code" != "200" ]; then
  bad "HTTP $code — 게이트웨이가 아닌 무언가가 답했습니다"
  note "프록시가 아직 없거나, 다른 서비스로 연결되어 있습니다."
  exit 1
fi

case "$payload" in
  *'"service":"june-nas-gateway"'*|*'"service": "june-nas-gateway"'*)
    ok "게이트웨이가 응답합니다"
    payload_flat="$(printf '%s' "$payload" | tr -d '\n')"
    printf '%s\n' "$payload_flat" | head -c 400
    printf '\n'
    case "$payload_flat" in
      *'"nas":false'*) warn "게이트웨이는 살아 있지만 저장소 접근에 실패했습니다"; note "DSM 로그인 정보 또는 DATA_DIR 권한을 확인하세요" ;;
    esac
    ;;
  *)
    # 200 인데 JSON 이 아니거나 게이트웨이가 아니다 = 거의 항상 DSM 로그인 페이지.
    bad "여기는 게이트웨이가 아닙니다"
    note "받은 내용(앞부분): $(printf '%s' "$payload" | tr -d '\n' | head -c 120)"
    echo
    warn "가장 흔한 원인 — 리버스 프록시의 소스/대상이 뒤바뀐 경우"
    note "소스: HTTPS / 443 / <도메인>      ← 사용자가 접속하는 바깥 문"
    note "대상: HTTP  / localhost / 8097    ← 게이트웨이가 있는 안쪽 방"
    note "지금 소스에 localhost:8097 이 들어가 있으면 DSM 이 자기 자신에게"
    note "되돌리는 설정이 되어 로그인 화면이 나옵니다."
    exit 1
    ;;
esac

# ---- 2) 키 검증 ----------------------------------------------------------
# /health 는 설계상 인증 없이 열려 있다. 키가 맞는지는 키가 필요한
# /api/state 로만 알 수 있다. 존재하지 않는 워크스페이스를 읽으므로 부작용이 없다.
if [ -n "$KEY" ]; then
  probe="$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' \
    -H "X-Sync-Key: $KEY" \
    "$URL/api/state?ws=ACCDIAGNOSTICPROBE0000000000" 2>/dev/null)"
  case "$probe" in
    200) ok "공유 키가 통과합니다" ;;
    401) bad "공유 키가 거부되었습니다 (X-Sync-Key)"; note "게이트웨이의 SYNC_SECRET 과 비교하세요"; exit 1 ;;
    *)   warn "키 확인 응답: HTTP $probe" ;;
  esac
else
  note "키를 넘기지 않아 키 검증은 건너뜁니다 (2번째 인자로 키를 주세요)"
fi

printf '\n%s정상입니다. 이제 앱 빌드에 주소를 심으세요:%s\n' "$c_grn" "$c_off"
note "SYNC_URL=\"$URL\" SYNC_KEY=\"<키>\" ./deploy_pages.sh custom"
printf '\n'
exit 0

#!/usr/bin/env bash
# 나스 게이트웨이를 처음 세팅할 때 쓰는 얇은 래퍼. (관리자 권한으로 실행)
#
# 실제 실행은 이미 있는 `start.sh` 에 맡긴다. start.sh 는 나스의 여러 경로에
# 흩어져 있는 node 를 찾아내고 .env 를 읽고 중복 실행을 막는 일을 이미 한다.
# 여기서 같은 로직을 다시 쓰면 두 곳이 서로 다른 답을 내는 사고가 난다
# (실제로 그렇게 만들었다가 .env 의 PORT 를 무시하는 버전이 나왔다).
#
# 이 스크립트가 start.sh 에 더하는 것은 셋뿐이다.
#   · 데이터 폴더를 만들고 권한을 맞춘다
#   · 뜬 다음 /health 로 실제 응답을 확인한다
#   · 부팅 시 자동 시작 등록 절차를 화면에 띄운다
#
# 사용법:
#   sudo ./setup-nas.sh              # 세팅 (이미 떠 있으면 그대로 둠)
#   sudo ./setup-nas.sh --restart    # 재시작
#   sudo ./setup-nas.sh --status     # 상태
#   sudo ./setup-nas.sh --stop       # 중지

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()    { printf '%s✔%s %s\n' "$c_grn" "$c_off" "$1"; }
bad()   { printf '%s✘%s %s\n' "$c_red" "$c_off" "$1"; }
warn()  { printf '%s!%s %s\n' "$c_yel" "$c_off" "$1"; }
note()  { printf '%s  %s%s\n' "$c_dim" "$1" "$c_off"; }
head_() { printf '\n%s\n' "── $1"; }

[ -f "$DIR/.env" ] || {
  bad ".env 가 없습니다"
  note "복사한 뒤 값을 채우세요: cp .env.example .env"
  exit 1
}

# FileStation 으로 올린 파일은 실행 비트가 없다. 그래서 ./start.sh 가
# "Permission denied" 로 죽는 일이 흔하다. 여기서 한 번 고쳐준다.
chmod +x "$DIR"/*.sh 2>/dev/null || true

# 이 스크립트가 root 로 돌면 이후 start.sh/check-sync.sh 를 그냥 실행해도 된다.

# .env 에서 PORT/DATA_DIR 만 읽는다. start.sh 는 자기 방식대로 읽으므로
# 여기서는 화면 표시와 폴더 준비에만 쓴다.
PORT="$(grep -E '^PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
PORT="${PORT:-8097}"
DATA_DIR="$(grep -E '^DATA_DIR=' .env 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
DATA_DIR="${DATA_DIR:-$DIR/data}"
STORAGE="$(grep -E '^STORAGE=' .env 2>/dev/null | cut -d= -f2 | tr -d ' \r')"
STORAGE="${STORAGE:-$(grep -qE '^NAS_HOST=.+' .env && echo dsm || echo local)}"

health() { curl -s --max-time 5 "http://127.0.0.1:$PORT/health" 2>/dev/null; }

wait_health() {
  local h=""
  for _ in $(seq 1 40); do          # 최대 10초. 느린 나스도 넉넉히 덮는다.
    h="$(health)"
    [ -n "$h" ] && { printf '%s' "$h"; return 0; }
    sleep 0.25
  done
  return 1
}

do_setup() {
  head_ "1 / 3  데이터 폴더"
  if [ "$STORAGE" = "local" ]; then
    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR" 2>/dev/null
    if [ -d "$DATA_DIR" ] && [ -w "$DATA_DIR" ]; then
      chown -R "$(id -un):users" "$DATA_DIR" 2>/dev/null || true
      ok "$DATA_DIR (쓰기 가능)"
    else
      bad "$DATA_DIR 에 쓸 수 없습니다"
      note "확인: ls -ld $DATA_DIR  →  소유자:권한"
      exit 1
    fi
  else
    note "STORAGE=dsm — 데이터는 나스 FileStation API 로 저장됩니다"
    note "NAS_HOST / NAS_USER / NAS_PASS 가 .env 에 있는지 확인하세요"
  fi

  head_ "2 / 3  게이트웨이 시작"
  if "$DIR/start.sh" status >/dev/null 2>&1; then
    warn "이미 실행 중 — 재시작합니다"
    "$DIR/start.sh" stop >/dev/null 2>&1 || true
    sleep 0.5
  fi

  if ! "$DIR/start.sh" start 2>&1 | sed 's/^/    /'; then
    echo
    bad "start.sh 가 실패했습니다"
    note "위의 ❌ 메시지를 그대로 보내주세요."
    note "가장 흔한 원인: Node.js 미설치"
    note "  DSM → 패키지 센터 → 설정 → '베타 패키지 포함' → Node.js v20 설치"
    exit 1
  fi

  head_ "3 / 3  실제 응답 확인"
  local h
  if h="$(wait_health)"; then
    ok "응답: $h"
    case "$h" in
      *'"nas":false'*)
        warn "게이트웨이는 살아 있지만 저장소 접근에 실패했습니다"
        note "STORAGE=dsm 이면 NAS_USER / NAS_PASS 를,"
        note "STORAGE=local 이면 DATA_DIR 권한을 확인하세요."
        ;;
    esac
  else
    bad "프로세스는 떴는데 /health 가 응답하지 않습니다"
    note "로그 ($DIR/gateway.log):"
    tail -n 25 "$DIR/gateway.log" 2>/dev/null | sed 's/^/    /'
    exit 1
  fi

  printf '\n%s게이트웨이가 살아 있습니다.%s\n' "$c_grn" "$c_off"

  printf '\n%s이제 남은 일은 세 가지입니다.%s\n\n' "$c_yel" "$c_off"

  printf '%s[1] 부팅 시 자동 시작 (한 번만)%s\n' "$c_dim" "$c_off"
  note "DSM → 제어판 → 작업 스케줄러 → 생성 → 트리거된 작업"
  note "  작업: 'scheduler-sync'   사용자: root"
  note "  이벤트: 부팅 시"
  note "  작업 설정 → 사용자 정의 스크립트:"
  note "    $DIR/start.sh start"
  printf '\n'

  printf '%s[2] 리버스 프록시 (이미 되어 있으면 그대로 두세요)%s\n' "$c_dim" "$c_off"
  note "소스: HTTPS / 443 / <도메인>        ← 사용자가 접속하는 바깥 문"
  note "대상: HTTP  / localhost / $PORT    ← 게이트웨이가 있는 안쪽 방"
  note "HTTP/2 는 끄세요 (롱폴을 버퍼링해 '가끔 멈춤'을 만듭니다)"
  note "'사용자 지정 머리글' 은 비워두어도 됩니다 — 서버가 Host 를 검사하지 않습니다"
  printf '\n'
  printf '%s[3] 인증서 지정 (안 하면 브라우저가 경고를 띄웁니다)%s\n' "$c_dim" "$c_off"
  note "제어판 → 보안 → 인증서 → 설정 → 서비스 탭"
  note "  위 주소(예: sync.example.com) 줄을 체크 → 확인 → 저장"
  printf '\n'
  note "그다음 확인:  $DIR/check-sync.sh"
  printf '\n'
}

case "${1:-}" in
  ""|--start|start)   do_setup ;;
  --status|status)    "$DIR/start.sh" status ;;
  --stop|stop)        "$DIR/start.sh" stop ;;
  --restart|restart)  "$DIR/start.sh" stop >/dev/null 2>&1 || true; do_setup ;;
  *) bad "알 수 없는 옵션: $1"; note "사용법: sudo $0 [--start|--stop|--status|--restart]" ;;
esac

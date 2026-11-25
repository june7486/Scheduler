#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  June's Scheduler — 가비아 전용 전환 / 복구 (한 파일)
#
#  실행
#    sudo bash scheduler-cutover.sh <zip> <approval.json>   전환 (승인 필수)
#    sudo bash scheduler-cutover.sh --rollback              복구 (수동)
#    sudo bash scheduler-cutover.sh --check                 현재 상태만 읽기
#
#  ## 전환이 거부되는 조건 (0번에서 즉시 중단, 운영은 그대로)
#    * approval.json 또는 approval.json.sig 가 없음
#    * 서명이 신뢰 목록(ops/verifier-keys.json)의 어떤 키와도 맞지 않음
#    * 승인된 커밋·SHA-256·크기·버전이 실물 ZIP 과 다름
#    * 커밋이 배포 금지 목록(앱 결함 잔존)에 있음
#    * ZIP 안에 data/ · .env · 개인키가 들어 있음
#  즉 **Git push 만으로는 운영이 바뀌지 않습니다.** 저장소에는 훅도 CI 도
#  없고, 있어도 이 스크립트는 승인 기록 없이는 진행하지 않습니다.
#
#  설계 원칙
#    1. 준비(STAGE)가 끝나기 전에는 기존 서비스를 내리지 않습니다.
#    2. 새 버전이 /health 에 답하지 못하면 기존 스케줄러로 자동 복구합니다.
#    3. 삭제는 하지 않습니다. 이름만 바꿔 보존합니다.
#    4. DNS·인증서·www.aqdesign.co.kr·허브·배포센터는 건드리지 않습니다.
#    5. 값(동기화 키)은 화면에 출력하지 않습니다.
#    6. sch.june7486.com 의 /api/ 는 전환 전후 모두 살아 있어야 합니다.
#
#  ## 이 파일에서 고친 것 (2026-11-24)
#  이전 판은 "자동 복구"를 표방했지만 실제로는 복구되지 않았습니다.
#    ① rollback() 이 경로를 잘못 잡았습니다. 새 배포본이 옮겨간 $LIVE 안에
#       파일이 남아 있으면 `[ ! -d "$LIVE" ]` 조건이 거짓이 되어 1.0.0 을
#       되돌리지 않고 그냥 exit 했습니다. 그 상태로 서비스를 시작하면
#       **깨진 새 버전**이 다시 올라옵니다. 복구라고 부를 수 없습니다.
#    ② rollback() 이 systemd 유닛과 nginx root 를 되돌리지 않았습니다.
#       1.0.0 을 복원해도 유닛이 새 경로를 가리키면 뜨지 않습니다.
#    ③ 안내 문구의 `--rollback` 이 구현되어 있지 않았습니다. 실행하면
#       옵션 문자열을 ZIP 경로로 해석해 "ZIP 없음"으로 끝났습니다.
#       운영자에게 되돌리기를 안내하면서 되돌리는 수단을 주지 않은 셈입니다.
#  셋 다 실제 전환에서 "복구 실패"로 이어지는 경로라 고쳤습니다.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

APP=scheduler
ROOT=/srv/june7486/sites
LIVE=$ROOT/scheduler
STAGE=$ROOT/scheduler-stage
OLD=$ROOT/scheduler-old
WWW=sch.june7486.com
PORT=8097
DATA=$LIVE/data
UNIT=/etc/systemd/system/june-gateway.service

EXPECT_SHA="6bd5444c3d7fbb48ec6a671f6f4f8862663e9d26b4aab431cd15f9b358452a43"

# ── 검증 주체 승인 (필수) ────────────────────────────────────────────
# ## 왜 하드코딩된 SHA 대신 승인 기록인가
# 이전 판은 이 파일 안에 SHA 하나를 박아 두고 그것만 확인했습니다. 그러면
#   · 새 릴리스가 나올 때마다 이 파일을 고쳐야 하고,
#   · 고치는 사람이 곧 배포를 승인하는 사람이 됩니다.
# 즉 "검증 주체가 승인한 산출물만 전환한다"는 요구가 지켜지지 않습니다.
# 지금은 ops/deploy-gate.py 가 서명된 승인 기록을 요구하고, 이 스크립트는
# 그 게이트를 **통과하지 못하면 시작조차 하지 않습니다.**
GATE="${SCHED_GATE:-}"
APPROVAL=""
if [ -z "$GATE" ]; then
  for c in "$(dirname "$0")/deploy-gate.py" \
           /home/user/flutter_app/ops/deploy-gate.py \
           /opt/scheduler-ops/deploy-gate.py; do
    [ -f "$c" ] && { GATE="$c"; break; }
  done
fi

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✅ %s\033[0m\n' "$*"; }
warn() { printf '  \033[33m⚠️  %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ 중단: %s\033[0m\n' "$*"; exit 1; }

MODE="${1:-}"
case "$MODE" in
  --rollback|--check) ZIP="" ;;
  "") ZIP=$(ls -1 /tmp/scheduler-op-40777e6-*.zip 2>/dev/null | tail -1) ;;
  *)  ZIP="$MODE" ;;
esac
# 승인 기록은 ZIP 옆에 오거나, 두 번째 인자로 줍니다
if [ -n "${2:-}" ]; then
  APPROVAL="$2"
elif [ -n "${ZIP:-}" ] && [ -f "${ZIP}.approval.json" ]; then
  APPROVAL="${ZIP}.approval.json"
fi

[ "$MODE" = "--check" ] || [ "$(id -u)" -eq 0 ] || die "sudo 로 실행해 주세요"

# ─────────────────────────────────────────────────────────────
#  공용: 유닛/nginx 를 특정 배포본에 맞추기
# ─────────────────────────────────────────────────────────────
point_unit_at() {
  local APP_DIR="$1" ENVF="$2" DATADIR="$3" NODE="$4"
  [ -f "$APP_DIR/server/gateway/june-gateway.service" ] || return 1
  sed -e "s#^WorkingDirectory=.*#WorkingDirectory=$APP_DIR#" \
      -e "s#^EnvironmentFile=.*#EnvironmentFile=-$ENVF#" \
      -e "s#^ExecStart=.*#ExecStart=$NODE server/gateway/server.js#" \
      -e "s#^Environment=DATA_DIR=.*#Environment=DATA_DIR=$DATADIR#" \
      "$APP_DIR/server/gateway/june-gateway.service" > "$UNIT"
  systemctl daemon-reload
}

point_nginx_at() {
  local WEBROOT="$1"
  # ## certbot 의 root 를 건드리면 안 됩니다 (2026-11-24 수정)
  # 이전 판은 `sed s#^(\s*)root\s+[^;]+;#...#` 로 **모든** root 지시자를
  # 치환했습니다. 그런데 이 설정에는 root 가 두 개입니다.
  #
  #     location /.well-known/acme-challenge/ { root /var/www/certbot; }
  #     location /                            { root /srv/.../scheduler-df225b3; }
  #
  # 둘 다 앱 번들 경로로 덮이면 ACME 챌린지가 번들 디렉터리에서 찾아지지
  # 않습니다. 증상이 즉시 나타나지 않고 **90일 뒤 갱신 실패**로만 드러나서
  # 더 위험합니다. HTTPS 를 유지하라는 요구사항과 정면으로 충돌합니다.
  #
  # 그래서 바꾸는 대상은 "앱 번들을 서빙하는 root 한 줄"로 한정합니다:
  #   - 인증서/ACME 경로(var/www/certbot, letsencrypt, .well-known)는 제외
  #   - 기존 root 값 또는 새 root 값이 이미 그 줄이면 그 줄만
  if grep -qE '^\s*root\s+' "$NGX" 2>/dev/null; then
    # 앱 번들 root 로 바꿀 대상 한 줄을 고릅니다.
    local TARGET
    TARGET=$(grep -nE '^\s*root\s+' "$NGX" \
      | grep -viE 'certbot|letsencrypt|well-known|acme' \
      | head -1 | cut -d: -f1)
    if [ -n "${TARGET:-}" ]; then
      sed -i -E "${TARGET}s#^(\s*)root\s+[^;]+;#\1root $WEBROOT;#" "$NGX"
    fi
  fi
  # ACME 경로는 그대로 남아 있어야 합니다. 사라졌으면 알립니다.
  if grep -q 'acme-challenge' "$NGX" 2>/dev/null && \
     ! grep -qE 'root\s+/var/www/certbot' "$NGX" 2>/dev/null; then
    warn "ACME 챌린지 root 가 /var/www/certbot 이 아닙니다 — 인증서 갱신을 확인하십시오"
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
}

wait_health() {
  local i
  for i in $(seq 1 20); do
    if curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT/health"; then return 0; fi
    sleep 1
  done
  return 1
}

# ─────────────────────────────────────────────────────────────
#  현재 상태 읽기 (아무것도 바꾸지 않음)
# ─────────────────────────────────────────────────────────────
read_current() {
  echo "  서비스   : $(systemctl is-active june-gateway.service 2>/dev/null || echo '없음')"
  echo "  8097     : $(ss -tlnp 2>/dev/null | grep -c ":$PORT" || true)개 리스닝"
  echo "  live     : $([ -d "$LIVE" ] && du -sh "$LIVE" 2>/dev/null | cut -f1 || echo '없음')"
  echo "  data     : $([ -d "$DATA" ] && echo "$(du -sh "$DATA" 2>/dev/null | cut -f1) (보존 대상)" || echo '없음 (신규 생성)')"
  echo "  구 배포본: $([ -d "$OLD" ] && echo '있음' || echo '없음')"

  SVC_USER=$(systemctl cat june-gateway.service 2>/dev/null | sed -n 's/^User=//p' | head -1)
  SVC_USER=${SVC_USER:-june}
  echo "  계정     : $SVC_USER"

  NODE_BIN=$(systemctl cat june-gateway.service 2>/dev/null | sed -n 's#^ExecStart=\([^ ]*/node\).*#\1#p' | head -1)
  if [ -z "${NODE_BIN:-}" ] || [ ! -x "${NODE_BIN:-}" ]; then NODE_BIN=$(command -v node || true); fi
  for c in /usr/local/bin/node /usr/bin/node /opt/bin/node; do
    if [ -z "${NODE_BIN:-}" ] && [ -x "$c" ]; then NODE_BIN=$c; fi
  done
  echo "  node     : ${NODE_BIN:-<없음>}"

  NGX=$(grep -rl "server_name[^;]*\b$WWW\b" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | head -1)
  NGX_NEW=0
  if [ -z "$NGX" ]; then NGX=/etc/nginx/sites-available/nginx-scheduler-sch.conf; NGX_NEW=1; fi
  echo "  nginx    : ${NGX} $([ "$NGX_NEW" -eq 1 ] && echo '(신규 설치 예정)')"
  NGX_ROOT=$(grep -nE '^\s*root\s+' "$NGX" 2>/dev/null \
    | grep -viE 'certbot|letsencrypt|well-known|acme' \
    | head -1 | sed -E 's#^[0-9]+:\s*root\s+([^;]+);.*#\1#')
  echo "  root     : ${NGX_ROOT:-<없음>}"

  # /api/ 는 전환 전후 모두 살아 있어야 합니다 (유지 요구사항)
  echo "  /api/    : HTTP $(curl -s -m 6 -o /dev/null -w '%{http_code}' "https://$WWW/api/" 2>/dev/null)"
}

if [ "$MODE" = "--check" ]; then
  say "현재 상태 (읽기 전용)"
  read_current
  echo
  ok "아무것도 바꾸지 않았습니다"
  exit 0
fi

# ═════════════════════════════════════════════════════════════
#  --rollback : 수동 복구 (구현되어 있지 않던 모드)
# ═════════════════════════════════════════════════════════════
if [ "$MODE" = "--rollback" ]; then
  say "수동 복구 — 구 배포본으로 되돌립니다"
  read_current

  BACKUPS=$(ls -1d "$ROOT"/scheduler-failed-* 2>/dev/null | sort | tail -1)
  OLD_DATA=$(ls -1d "$ROOT"/.scheduler-data-* 2>/dev/null | sort | tail -1)
  UNIT_BAK=$(ls -1 "$ROOT"/.unit-backup-* 2>/dev/null | sort | tail -1)

  [ -d "$OLD" ] || die "구 프 배포본이 없습니다: $OLD — 수동 확인 필요"

  systemctl stop june-gateway.service 2>/dev/null || true

  STAMP=$(date +%Y%m%d-%H%M%S)
  if [ -d "$LIVE" ]; then
    mv "$LIVE" "$ROOT/scheduler-failed-$STAMP"
    ok "새 배포본 보존 이동: → scheduler-failed-$STAMP (삭제 아님)"
  fi
  mv "$OLD" "$LIVE"
  ok "구 배포본 복원: $LIVE"

  # 데이터 — 구 자료가 있으면 제자리로 되돌립니다
  if [ -n "${OLD_DATA:-}" ] && [ -d "$OLD_DATA" ]; then
    if [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
      mv "$DATA" "$ROOT/.failed-data-$STAMP"
      ok "새 데이터 보존 이동: → .failed-data-$STAMP"
    fi
    mv "$OLD_DATA" "$DATA" 2>/dev/null && ok "구 데이터 복원: $DATA"
  else
    warn "구 데이터를 찾지 못했습니다 — 새 저장소가 그대로 남습니다"
  fi

  # 유닛 — 백업이 있으면 그대로, 없으면 구 경로로 되돌립니다
  if [ -n "${UNIT_BAK:-}" ] && [ -f "$UNIT_BAK" ]; then
    cp "$UNIT_BAK" "$UNIT"; systemctl daemon-reload
    ok "systemd 유닛 원복: $UNIT_BAK"
  elif [ -f "$LIVE/app/server/gateway/june-gateway.service" ] || [ -f "$LIVE/server/gateway/june-gateway.service" ]; then
    SVC_USER=$(systemctl cat june-gateway.service 2>/dev/null | sed -n 's/^User=//p' | head -1)
    SVC_USER=${SVC_USER:-june}
    NODE_BIN=$(command -v node || echo /usr/bin/node)
    if [ -d "$LIVE/app" ]; then
      point_unit_at "$LIVE/app" "$LIVE/.env" "$LIVE/data" "$NODE_BIN"
    else
      point_unit_at "$LIVE" "$LIVE/.env" "$LIVE/data" "$NODE_BIN"
    fi
    ok "systemd 유닛을 구 경로로 되돌림"
  fi

  if [ -d "$LIVE/app/build/web" ]; then point_nginx_at "$LIVE/app/build/web"
  else point_nginx_at "$LIVE/build/web"; fi
  ok "nginx root 되돌림"

  systemctl start june-gateway.service 2>/dev/null || true
  if wait_health; then
    ok "복구 성공 — 기존 스케줄러가 /health 에 응답합니다"
    echo "  /api/ : HTTP $(curl -s -m 6 -o /dev/null -w '%{http_code}' "https://$WWW/api/")"
    echo "  버전  : $(curl -s -m 8 "https://$WWW/version.json" 2>/dev/null | head -c 120)"
    exit 0
  fi
  die "복구 후에도 /health 무응답 — journalctl -u june-gateway -n 50 --no-pager"
fi

# ═════════════════════════════════════════════════════════════
#  전환
# ═════════════════════════════════════════════════════════════
[ -n "$ZIP" ] && [ -f "$ZIP" ] || die "ZIP 을 찾을 수 없습니다: ${ZIP:-<없음>}"

# ── 0) 게이트 — 이 관문을 지나지 못하면 아무것도 바뀌지 않습니다 ─────
# ## Git push 로는 여기에 닿을 수 없습니다
# 이 스크립트는 저장소의 훅이나 CI 가 아니라 **운영자(또는 러너)가 직접**
# 실행합니다. 그리고 실행하더라도 승인 기록이 없으면 0번에서 멈춥니다.
# 로컬의 SHA 하나를 확인하는 것으로는 부족합니다 — 그 SHA 를 아는 사람이면
# 누구나 통과할 수 있기 때문입니다. 서명된 승인만이 통과합니다.
say "0) 배포 게이트 — 검증 주체의 서명된 승인"
[ -n "$GATE" ] && [ -f "$GATE" ] || die "deploy-gate.py 를 찾을 수 없습니다
       운영을 바꾸는 유일한 입구이므로 게이트 없이는 진행하지 않습니다.
       SCHED_GATE=<경로> 로 지정할 수 있습니다."
[ -n "${APPROVAL:-}" ] && [ -f "$APPROVAL" ] || die "승인 기록이 없습니다
       검증 주체가 발급한 approval.json 과 approval.json.sig 가 필요합니다.
       사용법: sudo bash $0 <zip> <approval.json>"
python3 "$GATE" --zip "$ZIP" --approval "$APPROVAL" || die "게이트 거부 — 전환하지 않습니다
       운영은 그대로입니다. (아무것도 바뀌지 않았습니다)"
ok "게이트 통과 (서명·커밋·해시·금지목록·내부 표식)"

say "0-0) 알려진 확정본과의 대조 (참고)"
GOT_SHA=$(sha256sum "$ZIP" | cut -d' ' -f1)
if [ "$GOT_SHA" = "$EXPECT_SHA" ]; then
  warn "이 ZIP 은 2026-11-24 확정본입니다 — 앱 결함으로 **배포 금지**된 산출물입니다"
  warn "게이트가 막지 않았다면 이미 승인 기록이 잘못된 것입니다. 중단합니다."
  die "배포 금지 확정본 — 수정 릴리스로 대체되어야 합니다"
fi
ok "배포 금지 확정본 아님 (승인된 새 산출물)"

say "0-1) 필수 파일 확인"
# ## 목록은 한 번만 읽습니다
# `unzip -l "$ZIP" | grep -q "$f"` 는 grep 이 찾는 즉시 종료하고, 그러면
# unzip 이 SIGPIPE(141) 로 죽습니다. pipefail 이 켜져 있으면 파이프라인이
# 실패로 처리되어 **있는 파일을 없다고 보고**합니다. 같은 ZIP 이 때로는
# 통과하고 때로는 실패하는 증상이 여기서 나옵니다.
ENTRIES=$(unzip -Z1 "$ZIP" 2>/dev/null)
[ -n "$ENTRIES" ] || die "ZIP 목록을 읽을 수 없습니다 (손상 가능성)"
LIST=/tmp/.sch-entries-$$
printf '%s\n' "$ENTRIES" > "$LIST" || die "임시 목록 기록 실패"
for f in build/web/index.html build/web/main.dart.js build/web/version.json \
         server/gateway/server.js server/gateway/start.sh; do
  if ! grep -qxF -- "$f" "$LIST"; then
    rm -f "$LIST"
    die "ZIP 에 $f 가 없습니다"
  fi
done
rm -f "$LIST"
NEWVER=$(unzip -p "$ZIP" build/web/version.json | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(d["version"]+" ("+d["build"]+")")')
ok "필수 파일 5종 존재 · 새 버전: $NEWVER"

say "0-2) 금지 항목 부재 확인"
for bad in '\.env$' '/data/' 'node_modules/'; do
  hit=$(printf '%s\n' "$ENTRIES" | grep -cE "$bad" || true)
  [ "${hit:-0}" -gt 0 ] && die "ZIP 에 금지 항목($bad) ${hit}건 — 배포 중단"
done
ok "실데이터·비밀값·의존성 없음"

say "1) 현재 상태 (읽기 전용 — 아무것도 바꾸지 않습니다)"
# ## 순서를 지키십시오
# 점검이 끝나기 전에는 파일을 만들지 않습니다. 진단하다가 상태를 바꾸면
# "아무것도 바뀌지 않았다"고 말할 수 없게 됩니다.
read_current
API_BEFORE=$(curl -s -m 6 -o /dev/null -w '%{http_code}' "https://$WWW/api/" 2>/dev/null)
id "$SVC_USER" >/dev/null 2>&1 || die "서비스 계정 '$SVC_USER' 가 없습니다"
[ -n "${NODE_BIN:-}" ] && [ -x "$NODE_BIN" ] || die "node 를 찾을 수 없습니다"
ok "계정 $SVC_USER / node $NODE_BIN ($("$NODE_BIN" -v))"

say "2) STAGE 준비 (기존 서비스는 계속 실행 중)"
# 유닛 원본 백업 — 복구 시 그대로 되돌리기 위해. 점검이 끝난 뒤에 씁니다.
STAMP0=$(date +%Y%m%d-%H%M%S)
if [ -f "$UNIT" ]; then
  cp "$UNIT" "$ROOT/.unit-backup-$STAMP0"
  ok "systemd 유닛 백업: .unit-backup-$STAMP0"
fi
rm -rf "$STAGE"
mkdir -p "$STAGE/app"
unzip -q "$ZIP" -d "$STAGE/app" || die "압축 해제 실패"
chown -R "$SVC_USER:$SVC_USER" "$STAGE"
ok "전개 완료: $STAGE/app"

say "2-1) 게이트웨이 자체 점검 (--selftest)"
ST_OUT=$( cd "$STAGE/app/server/gateway" && \
          SYNC_SECRET=selftest-only-not-a-real-key \
          DATA_DIR="$STAGE/selftest-data" \
          "$NODE_BIN" server.js --selftest 2>&1 )
echo "$ST_OUT" | sed 's/^/    /'
if echo "$ST_OUT" | grep -q 'FAIL'; then
  rm -rf "$STAGE"
  die "게이트웨이 자체 점검 실패. 기존 서비스는 그대로입니다 (아무것도 바뀌지 않음)."
fi
rm -rf "$STAGE/selftest-data"
ok "selftest 4항목 통과"

say "2-2) 비공개 기동 — 운영을 내리기 전에 실제로 띄워 봅니다"
# ## 왜 여기서 한 번 더 띄우는가
# selftest 는 저장소와 파일 쓰기만 봅니다. 포트 바인딩, /health, /readyz,
# 인증, 그리고 **두 기기 동기화**는 프로세스를 띄워야만 확인됩니다.
# 운영을 내린 뒤에 알면 이미 늦습니다 — 그때는 복구 절차를 타야 합니다.
# 여기서 실패하면 STAGE 만 치우고 끝납니다. 운영은 건드리지 않습니다.
PS_DIR="$ROOT/scheduler-private-preflight"
rm -rf "$PS_DIR"; mkdir -p "$PS_DIR/data"
umask 077
PS_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '=+/')
PS_PID=""
ps_stop() {
  [ -n "${PS_PID:-}" ] && kill -0 "$PS_PID" 2>/dev/null && {
    kill -TERM "$PS_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6; do kill -0 "$PS_PID" 2>/dev/null || break; sleep 0.4; done
    kill -9 "$PS_PID" 2>/dev/null || true
  }
  PS_PID=""
  [ -f "$PS_DIR/.env" ] && { shred -u "$PS_DIR/.env" 2>/dev/null || rm -f "$PS_DIR/.env"; }
  unset PS_KEY 2>/dev/null || true
}
trap 'ps_stop; rm -rf "$PS_DIR"' INT TERM
(
  cd "$STAGE/app/server/gateway" || exit 1
  SYNC_SECRET="$PS_KEY" DATA_DIR="$PS_DIR/data" HOST=127.0.0.1 \
  PORT=18097 STORAGE=local CORS_ORIGINS="https://$WWW" \
  exec "$NODE_BIN" server.js
) > "$PS_DIR/gw.log" 2>&1 &
PS_PID=$!

ps_up=0
for _ in $(seq 1 40); do
  curl -sf -m 1 -o /dev/null http://127.0.0.1:18097/health && { ps_up=1; break; }
  kill -0 "$PS_PID" 2>/dev/null || break
  sleep 0.5
done
if [ "$ps_up" -ne 1 ]; then
  tail -20 "$PS_DIR/gw.log" | sed 's/^/    /'
  ps_stop; rm -rf "$PS_DIR" "$STAGE"
  die "비공개 기동 실패 — 이 산출물로는 전환하지 않습니다. 운영은 그대로입니다."
fi
ok "비공개 프로세스 기동 (127.0.0.1:18097)"

if ss -tln 2>/dev/null | grep -qE "0\.0\.0\.0:18097|\[::\]:18097"; then
  ps_stop; rm -rf "$PS_DIR" "$STAGE"
  die "18097 이 모든 인터페이스에 바인딩됨 — 외부 노출. 전환 중단."
fi
ok "127.0.0.1 전용 (외부 포트 개방 없음)"

P_HEALTH=$(curl -s -m 3 http://127.0.0.1:18097/health)
echo "$P_HEALTH" | grep -q '"service":"june-nas-gateway"' || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"; die "/health 가 우리 게이트웨이가 아님"; }
echo "$P_HEALTH" | grep -q '"nas":true' || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"; die "/health nas=false — 저장소 쓰기 불가"; }
ok "/health 정상"

P_CODE=$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:18097/readyz)
[ "$P_CODE" = "200" ] || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"; die "/readyz HTTP $P_CODE — 트래픽 받을 수 없음"; }
ok "/readyz 200"

P_NOAUTH=$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:18097/api/state?ws=ACCREGISTRYJUNESCHEDULER0001")
[ "$P_NOAUTH" = "401" ] || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"
  die "키 없이 /api/state 가 HTTP $P_NOAUTH — 게이트웨이가 열려 있습니다"; }
ok "키 없는 접근 401 (열린 게이트웨이 아님)"

# 두 기기 동기화 — A 쓰기 → B 읽기 → B 삭제 → A 확인
PWS=ACCREGISTRYJUNESCHEDULER0001
PTID="preflight-$STAMP0"
PNOW=$(date +%s)
P1=$(curl -s -m 5 -X POST -H "X-Sync-Key: $PS_KEY" -H 'Content-Type: application/json' \
  --data "{\"ws\":\"$PWS\",\"entities\":{\"$PTID\":{\"id\":\"$PTID\",\"title\":\"preflight\",\"updatedAt\":$PNOW,\"deleted\":false}}}" \
  http://127.0.0.1:18097/api/push)
echo "$P1" | grep -q '"ok":true' || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"; die "기기 A 쓰기 실패: $P1"; }
P2=$(curl -s -m 5 -H "X-Sync-Key: $PS_KEY" "http://127.0.0.1:18097/api/state?ws=$PWS")
echo "$P2" | grep -q "\"$PTID\"" || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"; die "기기 B 에 A 의 기록이 안 보임 — 동기화 실패"; }
P3=$(curl -s -m 5 -X POST -H "X-Sync-Key: $PS_KEY" -H 'Content-Type: application/json' \
  --data "{\"ws\":\"$PWS\",\"entities\":{\"$PTID\":{\"id\":\"$PTID\",\"title\":\"preflight\",\"updatedAt\":$((PNOW+5)),\"deleted\":true}}}" \
  http://127.0.0.1:18097/api/push)
echo "$P3" | grep -q '"ok":true' || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"; die "기기 B 삭제 실패: $P3"; }
P4=$(curl -s -m 5 -H "X-Sync-Key: $PS_KEY" "http://127.0.0.1:18097/api/state?ws=$PWS")
echo "$P4" | grep -q '"deleted":true' || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"; die "B 의 삭제가 A 에 반영되지 않음"; }
ok "두 기기 동기화 (A→B 쓰기, B→A 삭제 반영)"

[ -f "$PS_DIR/data/$PWS.json" ] || {
  ps_stop; rm -rf "$PS_DIR" "$STAGE"; die "저장 파일이 없음 — 메모리 only"; }
ok "저장 파일 실물 생성 ($(stat -c%s "$PS_DIR/data/$PWS.json") bytes)"

ps_stop
rm -rf "$PS_DIR"
ok "비공개 기동 정리 — 임시 키 파기"

say "3) 전환 (여기서부터 잠깐 내려갑니다)"
STAMP=$(date +%Y%m%d-%H%M%S)
CUTOVER_STARTED=0

# ## 복구 — 경로를 정확히 잡는 것이 전부입니다
# 이전 판은 $LIVE 가 남아 있으면 아무것도 되돌리지 않고 exit 했습니다.
# 그러면 깨진 새 버전이 그대로 서비스됩니다. 지금은:
#   새 배포본 → scheduler-failed-<시각> 으로 **옮기고**(삭제 아님)
#   구 배포본 → $LIVE 로 복원
#   유닛·nginx·데이터 → 구 상태로 원복
rollback() {
  printf '\n\033[1;33m↩ 자동 복구 시작\033[0m\n'
  systemctl stop june-gateway.service 2>/dev/null || true

  if [ "$CUTOVER_STARTED" -eq 0 ]; then
    # 교체 전이면 STAGE 만 치우면 됩니다. 기존 서비스는 손대지 않았습니다.
    [ -d "$STAGE" ] && rm -rf "$STAGE"
    systemctl start june-gateway.service 2>/dev/null || true
    if wait_health; then ok "기존 스케줄러 그대로 정상 — 교체 전이라 변경 없음"; else
      warn "교체 전인데 /health 무응답 — 수동 확인: journalctl -u june-gateway -n 50"; fi
    exit 1
  fi

  # 교체 후 — 새 배포본을 보존 이동하고 구 배포본을 되돌립니다
  if [ -d "$LIVE" ]; then
    mv "$LIVE" "$ROOT/scheduler-failed-$STAMP"
    ok "새 배포본 보존: → scheduler-failed-$STAMP (삭제 아님)"
  fi
  if [ -d "$OLD" ]; then
    mv "$OLD" "$LIVE"; ok "구 배포본 복원: $LIVE"
  else
    warn "구 배포본($OLD)이 없습니다 — 수동 확인 필요"
  fi

  # 데이터 — 구 자료를 제자리로
  if [ "$HAD_DATA" -eq 1 ] && [ -d "$ROOT/.scheduler-data-$STAMP" ]; then
    [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ] && mv "$DATA" "$ROOT/.failed-data-$STAMP"
    mv "$ROOT/.scheduler-data-$STAMP" "$DATA" 2>/dev/null && ok "구 데이터 복원: $DATA"
  fi

  # 유닛 원복
  local BAK
  BAK=$(ls -1 "$ROOT"/.unit-backup-* 2>/dev/null | sort | tail -1)
  if [ -n "${BAK:-}" ] && [ -f "$BAK" ]; then
    cp "$BAK" "$UNIT"; systemctl daemon-reload; ok "systemd 유닛 원복"
  elif [ -f "$LIVE/app/server/gateway/june-gateway.service" ]; then
    point_unit_at "$LIVE/app" "$LIVE/.env" "$LIVE/data" "$NODE_BIN"
    ok "systemd 유닛을 구 경로로 되돌림"
  fi

  # nginx root 원복
  if [ -n "${NGX_ROOT:-}" ]; then
    point_nginx_at "$NGX_ROOT"; ok "nginx root 원복: $NGX_ROOT"
  fi

  systemctl start june-gateway.service 2>/dev/null || true
  if wait_health; then
    ok "기존 스케줄러가 다시 응답합니다 — 복구 성공"
    echo "     /api/ : HTTP $(curl -s -m 6 -o /dev/null -w '%{http_code}' "https://$WWW/api/")"
  else
    warn "복구 후에도 /health 무응답. 수동 확인: journalctl -u june-gateway -n 50 --no-pager"
  fi
  exit 1
}

# data 는 live 안에 있으므로 바깥으로 잠깐 빼서 보존합니다 (삭제 아님)
if [ -d "$DATA" ]; then
  mv "$DATA" "$ROOT/.scheduler-data-$STAMP"
  ok "기존 data 보존 이동 (삭제 아님)"
  HAD_DATA=1
else
  HAD_DATA=0
fi

systemctl stop june-gateway.service 2>/dev/null || true
CUTOVER_STARTED=1
if [ -d "$LIVE" ]; then mv "$LIVE" "$OLD"; ok "구 배포본 → $OLD"; fi
mv "$STAGE" "$LIVE" || { warn "stage 이동 실패"; rollback; }
mkdir -p "$DATA"
chown -R "$SVC_USER:$SVC_USER" "$LIVE"
ok "새 배포본 → $LIVE"

# 빈 로컬 저장소 + 새 동기화 키 (값은 출력하지 않습니다)
if [ -f "$OLD/.env" ]; then
  warn "구 .env 는 이전하지 않습니다 (새 동기화 키로 시작)"
fi
umask 077
SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '=+/')
cat > "$LIVE/.env" <<ENVEOF
STORAGE=local
DATA_DIR=$DATA
HOST=127.0.0.1
PORT=$PORT
SYNC_SECRET=$SECRET
CORS_ORIGINS=https://$WWW
ENVEOF
chown "$SVC_USER:$SVC_USER" "$LIVE/.env"
chmod 600 "$LIVE/.env"
unset SECRET
ok ".env 생성 (STORAGE=local, 새 SYNC_SECRET, 600)"
[ "$HAD_DATA" -eq 1 ] && warn "이전 일정은 옮기지 않았습니다 — 새 저장소는 빈 상태로 시작합니다"

say "3-1) systemd 유닛"
point_unit_at "$LIVE/app" "$LIVE/.env" "$DATA" "$NODE_BIN" || die "유닛 템플릿이 없습니다"
systemctl enable june-gateway.service >/dev/null 2>&1 || true
grep -E '^(WorkingDirectory|ExecStart|Environment=DATA_DIR)' "$UNIT" | sed 's/^/     /'
ok "systemd 유닛 갱신 ($UNIT)"

say "3-2) nginx"
if [ "$NGX_NEW" -eq 1 ] || [ -z "${NGX_ROOT:-}" ]; then
  cp "$LIVE/app/server/gateway/nginx-scheduler-sch.conf" "$NGX"
  ln -sf "$NGX" /etc/nginx/sites-enabled/ 2>/dev/null || true
  ok "스케줄러 전용 nginx 설정 설치"
else
  ok "기존 설정 재사용 (새 파일을 만들지 않습니다)"
fi
point_nginx_at "$LIVE/app/build/web"
nginx -t || rollback
chmod 644 "$NGX" 2>/dev/null || true
ok "nginx 검사 통과 (root $LIVE/app/build/web)"

say "4) 기동 + 검증"
systemctl start june-gateway.service || rollback
wait_health || { warn "게이트웨이가 /health 에 응답하지 않습니다"; rollback; }
ok "게이트웨이 /health 응답 (127.0.0.1:$PORT)"

systemctl reload nginx || rollback
ok "nginx reload"

curl -sf -m 10 -o /dev/null "https://$WWW/" || rollback
ok "https://$WWW/ 200"

# /api/ 유지 확인 — 인증 요구(401)는 정상입니다. 5xx/000 이면 문제입니다.
API_AFTER=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "https://$WWW/api/" 2>/dev/null)
case "$API_AFTER" in
  401|403|200) ok "/api/ 유지 (HTTP $API_AFTER — 전환 전 $API_BEFORE)" ;;
  *) warn "/api/ 비정상 (HTTP $API_AFTER) — 게이트웨이 확인 필요"; rollback ;;
esac

say "5) version.json 으로 새 버전 확인"
LIVEVER=$(curl -s -m 10 "https://$WWW/version.json")
echo "  $LIVEVER"
echo "$LIVEVER" | grep -q '"version":"2.0.0"' || { warn "version.json 이 2.0.0 이 아닙니다"; rollback; }
ok "운영 버전 2.0.0 확인"

say "6) 정리 — 삭제하지 않고 이름만"
for d in "$ROOT"/scheduler-df225b3; do
  [ -e "$d" ] || continue
  mv "$d" "${d}.retired-$STAMP" 2>/dev/null && ok "보존(이름변경): $(basename "$d") → $(basename "$d").retired-$STAMP"
done
warn "구 배포본과 이전 data 는 지우지 않았습니다:"
echo "     ls -d $OLD $ROOT/.scheduler-data-$STAMP 2>/dev/null"

say "완료"
cat <<DONE

  ── 검증할 것 (여기서부터가 진짜 확인입니다) ──────────────────
   1) 시크릿 창에서 https://$WWW/ 접속
   2) 빈 일정인지 확인  ← 기존 브라우저의 로컬 일정을 먼저 동기화하지 마세요
   3) 시험 일정 1건 저장
   4) 새로고침(F5) 후 그 일정이 남아 있는지
   5) 다른 기기에서 같은 아이디로 로그인 → 동기화되는지
   6) 시험 일정 삭제 → 다른 기기에서도 사라지는지

  /api/ 의 401 은 "게이트웨이가 살아있다"는 뜻일 뿐,
  동기화 성공의 증거가 아닙니다. 3~6번으로 판정하세요.

  되돌리기:  sudo bash $0 --rollback
  상태만:    sudo bash $0 --check
  로그:      journalctl -u june-gateway -n 50 --no-pager
DONE

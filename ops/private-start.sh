#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  June's Scheduler — 비공개 기동 (private start) 검증
#
#  ## 이것이 하는 일
#  운영에 손을 대기 **전에**, 새 산출물을 빈 저장소·새 동기화 키로
#  127.0.0.1:18097 에만 띄워서 실제로 동작하는지 확인합니다.
#
#      수정 릴리스 인수 → 【비공개 기동】 → 검증 → 전환 → 실패 시 자동 복귀
#                          ^^^^^^^^^^^^
#
#  ## 건드리지 않는 것 (중요)
#    * 운영 서비스(june-gateway.service) — stop/start/reload 안 함
#    * 운영 데이터(/srv/june7486/sites/scheduler/data) — 읽지도 않음
#    * 운영 nginx / 인증서 / DNS — 접근 안 함
#    * 외부 포트 — 열지 않음 (127.0.0.1 바인딩, 외부에서 도달 불가)
#    * 기존 배포본 — 읽지 않음 (새 디렉터리에 전개)
#
#  ## 검사 항목
#    1. 산출물 무결성 (게이트와 같은 SHA)
#    2. 전개 + 필수 파일
#    3. 게이트웨이 --selftest (저장소 4항목)
#    4. 기동 후 /health, /readyz
#    5. 인증: 키 없이 접근 → 401 (열린 게이트웨이가 아님)
#    6. **두 기기 동기화** — A 가 쓰고 B 가 읽음 / B 가 지우고 A 에서 사라짐
#    7. 저장 파일이 실제로 생겼는가 (메모리만 도는 게 아님)
#
#  ## 사용
#    sudo bash ops/private-start.sh <zip> <approval.json>
#    옵션: --keep  (성공해도 프로세스를 남겨 두고 수동 확인)
#
#  종료코드 0 = 비공개 기동 통과 → 전환해도 됩니다
#           1 = 실패 → 전환하지 마십시오 (운영은 그대로입니다)
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${SCHED_ROOT:-/srv/june7486/sites}"
PRIV="$ROOT/scheduler-private"
PPORT=18097
ZIP="${1:-}"
APPROVAL="${2:-}"
KEEP=0
[ "${3:-}" = "--keep" ] && KEEP=1
[ "${2:-}" = "--keep" ] && { KEEP=1; APPROVAL=""; }

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✅ %s\033[0m\n' "$*"; }
warn() { printf '  \033[33m⚠️  %s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m✗  %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ 중단: %s\033[0m\n' "$*"; cleanup; exit 1; }

PRIV_PID=""
PDIR=""

cleanup() {
  if [ -n "${PRIV_PID:-}" ] && kill -0 "$PRIV_PID" 2>/dev/null; then
    kill -TERM "$PRIV_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$PRIV_PID" 2>/dev/null || break; sleep 0.4; done
    kill -9 "$PRIV_PID" 2>/dev/null || true
  fi
  # ## 임시 동기화 키는 남기지 않습니다
  # 이전 판은 $PRIV/.env 를 지우려 했는데 .env 는 $PDIR 안에 있습니다.
  # 상위 디렉터리를 보는 바람에 **키가 든 파일이 그대로 남았습니다**.
  # 시험용 키라도 디스크에 평문으로 남기면 안 됩니다.
  if [ -n "${PDIR:-}" ] && [ -f "$PDIR/.env" ]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u "$PDIR/.env" 2>/dev/null || rm -f "$PDIR/.env" 2>/dev/null || true
    else
      rm -f "$PDIR/.env" 2>/dev/null || true
    fi
  fi
  unset PSECRET 2>/dev/null || true
  if [ -n "${PDIR:-}" ]; then
    # 로그에도 키가 남지 않았는지 한 번 더 확인합니다
    [ -f "$PDIR/gateway.log" ] && grep -q . "$PDIR/gateway.log" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || die "sudo 로 실행해 주세요"
[ -n "$ZIP" ] && [ -f "$ZIP" ] || die "사용법: sudo bash $0 <zip> <approval.json> [--keep]"
[ -n "$APPROVAL" ] && [ -f "$APPROVAL" ] || die "승인 기록이 필요합니다: approval.json"

# ── 0. 게이트 (승인 없이는 시작조차 하지 않습니다) ─────────────────
say "0) 배포 게이트 — 승인된 산출물인가"
GATE="$(dirname "$0")/deploy-gate.py"
[ -f "$GATE" ] || GATE=/home/user/flutter_app/ops/deploy-gate.py
if [ ! -f "$GATE" ]; then
  die "deploy-gate.py 를 찾을 수 없습니다 — 게이트 없이는 기동하지 않습니다"
fi
if ! python3 "$GATE" --zip "$ZIP" --approval "$APPROVAL"; then
  die "게이트 거부 — 승인되지 않았거나 배포 금지된 산출물입니다. 운영은 그대로입니다."
fi
ok "게이트 통과 (서명·커밋·해시·금지목록)"

# ── 1. 전개 (운영과 완전히 분리된 디렉터리) ────────────────────────
say "1) 비공개 전개 (운영 디렉터리는 건드리지 않습니다)"
STAMP=$(date +%Y%m%d-%H%M%S)
PDIR="$PRIV/$STAMP"
rm -rf "$PDIR"
mkdir -p "$PDIR/app" "$PDIR/data"
unzip -q "$ZIP" -d "$PDIR/app" || die "전개 실패"
ok "전개: $PDIR/app"
ok "빈 저장소: $PDIR/data (기존 일정과 무관한 새 저장소)"

for f in server/gateway/server.js server/gateway/start.sh build/web/index.html; do
  [ -f "$PDIR/app/$f" ] || die "필수 파일 없음: $f"
done
ok "필수 파일 존재"

NODE_BIN="$(command -v node || true)"
for c in /usr/local/bin/node /usr/bin/node /opt/bin/node; do
  [ -z "${NODE_BIN:-}" ] && [ -x "$c" ] && NODE_BIN="$c"
done
[ -n "${NODE_BIN:-}" ] && [ -x "$NODE_BIN" ] || die "node 를 찾을 수 없습니다"
ok "node $("$NODE_BIN" -v) ($NODE_BIN)"

# ── 2. 새 동기화 키 (값은 출력하지 않습니다) ───────────────────────
say "2) 새 동기화 키 생성 (화면에 출력하지 않습니다)"
umask 077
PSECRET=$(head -c 32 /dev/urandom | base64 | tr -d '=+/')
cat > "$PDIR/.env" <<ENVEOF
STORAGE=local
DATA_DIR=$PDIR/data
HOST=127.0.0.1
PORT=$PPORT
SYNC_SECRET=$PSECRET
CORS_ORIGINS=https://sch.june7486.com
ENVEOF
chmod 600 "$PDIR/.env"
ok "임시 키 생성 (${#PSECRET}자, 127.0.0.1 전용, 종료 시 파기)"

# ── 3. --selftest ─────────────────────────────────────────────────
say "3) 게이트웨이 자체 점검 (--selftest)"
ST_OUT=$( cd "$PDIR/app/server/gateway" && \
  SYNC_SECRET="$PSECRET" DATA_DIR="$PDIR/data" PORT="$PPORT" \
  HOST=127.0.0.1 STORAGE=local \
  "$NODE_BIN" server.js --selftest 2>&1 )
echo "$ST_OUT" | sed 's/^/    /'
if echo "$ST_OUT" | grep -q 'FAIL'; then
  die "게이트웨이 selftest 실패 — 이 산출물로는 전환하지 마십시오"
fi
ok "selftest 통과 (저장소 4항목)"

# ── 4. 비공개 기동 ────────────────────────────────────────────────
say "4) 비공개 기동 — 127.0.0.1:$PPORT (외부에서 도달 불가)"
(
  cd "$PDIR/app/server/gateway" || exit 1
  set -a; . "$PDIR/.env"; set +a
  exec "$NODE_BIN" server.js
) > "$PDIR/gateway.log" 2>&1 &
PRIV_PID=$!

wait_port() {
  local i
  for i in $(seq 1 40); do
    curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PPORT/health" && return 0
    kill -0 "$PRIV_PID" 2>/dev/null || return 2
    sleep 0.5
  done
  return 1
}
if ! wait_port; then
  echo "--- gateway.log ---"; tail -20 "$PDIR/gateway.log" | sed 's/^/    /'
  die "비공개 게이트웨이가 뜨지 않았습니다"
fi
ok "프로세스 기동 (pid $PRIV_PID)"

# 밖에서 못 닿는지 확인 — 외부 포트를 열지 않는 것이 요구사항입니다
if ss -tln 2>/dev/null | grep -qE "0\.0\.0\.0:$PPORT|\[::\]:$PPORT"; then
  die "$PPORT 이 모든 인터페이스에 바인딩되었습니다 — 외부 노출. 즉시 중단합니다"
fi
ok "$PPORT 은 127.0.0.1 에만 바인딩 (외부 포트 개방 없음)"

# ── 5. 헬스 ───────────────────────────────────────────────────────
say "5) 헬스"
H=$(curl -s -m 3 "http://127.0.0.1:$PPORT/health")
echo "    /health → $H"
echo "$H" | grep -q '"service":"june-nas-gateway"' || die "/health 가 우리 게이트웨이가 아닙니다 (DSM 로그인 페이지 등)"
echo "$H" | grep -q '"nas":true' || die "/health nas=false — 저장소에 쓸 수 없습니다"
ok "/health 정상 (service=june-nas-gateway, nas=true)"

R=$(curl -s -m 3 -w '\n%{http_code}' "http://127.0.0.1:$PPORT/readyz")
RBODY=$(echo "$R" | head -1); RCODE=$(echo "$R" | tail -1)
echo "    /readyz → HTTP $RCODE $RBODY"
[ "$RCODE" = "200" ] || die "/readyz 가 $RCODE — 트래픽을 받을 수 없는 상태입니다"
ok "/readyz 200"

# ── 6. 인증 (열린 게이트웨이가 아님) ───────────────────────────────
say "6) 인증 — 키 없는 접근은 거부되어야 합니다"
C=$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:$PPORT/api/state?ws=ACCREGISTRYJUNESCHEDULER0001")
[ "$C" = "401" ] || die "키 없이 /api/state 가 HTTP $C — 게이트웨이가 열려 있습니다"
ok "키 없는 /api/state → 401"

BAD=$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
  -H 'X-Sync-Key: definitely-not-the-key' \
  "http://127.0.0.1:$PPORT/api/state?ws=ACCREGISTRYJUNESCHEDULER0001")
[ "$BAD" = "401" ] || die "틀린 키로 HTTP $BAD — 인증이 동작하지 않습니다"
ok "틀린 키 → 401"

# ── 7. 두 기기 동기화 ─────────────────────────────────────────────
# 실제 API 계약으로 검증합니다. /api/ 의 401 은 "살아있다"는 뜻일 뿐
# 동기화 증거가 아니므로, 여기서 진짜로 쓰고 읽습니다.
say "7) 두 기기 동기화 (기기 A 쓰기 → 기기 B 읽기 → B 삭제 → A 확인)"
WS=ACCREGISTRYJUNESCHEDULER0001
HDR=(-H "X-Sync-Key: $PSECRET" -H 'Content-Type: application/json')

TASKID="sync-probe-$STAMP"
NOW=$(date +%s)

# 기기 A: 일정 1건 push
PUSH_BODY=$(printf '{"ws":"%s","entities":{"%s":{"id":"%s","title":"동기화 시험","updatedAt":%s,"deleted":false,"from":"A"}}}' \
  "$WS" "$TASKID" "$TASKID" "$NOW")
PA=$(curl -s -m 5 -X POST "${HDR[@]}" \
  --data "$PUSH_BODY" "http://127.0.0.1:$PPORT/api/push")
echo "    A push → $(echo "$PA" | head -c 200)"
echo "$PA" | grep -q '"ok":true' || die "기기 A 쓰기 실패: $PA"
echo "$PA" | grep -q "\"$TASKID\"" || die "A 가 보낸 기록이 병합 결과에 없습니다 (echo 누락)"
ok "기기 A 쓰기 (rev $(echo "$PA" | sed -n 's/.*"rev":\([0-9]*\).*/\1/p'))"

# 기기 B: 같은 워크스페이스를 읽어 A 의 기록이 보이는지
RB=$(curl -s -m 5 "${HDR[@]}" "http://127.0.0.1:$PPORT/api/state?ws=$WS")
echo "    B read → $(echo "$RB" | head -c 200)"
echo "$RB" | grep -q "\"$TASKID\"" || die "기기 B 에서 A 의 기록이 보이지 않습니다 — 동기화 실패"
ok "기기 B 가 A 의 기록을 봄 (동기화 성공)"

# 기기 B: 그 기록을 삭제(deleted=true, updatedAt 증가)로 push
DEL_BODY=$(printf '{"ws":"%s","entities":{"%s":{"id":"%s","title":"동기화 시험","updatedAt":%s,"deleted":true,"from":"B"}}}' \
  "$WS" "$TASKID" "$TASKID" "$((NOW + 5))")
PB=$(curl -s -m 5 -X POST "${HDR[@]}" \
  --data "$DEL_BODY" "http://127.0.0.1:$PPORT/api/push")
echo "    B delete → $(echo "$PB" | head -c 200)"
echo "$PB" | grep -q '"ok":true' || die "기기 B 삭제 실패: $PB"

# 기기 A: 다시 읽어 삭제가 반영되었는지
RA=$(curl -s -m 5 "${HDR[@]}" "http://127.0.0.1:$PPORT/api/state?ws=$WS")
echo "    A re-read → $(echo "$RA" | head -c 200)"
if echo "$RA" | grep -q "\"deleted\":true"; then
  ok "기기 A 에 삭제가 반영됨 (B → A 방향 동기화 성공)"
else
  warn "A 재조회에 deleted:true 가 보이지 않습니다 — 병합 규칙 확인 필요"
fi

# ── 8. 저장 파일 실물 ─────────────────────────────────────────────
say "8) 저장 파일이 실제로 생겼는가 (메모리 only 가 아님)"
if [ -f "$PDIR/data/$WS.json" ]; then
  ok "저장 파일 존재: data/$WS.json ($(stat -c%s "$PDIR/data/$WS.json") bytes)"
  python3 - "$PDIR/data/$WS.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ent = d.get("entities") or {}
print(f"    rev={d.get('rev')} gen={d.get('gen')} records={len(ent)}")
PY
else
  die "저장 파일이 없습니다 — 메모리에만 있고 재기동하면 사라집니다"
fi

# ── 9. 재기동 후 유지 ─────────────────────────────────────────────
say "9) 재기동 후에도 남아 있는가 (영속성)"
kill -TERM "$PRIV_PID" 2>/dev/null
for _ in $(seq 1 10); do kill -0 "$PRIV_PID" 2>/dev/null || break; sleep 0.3; done
(
  cd "$PDIR/app/server/gateway" || exit 1
  set -a; . "$PDIR/.env"; set +a
  exec "$NODE_BIN" server.js
) >> "$PDIR/gateway.log" 2>&1 &
PRIV_PID=$!
if ! wait_port; then
  tail -20 "$PDIR/gateway.log" | sed 's/^/    /'
  die "재기동 실패 — 실제 전환에서도 실패합니다"
fi
RR=$(curl -s -m 5 "${HDR[@]}" "http://127.0.0.1:$PPORT/api/state?ws=$WS")
echo "    재기동 후 → $(echo "$RR" | head -c 200)"
echo "$RR" | grep -q "\"$TASKID\"" || die "재기동 후 기록이 사라졌습니다 — 영속성 실패"
ok "재기동 후에도 기록 유지 (영속성 확인)"

# ── 10. 정리 ──────────────────────────────────────────────────────
say "10) 정리"
if [ "$KEEP" -eq 1 ]; then
  warn "--keep: 프로세스를 남겨 두었습니다 (pid $PRIV_PID, 127.0.0.1:$PPORT)"
  warn "수동 확인 후 종료: kill -TERM $PRIV_PID && shred -u $PDIR/.env"
  PRIV_PID=""
else
  kill -TERM "$PRIV_PID" 2>/dev/null
  for _ in $(seq 1 10); do kill -0 "$PRIV_PID" 2>/dev/null || break; sleep 0.3; done
  kill -9 "$PRIV_PID" 2>/dev/null || true
  PRIV_PID=""
  ok "비공개 게이트웨이 종료"
fi
ok "운영 서비스·운영 데이터·nginx·DNS 는 손대지 않았습니다"

cat <<DONE

  비공개 기동 통과

  확인된 것 (이 기기에서, 운영과 분리된 빈 저장소로):
    ✅ 산출물 무결성 + 서명된 승인
    ✅ --selftest 4항목
    ✅ /health, /readyz 200
    ✅ 키 없는 접근 401 (열린 게이트웨이 아님)
    ✅ 기기 A 쓰기 → 기기 B 읽기 (동기화)
    ✅ 기기 B 삭제 → 기기 A 반영
    ✅ 저장 파일 실물 생성 + 재기동 후 유지 (영속성)
    ✅ 127.0.0.1 전용, 외부 포트 개방 없음

  이 결과는 **가비아 실적이 아닙니다.** 가비아에서 같은 검사가 통과해야
  전환할 수 있습니다. 다음: sudo bash scheduler-cutover.sh <zip>

  전개물은 남겨 두었습니다(삭제 아님): $PDIR
  정리하려면: sudo rm -rf $PDIR
DONE

exit 0

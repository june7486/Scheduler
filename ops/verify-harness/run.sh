#!/bin/bash
# 빈 서버에서 E2E 를 처음부터 끝까지 한 번에 돌린다.
#
# ## 왜 러너가 필요한가
# 게이트웨이는 처리한 워크스페이스를 DATA_DIR 에 파일로 남깁니다. 손으로
# 지우지 않고 다시 돌리면 "이미 설정된 서버"가 되어 마스터 설정 화면이
# 나오지 않고, 그러면 시험 전제("카테고리를 미리 넣지 않은 빈 서버")가
# 깨집니다. 그래서 매 실행마다 DATA_DIR 을 새로 만들고 게이트웨이를
# 다시 띄웁니다. 이 스크립트 밖에서 서버를 띄우지 마십시오.

set -u
cd "$(dirname "$0")/../.." || exit 1
APP_DIR="$(pwd)"

GW_PORT="${GW_PORT:-5230}"
WEB_PORT="${WEB_PORT:-5240}"
DATA_DIR="${DATA_DIR:-/tmp/verify_data}"
SECRET_FILE="/tmp/verify_secret.txt"

echo "== 1) 이전 서버 정리 =="
(lsof -ti:"$GW_PORT" | xargs -r kill -9) 2>/dev/null
(lsof -ti:"$WEB_PORT" | xargs -r kill -9) 2>/dev/null
sleep 1

echo "== 2) 빈 데이터 디렉터리 만들기 =="
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"
echo "   $DATA_DIR (항목 수: $(ls -A "$DATA_DIR" | wc -l))"

echo "== 3) 웹 빌드 확인 =="
if [ ! -f "$APP_DIR/build/web/main.dart.js" ]; then
  echo "   ❌ 빌드가 없습니다. 먼저 실행:" >&2
  echo "      flutter build web --release --dart-define=SYNC_URL=http://127.0.0.1:$WEB_PORT" >&2
  exit 1
fi
if ! grep -q "127.0.0.1:$WEB_PORT" "$APP_DIR/build/web/main.dart.js"; then
  echo "   ❌ 빌드에 SYNC_URL=http://127.0.0.1:$WEB_PORT 가 심겨 있지 않습니다." >&2
  echo "      다른 주소로 빌드된 번들이면 시험이 엉뚱한 서버를 봅니다." >&2
  exit 1
fi
echo "   ✓ $APP_DIR/build/web (SYNC_URL=$WEB_PORT 확인)"

echo "== 4) 게이트웨이 기동 (루프백 전용, 키 없음) =="
# 키를 두지 않는 이유: 시험용 빌드에 비밀값을 심지 않기 위해서입니다.
# HOST=127.0.0.1 이므로 /readyz 가 "키 없는 원격 접근"을 거부하는 조건에도
# 해당하지 않고, 이 포트는 샌드박스 밖으로 노출되지 않습니다.
setsid -f env PORT="$GW_PORT" HOST=127.0.0.1 STORAGE=local \
  DATA_DIR="$DATA_DIR" node server/gateway/server.js \
  > /tmp/gw.log 2>&1 < /dev/null
for i in $(seq 1 40); do
  if curl -s -m 1 -o /dev/null "http://127.0.0.1:$GW_PORT/health"; then break; fi
  sleep 0.3
done
echo "   /health : $(curl -s "http://127.0.0.1:$GW_PORT/health")"
echo "   /readyz : $(curl -s "http://127.0.0.1:$GW_PORT/readyz")"

echo "== 5) 같은 오리진 하네스 기동 =="
setsid -f env PORT="$WEB_PORT" WEB_ROOT="$APP_DIR/build/web" \
  GATEWAY="http://127.0.0.1:$GW_PORT" \
  python3 ops/verify-harness/server.py > /tmp/harness.log 2>&1 < /dev/null
for i in $(seq 1 40); do
  if curl -s -m 1 -o /dev/null "http://127.0.0.1:$WEB_PORT/"; then break; fi
  sleep 0.3
done
echo "   index   : $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/")"
echo "   api     : $(curl -s "http://127.0.0.1:$WEB_PORT/api/state?ws=ACCREGISTRYJUNESCHEDULER0001")"

echo "== 6) E2E 실행 =="
export BASE="http://127.0.0.1:$WEB_PORT"
export GW="http://127.0.0.1:$GW_PORT"
python3 ops/verify-harness/e2e.py
RC=$?

echo "== 7) 결과 =="
if [ -f /tmp/e2e_results.json ]; then
  python3 - <<'PY'
import json
rows = json.load(open('/tmp/e2e_results.json'))
ok = sum(1 for r in rows if r['ok'])
print(f"  통과 {ok}/{len(rows)}")
for r in rows:
    print(f"  [{'PASS' if r['ok'] else 'FAIL'}] {r['step']}"
          + (f" — {r['detail']}" if r['detail'] else ""))
PY
fi
exit $RC

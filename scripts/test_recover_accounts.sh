#!/bin/bash
# recover_accounts.py 전체 경로 회귀 시험
PASS=0; FAIL=0
# 시험 대상 스크립트 경로 (환경변수로 바꿀 수 있음)
SRC=${SRC:-/home/user/downloads/recover_accounts.py}
GW=${GW:-http://127.0.0.1:8131}
BASE=${BASE:-/tmp/regress/base}
PORT=${GW##*:}

if [ ! -f "$SRC" ]; then
  echo "[STOP] 시험 대상이 없습니다: $SRC"
  echo "  SRC=/경로/recover_accounts.py 로 지정하십시오."
  exit 1
fi

ck(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (기대:$3 실제:$2)"; FAIL=$((FAIL+1)); fi; }
mkdir -p /tmp/regress/bin && cp "$SRC" /tmp/regress/bin/r.py

# 게이트웨이를 직접 띄운다 (외부 상태에 의존하지 않게).
# 이미 그 포트에 무언가 있으면 그것을 쓰지 않고 중단한다 — 남의 서버에
# 대고 시험하면 결과가 조용히 틀어진다.
GW_PID=""
cleanup(){ [ -n "$GW_PID" ] && kill -9 "$GW_PID" 2>/dev/null; }
trap cleanup EXIT
if lsof -ti:$PORT >/dev/null 2>&1; then
  echo "[STOP] 포트 $PORT 가 이미 사용 중입니다. GW=... 로 다른 포트를 주십시오."
  exit 1
fi
NODE_BIN=$(command -v node || true)
if [ -z "$NODE_BIN" ]; then
  echo "[STOP] node 가 없어 게이트웨이를 띄울 수 없습니다."
  exit 1
fi
GWJS=${GWJS:-/home/user/flutter_app/server/gateway/server.js}
if [ ! -f "$GWJS" ]; then
  echo "[STOP] 게이트웨이 파일이 없습니다: $GWJS"
  exit 1
fi

# 매 실행마다 픽스처를 새로 만든다 (이전 실행의 흔적이 남으면 시험이 거짓말한다)
rm -rf $BASE && mkdir -p $BASE && python3 - "$BASE" <<'PYEOF'
import json,hashlib,sys,os
d=sys.argv[1]
def h(u,p):
    s=f'june-scheduler-pw-v1|{u.lower()}|{p}'.encode(); x=hashlib.sha256(s).digest()
    for _ in range(256): x=hashlib.sha256(x+s).digest()
    return x.hex()
def wc(u):
    s=f'june-scheduler-account-v2|{u}'.encode(); x=hashlib.sha256(s).digest()
    for _ in range(128): x=hashlib.sha256(x+s).digest()
    return 'ACC'+x.hex()[:28].upper()
P='0'*64
reg={"rev":9,"gen":0,"entities":{
 "accounts/june7486":{"id":"june7486","displayName":"이승준","isMaster":True,"enabled":False,
   "pwHash":P,"createdAt":"2026-11-20T10:00:00.000","updatedAt":1751000000000,
   "retiredAt":"2026-11-21T00:25:51.000","retiredBy":"reset_accounts.py"},
 "accounts/scoutmaster":{"id":"scoutmaster","displayName":"스카우트","isMaster":False,"enabled":False,
   "pwHash":P,"createdAt":"2026-11-20T10:00:00.000","updatedAt":1751000000000,
   "retiredAt":"2026-11-21T00:25:51.000","retiredBy":"reset_accounts.py"}}}
json.dump(reg,open(os.path.join(d,'ACCREGISTRYJUNESCHEDULER0001.json'),'w'),ensure_ascii=False,indent=2)
for uid,n in (('june7486',5),('scoutmaster',3)):
    e={"accounts/"+uid:reg['entities']["accounts/"+uid]}
    for i in range(n): e[f"tasks/t{i}"]={"id":f"t{i}","title":f"일정 {i+1}","ownerId":uid,"modifiedAt":i}
    json.dump({"rev":7,"gen":0,"entities":e},open(os.path.join(d,wc(uid)+'.json'),'w'),ensure_ascii=False,indent=2)
PYEOF

# 픽스처가 만들어진 뒤에 게이트웨이를 띄운다 (DATA_DIR 이 그 디렉터리여야 한다)
PORT=$PORT DATA_DIR=$BASE HOST=127.0.0.1 STORAGE=local SYNC_SECRET= \
  setsid -f "$NODE_BIN" "$GWJS" > /tmp/regress/gw.log 2>&1 < /dev/null
for i in $(seq 1 20); do
  curl -s -m 1 -o /dev/null "$GW/health" && break
  sleep 0.3
done
if ! curl -s -m 2 -o /dev/null "$GW/health"; then
  echo "[STOP] 게이트웨이가 뜨지 않았습니다. /tmp/regress/gw.log 확인:"
  tail -5 /tmp/regress/gw.log 2>/dev/null
  exit 1
fi
GW_PID=$(lsof -ti:$PORT 2>/dev/null | head -1)

echo "=== 1) 비번 4자 미만 → 거부 ==="
out=$(python3 /tmp/regress/bin/r.py $BASE --reset-pw june7486 --pw abc --gateway $GW 2>&1); rc=$?
ck "종료코드 2" "$rc" "2"
ck "메시지" "$(echo "$out" | grep -c '4자 이상')" "1"

echo "=== 2) --pw 없음 → 거부 ==="
out=$(python3 /tmp/regress/bin/r.py $BASE --reset-pw june7486 --gateway $GW 2>&1); rc=$?
ck "종료코드 2" "$rc" "2"

echo "=== 3) 오타 아이디 → 거부, 명부 나열 ==="
out=$(python3 /tmp/regress/bin/r.py $BASE --reset-pw june7469 --pw 'Good!2026' --gateway $GW 2>&1); rc=$?
ck "종료코드 2" "$rc" "2"
ck "오타 안내" "$(echo "$out" | grep -c '명부에 없습니다')" "1"
ck "있는 아이디 제시" "$(echo "$out" | grep -c '· june7486')" "1"

echo "=== 4) 정상 재설정 → 실제로 실행됨 ==="
out=$(python3 /tmp/regress/bin/r.py $BASE --reset-pw june7486 --pw 'Good!2026' --gateway $GW --apply 2>&1); rc=$?
ck "종료코드 0" "$rc" "0"
ck "적용 표시" "$(echo "$out" | grep -c '\[적용\]')" "1"
ck "백업 생성" "$(echo "$out" | grep -c '백업:')" "1"
ck "게이트웨이 정상" "$(echo "$out" | grep -c '게이트웨이 상태: 정상')" "1"

echo "=== 5) 게이트웨이 죽음 → 경고하되 파일은 고침 ==="
out=$(python3 /tmp/regress/bin/r.py $BASE --reset-pw june7486 --pw 'Dead!2026' --gateway http://127.0.0.1:9999 --apply 2>&1); rc=$?
ck "종료코드 0" "$rc" "0"
ck "죽음 경고" "$(echo "$out" | grep -c '게이트웨이가 응답하지 않습니다')" "1"

echo "=== 6) --list 는 읽기만 ==="
sum_before=$(find $BASE -name '*.json' -exec md5sum {} \; | sort | md5sum)
python3 /tmp/regress/bin/r.py $BASE --list --gateway $GW >/dev/null 2>&1
sum_after=$(find $BASE -name '*.json' -exec md5sum {} \; | sort | md5sum)
ck "파일 무변경" "$sum_after" "$sum_before"

echo "=== 7) --create 는 신규 생성 허용 ==="
out=$(python3 /tmp/regress/bin/r.py $BASE --create rooky --pw 'Rooky!2026' --gateway http://127.0.0.1:9999 --apply 2>&1); rc=$?
ck "종료코드 0" "$rc" "0"
ck "신규 표시" "$(echo "$out" | grep -c '계정행 신규')" "2"

echo "=== 8) 데이터 보존 불변식 ==="
inv=$(python3 - "$BASE" <<'PYEOF'
import json,hashlib,sys,os
d=sys.argv[1]
def wc(u):
    s=f'june-scheduler-account-v2|{u}'.encode(); x=hashlib.sha256(s).digest()
    for _ in range(128): x=hashlib.sha256(x+s).digest()
    return 'ACC'+x.hex()[:28].upper()
reg=json.load(open(os.path.join(d,'ACCREGISTRYJUNESCHEDULER0001.json'),encoding='utf-8'))['entities']
out=[]
r=reg['accounts/june7486']
out.append(('enabled', r.get('enabled')))
out.append(('isMaster', r.get('isMaster')))
out.append(('잠금흔적없음', 'retiredAt' not in r and 'retiredBy' not in r))
out.append(('독극해제', set(r.get('pwHash') or '')!={'0'}))
ws=json.load(open(os.path.join(d,wc('june7486')+'.json'),encoding='utf-8'))
out.append(('마스터일정', sum(1 for k in ws['entities'] if k.startswith('tasks/'))))
out.append(('gen', ws['gen']))
ws2=json.load(open(os.path.join(d,wc('scoutmaster')+'.json'),encoding='utf-8'))
out.append(('대원일정', sum(1 for k in ws2['entities'] if k.startswith('tasks/'))))
print('|'.join(f'{k}={v}' for k,v in out))
PYEOF
)
ck "마스터 활성(enabled=True)" "${inv%%|*}" "enabled=True"
ck "마스터 일정 5개 보존" "$(echo "$inv" | tr '|' '\n' | grep '^마스터일정=' | cut -d= -f2)" "5"
ck "대원 일정 3개 보존" "$(echo "$inv" | tr '|' '\n' | grep '^대원일정=' | cut -d= -f2)" "3"
ck "gen 유지(0)" "$(echo "$inv" | tr '|' '\n' | grep '^gen=' | cut -d= -f2)" "0"

echo
echo "=========================================="
echo " 통과 $PASS / 실패 $FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]

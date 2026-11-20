# 공유 키 교체(SYNC_KEY 회전) 절차

> **대상** `SYNC_KEY` / `SYNC_SECRET` — 앱과 게이트웨이가 공유하는 값
> **작성 이유** 이 키가 이미 공개 배포본 `main.dart.js` 안에 리터럴로 들어가 있음이 확인됐습니다. 회전이 필요합니다. 다만 **순서를 틀리면 전 사용자의 동기화가 멈춥니다.**

---

## 0. 먼저 알아야 할 사실

이 키는 **비밀이 아닙니다.** `deploy_pages.sh`가 이렇게 넘깁니다:

```bash
BUILD_ARGS+=(--dart-define=SYNC_KEY="${SYNC_KEY}")
```

`--dart-define`은 문자열을 **컴파일 시점에 코드 안에 박습니다.** 실제로 확인한 위치:

```
build/web/main.dart.js  offset 2,916,684
  x:"<64자 hex>"
```

그 파일은 `https://www.aqdesign.co.kr/`에서 누구나 내려받습니다. 즉:

| 오해 | 사실 |
|---|---|
| "키를 알면 남의 데이터를 읽는다" | 아니다. 데이터 접근은 **워크스페이스 ID + 계정 인증**이 결정한다 |
| "키를 바꾸면 안전해진다" | 부분적으로만. 캐시된 옛 번들이 옛 키를 계속 보낸다 |
| "키는 서버에만 있다" | 아니다. 이미 모든 브라우저에 배포됐다 |

**키의 실제 역할**은 "실수로 남의 워크스페이스에 쓰는 것을 막는 오타 방지 라벨"에 가깝습니다. 진짜 방어선은 두 가지입니다:

1. 게이트웨이는 `HOST=127.0.0.1`로만 바인딩 (인터넷에 직접 노출 금지)
2. 사용자 신뢰는 `SYNC_KEY`가 아니라 **계정 비밀번호 인증**에서 나온다

그래도 회전은 해야 합니다. 이미 공개된 값이 영원히 유효한 것은 바람직하지 않습니다.

---

## 1. 새 키 만들기

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

64자 hex가 나옵니다. 이 값을 `NEW_KEY`라고 하겠습니다.
**64자가 아니거나 16자 미만이면 `/readyz`가 503 `auth`로 거부합니다.**

---

## 2. 게이트웨이에 두 키를 동시에 수용시키기

NAS의 `.env`를 엽니다.

```bash
# 회전 전 상태 (예시)
SYNC_SECRET=<옛 키>
```

이렇게 바꿉니다:

```bash
SYNC_SECRET=<NEW_KEY>
SYNC_SECRET_PREVIOUS=<옛 키 그대로>
```

재시작합니다.

```bash
# start.sh 를 쓰신다면
./start.sh restart
# 또는 직접
pkill -f "gateway/server.js" && sleep 1 && setsid -f ./start.sh > gateway.log 2>&1 < /dev/null
```

**확인 — 로그에 이 줄이 보여야 합니다:**

```
[june-gateway] auth=key required
[june-gateway] rotation=on — the previous key is still accepted. …
```

**그리고 두 키 모두 통과하는지 직접 확인:**

```bash
# 새 키 → 200
curl -s -o /dev/null -w "new=%{http_code}\n" \
  -H "X-Sync-Key: $(grep '^SYNC_SECRET=' .env | cut -d= -f2)" \
  "http://127.0.0.1:8097/api/state?ws=TESTWS0001"

# 옛 키 → 200 (이게 200이 아니면 절대 다음 단계로 가지 마세요)
curl -s -o /dev/null -w "old=%{http_code}\n" \
  -H "X-Sync-Key: $OLD_KEY" \
  "http://127.0.0.1:8097/api/state?ws=TESTWS0001"
```

> ⚠️ **여기서 `old=401`이 나오면 2단계를 멈추고 `SYNC_SECRET_PREVIOUS` 철자를 확인하세요.**
> 이 상태에서 3단계(재배포)를 하면 캐시된 옛 번들이 전부 401이 됩니다.

---

## 3. 새 키로 앱 빌드 + 배포

`deploy_pages.sh`를 새 키로 실행합니다. **키를 명령줄에 직접 쓰지 마세요** — 셸 히스토리와 프로세스 목록에 남습니다.

```bash
cd /home/user/flutter_app

# 키를 파일로 두고 읽어쓰기 (이 파일은 .gitignore 대상)
printf '%s' "<NEW_KEY>" > .sync_key
chmod 600 .sync_key

SYNC_URL="https://sync.<NAS-호스트>.direct.quickconnect.to" \
SYNC_KEY="$(cat .sync_key)" \
GH_REPO="june7486/Scheduler" \
CUSTOM_DOMAIN="www.aqdesign.co.kr" \
BUILD_ID="$(date +%Y.%m.%d.%H%M)" \
./deploy_pages.sh custom
```

> `.sync_key`를 커밋하지 마세요. `.gitignore`에 있는지 확인하세요:
> ```bash
> grep -q '^\.sync_key$' .gitignore || echo '.sync_key' >> .gitignore
> ```

배포 후 **새 번들에 새 키가 들어갔는지 검증**합니다:

```bash
curl -s https://www.aqdesign.co.kr/main.dart.js -o /tmp/check.js
# 새 키가 있으면 1, 옛 키가 있으면 1 (배포 직후엔 둘 다 아닐 수 있음 — 캐시)
grep -c "<NEW_KEY>" /tmp/check.js   # 1 이어야 함
grep -c "$OLD_KEY" /tmp/check.js   # 0 이어야 함
```

---

## 4. 캐시가 빌 때까지 기다리기

이제 새 탭은 새 키를, 캐시가 남은 탭은 옛 키를 보냅니다. **둘 다 정상 동작합니다.**

게이트웨이 로그가 60초마다 이렇게 알려줍니다:

```
[june-gateway] retiredKeyHits=17 — clients still on a cached bundle; do NOT remove the old key yet
```

`retiredKeyHits`가 **증가하지 않고 0에 머무르면** 캐시가 빈 것입니다:

```
[june-gateway] retiredKeyHits=0 — no client is using the old key; safe to remove SYNC_SECRET_PREVIOUS
```

**얼마나 기다려야 하나?** GitHub Pages는 정적 파일에 `Cache-Control: max-age=600`(10분)을 붙입니다. 브라우저는 보통 그보다 오래 캐시할 수 있습니다. **최소 1시간, 안전하게는 하루**를 권합니다. 급할 이유가 없습니다 — 기다리는 동안 아무도 불편하지 않습니다.

> 이 앱은 서비스 워커를 쓰지 않습니다. 만약 나중에 도입한다면 서비스 워커가 `main.dart.js`를 붙잡을 수 있어 회전 창을 훨씬 길게 잡아야 합니다.

---

## 5. 옛 키 폐기

```bash
# .env 에서 SYNC_SECRET_PREVIOUS 줄을 삭제 (주석 처리 아님 — 완전 삭제)
sed -i '/^SYNC_SECRET_PREVIOUS=/d' .env
```

재시작 후 확인:

```bash
# 옛 키 → 401 이어야 함
curl -s -o /dev/null -w "old_after=%{http_code}\n" \
  -H "X-Sync-Key: $OLD_KEY" \
  "http://127.0.0.1:8097/api/state?ws=TESTWS0001"

# 새 키 → 200 이어야 함
curl -s -o /dev/null -w "new_after=%{http_code}\n" \
  -H "X-Sync-Key: $(grep '^SYNC_SECRET=' .env | cut -d= -f2)" \
  "http://127.0.0.1:8097/api/state?ws=TESTWS0001"
```

`old_after=401`, `new_after=200`이면 회전 완료입니다.

---

## 6. 되돌리기 (문제가 생겼을 때)

**모든 단계가 가역적입니다.** 옛 키를 버리기 전(5단계 전)이라면 언제든 되돌릴 수 있습니다.

| 시점 | 되돌리는 법 | 걸리는 시간 |
|---|---|---|
| 2단계 직후 | `.env`에서 두 줄을 옛 상태로 | 재시작 1회 |
| 3단계 직후 (배포함) | 옛 키로 다시 배포 + `.env` 원복 | 빌드 3~5분 |
| 4단계 중 | 그냥 기다리면 됨. 둘 다 통과 중이므로 장애 없음 | — |
| 5단계 이후 | 새 키로 다시 회전 (2→5 반복) | 처음부터 |

**5단계 전에는 어떤 시점에도 사용자가 끊기지 않습니다.** 이게 이 절차의 핵심입니다.

---

## 7. 회전 체크리스트 (출력해서 옆에 두세요)

```
[ ] 1. NEW_KEY 생성 (64자 hex)
[ ] 2. .env: SYNC_SECRET=NEW, SYNC_SECRET_PREVIOUS=OLD
[ ] 2a. 재시작 → 로그에 rotation=on 확인
[ ] 2b. curl: new=200 확인     ← 이게 200이어야 진행
[ ] 2c. curl: old=200 확인     ← 이게 200이어야 진행
[ ] 3. .sync_key 파일 생성 + .gitignore 확인
[ ] 3a. deploy_pages.sh 실행 (SYNC_KEY="$(cat .sync_key)")
[ ] 3b. 배포본 grep: NEW=1, old=0
[ ] 4. retiredKeyHits 관찰 (최소 1시간, 권장 하루)
[ ] 4a. retiredKeyHits=0 확인
[ ] 5. .env 에서 SYNC_SECRET_PREVIOUS 삭제 + 재시작
[ ] 5a. curl: old=401, new=200
[ ] 6. .sync_key 파일 삭제
[ ] 7. 이 문서에 회전 날짜 기록
```

---

## 8. 기록

| 날짜 | 작업 | 담당 |
|---|---|---|
| 2026-11-20 | 키가 `build/web/main.dart.js`에 평문 포함됨을 확인. 회전 필요 판정 | — |
| 2026-11-20 | 게이트웨이에 `SYNC_SECRET_PREVIOUS` 수용 구조 추가 (무중단 회전 가능) | — |
| (대기) | 실제 키 회전 실행 | 사용자 승인 대기 |

---

## 참고 — 왜 이렇게까지 하나

키 회전은 원래 30초짜리 작업입니다. 이 프로젝트에서 어려운 이유는 **키가 배포 산출물 안에 컴파일된다**는 구조 때문입니다. 서버 설정을 바꾸는 것과 클라이언트를 바꾸는 것이 동시에 일어날 수 없고, 그 사이에 사용자가 있습니다.

`SYNC_SECRET_PREVIOUS`는 그 간극을 메우는 장치입니다. 영구 기능이 아니라 **회전 중에만 쓰는 임시 값**이며, 다 쓰면 지우는 것이 정상입니다.

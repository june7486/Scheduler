# 나스에 직접 설치하기 — 가장 빠른 구성

준이 스케줄러의 데이터를 **나스 안에** 두고, 앱은 그 나스에게만 물어봅니다.
외부 클라우드를 거치지 않으므로, 같은 계정으로 로그인하면 **아이폰·안드로이드·크롬·사파리가
모두 같은 데이터**를 봅니다.

---

## 왜 이 방식이 가장 빠른가 (실측)

게이트웨이가 나스 **안에서** 돌면 데이터가 이렇게 흐릅니다.

```
앱 → (인터넷) → 나스 리버스 프록시 → 게이트웨이 → 로컬 파일
```

`STORAGE=dsm` (게이트웨이가 밖에서 돌 때) 은 여기에 **DSM API 왕복이 한 번 더** 붙습니다.

| 동작 | DSM 경유 (dsm) | 로컬 파일 (local) |
|---|---|---|
| 300개 일정 첫 읽기 (gzip 후 4.5 KB) | **633 ms** | **9 ms** |
| 저장 1회 | 699 ms | **6 ms** |
| 변경 없음 확인 | 2 ms (48 B) | **3 ms (48 B)** |
| 다른 기기로 전파 | 9 ms | 9 ms |

**70배 차이**입니다. 그래서 이 문서는 `STORAGE=local`, 즉 **나스에 직접 설치**를 안내합니다.

---

## ⚠️ 먼저: 관리자 계정이 필요합니다

`SYNO.Core.Package` API를 `scheduler` 계정(일반 사용자)으로 호출하면 **error 105 = 권한 없음**
이 돌아옵니다. 즉 **일반 사용자 권한으로는 Node.js 패키지를 설치할 수 없습니다.**
아래 1단계는 반드시 **관리자(admin)** 계정으로 로그인한 상태에서 하세요.

나머지(2~7단계)는 `scheduler` 계정으로도 가능합니다.

---

## 1단계 — Node.js 설치

DSM → **패키지 센터** → 검색: `Node.js` → **Node.js v20** 설치.

설치 위치 (자동): `/volume1/@appstore/Node.js_v20/bin/node`

확인:

```bash
/volume1/@appstore/Node.js_v20/bin/node -v
# v20.x.x 가 나오면 성공
```

> 게이트웨이는 **외부 의존성이 0개**입니다. `npm install` 할 것이 없습니다.

---

## 2단계 — 파일 올리기

이미 나스의 `/92_Scheduler/scheduler-sync` 에 올라가 있습니다.

| 파일 | 역할 |
|---|---|
| `server.js` | 게이트웨이 본체 (의존성 없음) |
| `start.sh` | 실행/정지/상태/셀프테스트 |
| `.env` | 설정 (키 포함 — 커밋 금지) |
| `.env.example` | 설정 견본 |
| `README.md` | 프로토콜 설명 |
| `DSM-설치가이드.md` | 이 문서 |

**File Station** 으로 확인하거나, SSH 로:

```bash
ls -la /volume1/92_Scheduler/scheduler-sync/
```

---

## 3단계 — `.env` 확인

이미 생성되어 있습니다. 값만 확인하세요.

```bash
cd /volume1/92_Scheduler/scheduler-sync
cat .env
```

핵심 3줄:

```ini
STORAGE=local
DATA_DIR=/volume1/92_Scheduler/scheduler-sync/data
SYNC_SECRET=46c8b41d49fce507fd0b61908c4de356a7b920bbfc2ee5f9f86b32a5934fe26d
```

- `DATA_DIR` 은 없으면 자동 생성됩니다.
- `SYNC_SECRET` 은 앱 빌드에 넣을 키입니다. **바꾸려면** 새로 만들고 7단계에서 다시 빌드하세요.

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

> 이 키를 모르면 아무도 데이터를 읽고 쓸 수 없습니다. 반대로 이 키가 노출되면
> 데이터가 노출됩니다. 저장소(GitHub)에는 **절대** 올리지 마세요 — `.gitignore` 에 처리되어 있습니다.

---

## 4단계 — 셀프테스트

프록시를 건드리기 **전에** 저장소부터 확인합니다.

```bash
cd /volume1/92_Scheduler/scheduler-sync
./start.sh selftest
```

기대하는 출력:

```
[june-gateway] self-test

  OK   storage — local(/volume1/92_Scheduler/scheduler-sync/data)
  OK   auth — shared key required
  OK   download — nothing stored yet (normal)
  OK   upload — write + folder creation works
```

`FAIL` 이 나오면 그 줄이 문제 지점입니다. 대개 `DATA_DIR` 쓰기 권한입니다.

```bash
chown -R scheduler:users /volume1/92_Scheduler/scheduler-sync
```

---

## 5단계 — 게이트웨이 실행 (DSM 부팅 시 자동 시작)

DSM 에는 `systemd` 가 없습니다. **제어판 → 작업 스케줄러 → 생성 → 트리거된 작업 →
사용자 정의 스크립트** 로 등록합니다.

- **이벤트**: 부팅됨
- **사용자**: root
- **스크립트**:

```bash
#!/bin/bash
DIR=/volume1/92_Scheduler/scheduler-sync
NODE=/volume1/@appstore/Node.js_v20/bin/node
LOG=$DIR/gateway.log

if pgrep -f "scheduler-sync/server.js" > /dev/null; then
  echo "$(date) already running" >> "$LOG"; exit 0
fi

cd "$DIR" || exit 1
set -a; . ./.env; set +a
nohup "$NODE" server.js >> "$LOG" 2>&1 &
echo "$(date) started pid=$!" >> "$LOG"
```

저장한 뒤, 작업을 선택하고 **실행** 을 한 번 눌러 지금 바로 띄웁니다.

확인:

```bash
cd /volume1/92_Scheduler/scheduler-sync
./start.sh status
# ✅ running  pid=1234
# {"ok":true,"service":"june-nas-gateway","storage":"local","nas":true,...}
```

`nas:true` 는 "저장 폴더에 쓸 수 있다"는 뜻입니다.

---

## 6단계 — 리버스 프록시 (HTTPS)

앱은 **HTTPS** 페이지이므로, 게이트웨이도 HTTPS 로 열려야 합니다. (HTTP 를 부르면 브라우저가
혼합 콘텐츠로 차단합니다.)

DSM → **제어판 → 로그인 포털 → 고급 → 리버스 프록시 → 생성**

| 항목 | 값 |
|---|---|
| 이름 | `scheduler-sync` |
| 프로토콜(소스) | **HTTPS** |
| 호스트 이름 | `sync.aqdesign.co.kr` (또는 사용할 주소) |
| 포트 | **443** |
| 프로토콜(대상) | **HTTP** |
| 호스트 이름 | `localhost` |
| 포트 | **8097** |

**사용자 지정 헤더** (중요 — 없으면 앱이 400/리다이렉트를 받습니다):

| 이름 | 값 |
|---|---|
| `Host` | `$host` |
| `X-Real-IP` | `$remote_addr` |

**HTTP/2 는 끄세요.** DSM 프록시의 HTTP/2 는 롱폴(20초 대기) 응답을 버퍼링해
"가끔 동기화가 멈추는" 증상의 원인이 됩니다.

**인증서**: `제어판 → 보안 → 인증서` 에서 위 호스트 이름에 대해
`aqdesign.co.kr` 인증서를 지정합니다. DNS 는 `sync.aqdesign.co.kr` → 나스 IP
(또는 DDNS 주소) 로 CNAME/A 레코드를 추가하세요.

확인 (외부에서):

```bash
curl https://sync.aqdesign.co.kr/health
# {"ok":true,"service":"june-nas-gateway","storage":"local","nas":true,...}
```

---

## 7단계 — 앱 빌드에 주소를 심기

주소를 앱에 미리 넣으면, 사용자는 로그인만 하면 됩니다 (설정 화면에서 입력할 필요 없음).

```bash
cd /home/user/flutter_app

SYNC_URL="https://sync.aqdesign.co.kr" \
SYNC_KEY="46c8b41d49fce507fd0b61908c4de356a7b920bbfc2ee5f9f86b32a5934fe26d" \
GH_REPO="june7486/Scheduler" \
CUSTOM_DOMAIN="www.aqdesign.co.kr" \
./deploy_pages.sh custom
```

`deploy_pages.sh` 는 두 값을 `--dart-define` 으로 넘기고, 빌드 후
`scripts/optimize_web.py` 로 폰트 subsetting 까지 자동 수행합니다.

---

## 8단계 — 실제 기기 확인

1. `https://www.aqdesign.co.kr` 접속 → 로그인
2. 설정 → **데이터 동기화** 패널이 `연결됨` 인지 확인
3. 일정 하나 추가
4. **다른 기기**(아이폰 사파리 / 안드로이드 크롬)에서 같은 아이디로 로그인
5. 몇 초 안에 같은 일정이 나타나면 성공

전파는 게이트웨이의 **롱폴**이 담당합니다. 대기 중인 요청을 붙잡아 두었다가,
누군가 저장하는 순간 즉시 깨웁니다 (실측 **9 ms**). 2초마다 묻는 방식이 아닙니다.

---

## 문제 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| 설정 패널이 `연결 안 됨` | 주소/키 오타, 또는 HTTPS 아님 | `curl <주소>/health` 가 열리는지 먼저 확인 |
| `bad key` | `SYNC_SECRET` 불일치 | `.env` 와 빌드에 넣은 `SYNC_KEY` 비교 |
| `curl` 은 되는데 앱만 실패 | CORS/혼합 콘텐츠 | HTTPS 인지, 주소 끝에 `/` 없는지 확인 |
| 동기화가 몇 초 멈춤 | HTTP/2 버퍼링 | 리버스 프록시에서 HTTP/2 끄기 |
| 부팅 후 죽어 있음 | Task Scheduler 미등록 | `./start.sh status`, `gateway.log` 확인 |
| `EADDRINUSE` | 이미 실행 중 | `./start.sh stop` |
| `storage` 줄이 FAIL | `DATA_DIR` 권한 | `chown -R scheduler:users <DATA_DIR>` |

로그:

```bash
tail -50 /volume1/92_Scheduler/scheduler-sync/gateway.log
```

---

## 백업

데이터는 **워크스페이스 1개 = JSON 파일 1개** 입니다.

```
/volume1/92_Scheduler/scheduler-sync/data/ACC7F3A91C2B4D5E6F708192A3B4C5D.json
```

`ACC…` 는 계정에서 유도된 값이라 아이디만 알면 어느 기기에서나 같은 파일을 찾습니다.
Hyper Backup 으로 이 폴더만 잡아두면 끝입니다.

---

## 보안 체크리스트

- [ ] `SYNC_SECRET` 이 충분히 길다 (32바이트 = 64자)
- [ ] `.env` 가 Git 에 없다 (`.gitignore` 확인)
- [ ] 리버스 프록시가 HTTPS 만 받는다
- [ ] DSM 계정은 2단계 인증 사용
- [ ] 정기적으로 `data/` 폴더 백업

# NAS 게이트웨이 — 구조와 운영

앱은 **정적 웹페이지**입니다. 브라우저는 시놀로지 DSM API의 응답을 직접 읽을 수 없습니다
(`Access-Control-Allow-Origin` 헤더가 없음 — 실측 확인). 그래서 **우리 출처(origin)에
서는 작은 중계 서버**가 하나 필요합니다. 이 파일이 그 서버입니다.

```
[아이폰 사파리 · 안드로이드 크롬 · 데스크톱]
        │  HTTPS + X-Sync-Key
        ▼
[게이트웨이  server/gateway/server.js]   ← 우리가 통제하는 출처, CORS 정상
        │
        ├── STORAGE=local : 나스 로컬 파일          ← 나스에 직접 설치 (가장 빠름)
        └── STORAGE=dsm   : DSM FileStation API     ← 게이트웨이를 다른 곳에서 운영
        ▼
   /…/data/<workspace>.json   (워크스페이스 1개 = 파일 1개)
```

**나스에 직접 설치하는 방법은 `DSM-설치가이드.md` 를 보세요.** 이 문서는 구조와
프로토콜, 그리고 다른 장비에서 돌릴 때의 운영 방법을 다룹니다.

---

## 1. 저장 방식 두 가지

| | `local` | `dsm` |
|---|---|---|
| 게이트웨이 위치 | 나스 안 (권장) | 아무 데나 |
| 저장 경로 | 로컬 디렉터리 | DSM FileStation 업로드 |
| 300건 첫 읽기 | **9 ms** | 633 ms |
| 저장 1회 | **6 ms** | 699 ms |
| 필요한 자격증명 | 없음 | DSM 계정 |
| 설정 | `DATA_DIR` | `NAS_HOST/NAS_USER/NAS_PASS/NAS_FOLDER` |

`STORAGE` 를 비우면 `NAS_HOST` 유무로 자동 선택됩니다.

---

## 2. 빠른 실행

```bash
cd server/gateway
cp .env.example .env      # 값 채우기
./start.sh                # start | stop | status | selftest
```

환경변수로 직접 넘겨도 됩니다:

```bash
# 나스에 직접 설치하는 경우 (가장 빠름)
STORAGE=local DATA_DIR=/volume1/92_Scheduler/scheduler-sync/data \
SYNC_SECRET='long-random-string' node server.js

# 다른 장비에서 돌리는 경우
STORAGE=dsm \
NAS_HOST=june7558.direct.quickconnect.to NAS_PORT=5001 \
NAS_USER=scheduler NAS_PASS='********' \
NAS_FOLDER=/92_Scheduler/sync NAS_INSECURE=0 \
SYNC_SECRET='long-random-string' node server.js
```

부팅 로그:

```
[june-gateway] listening on :8097
[june-gateway] storage=local(/volume1/92_Scheduler/scheduler-sync/data)
[june-gateway] auth=key required
```

### 환경변수

| 이름 | 기본값 | 설명 |
|---|---|---|
| `STORAGE` | `dsm`(NAS_HOST 있을 때) / `local` | `local` \| `dsm` |
| `DATA_DIR` | `./data` | `local` 저장 폴더 |
| `PORT` | `8097` | 게이트웨이 포트 |
| `NAS_HOST` | — | `dsm` 필수. 나스에서 돌린다면 `127.0.0.1` 권장 |
| `NAS_PORT` | `5001` | DSM HTTPS 포트 |
| `NAS_USER` | — | `dsm` 필수 |
| `NAS_PASS` | — | `dsm` 필수 |
| `NAS_SESSION` | `FileStation` | **바꾸지 마세요.** 다른 이름은 DSM이 402로 거부합니다 |
| `NAS_FOLDER` | — | `dsm` 필수. 절대 경로 |
| `NAS_INSECURE` | `1`(아니오) | `0` = 인증서 검증 |
| `SYNC_SECRET` | (없음) | 앱이 `X-Sync-Key`로 보내는 공유 키. **공인 인터넷에서는 필수** |
| `CACHE_MS` | `8000` | 문서를 RAM에서 재사용하는 시간 |
| `BASE_PATH` | (없음) | 리버스 프록시 하위 경로 (예: `/scheduler-sync`) |

---

## 3. HTTPS 로 노출하기

HTTPS 페이지(`https://www.aqdesign.co.kr`)는 HTTP 게이트웨이를 호출할 수 없습니다
(mixed content). 게이트웨이도 HTTPS여야 합니다.

### DSM 리버스 프록시 (나스에 직접 설치했다면 이 방법)

`제어판 → 로그인 포털 → 고급 → 리버스 프록시` — 자세한 값은 `DSM-설치가이드.md` 6단계.
핵심은 **HTTP/2 를 끄는 것**입니다. DSM 프록시의 HTTP/2 는 롱폴 응답을 버퍼링합니다.

### nginx

```nginx
server {
  listen 443 ssl http2;      # 롱폴을 쓴다면 http2 는 빼는 편이 안전합니다
  server_name sync.aqdesign.co.kr;

  ssl_certificate     /etc/letsencrypt/live/sync.aqdesign.co.kr/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/sync.aqdesign.co.kr/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:8097;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;

    proxy_read_timeout 60s;   # 롱폴은 최대 20초 열려 있습니다
    proxy_buffering off;      # 응답이 즉시 흘러가야 "즉시 반영"이 됩니다
  }
}
```

### Cloudflare Tunnel

```bash
cloudflared tunnel create june-sync
cloudflared tunnel route dns june-sync sync.aqdesign.co.kr
cloudflared tunnel run --url http://127.0.0.1:8097 june-sync
```

---

## 4. 앱에 주소 심기

빌드에 주소를 박아두면 사용자는 아무 설정도 하지 않습니다:

```bash
SYNC_URL="https://sync.aqdesign.co.kr" \
SYNC_KEY="same-long-random-string" \
GH_REPO="june7486/Scheduler" CUSTOM_DOMAIN="www.aqdesign.co.kr" \
./deploy_pages.sh custom
```

`deploy_pages.sh` 가 `--dart-define` 으로 넘기고, 빌드 후 `scripts/optimize_web.py` 로
폰트 subsetting 까지 수행합니다. 설정 화면에서 기기별로 덮어쓸 수도 있습니다
(빌드 값은 어디까지나 기본값).

---

## 5. 자동 시작

### DSM (나스에 직접 설치)

`systemd` 가 없으므로 **제어판 → 작업 스케줄러 → 트리거된 작업(부팅됨)** 에
`start.sh` 를 등록합니다. 스크립트 전문은 `DSM-설치가이드.md` 5단계.

### systemd (일반 리눅스)

```ini
[Unit]
Description=June Scheduler gateway
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/june-sync
EnvironmentFile=/opt/june-sync/.env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## 6. 동작 확인

```bash
# 살아 있나? (키 없이 열립니다 — 자격증명 노출 방지)
curl https://sync.aqdesign.co.kr/health
# → {"ok":true,"service":"june-nas-gateway","storage":"local","nas":true,"time":…}

# 읽기
curl -H "X-Sync-Key: $KEY" "https://sync.aqdesign.co.kr/api/state?ws=ACCYOURWORKSPACE"
# → {"exists":false,"rev":0,"gen":0,"entities":{}}

# 쓰기 — 응답의 echo 가 곧 저장 확인서입니다 (재조회 불필요)
curl -X POST -H "X-Sync-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"ws":"ACCYOURWORKSPACE","entities":{"tasks/t1":{"id":"t1","title":"테스트","updatedAt":1000}}}' \
  https://sync.aqdesign.co.kr/api/push
# → {"ok":true,"rev":1,"gen":0,"count":1,"echo":{"tasks/t1":1000}}

# 롱폴 — 다른 창에서 push 하면 즉시 깨어납니다
curl -H "X-Sync-Key: $KEY" \
  "https://sync.aqdesign.co.kr/api/state?ws=ACCYOURWORKSPACE&rev=1&wait=25"
```

---

## 7. 성능 설계 (실측)

| 항목 | 결과 |
|---|---|
| 300건 문서 전송 | **134,114 B → 1,430 B** (gzip, 94배) |
| 첫 읽기 (local / dsm) | **9 ms** / 633 ms |
| 캐시 읽기 | 9 ms / 31 ms |
| 변경 없음 확인 | **48 B, 2~3 ms** |
| 저장 확인 | **왕복 1회** (push 응답의 `echo` 가 확인서) |
| 다른 기기 전파 | **쓰기 후 9 ms** (롱폴이 깨어남) |
| 유휴 시 요청 수 | 분당 **약 2회** (2초 폴링 = 분당 30회) |

설계의 핵심 4가지:

1. **저장 응답이 확인서** — 쓰고 나서 다시 읽지 않습니다. `echo`(받은 키)와
   `lost`(경합에서 이긴 값)를 함께 돌려주므로 정상 저장은 요청 1회입니다.
2. **롱폴** — 2초마다 묻지 않습니다. 게이트웨이가 요청을 붙잡고 있다가 쓰기가
   들어오는 순간 깨웁니다.
3. **gzip** — 평범한 JSON이라 압축률이 매우 높습니다.
4. **`rev`/`gen`** — 변경이 없으면 48바이트로 답합니다. `gen`(세대)은 "서버가 비었다"와
   "초기화됐다"를 구분해, 한 기기에서 초기화해도 다른 기기가 데이터를 되살리지 않습니다.

---

## 8. 장애 대응

| 증상 | 원인 / 해결 |
|---|---|
| `nas login failed: {"code":115}` | 로그인을 multipart POST로 보냄. 이 게이트웨이는 GET을 씁니다 — 수정했다면 되돌리세요 |
| `{"error":{"code":402}}` | `NAS_SESSION` 이 `FileStation` 이 아님 |
| 읽기가 `502` + HTML | 폴더/파일 없음(정상). 첫 쓰기가 `create_parents=true`로 만듭니다 |
| `code 119` | SID 만료. DSM 모드에서 자동 재로그인합니다 |
| 앱이 `bad key` | `SYNC_SECRET` 과 빌드의 `SYNC_KEY` 불일치 |
| 앱은 뜨는데 동기화 안 됨 | mixed content — HTTPS 페이지 → HTTPS 게이트웨이인지 확인 |
| 롱폴이 20초마다 끊김 | 정상입니다. 그때마다 `unchanged`(~48 B)로 답합니다 |
| `EADDRINUSE` | 이미 실행 중 — `./start.sh stop` |
| `storage` FAIL | `DATA_DIR` 쓰기 권한 — `chown -R scheduler:users <DATA_DIR>` |

---

## 9. 백업

워크스페이스는 **JSON 파일 하나**입니다.

```
data/ACC7F3A91C2B4D5E6F708192A3B4C5D.json
```

`ACC…` 는 계정 아이디에서 유도되므로, 아이디만 알면 어느 기기에서나 같은 파일을
찾습니다. Hyper Backup이나 스냅샷으로 이 폴더만 잡아두면 계정 전체가 백업됩니다.

```bash
tar czf /92_Scheduler/backup/sync-$(date +%F).tgz -C /92_Scheduler/scheduler-sync data
```

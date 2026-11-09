# NAS 게이트웨이 배포 가이드

앱은 **정적 웹페이지**입니다. 브라우저는 시놀로지 DSM API의 응답을 읽을 수 없습니다
(`Access-Control-Allow-Origin` 헤더가 없음 — 실측 확인). 그래서 **우리 출처(origin)에
서는 작은 중계 서버**가 하나 필요합니다. 이 파일이 그 서버입니다.

```
[아이폰/크롬/사파리/안드로이드]
        │  HTTPS + X-Sync-Key
        ▼
[게이트웨이  server/gateway/server.js]   ← 우리가 통제하는 출처
        │  DSM 세션 보관 (비밀번호는 브라우저에 없음)
        ▼
[시놀로지 나스  FileStation]  /92_Scheduler/sync/<workspace>.json
```

---

## 1. 필요한 것

| 항목 | 값 (이 나스 기준) |
|---|---|
| 나스 주소 | `june7558.direct.quickconnect.to` |
| DSM 포트 | `5001` (HTTPS) |
| DSM 계정 | `scheduler` |
| 저장 폴더 | `/92_Scheduler/sync` |
| Node.js | 18 이상 (의존성 0개) |

> `scheduler` 계정은 관리자가 아니어도 됩니다. FileStation 읽기/쓰기만 되면 충분합니다.
> 실제로 `SYNO.Core.System` 호출은 1006으로 거부되지만 업로드/다운로드는 정상 동작합니다.

---

## 2. 실행

```bash
cd server/gateway
cp .env.example .env      # 값을 채웁니다
node server.js
```

`.env` 대신 환경변수로 직접 넘겨도 됩니다:

```bash
PORT=8097 \
NAS_HOST=june7558.direct.quickconnect.to \
NAS_PORT=5001 \
NAS_USER=scheduler \
NAS_PASS='********' \
NAS_FOLDER=/92_Scheduler/sync \
NAS_INSECURE=0 \
SYNC_SECRET='long-random-string' \
node server.js
```

부팅 로그가 이렇게 나오면 성공입니다:

```
[june-gateway] listening on :8097
[june-gateway] nas=june7558.direct.quickconnect.to:5001 folder=/92_Scheduler/sync
[june-gateway] auth=key required
```

### 환경변수

| 이름 | 기본값 | 설명 |
|---|---|---|
| `PORT` | `8097` | 게이트웨이가 열 포트 |
| `NAS_HOST` | — | **필수.** QuickConnect 주소 또는 IP |
| `NAS_PORT` | `5001` | DSM HTTPS 포트 |
| `NAS_USER` | — | **필수.** DSM 계정 |
| `NAS_PASS` | — | **필수.** DSM 비밀번호 |
| `NAS_SESSION` | `FileStation` | **바꾸지 마세요.** 다른 이름은 DSM이 402로 거부합니다 |
| `NAS_FOLDER` | — | **필수.** 절대 경로 |
| `NAS_INSECURE` | `1`(아니오) | `0` = 인증서 검증. Let's Encrypt 정식 인증서이므로 `0` |
| `SYNC_SECRET` | (없음) | 앱이 `X-Sync-Key`로 보내는 공유 키. **공인 인터넷에서는 반드시 설정** |
| `CACHE_MS` | `8000` | 문서를 RAM에서 재사용하는 시간 |

---

## 3. HTTPS 로 노출하기

브라우저에서 `https://www.aqdesign.co.kr` (HTTPS) 이 앱을 열면, **HTTPS 페이지는 HTTP
게이트웨이를 호출할 수 없습니다**(mixed content). 게이트웨이도 HTTPS여야 합니다.

### 이미 리버스 프록시가 있다면 (권장)

```nginx
server {
  listen 443 ssl;
  server_name sync.aqdesign.co.kr;

  ssl_certificate     /etc/letsencrypt/live/sync.aqdesign.co.kr/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/sync.aqdesign.co.kr/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:8097;
    proxy_http_version 1.1;
    proxy_set_header Host $host;

    # 롱폴이 최대 30초 열려 있습니다. 기본 60초로 충분하지만 명시해 둡니다.
    proxy_read_timeout 60s;
    proxy_buffering off;   # 응답이 즉시 흘러가야 "즉시 반영"이 됩니다
  }
}
```

### Cloudflare Tunnel (도메인만 있으면 가장 간단)

```bash
cloudflared tunnel create june-sync
cloudflared tunnel route dns june-sync sync.aqdesign.co.kr
cloudflared tunnel run --url http://127.0.0.1:8097 june-sync
```

---

## 4. 앱에 주소 심기

배포할 때 **빌드에 주소를 박아두면** 사용자는 아무 설정도 하지 않습니다:

```bash
SYNC_URL="https://sync.aqdesign.co.kr" \
SYNC_KEY="same-long-random-string" \
GH_REPO="june7486/Scheduler" CUSTOM_DOMAIN="www.aqdesign.co.kr" \
./deploy_pages.sh custom
```

`deploy_pages.sh` 가 `--dart-define` 으로 넘깁니다. 설정 화면에서 기기별로 덮어쓸 수도
있습니다(빌드 값은 어디까지나 기본값).

---

## 5. 자동 시작 (systemd)

`/etc/systemd/system/june-sync.service`:

```ini
[Unit]
Description=June Scheduler NAS gateway
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/june-sync
EnvironmentFile=/opt/june-sync/.env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now june-sync
sudo systemctl status june-sync
```

### Docker 로 돌린다면

```yaml
services:
  gateway:
    build: .
    restart: unless-stopped
    ports: ["8097:8097"]
    env_file: .env
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:8097/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
```

> 이 나스에는 **Docker가 설치되어 있지 않습니다.** 다른 장비나 VPS에서 돌리는 편이
> 현실적입니다. 게이트웨이는 나스에 *접속*만 하면 되므로 어디서 돌아도 됩니다.

---

## 6. 동작 확인

```bash
# 살아 있나?
curl https://sync.aqdesign.co.kr/health
# → {"ok":true,"service":"june-nas-gateway","nas":true,"time":...}

# 읽기 (빈 워크스페이스)
curl -H "X-Sync-Key: $KEY" \
  "https://sync.aqdesign.co.kr/api/state?ws=ACCYOURWORKSPACE&wait=0"
# → {"exists":false,"rev":0,"gen":0,"entities":{}}

# 쓰기 — 응답의 echo 가 곧 저장 확인서입니다
curl -X POST -H "X-Sync-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"ws":"ACCYOURWORKSPACE","entities":{"tasks/t1":{"id":"t1","title":"테스트","updatedAt":1000}}}' \
  https://sync.aqdesign.co.kr/api/push
# → {"ok":true,"rev":1,"gen":0,"count":1,"echo":{"tasks/t1":1000}}

# 롱폴: 다른 창에서 push 하면 즉시 깨어납니다
curl -H "X-Sync-Key: $KEY" \
  "https://sync.aqdesign.co.kr/api/state?ws=ACCYOURWORKSPACE&rev=1&wait=25"
```

---

## 7. 성능 설계 (실측)

| 항목 | 결과 |
|---|---|
| 일정 300건 문서 전송 | **134,114 B → 3,897 B** (gzip, 34배) |
| 캐시된 읽기 | **31 ms** |
| 저장 확인 | **왕복 1회** (write 응답의 `echo` 가 확인서) |
| 다른 기기 반영 | **쓰기 후 약 370 ms** (롱폴이 깨어남) |
| 유휴 시 요청 수 | 분당 **약 2회** (기존 2초 폴링 = 분당 30회) |

---

## 8. 장애 대응

| 증상 | 원인 / 해결 |
|---|---|
| `nas login failed: {"code":115}` | 로그인을 multipart POST로 보냄. 이 게이트웨이는 GET을 씁니다 — 코드를 수정했다면 되돌리세요 |
| `{"error":{"code":402}}` | `NAS_SESSION` 이 `FileStation` 이 아님 |
| 읽기가 `502` + HTML | 폴더가 아직 없음. 첫 쓰기가 `create_parents=true`로 만듭니다(정상) |
| `code 119` | SID 만료. 게이트웨이가 자동 재로그인합니다 |
| 앱이 `bad key` | `SYNC_SECRET` 과 `SYNC_KEY` 가 다름 |
| 앱은 뜨는데 동기화 안 됨 | mixed content. HTTPS 페이지 → HTTPS 게이트웨이인지 확인 |
| 롱폴이 30초마다 끊김 | 정상입니다. 그때마다 `unchanged`(~40 B)로 답합니다 |

---

## 9. 백업

워크스페이스는 **JSON 파일 하나**입니다. Hyper Backup이나 스냅샷으로
`/92_Scheduler/sync` 만 잡아두면 계정 전체가 백업됩니다.

```bash
# 수동 백업 예시
ssh scheduler@nas "tar czf /92_Scheduler/backup/sync-$(date +%F).tgz -C /92_Scheduler sync"
```

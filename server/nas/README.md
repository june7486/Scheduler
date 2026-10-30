# 내 NAS에 동기화 서버 두기

이 문서는 이승준 님의 **자기 땅에 데이터를 두는** 구성 안내입니다.
Firebase 같은 남의 창고를 빌리지 않고, NAS 한 대에 동기화 서버를 띄웁니다.

- 서버 코드: [`server.js`](./server.js) — 의존성 0개, Node 18+ 또는 Docker
- 앱 설정: **설정 → 내 NAS 서버** 에 주소 입력 후 `저장하고 연결`
- 저장 위치: `DATA_DIR` 안에 **계정(워크스페이스)당 JSON 파일 1개**

---

## 1. 왜 NAS인가 (솔직한 장단점)

| | Firebase (남의 창고) | 내 NAS (내 땅) |
|---|---|---|
| 데이터 소유 | 구글 계정·프로젝트 필요 | 내 디스크, 내 백업 |
| 요금·쿼터 | 무료 한도, 초과 시 과금 | 전기세 외 없음 |
| 요청 제한 | 있음 (이전 설계가 `HTTP 429`로 죽은 이유) | 내 하드웨어, 제한 없음 |
| 보관 기간 | 정책에 따름 | 내가 지우기 전까지 |
| 외부 접속 | 기본 제공 | **직접 열어야 함** (포트포워딩/VPN) |
| HTTPS | 기본 제공 | **직접 붙여야 함** (인증서) |

**핵심**: 앱은 이제 백엔드를 갈아 끼울 수 있게 설계되어 있습니다
(`lib/services/cloud/cloud_backend.dart`). NAS로 바꿔도 화면·자료 구조는
그대로이고, **주소 한 줄만 다릅니다.**

---

## 2. 5분 만에 띄우기 (Docker)

NAS에서 Docker를 쓴다면 이게 가장 빠릅니다. 이 폴더의
`server.js` · `Dockerfile` · `docker-compose.yml` 세 파일을 NAS의 같은 폴더에
넣고 아래를 실행하세요.

```bash
cd /volume1/docker/june-sync
# docker-compose.yml 안의 SYNC_SECRET 을 먼저 바꾸세요
docker compose up -d
```

확인:

```bash
curl http://NAS주소:8099/health
# {"ok":true,"service":"june-sync","time":...}
```

Docker 없이 바로 돌리려면 아래 **직접 실행**으로 넘어가세요.
서버 파일은 `server.js` 하나뿐이라 복사해서 넣으면 끝입니다.

---

## 3. 직접 실행 (가장 단순)

### 3-1. 파일 복사

`server/nas/server.js` 를 NAS의 원하는 폴더에 넣습니다.
예: `/volume1/docker/june-sync/server.js`

### 3-2. 실행

```bash
cd /volume1/docker/june-sync
PORT=8099 \
DATA_DIR=/volume1/docker/june-sync/data \
SYNC_SECRET='충분히-긴-임의의-문자열' \
node server.js
```

`node` 가 없다면:

- **Synology**: 패키지 센터 → Node.js 18 이상 설치
- **QNAP**: App Center → Node.js
- **TrueNAS / 라즈베리파이**: `apt install nodejs` (18+ 필요)

### 3-3. 부팅 시 자동 시작 (systemd)

`/etc/systemd/system/june-sync.service`:

```ini
[Unit]
Description=June Scheduler sync server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/volume1/docker/june-sync
Environment=PORT=8099
Environment=DATA_DIR=/volume1/docker/june-sync/data
Environment=SYNC_SECRET=충분히-긴-임의의-문자열
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=3
User=your-user

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now june-sync
sudo systemctl status june-sync
```

Synology는 **작업 스케줄러 → 부팅 시** 에 위 `node server.js` 명령을 넣어도 됩니다.

---

## 4. 환경 변수

| 이름 | 기본값 | 설명 |
|---|---|---|
| `PORT` | `8099` | 듣는 포트 |
| `DATA_DIR` | `./data` | JSON 파일이 저장될 폴더 |
| `SYNC_SECRET` | (없음) | `X-Sync-Key` 공유 키. **외부에 열 거면 반드시 설정** |

> `SYNC_SECRET` 을 비워두면 서버가 **누구에게나 열립니다.**
> 집 안 와이파이에서만 쓸 때는 괜찮지만, 포트를 외부에 열었다면 필수입니다.

---

## 5. API (직접 확인하고 싶을 때)

```bash
# 살아 있나
curl http://NAS:8099/health

# 문서 읽기 (없으면 exists:false)
curl "http://NAS:8099/api/state?ws=ACCXXXX" -H "X-Sync-Key: 키"

# 쓰기 (last-writer-wins 병합)
curl -X POST http://NAS:8099/api/push \
  -H 'Content-Type: application/json' \
  -H 'X-Sync-Key: 키' \
  -d '{"ws":"ACCXXXX","entities":{"tasks/t1":{"id":"t1","title":"첫 일정","updatedAt":1000}}}'
```

응답 예:

```json
{"exists":true,"rev":1,"entities":{"tasks/t1":{"id":"t1","title":"첫 일정","updatedAt":1000}}}
```

`rev` 를 함께 보내면 바뀐 게 없을 때 아주 작은 응답만 옵니다:

```bash
curl "http://NAS:8099/api/state?ws=ACCXXXX&rev=1"
# {"exists":true,"unchanged":true,"rev":1}
```

---

## 6. ⚠️ HTTPS — 여기서 대부분 막힙니다

앱은 `https://www.aqdesign.co.kr` 에서 열립니다. **브라우저는 https 페이지가
`http://` 주소를 호출하는 것을 차단합니다** (mixed content). 이때 증상은
"NAS 연결 실패"로 보이지만, 실제로는 요청이 나가기도 전에 막힌 것입니다.

설정 화면에서도 이 경우 빨간 경고를 띄웁니다. 세 가지 길이 있습니다.

### 방법 A — NAS에 인증서 + 역프록시 (권장)

Synology DSM: **제어판 → 보안 → 인증서** 에서 Let's Encrypt 발급 →
**응용 프로그램 포털**에서 `https://sync.내도메인.net` → `localhost:8099` 로 연결.

그러면 앱에는 `https://sync.내도메인.net` 만 입력하면 됩니다. 포트도 안 보입니다.

nginx 예시:

```nginx
server {
  listen 443 ssl;
  server_name sync.내도메인.net;

  ssl_certificate     /etc/letsencrypt/live/sync.내도메인.net/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/sync.내도메인.net/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:8099;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 60s;
  }
}
```

### 방법 B — 안드로이드 앱에서 쓰기

앱(APK)은 브라우저가 아니므로 mixed content 제한이 없습니다.
집 안 와이파이에서 `http://192.168.0.20:8099` 를 그대로 쓸 수 있습니다.
**가장 간단하고, 실제로 가장 빨리 되는 길입니다.**

### 방법 C — VPN (Tailscale 등)

외부에서도 쓰고 싶은데 인증서 붙이기가 부담이면 VPN이 정답입니다.
Tailscale을 NAS와 휴대폰에 설치하면 `http://100.x.x.x:8099` 로 사설망 접속이
가능해집니다. (Tailscale은 `https` 도메인도 제공합니다.)

---

## 7. 백업

`DATA_DIR` 폴더만 복사하면 전부입니다. 파일이 계정당 하나라 다루기 쉽습니다.

```bash
# 매일 새벽 3시, 30일 보관
0 3 * * * tar czf /volume1/backup/june-sync-$(date +\%F).tar.gz -C /volume1/docker/june-sync data && \
          find /volume1/backup -name 'june-sync-*.tar.gz' -mtime +30 -delete
```

Synology **Hyper Backup** 으로 `DATA_DIR` 을 잡아도 됩니다. 그게 더 편합니다.

---

## 8. 저장 구조

```
DATA_DIR/
  ACC7F3A...B91.json     ← 계정 1개 = 파일 1개
  ACC2C1D...44E.json     ← 다른 계정
```

파일 안:

```json
{
  "rev": 12,
  "entities": {
    "tasks/3f2a...": {"id":"3f2a...","title":"...","updatedAt":1793369563995},
    "categories/test::todo": {"id":"todo","ownerId":"test","updatedAt":...}
  }
}
```

- **rev**: 저장할 때마다 1씩 증가. 클라이언트가 이 값으로 "바뀐 게 없음"을 판단합니다.
- **entities**: `엔터티/키` → 레코드. 삭제는 `deletedAt` 이 찍힌 tombstone으로 남습니다.
- 병합은 `updatedAt` 이 큰 쪽이 이깁니다 (last-writer-wins).

---

## 9. 문제 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| `NAS 연결 실패` (웹) | https 페이지 → http 주소 | 위 6번 (A/B/C 중 하나) |
| `bad key` / 401 | `SYNC_SECRET` 불일치 | 앱과 서버의 키를 같게 |
| `Connection refused` | 서버 꺼짐 / 포트 다름 | `curl /health` 로 확인 |
| 계속 `연결 대기` | NAS 절전 | 절전 해제 또는 WOL |
| 동기화는 되는데 화면이 그대로 | 기존 대기열 | 설정 → **지금 동기화** |
| 다른 계정 자료가 보임 | 계정이 다름 | 계정당 파일이 분리됩니다. 로그인 확인 |

로그 확인:

```bash
sudo journalctl -u june-sync -f        # systemd
docker logs -f june-sync               # docker
```

---

## 10. 검증된 사실 (테스트로 확인됨)

`test/nas_backend_test.dart` 가 **실제 서버를 띄워서** 다음을 확인합니다:

- 빈 워크스페이스는 `exists:false` — "전부 삭제됨"과 구분됨
- 기기 A가 쓴 일정이 기기 B에 나타남
- 삭제가 tombstone으로 전파됨
- NAS가 꺼진 동안 쓴 글도 다시 켜지면 업로드됨
- 잘못된 키는 실패로 보고됨 (거짓 성공 없음)
- 주소가 앱 재시작 후에도 기억됨

```bash
flutter test test/nas_backend_test.dart
```

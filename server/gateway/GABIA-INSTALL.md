# 가비아 서버 설치 절차서 — June Scheduler

> 작성 기준 커밋 `f999236` (2026-11-20)
> 대상: 가비아 관리자 권한 Linux 가상서버 + Nginx
> 근거: 허브 설계자 협의회신 2026-11-20 + `GABIA-MIGRATION.md`

---

## 0. 이 문서의 위치

`GABIA-MIGRATION.md` 는 **국면(phase)별 전체 계획**입니다 — FTP 업로드부터
DNS 전환, 48시간 관찰, 롤백까지. 이 문서는 그중 **서버 한 대를 실제로
세우는 작업**만 다룹니다. 둘은 경쟁하지 않고 역할이 다릅니다.

| 문서 | 답하는 질문 |
|---|---|
| `GABIA-MIGRATION.md` | **언제, 어떤 순서로** 옮기는가 |
| 이 문서 | 서버에 **무엇을 어떻게 설치**하는가 |
| `DEV-HANDOFF-web-migration.md` | 개발자에게 **무엇을 넘기는가** |

---

## 1. 만들 것 (한눈에)

```
/srv/june7486/sites/scheduler/
├── app/
│   └── server/gateway/server.js      ← 게이트웨이 소스 (읽기 전용)
├── public/                            ← build/web 배포 결과 (Nginx 정적 루트)
├── data/                              ← 로컬 저장 모드의 영구 JSON (쓰기)
├── logs/                              ← Nginx 로그 (쓰기)
└── .env                               ← 게이트웨이 설정 (600, june:june)
```

프로세스는 **둘**입니다:

| 구성요소 | 제공 방식 | 포트 |
|---|---|---|
| Flutter 웹 번들 | Nginx 정적 서비스 | 없음 (443) |
| Node 게이트웨이 | systemd, `127.0.0.1` 전용 | **8097** |

> 협의회신 3번이 지적한 "기존 패키지는 `/` 전체를 4103으로 프록시" 문제를
> 이 구조가 해결합니다. 정적과 API 가 분리되고, 게이트웨이는 밖에서 안 보입니다.

---

## 2. 사전 조건 확인

```bash
# ① root 또는 sudo
sudo -v

# ② Node 22 이상
node --version      # v22.x 이상이어야 함
# 없으면: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
#         sudo apt-get install -y nodejs

# ③ Nginx
nginx -v

# ④ 8097 이 비어 있는지 (협의회신 2번: "가비아 서버에서 포트 충돌 확인")
sudo ss -tlnp | grep 8097 || echo "✅ 8097 비어 있음"
```

> ⚠️ **8097 이 이미 쓰이고 있으면 여기서 멈추세요.** 그 프로세스가 무엇인지
> 먼저 확인해야 합니다. 임의의 다른 포트로 옮기면 협의안(8097)과 어긋납니다.

---

## 3. 계정과 디렉터리

```bash
# 서비스 전용 계정 (로그인 불가)
sudo useradd --system --home /srv/june7486 --shell /usr/sbin/nologin june

# 디렉터리
sudo install -d -o june -g june /srv/june7486/sites/scheduler
sudo install -d -o june -g june /srv/june7486/sites/scheduler/data
sudo install -d -o june -g june /srv/june7486/sites/scheduler/logs
sudo install -d -o june -g june /srv/june7486/sites/scheduler/app
sudo install -d -o www-data -g www-data /srv/june7486/sites/scheduler/public

# 확인
sudo ls -la /srv/june7486/sites/scheduler/
```

> `public/` 만 소유자가 `www-data` 인 이유: Nginx 작업자 프로세스가 그
> 디렉터리를 읽어야 합니다. `data/` 는 게이트웨이(`june`)만 만집니다.

---

## 4. 소스 올리기

개발 환경에서 (이 샌드박스):

```bash
cd /home/user/flutter_app

# 게이트웨이 소스
tar czf /tmp/scheduler-app.tgz \
    server/gateway/server.js \
    server/gateway/package.json \
    server/gateway/june-gateway.service \
    server/gateway/nginx-scheduler-gabia.conf \
    server/gateway/env.gabia.example 2>/dev/null

# 웹 번들
tar czf /tmp/scheduler-public.tgz -C build/web .
```

서버에서:

```bash
sudo tar xzf scheduler-app.tgz -C /srv/june7486/sites/scheduler/app --strip-components=0
sudo chown -R june:june /srv/june7486/sites/scheduler/app

sudo tar xzf scheduler-public.tgz -C /srv/june7486/sites/scheduler/public
sudo chown -R www-data:www-data /srv/june7486/sites/scheduler/public
```

> ⚠️ `build/web` 를 올리기 전에 **누출 검사를 통과해야 합니다.**
> 개발 환경에서 `python3 scripts/check_bundle_secrets.py --strict` 를 먼저
> 돌리세요. `deploy_pages.sh` 와 `auto_deploy.sh` 는 자동으로 합니다.

---

## 5. 설정 파일

### 5-1. `.env`

```bash
sudo cp /srv/june7486/sites/scheduler/app/server/gateway/env.gabia.example \
        /srv/june7486/sites/scheduler/.env
sudo chmod 600 /srv/june7486/sites/scheduler/.env
sudo chown june:june /srv/june7486/sites/scheduler/.env

# SYNC_SECRET 생성해서 채우기
node -e "console.log('SYNC_SECRET=' + require('crypto').randomBytes(32).toString('hex'))"
```

그 값을 `.env` 의 `SYNC_SECRET=` 뒤에 붙여넣습니다.

> **이 값을 이 채팅·메일에 붙이지 마세요.** 별도 보안 채널로 옮기세요.

### 5-2. systemd 유닛

```bash
sudo install -m 644 \
  /srv/june7486/sites/scheduler/app/server/gateway/june-gateway.service \
  /etc/systemd/system/june-gateway.service

sudo systemctl daemon-reload
sudo systemctl enable --now june-gateway

# 상태
sudo systemctl status june-gateway --no-pager
sudo journalctl -u june-gateway -n 30 --no-pager
```

**여기서 반드시 확인 (이게 핵심입니다):**

```bash
# ① loopback 에만 있는가 — 이게 이 구조의 유일한 방어선입니다
sudo ss -tlnp | grep 8097
#   → 127.0.0.1:8097 이어야 정상
#   → 0.0.0.0:8097 또는 *:8097 이면 즉시 멈추고 원인 확인

# ② 응답
curl -sS http://127.0.0.1:8097/health
#   → {"ok":true,"service":"june-nas-gateway","nas":true}

# ③ 준비 상태
curl -sS -i http://127.0.0.1:8097/readyz | head -1
#   → HTTP/1.1 200  (설정이 덜 됐으면 503 + 이유)

# ④ 외부에서 안 닿는가
curl -sS -m 3 "http://$(hostname -I | awk '{print $1}'):8097/health" \
  && echo "❌ 열려 있음 — 즉시 조치" || echo "✅ 안 닿음"
```

> **①이 `0.0.0.0` 이면 나머지는 의미가 없습니다.** 2026-11-20 사건이 정확히
> 그것이었습니다. `HOST` 를 코드 기본값에 맡기지 말고 systemd 유닛에서
> 명시하는 이유입니다.

### 5-3. Nginx

```bash
sudo cp /srv/june7486/sites/scheduler/app/server/gateway/nginx-scheduler-gabia.conf \
        /etc/nginx/sites-available/june-scheduler

# 인증서 경로를 실제 발급 경로로 교체
sudo nano /etc/nginx/sites-available/june-scheduler

sudo ln -sf /etc/nginx/sites-available/june-scheduler \
            /etc/nginx/sites-enabled/june-scheduler

sudo nginx -t && sudo systemctl reload nginx
```

> 인증서가 아직 없으면 `nginx -t` 가 실패합니다. 그때는 DNS 전환 전이므로
> 정상입니다. 인증서 발급 → 그 다음 reload 순서로 가세요.

---

## 6. 검증 — 실측으로만 판정

```bash
# ① 정적
curl -sSI https://www.aqdesign.co.kr/ | head -3

# ② wasm MIME — 틀리면 흰 화면
curl -sSI https://www.aqdesign.co.kr/canvaskit/canvaskit.wasm | grep -i content-type
#   → content-type: application/wasm

# ③ /health 가 게이트웨이 응답인가 (정적 파일이 아니라)
curl -sS https://www.aqdesign.co.kr/health
#   → {"ok":true,...}

# ④ /readyz — 503 이 503 으로 보여야 함
curl -sS -i https://www.aqdesign.co.kr/readyz | head -1

# ⑤ /api/ prefix 보존 — 404 면 proxy_pass 에 슬래시 실수
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "X-Sync-Key: $SYNC_SECRET" \
  "https://www.aqdesign.co.kr/api/state?ws=TESTWS0001"
#   → 200

# ⑥ index.html / version.json 캐시 금지
curl -sSI https://www.aqdesign.co.kr/index.html | grep -i cache-control
curl -sSI https://www.aqdesign.co.kr/version.json | grep -i cache-control

# ⑦ 브라우저에서 실제로 열리는가 — 이게 최종 판정
#    curl 로 200 이어도 앱이 흰 화면이면 실패입니다
```

> 협의회신이 강조한 것: **"검증 대상은 '가비아가 .htaccess를 허용하는가'가
> 아니라 '우리가 설치한 Nginx가 실제 번들을 올바르게 제공하는가'"** 입니다.
> 위 ⑦번이 그 답입니다.

---

## 7. 재부팅 생존 확인

서버에서 가장 흔한 사고는 "재부팅하면 아무것도 안 살아난다"입니다.

```bash
sudo systemctl is-enabled june-gateway   # enabled
sudo systemctl is-enabled nginx          # enabled

# 실제로 재부팅해서 확인 (점검 시간에)
sudo reboot
# 돌아온 뒤
curl -sS http://127.0.0.1:8097/readyz
curl -sS https://www.aqdesign.co.kr/health
```

---

## 8. 로컬 저장 모드의 데이터 이전 (협의회신 5번 후단)

NAS → 로컬로 옮길 때 **두 곳에 동시에 쓰지 마세요.** 협의회신이 명시한
필수 결정 사항입니다:

| 결정 | 정해야 하는 이유 |
|---|---|
| 원본 기준 저장소 | 어느 쪽이 진짜인지 정하지 않으면 병합 사고 |
| 쓰기 중단 시점 | 이전 중 사용자가 쓰면 유실 |
| 최종 동기화 | 마지막 차이를 어떻게 맞출지 |
| 롤백 방법 | 되돌릴 수 있어야 시도할 수 있음 |

절차:

```
1. 사용자 공지: "N시부터 M시까지 쓰지 마세요"
2. STORAGE=dsm 상태에서 최종 읽기 → JSON 스냅숏 저장
3. 스냅숏을 data/ 로 복사
4. .env 를 STORAGE=local 로 변경
5. sudo systemctl restart june-gateway
6. /readyz 200 확인, 앱에서 데이터 보이는지 확인
7. NAS 는 그대로 보존 (지우지 않음) — 롤백 자료
```

> 7번이 중요합니다. "잘 되니까 NAS 정리하자"는 유혹이 있는데, 최소 일주일은
> 두세요. `GABIA-MIGRATION.md` 의 관찰 기간과 같은 이유입니다.

---

## 9. 롤백

```
게이트웨이만 문제      → sudo systemctl restart june-gateway
Nginx 설정만 문제      → sudo cp 이전설정 /etc/nginx/sites-available/... && sudo nginx -t && sudo systemctl reload nginx
번들만 문제            → public/ 이전 스냅숏으로 교체 (deploy_gabia.py --rollback)
전체 문제 (DNS 포함)   → GABIA-MIGRATION.md 국면 4 "즉시 되돌리기"
```

DNS 까지 되돌릴 때는 **TTL 600초(10분)** 을 기억하세요. 그 시간 동안은
일부 사용자가 옛 서버를 봅니다. 그래서 전환은 사용자가 적은 시간에 합니다.

---

## 10. 하지 말 것

| 하지 말 것 | 이유 |
|---|---|
| `HOST=0.0.0.0` | 게이트웨이가 인터넷에 노출. 인증이 공유키 하나뿐 |
| 8097 을 방화벽에서 열기 | Nginx 가 대신 받으므로 열 이유가 없음 |
| `proxy_pass http://127.0.0.1:8097/` (슬래시) | `/api/state` → `/state` 로 바뀌어 전부 404 |
| `index.html` 캐시 허용 | 사용자가 영원히 옛 버전을 봄 |
| `version.json` 캐시 허용 | 업데이트 확인이 조용히 거짓말을 함 |
| `.env` 를 git 에 커밋 | 사이트 탈취 |
| NAS 5001 을 인터넷에 열기 | 2026-11-20 사건의 그 포트 |
| `build/web` 를 검사 없이 업로드 | 번들에 NAS 주소·키가 실려 나감 |

---

## 11. 지금 당장 필요한 것 (사용자만 가능)

```
[ ] 1. 가비아 콘솔에서 FTP 아이디·비밀번호·접속 주소 확인
[ ] 2. 그 값을 .env.gabia 에 입력 (형식은 scripts/env.gabia.example)
[ ] 3. 가비아 홈 디렉터리 경로 확인 (/www 인지 /html 인지)
[ ] 4. python3 scripts/deploy_gabia.py --dry-run 결과 공유
[ ] 5. 서버 SSH 접속 정보 확인 (관리자 권한 Linux 가상서버인지)
```

1번만 오면 나머지는 제가 진행할 수 있습니다.
**DNS 와 SSL 은 원격으로 못 합니다** — 콘솔 접근이 필요합니다.

---

## 12. 기록

| 날짜 | 작업 | 결과 |
|---|---|---|
| 2026-11-20 | 시스템 유닛 작성 | `systemd-analyze verify` 통과 |
| 2026-11-20 | 가비아 Nginx 설정 작성 | `nginx -t` **successful** (nginx 1.26.3) |
| 2026-11-20 | 실측 검증 | 정적 200 · wasm `application/wasm` · /health 프록시 · /readyz 200 · /api 401/200 · prefix 보존 · HTTP→HTTPS 301 · version.json no-cache — **8/8 통과** |
| 2026-11-20 | loopback 바인딩 | `ss` 확인 — `127.0.0.1:8097` 만. 외부 IP 미노출 |
| — | 가비아 실제 설치 | **대기** — FTP/SSH 정보 필요 |

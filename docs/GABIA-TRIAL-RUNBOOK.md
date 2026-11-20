# 가비아 시험 이전 — 실행 절차서 (2026-11-20)

대상: 기존 가비아 Ubuntu 24.04 서버 `june-main-01`
원칙: **기존 허브 문서 루트도, 다른 앱 파일도 건드리지 않습니다.**

---

## 0. 이 문서를 쓰는 순서

1. ZIP 을 서버로 옮긴다 (관리자 직접)
2. **별도 시험 경로**에 압축을 푼다 — 기존 경로와 겹치지 않는 곳
3. 기존 서비스에 손대지 않고 **다른 포트**로만 띄운다
4. 브라우저로 확인한다
5. 확인이 끝나면 **중지하고 흔적을 지운다**

기존 Nginx 설정 파일, 기존 사이트 루트, 기존 서비스 유닛은 **읽지도 쓰지도 않습니다.**

---

## 1. 시험 경로 정하기

기존 경로와 절대 겹치지 않게 `/srv/june-trial-20261120/` 을 씁니다.
(`/var/www` 나 허브 루트 아래를 쓰지 않는 이유: 실수로 병합될 위험을 없애기 위해서입니다)

```
/srv/june-trial-20261120/
├── app/              ← web/ 내용 (정적 파일 49개)
└── trial.conf        ← 이 시험 전용 Nginx 설정 (별도 파일)
```

## 2. 올리기

```bash
sudo install -d -o "$USER" -m 755 /srv/june-trial-20261120
cd /srv/june-trial-20261120
# 관리자가 ZIP 을 이미 올려두었다고 가정
unzip -q scheduler-rel-20261120-*.zip -d unpacked
cp -a unpacked/web app
ls app | head        # index.html main.dart.js flutter_bootstrap.js …
```

## 3. 기존 서비스에 손대지 않고 띄우기 — 두 가지 방법

### 방법 A (권장) — Nginx 설정을 **새 파일로만** 추가

```bash
sudo tee /srv/june-trial-20261120/trial.conf >/dev/null <<'CONF'
server {
    listen 8088;                      # 기존 80/443 을 쓰지 않습니다
    server_name _;
    root /srv/june-trial-20261120/app;
    index index.html;

    # .wasm 은 반드시 이 타입이어야 합니다. 틀리면 흰 화면.
    types { application/wasm wasm; }

    # 진입점과 버전 파일은 캐시 금지
    location = /index.html      { add_header Cache-Control "no-store"; }
    location = /version.json    { add_header Cache-Control "no-store"; }
    location = /flutter_service_worker.js { add_header Cache-Control "no-store"; }

    location / { try_files $uri $uri/ /index.html; }
}
CONF

# 심볼릭 링크로 포함 — 기존 파일은 수정하지 않습니다
sudo ln -sfn /srv/june-trial-20261120/trial.conf /etc/nginx/conf.d/june-trial.conf
sudo nginx -t && sudo systemctl reload nginx
```

> `sites-available`/`sites-enabled` 를 쓰는 서버라면 링크 위치만 그쪽으로 바꾸세요.
> **기존 설정 파일은 열어보기만 하고 저장하지 마세요.**

### 방법 B — Nginx 를 아예 안 건드리기 (가장 안전)

```bash
cd /srv/june-trial-20261120/app
nohup python3 -m http.server 8088 --bind 127.0.0.1 >/tmp/june-trial.log 2>&1 &
```
방화벽을 열지 않아도 되도록 `127.0.0.1` 에만 바인딩하고, 확인은 서버 안에서 합니다:
```bash
curl -sI http://127.0.0.1:8088/ | head -3
```
외부에서 봐야 한다면 SSH 터널만 쓰세요 (방화벽 변경 없이):
```bash
# 관리자 PC 에서
ssh -L 8088:127.0.0.1:8088 <계정>@june-main-01
# 브라우저에서 http://127.0.0.1:8088
```

## 4. 확인 (체크리스트)

| # | 확인 | 기대값 |
|---|---|---|
| 1 | `curl -sI http://127.0.0.1:8088/` | `200`, `Cache-Control: no-store` |
| 2 | `curl -s .../version.json` | `"build":"2026.11.20.1400"` |
| 3 | `.wasm` 응답 헤더 | `Content-Type: application/wasm` |
| 4 | 브라우저 접속 | 로그인 화면이 뜬다 (흰 화면 아님) |
| 5 | 로그인 화면 하단 | `v2026.11.20.1400` |
| 6 | 새로고침 | `404` 없이 그대로 뜬다 |
| 7 | 개발자도구 Network | `main.dart.js` 200 |
| 8 | 동기화 설정 | **건드리지 않음** (기본값 그대로) |

## 5. 중지

```bash
# 방법 A
sudo rm -f /etc/nginx/conf.d/june-trial.conf
sudo nginx -t && sudo systemctl reload nginx

# 방법 B
pkill -f "http.server 8088"
```

## 6. 복구 — 원상태로

```bash
sudo rm -rf /srv/june-trial-20261120
rm -f /tmp/june-trial.log
# 지웠는지 확인
ls /srv | grep june-trial || echo "정리 완료"
sudo nginx -T 2>/dev/null | grep -c june-trial   # 0 이어야 합니다
```

**기존 서비스에 영향이 없었는지 마지막 확인:**
```bash
sudo nginx -t                      # 기존 설정 여전히 정상
systemctl is-active nginx          # active
curl -sI https://<기존 허브 주소>/ | head -1   # 200
```

---

## 하지 말아야 할 것 (이번 시험에서)

- 기존 사이트 루트(`/var/www/...`)에 파일을 넣지 마세요
- 기존 Nginx 설정 파일을 수정하지 마세요
- 80/443 을 시험용으로 쓰지 마세요
- 동기화 게이트웨이(8097)를 켜지 마세요 — 이번 시험은 **정적 웹만** 입니다
- 운영 데이터베이스·허브 데이터를 건드리지 마세요

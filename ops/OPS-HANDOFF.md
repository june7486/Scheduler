# June's Scheduler — 운영 인계 팩

배포센터가 그대로 소비할 수 있도록 만든 기계 판독용 + 사람 판독용 한 쌍입니다.
`RELEASE.json` 이 정본 값이고, 이 문서는 그 값을 **어떻게 쓰는지**를 적습니다.

---

## 0. 현재 상태

```
배포 준비 완료 / 자동배포 연결 대기
```

- 산출물·커밋·해시는 확정되어 있습니다.
- 배포센터 제출 경로는 아직 **연결되지 않았습니다** (401 `NO_PINNED_KEY`).
- 운영(`sch.june7486.com`)은 **여전히 1.0.0** 입니다. 2.0.0 은 올라가지 않았습니다.
- 이 문서는 "무엇을 하면 되는지"이지 "무엇을 했다"가 아닙니다.

---

## 1. 운영 전제 — 가비아 + 시놀로지 NAS

| 역할 | 위치 |
|---|---|
| 웹 (정적 번들) | 가비아 nginx |
| API (게이트웨이) | 가비아, `127.0.0.1:8097` |
| 운영 DB (동기화 자료) | 가비아 로컬 디스크, `STORAGE=local` |
| 백업 · 보관 | 시놀로지 NAS |

**금지 사항** — 아래에 운영을 의존시키지 않습니다.

- Cloudflare Pages · Workers · D1
- GitHub Actions · GitHub Pages
- GitHub 저장소를 운영 경로에 새로 연결하는 것

> 확인 결과: 현재 `lib/` · `server/` 운영 코드에 위 의존은 **없습니다**.
> `.github/workflows/` 도 존재하지 않습니다.
> `server/gateway/README.md` 에 Cloudflare Tunnel 예시가 있으나 **문서일 뿐
> 실행 경로가 아닙니다.** NAS 게이트웨이를 집 밖에 노출하던 옛 대안 설명이며,
> 현 구성은 가비아 nginx 리버스 프록시만 씁니다.

---

## 2. 산출물 — 검증된 ZIP 하나만 씁니다

```json
{
  "filename": "scheduler-op-40777e6-20261124-023403.zip",
  "bytes": 20327512,
  "entries": 53,
  "sha256": "6bd5444c3d7fbb48ec6a671f6f4f8862663e9d26b4aab431cd15f9b358452a43",
  "commit_full": "40777e66f2e13b127d07b59f94644346298f8ccc",
  "rebuilt_for_release": false
}
```

**다시 만들지 마십시오.** 이 ZIP 은 커밋 `40777e6` 시점의 `build/web` 을
그대로 담았습니다. 다시 빌드하면 `version.json` 이 기본값으로 덮이고 해시가
달라집니다. 새로 만든 ZIP 을 "같은 릴리스"라고 부르면 안 됩니다.

### 먼저 해시를 대조하십시오

```bash
sha256sum scheduler-op-40777e6-20261124-023403.zip
# 6bd5444c3d7fbb48ec6a671f6f4f8862663e9d26b4aab431cd15f9b358452a43
stat -c%s scheduler-op-40777e6-20261124-023403.zip
# 20327512
```

다르면 멈추십시오. 그 ZIP 은 이 릴리스가 아닙니다.

### 자동 검증 (읽기 전용)

```bash
bash ops/verify-release.sh scheduler-op-40777e6-20261124-023403.zip
```

해시·크기·엔트리 수·필수 파일·**비밀값 혼입 여부**·`version.json` 내용·
커밋 표식·압축 무결성을 한 번에 봅니다. 파일을 만들지도 지우지도 않고,
압축을 풀지도 않습니다. 통과하면 종료 코드 0, 불일치면 1 입니다.

비밀값 혼입 검사는 `data/`, `.env`, `*.key`, `*.pem`, `id_rsa`,
`.htaccess`, `CNAME` 을 찾습니다. 하나라도 있으면 실패로 처리합니다.

### 들어 있는 것 / 없는 것

```
build/web/          앱 정적 번들
server/gateway/     server.js, start.sh, systemd 유닛, nginx 설정,
                    보안 헤더, .env.example   ← 값이 아닌 견본
DEPLOYED_COMMIT.txt 어느 커밋의 산출물인지 적은 표식
```

없는 것과 이유:

| 빠진 것 | 이유 |
|---|---|
| `data/` | 운영 자료입니다. 절대 ZIP 에 넣지 않습니다 |
| `.env` | 동기화 키입니다. 견본만 넣습니다 |
| `*.key`, `*.pem` | 개인키입니다 |
| `recover.html` | 가비아 **공유호스팅**용 자료 복구 도구 |
| `.htaccess` | Apache 전용 (공유호스팅용). nginx 무관 |
| `CNAME` | GitHub Pages 용 |
| `tests/`, `scripts/` | 시험·진단. 기동에 불필요 |

게이트웨이는 Node 내장 모듈(`crypto`, `fs`, `http`, `https`, `path`, `zlib`)
만 씁니다. `package.json` 도 `node_modules` 도 필요 없습니다.

---

## 3. 배치 경로

```
/srv/june7486/sites/scheduler/
├── app/          ← ZIP 을 여기에 풉니다
│   ├── build/web/
│   └── server/gateway/
├── data/         ← 운영 DB (로컬)
└── .env          ← 동기화 키 등 (600, app/ 안이 아님)
```

systemd 유닛이 이 배치를 전제로 합니다.

```ini
[Service]
User=june
Group=june
WorkingDirectory=/srv/june7486/sites/scheduler/app
EnvironmentFile=-/srv/june7486/sites/scheduler/.env
Environment=PORT=8097
Environment=HOST=127.0.0.1
Environment=STORAGE=local
Environment=DATA_DIR=/srv/june7486/sites/scheduler/data
ExecStart=/usr/bin/node server/gateway/server.js
Restart=always
RestartSec=3
```

> `.env` 가 `app/` 밖에 있는 것이 중요합니다. `app/` 를 통째로 교체해도
> 키가 따라가지 않습니다. 유닛 파일은 ZIP 의 견본을 그대로 쓰지 말고
> **경로를 확인한 뒤** 설치하십시오.

---

## 4. 기동

### 4-1. 먼저 스스로 뜨는지 본다 (서비스에 손대지 않음)

```bash
cd /path/to/unzipped/server/gateway

SYNC_SECRET=selftest-only-not-a-real-key \
DATA_DIR=/tmp/selftest-data \
node server.js --selftest
rm -rf /tmp/selftest-data
```

네 항목이 나옵니다: `storage`, `auth`, `download`, `upload`.

**주의** — `SYNC_SECRET` 없이 돌리면 `auth` 가
`FAIL — OPEN (LAN only!)` 로 나옵니다. 게이트웨이 고장이 아니라
"아직 키를 주지 않았다"는 뜻입니다. 위처럼 점검용 임시 키를 주고,
그때 생기는 임시 디렉터리는 **반드시 지우십시오.** 남기면 "빈 저장소로
시작한다"는 약속이 그 자리에서 깨집니다.

### 4-2. 서비스로 기동

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now june-gateway.service
```

---

## 5. 상태 확인

### 5-1. 생존 — `/health`

```bash
curl -s https://sch.june7486.com/health
# {"ok":true,"service":"june-nas-gateway","nas":true}
```

판정: `200` + `ok:true` + `service:"june-nas-gateway"`.

`service` 값을 꼭 보십시오. 같은 호스트에서 DSM 로그인 페이지가 200 으로
답할 수 있고, 그것과 구분하는 유일한 표식입니다.

`nas` 필드는 **저장소 비트**입니다. `STORAGE=local` 에서는 "자료 디렉터리에
쓸 수 있다"는 뜻이고, NAS 에 닿았다는 뜻이 아닙니다. 이름이 NAS 시절 그대로인
것은 앱이 이 값을 읽고 있어 바꾸면 재빌드가 필요하기 때문입니다.

### 5-2. 트래픽 수용 여부 — `/readyz`

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://sch.june7486.com/readyz
# 200
```

준비 안 됨이면 `503` + `{"ready":false,"reason":"config|auth|storage"}`.

`/health` 와 분리된 이유가 있습니다. `/readyz` 의 `503` 을 nginx 가 `502` 로
바꾸면 "준비 안 됨"과 "게이트웨이 죽음"이 구분되지 않습니다.
`proxy_intercept_errors` 는 **끄고** 두십시오.

### 5-3. 버전

```bash
curl -s https://sch.june7486.com/version.json
```

`"version":"2.0.0"` + `"build":"2026.11.24.0137"` 이어야 합니다.

### 5-4. 완료 판정 — 이걸로 판정하지 마십시오

```
/api/ 가 401  →  게이트웨이가 살아 있고 키를 요구한다는 뜻
                 "동기화가 된다"는 뜻이 아닙니다
```

완료 여부는 사람 손으로 확인합니다.

1. 시크릿 창에서 열어 일정이 **비어 있다**
2. 일정 하나를 저장한다
3. 새로고침해도 **남아 있다**
4. 다른 기기에서 같은 계정으로 열면 **보인다**
5. 그 일정을 지우면 다른 기기에서도 **사라진다**

5번까지 가야 "동기화가 된다"고 말할 수 있습니다. 4번에서 멈추면
삭제가 전파되지 않는 결함을 놓칩니다.

---

## 6. 복구

### 6-1. 서비스가 안 뜰 때

```bash
systemctl status june-gateway.service
journalctl -u june-gateway -n 50 --no-pager
```

자주 나오는 세 가지:

| 증상 | 원인 | 조치 |
|---|---|---|
| `EADDRINUSE` | 8097 을 다른 프로세스가 잡음 | `ss -ltnp \| grep 8097` |
| `EACCES` (data) | `data/` 소유자가 `june` 이 아님 | `chown -R june:june data` |
| `/readyz` `reason:auth` | `.env` 의 `SYNC_SECRET` 누락 | `.env` 채우고 재기동 |

`STORAGE=local` 인데 `DATA_DIR` 이 없으면 기동 후 `reason:storage` 가 됩니다.

### 6-2. 이전 배포본으로 되돌리기

교체 전 배포본을 지우지 않고 옮겨 두는 것이 이 패키지의 규칙입니다.

```bash
sudo systemctl stop june-gateway.service
sudo mv /srv/june7486/sites/scheduler/app /srv/june7486/sites/scheduler/app.broken
sudo mv /srv/june7486/sites/scheduler-old/app /srv/june7486/sites/scheduler/app
sudo systemctl start june-gateway.service
sleep 3
curl -sf -m 5 http://127.0.0.1:8097/health && echo "복구됨"
```

되돌린 뒤 `version.json` 도 함께 되돌아갔는지 확인하십시오. 정적 번들과
게이트웨이는 같은 ZIP 출신이어야 합니다.

### 6-3. 자료

교체 시 기존 `data/` 는 **삭제하지 않고** `.scheduler-data-<시각>` 으로
옮겨 둡니다. 새 설치는 빈 저장소로 시작합니다.

```bash
ls -d /srv/june7486/sites/.scheduler-data-*
```

이전 일정을 되살리려면 그 디렉터리를 `data/` 로 옮기고 재기동하십시오.
**옮길지 말지는 사람이 결정합니다.** 자동으로 합치지 않습니다.

---

## 7. nginx

설정은 **하나만** 씁니다: `nginx-scheduler-sch.conf` (`server_name sch.june7486.com`).
중복 설정 파일을 만들지 마십시오. 세 개의 location 이 전부입니다.

```nginx
location = /health  { proxy_pass http://june_gateway_sch; }
location = /readyz  { proxy_pass http://june_gateway_sch; }
location /api/      { proxy_pass http://june_gateway_sch; }   ← 슬래시 없음
```

**함정** — `/api/` 의 `proxy_pass` 에 끝 슬래시를 붙이면 nginx 가
`/api/state` 를 `/state` 로 바꿔 넘깁니다. 증상이 "게이트웨이는 살아 있는데
앱만 동기화 실패"라서 원인을 찾기 어렵습니다.

정적 서빙 `root` 는 `app/build/web` 을 가리켜야 합니다.

---

## 8. 배포센터 제출 계약

```http
POST /api/v1/releases?app=scheduler
X-Release-Manifest: <raw JSON>
X-Manifest-Signature: <base64 Ed25519 서명>
```

- `app` 은 **본문이 아니라 쿼리**로 보냅니다.
- 매니페스트는 **raw JSON** 이어야 합니다. base64 로 감싸면 `MISSING_MANIFEST`.
- 서명 대상은 **매니페스트 원본 바이트 그대로**입니다. 서명한 뒤 한 글자도
  바꾸면 안 됩니다.
- 매니페스트 안의 `app` 과 쿼리의 `app` 이 같아야 합니다.

```bash
openssl pkeyutl -sign -inkey <private.key> -rawin -in manifest.json | base64 -w0
```

응답 코드:

| 코드 | 오류 | 뜻 |
|---|---|---|
| 400 | `MISSING_APP` | `?app=` 없음 |
| 400 | `MISSING_MANIFEST` | 헤더 없음 또는 base64 로 감쌈 |
| 400 | `MANIFEST_APP_MISMATCH` | 매니페스트의 app 불일치 |
| 401 | `NO_PINNED_KEY` | **현재 막힌 지점** |

### 서명 키

```
알고리즘  Ed25519
Key ID    3057A14449EFC470
공개키    MCowBQYDK2VwAyEA2YgKyW8re959hMwNj1mcahQvVauyeFJbFAF5diC8Xag=
```

공개키는 공개 값입니다. 등록은 배포센터 **화면**에서 관리자가 합니다.
등록 API 는 없습니다 (`/api/v1/keys` 등 모두 404).

**무인 운영은 아직 불가능합니다.** 개인키가 지속 저장소에 없습니다.
샌드박스가 초기화되면 개인키가 사라지고, 등록된 공개키는 무용지물이 됩니다.
KMS·비밀 관리 서비스·관리자가 지정한 서버 경로 중 하나가 정해져야
"자동 제출"이라고 부를 수 있습니다.

---

## 9. 하지 말 것

- ZIP 을 다시 빌드하거나 새로 만들어 "같은 릴리스"라고 부르기
- `data/` · `.env` · 개인키를 ZIP 이나 배포센터에 넣기
- nginx 설정 파일을 새로 만들기 (기존 하나만)
- `/api/` `proxy_pass` 에 끝 슬래시 붙이기
- `/api/` 401 을 동기화 성공 근거로 삼기
- 기존 자료를 자동으로 지우거나 합치기
- DNS · 인증서 · `www.aqdesign.co.kr` · 허브 · 배포센터 건드리기
- Cloudflare · GitHub 을 운영 경로에 새로 연결하기

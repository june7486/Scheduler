# 가비아 이전 절차서 — 그리고 언제든 되돌리는 방법

> **작성 2026-11-20**
> **현재 상태** `www.aqdesign.co.kr` → `CNAME june7486.github.io` (TTL 600초), GitHub Pages 서빙 중
> **목표** 가비아 웹호스팅으로 서빙 이전, 단 **언제든 되돌릴 수 있게**

---

## 0. 먼저 — 이 문서를 읽는 순서

이전은 **한 번에 끝나지 않습니다.** 다섯 국면이 있고, 각 국면마다 되돌리는
지점이 다릅니다. 급하게 DNS부터 바꾸면 나머지를 되돌릴 수 없습니다.

| 국면 | 무엇을 하나 | 되돌리기 |
|---|---|---|
| **1. 준비** | 가비아에 파일 올리기, DNS는 그대로 | 파일만 지우면 됨. 사용자는 아무 변화 없음 |
| **2. 검증** | 새 주소로 접속해 확인 (임시 도메인) | 아직 사용자 경로 아님. 그냥 중단 |
| **3. 전환** | DNS를 가비아로 | **DNS를 되돌리면 됨** (10분 내 복구) |
| **4. 관찰** | 48시간 지켜보기 | DNS 되돌리기 (아직 GitHub 살아 있음) |
| **5. 확정** | GitHub Pages 비활성화 | ⚠️ **여기서부터 되돌리기 어려움** |

**5국면 전까지는 GitHub Pages가 그대로 살아 있습니다.** 그게 최대 안전장치입니다.
DNS만 되돌리면 즉시 원상복구됩니다. 그러니 5국면은 **최소 일주일 뒤**에 하십시오.

---

## 0-1. ⚠️ 이전 전에 반드시 — 배포본 누출 검사

이전 절차보다 **먼저** 처리해야 할 것이 있습니다. 2026-11-20 에 확인한 사실:

```
build/web/main.dart.js 오프셋 2,920,179
  "https://sync.<호스트>.direct.quickconnect.to"
```

> 주소를 지운 이유: 이 문서가 제출 패키지에 들어갑니다. 사고를 설명하려고
> 실제 주소를 적어두면, 그 패키지가 같은 주소를 다시 유통시킵니다.

현재 배포본에는 NAS 주소가 들어 있고, 그 번들은 공개 서빙됩니다.
**가비아로 그대로 옮기면 같은 노출이 새 서버로 이사만 합니다.**

이전 전에:

```bash
python3 scripts/check_bundle_secrets.py --strict   # 차단 대상 0건이어야 함
```

0건이 아니면 **`SYNC_URL` / `SYNC_KEY` 없이 다시 빌드**하세요. 설정 화면에
주소 입력란이 있으므로 심지 않아도 동작합니다.

```bash
flutter build web --release --base-href "/" \
  --dart-define=BUILD_ID="$(date +%Y.%m.%d.%H%M)"
```

`scripts/auto_deploy.sh` 는 이 검사를 자동으로 돌리고, 실패하면 배포하지
않습니다. 자세한 배경은 `INCIDENT-2026-11-20.md` 를 보세요.

---

## 1. 국면 1 — 파일 올리기 (DNS 손대지 않음)

### 1-1. 가비아 FTP 정보 확인

가비아 콘솔 → **나의서비스관리** → **호스팅 관리** → **FTP/DB 관리**

여기서 확인할 것:

- **FTP 아이디** (보통 `도메인앞부분` 또는 별도 지정)
- **FTP 비밀번호**
- **FTP 접속 주소** (예: `ftp.aqdesign.co.kr` 또는 `도메인.gabia.io`)
- **홈 디렉터리** — 보통 `/www` 또는 `/html`

> ⚠️ **`/www` 와 `/html` 을 잘못 고르면 404 가 됩니다.** 가비아 콘솔에서
> "홈 디렉터리" 또는 "Document Root" 라고 적힌 경로를 그대로 쓰십시오.
> 확실하지 않으면 FTP 로 접속해 `ls` 해보고, `index.html` 이 있어야 할 자리를
> 확인하는 편이 빠릅니다.

### 1-2. 배포 설정 파일 만들기

```bash
cd /home/user/flutter_app

cat > .env.gabia <<'EOF'
GABIA_PROTOCOL=ftps
GABIA_HOST=ftp.aqdesign.co.kr
GABIA_PORT=21
GABIA_USER=여기에_FTP_아이디
GABIA_PASS=여기에_FTP_비밀번호
GABIA_PATH=/www
GABIA_PASSIVE=1
EOF

chmod 600 .env.gabia
```

> `.env.gabia` 는 `.gitignore` 에 등록되어 있습니다. 커밋되지 않습니다.
> `scripts/auto_deploy.sh` 는 이 파일이 git 에 추적되면 **거부하고 멈춥니다** —
> 한 번 커밋되면 파일을 지워도 히스토리에 남기 때문입니다.

### 1-3. 연결만 확인 (아무것도 올리지 않음)

```bash
python3 scripts/deploy_gabia.py --dry-run
```

성공하면 이렇게 나옵니다:

```
① 올릴 파일 목록 작성...
  ✅ .htaccess 적용 (wasm MIME, index.html no-cache)
  ✅ 43개 파일, 21.9 MB
      마지막에 올릴 파일: index.html
  ✅ --dry-run: 아무것도 전송하지 않았습니다.
```

### 1-4. 실제 업로드

```bash
python3 scripts/deploy_gabia.py
```

이 스크립트가 자동으로 하는 일:

1. **서버 현재 상태를 먼저 내려받아 스냅숏** (`.deploy/releases/…/rollback/`)
2. 파일 업로드 — **`index.html` 을 맨 마지막에**
3. 서버에서 다시 내려받아 **SHA-256 비교 검증**
4. 검증 실패 시 **자동 롤백 + 롤백 검증**

> ### 왜 `index.html` 이 마지막인가
> 업로드 도중 실패하면 서버에 새 파일과 옛 파일이 섞입니다. `index.html` 이
> 먼저 올라가 있으면 사용자는 새 index 를 받고 옛 `main.dart.js` 를 받아
> **흰 화면**을 봅니다. 마지막에 올리면, 중간에 죽어도 사용자는 계속 옛
> 버전을 봅니다. 반쯤 깨진 새 버전보다 낫습니다.

### 1-5. 검증 — 사용자 경로가 아닌 곳에서

DNS를 아직 안 바꿨으므로 `www.aqdesign.co.kr` 은 여전히 GitHub Pages 입니다.
가비아에 올린 것을 확인하려면 **임시 주소**를 씁니다.

가비아가 제공하는 임시 주소 형태 (콘솔에서 확인):

```
http://아이디.gabia.io/          또는
http://aqdesign.co.kr.가비아제공호스트/
```

또는 `/etc/hosts` 를 임시로 고쳐서 확인:

```bash
# 가비아 서버 IP 를 먼저 확인
dig +short ftp.aqdesign.co.kr     # 또는 콘솔에 적힌 서버 IP

# /etc/hosts 에 임시 추가 (나중에 반드시 삭제)
echo "1.2.3.4  www.aqdesign.co.kr" | sudo tee -a /etc/hosts
# 확인 후
sudo sed -i '/www.aqdesign.co.kr/d' /etc/hosts
```

### 1-6. 반드시 확인할 체크리스트

브라우저 개발자도구를 열고 확인하십시오. **이 5개가 전부 통과해야** DNS를 바꿉니다.

```
[ ] 1. 페이지가 뜨는가 (흰 화면이 아닌가)
[ ] 2. main.dart.js  Content-Type: application/javascript
[ ] 3. canvaskit.wasm  Content-Type: application/wasm     ← 가장 중요
[ ] 4. index.html  Cache-Control: no-cache
[ ] 5. 로그인이 되고 일정이 보이는가 (동기화)
```

3번이 `application/octet-stream` 이면 **흰 화면**이 됩니다. `.htaccess` 가
제대로 올라갔는지 확인하십시오:

```bash
python3 - <<'EOF'
# .htaccess 가 서버에 있는지만 확인
import sys; sys.path.insert(0,'scripts')
from deploy_gabia import load_env, make_transport
cfg = load_env()
t = make_transport(cfg); t.connect()
print(".htaccess 존재:", t.download('.htaccess', __import__('pathlib').Path('/tmp/ht')))
t.close()
EOF
```

---

## 2. 국면 2 — 검증 (아직 DNS 안 바꿈)

1-6 체크리스트를 **모바일과 데스크톱 양쪽에서** 확인합니다. 특히:

- **아이폰 Safari** — 이전에 문제가 있었던 환경입니다
- **시크릿 창** — 캐시 없는 상태
- **로그인 → 일정 추가 → 새로고침 → 남아있는가** (동기화 확인)

여기서 문제가 있으면 **그냥 중단하십시오.** DNS를 안 건드렸으므로 사용자는
아무 영향도 받지 않았습니다. 가비아 파일을 지우면 끝입니다.

---

## 3. 국면 3 — DNS 전환

### 3-1. 전환 전에 현재 값을 반드시 적어두기

**지금 이 순간의 값입니다. 되돌릴 때 그대로 입력해야 합니다.**

```
www.aqdesign.co.kr   CNAME   june7486.github.io.   TTL 600
```

> TTL 600초 = 10분. 이 값이 짧아서 다행입니다. DNS를 되돌리면 **10분 안에**
> 전 세계가 GitHub Pages 로 돌아옵니다. TTL 이 3600 이었다면 1시간이 걸립니다.

### 3-2. 가비아 DNS 관리 화면에서

가비아 콘솔 → **DNS 관리** → `aqdesign.co.kr` 선택

| 타입 | 호스트 | 기존 값 | 새 값 |
|---|---|---|---|
| CNAME | `www` | `june7486.github.io.` | 가비아 콘솔이 알려주는 값 (보통 `www.aqdesign.co.kr` 자체 또는 서버 호스트명) |

**A 레코드는 건드리지 마십시오.** apex(`aqdesign.co.kr`) 도메인은 지금도
GitHub Pages 를 가리키고 있고, 그건 그대로 두는 편이 안전합니다. 사용자는
`www` 로 들어옵니다.

> 가비아 공유호스팅에 도메인을 연결하면 보통 **CNAME 을 자기 자신으로** 두거나,
> 가비아가 지정한 호스트명을 쓰라고 안내합니다. 콘솔 안내를 따르십시오 —
> 여기에 적힌 값보다 콘솔이 정확합니다.

### 3-3. 전환 확인

```bash
# DNS 전파 확인 (10분쯤 뒤부터)
watch -n 30 'dig +short www.aqdesign.co.kr CNAME; echo "---"; dig +short www.aqdesign.co.kr A'
```

`june7486.github.io` 가 사라지고 가비아 서버 IP 가 나오면 전파 완료입니다.

### 3-4. HTTPS 인증서

가비아 공유호스팅은 대부분 **무료 Let's Encrypt 를 콘솔에서 버튼으로** 발급합니다.

- SSL 관리 메뉴에서 `www.aqdesign.co.kr` 인증서 신청
- 발급까지 수 분~수십 분
- **DNS 전파 후에 신청해야** 발급됩니다 (도메인 소유 확인을 DNS로 하므로)

> ⚠️ 인증서가 발급되기 전까지 `https://` 가 인증서 오류를 낼 수 있습니다.
> 그 사이 `http://` 로 접속하면 됩니다. 이 구간이 길어지면 DNS를 되돌리는
> 편이 낫습니다 — 사용자에게 경고 화면을 보여주는 것보다 낫습니다.

---

## 4. 국면 4 — 관찰 (48시간)

### 지켜볼 것

```bash
# 1분마다 상태 확인
watch -n 60 'curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://www.aqdesign.co.kr/'

# 앱이 완전히 로드되는지 (index + bundle 둘 다)
curl -s https://www.aqdesign.co.kr/ | grep -o 'main.dart.js' | head -1
curl -s -o /dev/null -w "bundle: %{http_code} %{size_download} bytes\n" \
  https://www.aqdesign.co.kr/main.dart.js
```

### 이 기간에 문제가 생기면 — 즉시 되돌리기

**국면 5 전이므로 GitHub Pages 가 그대로 살아 있습니다.**

```
1. 가비아 DNS 관리 → www CNAME 을  june7486.github.io.  로 되돌린다
2. 10분 대기
3. dig +short www.aqdesign.co.kr  →  june7486.github.io. 확인
```

끝입니다. 인증서를 이미 발급했다면 그건 그대로 두어도 무해합니다.

> ### 왜 48시간인가
> DNS TTL 600초는 "캐시를 10분만 보관해도 된다"는 뜻이지 "10분 뒤 모두
> 갱신된다"는 뜻이 아닙니다. 일부 ISP 와 기업 프록시는 TTL 을 무시하고
> 수 시간~수 일 캐시합니다. 그 뒤에 나타나는 문제가 가장 무섭습니다 —
> 우리는 이미 괜찮다고 결론내린 상태니까요.

---

## 5. 국면 5 — 확정 (최소 일주일 뒤)

이 시점부터 **되돌리기가 어려워집니다.** 그 전에 확신이 서야 합니다.

```
[ ] 국면 4 에서 48시간 무사고
[ ] 아이폰·안드로이드·데스크톱 모두 정상
[ ] 로그인·동기화 3일 이상 정상
[ ] 게이트웨이(동기화 서버)도 정상 동작
```

그 다음에:

1. GitHub 저장소 → Settings → Pages → Source: **None**
2. (선택) 저장소 → Settings → Pages → Custom domain 비우기
3. 가비아 DNS 의 apex A 레코드(185.199.x.x)를 가비아 서버로 변경 — **원할 때만**

> ### 그래도 GitHub 은 지우지 마십시오
> 저장소를 남겨두면 최후의 롤백 수단이 됩니다. 5국면 이후에도 GitHub Pages 를
> 다시 켜고 DNS만 되돌리면 복구됩니다. 저장소를 삭제하는 것은 **진짜로
> 되돌릴 수 없는 유일한 행동**입니다.

---

## 6. 배포 — 이제부터 자동

### 수동 배포

```bash
cd /home/user/flutter_app
./scripts/auto_deploy.sh
```

이 스크립트가 하는 일:

```
1/5 저장소 상태 확인   → 커밋 안 된 변경이 있으면 거부
2/5 설정 확인         → .env.gabia 존재 + 권한 600 + git 미추적
3/5 정적 분석         → flutter analyze, 컴파일 오류면 중단
4/5 빌드              → BUILD_ID 자동 주입, 폰트 경량화
5/5 배포              → 업로드 + 해시 검증 + 실패 시 자동 롤백
```

### 자동 배포 (커밋하면 자동으로)

```bash
# 방법 A — 커밋마다 (빠르지만 위험: 작업 중 커밋도 배포됨)
ln -sf ../../scripts/auto_deploy.sh .git/hooks/post-commit
chmod +x .git/hooks/post-commit

# 방법 B — 태그를 붙일 때만 (권장)
cat > .git/hooks/post-tag <<'EOF'
#!/usr/bin/env bash
cd "$(git rev-parse --show-toplevel)"
./scripts/auto_deploy.sh
EOF
chmod +x .git/hooks/post-tag
```

**방법 B 를 권합니다.** 이유:

- 커밋은 "저장"이고 배포는 "공개"입니다. 둘은 다른 의사결정입니다
- 작업 중 커밋(오타 수정, WIP)까지 배포되면 사용자가 그걸 보게 됩니다
- 태그는 의도가 명시적입니다: `git tag deploy-1115 && git push --tags`

> ### 왜 hook 에서 빌드까지 하나
> hook 에서 `git push` 만 하는 방식도 있습니다. 하지만 그러면 **가비아에
> 무엇이 올라갔는지 아무도 모릅니다.** 빌드와 배포를 같은 자리에서 하면
> `BUILD_ID` 가 앱 화면에 표시되어 "이게 어느 배포인지" 확인할 수 있습니다.

---

## 7. 롤백 — 배포를 되돌리기

### 가장 최근 배포 취소

```bash
python3 scripts/deploy_gabia.py --rollback
```

이 스크립트가 하는 일:

1. 가장 최근 릴리스에서 **배포 직전 서버 상태 스냅숏**을 찾는다
2. 파일을 복원한다 (**`index.html` 은 마지막에** — 같은 이유)
3. **서버에서 다시 내려받아 해시를 비교해 복원을 검증한다**
4. 검증 실패하면 **소리내어 실패한다** — 조용히 실패하는 롤백은 없느니만 못하다

### 특정 시점으로

```bash
python3 scripts/deploy_gabia.py --list
```

```
  스냅숏 목록 (최신순):

    20261120T143012Z-deploy
        배포 43개 · 되돌리기 42개 · 복원가능
    20261119T091500Z-deploy
        배포 43개 · 되돌리기 41개 · 복원가능
```

```bash
python3 scripts/deploy_gabia.py --rollback --snapshot 20261119
```

### 스냅숏은 어디에 있나

```
.deploy/releases/<시각>-deploy/
    manifest.json      이번에 올린 파일 목록 + 해시
    rollback/
        snapshot.json  배포 전 서버 상태
        files/         배포 전 파일 실물
```

**지우지 않습니다.** 용량이 문제가 되면 오래된 것만 골라 지우십시오:

```bash
# 30일 지난 스냅숏 정리 (선택)
find .deploy/releases -maxdepth 1 -type d -mtime +30
```

---

## 8. 전체 되돌리기 시나리오 (한눈에)

| 사고 | 되돌리는 법 | 걸리는 시간 |
|---|---|---|
| 배포했더니 흰 화면 | `deploy_gabia.py --rollback` | 2~3분 |
| 배포 중 실패 | 자동 롤백됨 (스크립트가 함) | 자동 |
| DNS 바꿨더니 사이트 안 뜸 | 가비아 DNS에서 CNAME 원복 | 10분 |
| HTTPS 인증서 오류 | 임시로 http 사용, 안 되면 DNS 원복 | 10분 |
| 며칠 뒤 동기화 안 됨 | DNS 원복 → GitHub Pages 복귀 | 10분 |
| 전부 원상복구 | 위 항목 중 해당하는 것 | 최대 10분 |

**국면 5 전까지는 어떤 사고도 10분 안에 되돌릴 수 있습니다.**

---

## 9. 지금 당장 필요한 것 (사용자가 해야 할 일)

제가 대신 할 수 없는 것들입니다:

```
[ ] 1. 가비아 콘솔에서 FTP 아이디·비밀번호·접속 주소 확인
[ ] 2. 그 값을 .env.gabia 에 입력 (제가 형식을 잡아뒀습니다)
[ ] 3. 가비아 홈 디렉터리 경로 확인 (/www 인지 /html 인지)
[ ] 4. python3 scripts/deploy_gabia.py --dry-run 실행해서 저에게 결과 공유
[ ] 5. 실제 업로드 후 임시 주소로 검증
[ ] 6. DNS 전환 (콘솔에서 직접)
[ ] 7. SSL 인증서 신청 (콘솔에서 직접)
```

1번만 알려주시면 나머지는 제가 진행할 수 있습니다. **DNS와 SSL 은 제가
원격으로 못 합니다** — 콘솔 접근이 필요합니다.

---

## 10. 기록

| 날짜 | 작업 | 결과 |
|---|---|---|
| 2026-11-20 | 현재 DNS 확인 | `www` → `CNAME june7486.github.io.` TTL 600 |
| 2026-11-20 | 배포 스크립트 작성 | `scripts/deploy_gabia.py` |
| 2026-11-20 | 로컬 FTP 서버로 실증 | **11/11 통과** — 배포·검증·롤백·복원검증 |
| 2026-11-20 | 자동 배포 스크립트 | `scripts/auto_deploy.sh` (4중 문턱) |
| 2026-11-20 | `.htaccess` 작성 | wasm MIME, index no-cache, SPA 폴백 |
| (대기) | 가비아 FTP 정보 입력 | — |
| (대기) | 실제 업로드 | — |
| (대기) | DNS 전환 | — |

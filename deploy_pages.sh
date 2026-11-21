#!/usr/bin/env bash
# =============================================================================
# June's Scheduler — GitHub Pages 원클릭 배포 스크립트
# -----------------------------------------------------------------------------
# 사용법:
#   GH_REPO="아이디/저장소명" ./deploy_pages.sh              # 프로젝트 페이지
#   GH_REPO="아이디/저장소명" ./deploy_pages.sh custom       # 커스텀 도메인(루트)
#
# 예) GH_REPO="seungjun/june-scheduler" ./deploy_pages.sh
# =============================================================================
set -euo pipefail

PROJECT_DIR="/home/user/flutter_app"
GH_REPO="${GH_REPO:?환경변수 GH_REPO 를 지정하세요 (예: 아이디/저장소명)}"
OWNER="${GH_REPO%%/*}"
REPO_NAME="${GH_REPO##*/}"
MODE="${1:-project}"          # project | custom

# ---- base href 결정 -------------------------------------------------------
# 프로젝트 페이지: https://<owner>.github.io/<repo>/  -> /<repo>/
# 사용자/조직 페이지(<owner>.github.io) 또는 커스텀 도메인: 루트 "/"
if [ "$MODE" = "custom" ] || [ "$REPO_NAME" = "${OWNER}.github.io" ]; then
  BASE_HREF="/"
else
  BASE_HREF="/${REPO_NAME}/"
fi

echo "▶ 저장소       : ${GH_REPO}"
echo "▶ 배포 모드    : ${MODE}"
echo "▶ base href    : ${BASE_HREF}"
echo

cd "$PROJECT_DIR"

# ---- 1) 인증 확인 ---------------------------------------------------------
echo "① GitHub 인증 확인..."
if ! git config --global --get credential.helper >/dev/null 2>&1 && [ ! -f "$HOME/.git-credentials" ]; then
  echo "   ⚠️  GitHub 자격증명이 없습니다. 샌드박스의 GitHub 탭에서 먼저 승인하세요."
fi

# ---- 2) 빌드 --------------------------------------------------------------
echo "② Flutter 웹 릴리즈 빌드 (base-href=${BASE_HREF})..."
# 동기화 서버 주소를 빌드에 심습니다. 이게 없으면 배포된 앱이 "동기화 서버 미설정"
# 상태로 뜨고, 새 기기에서 로그인해도 자료를 받아올 곳이 없습니다.
#   SYNTAX: SYNC_URL="https://sync.example.com" SYNC_KEY="..." ./deploy_pages.sh custom
BUILD_ARGS=(--release --base-href "$BASE_HREF")

# 빌드 식별자를 심습니다. 앱 화면의 버전 표시가 이 값을 씁니다.
#   · 이게 없으면 앱은 '이 기기를 처음 켠 날짜'를 버전처럼 보여줍니다.
#     배포를 해도 숫자가 그대로라 "반영이 안 됐다"고 오해하게 됩니다.
#   · 배포할 때마다 값이 달라지므로, 브라우저에 물어볼 수 있습니다:
#       화면 버전 == 방금 배포한 BUILD_ID  → 새 빌드가 떴다
#       화면 버전 != 방금 배포한 BUILD_ID  → 아직 옛 빌드가 돌고 있다 (캐시)
BUILD_ID="${BUILD_ID:-$(date +%Y.%m.%d.%H%M)}"
echo "   · BUILD_ID = ${BUILD_ID}"
BUILD_ARGS+=(--dart-define=BUILD_ID="${BUILD_ID}")

if [ -n "${SYNC_URL:-}" ]; then
  echo "   · SYNC_URL = ${SYNC_URL}"
  # ## 심어두면 편하지만, 동시에 공개됩니다
  # --dart-define 은 이 주소를 main.dart.js 안에 문자열 리터럴로 심습니다.
  # 그러면 배포본을 내려받는 누구나 NAS 주소를 알게 됩니다. 2026-11-20 에
  # 실제로 확인한 일입니다: 공개 번들에서
  #   "https://sync.<호스트>.direct.quickconnect.to"
  # 가 그대로 읽혔고, 그 주소의 DSM 에 해외 IP 가 로그인을 시도했습니다.
  #
  # 주소는 비밀이 될 수 없지만(브라우저가 어차피 접속해야 하므로), "어디를
  # 두드리면 되는지"를 공짜로 알려주는 것은 다릅니다. 설정 화면에 주소
  # 입력란이 있으므로 심지 않아도 동작합니다. 공개 배포본에는 심지 않는
  # 편이 낫습니다.
  if [ "${EMBED_SYNC_URL:-0}" != "1" ]; then
    echo "   ⚠️  SYNC_URL 이 공개 번들에 포함됩니다. 공개 배포라면 생략을 권합니다."
    echo "      생략: SYNC_URL 을 넘기지 마세요 (설정 화면에서 입력 가능)"
    echo "      그래도 심으려면: EMBED_SYNC_URL=1"
  fi
  BUILD_ARGS+=(--dart-define=SYNC_URL="${SYNC_URL}")
fi
if [ -n "${SYNC_KEY:-}" ]; then
  echo "   · SYNC_KEY = (설정됨, ${#SYNC_KEY}자)"
  # 길이만 확인합니다. 16자 미만이면 게이트웨이의 /readyz 가 503 auth 로 거부하므로,
  # 여기서 막지 않으면 "빌드는 성공했는데 앱만 동기화 실패"로 나타납니다.
  if [ "${#SYNC_KEY}" -lt 16 ]; then
    echo "   ⚠️  SYNC_KEY 가 너무 짧습니다 (${#SYNC_KEY}자). 게이트웨이가 거부합니다." >&2
    echo "      64자 hex 생성: node -e \"console.log(require('crypto').randomBytes(32).toString('hex'))\"" >&2
  fi
  # ## 이 키는 비밀이 아닙니다
  # --dart-define 은 문자열을 main.dart.js 안에 리터럴로 심습니다. 배포본을
  # 내려받는 누구나 읽을 수 있습니다. 실제 방어선은 게이트웨이를 프록시 뒤
  # loopback 에만 두는 것과 계정 인증입니다.
  # 회전 절차: server/gateway/KEY-ROTATION.md
  echo "   · SYNC_KEY 는 main.dart.js 에 평문으로 포함됩니다 (비밀 아님). 회전은 KEY-ROTATION.md 참고."
  BUILD_ARGS+=(--dart-define=SYNC_KEY="${SYNC_KEY}")
fi
flutter build web "${BUILD_ARGS[@]}"

# ---- 3) GitHub Pages 필수 파일 -------------------------------------------
echo "③ .nojekyll 생성 (Jekyll 비활성화)..."
touch build/web/.nojekyll

# 웹 빌드 경량화 (폰트 woff2 서브셋 + 불필요 파일 정리)
if [ "${SKIP_OPTIMIZE:-0}" != "1" ]; then
  echo "③-0 웹 빌드 경량화 (폰트 woff2 서브셋, 대용량 파일 정리)..."
  python3 "$PROJECT_DIR/scripts/optimize_web.py" || echo "   (경량화 실패 — 원본 그대로 진행)"
fi

# 커스텀 도메인 사용 시 CNAME 파일을 빌드에 포함 (GitHub Pages가 도메인 유지)
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
if [ -n "$CUSTOM_DOMAIN" ]; then
  echo "③-1 커스텀 도메인 CNAME 파일 생성: ${CUSTOM_DOMAIN}"
  printf '%s' "$CUSTOM_DOMAIN" > build/web/CNAME
fi

# ----- 3-3) version.json 에 빌드 식별자 심기 (업데이트 알림의 필수 조건) -----
# ## 이 단계가 없으면 업데이트 알림이 영원히 동작하지 않습니다
#
# 앱은 `version.json` 의 `build` 값과 자기 안의 `BUILD_ID` 를 비교해서
# "새 빌드가 떴나"를 판단합니다 (lib/services/update_service.dart).
#
# 그런데 Flutter 가 만드는 기본 version.json 에는 `build` 가 **없습니다**:
#   {"app_name":"...","version":"1.0.0","build_number":"1"}
#
# `--dart-define=BUILD_ID` 는 앱 안에만 심기지 파일로 나오지 않습니다.
# 그래서 이 단계를 빠뜨리면:
#   · 앱 안  : BUILD_ID = 2026.11.21.0100
#   · 서버   : build 필드 자체가 없음
#   · 결과   : check() 가 null 을 돌려주고, 사용자는 영원히 "최신입니다"
#
# 2026-11-21 확인: 운영 서버(www.aqdesign.co.kr)의 version.json 에
# 실제로 `build` 가 없었습니다. 배포는 됐지만 알림은 0% 동작 상태였습니다.
#
# ## 왜 여기(누출 검사 바로 앞)에 두는가
# ① 빌드가 끝난 뒤여야 build/web 이 존재합니다.
# ② 누출 검사보다 앞이어야 version.json 도 검사 대상에 포함됩니다.
# ③ gh-pages 커밋보다 앞이어야 파일이 실제로 배포본에 들어갑니다.
echo "③-3 version.json 에 build=${BUILD_ID} 심기..."
if [ -f "$PROJECT_DIR/scripts/write_version_json.py" ]; then
  # --notes 는 선택. 배포할 때 UPDATE_NOTES="..." 로 넘기면 팝업에 표시됩니다.
  # ## --build-dir 을 반드시 명시합니다
  # 이 스크립트의 기본값은 "이 파일 기준 ../build/web" 입니다. 지금은
  # 맞지만, 나중에 배포 디렉터리를 바꾸거나 스크립트를 옮기면 조용히
  # 엉뚱한 곳에 씁니다. 실제로 시험 중에 그 일이 났습니다 — 검사 장치가
  # 잡아서 망정이지, 없었으면 "심었다"고 보고하고 빈 파일을 배포했습니다.
  if [ -n "${UPDATE_NOTES:-}" ]; then
    python3 "$PROJECT_DIR/scripts/write_version_json.py" \
      --build-id "$BUILD_ID" --notes "$UPDATE_NOTES" \
      --build-dir "$PROJECT_DIR/build/web"
  else
    python3 "$PROJECT_DIR/scripts/write_version_json.py" \
      --build-id "$BUILD_ID" --build-dir "$PROJECT_DIR/build/web"
  fi

  # ## 심었는지 반드시 확인합니다
  # 스크립트가 조용히 실패하면 위의 모든 설명이 무용지물이 됩니다.
  # 실제로 파일을 다시 읽어 값이 같은지 봅니다.
  if ! python3 - "$PROJECT_DIR/build/web/version.json" "$BUILD_ID" <<'PYCHECK'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    got = json.load(open(path, encoding="utf-8")).get("build")
except Exception as e:
    print(f"   ❌ version.json 을 읽을 수 없습니다: {e}", file=sys.stderr)
    sys.exit(1)
if got != want:
    print(f"   ❌ build 불일치: 파일={got!r} 기대={want!r}", file=sys.stderr)
    sys.exit(1)
PYCHECK
  then
    echo "❌ version.json 에 빌드 식별자를 심지 못했습니다. 배포를 중단합니다." >&2
    echo "   이 상태로 배포하면 앱이 새 빌드를 영원히 못 알아챕니다." >&2
    exit 1
  fi
  echo "   ✅ version.json build=${BUILD_ID} 확인"
else
  echo "❌ scripts/write_version_json.py 가 없습니다. 배포를 중단합니다." >&2
  echo "   이 파일이 없으면 업데이트 알림이 동작하지 않습니다." >&2
  exit 1
fi

# ----- 4) 배포본 누출 검사 (배포 전 마지막 관문) ---------------------------
# ## 왜 빌드 직후에 검사하는가
# --dart-define 은 값을 main.dart.js 안에 문자열 리터럴로 심습니다. 그래서
# "빌드에 심었다"가 "전 세계에 공개했다"와 같아지는 경우가 있습니다.
# 2026-11-20 에 실제로 그랬습니다 — 공개 번들에서 NAS 주소가 그대로 읽혔고
# 그 주소의 DSM 에 해외 IP 가 로그인을 시도했습니다.
#
# ## auto_deploy.sh 가 아니라 여기에도 두는 이유
# 실제로 손이 가는 스크립트는 이 파일입니다. 검사가 다른 파일에만 있으면
# 쓰이지 않는 문은 없는 것과 같습니다.
echo "③-2 배포본 누출 검사..."
if [ "${SKIP_SECRET_SCAN:-0}" = "1" ]; then
  echo "   ⚠️  SKIP_SECRET_SCAN=1 — 누출 검사를 건너뜁니다 (권장하지 않음)"
elif [ -f "$PROJECT_DIR/scripts/check_bundle_secrets.py" ]; then
  if python3 "$PROJECT_DIR/scripts/check_bundle_secrets.py" --strict; then
    echo "   ✅ 누출 없음"
  else
    echo "" >&2
    echo "❌ 배포본에 주소·키가 포함되어 있습니다. 배포하지 않습니다." >&2
    echo "   허용하려면 : python3 scripts/check_bundle_secrets.py --allow <값>" >&2
    echo "   원인 제거  : SYNC_URL / SYNC_KEY 없이 빌드 (설정 화면에서 입력 가능)" >&2
    echo "   강제 진행  : SKIP_SECRET_SCAN=1 (권장하지 않음)" >&2
    exit 1
  fi
else
  echo "   ⚠️  검사 스크립트가 없습니다 — 누출 검사를 건너뜁니다"
fi

# ---- 5) 배포용 임시 브랜치(gh-pages) 구성 --------------------------------
echo "④ gh-pages 브랜치 구성 (build/web 내용만)..."
DEPLOY_DIR="$(mktemp -d)"
cp -r build/web/. "$DEPLOY_DIR"/
cd "$DEPLOY_DIR"
git init -q
git checkout -q -b gh-pages
git add -A
git -c user.name="deploy" -c user.email="deploy@local" \
    commit -q -m "Deploy June's Scheduler web build ($(date -u +%Y-%m-%dT%H:%MZ))"

# ---- 5) 푸시 --------------------------------------------------------------
echo "⑤ GitHub로 푸시..."git remote add origin "https://github.com/${GH_REPO}.git"
git push -f origin gh-pages

echo
echo "✅ 푸시 완료!"
echo
echo "다음 단계 (GitHub 웹에서 1회 설정):"
echo "  저장소 → Settings → Pages"
echo "     Source: Deploy from a branch"
echo "     Branch: gh-pages  /  (root)   → Save"
echo
if [ "$MODE" = "custom" ]; then
  echo "커스텀 도메인 연결:"
  echo "  Settings → Pages → Custom domain 에 도메인 입력 후 Save"
  echo "  DNS: apex 도메인이면 A 레코드 4개, www면 CNAME → ${OWNER}.github.io"
  echo "  A 레코드: 185.199.108.153 / 185.199.109.153 / 185.199.110.153 / 185.199.111.153"
else
  echo "배포 주소: https://${OWNER}.github.io/${REPO_NAME}/"
fi
echo
echo "⚠️  이후 코드 수정 시: 다시 이 스크립트를 실행하면 재배포됩니다."

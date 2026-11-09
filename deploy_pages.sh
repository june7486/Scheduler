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
if [ -n "${SYNC_URL:-}" ]; then
  echo "   · SYNC_URL = ${SYNC_URL}"
  BUILD_ARGS+=(--dart-define=SYNC_URL="${SYNC_URL}")
fi
if [ -n "${SYNC_KEY:-}" ]; then
  echo "   · SYNC_KEY = (설정됨)"
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

# ---- 4) 배포용 임시 브랜치(gh-pages) 구성 --------------------------------
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
echo "⑤ GitHub로 푸시..."
git remote add origin "https://github.com/${GH_REPO}.git"
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

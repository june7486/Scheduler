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
flutter build web --release --base-href "$BASE_HREF"

# ---- 3) GitHub Pages 필수 파일 -------------------------------------------
echo "③ .nojekyll 생성 (Jekyll 비활성화)..."
touch build/web/.nojekyll

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

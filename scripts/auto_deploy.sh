#!/usr/bin/env bash
# =============================================================================
# June Scheduler — 자동 배포 (가비아)
# -----------------------------------------------------------------------------
# "코드를 고치면 알아서 올라간다"를 만드는 스크립트.
#
# ## 설계 원칙: 자동이되, 무단은 아니다
#
# 자동 배포의 위험은 "실수한 코드가 즉시 운영에 나간다"입니다. 그래서 여기서는
# 네 가지 문턱을 둡니다.
#
#   1. **깨끗한 작업 트리에서만** 배포합니다. 커밋하지 않은 변경이 있으면
#      무엇이 올라가는지 알 수 없으므로 거부합니다.
#   2. **빌드가 통과해야** 합니다. flutter analyze 실패는 배포하지 않습니다.
#   3. **검증까지 통과해야** 합니다. 업로드 후 해시가 틀리면 자동 롤백됩니다.
#   4. **롤백 스냅숏을 항상 남깁니다.** 언제든 이전 상태로 돌아갈 수 있습니다.
#
# ## 사용법
#
#   ./scripts/auto_deploy.sh              # 검사 → 빌드 → 배포
#   ./scripts/auto_deploy.sh --build-only # 빌드까지만 (배포 안 함)
#   ./scripts/auto_deploy.sh --check      # 검사만
#
# ## git hook 으로 연결하기 (선택)
#
#   ⚠️ git 에는 **post-tag 훅이 없습니다.** 훅 목록은 post-commit,
#   post-checkout, pre-push 등이고 태그 전용 훅은 존재하지 않습니다.
#   그래서 "태그를 붙였을 때만 배포"는 post-commit 안에서 태그를 검사해
#   직접 만듭니다:
#
#   cat > .git/hooks/post-commit <<'EOF'
#   #!/usr/bin/env bash
#   # HEAD 에 태그가 붙어 있을 때만 배포한다. 태그가 없으면 조용히 통과.
#   if git describe --exact-match --tags HEAD >/dev/null 2>&1; then
#     ./scripts/auto_deploy.sh
#   fi
#   EOF
#   chmod +x .git/hooks/post-commit
#
#   그리고 배포는:  git tag deploy-$(date +%H%M) 한 뒤 커밋
#
#   ⚠️ post-commit 을 그냥 auto_deploy.sh 로 심볼릭 링크하면 커밋마다
#   배포가 나갑니다. 작업 중간 커밋에도 운영이 바뀝니다. 위처럼 태그
#   검사를 끼우는 편을 권합니다.
#
# ## 훅이 아니라 명령으로 쓰기 (가장 단순)
#
#   ./scripts/auto_deploy.sh
#
#   훅은 편하지만 "언제 나갔는지"를 잊기 쉽습니다. 배포를 하나의 명시적
#   행위로 두고 싶다면 훅 없이 이 명령만 쓰면 됩니다. 게이트 4개가
#   실수를 막아주므로 습관이 되면 충분합니다.
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

MODE="deploy"
case "${1:-}" in
  --check) MODE="check" ;;
  --build-only) MODE="build" ;;
  "") ;;
  *) echo "알 수 없는 옵션: $1"; echo "사용법: $0 [--check|--build-only]"; exit 2 ;;
esac

step() { echo ""; echo "▶ $*"; }
die()  { echo ""; echo "❌ $*" >&2; exit 1; }

# =============================================================================
step "1/5 저장소 상태 확인"
# =============================================================================
if [ -d .git ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "   커밋하지 않은 변경이 있습니다:"
    git status --porcelain | sed 's/^/     /'
    die "깨끗한 작업 트리에서만 배포합니다 (무엇이 올라가는지 알 수 없으므로)"
  fi
  COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '-')"
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  echo "   ✅ 깨끗함 (${BRANCH} @ ${COMMIT})"

  # ## 왜 main 브랜치를 확인하는가
  # 실험 브랜치에서 자동 배포가 돌면 검증되지 않은 코드가 운영에 나간다.
  # 기본은 **거부**하고, 정말 필요한 경우를 위해 탈출구(ALLOW_NON_MAIN)만 둔다.
  # 경고만 하고 통과시키면 경고는 곧 배경음이 된다.
  if [ -n "${ALLOW_NON_MAIN:-}" ]; then
    echo "   ⚠️  ALLOW_NON_MAIN 설정됨 — ${BRANCH} 브랜치를 배포합니다"
  elif [ "$BRANCH" != "main" ]; then
    echo "   ⚠️  현재 브랜치가 main 이 아닙니다: ${BRANCH}"
    echo "      운영에 나가도 되는 코드인지 확인하세요."
    die "main 브랜치가 아닙니다 (계속하려면 ALLOW_NON_MAIN=1 $0)"
  fi
else
  echo "   ⚠️  git 저장소가 아닙니다 — 상태 확인을 건너뜁니다"
fi

# =============================================================================
step "2/5 설정 확인"
# =============================================================================
if [ ! -f .env.gabia ]; then
  echo "   .env.gabia 가 없습니다. 템플릿을 복사해 값을 채우세요:"
  echo ""
  echo "     cp scripts/env.gabia.example .env.gabia"
  echo "     chmod 600 .env.gabia"
  echo "     \${EDITOR:-vi} .env.gabia"
  echo ""
  echo "   필요한 값: GABIA_HOST / GABIA_USER / GABIA_PASS / GABIA_PATH"
  echo "   가비아 콘솔 → 호스팅 관리 → FTP/DB 관리 에서 확인할 수 있습니다."
  echo "   계정 없이 미리 확인만 하려면:  python3 scripts/deploy_gabia.py --dry-run"
  exit 1
fi
# 권한 확인 — 비밀번호가 든 파일이 남에게 읽히면 안 된다
PERM="$(stat -c '%a' .env.gabia 2>/dev/null || echo '')"
if [ -n "$PERM" ] && [ "$PERM" != "600" ]; then
  echo "   ⚠️  .env.gabia 권한이 ${PERM} 입니다. 600 으로 좁힙니다."
  chmod 600 .env.gabia
fi
# 커밋되지 않았는지 확인 (한 번 커밋되면 히스토리에서 지워도 남는다)
if git ls-files --error-unmatch .env.gabia >/dev/null 2>&1; then
  die ".env.gabia 가 git 에 추적되고 있습니다! 즉시 추적 해제하세요:
     git rm --cached .env.gabia"
fi
echo "   ✅ .env.gabia 확인 (권한 600, git 미추적)"

# =============================================================================
if [ "$MODE" = "check" ]; then
  echo ""
  echo "✅ 검사 완료. 배포하려면 --check 없이 실행하세요."
  exit 0
fi

# =============================================================================
step "3/5 정적 분석"
# =============================================================================
if command -v flutter >/dev/null 2>&1; then
  # flutter analyze 는 경고가 있으면 exit 1 이 아니다 (오류만 실패).
  # 그게 우리가 원하는 기준이다 — 경고 때문에 배포를 막을 이유는 없다.
  if ! flutter analyze 2>&1 | tee /tmp/june_analyze.log | tail -3; then
    die "flutter analyze 실패 — 배포하지 않습니다"
  fi
  if grep -q "error •" /tmp/june_analyze.log; then
    cat /tmp/june_analyze.log | grep "error •" | head -10
    die "컴파일 오류가 있습니다 — 배포하지 않습니다"
  fi
  echo "   ✅ 분석 통과"
else
  echo "   ⚠️  flutter 가 없습니다 — 분석을 건너뜁니다"
fi

# =============================================================================
step "4/5 빌드"
# =============================================================================
BUILD_ID="$(date +%Y.%m.%d.%H%M)"
BUILD_ARGS=(--release --base-href "/")
BUILD_ARGS+=(--dart-define=BUILD_ID="$BUILD_ID")

if [ -n "${SYNC_URL:-}" ]; then
  BUILD_ARGS+=(--dart-define=SYNC_URL="$SYNC_URL")
  echo "   · SYNC_URL = ${SYNC_URL}"
fi
# .env.sync 에서 읽어들이기 (있으면) — 키를 명령줄에 남기지 않기 위해
if [ -f .env.sync ]; then
  chmod 600 .env.sync
  # shellcheck disable=SC1091
  set -a; . ./.env.sync; set +a
fi
if [ -n "${SYNC_KEY:-}" ]; then
  BUILD_ARGS+=(--dart-define=SYNC_KEY="$SYNC_KEY")
  echo "   · SYNC_KEY = (설정됨, ${#SYNC_KEY}자)"
  echo "   · SYNC_KEY 는 main.dart.js 에 평문 포함됩니다 (비밀 아님). 회전: server/gateway/KEY-ROTATION.md"
fi

echo "   · BUILD_ID = ${BUILD_ID}"
flutter build web "${BUILD_ARGS[@]}"

# 웹 빌드 경량화
if [ -f scripts/optimize_web.py ]; then
  python3 scripts/optimize_web.py || echo "   (경량화 실패 — 원본 그대로 진행)"
fi

echo "   ✅ 빌드 완료 ($(du -sh build/web | cut -f1))"

if [ "$MODE" = "build" ]; then
  echo ""
  echo "✅ 빌드까지만 완료. 배포하려면 --build-only 없이 실행하세요."
  exit 0
fi

# =============================================================================
step "5/5 배포 (검증 + 자동 롤백 포함)"
# =============================================================================
if ! python3 scripts/deploy_gabia.py; then
  echo ""
  echo "❌ 배포 실패. 위 로그를 확인하세요."
  echo "   되돌리기:  python3 scripts/deploy_gabia.py --rollback"
  echo "   목록:      python3 scripts/deploy_gabia.py --list"
  exit 1
fi

echo ""
echo "✅ 자동 배포 완료"
echo ""
echo "   확인:  https://${CUSTOM_DOMAIN:-www.aqdesign.co.kr}/"
echo "   되돌리기:  python3 scripts/deploy_gabia.py --rollback"
echo "   스냅숏:    python3 scripts/deploy_gabia.py --list"
echo ""

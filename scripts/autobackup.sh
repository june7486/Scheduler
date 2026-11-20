#!/usr/bin/env bash
# =============================================================================
# June Scheduler — 자동 백업 (autobackup.sh)
# =============================================================================
# ## 왜 "백업"이 아니라 "자동 백업"인가
# 한 번 만든 백업은 한 번만 최신입니다. 그 뒤로 코드가 바뀌면 그 백업은
# 점점 쓸모없어지는데, 파일 이름은 그대로라서 "백업 있어요"라는 착각만
# 남깁니다. 실제로 그래서 롤백이 실패합니다 — 백업은 있는데 그게 3주 전
# 것이라는 걸 그때 알게 됩니다.
#
# 그래서 이 스크립트는 **매번 새로 뜨고, 오래된 것은 지웁니다.** 그리고
# 무엇이 들어 있는지 manifest 에 적어서 나중에 "이 백업이 언제 것인지"
# 파일 이름만 보고 판단하지 않아도 되게 합니다.
#
# ## 두 종류를 뜹니다
#   source  : git 기록 + 소스. 작고(수 MB), 자주 뜨고, 오래 보관
#   full    : build/web 포함. 크고(수십 MB), 가끔 뜨고, 최근 것만 보관
#
# ## 무엇을 백업하지 않는가 (중요)
#   .env, .env.gabia, .sync_key, data/  → 비밀과 사용자 데이터
#
#   이걸 백업에 넣으면 백업 파일 자체가 유출 위험이 됩니다. 그리고
#   백업은 공유하거나 옮기는 물건이라 더 위험합니다. 비밀은 백업이 아니라
#   **암호 관리자**에 있어야 합니다. 필요한 건 "무엇을 채워야 하는지"의
#   목록이고, 그건 이미 .env.example 들에 있습니다.
#
# ## 사용법
#   ./scripts/autobackup.sh              source 백업
#   ./scripts/autobackup.sh --full       build/web 포함 백업
#   ./scripts/autobackup.sh --list       무엇이 있는지
#   ./scripts/autobackup.sh --prune      정책에 맞게 오래된 것 삭제만
# =============================================================================
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

BACKUP_ROOT="${BACKUP_ROOT:-/home/user/backups}"
KEEP_SOURCE="${KEEP_SOURCE:-8}"     # source 백업 몇 개 보관
KEEP_FULL="${KEEP_FULL:-3}"         # full 백업 몇 개 보관

MODE="source"
for arg in "$@"; do
  case "$arg" in
    --full)   MODE="full" ;;
    --list)   MODE="list" ;;
    --prune)  MODE="prune" ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $arg"; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✅\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠️ \033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

mkdir -p "$BACKUP_ROOT"

# =============================================================================
# --list / --prune
# =============================================================================
if [ "$MODE" = "list" ]; then
  hdr "백업 목록 ($BACKUP_ROOT)"
  if ! ls -1 "$BACKUP_ROOT"/*.tar.gz >/dev/null 2>&1; then
    info "없음"
    exit 0
  fi
  printf '  %-38s %10s  %s\n' "파일" "크기" "시각"
  for f in "$BACKUP_ROOT"/*.tar.gz; do
    SZ=$(du -h "$f" 2>/dev/null | cut -f1)
    TS=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)
    printf '  %-38s %10s  %s\n' "$(basename "$f")" "$SZ" "$TS"
  done
  exit 0
fi

prune() {
  local pattern="$1" keep="$2"
  local list
  list="$(ls -1t "$BACKUP_ROOT"/$pattern 2>/dev/null || true)"
  [ -z "$list" ] && return 0
  local n=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    n=$((n + 1))
    if [ "$n" -gt "$keep" ]; then
      rm -f "$f" && info "삭제: $(basename "$f")"
    fi
  done <<< "$list"
}

if [ "$MODE" = "prune" ]; then
  hdr "정리 (source ${KEEP_SOURCE}개 / full ${KEEP_FULL}개 유지)"
  prune "june-source-*.tar.gz" "$KEEP_SOURCE"
  prune "june-full-*.tar.gz"   "$KEEP_FULL"
  ok "정리 완료"
  exit 0
fi

# =============================================================================
# 백업 뜨기
# =============================================================================
STAMP="$(date '+%Y%m%d-%H%M%S')"

if [ "$MODE" = "full" ]; then
  OUT="$BACKUP_ROOT/june-full-$STAMP.tar.gz"
  hdr "전체 백업 (소스 + build/web)"
else
  OUT="$BACKUP_ROOT/june-source-$STAMP.tar.gz"
  hdr "소스 백업 (git 기록 + 소스)"
fi

# ## 커밋 안 된 변경이 있으면 알립니다
# 커밋 안 된 코드는 git 기록에 없으므로 "복원"이 아니라 "파일 복사"로만
# 살아납니다. tar 는 작업 트리를 그대로 담으므로 실제로는 포함되지만,
# 그 사실을 모르면 "커밋했으니 안전하다"고 착각합니다.
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
if [ "$DIRTY" != "0" ]; then
  warn "커밋 안 된 변경 ${DIRTY}건 — tar 에는 포함되지만 git 기록에는 없습니다"
fi

HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'nogit')"

# ── 제외 목록 ──────────────────────────────────────────────────────────────
# 비밀과 사용자 데이터는 절대 넣지 않습니다. 그리고 .git 도 full 에서는
# 다시 넣지 않습니다(source 에 이미 있음) — 두 번 넣으면 크기만 두 배입니다.
EXCLUDES=(
  --exclude='.git/objects/pack/*.pack.tmp'
  --exclude='server/gateway/data'
  --exclude='node_modules'
  --exclude='.dart_tool'
  --exclude='__pycache__'
  --exclude='*.log'
)

# ## .env 제외를 정확한 이름으로 하는 이유
# 처음엔 --exclude='.env.*' 한 줄로 끝냈습니다. 그런데 그 패턴이
# **.env.example 까지 잡아먹었습니다** — 실제로 복원 테스트에서
# server/gateway/.env.example 이 사라진 것을 발견했습니다.
#
# 템플릿은 비밀이 아니라 "무엇을 채워야 하는지"의 목록입니다. 이건
# 백업에 있어야 서버를 다시 세울 때 도움이 됩니다. 반면 실제 값이 든
# .env 는 절대 넣으면 안 됩니다.
#
# ## '!' 부정 패턴은 쓰지 않습니다
# GNU tar 는 --exclude='!*.example' 같은 부정 패턴을 지원하지 않습니다.
# 실제로 시험해봤더니 조용히 무시되고 아무것도 되살려주지 않았습니다.
# (tar 1.35 확인) 그래서 되살리기가 아니라 **정확한 이름만 제외**합니다.
# tar 의 --exclude='.env' 는 중첩 경로(server/gateway/.env)까지 잡으므로
# 이 방식이면 충분합니다. 그리고 .env.example 은 이름이 달라서 안전합니다.
EXCLUDES+=(
  --exclude='.env'
  --exclude='.env.gabia'
  --exclude='.env.sync'
  --exclude='.sync_key'
)

if [ "$MODE" = "full" ]; then
  EXCLUDES+=( --exclude='android/.gradle' --exclude='ios/Pods' )
  tar czf "$OUT" -C "$(dirname "$PROJECT_DIR")" \
      "${EXCLUDES[@]}" \
      --exclude='flutter_app/.git' \
      "$(basename "$PROJECT_DIR")" 2>/dev/null
else
  # source: .git 은 포함 (기록이 이 백업의 핵심), build 는 제외
  EXCLUDES+=( --exclude='build' --exclude='android/.gradle' )
  tar czf "$OUT" -C "$(dirname "$PROJECT_DIR")" \
      "${EXCLUDES[@]}" \
      "$(basename "$PROJECT_DIR")" 2>/dev/null
fi

if [ ! -f "$OUT" ]; then
  printf '  \033[31m❌\033[0m 백업 실패\n'
  exit 1
fi

# =============================================================================
# 검증 — 만들었다 ≠ 되돌릴 수 있다
# =============================================================================
# ## 왜 검증하는가
# "백업 만들었습니다"는 아무 의미가 없습니다. 실제로 tar 가 중간에 죽어
# 반쪽짜리 파일이 남는 일이 있고, 그걸 모르고 있다가 복원할 때 알게 됩니다.
# 그때는 이미 늦었습니다.
#
# 그래서 세 가지를 확인합니다:
#   ① gzip 무결성 (파일이 안 깨졌는가)
#   ② 안에 뭐가 들었는지 (핵심 파일이 실제로 있는가)
#   ③ git 기록이 들어 있는가 (source 백업의 존재 이유)

FAIL=0
if gzip -t "$OUT" 2>/dev/null; then
  ok "gzip 무결성"
else
  printf '  \033[31m❌\033[0m gzip 파일이 손상되었습니다\n'
  FAIL=1
fi

# 핵심 파일 존재 확인
LIST="$(tar tzf "$OUT" 2>/dev/null || true)"

# ## 여기서 grep -q 를 쓰지 않는 이유 (실제로 한 번 속았습니다)
# `printf ... | grep -qE 패턴` 은 grep 이 첫 일치에서 즉시 종료하며 파이프를
# 닫습니다. 그러면 printf 가 SIGPIPE 로 죽고, `set -o pipefail` 이 켜져
# 있으므로 **파이프라인 전체가 실패로 판정됩니다.** 일치하는데도 "누락"이라고
# 보고합니다. 실제로 .git/HEAD 가 멀쩡히 들어 있는데 누락으로 나와서
# 한참 헤맸습니다.
#
# `grep -q <<<` (herestring)로 바꾸면 파이프가 없어서 증상이 사라지지만,
# 그건 SIGPIPE 를 피한 것이지 논리를 고친 것이 아닙니다. 여기서는
# **-c 로 개수를 세서 숫자로 판정**합니다. 파이프는 여전히 있지만 grep 이
# 끝까지 읽으므로 SIGPIPE 가 나지 않고, 결과도 개수라서 명확합니다.
count_member() {
  local pat="$1"
  printf '%s\n' "$LIST" | grep -cE "$pat" 2>/dev/null || true
}

check_member() {
  local pat="$1" label="$2"
  local n
  n="$(count_member "$pat")"
  if [ "${n:-0}" -gt 0 ]; then
    ok "$label"
  else
    printf '  \033[31m❌\033[0m %s 누락\n' "$label"
    FAIL=1
  fi
}

check_member 'flutter_app/pubspec\.yaml'          "pubspec.yaml"
check_member 'flutter_app/lib/main\.dart'         "lib/main.dart"
check_member 'flutter_app/lib/services/store\.dart' "store.dart"

# 템플릿은 남아야 합니다. 서버를 다시 세울 때 필요한 "무엇을 채울지" 목록.
check_member 'env\.gabia\.example|\.env\.example' "환경변수 템플릿"

if [ "$MODE" = "source" ]; then
  check_member 'flutter_app/\.git/HEAD' "git 기록 (.git/HEAD)"
else
  check_member 'flutter_app/build/web/main\.dart\.js' "build/web/main.dart.js"
fi

# ## 비밀이 새어 들어가지 않았는지 확인
# 제외 목록을 썼지만, 제외가 실제로 먹혔는지는 별개 문제입니다.
# (패턴이 안 맞으면 조용히 통과합니다) 그래서 실제 목록에서 다시 봅니다.
#
# ## 이 검사는 "통과"가 기본값이면 안 됩니다
# 여기서 grep -q 를 쓰면 SIGPIPE + pipefail 로 인해 **일치해도 불일치로**
# 판정될 수 있습니다. 그러면 비밀이 들어 있는데 "미포함"이라고 보고합니다.
# 이 검사에서 그건 최악의 실패 방향입니다 — 없다고 믿게 만드는 거짓 통과.
# 그래서 여기서도 개수로 판정합니다.
SECRET_PAT='/(\.env|\.env\.gabia|\.env\.sync|\.sync_key)$'
SECRET_N="$(printf '%s\n' "$LIST" | grep -cE "$SECRET_PAT" 2>/dev/null || true)"
if [ "${SECRET_N:-0}" -gt 0 ]; then
  printf '  \033[31m❌\033[0m 백업에 .env 또는 .sync_key 가 %s건 들어갔습니다 — 삭제하세요\n' "$SECRET_N"
  printf '%s\n' "$LIST" | grep -E "$SECRET_PAT" 2>/dev/null | head -5 | while read -r l; do info "$l"; done
  FAIL=1
else
  ok "비밀 파일 미포함 (검사 ${SECRET_N:-0}건 일치)"
fi

# =============================================================================
# manifest — 이 백업이 언제 무엇인지 남깁니다
# =============================================================================
MANIFEST="${OUT%.tar.gz}.txt"
{
  echo "June Scheduler backup"
  echo "================================"
  echo "종류      : $MODE"
  echo "생성      : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "git HEAD  : $HEAD_SHA"
  echo "브랜치    : $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  echo "커밋 메시지: $(git log -1 --pretty=%s 2>/dev/null | cut -c1-70 || echo '?')"
  echo "커밋안된변경: $DIRTY 건"
  echo "크기      : $(du -h "$OUT" 2>/dev/null | cut -f1)"
  echo "파일      : $(basename "$OUT")"
  echo ""
  echo "복원 방법"
  echo "--------------------------------"
  echo "  mkdir -p /tmp/restore && tar xzf $(basename "$OUT") -C /tmp/restore"
  echo "  # 확인 후"
  echo "  rsync -a /tmp/restore/flutter_app/ /home/user/flutter_app/"
  echo ""
  echo "  전체를 덮어쓰지 마세요. 먼저 /tmp 에 풀어 무엇이 다른지 보세요."
  echo ""
  echo "포함하지 않은 것 (의도적)"
  echo "--------------------------------"
  echo "  .env, .env.*, .sync_key  → 비밀. 암호 관리자에 보관"
  echo "  server/gateway/data/     → 사용자 데이터. 별도 관리"
  echo "  node_modules, .dart_tool  → 재생성 가능"
} > "$MANIFEST"

ok "manifest: $(basename "$MANIFEST")"

# =============================================================================
# 정리
# =============================================================================
prune "june-source-*.tar.gz" "$KEEP_SOURCE"
prune "june-full-*.tar.gz"   "$KEEP_FULL"

# manifest 도 같이 정리 (tar 가 지워지면 그 짝도)
for m in "$BACKUP_ROOT"/*.txt; do
  [ -f "$m" ] || continue
  t="${m%.txt}.tar.gz"
  [ -f "$t" ] || rm -f "$m"
done

# =============================================================================
hdr "결과"
# =============================================================================
if [ "$FAIL" = "0" ]; then
  ok "백업 성공: $(basename "$OUT")"
  info "크기: $(du -h "$OUT" 2>/dev/null | cut -f1)"
  info "위치: $BACKUP_ROOT"
else
  printf '  \033[31m❌\033[0m 백업에 문제가 있습니다 — 위 로그를 확인하세요\n'
  exit 1
fi

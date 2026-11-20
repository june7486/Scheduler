#!/bin/bash
# June Scheduler — NAS gateway launcher.
#
# Finds a usable Node.js on a Synology box (the packaged one lives under
# /volume*/@appstore/Node.js_*/bin/node, which is not on root's PATH when DSM's
# Task Scheduler runs a script), loads .env, refuses to run twice, and detaches.
#
#   ./start.sh            start (no-op if already running)
#   ./start.sh stop       stop
#   ./start.sh status     is it up?
#   ./start.sh selftest   talk to the NAS once and print what worked

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1

LOG="$DIR/gateway.log"
PIDFILE="$DIR/gateway.pid"

# ---- locate node -----------------------------------------------------------
find_node() {
  if [ -n "${NODE_BIN:-}" ] && [ -x "$NODE_BIN" ]; then echo "$NODE_BIN"; return; fi
  if command -v node >/dev/null 2>&1; then command -v node; return; fi
  for c in /volume*/@appstore/Node.js_*/bin/node \
           /var/packages/Node.js_*/target/bin/node \
           /usr/local/bin/node /opt/bin/node; do
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  echo ""
}

NODE="$(find_node)"
if [ -z "$NODE" ]; then
  echo "❌ Node.js 를 찾지 못했습니다."
  echo "   패키지 센터에서 'Node.js v20' 을 설치한 뒤 다시 실행하세요."
  echo "   또는 NODE_BIN=/path/to/node ./start.sh"
  exit 1
fi

# ---- load .env -------------------------------------------------------------
if [ ! -f "$DIR/.env" ]; then
  echo "❌ .env 가 없습니다. DSM-설치가이드.md 3단계를 먼저 하세요."
  exit 1
fi
set -a
# shellcheck disable=SC1091
. "$DIR/.env"
set +a

running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

case "${1:-start}" in
  stop)
    if running; then
      kill "$(cat "$PIDFILE")" && echo "⏹  stopped"
      rm -f "$PIDFILE"
    else
      pkill -f "$DIR/server.js" 2>/dev/null && echo "⏹  stopped (by pattern)" || echo "이미 꺼져 있습니다."
    fi
    exit 0
    ;;
  status)
    if running; then
      echo "✅ running  pid=$(cat "$PIDFILE")"
      printf '   /health : '; curl -s -m 3 "http://127.0.0.1:${PORT:-8097}/health" || true
      echo
      # Readiness is a *separate* question from liveness, and the one that
      # matters after a reboot: a process can be up while the share is not
      # mounted yet, in which case every save fails and nothing looks wrong.
      printf '   /readyz : '; curl -s -m 5 -o /tmp/jg_readyz.$$ -w '%{http_code}' \
        "http://127.0.0.1:${PORT:-8097}/readyz" 2>/dev/null || true
      printf ' '; cat /tmp/jg_readyz.$$ 2>/dev/null || true; echo
      rm -f /tmp/jg_readyz.$$
    else
      echo "⛔ not running"
      exit 1
    fi
    exit 0
    ;;
  selftest)
    exec "$NODE" "$DIR/server.js" --selftest
    ;;
  start) ;;
  *)
    echo "사용법: $0 [start|stop|status|selftest]"
    exit 2
    ;;
esac

if running; then
  echo "이미 실행 중입니다 (pid=$(cat "$PIDFILE"))"
  exit 0
fi

# Stale pidfile from a crashed instance.
rm -f "$PIDFILE"

echo "▶ node    : $NODE ($("$NODE" -v))"
echo "▶ port    : ${PORT:-8097}"
echo "▶ storage : ${STORAGE:-auto}"
if [ "${STORAGE:-dsm}" = "local" ]; then
  echo "▶ data    : ${DATA_DIR:-$DIR/data}"
else
  echo "▶ nas     : ${NAS_HOST:-?} folder=${NAS_FOLDER:-?}"
fi

# DSM 의 작업 스케줄러는 스크립트가 끝나면 그 스크립트의 프로세스 그룹을 정리하는
# 경우가 있다. nohup 은 SIGHUP 만 막아주므로 그룹째 오는 신호에는 속수무책이다.
# setsid 로 새 세션에 옮겨두면 부모가 죽어도 게이트웨이는 살아남는다.
# (setsid 가 없는 나스도 있으므로 없으면 예전처럼 nohup 으로 떨어진다)
if command -v setsid >/dev/null 2>&1; then
  setsid "$NODE" "$DIR/server.js" >> "$LOG" 2>&1 < /dev/null &
else
  nohup "$NODE" "$DIR/server.js" >> "$LOG" 2>&1 < /dev/null &
fi
echo $! > "$PIDFILE"
sleep 2

if running; then
  echo "✅ 시작했습니다. pid=$(cat "$PIDFILE")"
  printf '   /health : '; curl -s -m 3 "http://127.0.0.1:${PORT:-8097}/health" || true
  echo

  # ## Why the launcher also asks /readyz
  # `/health` answers "the process is alive". That is not the question after a
  # reboot, when the NAS share may not be mounted yet: the process starts, the
  # port opens, /health says 200, and every save fails silently until somebody
  # notices days later. `/readyz` writes a scratch file and reports 503.
  #
  # A 503 here is not a reason to exit non-zero — the gateway is running and
  # will become ready on its own once the mount appears (the verdict is cached
  # for READY_CACHE_MS, so it re-probes). It *is* a reason to say so loudly.
  ready_code=$(curl -s -m 5 -o /tmp/jg_readyz.$$ -w '%{http_code}' \
    "http://127.0.0.1:${PORT:-8097}/readyz" 2>/dev/null || echo "000")
  ready_body=$(cat /tmp/jg_readyz.$$ 2>/dev/null || true)
  rm -f /tmp/jg_readyz.$$
  if [ "$ready_code" = "200" ]; then
    printf '   /readyz : %s %s\n' "$ready_code" "$ready_body"
  else
    printf '   /readyz : %s %s\n' "$ready_code" "$ready_body"
    echo "   ⚠️  아직 준비되지 않았습니다. 저장소가 마운트되었는지 확인하세요."
    echo "      (프로세스는 살아 있으므로 마운트되면 자동으로 준비 상태가 됩니다)"
  fi
else
  echo "❌ 시작 실패. 로그:"
  tail -20 "$LOG"
  exit 1
fi

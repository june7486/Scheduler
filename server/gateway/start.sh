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
      curl -s -m 3 "http://127.0.0.1:${PORT:-8097}/health" || true
      echo
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

nohup "$NODE" "$DIR/server.js" >> "$LOG" 2>&1 &
echo $! > "$PIDFILE"
sleep 2

if running; then
  echo "✅ 시작했습니다. pid=$(cat "$PIDFILE")"
  curl -s -m 3 "http://127.0.0.1:${PORT:-8097}/health" || true
  echo
else
  echo "❌ 시작 실패. 로그:"
  tail -20 "$LOG"
  exit 1
fi

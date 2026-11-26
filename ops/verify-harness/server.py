#!/usr/bin/env python3
"""빈 서버 + 실제 웹 빌드를 **같은 오리진**에서 내보내는 시험용 서버.

## 왜 필요한가

사용자가 요구한 시험은 "카테고리를 미리 넣지 않은 빈 서버에서 실제 웹 빌드와
독립 브라우저 세션 두 개"입니다. 그런데 웹 앱은 서버 주소를 `--dart-define
SYNC_URL` 로 심고, 게이트웨이는 CORS 허용 목록에 없는 오리진을 거절합니다.
정적 파일(5240)과 게이트웨이(5230)를 다른 오리진으로 두면 브라우저가 응답을
읽지 못해 시험이 "동기화 실패"로 잘못 결론납니다.

그래서 이 프록시는 두 가지를 한 포트에서 내보냅니다.

    /            → build/web 정적 파일 (Flutter 웹 빌드)
    /health      → 게이트웨이 /health   (앱이 첫 화면 전에 확인)
    /readyz      → 게이트웨이 /readyz
    /api/...     → 게이트웨이 /api/...  (state / push / reset)

앱은 `SYNC_URL=http://127.0.0.1:5240` 로 빌드되어 자기 자신에게 묻습니다.
즉 **운영과 같은 same-origin 구성**이고, 이 구성에서는 CORS 설정이 아예
개입하지 않습니다. 실제 nginx 배포가 `location /api/` 를 게이트웨이로 넘기는
것과 같은 모양입니다.
"""

import os
import sys
import mimetypes
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WEB_ROOT = os.environ.get("WEB_ROOT", "/home/user/flutter_app/build/web")
GATEWAY = os.environ.get("GATEWAY", "http://127.0.0.1:5230")
PORT = int(os.environ.get("PORT", "5240"))

API_PREFIXES = ("/api/", "/health", "/readyz")

mimetypes.add_type("application/javascript", ".js")
mimetypes.add_type("text/html", ".html")
mimetypes.add_type("application/wasm", ".wasm")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 조용히
        pass

    # ---------------- 게이트웨이로 넘기기 ----------------
    def _proxy(self, method):
        body = None
        length = self.headers.get("Content-Length")
        if length:
            body = self.rfile.read(int(length))

        url = GATEWAY + self.path
        req = urllib.request.Request(url, data=body, method=method)
        for h in ("Content-Type", "X-Sync-Key", "Accept-Encoding"):
            v = self.headers.get(h)
            if v:
                req.add_header(h, v)

        try:
            with urllib.request.urlopen(req, timeout=45) as r:
                payload = r.read()
                self.send_response(r.status)
                for k, v in r.getheaders():
                    if k.lower() in ("transfer-encoding", "connection",
                                     "content-length"):
                        continue
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        except urllib.error.HTTPError as e:
            payload = e.read()
            self.send_response(e.code)
            for k, v in e.headers.items():
                if k.lower() in ("transfer-encoding", "connection",
                                 "content-length"):
                    continue
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as e:  # 게이트웨이 다운
            msg = f'{{"ok":false,"error":"gateway unreachable: {e}"}}'.encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

    # ---------------- 정적 파일 ----------------
    def _static(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            path = "/index.html"

        # 디렉터리 탈출 차단
        safe = os.path.normpath(path).lstrip("/")
        full = os.path.join(WEB_ROOT, safe)
        if not os.path.abspath(full).startswith(os.path.abspath(WEB_ROOT)):
            self.send_error(403)
            return
        if os.path.isdir(full):
            full = os.path.join(full, "index.html")

        if not os.path.isfile(full):
            # Flutter 웹에는 라우팅이 없지만, 404 는 정직하게 알린다.
            self.send_error(404, "not found")
            return

        ctype, _ = mimetypes.guess_type(full)
        with open(full, "rb") as f:
            data = f.read()

        self.send_response(200)
        self.send_header("Content-Type", ctype or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        # 시험 중 캐시된 옛 번들이 끼어들지 않게 한다.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    # ---------------- 라우팅 ----------------
    def _route(self, method):
        if any(self.path.startswith(p) for p in API_PREFIXES):
            self._proxy(method)
        else:
            self._static()

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Allow", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    if not os.path.isdir(WEB_ROOT):
        print(f"웹 빌드가 없습니다: {WEB_ROOT}", file=sys.stderr)
        sys.exit(1)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    print(f"serving {WEB_ROOT} + {GATEWAY} on :{PORT}", flush=True)
    srv.serve_forever()

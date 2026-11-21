#!/usr/bin/env python3
"""업데이트 알림 종단 시험용 서버.

## 왜 별도 서버가 필요한가

업데이트 확인은 **실제 브라우저에서만** 동작합니다 (`kIsWeb`). 단위 시험은
판단 로직만 보지만, 여기서는 진짜로:

  ① 앱이 서버의 `version.json` 을 요청하는가
  ② 서버 build 가 앱 build 와 다를 때 팝업이 뜨는가
  ③ 서버 build 가 같을 때 조용한가

를 봅니다. 이 세 가지가 실제 사용자 경험 그 자체입니다.

## 요청을 기록하는 이유

"팝업이 떴다/안 떴다" 만 보면 왜 그런지 모릅니다. `version.json` 요청이
아예 없었는지, 있었는데 응답이 이상했는지 구분해야 원인을 찾습니다.

## 캐시 헤더

`version.json` 은 반드시 `no-store` 로 보냅니다. 운영 서버 설정이
그렇게 되어 있어야 하고, 시험 서버가 캐시하면 시험이 거짓말을 합니다.
"""
import http.server
import os
import socketserver
import sys
import threading

ROOT = sys.argv[1] if len(sys.argv) > 1 else '/tmp/updtest'
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5199
LOG = sys.argv[3] if len(sys.argv) > 3 else '/tmp/updtest_requests.log'

_hits = []
_lock = threading.Lock()


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def log_message(self, fmt, *args):
        pass  # 기본 액세스 로그는 시끄럽습니다

    def end_headers(self):
        p = self.path.split('?')[0]
        if p == '/version.json':
            # 업데이트 확인은 항상 새 값을 읽어야 합니다.
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
            self.send_header('Pragma', 'no-cache')
        # 서비스 워커가 붙어도 시험에 영향이 없도록 허용
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('X-Frame-Options', 'ALLOWALL')
        super().end_headers()

    def do_GET(self):
        # ## 쿼리스트링까지 기록합니다
        # 캐시 무력화 쿼리(_=...)가 붙었는지 확인해야 하는데, 앞에서
        # 잘라버리면 그 사실이 로그에서 사라집니다. 실제로 그렇게 만들어
        # "쿼리가 없다"고 잘못 판정했습니다 — 시험 도구가 거짓 보고를 한
        # 경우입니다. 원본 그대로 남깁니다.
        raw = self.path
        with _lock:
            _hits.append(raw)
            with open(LOG, 'a', encoding='utf-8') as f:
                f.write(raw + '\n')
        super().do_GET()


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('0.0.0.0', PORT), H) as httpd:
    print(f'[upd-server] {ROOT} on 0.0.0.0:{PORT}', flush=True)
    httpd.serve_forever()

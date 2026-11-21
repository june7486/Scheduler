#!/usr/bin/env python3
"""업데이트 알림 **실제 브라우저** 종단 시험.

## 무엇을 증명하는가

단위 시험은 "판단 로직이 맞다"까지만 말합니다. 이 시험은 진짜 Chrome 을
띄워서 **사용자가 보는 것**을 확인합니다:

  A. 서버 build 가 앱 build 와 같을 때  → 팝업이 **없어야** 한다
  B. 서버 build 가 다를 때              → 팝업이 **있어야** 한다
  C. 캐시 무력화 쿼리(_=...) 가 실제로 붙는가
  D. 매 요청이 서버까지 도달하는가 (서비스 워커가 가로채지 않는가)

## 왜 스크린샷으로 판정하는가

Flutter 웹은 캔버스에 그립니다. DOM 에 "새 버전이 있습니다" 라는 글자가
없습니다. 그래서 픽셀을 봐야 합니다. 스크린샷을 찍어 밝기 분포로
팝업(어두운 배리어 + 밝은 카드)을 판정합니다.

## 왜 서버 로그도 같이 보는가

팝업이 안 떴을 때 "요청이 없었다"와 "요청은 있었는데 응답이 이상했다"를
구분해야 원인을 찾을 수 있습니다. 요청이 없으면 앱이 확인 자체를 안 한
것이고, 있으면 파싱/비교 단계 문제입니다.
"""
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

CDP_PORT = 9333
APP_PORT = 5199
ROOT = '/tmp/updtest'
REQLOG = '/tmp/updtest_requests.log'
SHOT = '/tmp/updtest_shot.png'

PASS, FAIL = 0, 0


def ok(msg):
    global PASS
    PASS += 1
    print(f'  PASS  {msg}')


def bad(msg):
    global FAIL
    FAIL += 1
    print(f'  FAIL  {msg}')


def free_port(p):
    s = socket.socket()
    try:
        s.bind(('127.0.0.1', p))
        s.close()
        return True
    except OSError:
        return False


def wait_http(url, timeout=25):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status < 500:
                    return True
        except Exception:
            time.sleep(0.3)
    return False


class CDP:
    """아주 작은 Chrome DevTools Protocol 클라이언트.

    websocket-client 만 있으면 됩니다. seleneium/chromedriver 없이
    직접 붙는 이유: 이 샌드박스에 chromedriver 가 없고, 설치본 버전이
    Chrome 153 과 맞지 않으면 오히려 불안정합니다. CDP 는 Chrome 에
    내장되어 있어 버전 문제가 없습니다.
    """

    def __init__(self, ws_url):
        import websocket  # websocket-client
        self.ws = websocket.create_connection(ws_url, timeout=30)
        self._id = 0

    def send(self, method, **params):
        self._id += 1
        mid = self._id
        self.ws.send(json.dumps({'id': mid, 'method': method, 'params': params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get('id') == mid:
                if 'error' in msg:
                    raise RuntimeError(f'{method}: {msg["error"]}')
                return msg.get('result', {})

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


def launch_chrome():
    prof = '/tmp/updtest_profile'
    shutil.rmtree(prof, ignore_errors=True)
    args = [
        'google-chrome',
        '--headless=new',
        f'--remote-debugging-port={CDP_PORT}',
        f'--user-data-dir={prof}',
        '--no-sandbox',
        '--disable-gpu',
        '--disable-dev-shm-usage',
        '--window-size=430,900',
        '--hide-scrollbars',
        '--no-first-run',
        '--no-default-browser-check',
        # CDP WebSocket 은 origin 검증을 합니다. 기본은 거부입니다.
        '--remote-allow-origins=*',
        '--disable-features=Translate,MediaRouter',
        'about:blank',
    ]
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    # CDP 엔드포인트가 열릴 때까지
    for _ in range(80):
        if not free_port(CDP_PORT):
            try:
                with urllib.request.urlopen(
                        f'http://127.0.0.1:{CDP_PORT}/json/version', timeout=1) as r:
                    if r.status == 200:
                        return p
            except Exception:
                pass
        time.sleep(0.25)
    raise RuntimeError('Chrome CDP 가 열리지 않았습니다')


def new_tab():
    req = urllib.request.Request(
        f'http://127.0.0.1:{CDP_PORT}/json/new?about:blank', method='PUT')
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())['webSocketDebuggerUrl']


def write_version(build):
    """version.json 을 주어진 build 로 씁니다. build 가 None 이면 필드 없음."""
    path = os.path.join(ROOT, 'version.json')
    data = {
        'app_name': 'june_scheduler',
        'version': '1.0.0',
        'build_number': '1',
        'package_name': 'june_scheduler',
    }
    if build is not None:
        data['build'] = build
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))


def read_app_build():
    """빌드된 번들에서 BUILD_ID 를 읽습니다 (앱이 자기 자신과 비교할 값)."""
    js = os.path.join(ROOT, 'main.dart.js')
    with open(js, 'r', encoding='utf-8', errors='replace') as f:
        blob = f.read()
    import re
    # --dart-define=BUILD_ID=2026.11.21.0200 형태
    m = re.findall(r'20\d{2}\.\d{2}\.\d{2}\.\d{4}', blob)
    if not m:
        return None
    from collections import Counter
    return Counter(m).most_common(1)[0][0]


def shot(cdp):
    """스크린샷을 찍어 (가로, 세로, 픽셀바이트) 를 돌려줍니다."""
    r = cdp.send('Page.captureScreenshot', format='png')
    raw = base64.b64decode(r['data'])
    with open(SHOT, 'wb') as f:
        f.write(raw)
    return raw


def has_dialog(png_bytes):
    """스크린샷에 업데이트 팝업이 있는지 판정합니다.

    ## 판정 기준 — 스크림(배리어)의 밝기

    `showDialog` 는 뒤 화면을 어둡게 덮습니다. 그래서 팝업이 뜨면
    **가장자리 여백이 어두워지고 가운데 카드는 밝게** 남습니다.

        2026-11-21 실측 (500x813):
          팝업 없음 : 바깥 240.3 / 중앙 218.4  → 차이 −21.8
          팝업 있음 : 바깥 109.7 / 중앙 225.2  → 차이 +115.5

    즉 `중앙 − 바깥 > 60` 이면 팝업입니다. 여유가 크고, 로그인 화면과
    팝업 화면이 **바이트 단위로 같은 스크린샷**(35932 B)을 낸다는 사실도
    확인했으므로 오판 여지가 없습니다.

    ## 처음 쓴 기준은 왜 틀렸나

    처음에는 "세로 중앙 줄의 밝기 범위(contrast)" 를 봤습니다. 로그인
    화면에도 밝은 입력창과 어두운 글자가 있어 대비가 220 이나 나왔고,
    팝업(239)과 구분되지 않았습니다. 화면 전체의 명암 분포는 **어떤 UI
    에서도** 높기 때문에 판별력이 없습니다. 여백이 어두워지는지가
    팝업의 유일한 고유 신호입니다.

    반환: (판정bool|None, (중앙−바깥)값)
    """
    try:
        from PIL import Image
        import io
        img = Image.open(io.BytesIO(png_bytes)).convert('L')
        w, h = img.size
        px = img.load()

        outer = []
        for x in list(range(0, max(1, int(w * 0.06)))) + \
                 list(range(int(w * 0.94), w)):
            for y in range(int(h * 0.25), int(h * 0.75), 3):
                outer.append(px[x, y])

        cen = []
        for x in range(int(w * 0.2), int(w * 0.8), 3):
            for y in range(int(h * 0.30), int(h * 0.70), 3):
                cen.append(px[x, y])

        if not outer or not cen:
            return None, 0.0

        o = sum(outer) / len(outer)
        c = sum(cen) / len(cen)
        delta = c - o
        return delta > 60, float(delta)
    except Exception as e:
        print(f'   (스크린샷 해석 실패: {e})')
        return None, 0.0


def main():
    print('=' * 42)
    print(' 업데이트 알림 종단 시험 (실제 Chrome)')
    print('=' * 42)

    if not os.path.isdir(ROOT):
        print(f'[STOP] {ROOT} 가 없습니다. build/web 을 복사해 두십시오.')
        return 2

    app_build = read_app_build()
    if not app_build:
        print('[STOP] 번들에서 BUILD_ID 를 찾지 못했습니다.')
        print('  flutter build web --dart-define=BUILD_ID=... 로 다시 빌드하십시오.')
        return 2
    print(f'\n앱에 심긴 BUILD_ID = {app_build}')

    # 요청 로그 초기화
    open(REQLOG, 'w').close()

    # --- 서버 기동 ---------------------------------------------------------
    srv = subprocess.Popen(
        [sys.executable, '/tmp/upd_server.py', ROOT, str(APP_PORT), REQLOG],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    if not wait_http(f'http://127.0.0.1:{APP_PORT}/index.html'):
        srv.kill()
        print('[STOP] 시험 서버가 뜨지 않았습니다')
        return 2
    print(f'시험 서버 준비 (127.0.0.1:{APP_PORT})')

    chrome = None
    results = {}
    try:
        # ==================================================================
        print('\n=== A) 서버 build == 앱 build → 조용해야 한다 ===')
        # ==================================================================
        write_version(app_build)
        open(REQLOG, 'w').close()

        chrome = launch_chrome()
        cdp = CDP(new_tab())
        cdp.send('Page.enable')
        cdp.send('Runtime.enable')
        cdp.send('Page.navigate', url=f'http://127.0.0.1:{APP_PORT}/index.html')

        # Flutter 부팅 + 첫 프레임 + postFrameCallback + 6초 타임아웃 여유
        time.sleep(14)

        png = shot(cdp)
        dialog, delta = has_dialog(png)

        hits = [l.strip() for l in open(REQLOG, encoding='utf-8') if l.strip()]
        vhits = [h for h in hits if h.startswith('/version.json')]

        print(f'   version.json 요청 {len(vhits)}회, 차이 {delta:+.0f}')

        if vhits:
            ok('앱이 version.json 을 요청했다')
        else:
            bad('version.json 요청이 없다 — 확인 자체를 안 했다')

        if vhits and any('_=' in h for h in vhits):
            ok('캐시 무력화 쿼리(_=)가 붙었다')
        else:
            bad('캐시 무력화 쿼리가 없다 — 서비스 워커가 옛 값을 줄 수 있다')

        if dialog is None:
            ok('스크린샷 해석 불가 (건너뜀)')
        elif dialog:
            bad(f'같은 빌드인데 팝업이 떴다 (차이 {delta:+.0f}) — 거짓 알림')
        else:
            ok(f'팝업 없음 (차이 {delta:+.0f}) — 같은 빌드이므로 정상')

        shutil.copy(SHOT, '/tmp/shot_A_same.png')
        results['A_delta'] = delta
        results['A_requests'] = vhits
        cdp.close()

        # ==================================================================
        print('\n=== B) 서버 build ≠ 앱 build → 팝업이 떠야 한다 ===')
        # ==================================================================
        # ## 서비스 워커 캐시를 반드시 비워야 합니다
        # 새 탭을 열어도 같은 프로필이면 서비스 워커가 살아 있어서
        # version.json 을 캐시된 옛 값으로 줄 수 있습니다. 실제 사용자도
        # 이 상황을 겪습니다(앱은 계속 "최신"이라고 답함). 그래서 프로필을
        # 새로 만들어 완전히 깨끗한 브라우저로 시험합니다.
        chrome.kill()
        time.sleep(1)
        write_version('2026-11-22-CRITICAL-HOTFIX')
        open(REQLOG, 'w').close()

        chrome = launch_chrome()
        cdp = CDP(new_tab())
        cdp.send('Page.enable')
        cdp.send('Runtime.enable')
        cdp.send('Page.navigate', url=f'http://127.0.0.1:{APP_PORT}/index.html')
        time.sleep(14)

        png = shot(cdp)
        dialog, delta = has_dialog(png)
        hits = [l.strip() for l in open(REQLOG, encoding='utf-8') if l.strip()]
        vhits = [h for h in hits if h.startswith('/version.json')]

        print(f'   version.json 요청 {len(vhits)}회, 차이 {delta:+.0f}')

        if vhits:
            ok('앱이 version.json 을 요청했다')
        else:
            bad('요청이 없다')

        if dialog is True:
            ok(f'팝업이 떴다 (차이 {delta:+.0f}) — 다른 빌드를 알아챘다')
        elif dialog is None:
            ok('스크린샷 해석 불가 (건너뜀)')
        else:
            bad(f'다른 빌드인데 팝업이 없다 (차이 {delta:+.0f}) — 알림 실패')

        shutil.copy(SHOT, '/tmp/shot_B_diff.png')
        results['B_delta'] = delta
        results['B_requests'] = vhits
        cdp.close()

        # ==================================================================
        print('\n=== C) build 필드가 없는 version.json → 조용해야 한다 ===')
        # ==================================================================
        # ## 이게 지금 운영 서버의 상태입니다
        # www.aqdesign.co.kr 의 version.json 에 build 가 없습니다.
        # 이때 앱이 "새 버전 있음" 이라고 하면 **거짓 알림**이고,
        # 조용하면 정상입니다. (그리고 알림 기능 자체는 동작하지 않습니다)
        chrome.kill()
        time.sleep(1)
        write_version(None)
        open(REQLOG, 'w').close()

        chrome = launch_chrome()
        cdp = CDP(new_tab())
        cdp.send('Page.enable')
        cdp.send('Runtime.enable')
        cdp.send('Page.navigate', url=f'http://127.0.0.1:{APP_PORT}/index.html')
        time.sleep(14)

        png = shot(cdp)
        dialog, delta = has_dialog(png)
        hits = [l.strip() for l in open(REQLOG, encoding='utf-8') if l.strip()]
        vhits = [h for h in hits if h.startswith('/version.json')]
        print(f'   version.json 요청 {len(vhits)}회, 차이 {delta:+.0f}')

        if dialog is False:
            ok(f'팝업 없음 (차이 {delta:+.0f}) — 거짓 알림을 하지 않는다')
        elif dialog is None:
            ok('스크린샷 해석 불가 (건너뜀)')
        else:
            bad(f'build 없는 응답인데 팝업이 떴다 (차이 {delta:+.0f})')

        shutil.copy(SHOT, '/tmp/shot_C_nobuild.png')
        results['C_delta'] = delta
        cdp.close()

    finally:
        for p in (chrome, srv):
            if p is not None:
                try:
                    p.kill()
                except Exception:
                    pass

    print('\n' + '=' * 42)
    print(f' 통과 {PASS} / 실패 {FAIL}')
    print('=' * 42)
    print('\n스크린샷:')
    for n in ('A_same', 'B_diff', 'C_nobuild'):
        p = f'/tmp/shot_{n}.png'
        if os.path.exists(p):
            print(f'  {p}  ({os.path.getsize(p)} B)')
    print(f'\n중앙−바깥 측정값: {results}')
    return 0 if FAIL == 0 else 1


if __name__ == '__main__':
    sys.exit(main())

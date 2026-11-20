#!/usr/bin/env python3
"""
June's Scheduler — 계정 목록 + 로그인 불가 진단 (한 번에)

원하는 것: 등록된 아이디와 비밀번호를 마스킹해서 전부 보기.
현실     : 서버에는 비밀번호가 해시로만 있습니다. 되돌릴 수 없습니다.
           그래서 이 도구는 (1) 아이디 전부, (2) 비번 상태, (3) 흔한 비번이면
           그 값(마스킹), (4) 로그인이 왜 안 되는지 를 한 번에 보여줍니다.

사용:
  sudo python3 show_accounts.py /srv/june7486/sites/scheduler/data
"""
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

REGISTRY = 'ACCREGISTRYJUNESCHEDULER0001'
GATEWAY = 'http://127.0.0.1:8097'
ENV = '/srv/june7486/sites/scheduler/.env'

# 흔한 비밀번호 후보. 맞으면 그 값을 마스킹해서 보여준다.
CANDIDATES = [
    'test', '1234', '12345', '123456', '0000', '1111', 'aaaa', 'qwer',
    'password', 'pass1234', 'admin', 'admin1234', 'june', 'june7486',
    '7486', 'june1234', 'scheduler', 'junescheduler', 'test1234',
    'aaaa1111', '12341234', 'qwerty', 'apple', 'letmein', 'welcome1',
    'june2026', 'scheduler1234', 'scout', 'scout1234', '12345678',
]


def hash_password(user_id, pw):
    seed = f'june-scheduler-pw-v1|{user_id.lower()}|{pw}'.encode('utf-8')
    d = hashlib.sha256(seed).digest()
    for _ in range(256):
        d = hashlib.sha256(d + seed).digest()
    return d.hex()


def mask_end(s, keep=2):
    """뒷자리 별표 처리. 예: 'admin1234' → 'ad*******'"""
    if not s:
        return ''
    if len(s) <= keep:
        return s[0] + '*' * (len(s) - 1)
    return s[:keep] + '*' * (len(s) - keep)


def load(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def env_value(key):
    try:
        with open(ENV, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line.startswith(key + '='):
                    return line.split('=', 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def http_code(url, key=''):
    try:
        req = urllib.request.Request(url)
        if key:
            req.add_header('X-Sync-Key', key)
        with urllib.request.urlopen(req, timeout=4) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        return f'ERR({type(e).__name__})'


def main():
    data = sys.argv[1] if len(sys.argv) > 1 else '/srv/june7486/sites/scheduler/data'
    W = 78
    print('=' * W)
    print(" June's Scheduler — 계정 목록 및 로그인 진단")
    print('=' * W)

    if not os.path.isdir(data):
        print(f'\n[STOP] 데이터 디렉터리가 없습니다: {data}')
        print('  → 경로를 확인하십시오.')
        return 2

    # ── 1. 파일 현황 ────────────────────────────────────────────
    files = [f for f in sorted(os.listdir(data))
             if f.endswith('.json') and not f.startswith('.')]
    print(f'\n[1] 데이터 파일 {len(files)}개  ({data})')
    if not files:
        print('    ★ 파일이 하나도 없습니다.')
        print('      → 가비아 이전 때 데이터가 복사되지 않았을 가능성이 큽니다.')
        print('      → 이 경우 계정도 일정도 서버에 없습니다. 백업에서 복원해야 합니다.')
    for f in files:
        sz = os.path.getsize(os.path.join(data, f))
        tag = '  ← 계정 명부' if f == REGISTRY + '.json' else ''
        print(f'    {f:<44}{sz:>10,} B{tag}')

    # ── 2. 계정 목록 ────────────────────────────────────────────
    reg_path = os.path.join(data, REGISTRY + '.json')
    doc = load(reg_path)
    if not doc:
        print(f'\n[2] 계정 명부 없음')
        print('    → 아무도 서버에 로그인한 적이 없거나, 명부 파일이 사라졌습니다.')
        rows = {}
    else:
        ents = doc.get('entities', {})
        rows = {k[len('accounts/'):]: v for k, v in ents.items()
                if k.startswith('accounts/') and isinstance(v, dict)}
        print(f'\n[2] 등록된 계정 {len(rows)}개  (rev={doc.get("rev")})')

    if rows:
        print(f'\n    {"아이디":<20}{"표시이름":<13}{"권한":<7}{"상태":<6}비밀번호')
        print('    ' + '-' * 70)
        for aid in sorted(rows):
            a = rows[aid]
            # 비번 상태 판정
            h = a.get('pwHash')
            plain = a.get('password')
            if isinstance(plain, str) and plain:
                pw_txt = f'{mask_end(plain)}  (평문 저장됨)'
            elif isinstance(h, str) and h:
                hit = [c for c in CANDIDATES if hash_password(aid, c) == h]
                if hit:
                    pw_txt = f'{mask_end(hit[0])}  ← 흔한 비번 (해시 대조로 확인)'
                else:
                    pw_txt = '복구 불가 (단방향 해시, 흔한 값 아님)'
            else:
                pw_txt = '없음 ← 이 계정은 로그인 불가'
            print(f'    {aid:<20}{str(a.get("displayName",""))[:12]:<13}'
                  f'{"MASTER" if a.get("isMaster") else "일반":<7}'
                  f'{"활성" if a.get("enabled", True) else "비활성":<6}{pw_txt}')

    # ── 3. 워크스페이스 (일정 보존 확인) ────────────────────────
    print('\n[3] 계정별 워크스페이스 (일정 데이터)')
    any_ws = False
    for f in files:
        if f == REGISTRY + '.json':
            continue
        d = load(os.path.join(data, f))
        if not d:
            continue
        ents = d.get('entities', {})
        n_task = sum(1 for k in ents if k.startswith('tasks/'))
        owners = [k[len('accounts/'):] for k, v in ents.items()
                  if k.startswith('accounts/') and isinstance(v, dict)]
        if n_task or owners:
            any_ws = True
            shown = ', '.join(owners) if owners else '(없음)'
            print(f'    {f}  일정 {n_task:>3}개  계정행: {shown}')
    if not any_ws:
        print('    (비어 있음)')

    # ── 4. 로그인이 왜 안 되는가 ────────────────────────────────
    print('\n[4] 로그인 진단')
    secret = env_value('SYNC_SECRET')
    has_secret = bool(secret)
    print(f'    (가) 게이트웨이 비밀키 설정: '
          f'{"있음 ★ 원인" if has_secret else "없음 (정상)"}')
    if has_secret:
        print('        → 앱은 키를 보낼 수단이 없습니다. 모든 /api/ 가 401 이 됩니다.')
        print('        → 처방: .env 의 SYNC_SECRET 을 빈 값으로 (HOST=127.0.0.1 이라 안전)')

    print(f'    (나) /health           : {http_code(GATEWAY + "/health")}')
    code_nokey = http_code(f'{GATEWAY}/api/state?ws={REGISTRY}')
    note = ''
    if code_nokey == 401:
        if has_secret:
            note = '  ★ 401 → 위 (가) 가 원인'
        else:
            note = ('  ★ 401 인데 .env 를 못 읽었습니다.'
                    ' 서비스가 실제로 읽는 키가 따로 있는지 확인하십시오')
    print(f'    (다) /api/state (키없이): {code_nokey}{note}')
    if has_secret:
        print(f'    (라) /api/state (키있이): '
              f'{http_code(f"{GATEWAY}/api/state?ws={REGISTRY}", secret)}')
    print(f'    (마) 계정 명부 존재    : '
          f'{"있음" if doc else "없음 ★ 원인"}')
    if not rows and doc is not None:
        print('        → 명부는 있는데 계정이 0개입니다. 계정을 다시 심어야 합니다.')

    # ── 5. 다음 할 일 ───────────────────────────────────────────
    print('\n[5] 다음 할 일')
    if has_secret and code_nokey == 401:
        print('    1) SYNC_SECRET 을 비우십시오 (위 처방). 앱에서 바로 로그인됩니다.')
    if not rows:
        print('    2) 계정을 서버에 심으십시오:')
        print('       sudo python3 recover_accounts.py <data> \\')
        print('            --create june7486 --pw \'새비번\' --name \'이승준\' --master --apply')
    elif rows:
        print('    2) 비밀번호를 새로 심으십시오:')
        print('       sudo python3 recover_accounts.py <data> --reset-pw <아이디> --pw \'새비번\' --apply')
    print('\n    ※ 비밀번호는 해시만 저장되어 되돌릴 수 없습니다. 복구가 아니라 재설정입니다.')
    print('=' * W)
    return 0


if __name__ == '__main__':
    sys.exit(main())

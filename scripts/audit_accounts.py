#!/usr/bin/env python3
"""
가비아 서버 계정 명부 점검 스크립트

용도: 운영 서버의 데이터 디렉터리를 읽어 "어떤 계정이 있는지"를 정리하고,
      비밀번호가 복구 가능한지 / 위험한 계정이 있는지 점검합니다.

중요: 이 스크립트는 비밀번호를 복구하지 않습니다. 서버에는 해시만 있고
      평문은 없습니다. 아래는 (1) 명부 목록, (2) 약한 비밀번호 탐지,
      (3) 평문이 남아있는 구버전 행 탐지 를 합니다.

사용: sudo python3 audit_accounts.py /srv/june7486/sites/scheduler/data
"""
import hashlib
import json
import os
import sys

REGISTRY = 'ACCREGISTRYJUNESCHEDULER0001.json'

# 앱의 Store.hashPassword 와 동일한 계산.
#   seed = "june-scheduler-pw-v1|<id 소문자>|<비밀번호>"
#   d = sha256(seed); 256회 반복: d = sha256(d + seed)
def hash_password(user_id: str, pw: str) -> str:
    seed = f'june-scheduler-pw-v1|{user_id.lower()}|{pw}'.encode('utf-8')
    d = hashlib.sha256(seed).digest()
    for _ in range(256):
        d = hashlib.sha256(d + seed).digest()
    return d.hex()


# 점검용 최소 사전. 실제 공격 도구가 아니라 "이 정도면 위험"을 보여주는 용도.
WEAK_CANDIDATES = [
    'test', '1234', '12345', '123456', '0000', '1111', 'aaaa', 'qwer',
    'password', 'pass1234', 'admin', 'admin1234', 'june', 'june7486',
    '7486', 'june1234', 'scheduler', 'junescheduler', 'test1234',
    'aaaa1111', '12341234', 'qwerty', 'apple', 'letmein', 'welcome1',
]


def load(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)


def entities_of(doc):
    """게이트웨이 저장 형식에서 entities 꺼내기 (형식 차이 방어)."""
    if isinstance(doc, dict):
        if 'entities' in doc and isinstance(doc['entities'], dict):
            return doc['entities']
    return doc if isinstance(doc, dict) else {}


def main():
    if len(sys.argv) < 2:
        print('사용: sudo python3 audit_accounts.py <data 디렉터리>')
        return 2
    data_dir = sys.argv[1]
    if not os.path.isdir(data_dir):
        print(f'[STOP] 디렉터리가 없습니다: {data_dir}')
        return 2

    print('=' * 78)
    print(f' 계정 명부 점검 — {data_dir}')
    print('=' * 78)

    # ── 1. 데이터 파일 목록 ──────────────────────────────────────────
    files = sorted(
        f for f in os.listdir(data_dir)
        if f.endswith('.json') and not f.startswith('.')
    )
    print(f'\n[1] 워크스페이스 파일 {len(files)}개')
    reg_path = os.path.join(data_dir, REGISTRY)
    for f in files:
        tag = '  ← 계정 명부(레지스트리)' if f == REGISTRY else ''
        size = os.path.getsize(os.path.join(data_dir, f))
        print(f'    {f:<42} {size:>10,} B{tag}')

    if not os.path.exists(reg_path):
        print('\n[!] 계정 명부가 없습니다.')
        print('    → 아직 아무도 로그인하지 않았거나, 동기화가 꺼져 있습니다.')
        print('    → 이 경우 서버에 계정 자체가 없습니다(로컬 전용 상태).')
        return 0

    # ── 2. 계정 목록 ─────────────────────────────────────────────────
    doc = load(reg_path)
    ents = entities_of(doc)
    accounts = {}
    for k, v in ents.items():
        if k.startswith('accounts/') and isinstance(v, dict):
            accounts[k[len('accounts/'):]] = v

    print(f'\n[2] 등록된 계정 {len(accounts)}개')
    if not accounts:
        print('    (없음)')
        return 0

    hdr = f'    {"아이디":<22} {"표시이름":<16} {"권한":<7} {"상태":<6} {"비번저장":<8} {"생성일":<12}'
    print(hdr)
    print('    ' + '-' * (len(hdr) - 4))
    for aid in sorted(accounts):
        a = accounts[aid]
        role = 'MASTER' if a.get('isMaster') else '일반'
        state = '활성' if a.get('enabled', True) else '비활성'
        has_pw = a.get('pwHash')
        plain = a.get('password')
        if isinstance(plain, str) and plain:
            stored = '평문!'
        elif isinstance(has_pw, str) and has_pw:
            stored = '해시'
        else:
            stored = '없음'
        created = str(a.get('createdAt', ''))[:10]
        name = str(a.get('displayName', ''))[:15]
        print(f'    {aid:<22} {name:<16} {role:<7} {state:<6} {stored:<8} {created:<12}')

    # ── 3. 평문 노출 행 ──────────────────────────────────────────────
    plain_rows = [
        aid for aid, a in accounts.items()
        if isinstance(a.get('password'), str) and a.get('password')
    ]
    print('\n[3] 평문 비밀번호가 남아있는 구버전 행')
    if plain_rows:
        for aid in plain_rows:
            print(f'    [!] {aid} — 평문 필드 존재. 앱이 한 번 로그인하면 자동 정리됩니다.')
    else:
        print('    없음 (전부 해시)')

    # ── 4. 약한 비밀번호 탐지 ────────────────────────────────────────
    print('\n[4] 약한 비밀번호 탐지 (소사전 대조)')
    found = False
    for aid, a in sorted(accounts.items()):
        h = a.get('pwHash')
        if not (isinstance(h, str) and h):
            continue
        hits = [c for c in WEAK_CANDIDATES if hash_password(aid, c) == h]
        if hits:
            found = True
            for c in hits:
                shown = (c[0] + '*' * (len(c) - 1)) if len(c) > 1 else '*'
                print(f'    [!] 아이디 "{aid}" — 비밀번호가 "{shown}" 입니다. 즉시 변경 필요.')
    if not found:
        print('    소사전에서 못 찾음 (안전하다는 뜻은 아니고, 흔한 값은 아님)')

    # ── 5. 데모 계정 존재 여부 ───────────────────────────────────────
    print('\n[5] 데모/시험 계정')
    if 'test' in accounts:
        print('    [!] 레지스트리에 "test" 계정이 있습니다.')
    else:
        print('    레지스트리에는 "test" 없음')
    print('    ※ 주의: 앱이 부팅할 때마다 기기 로컬에 id/pw = test/test 계정을')
    print('      심습니다(store.dart _ensureTestUser, enabled=true).')
    print('      레지스트리에 없어도 로컬 대조로 로그인이 통과합니다.')
    print('      → 브라우저에서 test / test 를 직접 입력해 확인해 보십시오.')

    print('\n' + '=' * 78)
    return 0


if __name__ == '__main__':
    sys.exit(main())

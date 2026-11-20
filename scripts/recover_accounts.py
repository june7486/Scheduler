#!/usr/bin/env python3
"""
June's Scheduler — 계정 명부 복구 도구

가비아 이전 후 기존 아이디로 로그인이 안 될 때 쓰는 도구입니다.

무엇을 하는가
  1) 서버 데이터에서 계정 명부(레지스트리)를 읽어 아이디 목록을 보여줍니다.
  2) 비밀번호를 새 값으로 다시 심습니다(해시만 기록).
  3) 명부에 없는 아이디를 새로 만들 수 있습니다.

무엇을 하지 않는가
  - 일정(tasks/), 카테고리(categories/), 로그(logs/)는 건드리지 않습니다.
    계정 행(accounts/...)만 다룹니다. 기존 일정은 그대로 남습니다.
  - 비밀번호를 복구하지 않습니다. 되돌릴 수 없으므로 새로 심습니다.
  - 실행 전 자동 백업을 만듭니다.

사용
  # 1) 현황 보기 (읽기만)
  sudo python3 recover_accounts.py /srv/june7486/sites/scheduler/data --list

  # 2) 비밀번호 재설정 (미리보기)
  sudo python3 recover_accounts.py <data> --reset-pw june7486 --pw '새비번'

  # 3) 실제 적용
  sudo python3 recover_accounts.py <data> --reset-pw june7486 --pw '새비번' --apply

  # 4) 명부에 아이디가 아예 없을 때 새로 만들기
  sudo python3 recover_accounts.py <data> --create june7486 --pw '새비번' \
       --name '이승준' --master --apply
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import sys
import urllib.request

REGISTRY = 'ACCREGISTRYJUNESCHEDULER0001'
GATEWAY = 'http://127.0.0.1:8097'


# ─────────────────────────── 앱과 동일한 계산 ───────────────────────────
def hash_password(user_id: str, pw: str) -> str:
    """lib/services/store.dart 의 Store.hashPassword 와 바이트 단위로 동일."""
    seed = f'june-scheduler-pw-v1|{user_id.lower()}|{pw}'.encode('utf-8')
    d = hashlib.sha256(seed).digest()
    for _ in range(256):
        d = hashlib.sha256(d + seed).digest()
    return d.hex()


def workspace_code(uid: str) -> str:
    """lib/services/store.dart 의 Store.workspaceCodeFor 와 동일."""
    seed = f'june-scheduler-account-v2|{uid}'.encode('utf-8')
    digest = hashlib.sha256(seed).digest()
    for _ in range(128):
        digest = hashlib.sha256(digest + seed).digest()
    return 'ACC' + digest.hex()[:28].upper()


# ─────────────────────────── 파일 입출력 ───────────────────────────
def read_doc(path):
    if not os.path.exists(path):
        return {'rev': 0, 'gen': 0, 'entities': {}}
    with open(path, 'r', encoding='utf-8') as f:
        doc = json.load(f)
    if not isinstance(doc, dict):
        raise SystemExit(f'[STOP] 형식이 예상과 다릅니다: {path}')
    doc.setdefault('entities', {})
    doc.setdefault('rev', 0)
    doc.setdefault('gen', 0)
    return doc


def write_doc_atomic(path, doc):
    """게이트웨이 writeAtomic 과 같은 방식: 임시 파일 + rename."""
    tmp = f'{path}.{os.getpid()}.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(doc, f, ensure_ascii=False)
    os.replace(tmp, path)


def backup(data_dir):
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    dest = os.path.join(data_dir, f'.backup-accounts-{stamp}')
    os.makedirs(dest, exist_ok=True)
    n = 0
    for name in os.listdir(data_dir):
        if name.endswith('.json') and not name.startswith('.'):
            shutil.copy2(os.path.join(data_dir, name), os.path.join(dest, name))
            n += 1
    return dest, n


def gateway_key(env_path):
    """게이트웨이 키를 .env 에서 읽는다. 화면에 절대 출력하지 않는다."""
    try:
        with open(env_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line.startswith('SYNC_SECRET='):
                    return line.split('=', 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ''


def drop_cache(ws_list, key):
    """게이트웨이 RAM 캐시(8초)를 비운다. 실패해도 치명적이지 않다."""
    ok = 0
    for ws in ws_list:
        try:
            body = json.dumps({'ws': ws}).encode()
            req = urllib.request.Request(
                f'{GATEWAY}/api/drop', data=body,
                headers={'Content-Type': 'application/json'}, method='POST')
            if key:
                req.add_header('X-Sync-Key', key)
            with urllib.request.urlopen(req, timeout=3) as r:
                if r.status == 200:
                    ok += 1
        except Exception:
            pass
    return ok


# ─────────────────────────── 명령 ───────────────────────────
def cmd_list(data_dir):
    reg_path = os.path.join(data_dir, REGISTRY + '.json')
    print(f'데이터: {data_dir}')
    print(f'레지스트리: {"있음" if os.path.exists(reg_path) else "없음"}')
    if not os.path.exists(reg_path):
        print('\n[!] 계정 명부가 없습니다. 아직 아무도 로그인하지 않은 상태입니다.')
        print('    → 기존 아이디를 복구하려면 --create 로 새로 만들어야 합니다.')
        return 0

    doc = read_doc(reg_path)
    rows = {k[len('accounts/'):]: v for k, v in doc['entities'].items()
            if k.startswith('accounts/') and isinstance(v, dict)}
    print(f'\n등록된 계정 {len(rows)}개 (rev={doc.get("rev")})\n')
    print(f'  {"아이디":<20} {"표시이름":<14} {"권한":<7} {"상태":<6} {"비번":<7} 생성일')
    print('  ' + '-' * 74)
    for aid in sorted(rows):
        a = rows[aid]
        print(f'  {aid:<20} {str(a.get("displayName",""))[:13]:<14} '
              f'{"MASTER" if a.get("isMaster") else "일반":<7} '
              f'{"활성" if a.get("enabled", True) else "비활성":<6} '
              f'{"해시" if a.get("pwHash") else ("평문" if a.get("password") else "없음"):<7} '
              f'{str(a.get("createdAt",""))[:10]}')

    # 일정이 있는 워크스페이스도 알려준다 (데이터 보존 확인용)
    print('\n워크스페이스 파일:')
    for name in sorted(os.listdir(data_dir)):
        if not name.endswith('.json') or name.startswith('.') or name == REGISTRY + '.json':
            continue
        p = os.path.join(data_dir, name)
        d = read_doc(p)
        n_task = sum(1 for k in d['entities'] if k.startswith('tasks/'))
        owner = ''
        for k, v in d['entities'].items():
            if k.startswith('accounts/') and isinstance(v, dict):
                owner = k[len('accounts/'):]
        print(f'  {name}  일정 {n_task:>3}개  계정행: {owner or "(없음)"}')
    return 0


def _upsert(data_dir, aid, pw, name, master, apply_change):
    """레지스트리와 그 계정의 워크스페이스 양쪽에 계정 행을 심는다."""
    h = hash_password(aid, pw)
    now = datetime.datetime.now().isoformat(timespec='milliseconds')
    row = {
        'id': aid,
        'displayName': name,
        'isMaster': master,
        'enabled': True,
        'createdAt': now,
        'updatedAt': int(datetime.datetime.now().timestamp() * 1000),
        'pwHash': h,
    }

    targets = [
        (os.path.join(data_dir, REGISTRY + '.json'), True),
        (os.path.join(data_dir, workspace_code(aid) + '.json'), False),
    ]

    for path, is_reg in targets:
        exists = os.path.exists(path)
        doc = read_doc(path)
        key = f'accounts/{aid}'
        prev = doc['entities'].get(key)
        merged = dict(prev) if isinstance(prev, dict) else {}
        # 기존 표시이름/생성일은 보존한다 (사용자가 지금 쓰는 이름을 덮지 않는다)
        for f in ('displayName', 'createdAt'):
            if merged.get(f):
                row[f] = merged[f]
        if 'isMaster' in merged and merged['isMaster'] and not master:
            row['isMaster'] = True
        merged.update(row)
        merged.pop('password', None)   # 구버전 평문 제거
        doc['entities'][key] = merged
        doc['rev'] = int(doc.get('rev', 0)) + 1

        label = '레지스트리' if is_reg else '워크스페이스'
        act = '갱신' if isinstance(prev, dict) else '신규'
        print(f'  {label:<12} {"파일있음" if exists else "파일생성"} · 계정행 {act}'
              f' · entities {len(doc["entities"])}개 · rev {doc["rev"]}')
        if apply_change:
            write_doc_atomic(path, doc)
    return h


def cmd_reset(data_dir, aid, pw, name, master, apply_change, env_path):
    print(f'\n{"[적용]" if apply_change else "[미리보기]"} 계정 재설정: {aid}')
    if apply_change:
        dest, n = backup(data_dir)
        print(f'  백업: {dest} ({n}개 파일)')
    h = _upsert(data_dir, aid, pw, name or aid, master, apply_change)
    print(f'  새 비번 해시 앞 16자: {h[:16]}…  (전체는 기록하지 않습니다)')

    if apply_change:
        ws = workspace_code(aid)
        key = gateway_key(env_path)
        n = drop_cache([REGISTRY, ws], key)
        print(f'  게이트웨이 캐시 비움: {n}/2  (0이면 8초 뒤 자동 만료)')
        print('\n  이제 앱에서 새 비밀번호로 로그인하십시오.')
        print('  일정은 그대로입니다 (tasks/ 는 건드리지 않았습니다).')
    else:
        print('\n  실제로 쓰려면 같은 명령에 --apply 를 붙이십시오.')
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('data_dir')
    ap.add_argument('--list', action='store_true', help='현황만 보기')
    ap.add_argument('--reset-pw', metavar='ID', help='이 아이디의 비번을 다시 심기')
    ap.add_argument('--create', metavar='ID', help='(별칭) 새 아이디 만들기')
    ap.add_argument('--pw', help='새 비밀번호')
    ap.add_argument('--name', default='', help='표시 이름')
    ap.add_argument('--master', action='store_true', help='마스터 권한 부여')
    ap.add_argument('--apply', action='store_true', help='실제로 쓰기')
    ap.add_argument('--env', default='/srv/june7486/sites/scheduler/.env')
    a = ap.parse_args()

    if not os.path.isdir(a.data_dir):
        print(f'[STOP] 디렉터리 없음: {a.data_dir}')
        return 2

    if a.list or (not a.reset_pw and not a.create):
        return cmd_list(a.data_dir)

    aid = a.reset_pw or a.create
    if not aid:
        print('[STOP] 아이디를 지정하십시오')
        return 2
    if not a.pw:
        print('[STOP] --pw 로 새 비밀번호를 지정하십시오')
        return 2
    if len(a.pw) < 4:
        print('[STOP] 비밀번호는 4자 이상이어야 합니다 (앱 규칙)')
        return 2
    return cmd_reset(a.data_dir, aid, a.pw, a.name, a.master, a.apply, a.env)


if __name__ == '__main__':
    sys.exit(main())

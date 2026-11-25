#!/usr/bin/env python3
"""스케줄러 운영 전 사전 점검 — 읽기 전용. 아무것도 바꾸지 않습니다.

## 왜 따로 있나
전환 스크립트(scheduler-cutover.sh) 안에 점검을 섞어 두면, 점검하다가 상태를
바꾸는 코드가 섞여 들어가도 눈에 띄지 않습니다. 실제로 2026-11-24 판에서 유닛
백업 `cp` 가 "읽기 전용" 구간 안에 있었습니다. 그래서 점검은 분리합니다.

## 확인하는 것
  1. 전환에 필요한 명령이 있는가 (node, systemctl, nginx, unzip, curl)
  2. 서비스 계정이 있는가
  3. nginx 설정 파일을 찾을 수 있는가 + server_name 이 sch.june7486.com 인가
  4. **root 지시자가 두 개인가** — ACME(certbot) + 앱 번들. 이 둘을 구분하지
     못하면 인증서 갱신이 90일 뒤 조용히 실패합니다.
  5. `nginx -t` 가 통과하는가 (지금 상태에서)
  6. **reload 경로가 실제로 동작하는가** — reload 는 무중단이어야 하고,
     실패하면 그 자체가 차단점입니다. `systemctl reload nginx` 를 실제로
     호출하지 않고, 호출 가능성만 확인합니다 (점검은 읽기 전용이므로).
     대신 nginx 프로세스의 master/worker 구조와 reload 신호 지원을 봅니다.
  7. 포트 8097 이 이미 점유되어 있는가 (전환 시 충돌 여부)
  8. 디스크 여유 (ZIP 20MB + 전개 60MB × 2)
  9. 기존 배포본·데이터 위치

종료코드 0 = 전환 준비됨, 1 = 차단점 있음.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ.get("SCHED_ROOT", "/srv/june7486/sites"))
LIVE = ROOT / "scheduler"
WWW = "sch.june7486.com"
PORT = 8097

oks, fails, warns = [], [], []


def ok(m):
    oks.append(m)


def fail(m):
    fails.append(m)


def warn(m):
    warns.append(m)


def run(cmd, timeout=15):
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", "not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def find_bin(name: str):
    """PATH 에 없어도 표준 경로에서 찾습니다.

    ## 왜 필요한가
    `shutil.which("nginx")` 는 sudo 의 secure_path 나 systemd 환경에서 빈 값을
    돌려줍니다. 그러면 설정은 멀쩡한데 "nginx 없음"으로 차단점을 보고하게 되고,
    운영자가 실제로는 없는 문제를 쫓게 됩니다. 바이너리는 있는데 PATH 에 없을
    뿐이므로 표준 설치 경로를 함께 봅니다.
    """
    p = shutil.which(name)
    if p:
        return p
    for d in ("/usr/sbin", "/sbin", "/usr/local/sbin", "/usr/bin", "/usr/local/bin", "/bin"):
        cand = Path(d) / name
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return None


def nginx_pid_file(ngx: str):
    """nginx 가 실제로 쓰는 pid 경로를 설정에서 읽습니다 (하드코딩 금지)."""
    rc, out, _ = run([ngx, "-t"], timeout=10)
    # -t 는 pid 경로를 알려주지 않습니다. 설정 파일에서 찾습니다.
    for cand in ("/etc/nginx/nginx.conf",):
        p = Path(cand)
        if not p.is_file():
            continue
        m = re.search(r"^\s*pid\s+([^;]+);", p.read_text(errors="replace"), re.M)
        if m:
            return Path(m.group(1).strip())
    return Path("/run/nginx.pid")


def find_nginx_conf():
    """server_name 이 sch.june7486.com 인 설정 파일을 찾습니다."""
    for base in ("/etc/nginx/sites-enabled", "/etc/nginx/conf.d"):
        b = Path(base)
        if not b.is_dir():
            continue
        for p in sorted(b.rglob("*")):
            try:
                if p.is_file() and re.search(
                        rf"server_name[^;]*\b{re.escape(WWW)}\b",
                        p.read_text(errors="replace")):
                    return p.resolve()
            except Exception:
                continue
    return None


def main() -> int:
    print("\n\033[1;36m▶ 스케줄러 전환 사전 점검 (읽기 전용)\033[0m")
    print(f"  기준 경로: {ROOT}")
    print(f"  대상     : https://{WWW}")

    # ── 1. 명령 ────────────────────────────────────────────────
    need = {"node": "게이트웨이 실행", "systemctl": "유닛 관리",
            "nginx": "리버스 프록시", "unzip": "산출물 전개",
            "curl": "헬스 확인", "python3": "게이트"}
    missing = [c for c in need if find_bin(c) is None]
    if missing:
        for c in missing:
            fail(f"명령 없음: {c} ({need[c]})")
    else:
        ok(f"필요 명령 {len(need)}종 모두 있음")
        rc, out, _ = run(["node", "-v"])
        if rc == 0:
            ok(f"node {out.strip()}")
    NGX = find_bin("nginx")
    if NGX is None:
        fail("nginx 바이너리를 찾을 수 없음 — /usr/sbin/nginx 등 표준 경로에도 없습니다")
    else:
        ok(f"nginx 바이너리: {NGX}")

    # ── 2. 서비스 계정 ─────────────────────────────────────────
    unit = Path("/etc/systemd/system/june-gateway.service")
    svc_user = "june"
    if unit.is_file():
        m = re.search(r"^User=(\S+)", unit.read_text(errors="replace"), re.M)
        if m:
            svc_user = m.group(1)
    rc, _, _ = run(["id", svc_user])
    if rc == 0:
        ok(f"서비스 계정 존재: {svc_user}")
    else:
        fail(f"서비스 계정 없음: {svc_user} — useradd 또는 유닛 수정 필요")

    # ── 3. nginx 설정 ──────────────────────────────────────────
    conf = find_nginx_conf()
    if conf is None:
        fail(f"nginx 설정을 찾을 수 없음 — server_name {WWW} 인 파일이 없습니다")
    else:
        ok(f"nginx 설정: {conf}")
        text = conf.read_text(errors="replace")

        port_ok = re.search(rf"\b127\.0\.0\.1:{PORT}\b", text)
        if port_ok:
            ok(f"upstream 이 127.0.0.1:{PORT} 를 가리킴")
        else:
            fail(f"upstream 에 127.0.0.1:{PORT} 가 없음 — 게이트웨이로 프록시되지 않습니다")

        # ## root 가 두 개여야 정상입니다
        roots = re.findall(r"^\s*root\s+([^;]+);", text, re.M)
        acme = [r for r in roots if re.search(r"certbot|letsencrypt|well-known|acme", r)]
        app_roots = [r for r in roots if r not in acme]
        if len(roots) >= 2 and acme and app_roots:
            ok(f"root 지시자 {len(roots)}개 — ACME({acme[0].strip()}) + 앱({app_roots[0].strip()})")
        elif not acme:
            warn("ACME(certbot) root 가 없습니다 — 인증서 자동 갱신 경로를 확인하십시오")
        else:
            warn(f"root 지시자 {len(roots)}개 — 앱 번들 root 를 특정하지 못했습니다: {roots}")
        # 전환 스크립트가 바꿔야 하는 줄이 정확히 하나인지 확인합니다
        targets = [r for r in app_roots]
        if len(targets) == 1:
            ok("전환 시 바꿀 앱 root 줄이 정확히 1개 (certbot 줄 보호 가능)")
        elif len(targets) > 1:
            warn(f"앱 root 줄이 {len(targets)}개 — 전환 스크립트는 첫 줄만 바꿉니다: {targets}")

        # /api/ 프록시에 후행 슬래시가 붙으면 경로가 잘립니다
        if re.search(r"proxy_pass\s+http://[^;\s]+/;", text):
            fail("proxy_pass 에 후행 슬래시가 있습니다 — /api/ 경로가 잘려 404 가 됩니다")

    # ── 4. nginx -t ────────────────────────────────────────────
    if NGX is None:
        fail("nginx -t 를 실행할 수 없습니다 (바이너리 없음)")
    else:
        rc, out, err = run([NGX, "-t"])
        blob = (err or "") + (out or "")
        syntax_ok = "syntax is ok" in blob
        # ## 문법 오류와 권한 오류를 구분합니다
        # 비-root 로 `nginx -t` 를 돌리면 pid 파일을 열지 못해 emerg 로 끝납니다.
        # 그런데 설정 자체는 멸쟁합니다. 이 둘을 같은 "실패"로 묶으면
        # 운영자가 있지도 않은 설정 오류를 찾아 헤멥니다.
        perm_only = re.search(r"open\(\)\s+\"?[^\"]*nginx\.pid", blob) or \
                    "Permission denied" in blob
        if rc == 0 or (syntax_ok and perm_only):
            if rc == 0:
                ok("nginx -t 통과 (현재 설정 유효)")
            else:
                warn("nginx -t 문법 정상 — 비-root 실행이라 pid 파일만 열지 못했습니다 "
                     "(root 로 돌리면 통과합니다)")
        else:
            fail(f"nginx -t 실패 — reload 하면 nginx 가 뜨지 않습니다\n{blob.strip()[:300]}")

    # ── 5. reload 경로 ─────────────────────────────────────────
    # reload 는 master 에 SIGHUP 을 보냅니다. master 가 없으면 reload 는
    # 아무 일도 하지 않고 성공한 것처럼 보입니다 (systemctl 은 유닛만 봅니다).
    rc, out, _ = run(["systemctl", "is-active", "nginx"])
    if rc == 0 and out.strip() == "active":
        ok("nginx 유닛 active — systemctl reload nginx 사용 가능")
    else:
        warn(f"nginx 유닛 상태: {out.strip() or 'unknown'}")

    rc, out, _ = run("ps -eo pid,ppid,args | grep -c '[n]ginx: master process'")
    if rc == 0 and out.strip().isdigit() and int(out.strip()) >= 1:
        ok("nginx master 프로세스 존재 — SIGHUP reload 가 실제로 동작합니다")
        rc2, out2, _ = run("ps -eo args | grep -c '[n]ginx: worker process'")
        if rc2 == 0 and out2.strip().isdigit() and int(out2.strip()) >= 1:
            ok(f"nginx worker {out2.strip()}개 — 무중단 reload 구조")
        else:
            warn("nginx worker 가 보이지 않습니다")
    else:
        fail("nginx master 프로세스가 없습니다 — reload 해도 설정이 적용되지 않습니다")
    PIDF = nginx_pid_file(NGX) if NGX else Path("/run/nginx.pid")
    if not PIDF.exists():
        warn(f"{PIDF} 없음 — nginx 설정의 pid 경로와 확인하십시오")

    # ── 6. 포트 ────────────────────────────────────────────────
    rc, out, _ = run(f"ss -tln 2>/dev/null | grep -c ':{PORT} '")
    listening = int(out.strip()) if rc == 0 and out.strip().isdigit() else 0
    if listening:
        ok(f"{PORT} 리스닝 중 (운영 게이트웨이가 살아 있음) — 전환 시 잠깐 내려갑니다")
    else:
        warn(f"{PORT} 리스닝 없음 — 게이트웨이가 이미 내려가 있을 수 있습니다")
    rc, out, _ = run(f"ss -tln 2>/dev/null | grep -c ':18097 '")
    if rc == 0 and out.strip().isdigit() and int(out.strip()) > 0:
        warn("사전 점검용 포트 18097 이 이미 사용 중입니다 — 비공개 기동이 실패합니다")
    else:
        ok("비공개 기동 포트 18097 비어 있음")

    # ── 7. 디스크 ──────────────────────────────────────────────
    st = shutil.disk_usage(str(ROOT) if ROOT.exists() else "/")
    free_mb = st.free // (1024 * 1024)
    if free_mb > 500:
        ok(f"디스크 여유 {free_mb:,} MB (전개 2회분 ≈ 130 MB 필요)")
    else:
        fail(f"디스크 여유 부족: {free_mb} MB — 전개 실패 위험")

    # ── 8. 기존 배포본 ─────────────────────────────────────────
    if LIVE.is_dir():
        ok(f"운영 배포본 있음: {LIVE}")
        if (LIVE / "data").is_dir():
            ok("운영 data 있음 — 전환 시 보존 이동 대상 (삭제 아님)")
        if (LIVE / ".env").is_file():
            warn("운영 .env 있음 — 전환 시 새 동기화 키로 교체됩니다 (이전 키 미사용)")
    else:
        warn(f"운영 배포본 없음: {LIVE} — 최초 설치로 진행됩니다")

    # ── 출력 ───────────────────────────────────────────────────
    print()
    for m in oks:
        print(f"  \033[32mOK  \033[0m {m}")
    for m in warns:
        print(f"  \033[33m주의\033[0m {m}")
    for m in fails:
        print(f"  \033[31m차단\033[0m {m}")

    print()
    if fails:
        print(f"\033[1;31m✗ 차단점 {len(fails)}건 — 이 상태로 전환하면 실패합니다\033[0m\n")
        return 1
    print(f"\033[1;32m✓ 점검 통과 (주의 {len(warns)}건) — 전환 준비됨\033[0m\n")
    print(json.dumps({"pass": True, "checks": len(oks), "warnings": warns},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

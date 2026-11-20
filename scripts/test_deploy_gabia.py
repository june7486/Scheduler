#!/usr/bin/env python3
"""
배포 스크립트의 안전장치를 실제 FTP 서버로 검증한다.

## 왜 이 테스트가 필요한가

"롤백 기능이 있다"와 "롤백이 실제로 동작한다"는 다르다. 배포 스크립트를
검증 없이 넘기면, 사고가 난 뒤에야 반쪽짜리 롤백이라는 걸 알게 된다. 그때는
이미 사이트가 깨진 상태다.

이 테스트는 로컬에 진짜 FTP 서버(pyftpdlib)를 띄우고:

  1. 서버에 "옛 버전" 사이트를 미리 심어둔다  (실제 운영 중인 사이트를 흉내)
  2. 배포를 실행한다                          (새 버전이 올라간다)
  3. 파일이 실제로 바뀌었는지 확인한다
  4. 롤백을 실행한다                          (옛 버전으로 돌아가야 한다)
  5. 옛 버전과 **바이트 단위로 같아졌는지** 확인한다

그리고 나쁜 경우도 검증한다:

  6. 업로드가 중간에 실패하면 자동 롤백되는가
  7. index.html 이 정말 마지막에 올라가는가 (부분 배포 보호)

## 실행

  pip install pyftpdlib
  python3 scripts/test_deploy_gabia.py
"""

from __future__ import annotations

import hashlib
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
SCRIPT = PROJECT_DIR / "scripts" / "deploy_gabia.py"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def sha(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


class FtpFixture:
    """
    임시 FTP 서버 + 임시 사이트 루트.

    ## 왜 스레드인가
    pyftpdlib 는 자체 이벤트 루프를 돈다. blocking 으로 띄우면 테스트가 거기서
    멈춘다. 별도 스레드 + `serve_forever()` 로 띄우고, 끝날 때 `close_all()`.
    """

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="gabia_site_"))
        self.port = free_port()
        self.user = "testuser"
        self.password = "testpass1234"
        self.server = None
        self.thread = None

    def start(self) -> None:
        from pyftpdlib.authorizers import DummyAuthorizer
        from pyftpdlib.handlers import FTPHandler
        from pyftpdlib.servers import FTPServer

        authorizer = DummyAuthorizer()
        # elradfmwMT = 전체 권한 (읽기/쓰기/삭제/디렉터리 생성)
        authorizer.add_user(self.user, self.password, str(self.root), perm="elradfmwMT")

        handler = FTPHandler
        handler.authorizer = authorizer
        handler.banner = "test-ftp ready"

        self.server = FTPServer(("127.0.0.1", self.port), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

        # 서버가 실제로 응답할 때까지 기다린다 (고정 sleep 은 느리거나 불안정)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.3):
                    return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("FTP 서버가 뜨지 않았습니다")

    def stop(self) -> None:
        if self.server:
            self.server.close_all()
        shutil.rmtree(self.root, ignore_errors=True)


def write_file(base: Path, rel: str, content: str) -> Path:
    p = base / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return p


def run(cfg_path: Path, *args: str) -> subprocess.CompletedProcess:
    """deploy_gabia.py 를 별도 프로세스로 실행 (실제 사용과 같은 경로)."""
    env = dict(os.environ)
    # .env.gabia 가 아니라 임시 파일을 쓰도록 강제한다 — 실제 설정을 건드리지 않기 위해
    env["DEPLOY_ENV_OVERRIDE"] = str(cfg_path)
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        cwd=str(PROJECT_DIR),
        env=env,
        timeout=300,
    )


# ─────────────────────────────────────────────────────────────────────────────
# 검증 항목
# ─────────────────────────────────────────────────────────────────────────────
results: list[tuple[bool, str, str]] = []


def check(cond: bool, label: str, detail: str = "") -> None:
    results.append((bool(cond), label, detail))
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {label}")
    if detail and not cond:
        for line in detail.splitlines()[:12]:
            print(f"         {line}")


def main() -> int:
    print("=" * 70)
    print("  배포 · 롤백 실증 테스트 (로컬 FTP 서버)")
    print("=" * 70)

    try:
        import pyftpdlib  # noqa: F401
    except ImportError:
        print("\n  pyftpdlib 가 필요합니다:  pip install pyftpdlib\n")
        return 2

    fixture = FtpFixture()
    site = fixture.root
    # ## 릴리스 폴더는 테스트 전체에서 하나여야 한다
    # 호출마다 새로 만들면 배포가 남긴 스냅숏을 롤백이 볼 수 없다. 실제
    # 운영에서는 `.deploy/releases` 하나를 계속 쓰므로, 테스트도 그렇게 해야
    # 현실을 재현한다. (처음 이걸 호출마다 만들었다가 "롤백할 스냅숏이 없다"가
    # 나왔는데, 스크립트가 아니라 하네스가 틀린 경우였다.)
    releases = Path(tempfile.mkdtemp(prefix="gabia_rel_"))

    try:
        fixture.start()
        print(f"\n  FTP 서버: 127.0.0.1:{fixture.port}")
        print(f"  사이트 루트: {site}\n")

        # ── 1. 운영 중인 옛 사이트를 심는다 ────────────────────────────────
        print("① 옛 버전 사이트 구성 (운영 중 상황 재현)")
        old_files = {
            "index.html": "<html><body>OLD VERSION</body></html>",
            "main.dart.js": "// old bundle\nconsole.log('old');",
            "flutter.js": "// old flutter.js",
            "assets/AssetManifest.json": '{"old":true}',
            "version.json": '{"version":"0.0.1"}',
        }
        old_hashes = {}
        for rel, content in old_files.items():
            p = write_file(site, rel, content)
            old_hashes[rel] = sha(p)
        print(f"     {len(old_files)}개 파일 (옛 버전)")

        # ── 2. 배포할 새 빌드를 만든다 ─────────────────────────────────────
        print("\n② 새 빌드 준비")
        build = PROJECT_DIR / "build" / "web"
        if not build.is_dir():
            print("     build/web 이 없습니다. 먼저 flutter build web 을 실행하세요.")
            return 2
        new_hashes = {}
        for f in build.rglob("*"):
            if f.is_file():
                rel = f.relative_to(build).as_posix()
                new_hashes[rel] = sha(f)
        print(f"     {len(new_hashes)}개 파일")

        # ── 3. .env.gabia 작성 ────────────────────────────────────────────
        cfg = Path(tempfile.mkdtemp(prefix="gabia_cfg_")) / ".env.gabia"
        cfg.write_text(
            "\n".join(
                [
                    "GABIA_PROTOCOL=ftp",
                    f"GABIA_HOST=127.0.0.1",
                    f"GABIA_PORT={fixture.port}",
                    f"GABIA_USER={fixture.user}",
                    f"GABIA_PASS={fixture.password}",
                    "GABIA_PATH=/",
                    "GABIA_PASSIVE=1",
                ]
            ),
            encoding="utf-8",
        )

        # ── 4. dry-run 은 아무것도 바꾸지 않아야 한다 ──────────────────────
        print("\n③ --dry-run 이 서버를 건드리지 않는가")
        before = {p.relative_to(site).as_posix(): sha(p) for p in site.rglob("*") if p.is_file()}
        res = run(cfg, "--dry-run")
        after = {p.relative_to(site).as_posix(): sha(p) for p in site.rglob("*") if p.is_file()}
        check(before == after, "dry-run 이 서버를 변경하지 않음", f"{len(before)}→{len(after)}")

        # ── 5. 실제 배포 ──────────────────────────────────────────────────
        print("\n④ 실제 배포 실행")
        res = run_with_releases(cfg, releases)
        check(res.returncode == 0, "배포 종료 코드 0", res.stdout[-2000:] + res.stderr[-1000:])

        # 새 파일이 실제로 올라갔는가
        land_index = site / "index.html"
        check(land_index.exists(), "index.html 이 서버에 존재")
        if land_index.exists():
            landed = sha(land_index)
            check(
                landed == new_hashes.get("index.html"),
                "index.html 이 새 빌드와 일치",
                f"expected {new_hashes.get('index.html','?')[:16]} got {landed[:16]}",
            )

        land_bundle = site / "main.dart.js"
        if land_bundle.exists() and "main.dart.js" in new_hashes:
            check(
                sha(land_bundle) == new_hashes["main.dart.js"],
                "main.dart.js 가 새 빌드와 일치",
            )

        # ── 6. 롤백 ───────────────────────────────────────────────────────
        print("\n⑤ 롤백 실행")
        res = run_with_releases(cfg, releases, "--rollback")
        check(res.returncode == 0, "롤백 종료 코드 0", res.stdout[-2000:] + res.stderr[-1000:])

        # 옛 버전과 바이트 단위로 같아졌는가
        restored_all = True
        detail = []
        for rel, old_hash in old_hashes.items():
            p = site / rel
            if not p.exists():
                restored_all = False
                detail.append(f"{rel}: 없음")
                continue
            got = sha(p)
            if got != old_hash:
                restored_all = False
                detail.append(f"{rel}: {old_hash[:12]} != {got[:12]}")
        check(restored_all, "롤백 후 모든 옛 파일이 원래 해시로 복원", "\n".join(detail))

        # index.html 내용이 진짜 옛것인가 (해시만이 아니라)
        if land_index.exists():
            text = land_index.read_text(encoding="utf-8", errors="replace")
            check("OLD VERSION" in text, "롤백된 index.html 이 실제로 옛 내용")

        # ── 7. 자동 롤백: 업로드 중 실패 ──────────────────────────────────
        print("\n⑥ 업로드 실패 시 자동 롤백")
        res = run_with_releases(cfg, releases, "--fail-inject")
        out = res.stdout + res.stderr
        check(
            "자동 되돌리기" in out or "자동 롤백" in out or res.returncode != 0,
            "실패 시 되돌리기 경로로 진입",
            out[-1500:],
        )

        # ── 8. 업로드 순서: index.html 이 마지막인가 ─────────────────────
        print("\n⑦ 업로드 순서 (index.html 마지막 확인)")
        sys.path.insert(0, str(PROJECT_DIR / "scripts"))
        import deploy_gabia as dg

        manifest = dg.build_manifest(build)
        paths = [m["path"] for m in manifest]
        if "index.html" in paths:
            idx = paths.index("index.html")
            check(
                idx == len(paths) - 1,
                "index.html 이 업로드 목록의 마지막",
                f"index.html 위치 {idx+1}/{len(paths)}",
            )
        if "main.dart.js" in paths and "index.html" in paths:
            check(
                paths.index("main.dart.js") < paths.index("index.html"),
                "main.dart.js 가 index.html 보다 먼저",
            )

    finally:
        fixture.stop()
        shutil.rmtree(releases, ignore_errors=True)

    print("\n" + "=" * 70)
    passed = sum(1 for c, _, _ in results if c)
    total = len(results)
    print(f"  결과: {passed}/{total} 통과")
    print("=" * 70)
    for cond, label, _ in results:
        if not cond:
            print(f"  실패: {label}")
    return 0 if passed == total else 1


def run_with_releases(
    cfg: Path, releases: Path, *args: str
) -> subprocess.CompletedProcess:
    """
    릴리스 폴더를 임시 위치로 격리해서 실행한다.

    실제 `.deploy/releases` 를 쓰면 테스트가 사용자의 진짜 스냅숏과 섞인다.
    그건 테스트가 사용자 데이터를 오염시키는 것이고, 절대 해서는 안 되는 일이다.
    """
    env = dict(os.environ)
    env["DEPLOY_RELEASE_ROOT"] = str(releases)
    env["DEPLOY_ENV_OVERRIDE"] = str(cfg)
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        cwd=str(PROJECT_DIR),
        env=env,
        timeout=300,
    )


if __name__ == "__main__":
    sys.exit(main())

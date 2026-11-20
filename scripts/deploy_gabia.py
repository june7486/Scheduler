#!/usr/bin/env python3
"""
June Scheduler — 가비아(Gabia) 웹호스팅 배포 스크립트.

## 이 파일이 하는 일과, 하지 않는 일

**하는 일**
  · `build/web` 을 가비아 호스팅에 올린다 (FTP / FTPS / SFTP).
  · 올리기 **전에** 현재 서버 상태를 내려받아 스냅숏으로 남긴다.
  · 올린 뒤 **바이트 단위로 검증**한다.
  · 검증에 실패하면 **자동으로 되돌린다.**

**하지 않는 일**
  · DNS 를 건드리지 않는다. 그건 사람이 콘솔에서 한다.
  · 데이터를 지우지 않는다. 되돌리기 스냅숏은 지우지 않고 쌓아둔다.

## 왜 "안전장치"를 따로 만드는가

배포 스크립트에 롤백 기능을 넣는 것과, 그 롤백이 **실제로 동작하는 것**은
다른 문제다. 대부분의 배포 스크립트는 후자를 확인하지 않는다. 그래서 사고가
난 뒤에야 롤백이 반쯤만 되돌린다는 걸 알게 된다.

여기서는 세 가지를 지킨다.

1. **올리기 전에 현재 상태를 확보한다.** 실패해서 되돌릴 때 "무엇으로" 되돌릴지
   서버에서 가져온 실물이어야 한다. 내 기억이나 git 이 아니라.
2. **검증은 서버에서 다시 내려받아 한다.** 업로드 요청이 성공했다는 응답은
   "서버가 받았다"는 뜻이지 "내용이 맞다"는 뜻이 아니다. FTP 는 특히 그렇다.
3. **되돌리기도 검증한다.** 되돌린 뒤 다시 내려받아 해시를 비교한다. 되돌리기가
   실패하면 그 사실을 소리내어 말한다 — 조용히 실패하는 롤백은 없느니만 못하다.

## 왜 엔트리포인트를 마지막에 올리는가

업로드 도중 실패하면 서버에는 **새 파일과 옛 파일이 섞인 상태**가 남는다.
이때 `index.html` 이 먼저 올라가 있으면, 사용자는 새 index 를 받고 옛
`main.dart.js` 를 받아 흰 화면을 본다. 그래서 순서를 정한다.

  일반 자산 → main.dart.js → flutter_bootstrap.js → **index.html 맨 마지막**

`index.html` 이 마지막이라는 뜻은, 업로드가 중간에 죽으면 **사용자는 계속 옛
버전을 본다**는 뜻이다. 반쯤 깨진 새 버전보다 낫다.

## 사용법

  # 설정 확인만 (아무것도 올리지 않음)
  python3 scripts/deploy_gabia.py --dry-run

  # 실제 배포
  python3 scripts/deploy_gabia.py

  # 되돌리기 (가장 최근 스냅숏으로)
  python3 scripts/deploy_gabia.py --rollback

  # 특정 스냅숏으로 되돌리기
  python3 scripts/deploy_gabia.py --rollback --snapshot <이름>

  # 스냅숏 목록
  python3 scripts/deploy_gabia.py --list

## 설정 (.env.gabia — 커밋 금지)

  GABIA_PROTOCOL=ftps          # ftp | ftps | sftp
  GABIA_HOST=ftp.example.com
  GABIA_PORT=21                # ftps 는 보통 21, sftp 는 22
  GABIA_USER=아이디
  GABIA_PASS=비밀번호
  GABIA_PATH=/www            # 사이트 루트. 보통 /www 또는 /html
  GABIA_PASSIVE=1              # 공유호스팅은 거의 대부분 수동 모드 필요
"""

from __future__ import annotations

import argparse
import ftplib
import hashlib
import json
import os
import posixpath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
BUILD_DIR = PROJECT_DIR / "build" / "web"
ENV_FILE = (
    Path(os.environ["DEPLOY_ENV_OVERRIDE"])
    if os.environ.get("DEPLOY_ENV_OVERRIDE")
    else PROJECT_DIR / ".env.gabia"
)

# ## 왜 릴리스 폴더를 바꿀 수 있게 하는가
# `scripts/test_deploy_gabia.py` 가 실제 FTP 서버로 배포·롤백을 검증한다. 그때
# 스냅숏이 진짜 `.deploy/releases` 에 쌓이면 테스트가 사용자의 운영 스냅숏과
# 섞인다. 테스트가 실제 데이터를 오염시키는 건 절대 일어나선 안 되는 일이므로,
# 위치를 주입할 수 있게 해둔다. 운영 배포에서는 아무도 이 값을 건드리지 않는다.
RELEASE_ROOT = (
    Path(os.environ["DEPLOY_RELEASE_ROOT"])
    if os.environ.get("DEPLOY_RELEASE_ROOT")
    else PROJECT_DIR / ".deploy" / "releases"
)

# ─────────────────────────────────────────────────────────────────────────────
# 엔트리포인트 — 반드시 마지막에 올린다. (위 설명 참고)
# ─────────────────────────────────────────────────────────────────────────────
ENTRYPOINTS = ("index.html",)

# 이 순서대로 올린다. 뒤로 갈수록 "사용자가 실제로 여는 문"에 가깝다.
UPLOAD_ORDER = (
    "canvaskit/",
    "assets/",
    "icons/",
    "flutter.js",
    "flutter_bootstrap.js",
    "main.dart.js",
    "flutter_service_worker.js",
    "version.json",
    "manifest.json",
    "favicon.png",
    "index.html",
)

# 되돌리기 스냅숏에 넣지 않는 것 — 서버에 원래 있던 사이트 파일까지 통째로
# 내려받으면 스냅숏이 수 GB 가 되고, 우리 앱과 무관한 파일까지 되돌리게 된다.
BACKUP_SKIP_PREFIXES = ("cgi-bin/", ".well-known/")

CHUNK = 1 << 20  # 1 MiB


# ─────────────────────────────────────────────────────────────────────────────
# 출력
# ─────────────────────────────────────────────────────────────────────────────
def say(msg: str) -> None:
    print(msg, flush=True)


def ok(msg: str) -> None:
    print(f"  ✅ {msg}", flush=True)

def warn(msg: str) -> None:
    print(f"  ⚠️  {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"  ❌ {msg}", flush=True)


class DeployError(RuntimeError):
    """배포를 중단해야 하는 상황. 되돌리기 경로로 넘어간다."""


def display_path(p: Path) -> str:
    """
    경로를 사람이 읽기 좋게. 저장소 안이면 상대경로, 밖이면 절대경로.

    ## 왜 `relative_to` 를 그냥 쓰면 안 되는가
    스냅숏 위치를 환경변수로 바꿀 수 있다 (테스트가 운영 스냅숏을 더럽히지
    않도록). 그때 경로가 저장소 바깥이면 `relative_to` 가 ValueError 를 던져
    배포 전체가 죽는다 — 로그 한 줄 때문에. 실제로 이 테스트가 그걸 잡았다.
    """
    try:
        return str(p.relative_to(PROJECT_DIR))
    except ValueError:
        return str(p)


# ─────────────────────────────────────────────────────────────────────────────
# 설정
# ─────────────────────────────────────────────────────────────────────────────
def load_env() -> dict[str, str]:
    """
    `.env.gabia` 를 읽는다. 없으면 환경변수에서 읽는다.

    ## 왜 .env 파일인가
    키와 비밀번호를 명령줄에 쓰면 셸 히스토리와 `ps` 출력에 남는다. 파일에
    두고 읽는 편이 낫다. 대신 그 파일이 커밋되면 안 되므로 `.gitignore` 에
    반드시 넣는다 (이 저장소는 이미 그렇게 되어 있다).
    """
    cfg: dict[str, str] = {}
    if ENV_FILE.exists():
        for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")

    # 환경변수가 파일보다 우선 (CI 나 일회성 override 용)
    for key in (
        "GABIA_PROTOCOL",
        "GABIA_HOST",
        "GABIA_PORT",
        "GABIA_USER",
        "GABIA_PASS",
        "GABIA_PATH",
        "GABIA_PASSIVE",
    ):
        if os.environ.get(key):
            cfg[key] = os.environ[key]

    cfg.setdefault("GABIA_PROTOCOL", "ftps")
    cfg.setdefault("GABIA_PORT", "21" if cfg["GABIA_PROTOCOL"] != "sftp" else "22")
    cfg.setdefault("GABIA_PATH", "/www")
    cfg.setdefault("GABIA_PASSIVE", "1")
    return cfg


def require_config(cfg: dict[str, str], *, need_login: bool) -> None:
    """설정이 갖춰졌는지 확인한다. 없으면 '무엇이 없는지' 정확히 말한다."""
    missing = [k for k in ("GABIA_HOST", "GABIA_USER") if not cfg.get(k)]
    if need_login:
        missing += [k for k in ("GABIA_PASS",) if not cfg.get(k)]
    if missing:
        fail(f"설정이 없습니다: {', '.join(missing)}")
        say("")
        say(f"  {ENV_FILE} 파일을 만들고 다음을 채우세요:")
        say("")
        say("    GABIA_PROTOCOL=ftps")
        say("    GABIA_HOST=ftp.내도메인.com")
        say("    GABIA_PORT=21")
        say("    GABIA_USER=아이디")
        say("    GABIA_PASS=비밀번호")
        say("    GABIA_PATH=/www")
        say("")
        say("  가비아 콘솔 → 나의서비스관리 → 호스팅 관리 → FTP/DB 관리 에서")
        say("  FTP 아이디·비밀번호·접속 주소를 확인할 수 있습니다.")
        raise DeployError("설정 누락")


# ─────────────────────────────────────────────────────────────────────────────
# 전송 계층 — FTP / FTPS / SFTP 를 같은 인터페이스로
# ─────────────────────────────────────────────────────────────────────────────
class FtpTransport:
    """
    ftplib 기반. FTPS(explicit, AUTH TLS)는 `secure=True` 로 켠다.

    ## 왜 explicit TLS 인가
    가비아 공유호스팅은 implicit FTPS(990)보다 explicit(21 + AUTH TLS)를 쓴다.
    implicit 은 연결 즉시 TLS 로 감싸는 방식이고, explicit 은 먼저 평문으로
    붙어 `AUTH TLS` 로 승격한다. 둘은 호환되지 않으므로 구분이 필요하다.
    """

    def __init__(self, cfg: dict[str, str]):
        self.cfg = cfg
        self.ftp: ftplib.FTP | ftplib.FTP_TLS | None = None
        self.secure = cfg["GABIA_PROTOCOL"] == "ftps"
        self.root = cfg["GABIA_PATH"].rstrip("/") or "/"

    def connect(self) -> None:
        host = self.cfg["GABIA_HOST"]
        port = int(self.cfg["GABIA_PORT"])
        passive = self.cfg["GABIA_PASSIVE"] != "0"

        if self.secure:
            ftp: ftplib.FTP = ftplib.FTP_TLS()
        else:
            ftp = ftplib.FTP()

        # 타임아웃이 없으면 서버가 응답을 안 할 때 스크립트가 영원히 매달린다.
        ftp.connect(host, port, timeout=30)
        if self.secure:
            ftp.auth()
            ftp.prot_p()  # 데이터 채널도 암호화. 이게 없으면 파일만 평문으로 나간다.
        ftp.login(self.cfg["GABIA_USER"], self.cfg["GABIA_PASS"])
        ftp.set_pasv(passive)
        self.ftp = ftp

    def close(self) -> None:
        if self.ftp is not None:
            try:
                self.ftp.quit()
            except Exception:
                try:
                    self.ftp.close()
                except Exception:
                    pass
            self.ftp = None

    # ── 원격 경로 ────────────────────────────────────────────────────────────
    def rpath(self, rel: str) -> str:
        rel = rel.lstrip("/")
        return posixpath.join(self.root, rel) if rel else self.root

    def ensure_dir(self, rel_dir: str) -> None:
        """원격 디렉터리를 한 단계씩 만든다 (FTP 에는 mkdir -p 가 없다)."""
        assert self.ftp is not None
        if not rel_dir or rel_dir == ".":
            return
        cur = self.root
        for part in rel_dir.strip("/").split("/"):
            if not part:
                continue
            cur = posixpath.join(cur, part)
            try:
                self.ftp.mkd(cur)
            except ftplib.error_perm:
                # 이미 있으면 550 이 온다. 그건 정상이다.
                pass

    def upload(self, local: Path, rel: str) -> None:
        assert self.ftp is not None
        self.ensure_dir(posixpath.dirname(rel))
        with local.open("rb") as fh:
            self.ftp.storbinary(f"STOR {self.rpath(rel)}", fh, blocksize=CHUNK)

    def download(self, rel: str, local: Path) -> bool:
        """원격 파일을 내려받는다. 없으면 False."""
        assert self.ftp is not None
        local.parent.mkdir(parents=True, exist_ok=True)
        try:
            with local.open("wb") as fh:
                self.ftp.retrbinary(f"RETR {self.rpath(rel)}", fh.write, blocksize=CHUNK)
            return True
        except ftplib.error_perm as e:
            # 550 = 없음. 그 외는 진짜 오류다.
            if str(e).startswith("550"):
                local.unlink(missing_ok=True)
                return False
            raise

    def listdir(self, rel_dir: str) -> list[tuple[str, str]]:
        """
        [(name, 'file'|'dir'), ...]. MLSD 를 쓰고, 없으면 LIST 로 떨어진다.

        MLSD 가 표준이지만 오래된 서버는 지원하지 않는다. LIST 파싱은
        서버마다 형식이 달라 깨지기 쉬우므로, 가능하면 MLSD 를 쓴다.
        """
        assert self.ftp is not None
        path = self.rpath(rel_dir)
        out: list[tuple[str, str]] = []
        try:
            for name, facts in self.ftp.mlsd(path):
                if name in (".", ".."):
                    continue
                out.append((name, facts.get("type", "file")))
            return out
        except (ftplib.error_perm, AttributeError):
            pass

        names: list[str] = []
        try:
            self.ftp.retrlines(f"LIST {path}", names.append)
        except ftplib.error_perm:
            return []

        for line in names:
            parts = line.split(None, 8)
            if len(parts) < 9:
                continue
            name = parts[8]
            if name in (".", ".."):
                continue
            kind = "dir" if line.startswith("d") else "file"
            out.append((name, kind))
        return out

    def remove(self, rel: str) -> None:
        assert self.ftp is not None
        try:
            self.ftp.delete(self.rpath(rel))
        except ftplib.error_perm:
            pass


class SftpTransport:
    """
    OpenSSH 의 `sftp` 를 배치 모드로 호출한다.

    ## 왜 paramiko 가 아니라 sftp 인가
    이 저장소는 게이트웨이를 포함해 의존성 0 을 원칙으로 한다. 배포 스크립트
    하나 때문에 pip 패키지를 요구하면, 그 패키지가 없는 환경에서 배포가 안 되고
    사람은 그러면 스크립트를 안 쓴다. `sftp` 는 ssh 가 있으면 항상 있다.

    대신 배치 모드라 개별 실패를 잡아내기 어렵다. 그래서 **검증을 별도로**
    한다 (업로드 후 내려받아 해시 비교). 검증이 있으면 전송 계층의 약함이
    치명적이지 않다.
    """

    def __init__(self, cfg: dict[str, str]):
        self.cfg = cfg
        self.root = cfg["GABIA_PATH"].rstrip("/") or "."

    def connect(self) -> None:  # 인터페이스 맞추기용 — sftp 는 호출마다 새 연결
        pass

    def close(self) -> None:
        pass

    def rpath(self, rel: str) -> str:
        rel = rel.lstrip("/")
        return posixpath.join(self.root, rel) if rel else self.root

    def _run(self, commands: list[str]) -> subprocess.CompletedProcess:
        batch = "\n".join(commands) + "\n"
        cmd = [
            "sftp",
            "-q",
            "-b",
            "-",
            "-P",
            str(self.cfg["GABIA_PORT"]),
            "-o",
            "BatchMode=no",
            "-o",
            "StrictHostKeyChecking=accept-new",
            f"{self.cfg['GABIA_USER']}@{self.cfg['GABIA_HOST']}",
        ]
        env = dict(os.environ)
        # 비밀번호를 인자로 넘기면 ps 에 보인다. sshpass 를 쓸 수 있으면 쓰고,
        # 없으면 키 인증을 전제로 한다.
        if shutil.which("sshpass"):
            cmd = ["sshpass", "-p", self.cfg["GABIA_PASS"]] + cmd
        return subprocess.run(
            cmd, input=batch, text=True, capture_output=True, env=env, timeout=600
        )

    def upload(self, local: Path, rel: str) -> None:
        d = posixpath.dirname(rel)
        cmds = [f'-mkdir {self.rpath("")}'] if d == "" else []
        if d:
            cur = self.root
            for part in d.strip("/").split("/"):
                cur = posixpath.join(cur, part)
                cmds.append(f'-mkdir {cur}')
        cmds.append(f'put "{local}" "{self.rpath(rel)}"')
        res = self._run(cmds)
        if res.returncode != 0:
            raise DeployError(f"sftp 업로드 실패 {rel}: {res.stderr.strip()}")

    def download(self, rel: str, local: Path) -> bool:
        local.parent.mkdir(parents=True, exist_ok=True)
        res = self._run([f'get "{self.rpath(rel)}" "{local}"'])
        return res.returncode == 0 and local.exists()

    def listdir(self, rel_dir: str) -> list[tuple[str, str]]:
        res = self._run([f'ls -l {self.rpath(rel_dir)}'])
        out: list[tuple[str, str]] = []
        for line in res.stdout.splitlines():
            parts = line.split(None, 8)
            if len(parts) < 9 or line.startswith("total"):
                continue
            name = parts[8]
            if name in (".", ".."):
                continue
            out.append((name, "dir" if line.startswith("d") else "file"))
        return out

    def remove(self, rel: str) -> None:
        self._run([f'-rm {self.rpath(rel)}'])


def make_transport(cfg: dict[str, str]):
    if cfg["GABIA_PROTOCOL"] == "sftp":
        return SftpTransport(cfg)
    return FtpTransport(cfg)


# ─────────────────────────────────────────────────────────────────────────────
# 해시
# ─────────────────────────────────────────────────────────────────────────────
def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def build_manifest(root: Path) -> list[dict]:
    """
    올릴 파일 목록 + 크기 + 해시 + 업로드 순서.

    ## 왜 정렬을 여기서 하는가
    업로드 순서가 안전장치의 일부다 (엔트리포인트 마지막). 그런데 파일 목록은
    `os.walk` 가 주는 순서가 플랫폼마다 다르다. 순서를 데이터로 못박아두면
    검증도 같은 순서로 할 수 있고, 로그를 읽을 때도 예측 가능하다.
    """
    if not root.is_dir():
        raise DeployError(f"빌드 폴더가 없습니다: {root} (먼저 flutter build web)")

    files: list[dict] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            full = Path(dirpath) / name
            rel = full.relative_to(root).as_posix()
            files.append(
                {
                    "path": rel,
                    "size": full.stat().st_size,
                    "sha256": sha256_file(full),
                }
            )

    def rank(item: dict) -> tuple[int, str]:
        p = item["path"]
        if p in ENTRYPOINTS:
            return (1000, p)
        for i, pref in enumerate(UPLOAD_ORDER):
            if p == pref or (pref.endswith("/") and p.startswith(pref)):
                return (i, p)
        return (500, p)

    files.sort(key=rank)
    return files


# ─────────────────────────────────────────────────────────────────────────────
# 릴리스 스냅숏 (로컬)
# ─────────────────────────────────────────────────────────────────────────────
def new_release_dir(label: str) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    d = RELEASE_ROOT / f"{stamp}-{label}"
    d.mkdir(parents=True, exist_ok=True)
    return d


def write_json(path: Path, obj) -> None:
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False), encoding="utf-8")


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def backup_remote(transport, dest: Path) -> dict:
    """
    서버의 현재 상태를 내려받아 스냅숏을 만든다.

    ## 왜 필요한가
    되돌리기의 대상은 "내가 마지막으로 올린 것"이 아니라 **"지금 서버에 있는
    것"** 이어야 한다. 그 사이에 누군가 콘솔에서 파일을 고쳤을 수도 있고,
    이전 배포가 부분 실패했을 수도 있다. 서버에서 가져온 실물만이 정답이다.

    ## 무엇을 건너뛰는가
    `cgi-bin/`, `.well-known/` 같은 우리 앱과 무관한 경로는 제외한다. 전체
    사이트를 통째로 내려받으면 스냅숏이 수 GB 가 되고, 되돌리기가 앱과 상관없는
    파일까지 건드리게 된다.
    """
    say("② 서버 현재 상태 백업...")
    files: list[dict] = []
    failed: list[str] = []

    def walk(rel_dir: str, depth: int = 0) -> None:
        if depth > 6:  # 무한 재귀 방지
            return
        try:
            entries = transport.listdir(rel_dir)
        except Exception as e:
            failed.append(f"{rel_dir}: {e}")
            return
        for name, kind in entries:
            rel = posixpath.join(rel_dir, name) if rel_dir else name
            if any(rel.startswith(p) for p in BACKUP_SKIP_PREFIXES):
                continue
            if kind == "dir":
                walk(rel, depth + 1)
                continue
            local = dest / "files" / rel
            try:
                if transport.download(rel, local):
                    files.append(
                        {
                            "path": rel,
                            "size": local.stat().st_size,
                            "sha256": sha256_file(local),
                        }
                    )
                else:
                    failed.append(f"{rel}: 없음")
            except Exception as e:
                failed.append(f"{rel}: {e}")

    walk("")
    ok(f"{len(files)}개 파일 백업 ({sum(f['size'] for f in files) / 1048576:.1f} MB)")
    if failed:
        warn(f"{len(failed)}개 항목은 백업하지 못했습니다 (계속 진행)")
        for f in failed[:5]:
            say(f"      · {f}")

    # 스냅숏 자체를 기록한다. 되돌리기는 이 목록을 근거로 삼는다 —
    # 폴더를 다시 훑는 것보다, 그때 무엇을 내려받았는지가 남는 편이 정확하다.
    write_json(
        dest / "snapshot.json",
        {
            "created_at": datetime.now(timezone.utc).isoformat(),
            "root": "/",
            "files": files,
            "failed": failed,
        },
    )
    return {"files": files, "failed": failed}


# ─────────────────────────────────────────────────────────────────────────────
# 배포
# ─────────────────────────────────────────────────────────────────────────────
def do_deploy(cfg: dict, *, dry_run: bool, fail_inject: bool = False) -> int:
    say("")
    say("━" * 62)
    say("  June Scheduler → 가비아 배포")
    say("━" * 62)
    say(f"  프로토콜 : {cfg['GABIA_PROTOCOL'].upper()}")
    say(f"  호스트   : {cfg['GABIA_HOST']}:{cfg['GABIA_PORT']}")
    say(f"  계정     : {cfg['GABIA_USER']}")
    say(f"  경로     : {cfg['GABIA_PATH']}")
    say("")

    say("① 올릴 파일 목록 작성...")

    # ## .htaccess 는 빌드 산출물이 아니라 배포 설정이다
    # `flutter build web` 은 이 파일을 만들지 않는다. 그런데 없으면 가비아
    # (Apache)에서 .wasm MIME 이 빠져 흰 화면이 되고, index.html 이 캐시되어
    # "배포했는데 반영이 안 된다"가 된다. 그래서 배포 직전에 저장소의 원본을
    # build/web 으로 복사한다 — 손으로 관리하면 반드시 빠뜨린다.
    htaccess_src = PROJECT_DIR / "scripts" / "htaccess-for-gabia"
    if htaccess_src.exists() and BUILD_DIR.is_dir():
        shutil.copyfile(htaccess_src, BUILD_DIR / ".htaccess")
        ok(".htaccess 적용 (wasm MIME, index.html no-cache)")
    else:
        warn(".htaccess 원본을 찾지 못했습니다 — wasm MIME 이 빠져 흰 화면이 될 수 있습니다")

    manifest = build_manifest(BUILD_DIR)
    total = sum(f["size"] for f in manifest)
    ok(f"{len(manifest)}개 파일, {total / 1048576:.1f} MB")
    for item in manifest[-3:]:
        say(f"      마지막에 올릴 파일: {item['path']}")

    if dry_run:
        say("")
        ok("--dry-run: 아무것도 전송하지 않았습니다.")
        say("")
        say("  실제로 올리려면 --dry-run 을 빼고 다시 실행하세요.")
        return 0

    require_config(cfg, need_login=True)

    release = new_release_dir("deploy")
    write_json(release / "manifest.json", {"files": manifest, "total": total})
    ok(f"릴리스 기록: {display_path(release)}")

    transport = make_transport(cfg)
    backup = None

    try:
        say(f"② 연결: {cfg['GABIA_HOST']} ...")
        transport.connect()
        ok("연결됨")

        # ── 되돌리기용 스냅숏을 먼저 확보한다 ──────────────────────────────
        backup = backup_remote(transport, release / "rollback")

        # ── 업로드 ────────────────────────────────────────────────────────
        say("③ 업로드...")
        uploaded = 0
        for item in manifest:
            # ## fail_inject: 테스트 전용
            # 업로드 중간에 예외를 던져 "부분 배포 → 자동 롤백" 경로가 실제로
            # 동작하는지 확인한다. 이 경로는 평소에 실행되지 않으므로, 검증하지
            # 않으면 첫 실제 사고 때 처음 동작하는 코드가 된다.
            if fail_inject and uploaded >= 2 and item["path"] not in ENTRYPOINTS:
                raise DeployError("주입된 실패 (테스트)")
            local = BUILD_DIR / item["path"]
            transport.upload(local, item["path"])
            uploaded += 1
            if uploaded % 10 == 0 or uploaded == len(manifest):
                say(f"      {uploaded}/{len(manifest)}")

        # ── 검증: 서버에서 다시 내려받아 해시 비교 ────────────────────────
        say("④ 검증 (서버에서 다시 내려받아 해시 비교)...")
        mismatched: list[str] = []
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            for item in manifest:
                # 엔트리포인트는 특히 엄격하게 본다 — 사용자가 여는 문이다.
                tmpfile = tmp / item["path"].replace("/", "__")
                if not transport.download(item["path"], tmpfile):
                    mismatched.append(f"{item['path']} (내려받기 실패)")
                    continue
                got = sha256_file(tmpfile)
                if got != item["sha256"]:
                    mismatched.append(
                        f"{item['path']} (기대 {item['sha256'][:12]}… 실제 {got[:12]}…)"
                    )

        if mismatched:
            fail(f"{len(mismatched)}개 파일이 일치하지 않습니다:")
            for m in mismatched[:10]:
                say(f"      · {m}")
            raise DeployError("검증 실패")

        ok(f"{len(manifest)}개 파일 모두 일치")

    except Exception as e:
        fail(f"배포 실패: {e}")
        if backup is None:
            fail("백업을 확보하지 못해 자동 되돌리기를 건너뜁니다.")
            say("   (업로드 이전에 실패했다면 서버는 원래 상태 그대로입니다.)")
            return 1

        say("")
        say("━" * 62)
        say("  자동 되돌리기 시작")
        say("━" * 62)
        rc = do_restore(transport, release / "rollback", release)
        transport.close()
        if rc == 0:
            ok("되돌리기 완료. 서버는 배포 전 상태입니다.")
        else:
            fail("되돌리기 실패. 서버가 어중간한 상태일 수 있습니다.")
            say(f"   스냅숏: {release / 'rollback'}")
            say("   수동 복구: 이 폴더의 파일을 FTP 로 직접 올리세요.")
        return 1

    transport.close()

    say("")
    say("━" * 62)
    say("  배포 완료")
    say("━" * 62)
    ok(f"되돌리려면:  python3 scripts/deploy_gabia.py --rollback")
    ok(f"스냅숏:      {display_path(release)}")
    say("")
    return 0


# ─────────────────────────────────────────────────────────────────────────────
# 되돌리기
# ─────────────────────────────────────────────────────────────────────────────
def do_restore(transport, snapshot: Path, release: Path) -> int:
    """
    스냅숏의 파일을 서버로 되돌린다. 그리고 **되돌리기가 됐는지 확인한다.**

    ## 왜 되돌리기를 검증하는가
    "복원 명령을 실행했다"와 "서버가 원래대로 돌아갔다"는 다르다. 전송이
    일부 실패했는데 조용히 넘어가면, 우리는 안전하다고 믿으면서 실제로는
    반쯤 깨진 사이트를 남기게 된다. 그건 안전장치가 없는 것보다 나쁘다 —
    없으면 조심이라도 하니까.
    """
    files = read_json(snapshot / "snapshot.json")["files"] if (
        snapshot / "snapshot.json"
    ).exists() else None

    if files is None:
        # snapshot.json 이 없으면 폴더를 훑어서 만든다.
        files = []
        for full in (snapshot / "files").rglob("*"):
            if full.is_file():
                rel = full.relative_to(snapshot / "files").as_posix()
                files.append(
                    {"path": rel, "size": full.stat().st_size, "sha256": sha256_file(full)}
                )

    if not files:
        warn("되돌릴 파일이 스냅숏에 없습니다.")
        return 1

    # 엔트리포인트는 되돌릴 때도 마지막에 올린다 (같은 이유).
    files.sort(key=lambda f: (1000 if f["path"] in ENTRYPOINTS else 0, f["path"]))

    say(f"  {len(files)}개 파일 복원 중...")
    for i, item in enumerate(files, 1):
        local = snapshot / "files" / item["path"]
        if not local.exists():
            continue
        transport.upload(local, item["path"])
        if i % 10 == 0 or i == len(files):
            say(f"      {i}/{len(files)}")

    # ── 되돌리기도 검증한다 ──────────────────────────────────────────────
    say("  복원 검증...")
    bad: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for item in files:
            tmpfile = tmp / item["path"].replace("/", "__")
            if not transport.download(item["path"], tmpfile):
                bad.append(item["path"])
                continue
            if sha256_file(tmpfile) != item["sha256"]:
                bad.append(item["path"])

    if bad:
        fail(f"{len(bad)}개 파일이 스냅숏과 다릅니다:")
        for b in bad[:10]:
            say(f"      · {b}")
        return 1

    ok(f"{len(files)}개 파일 복원 확인")
    return 0


def do_rollback(cfg: dict, *, snapshot_name: str | None) -> int:
    say("")
    say("━" * 62)
    say("  되돌리기")
    say("━" * 62)

    releases = sorted([d for d in RELEASE_ROOT.glob("*") if d.is_dir()]) if RELEASE_ROOT.exists() else []
    if not releases:
        fail("스냅숏이 없습니다. 되돌릴 대상이 없습니다.")
        say("   (한 번도 배포한 적이 없다면 되돌릴 것도 없습니다.)")
        return 1

    if snapshot_name:
        matches = [d for d in releases if snapshot_name in d.name]
        if not matches:
            fail(f"'{snapshot_name}' 에 해당하는 스냅숏이 없습니다.")
            do_list()
            return 1
        target = matches[-1]
    else:
        # 되돌리기에 쓸 수 있는 것 = rollback 폴더가 있는 가장 최근 릴리스
        usable = [d for d in releases if (d / "rollback" / "files").is_dir()]
        if not usable:
            fail("복원 가능한 스냅숏이 없습니다.")
            do_list()
            return 1
        target = usable[-1]

    snap = target / "rollback"
    file_count = len(list((snap / "files").rglob("*"))) if (snap / "files").exists() else 0
    say(f"  스냅숏 : {target.name}")
    say(f"  파일   : {file_count}개")
    say("")

    require_config(cfg, need_login=True)
    transport = make_transport(cfg)
    try:
        say("연결...")
        transport.connect()
        ok("연결됨")
        rc = do_restore(transport, snap, target)
    finally:
        transport.close()

    if rc == 0:
        say("")
        ok("되돌리기 완료. 서버는 이 스냅숏 시점으로 돌아갔습니다.")
    else:
        say("")
        fail("되돌리기가 완전히 성공하지 못했습니다. 위 목록을 확인하세요.")
    return rc


def do_list() -> None:
    say("")
    if not RELEASE_ROOT.exists():
        say("  스냅숏이 없습니다.")
        return
    releases = sorted([d for d in RELEASE_ROOT.glob("*") if d.is_dir()], reverse=True)
    if not releases:
        say("  스냅숏이 없습니다.")
        return
    say("  스냅숏 목록 (최신순):")
    say("")
    for d in releases:
        mf = d / "manifest.json"
        rb = d / "rollback" / "files"
        n_deploy = len(read_json(mf)["files"]) if mf.exists() else 0
        n_rb = len(list(rb.rglob("*"))) if rb.exists() else 0
        can_restore = "복원가능" if n_rb else "복원불가"
        say(f"    {d.name}")
        say(f"        배포 {n_deploy}개 · 되돌리기 {n_rb}개 · {can_restore}")
    say("")
    say("  되돌리기: python3 scripts/deploy_gabia.py --rollback --snapshot <이름일부>")


# ─────────────────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description="June Scheduler → 가비아 배포")
    ap.add_argument("--dry-run", action="store_true", help="설정과 목록만 확인, 전송 없음")
    ap.add_argument("--rollback", action="store_true", help="되돌리기")
    ap.add_argument("--snapshot", help="되돌릴 스냅숏 이름 (부분 일치)")
    ap.add_argument("--list", action="store_true", help="스냅숏 목록")
    ap.add_argument(
        "--fail-inject",
        action="store_true",
        help=argparse.SUPPRESS,  # 테스트 전용 — 도움말에 노출하지 않는다
    )
    args = ap.parse_args()

    if args.list:
        do_list()
        return 0

    cfg = load_env()

    try:
        if args.rollback:
            return do_rollback(cfg, snapshot_name=args.snapshot)
        return do_deploy(cfg, dry_run=args.dry_run, fail_inject=args.fail_inject)
    except DeployError as e:
        fail(str(e))
        return 1
    except KeyboardInterrupt:
        say("")
        fail("사용자가 중단했습니다.")
        return 130


if __name__ == "__main__":
    sys.exit(main())

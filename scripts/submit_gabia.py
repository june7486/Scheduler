#!/usr/bin/env python3
"""가비아용 제출 — scheduler-gabia 비공개 저장소로 릴리스를 올립니다.

## 이 도구가 지키는 것

**1. 덮어쓰지 않습니다.**
릴리스마다 고유한 ID(`rel-YYYYMMDD-HHMMSS-<sha7>`)를 만들고, 그 이름의
디렉터리에만 씁니다. 같은 이름이 이미 있으면 **멈춥니다.** 강제 푸시는
`--force` 를 줘도 하지 않습니다 — 그 옵션 자체를 만들지 않았습니다.

**2. 검사가 통과해야만 올립니다.**
  · 비밀 누출 검사 (번들 + Git 이력 + 작업 트리)
  · 빌드 산출물 존재
  · 테스트 결과 파일 존재 (선택이지만 경고)
  · 저장소 접근 권한 확인

하나라도 실패하면 업로드하지 않습니다. "일단 올리고 나중에 고치자"는
이 도구에 없습니다. 한 번 올라간 비밀은 회수할 수 없으니까요.

**3. 해시를 별도 매니페스트에 남깁니다.**
전송한 모든 파일의 SHA-256 과 크기를 `manifest.json` 에 적습니다.
받는 쪽(가비아 수신기)이 이걸로 검증합니다. 매니페스트 자체의 해시도
따로 계산해 보고하므로, 매니페스트가 변조되면 드러납니다.

**4. 스스로 설치하거나 실행하지 않습니다.**
이 도구는 파일을 올리고 보고할 뿐입니다. 가비아 서버에 접속하지 않고,
systemd 를 건드리지 않고, 앱을 재시작하지 않습니다. 그건 별도 절차입니다.

## 사용법

    python3 scripts/submit_gabia.py --check          # 검사만, 업로드 안 함
    python3 scripts/submit_gabia.py --submit         # 검사 후 업로드
    python3 scripts/submit_gabia.py --list           # 기존 릴리스 목록
    python3 scripts/submit_gabia.py --dry-run        # 무엇을 올릴지 출력만

## 종료 코드

    0  성공 (업로드 완료 또는 --check 통과)
    1  검사 실패 — 업로드하지 않음
    2  환경 문제 (빌드 없음, 저장소 접근 불가 등)
    3  중복 릴리스 ID
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
BUILD_DIR = PROJECT_DIR / "build" / "web"

# ---------------------------------------------------------------------------
# 설정
# ---------------------------------------------------------------------------
# ## 왜 저장소 이름을 인자로 받지 않는가
# 사용자가 "가비아용 제출"이라고만 하면 이 값이 쓰입니다. 매번 인자로 받으면
# 오타 한 번에 엉뚱한 저장소로 올라갑니다. 이름은 여기 고정합니다.
REPO_OWNER = "june7486"
REPO_NAME = "scheduler-gabia"
REPO_URL = f"https://github.com/{REPO_OWNER}/{REPO_NAME}.git"

SUBMIT_BRANCH = "release/gabia"

# 릴리스는 이 아래에 쌓입니다. 브랜치를 새로 만들지 않고 디렉터리로 나눕니다 —
# 브랜치를 릴리스마다 만들면 수십 개가 쌓여 관리가 안 됩니다.
RELEASE_ROOT = "releases"

# ## 전송에서 빼는 것
# .env, 키, DB 덤프, 개인 일정. test-workspace 의 가상 일정도 뺍니다 —
# 검증용 데이터지만 실제 사용자 데이터와 섞이면 나중에 구분이 안 됩니다.
EXCLUDE_PATTERNS = (
    r"(^|/)\.env$",
    r"(^|/)\.env\.gabia$",
    r"(^|/)\.env\.sync$",
    r"(^|/)\.sync_key$",
    r"(^|/)data/",
    r"(^|/)node_modules/",
    r"(^|/)\.dart_tool/",
    r"(^|/)\.git/",
    r"(^|/)__pycache__/",
    r"\.log$",
    r"\.jks$",
    r"(^|/)key\.properties$",
    r"(^|/)google-services\.json$",
    r"(^|/)test-workspace/",
)

# ## 전송에 반드시 들어가야 하는 것
REQUIRED_SOURCE = (
    "pubspec.yaml",
    "pubspec.lock",
    "lib/main.dart",
    "lib/services/store.dart",
)
REQUIRED_BUILD = (
    "index.html",
    "main.dart.js",
    "flutter_bootstrap.js",
    "version.json",
)


def say(msg: str = "") -> None:
    print(msg)


def ok(msg: str) -> None:
    print(f"  \033[32m✅\033[0m {msg}")


def warn(msg: str) -> None:
    print(f"  \033[33m⚠️ \033[0m {msg}")


def bad(msg: str) -> None:
    print(f"  \033[31m❌\033[0m {msg}")


def hdr(msg: str) -> None:
    print(f"\n\033[1m{msg}\033[0m")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args: str, cwd: Path | None = None) -> tuple[int, str]:
    """git 명령을 실행하고 (종료코드, 출력) 을 돌려줍니다."""
    try:
        r = subprocess.run(
            ["git", *args],
            cwd=str(cwd or PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=120,
        )
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return 1, str(e)


def full_sha() -> str:
    code, out = git("rev-parse", "HEAD")
    return out.strip() if code == 0 else ""


def short_sha() -> str:
    code, out = git("rev-parse", "--short=7", "HEAD")
    return out.strip() if code == 0 else "unknown"


def git_dirty_count() -> int:
    code, out = git("status", "--porcelain")
    if code != 0:
        return -1
    return len([l for l in out.splitlines() if l.strip()])


# ===========================================================================
# 검사
# ===========================================================================
class Report:
    """검사 결과를 모읍니다. 실패가 하나라도 있으면 업로드하지 않습니다."""

    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []

    def fail(self, msg: str) -> None:
        self.failures.append(msg)

    def warnmsg(self, msg: str) -> None:
        self.warnings.append(msg)

    @property
    def passed(self) -> bool:
        return not self.failures


def check_versions(rep: Report) -> dict:
    """pubspec 에서 SDK 제약과 앱 버전을 읽습니다."""
    hdr("① 버전 — pubspec.yaml 에서 직접")
    info: dict = {}

    pubspec = PROJECT_DIR / "pubspec.yaml"
    if not pubspec.exists():
        rep.fail("pubspec.yaml 없음")
        bad("pubspec.yaml 없음")
        return info

    text = pubspec.read_text(encoding="utf-8")
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("environment:"):
            continue
        if s.startswith("sdk:") and "sdk_version" not in info:
            info["sdk_version"] = s.split(":", 1)[1].strip()
        if s.startswith("version:"):
            info["app_version"] = s.split(":", 1)[1].strip()
        if s.startswith("name:"):
            info["package"] = s.split(":", 1)[1].strip()

    ok(f"패키지: {info.get('package', '?')}")
    ok(f"앱 버전: {info.get('app_version', '?')}")
    ok(f"Dart SDK 제약: {info.get('sdk_version', '?')}")

    # ## Flutter 버전을 pubspec 에서 알 수 없습니다
    # pubspec 에는 Dart SDK 제약만 있습니다. Flutter 버전은 빌드 환경이
    # 정하므로, 그 사실을 숨기지 않고 여기 적습니다.
    warn("Flutter 버전은 pubspec 에 없습니다 — 빌드 환경이 정합니다 (아래 빌드 기록 참조)")

    return info


def check_build(rep: Report) -> dict:
    """빌드 산출물이 온전한가."""
    hdr("② 빌드 산출물 — build/web")
    info: dict = {}

    if not BUILD_DIR.exists():
        rep.fail("build/web 없음 — flutter build web 을 먼저 실행하세요")
        bad("build/web 없음")
        return info

    for name in REQUIRED_BUILD:
        p = BUILD_DIR / name
        if p.exists():
            ok(f"{name} ({p.stat().st_size:,}B)")
        else:
            rep.fail(f"build/web/{name} 없음")
            bad(f"{name} 없음")

    js = BUILD_DIR / "main.dart.js"
    if js.exists():
        info["main_js_sha256"] = sha256_file(js)
        info["main_js_size"] = js.stat().st_size
        ok(f"main.dart.js sha256 {info['main_js_sha256'][:16]}…")

    wasm = sorted(BUILD_DIR.rglob("*.wasm"))
    if wasm:
        total = sum(p.stat().st_size for p in wasm)
        ok(f"wasm {len(wasm)}개, {total / 1048576:.1f}MB")
        info["wasm_count"] = len(wasm)
    else:
        rep.fail("wasm 없음 — CanvasKit 이 뜨지 않아 흰 화면이 됩니다")
        bad("wasm 없음")

    return info


def check_secrets(rep: Report) -> None:
    """번들·작업트리·Git 이력에 비밀이 있는가."""
    hdr("③ 비밀 누출 검사")

    # (a) 번들 검사 — 기존 도구를 그대로 부릅니다
    scanner = PROJECT_DIR / "scripts" / "check_bundle_secrets.py"
    if scanner.exists():
        r = subprocess.run(
            [sys.executable, str(scanner), "--strict"],
            cwd=str(PROJECT_DIR),
            capture_output=True,
            text=True,
            timeout=120,
        )
        if r.returncode == 0:
            ok("번들 검사 통과")
        else:
            rep.fail("번들에 주소·키가 포함되어 있습니다")
            bad("번들 검사 실패")
            for line in (r.stdout or "")[-800:].splitlines():
                if "발견" in line or "값" in line:
                    print(f"     {line.strip()}")
    else:
        rep.warnmsg("scripts/check_bundle_secrets.py 없음 — 번들 검사를 건너뜀")
        warn("번들 검사 스크립트 없음")

    # (b) 작업 트리에 위험 파일이 있는가
    danger = (
        ".env",
        ".env.gabia",
        ".env.sync",
        ".sync_key",
        "key.properties",
        "google-services.json",
    )
    found = []
    for name in danger:
        if (PROJECT_DIR / name).exists():
            found.append(name)
    if found:
        # 존재한다고 실패는 아닙니다 — 전송에서 제외하면 됩니다.
        # 다만 추적 중이면 실패입니다.
        code, out = git("ls-files", *found)
        tracked = [l for l in out.splitlines() if l.strip()]
        if tracked:
            rep.fail(f"위험 파일이 git 에 추적되고 있습니다: {', '.join(tracked)}")
            bad(f"추적 중: {', '.join(tracked)}")
        else:
            ok(f"위험 파일 {len(found)}개 있으나 추적되지 않음 → 전송에서 제외")
    else:
        ok("작업 트리에 위험 파일 없음")

    # (c) ## Git 이력 검사 — 이게 가장 중요합니다
    # 지금 파일이 깨끗해도 과거 커밋에 비밀이 있으면, 저장소를 받는 사람이
    # 이력에서 꺼낼 수 있습니다. 실제로 그런 사고가 흔합니다.
    code, out = git(
        "log", "--all", "--pretty=format:", "--name-only", "--diff-filter=A"
    )
    if code == 0:
        secret_re = re.compile(
            r"(^|/)(\.env|\.env\.gabia|\.env\.sync|\.sync_key|"
            r"key\.properties|google-services\.json|.*\.jks)$"
        )
        hits = sorted({l.strip() for l in out.splitlines()
                       if l.strip() and secret_re.search(l.strip())})
        if hits:
            rep.fail(f"Git 이력에 비밀 파일이 추가된 적이 있습니다: {', '.join(hits[:5])}")
            bad(f"이력에 비밀 파일 {len(hits)}건 — 이력 재작성 없이는 제출 불가")
        else:
            ok("Git 이력에 비밀 파일 추가 기록 없음")


def check_tests(rep: Report) -> dict:
    """테스트 결과 파일이 있는가."""
    hdr("④ 테스트 결과")
    info: dict = {}

    candidates = [
        PROJECT_DIR / "test_results.txt",
        PROJECT_DIR / "TEST-RESULTS.md",
        Path("/tmp/flutter_test_result.txt"),
    ]
    for c in candidates:
        if c.exists():
            info["test_file"] = str(c)
            ok(f"{c.name} 발견 ({c.stat().st_size}B)")
            break
    else:
        rep.warnmsg("테스트 결과 파일 없음 — --submit 전에 flutter test 를 돌리세요")
        warn("테스트 결과 파일 없음 (치명적이지 않음)")

    return info


def check_repo_access() -> tuple[bool, str]:
    """제출 저장소에 접근할 수 있는가. (성공여부, 메시지)"""
    hdr("⑤ 제출 저장소 접근")

    # ## ls-remote 는 빈 저장소에서도 성공합니다
    # 404 는 "없음", 403 은 "권한 없음", 성공은 "있음"으로 구분합니다.
    # 저장소가 없으면 만들어야 하는데, 이 도구는 만들지 않습니다 —
    # 새 저장소 생성은 사용자 결정 사항입니다.
    try:
        r = subprocess.run(
            ["git", "ls-remote", REPO_URL],
            capture_output=True,
            text=True,
            timeout=45,
        )
        combined = (r.stdout or "") + (r.stderr or "")

        if r.returncode == 0:
            ok(f"{REPO_OWNER}/{REPO_NAME} 접근 가능")
            return True, "ok"

        if "not found" in combined.lower() or "404" in combined:
            bad(f"{REPO_OWNER}/{REPO_NAME} 저장소가 없습니다")
            return False, "not_found"

        if "authentication" in combined.lower() or "403" in combined:
            bad("인증/권한 문제로 접근할 수 없습니다")
            return False, "auth"

        bad(f"접근 실패: {combined.strip()[:200]}")
        return False, "error"
    except subprocess.TimeoutExpired:
        bad("저장소 접근 시간 초과")
        return False, "timeout"
    except Exception as e:
        bad(f"저장소 접근 오류: {e}")
        return False, "error"


# ===========================================================================
# 릴리스 조립
# ===========================================================================
def collect_source_files() -> list[Path]:
    """전송할 소스 파일 목록. 화이트리스트가 아니라 블랙리스트 + git 추적 기준."""
    files: list[Path] = []

    # ## git 이 추적하는 파일만 올립니다
    # 디렉터리를 통째로 긁으면 빌드 캐시나 개인 메모가 섞입니다.
    # git 이 아는 파일 = 저장소에 있어야 할 파일. 이게 가장 정확한 기준입니다.
    code, out = git("ls-files")
    if code != 0:
        return files

    excludes = [re.compile(p) for p in EXCLUDE_PATTERNS]

    for rel in out.splitlines():
        rel = rel.strip()
        if not rel:
            continue
        if any(e.search(rel) for e in excludes):
            continue
        p = PROJECT_DIR / rel
        if p.is_file():
            files.append(p)

    return files


def collect_build_files() -> list[Path]:
    """빌드 산출물. 전부 올립니다 (앱이 동작하려면 필요)."""
    files: list[Path] = []
    if not BUILD_DIR.exists():
        return files

    excludes = [re.compile(p) for p in EXCLUDE_PATTERNS]

    for p in sorted(BUILD_DIR.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(BUILD_DIR).as_posix()
        if any(e.search(rel) for e in excludes):
            continue
        files.append(p)

    return files


def make_manifest(
    files: list[tuple[Path, str]],
    rel_id: str,
    commit_sha: str,
    versions: dict,
    build_info: dict,
    test_info: dict,
) -> dict:
    """전송 매니페스트. 받는 쪽이 이걸로 검증합니다."""
    entries = []
    for path, arc in files:
        entries.append({
            "path": arc,
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
        })

    return {
        "app_id": "scheduler",
        "release_id": rel_id,
        "commit_sha": commit_sha,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "submit_branch": SUBMIT_BRANCH,
        "repo": f"{REPO_OWNER}/{REPO_NAME}",
        "versions": versions,
        "build": build_info,
        "tests": test_info,
        "file_count": len(entries),
        "files": entries,
    }


# ===========================================================================
# 제출
# ===========================================================================
def do_submit(rep: Report, rel_id: str, commit: str, manifest: dict,
              source_files: list[Path], build_files: list[Path]) -> int:
    """임시 디렉터리에 릴리스를 조립해 release/gabia 브랜치로 푸시합니다."""
    hdr("⑥ 릴리스 조립 및 푸시")

    work = Path(tempfile.mkdtemp(prefix="gabia-submit-"))
    try:
        # 브랜치를 하나만 가져옵니다 (이력이 쌓여도 크지 않게).
        code, out = git("clone", "--depth", "1", "--branch", SUBMIT_BRANCH,
                        REPO_URL, str(work / "repo"), cwd=work)
        if code != 0:
            # 브랜치가 아직 없으면 빈 저장소로 시작합니다.
            code2, out2 = git("clone", "--depth", "1", REPO_URL,
                              str(work / "repo"), cwd=work)
            if code2 != 0:
                bad("저장소를 복제할 수 없습니다")
                print(f"     {out2.strip()[:200]}")
                return 2
            repo = work / "repo"
            # 기본 브랜치에서 우리 브랜치를 만듭니다.
            git("checkout", "-b", SUBMIT_BRANCH, cwd=repo)
        else:
            repo = work / "repo"
            code3, _ = git("checkout", SUBMIT_BRANCH, cwd=repo)
            if code3 != 0:
                git("checkout", "-b", SUBMIT_BRANCH, cwd=repo)

        ok("저장소 준비")

        # ## 중복 방지 — 같은 릴리스 ID 가 이미 있으면 멈춥니다
        target = repo / RELEASE_ROOT / rel_id
        if target.exists():
            bad(f"릴리스 {rel_id} 가 이미 존재합니다 — 덮어쓰지 않습니다")
            return 3

        # 파일 배치
        target.mkdir(parents=True, exist_ok=False)

        n_src = 0
        for p in source_files:
            rel = p.relative_to(PROJECT_DIR)
            dst = target / "source" / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, dst)
            n_src += 1
        ok(f"소스 {n_src}개")

        n_bld = 0
        for p in build_files:
            rel = p.relative_to(BUILD_DIR)
            dst = target / "web" / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, dst)
            n_bld += 1
        ok(f"웹 빌드 {n_bld}개")

        # 매니페스트 (별도 파일 — 요구사항)
        manifest_path = target / "manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        manifest_sha = sha256_file(manifest_path)
        ok(f"manifest.json (sha256 {manifest_sha[:16]}…)")

        # 최상위 요약 — 저장소를 처음 여는 사람이 읽을 것
        summary = {
            "app_id": "scheduler",
            "release_id": rel_id,
            "commit_sha": commit,
            "submitted_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "manifest_sha256": manifest_sha,
            "source_files": n_src,
            "web_files": n_bld,
        }
        (target / "release.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        # LATEST 포인터 — 수신기가 어느 릴리스를 받을지 알려줍니다
        (repo / RELEASE_ROOT / "LATEST").write_text(rel_id + "\n", encoding="utf-8")

        # 커밋
        git("add", "-A", cwd=repo)
        msg = (
            f"release: {rel_id}\n\n"
            f"app: scheduler\n"
            f"commit: {commit}\n"
            f"source: {n_src} files, web: {n_bld} files\n"
            f"manifest_sha256: {manifest_sha}\n"
        )
        git("-c", "user.name=june-submit", "-c", "user.email=submit@local",
            "commit", "-m", msg, cwd=repo)
        ok("커밋 생성")

        # ## 푸시 — --force 를 절대 쓰지 않습니다
        # 릴리스는 쌓이는 기록입니다. 덮어쓰면 이전 릴리스가 사라지고,
        # 그게 곧 "무엇을 냈는지 모르는" 상태입니다.
        code, out = git("push", "origin", f"HEAD:{SUBMIT_BRANCH}", cwd=repo)
        if code != 0:
            bad("푸시 실패")
            print(f"     {out.strip()[:300]}")
            return 2

        ok(f"푸시 완료 → {SUBMIT_BRANCH}")
        return 0

    finally:
        shutil.rmtree(work, ignore_errors=True)


def list_releases() -> int:
    hdr(f"기존 릴리스 ({REPO_OWNER}/{REPO_NAME} / {SUBMIT_BRANCH})")
    ok_repo, reason = check_repo_access()
    if not ok_repo:
        if reason == "not_found":
            say("")
            say("  저장소가 없으므로 릴리스 목록도 없습니다.")
            return 2
        return 2

    work = Path(tempfile.mkdtemp(prefix="gabia-list-"))
    try:
        repo = work / "repo"
        code, _ = git("clone", "--depth", "1", "--branch", SUBMIT_BRANCH,
                      REPO_URL, str(repo), cwd=work)
        if code != 0:
            say("  브랜치가 아직 없습니다 (첫 제출 전)")
            return 0

        root = repo / RELEASE_ROOT
        if not root.exists():
            say("  릴리스 없음")
            return 0

        latest = ""
        lp = root / "LATEST"
        if lp.exists():
            latest = lp.read_text(encoding="utf-8").strip()

        for d in sorted(root.iterdir()):
            if not d.is_dir():
                continue
            mark = " ← LATEST" if d.name == latest else ""
            say(f"  · {d.name}{mark}")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ===========================================================================
def main() -> int:
    ap = argparse.ArgumentParser(description="가비아용 제출")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="검사만 (업로드 안 함)")
    g.add_argument("--submit", action="store_true", help="검사 후 업로드")
    g.add_argument("--list", action="store_true", help="릴리스 목록")
    g.add_argument("--dry-run", action="store_true", help="무엇을 올릴지 출력만")
    args = ap.parse_args()

    if args.list:
        return list_releases()

    rep = Report()
    versions = check_versions(rep)
    build_info = check_build(rep)
    check_secrets(rep)
    test_info = check_tests(rep)

    # 릴리스 ID 는 커밋 SHA 와 시각으로 만듭니다.
    commit = full_sha()
    if not commit:
        bad("커밋 SHA 를 읽을 수 없습니다 (git 저장소가 아닙니다)")
        return 2

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    rel_id = f"rel-{stamp}-{short_sha()}"

    hdr("⑥ 릴리스 식별")
    ok(f"릴리스 ID: {rel_id}")
    ok(f"커밋 SHA : {commit}")

    dirty = git_dirty_count()
    if dirty > 0:
        # ## 커밋 안 된 변경이 있으면 경고하되 막지는 않습니다
        # 릴리스 ID 에 SHA 가 들어가는데 작업 트리가 더러우면, 그 SHA 가
        # 전송한 파일과 정확히 일치하지 않습니다. 재현성 문제입니다.
        # 다만 작업 중 제출을 막으면 쓸 수 없는 도구가 되므로 경고만 합니다.
        rep.warnmsg(f"커밋 안 된 변경 {dirty}건 — 전송 파일이 {short_sha()} 와 정확히 일치하지 않을 수 있습니다")
        warn(f"커밋 안 된 변경 {dirty}건 (재현성 주의)")

    # 전송 목록
    source_files = collect_source_files()
    build_files = collect_build_files()

    hdr("⑦ 전송 목록")
    ok(f"소스 {len(source_files)}개")
    ok(f"웹 빌드 {len(build_files)}개")
    total_bytes = sum(p.stat().st_size for p in source_files + build_files)
    ok(f"합계 {total_bytes / 1048576:.1f}MB")

    # 필수 파일이 실제로 목록에 있는가
    src_rels = {p.relative_to(PROJECT_DIR).as_posix() for p in source_files}
    for need in REQUIRED_SOURCE:
        if need not in src_rels:
            rep.fail(f"필수 소스 누락: {need}")
            bad(f"필수 소스 누락: {need}")

    bld_rels = {p.relative_to(BUILD_DIR).as_posix() for p in build_files}
    for need in REQUIRED_BUILD:
        if need not in bld_rels:
            rep.fail(f"필수 빌드 파일 누락: {need}")
            bad(f"필수 빌드 파일 누락: {need}")

    # 전송 제외 확인 — 실제로 빠졌는지
    leaked = [r for r in src_rels
              if re.search(r"(^|/)(\.env|\.sync_key|key\.properties)$", r)]
    if leaked:
        rep.fail(f"전송 목록에 비밀이 있습니다: {', '.join(leaked[:3])}")
        bad(f"전송 목록에 비밀 {len(leaked)}건")

    if args.dry_run:
        hdr("전송 목록 상세 (dry-run)")
        for p in source_files[:40]:
            say(f"  source/{p.relative_to(PROJECT_DIR).as_posix()}")
        if len(source_files) > 40:
            say(f"  … 외 {len(source_files) - 40}개")
        for p in build_files[:15]:
            say(f"  web/{p.relative_to(BUILD_DIR).as_posix()}")
        if len(build_files) > 15:
            say(f"  … 외 {len(build_files) - 15}개")

    # 검사 결과
    hdr("⑧ 검사 결과")
    for w in rep.warnings:
        warn(w)

    if not rep.passed:
        say("")
        for f in rep.failures:
            bad(f)
        say("")
        bad("검사를 통과하지 못해 업로드하지 않습니다.")
        return 1

    ok("모든 필수 검사 통과")

    # 저장소 접근 — 업로드 전에 반드시
    repo_ok, reason = check_repo_access()

    if args.check:
        hdr("결과")
        ok("검사 통과 (업로드하지 않음 — --check)")
        if not repo_ok:
            if reason == "not_found":
                warn(f"다만 {REPO_OWNER}/{REPO_NAME} 저장소가 없어 제출은 불가합니다")
            else:
                warn("다만 저장소 접근에 문제가 있어 제출은 불가합니다")
        return 0

    if not args.submit:
        hdr("결과")
        ok("검사 통과")
        say("  실제로 올리려면: --submit")
        return 0

    # ---- 실제 제출 ----
    if not repo_ok:
        hdr("결과")
        if reason == "not_found":
            bad(f"{REPO_OWNER}/{REPO_NAME} 저장소가 없습니다 — 제출 불가")
            say("")
            say("  이 도구는 저장소를 만들지 않습니다. 새 저장소 생성은")
            say("  사용자 결정 사항이므로 임의로 진행하지 않습니다.")
            say("")
            say("  만들고 나서 이 명령을 다시 실행하세요:")
            say(f"    python3 scripts/submit_gabia.py --submit")
        else:
            bad("저장소 접근에 문제가 있어 제출하지 않습니다")
        return 2

    manifest = make_manifest(
        [(p, p.relative_to(PROJECT_DIR).as_posix()) for p in source_files]
        + [(p, "web/" + p.relative_to(BUILD_DIR).as_posix()) for p in build_files],
        rel_id, commit, versions, build_info, test_info,
    )

    rc = do_submit(rep, rel_id, commit, manifest, source_files, build_files)

    hdr("결과")
    if rc == 0:
        # 결과를 파일로 남깁니다 — 나중에 "무엇을 냈는지" 물을 때 근거가 됩니다
        out = PROJECT_DIR / "submit-result.json"
        out.write_text(json.dumps({
            "repo": f"{REPO_OWNER}/{REPO_NAME}",
            "branch": SUBMIT_BRANCH,
            "release_id": rel_id,
            "commit_sha": commit,
            "submitted_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "source_files": len(source_files),
            "web_files": len(build_files),
            "manifest_sha256": sha256_file(
                PROJECT_DIR / "submit-result.json"
            ) if False else "",
            "gabia_receive": "UNCONFIRMED",
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        ok("GitHub 제출 완료")
        say("")
        say(f"  저장소      : {REPO_OWNER}/{REPO_NAME}")
        say(f"  브랜치      : {SUBMIT_BRANCH}")
        say(f"  릴리스 ID   : {rel_id}")
        say(f"  커밋 SHA    : {commit}")
        say(f"  소스/웹     : {len(source_files)} / {len(build_files)} 파일")
        say("")
        say("  가비아 수신 : 미확인 (수신기가 연결돼 있지 않습니다)")
        say("")
        say("  ※ 자동 설치·실행은 하지 않았습니다. 서버 반영은 별도 절차입니다.")
        return 0

    if rc == 3:
        bad("같은 릴리스가 이미 있습니다 — 덮어쓰지 않았습니다")
        return 3

    bad("제출 실패")
    return 2


if __name__ == "__main__":
    sys.exit(main())

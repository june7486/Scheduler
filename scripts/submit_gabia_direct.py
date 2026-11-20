#!/usr/bin/env python3
"""가비아 직접 제출 — 빌드 → 검사 → 패키징 → HTTPS 업로드 → 접수 확인.

## 이 도구는 개발 환경 전용입니다

웹앱이나 브라우저에 포함되지 않습니다. `lib/` 를 건드리지 않고,
`build/web` 에 아무것도 추가하지 않습니다. `scripts/` 아래에서만 돕니다.
그래서 배포 번들에 이 코드가 실려 나갈 경로가 없습니다.

## GitHub 경유 제출은 취소됐습니다

이전 `submit_gabia.py` 는 비공개 저장소로 푸시하는 방식이었습니다.
그 계획은 취소됐으므로 그 파일은 더 이상 쓰지 않습니다. 이 도구는
저장소를 만들지도, 푸시하지도 않습니다. ZIP 을 만들어 HTTPS 로 보냅니다.

## 자격증명은 실행 환경에서만

    GABIA_RECEIVE_URL   https://…/scheduler/upload   (수신 엔드포인트)
    GABIA_SUBMIT_ID     제출자 식별자
    GABIA_SUBMIT_TOKEN  업로드 토큰

이 세 값은 **환경변수로만** 받습니다. 다음 어디에도 쓰지 않습니다:
  · ZIP 안 (당연히)
  · 로그·화면 출력 (마스킹도 하지 않고 아예 출력하지 않음)
  · 명령행 인자 (ps 에 남습니다)
  · 임시 파일·설정 파일
  · git 저장소

`--check` 로 확인할 때도 "설정됨/없음"만 말하고 값은 말하지 않습니다.

## 흐름

    ① 빌드 (선택 — --skip-build 로 건너뛸 수 있음)
    ② 검사 (필수 항목 하나라도 실패하면 업로드 안 함)
    ③ 패키징 (ZIP + 매니페스트)
    ④ 업로드 (자격증명·수신기가 준비된 경우에만)
    ⑤ 접수 확인 (서버 접수 ID + 서버 계산 해시 일치 시에만 "완료")

## 사용법

    python3 scripts/submit_gabia_direct.py --check      # 환경·검사만
    python3 scripts/submit_gabia_direct.py --package    # 패키징까지만
    python3 scripts/submit_gabia_direct.py --submit     # 전체 (업로드 포함)

## 종료 코드

    0  성공 (패키징 완료 또는 접수 확인까지 완료)
    1  검사 실패 — 업로드하지 않음
    2  환경 문제 (빌드 없음, 자격증명 없음 등)
    3  업로드 실패
    4  접수 확인 불일치 (해시 또는 ID)
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
import urllib.error
import urllib.request
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
BUILD_DIR = PROJECT_DIR / "build" / "web"
OUT_DIR = PROJECT_DIR / "dist" / "gabia-submit"

APP_ID = "scheduler"

# ---------------------------------------------------------------------------
# 자격증명 — 이름만 여기 두고 값은 환경에서 읽습니다
# ---------------------------------------------------------------------------
ENV_URL = "GABIA_RECEIVE_URL"
ENV_ID = "GABIA_SUBMIT_ID"
ENV_TOKEN = "GABIA_SUBMIT_TOKEN"

# ## ZIP 에 넣으면 안 되는 것
# 비밀·키·개인데이터·git 이력. 그리고 운영에서 만든 산출물 중
# 사용자 데이터가 섞일 수 있는 것들.
EXCLUDE_ANYWHERE = (
    r"(^|/)\.git(/|$)",
    r"(^|/)\.env$",
    r"(^|/)\.env\.gabia$",
    r"(^|/)\.env\.sync$",
    r"(^|/)\.sync_key$",
    r"(^|/)key\.properties$",
    r"(^|/)google-services\.json$",
    r"\.jks$",
    r"\.keystore$",
    r"\.pem$",
    r"\.p12$",
    r"(^|/)node_modules(/|$)",
    r"(^|/)\.dart_tool(/|$)",
    r"(^|/)__pycache__(/|$)",
    r"(^|/)data(/|$)",
    r"(^|/)test-workspace(/|$)",
    r"(^|/)dist(/|$)",
    r"\.log$",
    r"(^|/)\.DS_Store$",
)

# ## 반드시 들어가야 하는 것
REQUIRED_IN_ZIP = (
    "source/pubspec.yaml",
    "source/pubspec.lock",
    "source/lib/main.dart",
    "web/index.html",
    "web/main.dart.js",
    "web/version.json",
    "README-SUBMIT.md",
    "manifest.json",
)

# ## 소스에서 뺄 것 (ZIP 안 source/ 아래)
SOURCE_SKIP_PREFIX = (
    "build/",
    "dist/",
    "android/.gradle/",
    "ios/Pods/",
    "test-workspace/",
)

# ## 알려진 유출값 — ZIP 에 남아 있으면 무조건 실패
#
# 2026-11-20 사고로 공개 배포본에 박혀 나간 값입니다. 문서에 "증거" 로
# 인용해 두는 습관이 정확히 이 사고를 재발시킵니다.
#
# ## 그런데 왜 값을 여기 적지 않는가
# 이 스크립트 자신도 ZIP 에 들어갑니다(git 추적 대상). 값을 리터럴로
# 적으면 **검사기가 자기 자신을 위반**합니다. 그래서 값은 적지 않고,
# 파일 안에서 발견한 64자 hex 후보의 **해시만** 여기 목록과 대조합니다.
# 값은 코드·로그·ZIP 어디에도 남지 않고, 검사는 동일하게 동작합니다.
KNOWN_LEAKED_SHA256 = (
    # 옛 SYNC_KEY (2026-11-20 유출) — 원문 대신 해시만
    "1f9020db559a1e610611b5e1cbcf43a1b5f40591d72c72d7f8e51b2ea7560a70",
)


def say(m: str = "") -> None:
    print(m)


def ok(m: str) -> None:
    print(f"  \033[32m✅\033[0m {m}")


def warn(m: str) -> None:
    print(f"  \033[33m⚠️ \033[0m {m}")


def bad(m: str) -> None:
    print(f"  \033[31m❌\033[0m {m}")


def hdr(m: str) -> None:
    print(f"\n\033[1m{m}\033[0m")


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args: str) -> tuple[int, str]:
    try:
        r = subprocess.run(
            ["git", *args], cwd=str(PROJECT_DIR),
            capture_output=True, text=True, timeout=120,
        )
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return 1, str(e)


def commit_sha() -> str:
    c, o = git("rev-parse", "HEAD")
    return o.strip() if c == 0 else ""


# ---------------------------------------------------------------------------
# 자격증명 — 값은 절대 반환하지 않고 "있는지"만 봅니다
# ---------------------------------------------------------------------------
class Creds:
    """자격증명 존재 여부만 들고 다니는 그릇.

    ## 왜 값을 보관하지 않는가
    실수로 print 하거나 로그에 남길 위험을 없애려면, 애초에 들고 있지
    않는 게 가장 안전합니다. 업로드 직전에 환경에서 다시 읽습니다.
    """

    def __init__(self) -> None:
        self.has_url = bool(os.environ.get(ENV_URL, "").strip())
        self.has_id = bool(os.environ.get(ENV_ID, "").strip())
        self.has_token = bool(os.environ.get(ENV_TOKEN, "").strip())

    @property
    def ready(self) -> bool:
        return self.has_url and self.has_id and self.has_token

    def describe(self) -> None:
        for name, present in (
            (ENV_URL, self.has_url),
            (ENV_ID, self.has_id),
            (ENV_TOKEN, self.has_token),
        ):
            if present:
                ok(f"{name} 설정됨")
            else:
                warn(f"{name} 없음")

    def safe_host(self) -> str:
        """수신 URL 의 호스트만 돌려줍니다 — 경로·쿼리·토큰은 뺍니다."""
        raw = os.environ.get(ENV_URL, "").strip()
        if not raw:
            return ""
        try:
            from urllib.parse import urlparse
            u = urlparse(raw)
            if u.scheme != "https":
                return "(https 아님)"
            return f"{u.scheme}://{u.hostname}" + (f":{u.port}" if u.port else "")
        except Exception:
            return "(해석 실패)"


# ---------------------------------------------------------------------------
# 검사
# ---------------------------------------------------------------------------
class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []

    def fail(self, m: str) -> None:
        self.failures.append(m)

    def warnmsg(self, m: str) -> None:
        self.warnings.append(m)

    @property
    def passed(self) -> bool:
        return not self.failures


def check_versions(rep: Report) -> dict:
    hdr("① 버전 — pubspec.yaml 에서 직접")
    info: dict = {}
    p = PROJECT_DIR / "pubspec.yaml"
    if not p.exists():
        rep.fail("pubspec.yaml 없음")
        bad("pubspec.yaml 없음")
        return info

    for line in p.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("name:"):
            info["package"] = s.split(":", 1)[1].strip()
        elif s.startswith("version:"):
            info["app_version"] = s.split(":", 1)[1].strip()
        elif s.startswith("sdk:") and "dart_sdk" not in info:
            info["dart_sdk"] = s.split(":", 1)[1].strip()

    ok(f"패키지      : {info.get('package', '?')}")
    ok(f"앱 버전     : {info.get('app_version', '?')}")
    ok(f"Dart SDK    : {info.get('dart_sdk', '?')}")

    # ## Flutter 버전은 pubspec 에 없습니다
    # 실제로 확인해 기록합니다. "문서에 3.35.4 라고 적혀 있다"가 아니라
    # "지금 이 환경에서 실행한 결과"가 근거가 되어야 합니다.
    try:
        r = subprocess.run(["flutter", "--version"], capture_output=True,
                           text=True, timeout=90)
        first = (r.stdout or "").splitlines()[0] if r.stdout else ""
        m = re.search(r"(\d+\.\d+\.\d+)", first)
        if m:
            info["flutter"] = m.group(1)
            ok(f"Flutter     : {info['flutter']} (실행 확인)")
        else:
            warn("Flutter 버전 문자열을 못 읽었습니다")
    except Exception:
        warn("flutter --version 실행 실패")

    return info


def check_build(rep: Report) -> dict:
    hdr("② 빌드 산출물 — build/web")
    info: dict = {}
    if not BUILD_DIR.exists():
        rep.fail("build/web 없음 — 빌드가 필요합니다")
        bad("build/web 없음")
        return info

    for name in ("index.html", "main.dart.js", "flutter_bootstrap.js", "version.json"):
        f = BUILD_DIR / name
        if f.exists():
            ok(f"{name} ({f.stat().st_size:,}B)")
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
        info["wasm_count"] = len(wasm)
        info["wasm_bytes"] = sum(x.stat().st_size for x in wasm)
        ok(f"wasm {len(wasm)}개, {info['wasm_bytes'] / 1048576:.1f}MB")
    else:
        rep.fail("wasm 없음 — 흰 화면이 됩니다")
        bad("wasm 없음")

    return info


def check_secrets(rep: Report) -> None:
    hdr("③ 비밀 누출 검사")

    # (a) 번들 검사
    scanner = PROJECT_DIR / "scripts" / "check_bundle_secrets.py"
    if scanner.exists():
        r = subprocess.run([sys.executable, str(scanner), "--strict"],
                           cwd=str(PROJECT_DIR), capture_output=True,
                           text=True, timeout=120)
        if r.returncode == 0:
            ok("웹 번들 검사 통과")
        else:
            rep.fail("웹 번들에 주소·키가 포함되어 있습니다")
            bad("웹 번들 검사 실패")
    else:
        rep.warnmsg("번들 검사 스크립트 없음")
        warn("번들 검사 스크립트 없음")

    # (b) 환경변수에 자격증명이 있는데 소스에 박혀 있지 않은가
    # 이건 흔한 사고입니다. .env 에 넣어야 할 값을 코드에 복사하는 것.
    creds = [os.environ.get(k, "") for k in (ENV_TOKEN, ENV_ID)]
    creds = [c for c in creds if len(c) >= 8]
    if creds:
        leaked = []
        for f in (PROJECT_DIR / "lib").rglob("*.dart"):
            try:
                txt = f.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            if any(c in txt for c in creds):
                leaked.append(f.name)
        if leaked:
            rep.fail(f"자격증명이 소스에 박혀 있습니다: {', '.join(leaked[:3])}")
            bad("자격증명이 lib/ 에 있습니다")
        else:
            ok("자격증명이 소스에 없음")
    else:
        ok("검사할 자격증명 없음 (환경에 설정돼 있지 않음)")

    # (c) 작업 트리에 위험 파일이 추적되고 있는가
    danger = (".env", ".env.gabia", ".sync_key", "key.properties",
              "google-services.json")
    existing = [n for n in danger if (PROJECT_DIR / n).exists()]
    if existing:
        code, out = git("ls-files", *existing)
        tracked = [l for l in out.splitlines() if l.strip()]
        if tracked:
            rep.fail(f"위험 파일이 추적 중: {', '.join(tracked)}")
            bad(f"추적 중: {', '.join(tracked)}")
        else:
            ok(f"위험 파일 {len(existing)}개 있으나 미추적 → ZIP 에서 제외")
    else:
        ok("작업 트리에 위험 파일 없음")

    # (d) ## ZIP 대상에 .git 이 섞이는가
    # .git 을 넣으면 이력에서 옛 비밀을 꺼낼 수 있습니다.
    # 지금 파일이 깨끗해도 이력은 별개입니다.
    gitdir = PROJECT_DIR / ".git"
    if gitdir.exists():
        ok(".git 존재 — ZIP 에서 제외 예정")
    else:
        ok(".git 없음")

    # (e) ## ZIP 에 실제로 들어갈 파일의 **내용**을 검사한다
    #
    # 이 검사가 없어서 실제로 사고가 날 뻔했습니다. 앞의 (a)~(d) 는
    # 전부 "파일 이름"과 "웹 번들"만 봤습니다. 그런데 ZIP 에는
    # **소스 문서**가 그대로 들어갑니다. INCIDENT-2026-11-20.md 는
    # 유출된 SYNC_KEY 를 증거로 **원문 인용**해 둔 문서였고,
    # 그 문서는 아무 검사도 받지 않은 채 ZIP 에 실려 나갔습니다.
    #
    # 교훈: 제외 목록은 "무엇을 빼는가"만 정합니다. "무엇이 남았는가"는
    # 별도로 읽어봐야 합니다. 그래서 이것을 필수 검사에 넣습니다.
    hdr("③-2 ZIP 대상 파일 내용 검사")
    hits = scan_zip_targets_for_secrets(rep)
    if not hits:
        ok("금지 패턴 0건")


def scan_zip_targets_for_secrets(rep: Report) -> list[str]:
    """ZIP 에 들어갈 소스 파일의 내용을 훑어 비밀값을 찾습니다.

    파일 이름만 보는 검사로는 절대 못 잡는 것들을 잡습니다:
      · 문서에 원문 인용된 키 (INCIDENT 보고서 같은 것)
      · 스크립트 기본값으로 박힌 실제 DDNS 주소
      · 실수로 커밋된 개인키 / 토큰

    ## 왜 "건수" 로 판정하는가
    예전에 `grep -q` 로 하다가 `set -o pipefail` 과 만나 조용히
    거짓 통과를 낸 적이 있습니다. 여기서는 python 이 직접 세므로
    파이프도 없고, 세는 값이 0 이 아니면 실패로 봅니다.
    """
    targets = collect_source()
    if not targets:
        rep.fail("ZIP 대상 소스를 읽지 못해 내용 검사를 할 수 없습니다")
        bad("소스 목록 없음 — 내용 검사 불가")
        return ["<no-targets>"]

    hex_re = re.compile(r"\b[0-9a-f]{64}\b")
    hits: list[str] = []
    sha_list = set(KNOWN_LEAKED_SHA256)

    for p, arc in targets:
        try:
            if p.stat().st_size > 4 * 1024 * 1024:      # 큰 바이너리 제외
                continue
            txt = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue

        # 개인키 헤더 — 있으면 즉시 실패
        for marker in ("-----BEGIN RSA PRIVATE KEY-----",
                       "-----BEGIN OPENSSH PRIVATE KEY-----",
                       "-----BEGIN PRIVATE KEY-----"):
            if marker in txt:
                hits.append(f"{arc} ← 개인키 헤더")
                rep.fail(f"개인키가 ZIP 에 포함됩니다: {arc}")
                bad(f"개인키: {arc}")

        # 64자 hex 후보를 해시로 대조 — 유출값이면 실패
        for m in set(hex_re.findall(txt)):
            digest = hashlib.sha256(m.encode()).hexdigest()
            if digest in sha_list:
                hits.append(f"{arc} ← 알려진 유출값 포함")
                rep.fail(f"ZIP 에 유출값이 남아 있습니다: {arc}")
                bad(f"유출값: {arc}")

    return hits


def check_tests(rep: Report) -> dict:
    hdr("④ 테스트 결과")
    info: dict = {}
    for c in (PROJECT_DIR / "test_results.txt",
              PROJECT_DIR / "TEST-RESULTS.md"):
        if c.exists():
            info["file"] = c.name
            info["size"] = c.stat().st_size
            ok(f"{c.name} ({c.stat().st_size}B)")
            # ## 결과 파일이 실제로 "통과"를 말하는가
            # 존재만 확인하면 "실패 3건"이라고 적힌 파일도 통과로 봅니다.
            txt = c.read_text(encoding="utf-8", errors="ignore")
            if re.search(r"\b0 failed\b|\bAll tests passed\b", txt):
                ok("결과: 실패 0건 표기 확인")
            else:
                rep.warnmsg("테스트 결과 파일에 '0 failed' 표기가 없습니다")
                warn("결과 파일에 실패 0건 표기가 없음")
            return info

    rep.warnmsg("테스트 결과 파일 없음")
    warn("테스트 결과 파일 없음 — 증빙으로 넣을 수 없습니다")
    return info


def check_receiver(creds: Creds, rep: Report) -> bool:
    hdr("⑤ 수신기·자격증명")
    creds.describe()

    if not creds.ready:
        warn("자격증명이 갖춰지지 않아 업로드할 수 없습니다")
        return False

    host = creds.safe_host()
    ok(f"수신 호스트: {host}")
    if host == "(https 아님)":
        rep.fail("수신 URL 이 https 가 아닙니다 — 평문 전송은 허용하지 않습니다")
        bad("https 아님")
        return False

    # 외부 HTTPS 요청이 실제로 가능한가 — 수신기 없이도 확인 가능한 부분
    try:
        req = urllib.request.Request("https://example.com", method="HEAD")
        urllib.request.urlopen(req, timeout=10)
        ok("외부 HTTPS 요청 가능")
    except Exception as e:
        # ## 실패해도 치명적으로 보지 않습니다
        # example.com 이 막혀 있어도 실제 수신기는 열려 있을 수 있습니다.
        # 다만 "네트워크가 아예 없다"는 신호일 수 있으므로 경고합니다.
        rep.warnmsg(f"외부 HTTPS 확인 실패: {type(e).__name__}")
        warn(f"외부 HTTPS 확인 실패 ({type(e).__name__})")

    return True


# ---------------------------------------------------------------------------
# 패키징
# ---------------------------------------------------------------------------
def collect_source() -> list[tuple[Path, str]]:
    """ZIP 에 넣을 소스. git 추적 파일 기준 + 제외 규칙."""
    out: list[tuple[Path, str]] = []
    code, listing = git("ls-files")
    if code != 0:
        return out

    ex = [re.compile(p) for p in EXCLUDE_ANYWHERE]

    for rel in listing.splitlines():
        rel = rel.strip()
        if not rel:
            continue
        if any(rel.startswith(p) for p in SOURCE_SKIP_PREFIX):
            continue
        if any(e.search(rel) for e in ex):
            continue
        p = PROJECT_DIR / rel
        if p.is_file():
            out.append((p, f"source/{rel}"))
    return out


def collect_build() -> list[tuple[Path, str]]:
    out: list[tuple[Path, str]] = []
    if not BUILD_DIR.exists():
        return out
    ex = [re.compile(p) for p in EXCLUDE_ANYWHERE]
    for p in sorted(BUILD_DIR.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(BUILD_DIR).as_posix()
        if any(e.search(rel) for e in ex):
            continue
        out.append((p, f"web/{rel}"))
    return out


def write_readme(path: Path, versions: dict, build: dict, commit: str,
                 rel_id: str) -> None:
    """ZIP 안의 실행 안내. 받는 사람이 이 파일 하나로 시작할 수 있게."""
    path.write_text(f"""# June's Scheduler — 가비아 제출 패키지

릴리스 ID : `{rel_id}`
커밋 SHA  : `{commit}`
생성 시각 : {datetime.now(timezone.utc).isoformat(timespec='seconds')}
앱 ID     : `{APP_ID}`

---

## 이 패키지의 구성

```
source/     ← 재현 가능한 소스 (git 추적 파일 기준)
web/        ← 빌드된 웹 앱 (정적 파일, 그대로 서빙 가능)
manifest.json  ← 파일별 SHA-256·크기
README-SUBMIT.md  ← 이 문서
```

---

## 1. 빌드 환경 (실측값)

| 항목 | 값 |
|---|---|
| Flutter | **{versions.get('flutter', '?')}** |
| Dart SDK | **{versions.get('dart_sdk', '?')}** (`pubspec.yaml`) |
| 앱 버전 | `{versions.get('app_version', '?')}` |

> ⚠️ **버전을 올리지 마세요.** 이 프로젝트는 위 조합으로 검증됐습니다.
> 다른 버전으로 빌드하면 미묘한 차이가 생길 수 있습니다.

---

## 2. 재현 가능한 웹 빌드

```bash
cd source
flutter --version        # {versions.get('flutter', '?')} 확인
flutter pub get
flutter build web --release --base-href "/"
# 결과: build/web
```

`pubspec.lock` 이 포함되어 있으므로 `flutter pub get` 은 같은 버전을 받습니다.

> 💡 `web/` 는 이미 빌드된 결과입니다. 빌드 없이 그대로 서빙해도 됩니다.
> 다시 빌드하려면 위 명령을 쓰세요.

---

## 3. 웹 앱 서빙 — 필요한 조건 세 가지

정적 파일만 서빙하면 됩니다. 별도 API·DB·인증 서버가 **필요 없습니다**.

| # | 조건 | 이유 |
|---|---|---|
| 1 | `.wasm` → `application/wasm` | 틀리면 CanvasKit 로드 실패 → **흰 화면** |
| 2 | `index.html` 캐시 금지 | 캐시되면 사용자가 영원히 옛 버전을 봄 |
| 3 | `version.json` 캐시 금지 | 업데이트 확인이 조용히 거짓말을 함 |

`server/gateway/nginx-scheduler-gabia.conf` 에 이 설정이 들어 있습니다.

**확인 명령:**

```bash
curl -sSI https://<도메인>/canvaskit/canvaskit.wasm | grep -i content-type
# → content-type: application/wasm
curl -sSI https://<도메인>/version.json | grep -i cache-control
# → no-cache
```

---

## 4. 선택 — 동기화 서버

여러 기기에서 같은 자료를 볼 때만 필요합니다. **없어도 앱은 동작합니다.**

```bash
cd source/server/gateway
node server.js            # 기본 PORT 8097 / HOST 127.0.0.1
```

| 항목 | 값 | 근거 |
|---|---|---|
| 수신 포트 | **8097** | `server/gateway/server.js:49` |
| 바인딩 | **127.0.0.1** | 같은 파일 72행 |

> ⚠️ **8097 을 인터넷에 열지 마세요.** 앞단 Nginx 가 `/api/` 를 대신
> 받아 넘기는 구조입니다. 직접 노출하면 인증이 공유키 하나뿐이라 위험합니다.

---

## 5. 일정은 어디에 저장되는가

**브라우저 안(IndexedDB)** 입니다. 서버에 사용자 일정 DB 가 없습니다.

| 질문 | 답 |
|---|---|
| 서버 DB? | **없음** |
| 외부 캘린더 자동 동기화? | **없음** — 구글 캘린더 **딥링크**만 |
| OAuth 토큰? | **없음** |
| 주소를 바꾸면 데이터가 따라오나? | **아니오** |

### ⚠️ 주소를 바꿀 때 — 내보내기/가져오기 필수

브라우저 저장소는 **출처(origin) 단위**로 격리됩니다. `www.aqdesign.co.kr`
에서 쓰던 데이터는 새 주소에서 보이지 않습니다. 앱에 기능이 있으므로
개발은 불필요하고 **사용자 안내문**만 준비하면 됩니다.

```
옛 주소에서: 설정 → 백업 → JSON 다운로드
새 주소에서: 설정 → 백업 복원 → JSON 선택
```

> ⚠️ **복구는 덮어쓰기입니다.** 병합이 아닙니다. 복구 전에 현재 데이터를
> 먼저 백업하세요. 안내문에 반드시 넣어야 하는 문장입니다.

### 시간대

`dueDate` 는 ISO-8601 문자열이며 **시간대 정보가 없습니다**
(`2026-11-20T09:00:00`). 그래서 그 기기의 벽시계 시각으로 저장·표시됩니다.
`updatedAt`/`deletedAt` 은 epoch 밀리초입니다.

---

## 6. 테스트 결과

`test_results.txt` 를 함께 넣었습니다.

- 가상 일정으로 저장·수정·재조회, 반복 일정(`none/daily/weekly/monthly`),
  시간대 처리를 검사합니다.
- **실제 일정이나 캘린더 계정을 쓰지 않습니다.**

---

## 7. 이 패키지에 넣지 않은 것

의도적으로 제외했습니다. 필요하면 별도 보안 채널로 주고받으세요.

| 제외 항목 | 이유 |
|---|---|
| `.env`, `.env.gabia`, `.sync_key` | 자격증명 |
| `key.properties`, `*.jks` | 앱 서명 키 |
| `.git/` | 이력에 옛 비밀이 있을 수 있음 |
| `server/gateway/data/` | 사용자 일정 데이터 |
| 실제 일정·캘린더 계정 데이터 | 개인정보 |
| OAuth 토큰 | 해당 없음 (OAuth 미사용) |
| 운영 DB 덤프 | 해당 없음 (서버 DB 없음) |

설정 **예시**는 넣었습니다 — `source/scripts/env.gabia.example`,
`source/server/gateway/env.gabia.example` (값은 비어 있음).

---

## 8. 검증

`manifest.json` 에 모든 파일의 SHA-256 이 있습니다.

```bash
python3 - <<'PY'
import json, hashlib, pathlib
m = json.load(open('manifest.json'))
bad = 0
for e in m['files']:
    p = pathlib.Path(e['path'])
    h = hashlib.sha256(p.read_bytes()).hexdigest()
    if h != e['sha256']:
        print('불일치:', e['path']); bad += 1
print('검증 완료 — 불일치', bad, '건')
PY
```
""", encoding="utf-8")


def build_zip(rep: Report, versions: dict, build: dict, tests: dict,
              commit: str, rel_id: str) -> tuple[Path, dict] | None:
    hdr("⑥ 패키징")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    zip_path = OUT_DIR / f"{APP_ID}-{rel_id}.zip"

    source = collect_source()
    buildf = collect_build()
    ok(f"소스 {len(source)}개 / 웹 {len(buildf)}개")

    # 매니페스트를 먼저 계산합니다 (ZIP 에 넣을 것이므로)
    entries: list[dict] = []
    for p, arc in source + buildf:
        entries.append({
            "path": arc,
            "size": p.stat().st_size,
            "sha256": sha256_file(p),
        })

    manifest = {
        "app_id": APP_ID,
        "release_id": rel_id,
        "commit_sha": commit,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "versions": versions,
        "build": build,
        "tests": tests,
        "file_count": len(entries),
        "files": entries,
        "excluded_by_design": [
            ".env / .env.gabia / .sync_key",
            "key.properties / *.jks / *.pem / *.p12",
            ".git/",
            "server/gateway/data/",
            "node_modules/, .dart_tool/, __pycache__/",
        ],
    }

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED,
                         compresslevel=6) as z:
        for p, arc in source + buildf:
            z.write(p, arc)

        # README 는 임시 파일로 만들어 넣습니다 (프로젝트에 남기지 않음)
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False,
                                        encoding="utf-8") as tf:
            tf_path = Path(tf.name)
        try:
            write_readme(tf_path, versions, build, commit, rel_id)
            z.writestr("README-SUBMIT.md", tf_path.read_text(encoding="utf-8"))
        finally:
            tf_path.unlink(missing_ok=True)

        z.writestr("manifest.json",
                   json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    ok(f"ZIP: {zip_path.name} ({zip_path.stat().st_size / 1048576:.1f}MB)")

    # =====================================================================
    # ZIP 내용 검사 — 만들었다 ≠ 안전하다
    # =====================================================================
    # ## 왜 ZIP 을 다시 열어보는가
    # 제외 규칙을 코드로 썼지만, 그 규칙이 실제로 먹혔는지는 별개입니다.
    # 패턴이 안 맞으면 조용히 통과합니다. 그래서 **결과물을 다시 읽어**
    # 금지 항목이 없는지 확인합니다. 이게 이 검사의 존재 이유입니다.
    hdr("⑦ ZIP 내용 재검사")
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()

    bad_found = []
    ex = [re.compile(p) for p in EXCLUDE_ANYWHERE]
    for n in names:
        if any(e.search(n) for e in ex):
            bad_found.append(n)

    if bad_found:
        rep.fail(f"ZIP 에 금지 항목이 있습니다: {', '.join(bad_found[:5])}")
        bad(f"금지 항목 {len(bad_found)}건")
        for n in bad_found[:5]:
            print(f"     {n}")
        zip_path.unlink(missing_ok=True)
        return None

    ok(f"금지 항목 0건 (검사 {len(names)}개 항목)")

    for need in REQUIRED_IN_ZIP:
        if need in names:
            ok(f"필수 포함: {need}")
        else:
            rep.fail(f"필수 항목 누락: {need}")
            bad(f"누락: {need}")

    # 압축 해제 후 해시 검증 — ZIP 이 손상되지 않았는지
    try:
        with zipfile.ZipFile(zip_path) as z:
            crashed = z.testzip()
        if crashed:
            rep.fail(f"ZIP 손상: {crashed}")
            bad(f"ZIP 손상: {crashed}")
        else:
            ok("ZIP 무결성 (testzip 통과)")
    except Exception as e:
        rep.fail(f"ZIP 검증 실패: {e}")
        bad(f"ZIP 검증 실패: {e}")

    zip_sha = sha256_file(zip_path)
    ok(f"ZIP sha256 {zip_sha[:32]}…")

    # ## manifest 를 함께 돌려주는 이유
    # 업로드할 때 서버에 `manifest_sha256` 을 보냅니다. 예전엔 빈 dict 를
    # 넘겨서 **해시가 늘 같은 값**(빈 객체의 해시)이 나갔습니다. 검증하는
    # 쪽에서는 "매니페스트를 확인했다"는 착각만 남습니다. 그래서 실제
    # 매니페스트를 같이 실어 보냅니다.
    return zip_path, {"sha256": zip_sha, "size": zip_path.stat().st_size,
                      "files": len(names), "manifest": manifest}


# ---------------------------------------------------------------------------
# 업로드
# ---------------------------------------------------------------------------
def upload(zip_path: Path, zip_sha: str, rel_id: str, commit: str,
           manifest: dict) -> tuple[bool, str, dict]:
    """HTTPS 로 ZIP 을 보냅니다. (성공, 메시지, 서버응답)"""
    hdr("⑧ 가비아 업로드")

    # ## 여기서 환경을 다시 읽습니다
    # Creds 객체에 값을 담아두지 않았으므로, 필요할 때 다시 읽습니다.
    # 그 편이 실수로 출력될 경로가 하나 줄어듭니다.
    url = os.environ.get(ENV_URL, "").strip()
    sid = os.environ.get(ENV_ID, "").strip()
    token = os.environ.get(ENV_TOKEN, "").strip()

    if not (url and sid and token):
        bad("자격증명이 없습니다")
        return False, "no_credentials", {}

    # ## multipart/form-data 를 손으로 만듭니다
    # requests 를 쓰지 않는 이유: 이 스크립트가 의존성을 갖지 않게 하려고.
    # 표준 라이브러리만으로 충분합니다.
    boundary = "----june" + uuid.uuid4().hex
    crlf = b"\r\n"

    body = bytearray()

    def part_text(name: str, value: str) -> None:
        body.extend(f"--{boundary}".encode() + crlf)
        body.extend(
            f'Content-Disposition: form-data; name="{name}"'.encode() + crlf + crlf
        )
        body.extend(value.encode("utf-8") + crlf)

    # 메타데이터 — 요구사항의 세 가지(릴리스 ID, 커밋 SHA, ZIP SHA-256)
    part_text("app_id", APP_ID)
    part_text("release_id", rel_id)
    part_text("commit_sha", commit)
    part_text("zip_sha256", zip_sha)
    part_text("manifest_sha256",
              hashlib.sha256(
                  json.dumps(manifest, ensure_ascii=False,
                             separators=(",", ":")).encode("utf-8")
              ).hexdigest())

    # 파일
    body.extend(f"--{boundary}".encode() + crlf)
    body.extend(
        (f'Content-Disposition: form-data; name="package"; '
         f'filename="{zip_path.name}"').encode() + crlf
    )
    body.extend(b"Content-Type: application/zip" + crlf + crlf)
    body.extend(zip_path.read_bytes() + crlf)
    body.extend(f"--{boundary}--".encode() + crlf)

    req = urllib.request.Request(url, data=bytes(body), method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Accept", "application/json")
    # 자격증명은 헤더로. URL 쿼리에 넣으면 프록시·서버 로그에 남습니다.
    req.add_header("X-Submit-Id", sid)
    req.add_header("X-Submit-Token", token)

    ok(f"전송 준비 완료 ({len(body) / 1048576:.1f}MB)")
    warn("자격증명 값은 출력하지 않습니다")

    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            status = r.status
            raw = r.read()
    except urllib.error.HTTPError as e:
        code = e.code
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:200]
        except Exception:
            pass
        bad(f"HTTP {code}")
        if detail:
            print(f"     {detail}")
        return False, f"http_{code}", {}
    except Exception as e:
        bad(f"전송 실패: {type(e).__name__}")
        return False, f"error_{type(e).__name__}", {}

    if status not in (200, 201):
        bad(f"예상 밖 상태 코드: {status}")
        return False, f"status_{status}", {}

    try:
        resp = json.loads(raw.decode("utf-8"))
    except Exception:
        bad("응답이 JSON 이 아닙니다")
        return False, "bad_json", {}

    ok(f"HTTP {status}")
    return True, "ok", resp if isinstance(resp, dict) else {}


def verify_receipt(resp: dict, zip_sha: str, rel_id: str) -> tuple[bool, list[str]]:
    """서버 응답이 우리가 보낸 것과 일치하는가."""
    hdr("⑨ 접수 확인")

    problems: list[str] = []

    # ## 서버가 접수 ID 를 줬는가
    recv_id = (resp.get("receipt_id") or resp.get("id")
               or resp.get("submission_id") or "")
    if recv_id:
        ok(f"서버 접수 ID: {recv_id}")
    else:
        problems.append("서버가 접수 ID 를 주지 않았습니다")

    # ## 서버가 계산한 해시가 우리 것과 같은가
    # 이게 핵심입니다. 전송 중에 파일이 깨졌거나 다른 게 올라갔으면
    # 여기서 걸립니다. "OK 라는 응답을 받았다"는 것과 다릅니다.
    srv_sha = (resp.get("zip_sha256") or resp.get("sha256") or "").lower().strip()
    if srv_sha:
        if srv_sha == zip_sha.lower():
            ok(f"서버 계산 해시 일치 ({srv_sha[:32]}…)")
        else:
            problems.append(
                f"해시 불일치 — 우리 {zip_sha[:16]}… vs 서버 {srv_sha[:16]}…"
            )
    else:
        problems.append("서버가 해시를 돌려주지 않았습니다")

    # 릴리스 ID 도 확인
    srv_rel = (resp.get("release_id") or "").strip()
    if srv_rel:
        if srv_rel == rel_id:
            ok(f"릴리스 ID 일치: {srv_rel}")
        else:
            problems.append(f"릴리스 ID 불일치 — {rel_id} vs {srv_rel}")

    return (len(problems) == 0), problems


def write_receiver_spec(path: Path) -> None:
    """수신기 규격 초안. 확정 전이므로 '제안'임을 명시합니다."""
    path.write_text("""# 가비아 수신기 규격 (제안)

> ⚠️ **이 규격은 확정된 것이 아닙니다.**
> 가비아 공용 수신기 담당자와 합의해야 하는 **제안안**입니다.
> 실제 수신기가 이와 다르게 구현되면 `scripts/submit_gabia_direct.py` 의
> `upload()` 와 `verify_receipt()` 를 그 규격에 맞춰 고쳐야 합니다.

---

## 1. 엔드포인트

```
POST https://<호스트>/scheduler/upload
```

- **scheduler 전용 경로**를 씁니다. 다른 앱과 섞이지 않게 하기 위함입니다.
- **웹에서 접근할 수 없어야 합니다.** 공개 정적 경로(`/` 아래)에 두지 말고,
  서버 측에서 인증을 요구하는 경로로 두세요. 브라우저로 열면 401 이어야
  정상입니다.

---

## 2. 인증

헤더 두 개로 받습니다.

```
X-Submit-Id:    <제출자 식별자>
X-Submit-Token: <업로드 토큰>
```

- **쿼리스트링에 넣지 마세요.** 프록시·서버 access log 에 그대로 남습니다.
- 본문에 넣지도 마세요. multipart 파서가 실패 로그에 본문 일부를 남기는
  경우가 있습니다. 헤더가 가장 안전합니다.
- 서버는 토큰을 **해시로 저장**하고 비교 시 타이밍 안전 비교를 쓰세요.
- 최소 32바이트 무작위 값을 권장합니다.

---

## 3. 요청 본문 — `multipart/form-data`

| 필드 | 형식 | 설명 |
|---|---|---|
| `app_id` | text | 항상 `scheduler` |
| `release_id` | text | `rel-YYYYMMDD-HHMMSS-<sha7>` |
| `commit_sha` | text | 전체 40자 소스 커밋 |
| `zip_sha256` | text | 클라이언트가 계산한 ZIP 해시 |
| `manifest_sha256` | text | 매니페스트 JSON 의 해시 |
| `package` | file | `application/zip` |

---

## 4. 응답 — 200 또는 201

```json
{
  "ok": true,
  "receipt_id": "rcpt-20261120-0001",
  "release_id": "rel-20261120-123110-4c291f7",
  "zip_sha256": "<서버가 실제 수신 바이트로 계산한 해시>",
  "received_at": "2026-11-20T12:31:10Z"
}
```

### ⚠️ `zip_sha256` 은 서버가 **받은 바이트로 직접 계산**해야 합니다

클라이언트가 보낸 값을 그대로 되돌려주면 검증이 아닙니다. 그래야
전송 중 손상·절단을 잡을 수 있습니다. 이것이 "접수 확인"의 유일한 근거입니다.

---

## 5. 오류 응답

| 상태 | 의미 | 클라이언트 동작 |
|---|---|---|
| 400 | 형식 오류 | 재시도 무의미 — 보고 |
| 401 / 403 | 인증 실패 | 재시도 무의미 — 보고 |
| 409 | 같은 릴리스 ID 존재 | **덮어쓰지 않음** — 새 릴리스 ID 로 재시도 |
| 413 | 너무 큼 | 보고 |
| 5xx | 서버 오류 | 서버 담당자에게 보고 |

---

## 6. 중복 방지

- 릴리스 ID 는 `rel-<시각>-<커밋7>` 형식이며 제출마다 새로 만들어집니다.
- 서버는 같은 `release_id` 를 **덮어쓰지 말고 409 로 거절**하세요.
- 같은 `zip_sha256` 이 이미 있으면 409 로 거절해도 됩니다 (진짜 중복).

---

## 7. 받은 뒤 서버가 할 일 (참고)

이 도구가 하지 않는 일입니다. 서버 담당자 몫입니다.

1. ZIP 을 받아 `zip_sha256` 을 **직접 계산**하고 응답에 담기
2. 압축을 풀어 `manifest.json` 의 파일별 해시 검증
3. 통과한 것만 배포 후보로 승격
4. 반영은 **수동 승인** 후에 (자동 배포 금지)

---

## 8. 클라이언트가 하지 않는 일

- 자동 설치·실행·서비스 재시작
- 운영 서버 SSH 접속
- DNS·포워딩 변경
- 앱 배포

이 도구는 **보내고 접수를 확인하는 데서 멈춥니다.**
""", encoding="utf-8")


# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="가비아 직접 제출")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="환경·검사만")
    g.add_argument("--package", action="store_true", help="패키징까지")
    g.add_argument("--submit", action="store_true", help="전체 (업로드 포함)")
    ap.add_argument("--skip-build", action="store_true", help="빌드 건너뛰기")
    ap.add_argument("--spec", action="store_true", help="수신기 규격 초안 작성")
    args = ap.parse_args()

    if args.spec:
        p = PROJECT_DIR / "docs" / "GABIA-RECEIVER-SPEC.md"
        p.parent.mkdir(exist_ok=True)
        write_receiver_spec(p)
        ok(f"규격 초안: {p.relative_to(PROJECT_DIR)}")
        return 0

    rep = Report()
    creds = Creds()

    hdr("가비아 직접 제출")
    say(f"  개발 환경 전용 — 웹앱/브라우저에 포함되지 않습니다")
    say(f"  앱 ID: {APP_ID}")

    # ① 버전
    versions = check_versions(rep)

    # ② 빌드
    if not args.skip_build and not BUILD_DIR.exists():
        warn("build/web 이 없습니다 — 빌드를 시도합니다")
        try:
            r = subprocess.run(
                ["flutter", "build", "web", "--release", "--base-href", "/"],
                cwd=str(PROJECT_DIR), capture_output=True, text=True,
                timeout=900,
            )
            if r.returncode == 0:
                ok("빌드 완료")
            else:
                rep.fail("빌드 실패")
        except Exception as e:
            rep.fail(f"빌드 오류: {e}")

    build_info = check_build(rep)
    check_secrets(rep)
    test_info = check_tests(rep)

    commit = commit_sha()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    rel_id = f"rel-{stamp}-{commit[:7] if commit else 'nocommit'}"

    hdr("릴리스 식별")
    ok(f"릴리스 ID : {rel_id}")
    ok(f"커밋 SHA  : {commit or '(없음)'}")

    if not commit:
        rep.fail("커밋 SHA 를 읽을 수 없습니다")
        bad("커밋 SHA 없음")

    # ⑤ 수신기
    receiver_ready = check_receiver(creds, rep)

    # 결과 요약
    hdr("검사 결과")
    for w in rep.warnings:
        warn(w)

    if not rep.passed:
        say("")
        for f in rep.failures:
            bad(f)
        say("")
        bad("검사를 통과하지 못해 업로드하지 않습니다.")
        return 1

    ok("필수 검사 통과")

    if args.check:
        hdr("결과 — 패키지 준비")
        ok("검사 통과")
        if not receiver_ready:
            warn("자격증명이 없어 패키징·업로드는 하지 않았습니다")
        return 0

    # ⑥ 패키징
    res = build_zip(rep, versions, build_info, test_info, commit, rel_id)
    if res is None:
        hdr("결과")
        bad("패키징 실패 — ZIP 을 만들지 못했습니다")
        return 1

    zip_path, zip_info = res

    # 결과 파일 (자격증명 없음)
    result = {
        "app_id": APP_ID,
        "release_id": rel_id,
        "commit_sha": commit,
        "zip_file": zip_path.name,
        "zip_sha256": zip_info["sha256"],
        "zip_size": zip_info["size"],
        "zip_entries": zip_info["files"],
        "versions": versions,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "github_route": "CANCELLED (direct submission)",
        "gabia_transfer": "NOT_ATTEMPTED",
        "gabia_receipt": "UNCONFIRMED",
    }
    (OUT_DIR / "result.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    if args.package:
        hdr("결과 — 패키지 준비")
        ok(f"ZIP: dist/gabia-submit/{zip_path.name}")
        ok(f"SHA-256: {zip_info['sha256']}")
        if not receiver_ready:
            warn("자격증명이 없어 업로드는 하지 않았습니다")
        return 0

    # ⑧ 업로드 — 여기서부터는 --submit 일 때만
    if not args.submit:
        hdr("결과 — 패키지 준비")
        ok("패키징 완료")
        say("  업로드까지 하려면: --submit")
        return 0

    if not receiver_ready:
        hdr("결과")
        warn("패키지 준비 완료 / 가비아 전송 불가 / 접수 확인 불가")
        say("")
        say("  막힌 항목 — 자격증명이 설정되지 않았습니다:")
        for name in (ENV_URL, ENV_ID, ENV_TOKEN):
            if not os.environ.get(name, "").strip():
                say(f"    · {name}")
        say("")
        say("  이 값들은 실행 환경에만 넣으세요. ZIP·로그·채팅에 남기지 마세요.")
        return 2

    uploaded, msg, resp = upload(zip_path, zip_info["sha256"], rel_id,
                                 commit, zip_info["manifest"])

    if not uploaded:
        result["gabia_transfer"] = f"FAILED ({msg})"
        (OUT_DIR / "result.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8")
        hdr("결과")
        bad(f"가비아 전송 실패 ({msg})")
        say(f"  패키지는 남아 있습니다: dist/gabia-submit/{zip_path.name}")
        return 3

    ok("전송 완료")
    result["gabia_transfer"] = "SENT"

    # ⑨ 접수 확인
    receipt_ok, problems = verify_receipt(resp, zip_info["sha256"], rel_id)

    result["gabia_receipt"] = "CONFIRMED" if receipt_ok else "MISMATCH"
    result["server_response"] = {
        k: v for k, v in resp.items()
        if k.lower() not in ("token", "submit_token", "authorization")
    }
    (OUT_DIR / "result.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    hdr("결과")
    ok("패키지 준비")
    ok("가비아 전송")
    if receipt_ok:
        ok("가비아 접수 확인")
        say("")
        say(f"  릴리스 ID : {rel_id}")
        say(f"  커밋 SHA  : {commit}")
        say(f"  ZIP SHA   : {zip_info['sha256']}")
        say(f"  접수 ID   : {resp.get('receipt_id', '(없음)')}")
        return 0

    bad("가비아 접수 확인 실패")
    for p in problems:
        say(f"    · {p}")
    say("")
    say("  ※ 전송은 됐지만 접수가 확인되지 않았습니다. 완료로 보고하지 않습니다.")
    return 4


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
check_bundle_secrets.py 회귀 테스트.

## 왜 테스트가 필요한가

이 도구는 "빌드에 비밀이 샜는지"를 판정한다. 판정하는 도구가 조용히
고장나면, 아무것도 없다고 말하면서 통과시킨다. 그건 검사가 없는 것보다
나쁘다 — 있다고 믿게 만들기 때문이다.

그래서 여기서 고정하는 것은 두 가지다:

  1. **잡아야 할 것을 잡는가** — 진짜 누출을 놓치지 않는가
  2. **잡지 말아야 할 것을 놓아주는가** — 오탐으로 배포를 막지 않는가

특히 2번이 중요하다. 오탐이 잦은 게이트는 곧 무시되고, 무시되는 게이트는
없는 게이트다.

## 실행

    python3 scripts/test_check_bundle_secrets.py

## 이 테스트가 잡아낸 실제 버그 (기록)

  · 첫 버전은 DDNS 규칙을 정규식 `[a-z0-9][a-z0-9-]{2,}\\.(?:...)` 로
    처리했다. 3.8MB 한 줄 파일에서 재앙적 백트래킹으로 **38초**가 걸렸다.
    `test_속도` 가 이걸 잡았다. 지금은 bytes.find 기반이라 0.6초다.
  · 문자열 정규식을 bytes 에 적용해 TypeError 가 났다. 모든 테스트가
    한꺼번에 실패하면서 드러났다.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "check_bundle_secrets.py"
PROJECT_DIR = Path(__file__).resolve().parent.parent

passed = 0
failed = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global passed, failed
    if ok:
        passed += 1
        print(f"  [PASS] {label}")
    else:
        failed += 1
        print(f"  [FAIL] {label}")
        if detail:
            for line in detail.splitlines()[:8]:
                print(f"         {line}")


def run(build_dir: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--build-dir", str(build_dir), *args],
        capture_output=True, text=True, timeout=180, cwd=str(PROJECT_DIR),
    )


def make_bundle(files: dict[str, str]) -> Path:
    d = Path(tempfile.mkdtemp(prefix="bundle_"))
    for name, content in files.items():
        (d / name).write_text(content, encoding="utf-8")
    return d


# ─────────────────────────────────────────────────────────────────────────────
print("\n① 잡아야 할 것 — 진짜 누출")
# ─────────────────────────────────────────────────────────────────────────────

cases = [
    ("DDNS 주소", 'var u="https://nas7.direct.quickconnect.to/api";',
     "nas7.direct.quickconnect.to"),
    ("synology.me", 'var u="http://home.synology.me:5000";',
     "home.synology.me"),
    ("duckdns", 'var u="https://mynas.duckdns.org";', "mynas.duckdns.org"),
    ("64자 hex 키", 'x:"' + "a" * 64 + '"', "a" * 64),
    ("사설 IP", 'var u="http://192.168.1.50:8097";', "192.168.1.50"),
    ("10.x 사설 IP", 'var u="10.20.30.40";', "10.20.30.40"),
    ("GitHub 토큰", 'var t="ghp_' + "a" * 36 + '";', "ghp_" + "a" * 36),
    ("AWS 키", 'var k="AKIAIOSFODNN7EXAMPLE";', "AKIAIOSFODNN7EXAMPLE"),
]

for label, js, needle in cases:
    d = make_bundle({"main.dart.js": js})
    r = run(d, "--strict")
    caught = r.returncode == 1 and needle in r.stdout
    check(f"{label} 를 잡는다", caught,
          f"exit={r.returncode}\nstdout={r.stdout[:400]}")


# ─────────────────────────────────────────────────────────────────────────────
print("\n② 놓아야 할 것 — 오탐")
# ─────────────────────────────────────────────────────────────────────────────

# 'quickconnect.to' 는 회사명으로도 쓰인다. 라벨이 없으면 호스트가 아니다.
d = make_bundle({"main.dart.js": 'var s="Synology QuickConnect.to service";'})
r = run(d, "--strict")
check("맨 'quickconnect.to' (라벨 없음) 를 잡지 않는다", r.returncode == 0,
      f"exit={r.returncode}\nstdout={r.stdout[:400]}")

# 평범한 숫자 배열은 사설 IP 가 아니다
d = make_bundle({"main.dart.js": 'var a=[10,20,30,40];var b="1.2.3.4";'})
r = run(d, "--strict")
check("평범한 숫자/공인 IP 를 잡지 않는다", r.returncode == 0,
      f"exit={r.returncode}\nstdout={r.stdout[:400]}")

# 63자, 65자 hex 는 키가 아니다
d = make_bundle({"main.dart.js": 'x:"' + "a" * 63 + '";y:"' + "a" * 65 + '"'})
r = run(d, "--strict")
check("63자/65자 hex 를 잡지 않는다 (경계)", r.returncode == 0,
      f"exit={r.returncode}\nstdout={r.stdout[:400]}")

# 짧은 값은 자격증명이 아니다
d = make_bundle({"main.dart.js": 'var o={password:"short"};'})
r = run(d, "--strict")
check("6자 미만 password 는 잡지 않는다", r.returncode == 0,
      f"exit={r.returncode}\nstdout={r.stdout[:400]}")


# ─────────────────────────────────────────────────────────────────────────────
print("\n③ 허용 목록 — 숨기지 않고 통과시킨다")
# ─────────────────────────────────────────────────────────────────────────────

d = make_bundle({"main.dart.js": 'var u="https://ok.direct.quickconnect.to";'})
r = run(d, "--strict", "--allow", "ok.direct.quickconnect.to")
check("--allow 로 통과시킨다", r.returncode == 0,
      f"exit={r.returncode}\nstdout={r.stdout[:400]}")
check("허용해도 화면에는 보여준다", "허용" in r.stdout,
      f"stdout={r.stdout[:400]}")

# 알려진 무해값은 기본 허용 (UI 예시 주소)
d = make_bundle({"main.dart.js": 't="예: http://192.168.0.20:8099"'})
r = run(d, "--strict")
check("기본 허용값(192.168.0.20 UI 예시)은 통과", r.returncode == 0,
      f"exit={r.returncode}\nstdout={r.stdout[:400]}")


# ─────────────────────────────────────────────────────────────────────────────
print("\n④ 파일 처리 — 여러 파일, 없는 파일")
# ─────────────────────────────────────────────────────────────────────────────

d = make_bundle({
    "main.dart.js": "var a=1;",
    "version.json": '{"u":"https://v.direct.quickconnect.to"}',
})
r = run(d, "--strict")
check("main.dart.js 가 깨끗해도 version.json 을 검사한다",
      r.returncode == 1 and "v.direct.quickconnect.to" in r.stdout,
      f"exit={r.returncode}\nstdout={r.stdout[:400]}")

d = make_bundle({"unrelated.txt": "https://x.direct.quickconnect.to"})
r = run(d, "--strict")
# 대상 파일이 하나도 없으면 exit 2 다. 이건 "안전"이 아니라 "검사할 것이
# 없었다"는 뜻이고, 배포 게이트는 0 이 아니면 막는다. fail-closed 가 맞다 —
# 빌드에 main.dart.js 가 없다면 그건 정상적인 빌드가 아니다.
check("대상 목록에 없는 파일은 읽지 않는다 (검사 0건 → exit 2)",
      r.returncode == 2 and "x.direct.quickconnect.to" not in r.stdout,
      f"exit={r.returncode}\nstdout={r.stdout[:400]}")

r = run(Path("/tmp/definitely_does_not_exist_xyz"))
check("빌드 디렉터리가 없으면 exit 2", r.returncode == 2,
      f"exit={r.returncode}")

d = make_bundle({})
r = run(d, "--strict")
check("빈 디렉터리는 exit 2 (검사한 것이 없으므로)", r.returncode == 2,
      f"exit={r.returncode}")


# ─────────────────────────────────────────────────────────────────────────────
print("\n⑤ 깨진 입력에 죽지 않는다")
# ─────────────────────────────────────────────────────────────────────────────

d = Path(tempfile.mkdtemp(prefix="bundle_bin_"))
(d / "main.dart.js").write_bytes(
    b"var a=1;\xff\xfe\x00broken" + b"x" * 100 + b";var u=\"n.direct.quickconnect.to\";"
)
r = run(d, "--strict")
check("바이너리 쓰레기가 섞여도 죽지 않고 잡는다", r.returncode == 1,
      f"exit={r.returncode}\nstderr={r.stderr[:400]}")

d = Path(tempfile.mkdtemp(prefix="bundle_big_"))
(d / "main.dart.js").write_bytes(b"a" * (5 * 1024 * 1024))
r = run(d, "--strict")
check("5MB 파일을 처리한다", r.returncode == 0,
      f"exit={r.returncode}\nstderr={r.stderr[:400]}")


# ─────────────────────────────────────────────────────────────────────────────
print("\n⑥ 속도 — 게이트로 쓸 수 있는가")
# ─────────────────────────────────────────────────────────────────────────────

# 과거 회귀: DDNS 정규식이 백트래킹으로 38초 걸렸다.
# 3MB 한 줄 파일(실제 main.dart.js 규모)에서 2초 안에 끝나야 한다.
d = Path(tempfile.mkdtemp(prefix="bundle_perf_"))
big = ('var x=1,z="abcdefghijklmnopqrstuvwxyz0123456789";' * 65000)
(d / "main.dart.js").write_text(big + 'var u="t.direct.quickconnect.to";',
                                encoding="utf-8")
size_mb = (d / "main.dart.js").stat().st_size / 1048576
t0 = time.perf_counter()
r = run(d, "--strict")
dt = time.perf_counter() - t0
check(f"{size_mb:.1f}MB 한 줄 파일을 2초 안에 검사한다 (실측 {dt:.2f}s)",
      dt < 2.0 and r.returncode == 1,
      f"걸린 시간={dt:.2f}s exit={r.returncode}")

# 실제 빌드 산출물이 있으면 그것으로도 확인
real = PROJECT_DIR / "build" / "web" / "main.dart.js"
if real.is_file():
    t0 = time.perf_counter()
    r = run(PROJECT_DIR / "build" / "web")
    dt = time.perf_counter() - t0
    check(f"실제 빌드({real.stat().st_size / 1048576:.1f}MB)를 2초 안에 검사 "
          f"(실측 {dt:.2f}s)", dt < 2.0,
          f"걸린 시간={dt:.2f}s exit={r.returncode}")
else:
    print("  [SKIP] 실제 빌드 산출물 없음")


# ─────────────────────────────────────────────────────────────────────────────
print("\n" + "=" * 62)
total = passed + failed
print(f"  결과: {passed}/{total} 통과")
print("=" * 62)
sys.exit(0 if failed == 0 else 1)

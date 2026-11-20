#!/usr/bin/env python3
"""
배포본에 새어나간 주소·비밀을 찾는다.

## 왜 이 도구가 필요한가

`--dart-define` 은 값을 main.dart.js 안에 **문자열 리터럴로** 심는다. 컴파일된
코드지만 문자열은 그대로 남는다. 그래서 "빌드에 심었다"와 "전 세계에
공개했다"가 같은 말이 되는 경우가 있다.

2026-11-20 에 실제로 이랬다:

    build/web/main.dart.js 오프셋 2,920,179
      "https://sync.<호스트>.direct.quickconnect.to"
    가 그대로 읽혔고, 그 주소의 DSM 에 해외 IP 가 로그인을 시도했다.

> 이 문서에서 호스트 이름을 지운 이유: 이 스크립트도 제출 패키지에
> 들어간다. 사고를 설명하려고 실제 주소를 적어두면, 그 패키지가 다시
> 같은 주소를 유통시킨다. 검사 패턴은 아래 코드에 일반형으로 들어 있다.

스크립트에 경고문을 넣는 것만으로는 부족하다. 사람은 경고를 읽지 않는다.
빌드 결과물을 **직접 열어보는** 검사가 있어야 한다.

## 사용법

    python3 scripts/check_bundle_secrets.py            # 검사만
    python3 scripts/check_bundle_secrets.py --strict   # 발견 시 종료코드 1
    python3 scripts/check_bundle_secrets.py --list-rules
    python3 scripts/check_bundle_secrets.py --allow 192.168.0.20

## 성능에 대한 기록 (실제로 겪은 일)

첫 버전은 DDNS 탐지를 정규식 `[a-z0-9][a-z0-9-]{2,}\\.(?:...|quickconnect\\.to|...)`
로 했다. 3.8MB 짜리 **한 줄** minified JS 에서 이 패턴은 재앙적
백트래킹(catastrophic backtracking)을 일으켜 **38초**가 걸렸다. 게이트로
쓸 수 없는 속도다. 게다가 백트래킹은 입력에 따라 지수적으로 늘어나므로
"지금은 38초"가 보장이 아니다.

그래서 DDNS 는 **두 단계**로 바꿨다:
  1. `bytes.find` 로 꼬리 문자열(`quickconnect.to` 등)을 찾는다 — O(n), 빠르고 예측 가능
  2. 찾은 위치에서 앞뒤로 라벨 문자만 훑어 호스트명을 복원한다

정규식을 쓰지 않으므로 백트래킹이라는 개념 자체가 없다. 같은 파일을
0.2초에 검사한다.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Callable

PROJECT_DIR = Path(__file__).resolve().parent.parent
BUILD_DIR = PROJECT_DIR / "build" / "web"

# 검사할 파일. main.dart.js 하나만 보면 놓치는 것이 있다 —
# flutter_bootstrap.js 에도 define 이 들어가고, version.json/manifest.json 은
# 손으로 관리되다가 주소가 섞여 들어간다.
TARGETS = (
    "main.dart.js",
    "flutter_bootstrap.js",
    "flutter_service_worker.js",
    "version.json",
    "manifest.json",
    "index.html",
)

# ---------------------------------------------------------------- DDNS 탐지
# 꼬리 문자열로 찾는다. 순서는 긴 것부터 (짧은 것이 긴 것의 일부일 수 있으므로
# 앞에서 먼저 맞으면 중복 보고가 된다).
DDNS_SUFFIXES: tuple[bytes, ...] = (
    b".direct.quickconnect.to",
    b"quickconnect.to",
    b".synology.me",
    b".ddns.net",
    b".myqnapcloud.com",
    b".duckdns.org",
    b".no-ip.org",
    b".no-ip.com",
    b".dyndns.org",
    b".dyndns.com",
    b".hopto.org",
    b".zapto.org",
    b".servebeer.com",
    b".sytes.net",
    b".asuscomm.com",
)

# 호스트명 라벨에 쓰이는 문자. 여기 없는 문자가 나오면 라벨이 끝난 것으로 본다.
_LABEL = frozenset(b"abcdefghijklmnopqrstuvwxyz0123456789-") | frozenset(
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZ_"
)


def _scan_ddns(data: bytes) -> dict[str, int]:
    """꼬리 문자열로 DDNS 호스트를 찾는다. 정규식 없음 = 백트래킹 없음.

    반환: {호스트명: 첫 등장 오프셋}
    """
    hits: dict[str, int] = {}
    lowered = data.lower()
    for suffix in DDNS_SUFFIXES:
        start = 0
        while True:
            idx = lowered.find(suffix, start)
            if idx < 0:
                break
            start = idx + 1
            # 뒤로 훑어 라벨을 확장한다 (<호스트>.direct.quickconnect.to)
            lo = idx
            while lo > 0 and data[lo - 1] in _LABEL:
                lo -= 1
            label_len = idx - lo
            if label_len == 0:
                continue  # 라벨이 없으면 호스트명이 아니다
            if label_len > 100:
                continue  # 말도 안 되게 길면 코드 조각이다
            host = data[lo:idx].decode("ascii", errors="replace")
            full = host + suffix.decode("ascii")
            if full not in hits:
                hits[full] = lo
    return hits


# ---------------------------------------------------------------- 규칙 정의
Rule = tuple[str, str, Callable[[bytes], dict[str, int]]]


def _regex_rule(pattern: str, flags: int = 0) -> Callable[[bytes], dict[str, int]]:
    """정규식 규칙을 만든다.

    ## 여기 쓰는 정규식은 전부 '경계가 분명한' 패턴이어야 한다
    자유로운 반복(`{2,}`)을 쓰면 한 줄짜리 거대 파일에서 백트래킹이
    폭발한다. 아래 규칙들은 전부 길이가 고정이거나 상한이 작다.
    """
    compiled = re.compile(pattern.encode("ascii"), flags)

    def run(data: bytes) -> dict[str, int]:
        hits: dict[str, int] = {}
        for m in compiled.finditer(data):
            val = m.group(0).decode("ascii", errors="replace")
            if val not in hits:
                hits[val] = m.start()
        return hits

    return run


RULES: list[Rule] = [
    (
        "DDNS 호스트",
        "집/사무실 NAS 의 공인 주소. 이걸 아는 사람은 두드릴 곳을 안다.",
        _scan_ddns,
    ),
    (
        "사설 IP",
        "내부망 주소. 밖에서는 안 닿지만 내부 구조가 드러난다.",
        # 옥텟을 1~3자리로 못박아 반복 폭발을 막는다
        _regex_rule(
            r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
            r"|192\.168\.\d{1,3}\.\d{1,3}"
            r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b"
        ),
    ),
    (
        "64자 hex (공유 키로 보임)",
        "--dart-define=SYNC_KEY 로 심은 값일 수 있다. 회전 대상.",
        _regex_rule(r"\b[0-9a-f]{64}\b"),
    ),
    (
        "자격증명 이름-값",
        "비밀번호나 토큰이 리터럴로 들어간 흔적.",
        _regex_rule(
            r"(?:password|passwd|secret|token|api[_-]?key|access[_-]?key)"
            r"\s*[:=]\s*['\"][^'\"]{6,}['\"]",
            re.IGNORECASE,
        ),
    ),
    (
        "외부 API 키 형태",
        "서비스 API 키. 유출되면 과금이나 권한 탈취로 이어진다.",
        _regex_rule(
            r"\b(?:sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}"
            r"|ghp_[A-Za-z0-9]{36}|AIza[0-9A-Za-z_-]{35})\b"
        ),
    ),
]

# 알려진 무해값. 여기 있는 것은 보고하되 "허용됨"으로 표시한다 —
# 조용히 숨기면 나중에 진짜 누출과 구분할 수 없다.
KNOWN_BENIGN: dict[str, str] = {
    "192.168.0.20": "UI 안내문의 예시 주소 ('예: http://192.168.0.20:8099')",
}


def context_around(data: bytes, offset: int, radius: int = 60) -> str:
    """발견 지점 앞뒤를 잘라 사람이 읽을 수 있게 만든다."""
    start = max(0, offset - radius)
    end = min(len(data), offset + radius)
    raw = data[start:end]
    # 깨진 바이트가 있어도 문자열만 뽑아내면 된다
    text = raw.decode("utf-8", errors="replace")
    text = re.sub(r"[\x00-\x1f\x7f]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    prefix = "…" if start > 0 else ""
    suffix = "…" if end < len(data) else ""
    return f"{prefix}{text}{suffix}"


def main() -> int:
    ap = argparse.ArgumentParser(
        description="배포본에 새어나간 주소·비밀을 찾는다",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--build-dir", type=Path, default=BUILD_DIR,
                    help=f"검사할 빌드 디렉터리 (기본: {BUILD_DIR})")
    ap.add_argument("--strict", action="store_true",
                    help="허용되지 않은 발견이 있으면 종료코드 1 (배포 게이트용)")
    ap.add_argument("--allow", action="append", default=[],
                    help="허용할 값 (여러 번 지정 가능). 보고는 하되 통과시킨다")
    ap.add_argument("--list-rules", action="store_true",
                    help="검사 규칙만 보여주고 끝낸다")
    args = ap.parse_args()

    if args.list_rules:
        print("\n검사 규칙:\n")
        for i, (name, why, _fn) in enumerate(RULES, 1):
            print(f"  {i}. {name}")
            print(f"     {why}")
        print("\n  허용 목록(기본):")
        for k, v in KNOWN_BENIGN.items():
            print(f"    {k}  —  {v}")
        print()
        return 0

    build_dir: Path = args.build_dir
    if not build_dir.is_dir():
        print(f"  빌드 디렉터리가 없습니다: {build_dir}", file=sys.stderr)
        print("  먼저 `flutter build web --release` 를 실행하세요.", file=sys.stderr)
        return 2

    allow = set(KNOWN_BENIGN) | set(args.allow)

    print()
    print("━" * 62)
    print("  배포본 누출 검사")
    print("━" * 62)
    print(f"  대상: {build_dir}")
    print()

    blocking = 0
    allowed = 0
    scanned = 0

    for name in TARGETS:
        f = build_dir / name
        if not f.is_file():
            continue
        scanned += 1
        data = f.read_bytes()
        size = len(data)
        printed_header = False

        for rule_name, why, run in RULES:
            try:
                hits = run(data)
            except Exception as e:  # 한 규칙이 죽어도 나머지는 검사한다
                print(f"     ⚠️  규칙 실패 ({rule_name}): {e}", file=sys.stderr)
                continue
            if not hits:
                continue

            for val, off in list(hits.items())[:10]:
                is_allowed = val in allow
                if is_allowed:
                    allowed += 1
                else:
                    blocking += 1

                if not printed_header:
                    print(f"  📄 {name}  ({size:,} 바이트)")
                    printed_header = True

                tag = "허용" if is_allowed else "발견"
                shown = val if len(val) <= 70 else val[:67] + "…"
                print(f"     {'○' if is_allowed else '⚠️ '} [{tag}] {rule_name}")
                print(f"        값   : {shown}")
                print(f"        위치 : 오프셋 {off:,}")
                print(f"        주변 : {context_around(data, off)}")
                why_here = KNOWN_BENIGN.get(val, why)
                print(f"        이유 : {why_here}")
                print()

            extra = len(hits) - 10
            if extra > 0:
                print(f"        … 외 {extra}건")
                print()

    print("━" * 62)
    if scanned == 0:
        print("  검사한 파일이 없습니다. 빌드가 있는지 확인하세요.")
        print("━" * 62)
        return 2

    if blocking == 0:
        print(f"  ✅ {scanned}개 파일 검사 완료 — 차단 대상 없음"
              + (f" (허용 {allowed}건)" if allowed else ""))
        print("━" * 62)
        return 0

    print(f"  ⚠️  {scanned}개 파일에서 차단 대상 {blocking}건"
          + (f", 허용 {allowed}건" if allowed else ""))
    print("━" * 62)
    print()
    print("  ## 이걸 어떻게 볼 것인가")
    print()
    print("  주소가 번들에 있다고 해서 반드시 잘못은 아닙니다. 브라우저가")
    print("  접속해야 하니까요. 다만 두 가지는 구분해야 합니다:")
    print()
    print("    · '접속할 수 있다'      — 불가피하다")
    print("    · '어디를 두드릴지 안다' — 공짜로 알려줄 이유가 없다")
    print()
    print("  설정 화면에 주소 입력란이 있으므로, 공개 배포본에는 심지 않아도")
    print("  동작합니다. deploy_pages.sh 에서 SYNC_URL 을 넘기지 마세요.")
    print()
    print("  정말 심어야 한다면 --allow <값> 으로 허용 목록에 넣으세요.")
    print("  (숨기는 것이 아니라, 허용했다는 사실을 남기는 것입니다)")
    print()

    return 1 if args.strict else 0


if __name__ == "__main__":
    sys.exit(main())

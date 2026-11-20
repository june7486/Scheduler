#!/usr/bin/env python3
"""version.json 에 배포 식별자를 심습니다.

## 왜 필요한가

Flutter 가 만들어 주는 `version.json` 은 이런 모양입니다:

    {"app_name":"june_scheduler","version":"1.0.0","build_number":"1"}

여기에는 **"이 빌드가 언제 것인지"가 없습니다.** `version` 은 사람이
`pubspec.yaml` 에 적어둔 값이라 배포해도 그대로입니다. 그래서 앱이
"새 빌드가 떴나?"를 물으려고 이 파일을 읽으면, 몇 달 전 빌드든 오늘
빌드든 같은 답을 받습니다. 쓸모가 없습니다.

그래서 `build` 필드를 추가합니다. 값은 `--dart-define=BUILD_ID` 로 앱에
심은 것과 **같은 문자열**이어야 합니다. 같아야 비교가 성립합니다.

## 왜 스크립트로 분리했는가

배포 경로가 셋입니다 (GitHub Pages, 가비아 FTP, 가비아 Nginx). 셋 다
같은 규칙을 따라야 하는데, 각 배포 스크립트에 복사해 넣으면 하나는
고치고 하나는 잊습니다. 여기 한 곳에 두고 셋이 부르게 합니다.

## 사용법

    python3 scripts/write_version_json.py --build-id 2026.11.20.0851
    python3 scripts/write_version_json.py --build-id 2026.11.20.0851 \\
        --notes "반복 일정 버그 수정"

`--build-id` 를 생략하면 현재 시각으로 만듭니다. 그러면 앱에 심은
BUILD_ID 와 달라져서 "영원히 새 버전이 있다"고 나옵니다 — 그렇게
쓰지 마세요. 배포 스크립트는 반드시 같은 값을 넘깁니다.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_BUILD_DIR = PROJECT_DIR / "build" / "web"


def read_pubspec_version() -> tuple[str, str]:
    """pubspec.yaml 에서 version: 1.0.0+1 을 읽습니다."""
    pubspec = PROJECT_DIR / "pubspec.yaml"
    name = "june_scheduler"
    version = "1.0.0"
    build_number = "1"

    if not pubspec.exists():
        return version, build_number

    for line in pubspec.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("version:"):
            raw = line.split(":", 1)[1].strip().strip('"').strip("'")
            if "+" in raw:
                version, build_number = raw.split("+", 1)
            else:
                version = raw
            break
    return version, build_number


def main() -> int:
    ap = argparse.ArgumentParser(description="version.json 에 build 식별자 심기")
    ap.add_argument(
        "--build-id",
        default="",
        help="앱에 심은 BUILD_ID 와 같은 값. 생략하면 현재 시각",
    )
    ap.add_argument("--notes", default="", help="업데이트 팝업에 보여줄 짧은 설명")
    ap.add_argument(
        "--build-dir",
        default=str(DEFAULT_BUILD_DIR),
        help="build/web 경로",
    )
    args = ap.parse_args()

    build_dir = Path(args.build_dir)
    target = build_dir / "version.json"

    if not build_dir.exists():
        print(f"❌ 빌드 디렉터리가 없습니다: {build_dir}", file=sys.stderr)
        return 2

    build_id = args.build_id.strip()
    generated = False
    if not build_id:
        # 생략하면 현재 시각. 배포 스크립트가 이 경로를 쓰면 앱과 값이
        # 어긋나므로 경고합니다.
        build_id = datetime.now().strftime("%Y.%m.%d.%H%M")
        generated = True

    version, build_number = read_pubspec_version()

    # ## 기존 파일을 최대한 살립니다
    # Flutter 가 넣은 app_name, package_name 등을 지울 이유가 없습니다.
    # 읽어서 우리 필드만 더합니다.
    data: dict = {}
    if target.exists():
        try:
            loaded = json.loads(target.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                data = loaded
        except Exception:
            data = {}

    data.setdefault("app_name", "june_scheduler")
    data.setdefault("package_name", "june_scheduler")
    data["version"] = version
    data["build_number"] = build_number

    # 핵심 필드
    data["build"] = build_id
    data["built_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    if args.notes:
        data["notes"] = args.notes

    target.write_text(
        json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )

    print(f"   · version.json ← build={build_id}")
    if generated:
        print(
            "   ⚠️  --build-id 를 생략해 현재 시각을 썼습니다. "
            "앱에 심은 BUILD_ID 와 다르면 '영원히 새 버전' 증상이 납니다.",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())

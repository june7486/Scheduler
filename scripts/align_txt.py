#!/usr/bin/env python3
"""평문 보고서의 표 열을 표시폭 기준으로 정렬합니다.

## 왜 필요한가
보고서 원본은 사람이 손으로 띄어 쓴 평문입니다. 한글은 폭이 2, 영문은 1 이라
글자 수로 띄어 쓰면 PDF 에서 열이 어긋납니다. 실제로 그렇게 나왔습니다.

  노출된 동기화 키 값       0건
  사설 키 헤더 문자열      0건      ← 값이 한 칸씩 밀립니다

## 하는 일
들여쓰기 2칸 이상으로 시작하고 "라벨 + 구분 + 값" 구조인 줄을 묶어, 블록 안의
최대 라벨 폭에 맞춰 구분 위치를 다시 계산합니다. 그 밖의 줄은 손대지 않습니다.

구분자는 두 가지를 모두 인정합니다.
  "  라벨 : 값"     ← 콜론 앞뒤 공백
  "  라벨      값"  ← 공백 2칸 이상

표 머리글 아래에 점선(-----) 구분행이 있으면, 머리글·점선·데이터를 한 블록으로
보고 같은 폭으로 맞춥니다. 그래야 머리글과 값의 열이 일치합니다.
"""
import re
import sys
import unicodedata
from pathlib import Path

# 들여쓰기(2칸+) + 라벨 + 구분(콜론 또는 공백 2칸+) + 값
ROW_RE = re.compile(r"^(\s{2,})(.+?)(\s+:\s+|\s{2,})(\S.*)$")


def dwidth(s: str) -> int:
    """표시폭. 동아시아 전각(W/F)은 2칸으로 셉니다."""
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def is_rule(line: str) -> bool:
    """점선 구분행인가. 두 개의 점선 묶음을 공백으로 이은 형태도 포함합니다."""
    s = line.strip()
    return bool(s) and set(s) <= set("- ")


def parse_row(line: str):
    m = ROW_RE.match(line.rstrip())
    if not m:
        return None
    indent, label, sep, value = m.groups()
    label = label.strip()
    value = value.strip()
    if not label or not value:
        return None
    return len(indent), label, ":" in sep, value


def main() -> None:
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src
    lines = src.read_text(encoding="utf-8").splitlines()

    out = []
    i = 0
    n = len(lines)
    while i < n:
        row = parse_row(lines[i])
        if row is None:
            out.append(lines[i])
            i += 1
            continue

        indent = row[0]
        block = []
        while i < n:
            r = parse_row(lines[i])
            if r is None or r[0] != indent:
                break
            block.append(r)
            i += 1

        # 표 머리글 + 점선 + 데이터를 한 덩어리로 처리합니다.
        has_rule = i < n and is_rule(lines[i])
        if has_rule:
            i += 1
            while i < n:
                r = parse_row(lines[i])
                if r is None or r[0] != indent:
                    break
                block.append(r)
                i += 1

        if len(block) < 2 and not has_rule:
            # 정렬할 대상이 없는 한 줄은 원문 그대로 둡니다.
            out.append(lines[i - len(block)])
            continue

        pad = max(dwidth(lbl) for _, lbl, _, _ in block) + 1
        for idx, (_, label, has_colon, value) in enumerate(block):
            gap = " " * (pad - dwidth(label))
            out.append(" " * indent + label + gap
                       + (": " if has_colon else "  ") + value)
            # 머리글 바로 뒤에 점선을 같은 위치에 다시 그립니다
            if has_rule and idx == 0:
                out.append(" " * indent + "-" * (pad - 1) + "  "
                           + "-" * max(len(value), 8))

    dst.write_text("\n".join(out) + "\n", encoding="utf-8")
    changed = sum(1 for a, b in zip(lines, out) if a != b)
    print(f"정렬: {src.name} → {dst.name} ({len(lines)}줄, {changed}줄 변경)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Flutter web 빌드 경량화 스크립트 (June's Scheduler)

1) 손글씨 폰트(Gaegu 2종 + NanumPen)를 woff2 서브셋으로 교체
   - 각 폰트의 '전체 한글 음절'은 그대로 유지 → 커버리지 손실 없음
   - 레이아웃 테이블(GSUB/GPOS/GDEF) 제거 (손글씨 렌더링엔 불필요)
   - 웹 브라우저는 폰트 포맷을 내용으로 자동 인식하므로 .ttf 이름 유지 OK
   - 결과: 약 9MB → 약 1.3MB
2) 런타임에 절대 쓰이지 않는 대용량 파일 삭제
   - skwasm*(wasm 외 빌드), *.symbols(디버그 심볼)
"""
import os
import sys
import glob

BUILD = "/home/user/flutter_app/build/web"
SRC_FONTS = "/home/user/flutter_app/assets/fonts"
FONT_TARGET = os.path.join(BUILD, "assets", "assets", "fonts")

FONT_FILES = [
    "Gaegu-Regular.ttf",
    "Gaegu-Bold.ttf",
    "NanumPenScript-Regular.ttf",
]


def build_charset(font_path):
    """해당 폰트가 가진 전체 한글 음절 + 기본 문자 집합."""
    from fontTools.ttLib import TTFont

    t = TTFont(font_path, lazy=True)
    cmap = t.getBestCmap()
    keep = set()
    for c in cmap:
        if 0xAC00 <= c <= 0xD7A3:          # 한글 음절(가~힣)
            keep.add(chr(c))
    keep |= set(chr(c) for c in range(0x20, 0x7F))       # ASCII
    keep |= set(chr(c) for c in range(0x3130, 0x3190))   # 호환 자모
    keep |= set(chr(c) for c in range(0x3000, 0x303F))   # CJK 기호
    keep |= set(chr(c) for c in range(0xFF00, 0xFFEF))   # 전각
    keep |= set("…—–·‘’“”《》〈〉→←↑↓★☆○●□■△▲※✓✔€₩°±×÷")
    return "".join(sorted(keep))


def subset_font_to_woff2(src, dst):
    from fontTools import subset

    charset = build_charset(src)
    opts = subset.Options()
    opts.flavor = "woff2"
    opts.desubroutinize = True
    opts.drop_tables += ["GSUB", "GPOS", "GDEF", "BASE", "JSTF"]
    font = subset.load_font(src, opts)
    s = subset.Subsetter(options=opts)
    s.populate(text=charset)
    s.subset(font)
    subset.save_font(font, dst, opts)
    font.close()


def main():
    if not os.path.isdir(FONT_TARGET):
        print(f"  ⚠️  폰트 경로 없음: {FONT_TARGET}")
        return 1

    print("  · 손글씨 폰트 woff2 서브셋 교체")
    saved = 0
    for name in FONT_FILES:
        src = os.path.join(SRC_FONTS, name)
        dst = os.path.join(FONT_TARGET, name)   # 같은 파일명 유지
        if not os.path.exists(src):
            print(f"      (건너뜀) {name} 원본 없음")
            continue
        old = os.path.getsize(dst) if os.path.exists(dst) else 0
        subset_font_to_woff2(src, dst)
        new = os.path.getsize(dst)
        saved += max(0, old - new)
        print(f"      {name:34s} {old//1024:5d}KB → {new//1024:4d}KB")

    print("  · 불필요 대용량 파일 정리")
    patterns = [
        os.path.join(BUILD, "canvaskit", "skwasm*.wasm"),
        os.path.join(BUILD, "canvaskit", "skwasm*.js"),
        os.path.join(BUILD, "canvaskit", "skwasm*.js.symbols"),
        os.path.join(BUILD, "canvaskit", "canvaskit.js.symbols"),
        os.path.join(BUILD, "canvaskit", "chromium", "canvaskit.js.symbols"),
    ]
    for pat in patterns:
        for f in glob.glob(pat):
            try:
                removed = os.path.getsize(f)
                os.remove(f)
                saved += removed
                print(f"      삭제 {os.path.relpath(f, BUILD)} ({removed//1024}KB)")
            except OSError:
                pass

    print(f"  ✅ 총 절감: 약 {saved//1024//1024}MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())

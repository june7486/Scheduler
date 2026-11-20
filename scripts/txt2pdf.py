#!/usr/bin/env python3
"""텍스트 보고서를 PDF 로 변환합니다 (한글 지원).

## 왜 직접 만드는가
이 환경에 pandoc·wkhtmltopdf·weasyprint 가 없습니다. reportlab 만 있습니다.
reportlab 기본 폰트(Helvetica)는 한글을 못 그려서 빈 네모가 됩니다.
나눔고딕 TTF 를 등록해서 씁니다.

## 구조 해석
원본 .txt 는 구분선(==== / ----)으로 섹션을 나눈 평문입니다.
그 규칙을 그대로 읽어 제목/소제목/본문으로 나눕니다.
원본을 고치지 않고 읽기만 합니다.
"""

import sys
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, Frame, PageTemplate,
                                Paragraph, Preformatted, Spacer)

FONT_DIR = Path("/usr/share/fonts/truetype/nanum")
FONT_R = FONT_DIR / "NanumGothic.ttf"
FONT_B = FONT_DIR / "NanumGothicBold.ttf"
# 고정폭 블록 전용. 나눔고딕은 비례폭이라 표의 열이 어긋납니다.
# 나눔고딕코딩은 한글·영문 모두 고정폭이어서 열 맞춤이 됩니다.
FONT_M = FONT_DIR / "NanumGothicCoding.ttf"
FONT_MB = FONT_DIR / "NanumGothicCodingBold.ttf"

EQ = "=" * 80
DASH = "-" * 80


def register_fonts() -> None:
    if not FONT_R.exists():
        sys.exit(f"한글 폰트가 없습니다: {FONT_R}")
    pdfmetrics.registerFont(TTFont("Nanum", str(FONT_R)))
    # 고정폭 폰트가 없으면 비례폭으로 대체합니다 (열은 어긋나지만 글자는 나옵니다).
    mono = FONT_M if FONT_M.exists() else FONT_R
    mono_b = FONT_MB if FONT_MB.exists() else mono
    pdfmetrics.registerFont(TTFont("NanumMono", str(mono)))
    pdfmetrics.registerFont(TTFont("NanumMonoB", str(mono_b)))
    pdfmetrics.registerFontFamily("NanumMono", normal="NanumMono",
                                  bold="NanumMonoB", italic="NanumMono",
                                  boldItalic="NanumMonoB")
    if not FONT_M.exists():
        print(f"경고: 고정폭 폰트가 없어 비례폭으로 대체합니다: {FONT_M}")
    if FONT_B.exists():
        pdfmetrics.registerFont(TTFont("NanumB", str(FONT_B)))
        pdfmetrics.registerFontFamily("Nanum", normal="Nanum",
                                      bold="NanumB", italic="Nanum",
                                      boldItalic="NanumB")
    else:
        # 굵은 폰트가 없으면 같은 폰트로 대체 (깨지는 것보다 낫습니다)
        pdfmetrics.registerFontFamily("Nanum", normal="Nanum", bold="Nanum",
                                      italic="Nanum", boldItalic="Nanum")


def styles() -> dict:
    return {
        "title": ParagraphStyle(
            "title", fontName="NanumB", fontSize=17, leading=24,
            spaceAfter=4, textColor=colors.HexColor("#111111")),
        "sub": ParagraphStyle(
            "sub", fontName="Nanum", fontSize=9.5, leading=15,
            textColor=colors.HexColor("#444444")),
        "h1": ParagraphStyle(
            "h1", fontName="NanumB", fontSize=12.5, leading=19,
            spaceBefore=13, spaceAfter=5,
            textColor=colors.HexColor("#ffffff"),
            backColor=colors.HexColor("#33415c"),
            borderPadding=(5, 6, 5, 6), leftIndent=0),
        "h2": ParagraphStyle(
            "h2", fontName="NanumB", fontSize=10.5, leading=16,
            spaceBefore=9, spaceAfter=3,
            textColor=colors.HexColor("#33415c")),
        "body": ParagraphStyle(
            "body", fontName="Nanum", fontSize=9.2, leading=14.6,
            alignment=TA_LEFT, textColor=colors.HexColor("#1a1a1a")),
        "mono": ParagraphStyle(
            "mono", fontName="NanumMono", fontSize=8.4, leading=12.4,
            textColor=colors.HexColor("#1a1a1a")),
        "mono_small": ParagraphStyle(
            "mono_small", fontName="NanumMono", fontSize=8.2, leading=12.6,
            textColor=colors.HexColor("#333333")),
    }


def esc(t: str) -> str:
    """XML 이스케이프. 원본에 & < > 가 들어 있어 Paragraph 가 깨집니다."""
    return (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def build(src: Path, out: Path) -> None:
    register_fonts()
    st = styles()
    raw = src.read_text(encoding="utf-8").splitlines()
    n_total = len(raw)

    def is_eq(s: str) -> bool:
        return len(s) >= 20 and set(s) == {"="}

    def is_dash(s: str) -> bool:
        return len(s) >= 20 and set(s) == {"-"}

    story = []
    i = 0

    # ------------------------------------------------------------------
    # 표지 — 첫 두 줄 (==== 와 그 안의 제목)
    # ------------------------------------------------------------------
    if raw and is_eq(raw[0]):
        j = 1
        while j < n_total and not is_eq(raw[j]):
            t = raw[j].strip()
            if t:
                story.append(Paragraph(esc(t), st["title"]))
            j += 1
        story.append(Spacer(1, 7))

        # 표지 닫는 ==== 다음, 다음 ==== 전까지가 서지정보입니다.
        #
        # ## 여기서 한 번 틀렸습니다
        # 처음엔 "다음 ---- 까지"를 서지정보로 봤습니다. 그런데 이 문서는
        # 섹션 구분을 ==== 로 하고 ---- 는 거의 안 씁니다. 그래서 서지정보
        # 루프가 "1. 요약" 제목과 본문까지 삼켜버렸습니다.
        # 종료 지점은 ==== 하나로 못 박는 게 맞습니다.
        j += 1
        while j < n_total and not is_eq(raw[j]):
            t = raw[j].rstrip()
            if not t.strip():
                story.append(Spacer(1, 2))
            elif len(t) - len(t.lstrip()) >= 2:
                story.append(Preformatted(t, st["mono_small"]))
            else:
                story.append(Paragraph(esc(t.strip()), st["sub"]))
            j += 1
        i = j

    # ------------------------------------------------------------------
    # 본문
    # ------------------------------------------------------------------
    while i < n_total:
        line = raw[i]

        # ==== / 제목 / ====  → 섹션 제목
        if is_eq(line):
            j = i + 1
            title = ""
            while j < n_total and not is_eq(raw[j]):
                if raw[j].strip():
                    title = raw[j].strip()
                j += 1
            if title:
                story.append(Spacer(1, 9))
                story.append(Paragraph(esc(title), st["h1"]))
                story.append(Spacer(1, 5))
            i = j + 1
            continue

        # ---- 를 구분선으로만 쓰는 경우 (제목 없음)
        if is_dash(line):
            # 다음 줄도 ---- 이면 중복이므로 건너뜀
            i += 1
            continue

        s = line.strip()
        if not s:
            story.append(Spacer(1, 2.5))
            i += 1
            continue

        # [x-y] 소제목
        if s.startswith("[") and "]" in s and len(s) < 64:
            story.append(Paragraph(esc(s), st["h2"]))
            i += 1
            continue

        # 들여쓰기 큰 줄 → 고정폭
        indent = len(line) - len(line.lstrip())
        if indent >= 2:
            story.append(Preformatted(line.rstrip(), st["mono"]))
        else:
            story.append(Paragraph(esc(s), st["body"]))
        i += 1

    doc = BaseDocTemplate(
        str(out), pagesize=A4,
        leftMargin=18 * mm, rightMargin=16 * mm,
        topMargin=16 * mm, bottomMargin=16 * mm,
        title=src.stem, author="June's Scheduler",
        subject="작업 보고서")

    frame = Frame(doc.leftMargin, doc.bottomMargin,
                  doc.width, doc.height, id="f")

    def footer(canv, d):
        canv.saveState()
        canv.setFont("Nanum", 7.6)
        canv.setFillColor(colors.HexColor("#777777"))
        canv.drawString(doc.leftMargin, 10 * mm,
                        "June's Scheduler — 작업 보고서 (2026-11-20)")
        canv.drawRightString(A4[0] - doc.rightMargin, 10 * mm,
                             f"{d.page} 쪽")
        canv.setStrokeColor(colors.HexColor("#cccccc"))
        canv.setLineWidth(0.4)
        canv.line(doc.leftMargin, 13 * mm,
                  A4[0] - doc.rightMargin, 13 * mm)
        canv.restoreState()

    doc.addPageTemplates([PageTemplate(id="all", frames=[frame],
                                       onPage=footer)])
    doc.build(story)
    print(f"생성: {out} ({out.stat().st_size:,}B)")


if __name__ == "__main__":
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".pdf")
    if not src.exists():
        sys.exit(f"원본이 없습니다: {src}")
    build(src, out)

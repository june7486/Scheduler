#!/usr/bin/env python3
"""스케줄러 전용 배포 게이트 — 승인된 커밋·산출물만 전환을 허용합니다.

## 왜 필요한가
"Git push 로 운영이 바뀌면 안 된다"는 요구는 설정 한 줄로 되는 일이 아닙니다.
운영을 바꾸는 **유일한 입구**가 승인 기록을 요구하도록 만들어야 합니다.
이 스크립트가 그 입구입니다.

    git push  ──→  (아무 일도 없음)
    ZIP 도착  ──→  deploy-gate.py  ──→  private-start.sh  ──→  cutover

## 두 겹의 자물쇠
  1. **서명** — 승인 기록은 검증 주체의 Ed25519 개인키로 서명되어야 합니다.
     서명이 없거나 맞지 않으면 내용을 읽지도 않습니다. 승인 JSON 을 손으로
     고쳐 커밋·해시를 바꾸는 우회로가 여기서 막힙니다.
  2. **고정 목록** — 서명이 유효해도 배포 금지 커밋이면 거부합니다.
     검증 주체가 실수로 결함 커밋을 승인해도 나가지 않습니다.

## 승인 기록 (approval.json) + 서명 (approval.json.sig)
검증 주체가 발급합니다.

    {
      "app": "scheduler",
      "approved": true,
      "commit_full": "<40자리>",
      "artifact_sha256": "<64자리>",
      "artifact_bytes": <정수>,
      "version": "2.0.0",
      "verifier": "<검증 주체>",
      "approved_at": "<ISO8601>",
      "note": "..."
    }

서명 대상은 **파일의 바이트 그대로**입니다 (정규화 없음 — 해석 차이를 없애기 위해).

    openssl pkeyutl -sign -inkey verifier.key -rawin \\
        -in approval.json -out approval.json.sig

## 신뢰 공개키 (ops/verifier-keys.json)
    {
      "app": "scheduler",
      "verifiers": [
        {"name": "배포센터 검증 러너", "key_id": "3057A14449EFC470",
         "public_key": "MCowBQYDK2VwAyEA..."}
      ]
    }

목록이 비어 있으면 **전부 거부**합니다 (fail-closed). 공개키를 넣는 일은
검증 주체만 할 수 있고, 개인키는 이 저장소에 들어오지 않습니다.

## 사용
    python3 ops/deploy-gate.py --zip <zip> --approval <approval.json>
    python3 ops/deploy-gate.py --zip <zip> --approval <approval.json> --json
    python3 ops/deploy-gate.py --print-keyid <pubkey.pem|base64>

종료코드 0 = 전환 허용, 1 = 전환 금지.
"""

import argparse
import base64
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

# ── 배포 금지 커밋 ────────────────────────────────────────────────
# 앱 결함이 남아 있는 산출물입니다. 서명된 승인 기록이 있어도 전환하지 않습니다.
BLOCKED = {
    "40777e66f2e13b127d07b59f94644346298f8ccc":
        "앱 결함 잔존 — 수정 릴리스로 대체되어야 합니다 (2026-11-24 지시)",
}

DEFAULT_TRUST = Path(__file__).resolve().parent / "verifier-keys.json"

FORBIDDEN_ENTRY = re.compile(
    r"(^|/)\.env$|(^|/)data/|node_modules/|\.key$|\.pem$|id_rsa|(^|/)CNAME$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")

REQUIRED_FILES = (
    "build/web/index.html",
    "build/web/version.json",
    "server/gateway/server.js",
)


class Gate:
    def __init__(self, as_json: bool = False):
        self.oks = []
        self.fails = []
        self.as_json = as_json

    def ok(self, msg):
        self.oks.append(msg)

    def fail(self, msg):
        self.fails.append(msg)

    def report(self):
        if self.as_json:
            print(json.dumps({
                "pass": not self.fails,
                "checks": self.oks,
                "failures": self.fails,
            }, ensure_ascii=False, indent=2))
        else:
            for m in self.oks:
                print(f"  \033[32mOK  \033[0m {m}")
            for m in self.fails:
                print(f"  \033[31mFAIL\033[0m {m}")
        return 0 if not self.fails else 1


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


# ── Ed25519 공개키 ────────────────────────────────────────────────
def key_id_of(spki_der: bytes) -> str:
    """공개키 지문 — DER(SPKI) 바이트의 SHA-256 앞 16자리(대문자)."""
    return hashlib.sha256(spki_der).hexdigest()[:16].upper()


def load_public_key(text: str):
    """base64(DER SPKI) 또는 PEM 문자열 → 공개키 객체. 실패하면 None."""
    from cryptography.hazmat.primitives.serialization import (
        load_der_public_key, load_pem_public_key)

    t = text.strip()
    if "BEGIN PUBLIC KEY" in t:
        try:
            return load_pem_public_key(t.encode())
        except Exception:
            return None
    try:
        return load_der_public_key(base64.b64decode("".join(t.split()), validate=True))
    except Exception:
        return None


def spki_of(pub) -> bytes:
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    return pub.public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)


def load_trust(path: Path, g: Gate):
    """신뢰 목록을 읽어 [(name, key_id, pub)] 로 돌려줍니다. 실패 시 []."""
    if not path.is_file():
        g.fail(f"신뢰 공개키 목록 없음: {path} — "
               "검증 주체 공개키가 등록되기 전에는 전환할 수 없습니다")
        return []

    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        g.fail(f"신뢰 목록을 읽을 수 없음: {e}")
        return []

    if doc.get("app") != "scheduler":
        g.fail(f"신뢰 목록의 app 이 scheduler 가 아님: {doc.get('app')!r}")

    out = []
    for v in doc.get("verifiers") or []:
        name = str(v.get("name") or "?")
        pub = load_public_key(str(v.get("public_key") or ""))
        if pub is None:
            g.fail(f"신뢰 공개키 해석 실패: {name}")
            continue
        real = key_id_of(spki_of(pub))
        declared = str(v.get("key_id") or "").strip().upper()
        if declared and declared != real:
            # 선언된 지문과 실제 키가 다르면 어느 쪽이 진짜인지 알 수 없습니다.
            g.fail(f"신뢰 공개키 지문 불일치: {name} — 선언 {declared} / 실제 {real}")
            continue
        out.append((name, real, pub))

    if not out:
        g.fail("신뢰 공개키가 하나도 등록되지 않았습니다 (fail-closed) — 전환 거부")
    return out


def verify_approval(ap_path: Path, raw: bytes, trust, g: Gate) -> bool:
    """approval.json.sig 를 신뢰 목록의 키로 검증합니다."""
    sig_path = ap_path.with_name(ap_path.name + ".sig")
    if not sig_path.is_file():
        g.fail(f"승인 서명 없음: {sig_path.name} — 서명되지 않은 승인은 받지 않습니다")
        return False

    try:
        sig = sig_path.read_bytes()
    except Exception as e:
        g.fail(f"승인 서명을 읽을 수 없음: {e}")
        return False

    if len(sig) != 64:
        g.fail(f"승인 서명 길이가 Ed25519 가 아님: {len(sig)} bytes (64 이어야 함)")
        return False

    for name, kid, pub in trust:
        try:
            pub.verify(sig, raw)
        except Exception:
            continue
        else:
            g.ok(f"승인 서명 검증 — 서명자 『{name}』 (키 {kid})")
            return True

    g.fail("승인 서명 검증 실패 — 신뢰 목록의 어떤 키로도 서명이 맞지 않습니다")
    return False


# ── ZIP 검사 ─────────────────────────────────────────────────────
def check_zip(zp: Path, a_commit: str, a_ver: str, g: Gate):
    try:
        with zipfile.ZipFile(zp) as z:
            names = z.namelist()

            def read(name):
                try:
                    return z.read(name).decode("utf-8", "replace")
                except KeyError:
                    return ""

            dc = read("DEPLOYED_COMMIT.txt")
            m = re.search(r"commit_full=([0-9a-f]{40})", dc)
            if not m:
                g.fail("ZIP 에 DEPLOYED_COMMIT.txt 의 commit_full 이 없습니다")
            elif m.group(1) != a_commit:
                g.fail(f"ZIP 내부 커밋 불일치 — 승인 {a_commit[:12]}… / ZIP {m.group(1)[:12]}…")
            else:
                g.ok(f"ZIP 내부 커밋 일치 {m.group(1)[:12]}…")

            vj = read("build/web/version.json")
            if not vj:
                g.fail("ZIP 에 build/web/version.json 이 없습니다")
            else:
                try:
                    v = json.loads(vj)
                except Exception:
                    v = {}
                if str(v.get("version", "")) != a_ver:
                    g.fail(f"ZIP 버전 불일치 — 승인 {a_ver!r} / ZIP {v.get('version')!r}")
                else:
                    g.ok(f"ZIP 버전 일치 {a_ver}")

            bad = sorted({n for n in names if FORBIDDEN_ENTRY.search(n)})
            if bad:
                g.fail("ZIP 에 있으면 안 되는 항목: " + ", ".join(bad[:5]))
            else:
                g.ok("운영자료·비밀값·개인키 없음")

            missing = [r for r in REQUIRED_FILES if r not in names]
            if missing:
                for r in missing:
                    g.fail(f"필수 파일 없음: {r}")
            else:
                g.ok(f"필수 파일 존재 ({len(REQUIRED_FILES)}종)")
    except zipfile.BadZipFile:
        g.fail("ZIP 이 손상되었습니다")


# ── 본체 ─────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(
        description="스케줄러 전환 전제 조건 게이트 (서명된 승인 + 산출물 실물 대조)")
    ap.add_argument("--zip", help="전환할 산출물 ZIP")
    ap.add_argument("--approval", help="검증 주체가 서명한 approval.json")
    ap.add_argument("--trust", default=str(DEFAULT_TRUST),
                    help=f"신뢰 공개키 목록 (기본 {DEFAULT_TRUST.name})")
    ap.add_argument("--json", action="store_true", help="기계 판독용 JSON 출력")
    ap.add_argument("--print-keyid", metavar="PUBKEY",
                    help="공개키 파일의 키 ID(지문)를 출력하고 끝냅니다")
    a = ap.parse_args()

    # ── 지문 계산 도우미 ────────────────────────────────────────
    if a.print_keyid:
        txt = Path(a.print_keyid).read_text(encoding="utf-8", errors="replace")
        pub = load_public_key(txt)
        if pub is None:
            print("공개키를 해석할 수 없습니다", file=sys.stderr)
            return 1
        print(key_id_of(spki_of(pub)))
        return 0

    if not a.zip or not a.approval:
        ap.error("--zip 과 --approval 이 필요합니다")

    g = Gate(a.json)
    zp = Path(a.zip)
    ap_path = Path(a.approval)

    # ── 1. 입력 존재 ────────────────────────────────────────────
    if not zp.is_file():
        g.fail(f"ZIP 없음: {zp}")
        return g.report()
    g.ok(f"ZIP 존재: {zp.name}")

    if not ap_path.is_file():
        g.fail(f"승인 기록 없음: {ap_path} — 검증 주체의 approval.json 이 필요합니다")
        return g.report()

    raw = ap_path.read_bytes()
    try:
        av = json.loads(raw.decode("utf-8"))
    except Exception as e:
        g.fail(f"승인 기록을 읽을 수 없음: {e}")
        return g.report()
    g.ok("승인 기록 파싱")

    # ── 2. 서명 (내용을 믿기 전에 먼저) ─────────────────────────
    trust = load_trust(Path(a.trust), g)
    if trust and not verify_approval(ap_path, raw, trust, g):
        return g.report()
    if g.fails:
        return g.report()

    # ── 3. 승인 자체의 형식 ────────────────────────────────────
    if av.get("app") != "scheduler":
        g.fail(f"승인 대상 앱이 scheduler 가 아님: {av.get('app')!r}")
    if av.get("approved") is not True:
        g.fail("approved 가 true 가 아님 — 승인되지 않은 릴리스입니다")

    a_commit = str(av.get("commit_full", "")).strip().lower()
    a_sha = str(av.get("artifact_sha256", "")).strip().lower()
    a_bytes = av.get("artifact_bytes")
    a_ver = str(av.get("version", "")).strip()

    if not HEX40.match(a_commit):
        g.fail(f"승인 커밋이 40자리 hex 가 아님: {a_commit!r}")
    if not HEX64.match(a_sha):
        g.fail(f"승인 SHA-256 이 64자리 hex 가 아님: {a_sha!r}")
    if not isinstance(a_bytes, int) or isinstance(a_bytes, bool) or a_bytes <= 0:
        g.fail(f"승인 artifact_bytes 가 양의 정수가 아님: {a_bytes!r}")
    if not a_ver:
        g.fail("승인 version 이 비었습니다")
    if g.fails:
        return g.report()
    g.ok(f"승인 커밋  {a_commit[:12]}…")
    g.ok(f"승인 SHA   {a_sha[:16]}…")
    g.ok(f"승인 크기  {a_bytes:,} B")
    g.ok(f"승인 버전  {a_ver}")

    # ── 4. 배포 금지 목록 ──────────────────────────────────────
    if a_commit in BLOCKED:
        g.fail(f"배포 금지 커밋: {a_commit[:12]}… — {BLOCKED[a_commit]}")
        return g.report()
    g.ok(f"배포 금지 목록 통과 ({len(BLOCKED)}건 등록)")

    # ── 5. 실물 대조 ───────────────────────────────────────────
    real_bytes = zp.stat().st_size
    if real_bytes != a_bytes:
        g.fail(f"크기 불일치 — 승인 {a_bytes:,} B / 실물 {real_bytes:,} B")
    else:
        g.ok(f"크기 일치 {real_bytes:,} B")

    real_sha = sha256_file(zp)
    if real_sha != a_sha:
        g.fail(f"SHA-256 불일치\n         승인: {a_sha}\n         실물: {real_sha}")
    else:
        g.ok(f"SHA-256 일치 {real_sha[:16]}…")

    if g.fails:
        return g.report()

    # ── 6. ZIP 내부 표식 ───────────────────────────────────────
    check_zip(zp, a_commit, a_ver, g)
    return g.report()


if __name__ == "__main__":
    sys.exit(main())

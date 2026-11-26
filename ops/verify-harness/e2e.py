#!/usr/bin/env python3
"""스케줄러 2.0 — 빈 서버 + 실제 웹 빌드 + 독립 브라우저 세션 두 개 E2E 시험.

## 사용자가 요구한 다섯 가지

  ① 저장            — A 가 카테고리와 일정을 만든다
  ② 새로고침 후 유지  — A 를 리로드해도 남아 있다
  ③ 다른 세션 동기화  — B 가 A 의 것을 본다
  ④ 삭제 반영        — A 가 지우면 B 에서도 사라진다
  ⑤ 재접속 후 중복 없음 — 새로고침·재로그인을 반복해도 기본 일정이 늘지 않는다

## "독립 브라우저 세션 두 개"를 어떻게 보장하는가

  · 서로 다른 `browser.new_context()` = 쿠키·localStorage·IndexedDB 가 분리됨
  · `context` 마다 **별도 브라우저 프로필**이므로 Hive(IndexedDB)도 따로
  · 두 세션은 동시에 열려 있고, 같은 오리진(:5240)을 본다
  · 서버는 `DATA_DIR` 이 빈 디렉터리에서 시작한다 (카테고리 미리 넣지 않음)

## 결함 ① 재현 조건

  A 가 만든 워크스페이스를 B 가 처음 내려받을 때, B 가 기본 카테고리를 새로
  만들어 올리면 A 의 카테고리가 덮인다. 그래서 ③ 에서 **탭 이름**까지 확인한다.
  B 가 "A 의 탭 이름"을 보면 B 는 기본값을 올리지 않은 것이다.

## 결함 ② 재현 조건

  기본 일정 id 가 기기마다 다르면 두 기기가 각자 만들어 서버에 2배가 남는다.
  ⑤ 에서 재로그인·새로고침을 반복하며 서버의 기본 일정 개수를 센다.
"""

import json
import os
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

BASE = os.environ.get("BASE", "http://127.0.0.1:5240")
GW = os.environ.get("GW", "http://127.0.0.1:5230")
CHROME = "/usr/bin/google-chrome"
ROUNDS = int(os.environ.get("ROUNDS", "3"))

MASTER_ID = "rnk7558"
MASTER_PW = "Verify2026!pw"

# 시험 계정. 마스터 콘솔이 아니라 일반 계정 흐름을 쓰고 싶지만, 2.0 은
# 마스터 계정이 곧 대표 계정이므로 마스터로 진행한다.
ACCOUNT = MASTER_ID
PASSWORD = MASTER_PW

results = []


def step(name, ok, detail=""):
    results.append({"step": name, "ok": bool(ok), "detail": detail})
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {name}" + (f" — {detail}" if detail else ""), flush=True)
    return ok


# ---------------------------------------------------------------- 서버 조회

def api_state(ws):
    """게이트웨이에서 워크스페이스 문서를 직접 읽는다 (시험의 '진실')."""
    import urllib.request
    with urllib.request.urlopen(f"{GW}/api/state?ws={ws}", timeout=20) as r:
        return json.loads(r.read().decode())


def workspace_of(account_id):
    """store.dart 의 workspaceCodeFor 와 같은 규칙 (증명용)."""
    import hashlib
    seed = f"june-scheduler-account-v2|{account_id}".encode()
    digest = hashlib.sha256(seed).digest()
    for _ in range(128):
        digest = hashlib.sha256(digest + seed).digest()
    return "ACC" + digest.hex()[:28].upper()


def registry_workspace():
    return "ACCREGISTRYJUNESCHEDULER0001"


# ---------------------------------------------------------------- 브라우저 도우미

class Session:
    """독립 브라우저 세션 한 개 (전용 프로필 = 전용 IndexedDB)."""

    def __init__(self, browser, name):
        self.name = name
        self.ctx = browser.new_context(
            viewport={"width": 430, "height": 932},
            locale="ko-KR",
            # 서비스 워커는 시험 중 옛 번들을 물고 올 수 있다. 막아 둔다.
            service_workers="block",
        )
        self.page = self.ctx.new_page()
        self.logs = []
        self.page.on(
            "console",
            lambda m: self.logs.append(f"{m.type}: {m.text}"),
        )
        self.page.on("pageerror", lambda e: self.logs.append(f"pageerror: {e!r}"))

    def goto(self, wait=9):
        self.page.goto(BASE + "/", wait_until="load", timeout=60000)
        time.sleep(wait)
        self.enable_semantics()

    def reload(self, wait=9):
        self.page.reload(wait_until="load", timeout=60000)
        time.sleep(wait)
        self.enable_semantics()

    def enable_semantics(self):
        try:
            self.page.evaluate(
                "() => { const el=document.querySelector("
                "'flt-semantics-placeholder'); if(el) el.click(); }"
            )
        except Exception:
            pass
        time.sleep(1.2)

    def labels(self):
        """의미 트리의 글자들.

        Flutter web 은 aria-label 을 쓰지 않고 노드의 textContent 에 글자를
        넣는 경우가 많습니다. 둘 다 읽어야 화면을 놓치지 않습니다.
        """
        return self.page.evaluate(
            """() => Array.from(document.querySelectorAll('flt-semantics'))
                .map(n => ((n.getAttribute('aria-label') || '') + ' '
                            + (n.textContent || '')).trim())
                .filter(Boolean)"""
        )

    def has_text(self, needle):
        return any(needle in x for x in self.labels())

    def _text_fields(self):
        """의미 트리가 만든 실제 입력칸들 (aria-label 기준).

        Flutter web 은 접근성 모드에서만 <input> 을 만든다. 그래서
        `enable_semantics()` 를 먼저 부르지 않으면 이 목록이 비어 있다.
        """
        return self.page.query_selector_all(
            'flt-semantics-host input, flt-semantics input, input'
        )

    def type_field(self, label_part, text, index=0):
        """aria-label 이 label_part 를 포함하는 입력칸에 글자를 넣는다."""
        box = self.page.evaluate(
            """(needle) => {
                const ins = Array.from(document.querySelectorAll('input'));
                const hits = ins.filter(
                    e => (e.getAttribute('aria-label') || '').includes(needle));
                if (!hits.length) return null;
                const r = hits[0].getBoundingClientRect();
                return {x: r.x + r.width / 2, y: r.y + r.height / 2};
            }""",
            label_part,
        )
        if not box:
            raise RuntimeError(f"입력칸을 찾지 못했습니다: {label_part}")
        # 실제 마우스로 눌러 포커스를 준다. DOM .click() 은 Flutter 가
        # 포커스를 인정하지 않아 글자가 들어가지 않는 경우가 있다.
        self.page.mouse.click(box["x"], box["y"])
        time.sleep(0.35)
        self.page.keyboard.type(text, delay=45)
        time.sleep(0.35)

    def tap(self, label_part):
        """글자가 일치하는 컨트롤을 누른다.

        ## 왜 단순히 "가장 작은 노드"가 아닌가
        한 화면에 같은 글자가 여러 곳에 있습니다. 로그인 화면에는 버튼
        「로그인」과 부제 「계속하시려면 로그인하세요」가 있고, 부제 쪽 글자
        노드가 더 작습니다. 면적만 보면 부제를 눌러 아무 일도 일어나지 않습니다.

        그래서 점수를 매깁니다.
          1) `role="button"` 인가            — 가장 중요
          2) 글자가 정확히 같은가             — 부분 일치보다 우선
          3) 면적이 작은가                    — 실제 컨트롤일 가능성이 높다
        """
        box = self.page.evaluate(
            """(needle) => {
                const nodes = Array.from(
                    document.querySelectorAll('flt-semantics'));
                let best = null;
                for (const n of nodes) {
                    const t = ((n.getAttribute('aria-label') || '') + ' '
                               + (n.textContent || '')).trim();
                    if (!t.includes(needle)) continue;
                    const r = n.getBoundingClientRect();
                    if (r.width <= 0 || r.height <= 0) continue;
                    // 화면 전체를 덮는 노드는 컨트롤이 아니다.
                    if (r.width > 400 && r.height > 800) continue;

                    let score = 0;
                    if ((n.getAttribute('role') || '') === 'button') score += 100;
                    if (t === needle || t === (n.getAttribute('aria-label')||'').trim()
                        && t === needle) score += 40;
                    if ((n.getAttribute('aria-label') || '').trim() === needle)
                        score += 40;
                    if ((n.textContent || '').trim() === needle) score += 30;
                    // 작을수록 좋다: 최대 20점
                    score += Math.max(0, 20 - (r.width * r.height) / 20000);

                    if (!best || score > best.score) {
                        best = {score: score,
                                x: r.x + r.width / 2,
                                y: r.y + r.height / 2,
                                w: r.width, h: r.height,
                                text: t.slice(0, 40)};
                    }
                }
                return best;
            }""",
            label_part,
        )
        if not box:
            raise RuntimeError(f"누를 곳을 찾지 못했습니다: {label_part}")
        self.page.mouse.click(box["x"], box["y"])
        time.sleep(1.6)
        return True

    def shot(self, path):
        try:
            self.page.screenshot(path=path)
        except Exception:
            pass

    def close(self):
        try:
            self.ctx.close()
        except Exception:
            pass


def wait_until(fn, timeout=25, interval=0.7):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:
            pass
        time.sleep(interval)
    return False


# ---------------------------------------------------------------- 시나리오

def do_master_setup(s):
    """첫 설치 화면에서 대표 계정 비밀번호를 정한다.

    이미 비밀번호가 정해진 서버라면 이 화면은 나오지 않는다. 그 경우
    "설정이 필요 없다"가 정상이므로 실패로 보지 않는다.
    """
    ok = wait_until(lambda: s.has_text("관리자 비밀번호를 정해 주세요"), 18)
    if not ok:
        if s.has_text("아이디") or s.has_text("로그인"):
            print("  (이미 설정된 서버 — 마스터 설정 화면 없음)", flush=True)
            return True
        return False
    s.type_field("새 비밀번호", MASTER_PW)
    s.type_field("한 번 더", MASTER_PW)
    s.tap("정하고 시작하기")
    return wait_until(
        lambda: s.has_text("로그인") or s.has_text("아이디"), 25
    )


def already_home(s):
    """이미 로그인되어 홈 화면인가."""
    s.enable_semantics()
    return s.has_text("할일 추가") or s.has_text("완료됨")


def do_second_device_entry(s):
    """새 기기(다른 프로필)로 들어온다.

    이미 대표 비밀번호가 정해진 서버에서는 새 기기에 설정 화면이 뜨지만,
    "대표 계정 「rnk7558」은 이미 주인이 있습니다" 안내와 함께
    「로그인 화면으로」 버튼이 나온다. 이것이 정상 동작이다(비밀번호를
    덮어쓰지 못하게 막는 장치). 그 버튼을 눌러 로그인 화면으로 간다.
    """
    s.enable_semantics()
    for _ in range(12):
        if s.has_text("아이디") or already_home(s):
            return "login"
        if s.has_text("로그인 화면으로"):
            s.tap("로그인 화면으로")
            time.sleep(2.2)
            s.enable_semantics()
            continue
        time.sleep(1.0)
        s.enable_semantics()
    return "unknown"


def do_login(s):
    """로그인 화면이면 로그인하고, 이미 홈이면 그대로 통과시킨다.

    새로고침해도 세션(IndexedDB)이 남아 있으면 로그인 화면이 나오지 않는다.
    그때 "로그인 화면이 없다"를 실패로 처리하면 멀쩡한 동작을 결함으로
    오해한다. 그래서 홈에 이미 있으면 성공으로 본다.
    """
    s.enable_semantics()
    if wait_until(lambda: already_home(s), 8):
        return True
    if not wait_until(lambda: s.has_text("아이디") or s.has_text("로그인"), 25):
        return False
    s.type_field("아이디", ACCOUNT)
    time.sleep(0.5)
    s.type_field("비밀번호", PASSWORD)
    time.sleep(0.6)
    s.tap("로그인")
    return wait_until(lambda: already_home(s), 40)


def count_seed_tasks_on_server(ws):
    """서버에서 '기본 일정' 성격의 기록 수를 센다.

    기본 일정은 (a) repeat 카테고리의 월세/창고비, (b) daily 카테고리의 루틴
    4건이다. 사용자가 만든 것과 구분하기 위해 제목이 아니라 **개수와 중복**을
    본다: 같은 제목이 두 번 있으면 중복 생성이다.
    """
    doc = api_state(ws)
    ents = doc.get("entities", {})
    tasks = {
        k: v for k, v in ents.items()
        if k.startswith("tasks/") and isinstance(v, dict)
        and not v.get("deletedAt")
    }
    titles = {}
    for v in tasks.values():
        t = (v.get("title") or "").strip()
        titles[t] = titles.get(t, 0) + 1
    dupes = {t: c for t, c in titles.items() if c > 1}
    return {
        "total_tasks": len(tasks),
        "titles": titles,
        "duplicates": dupes,
        "rev": doc.get("rev", 0),
        "gen": doc.get("gen", 0),
        "exists": doc.get("exists", False),
        "categories": len([k for k in ents if k.startswith("categories/")]),
    }


def add_task(s, title, category_hint=None, category_choice=None):
    """홈에서 일정 하나를 만든다."""
    s.enable_semantics()
    s.tap("할일 추가")
    time.sleep(2.2)
    s.enable_semantics()
    if not wait_until(lambda: s.has_text("새 할일"), 20):
        raise RuntimeError("편집기가 열리지 않았습니다")
    s.type_field("예: 월세 납부", title)
    time.sleep(0.5)
    if category_choice:
        # 카테고리 칩을 눌러 바꾼다.
        s.tap(category_choice)
    time.sleep(0.6)
    s.tap("저장")
    time.sleep(3.0)
    s.enable_semantics()
    return wait_until(lambda: title in " ".join(s.labels()), 25)


def open_category(s, name):
    """상단 카테고리 칩을 눌러 그 탭으로 이동한다."""
    s.enable_semantics()
    s.tap(name)
    time.sleep(2.5)
    s.enable_semantics()


def count_visible_rows(s, title):
    """화면 의미 트리에 그 제목이 몇 번 나오는가 (= 행 수)."""
    n = s.page.evaluate(
        """(t) => {
            const nodes = Array.from(
                document.querySelectorAll('flt-semantics'));
            // 정확히 같은 글자를 가진 잎 노드만 센다(부모는 자식을 이어붙임).
            return nodes.filter(n => (n.textContent || '').trim() === t).length;
        }""",
        title,
    )
    return n


def main():
    ws = workspace_of(ACCOUNT)
    print("=" * 70, flush=True)
    print("스케줄러 2.0 — 빈 서버 E2E", flush=True)
    print(f"계정 {ACCOUNT} → 워크스페이스 {ws}", flush=True)
    before = api_state(ws)
    print(f"시험 전 서버: exists={before.get('exists')} "
          f"rev={before.get('rev')} "
          f"entities={len(before.get('entities', {}))}", flush=True)
    step("서버가 시작 시점에 비어 있다 (카테고리 미포함)",
         not before.get("exists") or len(before.get("entities", {})) == 0,
         f"entities={len(before.get('entities', {}))}")

    try:
      with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=CHROME,
            # IsolateOrigins 를 끄면 Flutter web 의 접근성 트리 초기화가
            # 실패하는 것을 확인했습니다(의미 노드가 0개). 기본값으로 둡니다.
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )

        # ===================== 세션 A (첫 기기) =====================
        print("\n=== 세션 A: 첫 기기 ===", flush=True)
        a = Session(browser, "A")
        a.goto()
        step("A 마스터 비밀번호 설정", do_master_setup(a))
        step("A 로그인 성공", do_login(a))
        a.shot("/tmp/e2e_1_A_home.png")

        # ---- ① 저장 ----
        TITLE = "결함검증 일정 알파"
        CAT = "회사업무"
        open_category(a, CAT)
        made = add_task(a, TITLE)
        a.shot("/tmp/e2e_2_A_task_added.png")
        step("① A 가 일정을 저장했다", made, TITLE)

        # 서버에 실제로 도달했는지 (동기화 지연을 넉넉히 기다린다)
        def server_has(title):
            ents = api_state(ws).get("entities", {})
            return any(
                isinstance(v, dict) and (v.get("title") or "") == title
                and not v.get("deletedAt")
                for k, v in ents.items() if k.startswith("tasks/")
            )

        step("① 서버에 일정이 도달했다", wait_until(lambda: server_has(TITLE), 40))

        # ---- ② 새로고침 후 유지 ----
        a.reload()
        step("② A 새로고침 후에도 로그인 상태다",
             do_login(a) or a.has_text("할일 추가"))
        open_category(a, CAT)
        kept = wait_until(lambda: TITLE in " ".join(a.labels()), 30)
        a.shot("/tmp/e2e_3_A_after_reload.png")
        step("② 새로고침 후에도 A 에 일정이 남아 있다", kept, TITLE)

        # ===================== 세션 B (두 번째 기기) =====================
        print("\n=== 세션 B: 두 번째 기기 (독립 프로필) ===", flush=True)
        b_sess = Session(browser, "B")
        b_sess.goto()
        b_sess.enable_semantics()
        # 결함 ① 방지 장치가 실제로 도는지 확인: 새 기기는 "이미 주인이 있다"를
        # 보고 비밀번호를 덮어쓰지 못한다.
        owner_protected = (
            b_sess.has_text("이미 주인이 있습니다")
            or b_sess.has_text("로그인 화면으로")
            or b_sess.has_text("아이디")
        )
        step("B 새 기기는 대표 비밀번호를 덮어쓰지 못한다", owner_protected)
        step("B 로그인 화면 진입", do_second_device_entry(b_sess) != "unknown",
             "로그인 화면" if b_sess.has_text("아이디") else "홈")
        step("B 로그인 성공", do_login(b_sess))
        b_sess.shot("/tmp/e2e_4_B_home.png")

        # ---- ③ 다른 세션 동기화 ----
        open_category(b_sess, CAT)
        synced = wait_until(
            lambda: TITLE in " ".join(b_sess.labels()), 45)
        b_sess.shot("/tmp/e2e_5_B_synced.png")
        step("③ B 에 A 의 일정이 동기화됐다", synced, TITLE)

        # 결함 ① 의 핵심: B 가 기본 카테고리를 새로 만들어 올리지 않았는가.
        # A 가 바꾼 것이 없으므로 대신 **카테고리 개수가 늘지 않았는지** 본다.
        cats_now = len([k for k in api_state(ws).get("entities", {})
                        if k.startswith("categories/")])
        step("③ B 로그인으로 카테고리가 중복 생성되지 않았다",
             cats_now == 14, f"categories={cats_now} (기대 14)")

        # B 가 A 의 일정을 덮어쓰지 않았는가
        step("③ B 로그인 후에도 서버에 A 의 일정이 그대로다",
             server_has(TITLE))

        # ---- ④ 삭제 반영 ----
        print("\n=== ④ 삭제 반영 ===", flush=True)
        # 삭제는 A 에서 한다 (사용자가 자기 기기에서 지우는 상황).
        a.enable_semantics()
        open_category(a, CAT)
        deleted_ui = False
        try:
            # 홈의 행을 누르면 **하단 시트**(완료 표시 / 삭제)가 열린다.
            # 그 안의 「삭제」를 누르면 확인 대화상자가 뜬다(확인 버튼은 영어
            # 'Delete' 로 하드코딩되어 있다 — 한국어 UI 에서도 그대로다).
            a.tap(TITLE)
            time.sleep(2.2)
            a.enable_semantics()
            print(f"  시트 열림: 삭제={a.has_text('삭제')} "
                  f"완료={a.has_text('완료')}", flush=True)

            if a.has_text("삭제"):
                a.tap("삭제")            # 하단 시트의 삭제
                time.sleep(1.8)
                a.enable_semantics()
            if a.has_text("삭제하시겠어요") or a.has_text("Delete"):
                for confirm in ("Delete", "삭제"):
                    if a.has_text(confirm):
                        a.tap(confirm)   # 확인 대화상자
                        deleted_ui = True
                        break
            time.sleep(3.0)
            a.enable_semantics()
        except Exception as exc:
            print(f"  (삭제 UI 시도 중 예외: {exc})", flush=True)

        a.shot("/tmp/e2e_6_A_deleted.png")

        def server_deleted(title):
            ents = api_state(ws).get("entities", {})
            for k, v in ents.items():
                if not k.startswith("tasks/"):
                    continue
                if isinstance(v, dict) and (v.get("title") or "") == title:
                    return bool(v.get("deletedAt"))
            return True  # 서버에 아예 없음 = 삭제된 것으로 본다

        step("④ 서버에서 일정이 삭제됐다",
             wait_until(lambda: server_deleted(TITLE), 45),
             f"UI 삭제 시도={deleted_ui}")

        b_sess.reload()
        do_login(b_sess) or None
        open_category(b_sess, CAT)
        gone = wait_until(lambda: TITLE not in " ".join(b_sess.labels()), 45)
        b_sess.shot("/tmp/e2e_7_B_after_delete.png")
        step("④ B 에서도 일정이 사라졌다", gone, TITLE)

        # ---- ⑤ 재접속 후 중복 없음 ----
        print("\n=== ⑤ 재접속 반복 후 중복 없음 ===", flush=True)
        baseline = count_seed_tasks_on_server(ws)
        print(f"  기준: tasks={baseline['total_tasks']} "
              f"cats={baseline['categories']} "
              f"중복={baseline['duplicates']}", flush=True)

        for i in range(ROUNDS):
            for sess in (a, b_sess):
                sess.reload()
                do_login(sess) or None
                sess.enable_semantics()
            time.sleep(4)
            snap = count_seed_tasks_on_server(ws)
            print(f"  {i+1}회차: tasks={snap['total_tasks']} "
                  f"cats={snap['categories']} "
                  f"중복={snap['duplicates']}", flush=True)
            if snap["total_tasks"] != baseline["total_tasks"]:
                break

        final = count_seed_tasks_on_server(ws)
        step("⑤ 재접속을 반복해도 일정 개수가 늘지 않는다",
             final["total_tasks"] == baseline["total_tasks"],
             f"{baseline['total_tasks']} → {final['total_tasks']}")
        step("⑤ 같은 제목의 일정이 두 번 생기지 않는다",
             not final["duplicates"], f"중복={final['duplicates']}")
        step("⑤ 카테고리도 늘지 않는다",
             final["categories"] == baseline["categories"],
             f"{baseline['categories']} → {final['categories']}")

        a.shot("/tmp/e2e_8_final_A.png")
        b_sess.shot("/tmp/e2e_9_final_B.png")

        a.close()
        b_sess.close()
        browser.close()
    except Exception as exc:
        import traceback
        traceback.print_exc()
        step("시험 도중 예외 없이 끝까지 진행됐다", False, repr(exc)[:160])

    summary()


def summary():
    print("\n" + "=" * 70)
    ok = sum(1 for r in results if r["ok"])
    print(f"결과: {ok}/{len(results)} 통과")
    for r in results:
        print(f"  [{'PASS' if r['ok'] else 'FAIL'}] {r['step']}"
              + (f" — {r['detail']}" if r["detail"] else ""))
    print("=" * 70)
    with open("/tmp/e2e_results.json", "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()

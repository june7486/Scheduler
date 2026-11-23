// `test` 계정에 들어가는 견본 자료.
//
// ## 이 파일이 지켜야 하는 세 가지
//
// ### 1. 결정론적(deterministic)이어야 한다
// `test` 계정은 기기마다 만들어집니다. 그런데 자료가 기기마다 다르면 어떻게
// 될까요. 폰에서 만든 1년치와 노트북에서 만든 1년치가 동기화로 **합쳐집니다.**
// 같은 계정에 2년치가 생기고, 사용자는 처음부터 신뢰를 잃습니다.
// 그래서 여기에는 `DateTime.now()` 기반의 난수가 없습니다. 날짜는 오늘에서
// 거꾸로 세고, 고르는 순서는 고정된 난수 열로 정합니다. 같은 날 실행하면
// 언제나 같은 자료가 나옵니다.
//
// ### 2. 항목 id 가 고정이어야 한다
// 동기화는 `tasks/<id>` 를 문서 키로 씁니다. id 가 매번 다르면 두 기기의
// 자료가 "같은 항목"으로 인식되지 않고 그대로 쌓입니다. `demo:...` 로
// 시작하는 고정 id 를 씁니다.
//
// ### 3. 되살아나야 한다
// 사용자가 A(완전 초기화)를 고르면 견본도 지워집니다. 그 뒤 앱을 다시 열면
// 견본이 없어야 정상일까요? 아닙니다 — `test` 계정의 존재 이유가 "한눈에
// 보는 견본"이므로, 지워지면 다시 채웁니다. 판단 기준은 별도 표시가 아니라
// **안내 항목의 존재 여부**입니다. 표시를 따로 두면 초기화 뒤에 표시만 남아
// 빈 계정이 됩니다.

import '../models/models.dart';

/// 견본 자료의 한 줄.
class DemoItem {
  final String id;
  final String title;
  final String note;
  final String categoryId;
  final DateTime createdAt;
  final DateTime? dueDate;
  final bool completed;
  final DateTime? completedAt;
  final double? amount;
  final String relatedTo;
  final String recurrence;
  final int? recurrenceDay;
  final bool pinned;
  final int order;

  const DemoItem({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.categoryId,
    this.note = '',
    this.dueDate,
    this.completed = false,
    this.completedAt,
    this.amount,
    this.relatedTo = '',
    this.recurrence = 'none',
    this.recurrenceDay,
    this.pinned = false,
    this.order = 0,
  });

  Task toTask(String ownerId) => Task(
    id: id,
    title: title,
    note: note,
    ownerId: ownerId,
    categoryId: categoryId,
    createdAt: createdAt,
    dueDate: dueDate,
    completed: completed,
    completedAt: completedAt,
    amount: amount,
    relatedTo: relatedTo,
    recurrence: recurrence,
    recurrenceDay: recurrenceDay,
    pinned: pinned,
    order: order,
    // Stamp with the creation time so the sync engine sees a stable value
    // instead of "now" on every launch.
    updatedAt: createdAt.millisecondsSinceEpoch,
  );
}

/// 안내 항목의 id. 이 항목이 있으면 견본이 이미 깔린 것으로 봅니다.
const String demoGuideAnchorId = 'demo:guide:0';

/// 안내 항목 앞에 붙는 순서값. 실제 일정은 0부터 시작하므로 음수를 씁니다.
const int demoGuideOrderBase = -1000;

/// 고정 난수 열 (xorshift32). 씨앗은 상수입니다.
///
/// `Random(seed)` 를 쓰지 않은 이유: Dart 의 구현이 플랫폼마다 같다는 보장이
/// 없습니다. 웹(자바스크립트 숫자)과 안드로이드에서 같은 열이 나오지 않으면
/// 기기마다 다른 견본이 생깁니다. 산술만으로 이루어진 이 방식은 어디서나
/// 같은 값을 냅니다.
class _Rng {
  int _s;
  _Rng(int seed) : _s = seed == 0 ? 0x9E3779B9 : seed;

  int next() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s;
  }

  /// 0 이상 [max] 미만.
  int pick(int max) => max <= 0 ? 0 : next() % max;

  bool chance(int percent) => pick(100) < percent;
}

/// 한 해의 견본을 만듭니다. [ko] 가 false 면 영어 제목을 씁니다.
List<DemoItem> buildDemoYear({
  required DateTime now,
  required bool ko,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final out = <DemoItem>[];

  // ------------------------------------------------------------------
  // 1) 안내 — 가장 위에 고정
  // ------------------------------------------------------------------
  out.addAll(_guides(today, ko));

  // ------------------------------------------------------------------
  // 2) 12개월치 기록
  // ------------------------------------------------------------------
  final rng = _Rng(20261121);
  var order = 0;

  for (var back = 12; back >= 1; back--) {
    final monthStart = DateTime(today.year, today.month - back, 1);
    final daysInMonth = DateTime(monthStart.year, monthStart.month + 1, 0).day;

    // 한 달에 12~16건. 365일을 200건으로 채우면 표가 벽이 되고,
    // 30건이면 "이게 1년이라고?" 싶어집니다.
    final count = 12 + rng.pick(5);

    for (var i = 0; i < count; i++) {
      final day = 1 + rng.pick(daysInMonth);
      final date = DateTime(monthStart.year, monthStart.month, day);
      final kind = _pickKind(rng);
      final done = _completionFor(back, date, today, rng);

      out.add(
        _item(
          kind: kind,
          rng: rng,
          ko: ko,
          date: date,
          today: today,
          done: done,
          order: order++,
          serial: out.length,
        ),
      );
    }
  }

  // ------------------------------------------------------------------
  // 3) 이번 달 — 아직 진행 중인 일
  // ------------------------------------------------------------------
  final count = 10 + rng.pick(5);
  for (var i = 0; i < count; i++) {
    final daysInMonth = DateTime(today.year, today.month + 1, 0).day;
    final day = 1 + rng.pick(daysInMonth);
    var date = DateTime(today.year, today.month, day);
    // 이번 달은 미래 날짜도 섞여야 "예정"이 보입니다.
    if (day > today.day + 12) date = DateTime(today.year, today.month, today.day);
    final kind = _pickKind(rng);
    // 이번 달은 절반만 끝난 상태로 둡니다. 전부 완료면 앱이 심심하고,
    // 전부 미완료면 "이 앱은 정리가 안 되네"로 보입니다.
    final done = date.isBefore(today) && rng.chance(60);
    out.add(
      _item(
        kind: kind,
        rng: rng,
        ko: ko,
        date: date,
        today: today,
        done: done,
        order: order++,
        serial: out.length,
      ),
    );
  }

  // ------------------------------------------------------------------
  // 4) 반복 항목 — 매월 같은 날 (dueDate 없이 recurrenceDay 로)
  // ------------------------------------------------------------------
  // 반복을 넣는 이유: 통계가 반복을 어떻게 세는지 견본에서 바로 보여야
  // 하기 때문입니다. 이게 없으면 "매월 관리비"가 한 날짜에 몰려 보입니다.
  //
  // `List<Object?>` 인 이유: 금액이 없는 반복(보고·모임)은 null 입니다.
  // `List<Object>` 로 두면 null 을 담을 수 없어 컴파일이 막힙니다.
  final recurring = <List<Object?>>[
    ['finance', ko ? '관리비 자동이체' : 'Maintenance fee', 25, 180000.0],
    ['debt', ko ? '주택담보대출 이자' : 'Mortgage interest', 5, 620000.0],
    ['company', ko ? '월간 진행 보고' : 'Monthly progress report', 28, null],
    ['scout', ko ? '대원 정기 모임' : 'Troop regular meeting', 12, null],
  ];
  for (var i = 0; i < recurring.length; i++) {
    final r = recurring[i];
    final day = r[2] as int;
    out.add(
      DemoItem(
        id: 'demo:recurring:$i',
        title: r[1] as String,
        note: ko ? '매월 $day일 반복' : 'Repeats on day $day',
        categoryId: r[0] as String,
        // 반복 항목은 1년 전에 시작한 것으로 둡니다. 그래야 "1년 전~전체"
        // 통계에서 12개월 내내 잡히는 모습을 볼 수 있습니다.
        createdAt: DateTime(today.year - 1, today.month, day),
        dueDate: null,
        completed: false,
        amount: r[3] as double?,
        recurrence: 'monthly',
        recurrenceDay: day,
        order: order++,
      ),
    );
  }

  // ------------------------------------------------------------------
  // 5) 기한이 지난 미완료 — 통계의 "기한 초과"가 0이 아니어야
  //    그 숫자가 무엇을 뜻하는지 견본에서 알 수 있습니다.
  // ------------------------------------------------------------------
  for (var i = 0; i < 4; i++) {
    final date = today.subtract(Duration(days: 10 + i * 23));
    out.add(
      DemoItem(
        id: 'demo:overdue:$i',
        title: ko
            ? ['창고 정리', '보험 증권 갱신', '차량 정기점검', '연말 정산 서류'][i]
            : ['Tidy the storage', 'Renew insurance', 'Vehicle service', 'Year-end papers'][i],
        note: ko ? '기한이 지났습니다 — 통계의 「기한 초과」에 잡힙니다' : 'Overdue — counted in "overdue"',
        categoryId: ['personal', 'todo', 'personal', 'bank'][i],
        createdAt: date,
        dueDate: date,
        completed: false,
        order: order++,
      ),
    );
  }

  return out;
}

/// 위쪽 안내 카드. 처음 온 사람이 여기서 앱 사용법을 읽고 끝냅니다.
List<DemoItem> _guides(DateTime today, bool ko) {
  // 오늘 자정. `today` 에 시각을 더하면 아침 7시에 앱을 열었을 때
  // "미래에 만든 항목"이 됩니다. 자정으로 두면 언제 열어도 과거입니다.
  final now = DateTime(today.year, today.month, today.day);
  final src = ko
      ? <List<String>>[
          [
            '처음 오셨나요? — 이 계정은 연습장입니다',
            '이 계정은 「test」이고, 실제로 쓰지 않아도 됩니다.\n'
                '여기 있는 1년치 기록은 전부 견본입니다. 지워도 되고, 그대로 두고 구경만 해도 됩니다.\n\n'
                '· 위쪽 + 단추로 할 일을 적습니다\n'
                '· 항목을 누르면 오른쪽 탭에 집어넣을 수 있습니다\n'
                '· 아래 통계 화면에서 기간별로 볼 수 있습니다\n\n'
                '실제로 쓰시려면 로그아웃하고 새 아이디를 만드세요.',
          ],
          [
            '사용법 — 5단계',
            '1. 새 아이디 만들기 → 원하는 이름 (영문 소문자·숫자·밑줄, 4~20자)\n'
                '2. 로그인하면 탭 14개가 미리 깔려 있습니다. 이름을 바꾸거나 지워도 됩니다\n'
                '3. + 단추로 할 일을 적습니다. 마감일·금액·메모는 원할 때만\n'
                '4. 끝난 일은 동그라미를 누르면 취소선이 그어집니다. 기록은 지워지지 않습니다\n'
                '5. 다른 기기에서 같은 아이디로 들어오면 목록이 따라옵니다',
          ],
          [
            '통계 보는 법',
            '설정 → 통계 에서 기간을 고릅니다.\n\n'
                '· 일주일 전 오늘 : 하루 단위 7칸 — 요일별로 몰리는지 보입니다\n'
                '· 한 달 전 오늘 : 6일 단위 5칸\n'
                '· 1년 전 ~ 전체 : 달 단위 — 언제 바빴는지 보입니다\n\n'
                '「완료율」이 「—」로 보이면 그 기간에 기록이 없다는 뜻입니다. 0%와는 다릅니다.',
          ],
          [
            '만든이',
            '이승준 — 건축가, 스카우트 대장.\n'
                '도면 쓰던 손으로 만들었습니다. 달력 앱이 자꾸 제 일을 제 방식대로 못 담아서 직접 만들었습니다.\n\n'
                '스카우트 자료는 www.scout.it.kr 에 있습니다.\n'
                '문의·요청은 로그인 화면의 안내를 보세요.',
          ],
        ]
      : <List<String>>[
          [
            'First time here? This account is a sandbox',
            'This is the "test" account — you do not have to use it for real.\n'
                'The year of records here is all sample data. Delete it, or just look around.\n\n'
                '· Add an item with the + button at the top\n'
                '· Tap an item to place it in a tab on the right\n'
                '· See it by period in Settings → Statistics\n\n'
                'To actually use it, sign out and create your own id.',
          ],
          [
            'How it works — five steps',
            '1. Create an id → lowercase letters, digits, underscore, 4-20 chars\n'
                '2. Signing in gives you 14 tabs. Rename or delete any of them\n'
                '3. Add an item with +. Due date, amount and note are optional\n'
                '4. Tick the circle to strike it out. The record is never erased\n'
                '5. Sign in with the same id elsewhere and the list follows you',
          ],
          [
            'Reading the statistics',
            'Settings → Statistics, then pick a period.\n\n'
                '· Week ago today: seven daily bars — see which weekday piles up\n'
                '· Month ago today: five six-day bars\n'
                '· Year ago → all: monthly bars — see when the year was busy\n\n'
                'A rate shown as "—" means no records in that period. That is not 0%.',
          ],
          [
            'Who made this',
            'Seungjun Lee — architect, scout leader.\n'
                'Built it because calendar apps would not hold work the way he does.\n\n'
                'Scout material lives at www.scout.it.kr.',
          ],
        ];

  return [
    for (var i = 0; i < src.length; i++)
      DemoItem(
        id: 'demo:guide:$i',
        title: src[i][0],
        note: src[i][1],
        categoryId: i == 1 ? 'memo' : (i == 3 ? 'other' : 'todo'),
        createdAt: now,
        completed: false,
        pinned: true,
        order: demoGuideOrderBase + i,
      ),
  ];
}

/// 어떤 종류의 일을 만들지. 분류가 한쪽으로 쏠리면 견본이 아니라 거짓말입니다.
String _pickKind(_Rng rng) {
  const weights = <String>[
    'todo', 'todo', 'todo', 'todo',
    'company', 'company', 'company',
    'personal', 'personal',
    'finance', 'finance',
    'bank',
    'scout', 'scout',
    'birthday', 'birthday',
    'memo',
    'daily', 'daily',
    'debt', 'receivable',
    'longterm',
  ];
  return weights[rng.pick(weights.length)];
}

/// 그 달의 일이 끝났는지. 오래된 달은 거의 다 끝나 있어야 자연스럽습니다.
bool _completionFor(int monthsBack, DateTime date, DateTime today, _Rng rng) {
  if (date.isAfter(today)) return false;
  if (monthsBack >= 3) return rng.chance(94);
  if (monthsBack >= 1) return rng.chance(85);
  return rng.chance(70);
}

DemoItem _item({
  required String kind,
  required _Rng rng,
  required bool ko,
  required DateTime date,
  required DateTime today,
  required bool done,
  required int order,
  required int serial,
}) {
  // ## 난수는 언어를 고르기 **전에** 뽑습니다
  //
  // 처음엔 `_title` 안에서 제목 배열 길이만큼 `rng.pick` 을 불렀습니다.
  // 그런데 한국어 배열은 5개, 영어 배열은 3개라서 소비하는 난수 "개수"가
  // 언어에 따라 달라졌습니다(생일 항목은 한국어만 이름을 뽑았습니다).
  // 그 뒤로 난수 열이 어긋나서 **언어를 바꾸면 항목 수가 192 vs 200 으로
  // 달라졌습니다.** id 와 날짜는 같아야 하는데 말이죠.
  //
  // 그래서 뽑는 일은 여기서 한 번만 하고, `_title` 은 받은 숫자로 배열만
  // 고릅니다. `_title` 은 이제 난수를 하나도 쓰지 않습니다.
  final sel = rng.pick(1000);
  final sel2 = rng.pick(1000);

  final t = _title(kind, sel, sel2, ko);
  final hasAmount = kind == 'finance' || kind == 'debt' || kind == 'receivable';
  // 금액은 만원 단위로 떨어지게. 37,412원 같은 값은 견본에서 잡음입니다.
  final amount = hasAmount ? ((5 + rng.pick(60)) * 10000).toDouble() : null;

  // ## 만든 날은 미래가 될 수 없다
  //
  // 이번 달 항목에는 아직 오지 않은 날짜가 섞입니다(예정된 일). 그건
  // `dueDate` 로 표현해야 맞습니다. "만든 날"이 미래면 그 항목은 존재할 수
  // 없는 것이고, 통계에서도 어느 막대에도 안 들어가 사라집니다.
  final created = date.isAfter(today) ? today : date;
  final due = rng.chance(45)
      ? date.add(Duration(days: rng.pick(9) - 2))
      : null;

  return DemoItem(
    id: 'demo:y1:$serial',
    title: t[0],
    note: t[1],
    categoryId: kind,
    createdAt: created,
    dueDate: due,
    completed: done,
    completedAt: done
        ? created.add(Duration(hours: 9 + rng.pick(9)))
        : null,
    amount: amount,
    relatedTo: t.length > 2 ? t[2] : '',
    order: order,
  );
}

/// 제목·메모·관련인. [0]=제목 [1]=메모 [2]=관련인(선택)
///
/// **[sel]·[sel2] 만 보고 고릅니다. 난수를 쓰지 않습니다.** 그래야 언어를
/// 바꿔도 난수 열이 어긋나지 않습니다 (자세한 사고 경위는 [_item] 참고).
List<String> _title(String kind, int sel, int sel2, bool ko) {
  List<String> pickOf(List<List<String>> list) => list[sel % list.length];

  if (ko) {
    switch (kind) {
      case 'todo':
        return pickOf(const [
          ['우유·달걀 사기', '냉장고가 비었습니다'],
          ['세탁기 필터 청소', ''],
          ['전등 갓 닦기', ''],
          ['현관 신발장 정리', ''],
          ['자전거 체인 기름칠', ''],
        ]);
      case 'company':
        return pickOf(const [
          ['현장 답사', '도면과 실측이 다를 수 있습니다', ''],
          ['시공사 미팅', '', ''],
          ['설계 변경안 정리', '발주처 요청 반영', ''],
          ['구조 검토 회신', '', ''],
          ['준공 서류 확인', '', ''],
        ]);
      case 'personal':
        return pickOf(const [
          ['치과 예약', ''],
          ['부모님 댁 방문', ''],
          ['운동 30분', ''],
          ['책 반납', ''],
          ['병원 정기검진', ''],
        ]);
      case 'finance':
        return pickOf(const [
          ['장보기', '', '마트'],
          ['건축 자재비', '', ''],
          ['사무실 비품', '', ''],
          ['식비', '', ''],
          ['주유', '', ''],
        ]);
      case 'bank':
        return pickOf(const [
          ['잔금 이체', '', ''],
          ['통장 정리', '', ''],
          ['자동이체 확인', '', ''],
          ['세금 납부', '', ''],
        ]);
      case 'scout':
        return pickOf(const [
          ['대원 진급 심사', '', ''],
          ['야영 준비물 점검', '', ''],
          ['스카우트 자료실 정리', 'www.scout.it.kr', ''],
          ['학부모 안내문 발송', '', ''],
          ['지도자 연수 참석', '', ''],
        ]);
      case 'birthday':
        const names = ['김민수', '이정희', '박준영', '최수연', '정해원'];
        return ['${names[sel2 % names.length]} 생일', '축하 연락', ''];
      case 'memo':
        return pickOf(const [
          ['아이디어 메모', '창고 선반 높이 조정'],
          ['읽을거리', '목구조 설계 지침'],
          ['나중에 볼 것', ''],
        ]);
      case 'daily':
        return pickOf(const [
          ['물 2L 마시기', ''],
          ['걷기 6000보', ''],
          ['일기 한 줄', ''],
        ]);
      case 'debt':
        return pickOf(const [
          ['자재상 외상 결제', '', '대한목재'],
          ['장비 대여료', '', ''],
        ]);
      case 'receivable':
        return pickOf(const [
          ['설계비 청구', '', ''],
          ['감리비 입금 확인', '', ''],
        ]);
      case 'longterm':
        return pickOf(const [
          ['장기 과제 — 창고 증축', '올해 안에'],
          ['장기 과제 — 홈페이지 개편', ''],
        ]);
      case 'repeat':
        return const ['반복 일정', ''];
      default:
        return const ['기타 일정', ''];
    }
  }

  switch (kind) {
    case 'todo':
      return pickOf(const [
        ['Buy milk and eggs', ''],
        ['Clean the washer filter', ''],
        ['Dust the lamp shades', ''],
        ['Sort the shoe rack', ''],
        ['Oil the bike chain', ''],
      ]);
    case 'company':
      return pickOf(const [
        ['Site survey', ''],
        ['Contractor meeting', ''],
        ['Revise the design', ''],
        ['Reply on the structure review', ''],
        ['Check the completion papers', ''],
      ]);
    case 'personal':
      return pickOf(const [
        ['Dentist appointment', ''],
        ['Visit the parents', ''],
        ['Thirty minutes of exercise', ''],
        ['Return the library books', ''],
        ['Annual check-up', ''],
      ]);
    case 'finance':
      return pickOf(const [
        ['Groceries', '', 'Mart'],
        ['Building materials', '', ''],
        ['Office supplies', '', ''],
        ['Meals', '', ''],
        ['Fuel', '', ''],
      ]);
    case 'bank':
      return pickOf(const [
        ['Transfer the balance', ''],
        ['Reconcile the account', ''],
        ['Check the standing orders', ''],
        ['Pay the tax', ''],
      ]);
    case 'scout':
      return pickOf(const [
        ['Advancement review', ''],
        ['Camp gear check', ''],
        ['Sort the scout archive', 'www.scout.it.kr'],
        ['Send the parents letter', ''],
        ['Leader training', ''],
      ]);
    case 'birthday':
      const names = ['Minsu', 'Jeonghee', 'Junyeong', 'Suyeon', 'Haewon'];
      return ['Birthday — ${names[sel2 % names.length]}', 'Send a note', ''];
    case 'memo':
      return pickOf(const [
        ['Idea note', 'Adjust the shelf height'],
        ['To read', 'Timber design guide'],
        ['Look at this later', ''],
      ]);
    case 'daily':
      return pickOf(const [
        ['Drink 2L of water', ''],
        ['Walk 6000 steps', ''],
        ['One line of journal', ''],
      ]);
    case 'debt':
      return pickOf(const [
        ['Timber supplier credit', '', 'Daehan Timber'],
        ['Equipment rental', '', ''],
      ]);
    case 'receivable':
      return pickOf(const [
        ['Invoice the design fee', '', ''],
        ['Confirm the supervision payment', '', ''],
      ]);
    case 'longterm':
      return pickOf(const [
        ['Long term — extend the storehouse', 'This year'],
        ['Long term — rebuild the website', ''],
      ]);
    case 'repeat':
      return const ['Recurring item', ''];
    default:
      return const ['Misc. schedule', ''];
  }
}

// 통계 계산 — 화면과 완전히 분리된 순수 Dart.
//
// ## 왜 화면에서 떼어냈나
// 통계는 "숫자가 맞는가"가 전부인 기능입니다. 그런데 위젯 안에서 계산하면
// 시험하려고 위젯을 띄우고, 탭을 누르고, 스크롤해야 합니다. 계산이 틀렸는지
// 확인하는 데 그런 비용이 들면 아무도 확인하지 않고, 결국 숫자가 틀린 채로
// 배포됩니다. 그래서 여기에는 Flutter import 가 하나도 없습니다.
//
// ## 날짜는 무엇을 기준으로 세는가
// `report_screen.dart` 의 날짜별 리포트와 **같은 규칙**을 씁니다:
//
//     기준일 = dueDate ?? 반복으로 계산한 날짜 ?? 만든 날
//
// 두 화면이 다른 날짜로 같은 일을 세면 사용자는 둘 중 하나를 믿지 않게
// 됩니다. 그래서 규칙을 복사하지 않고 이 파일에 한 번만 적고, 리포트 화면도
// 같은 함수를 쓰도록 맞췄습니다.

/// 통계에서 고를 수 있는 기간.
///
/// 사용자가 요청한 네 가지입니다:
///   · 일주일 전 오늘
///   · 한 달 전 오늘
///   · 1년 전 부터 (… 무한대)
///   · 전체 (처음 기록까지 — 사실상 무한대)
enum StatsRange {
  /// 최근 7일.
  week,

  /// 최근 30일.
  month,

  /// 최근 1년.
  year,

  /// 기록이 시작된 때부터 지금까지. 끝이 없습니다.
  all,
}

extension StatsRangeX on StatsRange {
  /// 이 기간의 시작점. [all] 은 "끝을 모른다"는 뜻이라 null 입니다.
  ///
  /// ## 왜 [all] 에 아주 옛날 날짜를 넣지 않는가
  /// `DateTime(1970)` 을 쓰면 "1년치"와 "전체"의 막대 개수 계산이 같아져서
  /// 두 기간이 눈으로 구별되지 않습니다. null 로 두고, 실제 시작점은
  /// **자료가 정하게** 합니다 — 기록이 3개월치뿐이면 3개월이 전체입니다.
  DateTime? startFrom(DateTime now) {
    switch (this) {
      case StatsRange.week:
        return _dayStart(now).subtract(const Duration(days: 6));
      case StatsRange.month:
        return _dayStart(now).subtract(const Duration(days: 29));
      case StatsRange.year:
        // 365일을 빼면 윤년에서 하루씩 밀립니다(2/29 → 3/1).
        // 달력으로 12개월을 뺍니다.
        return _addMonths(_dayStart(now), -12);
      case StatsRange.all:
        return null;
    }
  }
}

DateTime _dayStart(DateTime t) => DateTime(t.year, t.month, t.day);

/// 달력 기준 개월 이동. 31일에 한 달을 빼면 없는 날짜가 생기므로
/// 그 달의 마지막 날로 당깁니다 (3/31 → 2/28).
///
/// ## `~/` 를 그냥 쓰면 안 되는 이유
/// Dart 의 `~/` 는 **0 방향으로 자릅니다**. 그래서 `-1 ~/ 12` 는 `-1` 이
/// 아니라 `0` 이고, 11월에서 11개월을 빼면 2025년 12월이 아니라 2026년
/// 12월이 나옵니다. 통계 막대 12개가 전부 미래를 가리키는 형태로 어긋납니다.
/// 그래서 개월 수를 **절대값(년*12 + 월)** 으로 바꿔 계산합니다. 이러면
/// 나눗셈이 음수로 갈 일이 없습니다.
DateTime _addMonths(DateTime t, int months) {
  final total = t.year * 12 + (t.month - 1) + months;
  final y = total ~/ 12;
  final m = (total % 12) + 1;
  final lastDay = DateTime(y, m + 1, 0).day;
  final d = t.day > lastDay ? lastDay : t.day;
  return DateTime(y, m, d);
}

/// 한 막대가 담당하는 구간.
///
/// [start] 는 포함, [end] 는 **제외**입니다. 반쯤 열린 구간으로 두면
/// 경계에 있는 항목이 두 막대에 동시에 세어지거나, 어느 막대에도 안 세어지는
/// 일이 사라집니다.
class StatsBucket {
  final DateTime start;
  final DateTime end;
  final String label;

  int total = 0;
  int done = 0;

  /// 금액이 적힌 항목들의 합 (금전출납·채무·받을돈).
  double amount = 0;

  StatsBucket({
    required this.start,
    required this.end,
    required this.label,
  });

  int get open => total - done;

  /// 이 구간의 완료율. 항목이 없으면 0 이 아니라 null 로 두고, 화면이
  /// "—" 를 그리게 합니다. 0% 와 "자료 없음"은 다른 사실입니다.
  double? get rate => total == 0 ? null : done / total;

  bool contains(DateTime d) => !d.isBefore(start) && d.isBefore(end);
}

/// 카테고리 하나의 집계.
class StatsCategory {
  final String id;
  final String label;
  final String emoji;
  final int colorValue;

  int total = 0;
  int done = 0;
  double amount = 0;

  StatsCategory({
    required this.id,
    required this.label,
    required this.emoji,
    required this.colorValue,
  });

  int get open => total - done;
  double? get rate => total == 0 ? null : done / total;
}

/// 한 기간에 대해 계산이 끝난 결과.
///
/// 화면은 이것만 받아서 그립니다. 계산이 이미 끝났으므로 `build()` 안에서
/// 반복문을 돌리지 않습니다.
class StatsSnapshot {
  final StatsRange range;

  /// 실제로 집계한 시작일. [StatsRange.all] 이면 자료의 가장 오래된 날짜입니다.
  final DateTime from;
  final DateTime to;

  final List<StatsBucket> buckets;
  final List<StatsCategory> categories;

  int total = 0;
  int done = 0;
  double amount = 0;

  /// 기한이 지났는데 아직 안 끝난 항목 수. "1년 전~전체"를 볼 때 특히
  /// 중요한 숫자입니다 — 오래된 미완료가 쌓여 있는지 바로 보입니다.
  int overdue = 0;

  StatsSnapshot({
    required this.range,
    required this.from,
    required this.to,
    required this.buckets,
    required this.categories,
  });

  int get open => total - done;
  double? get rate => total == 0 ? null : done / total;

  /// 자료가 아예 없는 기간인지. 화면이 "이 기간에는 기록이 없습니다"를
  /// 그릴지 결정합니다.
  bool get isEmpty => total == 0;

  /// 가장 많이 담긴 카테고리. 비어 있으면 null.
  StatsCategory? get busiest {
    if (categories.isEmpty) return null;
    var best = categories.first;
    for (final c in categories) {
      if (c.total > best.total) best = c;
    }
    return best.total == 0 ? null : best;
  }
}

/// 한 항목이 통계에서 갖는 값. 계산에 필요한 것만 추립니다.
///
/// `Task` 를 직접 받지 않는 이유: 이 파일이 모델에 묶이면 시험에서 매번
/// `Task` 를 만들어야 하고, 모델이 바뀔 때마다 통계 시험이 함께 깨집니다.
class StatsEntry {
  final DateTime date;
  final bool completed;

  /// 마감이 있었다면 그 날짜. 기한 초과를 세려면 "만든 날"과 구별해야 합니다.
  final DateTime? due;

  final String categoryId;
  final double amount;

  const StatsEntry({
    required this.date,
    required this.completed,
    this.due,
    this.categoryId = '',
    this.amount = 0,
  });
}

/// 반복 항목의 이번 달 발생일을 계산합니다.
///
/// ## 왜 필요한가
/// "매월 12일 관리비"는 `dueDate` 가 없습니다. 그래서 그냥 만들어진 날짜로
/// 세면 1년치 관리비 12건이 전부 같은 날 한 막대에 몰립니다. 통계가
/// 거짓말을 하는 것입니다. 반복 주기와 발생일로 이번 달 날짜를 계산합니다.
DateTime? recurrenceDate({
  required String recurrence,
  int? recurrenceDay,
  required DateTime now,
}) {
  switch (recurrence) {
    case 'daily':
      return _dayStart(now);
    case 'weekly':
      return _dayStart(now);
    case 'monthly':
      final day = recurrenceDay;
      if (day == null) return null;
      final lastDay = DateTime(now.year, now.month + 1, 0).day;
      final d = day > lastDay ? lastDay : day;
      return DateTime(now.year, now.month, d);
    default:
      return null;
  }
}

/// 기간별 막대를 만듭니다.
///
/// ## 막대 개수를 기간마다 다르게 하는 이유
/// 1년을 365개 막대로 그리면 폰 화면에서 1픽셀도 안 됩니다. 반대로 일주일을
/// 12개 막대로 그리면 하루가 0.6일씩 섞여서 "화요일에 몰렸다"를 읽을 수
/// 없습니다. 그래서 구간마다 눈금 단위를 바꿉니다:
///
///   일주일 → 7칸 (하루)
///   한달   → 5칸 (약 6일)
///   1년     → 12칸 (한 달)
///   전체    → 12칸 (한 달), 자료가 짧으면 그만큼만
List<StatsBucket> buildBuckets({
  required StatsRange range,
  required DateTime now,
  required DateTime earliest,
  String Function(DateTime start, DateTime end, int index)? labeler,
}) {
  final today = _dayStart(now);
  // 오늘 하루를 포함하므로 끝은 "내일 0시"입니다.
  final end = today.add(const Duration(days: 1));

  final out = <StatsBucket>[];

  void add(DateTime s, DateTime e, int i) {
    out.add(
      StatsBucket(
        start: s,
        end: e,
        label: labeler?.call(s, e, i) ?? '${s.month}/${s.day}',
      ),
    );
  }

  switch (range) {
    case StatsRange.week:
      for (var i = 0; i < 7; i++) {
        final s = today.subtract(Duration(days: 6 - i));
        add(s, s.add(const Duration(days: 1)), i);
      }
    case StatsRange.month:
      // 30일을 5칸으로. 마지막 칸은 반드시 오늘을 포함합니다.
      for (var i = 0; i < 5; i++) {
        final s = today.subtract(Duration(days: 29 - i * 6));
        var e = s.add(const Duration(days: 6));
        if (e.isAfter(end)) e = end;
        add(s, e, i);
      }
    case StatsRange.year:
      for (var i = 11; i >= 0; i--) {
        final s = _addMonths(DateTime(today.year, today.month, 1), -i);
        final e = _addMonths(s, 1);
        add(s, e.isAfter(end) ? end : e, 11 - i);
      }
    case StatsRange.all:
      // 자료가 시작된 달부터 이번 달까지. 최대 36칸 — 그보다 길면 3년씩
      // 묶어도 "언제 몰렸나"를 읽기에 충분합니다.
      final first = DateTime(earliest.year, earliest.month, 1);
      final nowMonth = DateTime(today.year, today.month, 1);
      var months = (nowMonth.year - first.year) * 12 +
          (nowMonth.month - first.month) +
          1;
      if (months < 1) months = 1;
      final step = months > 36 ? (months / 36).ceil() : 1;
      final starts = <DateTime>[];
      for (var i = months - 1; i >= 0; i -= step) {
        starts.add(_addMonths(nowMonth, -i));
      }
      if (starts.isEmpty) starts.add(nowMonth);
      for (var i = 0; i < starts.length; i++) {
        final s = starts[i];
        final e = i + 1 < starts.length ? starts[i + 1] : end;
        add(s, e, i);
      }
  }

  return out;
}

/// [entries] 를 [range] 기준으로 집계합니다.
///
/// [catalog] 는 카테고리 표시 정보(이름·이모지·색)입니다. 통계에 항목이
/// 하나도 없는 카테고리는 결과에서 뺍니다 — 14개 탭을 모두 0으로 그리면
/// 표가 아니라 벽이 됩니다.
StatsSnapshot computeStats({
  required List<StatsEntry> entries,
  required StatsRange range,
  required DateTime now,
  required List<StatsCategory> Function() catalog,
  String Function(DateTime start, DateTime end, int index)? labeler,
}) {
  final today = _dayStart(now);
  final endExclusive = today.add(const Duration(days: 1));

  // 자료의 가장 오래된 날짜는 "전체" 기간의 시작점이 됩니다.
  var earliest = today;
  for (final e in entries) {
    if (e.date.isBefore(earliest)) earliest = e.date;
  }

  final from = range.startFrom(now) ?? _dayStart(earliest);

  // 기간 안에 들어오는 항목만 남깁니다.
  final scoped = entries.where((e) {
    if (e.date.isBefore(from)) return false;
    if (!e.date.isBefore(endExclusive)) return false;
    return true;
  }).toList();

  final buckets = buildBuckets(
    range: range,
    now: now,
    earliest: earliest,
    labeler: labeler,
  );

  // 카테고리 표를 미리 만듭니다. 결과에만 남깁니다.
  final catMap = <String, StatsCategory>{};
  for (final c in catalog()) {
    catMap[c.id] = c;
  }

  final snap = StatsSnapshot(
    range: range,
    from: from,
    to: endExclusive.subtract(const Duration(days: 1)),
    buckets: buckets,
    // `const []` 를 넘기면 addAll 에서 터집니다. 빈 **가변** 목록이어야 합니다.
    categories: <StatsCategory>[],
  );

  for (final e in scoped) {
    snap.total++;
    if (e.completed) snap.done++;
    if (e.amount != 0) snap.amount += e.amount;

    // 기한 초과: 마감이 지났고, 아직 안 끝났고, 마감일이 기간 안.
    final due = e.due;
    if (!e.completed && due != null) {
      if (_dayStart(due).isBefore(today) && !_dayStart(due).isBefore(from)) {
        snap.overdue++;
      }
    }

    for (final b in buckets) {
      if (b.contains(e.date)) {
        b.total++;
        if (e.completed) b.done++;
        if (e.amount != 0) b.amount += e.amount;
        break;
      }
    }

    if (e.categoryId.isNotEmpty) {
      final c = catMap[e.categoryId] ??=
          StatsCategory(
            id: e.categoryId,
            label: e.categoryId,
            emoji: '',
            colorValue: 0xFF90A4AE,
          );
      c.total++;
      if (e.completed) c.done++;
      if (e.amount != 0) c.amount += e.amount;
    }
  }

  // 많이 담긴 순. 같으면 이름 순 — 순서가 실행마다 달라지면 표가 흔들립니다.
  final cats = catMap.values.where((c) => c.total > 0).toList()
    ..sort((a, b) {
      final byTotal = b.total.compareTo(a.total);
      if (byTotal != 0) return byTotal;
      return a.label.compareTo(b.label);
    });

  snap.categories.addAll(cats);
  return snap;
}

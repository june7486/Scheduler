// 통계 계산 시험.
//
// ## 왜 이 시험이 중요한가
// 통계는 "그럴듯하게 보이는" 것이 가장 위험한 기능입니다. 막대가 예쁘게
// 그려지면 아무도 숫자를 의심하지 않습니다. 그래서 여기서는 그림이 아니라
// **경계**를 검사합니다 — 오늘 자정, 기간의 첫날, 기간의 마지막 순간,
// 윤년 2월 29일, 31일에서 한 달 빼기.
//
// ## 날짜를 고정하는 이유
// `DateTime.now()` 를 쓰면 시험이 실행한 날에 따라 결과가 달라집니다.
// 3월 31일에 통과하고 4월 1일에 실패하는 시험은 시험이 아니라 함정입니다.
// 그래서 모든 시험이 `now` 를 직접 넘깁니다.

import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/stats.dart';

void main() {
  group('기간 시작점', () {
    test('일주일 전 오늘은 오늘 포함 7일이다', () {
      final now = DateTime(2026, 11, 21, 14, 30);
      final from = StatsRange.week.startFrom(now)!;
      expect(from, DateTime(2026, 11, 15));
      // 시각이 0시로 맞춰져야 오늘 항목이 빠지지 않습니다.
      expect(from.hour, 0);
      final days = DateTime(2026, 11, 22).difference(from).inDays;
      expect(days, 7, reason: '오늘 포함 7일이어야 합니다');
    });

    test('한 달 전 오늘은 오늘 포함 30일이다', () {
      final now = DateTime(2026, 11, 21, 14, 30);
      final from = StatsRange.month.startFrom(now)!;
      expect(from, DateTime(2026, 10, 23));
      expect(DateTime(2026, 11, 22).difference(from).inDays, 30);
    });

    test('1년 전은 달력으로 뺀다 — 윤년에 하루 밀리지 않는다', () {
      // 2028 은 윤년. 2/29 에서 365일을 빼면 2027/3/1 이 되어 버립니다.
      final from = StatsRange.year.startFrom(DateTime(2028, 2, 29, 9))!;
      expect(from, DateTime(2027, 2, 28));
    });

    test('전체 기간은 시작점이 없다 (자료가 정한다)', () {
      expect(StatsRange.all.startFrom(DateTime(2026, 11, 21)), isNull);
    });
  });

  group('막대 구간', () {
    test('일주일은 7칸이고 오늘을 포함한다', () {
      final now = DateTime(2026, 11, 21, 23, 59);
      final b = buildBuckets(
        range: StatsRange.week,
        now: now,
        earliest: now,
      );
      expect(b.length, 7);
      expect(b.last.contains(DateTime(2026, 11, 21, 23, 59)), isTrue);
      expect(b.last.contains(DateTime(2026, 11, 22)), isFalse,
          reason: '끝은 제외여야 내일 항목이 섞이지 않습니다');
      expect(b.first.contains(DateTime(2026, 11, 15)), isTrue);
      expect(b.first.contains(DateTime(2026, 11, 14, 23, 59)), isFalse);
    });

    test('한 달은 5칸이고 빈틈이 없다', () {
      final now = DateTime(2026, 11, 21, 10);
      final b = buildBuckets(range: StatsRange.month, now: now, earliest: now);
      expect(b.length, 5);
      for (var i = 1; i < b.length; i++) {
        expect(
          b[i].start,
          b[i - 1].end,
          reason: '칸 사이에 빈틈이 있으면 항목이 사라집니다',
        );
      }
      expect(b.last.contains(now), isTrue);
    });

    test('1년은 12칸이고 라벨이 달 단위다', () {
      final now = DateTime(2026, 11, 21);
      final b = buildBuckets(range: StatsRange.year, now: now, earliest: now);
      expect(b.length, 12);
      expect(b.last.contains(now), isTrue);
      expect(b.first.start, DateTime(2025, 12, 1));
      // 마지막 칸이 미래까지 뻗지 않아야 합니다.
      expect(b.last.end, DateTime(2026, 11, 22));
    });

    test('전체 기간 — 자료가 3개월이면 3칸이다', () {
      final now = DateTime(2026, 11, 21);
      final b = buildBuckets(
        range: StatsRange.all,
        now: now,
        earliest: DateTime(2026, 9, 5),
      );
      expect(b.length, 3, reason: '9월·10월·11월');
      expect(b.first.start, DateTime(2026, 9, 1));
      expect(b.last.contains(now), isTrue);
    });

    test('전체 기간 — 10년치도 36칸을 넘지 않는다', () {
      final now = DateTime(2026, 11, 21);
      final b = buildBuckets(
        range: StatsRange.all,
        now: now,
        earliest: DateTime(2014, 1, 1),
      );
      expect(b.length, lessThanOrEqualTo(36));
      expect(b.last.contains(now), isTrue);
      expect(b.first.contains(DateTime(2014, 1, 15)), isTrue);
    });
  });

  group('집계', () {
    final now = DateTime(2026, 11, 21, 12);

    List<StatsCategory> catalog() => [
      StatsCategory(
        id: 'todo',
        label: '할일',
        emoji: '✅',
        colorValue: 0xFF42A5F5,
      ),
      StatsCategory(
        id: 'finance',
        label: '금전출납',
        emoji: '💰',
        colorValue: 0xFFFFA726,
      ),
    ];

    test('기간 밖 항목은 세지 않는다', () {
      final snap = computeStats(
        entries: [
          StatsEntry(
            date: DateTime(2026, 11, 21),
            completed: true,
            categoryId: 'todo',
          ),
          // 8일 전 — 일주일 기간 밖
          StatsEntry(
            date: DateTime(2026, 11, 13),
            completed: true,
            categoryId: 'todo',
          ),
        ],
        range: StatsRange.week,
        now: now,
        catalog: catalog,
      );
      expect(snap.total, 1);
      expect(snap.done, 1);
    });

    test('완료율 — 항목이 없으면 0% 가 아니라 null 이다', () {
      final empty = computeStats(
        entries: const [],
        range: StatsRange.week,
        now: now,
        catalog: catalog,
      );
      expect(empty.isEmpty, isTrue);
      expect(empty.rate, isNull, reason: '"자료 없음"과 "0%"는 다른 사실입니다');

      final half = computeStats(
        entries: [
          StatsEntry(date: now, completed: true, categoryId: 'todo'),
          StatsEntry(date: now, completed: false, categoryId: 'todo'),
        ],
        range: StatsRange.week,
        now: now,
        catalog: catalog,
      );
      expect(half.rate, 0.5);
    });

    test('기한 초과 — 마감이 지났고 미완료인 것만 센다', () {
      final snap = computeStats(
        entries: [
          // 3일 전 마감, 미완료 → 초과
          StatsEntry(
            date: DateTime(2026, 11, 18),
            completed: false,
            due: DateTime(2026, 11, 18),
            categoryId: 'todo',
          ),
          // 3일 전 마감, 완료 → 초과 아님
          StatsEntry(
            date: DateTime(2026, 11, 18),
            completed: true,
            due: DateTime(2026, 11, 18),
            categoryId: 'todo',
          ),
          // 마감이 오늘 → 아직 안 지났다
          StatsEntry(
            date: now,
            completed: false,
            due: now,
            categoryId: 'todo',
          ),
        ],
        range: StatsRange.week,
        now: now,
        catalog: catalog,
      );
      expect(snap.overdue, 1);
    });

    test('금액은 기간 안 항목만 더한다', () {
      final snap = computeStats(
        entries: [
          StatsEntry(
            date: DateTime(2026, 11, 20),
            completed: true,
            categoryId: 'finance',
            amount: 50000,
          ),
          StatsEntry(
            date: DateTime(2026, 11, 19),
            completed: false,
            categoryId: 'finance',
            amount: -20000,
          ),
          // 기간 밖
          StatsEntry(
            date: DateTime(2026, 10, 1),
            completed: true,
            categoryId: 'finance',
            amount: 999999,
          ),
        ],
        range: StatsRange.week,
        now: now,
        catalog: catalog,
      );
      expect(snap.amount, 30000);
    });

    test('항목 없는 카테고리는 결과에서 뺀다', () {
      final snap = computeStats(
        entries: [
          StatsEntry(date: now, completed: true, categoryId: 'todo'),
        ],
        range: StatsRange.week,
        now: now,
        catalog: catalog,
      );
      expect(snap.categories.length, 1);
      expect(snap.categories.first.id, 'todo');
      expect(snap.busiest?.id, 'todo');
    });

    test('분류가 없는 항목도 사라지지 않는다', () {
      // 카테고리를 지웠는데 항목이 남은 경우. 합계에서 빠지면
      // "합계 3인데 막대 합은 2" 같은 거짓말이 됩니다.
      final snap = computeStats(
        entries: [
          StatsEntry(date: now, completed: true, categoryId: ''),
          StatsEntry(date: now, completed: true, categoryId: 'ghost'),
        ],
        range: StatsRange.week,
        now: now,
        catalog: catalog,
      );
      expect(snap.total, 2);
      expect(snap.categories.any((c) => c.id == 'ghost'), isTrue);
    });

    test('막대 합계와 전체 합계가 같다 — 항목이 두 번 세어지지 않는다', () {
      final entries = <StatsEntry>[];
      for (var d = 0; d < 20; d++) {
        entries.add(
          StatsEntry(
            date: DateTime(2026, 11, 21).subtract(Duration(days: d)),
            completed: d.isEven,
            categoryId: 'todo',
          ),
        );
      }
      for (final range in StatsRange.values) {
        final snap = computeStats(
          entries: entries,
          range: range,
          now: now,
          catalog: catalog,
        );
        final bucketSum = snap.buckets.fold<int>(0, (a, b) => a + b.total);
        expect(
          bucketSum,
          snap.total,
          reason: '$range: 막대 합($bucketSum) ≠ 합계(${snap.total})',
        );
        final doneSum = snap.buckets.fold<int>(0, (a, b) => a + b.done);
        expect(doneSum, snap.done, reason: '$range: 완료 합이 다릅니다');
      }
    });

    test('전체 기간은 자료의 첫 날부터 센다', () {
      final snap = computeStats(
        entries: [
          StatsEntry(
            date: DateTime(2024, 3, 2),
            completed: true,
            categoryId: 'todo',
          ),
          StatsEntry(date: now, completed: false, categoryId: 'todo'),
        ],
        range: StatsRange.all,
        now: now,
        catalog: catalog,
      );
      expect(snap.total, 2);
      expect(snap.from, DateTime(2024, 3, 2));
    });
  });

  group('반복 항목 날짜', () {
    test('매월 12일은 이번 달 12일로 계산된다', () {
      expect(
        recurrenceDate(
          recurrence: 'monthly',
          recurrenceDay: 12,
          now: DateTime(2026, 11, 21),
        ),
        DateTime(2026, 11, 12),
      );
    });

    test('2월에 31일 반복은 그 달 마지막 날로 당긴다', () {
      expect(
        recurrenceDate(
          recurrence: 'monthly',
          recurrenceDay: 31,
          now: DateTime(2027, 2, 10),
        ),
        DateTime(2027, 2, 28),
      );
      // 윤년 2월은 29일
      expect(
        recurrenceDate(
          recurrence: 'monthly',
          recurrenceDay: 31,
          now: DateTime(2028, 2, 10),
        ),
        DateTime(2028, 2, 29),
      );
    });

    test('반복이 아니면 null 이다', () {
      expect(
        recurrenceDate(recurrence: 'none', recurrenceDay: 5, now: DateTime(2026)),
        isNull,
      );
    });
  });
}

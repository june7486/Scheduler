// 견본 자료 시험.
//
// ## 여기서 지키려는 것
// `test` 계정의 견본은 **기기마다 만들어집니다.** 그래서 이 자료가 조금이라도
// 실행할 때마다 달라지면, 폰과 노트북의 자료가 동기화로 합쳐져 같은 계정에
// 1년치가 두 벌 생깁니다. 사용자는 그걸 보고 앱을 의심합니다.
//
// 그래서 이 시험의 절반은 "결정론"을 검사합니다: 같은 날 두 번 만들면
// **완전히 같은** 결과여야 합니다.

import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/demo_seed.dart';
import 'package:june_scheduler/services/stats.dart';

void main() {
  final now = DateTime(2026, 11, 21, 14, 30);

  group('결정론 — 두 기기가 같은 자료를 만든다', () {
    test('같은 날 두 번 만들면 id·제목·날짜가 모두 같다', () {
      final a = buildDemoYear(now: now, ko: true);
      final b = buildDemoYear(now: now, ko: true);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].id, b[i].id, reason: '$i번째 id');
        expect(a[i].title, b[i].title, reason: '$i번째 제목');
        expect(a[i].createdAt, b[i].createdAt, reason: '$i번째 날짜');
      }
    });

    test('id 가 겹치지 않는다 — 겹치면 동기화에서 덮어쓴다', () {
      final items = buildDemoYear(now: now, ko: true);
      final ids = items.map((e) => e.id).toSet();
      expect(ids.length, items.length, reason: '중복 id 가 있습니다');
    });

    test('id 가 매번 새 uuid 가 아니다 (동기화 키로 쓸 수 있다)', () {
      // uuid 였다면 실행마다 달라져 기기마다 자료가 쌓입니다.
      final items = buildDemoYear(now: now, ko: true);
      for (final i in items) {
        expect(i.id.startsWith('demo:'), isTrue, reason: '고정 접두사가 없습니다');
      }
    });

    test('언어가 달라도 id 와 날짜는 같다 (제목만 다르다)', () {
      final ko = buildDemoYear(now: now, ko: true);
      final en = buildDemoYear(now: now, ko: false);
      expect(ko.length, en.length);
      for (var i = 0; i < ko.length; i++) {
        expect(ko[i].id, en[i].id);
        expect(ko[i].createdAt, en[i].createdAt);
      }
      // 제목은 실제로 달라야 합니다 (번역이 빠졌다는 증거).
      expect(ko.first.title, isNot(en.first.title));
    });
  });

  group('1년치라는 약속', () {
    test('12개월 전부터 지금까지 걸쳐 있다', () {
      final items = buildDemoYear(now: now, ko: true);
      final dates = items.map((e) => e.createdAt).toList()
        ..sort((a, b) => a.compareTo(b));
      expect(dates.first.year, 2025, reason: '작년 자료가 있어야 합니다');
      expect(dates.first.month, lessThanOrEqualTo(11));
      expect(dates.last.isAfter(DateTime(2026, 10, 31)), isTrue);
    });

    test('한 달도 빠지지 않는다', () {
      final items = buildDemoYear(now: now, ko: true)
          .where((e) => !e.id.startsWith('demo:recurring'))
          .toList();
      final months = <String>{};
      for (final i in items) {
        months.add('${i.createdAt.year}-${i.createdAt.month}');
      }
      // 2025-12 ~ 2026-11 = 12개월
      expect(months.length, greaterThanOrEqualTo(12),
          reason: '빠진 달이 있습니다: $months');
    });

    test('항목이 너무 많지도 적지도 않다', () {
      final items = buildDemoYear(now: now, ko: true);
      // 1년에 200건을 넘으면 표가 벽이 되고, 100건 미만이면 "이게 1년?" 입니다.
      expect(items.length, greaterThan(140));
      expect(items.length, lessThan(300));
    });

    test('미래 날짜가 섞여 있지 않다', () {
      final items = buildDemoYear(now: now, ko: true);
      for (final i in items) {
        expect(
          i.createdAt.isAfter(DateTime(2026, 11, 21, 23, 59)),
          isFalse,
          reason: '미래 항목: ${i.title} ${i.createdAt}',
        );
      }
    });
  });

  group('안내 — 처음 온 사람이 읽을 것', () {
    test('처음 사용자·사용법·통계·만든이 네 장이 있고 맨 위에 온다', () {
      final items = buildDemoYear(now: now, ko: true);
      final guides = items.where((e) => e.id.startsWith('demo:guide:')).toList();
      expect(guides.length, 4);
      expect(guides.first.id, demoGuideAnchorId);
      // order 가 음수라서 실제 일정보다 위에 옵니다.
      for (final g in guides) {
        expect(g.order, lessThan(0));
        expect(g.pinned, isTrue, reason: '안내는 고정되어야 눈에 띕니다');
      }
    });

    test('안내 본문에 실제로 안내가 적혀 있다', () {
      final items = buildDemoYear(now: now, ko: true);
      final text = items
          .where((e) => e.id.startsWith('demo:guide:'))
          .map((e) => '${e.title}\n${e.note}')
          .join('\n');
      expect(text.contains('test'), isTrue);
      expect(text.contains('사용법'), isTrue);
      expect(text.contains('통계'), isTrue);
      expect(text.contains('이승준'), isTrue);
    });

    test('영어 견본에는 한글이 섞이지 않는다', () {
      final items = buildDemoYear(now: now, ko: false);
      final korean = RegExp(r'[가-힣]');
      for (final i in items) {
        expect(korean.hasMatch(i.title), isFalse,
            reason: '한글 제목: ${i.title}');
        expect(korean.hasMatch(i.note), isFalse,
            reason: '한글 메모: ${i.note}');
      }
    });
  });

  group('통계가 견본에서 의미 있게 보인다', () {
    /// 견본을 통계 입력으로 바꿉니다. 화면이 하는 일과 같습니다.
    List<StatsEntry> entriesOf(List<DemoItem> items) => [
      for (final i in items)
        StatsEntry(
          date: i.dueDate ?? i.createdAt,
          completed: i.completed,
          due: i.dueDate,
          categoryId: i.categoryId,
          amount: i.amount ?? 0,
        ),
    ];

    test('모든 기간에 자료가 있다 — 빈 화면이 뜨면 견본의 뜻이 없다', () {
      final entries = entriesOf(buildDemoYear(now: now, ko: true));
      for (final range in StatsRange.values) {
        final snap = computeStats(
          entries: entries,
          range: range,
          now: now,
          catalog: () => const [],
        );
        expect(snap.isEmpty, isFalse, reason: '$range 기간이 비어 있습니다');
      }
    });

    test('완료율이 0%도 100%도 아니다 — 둘 다 견본으로 부자연스럽다', () {
      final entries = entriesOf(buildDemoYear(now: now, ko: true));
      final snap = computeStats(
        entries: entries,
        range: StatsRange.all,
        now: now,
        catalog: () => const [],
      );
      expect(snap.rate, greaterThan(0.4));
      expect(snap.rate, lessThan(0.98));
    });

    test('기한 초과가 0이 아니다 — 그 숫자의 뜻을 견본에서 볼 수 있어야', () {
      final entries = entriesOf(buildDemoYear(now: now, ko: true));
      final snap = computeStats(
        entries: entries,
        range: StatsRange.all,
        now: now,
        catalog: () => const [],
      );
      expect(snap.overdue, greaterThan(0));
    });

    test('금액 합계가 0이 아니다', () {
      final entries = entriesOf(buildDemoYear(now: now, ko: true));
      final snap = computeStats(
        entries: entries,
        range: StatsRange.all,
        now: now,
        catalog: () => const [],
      );
      expect(snap.amount, greaterThan(0));
    });

    test('분류가 한쪽에 몰리지 않는다', () {
      final entries = entriesOf(buildDemoYear(now: now, ko: true));
      final snap = computeStats(
        entries: entries,
        range: StatsRange.all,
        now: now,
        catalog: () => const [],
      );
      expect(snap.categories.length, greaterThanOrEqualTo(8),
          reason: '분류가 ${snap.categories.length}개뿐입니다');
    });
  });
}

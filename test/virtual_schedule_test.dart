// 가상 일정으로 저장·재조회·반복·시간대를 검사한다.
//
// ## 왜 이 파일이 따로 있는가
// 제출 패키지(가비아)의 README 가 "가상 일정으로 반복·시간대를 검사한다" 고
// 적는데, 실제로 그런 테스트가 없었습니다. 문서가 사실보다 앞서 나가면
// 그건 증빙이 아니라 주장입니다. 그래서 검사를 실제로 만듭니다.
//
// ## 원칙
// 실제 일정·계정·캘린더를 쓰지 않습니다. 전부 메모리 안의 가상 데이터입니다.

import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/models/models.dart';

void main() {
  group('가상 일정 — 저장·재조회 왕복', () {
    test('모든 필드가 toMap → fromMap 왕복에서 보존된다', () {
      final t = Task(
        id: 'virt-001',
        title: '가상 회의',
        categoryId: 'cat-work',
        categoryIds: ['cat-work', 'cat-team'],
        dueDate: DateTime(2026, 11, 20, 9, 30),
        recurrence: 'weekly',
        recurrenceDay: 4,
        amount: 12000,
        relatedTo: '가상 담당자',
        pinned: true,
        longTerm: false,
        updatedAt: 1763631000000,
      );

      final back = Task.fromMap(t.toMap());

      expect(back.id, t.id);
      expect(back.title, t.title);
      expect(back.categoryId, t.categoryId);
      expect(back.categoryIds, t.categoryIds);
      expect(back.dueDate, t.dueDate);
      expect(back.recurrence, 'weekly');
      expect(back.recurrenceDay, 4);
      expect(back.amount, 12000);
      expect(back.relatedTo, '가상 담당자');
      expect(back.pinned, isTrue);
      expect(back.longTerm, isFalse);
      expect(back.updatedAt, 1763631000000);
    });

    test('두 번 왕복해도 값이 흔들리지 않는다 (멱등성)', () {
      final t = Task(
        id: 'virt-002',
        title: '가상 반복 점검',
        categoryId: 'c1',
        dueDate: DateTime(2026, 3, 1, 0, 0),
        recurrence: 'monthly',
        recurrenceDay: 1,
      );
      final once = Task.fromMap(t.toMap());
      final twice = Task.fromMap(once.toMap());
      expect(twice.dueDate, once.dueDate);
      expect(twice.recurrence, once.recurrence);
      expect(twice.recurrenceDay, once.recurrenceDay);
    });
  });

  group('반복 일정 — 실제로 구현된 값만 검사한다', () {
    // 앱이 실제로 쓰는 네 값. 없는 값을 테스트하면 통과해도 의미가 없다.
    const supported = ['none', 'daily', 'weekly', 'monthly'];

    test('네 가지 반복 값이 모두 왕복에서 보존된다', () {
      for (final r in supported) {
        final t = Task(id: 'r-$r', title: '반복 $r', categoryId: 'c', recurrence: r);
        expect(Task.fromMap(t.toMap()).recurrence, r, reason: '$r 보존 실패');
      }
    });

    test('기본값은 none 이다', () {
      final t = Task(id: 'r-def', title: '기본', categoryId: 'c');
      expect(t.recurrence, 'none');
      expect(Task.fromMap(t.toMap()).recurrence, 'none');
    });

    test('monthly 의 recurrenceDay 가 살아남는다', () {
      final t = Task(
        id: 'r-m',
        title: '월세',
        categoryId: 'c-fin',
        recurrence: 'monthly',
        recurrenceDay: 25,
      );
      expect(Task.fromMap(t.toMap()).recurrenceDay, 25);
    });

    test('dueDate 가 없어도 반복 설정은 유지된다', () {
      final t = Task(id: 'r-nd', title: '날짜 없는 반복', categoryId: 'c', recurrence: 'daily');
      final back = Task.fromMap(t.toMap());
      expect(back.dueDate, isNull);
      expect(back.recurrence, 'daily');
    });
  });

  group('시간대 — 저장 형식이 시간대를 흔들지 않는가', () {
    test('dueDate 는 ISO-8601 이고 시간대 접미사가 없다', () {
      final t = Task(
        id: 'tz-001',
        title: '시간대 점검',
        categoryId: 'c',
        dueDate: DateTime(2026, 11, 20, 9, 30),
      );
      final s = t.toMap()['dueDate'] as String;

      // 이 앱의 설계: 시간대 정보를 저장하지 않는다(벽시계 시각).
      // 접미사가 붙으면 다른 기기에서 시각이 밀린다.
      expect(s.contains('Z'), isFalse, reason: 'UTC 표식이 붙으면 안 된다');
      expect(s.contains('+'), isFalse, reason: '양수 오프셋이 붙으면 안 된다');

      // 되읽었을 때 같은 벽시계 시각이어야 한다
      final back = Task.fromMap(t.toMap());
      expect(back.dueDate!.year, 2026);
      expect(back.dueDate!.month, 11);
      expect(back.dueDate!.day, 20);
      expect(back.dueDate!.hour, 9);
      expect(back.dueDate!.minute, 30);
    });

    test('자정·월말 경계에서도 날짜가 하루 밀리지 않는다', () {
      final cases = [
        DateTime(2026, 1, 1, 0, 0),   // 연초 자정
        DateTime(2026, 12, 31, 23, 59), // 연말 심야
        DateTime(2028, 2, 29, 12, 0), // 윤일
      ];
      for (final d in cases) {
        final t = Task(id: 'tz-${d.millisecondsSinceEpoch}', title: 't', categoryId: 'c', dueDate: d);
        final back = Task.fromMap(t.toMap()).dueDate!;
        expect(back.year, d.year, reason: '$d 연도 밀림');
        expect(back.month, d.month, reason: '$d 월 밀림');
        expect(back.day, d.day, reason: '$d 일 밀림');
        expect(back.hour, d.hour, reason: '$d 시 밀림');
      }
    });

    test('updatedAt 은 epoch 밀리초 정수로 남는다 (문자열 아님)', () {
      final t = Task(id: 'tz-ms', title: 't', categoryId: 'c', updatedAt: 1763631000123);
      final raw = t.toMap()['updatedAt'];
      expect(raw, isA<int>());
      expect(Task.fromMap(t.toMap()).updatedAt, 1763631000123);
    });
  });
}

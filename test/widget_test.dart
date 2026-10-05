import 'package:flutter_test/flutter_test.dart';

import 'package:june_scheduler/models/models.dart';

void main() {
  test('Task serialises and deserialises', () {
    final t = Task(
      id: '1',
      title: 'Pay rent',
      categoryId: 'repeat',
      amount: 2500000,
    );
    final map = t.toMap();
    final back = Task.fromMap(map);
    expect(back.title, 'Pay rent');
    expect(back.amount, 2500000);
    expect(back.categoryId, 'repeat');
  });
}

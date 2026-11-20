// 새 기기에서 로그인이 되는지, 라이브 게이트웨이에 직접 물어본다.
//
// 실제 사고: 데스크탑 크롬은 되는데 다른 기기에서는 로그인이 안 됐다.
// 원인 후보를 배제하기 위해 앱이 쓰는 경로를 그대로 실행한다.
//
//   LIVE_URL=<게이트웨이 주소> LIVE_KEY=<공유키> LIVE_PW=<비밀번호> \
//     flutter test test/live_login_probe_test.dart
//
// 값을 넘기지 않으면 조용히 건너뛴다 (저장소에 주소·비밀번호를 두지 않는다).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/cloud/nas_backend.dart';
import 'package:june_scheduler/services/store.dart';

// ## 왜 주소를 상수로 박지 않는가
// 이 파일도 소스 패키지에 들어갑니다. 실제 DDNS 주소를 기본값으로 두면
// (1) 제출물이 그 주소를 다시 유통시키고 (2) 테스트가 남의 서버를 두드립니다.
// 주소는 LIVE_URL 환경변수로만 받습니다. 없으면 아래에서 skip 됩니다.
const _id = 'june7486';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final url = Platform.environment['LIVE_URL'] ?? '';
  final key = Platform.environment['LIVE_KEY'] ?? '';
  final pw = Platform.environment['LIVE_PW'] ?? '';
  final skip = url.isEmpty || key.isEmpty || pw.isEmpty;

  test('라이브 게이트웨이 진단이 ok', () async {
    final d = await NasBackend(baseUrl: url, secret: key).diagnose();
    // ignore: avoid_print
    print('diagnose = $d');
    expect(d, NasDiagnosis.ok);
  }, skip: skip);

  test('레지스트리에서 이 계정을 찾고 비밀번호를 검증한다', () async {
    final backend = NasBackend(baseUrl: url, secret: key);
    final doc = await backend.read(Store.registryWorkspaceId);

    // ignore: avoid_print
    print('registry exists=${doc.exists} rev=${doc.rev}');
    for (final e in doc.entities.entries) {
      // ignore: avoid_print
      print('  $e'.split(':').first);
    }

    final row = doc.entities['accounts/$_id'];
    expect(row, isNotNull, reason: '레지스트리에 계정 행이 있어야 한다');

    final record = Map<dynamic, dynamic>.from(row as Map);
    // ignore: avoid_print
    print('  pwHash 있음: ${record['pwHash'] != null}');
    // ignore: avoid_print
    print('  password 필드: ${record.containsKey('password')}');

    final ok = Store.verifyAccountPassword(record, pw);
    // ignore: avoid_print
    print('verifyAccountPassword = $ok');
    expect(ok, isTrue, reason: '레지스트리 해시로 비밀번호가 검증되어야 한다');
  }, skip: skip);

  test('워크스페이스 사본만으로도 비밀번호를 검증할 수 있다 (해시 치유 확인)', () async {
    final backend = NasBackend(baseUrl: url, secret: key);
    final ws = Store.workspaceCodeFor(_id);
    final doc = await backend.read(ws);

    // ignore: avoid_print
    print('workspace $ws exists=${doc.exists} rev=${doc.rev}');
    final row = doc.entities['accounts/$_id'];
    expect(row, isNotNull);

    final record = Map<dynamic, dynamic>.from(row as Map);
    // ignore: avoid_print
    print('  password 필드: ${record.containsKey('password')}');
    final hash = record['pwHash'];
    // ignore: avoid_print
    print('  pwHash: ${hash == null ? '없음' : '${(hash as String).substring(0, 16)}…'}');

    expect(record.containsKey('password'), isFalse,
        reason: '워크스페이스 사본에 평문이 있으면 안 된다');
    expect(hash, isNotNull, reason: '새 기기는 이 해시로 검증한다');
    expect(Store.verifyAccountPassword(record, pw), isTrue);
  }, skip: skip);

  test('작업 데이터가 실제로 들어 있다', () async {
    final backend = NasBackend(baseUrl: url, secret: key);
    final doc = await backend.read(Store.workspaceCodeFor(_id));
    final tasks = doc.entities.keys.where((k) => k.startsWith('tasks/')).length;
    final cats = doc.entities.keys.where((k) => k.startsWith('categories/')).length;
    // ignore: avoid_print
    print('tasks=$tasks categories=$cats');
    expect(tasks, greaterThan(0));
    expect(cats, greaterThan(0));
  }, skip: skip);
}

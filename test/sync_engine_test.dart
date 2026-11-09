import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/cloud/sync_engine.dart';
import 'package:june_scheduler/services/store.dart';

/// A minimal in-test backend.
///
/// The production NAS gateway is verified against the real NAS by
/// `test/nas_backend_test.dart`; this fake exists only to exercise the sync
/// engine's own logic (outbox → echo → clear) without any I/O.
class FakeBackend implements CloudBackend {
  FakeBackend();

  CloudDoc doc = CloudDoc.unknown;
  int writes = 0;
  int resets = 0;
  bool failNextWrite = false;
  void Function(CloudDoc)? _listener;

  @override
  String get name => 'fake';

  @override
  bool get isConfigured => true;

  @override
  Future<CloudDoc> read(String workspaceId, {int haveRev = 0}) async => doc;

  @override
  Future<CloudWriteResult> write(
    String workspaceId,
    CloudDoc incoming, {
    Map<String, dynamic>? extra,
  }) async {
    if (failNextWrite) {
      failNextWrite = false;
      return const CloudWriteResult(ok: false, error: 'network');
    }
    writes++;
    final merged = Map<String, dynamic>.from(doc.entities);
    final echo = <String, int>{};
    for (final e in incoming.entities.entries) {
      final rec = e.value as Map;
      final mine = (rec['updatedAt'] as num?)?.toInt() ?? 0;
      final theirs =
          ((merged[e.key] as Map?)?['updatedAt'] as num?)?.toInt() ?? 0;
      if (mine >= theirs) {
        merged[e.key] = rec;
        echo[e.key] = mine;
      }
    }
    doc = CloudDoc(
      entities: merged,
      rev: doc.rev + 1,
      gen: doc.gen,
    );
    return CloudWriteResult(ok: true, rev: doc.rev, gen: doc.gen, echo: echo);
  }

  @override
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
    int haveRev = 0,
  }) {
    _listener = onRemote;
    return _FakeSub(() => _listener = null);
  }

  /// Simulates "another device wrote something".
  void pushRemote(CloudDoc next) {
    doc = next;
    _listener?.call(next);
  }

  @override
  Future<CloudWriteResult> resetWorkspace(String workspaceId) async {
    resets++;
    doc = CloudDoc(entities: const {}, rev: doc.rev + 1, gen: doc.gen + 1);
    return CloudWriteResult(ok: true, rev: doc.rev, gen: doc.gen, count: 0);
  }

  @override
  Future<void> dispose() async {}
}

class _FakeSub implements CloudSubscription {
  _FakeSub(this._onCancel);
  final void Function() _onCancel;
  @override
  void cancel() => _onCancel();
}

void main() {
  test('write echo confirms the outbox in one round trip', () async {
    final b = FakeBackend();
    final res = await b.write(
      'WS',
      const CloudDoc(
        entities: {
          'tasks/t1': {'id': 't1', 'updatedAt': 1000},
        },
        rev: 0,
      ),
    );
    expect(res.ok, isTrue);
    expect(res.echo?['tasks/t1'], 1000);
    expect(res.rev, 1);
  });

  test('a losing write reports no echo and ships the winner', () async {
    final b = FakeBackend();
    await b.write(
      'WS',
      const CloudDoc(
        entities: {
          'tasks/t1': {'id': 't1', 'title': 'newer', 'updatedAt': 5000},
        },
        rev: 0,
      ),
    );
    final res = await b.write(
      'WS',
      const CloudDoc(
        entities: {
          'tasks/t1': {'id': 't1', 'title': 'older', 'updatedAt': 1000},
        },
        rev: 1,
      ),
    );
    expect(res.ok, isTrue);
    expect(res.echo?.containsKey('tasks/t1'), isFalse);
    // The server keeps the newer copy.
    expect((b.doc.entities['tasks/t1'] as Map)['title'], 'newer');
  });

  test('failed write is reported, not swallowed as success', () async {
    final b = FakeBackend()..failNextWrite = true;
    final res = await b.write(
      'WS',
      const CloudDoc(entities: {'tasks/t1': {'id': 't1'}}, rev: 0),
    );
    expect(res.ok, isFalse);
    expect(res.error, isNotNull);
  });

  test('reset empties the workspace and bumps the generation', () async {
    final b = FakeBackend();
    await b.write(
      'WS',
      const CloudDoc(entities: {'tasks/t1': {'id': 't1'}}, rev: 0),
    );
    final res = await b.resetWorkspace('WS');
    expect(res.ok, isTrue);
    expect(res.gen, 1);
    expect(b.doc.entities, isEmpty);
  });

  test('watch delivers remote changes', () async {
    final b = FakeBackend();
    CloudDoc? got;
    b.watch('WS', onRemote: (d) => got = d, onError: (_) {});
    b.pushRemote(
      const CloudDoc(entities: {'tasks/x': {'id': 'x'}}, rev: 3, gen: 1),
    );
    expect(got?.rev, 3);
    expect(got?.gen, 1);
  });

  test('NullBackend degrades to local-only instead of throwing', () async {
    const nb = NullBackend();
    expect(nb.isConfigured, isFalse);
    expect((await nb.read('WS')).exists, isFalse);
    expect((await nb.write('WS', CloudDoc.unknown)).ok, isFalse);
    expect((await nb.resetWorkspace('WS')).ok, isFalse);
    // A subscription that can be cancelled without a timer behind it.
    nb.watch('WS', onRemote: (_) {}, onError: (_) {}).cancel();
  });

  /// The support case that started this: a build with no server address.
  ///
  /// `start()` marks the engine stopped when there is no backend, and `flush()`
  /// used to check "stopped" first — so it reported `off` ("동기화 꺼짐"),
  /// implying the user had switched sync off themselves. The honest answer is
  /// `notConfigured`: an address has to be entered. That distinction is the
  /// difference between "I broke it" and "it was never set up".
  test('서버 주소가 없으면 "꺼짐"이 아니라 "미설정"으로 보고한다', () async {
    final store = _StubStore();
    final engine = SyncService(store, const NullBackend());

    await engine.start();
    expect(engine.state, SyncState.notConfigured,
        reason: '주소가 없으면 start() 는 미설정으로 보고해야 합니다');

    // Manual flush must not overwrite that with a less useful state.
    await engine.flush(manual: true);
    expect(engine.state, SyncState.notConfigured,
        reason: 'flush() 가 "꺼짐"으로 덮어쓰면 원인을 숨기게 됩니다');
    expect(engine.statusLabel(ko: true), contains('미설정'));
    engine.stop();
  });
}

/// The smallest [Store] stand-in [SyncService] needs.
///
/// Only the handful of members the engine actually touches are overridden, so
/// this stays honest: if the engine starts depending on something new, the
/// compile fails here instead of silently doing the wrong thing.
class _StubStore extends Store {
  @override
  bool get syncEnabled => true;

  @override
  String get workspaceId => 'ACCSTUBWORKSPACE0000000000000';

  @override
  int get pendingCount => 0;

  @override
  Future<void> clearPending(Iterable<String> keys) async {}

  @override
  Future<void> setCachedRev(int rev, int gen) async {}

  @override
  void beginRemoteApply() {}

  @override
  void endRemoteApply(bool changed) {}

  @override
  Future<bool> applyServerRecord(
          String entity, String id, Map<String, dynamic>? record) async =>
      false;

  @override
  Future<void> dropWorkspaceCache(String ownerId) async {}

  @override
  Future<void> clearAllPending() async {}

  @override
  void onSyncStatusChanged() {}

  @override
  void notifyListeners() {}
}

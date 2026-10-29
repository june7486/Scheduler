import 'dart:async';

import 'package:june_scheduler/services/cloud/cloud_backend.dart';

/// A [CloudBackend] backed by a plain map — used by tests to exercise the sync
/// engine without a live Firestore project.
///
/// It deliberately mimics the parts of Firestore the engine relies on:
/// * a transaction-style merge (last-writer-wins on `updatedAt`),
/// * push notifications to every subscriber,
/// * an "unknown" answer for a workspace that was never written.
class MemoryBackend implements CloudBackend {
  final Map<String, Map<String, dynamic>> _store = {};
  final List<_Sub> _subs = [];
  final List<String> log = [];

  /// Simulates a read/write failure.
  bool offline = false;

  @override
  String get name => 'Memory';

  @override
  bool get isConfigured => true;

  @override
  Future<CloudDoc> read(String workspaceId) async {
    if (offline) throw const CloudException('unavailable');
    log.add('read $workspaceId');
    final data = _store[workspaceId];
    if (data == null) return CloudDoc.unknown;
    return _toDoc(data);
  }

  @override
  Future<CloudWriteResult> write(String workspaceId, CloudDoc doc) async {
    if (offline) return const CloudWriteResult(ok: false, error: 'unavailable');
    log.add('write ${doc.entities.length}');
    final current = _store[workspaceId];
    final merged = <String, dynamic>{};
    if (current != null) {
      for (final e in _toDoc(current).entities.entries) {
        merged[e.key] = e.value;
      }
    }
    for (final e in doc.entities.entries) {
      final mine = (e.value['updatedAt'] as num?)?.toInt() ?? 0;
      final theirs = merged[e.key] is Map
          ? (((merged[e.key] as Map)['updatedAt'] as num?)?.toInt() ?? 0)
          : -1;
      if (mine >= theirs) merged[e.key] = e.value;
    }
    final rev = current == null ? 1 : ((current['rev'] as num?)?.toInt() ?? 0) + 1;
    _store[workspaceId] = {'rev': rev, 'entities': merged};
    _emit(workspaceId);
    return CloudWriteResult(ok: true, rev: rev);
  }

  @override
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
  }) {
    final sub = _Sub(workspaceId, onRemote);
    _subs.add(sub);
    // Firestore emits the current state immediately on subscribe.
    scheduleMicrotask(() {
      final data = _store[workspaceId];
      onRemote(data == null ? CloudDoc.unknown : _toDoc(data));
    });
    return _Handle(this, sub);
  }

  void _emit(String workspaceId) {
    final data = _store[workspaceId];
    final doc = data == null ? CloudDoc.unknown : _toDoc(data);
    for (final s in List.of(_subs)) {
      if (s.workspaceId == workspaceId) s.onRemote(doc);
    }
  }

  /// Lets a test simulate another device writing directly to the server.
  void remoteWrite(String workspaceId, Map<String, dynamic> entities) {
    final current = _store[workspaceId];
    final merged = <String, dynamic>{};
    if (current != null) {
      for (final e in _toDoc(current).entities.entries) {
        merged[e.key] = e.value;
      }
    }
    for (final e in entities.entries) {
      final mine = (e.value['updatedAt'] as num?)?.toInt() ?? 0;
      final theirs = merged[e.key] is Map
          ? (((merged[e.key] as Map)['updatedAt'] as num?)?.toInt() ?? 0)
          : -1;
      if (mine >= theirs) merged[e.key] = e.value;
    }
    _store[workspaceId] = {
      'rev': current == null ? 1 : ((current['rev'] as num?)?.toInt() ?? 0) + 1,
      'entities': merged,
    };
    _emit(workspaceId);
  }

  Map<String, dynamic> raw(String workspaceId) =>
      _toDoc(_store[workspaceId] ?? {}).entities;

  CloudDoc _toDoc(Map<String, dynamic> data) {
    final raw = data['entities'];
    final entities = <String, dynamic>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        entities[e.key.toString()] = e.value;
      }
    }
    return CloudDoc(
      entities: entities,
      rev: (data['rev'] as num?)?.toInt() ?? 0,
      exists: entities.isNotEmpty || data.isNotEmpty,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _Sub {
  _Sub(this.workspaceId, this.onRemote);
  final String workspaceId;
  final void Function(CloudDoc) onRemote;
}

class _Handle implements CloudSubscription {
  _Handle(this._b, this._s);
  final MemoryBackend _b;
  final _Sub _s;
  @override
  void cancel() => _b._subs.remove(_s);
}

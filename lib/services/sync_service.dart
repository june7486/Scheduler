import 'dart:async';
import 'dart:convert';


import 'package:http/http.dart' as http;

import 'store.dart';

/// Raised for any sync failure that should be surfaced to the user.
class SyncException implements Exception {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}

/// What the sync engine is currently doing (drives the Settings UI).
enum SyncState { off, idle, syncing, offline, error }

/// Cross-device synchronisation for June's Scheduler.
///
/// Design
/// ------
/// * Records (tasks / categories / voice notes) are synced individually and
///   merged with **last-writer-wins** on `updatedAt` (epoch ms).
/// * Deletions become **tombstones** (`deletedAt`) instead of hard deletes, so
///   a removal on one device also removes the row elsewhere.
/// * Every write is debounced and pushed as a delta; every device also polls,
///   so all devices converge within a couple of seconds.
/// * Offline edits are never lost: a record whose local `updatedAt` is newer
///   than the server copy is kept and re-uploaded.
///
/// The backend is plain REST:
///   GET  {base}/state?code=CODE           -> {rev, entities:{key:{...}}, t}
///   POST {base}/push  {code, baseRev, entities:{key:{...}}} -> {rev, entities}
/// `syncUrl` is user-configurable, so the app is not tied to one provider.
class SyncService {
  SyncService(this._store);

  final Store _store;
  Timer? _debounce;
  Timer? _poll;
  bool _busy = false;
  bool _stopped = true;

  SyncState _state = SyncState.off;
  SyncState get state => _state;

  String _message = '';
  String get message => _message;

  DateTime? _lastSync;
  DateTime? get lastSync => _lastSync;

  int _pendingLocal = 0;
  int get pendingLocal => _pendingLocal;

  /// Server revision this device last saw.
  int _rev = 0;

  /// Set when a local write happens while a request is in flight.
  bool _dirty = false;

  /// Poll interval. Short enough to feel live across devices.
  static const pollInterval = Duration(seconds: 2);

  /// Debounce applied to local writes before pushing.
  static const writeDebounce = Duration(milliseconds: 700);

  static const _timeout = Duration(seconds: 12);

  bool get isActive => !_stopped && _store.syncEnabled;

  String get code => _store.syncCode;
  String get baseUrl =>
      _store.syncUrl.isEmpty ? defaultBaseUrl : _store.syncUrl.trim();

  /// Hosted relay used when the user has not configured their own.
  static const defaultBaseUrl = 'https://sync.aqdesign.co.kr';

  // ---------------- Lifecycle ----------------

  /// Starts polling/pushing for the signed-in user. Safe to call repeatedly.
  Future<void> start() async {
    if (!_store.syncEnabled) {
      _setState(SyncState.off, '');
      return;
    }
    _stopped = false;
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) => pull(silent: true));
    await pull();
  }

  void stop() {
    _stopped = true;
    _poll?.cancel();
    _poll = null;
    _debounce?.cancel();
    _debounce = null;
    _setState(SyncState.off, '');
  }

  /// Called by [Store] whenever local data changed: schedules a push.
  void markDirty() {
    if (!isActive) return;
    if (_busy) {
      _dirty = true;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(writeDebounce, () => push(silent: true));
  }

  void _setState(SyncState s, String msg) {
    _state = s;
    _message = msg;
    _store.onSyncStatusChanged();
  }

  // ---------------- Networking ----------------

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  /// Reads the server state and merges anything newer than the local copy.
  Future<void> pull({bool silent = false}) async {
    if (!isActive || _busy) return;
    _busy = true;
    if (!silent) _setState(SyncState.syncing, '');
    try {
      final res = await http
          .get(
            _uri('/state', {'code': code, 'owner': _store.currentUserId}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        throw SyncException('HTTP ${res.statusCode}');
      }
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map) throw const SyncException('Bad response');
      _applyRemote(body);
      if (_dirty) {
        _dirty = false;
        _busy = false;
        await push(silent: true);
        return;
      }
      _pendingLocal = _countPending();
      _lastSync = DateTime.now();
      _setState(SyncState.idle, '');
    } catch (e) {
      _setState(SyncState.offline, '$e');
      if (!silent) rethrow;
    } finally {
      _busy = false;
    }
  }

  /// Uploads local records newer than the server's copy.
  Future<void> push({bool silent = false}) async {
    if (!isActive || _busy) return;
    final owner = _store.currentUserId;
    if (owner.isEmpty) return;
    _busy = true;
    if (!silent) _setState(SyncState.syncing, '');
    try {
      final snapshot = _store.syncSnapshot(owner);
      final stamps = _store.syncUpdatedAt(owner);
      final res = await http
          .post(
            _uri('/push'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(
              jsonEncode({
                'code': code,
                'owner': owner,
                'baseRev': _rev,
                'entities': snapshot,
                'stamps': stamps,
              }),
            ),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        throw SyncException('HTTP ${res.statusCode}');
      }
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map) throw const SyncException('Bad response');
      _applyRemote(body);
      _pendingLocal = 0;
      _lastSync = DateTime.now();
      _setState(SyncState.idle, '');
    } catch (e) {
      _dirty = true;
      _setState(SyncState.offline, '$e');
      if (!silent) rethrow;
    } finally {
      _busy = false;
    }
  }

  /// Merges a server payload into the local boxes.
  void _applyRemote(Map body) {
    final rev = (body['rev'] as num?)?.toInt();
    if (rev != null) _rev = rev;
    final entities = body['entities'];
    if (entities is! Map) return;
    _pendingApply = <String, Map<String, dynamic>>{};
    for (final e in entities.entries) {
      final key = '${e.key}';
      final slash = key.indexOf('/');
      if (slash <= 0) continue;
      final entity = key.substring(0, slash);
      final boxKey = key.substring(slash + 1);
      final value = e.value;
      if (value is! Map) continue;
      _pendingApply![key] = Map<String, dynamic>.from(value);
      // Fire and forget: applyRemoteEntity is async (Hive write).
      _store
          .applyRemoteEntity(entity, boxKey, Map<String, dynamic>.from(value))
          .then((changed) {
            if (changed) _changedRemotely = true;
          });
    }
  }

  Map<String, Map<String, dynamic>>? _pendingApply;
  bool _changedRemotely = false;

  int _countPending() {
    final owner = _store.currentUserId;
    if (owner.isEmpty) return 0;
    final localMax = _store.syncMaxUpdatedAt(owner);
    final seen = _store.syncMaxUpdatedAtCache;
    return localMax > seen ? 1 : 0;
  }

  /// True when a pull modified local data (the UI listens and rebuilds).
  bool get changedRemotely => _changedRemotely;

  /// Waits for in-flight per-entity Hive writes to land, then notifies.
  Future<void> flushRemoteApply() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (_changedRemotely) {
      _changedRemotely = false;
      _store.onRemoteApplied();
    }
  }

  // ---------------- Setup helpers ----------------

  /// Creates a brand-new workspace code and turns sync on.
  Future<String> createWorkspace() async {
    final newCode = _randomCode();
    await _store.setSyncConfig(
      code: newCode,
      enabled: true,
      ownerId: _store.currentUserId,
    );
    await _store.setSyncStamp(0);
    _rev = 0;
    await push(silent: true);
    await start();
    return newCode;
  }

  /// Joins an existing workspace by code.
  Future<void> joinWorkspace(String newCode) async {
    await _store.setSyncConfig(
      code: newCode.trim().toUpperCase(),
      enabled: true,
    );
    await _store.setSyncStamp(0);
    _rev = 0;
    await start();
  }

  static String _randomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    var seed = rnd;
    for (var i = 0; i < 10; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      buf.write(chars[seed % chars.length]);
    }
    return buf.toString();
  }

  /// Human readable status line for the Settings screen.
  String statusLabel({required bool ko}) {
    switch (_state) {
      case SyncState.off:
        return ko ? '동기화 꺼짐' : 'Sync off';
      case SyncState.idle:
        return ko ? '연결됨 · 최신 상태' : 'Connected · up to date';
      case SyncState.syncing:
        return ko ? '동기화 중…' : 'Syncing…';
      case SyncState.offline:
        return ko ? '연결 안 됨 (오프라인)' : 'Offline';
      case SyncState.error:
        return ko ? '오류' : 'Error';
    }
  }
}

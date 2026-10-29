import 'dart:async';
import 'dart:math';

import 'store.dart';
import 'sync_relay.dart';

/// What the sync engine is currently doing (drives the Settings UI).
enum SyncState { off, idle, syncing, offline, error }

/// Cross-device synchronisation for June's Scheduler.
///
/// Design
/// ------
/// * Records (tasks / categories / voice notes) sync individually and merge
///   with **last-writer-wins** on `updatedAt` (epoch ms).
/// * Deletions become **tombstones** (`deletedAt`) instead of hard deletes, so
///   a removal on one device also removes the row elsewhere.
/// * Local writes are debounced (700 ms) and pushed; every device also polls
///   every 2 s, so all devices converge within a couple of seconds.
/// * Offline edits are never lost: a record whose local `updatedAt` is newer
///   than the server copy is kept and re-uploaded.
/// * Transport is pluggable ([SyncRelay]). With no configuration the app uses
///   an end-to-end encrypted ntfy.sh topic derived from the sync code, so sync
///   works with no account and no server to host.
class SyncService {
  SyncService(this._store);

  final Store _store;
  Timer? _debounce;
  Timer? _poll;
  bool _busy = false;
  bool _stopped = true;

  /// Set when a local write happened while a request was in flight; the write
  /// is retried as soon as the current request finishes.
  bool _dirty = false;

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

  /// Number of records last exchanged — shown in Settings so the user can see
  /// that something is really happening.
  int _lastCount = 0;
  int get lastCount => _lastCount;

  /// Poll interval. Short enough to feel live across devices.
  static const pollInterval = Duration(seconds: 2);

  /// Debounce applied to local writes before pushing.
  static const writeDebounce = Duration(milliseconds: 700);

  bool get isActive => !_stopped && _store.syncEnabled;

  String get code => _store.syncCode;

  String get baseUrl {
    final custom = _store.syncUrl.trim();
    return custom.isEmpty ? NtfyRelay.defaultBaseUrl : custom;
  }

  /// Kept because the setup dialog references it.
  static const defaultBaseUrl = NtfyRelay.defaultBaseUrl;

  SyncRelay? _relay;

  SyncRelay? get _current {
    if (!isActive || code.isEmpty) return null;
    return _relay ??= makeRelay(baseUrl, code);
  }

  /// Drops the cached transport after the code or server changes.
  void resetRelay() => _relay = null;

  // ---------------- Lifecycle ----------------

  /// Starts polling/pushing for the signed-in user. Safe to call repeatedly.
  Future<void> start() async {
    if (!_store.syncEnabled) {
      _stopped = true;
      _poll?.cancel();
      _poll = null;
      _setState(SyncState.off, '');
      return;
    }
    _stopped = false;
    resetRelay();
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) {
      if (_busy) return;
      if (_dirty) {
        // A write came in mid-flight; flush it before pulling.
        _dirty = false;
        unawaited(push(silent: true));
      } else {
        unawaited(pull(silent: true));
      }
    });
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
    _debounce = Timer(writeDebounce, () => unawaited(push(silent: true)));
  }

  void _setState(SyncState s, String msg) {
    _state = s;
    _message = msg;
    _store.onSyncStatusChanged();
  }

  // ---------------- Sync cycle ----------------

  /// Reads the workspace and merges anything newer than the local copy.
  Future<void> pull({bool silent = false}) async {
    final relay = _current;
    if (relay == null || _busy) return;
    _busy = true;
    if (!silent) _setState(SyncState.syncing, '');
    try {
      final remote = await relay.read();
      _rev = (remote['rev'] as num?)?.toInt() ?? 0;
      final changed = await _applyRemote(remote);
      _pendingLocal = _countPending();
      _lastSync = DateTime.now();
      _setState(SyncState.idle, '');
      if (!changed) _store.onSyncStatusChanged();

      // Merge forward: if this device holds records the workspace does not have
      // (or holds newer copies), publish them. Without this a late-joining
      // device's rows could be dropped whenever the other device overwrote the
      // document while its upload was still in flight.
      if (_hasLocalOnly(_store.currentUserId, remote)) {
        _busy = false;
        await push(silent: true);
      }
    } catch (e) {
      _setState(SyncState.offline, _friendly(e));
      if (!silent) rethrow;
    } finally {
      _busy = false;
    }
  }

  /// True when local data is missing from, or newer than, the remote snapshot.
  bool _hasLocalOnly(String ownerId, Map remote) {
    final remoteEntities = (remote['entities'] as Map?) ?? const {};
    final local = _store.syncSnapshot(ownerId);
    if (local.isEmpty) return false;
    for (final e in local.entries) {
      final mine = e.value;
      final theirs = remoteEntities[e.key];
      final mineStamp = (mine['updatedAt'] as num?)?.toInt() ?? 0;
      if (theirs is! Map) return true;
      final theirStamp = (theirs['updatedAt'] as num?)?.toInt() ?? 0;
      if (mineStamp > theirStamp) return true;
    }
    return false;
  }

  /// Uploads local records newer than the server's copy.
  Future<void> push({bool silent = false}) async {
    if (!isActive) return;
    final relay = _current;
    if (relay == null || _busy) return;
    final owner = _store.currentUserId;
    if (owner.isEmpty) return;
    _busy = true;
    if (!silent) _setState(SyncState.syncing, '');
    try {
      final entities = _store.syncSnapshot(owner);
      _lastCount = entities.length;
      await relay.write({'rev': _rev, 'entities': entities});
      _pendingLocal = 0;
      _lastSync = DateTime.now();
      _setState(SyncState.idle, '');
      // Read straight back so this device also sees whatever the other one
      // had already published (including rows it wrote while we were offline).
      final echo = await relay.read();
      _rev = (echo['rev'] as num?)?.toInt() ?? _rev;
      await _applyRemote(echo);
    } catch (e) {
      _dirty = true;
      _setState(SyncState.offline, _friendly(e));
      if (!silent) rethrow;
    } finally {
      _busy = false;
    }
  }

  /// Merges a workspace payload into the local boxes.
  ///
  /// Awaited (not fire-and-forget) so the caller only reports success once the
  /// records are on disk, and so the UI is notified exactly once.
  Future<bool> _applyRemote(Map remote) async {
    final entities = remote['entities'];
    if (entities is! Map) return false;

    var changed = false;
    _store.beginRemoteApply();
    try {
      for (final e in entities.entries) {
        final key = '${e.key}';
        final slash = key.indexOf('/');
        if (slash <= 0) continue;
        final entity = key.substring(0, slash);
        final boxKey = key.substring(slash + 1);
        final value = e.value;
        if (value is! Map) continue;
        final didChange = await _store.applyRemoteEntity(
          entity,
          boxKey,
          Map<String, dynamic>.from(value),
        );
        if (didChange) changed = true;
      }
    } finally {
      _store.endRemoteApply(changed);
    }
    return changed;
  }

  int _countPending() {
    final owner = _store.currentUserId;
    if (owner.isEmpty) return 0;
    final localMax = _store.syncMaxUpdatedAt(owner);
    final seen = _store.syncMaxUpdatedAtCache;
    return localMax > seen ? 1 : 0;
  }

  String _friendly(Object e) {
    final s = '$e';
    if (s.contains('XMLHttpRequest') || s.contains('Failed to fetch')) {
      return 'network unreachable';
    }
    if (s.contains('TimeoutException')) return 'timeout';
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  // ---------------- Setup helpers ----------------

  /// Creates a brand-new workspace code and turns sync on.
  ///
  /// Everything already on this device is uploaded so the second device starts
  /// from a complete copy instead of an empty screen.
  Future<String> createWorkspace() async {
    final newCode = _randomCode();
    resetRelay();
    _rev = 0;
    await _store.setSyncConfig(
      code: newCode,
      enabled: true,
      ownerId: _store.currentUserId,
    );
    await _store.setSyncStamp(0);
    await _store.reStampAll(_store.currentUserId);
    _stopped = false;
    _relay = makeRelay(baseUrl, newCode);
    await push();
    await start();
    return newCode;
  }

  /// Joins an existing workspace by code.
  ///
  /// Pulls first so the incoming rows land, then re-stamps and pushes the local
  /// records so the other device receives them too (true two-way merge).
  Future<void> joinWorkspace(String newCode) async {
    final clean = newCode.trim().toUpperCase();
    resetRelay();
    _rev = 0;
    await _store.setSyncConfig(code: clean, enabled: true);
    await _store.setSyncStamp(0);
    _stopped = false;
    _relay = makeRelay(baseUrl, clean);
    await pull();
    await _store.reStampAll(_store.currentUserId);
    await push();
    await start();
  }

  static String _randomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < 10; i++) {
      buf.write(chars[rnd.nextInt(chars.length)]);
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

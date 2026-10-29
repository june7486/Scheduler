import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

import 'online_hook_stub.dart'
    if (dart.library.js_interop) 'online_hook_web.dart' as online;
import 'store.dart';
import 'sync_relay.dart';

/// What the sync engine is currently doing (drives the Settings UI).
enum SyncState { off, idle, syncing, offline, error }

/// Cross-device synchronisation for June's Scheduler.
///
/// **Server is the source of truth.**
/// --------------------------------
/// The workspace document on the relay is the real storage. This device keeps
/// only a read cache plus a small *outbox* (`Store.pendingKeys`) of changes
/// that have not been acknowledged by the server yet. Nothing counts as saved
/// until the server accepted it.
///
/// Behaviour:
/// * Local edit -> goes into the outbox -> uploaded on the next cycle.
/// * Merge is last-writer-wins on `updatedAt`, so a device that was offline for
///   a week cannot resurrect stale rows over newer ones.
/// * Records the server does not have are pruned locally (server wins), except
///   for outbox entries, which are still on their way up.
/// * When the connection drops the outbox stays intact; a periodic retry (and
///   the browser `online` event) flushes it as soon as the network returns.
class SyncService {
  SyncService(this._store);

  final Store _store;
  Timer? _debounce;
  Timer? _poll;
  bool _busy = false;
  bool _stopped = true;

  /// A local write landed while a request was in flight; it is guaranteed to
  /// be in the outbox, so the next tick will pick it up.
  bool _dirty = false;
  bool get hasQueuedWrite => _dirty;

  SyncState _state = SyncState.off;
  SyncState get state => _state;

  String _message = '';
  String get message => _message;

  DateTime? _lastSync;
  DateTime? get lastSync => _lastSync;

  /// Failed upload attempts in a row, used for backoff.
  int _failures = 0;
  int get failures => _failures;

  /// Records uploaded on the last successful cycle.
  int _lastCount = 0;
  int get lastCount => _lastCount;

  /// Engine tick. Each tick pulls the server, then flushes the outbox.
  static const pollInterval = Duration(seconds: 2);

  /// Backoff when the server is unreachable (capped).
  static const _maxBackoff = Duration(seconds: 60);

  /// Debounce applied to local writes before a push attempt.
  static const writeDebounce = Duration(milliseconds: 500);

  bool get isActive => !_stopped && _store.syncEnabled;

  String get code => _store.syncCode;

  String get baseUrl {
    final custom = _store.syncUrl.trim();
    return custom.isEmpty ? NtfyRelay.defaultBaseUrl : custom;
  }

  /// Kept because the setup dialog references it.
  static const defaultBaseUrl = NtfyRelay.defaultBaseUrl;

  /// Changes waiting to be uploaded.
  int get pendingCount => _store.pendingCount;

  SyncRelay? _relay;

  /// The transport for the current workspace.
  ///
  /// Deliberately does NOT depend on [_stopped]: a manual "sync now" must work
  /// even before the timer loop was armed.
  SyncRelay? _relayFor(String code) {
    if (code.isEmpty) return null;
    return _relay ??= makeRelay(baseUrl, code);
  }

  /// Drops the cached transport after the code or server changes.
  void resetRelay() => _relay = null;

  // ---------------- Lifecycle ----------------

  /// Starts the periodic cycle. Safe to call repeatedly.
  Future<void> start() async {
    if (!_store.syncEnabled) {
      _stopped = true;
      _poll?.cancel();
      _poll = null;
      _setState(SyncState.off, '');
      return;
    }
    _stopped = false;
    _failures = 0;
    resetRelay();
    _installOnlineListener();
    _armPoll();
    await tick(manual: true);
  }

  /// Fires as soon as the device regains network access, so a queued change
  /// goes up immediately instead of waiting for the next poll.
  void _installOnlineListener() {
    if (!kIsWeb || _onlineHooked) return;
    _onlineHooked = true;
    try {
      online.hookOnline(() => unawaited(retryNow()));
    } catch (_) {
      // Non-web / unsupported browser: the periodic retry still covers us.
    }
  }

  bool _onlineHooked = false;

  void _armPoll() {
    _poll?.cancel();
    final backoff = _failures == 0
        ? pollInterval
        : Duration(
            seconds: (pollInterval.inSeconds * (1 << _failures)).clamp(
              pollInterval.inSeconds,
              _maxBackoff.inSeconds,
            ),
          );
    _poll = Timer.periodic(backoff, (_) => unawaited(tick()));
  }

  void stop() {
    _stopped = true;
    _poll?.cancel();
    _poll = null;
    _debounce?.cancel();
    _debounce = null;
    _setState(SyncState.off, '');
  }

  /// Called by [Store] whenever local data changed.
  void markDirty() {
    if (!isActive) return;
    if (_busy) {
      _dirty = true;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(writeDebounce, () => unawaited(tick()));
  }

  /// Flushes the outbox immediately — used when the network comes back.
  Future<void> retryNow() async {
    if (!isActive) return;
    _failures = 0;
    await tick(manual: true);
  }

  void _setState(SyncState s, String msg) {
    _state = s;
    _message = msg;
    _store.onSyncStatusChanged();
  }

  // ---------------- The cycle ----------------

  /// Pull the server document, then upload anything still in the outbox.
  Future<void> tick({bool manual = false}) async {
    if (_busy) return;
    if (_store.currentUserId.isEmpty || _store.syncCode.isEmpty) {
      // Nothing to talk to yet. Report it instead of silently "succeeding".
      _setState(SyncState.offline, 'not signed in');
      return;
    }
    final relay = _relayFor(_store.syncCode);
    if (relay == null) {
      _setState(SyncState.offline, 'not configured');
      return;
    }
    _busy = true;
    if (manual) _setState(SyncState.syncing, '');

    try {
      // 1) Server -> local (server wins, outbox entries are protected).
      final remote = await relay.read();
      final serverEntities = (remote['entities'] as Map?) ?? const {};
      await _applyServerState(serverEntities);

      // 2) Local outbox -> server.
      final owner = _store.currentUserId;
      final outbox = _store.pendingSnapshot(owner);
      if (outbox.isNotEmpty && owner.isNotEmpty) {
        await relay.write({'rev': 0, 'entities': outbox});
        await _store.clearPending(outbox.keys);
        _lastCount = outbox.length;
      } else {
        _lastCount = serverEntities.length;
      }

      _failures = 0;
      _dirty = false;
      _lastSync = DateTime.now();
      // Only claim success when nothing is still waiting to be uploaded.
      final stillQueued = _store.pendingCount;
      _setState(
        stillQueued == 0 ? SyncState.idle : SyncState.syncing,
        stillQueued == 0 ? '' : 'still uploading',
      );
      _store.onSyncStatusChanged();
    } catch (e, st) {
      _failures = (_failures + 1).clamp(1, 6);
      _dirty = true;
      debugPrint('SYNCDBG ${e.runtimeType}: $e');
      debugPrint('SYNCDBG at ${st.toString().split('\n').take(4).join(' | ')}');
      _setState(SyncState.offline, _friendly(e));
      _armPoll();
    } finally {
      _busy = false;
    }
  }

  /// Pull-only, kept for the "sync now" button.
  Future<void> pull({bool silent = false}) => tick(manual: !silent);

  /// Push-only; the outbox is flushed by [tick], so this just runs a cycle.
  Future<void> push({bool silent = false}) => tick(manual: !silent);

  /// Writes the server snapshot into the boxes and drops vanished records.
  Future<void> _applyServerState(Map serverEntities) async {
    var changed = false;
    final keys = <String>{};
    for (final e in serverEntities.entries) {
      final key = '${e.key}';
      keys.add(key);
    }
    _store.beginRemoteApply();
    try {
      changed = _store.applyServerSnapshot(serverEntities);
      final pruned = await _store.pruneMissing(_store.currentUserId, keys);
      if (pruned) changed = true;
    } finally {
      _store.endRemoteApply(changed);
    }
  }

  String _friendly(Object e) {
    final s = '$e';
    if (s.contains('SocketException') ||
        s.contains('XMLHttpRequest') ||
        s.contains('Failed to fetch') ||
        s.contains('ClientException')) {
      return 'offline';
    }
    if (s.contains('TimeoutException')) return 'timeout';
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  // ---------------- Setup helpers ----------------

  /// Creates a brand-new workspace and uploads everything on this device.
  Future<String> createWorkspace() async {
    final newCode = _randomCode();
    resetRelay();
    await _store.setSyncConfig(
      code: newCode,
      enabled: true,
      ownerId: _store.currentUserId,
    );
    _relay = makeRelay(baseUrl, newCode);
    // Everything currently on the device becomes the initial server content.
    await _store.queueAllForUpload(_store.currentUserId);
    _stopped = false;
    _failures = 0;
    await tick(manual: true);
    _armPoll();
    return newCode;
  }

  /// Joins an existing workspace.
  ///
  /// The server copy replaces the local cache, but anything this device edited
  /// while offline is uploaded on top instead of being lost.
  Future<void> joinWorkspace(String newCode) async {
    final clean = newCode.trim().toUpperCase();
    resetRelay();
    await _store.setSyncConfig(code: clean, enabled: true);
    _relay = makeRelay(baseUrl, clean);
    _stopped = false;
    _failures = 0;
    await tick(manual: true);
    _armPoll();
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
        return ko ? '서버와 동일' : 'In sync with server';
      case SyncState.syncing:
        return ko ? '동기화 중…' : 'Syncing…';
      case SyncState.offline:
        return ko ? '서버 연결 안 됨 — 재시도 중' : 'Server unreachable — retrying';
      case SyncState.error:
        return ko ? '오류' : 'Error';
    }
  }
}

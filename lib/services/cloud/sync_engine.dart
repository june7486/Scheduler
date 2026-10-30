import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../store.dart';
import 'cloud_backend.dart';

/// What the cloud sync is doing right now (drives the Settings panel).
enum SyncState { off, idle, syncing, offline, notConfigured }

/// Cloud sync for June's Scheduler.
///
/// ## The model
/// **The server is the only durable copy.** The device keeps a read cache plus
/// an *outbox* of records that have not been acknowledged yet. A local edit is
/// not "saved" until it comes back from the server in a snapshot.
///
/// ## Why this is a rewrite
/// The previous version treated a pub/sub topic (ntfy.sh) as a database:
/// 2-second polling against a 5-second rate limit, a 4 KB body cap, and 12-hour
/// message retention. It failed in exactly the way those limits predict —
/// `HTTP 429`, then silent data loss. Nothing of that design survives here.
///
/// ## How it works now
/// * One `snapshots()` listener per workspace. Firestore pushes changes; there
///   is no polling, so there is no rate limit to trip.
/// * A local write marks records in the outbox and schedules an upload. The
///   upload merges (last-writer-wins on `updatedAt`) inside a transaction.
/// * The listener confirms the upload: records leave the outbox only when the
///   server sends them back. A write that never lands stays queued.
/// * Deletions are tombstones (`deletedAt`), so they propagate like any other
///   change instead of relying on "missing" — which an unseen document would
///   confuse with "not synced yet".
class SyncService {
  SyncService(this._store, this._backend);

  final Store _store;
  final CloudBackend _backend;

  CloudSubscription? _sub;
  Timer? _pushTimer;
  Timer? _retry;

  bool _busy = false;
  bool _dirty = false;
  bool _stopped = true;

  SyncState _state = SyncState.off;
  SyncState get state => _state;

  String _message = '';
  String get message => _message;

  DateTime? _lastSync;
  DateTime? get lastSync => _lastSync;

  int _failures = 0;
  int get failures => _failures;

  /// Records acknowledged by the server during the last successful upload.
  int _lastCount = 0;
  int get lastCount => _lastCount;

  /// How long to wait after a local edit before uploading (batches keystrokes).
  static const pushDebounce = Duration(milliseconds: 500);

  /// Backoff for retries after a failed upload.
  static const _retryBase = Duration(seconds: 2);
  static const _retryMax = Duration(seconds: 60);

  bool get isActive => !_stopped && _store.syncEnabled;
  bool get isLive => _sub != null;
  bool get isConfigured => _isBackendReady();

  String get backendName => _backend.name;
  int get pendingCount => _store.pendingCount;

  String get workspaceId => _store.workspaceId;

  // ---------------- Lifecycle ----------------

  /// Starts listening. Safe to call repeatedly.
  Future<void> start() async {
    if (!_store.syncEnabled) {
      _stopped = true;
      _cancelAll();
      _setState(SyncState.off, '');
      return;
    }
    if (!_isBackendReady()) {
      _setState(SyncState.notConfigured, 'firebase not configured');
      return;
    }
    _stopped = false;
    _failures = 0;
    _subscribe();
    await flush(manual: true);
  }

  /// True only when the backend can actually be used.
  ///
  /// Constructing the Firestore backend throws when Firebase was never
  /// initialised, so this must be asked before anything touches it. Treating
  /// that case as "not configured" is what lets the app run local-only instead
  /// of crashing on the first edit.
  bool _isBackendReady() {
    try {
      return _backend.isConfigured;
    } catch (_) {
      return false;
    }
  }

  /// Opens the single live subscription for this workspace.
  void _subscribe() {
    if (_stopped) return;
    if (_sub != null) return;
    final id = workspaceId;
    if (id.isEmpty) return;

    _sub = _backend.watch(
      id,
      onRemote: (doc) {
        // Firestore calls this once immediately with the current document, then
        // on every change from any device — including our own uploads, which is
        // what lets us confirm them and empty the outbox.
        unawaited(_onRemote(doc));
      },
      onError: (reason) {
        debugPrint('CLOUDDBG listener error: $reason');
        _setState(SyncState.offline, _friendly(reason));
      },
    );
  }

  void _cancelAll() {
    _sub?.cancel();
    _sub = null;
    _pushTimer?.cancel();
    _pushTimer = null;
    _retry?.cancel();
    _retry = null;
  }

  void stop() {
    _stopped = true;
    _cancelAll();
    _setState(SyncState.off, '');
  }

  /// Called by [Store] whenever local data changed.
  void markDirty() {
    if (_stopped || !_store.syncEnabled) return;
    if (_busy) {
      // A flush is already in flight. Remember that more work arrived so the
      // in-flight cycle starts another one when it finishes — dropping this
      // call would silently swallow an edit made during a slow upload.
      _dirty = true;
      return;
    }
    _pushTimer?.cancel();
    _pushTimer = Timer(pushDebounce, () => unawaited(flush()));
  }

  /// Uploads the outbox right now (used by the "sync now" button and after a
  /// reconnect).
  Future<void> flush({bool manual = false}) async {
    if (_stopped) {
      if (manual) _setState(SyncState.off, '');
      return;
    }
    if (!_isBackendReady()) {
      _setState(SyncState.notConfigured, 'firebase not configured');
      return;
    }
    if (_busy) {
      // Let the running cycle know it has more work once it finishes.
      _dirty = true;
      return;
    }
    final id = workspaceId;
    if (id.isEmpty) {
      _setState(SyncState.offline, 'not signed in');
      return;
    }

    final outbox = _store.pendingSnapshot(_store.currentUserId);
    if (outbox.isEmpty) {
      // Nothing to upload. Report honestly: we are only in sync if a snapshot
      // has actually arrived at least once.
      _setState(
        _lastSync == null ? SyncState.syncing : SyncState.idle,
        '',
      );
      return;
    }

    _busy = true;
    if (manual) _setState(SyncState.syncing, '');
    try {
      final res = await _backend.write(
        id,
        CloudDoc(entities: outbox, rev: 0),
      );
      if (!res.ok) {
        _failures = (_failures + 1).clamp(1, 8);
        _setState(SyncState.offline, _friendly(res.error ?? 'write failed'));
        _scheduleRetry();
        return;
      }
      // Confirmation comes from the server's answer, not from the HTTP result
      // alone: the outbox is emptied in [_onRemote] only for records the server
      // echoed back. That closes the "reported saved but never stored" hole.
      //
      // Read back immediately instead of waiting for the push channel to fire.
      // Firestore's snapshot would arrive on its own, but a polling backend
      // (NAS) would only confirm on its next tick — up to two seconds of the
      // pending badge sitting there after a successful upload, which reads as
      // "it did not work". An extra read costs nothing and makes the panel
      // honest the instant the write lands.
      _failures = 0;
      final confirm = await _backend.read(id);
      await _onRemote(confirm);
    } catch (e) {
      _failures = (_failures + 1).clamp(1, 8);
      debugPrint('CLOUDDBG upload failed: $e');
      _setState(SyncState.offline, _friendly('$e'));
      _scheduleRetry();
    } finally {
      _busy = false;
      // Edits that arrived while this cycle was running must not be dropped:
      // run one more pass if anything is still queued.
      if (!_stopped && _dirty) {
        _dirty = false;
        if (_store.pendingCount > 0) _pushTimer?.cancel();
        _pushTimer = Timer(pushDebounce, () => unawaited(flush()));
      }
    }
  }

  void _scheduleRetry() {
    _retry?.cancel();
    final secs = (_retryBase.inSeconds * (1 << (_failures - 1)))
        .clamp(_retryBase.inSeconds, _retryMax.inSeconds);
    _retry = Timer(Duration(seconds: secs), () => unawaited(flush()));
  }

  /// Applies a document coming from the server.
  Future<void> _onRemote(CloudDoc doc) async {
    if (_stopped) return;

    if (!doc.exists) {
      // Brand-new account: nothing on the server yet. Seed it with whatever is
      // already on this device so the first device is not an empty shell.
      _lastSync ??= DateTime.now();
      if (_store.pendingCount == 0) {
        await _store.queueAllForUpload(_store.currentUserId);
        markDirty();
      }
      _setState(SyncState.idle, '');
      return;
    }

    var changed = false;
    final pendingBefore = _store.pendingKeys;

    _store.beginRemoteApply();
    try {
      changed = _store.applyServerSnapshot(doc.entities);

      // Records the server now holds at (or above) our version are confirmed:
      // they can leave the outbox.
      final confirmed = <String>[];
      for (final key in pendingBefore) {
        final srv = doc.entities[key];
        if (srv is! Map) continue;
        final local = _store.pendingRecord(key);
        final mine = (local?['updatedAt'] as num?)?.toInt() ?? 0;
        final theirs = (srv['updatedAt'] as num?)?.toInt() ?? 0;
        if (theirs >= mine) confirmed.add(key);
      }
      if (confirmed.isNotEmpty) {
        await _store.clearPending(confirmed);
        _lastCount = confirmed.length;
      }

      // Anything the server dropped and that we do not have queued is gone.
      final pruned = await _store.pruneMissing(
        _store.currentUserId,
        doc.entities.keys.toSet(),
      );
      if (pruned) changed = true;
    } finally {
      _store.endRemoteApply(changed);
    }

    _lastSync = DateTime.now();
    _failures = 0;

    if (_store.pendingCount > 0) {
      // Still something to push (or a fresh local edit).
      _setState(SyncState.syncing, '');
      if (!_busy) markDirty();
    } else {
      _setState(SyncState.idle, '');
    }
  }

  /// Forces a read + push. Kept for the Settings "지금 동기화" button.
  Future<void> syncNow() async {
    if (_store.syncEnabled && _sub == null) {
      _stopped = false;
      _subscribe();
    }
    await flush(manual: true);
  }

  String _friendly(String s) {
    final t = s.trim();
    if (t.contains('unavailable') ||
        t.contains('network') ||
        t.contains('Failed host lookup') ||
        t.contains('ClientException')) {
      return 'offline';
    }
    if (t.contains('permission-denied')) return 'permission denied';
    return t.length > 90 ? '${t.substring(0, 90)}…' : t;
  }

  void _setState(SyncState s, String msg) {
    if (_state == s && _message == msg) return;
    _state = s;
    _message = msg;
    _store.onSyncStatusChanged();
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
        return ko ? '연결 대기 — 자동 재시도' : 'Waiting to reconnect';
      case SyncState.notConfigured:
        return ko ? '클라우드 미설정 (로컬 저장)' : 'Cloud not configured (local only)';
    }
  }
}

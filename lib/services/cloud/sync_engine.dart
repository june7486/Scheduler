import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../store.dart';
import 'cloud_backend.dart';
import 'nas_backend.dart';

/// What the cloud sync is doing right now (drives the Settings panel).
enum SyncState { off, idle, syncing, offline, notConfigured }

/// Cloud sync for June's Scheduler.
///
/// ## The model
/// **The server is the only durable copy.** The device keeps a read cache plus
/// an *outbox* of records that have not been acknowledged yet. A local edit is
/// not "saved" until the server confirms it.
///
/// ## Why this design loads fast
/// The previous version treated a pub/sub topic as a database (2 s polling into
/// a 5 s rate limit, 4 KB bodies) and then, after moving to the NAS, wrote the
/// whole document and immediately **re-read it** to confirm — two full round
/// trips for every edit, plus a 2 s poll on top. Opening the app mean waiting.
///
/// Three changes removed almost all of that:
///
/// 1. **The write answer is the confirmation.** The gateway merges and returns
///    `echo` (accepted) and `lost` (someone else won). Both empty the outbox and
///    apply the winner, so a normal save is ONE request.
/// 2. **Nothing is downloaded to paint.** The UI renders from Hive, which is a
///    local read. The network is only asked "is your rev different from mine?"
///    and an unchanged workspace answers ~40 bytes.
/// 3. **A parked request instead of a timer.** `watch()` uses the gateway's long
///    poll, so another device's edit arrives within one round trip and an idle
///    session costs a couple of requests per minute instead of thirty.
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

  /// Revision of the workspace this device currently mirrors. Sent on every
  /// read so the server can answer "unchanged" — the cheapest possible reply.
  int _rev = 0;
  int get rev => _rev;

  /// Workspace generation, so a reset on another device is detected.
  int _gen = 0;
  int get gen => _gen;

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
  static const pushDebounce = Duration(milliseconds: 400);

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
      _setState(SyncState.notConfigured, 'sync server not configured');
      return;
    }
    _stopped = false;
    _failures = 0;

    // Reuse the revision we already mirror so the very first request can be
    // answered with "unchanged" instead of shipping the whole workspace.
    _rev = _store.cachedRev;
    _gen = _store.cachedGen;

    _subscribe();

    // Push anything the last session could not upload. Everything else is
    // already on the server, so there is nothing to download first.
    if (_store.pendingCount > 0) {
      await flush(manual: true);
    } else {
      _setState(SyncState.syncing, '');
    }
  }

  /// True only when the backend can actually be used.
  bool _isBackendReady() {
    try {
      return _backend.isConfigured;
    } catch (_) {
      return false;
    }
  }

  /// Opens the single live channel for this workspace.
  void _subscribe() {
    if (_stopped) return;
    if (_sub != null) return;
    final id = workspaceId;
    if (id.isEmpty) return;

    _sub = _backend.watch(
      id,
      haveRev: _rev,
      onRemote: (doc) {
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

  /// Re-reads the workspace from scratch (used after a reset, or by "지금 동기화").
  Future<void> resubscribe({bool forceFull = false}) async {
    _sub?.cancel();
    _sub = null;
    if (forceFull) {
      _rev = 0;
      _gen = 0;
    }
    if (!_stopped) _subscribe();
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

  /// Uploads the outbox right now (used by the "지금 동기화" button and after a
  /// reconnect). Costs exactly one round trip on success.
  Future<void> flush({bool manual = false}) async {
    if (_stopped) {
      if (manual) _setState(SyncState.off, '');
      return;
    }
    if (!_isBackendReady()) {
      _setState(SyncState.notConfigured, 'sync server not configured');
      return;
    }
    if (_busy) {
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
      // Nothing to upload. Do not claim "in sync" before the server has ever
      // answered — that would be a green light nobody verified.
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
        CloudDoc(entities: outbox, rev: _rev, gen: _gen),
      );

      if (!res.ok) {
        _failures = (_failures + 1).clamp(1, 8);
        _setState(SyncState.offline, _friendly(res.error ?? 'write failed'));
        _scheduleRetry();
        return;
      }

      _failures = 0;
      if (res.rev != null) _rev = res.rev!;
      if (res.gen != null) _gen = res.gen!;

      // --- The one-round-trip confirmation -----------------------------------
      // `echo` lists the records the server now holds at our version: those
      // leave the outbox. `lost` carries records where another device's edit was
      // newer: we adopt it locally and also drop it from the outbox, because the
      // server is authoritative and this is not a conflict anymore — it is
      // resolved.
      _store.beginRemoteApply();
      var changed = false;
      try {
        final lost = res.lost;
        if (lost != null) {
          for (final e in lost.entries) {
            final slash = e.key.indexOf('/');
            if (slash <= 0) continue;
            final entity = e.key.substring(0, slash);
            final boxKey = e.key.substring(slash + 1);
            if (await _store.applyServerRecord(entity, boxKey, e.value)) {
              changed = true;
            }
          }
        }
      } finally {
        _store.endRemoteApply(changed);
      }

      final acked = <String>[
        ...?res.echo?.keys,
        if (res.lost != null) ...res.lost!.keys,
      ];
      if (acked.isNotEmpty) {
        await _store.clearPending(acked);
        _lastCount = acked.length;
      }

      _rev = res.rev ?? _rev;
      _gen = res.gen ?? _gen;
      await _store.setCachedRev(_rev, _gen);
      _lastSync = DateTime.now();

      if (_store.pendingCount > 0) {
        _setState(SyncState.syncing, '');
        if (!_busy) markDirty();
      } else {
        _setState(SyncState.idle, '');
      }
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
        _pushTimer?.cancel();
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
      // Nothing on the server. That is either a brand-new account or a reset
      // performed elsewhere — the generation tells them apart.
      final resetElsewhere = doc.gen > _gen;
      _rev = doc.rev;
      _gen = doc.gen;

      if (resetElsewhere) {
        // The user wiped the workspace from another device. Honour it: drop the
        // local cache instead of helpfully uploading it all back.
        _store.beginRemoteApply();
        try {
          await _store.dropWorkspaceCache(_store.currentUserId);
          await _store.clearAllPending();
        } finally {
          _store.endRemoteApply(true);
        }
        await _store.setCachedRev(_rev, _gen);
        _lastSync = DateTime.now();
        _failures = 0;
        _setState(SyncState.idle, '');
        return;
      }

      _lastSync ??= DateTime.now();
      if (_store.pendingCount == 0) {
        await _store.queueAllForUpload(_store.currentUserId);
        markDirty();
      }
      await _store.setCachedRev(_rev, _gen);
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

      // Anything the server no longer has and that we are not still holding in
      // the outbox is genuinely gone.
      //
      // This is deliberately skipped when the document is only a partial answer
      // (i.e. we already had this revision and the poll simply timed out): in
      // that case `entities` is still the full document, so pruning is safe.
      final pruned = await _store.pruneMissing(
        _store.currentUserId,
        doc.entities.keys.toSet(),
      );
      if (pruned) changed = true;
    } finally {
      _store.endRemoteApply(changed);
    }

    _rev = doc.rev;
    _gen = doc.gen;
    await _store.setCachedRev(_rev, _gen);
    _lastSync = DateTime.now();
    _failures = 0;

    if (_store.pendingCount > 0) {
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
    if (_store.pendingCount == 0 && _isBackendReady()) {
      // Ask the server once, bypassing the parked poll, so a manual sync always
      // produces a visible answer.
      try {
        final doc = await _backend.read(workspaceId, haveRev: _rev);
        await _onRemote(doc);
      } on CloudException catch (e) {
        if (e.message != 'unchanged') {
          _setState(SyncState.offline, _friendly(e.message));
        } else {
          _lastSync = DateTime.now();
          _setState(SyncState.idle, '');
        }
      } catch (e) {
        _setState(SyncState.offline, _friendly('$e'));
      }
    }
  }

  /// Empties the workspace on the server so every device follows.
  ///
  /// Returns an error message, or null on success.
  Future<String?> resetRemote() async {
    final id = workspaceId;
    if (id.isEmpty) return 'not signed in';
    if (!_isBackendReady()) return 'sync server not configured';

    // Stop the parked poll first: its answer would fight the reset.
    _sub?.cancel();
    _sub = null;

    final res = await _backend.resetWorkspace(id);
    if (!res.ok) {
      if (!_stopped) _subscribe();
      return res.error ?? 'reset failed';
    }

    _rev = res.rev ?? 0;
    _gen = res.gen ?? (_gen + 1);
    _store.beginRemoteApply();
    try {
      await _store.dropWorkspaceCache(_store.currentUserId);
      await _store.clearAllPending();
    } finally {
      _store.endRemoteApply(true);
    }
    await _store.setCachedRev(_rev, _gen);
    _lastSync = DateTime.now();
    _failures = 0;
    _setState(SyncState.idle, '');
    if (!_stopped) _subscribe();
    return null;
  }

  String _friendly(String s) {
    final t = s.trim();
    if (t.contains('unavailable') ||
        t.contains('network') ||
        t.contains('Failed host lookup') ||
        t.contains('ClientException') ||
        t.contains('SocketException') ||
        t.contains('TimeoutException')) {
      return 'offline';
    }
    if (t.contains('401') || t.contains('bad key')) return 'bad key';
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
        return ko ? '모든 기기와 동일' : 'In sync with all devices';
      case SyncState.syncing:
        return ko ? '동기화 중…' : 'Syncing…';
      case SyncState.offline:
        return ko ? '연결 대기 — 자동 재시도' : 'Waiting to reconnect';
      case SyncState.notConfigured:
        return ko ? '동기화 서버 미설정 (로컬 저장)' : 'No sync server (local only)';
    }
  }

  /// The long-poll wait used by this backend, for the Settings panel copy.
  int get pollWaitSeconds => NasBackend.pollWaitSeconds;
}

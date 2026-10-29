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
/// **How the network is used**
/// ---------------------------
/// The relay is reached over a *single long-lived stream* (SSE), not a polling
/// loop. ntfy.sh — the zero-setup relay — rate-limits anonymous callers to
/// about one request per five seconds, so a 1-2 s poll answers `HTTP 429`
/// within a minute and looks exactly like "the server is down". A stream keeps
/// the connection open and only costs a request when a change actually happens.
///
/// A slow safety-net timer (60 s, exponential backoff while failing) still runs
/// so a blocked or dropped stream cannot leave the device permanently stale.
///
/// Merge rules:
/// * Last-writer-wins on `updatedAt`, so a device that was offline for a week
///   cannot resurrect stale rows over newer ones.
/// * Records the server does not have are pruned locally (server wins) — but
///   only when the server actually answered with a document. An empty/unreadable
///   answer never deletes anything.
class SyncService {
  SyncService(this._store);

  final Store _store;
  Timer? _debounce;
  Timer? _safety;
  RelayWatch? _watch;
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

  /// Failed cycles in a row, used for backoff.
  int _failures = 0;
  int get failures => _failures;

  /// Records uploaded on the last successful cycle.
  int _lastCount = 0;
  int get lastCount => _lastCount;

  /// Safety-net reconcile, only used when the live stream is silent.
  static const safetyInterval = Duration(seconds: 60);

  /// While changes keep arriving the engine reconciles at most this often.
  static const changeDebounce = Duration(milliseconds: 700);

  /// Backoff when the server is unreachable (capped).
  static const _maxBackoff = Duration(seconds: 120);

  /// Debounce applied to local writes before a push attempt.
  static const writeDebounce = Duration(milliseconds: 600);

  bool get isActive => !_stopped && _store.syncEnabled;

  bool get isLive => _watch != null;

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
  /// even before the stream loop was armed.
  SyncRelay? _relayFor(String code) {
    if (code.isEmpty) return null;
    return _relay ??= makeRelay(baseUrl, code);
  }

  /// Drops the cached transport after the code or server changes.
  void resetRelay() {
    _watch?.close();
    _watch = null;
    _relay?.dispose();
    _relay = null;
  }

  // ---------------- Lifecycle ----------------

  /// Starts the live stream + safety net. Safe to call repeatedly.
  Future<void> start() async {
    if (!_store.syncEnabled) {
      _stopped = true;
      _watch?.close();
      _watch = null;
      _safety?.cancel();
      _safety = null;
      _setState(SyncState.off, '');
      return;
    }
    _stopped = false;
    _failures = 0;
    _installOnlineListener();
    _openStream();
    _armSafety();
    await tick(manual: true);
  }

  /// Opens the one and only change feed for this workspace.
  void _openStream() {
    if (_stopped) return;
    final relay = _relayFor(_store.syncCode);
    if (relay == null) return;
    if (_watch != null) return;

    _watch = relay.watch(
      RelayWatchHandlers(
        onOpen: () {
          // The stream came up; a reconcile now catches anything published
          // while we were disconnected.
          _failures = 0;
          unawaited(tick());
        },
        onChange: () => _scheduleChange(),
        onError: (reason) {
          _setState(SyncState.offline, reason);
        },
      ),
    );
  }

  void _scheduleChange() {
    if (_stopped) return;
    _debounce?.cancel();
    _debounce = Timer(changeDebounce, () => unawaited(tick()));
  }

  /// Fires as soon as the device regains network access, so a queued change
  /// goes up immediately instead of waiting for the safety net.
  void _installOnlineListener() {
    if (!kIsWeb || _onlineHooked) return;
    _onlineHooked = true;
    try {
      online.hookOnline(() => unawaited(retryNow()));
    } catch (_) {
      // Non-web / unsupported browser: the safety net still covers us.
    }
  }

  bool _onlineHooked = false;

  void _armSafety() {
    _safety?.cancel();
    final delay = _failures == 0
        ? safetyInterval
        : Duration(
            seconds: (safetyInterval.inSeconds * (1 << _failures - 1))
                .clamp(safetyInterval.inSeconds, _maxBackoff.inSeconds),
          );
    _safety = Timer(delay, () {
      unawaited(tick());
      _armSafety();
    });
  }

  void stop() {
    _stopped = true;
    _safety?.cancel();
    _safety = null;
    _debounce?.cancel();
    _debounce = null;
    _watch?.close();
    _watch = null;
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
    // A reconnect often means the stream died too; re-open it.
    if (_watch == null) _openStream();
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
    if (_busy) {
      // A cycle is already talking to the server. Do NOT drop the request on
      // the floor: remember that another pass is needed and run it as soon as
      // the current one finishes. Silently returning here is what made edits
      // appear to "not sync" for up to a minute.
      _dirty = true;
      if (manual) _manualQueued = true;
      return;
    }
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
    if (manual && _store.pendingCount > 0) _setState(SyncState.syncing, '');

    try {
      // 1) Server -> local (server wins, outbox entries are protected).
      final doc = await relay.read();
      // Reconcile what we pulled with what we are about to push.
      await _applyServerState(doc);

      // 2) Local outbox -> server, then VERIFY before clearing.
      //
      // A relay that answers 200 is not proof the record landed: ntfy topics
      // are eventually consistent and replicate between nodes with a delay, so
      // a merge-read a moment later can miss a just-published document. Only
      // keys the server actually holds at our version leave the outbox —
      // anything else is retried on the next cycle instead of being reported
      // as saved and silently lost.
      final owner = _store.currentUserId;
      final outbox = _store.pendingSnapshot(owner);
      if (outbox.isNotEmpty && owner.isNotEmpty) {
        await relay.write({'rev': 0, 'entities': outbox});
        RelayDoc ack;
        try {
          ack = await relay.read();
        } catch (_) {
          ack = RelayDoc.unknown;
        }
        final confirmed = <String>[];
        for (final e in outbox.entries) {
          final srv = ack.entities[e.key];
          if (srv is! Map) continue;
          final mine = (e.value['updatedAt'] as num?)?.toInt() ?? 0;
          final theirs = (srv['updatedAt'] as num?)?.toInt() ?? 0;
          if (theirs >= mine) confirmed.add(e.key);
        }
        if (confirmed.isNotEmpty) await _store.clearPending(confirmed);
        _lastCount = confirmed.length;
        // The server now holds newer copies of these; reflect them locally.
        if (confirmed.isNotEmpty) {
          final subset = <String, dynamic>{
            for (final k in confirmed)
              if (ack.entities[k] is Map) k: ack.entities[k],
          };
          if (subset.isNotEmpty) {
            _store.beginRemoteApply();
            final changed = _store.applyServerSnapshot(subset);
            _store.endRemoteApply(changed);
          }
        }
        // Unverified rows stay queued; that is a retry, not a hard failure.
        if (!ack.authoritative && confirmed.isEmpty) {
          throw const RelayException('not acknowledged yet');
        }
      } else {
        _lastCount = doc.entities.length;
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
    } catch (e) {
      _failures = (_failures + 1).clamp(1, 6);
      _dirty = true;
      debugPrint('SYNCDBG ${e.runtimeType}: $e');
      _setState(SyncState.offline, _friendly(e));
      _armSafety();
    } finally {
      _busy = false;
      // Anything that arrived while we were busy gets a follow-up pass.
      if (!_stopped && (_dirty || _store.pendingCount > 0 || _manualQueued)) {
        _manualQueued = false;
        _debounce?.cancel();
        _debounce = Timer(
          _failures == 0 ? const Duration(milliseconds: 300) : _backoff(),
          () => unawaited(tick()),
        );
      }
    }
  }

  bool _manualQueued = false;

  Duration _backoff() => Duration(
        seconds: (safetyInterval.inSeconds * (1 << _failures - 1))
            .clamp(safetyInterval.inSeconds, _maxBackoff.inSeconds),
      );

  /// Pull-only, kept for the "sync now" button.
  Future<void> pull({bool silent = false}) => tick(manual: !silent);

  /// Push-only; the outbox is flushed by [tick], so this just runs a cycle.
  Future<void> push({bool silent = false}) => tick(manual: !silent);

  /// Writes the server snapshot into the boxes and drops vanished records.
  Future<void> _applyServerState(RelayDoc doc) async {
    var changed = false;
    _store.beginRemoteApply();
    try {
      changed = _store.applyServerSnapshot(doc.entities);
      // Only prune when the server actually returned a document. An empty or
      // unreadable answer means "unknown", never "everything was deleted".
      if (doc.authoritative) {
        final pruned = await _store.pruneMissing(
          _store.currentUserId,
          doc.entities.keys.map((e) => e.toString()).toSet(),
        );
        if (pruned) changed = true;
      }
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
    if (s.contains('429')) return 'rate limited';
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
    _openStream();
    await tick(manual: true);
    _armSafety();
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
    _openStream();
    await tick(manual: true);
    _armSafety();
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
        return ko ? '연결 대기 — 자동 재시도' : 'Waiting to reconnect';
      case SyncState.error:
        return ko ? '오류' : 'Error';
    }
  }
}

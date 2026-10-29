import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'cloud_backend.dart';

/// Firestore implementation of [CloudBackend].
///
/// Why Firestore:
///  * A permanent, real database — not a message queue with a 12 h retention.
///  * `snapshots()` gives push updates, so there is no polling, no SSE and no
///    rate limit to fight (that combination is what broke the previous relay).
///  * The SDK keeps its own offline queue and flushes it when the network
///    returns, which is exactly the "reconnect and sync" behaviour we want.
///  * The free tier is far beyond what a personal scheduler will ever use.
///
/// Layout: one document per workspace,
///   `workspaces/{workspaceId}` with `{ rev, entities: {key: record}, updatedAt }`.
///
/// Keeping the entities in a single map (instead of one document per task)
/// means a change is one atomic write, and a brand-new device gets a consistent
/// snapshot in one read — no half-synced intermediate state.
class FirestoreBackend implements CloudBackend {
  FirestoreBackend({FirebaseFirestore? db}) : _dbOverride = db;

  final FirebaseFirestore? _dbOverride;

  /// Resolved lazily, never in the constructor.
  ///
  /// `FirebaseFirestore.instance` throws when Firebase was not initialised
  /// (missing config, failed init). If the constructor touched it, simply
  /// *creating* the backend would take the app down — the store builds the
  /// engine the moment a user signs in. Resolving on use keeps that failure
  /// where it can be reported instead of thrown.
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;

  @override
  String get name => 'Firestore';

  @override
  bool get isConfigured => _dbOverride != null || Firebase.apps.isNotEmpty;

  DocumentReference<Map<String, dynamic>> _doc(String workspaceId) =>
      _db.collection('workspaces').doc(workspaceId);

  static const _timeout = Duration(seconds: 20);

  @override
  Future<CloudDoc> read(String workspaceId) async {
    try {
      final snap = await _doc(workspaceId).get().timeout(_timeout);
      if (!snap.exists) return CloudDoc.unknown;
      return _toDoc(snap.data());
    } on TimeoutException {
      // Treat a slow network as "unknown" rather than an error: the local cache
      // stays intact and the next attempt retries.
      return CloudDoc.unknown;
    } catch (e) {
      throw CloudException('read failed: $e');
    }
  }

  @override
  Future<CloudWriteResult> write(String workspaceId, CloudDoc doc) async {
    try {
      // Merge inside a transaction so two devices writing at the same time
      // cannot clobber each other. The merge rule is last-writer-wins per
      // record on `updatedAt`; deletions are explicit tombstones, so they win
      // by carrying a newer stamp rather than by disappearing.
      await _db.runTransaction((tx) async {
        final ref = _doc(workspaceId);
        final snap = await tx.get(ref);
        final current = snap.exists ? _toDoc(snap.data()).entities : <String, dynamic>{};

        final merged = <String, dynamic>{};
        for (final e in current.entries) {
          if (e.value is Map) {
            merged[e.key] = Map<String, dynamic>.from(e.value as Map);
          }
        }
        for (final e in doc.entities.entries) {
          final incoming = e.value;
          if (incoming is! Map) continue;
          final mine = (incoming['updatedAt'] as num?)?.toInt() ?? 0;
          final theirs = (merged[e.key] is Map)
              ? (((merged[e.key] as Map)['updatedAt'] as num?)?.toInt() ?? 0)
              : -1;
          if (mine >= theirs) {
            merged[e.key] = Map<String, dynamic>.from(incoming);
          }
        }

        final rev = snap.exists ? ((snap.data()?['rev'] as num?)?.toInt() ?? 0) : 0;
        tx.set(ref, {
          'rev': rev + 1,
          'entities': merged,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }).timeout(_timeout);

      return CloudWriteResult.success;
    } on TimeoutException {
      // The write may still land; leaving it "unknown" makes the engine keep
      // the records queued and retry, which is the safe direction.
      return CloudWriteResult(ok: false, error: 'timeout');
    } catch (e) {
      return CloudWriteResult.failure(e);
    }
  }

  @override
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
  }) {
    final sub = _doc(workspaceId).snapshots().listen(
      (snap) {
        if (!snap.exists) {
          onRemote(CloudDoc.unknown);
          return;
        }
        onRemote(_toDoc(snap.data()));
      },
      onError: (Object e) {
        debugPrint('CLOUDDBG snapshot error: $e');
        onError('$e');
      },
      cancelOnError: false,
    );
    return _FirestoreSubscription(sub);
  }

  @override
  Future<void> dispose() async {}

  CloudDoc _toDoc(Map<String, dynamic>? data) {
    if (data == null) return CloudDoc.unknown;
    final raw = data['entities'];
    final entities = <String, dynamic>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        if (e.value is Map) {
          entities[e.key.toString()] =
              Map<String, dynamic>.from(e.value as Map);
        }
      }
    }
    return CloudDoc(
      entities: entities,
      rev: (data['rev'] as num?)?.toInt() ?? 0,
    );
  }
}

class _FirestoreSubscription implements CloudSubscription {
  _FirestoreSubscription(this._sub);
  final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> _sub;

  @override
  void cancel() => _sub.cancel();
}

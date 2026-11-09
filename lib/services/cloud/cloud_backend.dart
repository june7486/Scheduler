/// The contract every cloud backend must satisfy.
///
/// The app deliberately knows nothing about *how* data is stored. It only knows
/// that a workspace document can be read, written, and watched. Swapping the
/// transport (NAS gateway, a self-hosted server, an in-memory test fake) never
/// touches a single screen.
library;

/// A single workspace document.
///
/// `entities` maps a flat key (`tasks/<id>`, `categories/<owner>::<id>`, …) to
/// that record's JSON. Keeping it flat means the merge rule is one comparison
/// per record and no nested-path bookkeeping.
class CloudDoc {
  const CloudDoc({
    required this.entities,
    required this.rev,
    this.exists = true,
    this.gen = 0,
  });

  final Map<String, dynamic> entities;
  final int rev;

  /// False when the backend has no document for this workspace yet (new
  /// account) or could not be reached. An unknown document must never be
  /// treated as "everything was deleted".
  final bool exists;

  /// Workspace generation. Incremented when the user wipes the workspace, so
  /// every other device can tell "the server is empty because I deleted
  /// everything" apart from "the server is empty because it is new". A device
  /// whose stored generation is behind drops its local cache and adopts the
  /// reset instead of helpfully uploading it all back.
  final int gen;

  static const unknown = CloudDoc(entities: {}, rev: 0, exists: false);

  @override
  String toString() =>
      'CloudDoc(rev=$rev, gen=$gen, exists=$exists, n=${entities.length})';
}

/// Result of a write attempt.
class CloudWriteResult {
  const CloudWriteResult({
    required this.ok,
    this.error,
    this.rev,
    this.gen,
    this.echo,
    this.lost,
    this.count,
  });

  final bool ok;
  final String? error;
  final int? rev;
  final int? gen;

  /// `entity/boxKey` → the `updatedAt` the server now holds for it.
  ///
  /// This is the whole reason a save costs one round trip instead of two: the
  /// merge already happened server-side, so the answer *is* the confirmation.
  /// Only records the server accepted at or above our version appear here, so a
  /// write that lost the merge stays in the outbox instead of being dropped.
  final Map<String, int>? echo;

  /// `entity/boxKey` → the record that **won** the merge on the server.
  ///
  /// Present only when this device's version lost (the same record was edited
  /// elsewhere simultaneously). Applying it locally also finishes the save in
  /// one round trip rather than needing a read to discover the winner.
  final Map<String, Map<String, dynamic>>? lost;

  /// How many records the workspace holds after the merge.
  final int? count;

  static const success = CloudWriteResult(ok: true);
  factory CloudWriteResult.failure(Object e) =>
      CloudWriteResult(ok: false, error: '$e');
}

/// Thrown by backend implementations for transport problems.
class CloudException implements Exception {
  const CloudException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One live subscription to the workspace.
abstract class CloudSubscription {
  void cancel();
}

/// Everything a sync engine needs from a storage provider.
abstract class CloudBackend {
  /// Human readable name shown in Settings.
  String get name;

  /// True when the backend is configured well enough to be used.
  bool get isConfigured;

  /// Reads the whole workspace.
  ///
  /// [haveRev] short-circuits the transfer: when it equals the server's current
  /// revision the backend may answer with an unchanged marker instead of the
  /// document. That is what makes a background check nearly free.
  ///
  /// Returns [CloudDoc.unknown] rather than throwing when the document simply
  /// does not exist yet.
  Future<CloudDoc> read(String workspaceId, {int haveRev = 0});

  /// Writes the whole workspace (the implementation must merge, never blind
  /// overwrite: two devices signing in at once must both keep their records).
  ///
  /// [extra] carries control records (e.g. a reset request) that travel with
  /// the merge rather than needing an HTTP verb of their own.
  Future<CloudWriteResult> write(
    String workspaceId,
    CloudDoc doc, {
    Map<String, dynamic>? extra,
  });

  /// Pushes the workspace to the backend whenever it changes anywhere.
  ///
  /// [onRemote] runs with the newest document. Implementations must also fire
  /// it once right after subscribing so the caller gets the initial state.
  ///
  /// [haveRev] lets the implementation skip the initial full download when the
  /// caller's cache is already current.
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
    int haveRev = 0,
  });

  /// Releases resources.
  Future<void> dispose() async {}

  /// Empties the workspace on the server and bumps its generation.
  ///
  /// This is what makes "reset everything" a real reset: other devices see the
  /// new generation, drop their cached copy, and adopt the empty workspace
  /// instead of dutifully uploading their old records back.
  ///
  /// Returns the new `rev`/`gen`. Backends that cannot do this report failure.
  Future<CloudWriteResult> resetWorkspace(String workspaceId) async =>
      const CloudWriteResult(ok: false, error: 'not supported');
}

/// The "no server configured" backend.
///
/// A build without a NAS address must still run: the app is fully usable as a
/// local-only scheduler, and Settings honestly reports that sync is off. Having
/// this as a real backend (instead of a null check in every call site) keeps
/// [SyncService] free of special cases — it just reports `notConfigured`.
class NullBackend implements CloudBackend {
  const NullBackend();

  @override
  String get name => 'none';

  @override
  bool get isConfigured => false;

  @override
  Future<CloudDoc> read(String workspaceId, {int haveRev = 0}) async =>
      CloudDoc.unknown;

  @override
  Future<CloudWriteResult> write(
    String workspaceId,
    CloudDoc doc, {
    Map<String, dynamic>? extra,
  }) async =>
      const CloudWriteResult(ok: false, error: 'no server configured');

  /// Returns an already-cancelled subscription: nothing to watch, nothing to
  /// schedule, no timer left running in a local-only session.
  @override
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
    int haveRev = 0,
  }) =>
      const _NullSubscription();

  @override
  Future<CloudWriteResult> resetWorkspace(String workspaceId) async =>
      const CloudWriteResult(ok: false, error: 'no server configured');

  @override
  Future<void> dispose() async {}
}

class _NullSubscription implements CloudSubscription {
  const _NullSubscription();

  @override
  void cancel() {}
}

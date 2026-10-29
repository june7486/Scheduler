/// The contract every cloud backend must satisfy.
///
/// The app deliberately knows nothing about *how* data is stored. It only knows
/// that a workspace document can be read, written, and watched. That way the
/// backend can be swapped (Firestore today, a self-hosted server tomorrow)
/// without touching a single screen.
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
  });

  final Map<String, dynamic> entities;
  final int rev;

  /// False when the backend has no document for this workspace yet (new
  /// account) or could not be reached. An unknown document must never be
  /// treated as "everything was deleted".
  final bool exists;

  static const unknown = CloudDoc(entities: {}, rev: 0, exists: false);

  @override
  String toString() => 'CloudDoc(rev=$rev, exists=$exists, n=${entities.length})';
}

/// Result of a write attempt.
class CloudWriteResult {
  const CloudWriteResult({required this.ok, this.error, this.rev});

  final bool ok;
  final String? error;
  final int? rev;

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
  /// Returns [CloudDoc.unknown] rather than throwing when the document simply
  /// does not exist yet.
  Future<CloudDoc> read(String workspaceId);

  /// Writes the whole workspace (the implementation must merge, never blind
  /// overwrite: two devices signing in at once must both keep their records).
  Future<CloudWriteResult> write(String workspaceId, CloudDoc doc);

  /// Pushes the workspace to the backend whenever it changes anywhere.
  ///
  /// [onRemote] runs with the newest document. Implementations must also fire
  /// it once right after subscribing so the caller gets the initial state.
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
  });

  /// Releases resources.
  Future<void> dispose() async {}
}

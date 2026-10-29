import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'event_source_stub.dart'
    if (dart.library.js_interop) 'event_source_web.dart' as sse;
import 'sync_crypto.dart';

/// Raised for any transport problem; the engine turns this into "offline".
class RelayException implements Exception {
  final String message;
  const RelayException(this.message);
  @override
  String toString() => message;
}

/// A single document per workspace: read the merged entity map, write it back.
///
/// Two implementations exist:
///  * [RestRelay]  — a user-hosted relay speaking `GET /state` + `POST /push`
///    (see `server/sync-worker.js`). Recommended for permanent use.
///  * [NtfyRelay]  — the zero-setup fallback on ntfy.sh, so cross-device sync
///    works out of the box with no account and no server to run.
abstract class SyncRelay {
  /// Current workspace state.
  ///
  /// [RelayDoc.authoritative] tells the engine whether an empty answer means
  /// "the workspace really is empty" or "we could not find any document".
  Future<RelayDoc> read();

  /// Publishes the full state. Existing records are merged, never dropped.
  Future<void> write(Map<String, dynamic> state);

  /// Live change notifications, if the transport supports them.
  ///
  /// Emits whenever *somebody else* published a new document, so the engine can
  /// reconcile immediately instead of polling. Returns `null` when the
  /// transport has no push channel (a REST relay); the engine then falls back
  /// to its slow safety-net timer.
  RelayWatch? watch(RelayWatchHandlers handlers) => null;

  /// Releases any stream / long-lived connection.
  void dispose() {}
}

/// Result of [SyncRelay.read].
///
/// [authoritative] is false when the relay had **no readable document at all**
/// (brand-new workspace, expired retention, or every shard unreadable). In that
/// case the engine must NOT prune local records: an empty answer means "we do
/// not know", not "everything was deleted".
class RelayDoc {
  const RelayDoc(this.entities, {this.authoritative = true});

  final Map<String, dynamic> entities;
  final bool authoritative;

  /// Convenience so `doc['entities']` still reads like the old map API.
  Object? operator [](String key) {
    switch (key) {
      case 'entities':
        return entities;
      case 'rev':
        return authoritative ? 1 : 0;
    }
    return null;
  }

  static const unknown = RelayDoc(<String, dynamic>{}, authoritative: false);
}

/// A live connection to the relay's change feed.
abstract class RelayWatch {
  void close();
}

/// Callbacks the engine attaches to a [RelayWatch].
class RelayWatchHandlers {
  const RelayWatchHandlers({
    required this.onOpen,
    required this.onChange,
    required this.onError,
  });

  final void Function() onOpen;
  final void Function() onChange;
  final void Function(String reason) onError;
}

/// Builds the production relay for a workspace code (used by tests/probes).
class NtfyRelayFactory {
  static SyncRelay of(String code) => NtfyRelay(code);
}

/// Picks the right transport for a user-supplied base URL.
SyncRelay makeRelay(String baseUrl, String code) {
  final trimmed = baseUrl.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.contains('ntfy.sh')) {
    return NtfyRelay(code);
  }
  return RestRelay(trimmed.isEmpty ? NtfyRelay.defaultBaseUrl : trimmed, code);
}

// ---------------------------------------------------------------------------
// REST relay (Cloudflare Worker / self-hosted python reference server)
// ---------------------------------------------------------------------------

class RestRelay extends SyncRelay {
  RestRelay(this.baseUrl, this.code);

  final String baseUrl;
  final String code;

  static const _timeout = Duration(seconds: 12);

  Uri _uri(String path, [Map<String, String>? q]) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final u = Uri.parse('$base$path');
    return q == null ? u : u.replace(queryParameters: q);
  }

  @override
  Future<RelayDoc> read() async {
    final res = await http
        .get(_uri('/state', {'code': code}))
        .timeout(_timeout);
    if (res.statusCode == 404) return RelayDoc.unknown;
    if (res.statusCode != 200) {
      throw RelayException('HTTP ${res.statusCode} ${_snippet(res.body)}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is! Map) throw const RelayException('Bad response');
    final entities = (body['entities'] as Map?) ?? const {};
    return RelayDoc(
      Map<String, dynamic>.from(entities),
      authoritative: body['exists'] != false,
    );
  }

  @override
  Future<void> write(Map<String, dynamic> state) async {
    final res = await http
        .post(
          _uri('/push'),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: utf8.encode(
            jsonEncode({
              'code': code,
              'baseRev': (state['rev'] as num?)?.toInt() ?? 0,
              'entities': state['entities'] ?? {},
            }),
          ),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw RelayException('HTTP ${res.statusCode} ${_snippet(res.body)}');
    }
  }
}

// ---------------------------------------------------------------------------
// ntfy.sh relay — no account, no server, works immediately
// ---------------------------------------------------------------------------

/// Publishes the workspace as an encrypted, chunked document on a topic derived
/// from the sync code. Anyone without the code cannot find the topic (it is a
/// SHA-256 prefix) and cannot decrypt the payload (AES-256-CBC).
///
/// ### Why there is no polling loop
/// ntfy.sh rate-limits anonymous callers to roughly one request every five
/// seconds, with a burst allowance. A client that polls every second burns
/// through the allowance in under a minute and then gets `HTTP 429` — which
/// looks exactly like "the server is down". Instead this relay keeps **one**
/// long-lived Server-Sent-Events connection (`/topic/sse`) and only fetches the
/// document when a message actually arrives.
class NtfyRelay extends SyncRelay {
  NtfyRelay(this.code) : _crypto = SyncCrypto(code);

  /// Used as the built-in default so sync works with nothing configured.
  static const defaultBaseUrl = 'https://ntfy.sh';

  final String code;
  final SyncCrypto _crypto;

  static const _timeout = Duration(seconds: 15);

  /// ntfy caps a short text message at 4096 bytes; base64 + envelope overhead
  /// means ~2400 usable characters per message. Above that it silently turns
  /// the body into a file *attachment*, which JS could not read back.
  static const _shardChars = 2400;

  /// Envelope prefix, so unrelated messages on the same topic are ignored.
  static const _marker = 'J1';

  static final _base64 = RegExp(r'^[A-Za-z0-9+/=]+$');

  /// Topic name: deterministic from the code, unguessable without it.
  String get topic {
    final d = sha256.convert(utf8.encode('june-sync-topic-v1|${code.toUpperCase()}'));
    return 'junes${d.toString().substring(0, 24)}';
  }

  Uri _poll([String since = 'all']) =>
      Uri.parse('https://ntfy.sh/$topic/json?poll=1&since=$since');

  /// Reassembly cache: ntfy holds only a handful of documents, so re-decrypting
  /// the same sequence on every read is wasted CPU. Keyed by sequence id.
  final Map<String, Map<String, dynamic>> _decoded = <String, Map<String, dynamic>>{};

  /// The newest sequence successfully decoded, if any.
  String? lastSeq;

  @override
  Future<RelayDoc> read() async {
    http.Response? res;
    // `since=all` is the primary form; the fallbacks keep a single odd gateway
    // response from pinning the client to "offline" forever.
    for (final since in const ['all', '24h', '7d']) {
      try {
        final r = await http.get(_poll(since)).timeout(_timeout);
        if (r.statusCode == 200) {
          res = r;
          break;
        }
      } catch (_) {
        // try the next variant
      }
    }
    // Nothing answered: report "unknown" instead of "empty", so a network blip
    // can never make the engine delete the local cache.
    if (res == null) return RelayDoc.unknown;

    final text = utf8.decode(res.bodyBytes, allowMalformed: true);

    // Group shards by publish sequence, then take the newest set that both
    // reassembles completely AND decrypts. Anything else on the topic (a stray
    // text message, a file-attachment notice ntfy substituted for an oversized
    // chunk) is simply skipped instead of poisoning the whole read.
    final partial = <String, Map<int, String>>{};
    final totals = <String, int>{};

    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      Object? event;
      try {
        event = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (event is! Map) continue;
      final message = event['message'];
      if (message is! String || !message.startsWith('$_marker:')) continue;

      // J1:<seq>:<index>/<total>:<base64 payload>
      final parts = message.split(':');
      if (parts.length < 4) continue;
      final seq = parts[1];
      final idxParts = parts[2].split('/');
      if (idxParts.length != 2) continue;
      final idx = int.tryParse(idxParts[0]);
      final total = int.tryParse(idxParts[1]);
      if (idx == null || total == null) continue;
      if (total <= 0 || total > 512 || idx < 0 || idx >= total) continue;

      final payload = parts.sublist(3).join(':');
      // Base64 only. This is what rejects ordinary chatter on the topic.
      if (!_base64.hasMatch(payload)) continue;
      if (payload.length > _shardChars + 64) continue;

      partial.putIfAbsent(seq, () => <int, String>{})[idx] = payload;
      totals[seq] = total;
    }

    // Newest first, so the most recent workspace state wins.
    final sequences = partial.keys.toList()..sort((a, b) => b.compareTo(a));

    for (final seq in sequences) {
      final cached = _decoded[seq];
      if (cached != null) {
        lastSeq = seq;
        return RelayDoc(cached);
      }

      final total = totals[seq] ?? 0;
      final chunks = partial[seq]!;
      if (chunks.length != total) continue;

      final buffer = StringBuffer();
      var complete = true;
      for (var i = 0; i < total; i++) {
        final chunk = chunks[i];
        if (chunk == null) {
          complete = false;
          break;
        }
        buffer.write(chunk);
      }
      if (!complete) continue;

      final decoded = _crypto.decryptJson(buffer.toString());
      if (decoded is! Map) continue; // wrong key or corrupted -> try older

      final entities = <String, dynamic>{};
      final raw = decoded['entities'];
      if (raw is Map) {
        for (final e in raw.entries) {
          if (e.value is Map) {
            entities[e.key.toString()] = Map<String, dynamic>.from(e.value as Map);
          }
        }
      }
      // Keep only the few newest entries to bound memory.
      _decoded[seq] = entities;
      if (_decoded.length > 4) {
        final oldest = _decoded.keys.toList()..sort();
        while (_decoded.length > 4) {
          _decoded.remove(oldest.removeAt(0));
        }
      }
      lastSeq = seq;
      return RelayDoc(entities);
    }

    // Nothing readable: a brand-new workspace, or the old document aged out.
    // Either way this is NOT proof that records were deleted.
    return RelayDoc.unknown;
  }

  @override
  Future<void> write(Map<String, dynamic> state) async {
    // ntfy replaces the document instead of merging, so merge here first:
    // otherwise a device that had not pulled yet would wipe the other's rows.
    final RelayDoc remote;
    try {
      remote = await read();
    } catch (e) {
      throw RelayException('merge-read failed: $e');
    }
    final merged = <String, dynamic>{};
    final local = (state['entities'] as Map?) ?? {};

    for (final e in remote.entities.entries) {
      final rec = e.value;
      if (rec is Map) merged[e.key.toString()] = Map<String, dynamic>.from(rec);
    }
    for (final e in local.entries) {
      final rec = e.value;
      if (rec is! Map) continue;
      final prev = merged['${e.key}'];
      final remoteStamp =
          prev is Map ? ((prev['updatedAt'] as num?)?.toInt() ?? 0) : -1;
      final localStamp = (rec['updatedAt'] as num?)?.toInt() ?? 0;
      if (localStamp >= remoteStamp) {
        merged['${e.key}'] = Map<String, dynamic>.from(rec);
      }
    }

    final blob = _crypto.encryptJson({'rev': 1, 'entities': merged});
    final chunks = <String>[];
    for (var i = 0; i < blob.length; i += _shardChars) {
      chunks.add(
        blob.substring(i, (i + _shardChars).clamp(0, blob.length)),
      );
    }
    if (chunks.isEmpty) chunks.add('');

    final seq = DateTime.now().toUtc().microsecondsSinceEpoch
        .toRadixString(36)
        .toUpperCase()
        .padLeft(10, '0');

    for (var i = 0; i < chunks.length; i++) {
      final body = '$_marker:$seq:$i/${chunks.length}:${chunks[i]}';
      final res = await http
          .post(
            Uri.parse('https://ntfy.sh/$topic'),
            headers: {'Content-Type': 'text/plain; charset=utf-8'},
            body: utf8.encode(body),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        // A chunk the relay refused cannot be delivered; surface it so the
        // outbox keeps the record instead of silently dropping it.
        throw RelayException('upload rejected (${res.statusCode})');
      }
    }

    // Our own document is now the newest one; remember it so the next read is
    // a cache hit and the change feed does not echo it back as "remote news".
    _decoded[seq] = merged;
    lastSeq = seq;
  }

  NtfyWatch? _watch;

  @override
  RelayWatch? watch(RelayWatchHandlers handlers) {
    // No EventSource outside the browser. That is NOT a failure: plain HTTPS
    // reads still work, so return "no push channel" and let the engine's
    // safety-net timer do the work instead of scaring the user with
    // "server unreachable".
    if (!kIsWeb) return null;
    _watch ??= NtfyWatch(topic, handlers);
    return _watch;
  }

  @override
  void dispose() {
    _watch?.close();
    _watch = null;
  }
}

/// One self-healing SSE connection to `https://ntfy.sh/<topic>/sse`.
///
/// The stream itself carries no document, only "something changed here" — the
/// payload is still fetched with a single `GET ?poll=1&since=all`. That keeps
/// the request count at one per change instead of one per second.
class NtfyWatch implements RelayWatch {
  NtfyWatch(this.topic, this.handlers) {
    // Connect on the next microtask so the caller can finish wiring things up.
    scheduleMicrotask(_connect);
  }

  final String topic;
  final RelayWatchHandlers handlers;

  sse.EventSourceHandle? _handle;
  Timer? _retry;
  int _attempt = 0;
  bool _closed = false;
  bool _everOpen = false;

  String get _url => 'https://ntfy.sh/$topic/sse?since=all';

  bool get isLive => _everOpen && _handle != null;

  void _connect() {
    if (_closed) return;
    _handle = sse.openEventSource(
      _url,
      onOpen: () {
        _attempt = 0;
        _everOpen = true;
        handlers.onOpen();
      },
      onMessage: (data) {
        // Keepalives and the initial "open" frame are not content changes.
        if (data.contains('"event":"keepalive"')) return;
        if (data.contains('"event":"open"')) return;
        handlers.onChange();
      },
      onError: () {
        if (_closed) return;
        _handle?.close();
        _handle = null;
        if (!_everOpen) handlers.onError('stream unavailable');
        _scheduleReconnect();
      },
    );
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _retry?.cancel();
    _attempt = (_attempt + 1).clamp(1, 8);
    final delay = Duration(seconds: (1 << _attempt).clamp(2, 60));
    _retry = Timer(delay, _connect);
  }

  @override
  void close() {
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _handle?.close();
    _handle = null;
  }
}

String _snippet(String body) {
  final t = body.trim();
  return t.length > 160 ? t.substring(0, 160) : t;
}

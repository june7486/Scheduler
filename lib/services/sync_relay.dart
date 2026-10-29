import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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
  /// Current workspace state: `{rev, entities:{key: record}}`.
  Future<Map<String, dynamic>> read();

  /// Publishes the full state. Existing records are merged, never dropped.
  Future<void> write(Map<String, dynamic> state);
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

class RestRelay implements SyncRelay {
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
  Future<Map<String, dynamic>> read() async {
    final res = await http
        .get(_uri('/state', {'code': code}))
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw RelayException('HTTP ${res.statusCode} ${_snippet(res.body)}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is! Map) throw const RelayException('Bad response');
    return {'rev': (body['rev'] as num?)?.toInt() ?? 0, 'entities': body['entities'] ?? {}};
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
class NtfyRelay implements SyncRelay {
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

  @override
  Future<Map<String, dynamic>> read() async {
    http.Response? res;
    // ignore: unused_local_variable
    Object? lastError;
    // `since=all` is the primary form; a couple of fallbacks keep a single
    // odd gateway response from pinning the client to "offline" forever.
    for (final since in const ['all', '24h', '7d']) {
      try {
        final r = await http.get(_poll(since)).timeout(_timeout);
        if (r.statusCode == 200) {
          res = r;
          break;
        }
        lastError = 'HTTP ${r.statusCode}';
      } catch (e) {
        lastError = '$e';
      }
    }
    if (res == null) {
      // An unreachable/oddly-answering topic must not wedge the engine: treat
      // it as "no document yet" and let the next cycle retry.
      return {'rev': 0, 'entities': <String, dynamic>{}};
    }
    if (res.statusCode != 200) {
      throw RelayException('HTTP ${res.statusCode} ${_snippet(res.body)}');
    }
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
    final sequences = partial.keys.toList()
      ..sort((a, b) => b.compareTo(a));

    for (final seq in sequences) {
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
      return {
        'rev': (decoded['rev'] as num?)?.toInt() ?? 0,
        'entities': decoded['entities'] ?? {},
      };
    }

    // Nothing readable yet: an empty workspace, not an error. Throwing here
    // would pin the client to "offline" forever over a stale message.
    return {'rev': 0, 'entities': <String, dynamic>{}};
  }

  @override
  Future<void> write(Map<String, dynamic> state) async {
    // ntfy replaces the document instead of merging, so merge here first:
    // otherwise a device that had not pulled yet would wipe the other's rows.
    final Map<String, dynamic> remote;
    try {
      remote = await read();
    } catch (e) {
      throw RelayException('merge-read failed: $e');
    }
    final merged = <String, dynamic>{};
    final local = (state['entities'] as Map?) ?? {};
    final other = (remote['entities'] as Map?) ?? {};

    for (final e in other.entries) {
      final rec = e.value;
      if (rec is Map) merged['${e.key}'] = Map<String, dynamic>.from(rec);
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
        throw RelayException(
          'upload rejected (${res.statusCode})',
        );
      }
    }
  }
}

String _snippet(String body) {
  final t = body.trim();
  return t.length > 160 ? t.substring(0, 160) : t;
}

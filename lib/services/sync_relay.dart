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
      throw RelayException('HTTP ${res.statusCode}');
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
      throw RelayException('HTTP ${res.statusCode}');
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

  /// Topic name: deterministic from the code, unguessable without it.
  String get topic {
    final d = sha256.convert(utf8.encode('june-sync-topic-v1|${code.toUpperCase()}'));
    return 'junes${d.toString().substring(0, 24)}';
  }

  Uri _poll() => Uri.parse(
    'https://ntfy.sh/$topic/json?poll=1&since=all&scheduled=0',
  );

  @override
  Future<Map<String, dynamic>> read() async {
    final res = await http.get(_poll()).timeout(_timeout);
    if (res.statusCode != 200) {
      throw RelayException('HTTP ${res.statusCode}');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);

    // Keep only complete document sets, keyed by publish sequence.
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

      // J1:<seq>:<index>/<total>:<payload>
      final parts = message.split(':');
      if (parts.length < 4) continue;
      final seq = parts[1];
      final idxParts = parts[2].split('/');
      if (idxParts.length != 2) continue;
      final idx = int.tryParse(idxParts[0]);
      final total = int.tryParse(idxParts[1]);
      if (idx == null || total == null || total <= 0) continue;

      final payload = parts.sublist(3).join(':');
      partial.putIfAbsent(seq, () => <int, String>{})[idx] = payload;
      totals[seq] = total;
    }

    // Newest complete document wins.
    String? best;
    for (final e in partial.entries) {
      final total = totals[e.key] ?? 0;
      if (e.value.length != total) continue;
      if (best == null || e.key.compareTo(best) > 0) best = e.key;
    }
    if (best == null) return {'rev': 0, 'entities': <String, dynamic>{}};

    final buffer = StringBuffer();
    for (var i = 0; i < (totals[best] ?? 0); i++) {
      final chunk = partial[best]![i];
      if (chunk == null) return {'rev': 0, 'entities': <String, dynamic>{}};
      buffer.write(chunk);
    }

    final decoded = _crypto.decryptJson(buffer.toString());
    if (decoded is! Map) {
      // Either tampered with, or encrypted under a different code.
      throw const RelayException('sync code mismatch');
    }
    return {
      'rev': (decoded['rev'] as num?)?.toInt() ?? 0,
      'entities': decoded['entities'] ?? {},
    };
  }

  @override
  Future<void> write(Map<String, dynamic> state) async {
    // ntfy replaces the document instead of merging, so merge here first:
    // otherwise a device that had not pulled yet would wipe the other's rows.
    final remote = await read();
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
        throw RelayException('HTTP ${res.statusCode}');
      }
    }
  }
}

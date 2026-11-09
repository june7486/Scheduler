import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'cloud_backend.dart';

/// Talks to the NAS gateway (see `server/gateway/server.js`).
///
/// The gateway holds the DSM session and re-exposes one small JSON file per
/// workspace with proper CORS, so the browser never talks to Synology directly.
///
/// Three endpoints:
///   GET  /health                       — is the NAS awake?
///   GET  /api/state?ws=&rev=&gen=&wait= — document, or "unchanged" after a wait
///   POST /api/push                     — merge entities, return the echo
///
/// ## Why this is fast
/// * **One round trip per save.** The push answer carries an `echo` map of
///   `key → updatedAt` the server now holds, so the client can clear its outbox
///   from the reply itself. The previous design wrote and then immediately
///   re-read the whole document — doubling latency on every keystroke batch.
/// * **Long poll instead of a timer.** `wait=25` parks the request server-side;
///   the answer lands the moment another device writes, so changes feel
///   instant while idle sessions cost one request per 25 s instead of one per 2 s.
/// * **`rev` and `gen` short-circuits.** An unchanged workspace answers ~40 bytes,
///   and a generation mismatch (the user wiped everything) forces a full sync.
class NasBackend implements CloudBackend {
  NasBackend({
    required String baseUrl,
    this.secret = '',
    http.Client? client,
  })  : _base = _normalise(baseUrl),
        _client = client ?? http.Client();

  /// e.g. `https://sync.mydomain.net`, `http://192.216.0.20:8097`
  final String _base;

  /// Optional shared key (`X-Sync-Key`). Empty means the gateway is open — fine
  /// on a trusted LAN, never on the public internet.
  final String secret;

  final http.Client _client;

  /// Generous, because a long poll is *supposed* to sit there. The gateway caps
  /// its own wait below this, so hitting the timeout means a dead connection.
  static const _timeout = Duration(seconds: 40);
  static const _shortTimeout = Duration(seconds: 15);

  /// How long a `watch` request is parked server-side.
  static const pollWaitSeconds = 25;

  static String _normalise(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  @override
  String get name => 'NAS';

  @override
  bool get isConfigured => _base.isNotEmpty;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=utf-8',
        if (secret.isNotEmpty) 'X-Sync-Key': secret,
      };

  Uri _uri(String path, [Map<String, String>? q]) {
    final u = Uri.parse('$_base$path');
    return q == null ? u : u.replace(queryParameters: q);
  }

  /// Quick reachability probe used by the Settings screen.
  Future<bool> ping() async {
    if (!isConfigured) return false;
    try {
      final r = await _client.get(_uri('/health')).timeout(_shortTimeout);
      if (r.statusCode != 200) return false;
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      // `nas:false` means the gateway is up but the NAS login failed — honest
      // reporting beats a green light that lies.
      return body is Map && body['nas'] != false;
    } catch (_) {
      return false;
    }
  }

  static CloudDoc _docFrom(Map body) {
    final raw = body['entities'];
    final entities = <String, dynamic>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        if (e.value is Map) {
          entities['${e.key}'] = Map<String, dynamic>.from(e.value as Map);
        }
      }
    }
    return CloudDoc(
      entities: entities,
      rev: (body['rev'] as num?)?.toInt() ?? 0,
      gen: (body['gen'] as num?)?.toInt() ?? 0,
      exists: body['exists'] != false,
    );
  }

  @override
  Future<CloudDoc> read(String workspaceId, {int haveRev = 0}) async {
    if (!isConfigured) return CloudDoc.unknown;
    try {
      final r = await _client
          .get(
            _uri('/api/state', {
              'ws': workspaceId,
              if (haveRev > 0) 'rev': '$haveRev',
            }),
            headers: _headers,
          )
          .timeout(_shortTimeout);
      if (r.statusCode == 401) throw const CloudException('bad key');
      if (r.statusCode != 200) throw CloudException('HTTP ${r.statusCode}');
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is! Map) throw const CloudException('bad response');
      if (body['unchanged'] == true) {
        throw const CloudException('unchanged'); // caller already has it
      }
      if (body['exists'] == false) return CloudDoc.unknown;
      return _docFrom(body);
    } on CloudException {
      rethrow;
    } catch (e) {
      throw CloudException('read failed: $e');
    }
  }

  @override
  Future<CloudWriteResult> write(
    String workspaceId,
    CloudDoc doc, {
    Map<String, dynamic>? extra,
  }) async {
    if (!isConfigured) {
      return const CloudWriteResult(ok: false, error: 'nas not configured');
    }
    try {
      final payload = <String, dynamic>{
        'ws': workspaceId,
        'entities': doc.entities,
        if (extra != null) ...extra,
      };
      final r = await _client
          .post(
            _uri('/api/push'),
            headers: _headers,
            body: utf8.encode(jsonEncode(payload)),
          )
          .timeout(_shortTimeout);
      if (r.statusCode == 401) {
        return const CloudWriteResult(ok: false, error: 'bad key');
      }
      if (r.statusCode != 200) {
        return CloudWriteResult(ok: false, error: 'HTTP ${r.statusCode}');
      }
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is! Map) {
        return const CloudWriteResult(ok: false, error: 'bad response');
      }
      final echoRaw = body['echo'];
      final echo = <String, int>{};
      if (echoRaw is Map) {
        for (final e in echoRaw.entries) {
          echo['${e.key}'] = (e.value as num?)?.toInt() ?? 0;
        }
      }
      final lostRaw = body['lost'];
      final lost = <String, Map<String, dynamic>>{};
      if (lostRaw is Map) {
        for (final e in lostRaw.entries) {
          if (e.value is Map) {
            lost['${e.key}'] = Map<String, dynamic>.from(e.value as Map);
          }
        }
      }
      return CloudWriteResult(
        ok: true,
        rev: (body['rev'] as num?)?.toInt(),
        gen: (body['gen'] as num?)?.toInt(),
        echo: echo,
        lost: lost.isEmpty ? null : lost,
        count: (body['count'] as num?)?.toInt(),
      );
    } catch (e) {
      return CloudWriteResult.failure(e);
    }
  }

  @override
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
    int haveRev = 0,
  }) {
    final poller = _NasLongPoller(
      this,
      workspaceId,
      onRemote: onRemote,
      onError: onError,
      haveRev: haveRev,
    );
    poller.start();
    return poller;
  }

  @override
  Future<CloudWriteResult> resetWorkspace(String workspaceId) async {
    if (!isConfigured) {
      return const CloudWriteResult(ok: false, error: 'nas not configured');
    }
    try {
      final r = await _client
          .post(
            _uri('/api/reset'),
            headers: _headers,
            body: utf8.encode(jsonEncode({'ws': workspaceId})),
          )
          .timeout(_shortTimeout);
      if (r.statusCode != 200) {
        return CloudWriteResult(ok: false, error: 'HTTP ${r.statusCode}');
      }
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is! Map) {
        return const CloudWriteResult(ok: false, error: 'bad response');
      }
      return CloudWriteResult(
        ok: true,
        rev: (body['rev'] as num?)?.toInt(),
        gen: (body['gen'] as num?)?.toInt(),
        count: 0,
      );
    } catch (e) {
      return CloudWriteResult.failure(e);
    }
  }

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

/// One parked request per workspace.
///
/// The gateway holds the connection until something changes (or ~25 s passes),
/// so this loop is idle rather than busy: no 2-second hammering, no rate limit,
/// and a change on another device arrives within one round trip.
class _NasLongPoller implements CloudSubscription {
  _NasLongPoller(
    this._backend,
    this._workspaceId, {
    required this.onRemote,
    required this.onError,
    int haveRev = 0,
  }) : _rev = haveRev;

  final NasBackend _backend;
  final String _workspaceId;
  final void Function(CloudDoc) onRemote;
  final void Function(String) onError;

  /// Backoff bounds used only while the gateway is unreachable.
  static const _backoffBase = Duration(seconds: 1);
  static const _backoffMax = Duration(seconds: 30);

  Timer? _timer;
  int _failures = 0;
  int _rev;
  int _gen = 0;
  bool _closed = false;
  bool _busy = false;

  void start() {
    // First tick immediately: the caller may have an empty local cache.
    scheduleMicrotask(_tick);
  }

  Future<void> _tick() async {
    if (_closed || _busy) return;
    _busy = true;
    try {
      final r = await _backend._client
          .get(
            _backend._uri('/api/state', {
              'ws': _workspaceId,
              if (_rev > 0) 'rev': '$_rev',
              if (_gen > 0) 'gen': '$_gen',
              'wait': '${NasBackend.pollWaitSeconds}',
            }),
            headers: _backend._headers,
          )
          .timeout(NasBackend._timeout);
      if (_closed) return;

      if (r.statusCode == 401) {
        onError('bad key');
        _failures++;
      } else if (r.statusCode != 200) {
        onError('HTTP ${r.statusCode}');
        _failures++;
      } else {
        final body = jsonDecode(utf8.decode(r.bodyBytes));
        _failures = 0;
        if (body is Map) {
          final rev = (body['rev'] as num?)?.toInt() ?? 0;
          final gen = (body['gen'] as num?)?.toInt() ?? 0;
          if (body['unchanged'] == true) {
            _rev = rev;
            _gen = gen;
          } else if (body['exists'] == false) {
            _rev = rev;
            _gen = gen;
            onRemote(CloudDoc.unknown);
          } else {
            _rev = rev;
            _gen = gen;
            onRemote(NasBackend._docFrom(body));
          }
        }
      }
    } catch (e) {
      // A long poll hitting its own client timeout is normal-ish (the gateway
      // caps at 25 s), so only log genuine failures to keep the console honest.
      if (!_closed) {
        _failures++;
        if (_failures > 1) debugPrint('NASDBG poll failed: $e');
        onError('$e');
      }
    } finally {
      _busy = false;
      if (!_closed) _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_failures == 0) {
      // Answer arrived (a change, or the gateway's own 25 s cap).
      // Wait a single frame-ish beat so a hot loop cannot form if the server
      // replies instantly with `unchanged` for any reason.
      _timer = Timer(const Duration(milliseconds: 150), _tick);
      return;
    }
    final secs = (_backoffBase.inSeconds * (1 << (_failures - 1)))
        .clamp(_backoffBase.inSeconds, _backoffMax.inSeconds);
    _timer = Timer(Duration(seconds: secs), _tick);
  }

  /// Lets the engine tell the poller "I already have rev N", so the next tick
  /// does not re-download a document we just produced ourselves.
  void acknowledge(int rev, int gen) {
    _rev = rev;
    _gen = gen;
  }

  @override
  void cancel() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}

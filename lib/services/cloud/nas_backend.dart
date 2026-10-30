import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'cloud_backend.dart';

/// Talks to a sync server running on your own NAS (see `server/nas/server.js`).
///
/// This is the "my own land" option: the data file lives in a folder you
/// control, backed up by whatever your NAS already does. No account, no quota,
/// no retention limit, and no third party that can rate-limit you.
///
/// It speaks three endpoints:
///   GET  /health                    — is the NAS awake?
///   GET  /api/state?ws=…&rev=…      — full document (or `unchanged`)
///   POST /api/push                  — merge entities, last-writer-wins
///
/// Polling is cheap here because the server is yours, but the engine still
/// prefers one long-lived loop over hammering: an unchanged answer is a tiny
/// `{unchanged:true}` body, and the interval scales with failures.
class NasBackend implements CloudBackend {
  NasBackend({
    required String baseUrl,
    this.secret = '',
    http.Client? client,
  })  : _base = _normalise(baseUrl),
        _client = client ?? http.Client();

  /// e.g. `http://192.168.0.20:8099`, `https://nas.mydomain.net`
  final String _base;

  /// Optional shared key (`X-Sync-Key`). Empty means the server is open — fine
  /// on a trusted LAN, not fine on the public internet.
  final String secret;

  final http.Client _client;

  static const _timeout = Duration(seconds: 15);

  static String _normalise(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
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
      final r = await _client.get(_uri('/health')).timeout(_timeout);
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<CloudDoc> read(String workspaceId) async {
    if (!isConfigured) return CloudDoc.unknown;
    try {
      final r = await _client
          .get(_uri('/api/state', {'ws': workspaceId}), headers: _headers)
          .timeout(_timeout);
      if (r.statusCode == 401) throw const CloudException('bad key');
      if (r.statusCode != 200) {
        throw CloudException('HTTP ${r.statusCode}');
      }
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is! Map) throw const CloudException('bad response');
      if (body['exists'] == false) return CloudDoc.unknown;
      final raw = body['entities'];
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
        rev: (body['rev'] as num?)?.toInt() ?? 0,
      );
    } on CloudException {
      rethrow;
    } catch (e) {
      throw CloudException('read failed: $e');
    }
  }

  @override
  Future<CloudWriteResult> write(String workspaceId, CloudDoc doc) async {
    if (!isConfigured) {
      return const CloudWriteResult(ok: false, error: 'nas not configured');
    }
    try {
      final r = await _client
          .post(
            _uri('/api/push'),
            headers: _headers,
            body: utf8.encode(
              jsonEncode({'ws': workspaceId, 'entities': doc.entities}),
            ),
          )
          .timeout(_timeout);
      if (r.statusCode != 200) {
        return CloudWriteResult(ok: false, error: 'HTTP ${r.statusCode}');
      }
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      final rev = body is Map ? (body['rev'] as num?)?.toInt() : null;
      return CloudWriteResult(ok: true, rev: rev);
    } catch (e) {
      return CloudWriteResult.failure(e);
    }
  }

  /// Polls `/api/state`. The first call returns `exists:false` for a new
  /// workspace, which the engine treats as "seed me" rather than "empty".
  @override
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
  }) {
    final poller = _NasPoller(
      this,
      workspaceId,
      onRemote: onRemote,
      onError: onError,
    );
    poller.start();
    return poller;
  }

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

/// One self-scheduling read loop per workspace.
///
/// Interval grows while the NAS is unreachable (2s → 60s) and resets the
/// moment it answers again, so a sleeping NAS costs nothing and a live one
/// feels instant. `rev` is sent so an unchanged workspace returns ~20 bytes.
class _NasPoller implements CloudSubscription {
  _NasPoller(
    this._backend,
    this._workspaceId, {
    required this.onRemote,
    required this.onError,
  });

  final NasBackend _backend;
  final String _workspaceId;
  final void Function(CloudDoc) onRemote;
  final void Function(String) onError;

  static const _fast = Duration(seconds: 2);
  static const _slow = Duration(seconds: 60);

  Timer? _timer;
  int _failures = 0;
  int _rev = 0;
  bool _closed = false;
  bool _busy = false;

  void start() {
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
            }),
            headers: _backend._headers,
          )
          .timeout(NasBackend._timeout);
      if (_closed) return;

      if (r.statusCode == 401) {
        onError('bad key');
      } else if (r.statusCode != 200) {
        onError('HTTP ${r.statusCode}');
        _failures++;
      } else {
        final body = jsonDecode(utf8.decode(r.bodyBytes));
        _failures = 0;
        if (body is Map) {
          final rev = (body['rev'] as num?)?.toInt() ?? 0;
          if (body['unchanged'] == true) {
            _rev = rev;
          } else if (body['exists'] == false) {
            onRemote(CloudDoc.unknown);
          } else {
            _rev = rev;
            final raw = body['entities'];
            final entities = <String, dynamic>{};
            if (raw is Map) {
              for (final e in raw.entries) {
                if (e.value is Map) {
                  entities[e.key.toString()] =
                      Map<String, dynamic>.from(e.value as Map);
                }
              }
            }
            onRemote(CloudDoc(entities: entities, rev: rev));
          }
        }
      }
    } catch (e) {
      if (!_closed) {
        debugPrint('NASDBG poll failed: $e');
        onError('$e');
        _failures++;
      }
    } finally {
      _busy = false;
      if (!_closed) _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final secs = _failures == 0
        ? _fast.inSeconds
        : (_fast.inSeconds * (1 << (_failures - 1)))
            .clamp(_fast.inSeconds, _slow.inSeconds);
    _timer = Timer(Duration(seconds: secs), _tick);
  }

  @override
  void cancel() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}

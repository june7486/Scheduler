import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'cloud/cloud_backend.dart';
import 'cloud/nas_backend.dart';
import 'cloud/sync_engine.dart';

/// Central application state & persistence layer.
///
/// Multi-user model:
///   * `users` box holds [User] records keyed by login id.
///   * every task / category / log / voice note carries an `ownerId`.
///   * the master account can read and manage every user's data.
///
/// Uses Hive boxes of plain maps (no code-gen adapters) so the web build stays
/// simple and reliable.
class Store extends ChangeNotifier {
  static const _userBox = 'users';
  static const _taskBox = 'tasks';
  static const _catBox = 'categories';
  static const _logBox = 'logs';
  static const _voiceBox = 'voices';
  static const _prefBox = 'prefs';

  /// The owner account. The password is **not** in the source.
  ///
  /// A fresh install has no local `june7486` at all; the first sign-in reads
  /// `accounts/june7486` from that account's workspace on the server, checks the
  /// password there, and caches the account locally. So this constant no longer
  /// grants access — it only names the account that is allowed to be master.
  ///
  /// Getting here took a deliberate order: the account had to reach the server
  /// *before* the password could be deleted from the code, otherwise the first
  /// login on a new device would have had nothing to adopt.
  static const masterId = 'june7486';

  // A ready-to-use demo account (id/pw = test/test).
  static const testId = 'test';
  static const testPw = 'test';

  late Box _users;
  late Box _tasks;
  late Box _cats;
  late Box _logs;
  late Box _voices;
  late Box _prefs;

  final _uuid = const Uuid();

  bool _ready = false;
  bool get isReady => _ready;

  /// Cloud storage provider — a NAS gateway (or any server speaking the
  /// `server/gateway` protocol).
  ///
  /// A build-time default via `--dart-define=SYNC_URL=…` means a deployed build
  /// needs no setup: sign in and it is already pointed at the NAS. That value is
  /// only a fallback, so Settings can still override it per device.
  ///
  /// Created lazily so the very first frame never waits on anything.
  CloudBackend? _backendOverride;
  CloudBackend get backend => _backendOverride ??= _resolveBackend();

  CloudBackend _resolveBackend() {
    final url = _nasUrl.isNotEmpty ? _nasUrl : _envSyncUrl;
    if (url.isEmpty) return const NullBackend();
    return NasBackend(
      baseUrl: url,
      secret: _nasKey.isNotEmpty ? _nasKey : _envSyncKey,
    );
  }

  /// Address baked into the build (`--dart-define=SYNC_URL`).
  static const _envSyncUrl = String.fromEnvironment('SYNC_URL');

  /// Shared key baked into the build (`--dart-define=SYNC_KEY`).
  static const _envSyncKey = String.fromEnvironment('SYNC_KEY');

  /// Builds the NAS client from the saved URL + key. Cheap, but not cached: the
  /// URL can change from Settings, and a stale cached client would keep talking
  /// to the old address.
  NasBackend _nas() => NasBackend(baseUrl: _nasUrl, secret: _nasKey);

  String get _nasUrl => (_users.get('__sync_url__') as String?) ?? '';

  String get _nasKey => (_users.get('__sync_secret__') as String?) ?? '';

  /// The address actually in use (saved value, else the build default).
  String get nasUrl => _nasUrl.isNotEmpty ? _nasUrl : _envSyncUrl;

  /// Saved shared key for the gateway (empty when none was set).
  String get nasSecret => _nasKey.isNotEmpty ? _nasKey : _envSyncKey;

  /// Replaces the storage provider (tests, or a different server).
  void useBackend(CloudBackend backend) {
    final wasStarted = _sync != null;
    _sync?.stop();
    _backendOverride = backend;
    _sync = null;
    // If an engine had already been created (login fires start() eagerly), give
    // the caller a live engine on the new backend instead of a dead one.
    if (wasStarted) unawaited(sync.start());
  }

  /// Points every future read/write at a NAS (or any server speaking the
  /// `server/gateway/server.js` protocol) and remembers it for next launch.
  ///
  /// An empty [url] means "go back to the cloud default", which is why the
  /// stored key is cleared as well — half a configuration is worse than none.
  Future<void> useNasBackend({required String url, String secret = ''}) async {
    final clean = url.trim();
    await _users.put('__sync_url__', clean);
    await _users.put('__sync_secret__', secret.trim());
    _backendOverride = clean.isEmpty ? null : _nas();
    final wasStarted = _sync != null;
    _sync?.stop();
    _sync = null;
    if (wasStarted) unawaited(sync.start());
    notifyListeners();
  }

  /// Quick "can we reach it?" probe for the Settings screen.
  Future<bool> pingNas({required String url, String secret = ''}) =>
      NasBackend(baseUrl: url, secret: secret).ping();

  bool get usingNas => _nasUrl.isNotEmpty;

  /// Cross-device sync engine. Built on first use for the same reason.
  SyncService? _sync;
  SyncService get sync => _sync ??= SyncService(this, backend);

  /// Replaces the engine instance (used by tests to drive a cycle directly).
  void attachSync(SyncService svc) => _sync = svc;

  /// Suppresses the auto-push while the app itself is applying remote data.
  int _remoteDepth = 0;

  /// Called by [SyncService] when its state changes. Must bypass the
  /// auto-push override below, otherwise notifyListeners() -> markDirty() ->
  /// _setState() -> onSyncStatusChanged() recurses forever and blows the stack.
  void onSyncStatusChanged() => super.notifyListeners();

  /// Wraps a batch of remote writes so they do not bounce back to the server.
  void beginRemoteApply() => _remoteDepth++;

  /// Ends a remote-apply batch and rebuilds the UI exactly once, only when
  /// something actually changed.
  void endRemoteApply(bool changed) {
    if (_remoteDepth > 0) _remoteDepth--;
    if (changed && _remoteDepth == 0) super.notifyListeners();
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    // Any local mutation should be pushed to the other devices — but never
    // while we are the ones applying a pulled change (that would ping-pong).
    //
    // Only schedule an upload when the outbox is actually non-empty. Delaying
    // here is not a shortcut, it is the fix for a request storm: widgets call
    // back into the store during build (logging, seeding), each call notifies,
    // and an unconditional markDirty() turned that into endless ticks — 270+
    // `HTTP 429` responses in one session. The outbox is the single source of
    // truth for "something needs uploading", so trusting it is both correct
    // and quiet.
    if (_ready && _remoteDepth == 0 && pendingCount > 0) sync.markDirty();
  }

  String _currentUserId = '';
  bool _masterViewingAll = false;

  // ---------------- Init ----------------
  Future<void> init() async {
    await Hive.initFlutter();
    _users = await Hive.openBox(_userBox);
    _tasks = await Hive.openBox(_taskBox);
    _cats = await Hive.openBox(_catBox);
    _logs = await Hive.openBox(_logBox);
    _voices = await Hive.openBox(_voiceBox);
    _prefs = await Hive.openBox(_prefBox);

    await _ensureMaster();
    await _ensureTestUser();
    await _loadRemembered();
    await rememberAppVersion();
    _ready = true;
    notifyListeners();
  }

  /// Puts a master-shaped user in the box on a brand-new install.
  ///
  /// The stored password is **random per install** and never shown or typed, so
  /// it can never be used to sign in. It only makes `userById(masterId)` return
  /// something sane before the first real sign-in. Actual access is decided by
  /// the server copy of `accounts/june7486` — see [authenticate].
  Future<void> _ensureMaster() async {
    if (!_users.containsKey(masterId)) {
      final master = User(
        id: masterId,
        password: _randomPlaceholder(),
        displayName: 'Master',
        isMaster: true,
      );
      await _users.put(masterId, master.toMap());
    }
  }

  /// 32 random hex chars. Uses [Uuid]'s v4 source, which is already a dependency
  /// and is cryptographically seeded.
  String _randomPlaceholder() =>
      '${_uuid.v4()}-${_uuid.v4()}'.replaceAll('-', '');

  /// Ensures the demo account (id/pw = test/test) exists with sample content,
  /// so reviewers can sign in immediately without the master credentials.
  Future<void> _ensureTestUser() async {
    if (!_users.containsKey(testId)) {
      final u = User(id: testId, password: testPw, displayName: 'Test');
      await _users.put(testId, u.toMap());
    }
    await _ensureUserSeed(testId);
    if (tasksForOwner(testId).isEmpty) {
      final ko = language == 'ko';
      final samples = <Map<String, dynamic>>[
        {
          'cat': 'todo',
          'title': ko ? '샘플 할일 — 시험용' : 'Sample to-do — for testing',
          'note': ko ? '테스트 계정입니다' : 'This is the test account',
        },
        {
          'cat': 'finance',
          'title': ko ? '장보기 (예산 ₩50,000)' : 'Groceries (₩50,000 budget)',
          'amount': 50000,
        },
        {'cat': 'bank', 'title': ko ? '은행 업무 확인' : 'Check bank work'},
        {'cat': 'scout', 'title': ko ? '스카우트 대장 미팅' : 'Scout leader meeting'},
      ];
      for (final s in samples) {
        final t = Task(
          id: _uuid.v4(),
          ownerId: testId,
          title: s['title'] as String,
          note: (s['note'] ?? '') as String,
          categoryId: s['cat'] as String,
          amount: (s['amount'] as num?)?.toDouble(),
        );
        await _tasks.put(t.id, t.toMap());
      }
    }
  }

  // ---------------- Users ----------------
  /// The `users` box also holds reserved app-metadata entries (keys wrapped in
  /// `__…__`, e.g. __lang__, __theme_mode__, __app_version__). Those must never
  /// be parsed as [User] records.
  static bool _isReservedKey(Object? key) =>
      key is String && key.startsWith('__') && key.endsWith('__');

  List<User> get allUsers {
    final list = <User>[];
    for (final key in _users.keys) {
      if (_isReservedKey(key)) continue;
      final raw = _users.get(key);
      if (raw is Map) {
        list.add(User.fromMap(raw));
      }
    }
    list.sort((a, b) {
      if (a.isMaster != b.isMaster) return a.isMaster ? -1 : 1;
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  User? userById(String id) {
    final raw = _users.get(id);
    return raw == null ? null : User.fromMap(raw);
  }

  // ---------------- remembered accounts ----------------
  //
  // Who has signed in on *this* device. The login form shows these as one-tap
  // chips, which is the difference between "type a 12-character password on a
  // phone keyboard every morning" and "tap your name".
  //
  // Deliberately stored outside the `users` box: it is a list of ids only, not
  // credentials, and it must never be published to the server. The passwords
  // used for the one-tap path live in `shared_preferences`, which is
  // device-local by definition — copying them to the NAS would undo the whole
  // point of stripping plaintext from the synced account rows.

  /// Ids that have signed in here, most recent first.
  List<String> get rememberedAccountIds => List<String>.from(_remembered);

  /// Accounts this device can offer with one tap.
  ///
  /// Only accounts that still exist locally *and* are enabled: a deleted or
  /// disabled account must not linger as a button that cannot work.
  List<User> get rememberedAccounts {
    final out = <User>[];
    for (final id in _remembered) {
      final u = userById(id);
      if (u == null || !u.enabled) continue;
      out.add(u);
    }
    return out;
  }

  List<String> _remembered = const [];
  Map<String, String> _savedPw = const {};
  SharedPreferences? _devicePrefs;

  static const _kRemembered = 'remembered_accounts';
  static const _kSavedPwPrefix = 'saved_pw::';

  Future<SharedPreferences> get _device async =>
      _devicePrefs ??= await SharedPreferences.getInstance();

  /// Loads the remembered list. Called from [init]; failures are non-fatal.
  Future<void> _loadRemembered() async {
    try {
      final prefs = await _device;
      _remembered = prefs.getStringList(_kRemembered) ?? const [];
      final pw = <String, String>{};
      for (final id in _remembered) {
        final v = prefs.getString('$_kSavedPwPrefix$id');
        if (v != null && v.isNotEmpty) pw[id] = v;
      }
      _savedPw = pw;
    } catch (_) {
      _remembered = const [];
      _savedPw = const {};
    }
  }

  /// Records that [id] signed in on this device, optionally remembering [pw].
  ///
  /// [pw] is only remembered when the caller explicitly wants one-tap sign-in;
  /// a wrong or empty password is never stored.
  Future<void> rememberAccount(
    String id, {
    bool rememberPassword = true,
  }) async {
    if (id.isEmpty) return;
    final next = [id, ..._remembered.where((e) => e != id)];
    // Keep the list short — a login screen with twenty chips is noise.
    _remembered = next.take(6).toList();
    final saved = Map<String, String>.from(_savedPw);
    try {
      final prefs = await _device;
      await prefs.setStringList(_kRemembered, _remembered);
      if (rememberPassword) {
        final u = userById(id);
        final pw = u?.password ?? '';
        if (pw.isNotEmpty && !_looksLikePlaceholder(pw)) {
          saved[id] = pw;
          await prefs.setString('$_kSavedPwPrefix$id', pw);
        }
      }
      _savedPw = saved;
    } catch (_) {
      // Private browsing / storage full: the chip still appears, it just asks
      // for the password. Never let this break a successful sign-in.
    }
    notifyListeners();
  }

  /// The password saved on this device for [id], if any.
  String? savedPasswordFor(String id) {
    final v = _savedPw[id];
    return (v != null && v.isNotEmpty) ? v : null;
  }

  /// Drops the saved password but keeps the account in this device's list.
  ///
  /// Used when a one-tap sign-in is refused: the saved copy is probably stale
  /// (the password was changed elsewhere), and a chip that keeps failing is
  /// worse than one that asks. The user only has to type the password once —
  /// [rememberAccount] saves it again on the next successful sign-in.
  Future<void> forgetSavedPassword(String id) async {
    if (!_savedPw.containsKey(id)) return;
    _savedPw = Map<String, String>.from(_savedPw)..remove(id);
    try {
      final prefs = await _device;
      await prefs.remove('$_kSavedPwPrefix$id');
    } catch (_) {}
    notifyListeners();
  }

  /// Forgets one account on this device (its chip and its saved password).
  Future<void> forgetAccount(String id) async {
    _remembered = _remembered.where((e) => e != id).toList();
    final saved = Map<String, String>.from(_savedPw)..remove(id);
    _savedPw = saved;
    try {
      final prefs = await _device;
      await prefs.setStringList(_kRemembered, _remembered);
      await prefs.remove('$_kSavedPwPrefix$id');
    } catch (_) {}
    notifyListeners();
  }

  User? get currentUser => userById(_currentUserId);
  String get currentUserId => _currentUserId;
  bool get isMaster => currentUser?.isMaster ?? false;

  /// When true, a non-master... (reserved) ; master can switch data scope.
  bool get masterViewingAll => _masterViewingAll;
  void setMasterViewingAll(bool v) {
    _masterViewingAll = v;
    notifyListeners();
  }

  /// Verifies credentials. On success sets the current user & seeds data.
  ///
  /// ## Signing in on a device that has never seen this account
  /// The account row normally lives in the local `users` box — which a brand-new
  /// phone does not have. Without help, "sign in with the same id" would answer
  /// "no such account" on every new device, which makes the whole cross-device
  /// promise hollow.
  ///
  /// The workspace key is derived from the id alone ([workspaceCodeFor]), so the
  /// device *can* find the account's server document before it knows anything
  /// else: ask the server for that workspace, and if it holds an `accounts/<id>`
  /// record, prove the password against it and adopt the account locally.
  ///
  /// That one lookup is why this method is `async` beyond the local check — and
  /// why it is only attempted when the local check fails, so the common case
  /// still answers instantly without touching the network.
  Future<bool> authenticate(String id, String pw) async {
    final trimmed = id.trim();

    // The registry is the authority when it is reachable. Checking it first is
    // the whole point of central account management: a local row must not be
    // able to accept a password the other devices would reject.
    var u = await _bounded<User?>(
      () => authenticateAgainstRegistry(trimmed, pw),
    );

    if (u == null) {
      // Registry unreachable, or it does not know this id yet (an account made
      // before the registry existed). Fall back to the device's own copy, then to
      // the account's own workspace.
      final local = userById(trimmed);
      final localOk = local != null && local.enabled && local.password == pw;
      if (localOk) {
        u = local;
      } else {
        u = await _bounded<User?>(() => _adoptAccountFromServer(trimmed, pw));
        if (u == null) {
          // Say *why*, and leave a trace. A single "아이디 또는 비밀번호가
          // 올바르지 않습니다" for both "wrong password" and "the server never
          // answered" sends people hunting for a typo when the real problem is
          // the connection — and leaves nothing in the log to tell them apart
          // afterwards.
          final reason = await _diagnoseReason();
          addLog('LoginFailed', '$trimmed reason=$reason');
          return false;
        }
      }
    }

    final user = u;
    _currentUserId = user.id;
    await _ensureUserSeed(user.id);
    await rememberAccount(user.id);
    addLog('Login', user.id);
    notifyListeners();
    // Every account is its own cloud workspace: signing in is all it takes.
    await enableAutoSyncForUser();
    // Make this account discoverable from any other device.
    await publishAccount(user.id);
    // A workspace written before the account row carried `pwHash` cannot be
    // verified against by a new device. Now that we hold the plaintext (someone
    // just signed in with it), repair that copy. Fire-and-forget: a failure here
    // must not fail a successful login.
    unawaited(_healWorkspaceAccountRow(user));
    unawaited(sync.start());
    return true;
  }

  /// Why a sign-in could not be confirmed, for the log.
  ///
  /// Distinguishes "the password is wrong" from "the server never answered".
  /// Uses the *saved* address and key, not a blank client, so the answer
  /// describes the connection this device is actually configured for.
  Future<String> _diagnoseReason() async {
    if (!_backendIsUsable) return 'notConfigured';
    try {
      final url = nasUrl;
      if (url.isEmpty) return 'notConfigured';
      final d = await NasBackend(
        baseUrl: url,
        secret: nasSecret,
      ).diagnose().timeout(_registryTimeout);
      return d.name;
    } catch (_) {
      return 'unreachable';
    }
  }

  /// Ensures the workspace's own `accounts/<id>` row carries a usable `pwHash`.
  ///
  /// Best-effort only. Quietly does nothing when the row already has a hash, when
  /// the server is unreachable, or when the local password is a placeholder.
  Future<void> _healWorkspaceAccountRow(User u) async {
    if (!_backendIsUsable) return;
    if (_looksLikePlaceholder(u.password)) return;
    try {
      final ws = workspaceCodeFor(u.id);
      final doc = await backend.read(ws);
      final row = doc.entities['accounts/${u.id}'];
      if (row is! Map) return;
      final hasHash = row['pwHash'];
      if (hasHash is String && hasHash.isNotEmpty) return; // already fine
      final fixed = Map<String, dynamic>.from(row);
      fixed.remove('password');
      fixed['pwHash'] = hashPassword(u.id, u.password);
      fixed['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
      await backend.write(
        ws,
        CloudDoc(
          entities: {'accounts/${u.id}': fixed},
          rev: doc.rev,
          gen: doc.gen,
        ),
      );
    } catch (_) {
      // A missing hash only affects brand-new devices; the account still works.
    }
  }

  /// Looks for `accounts/<id>` in that account's workspace and, when the
  /// password matches, writes the account locally so this device can sign in
  /// offline next time.
  ///
  /// Returns the adopted user, or null when the account does not exist, the
  /// password is wrong, or the server is unreachable. All three are the same
  /// "no" to the caller — a login form must never leak which one it was, and a
  /// wrong password must never overwrite a local account.
  Future<User?> _adoptAccountFromServer(String id, String pw) async {
    if (id.isEmpty) return null;
    if (!_backendIsUsable) return null;

    try {
      final doc = await backend.read(workspaceCodeFor(id));
      if (!doc.exists) return null;
      final raw = doc.entities['accounts/$id'];
      if (raw is! Map) return null;

      final remote = User.fromMap(raw);
      if (!remote.enabled) return null;

      // The workspace copy carries `pwHash`, never plaintext (see
      // [_accountRowForSync]), so comparing `remote.password` would reject every
      // correct password once this device has synced — the bug that stopped new
      // devices from signing in. Verify the hash, and keep accepting a legacy
      // plaintext row so accounts written by older builds still work.
      final record = Map<dynamic, dynamic>.from(raw);
      final hasHash = record['pwHash'];
      final verified = (hasHash is String && hasHash.isNotEmpty)
          ? verifyAccountPassword(record, pw)
          : remote.password == pw;
      if (!verified) return null;

      // This is the only moment the plaintext is known — the user just typed it.
      remote.password = pw;

      // Adopt locally. `updatedAt` is kept so a later merge does not treat this
      // copy as a fresh local edit and push it back.
      await _users.put(remote.id, remote.toMap());
      return remote;
    } catch (_) {
      // Offline, bad key, server down: fall back to "cannot verify".
      return null;
    }
  }

  /// True when a backend is configured well enough to be asked anything.
  bool get _backendIsUsable {
    try {
      return backend.isConfigured;
    } catch (_) {
      return false;
    }
  }

  /// Makes the given account available on every device.
  ///
  /// Called on login and whenever the display name changes. The record travels
  /// as a normal entity (`accounts/<id>`) so it merges last-writer-wins like
  /// everything else.
  ///
  /// The password hash is deliberately **not** rewritten here — see
  /// [publishAccountToRegistry] for why a routine sign-in must not be able to
  /// overrule a password that was changed on another device.
  Future<void> publishAccount(String id, {bool withPassword = false}) async {
    if (id.isEmpty) return;
    if (!syncEnabled) return;
    final u = userById(id);
    if (u == null) return;
    u.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _users.put(id, u.toMap());
    await _markPending('accounts', id);
    // Keep the central list in step. This is what makes a rename, a display-name
    // change or a password change visible from every other device.
    await publishAccountToRegistry(u, withPassword: withPassword);
  }

  /// Turns cloud storage on for the signed-in account.
  ///
  /// The account id *is* the workspace key, so nothing has to be configured.
  Future<void> enableAutoSyncForUser() async {
    final uid = _currentUserId;
    if (uid.isEmpty) return;
    // Saying the same thing every launch is cheap; only write when it differs
    // so we do not churn the metadata box (and notify on every reload).
    if (_users.get('__sync_code__') != workspaceCodeFor(uid) ||
        _users.get('__sync_owner__') != uid ||
        _users.get('__sync_on__') != true) {
      await _users.put('__sync_code__', workspaceCodeFor(uid));
      await _users.put('__sync_owner__', uid);
      await _users.put('__sync_on__', true);
    }
  }

  /// The server-side workspace key for this account.
  ///
  /// Derived from the user id so every device that signs in lands on the same
  /// document — no code to copy, no server to choose. Prefixed and hashed so
  /// the id is opaque (it is the path, not a secret).
  String get workspaceId {
    final uid = _currentUserId;
    if (uid.isEmpty) return '';
    return workspaceCodeFor(uid);
  }

  /// Deterministic, non-guessable workspace key for an account id.
  /// Only this account can reach its document, and no code is ever shown.
  static String workspaceCodeFor(String userId) {
    var seed = utf8.encode('june-scheduler-account-v2|$userId');
    var digest = sha256.convert(seed);
    for (var i = 0; i < 128; i++) {
      digest = sha256.convert([...digest.bytes, ...seed]);
    }
    return 'ACC${digest.toString().substring(0, 28).toUpperCase()}';
  }

  // ---------------- account registry ----------------

  /// One shared workspace that lists every account, so ids are managed centrally
  /// instead of per device.
  ///
  /// ## Why a registry exists
  /// Each account's own workspace is derived from its id
  /// ([workspaceCodeFor]), which is enough to *find* an account you already know
  /// the name of. It is not enough to *manage* accounts: without a shared list,
  /// two devices can each create their own `june7486` with different passwords,
  /// and nothing notices. Signing in then means "whichever copy this device
  /// happens to hold", which is the opposite of one account.
  ///
  /// The registry is a fixed, well-known workspace holding
  /// `accounts/<id>` records. Every device reads the same one.
  ///
  /// ## Passwords
  /// Stored as `pwHash` — a salted SHA-256 of the id and password — never as
  /// plaintext. The gateway's shared key ships inside the web bundle and is
  /// therefore public, so anyone could fetch this document; a hash at least means
  /// they do not walk away with working credentials. Records written by older
  /// builds still carry a `password` field, and [verifyAccountPassword] still
  /// accepts those so no existing account is locked out.
  static const registryWorkspaceId = 'ACCREGISTRYJUNESCHEDULER0001';

  /// Salted, iterated hash. The iteration count is not about resisting a GPU
  /// farm (SHA-256 in Dart is not the tool for that) — it raises the cost of
  /// turning one leaked registry into a list of usable passwords.
  static String hashPassword(String id, String pw) {
    final seed = utf8.encode('june-scheduler-pw-v1|${id.toLowerCase()}|$pw');
    var digest = sha256.convert(seed);
    for (var i = 0; i < 256; i++) {
      digest = sha256.convert([...digest.bytes, ...seed]);
    }
    return digest.toString();
  }

  /// True when [record] describes an enabled account whose password is [pw].
  static bool verifyAccountPassword(Map<dynamic, dynamic> record, String pw) {
    if (record['enabled'] == false) return false;
    final id = '${record['id'] ?? ''}';
    if (id.isEmpty) return false;
    final hash = record['pwHash'];
    if (hash is String && hash.isNotEmpty) {
      return _constantTimeEquals(hash, hashPassword(id, pw));
    }
    // Legacy plaintext row (written before the registry existed).
    final plain = record['password'];
    return plain is String && plain == pw;
  }

  /// Compares without an early exit, so timing does not leak the prefix.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// The registry document as a map of `id -> record`.
  ///
  /// Returns an empty map when the registry cannot be read — a missing list means
  /// "no accounts known centrally", which callers must treat as "fall back", not
  /// as "the account does not exist".
  Future<Map<String, Map<String, dynamic>>> readAccountRegistry() async {
    if (!_backendIsUsable) return const {};
    try {
      final doc = await backend.read(registryWorkspaceId);
      final out = <String, Map<String, dynamic>>{};
      for (final e in doc.entities.entries) {
        if (!e.key.startsWith('accounts/')) continue;
        final raw = e.value;
        if (raw is! Map) continue;
        out[e.key.substring('accounts/'.length)] = Map<String, dynamic>.from(
          raw,
        );
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// How long a sign-in may wait on the central account list.
  ///
  /// A login form must answer even when the NAS is asleep, on the wrong network,
  /// or behind a reverse proxy that has stopped answering. Without a bound, that
  /// case would leave the button spinning instead of telling the user what
  /// happened.
  ///
  /// **Was 4 seconds — too tight.** A cold connection to a home NAS has to do
  /// DNS, a TCP handshake, a TLS handshake and then two round trips (registry,
  /// then the account's workspace), and a Synology reverse proxy adds a little
  /// on top. On a mobile network 4s is easily exceeded, and the failure mode is
  /// vicious: the timeout is swallowed, the local fallback finds no plaintext
  /// (it is never synced), and the user is told "wrong password" for what is
  /// really a slow connection. 12s still ends a press rather than hanging it.
  static const _registryTimeout = Duration(seconds: 12);

  /// Runs [work], but gives up after [_registryTimeout] instead of hanging.
  ///
  /// Returns null on timeout *and* on failure: to a login form those are the same
  /// "the server did not confirm this", and both have to fall through to the
  /// local path rather than keep the user waiting.
  Future<T?> _bounded<T>(Future<T> Function() work) async {
    final pending = work();
    // An answer that arrives after the deadline must not surface as an unhandled
    // error — nobody is listening to it anymore.
    pending.then((_) {}, onError: (Object _) {});
    try {
      return await pending.timeout(_registryTimeout);
    } catch (_) {
      return null;
    }
  }

  /// Writes this account into the shared registry.
  ///
  /// Best effort: a failure here must never block a sign-in, because the account
  /// still reaches its own workspace. It only means the central list is a little
  /// stale until the next attempt.
  ///
  /// ## [withPassword] exists to stop a password revert
  /// The registry is last-writer-wins on `updatedAt`, and every caller stamps
  /// "now". So whoever writes last owns the password — including a device that
  /// signed in **offline** with a password the user has since changed centrally.
  /// Publishing from that session would quietly restore the old password for
  /// every device, which is the per-device-account problem in disguise.
  ///
  /// Only the two situations where the local password is genuinely authoritative
  /// pass `true`: creating an account, and a deliberate password change. A plain
  /// sign-in refreshes everything else and leaves the hash alone.
  Future<bool> publishAccountToRegistry(
    User u, {
    bool withPassword = false,
  }) async {
    if (!_backendIsUsable) return false;
    try {
      final existing = await backend.read(registryWorkspaceId);
      final current = existing.entities['accounts/${u.id}'];
      final record = <String, dynamic>{
        'id': u.id,
        'displayName': u.displayName,
        'isMaster': u.isMaster,
        'enabled': u.enabled,
        'createdAt': u.createdAt.toIso8601String(),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        // Deliberately no `password` field: nothing in the registry is plaintext.
      };
      final inherited = current is Map ? current['pwHash'] : null;
      if (!withPassword && inherited is String && inherited.isNotEmpty) {
        // Someone else already decided the password. Do not overrule them.
        record['pwHash'] = inherited;
      } else {
        record['pwHash'] = hashPassword(u.id, u.password);
      }
      final res = await backend.write(
        registryWorkspaceId,
        CloudDoc(
          entities: {'accounts/${u.id}': record},
          rev: existing.rev,
          gen: existing.gen,
        ),
      );
      return res.ok;
    } catch (_) {
      return false;
    }
  }

  /// Marks an account disabled in the shared registry.
  ///
  /// The row is kept, not removed: a tombstone is what lets every device see the
  /// decision, and it keeps the id from being silently reused by someone else.
  /// [verifyAccountPassword] already refuses a record with `enabled == false`, so
  /// a retired account can no longer sign in anywhere — including on a device
  /// that has never seen it before.
  Future<bool> retireAccountInRegistry(String id) async {
    if (!_backendIsUsable || id.isEmpty) return false;
    try {
      final existing = await backend.read(registryWorkspaceId);
      final current = existing.entities['accounts/$id'];
      final record = <String, dynamic>{
        if (current is Map) ...Map<String, dynamic>.from(current),
        'id': id,
        'enabled': false,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };
      final res = await backend.write(
        registryWorkspaceId,
        CloudDoc(
          entities: {'accounts/$id': record},
          rev: existing.rev,
          gen: existing.gen,
        ),
      );
      return res.ok;
    } catch (_) {
      return false;
    }
  }

  /// Looks an account up in the registry and, when the password matches, adopts
  /// it locally so this device can sign in offline afterwards.
  ///
  /// This is what makes "one account, every device" true: the id is verified
  /// against the *central* copy, so a device cannot accept a different password
  /// just because it happens to hold an older local row.
  Future<User?> authenticateAgainstRegistry(String id, String pw) async {
    if (!_backendIsUsable) return null;
    try {
      final doc = await backend.read(registryWorkspaceId);
      final raw = doc.entities['accounts/$id'];
      if (raw is! Map) return null;
      if (!verifyAccountPassword(raw, pw)) return null;

      final adopted = User.fromMap(raw);
      // The plaintext password has to exist locally for the offline path, and
      // this is the only moment it is known — it is the one the user just typed.
      adopted.password = pw;
      await _users.put(adopted.id, adopted.toMap());
      return adopted;
    } catch (_) {
      return null;
    }
  }

  /// Does the registry already own this id, with a *different* password?
  ///
  /// Returns the display name when it does, so [addUser] can refuse instead of
  /// silently creating a second, unreachable account with the same name.
  Future<String?> registryConflict(String id, String pw) async {
    if (!_backendIsUsable) return null;
    try {
      final doc = await backend.read(registryWorkspaceId);
      final raw = doc.entities['accounts/$id'];
      if (raw is! Map) return null;
      // A retired row is not a conflict: the id is free to be claimed again by
      // whoever wants it. Refusing here would make "delete" useless, because the
      // id could never be reused.
      if (raw['enabled'] == false) return null;
      if (verifyAccountPassword(raw, pw)) return null; // same credentials: fine
      return '${raw['displayName'] ?? id}';
    } catch (_) {
      return null;
    }
  }

  /// Restores the signed-in user after a reload.
  ///
  /// Sync has to be restarted here too: the page reload wipes the timer and
  /// [currentUserId], and without this the app would look logged in while
  /// silently never talking to the server again.
  Future<void> setCurrentUser(String id) async {
    _currentUserId = id;
    notifyListeners();
    if (id.isEmpty) return;
    await enableAutoSyncForUser();
    await publishAccount(id);
    unawaited(sync.start());
  }

  void logoutCurrent() {
    sync.stop();
    _currentUserId = '';
    _masterViewingAll = false;
    notifyListeners();
  }

  /// Creates a new (non-master) user. Returns null on success, or an error
  /// message describing why creation failed.
  /// Creates a new (non-master) user. Returns null on success, or an error
  /// message describing why creation failed.
  Future<String?> addUser(
    String id,
    String pw, {
    String displayName = '',
  }) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return 'ID cannot be empty.';
    if (!RegExp(r'^[A-Za-z0-9_.@-]{3,}$').hasMatch(trimmed)) {
      return 'ID must be at least 3 chars (letters, numbers, . _ - @).';
    }
    if (pw.length < 4) return 'Password must be at least 4 characters.';
    if (_users.containsKey(trimmed)) return 'That ID already exists.';

    // Account ids are shared, not per device. Without this check a second device
    // could create the same id with its own password and the two "accounts"
    // would silently diverge — the exact failure this registry exists to stop.
    final taken = await registryConflict(trimmed, pw);
    if (taken != null) {
      return 'That ID is already registered ($taken). '
          'Sign in with its existing password.';
    }

    final u = User(id: trimmed, password: pw, displayName: displayName);
    await _users.put(trimmed, u.toMap());
    await _seedCategories(trimmed);
    // Register centrally so the id is claimed everywhere at once. Creation is
    // authoritative for the password — this is the moment it is decided.
    await publishAccountToRegistry(u, withPassword: true);
    addLog('Create user', trimmed);
    notifyListeners();
    return null;
  }

  Future<void> deleteUser(String id) async {
    if (id == masterId) return; // never delete the master
    // Retire the account centrally *before* dropping the local row: otherwise a
    // later sign-in on another device would just find the registry entry and
    // adopt the account again, and "deleted" would only mean "deleted here".
    await retireAccountInRegistry(id);
    await _users.delete(id);
    // Remove that user's data
    for (final k in _tasks.keys.toList()) {
      final m = _tasks.get(k);
      if (m != null && m['ownerId'] == id) await _tasks.delete(k);
    }
    for (final k in _cats.keys.toList()) {
      final m = _cats.get(k);
      if (m != null && m['ownerId'] == id) await _cats.delete(k);
    }
    for (final k in _logs.keys.toList()) {
      final m = _logs.get(k);
      if (m != null && m['ownerId'] == id) await _logs.delete(k);
    }
    for (final k in _voices.keys.toList()) {
      final m = _voices.get(k);
      if (m != null && m['ownerId'] == id) await _voices.delete(k);
    }
    addLog('Delete user', id);
    notifyListeners();
  }

  /// Master-only: change another user's password directly.
  Future<void> setUserPassword(String id, String newPw) async {
    final u = userById(id);
    if (u == null) return;
    u.password = newPw;
    await _users.put(id, u.toMap());
    addLog('Change password (admin)', id);
    notifyListeners();
  }

  /// Master-only: reset a user's password to a default value.
  Future<String> resetUserPassword(String id) async {
    const def = '1234';
    await setUserPassword(id, def);
    return def;
  }

  Future<void> updateUserPrefs(
    String id, {
    String? forwardUrl,
    String? appThemeMode,
    String? printDesignMode,
    double? baseFontSize,
    String? displayName,
  }) async {
    final u = userById(id);
    if (u == null) return;
    if (forwardUrl != null) u.forwardUrl = forwardUrl;
    if (appThemeMode != null) u.appThemeMode = appThemeMode;
    if (printDesignMode != null) u.printDesignMode = printDesignMode;
    if (baseFontSize != null) u.baseFontSize = baseFontSize;
    if (displayName != null) u.displayName = displayName;
    await _users.put(id, u.toMap());
    notifyListeners();
  }

  // ---------------- Ownership scope ----------------
  /// The owner scope used for the "my data" getters.
  String get _scopeId => _currentUserId;

  /// Owner ids the master can see; a normal user only sees themselves.
  List<String> get visibleOwnerIds {
    if (isMaster && _masterViewingAll) {
      return allUsers.map((u) => u.id).toList();
    }
    return [_scopeId];
  }

  // ---------------- Categories ----------------
  static const defaultCategories = <Map<String, dynamic>>[
    {'id': 'birthday', 'label': 'Birthday', 'emoji': '🎂', 'color': 0xFFEC407A},
    {'id': 'todo', 'label': 'To-Do', 'emoji': '✅', 'color': 0xFF66BB6A},
    {'id': 'finance', 'label': 'Finance', 'emoji': '💰', 'color': 0xFFFFA726},
    {
      'id': 'company',
      'label': 'Company Work',
      'emoji': '🏢',
      'color': 0xFF5C6BC0,
    },
    {
      'id': 'personal',
      'label': 'Personal Work',
      'emoji': '🏠',
      'color': 0xFF26A69A,
    },
    {'id': 'bank', 'label': 'Bank Work', 'emoji': '🏦', 'color': 0xFF7E57C2},
    {'id': 'debt', 'label': 'Debt List', 'emoji': '📉', 'color': 0xFFEF5350},
    {
      'id': 'receivable',
      'label': 'Receivables',
      'emoji': '📈',
      'color': 0xFF29B6F6,
    },
    {'id': 'scout', 'label': 'Scout Work', 'emoji': '⚜️', 'color': 0xFF8D6E63},
    {
      'id': 'longterm',
      'label': 'Long-term',
      'emoji': '🗓️',
      'color': 0xFF78909C,
    },
    {'id': 'repeat', 'label': 'Repeat', 'emoji': '🔁', 'color': 0xFF42A5F5},
    {'id': 'memo', 'label': 'Memo', 'emoji': '📝', 'color': 0xFFAB47BC},
    {'id': 'daily', 'label': 'Daily Tasks', 'emoji': '☀️', 'color': 0xFFFFCA28},
    {'id': 'other', 'label': 'Other', 'emoji': '📌', 'color': 0xFF90A4AE},
  ];

  String _catKey(String ownerId, String catId) => '$ownerId::$catId';
  String _logKey(String ownerId, String logId) => '$ownerId::$logId';

  /// Default tabs only: no upload is queued for them.
  ///
  /// Called at sign-in *before* the server has been consulted. Seeding is a
  /// convenience for a brand-new account, not a user edit — queuing it would put
  /// the new device in a position to overwrite the workspace the user built on
  /// another device. See [seedDefaultsIfEmpty] for the careful version.
  Future<void> _ensureUserSeed(String ownerId) async {
    final hasCats = _cats.values.any((e) => e['ownerId'] == ownerId);
    if (!hasCats) await _seedCategories(ownerId, silent: true);
  }

  /// Adds the default tabs, but only when they would not mask server data.
  ///
  /// Returns true when it actually seeded. Deliberately refuses when a queued
  /// upload exists: something is waiting to reach the server, so this device is
  /// not a blank slate and inventing tabs would mix local and remote state.
  Future<bool> seedDefaultsIfEmpty(String ownerId) async {
    final hasCats = _cats.values.any((e) => e['ownerId'] == ownerId);
    if (hasCats) return false;
    if (pendingDataCount > 0) return false;
    await _seedCategories(ownerId, silent: true);
    return true;
  }

  Future<void> _seedCategories(String ownerId, {bool silent = false}) async {
    for (var i = 0; i < defaultCategories.length; i++) {
      final c = defaultCategories[i];
      final id = c['id'] as String;
      await _cats.put(_catKey(ownerId, id), {
        'id': id,
        'ownerId': ownerId,
        'label': _label(id, c['label'] as String),
        'emoji': c['emoji'],
        'colorValue': c['color'],
        'order': i,
        'enabled': true,
        'showInTopTabs': i < 6,
      });
      // A default tab is not an edit. Queuing it would make a brand-new device
      // look like it had local changes, and the pull would then have to reconcile
      // a workspace it had just invented with the one the user actually built.
      if (!silent) await _markPending('categories', _catKey(ownerId, id));
    }
  }

  /// Localised default label for a built-in category id.
  String _label(String id, String fallback) {
    if (language == 'ko') {
      const ko = {
        'birthday': '생일',
        'todo': '할일',
        'finance': '금전출납',
        'company': '회사업무',
        'personal': '개인업무',
        'bank': '은행업무',
        'debt': '채무리스트',
        'receivable': '받을 돈',
        'scout': '스카우트업무',
        'longterm': '롱텀',
        'repeat': '반복',
        'memo': '메모',
        'daily': '매일 할일',
        'other': '기타',
      };
      return ko[id] ?? fallback;
    }
    return fallback;
  }

  List<Category> categoriesFor(String ownerId) {
    final list = _cats.values
        .where((e) => e['ownerId'] == ownerId && e['deletedAt'] == null)
        .map((e) => Category.fromMap(e))
        .toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  List<Category> get categories => categoriesFor(_scopeId);
  List<Category> get enabledCategories =>
      categories.where((c) => c.enabled).toList();
  List<Category> get topTabCategories =>
      categories.where((c) => c.enabled && c.showInTopTabs).toList();

  Category? categoryById(String catId, {String? ownerId}) {
    final oid = ownerId ?? _scopeId;
    final raw = _cats.get(_catKey(oid, catId));
    if (raw == null || raw['deletedAt'] != null) return null;
    return Category.fromMap(raw);
  }

  Future<void> saveCategory(Category c) async {
    await _putCat(c);
    notifyListeners();
  }

  Future<void> addCategory(
    String label, {
    String emoji = '📌',
    int color = 0xFF5C6BC0,
  }) async {
    final ownerId = _scopeId;
    final id = 'cat_${_uuid.v4().substring(0, 8)}';
    final existing = categoriesFor(ownerId);
    final maxOrder = existing.isEmpty ? 0 : existing.last.order + 1;
    await _cats.put(_catKey(ownerId, id), {
      'id': id,
      'ownerId': ownerId,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'label': label,
      'emoji': emoji,
      'colorValue': color,
      'order': maxOrder,
      'enabled': true,
      'showInTopTabs': true,
    });
    addLog('Add tab', label);
    notifyListeners();
  }

  Future<void> deleteCategory(String catId) async {
    final cat = categoryById(catId);
    final ownerId = _scopeId;

    // Soft delete the tab itself so the removal reaches other devices.
    final tomb = <String, dynamic>{
      'id': catId,
      'ownerId': ownerId,
      'label': cat?.label ?? catId,
      'emoji': cat?.emoji ?? '',
      'colorValue': cat?.colorValue ?? 0,
      'order': cat?.order ?? 0,
    };
    stamp(tomb);
    tomb['deletedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _cats.put(_catKey(ownerId, catId), tomb);
    await _markPending('categories', _catKey(ownerId, catId));

    // Re-point the tasks that used this tab.
    for (final t in tasksForCategory(catId, includeCompleted: true)) {
      if (t.categoryId == catId) t.categoryId = 'other';
      if (t.categoryIds.contains(catId)) {
        t.categoryIds = [...t.categoryIds]..remove(catId);
      }
      await _putTask(t);
    }
    addLog('Delete tab', cat?.label ?? catId);
    notifyListeners();
  }

  Future<void> reorderCategories(List<Category> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].order = i;
      await _putCat(ordered[i]);
    }
    notifyListeners();
  }

  // ---------------- Tasks ----------------
  List<Task> tasksForOwner(String ownerId) {
    final list = _tasks.values
        .where((e) => e['ownerId'] == ownerId && e['deletedAt'] == null)
        .map((e) => Task.fromMap(e))
        .toList();
    _sortTasks(list);
    return list;
  }

  void _sortTasks(List<Task> list) {
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final byOrder = a.order.compareTo(b.order);
      if (byOrder != 0) return byOrder;
      return a.createdAt.compareTo(b.createdAt);
    });
  }

  /// Tasks for the current scope (own data, or all users if master-viewing-all).
  List<Task> get tasks {
    if (isMaster && _masterViewingAll) {
      final list = _tasks.values
          .where((e) => e['deletedAt'] == null)
          .map((e) => Task.fromMap(e))
          .toList();
      _sortTasks(list);
      return list;
    }
    return tasksForOwner(_scopeId);
  }

  List<Task> allTasksRaw() => _tasks.values
      .where((e) => e['deletedAt'] == null)
      .map((e) => Task.fromMap(e))
      .toList();

  int allTaskTotal() =>
      _tasks.values.where((e) => e['deletedAt'] == null).length;

  List<Task> tasksForCategory(
    String categoryId, {
    bool includeCompleted = false,
    String? ownerId,
  }) {
    final oid = ownerId ?? _scopeId;
    return tasks
        .where((t) => t.ownerId == oid && t.isInCategory(categoryId))
        .where((t) => includeCompleted || !t.completed)
        .toList();
  }

  List<Task> completedForCategory(String categoryId, {String? ownerId}) {
    final oid = ownerId ?? _scopeId;
    return tasks
        .where(
          (t) => t.ownerId == oid && t.isInCategory(categoryId) && t.completed,
        )
        .toList();
  }

  int taskCountFor(String categoryId, {String? ownerId}) {
    final oid = ownerId ?? _scopeId;
    return tasks
        .where(
          (t) => t.ownerId == oid && t.isInCategory(categoryId) && !t.completed,
        )
        .length;
  }

  int openTaskCountForOwner(String ownerId) =>
      tasksForOwner(ownerId).where((t) => !t.completed).length;

  Future<void> saveTask(Task t) async {
    if (t.ownerId.isEmpty) t.ownerId = _scopeId;
    await _putTask(t);
    notifyListeners();
  }

  Future<Task> addTask(
    String title,
    String categoryId, {
    String note = '',
  }) async {
    final ownerId = _scopeId;
    final existing = tasksForOwner(ownerId);
    final maxOrder = existing.isEmpty
        ? 0
        : existing.map((e) => e.order).reduce((a, b) => a > b ? a : b) + 1;
    final t = Task(
      id: _uuid.v4(),
      title: title,
      note: note,
      ownerId: ownerId,
      categoryId: categoryId,
      order: maxOrder,
    );
    await _putTask(t);
    addLog('Add task', title);
    notifyListeners();
    return t;
  }

  Future<void> toggleComplete(Task t) async {
    t.completed = !t.completed;
    t.completedAt = t.completed ? DateTime.now() : null;
    await _putTask(t);
    addLog(t.completed ? 'Complete task' : 'Reopen task', t.title);
    notifyListeners();
  }

  Future<void> deleteTask(Task t) async {
    // Soft delete: keep a tombstone so the removal also reaches other devices.
    final m = t.toMap();
    stamp(m);
    m['deletedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _tasks.put(t.id, m);
    await _markPending('tasks', t.id);
    addLog('Delete task', t.title);
    notifyListeners();
  }

  Future<void> moveTask(Task t, String newCategoryId) async {
    t.categoryId = newCategoryId;
    await _putTask(t);
    final label = categoryById(newCategoryId)?.label ?? newCategoryId;
    addLog('Move task', '${t.title} → $label');
    notifyListeners();
  }

  /// Adds or removes [categoryId] on [t] (multi-tab membership).
  ///
  /// The primary [Task.categoryId] is always kept; the extra memberships live
  /// in [Task.categoryIds]. Toggling the primary off is a no-op.
  Future<void> toggleCategoryIn(Task t, String categoryId) async {
    final extra = [...t.categoryIds];
    if (categoryId == t.categoryId) {
      // Primary can't be removed; if it was re-toggled, nothing to do.
      return;
    }
    if (extra.contains(categoryId)) {
      extra.remove(categoryId);
    } else {
      extra.add(categoryId);
    }
    t.categoryIds = extra;
    await _putTask(t);
    notifyListeners();
  }

  // ---------------- Sync support ----------------
  /// Entity boxes that participate in cross-device sync, with the box's
  /// storage-key builder. Tasks/voices are keyed by their own id; categories
  /// and logs are keyed by `ownerId::id`.
  Map<String, Box> get _syncBoxes => {
    'tasks': _tasks,
    'categories': _cats,
    'voices': _voices,
    'prefs': _prefs,
    'accounts': _users,
  };

  /// Entities whose records are keyed by account id and therefore do not carry
  /// an `ownerId` the way tasks do.
  ///
  /// This matters in three places that filter on `ownerId` — `queueAllForUpload`,
  /// `pruneMissing` and `dropWorkspaceCache`. Treating an account row like a task
  /// would mean it is never uploaded, or worse, is deleted the first time a
  /// snapshot arrives without it.
  static const _ownerlessEntities = {'accounts'};

  /// True when [entity] scopes its records by `ownerId`.
  static bool _isOwned(String entity) => !_ownerlessEntities.contains(entity);

  /// Re-stamps every record of [ownerId] as modified now.
  ///
  /// Used when a second device adopts an existing workspace: without this its
  /// older copies would lose last-writer-wins against the server and the two
  /// devices would keep showing different data.
  Future<void> reStampAll(String ownerId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var i = 0;
    for (final e in _syncBoxes.entries) {
      for (final k in e.value.keys.toList()) {
        final raw = e.value.get(k);
        if (raw is! Map) continue;
        if ((raw['ownerId'] ?? '') != ownerId) continue;
        final m = Map<String, dynamic>.from(raw);
        // Keep a strict ordering inside one batch so nothing ties.
        m['updatedAt'] = now + (i++);
        await e.value.put(k, m);
      }
    }
  }

  /// Every syncable record of [ownerId] as `{boxKey: map}`, including
  /// soft-deleted tombstones so deletions propagate. Server bookkeeping fields
  /// (`_rev`, `_updatedAt`) are stripped.
  Map<String, Map<String, dynamic>> syncSnapshot(String ownerId) {
    final out = <String, Map<String, dynamic>>{};
    for (final e in _syncBoxes.entries) {
      final prefix = '${e.key}/';
      for (final k in e.value.keys) {
        final raw = e.value.get(k);
        if (raw is! Map) continue;
        if ((raw['ownerId'] ?? '') != ownerId) continue;
        final m = Map<String, dynamic>.from(raw);
        m.remove('_rev');
        m.remove('_updatedAt');
        if (e.key == 'accounts') {
          out['$prefix$k'] = _accountRowForSync('$k', m);
          continue;
        }
        out['$prefix$k'] = m;
      }
    }
    return out;
  }

  /// Timestamps of everything that changed since the last upload, per entity.
  Map<String, int> syncUpdatedAt(String ownerId) {
    final out = <String, int>{};
    for (final e in _syncBoxes.entries) {
      final prefix = '${e.key}/';
      for (final k in e.value.keys) {
        final raw = e.value.get(k);
        if (raw is! Map) continue;
        if ((raw['ownerId'] ?? '') != ownerId) continue;
        out['$prefix$k'] = (raw['updatedAt'] as num?)?.toInt() ?? 0;
      }
    }
    return out;
  }

  /// Highest `updatedAt` currently stored for [ownerId] (0 when none).
  int syncMaxUpdatedAt(String ownerId) {
    var max = 0;
    for (final v in syncUpdatedAt(ownerId).values) {
      if (v > max) max = v;
    }
    return max;
  }

  /// Marks an entity map as touched now. Call before persisting a change.
  static int stamp(Map<String, dynamic> m) {
    final t = DateTime.now().millisecondsSinceEpoch;
    m['updatedAt'] = t;
    return t;
  }

  /// Persists a task, stamping it as changed now (so it wins last-writer-wins
  /// against stale copies on other devices).
  Future<void> _putTask(Task t) async {
    final m = t.toMap();
    stamp(m);
    t.updatedAt = m['updatedAt'] as int;
    await _tasks.put(t.id, m);
    await _markPending('tasks', t.id);
  }

  /// Persists a category, stamped as changed now.
  Future<void> _putCat(Category c) async {
    final oid = c.ownerId.isEmpty ? _scopeId : c.ownerId;
    c.ownerId = oid;
    final m = c.toMap();
    stamp(m);
    c.updatedAt = m['updatedAt'] as int;
    await _cats.put(_catKey(oid, c.id), m);
    await _markPending('categories', _catKey(oid, c.id));
  }

  /// Persists a voice note, stamped as changed now so it reaches other devices.
  Future<void> _putVoice(VoiceNote v) async {
    if (v.ownerId.isEmpty) v.ownerId = _scopeId;
    final m = v.toMap();
    stamp(m);
    await _voices.put(v.id, m);
    await _markPending('voices', v.id);
  }

  // ---------------- Server-authoritative sync ----------------
  //
  // The server document is the source of truth. Local Hive only holds
  // (a) a cache of the server state and (b) a small outbox of changes that
  // could not be uploaded yet. Nothing is considered "saved" until the server
  // acknowledged it.

  static const _pendingKey = '__sync_pending__';

  /// Box keys (`entity/boxKey`) waiting to be uploaded.
  Set<String> get pendingKeys {
    final raw = _users.get(_pendingKey);
    if (raw is List) return raw.map((e) => '$e').toSet();
    return <String>{};
  }

  int get pendingCount => pendingKeys.length;

  /// Queued uploads that are actually *user data*.
  ///
  /// `accounts/<id>` is deliberately excluded. That record describes the login
  /// itself: it is rewritten by every sign-in (`publishAccount`), so counting it
  /// would make every session look like it held unsent edits. With a non-zero
  /// count, [adoptServerSnapshot] refuses to pull — and the pull would then never
  /// happen, which is precisely the bug where a second device kept its own empty
  /// workspace instead of loading the account's.
  ///
  /// A stale account row is harmless: the push that follows the pull carries it,
  /// and the merge is last-writer-wins on `updatedAt`.
  int get pendingDataCount =>
      pendingKeys.where((k) => !k.startsWith('accounts/')).length;

  Future<void> _markPending(String entity, String boxKey) async {
    if (!syncEnabled) return;
    final set = pendingKeys..add('$entity/$boxKey');
    await _users.put(_pendingKey, set.toList());
  }

  Future<void> clearPending(Iterable<String> keys) async {
    final set = pendingKeys..removeAll(keys);
    await _users.put(_pendingKey, set.toList());
  }

  Future<void> clearAllPending() async => _users.put(_pendingKey, <String>[]);

  /// Snapshot of ONLY the records that still need uploading.
  ///
  /// Deliberately does not filter on `ownerId`: the record was explicitly
  /// queued by a write on this device, and dropping it because the field is
  /// missing would leave it stuck in the outbox forever.
  Map<String, Map<String, dynamic>> pendingSnapshot(String ownerId) {
    final out = <String, Map<String, dynamic>>{};
    final pending = pendingKeys;
    if (pending.isEmpty) return out;
    for (final full in pending) {
      final slash = full.indexOf('/');
      if (slash <= 0) continue;
      final entity = full.substring(0, slash);
      final box = _syncBoxes[entity];
      if (box == null) continue;
      final raw = box.get(full.substring(slash + 1));
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      m.remove('_rev');
      m.remove('_updatedAt');
      if (entity == 'accounts') {
        // Replace the local plaintext with a hash — the server copy is what a
        // new device verifies against, so it needs pwHash and must not leak.
        out[full] = _accountRowForSync(full.substring(slash + 1), m);
        continue;
      }
      // Guarantee the server record is attributable to this workspace. Account
      // rows deliberately have no owner — the workspace itself is the owner.
      if (_isOwned(entity) && (m['ownerId'] ?? '') == '') {
        m['ownerId'] = ownerId;
      }
      out[full] = m;
    }
    return out;
  }

  /// The raw local record for a queued `entity/boxKey`, or null.
  Map<String, dynamic>? pendingRecord(String fullKey) {
    final slash = fullKey.indexOf('/');
    if (slash <= 0) return null;
    final box = _syncBoxes[fullKey.substring(0, slash)];
    final raw = box?.get(fullKey.substring(slash + 1));
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  /// Applies a whole server snapshot in one pass.
  /// Returns true when anything local changed.
  bool applyServerSnapshot(Map serverEntities) {
    var changed = false;
    for (final e in serverEntities.entries) {
      final key = '${e.key}';
      final slash = key.indexOf('/');
      if (slash <= 0) continue;
      final entity = key.substring(0, slash);
      final boxKey = key.substring(slash + 1);
      // Reserved `__…__` keys are per-device metadata (sync config, cached rev,
      // app version). Never accept those from the server.
      if (boxKey.startsWith('__') && boxKey.endsWith('__')) continue;
      final raw = e.value;
      if (raw is! Map) continue;
      final box = _syncBoxes[entity];
      if (box == null) continue;

      final remote = Map<String, dynamic>.from(raw);
      final pending = pendingKeys.contains(key);
      final local = box.get(boxKey);

      // Account rows need special handling: the server copy has no plaintext
      // password on purpose, so it must be merged rather than written over.
      if (entity == 'accounts') {
        _sanitizeIncomingAccount(remote);
        final merged = _mergeIncomingAccount(boxKey, remote, local);
        if (local is Map) {
          final a = Map<String, dynamic>.from(local)
            ..remove('_rev')
            ..remove('_updatedAt');
          if (!pending && _shallowEquals(a, merged)) continue;
        }
        box.put(boxKey, merged);
        changed = true;
        continue;
      }

      if (local is Map && !pending) {
        final a = Map<String, dynamic>.from(local);
        a.remove('_rev');
        a.remove('_updatedAt');
        if (_shallowEquals(a, remote)) continue;
      }
      box.put(boxKey, remote);
      // Preferences arrive as `pref/<name>` records, but the getters read the
      // `users` box. Mirror them here so a design chosen on the phone is live on
      // the laptop the moment the snapshot lands.
      if (entity == 'prefs') _mirrorPref(boxKey, remote);
      changed = true;
    }
    return changed;
  }

  /// Removes a plaintext password from an account record arriving from the
  /// server.
  ///
  /// `accounts/<id>` rows travel as ordinary sync entities. Before this existed,
  /// an already-leaked workspace could drop someone's plaintext password into
  /// the local credential store; uploads are now hash-only, and this is the
  /// matching guard on the way in.
  static void _sanitizeIncomingAccount(Map<String, dynamic> remote) {
    remote.remove('password');
  }

  /// Builds the account row that travels to the server.
  ///
  /// The workspace copy is what a brand-new device reads to sign in
  /// ([_adoptAccountFromServer]), so it needs something to verify against — but
  /// it must never be the plaintext. `password` is dropped here and replaced by
  /// `pwHash`, derived from the local credential at upload time.
  ///
  /// Why this exists: `accounts/<id>` used to be serialised straight from
  /// `User.toMap()`, which carries `password` and no hash. The registry
  /// (`ACCREGISTRY…`) always stored only `pwHash`, so the two copies disagreed:
  /// the workspace leaked plaintext while being useless for hash verification.
  static Map<String, dynamic> _accountRowForSync(
    String boxKey,
    Map<String, dynamic> local,
  ) {
    final out = Map<String, dynamic>.from(local);
    final pw = out.remove('password');
    if (pw is String && pw.isNotEmpty && !_looksLikePlaceholder(pw)) {
      out['pwHash'] = hashPassword('${out['id'] ?? boxKey}', pw);
    }
    // No local secret (row adopted from the registry, or a never-used master
    // slot): leave `pwHash` exactly as it was. Fabricating one would overwrite a
    // good credential on every other device via last-writer-wins.
    return out;
  }

  /// True for [_randomPlaceholder] passwords — 64 hex chars, two uuids joined.
  ///
  /// Such a value is not a credential and must never be hashed into the
  /// workspace: doing so would publish a password nobody knows and lock the
  /// account out once the registry's real hash loses last-writer-wins.
  static bool _looksLikePlaceholder(String pw) =>
      pw.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(pw);

  /// Merges a server account row into the local one without dropping the
  /// credential this device signs in with.
  ///
  /// The server copy carries settings and `pwHash`, never `password` (see
  /// [_accountRowForSync]). Writing it wholesale would blank the local password
  /// and break offline sign-in — the account would look fine until the server
  /// could not be reached, then refuse every login. Local keeps the plaintext;
  /// remote wins for everything else.
  static Map<String, dynamic> _mergeIncomingAccount(
    String boxKey,
    Map<String, dynamic> remote,
    Object? local,
  ) {
    final merged = Map<String, dynamic>.from(remote);
    final localPw = local is Map ? local['password'] : null;
    if (localPw is String && localPw.isNotEmpty) {
      merged['password'] = localPw;
    }
    // A stale server row must not erase a hash this device already trusts.
    final localHash = local is Map ? local['pwHash'] : null;
    final remoteHash = remote['pwHash'];
    if ((remoteHash is! String || remoteHash.isEmpty) &&
        localHash is String &&
        localHash.isNotEmpty) {
      merged['pwHash'] = localHash;
    }
    merged['id'] ??= boxKey;
    return merged;
  }

  /// Reserved `users`-box key for a synced preference, or null when the pref is
  /// not one of the mirrored ones.
  static const _mirroredPrefs = <String, String>{
    'design': '__design__',
    'skin': '__skin__',
    'lang': '__lang__',
    'theme_mode': '__theme_mode__',
    'font': '__font__',
    'font_scale': '__font_scale__',
    'handwriting': '__handwriting__',
  };

  void _mirrorPref(String name, Map<String, dynamic> record) {
    final key = _mirroredPrefs[name];
    if (key == null) return;
    final v = record['value'];
    if (v == null) return;
    if (_users.get(key) == v) return;
    _users.put(key, v);
  }

  /// Replaces local state with what the server holds (server authoritative).
  ///
  /// ## Why this exists
  /// Signing in used to be "seed defaults, then push." On a second device that is
  /// backwards: the fresh device has nothing meaningful in it, yet its seeded
  /// defaults were queued and uploaded — so the workspace the user had been
  /// building on their phone could be overwritten by an empty one from the
  /// laptop. The whole point of signing in with the same id is that the server's
  /// data comes down *first*.
  ///
  /// ## Rules that keep it safe
  /// * **Queued edits are never discarded.** If the outbox is non-empty this
  ///   device has work that never reached the server (offline edits, a previous
  ///   failure). Pushing those first is correct, so this returns null and the
  ///   caller falls through to the normal merge path.
  /// * **A genuinely new workspace is left alone.** When the server has no
  ///   records at all there is nothing to adopt, so local defaults are kept and
  ///   uploaded normally.
  /// * **A reset is applied as a reset.** The generation tells a deliberate wipe
  ///   apart from a new account; a wipe drops the local cache instead of
  ///   re-uploading it.
  /// * **Credentials and per-device metadata survive.** Anything owned by another
  ///   account, plus reserved `__…__` keys, is left untouched.
  ///
  /// Returns a short status on success (`adopted` / `reset` / `empty`), or null
  /// when the caller should continue with the normal push path.
  Future<String?> adoptServerSnapshot(CloudDoc doc) async {
    final owner = currentUserId;

    // No document, and this device never mirrored one: this account has not
    // been created on the server yet. Seed the default tabs *and* queue
    // everything — including those quietly seeded tabs — so the account is
    // usable from the next device that signs in.
    //
    // Queuing is not optional here. A tab that is only in the local box is
    // neither on the server nor pending, so the very next snapshot prunes it as
    // "the server no longer has this" and a new account ends up with zero tabs.
    // Returning null lets the caller continue with its push.
    if (!doc.exists && doc.gen <= cachedGen) {
      // A device that already holds unsent work is not a fresh account; that is
      // business data and it only needs its own push. But an account with no
      // queued *data* still needs its baseline made durable.
      if (pendingDataCount == 0) await ensureWorkspaceBaseline(owner);
      await setCachedRev(doc.rev, doc.gen);
      return null;
    }

    final resetElsewhere = !doc.exists && doc.gen > cachedGen;

    // Local work that never reached the server outranks a download.
    if (!resetElsewhere && pendingDataCount > 0) return null;

    beginRemoteApply();
    try {
      // Drop what the server no longer has. Accounts and reserved keys are
      // protected inside dropWorkspaceCache.
      await dropWorkspaceCache(owner);
      await clearAllPending();

      if (doc.exists) {
        applyServerSnapshot(doc.entities);
      } else {
        // Wiped from another device: re-create only the default tabs, and do not
        // queue them — the empty server is the intended state, not a gap to fill.
        await _ensureUserSeed(owner);
      }

      await setCachedRev(doc.rev, doc.gen);
    } finally {
      endRemoteApply(true);
    }

    // Deliberately no addLog() here: a log entry is itself a synced record, and
    // queuing one during a pull would leave the outbox non-empty right after it
    // was cleared — which is the exact state that makes the next start() push
    // instead of pull.
    return doc.exists ? 'adopted' : 'reset';
  }

  /// Makes this account's baseline real: default tabs seeded, everything queued.
  ///
  /// Used when the server has no document for the workspace, which means the
  /// account is being created. Both halves matter:
  ///
  /// * **Seeding** gives a brand-new account usable tabs instead of a blank
  ///   screen.
  /// * **Queuing** is what makes those tabs survive. A tab that exists only in
  ///   the local box is neither on the server nor in the outbox, and the first
  ///   server snapshot then treats it as "the server no longer has this" and
  ///   prunes it. That is exactly how a new account used to lose its 14 default
  ///   tabs the moment sync connected.
  ///
  /// Safe to call repeatedly — seeding checks for existing rows and
  /// [queueAllForUpload] merges rather than replaces.
  Future<void> ensureWorkspaceBaseline(String ownerId) async {
    if (ownerId.isEmpty) return;
    await _ensureUserSeed(ownerId);
    await queueAllForUpload(ownerId);
  }

  /// Marks every record of [ownerId] as needing an upload (workspace creation).
  ///
  /// **Merges** with the current outbox instead of replacing it: a record already
  /// queued may have been deleted locally since, and rebuilding the list from the
  /// boxes alone would silently drop whatever stayed queued.
  Future<void> queueAllForUpload(String ownerId) async {
    final keys = pendingKeys;
    for (final e in _syncBoxes.entries) {
      for (final k in e.value.keys) {
        // Reserved metadata (sync config, cached rev, app version) is per
        // device and must never be uploaded — it would overwrite the phone's
        // own settings with the laptop's.
        if (k is String && _isReservedKey(k)) continue;
        final raw = e.value.get(k);
        if (raw is! Map) continue;
        if (_isOwned(e.key) && (raw['ownerId'] ?? '') != ownerId) continue;
        keys.add('${e.key}/$k');
      }
    }
    await _users.put(_pendingKey, keys.toList());
  }

  /// Applies one record straight from the server (server wins).
  /// A `null` [remote] means the server no longer has it -> drop locally.
  Future<bool> applyServerRecord(
    String entity,
    String boxKey,
    Map<String, dynamic>? remote,
  ) async {
    final box = _syncBoxes[entity];
    if (box == null) return false;
    final pending = pendingKeys.contains('$entity/$boxKey');
    final local = box.get(boxKey);

    if (remote == null) {
      // Server deleted it. Keep a local edit that has not been uploaded yet.
      if (pending) return false;
      if (local == null) return false;
      await box.delete(boxKey);
      return true;
    }

    if (local is Map && !pending) {
      final a = Map<String, dynamic>.from(local);
      a.remove('_rev');
      a.remove('_updatedAt');
      if (_shallowEquals(a, remote)) return false;
    }
    await box.put(boxKey, remote);
    return true;
  }

  /// Drops local records of [ownerId] that the server no longer has.
  /// Pending (unsent) edits are always kept.
  Future<bool> pruneMissing(String ownerId, Set<String> serverKeys) async {
    final pending = pendingKeys;
    var changed = false;
    for (final e in _syncBoxes.entries) {
      for (final k in e.value.keys.toList()) {
        // Reserved `__…__` keys are app metadata, never server records.
        if (k is String && _isReservedKey(k)) continue;
        final raw = e.value.get(k);
        if (raw is! Map) continue;
        // Only records belonging to the signed-in account. Categories/logs are
        // keyed `owner::id`, so the owner field is what separates accounts.
        // Account rows are owner-less: the workspace *is* the owner.
        if (_isOwned(e.key) && (raw['ownerId'] ?? '') != ownerId) continue;
        final full = '${e.key}/$k';
        if (serverKeys.contains(full)) continue;
        // A record that is queued but not yet on the server is *new*, not
        // deleted. Sending it is the right move; dropping it loses data.
        if (pending.contains(full)) continue;
        await e.value.delete(k);
        changed = true;
      }
    }
    return changed;
  }

  /// Applies a record coming from the sync server (last-writer-wins).
  ///
  /// Returns true when the local copy changed. A missing/deleted record is
  /// kept as a tombstone (not erased) so the deletion keeps propagating.
  Future<bool> applyRemoteEntity(
    String entity,
    String boxKey,
    Map<String, dynamic> remote,
  ) async {
    final box = _syncBoxes[entity];
    if (box == null) return false;
    final local = box.get(boxKey);
    final remoteStamp = (remote['updatedAt'] as num?)?.toInt() ?? 0;
    final localStamp = local is Map
        ? ((local['updatedAt'] as num?)?.toInt() ?? 0)
        : -1;
    // Local wins when it is strictly newer (offline edits are preserved).
    if (localStamp > remoteStamp) return false;

    final incoming = <String, dynamic>{};
    for (final e in remote.entries) {
      if (e.key == '_rev' || e.key == '_updatedAt') continue;
      incoming[e.key.toString()] = e.value;
    }
    incoming['updatedAt'] = remoteStamp;
    incoming['deletedAt'] = (incoming['deletedAt'] as num?)?.toInt();
    final id = incoming['id']?.toString() ?? '';
    if (id.isEmpty) return false;

    final same =
        local is Map &&
        _shallowEquals(Map<String, dynamic>.from(local), incoming);
    if (same) return false;

    await box.put(boxKey, incoming);
    return true;
  }

  static bool _shallowEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      final va = a[k];
      final vb = b[k];
      if (va is List && vb is List) {
        if (va.length != vb.length) return false;
        for (var i = 0; i < va.length; i++) {
          if ('${va[i]}' != '${vb[i]}') return false;
        }
        continue;
      }
      if ('$va' != '$vb') return false;
    }
    return true;
  }

  /// Drops every locally cached record of [ownerId].
  ///
  /// Used when the workspace was reset (here or on another device). The outbox
  /// is cleared by the caller, because "delete everything" must not leave
  /// tombstones queued that would resurrect nothing and block the sync.
  Future<void> dropWorkspaceCache(String ownerId) async {
    for (final e in _syncBoxes.entries) {
      for (final k in e.value.keys.toList()) {
        // Never wipe credentials or app metadata: a reset clears the user's
        // content, not the ability to sign in afterwards.
        if (k is String && _isReservedKey(k)) continue;
        if (e.key == 'accounts') continue;
        final raw = e.value.get(k);
        if (raw is! Map) continue;
        if (_isOwned(e.key) &&
            ownerId.isNotEmpty &&
            (raw['ownerId'] ?? '') != ownerId) {
          continue;
        }
        await e.value.delete(k);
      }
    }
  }

  /// Revision + generation of the workspace this device mirrors.
  ///
  /// Persisted so a reload can ask the server "anything new since rev N?" and
  /// get a ~40-byte "unchanged" instead of the whole document.
  int get cachedRev => (_users.get('__sync_rev__') as num?)?.toInt() ?? 0;

  int get cachedGen => (_users.get('__sync_gen__') as num?)?.toInt() ?? 0;

  Future<void> setCachedRev(int rev, int gen) async {
    if (_users.get('__sync_rev__') != rev) {
      await _users.put('__sync_rev__', rev);
    }
    if (_users.get('__sync_gen__') != gen) {
      await _users.put('__sync_gen__', gen);
    }
  }

  /// Re-reads all boxes from disk after a sync pull changed them.
  void onRemoteApplied() => notifyListeners();

  // ---------------- Sync metadata (per device) ----------------
  String get syncCode => (_users.get('__sync_code__') as String?) ?? '';

  bool get syncEnabled =>
      ((_users.get('__sync_on__') as bool?) ?? false) && syncCode.isNotEmpty;

  String get syncUrl => (_users.get('__sync_url__') as String?) ?? '';

  /// Which user owns the shared workspace; remembered so login always targets
  /// the same cloud document.
  String get syncOwnerId => (_users.get('__sync_owner__') as String?) ?? '';

  Future<void> setSyncConfig({
    String? code,
    String? url,
    bool? enabled,
    String? ownerId,
  }) async {
    if (code != null) await _users.put('__sync_code__', code);
    if (url != null) await _users.put('__sync_url__', url);
    if (enabled != null) await _users.put('__sync_on__', enabled);
    if (ownerId != null) await _users.put('__sync_owner__', ownerId);
    notifyListeners();
  }

  int get syncMaxUpdatedAtCache =>
      (_users.get('__sync_stamp__') as num?)?.toInt() ?? 0;

  Future<void> setSyncStamp(int ms) async {
    await _users.put('__sync_stamp__', ms);
  }

  /// Seed the recurring bills (rent & warehouse) for the current user.
  Future<void> seedRecurringBillsIfEmpty() async {
    final ownerId = _scopeId;
    final mine = tasksForOwner(ownerId);
    final ko = language == 'ko';
    if (mine.any((t) => t.recurrence == 'monthly' && t.recurrenceDay == 12)) {
      return;
    }
    final rent = Task(
      id: _uuid.v4(),
      ownerId: ownerId,
      title: ko ? '월세 — ₩2,500,000' : 'Rent — ₩2,500,000',
      categoryId: 'repeat',
      note: ko ? '매월 12일 납부' : 'Monthly rent, due on the 12th',
      recurrence: 'monthly',
      recurrenceDay: 12,
      amount: 2500000,
    );
    final warehouse = Task(
      id: _uuid.v4(),
      ownerId: ownerId,
      title: ko ? '창고비 — ₩30,000' : 'Warehouse fee — ₩30,000',
      categoryId: 'repeat',
      note: ko ? '매월 창고비' : 'Monthly warehouse fee',
      recurrence: 'monthly',
      recurrenceDay: 12,
      amount: 30000,
    );
    await _putTask(rent);
    await _putTask(warehouse);
    notifyListeners();
  }

  /// Seed daily routine tasks (medicine, laundry, cleaning, make bed).
  Future<void> seedDailyRoutinesIfEmpty() async {
    final ownerId = _scopeId;
    final mine = tasksForOwner(ownerId);
    if (mine.any((t) => t.categoryId == 'daily')) return;
    final ko = language == 'ko';
    final items = ko
        ? ['약 먹기', '빨래', '청소', '이불 개기']
        : ['Take medicine', 'Laundry', 'Cleaning', 'Make the bed'];
    for (final item in items) {
      final t = Task(
        id: _uuid.v4(),
        ownerId: ownerId,
        title: item,
        categoryId: 'daily',
        recurrence: 'daily',
      );
      await _putTask(t);
    }
    notifyListeners();
  }

  // ---------------- Logs ----------------
  List<LogEntry> get logs {
    final list = _logs.values
        .where((e) => e['ownerId'] == _scopeId)
        .map((e) => LogEntry.fromMap(e))
        .toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  List<LogEntry> allLogs() {
    final list = _logs.values.map((e) => LogEntry.fromMap(e)).toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  void addLog(String action, [String detail = '']) {
    if (_currentUserId.isEmpty) return;
    final entry = LogEntry(
      id: _uuid.v4(),
      timestamp: DateTime.now(),
      action: action,
      detail: detail,
      ownerId: _scopeId,
    );
    _logs.put(_logKey(_scopeId, entry.id), entry.toMap());
  }

  Future<void> clearLogs() async {
    for (final k in _logs.keys.toList()) {
      final m = _logs.get(k);
      if (m != null && m['ownerId'] == _scopeId) await _logs.delete(k);
    }
    notifyListeners();
  }

  // ---------------- Voice notes ----------------
  List<VoiceNote> get voiceNotes {
    final list = _voices.values
        .where((e) => e['ownerId'] == _scopeId && e['deletedAt'] == null)
        .map((e) => VoiceNote.fromMap(e))
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> saveVoiceNote(VoiceNote v) async {
    await _putVoice(v);
    notifyListeners();
  }

  Future<void> deleteVoiceNote(String id) async {
    await _voices.delete(id);
    notifyListeners();
  }

  // ---------------- Per-user settings ----------------

  /// Identifier of the running build: `--dart-define=BUILD_ID=…`.
  ///
  /// The deploy script passes the build time, so every deploy ships a different
  /// value and a browser can be asked "which build are you actually running?".
  /// Without it the string is empty and only the stored date is available,
  /// which says when this *device first ran the app*, never which build it is.
  static const _envBuildId = String.fromEnvironment('BUILD_ID');

  /// The build currently executing. Empty when the build predates BUILD_ID.
  String get buildId => _envBuildId;

  /// Version shown in the UI.
  ///
  /// This used to return `__app_version__` from the `users` box, which was
  /// seeded once with `DateTime.now()` of the *first launch on that device* and
  /// never refreshed. The result was a number that looked like a build stamp
  /// but was really a device-provisioning date: a freshly deployed app on an
  /// old device reported last month's date, which makes "did the deploy land?"
  /// impossible to answer. Settings → 백업 → 캐시 삭제 could not fix it either,
  /// because the stored value lived in Hive, not in the shared_preferences
  /// cache that button clears.
  ///
  /// Truth now comes from the build itself. The stored value remains the
  /// fallback for builds that predate BUILD_ID, so old clients keep working.
  /// The version string shown on the login screen.
  ///
  /// **A getter must not touch storage.** This used to `put()` the generated
  /// value into Hive the first time it ran, which happens during `build()` — so
  /// a widget rebuild quietly turned into a disk write, every launch, on a
  /// frame. In the app that is merely wasteful; inside a widget test the write
  /// is a real async I/O that the fake clock never lets finish, and the test
  /// dies with a confusing compiler error. (It cost an hour to find. Hence this
  /// comment.)
  ///
  /// So: reads are read-only, and [rememberAppVersion] does the one-time write
  /// from a place that is allowed to await.
  String get appVersion {
    if (_envBuildId.isNotEmpty) return _envBuildId;
    final stored = _users.get('__app_version__') as String?;
    if (stored != null) return stored;
    return _generatedVersion;
  }

  /// The value [appVersion] would generate, without storing it.
  String get _generatedVersion {
    final now = DateTime.now();
    return '${now.year}.${now.month.toString().padLeft(2, '0')}'
        '.${now.day.toString().padLeft(2, '0')}.'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
  }

  /// Persists the generated version once, outside of any build pass.
  ///
  /// Called from [init]. Safe to call again: an existing value is left alone.
  Future<void> rememberAppVersion() async {
    if (_envBuildId.isNotEmpty) return;
    if (_users.get('__app_version__') is String) return;
    try {
      await _users.put('__app_version__', _generatedVersion);
    } catch (_) {}
  }

  Future<void> setAppVersion(String v) async {
    await _users.put('__app_version__', v);
    notifyListeners();
  }

  // ---------------- Look & language (synced across devices) -------------
  //
  // These live in their own `prefs` box keyed `pref/<name>` so they travel with
  // the workspace: pick a design on the phone, and the laptop shows the same one
  // on next open. Keeping them out of the `users` box matters — that box is the
  // credential store, and this one is deliberately part of the synced document.

  void _putPref(String name, Object? value) {
    _prefs.put(name, {
      'id': name,
      'ownerId': _scopeId,
      'value': value,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    unawaited(_markPending('prefs', name));
  }

  T _getPref<T>(String name, T fallback) {
    final raw = _prefs.get(name);
    if (raw is! Map) return fallback;
    final v = raw['value'];
    return v is T ? v : fallback;
  }

  /// UI language: 'ko' (default) or 'en'.
  String get language => (_users.get('__lang__') as String?) ?? 'ko';

  Future<void> setLanguage(String lang) async {
    await _users.put('__lang__', lang);
    _putPref('lang', lang);
    notifyListeners();
  }

  /// Screen theme mode: 'system' (follow phone, default), 'light' or 'dark'.
  String get themeModeKey =>
      (_users.get('__theme_mode__') as String?) ?? 'system';

  Future<void> setThemeModeKey(String mode) async {
    await _users.put('__theme_mode__', mode);
    _putPref('theme_mode', mode);
    notifyListeners();
  }

  /// Active design language (see [AppDesigns]). Defaults to 'paper'.
  ///
  /// A design language is not a recolour: it changes the geometry, the
  /// decoration, the typography and the rhythm of every screen. The colour skin
  /// selects a palette *inside* that design.
  String get designKey => _getPref<String>(
    'design',
    (_users.get('__design__') as String?) ?? 'paper',
  );

  Future<void> setDesignKey(String id) async {
    await _users.put('__design__', id);
    _putPref('design', id);
    notifyListeners();
  }

  /// Active colour skin id (see [AppSkins.ids]). Defaults to 'midnight'.
  String get skinKey => _getPref<String>(
    'skin',
    (_users.get('__skin__') as String?) ?? 'midnight',
  );

  Future<void> setSkinKey(String id) async {
    await _users.put('__skin__', id);
    _putPref('skin', id);
    notifyListeners();
  }

  /// Hand-writing (pen) look for non-notebook designs. The paper design always
  /// uses it; here the user can also force it on/off elsewhere.
  bool get handwritingKey => _getPref<bool>(
    'handwriting',
    (_users.get('__handwriting__') as bool?) ?? true,
  );

  Future<void> setHandwritingKey(bool on) async {
    await _users.put('__handwriting__', on);
    _putPref('handwriting', on);
    notifyListeners();
  }

  /// Font family choice (see [AppFonts.ids]): 'system' (Windows / platform
  /// default, the app default), 'pen' (NanumPenScript), 'gaegu' (Gaegu),
  /// 'gothic' (NanumGothic), 'myeongjo', 'dodum', 'jua', 'dohyeon', 'black'.
  String get fontKey =>
      _getPref<String>('font', (_users.get('__font__') as String?) ?? 'system');

  Future<void> setFontKey(String k) async {
    await _users.put('__font__', k);
    _putPref('font', k);
    notifyListeners();
  }

  /// Global text-size multiplier (0.85 – 1.6; 1.0 = normal).
  double get fontScale => _getPref<double>(
    'font_scale',
    ((_users.get('__font_scale__') as num?)?.toDouble() ?? 1.0),
  ).clamp(0.85, 1.6);

  Future<void> setFontScale(double v) async {
    final clamped = v.clamp(0.85, 1.6);
    await _users.put('__font_scale__', clamped);
    _putPref('font_scale', clamped);
    notifyListeners();
  }

  /// Google Calendar integration mode:
  ///   'off'    — feature hidden, nothing happens on save (default).
  ///   'manual' — "Add to Calendar" appears in the task menu only.
  ///   'auto'   — every newly saved task is also pushed to Google Calendar.
  String get calendarMode => (_users.get('__cal_mode__') as String?) ?? 'off';

  bool get calendarEnabled => calendarMode != 'off';

  Future<void> setCalendarMode(String mode) async {
    await _users.put('__cal_mode__', mode);
    notifyListeners();
  }

  /// Google Drive folder used for uploading / backing up all data.
  /// Editable from Settings. Defaults to the user's shared folder.
  static const defaultDriveUrl =
      'https://drive.google.com/drive/folders/1sksOKepRPLxIFcMMT1nB7CZE2AS2NAmL?usp=sharing';

  String get driveUrl =>
      (_users.get('__drive_url__') as String?) ?? defaultDriveUrl;

  Future<void> setDriveUrl(String url) async {
    final v = url.trim();
    await _users.put('__drive_url__', v.isEmpty ? defaultDriveUrl : v);
    notifyListeners();
  }

  // Per-user convenience accessors for the current user.
  String get username => _currentUserId;
  String get password => currentUser?.password ?? '';

  /// Change the current user's own password.
  Future<void> setPassword(String pw) async {
    await updatePassword(_currentUserId, pw);
  }

  Future<void> updatePassword(String id, String pw) async {
    final u = userById(id);
    if (u == null) return;
    u.password = pw;
    await _users.put(id, u.toMap());
    // A password change must reach every device, or the next sign-in on the
    // phone would use the old one and be refused. This is one of the two places
    // allowed to write the registry hash.
    await publishAccount(id, withPassword: true);
    addLog('Change password');
    notifyListeners();
  }

  String get forwardUrl => currentUser?.forwardUrl ?? 'https://aqdesign.co.kr';
  Future<void> setForwardUrl(String url) async =>
      updateUserPrefs(_currentUserId, forwardUrl: url);

  String get appThemeMode => currentUser?.appThemeMode ?? 'mix';
  Future<void> setAppThemeMode(String mode) async =>
      updateUserPrefs(_currentUserId, appThemeMode: mode);

  String get printDesignMode => currentUser?.printDesignMode ?? 'minimal';
  Future<void> setPrintDesignMode(String mode) async =>
      updateUserPrefs(_currentUserId, printDesignMode: mode);

  double get baseFontSize => currentUser?.baseFontSize ?? 13.0;
  Future<void> setBaseFontSize(double v) async =>
      updateUserPrefs(_currentUserId, baseFontSize: v);

  // ---------------- Backup / Restore ----------------
  Map<String, dynamic> exportBackup() => {
    'version': appVersion,
    'exportedAt': DateTime.now().toIso8601String(),
    'users': allUsers.map((e) => e.toMap()).toList(),
    'tasks': _tasks.values.map((e) => Map<String, dynamic>.from(e)).toList(),
    'categories': _cats.values
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
    'logs': _logs.values.map((e) => Map<String, dynamic>.from(e)).toList(),
    'voices': _voices.values.map((e) => Map<String, dynamic>.from(e)).toList(),
  };

  Future<void> importBackup(Map<String, dynamic> data) async {
    await _tasks.clear();
    await _cats.clear();
    await _logs.clear();
    await _voices.clear();
    for (final e in (data['tasks'] as List? ?? [])) {
      await _tasks.put(e['id'], Map<String, dynamic>.from(e));
    }
    for (final e in (data['categories'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(e);
      await _cats.put(_catKey(m['ownerId'] ?? '', m['id']), m);
    }
    for (final e in (data['logs'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(e);
      await _logs.put(_logKey(m['ownerId'] ?? '', m['id']), m);
    }
    for (final e in (data['voices'] as List? ?? [])) {
      await _voices.put(e['id'], Map<String, dynamic>.from(e));
    }
    if (data['users'] is List) {
      for (final e in (data['users'] as List)) {
        final m = Map<String, dynamic>.from(e);
        await _users.put(m['id'], m);
      }
    }
    await _ensureMaster();
    addLog('Restore backup');
    notifyListeners();
  }

  Future<void> clearCache() async {
    // Clear non-essential cached data but keep user content & settings.
    await clearLogs();
    if (_envBuildId.isNotEmpty) {
      // The button claims to clear the cache, so it must also clear the stale
      // provision date that used to masquerade as a build stamp. Otherwise it
      // "does nothing" from the user's point of view.
      await _users.delete('__app_version__');
    }
    notifyListeners();
  }

  Future<void> wipeAll() async {
    // Remove the current user's data only.
    for (final k in _tasks.keys.toList()) {
      final m = _tasks.get(k);
      if (m != null && m['ownerId'] == _scopeId) await _tasks.delete(k);
    }
    for (final k in _cats.keys.toList()) {
      final m = _cats.get(k);
      if (m != null && m['ownerId'] == _scopeId) await _cats.delete(k);
    }
    for (final k in _logs.keys.toList()) {
      final m = _logs.get(k);
      if (m != null && m['ownerId'] == _scopeId) await _logs.delete(k);
    }
    await _seedCategories(_scopeId);
    notifyListeners();
  }
}

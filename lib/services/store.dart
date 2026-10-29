import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'sync_service.dart';

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

  static const masterId = 'june7486';
  static const masterPw = 'Corbuser7!@@';

  // A ready-to-use demo account (id/pw = test/test).
  static const testId = 'test';
  static const testPw = 'test';

  late Box _users;
  late Box _tasks;
  late Box _cats;
  late Box _logs;
  late Box _voices;

  final _uuid = const Uuid();

  bool _ready = false;
  bool get isReady => _ready;

  /// Cross-device sync engine (created on first use).
  SyncService? _sync;
  SyncService get sync => _sync ??= SyncService(this);

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
    if (_ready && _remoteDepth == 0) sync.markDirty();
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

    await _ensureMaster();
    await _ensureTestUser();
    _ready = true;
    notifyListeners();
  }

  Future<void> _ensureMaster() async {
    if (!_users.containsKey(masterId)) {
      final master = User(
        id: masterId,
        password: masterPw,
        displayName: 'Master',
        isMaster: true,
      );
      await _users.put(masterId, master.toMap());
    }
  }

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
        {
          'cat': 'bank',
          'title': ko ? '은행 업무 확인' : 'Check bank work',
        },
        {
          'cat': 'scout',
          'title': ko ? '스카우트 대장 미팅' : 'Scout leader meeting',
        },
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
  Future<bool> authenticate(String id, String pw) async {
    final u = userById(id);
    if (u == null) return false;
    if (!u.enabled) return false;
    if (u.password != pw) return false;
    _currentUserId = u.id;
    await _ensureUserSeed(u.id);
    addLog('Login', u.id);
    notifyListeners();
    // Every account is its own cloud workspace: signing in is all it takes.
    // No setup, no code to copy -- the server copy is pulled immediately.
    await enableAutoSyncForUser();
    unawaited(sync.start());
    return true;
  }

  /// Turns cloud storage on for the signed-in account.
  ///
  /// The account id *is* the workspace key, so nothing has to be configured.
  Future<void> enableAutoSyncForUser() async {
    final uid = _currentUserId;
    if (uid.isEmpty) return;
    final code = syncCode;
    if (code.isEmpty || syncOwnerId != uid) {
      // First run on this device (or the account changed): derive the key.
      await setSyncConfig(
        code: workspaceCodeFor(uid),
        enabled: true,
        ownerId: uid,
      );
    } else if (_users.get('__sync_on__') != true) {
      await setSyncConfig(enabled: true);
    }
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
    final u = User(id: trimmed, password: pw, displayName: displayName);
    await _users.put(trimmed, u.toMap());
    await _seedCategories(trimmed);
    addLog('Create user', trimmed);
    notifyListeners();
    return null;
  }

  Future<void> deleteUser(String id) async {
    if (id == masterId) return; // never delete the master
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

  Future<void> _ensureUserSeed(String ownerId) async {
    final hasCats = _cats.values.any((e) => e['ownerId'] == ownerId);
    if (!hasCats) await _seedCategories(ownerId);
  }

  Future<void> _seedCategories(String ownerId) async {
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
          (t) =>
              t.ownerId == oid && t.isInCategory(categoryId) && t.completed,
        )
        .toList();
  }

  int taskCountFor(String categoryId, {String? ownerId}) {
    final oid = ownerId ?? _scopeId;
    return tasks
        .where(
          (t) =>
              t.ownerId == oid && t.isInCategory(categoryId) && !t.completed,
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
  };

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
      final box = _syncBoxes[full.substring(0, slash)];
      if (box == null) continue;
      final raw = box.get(full.substring(slash + 1));
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      m.remove('_rev');
      m.remove('_updatedAt');
      // Guarantee the server record is attributable to this workspace.
      if ((m['ownerId'] ?? '') == '') m['ownerId'] = ownerId;
      out[full] = m;
    }
    return out;
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
      final raw = e.value;
      if (raw is! Map) continue;
      final box = _syncBoxes[entity];
      if (box == null) continue;

      final remote = Map<String, dynamic>.from(raw);
      final pending = pendingKeys.contains(key);
      final local = box.get(boxKey);

      if (local is Map && !pending) {
        final a = Map<String, dynamic>.from(local);
        a.remove('_rev');
        a.remove('_updatedAt');
        if (_shallowEquals(a, remote)) continue;
      }
      box.put(boxKey, remote);
      changed = true;
    }
    return changed;
  }

  /// Marks every record of [ownerId] as needing an upload (workspace creation).
  Future<void> queueAllForUpload(String ownerId) async {
    final keys = <String>[];
    for (final e in _syncBoxes.entries) {
      for (final k in e.value.keys) {
        final raw = e.value.get(k);
        if (raw is! Map) continue;
        if ((raw['ownerId'] ?? '') != ownerId) continue;
        keys.add('${e.key}/$k');
      }
    }
    await _users.put(_pendingKey, keys);
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
  Future<bool> pruneMissing(
    String ownerId,
    Set<String> serverKeys,
  ) async {
    final pending = pendingKeys;
    var changed = false;
    for (final e in _syncBoxes.entries) {
      for (final k in e.value.keys.toList()) {
        final raw = e.value.get(k);
        if (raw is! Map) continue;
        if ((raw['ownerId'] ?? '') != ownerId) continue;
        final full = '${e.key}/$k';
        if (serverKeys.contains(full)) continue;
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
    final remoteStamp =
        (remote['updatedAt'] as num?)?.toInt() ?? 0;
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

    final same = local is Map &&
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
  Future<void> seedRecurringBillsIfEmpty() async {    final ownerId = _scopeId;
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
  String get appVersion {
    final v = _users.get('__app_version__') as String?;
    if (v != null) return v;
    final now = DateTime.now();
    final generated =
        '${now.year}.${now.month.toString().padLeft(2, '0')}'
        '.${now.day.toString().padLeft(2, '0')}.'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    _users.put('__app_version__', generated);
    return generated;
  }

  Future<void> setAppVersion(String v) async {
    await _users.put('__app_version__', v);
    notifyListeners();
  }

  /// UI language: 'ko' (default) or 'en'.
  String get language => (_users.get('__lang__') as String?) ?? 'ko';

  Future<void> setLanguage(String lang) async {
    await _users.put('__lang__', lang);
    notifyListeners();
  }

  /// Screen theme mode: 'system' (follow phone, default), 'light' or 'dark'.
  String get themeModeKey =>
      (_users.get('__theme_mode__') as String?) ?? 'system';

  Future<void> setThemeModeKey(String mode) async {
    await _users.put('__theme_mode__', mode);
    notifyListeners();
  }

  /// Active colour skin id (see [AppSkins.ids]). Defaults to 'midnight'.
  String get skinKey => (_users.get('__skin__') as String?) ?? 'midnight';

  Future<void> setSkinKey(String id) async {
    await _users.put('__skin__', id);
    notifyListeners();
  }

  /// Hand-writing (pen) look for non-notebook skins. The notebook skin always
  /// uses it; here the user can also force it on/off elsewhere.
  bool get handwritingKey => (_users.get('__handwriting__') as bool?) ?? true;

  Future<void> setHandwritingKey(bool on) async {
    await _users.put('__handwriting__', on);
    notifyListeners();
  }

  /// Font family choice (see [AppFonts.ids]): 'system' (Windows / platform
  /// default, the app default), 'pen' (NanumPenScript), 'gaegu' (Gaegu),
  /// 'gothic' (NanumGothic), 'myeongjo', 'dodum', 'jua', 'dohyeon', 'black'.
  String get fontKey => (_users.get('__font__') as String?) ?? 'system';

  Future<void> setFontKey(String k) async {
    await _users.put('__font__', k);
    notifyListeners();
  }

  /// Global text-size multiplier (0.85 – 1.6; 1.0 = normal).
  double get fontScale =>
      ((_users.get('__font_scale__') as num?)?.toDouble() ?? 1.0)
          .clamp(0.85, 1.6);

  Future<void> setFontScale(double v) async {
    await _users.put('__font_scale__', v.clamp(0.85, 1.6));
    notifyListeners();
  }

  /// Google Calendar integration mode:
  ///   'off'    — feature hidden, nothing happens on save (default).
  ///   'manual' — "Add to Calendar" appears in the task menu only.
  ///   'auto'   — every newly saved task is also pushed to Google Calendar.
  String get calendarMode =>
      (_users.get('__cal_mode__') as String?) ?? 'off';

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

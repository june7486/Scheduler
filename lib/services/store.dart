import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';

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
    return true;
  }

  void setCurrentUser(String id) {
    _currentUserId = id;
    notifyListeners();
  }

  void logoutCurrent() {
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
        .where((e) => e['ownerId'] == ownerId)
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
    return raw == null ? null : Category.fromMap(raw);
  }

  Future<void> saveCategory(Category c) async {
    final oid = c.ownerId.isEmpty ? _scopeId : c.ownerId;
    c.ownerId = oid;
    await _cats.put(_catKey(oid, c.id), c.toMap());
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
    final ownerId = _scopeId;
    final c = categoryById(catId);
    await _cats.delete(_catKey(ownerId, catId));
    for (final t in tasksForCategory(catId, includeCompleted: true)) {
      t.categoryId = 'other';
      await _tasks.put(t.id, t.toMap());
    }
    addLog('Delete tab', c?.label ?? catId);
    notifyListeners();
  }

  Future<void> reorderCategories(List<Category> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].order = i;
      final oid = ordered[i].ownerId.isEmpty ? _scopeId : ordered[i].ownerId;
      await _cats.put(_catKey(oid, ordered[i].id), ordered[i].toMap());
    }
    notifyListeners();
  }

  // ---------------- Tasks ----------------
  List<Task> tasksForOwner(String ownerId) {
    final list = _tasks.values
        .where((e) => e['ownerId'] == ownerId)
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
      final list = _tasks.values.map((e) => Task.fromMap(e)).toList();
      _sortTasks(list);
      return list;
    }
    return tasksForOwner(_scopeId);
  }

  List<Task> allTasksRaw() =>
      _tasks.values.map((e) => Task.fromMap(e)).toList();

  int allTaskTotal() => _tasks.length;

  List<Task> tasksForCategory(
    String categoryId, {
    bool includeCompleted = false,
    String? ownerId,
  }) {
    final oid = ownerId ?? _scopeId;
    return tasks
        .where((t) => t.ownerId == oid && t.categoryId == categoryId)
        .where((t) => includeCompleted || !t.completed)
        .toList();
  }

  List<Task> completedForCategory(String categoryId, {String? ownerId}) {
    final oid = ownerId ?? _scopeId;
    return tasks
        .where(
          (t) => t.ownerId == oid && t.categoryId == categoryId && t.completed,
        )
        .toList();
  }

  int taskCountFor(String categoryId, {String? ownerId}) {
    final oid = ownerId ?? _scopeId;
    return tasks
        .where(
          (t) => t.ownerId == oid && t.categoryId == categoryId && !t.completed,
        )
        .length;
  }

  int openTaskCountForOwner(String ownerId) =>
      tasksForOwner(ownerId).where((t) => !t.completed).length;

  Future<void> saveTask(Task t) async {
    if (t.ownerId.isEmpty) t.ownerId = _scopeId;
    await _tasks.put(t.id, t.toMap());
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
    await _tasks.put(t.id, t.toMap());
    addLog('Add task', title);
    notifyListeners();
    return t;
  }

  Future<void> toggleComplete(Task t) async {
    t.completed = !t.completed;
    t.completedAt = t.completed ? DateTime.now() : null;
    await _tasks.put(t.id, t.toMap());
    addLog(t.completed ? 'Complete task' : 'Reopen task', t.title);
    notifyListeners();
  }

  Future<void> deleteTask(Task t) async {
    await _tasks.delete(t.id);
    addLog('Delete task', t.title);
    notifyListeners();
  }

  Future<void> moveTask(Task t, String newCategoryId) async {
    t.categoryId = newCategoryId;
    await _tasks.put(t.id, t.toMap());
    final label = categoryById(newCategoryId)?.label ?? newCategoryId;
    addLog('Move task', '${t.title} → $label');
    notifyListeners();
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
    await _tasks.put(rent.id, rent.toMap());
    await _tasks.put(warehouse.id, warehouse.toMap());
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
      await _tasks.put(t.id, t.toMap());
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
        .where((e) => e['ownerId'] == _scopeId)
        .map((e) => VoiceNote.fromMap(e))
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> saveVoiceNote(VoiceNote v) async {
    if (v.ownerId.isEmpty) v.ownerId = _scopeId;
    await _voices.put(v.id, v.toMap());
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

  /// Active colour skin id (see [AppSkins.ids]). Defaults to 'sage'.
  String get skinKey => (_users.get('__skin__') as String?) ?? 'sage';

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

  /// Font family choice: 'auto' (follow skin/handwriting), 'pen' (NanumPen
  /// hand-writing), 'mark' (Gaegu hand-writing) or 'system' (default gothic).
  String get fontKey => (_users.get('__font__') as String?) ?? 'auto';

  Future<void> setFontKey(String k) async {
    await _users.put('__font__', k);
    notifyListeners();
  }

  /// Global text-size multiplier (0.85 – 1.35; 1.0 = normal).
  double get fontScale =>
      ((_users.get('__font_scale__') as num?)?.toDouble() ?? 1.0)
          .clamp(0.85, 1.35);

  Future<void> setFontScale(double v) async {
    await _users.put('__font_scale__', v.clamp(0.85, 1.35));
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

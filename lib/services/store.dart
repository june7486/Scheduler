import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';

/// Central application state & persistence layer.
/// Uses Hive boxes (maps) so no code-gen adapters are required — keeps the
/// web build simple and reliable.
class Store extends ChangeNotifier {
  static const _taskBox = 'tasks';
  static const _catBox = 'categories';
  static const _logBox = 'logs';
  static const _voiceBox = 'voices';
  static const _settingsBox = 'settings';

  late Box _tasks;
  late Box _cats;
  late Box _logs;
  late Box _voices;
  late Box _settings;

  final _uuid = const Uuid();

  bool _ready = false;
  bool get isReady => _ready;

  /// ---------------- Init ----------------
  Future<void> init() async {
    await Hive.initFlutter();
    _tasks = await Hive.openBox(_taskBox);
    _cats = await Hive.openBox(_catBox);
    _logs = await Hive.openBox(_logBox);
    _voices = await Hive.openBox(_voiceBox);
    _settings = await Hive.openBox(_settingsBox);

    if (_cats.isEmpty) await _seedCategories();
    _ready = true;
    notifyListeners();
  }

  /// ---------------- Categories ----------------
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

  Future<void> _seedCategories() async {
    for (var i = 0; i < defaultCategories.length; i++) {
      final c = defaultCategories[i];
      await _cats.put(c['id'], {
        'id': c['id'],
        'label': c['label'],
        'emoji': c['emoji'],
        'colorValue': c['color'],
        'order': i,
        'enabled': true,
        'showInTopTabs': i < 6,
      });
    }
  }

  List<Category> get categories {
    final list = _cats.values.map((e) => Category.fromMap(e)).toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  List<Category> get enabledCategories =>
      categories.where((c) => c.enabled).toList();

  List<Category> get topTabCategories =>
      categories.where((c) => c.enabled && c.showInTopTabs).toList();

  Category? categoryById(String id) {
    final raw = _cats.get(id);
    return raw == null ? null : Category.fromMap(raw);
  }

  Future<void> saveCategory(Category c) async {
    await _cats.put(c.id, c.toMap());
    notifyListeners();
  }

  Future<void> addCategory(
    String label, {
    String emoji = '📌',
    int color = 0xFF5C6BC0,
  }) async {
    final id = 'cat_${_uuid.v4().substring(0, 8)}';
    final maxOrder = categories.isEmpty ? 0 : categories.last.order + 1;
    await _cats.put(id, {
      'id': id,
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

  Future<void> deleteCategory(String id) async {
    final c = categoryById(id);
    await _cats.delete(id);
    // Re-assign tasks of this category to 'other'
    for (final t in tasks.where((t) => t.categoryId == id)) {
      t.categoryId = 'other';
      await _tasks.put(t.id, t.toMap());
    }
    addLog('Delete tab', c?.label ?? id);
    notifyListeners();
  }

  Future<void> reorderCategories(List<Category> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].order = i;
      await _cats.put(ordered[i].id, ordered[i].toMap());
    }
    notifyListeners();
  }

  /// ---------------- Tasks ----------------
  List<Task> get tasks {
    final list = _tasks.values.map((e) => Task.fromMap(e)).toList();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final byOrder = a.order.compareTo(b.order);
      if (byOrder != 0) return byOrder;
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  List<Task> tasksForCategory(String categoryId) =>
      tasks.where((t) => t.categoryId == categoryId && !t.completed).toList();

  List<Task> completedForCategory(String categoryId) =>
      tasks.where((t) => t.categoryId == categoryId && t.completed).toList();

  int taskCountFor(String categoryId) =>
      tasks.where((t) => t.categoryId == categoryId && !t.completed).length;

  Future<void> saveTask(Task t) async {
    await _tasks.put(t.id, t.toMap());
    notifyListeners();
  }

  Future<Task> addTask(
    String title,
    String categoryId, {
    String note = '',
  }) async {
    final maxOrder = tasks.isEmpty
        ? 0
        : tasks.map((e) => e.order).reduce((a, b) => a > b ? a : b) + 1;
    final t = Task(
      id: _uuid.v4(),
      title: title,
      note: note,
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

  /// Seed the recurring bills described by the user (rent & warehouse).
  Future<void> seedRecurringBillsIfEmpty() async {
    final hasRent = tasks.any((t) => t.title.contains('Rent'));
    if (hasRent) return;
    final rent = Task(
      id: _uuid.v4(),
      title: 'Rent — ₩2,500,000',
      categoryId: 'repeat',
      note: 'Monthly rent, due on the 12th',
      recurrence: 'monthly',
      recurrenceDay: 12,
      amount: 2500000,
    );
    final warehouse = Task(
      id: _uuid.v4(),
      title: 'Warehouse fee — ₩30,000',
      categoryId: 'repeat',
      note: 'Monthly warehouse fee',
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
    if (tasks.any((t) => t.categoryId == 'daily')) return;
    for (final item in [
      'Take medicine',
      'Laundry',
      'Cleaning',
      'Make the bed',
    ]) {
      final t = Task(
        id: _uuid.v4(),
        title: item,
        categoryId: 'daily',
        recurrence: 'daily',
      );
      await _tasks.put(t.id, t.toMap());
    }
    notifyListeners();
  }

  /// ---------------- Logs ----------------
  List<LogEntry> get logs {
    final list = _logs.values.map((e) => LogEntry.fromMap(e)).toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  void addLog(String action, [String detail = '']) {
    final entry = LogEntry(
      id: _uuid.v4(),
      timestamp: DateTime.now(),
      action: action,
      detail: detail,
    );
    _logs.put(entry.id, entry.toMap());
  }

  Future<void> clearLogs() async {
    await _logs.clear();
    notifyListeners();
  }

  /// ---------------- Voice notes ----------------
  List<VoiceNote> get voiceNotes {
    final list = _voices.values.map((e) => VoiceNote.fromMap(e)).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> saveVoiceNote(VoiceNote v) async {
    await _voices.put(v.id, v.toMap());
    notifyListeners();
  }

  Future<void> deleteVoiceNote(String id) async {
    await _voices.delete(id);
    notifyListeners();
  }

  /// ---------------- Settings ----------------
  String get appVersion {
    final v = _settings.get('appVersion') as String?;
    if (v != null) return v;
    final now = DateTime.now();
    final generated =
        '${now.year}.${now.month.toString().padLeft(2, '0')}'
        '.${now.day.toString().padLeft(2, '0')}.'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    _settings.put('appVersion', generated);
    return generated;
  }

  Future<void> setAppVersion(String v) async {
    await _settings.put('appVersion', v);
    notifyListeners();
  }

  String get password => (_settings.get('password') as String?) ?? '748652';
  String get username => (_settings.get('username') as String?) ?? 'tiger415';

  Future<void> setPassword(String pw) async {
    await _settings.put('password', pw);
    addLog('Change password');
    notifyListeners();
  }

  String get forwardUrl =>
      (_settings.get('forwardUrl') as String?) ?? 'https://aqdesign.co.kr';

  Future<void> setForwardUrl(String url) async {
    await _settings.put('forwardUrl', url);
    notifyListeners();
  }

  /// Design/theme mode for the app itself: 'material' | 'minimal'
  String get appThemeMode =>
      (_settings.get('appThemeMode') as String?) ?? 'mix';

  Future<void> setAppThemeMode(String mode) async {
    await _settings.put('appThemeMode', mode);
    notifyListeners();
  }

  /// Output/print design mode: muji | minimal | fancy | whitespace
  String get printDesignMode =>
      (_settings.get('printDesignMode') as String?) ?? 'minimal';

  Future<void> setPrintDesignMode(String mode) async {
    await _settings.put('printDesignMode', mode);
    notifyListeners();
  }

  double get baseFontSize =>
      (_settings.get('baseFontSize') as num?)?.toDouble() ?? 13.0;

  Future<void> setBaseFontSize(double v) async {
    await _settings.put('baseFontSize', v);
    notifyListeners();
  }

  /// ---------------- Backup / Restore ----------------
  Map<String, dynamic> exportBackup() => {
    'version': appVersion,
    'exportedAt': DateTime.now().toIso8601String(),
    'tasks': _tasks.values.map((e) => Map<String, dynamic>.from(e)).toList(),
    'categories': _cats.values
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
    'logs': _logs.values.map((e) => Map<String, dynamic>.from(e)).toList(),
    'voices': _voices.values.map((e) => Map<String, dynamic>.from(e)).toList(),
    'settings': {
      'password': password,
      'username': username,
      'forwardUrl': forwardUrl,
      'appThemeMode': appThemeMode,
      'printDesignMode': printDesignMode,
      'baseFontSize': baseFontSize,
      'appVersion': appVersion,
    },
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
      await _cats.put(e['id'], Map<String, dynamic>.from(e));
    }
    for (final e in (data['logs'] as List? ?? [])) {
      await _logs.put(e['id'], Map<String, dynamic>.from(e));
    }
    for (final e in (data['voices'] as List? ?? [])) {
      await _voices.put(e['id'], Map<String, dynamic>.from(e));
    }
    final s = data['settings'] as Map?;
    if (s != null) {
      await _settings.put('password', s['password'] ?? password);
      await _settings.put('username', s['username'] ?? username);
      await _settings.put('forwardUrl', s['forwardUrl'] ?? forwardUrl);
      await _settings.put('appThemeMode', s['appThemeMode'] ?? appThemeMode);
      await _settings.put(
        'printDesignMode',
        s['printDesignMode'] ?? printDesignMode,
      );
      await _settings.put('baseFontSize', s['baseFontSize'] ?? baseFontSize);
      await _settings.put('appVersion', s['appVersion'] ?? appVersion);
    }
    addLog('Restore backup');
    notifyListeners();
  }

  Future<void> clearCache() async {
    // Clear non-essential cached data but keep user content & settings.
    await _logs.clear();
    notifyListeners();
  }

  Future<void> wipeAll() async {
    await _tasks.clear();
    await _cats.clear();
    await _logs.clear();
    await _voices.clear();
    await _seedCategories();
    notifyListeners();
  }
}

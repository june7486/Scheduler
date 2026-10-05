/// A user account. The master account is flagged with [isMaster].
class User {
  final String id; // login id (unique)
  String password; // plaintext for local-only app (see note in settings)
  String displayName;
  bool isMaster;
  bool enabled;
  DateTime createdAt;

  // Per-user preferences
  String forwardUrl;
  String appThemeMode; // material | minimal | mix
  String printDesignMode; // muji | minimal | fancy | whitespace
  double baseFontSize;

  User({
    required this.id,
    required this.password,
    this.displayName = '',
    this.isMaster = false,
    this.enabled = true,
    DateTime? createdAt,
    this.forwardUrl = 'https://aqdesign.co.kr',
    this.appThemeMode = 'mix',
    this.printDesignMode = 'minimal',
    this.baseFontSize = 13.0,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'password': password,
    'displayName': displayName,
    'isMaster': isMaster,
    'enabled': enabled,
    'createdAt': createdAt.toIso8601String(),
    'forwardUrl': forwardUrl,
    'appThemeMode': appThemeMode,
    'printDesignMode': printDesignMode,
    'baseFontSize': baseFontSize,
  };

  factory User.fromMap(Map<dynamic, dynamic> map) => User(
    id: (map['id'] ?? '') as String,
    password: (map['password'] ?? '') as String,
    displayName: (map['displayName'] ?? '') as String,
    isMaster: (map['isMaster'] ?? false) as bool,
    enabled: (map['enabled'] ?? true) as bool,
    createdAt: map['createdAt'] != null
        ? DateTime.tryParse(map['createdAt'] as String) ?? DateTime.now()
        : DateTime.now(),
    forwardUrl: (map['forwardUrl'] ?? 'https://aqdesign.co.kr') as String,
    appThemeMode: (map['appThemeMode'] ?? 'mix') as String,
    printDesignMode: (map['printDesignMode'] ?? 'minimal') as String,
    baseFontSize: (map['baseFontSize'] as num?)?.toDouble() ?? 13.0,
  );
}

/// A single schedulable task/item in June's Scheduler.
class Task {
  final String id;
  String title;
  String note;

  /// Owner (user id) this task belongs to.
  String ownerId;

  /// Category/tab id this task belongs to.
  String categoryId;

  /// Priority order for display (lower = higher up).
  int order;

  bool completed;
  DateTime? completedAt;
  DateTime createdAt;
  DateTime? dueDate;

  /// Recurrence: none | daily | weekly | monthly
  String recurrence;

  /// For monthly recurrence: day of month (e.g. 12 for rent).
  int? recurrenceDay;

  /// Optional money amount (for finance/debt/receivable categories).
  double? amount;

  /// Optional person/payee related to the task.
  String relatedTo;

  /// Whether the task is pinned/highlighted.
  bool pinned;

  /// Long-term flag (long-term category behaviour).
  bool longTerm;

  Task({
    required this.id,
    required this.title,
    this.ownerId = '',
    this.note = '',
    required this.categoryId,
    this.order = 0,
    this.completed = false,
    this.completedAt,
    DateTime? createdAt,
    this.dueDate,
    this.recurrence = 'none',
    this.recurrenceDay,
    this.amount,
    this.relatedTo = '',
    this.pinned = false,
    this.longTerm = false,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'ownerId': ownerId,
    'note': note,
    'categoryId': categoryId,
    'order': order,
    'completed': completed,
    'completedAt': completedAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'dueDate': dueDate?.toIso8601String(),
    'recurrence': recurrence,
    'recurrenceDay': recurrenceDay,
    'amount': amount,
    'relatedTo': relatedTo,
    'pinned': pinned,
    'longTerm': longTerm,
  };

  factory Task.fromMap(Map<dynamic, dynamic> map) => Task(
    id: map['id'] as String,
    title: (map['title'] ?? '') as String,
    ownerId: (map['ownerId'] ?? '') as String,
    note: (map['note'] ?? '') as String,
    categoryId: (map['categoryId'] ?? 'other') as String,
    order: (map['order'] ?? 0) as int,
    completed: (map['completed'] ?? false) as bool,
    completedAt: map['completedAt'] != null
        ? DateTime.tryParse(map['completedAt'] as String)
        : null,
    createdAt: map['createdAt'] != null
        ? DateTime.tryParse(map['createdAt'] as String) ?? DateTime.now()
        : DateTime.now(),
    dueDate: map['dueDate'] != null
        ? DateTime.tryParse(map['dueDate'] as String)
        : null,
    recurrence: (map['recurrence'] ?? 'none') as String,
    recurrenceDay: map['recurrenceDay'] as int?,
    amount: (map['amount'] as num?)?.toDouble(),
    relatedTo: (map['relatedTo'] ?? '') as String,
    pinned: (map['pinned'] ?? false) as bool,
    longTerm: (map['longTerm'] ?? false) as bool,
  );
}

/// A configurable category / tab. Users can add, rename, reorder or remove.
class Category {
  final String id;
  String ownerId;
  String label;
  String emoji;
  int colorValue;
  int order;
  bool enabled;

  /// Whether this category participates in the top filter tab row.
  bool showInTopTabs;

  Category({
    required this.id,
    this.ownerId = '',
    required this.label,
    this.emoji = '',
    required this.colorValue,
    this.order = 0,
    this.enabled = true,
    this.showInTopTabs = true,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'ownerId': ownerId,
    'label': label,
    'emoji': emoji,
    'colorValue': colorValue,
    'order': order,
    'enabled': enabled,
    'showInTopTabs': showInTopTabs,
  };

  factory Category.fromMap(Map<dynamic, dynamic> map) => Category(
    id: map['id'] as String,
    ownerId: (map['ownerId'] ?? '') as String,
    label: (map['label'] ?? '') as String,
    emoji: (map['emoji'] ?? '') as String,
    colorValue: (map['colorValue'] ?? 0xFF5C6BC0) as int,
    order: (map['order'] ?? 0) as int,
    enabled: (map['enabled'] ?? true) as bool,
    showInTopTabs: (map['showInTopTabs'] ?? true) as bool,
  );
}

/// A log entry for the activity log in settings.
class LogEntry {
  final String id;
  final DateTime timestamp;
  final String action;
  final String detail;
  final String ownerId;

  LogEntry({
    required this.id,
    required this.timestamp,
    required this.action,
    this.detail = '',
    this.ownerId = '',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'action': action,
    'detail': detail,
    'ownerId': ownerId,
  };

  factory LogEntry.fromMap(Map<dynamic, dynamic> map) => LogEntry(
    id: map['id'] as String,
    timestamp: DateTime.tryParse(map['timestamp'] as String) ?? DateTime.now(),
    action: (map['action'] ?? '') as String,
    detail: (map['detail'] ?? '') as String,
    ownerId: (map['ownerId'] ?? '') as String,
  );
}

/// Voice note with transcript and auto-summary.
class VoiceNote {
  final String id;
  final DateTime createdAt;
  final String filePath;
  final int durationSeconds;
  String transcript;
  String summary;
  List<String> bulletPoints;
  String ownerId;

  VoiceNote({
    required this.id,
    required this.createdAt,
    required this.filePath,
    this.durationSeconds = 0,
    this.transcript = '',
    this.summary = '',
    List<String>? bulletPoints,
    this.ownerId = '',
  }) : bulletPoints = bulletPoints ?? [];

  Map<String, dynamic> toMap() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'filePath': filePath,
    'durationSeconds': durationSeconds,
    'transcript': transcript,
    'summary': summary,
    'bulletPoints': bulletPoints,
    'ownerId': ownerId,
  };

  factory VoiceNote.fromMap(Map<dynamic, dynamic> map) => VoiceNote(
    id: map['id'] as String,
    createdAt: DateTime.tryParse(map['createdAt'] as String) ?? DateTime.now(),
    filePath: (map['filePath'] ?? '') as String,
    durationSeconds: (map['durationSeconds'] ?? 0) as int,
    transcript: (map['transcript'] ?? '') as String,
    summary: (map['summary'] ?? '') as String,
    bulletPoints:
        (map['bulletPoints'] as List?)?.map((e) => e.toString()).toList() ?? [],
    ownerId: (map['ownerId'] ?? '') as String,
  );
}

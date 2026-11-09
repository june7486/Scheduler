/// A user account. The master account is flagged with [isMaster].
class User {
  final String id; // login id (unique)
  String password; // plaintext for local-only app (see note in settings)
  String displayName;
  bool isMaster;
  bool enabled;
  DateTime createdAt;

  /// Last modification time (epoch ms). The account record itself syncs across
  /// devices so a new phone can sign in with the same credentials; this is what
  /// decides which copy of the account is newer.
  int updatedAt;

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
    this.updatedAt = 0,
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
    'updatedAt': updatedAt,
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
    updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
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

  /// Category/tab id this task belongs to (the primary category).
  String categoryId;

  /// Additional category/tab ids this task also belongs to (multi-tab).
  List<String> categoryIds;

  /// All categories this task belongs to: the primary [categoryId] plus any
  /// extra [categoryIds] (deduplicated, primary first).
  List<String> get allCategoryIds {
    final list = <String>[categoryId];
    for (final c in categoryIds) {
      if (c.isNotEmpty && !list.contains(c)) list.add(c);
    }
    return list;
  }

  bool isInCategory(String id) => allCategoryIds.contains(id);

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

  /// Last local modification time, in epoch milliseconds. Used by the sync
  /// engine to decide which copy of a record is newer. 0 = never stamped.
  int updatedAt;

  /// Soft-delete marker (epoch ms). Non-null means "deleted", which lets a
  /// deletion propagate to other devices instead of the record coming back
  /// from a stale copy.
  int? deletedAt;

  Task({
    required this.id,
    required this.title,
    this.ownerId = '',
    this.note = '',
    required this.categoryId,
    this.categoryIds = const [],
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
    this.updatedAt = 0,
    this.deletedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'ownerId': ownerId,
    'note': note,
    'categoryId': categoryId,
    'categoryIds': categoryIds,
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
    'updatedAt': updatedAt,
    'deletedAt': deletedAt,
  };

  factory Task.fromMap(Map<dynamic, dynamic> map) => Task(
    id: map['id'] as String,
    title: (map['title'] ?? '') as String,
    ownerId: (map['ownerId'] ?? '') as String,
    note: (map['note'] ?? '') as String,
    categoryId: (map['categoryId'] ?? 'other') as String,
    categoryIds: ((map['categoryIds'] as List?) ?? const [])
        .map((e) => '$e')
        .toList(),
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
    updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
    deletedAt: (map['deletedAt'] as num?)?.toInt(),
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

  /// True once the user renamed this (built-in) category. A renamed category
  /// keeps its own label instead of following the UI language.
  bool isCustomLabel;

  /// Last local modification time (epoch ms) — sync metadata.
  int updatedAt;

  /// Soft-delete marker (epoch ms) — sync metadata.
  int? deletedAt;

  Category({
    required this.id,
    this.ownerId = '',
    required this.label,
    this.emoji = '',
    required this.colorValue,
    this.order = 0,
    this.enabled = true,
    this.showInTopTabs = true,
    this.isCustomLabel = false,
    this.updatedAt = 0,
    this.deletedAt,
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
    'isCustomLabel': isCustomLabel,
    'updatedAt': updatedAt,
    'deletedAt': deletedAt,
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
    isCustomLabel: (map['isCustomLabel'] ?? false) as bool,
    updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
    deletedAt: (map['deletedAt'] as num?)?.toInt(),
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

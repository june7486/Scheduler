/// A single schedulable task/item in June's Scheduler.
class Task {
  final String id;
  String title;
  String note;

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
  String label;
  String emoji;
  int colorValue;
  int order;
  bool enabled;

  /// Whether this category participates in the top filter tab row.
  bool showInTopTabs;

  Category({
    required this.id,
    required this.label,
    this.emoji = '',
    required this.colorValue,
    this.order = 0,
    this.enabled = true,
    this.showInTopTabs = true,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'label': label,
    'emoji': emoji,
    'colorValue': colorValue,
    'order': order,
    'enabled': enabled,
    'showInTopTabs': showInTopTabs,
  };

  factory Category.fromMap(Map<dynamic, dynamic> map) => Category(
    id: map['id'] as String,
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

  LogEntry({
    required this.id,
    required this.timestamp,
    required this.action,
    this.detail = '',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'action': action,
    'detail': detail,
  };

  factory LogEntry.fromMap(Map<dynamic, dynamic> map) => LogEntry(
    id: map['id'] as String,
    timestamp: DateTime.tryParse(map['timestamp'] as String) ?? DateTime.now(),
    action: (map['action'] ?? '') as String,
    detail: (map['detail'] ?? '') as String,
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

  VoiceNote({
    required this.id,
    required this.createdAt,
    required this.filePath,
    this.durationSeconds = 0,
    this.transcript = '',
    this.summary = '',
    List<String>? bulletPoints,
  }) : bulletPoints = bulletPoints ?? [];

  Map<String, dynamic> toMap() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'filePath': filePath,
    'durationSeconds': durationSeconds,
    'transcript': transcript,
    'summary': summary,
    'bulletPoints': bulletPoints,
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
  );
}

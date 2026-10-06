import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';

/// Google Calendar integration.
///
/// Uses the official "render template" URL which works both on the web and on
/// Android (the OS routes it to the Google Calendar app when installed).
/// This keeps us free of heavy OAuth flows while still giving one-tap
/// "add to diary" behaviour, matching the user's request.
class CalendarService {
  static Uri buildEventUri(
    Task task, {
    DateTime? start,
    int durationMinutes = 60,
  }) {
    final s = start ?? task.dueDate ?? _nextOccurrence(task);
    final e = s.add(Duration(minutes: durationMinutes));
    final dates = '${_fmt(s)}/${_fmt(e)}';
    final params = {
      'action': 'TEMPLATE',
      'text': task.title,
      'dates': dates,
      'details': _details(task),
    };
    return Uri.https('calendar.google.com', '/calendar/render', params);
  }

  static String _details(Task task) {
    final buf = StringBuffer();
    if (task.note.isNotEmpty) buf.writeln(task.note);
    if (task.amount != null) {
      buf.writeln('Amount: ₩${task.amount!.toStringAsFixed(0)}');
    }
    if (task.relatedTo.isNotEmpty) buf.writeln('Related to: ${task.relatedTo}');
    if (task.recurrence != 'none') {
      buf.writeln(
        'Repeats: ${task.recurrence}'
        '${task.recurrenceDay != null ? ' (day ${task.recurrenceDay})' : ''}',
      );
    }
    buf.writeln('\n— Created by June\'s Scheduler');
    return buf.toString();
  }

  static DateTime _nextOccurrence(Task task) {
    final now = DateTime.now();
    if (task.recurrence == 'monthly' && task.recurrenceDay != null) {
      var d = DateTime(now.year, now.month, task.recurrenceDay!);
      if (d.isBefore(now)) {
        d = DateTime(now.year, now.month + 1, task.recurrenceDay!);
      }
      return DateTime(d.year, d.month, d.day, 9, 0);
    }
    final tomorrow = now.add(const Duration(days: 1));
    return DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9, 0);
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}T${two(d.hour)}${two(d.minute)}00';
  }

  /// Opens the Google Calendar "create event" screen for [task].
  /// Returns true if the launch succeeded.
  static Future<bool> addToCalendar(BuildContext context, Task task) async {
    final uri = buildEventUri(task);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Opens Google Calendar itself (month view). Used by the "open calendar"
  /// action so the user can glance at their synced diary.
  static Future<bool> openCalendar() async {
    final uri = Uri.https('calendar.google.com', '/calendar/u/0/r/month');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
    } catch (_) {}
    return false;
  }
}

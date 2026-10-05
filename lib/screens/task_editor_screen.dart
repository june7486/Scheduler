import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../services/calendar_service.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';

class TaskEditorScreen extends StatefulWidget {
  final Task? task;
  final String? initialCategoryId;
  const TaskEditorScreen({super.key, this.task, this.initialCategoryId});

  @override
  State<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends State<TaskEditorScreen> {
  late TextEditingController _title;
  late TextEditingController _note;
  late TextEditingController _amount;
  late TextEditingController _related;
  late TextEditingController _day;
  String _categoryId = 'todo';
  String _recurrence = 'none';
  bool _pinned = false;
  bool _longTerm = false;
  DateTime? _dueDate;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _title = TextEditingController(text: t?.title ?? '');
    _note = TextEditingController(text: t?.note ?? '');
    _amount = TextEditingController(text: t?.amount?.toStringAsFixed(0) ?? '');
    _related = TextEditingController(text: t?.relatedTo ?? '');
    _day = TextEditingController(text: t?.recurrenceDay?.toString() ?? '');
    _categoryId = t?.categoryId ?? widget.initialCategoryId ?? 'todo';
    _recurrence = t?.recurrence ?? 'none';
    _pinned = t?.pinned ?? false;
    _longTerm = t?.longTerm ?? false;
    _dueDate = t?.dueDate;
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _amount.dispose();
    _related.dispose();
    _day.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('enter_title'))));
      return;
    }
    final t =
        widget.task ??
        Task(id: const Uuid().v4(), title: '', categoryId: _categoryId);
    t.title = _title.text.trim();
    t.note = _note.text.trim();
    t.categoryId = _categoryId;
    t.recurrence = _recurrence;
    t.recurrenceDay = int.tryParse(_day.text.trim());
    t.amount = double.tryParse(_amount.text.replaceAll(',', '').trim());
    t.relatedTo = _related.text.trim();
    t.pinned = _pinned;
    t.longTerm = _longTerm;
    t.dueDate = _dueDate;
    Navigator.pop(context, t);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final cats = store.enabledCategories;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.task == null ? context.tr('new_task') : context.tr('edit_task')),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              context.tr('save'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Label(context.tr('title')),
            TextField(
              controller: _title,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(hintText: context.tr('title_hint')),
            ),
            const SizedBox(height: 16),
            _Label(context.tr('note')),
            TextField(
              controller: _note,
              style: const TextStyle(fontSize: 13.5),
              maxLines: 3,
              decoration: InputDecoration(hintText: context.tr('note_hint')),
            ),
            const SizedBox(height: 16),
            _Label(context.tr('category_tab')),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: cats.map((c) {
                final col = Color(c.colorValue);
                final sel = c.id == _categoryId;
                return GestureDetector(
                  onTap: () => setState(() => _categoryId = c.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: sel ? col.withValues(alpha: 0.15) : p.card,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: sel ? col : p.line),
                    ),
                    child: Text(
                      '${c.emoji} ${c.label}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? ct(col) : p.inkSoft,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            _Label(context.tr('recurrence')),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'none',
                  label: Text(context.tr('rec_none'),
                      style: const TextStyle(fontSize: 11.5)),
                ),
                ButtonSegment(
                  value: 'daily',
                  label: Text(context.tr('rec_daily'),
                      style: const TextStyle(fontSize: 11.5)),
                ),
                ButtonSegment(
                  value: 'weekly',
                  label: Text(context.tr('rec_weekly'),
                      style: const TextStyle(fontSize: 11.5)),
                ),
                ButtonSegment(
                  value: 'monthly',
                  label: Text(context.tr('rec_monthly'),
                      style: const TextStyle(fontSize: 11.5)),
                ),
              ],
              selected: {_recurrence},
              onSelectionChanged: (s) => setState(() => _recurrence = s.first),
              showSelectedIcon: false,
            ),
            if (_recurrence == 'monthly') ...[
              const SizedBox(height: 12),
              _Label(context.tr('day_of_month')),
              TextField(
                controller: _day,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 13.5),
                decoration: InputDecoration(hintText: context.tr('day_of_month_hint')),
              ),
            ],
            const SizedBox(height: 16),
            _Label(context.tr('amount')),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(hintText: context.tr('amount_hint')),
            ),
            const SizedBox(height: 16),
            _Label(context.tr('related_to')),
            TextField(
              controller: _related,
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(hintText: context.tr('related_hint')),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr('pin_top'), style: const TextStyle(fontSize: 13.5)),
              value: _pinned,
              activeThumbColor: p.indigo,
              onChanged: (v) => setState(() => _pinned = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr('long_term'), style: const TextStyle(fontSize: 13.5)),
              value: _longTerm,
              activeThumbColor: p.indigo,
              onChanged: (v) => setState(() => _longTerm = v),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final t =
                    widget.task ??
                    Task(
                      id: const Uuid().v4(),
                      title: _title.text.trim(),
                      categoryId: _categoryId,
                    );
                t.title = _title.text.trim().isEmpty
                    ? 'Untitled task'
                    : _title.text.trim();
                t.note = _note.text.trim();
                t.amount = double.tryParse(
                  _amount.text.replaceAll(',', '').trim(),
                );
                t.relatedTo = _related.text.trim();
                t.recurrence = _recurrence;
                t.recurrenceDay = int.tryParse(_day.text.trim());
                final ok = await CalendarService.addToCalendar(context, t);
                if (!context.mounted) return;
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(context.tr('cannot_open_calendar')),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.event_available_outlined, size: 18),
              label: Text(
                context.tr('add_to_calendar'),
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: p.inkSoft,
        letterSpacing: 0.3,
      ),
    ),
  );
}

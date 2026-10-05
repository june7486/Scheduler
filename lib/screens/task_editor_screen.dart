import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

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
      ).showSnackBar(const SnackBar(content: Text('Please enter a title.')));
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
        title: Text(widget.task == null ? 'New Task' : 'Edit Task'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'Save',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _Label('Title'),
            TextField(
              controller: _title,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(hintText: 'e.g. Pay rent'),
            ),
            const SizedBox(height: 16),
            const _Label('Note'),
            TextField(
              controller: _note,
              style: const TextStyle(fontSize: 13.5),
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Details (optional)'),
            ),
            const SizedBox(height: 16),
            const _Label('Category / Tab'),
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
                      color: sel ? col.withValues(alpha: 0.15) : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: sel ? col : AppColors.line),
                    ),
                    child: Text(
                      '${c.emoji} ${c.label}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? col : AppColors.inkSoft,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            const _Label('Recurrence'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'none',
                  label: Text('None', style: TextStyle(fontSize: 11.5)),
                ),
                ButtonSegment(
                  value: 'daily',
                  label: Text('Daily', style: TextStyle(fontSize: 11.5)),
                ),
                ButtonSegment(
                  value: 'weekly',
                  label: Text('Weekly', style: TextStyle(fontSize: 11.5)),
                ),
                ButtonSegment(
                  value: 'monthly',
                  label: Text('Monthly', style: TextStyle(fontSize: 11.5)),
                ),
              ],
              selected: {_recurrence},
              onSelectionChanged: (s) => setState(() => _recurrence = s.first),
              showSelectedIcon: false,
            ),
            if (_recurrence == 'monthly') ...[
              const SizedBox(height: 12),
              const _Label('Day of month'),
              TextField(
                controller: _day,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 13.5),
                decoration: const InputDecoration(hintText: 'e.g. 12'),
              ),
            ],
            const SizedBox(height: 16),
            const _Label('Amount (₩, optional)'),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(hintText: 'e.g. 2500000'),
            ),
            const SizedBox(height: 16),
            const _Label('Related to (person / payee, optional)'),
            TextField(
              controller: _related,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(hintText: 'e.g. Landlord'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pin to top', style: TextStyle(fontSize: 13.5)),
              value: _pinned,
              activeThumbColor: AppColors.indigo,
              onChanged: (v) => setState(() => _pinned = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Long-term', style: TextStyle(fontSize: 13.5)),
              value: _longTerm,
              activeThumbColor: AppColors.indigo,
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
                    const SnackBar(
                      content: Text('Could not open Google Calendar.'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.event_available_outlined, size: 18),
              label: const Text(
                'Add to Google Calendar',
                style: TextStyle(fontSize: 12.5),
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
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: AppColors.inkSoft,
        letterSpacing: 0.3,
      ),
    ),
  );
}

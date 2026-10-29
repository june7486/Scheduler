import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../services/calendar_service.dart';
import '../services/session_service.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';
import '../widgets/notebook_ui.dart';
import '../widgets/task_row.dart';
import 'settings_screen.dart';
import 'admin_screen.dart';
import 'task_editor_screen.dart';
import 'voice_note_screen.dart';
import 'print_preview_screen.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _topTab = 'all'; // 'all' or a category id
  String? _selectedTaskId;
  bool _completedExpanded = true;

  // Controllers so the ‹ › / ▲ ▼ arrows can scroll the top tab bar and the
  // right category rail.
  final ScrollController _tabScroll = ScrollController();
  final ScrollController _railScroll = ScrollController();
  bool _tabCanLeft = false;
  bool _tabCanRight = false;
  bool _railCanUp = false;
  bool _railCanDown = false;

  @override
  void initState() {
    super.initState();
    _tabScroll.addListener(_syncTabArrows);
    _railScroll.addListener(_syncRailArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final store = context.read<Store>();
      await store.seedRecurringBillsIfEmpty();
      await store.seedDailyRoutinesIfEmpty();
      _syncTabArrows();
      _syncRailArrows();
    });
  }

  @override
  void dispose() {
    _tabScroll.dispose();
    _railScroll.dispose();
    super.dispose();
  }

  void _syncTabArrows() {
    if (!mounted || !_tabScroll.hasClients) return;
    final pos = _tabScroll.position;
    final l = pos.pixels > 1;
    final r = pos.pixels < pos.maxScrollExtent - 1;
    if (l != _tabCanLeft || r != _tabCanRight) {
      setState(() {
        _tabCanLeft = l;
        _tabCanRight = r;
      });
    }
  }

  void _syncRailArrows() {
    if (!mounted || !_railScroll.hasClients) return;
    final pos = _railScroll.position;
    final u = pos.pixels > 1;
    final d = pos.pixels < pos.maxScrollExtent - 1;
    if (u != _railCanUp || d != _railCanDown) {
      setState(() {
        _railCanUp = u;
        _railCanDown = d;
      });
    }
  }

  /// Smoothly nudges a scroll view by roughly one row/column.
  void _nudge(ScrollController c, double delta) {
    if (!c.hasClients) return;
    final max = c.position.maxScrollExtent;
    c.animateTo(
      (c.offset + delta).clamp(0.0, max),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final cats = store.enabledCategories;
    final topCats = store.topTabCategories;

    // Tasks to display according to the selected top tab.
    List<Task> active = _topTab == 'all'
        ? store.tasks.where((t) => !t.completed).toList()
        : store.tasksForCategory(_topTab);
    List<Task> done = _topTab == 'all'
        ? store.tasks.where((t) => t.completed).toList()
        : store.completedForCategory(_topTab);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              store.language == 'en' ? "June's Scheduler" : 'June 스케줄러',
              style: TextStyle(
                fontFamily: handFamily(),
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              store.isMaster && store.masterViewingAll
                  ? context.tr('master_viewing_all')
                  : context.tr('signed_in', args: {
                      'id': '${store.currentUserId}${store.isMaster ? " (${context.tr('master')})" : ""}'
                    }),
              style: TextStyle(
                fontSize: 10.5,
                color: p.inkSoft,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          if (store.isMaster)
            IconButton(
              tooltip: context.tr('master_console'),
              icon: const Icon(Icons.admin_panel_settings_outlined, size: 21),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AdminScreen()),
              ),
            ),
          IconButton(
            tooltip: context.tr('print_export'),
            icon: const Icon(Icons.print_outlined, size: 21),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrintPreviewScreen()),
            ),
          ),
          IconButton(
            tooltip: context.tr('voice_note'),
            icon: const Icon(Icons.mic_none_rounded, size: 21),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const VoiceNoteScreen()),
            ),
          ),
          IconButton(
            tooltip: context.tr('settings'),
            icon: const Icon(Icons.settings_outlined, size: 21),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          IconButton(
            tooltip: context.tr('sign_out'),
            icon: const Icon(Icons.logout_rounded, size: 20),
            onPressed: () async {
              await SessionService().logout();
              if (!context.mounted) return;
              context.read<Store>().logoutCurrent();
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  _topTabBar(topCats),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: _taskArea(store, cats, active, done)),
                        _rightRail(store, cats),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: p.indigo,
        foregroundColor: p.onAccent,
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add, size: 20),
        label: Text(context.tr('add_task'), style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  // ---------------- Top filter tabs ----------------
  Widget _topTabBar(List<Category> topCats) {
    return Container(
      height: 44,
      color: p.card,
      child: Row(
        children: [
          // ‹ — scroll the tab strip left
          _scrollArrow(
            icon: Icons.chevron_left,
            enabled: _tabCanLeft,
            tooltip: context.tr('scroll_left'),
            onTap: () => _nudge(_tabScroll, -140),
          ),
          Expanded(
            child: ListView(
              controller: _tabScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              children: [
                _topChip('all', '📋', context.tr('all')),
                for (final c in topCats)
                  _topChip(
                    c.id,
                    c.emoji,
                    catLabel(c),
                    color: Color(c.colorValue),
                  ),
              ],
            ),
          ),
          // › — scroll the tab strip right
          _scrollArrow(
            icon: Icons.chevron_right,
            enabled: _tabCanRight,
            tooltip: context.tr('scroll_right'),
            onTap: () => _nudge(_tabScroll, 140),
          ),
          // ＋ 항목추가 — new tab/menu right where the tabs live
          _addItemButton(),
        ],
      ),
    );
  }

  /// Small ‹ › arrow used by the horizontal tab strip.
  Widget _scrollArrow({
    required IconData icon,
    required bool enabled,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 22,
          height: 44,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? p.indigo : p.inkSoft.withValues(alpha: 0.28),
          ),
        ),
      ),
    );
  }

  /// The "항목추가" (add item / tab) button pinned at the right of the tab bar.
  Widget _addItemButton() {
    return Padding(
      padding: const EdgeInsets.only(right: 8, left: 2),
      child: InkWell(
        onTap: () => _addTabDialog(context, context.read<Store>()),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: p.indigo,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 14, color: p.onAccent),
              const SizedBox(width: 3),
              Text(
                context.tr('add_item'),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: p.onAccent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shared "add a new menu/tab" dialog.
  void _addTabDialog(BuildContext context, Store store) {
    final label = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('add_menu')),
        content: TextField(
          controller: label,
          autofocus: true,
          decoration: InputDecoration(hintText: context.tr('tab_name')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              if (label.text.trim().isNotEmpty) {
                store.addCategory(label.text.trim());
              }
              Navigator.pop(context);
            },
            child: Text(context.tr('add')),
          ),
        ],
      ),
    );
  }

  Widget _topChip(String id, String emoji, String label, {Color? color}) {
    final selected = _topTab == id;
    final col = color ?? p.indigo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
      child: GestureDetector(
        onTap: () => setState(() => _topTab = id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? col.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? col.withValues(alpha: 0.5) : p.line,
            ),
          ),
          child: Text(
            '$emoji $label',
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? ct(col) : p.inkSoft,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- Task area ----------------
  Widget _taskArea(
    Store store,
    List<Category> cats,
    List<Task> active,
    List<Task> done,
  ) {
    return Column(
      children: [
        _sectionHeader(context.tr('tasks'), active.length),
        Expanded(
          child: active.isEmpty
              ? Center(
                  child: Text(
                    context.tr('no_tasks'),
                    style: TextStyle(fontSize: 12.5, color: p.inkSoft),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 90),
                  itemCount: active.length,
                  itemBuilder: (_, i) {
                    final t = active[i];
                    final cat = store.categoryById(t.categoryId) ?? cats.first;
                    return _wrapSelectable(
                      t,
                      GestureDetector(
                        onLongPress: () => _showTaskMenu(store, t),
                        child: TaskRow(
                          task: t,
                          category: cat,
                          assignTargets: cats,
                          onToggle: () => store.toggleComplete(t),
                          onTap: () => setState(
                            () => _selectedTaskId = _selectedTaskId == t.id
                                ? null
                                : t.id,
                          ),
                          onDelete: () => _confirmDelete(store, t),
                          onAssign: (c) => store.toggleCategoryIn(t, c.id),
                        ),
                      ),
                    );
                  },
                ),
        ),
        // ---------------- Completed section ----------------
        Container(
          decoration: BoxDecoration(
            color: p.card,
            border: Border(top: BorderSide(color: p.line)),
          ),
          child: Column(
            children: [
              InkWell(
                onTap: () =>
                    setState(() => _completedExpanded = !_completedExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: 16,
                        color: p.inkSoft,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        context.tr('completed'),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: p.inkSoft,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '(${done.length})',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: p.inkSoft,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        _completedExpanded
                            ? Icons.expand_more
                            : Icons.expand_less,
                        size: 18,
                        color: p.inkSoft,
                      ),
                    ],
                  ),
                ),
              ),
              if (_completedExpanded)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: done.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Text(
                            context.tr('nothing_completed'),
                            style: TextStyle(
                              fontSize: 11.5,
                              color: p.inkSoft,
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: done.length,
                          itemBuilder: (_, i) {
                            final t = done[i];
                            final cat =
                                store.categoryById(t.categoryId) ?? cats.first;
                            return _completedRow(store, t, cat);
                          },
                        ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, int count) {
    return Container(
      color: p.card,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        children: [
          if (handwritingOn) ...[
            const HandAsterisk(size: 15, seed: 3),
            const SizedBox(width: 6),
          ],
          handwritingOn
              ? HandHighlight(
                  color: const Color(0xFFFFE066),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontFamily: handFamily(),
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                )
              : Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: p.ink,
                  ),
                ),
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: TextStyle(fontSize: 11.5, color: p.inkSoft),
          ),
        ],
      ),
    );
  }

  Widget _wrapSelectable(Task t, Widget child) {
    final selected = _selectedTaskId == t.id;
    return Container(
      decoration: selected
          ? BoxDecoration(
              border: Border.all(color: p.indigo, width: 1.4),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: child,
    );
  }

  Widget _completedRow(Store store, Task t, Category cat) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: [
          Icon(Icons.check, size: 15, color: ct(Color(cat.colorValue))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.title,
              style: TextStyle(
                fontSize: 12,
                color: p.inkSoft,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          ),
          IconButton(
            onPressed: () => store.deleteTask(t),
            icon: Icon(
              Icons.delete_outline,
              size: 17,
              color: p.danger,
            ),
            visualDensity: VisualDensity.compact,
            tooltip: context.tr('delete'),
          ),
        ],
      ),
    );
  }

  // ---------------- Right rail (instant categorisation) ----------------
  Widget _rightRail(Store store, List<Category> cats) {
    return Container(
      width: 78,
      decoration: BoxDecoration(
        color: p.card,
        border: Border(left: BorderSide(color: p.line)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text(
              _selectedTaskId == null
                  ? context.tr('select_task_then_tab')
                  : context.tr('assign_to'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9.5,
                color: p.inkSoft,
                height: 1.3,
              ),
            ),
          ),
          const Divider(height: 1),
          // ▲ — scroll the category rail up
          _railArrow(
            icon: Icons.keyboard_arrow_up,
            enabled: _railCanUp,
            tooltip: context.tr('scroll_up'),
            onTap: () => _nudge(_railScroll, -110),
          ),
          Expanded(
            child: ListView.builder(
              controller: _railScroll,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: cats.length,
              itemBuilder: (_, i) {
                final c = cats[i];
                final col = Color(c.colorValue);
                final count = store.taskCountFor(c.id);
                final isCurrent = _selectedTaskId != null &&
                    store.tasks
                        .firstWhere(
                          (t) => t.id == _selectedTaskId,
                          orElse: () => _emptyTask(),
                        )
                        .isInCategory(c.id);
                return InkWell(
                  onTap: () => _railTap(store, c),
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2.5,
                    ),
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? col.withValues(alpha: 0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isCurrent ? col : Colors.transparent,
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(c.emoji, style: const TextStyle(fontSize: 15)),
                        const SizedBox(height: 1),
                        Text(
                          catLabel(c),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 8.6,
                            height: 1.1,
                            fontWeight: FontWeight.w600,
                            color: isCurrent ? ct(col) : p.inkSoft,
                          ),
                        ),
                        if (count > 0)
                          Container(
                            margin: const EdgeInsets.only(top: 2),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 0.5,
                            ),
                            decoration: BoxDecoration(
                              color: col.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$count',
                              style: TextStyle(
                                fontSize: 8.5,
                                color: ct(col),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // ▼ — scroll the category rail down
          _railArrow(
            icon: Icons.keyboard_arrow_down,
            enabled: _railCanDown,
            tooltip: context.tr('scroll_down'),
            onTap: () => _nudge(_railScroll, 110),
          ),
          // Bottom of the left rail: add a new menu/tab.
          const Divider(height: 1),
          InkWell(
            onTap: () => _addTabDialog(context, store),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
              child: Column(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: p.indigo.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: p.indigo.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Icon(Icons.add, size: 15, color: p.indigo),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    context.tr('add_menu'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 8.6,
                      height: 1.1,
                      fontWeight: FontWeight.w700,
                      color: p.indigo,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Task _emptyTask() => Task(id: '_', title: '', categoryId: '');

  /// Small ▲ ▼ arrow used by the vertical category rail.
  Widget _railArrow({
    required IconData icon,
    required bool enabled,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: 22,
          width: double.infinity,
          child: Icon(
            icon,
            size: 18,
            color: enabled ? p.indigo : p.inkSoft.withValues(alpha: 0.28),
          ),
        ),
      ),
    );
  }

  void _railTap(Store store, Category c) {
    if (_selectedTaskId != null) {
      final t = store.tasks.firstWhere(
        (x) => x.id == _selectedTaskId,
        orElse: () => _emptyTask(),
      );
      if (t.id != '_') {
        store.moveTask(t, c.id);
        setState(() => _selectedTaskId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('moved_to',
                args: {'title': t.title, 'category': catLabel(c)})),
            duration: const Duration(seconds: 1),
          ),
        );
        return;
      }
    }
    // No task selected → behave like a filter tab.
    setState(() => _topTab = c.id);
  }

  Future<void> _confirmDelete(Store store, Task t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('delete_task_q')),
        content: Text(context.tr('will_be_removed', args: {'title': t.title})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Delete',
              style: TextStyle(color: p.danger),
            ),
          ),
        ],
      ),
    );
    if (ok == true) store.deleteTask(t);
  }

  Future<void> _openEditor() async {
    final store = context.read<Store>();
    final result = await Navigator.push<Task>(
      context,
      MaterialPageRoute(
        builder: (_) => TaskEditorScreen(
          initialCategoryId: _topTab == 'all'
              ? store.enabledCategories.first.id
              : _topTab,
        ),
      ),
    );
    if (result != null) {
      await store.saveTask(result);
      await _maybeAutoCalendar(store, result);
    }
  }

  /// In 'auto' calendar mode, push a freshly created task to Google Calendar.
  Future<void> _maybeAutoCalendar(Store store, Task t) async {
    if (store.calendarMode != 'auto') return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await CalendarService.addToCalendar(context, t);
    if (ok && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(context.tr('calendar_auto_sent')),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _editTask(Store store, Task t) async {
    final result = await Navigator.push<Task>(
      context,
      MaterialPageRoute(builder: (_) => TaskEditorScreen(task: t)),
    );
    if (result != null) await store.saveTask(result);
  }

  void _showTaskMenu(Store store, Task t) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                t.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.edit_outlined, size: 20),
              title: Text(context.tr('edit_task'), style: const TextStyle(fontSize: 13.5)),
              onTap: () {
                Navigator.pop(context);
                _editTask(store, t);
              },
            ),
            if (store.calendarEnabled)
              ListTile(
                leading: const Icon(Icons.event_available_outlined, size: 20),
                title: Text(
                  context.tr('add_to_calendar'),
                  style: const TextStyle(fontSize: 13.5),
                ),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final failMsg = context.tr('cannot_open_calendar');
                  Navigator.pop(context);
                  final ok = await CalendarService.addToCalendar(context, t);
                  if (!ok) {
                    messenger.showSnackBar(SnackBar(content: Text(failMsg)));
                  }
                },
              ),
            ListTile(
              leading: Icon(
                t.completed ? Icons.undo : Icons.check_circle_outline,
                size: 20,
              ),
              title: Text(
                t.completed ? context.tr('reopen_task') : context.tr('mark_complete'),
                style: const TextStyle(fontSize: 13.5),
              ),
              onTap: () {
                Navigator.pop(context);
                store.toggleComplete(t);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                size: 20,
                color: p.danger,
              ),
              title: Text(
                'Delete',
                style: TextStyle(fontSize: 13.5, color: p.danger),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(store, t);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

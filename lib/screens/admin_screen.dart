import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';
import 'report_screen.dart';

/// Master-only administration console.
/// View every user's data, inspect / reset / change / delete passwords,
/// delete users, and launch the multi-user reporting output.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    if (!store.isMaster) {
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('master_admin'))),
        body: Center(
          child: Text(
            context.tr('admin_only'),
            style: TextStyle(fontSize: 13, color: p.inkSoft),
          ),
        ),
      );
    }
    final users = store.allUsers;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('master_console')),
        actions: [
          IconButton(
            tooltip: context.tr('user_reports'),
            icon: const Icon(Icons.summarize_outlined, size: 21),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReportScreen()),
            ),
          ),
          IconButton(
            tooltip: context.tr('create_user'),
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 21),
            onPressed: () => _createUser(context, store),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _masterHeader(context, store),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: users.length,
                itemBuilder: (_, i) => _userCard(context, store, users[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _masterHeader(BuildContext context, Store store) {
    return Container(
      width: double.infinity,
      color: p.indigo.withValues(alpha: 0.06),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('master_account'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: p.indigo,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            context.tr('n_ids_tasks', args: {
              'ids': '${store.allUsers.length}',
              'tasks': '${store.allTaskTotal()}',
            }),
            style: TextStyle(fontSize: 11.5, color: p.inkSoft),
          ),
          const SizedBox(height: 8),
          RadioGroup<bool>(
            groupValue: store.masterViewingAll,
            onChanged: (v) => store.setMasterViewingAll(v ?? false),
            child: Column(
              children: [
                RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: false,
                  activeColor: p.indigo,
                  title: Text(
                    context.tr('view_own'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: true,
                  activeColor: p.indigo,
                  title: Text(
                    context.tr('view_all'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _userCard(BuildContext context, Store store, User u) {
    final tasks = store.tasksForOwner(u.id);
    final open = tasks.where((t) => !t.completed).length;
    final done = tasks.where((t) => t.completed).length;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (u.isMaster ? p.indigo : p.teal)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    u.isMaster
                        ? Icons.workspace_premium_outlined
                        : Icons.person_outline,
                    size: 18,
                    color: u.isMaster ? p.indigo : p.teal,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            u.id,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (u.isMaster)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: p.indigo.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                'MASTER',
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                  color: p.indigo,
                                ),
                              ),
                            ),
                          if (!u.enabled)
                            Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Text(
                                context.tr('disabled'),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: p.danger,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Text(
                        '${u.displayName.isEmpty ? "—" : u.displayName} · '
                        '${context.tr('open_done', args: {'open': '$open', 'done': '$done'})}',
                        style: TextStyle(
                          fontSize: 11,
                          color: p.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: context.tr('view_data'),
                  icon: Icon(
                    Icons.list_alt_outlined,
                    size: 19,
                    color: p.indigo,
                  ),
                  onPressed: () => _viewUserData(context, store, u),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _miniBtn(
                    context.tr('show_password'),
                    Icons.visibility_outlined,
                    () => _showPassword(context, store, u),
                  ),
                  _miniBtn(
                    context.tr('change'),
                    Icons.edit_outlined,
                    () => _changePassword(context, store, u),
                  ),
                  _miniBtn(
                    context.tr('reset_pw'),
                    Icons.restart_alt,
                    () => _resetPassword(context, store, u),
                  ),
                  if (!u.isMaster)
                    _miniBtn(
                      context.tr('delete_id'),
                      Icons.delete_outline,
                      () => _deleteUser(context, store, u),
                      danger: true,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniBtn(
    String label,
    IconData icon,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    final col = danger ? p.danger : p.inkSoft;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 14, color: col),
      label: Text(label, style: TextStyle(fontSize: 10.5, color: col)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: BorderSide(color: danger ? p.danger : p.line),
      ),
    );
  }

  void _showPassword(BuildContext context, Store store, User u) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('password_for', args: {'id': u.id})),
        content: SelectableText(
          u.password,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('close')),
          ),
        ],
      ),
    );
  }

  void _changePassword(BuildContext context, Store store, User u) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('change_pw_for', args: {'id': u.id})),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(hintText: context.tr('new_pw_hint')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              if (ctrl.text.length >= 4) {
                store.setUserPassword(u.id, ctrl.text);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('pw_changed', args: {'id': u.id}))),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('min_4'))),
                );
              }
            },
            child: Text(context.tr('save')),
          ),
        ],
      ),
    );
  }

  void _resetPassword(BuildContext context, Store store, User u) async {
    final def = await store.resetUserPassword(u.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('pw_reset_to', args: {'id': u.id, 'pw': def}))),
    );
  }

  void _deleteUser(BuildContext context, Store store, User u) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('delete_id_q', args: {'id': u.id})),
        content: Text(context.tr('delete_id_msg')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              store.deleteUser(u.id);
              Navigator.pop(context);
            },
            child: Text(
              context.tr('delete'),
              style: TextStyle(color: p.danger),
            ),
          ),
        ],
      ),
    );
  }

  void _viewUserData(BuildContext context, Store store, User u) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UserDataScreen(userId: u.id)),
    );
  }

  void _createUser(BuildContext context, Store store) {
    final idCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('create_id')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idCtrl,
              decoration: InputDecoration(hintText: context.tr('new_id_hint')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pwCtrl,
              obscureText: true,
              decoration: InputDecoration(hintText: context.tr('password_min')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                hintText: context.tr('display_name'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () async {
              final err = await store.addUser(
                idCtrl.text,
                pwCtrl.text,
                displayName: nameCtrl.text,
              );
              if (!ctx.mounted) return;
              if (err == null) {
                Navigator.pop(ctx);
              } else {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(SnackBar(content: Text(err)));
              }
            },
            child: Text(context.tr('create')),
          ),
        ],
      ),
    );
  }
}

/// Read-only view of a specific user's tasks, grouped by tab.
class UserDataScreen extends StatelessWidget {
  final String userId;
  const UserDataScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final u = store.userById(userId);
    final cats = store.categoriesFor(userId);
    final tasks = store.tasksForOwner(userId);

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('data_for', args: {'id': u?.id ?? userId}))),
      body: SafeArea(
        child: tasks.isEmpty
            ? Center(
                child: Text(
                  context.tr('no_tasks_user'),
                  style: TextStyle(fontSize: 13, color: p.inkSoft),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final c in cats)
                    if (tasks.any((t) => t.categoryId == c.id))
                      _group(
                        c,
                        tasks.where((t) => t.categoryId == c.id).toList(),
                      ),
                ],
              ),
      ),
    );
  }

  Widget _group(Category c, List<Task> items) {
    final col = Color(c.colorValue);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: col.withValues(alpha: 0.10),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
            ),
            child: Text(
              '${c.emoji} ${catLabel(c)}  (${items.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: ct(col),
              ),
            ),
          ),
          ...items.map(
            (t) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    t.completed
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 14,
                    color: t.completed ? p.teal : p.inkSoft,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.title,
                      style: TextStyle(
                        fontSize: 12.5,
                        decoration: t.completed
                            ? TextDecoration.lineThrough
                            : null,
                        color: t.completed ? p.inkSoft : p.ink,
                      ),
                    ),
                  ),
                  if (t.amount != null)
                    Text(
                      '₩${t.amount!.toStringAsFixed(0)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: p.inkSoft,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

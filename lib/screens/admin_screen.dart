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
            context.tr(
              'n_ids_tasks',
              args: {
                'ids': '${store.allUsers.length}',
                'tasks': '${store.allTaskTotal()}',
              },
            ),
            style: TextStyle(fontSize: 11.5, color: p.inkSoft),
          ),
          const SizedBox(height: 8),
          // ## 명부에서 불러오기
          //
          // 마스터가 "모든 아이디"를 관리하려면 그 목록이 **로컬에 있어야**
          // 합니다. 그런데 계정은 각자의 기기에서 만들어집니다. 그래서
          // 새 기기의 마스터는 자기 계정 하나만 보는 상태로 시작합니다.
          //
          // 명부(ACCREGISTRY…)는 모든 기기가 읽는 유일한 공통 문서이므로,
          // 여기서 한 번 당겨오면 전체 목록이 채워집니다. 자동으로 하지 않는
          // 이유: 이 화면을 열 때마다 서버를 치면 지하주차장에서 스피너만
          // 보게 됩니다. 명시적 버튼이면 실패해도 사용자가 원인을 압니다.
          OutlinedButton.icon(
            onPressed: () => _pullRegistry(context, store),
            icon: const Icon(Icons.cloud_download_outlined, size: 15),
            label: Text(
              context.tr('admin_pull_registry'),
              style: const TextStyle(fontSize: 11.5),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.indigo,
              side: BorderSide(color: p.line),
              padding: const EdgeInsets.symmetric(vertical: 8),
              minimumSize: const Size(double.infinity, 34),
            ),
          ),
          const SizedBox(height: 10),
          // ## 보안 경고 — 숨기지 않고 화면에 적습니다
          //
          // 이 앱은 금고가 아닙니다. 마스터가 모든 비밀번호를 볼 수 있게
          // 만들었으므로, 그 사실을 관리자 화면 맨 위에 둡니다. 코드 주석에만
          // 적으면 정작 결정한 사람이 안 읽습니다.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: p.danger.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.danger.withValues(alpha: 0.25)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 14, color: p.danger),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    context.tr('admin_plaintext_warning'),
                    style: TextStyle(
                      fontSize: 10.5,
                      color: p.danger,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
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

  /// 명부(ACCREGISTRY…)에서 전체 계정 목록을 당겨옵니다.
  ///
  /// ## 왜 필요한가
  /// 계정은 각자의 기기에서 만들어집니다. 새 기기의 마스터는 자기 계정
  /// 하나만 들고 시작하므로, 이걸 하지 않으면 "아이디별 관리" 화면에
  /// 자기 자신만 보입니다. 사용자는 그걸 보고 "다른 사람 계정이 사라졌다"고
  /// 생각합니다.
  ///
  /// ## 실패를 숨기지 않습니다
  /// 서버가 안 닿으면 "0건"이 아니라 **이유**를 보여줍니다. 0건과 실패는
  /// 다른 사실이고, 둘을 같은 화면으로 보여주면 사용자는 계정이 지워졌다고
  /// 믿게 됩니다.
  Future<void> _pullRegistry(BuildContext context, Store store) async {
    final messenger = ScaffoldMessenger.of(context);
    final ko = store.language != 'en';
    // 버튼을 누르자마자 "가져오는 중"을 보여줍니다. 서버 왕복이 2초를 넘으면
    // 아무 반응 없는 버튼은 두 번 눌리게 됩니다.
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 30),
        content: Text(ko ? '명부를 불러오는 중…' : 'Loading the registry…'),
      ),
    );
    final added = await store.importAccountsFromRegistry();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          added == null
              ? (ko
                    ? '명부에 연결하지 못했습니다. 설정에서 동기화 주소를 확인하세요.'
                    : 'Could not reach the registry. Check the sync address in Settings.')
              : (ko
                    ? '$added개 계정을 명부에서 가져왔습니다'
                    : 'Imported $added account(s) from the registry'),
        ),
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
                    color: (u.isMaster ? p.indigo : p.teal).withValues(
                      alpha: 0.14,
                    ),
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
                                style: TextStyle(fontSize: 10, color: p.danger),
                              ),
                            ),
                        ],
                      ),
                      Text(
                        '${u.displayName.isEmpty ? "—" : u.displayName} · '
                        '${context.tr('open_done', args: {'open': '$open', 'done': '$done'})}',
                        style: TextStyle(fontSize: 11, color: p.inkSoft),
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
                      // ## deleteUser → purgeUserCompletely
                      //
                      // 예전에는 퇴역 표시만 했습니다. 그래서 마스터가 지운
                      // 계정이 다른 기기의 명부에서 다시 나타났습니다 —
                      // "지웠는데 왜 또 있지?" 의 정체입니다.
                      //
                      // 지시가 "삭제"이므로 명부에서도 지웁니다. 대신 확인
                      // 문구에 **무엇이 지워지는지** 적습니다.
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

  /// 비밀번호 조회.
  ///
  /// ## 2026-11-23 — 한 곳이 아니라 두 곳을 봅니다
  ///
  /// 예전에는 로컬 `u.password` 만 보여줬습니다. 그런데 그 계정을 **한 번도
  /// 이 기기에서 로그인하지 않았다면** 그 값은 무작위 자리표시자(64자)입니다.
  /// 사용자는 그걸 보고 "비밀번호가 이상하게 바뀌었다"고 생각합니다.
  ///
  /// 진짜 값은 명부의 `pwPlain` 에 있습니다. 그래서 둘 다 보여주고, 어느
  /// 쪽이 진짜인지 화면에서 구분합니다.
  Future<void> _showPassword(
    BuildContext context,
    Store store,
    User u,
  ) async {
    final ko = store.language != 'en';
    final localIsPlaceholder = u.password.length == 64 &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(u.password);

    // 명부에서 최신 평문을 가져옵니다. 실패해도 로컬 값은 보여줍니다 —
    // 서버가 죽었다고 마스터가 아무것도 못 보면 안 됩니다.
    String? registryPlain;
    try {
      final rows = await store.readAccountRegistry();
      final row = rows[u.id];
      final p = row?['pwPlain'];
      if (p is String && p.isNotEmpty) registryPlain = p;
    } catch (_) {
      registryPlain = null;
    }

    final shown = registryPlain ??
        (localIsPlaceholder ? null : u.password);

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('password_for', args: {'id': u.id})),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (shown == null) ...[
              Text(
                ko
                    ? '이 기기에는 비밀번호가 없습니다.\n'
                          '이 계정으로 이 기기에서 로그인한 적이 없고, 명부에도 값이 없습니다.'
                    : 'No password on this device.\n'
                          'This account never signed in here, and the registry has no value.',
                style: TextStyle(fontSize: 12, color: p.ink, height: 1.6),
              ),
              const SizedBox(height: 10),
              Text(
                ko
                    ? '「변경」으로 새 비밀번호를 정해 주세요.'
                    : 'Use “Change” to set a new password.',
                style: TextStyle(fontSize: 11, color: p.inkSoft),
              ),
            ] else
              SelectableText(
                shown,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            if (shown != null && registryPlain == null) ...[
              const SizedBox(height: 10),
              Text(
                ko
                    ? '이 기기에 저장된 값입니다 (명부에 닿지 못했습니다)'
                    : 'Stored on this device (registry not reachable)',
                style: TextStyle(fontSize: 10.5, color: p.inkSoft),
              ),
            ],
          ],
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
                  SnackBar(
                    content: Text(context.tr('pw_changed', args: {'id': u.id})),
                  ),
                );
              } else {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(context.tr('min_4'))));
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
      SnackBar(
        content: Text(context.tr('pw_reset_to', args: {'id': u.id, 'pw': def})),
      ),
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
              // 완전 삭제 — 명부에서도 지워 목록에 다시 나타나지 않게 합니다.
              store.purgeUserCompletely(u.id);
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
              decoration: InputDecoration(hintText: context.tr('display_name')),
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
      appBar: AppBar(
        title: Text(context.tr('data_for', args: {'id': u?.id ?? userId})),
      ),
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
                      style: TextStyle(fontSize: 11, color: p.inkSoft),
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../services/calendar_service.dart';
import '../services/session_service.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';
import '../widgets/notebook_ui.dart';
import '../widgets/design_quick_picker.dart';
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
      // ## 시딩 시점 (2026-11-25)
      // 이전에는 화면이 뜨자마자 무조건 시딩했습니다. 그런데 화면은 서버보다
      // 먼저 뜹니다. 두 기기가 거의 동시에 로그인하면 둘 다 "기본 일정이
      // 없네" 하고 각자 만들고, 서로 다른 id 라서 병합되지 않고 쌓였습니다.
      // 이제는 store 가 "서버를 봤거나 동기화를 쓰지 않는다"고 확인해 준
      // 경우에만 시딩합니다. 서버를 아직 못 봤으면 동기화가 끝날 때 store 가
      // onSeededRetry 로 다시 불러 줍니다. 기존 일정은 건드리지 않습니다.
      await store.seedDefaultsOnceAfterSync();
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
                  : context.tr(
                      'signed_in',
                      args: {
                        'id':
                            '${store.currentUserId}${store.isMaster ? " (${context.tr('master')})" : ""}',
                      },
                    ),
              style: TextStyle(
                fontSize: 10.5,
                color: p.inkSoft,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          // 테마를 여기 두는 이유: 스킨 설정 화면은 앱을 자기 화면으로 덮는다.
          // 디자인은 '비교'의 문제인데, 고르고 → 닫고 → 보고 → 다시 열고 하는
          // 왕복은 비교 자체를 불가능하게 만든다. 여기서는 목록이 그대로 보이는
          // 상태에서 즉시 적용되므로, 미리보기가 아니라 그 자체가 결과다.
          const DesignQuickPicker(),
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
        label: Text(
          context.tr('add_task'),
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }

  // ---------------- Top filter tabs ----------------
  //
  // Minimal mode: the strip loses ~14px of height, the chips lose their
  // individual borders (a row of twelve outlined boxes is a wall of frames, not
  // a tab strip), and the selected chip is marked by fill alone. The surface is
  // [chromeSurface] rather than `p.card` so it can never be a white band on a
  // dark page.
  Widget _topTabBar(List<Category> topCats) {
    final minimal = minimalChrome;
    return Container(
      height: minimal ? 30 : 44,
      decoration: BoxDecoration(
        color: minimal ? chromeSurface : p.card,
        border: minimal
            ? Border(bottom: BorderSide(color: chromeLine))
            : null,
      ),
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
          // ＋ 할 일 추가 — 상단에도 둔다 (하단 FAB 은 그대로 유지).
          //
          // ## 왜 둘 다인가
          // 하단 FAB 은 "지금 목록에 한 줄 더" 라는 뜻이고, 손이 닿는 자리에
          // 있어 편하다. 그런데 목록을 스크롤해 올라가 있으면 시야에서 멀고,
          // PC 브라우저처럼 넓은 화면에서는 화면 반대편 구석에 있다.
          // 목록을 읽는 눈은 위에 머무르므로, 추가 버튼도 거기 있어야 한다.
          // 둘은 서로를 대체하지 않는다 — 하나는 근접성, 하나는 시야.
          _addTaskButton(),
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

  /// The "할 일 추가" button pinned at the right of the tab bar.
  ///
  /// ## 왜 하단 FAB 을 없애지 않고 하나 더 두는가
  /// 하단 FAB 은 *손*을 위한 자리다. 엄지가 닿고, 목록 맨 아래를 보고 있을 때
  /// 바로 옆에 있다. 반대로 목록을 **읽는 눈**은 위쪽에 머문다. 목록이 길어져
  /// 스크롤을 올려 놓으면 FAB 은 시야 밖 먼 구석이고, 데스크톱 브라우저처럼
  /// 넓은 화면에서는 커서와 화면 반대편 끝이다. 그때 사람은 "추가하고 싶다"는
  /// 생각과 "버튼을 찾는" 동작을 따로 해야 한다.
  /// 그래서 둘은 서로의 대체물이 아니다 — 하나는 근접성, 하나는 시야다.
  ///
  /// ## 왜 [_addItemButton] 과 똑같이 생기면 안 되는가
  /// 바로 옆에 똑같은 인디고 덩어리를 붙이면 두 버튼이 **하나의 넓은 버튼**으로
  /// 읽힌다. 이 버튼은 채우지 않고 테두리만 인디고로 준다(tonal). 자주 쓰는
  /// 동작이지만, 옆의 '항목추가'와는 다른 종류의 일이라는 것이 한눈에 보여야 한다.
  ///
  /// ## 좁은 화면
  /// 480px 미만에서는 글자를 빼고 아이콘만 남긴다. 상단 바는 탭 목록이 주인공인
  /// 곳이고, 버튼 두 개가 탭을 밀어내면 본말이 뒤집힌다. 뜻은 Tooltip 이 지고,
  /// 하단 FAB 이 글자까지 달고 같은 일을 한다.
  Widget _addTaskButton() {
    final minimal = minimalChrome;
    final narrow = MediaQuery.sizeOf(context).width < 480;
    final label = context.tr('add_task');

    final button = InkWell(
      onTap: () => _openEditor(),
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: narrow ? 7 : 9,
          vertical: minimal ? 5 : 6,
        ),
        decoration: BoxDecoration(
          color: p.indigo.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: p.indigo.withValues(alpha: 0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 14, color: p.indigo),
            if (!narrow) ...[
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: p.indigo,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(message: label, child: button),
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
    final minimal = minimalChrome;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: minimal ? 3 : 7, horizontal: 3),
      child: GestureDetector(
        onTap: () => setState(() => _topTab = id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.symmetric(horizontal: minimal ? 9 : 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? col.withValues(alpha: minimal ? 0.18 : 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(minimal ? 6 : 8),
            // 미니멀에서는 테두리를 없앤다. 열두 개짜리 탭 줄에 상자를 열두 개
            // 그리면 '탭'이 아니라 '액자 벽'이 된다. 선택은 채움으로만 말한다.
            border: minimal
                ? null
                : Border.all(
                    color: selected ? col.withValues(alpha: 0.5) : p.line,
                  ),
          ),
          child: Text(
            '$emoji $label',
            maxLines: 1,
            style: TextStyle(
              fontSize: minimal ? 11.5 : 12,
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
              : Column(
                  children: [
                    // 표 테마에서만 머리글을 그린다. 열이 맞아도 이름이 없으면
                    // 그냥 흩어진 글자다. 머리글이 열을 '열'로 만든다.
                    if (sx.isTable) TaskRow.tableHeader(context),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: 90),
                        itemCount: active.length,
                        itemBuilder: (_, i) {
                          final t = active[i];
                          final cat =
                              store.categoryById(t.categoryId) ?? cats.first;
                          return _wrapSelectable(
                            t,
                            GestureDetector(
                              onLongPress: () => _showTaskMenu(store, t),
                              child: TaskRow(
                                task: t,
                                category: cat,
                                assignTargets: cats,
                                stripeIndex: i,
                                onToggle: () => store.toggleComplete(t),
                                onTap: () => setState(
                                  () => _selectedTaskId =
                                      _selectedTaskId == t.id ? null : t.id,
                                ),
                                onDelete: () => _confirmDelete(store, t),
                                onAssign: (c) =>
                                    store.toggleCategoryIn(t, c.id),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        // ---------------- Completed section ----------------
        //
        // 완료 구역도 밀도를 따라간다. 목록이 표로 바뀌었는데 이 구역만
        // 10px 여백에 12.5px 제목으로 남으면, 화면이 두 개의 앱처럼 보인다.
        Container(
          decoration: BoxDecoration(
            color: chromeSurface,
            border: Border(top: BorderSide(color: chromeLine)),
          ),
          child: Column(
            children: [
              InkWell(
                onTap: () =>
                    setState(() => _completedExpanded = !_completedExpanded),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: sx.isTable ? 4 : 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: sx.isTable ? 13 : 16,
                        color: p.inkSoft,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        context.tr('completed'),
                        style: TextStyle(
                          fontSize: sx.isTable ? 11 : 12.5,
                          fontWeight: FontWeight.w700,
                          color: p.inkSoft,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '(${done.length})',
                        style: TextStyle(fontSize: 11.5, color: p.inkSoft),
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
                            style: TextStyle(fontSize: 11.5, color: p.inkSoft),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: done.length,
                          itemBuilder: (_, i) {
                            final t = done[i];
                            final cat =
                                store.categoryById(t.categoryId) ?? cats.first;
                            return _completedRow(store, t, cat, i);
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
          Text('($count)', style: TextStyle(fontSize: 11.5, color: p.inkSoft)),
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

  /// A completed task, drawn with the SAME row renderer as the active list.
  ///
  /// ## 두 가지 실수가 여기 있었고, 둘 다 고쳤다
  ///
  /// 1) 배경이 `Color(0xFFF7F8FC)` 로 **하드코딩**돼 있었다. 팔레트를 읽지
  ///    않으니 다크모드에서도 이 줄만 순백으로 남고, 밝은 바탕 위의 밝은
  ///    글자가 됐다. 이제 `p.card`/`p.line` 을 쓴다.
  ///
  /// 2) 완료된 일은 별도의 작은 위젯으로 그려서, 고밀도 테마를 골라도 이
  ///    구역만 예전 모양 그대로였다. 같은 데이터를 두 가지 방식으로 그리면
  ///    반드시 한쪽만 고치는 날이 온다 — 오늘이 그 날이었다.
  ///
  /// 그래서 `TaskRow` 를 그대로 쓴다. 완료 표시는 이미 `task.completed` 를
  /// 읽어 체크 + 취소선으로 그리므로, 테마가 바뀌면 완료 구역도 같이 바뀐다.
  Widget _completedRow(Store store, Task t, Category cat, int index) {
    return GestureDetector(
      onLongPress: () => _showTaskMenu(store, t),
      child: TaskRow(
        task: t,
        category: cat,
        assignTargets: store.enabledCategories,
        stripeIndex: index,
        onToggle: () => store.toggleComplete(t),
        onTap: () => store.toggleComplete(t),
        onDelete: () => _confirmDelete(store, t),
        onAssign: (c) => store.toggleCategoryIn(t, c.id),
      ),
    );
  }

  // ---------------- Right rail (instant categorisation) ----------------
  //
  // ## Minimal mode
  // The rail used to be a 78px column of emoji + two-line Korean label + count
  // badge for every category. It is a *shortcut*, not a reading surface: you
  // glance at it to hit a target, and the list on the left pays for its width
  // on a phone.
  //
  // In minimal mode it becomes a 40px strip of coloured dots with the category
  // colour underneath — the colour is the identity you actually aim by, and the
  // name was mostly being re-read from the tab strip above. The full name is
  // one long-press (or hover) away via tooltip, so nothing is lost that was
  // being used, and the list gains ~38px of width.
  Widget _rightRail(Store store, List<Category> cats) {
    final minimal = minimalChrome;
    return Container(
      // 40px → 50px. 색 막대만으로는 어느 분류인지 알 수 없어서 이름(7.5px,
      // 두 글자)을 되살렸고, 두 글자가 잘리지 않을 최소 폭이 필요하다.
      // 78px(전체 이름)보다는 훨씬 좁으면서, 정체불명의 색 줄은 아니게.
      width: minimal ? 50 : 78,
      // chromeSurface is derived from ink-over-bg, so it cannot end up a white
      // slab on a dark page the way `p.card` could.
      decoration: BoxDecoration(
        color: minimal ? chromeSurface : p.card,
        border: Border(left: BorderSide(color: chromeLine)),
      ),
      child: Column(
        children: [
          if (!minimal)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Text(
                _selectedTaskId == null
                    ? context.tr('select_task_then_tab')
                    : context.tr('assign_to'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9.5, color: p.inkSoft, height: 1.3),
              ),
            ),
          if (!minimal) const Divider(height: 1),
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
              padding: EdgeInsets.symmetric(vertical: minimal ? 2 : 4),
              itemCount: cats.length,
              itemBuilder: (_, i) {
                final c = cats[i];
                final col = Color(c.colorValue);
                final count = store.taskCountFor(c.id);
                final isCurrent =
                    _selectedTaskId != null &&
                    store.tasks
                        .firstWhere(
                          (t) => t.id == _selectedTaskId,
                          orElse: () => _emptyTask(),
                        )
                        .isInCategory(c.id);
                if (minimal) return _railDot(c, col, count, isCurrent);
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

  /// One category in the minimal rail.
  ///
  /// ## 이름을 빼면 안 됐다
  /// 첫 시도에서 색 막대만 남겼더니, 화면에는 정체불명의 색 줄 14개가
  /// 늘어섰다. "빨강이 은행업무였나, 금전출납이었나"를 매번 기억해야 하고,
  /// 기억은 다음 화면에서 틀린다. **색은 이름을 대신하지 못한다.**
  ///
  /// ## 색 막대도 이모지를 대신하지 못한다
  /// 이름을 되살린 뒤에도 맨 앞의 색 막대는 여전히 자리만 차지했다.
  /// 분류 14개에 색 14개를 배정하면 외워야 할 것이 하나 더 늘 뿐이고,
  /// 정작 눈에 먼저 들어와야 하는 건 정보다. 그래서 막대를 걷어내고
  /// 이모지(🏦 🎂 ⚜️)를 세웠다 — 그림은 읽지 않아도 되고, 글자는
  /// 읽으면 되고, 색은 **현재 선택 표시에만** 조용히 쓴다.
  ///
  /// 밀도는 글자를 없애서 만드는 게 아니라, 같은 글자를 더 작은 상자에
  /// 넣어서 만든다. 그래서 이름은 그대로 둔다 — 7.5px, 두 글자까지.
  /// (한글 두 글자면 '은행/금전/개인/생일'처럼 실제로 구분된다.)
  Widget _railDot(Category c, Color col, int count, bool isCurrent) {
    final name = catLabel(c);
    final short = name.characters.take(2).toString();
    return Tooltip(
      message: '${c.emoji} $name${count > 0 ? '  ($count)' : ''}',
      waitDuration: const Duration(milliseconds: 250),
      child: InkWell(
        onTap: () => _railTap(context.read<Store>(), c),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color:
                isCurrent ? p.indigo.withValues(alpha: 0.13) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: isCurrent
                  ? p.indigo.withValues(alpha: 0.55)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 이모지가 정체성이다. 색 막대를 없앤 자리이고, 이제
                  // "무슨 분류인지"가 색 암기 없이 바로 읽힌다.
                  if (c.emoji.trim().isNotEmpty)
                    Text(
                      c.emoji,
                      style: const TextStyle(fontSize: 11, height: 1.0),
                    )
                  else
                    // 이모지 없는 사용자 분류: 작은 점 하나로 칸이 비는 것을 막는다.
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: col,
                        shape: BoxShape.circle,
                      ),
                    ),
                  if (count > 0) ...[
                    const SizedBox(width: 1.5),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 7.5,
                        height: 1.0,
                        fontWeight: FontWeight.w700,
                        color: p.inkSoft,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 1.5),
              Text(
                short,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 7.5,
                  height: 1.0,
                  letterSpacing: -0.2,
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  color: isCurrent ? ct(col) : p.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
            content: Text(
              context.tr(
                'moved_to',
                args: {'title': t.title, 'category': catLabel(c)},
              ),
            ),
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
            child: Text('Delete', style: TextStyle(color: p.danger)),
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
              title: Text(
                context.tr('edit_task'),
                style: const TextStyle(fontSize: 13.5),
              ),
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
                t.completed
                    ? context.tr('reopen_task')
                    : context.tr('mark_complete'),
                style: const TextStyle(fontSize: 13.5),
              ),
              onTap: () {
                Navigator.pop(context);
                store.toggleComplete(t);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, size: 20, color: p.danger),
              title: Text(
                // 하드코딩된 'Delete' 였다. 영어 UI 에서는 티가 안 났지만
                // 한국어 사용자에게는 이 메뉴 한 줄만 영어로 남는다.
                context.tr('delete'),
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../services/session_service.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';
import 'guide_screen.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _idCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _pwFocus = FocusNode();
  final _session = SessionService();
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  /// Which chip is currently signing in (so only that one shows a spinner).
  String? _busyId;

  @override
  void dispose() {
    _idCtrl.dispose();
    _pwCtrl.dispose();
    _pwFocus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    await _loginWith(_idCtrl.text.trim(), _pwCtrl.text);
  }

  /// The one shared sign-in path.
  ///
  /// Both the form and the saved-account chips go through here so they cannot
  /// drift apart: one place decides what success means, what is remembered, and
  /// where the user lands.
  Future<bool> _loginWith(String id, String pw) async {
    if (id.isEmpty || pw.isEmpty) return false;
    final store = context.read<Store>();
    setState(() {
      _loading = true;
      _error = null;
      _busyId = id;
    });
    await Future.delayed(const Duration(milliseconds: 250));

    final ok = await store.authenticate(id, pw);
    if (!mounted) return false;
    if (ok) {
      await store.rememberAccount(id);
      await _session.login(store.currentUserId);
      if (!mounted) return false;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
      return true;
    }
    setState(() {
      _loading = false;
      _busyId = null;
      _error = context.tr('incorrect_login');
    });
    return false;
  }

  /// Tapping a remembered account.
  ///
  /// With a password saved on this device it signs in immediately — that is the
  /// whole point of the chip. Without one it fills the id and drops the cursor
  /// in the password field, which is still faster than typing the id on a phone.
  Future<void> _quickLogin(User u) async {
    final store = context.read<Store>();
    final pw = store.savedPasswordFor(u.id);
    if (pw == null || pw.isEmpty) {
      _askForPassword(u);
      return;
    }

    final ok = await _loginWith(u.id, pw);
    if (ok || !mounted) return;

    // The saved password was refused. The most likely reason is not a typo —
    // nobody typed anything — it is that the password was changed on another
    // device and this copy went stale. Keeping it would produce the same dead
    // end every morning, so drop it and ask once. The account stays in the list;
    // only the one-tap part stops working until the next successful sign-in.
    await store.forgetSavedPassword(u.id);
    if (!mounted) return;
    _askForPassword(u);
  }

  /// Puts the user in front of the password field for [u] with the id filled in.
  void _askForPassword(User u) {
    _idCtrl.text = u.id;
    _pwCtrl.clear();
    setState(() {
      _loading = false;
      _busyId = null;
      _error = null;
    });
    _pwFocus.requestFocus();
  }

  Future<void> _forget(User u) async {
    final store = context.read<Store>();
    await store.forgetAccount(u.id);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.tr('forget_account_done'))));
  }

  Future<void> _clearCache() async {
    final store = context.read<Store>();
    await _session.clearCache();
    await store.clearCache();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.tr('cache_cleared'))));
  }

  void _showVersion() {
    final store = context.read<Store>();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('app_version')),
        content: Text(
          '${context.tr('installed_version')}: v${store.appVersion}\n'
          '${context.tr('version_note')}',
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

  void _openSignUp() {
    final idCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.tr('create_id')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idCtrl,
              decoration: InputDecoration(hintText: ctx.tr('new_id_hint')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pwCtrl,
              obscureText: true,
              decoration: InputDecoration(hintText: ctx.tr('password_min')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(hintText: ctx.tr('display_name')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.tr('cancel')),
          ),
          TextButton(
            onPressed: () async {
              final store = context.read<Store>();
              final err = await store.addUser(
                idCtrl.text,
                pwCtrl.text,
                displayName: nameCtrl.text,
              );
              if (!ctx.mounted) return;
              if (err == null) {
                Navigator.pop(ctx);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      context.tr(
                        'id_created',
                        args: {'id': idCtrl.text.trim()},
                      ),
                    ),
                  ),
                );
              } else {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(SnackBar(content: Text(err)));
              }
            },
            child: Text(ctx.tr('create')),
          ),
        ],
      ),
    );
  }

  /// One remembered account.
  ///
  /// The whole row is the tap target — a 40px chip is a cruel thing to aim at
  /// with a thumb. The key icon says whether a tap signs in (key filled) or
  /// merely fills the id and asks for the password (key outline), so the user
  /// is never surprised by what happens next.
  Widget _savedAccountRow(Store store, User u, bool isKo) {
    final hasPw = (store.savedPasswordFor(u.id) ?? '').isNotEmpty;
    final busy = _busyId == u.id;
    final name = u.displayName.trim().isNotEmpty ? u.displayName : u.id;
    final initial = name.characters.first.toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _loading ? null : () => _quickLogin(u),
          onLongPress: () => _confirmForget(u),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.line),
              color: p.indigo.withValues(alpha: 0.03),
            ),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.indigo.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: p.indigo,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: p.ink,
                              ),
                            ),
                          ),
                          if (u.isMaster) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: p.indigo.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isKo ? '대표' : 'MASTER',
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w700,
                                  color: p.indigo,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 1),
                      Text(
                        u.id,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: p.inkSoft),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (busy)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.indigo,
                    ),
                  )
                else
                  Icon(
                    hasPw ? Icons.key_rounded : Icons.key_outlined,
                    size: 17,
                    color: hasPw ? p.indigo : p.inkSoft,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「처음이신가요? 사용 안내」 / 「프로그램 소개」 한 줄.
  ///
  /// OutlinedButton 을 쓰지 않은 이유: 이 버튼은 로그인이 아니라 **옆길**이다.
  /// 같은 테두리·같은 높이로 만들면 로그인 버튼과 형제처럼 보여서, 급한
  /// 사람이 잘못 누른다. 그래서 테두리는 유지하되(누를 수 있다는 신호),
  /// 채움 없이 아이콘 + 글자 + 화살표만 두고 높이를 조금 낮춘다.
  Widget _guideRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: p.line),
            color: p.soft.withValues(alpha: 0.45),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: p.indigo),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 17, color: p.inkSoft),
            ],
          ),
        ),
      ),
    );
  }

  /// Long-press a saved account to remove it from this device.
  void _confirmForget(User u) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.tr('forget_account')),
        content: Text('${u.id}\n\n${ctx.tr('saved_pw_note')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _forget(u);
            },
            child: Text(ctx.tr('delete')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final isKo = store.language != 'en';
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              top: false,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 10),
                        Container(
                          width: 72,
                          height: 72,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.indigo.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(
                            Icons.calendar_month_rounded,
                            size: 38,
                            color: p.indigo,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          isKo ? 'June 스케줄러' : "June's Scheduler",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: p.ink,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          context.tr('sign_in_hint'),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12.5, color: p.inkSoft),
                        ),
                        const SizedBox(height: 30),
                        TextField(
                          controller: _idCtrl,
                          style: const TextStyle(fontSize: 13.5),
                          decoration: InputDecoration(
                            hintText: context.tr('id'),
                            prefixIcon: const Icon(
                              Icons.person_outline,
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _pwCtrl,
                          focusNode: _pwFocus,
                          obscureText: _obscure,
                          style: const TextStyle(fontSize: 13.5),
                          onSubmitted: (_) => _login(),
                          decoration: InputDecoration(
                            hintText: context.tr('password'),
                            prefixIcon: const Icon(
                              Icons.lock_outline,
                              size: 20,
                            ),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                size: 20,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _error!,
                            style: TextStyle(color: p.danger, fontSize: 12),
                          ),
                        ],
                        const SizedBox(height: 22),
                        SizedBox(
                          height: 46,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _login,
                            child: _loading
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: p.card,
                                    ),
                                  )
                                : Text(context.tr('sign_in')),
                          ),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _openSignUp,
                          icon: const Icon(
                            Icons.person_add_alt_1_outlined,
                            size: 17,
                          ),
                          label: Text(
                            context.tr('create_id'),
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: p.indigo,
                            side: BorderSide(color: p.indigo),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),

                        // ---- 처음 오신 분을 위한 두 문 ----
                        //
                        // 새 아이디 만들기 **바로 아래**에 둔다. 이 화면에서
                        // 가장 곤란한 사람은 아이디가 없는 사람이고, 그 사람이
                        // 다음에 품는 질문은 둘 중 하나다: "이거 어떻게 써?"
                        // 또는 "이게 뭐야?". 그 질문이 생기는 자리에 답을 둔다.
                        //
                        // 아래쪽(캐시 삭제 옆)에 두면 안 된다. 거기는 이미
                        // 로그인을 마친 사람이 지나가는 자리고, 정작 필요한
                        // 사람은 거기까지 스크롤하지 않는다.
                        const SizedBox(height: 8),
                        _guideRow(
                          icon: Icons.info_outline_rounded,
                          label: context.tr('guide_new_here'),
                          onTap: () => openGuide(context, GuideKind.howToUse),
                        ),
                        const SizedBox(height: 8),
                        _guideRow(
                          icon: Icons.eco_outlined,
                          label: context.tr('guide_about'),
                          onTap: () => openGuide(context, GuideKind.aboutProgram),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          context.tr('session_kept'),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: p.inkSoft),
                        ),

                        // ---- 이 기기에서 사용한 계정 (빠른 로그인) ----
                        if (store.rememberedAccounts.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          Row(
                            children: [
                              Expanded(
                                child: Container(height: 1, color: p.line),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                child: Text(
                                  context.tr('saved_accounts'),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: p.inkSoft,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Container(height: 1, color: p.line),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          for (final u in store.rememberedAccounts)
                            _savedAccountRow(store, u, isKo),
                          const SizedBox(height: 8),
                          Text(
                            context.tr('saved_pw_note'),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 10, color: p.inkSoft),
                          ),
                        ],

                        const SizedBox(height: 28),
                        const Divider(),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _clearCache,
                                icon: const Icon(
                                  Icons.cleaning_services_outlined,
                                  size: 17,
                                ),
                                label: Text(
                                  context.tr('clear_cache'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: p.inkSoft,
                                  side: BorderSide(color: p.line),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _showVersion,
                                icon: const Icon(Icons.info_outline, size: 17),
                                label: Text(
                                  context.tr('version'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: p.inkSoft,
                                  side: BorderSide(color: p.line),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'v${store.appVersion}',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 10.5, color: p.inkSoft),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/session_service.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _idCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _session = SessionService();
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _idCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final store = context.read<Store>();
    setState(() {
      _loading = true;
      _error = null;
    });
    await Future.delayed(const Duration(milliseconds: 250));

    final ok = await store.authenticate(_idCtrl.text.trim(), _pwCtrl.text);
    if (ok) {
      await _session.login(store.currentUserId);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      setState(() {
        _loading = false;
        _error = context.tr('incorrect_login');
      });
    }
  }

  Future<void> _clearCache() async {
    final store = context.read<Store>();
    await _session.clearCache();
    await store.clearCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('cache_cleared'))),
    );
  }

  void _showVersion() {
    final store = context.read<Store>();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('app_version')),
        content: Text('${context.tr('installed_version')}: v${store.appVersion}\n'
            '${context.tr('version_note')}'),
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
              onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel'))),
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
                      content: Text(context
                          .tr('id_created', args: {'id': idCtrl.text.trim()}))),
                );
              } else {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(err)),
                );
              }
            },
            child: Text(ctx.tr('create')),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
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
                          child: Icon(Icons.calendar_month_rounded,
                              size: 38, color: p.indigo),
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
                      prefixIcon: const Icon(Icons.person_outline, size: 20),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pwCtrl,
                    obscureText: _obscure,
                    style: const TextStyle(fontSize: 13.5),
                    onSubmitted: (_) => _login(),
                    decoration: InputDecoration(
                      hintText: context.tr('password'),
                      prefixIcon: const Icon(Icons.lock_outline, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
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
                                  strokeWidth: 2, color: p.card),
                            )
                          : Text(context.tr('sign_in')),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _openSignUp,
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 17),
                    label: Text(context.tr('create_id'),
                        style: const TextStyle(fontSize: 12.5)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.indigo,
                      side: BorderSide(color: p.indigo),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    context.tr('session_kept'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: p.inkSoft),
                  ),
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _clearCache,
                          icon: const Icon(Icons.cleaning_services_outlined, size: 17),
                          label: Text(context.tr('clear_cache'),
                              style: const TextStyle(fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: p.inkSoft,
                            side: BorderSide(color: p.line),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showVersion,
                          icon: const Icon(Icons.info_outline, size: 17),
                          label: Text(context.tr('version'),
                              style: const TextStyle(fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: p.inkSoft,
                            side: BorderSide(color: p.line),
                            padding: const EdgeInsets.symmetric(vertical: 12),
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

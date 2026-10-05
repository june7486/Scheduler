import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
    } else {
      setState(() {
        _loading = false;
        _error = 'Incorrect ID or password.';
      });
    }
  }

  Future<void> _clearCache() async {
    final store = context.read<Store>();
    await _session.clearCache();
    await store.clearCache();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Cache cleared.')));
  }

  void _showVersion() {
    final store = context.read<Store>();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('App Version'),
        content: Text(
          'Installed version: v${store.appVersion}\n'
          'Version is defined by the stored build date & time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
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
        title: const Text('Create new ID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(
                hintText: 'New ID (login name)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pwCtrl,
              obscureText: true,
              decoration: const InputDecoration(hintText: 'Password (min 4)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                hintText: 'Display name (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
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
                    content: Text('ID "${idCtrl.text.trim()}" created.'),
                  ),
                );
              } else {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(SnackBar(content: Text(err)));
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.indigo.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(
                      Icons.calendar_month_rounded,
                      size: 38,
                      color: AppColors.indigo,
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    "June's Scheduler",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Sign in to continue',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: AppColors.inkSoft),
                  ),
                  const SizedBox(height: 30),
                  TextField(
                    controller: _idCtrl,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: const InputDecoration(
                      hintText: 'ID',
                      prefixIcon: Icon(Icons.person_outline, size: 20),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pwCtrl,
                    obscureText: _obscure,
                    style: const TextStyle(fontSize: 13.5),
                    onSubmitted: (_) => _login(),
                    decoration: InputDecoration(
                      hintText: 'Password',
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
                      style: const TextStyle(
                        color: AppColors.danger,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  SizedBox(
                    height: 46,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _login,
                      child: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Sign in'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _openSignUp,
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 17),
                    label: const Text(
                      'Create a new ID',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.indigo,
                      side: const BorderSide(color: AppColors.indigo),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Each ID keeps its own separate schedule data. '
                    'Session is kept for 1 hour.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: AppColors.inkSoft),
                  ),
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
                          label: const Text(
                            'Clear cache',
                            style: TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.inkSoft,
                            side: const BorderSide(color: AppColors.line),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showVersion,
                          icon: const Icon(Icons.info_outline, size: 17),
                          label: const Text(
                            'Version',
                            style: TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.inkSoft,
                            side: const BorderSide(color: AppColors.line),
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
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppColors.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

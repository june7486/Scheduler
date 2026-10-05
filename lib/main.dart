import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/l10n.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/session_service.dart';
import 'services/store.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = Store();
  await store.init();
  // Sync the static language used by the L10n helper.
  L10n.currentLang = store.language == 'en' ? AppLang.en : AppLang.ko;
  runApp(JuneSchedulerApp(store: store));
}

class JuneSchedulerApp extends StatelessWidget {
  final Store store;
  const JuneSchedulerApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: store,
      child: Consumer<Store>(
        builder: (context, s, _) {
          // Keep the global language in sync with the store.
          L10n.currentLang = s.language == 'en' ? AppLang.en : AppLang.ko;
          return MaterialApp(
            title: s.language == 'en'
                ? "June's Scheduler"
                : 'June 스케줄러',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.build(),
            home: const _Gate(),
          );
        },
      ),
    );
  }
}

/// Decides whether to show login or the home screen based on session state.
class _Gate extends StatefulWidget {
  const _Gate();
  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  bool? _loggedIn;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final session = SessionService();
    final store = context.read<Store>();

    // Version / cache handling: if the stored version is older than the
    // current build version, clear the cache so fresh data is downloaded.
    final installed = await session.installedVersion();
    if (installed == null || installed != store.appVersion) {
      await session.clearCache();
      await session.saveInstalledVersion(store.appVersion);
    }

    final logged = await session.isLoggedIn();
    if (logged) {
      final uid = await session.loggedInUserId();
      if (uid.isNotEmpty && store.userById(uid) != null) {
        store.setCurrentUser(uid);
      } else {
        await session.logout();
        if (!mounted) return;
        setState(() => _loggedIn = false);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _loggedIn = logged);
  }

  @override
  Widget build(BuildContext context) {
    if (_loggedIn == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _loggedIn! ? const HomeScreen() : const LoginScreen();
  }
}

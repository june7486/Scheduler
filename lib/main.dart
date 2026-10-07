import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/l10n.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/session_service.dart';
import 'services/store.dart';
import 'theme/app_theme.dart';
import 'widgets/skin_backdrop.dart';
import 'widgets/skin_lang_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = Store();
  await store.init();
  // Sync the static language used by the L10n helper.
  L10n.currentLang = store.language == 'en' ? AppLang.en : AppLang.ko;
  runApp(JuneSchedulerApp(store: store));
}

ThemeMode _themeModeFor(String key) => switch (key) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

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
          // Keep the active skin in sync with the store.
          setSkin(s.skinKey);
          // Hand-writing (pen) preference for non-notebook skins.
          setHandwriting(s.handwritingKey);
          // Font family + text-size choice.
          setFontPrefs(s.fontKey, s.fontScale);
          return MaterialApp(
            title: s.language == 'en'
                ? "June's Scheduler"
                : 'June 스케줄러',
            debugShowCheckedModeBanner: false,
            navigatorKey: appNavKey,
            theme: AppTheme.build(s.skinKey, Brightness.light),
            darkTheme: AppTheme.build(s.skinKey, Brightness.dark),
            themeMode: _themeModeFor(s.themeModeKey),
            // Sync the effective brightness, then paint the skin's decorative
            // backdrop behind every route (ruled paper / grid / gradient…).
            // The skin + language bar is pinned at the very top so both are
            // ALWAYS reachable, on every screen.
            builder: (context, child) {
              setGlobalBrightness(Theme.of(context).brightness);
              // Apply the user's global text-size choice to the whole app.
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(textScaler: TextScaler.linear(fontScale)),
                child: SkinBackdrop(
                  child: Column(
                    children: [
                      const SkinLangBar(),
                      Expanded(
                        // The bar already consumed the top inset — stop the
                        // routes below (app bars etc.) from padding it again.
                        child: MediaQuery.removePadding(
                          context: context,
                          removeTop: true,
                          child: child ?? const SizedBox.shrink(),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
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

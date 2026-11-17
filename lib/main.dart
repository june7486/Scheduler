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

  // No network call happens before the first frame. Hive reads are local and
  // fast, so the UI paints from the on-device cache immediately; the NAS is
  // contacted afterwards, in the background, by the sync engine. That is the
  // difference between "opens instantly" and "stares at a spinner".
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

/// The brightness the app will actually paint with, resolved *before* the
/// widget tree is built.
///
/// ## Why this cannot wait for MaterialApp.builder
/// Widgets read colours through the global `p` accessor, which resolves the
/// palette from a global brightness. Until this fix, that global was only
/// updated inside `MaterialApp.builder` — but builder runs *after* the subtree
/// it wraps has already been built for that frame. First frame therefore had:
///
///   ThemeData  → dark   (MaterialApp read the same store value)
///   p          → light  (the global had not been updated yet)
///
/// The result was the worst of both: `p.card` panels painted white while the
/// scaffold painted near-black, and `p.ink` text stayed dark-on-dark. Dark mode
/// looked broken in a way that no single colour constant could explain.
///
/// Resolving the brightness here, from the same source of truth MaterialApp
/// uses, removes the race entirely.
Brightness _resolveBrightness(Store s, BuildContext context) {
  switch (_themeModeFor(s.themeModeKey)) {
    case ThemeMode.light:
      return Brightness.light;
    case ThemeMode.dark:
      return Brightness.dark;
    case ThemeMode.system:
      return View.of(context).platformDispatcher.platformBrightness;
  }
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
          // Keep the active design language + colour skin in sync.
          setDesign(s.designKey);
          setSkin(s.skinKey);
          // Hand-writing (pen) preference for non-notebook skins.
          setHandwriting(s.handwritingKey);
          // Compressed chrome (top bar / tab strip / right rail).
          setMinimalChrome(s.minimalChromeKey);
          // Font family + text-size choice.
          setFontPrefs(s.fontKey, s.fontScale);
          // Brightness MUST be resolved before anything below reads `p`.
          // See [_resolveBrightness] for the failure this prevents.
          setGlobalBrightness(_resolveBrightness(s, context));
          return MaterialApp(
            title: s.language == 'en' ? "June's Scheduler" : 'June 스케줄러',
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
              // Keep the global brightness in step with what is actually being
              // painted. The pre-build resolution above already covers the
              // first frame; this covers a change that arrives mid-tree (and
              // ThemeMode.system flipping while the app is open).
              setGlobalBrightness(Theme.of(context).brightness);
              // Apply the user's global text-size choice to the whole app.
              // [effectiveFontScale] folds in the hand-writing legibility boost.
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(
                  textScaler: TextScaler.linear(effectiveFontScale),
                ),
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _loggedIn! ? const HomeScreen() : const LoginScreen();
  }
}

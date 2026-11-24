import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/l10n.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/master_setup_screen.dart';
import 'services/session_service.dart';
import 'services/store.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'widgets/skin_backdrop.dart';
import 'widgets/skin_lang_bar.dart';
import 'widgets/update_dialog.dart';

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

  /// 마스터 첫 비밀번호 설정 화면을 띄울지.
  ///
  /// 이 판단은 **네트워크를 타지 않습니다** ([Store.masterNeedsSetupLocally]).
  /// 앱을 열자마자 12초 스피너를 보여주면 설치가 깨진 것처럼 보입니다.
  /// 명부 확인은 설정 화면 안에서, 사용자가 버튼을 누를 수 있는 상태로 합니다.
  bool _needsMasterSetup = false;

  /// 시작 시 한 번만 만드는 업데이트 확인기.
  ///
  /// `_check()` 안에서 매번 새로 만들면 http.Client 가 쌓입니다.
  /// 필드로 들고 있다가 dispose 에서 닫습니다.
  UpdateService? _updates;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _updates?.dispose();
    super.dispose();
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
        _scheduleUpdateCheck();
        return;
      }
    }
    if (!mounted) return;

    // ## 첫 설치 안내는 "로그인 안 된 상태"에서만
    // 이미 누군가로 로그인해 쓰고 있는 기기라면 대표 비밀번호가 없어도
    // 앱을 막지 않습니다. 일정을 보러 온 사람을 관리자 설정 화면에
    // 가두는 것은 이 기능의 목적이 아닙니다.
    final needsSetup = !logged && store.masterNeedsSetupLocally;

    setState(() {
      _loggedIn = logged;
      _needsMasterSetup = needsSetup;
    });

    // ## 업데이트 확인은 "그린 다음"입니다
    // 화면을 먼저 띄우고(위 setState), 그 다음 프레임에서 조용히 확인합니다.
    // 확인을 await 로 기다리면 네트워크가 느릴 때 스피너만 보게 됩니다.
    // 업데이트 확인은 부가 기능이므로 앱 시작을 절대 붙잡으면 안 됩니다.
    _scheduleUpdateCheck();
  }

  /// 첫 프레임이 실제로 그려진 뒤에 업데이트를 확인합니다.
  ///
  /// `showDialog` 는 Navigator 가 필요합니다. initState 시점에는 아직
  /// 위젯이 트리에 올라오기 전이라 push 가 실패할 수 있습니다. 그래서
  /// 프레임 콜백으로 미룹니다.
  void _scheduleUpdateCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _checkForUpdate();
    });
  }

  Future<void> _checkForUpdate() async {
    // BUILD_ID 없이 만들어진 빌드(개발 빌드)나 웹이 아니면 check() 가
    // 즉시 null 을 돌려줍니다. 여기서 따로 분기하지 않아도 됩니다.
    final service = _updates ??= UpdateService();
    final UpdateCheck? check;
    try {
      check = await service.check();
    } catch (_) {
      // check() 는 내부에서 모든 예외를 삼키지만, 만약을 대비한 이중 안전망.
      return;
    }

    if (!mounted) return;
    if (check == null || !check.available) return;

    final go = await UpdateDialog.show(context, check);

    // 사용자가 팝업을 열어둔 사이 위젯이 사라졌을 수 있습니다.
    if (!mounted) return;

    if (go) {
      // 선택한 빌드는 "건너뛰기"가 아닙니다. 기록을 남기지 않고 새로고침만.
      await UpdateService.applyUpdate();
    } else {
      // "나중에" — 이 빌드에 대해서는 3일간 다시 묻지 않습니다.
      await service.snooze(check.remoteBuild);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loggedIn == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // ## 왜 로그인 화면보다 앞인가
    // 이 화면이 없으면 새로 설치한 사람은 첫 화면에서 **영원히** 막힙니다.
    // 마스터 행의 비밀번호는 설치할 때 무작위로 태어나고 아무도 그 값을
    // 모릅니다. 그래서 로그인 폼을 보여주기 전에 정하게 합니다.
    if (_needsMasterSetup) {
      return MasterSetupScreen(
        onDone: () => setState(() {
          _needsMasterSetup = false;
          _loggedIn = false;
        }),
      );
    }
    return _loggedIn! ? const HomeScreen() : const LoginScreen();
  }
}

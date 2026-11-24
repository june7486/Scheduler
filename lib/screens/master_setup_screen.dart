// 마스터 첫 비밀번호 설정 화면.
//
// ## 왜 필요한가
// 마스터 행은 설치할 때 **무작위 64자** 비밀번호로 태어납니다. 아무도 그 값을
// 모릅니다. 그래서 이 화면이 없으면 새로 설치한 사람은 첫 화면에서
// **영원히 로그인할 수 없습니다.**
//
// ## 왜 로그인 화면이 아니라 별도 화면인가
// 로그인 폼 아래에 "마스터 비밀번호를 정하세요"를 넣으면, 그건 로그인 화면이
// 두 가지 일을 하는 것입니다. 게다가 이 화면은 **한 번만** 뜹니다. 한 번만
// 뜨는 것은 별도 화면이 맞습니다 — 지나가고 나면 로그인 화면에 흔적이 남지
// 않아야 합니다.
//
// ## 무엇을 숨기지 않을 것인가
// "아무도 정하지 않은 상태에서 누구든 먼저 열면 마스터가 된다"는 사실을
// 화면에 적습니다. 이건 결함이 아니라 "완벽한 보안용이 아니다"라는 결정의
// 일부이지만, 사용자가 모르고 지나가면 나중에 문제가 됩니다.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/store.dart';
import '../theme/app_theme.dart';

class MasterSetupScreen extends StatefulWidget {
  /// 설정을 마쳤을 때 부를 콜백. 앱이 로그인 화면으로 넘깁니다.
  final VoidCallback onDone;

  const MasterSetupScreen({super.key, required this.onDone});

  @override
  State<MasterSetupScreen> createState() => _MasterSetupScreenState();
}

class _MasterSetupScreenState extends State<MasterSetupScreen> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _focus2 = FocusNode();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  /// 명부에 이미 주인이 있는지 확인 중.
  bool _checking = true;

  /// 명부가 "이미 정해져 있다"고 답한 경우.
  ///
  /// 이때는 입력란을 열지 않습니다. 열어 두면 사용자가 몇 글자 적고 눌렀을
  /// 때에야 거절당합니다. 처음부터 "다른 기기에서 이미 정했습니다"를
  /// 보여주는 편이 정직합니다.
  bool _taken = false;

  @override
  void initState() {
    super.initState();
    _probeRegistry();
  }

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    _focus2.dispose();
    super.dispose();
  }

  /// ## 왜 화면에 들어와서 확인하는가
  /// 기동 경로(`_Gate`)에서 물으면 앱이 12초 멈춥니다. 그래서 첫 화면은
  /// 로컬만 보고 넘어왔습니다. 여기서는 스피너를 보여줄 수 있으니 명부에
  /// 물어봅니다. 이 확인이 없으면 **두 번째 기기가 마스터를 가로챌 수
  /// 있습니다.**
  Future<void> _probeRegistry() async {
    final store = context.read<Store>();
    // 네트워크가 없거나 로컬 전용 설치면 즉시 끝납니다.
    bool needs;
    try {
      needs = await store.checkMasterSetup();
    } catch (_) {
      needs = true; // 물어보지 못했으면 정하게 둡니다. 막는 쪽이 더 나쁩니다.
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _taken = !needs && store.masterRegistryAnswered;
    });
  }

  Future<void> _submit() async {
    final ko = context.read<Store>().language != 'en';
    final a = _pw.text;
    final b = _pw2.text;

    if (a.length < 4) {
      setState(
        () =>
            _error = ko ? '비밀번호는 4자 이상으로 정해 주세요' : 'Use at least 4 characters',
      );
      return;
    }
    // ## 확인 입력을 요구하는 이유
    // 이 값은 다시 볼 수 없습니다(마스터 콘솔에서만 보입니다). 오타로 정하면
    // 로그인할 수 없고, 되돌릴 방법도 없습니다. 두 번 받는 것이 유일한
    // 방어입니다.
    if (a != b) {
      setState(
        () => _error = ko ? '두 비밀번호가 다릅니다' : 'The two passwords do not match',
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final store = context.read<Store>();
    final err = await store.setInitialMasterPassword(a);
    if (!mounted) return;

    if (err != null) {
      setState(() {
        _busy = false;
        if (err == 'master_taken') {
          // 누르기 직전에 다른 기기가 먼저 정했습니다.
          _taken = true;
          _error = null;
        } else {
          _error = ko ? '비밀번호를 정하지 못했습니다: $err' : 'Could not set it: $err';
        }
      });
      return;
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final ko = store.language != 'en';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 68,
                    height: 68,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: p.indigo.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(19),
                    ),
                    child: Icon(
                      Icons.admin_panel_settings_outlined,
                      size: 34,
                      color: p.indigo,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    ko ? '관리자 비밀번호를 정해 주세요' : 'Set the master password',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _taken
                        ? (ko
                              ? '대표 계정 「${Store.masterId}」은 이미 주인이 있습니다.'
                              : 'The master account 「${Store.masterId}」 already has an owner.')
                        : (ko
                              ? '이 앱을 처음 설치했습니다.\n'
                                    '대표 계정 「${Store.masterId}」의 비밀번호가 아직 없습니다.'
                              : 'This is a fresh install.\n'
                                    'The master account 「${Store.masterId}」 has no password yet.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: p.inkSoft,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 22),
                  if (_checking)
                    _checkingBox(ko)
                  else if (_taken)
                    _takenBox(ko)
                  else ...[
                    TextField(
                      controller: _pw,
                      obscureText: _obscure,
                      autofocus: true,
                      style: const TextStyle(fontSize: 13.5),
                      onSubmitted: (_) => _focus2.requestFocus(),
                      decoration: InputDecoration(
                        hintText: ko ? '새 비밀번호 (4자 이상)' : 'New password (4+)',
                        prefixIcon: const Icon(Icons.lock_outline, size: 20),
                        suffixIcon: ExcludeFocus(
                          // ## Tab 이 눈 아이콘에 걸리면 안 됩니다
                          // 첫 칸을 쓰고 Tab 을 누르는 사람은 "다음 칸"으로
                          // 가려는 것입니다. 기본 탭 순서는 suffix 버튼을
                          // 먼저 거치기 때문에, 그대로 두면 두 번째 칸이 비어
                          // 있는 채로 [정하고 시작하기] 에 도착하고
                          // "두 비밀번호가 다릅니다" 만 보게 됩니다.
                          // (웹에서 실제로 재현했습니다.)
                          child: IconButton(
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
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _pw2,
                      focusNode: _focus2,
                      obscureText: _obscure,
                      style: const TextStyle(fontSize: 13.5),
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        hintText: ko
                            ? '한 번 더 (오타 방지)'
                            : 'Once more (typo check)',
                        prefixIcon: const Icon(
                          Icons.lock_reset_outlined,
                          size: 20,
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
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: p.card,
                                ),
                              )
                            : Text(ko ? '정하고 시작하기' : 'Set it and start'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  // ## 숨기지 않는 경고
                  //
                  // 이 상황은 "완벽한 보안용이 아니다"라는 결정의 일부입니다.
                  // 사용자가 모르고 지나가면 나중에 문제가 됩니다. 그래서
                  // 화면에 적습니다 — 코드 주석은 결정한 사람이 읽지 않습니다.
                  if (!_checking && !_taken)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: p.soft.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: p.line),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: p.inkSoft,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ko
                                  ? '아직 아무도 이 비밀번호를 정하지 않았습니다. '
                                        '이 상태에서 먼저 여는 사람이 대표 계정이 됩니다. '
                                        '지금 정하시면 그 사람은 당신입니다.\n\n'
                                        '정한 비밀번호는 관리자 콘솔에서 다시 볼 수 있습니다. '
                                        '다른 곳에서 쓰는 비밀번호는 여기에 쓰지 마세요.'
                                  : 'Nobody has set this password yet. '
                                        'Whoever opens the app first becomes the master. '
                                        'Setting it now makes that person you.\n\n'
                                        'You can see it again in the master console. '
                                        'Do not reuse a password from anywhere else.',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: p.inkSoft,
                                height: 1.6,
                              ),
                            ),
                          ),
                        ],
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

  /// 명부에 물어보는 동안.
  Widget _checkingBox(bool ko) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 26),
      child: Column(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: p.indigo),
          ),
          const SizedBox(height: 14),
          Text(
            ko ? '이미 정해져 있는지 확인하는 중…' : 'Checking whether this is already set…',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: p.inkSoft),
          ),
        ],
      ),
    );
  }

  /// 이미 다른 기기가 정한 경우.
  ///
  /// ## 왜 "정할 수 없음"이 아니라 "이미 있음"이라고 말하는가
  /// 사용자 잘못이 아닙니다. 그리고 다음에 할 일이 분명합니다 — 그
  /// 비밀번호로 로그인하면 됩니다. 막다른 길이 아니라 안내입니다.
  Widget _takenBox(bool ko) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: p.danger.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.danger.withValues(alpha: 0.25)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_rounded, size: 15, color: p.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ko
                      ? '이미 다른 기기에서 대표 비밀번호를 정했습니다.\n'
                            '새로 정할 수 없습니다. 그 비밀번호로 로그인해 주세요.\n'
                            '잊어버렸다면 대표 계정으로 로그인한 뒤 관리자 콘솔에서 확인할 수 있습니다.'
                      : 'The master password was already set on another device.\n'
                            'It cannot be set again. Sign in with that password.\n'
                            'If it is lost, sign in as master and read it in the admin console.',
                  style: TextStyle(fontSize: 11, color: p.ink, height: 1.6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 46,
          child: OutlinedButton(
            onPressed: () => widget.onDone(),
            child: Text(ko ? '로그인 화면으로' : 'Go to sign-in'),
          ),
        ),
      ],
    );
  }
}

// 처음 온 사람을 위한 두 개의 안내 화면.
//
// ## 왜 다이얼로그가 아니라 화면인가
// 로그인 화면에 "사용 안내"를 넣는 방식은 두 가지가 있다. 하나는 AlertDialog,
// 다른 하나는 별도 화면이다. 이 글은 꽤 길다 — 스크롤이 필요하고, 읽다가
// 잠깐 로그인 화면을 보고 싶어지기도 한다. 다이얼로그는 그 두 가지를 모두
// 불편하게 만든다(작은 상자, 뒤를 가리는 배리어). 그래서 화면으로 만든다.
//
// ## 왜 외부 브라우저로 보내지 않는가
// www.scout.it.kr 은 스카우트 자료실이고, 이 앱의 설명서는 아니다. 폰에서
// 눌렀을 때 브라우저가 튀어나오면 "앱이 나를 내보냈다"는 느낌이 든다.
// 그래서 설명은 앱 안에서 끝내고, 사이트는 **원할 때만** 가는 링크로 둔다.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';

/// 스카우트 자료실. 이 앱과 별개로 운영되는 사이트라 상수로 고정한다.
const String kScoutSiteUrl = 'https://www.scout.it.kr';

/// 어떤 안내를 보여줄지.
enum GuideKind {
  /// 「처음이신가요? 사용 안내」
  howToUse,

  /// 「프로그램 소개」
  aboutProgram,
}

/// [kind] 에 맞는 안내 화면을 연다.
Future<void> openGuide(BuildContext context, GuideKind kind) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => GuideScreen(kind: kind)),
  );
}

class GuideScreen extends StatelessWidget {
  final GuideKind kind;
  const GuideScreen({super.key, required this.kind});

  @override
  Widget build(BuildContext context) {
    final isKo = L10n.currentLang == AppLang.ko;
    final title = kind == GuideKind.howToUse
        ? context.tr('guide_new_here')
        : context.tr('guide_about');

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 34),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Hero(kind: kind, isKo: isKo),
                  const SizedBox(height: 22),
                  if (kind == GuideKind.howToUse) ..._howTo(context) else ..._about(context),
                  const SizedBox(height: 26),
                  const Divider(),
                  const SizedBox(height: 14),
                  const _SiteButton(),
                  const SizedBox(height: 8),
                  Text(
                    context.tr('guide_origin_link'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10.5, color: p.inkSoft, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _howTo(BuildContext context) => [
        _Section(
          title: context.tr('guide_what_title'),
          body: context.tr('guide_what_body'),
        ),
        _Section(
          title: context.tr('guide_start_title'),
          steps: [
            context.tr('guide_start_1'),
            context.tr('guide_start_2'),
            context.tr('guide_start_3'),
            context.tr('guide_start_4'),
            context.tr('guide_start_5'),
          ],
        ),
        _Section(
          title: context.tr('guide_theme_title'),
          body: context.tr('guide_theme_body'),
        ),
        _Section(
          title: context.tr('guide_data_title'),
          body: context.tr('guide_data_body'),
        ),
      ];

  List<Widget> _about(BuildContext context) => [
        _Section(
          title: context.tr('guide_what_title'),
          body: context.tr('guide_what_body'),
        ),
        _Section(
          title: context.tr('guide_origin_title'),
          body: context.tr('guide_origin_body'),
        ),
        _Section(
          title: context.tr('guide_theme_title'),
          body: context.tr('guide_theme_body'),
        ),
        _Section(
          title: context.tr('guide_data_title'),
          body: context.tr('guide_data_body'),
        ),
      ];
}

/// 화면 맨 위의 아이콘 + 한 줄 제목.
class _Hero extends StatelessWidget {
  final GuideKind kind;
  final bool isKo;
  const _Hero({required this.kind, required this.isKo});

  @override
  Widget build(BuildContext context) {
    final icon = kind == GuideKind.howToUse
        ? Icons.menu_book_rounded
        : Icons.info_outline_rounded;
    final sub = kind == GuideKind.howToUse
        ? (isKo ? '읽는 데 2분이면 충분합니다' : 'Two minutes is enough')
        : (isKo ? '무엇을 위해 만든 도구인지' : 'What it was built for');

    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: p.indigo.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(icon, size: 27, color: p.indigo),
        ),
        const SizedBox(height: 12),
        Text(
          sub,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: p.inkSoft),
        ),
      ],
    );
  }
}

/// 제목 + 본문, 또는 제목 + 번호 매긴 단계.
class _Section extends StatelessWidget {
  final String title;
  final String? body;
  final List<String>? steps;
  const _Section({required this.title, this.body, this.steps});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: p.ink,
              letterSpacing: 0.1,
            ),
          ),
          const SizedBox(height: 7),
          if (body != null)
            Text(
              body!,
              style: TextStyle(fontSize: 12.5, color: p.ink, height: 1.72),
            ),
          if (steps != null)
            for (var i = 0; i < steps!.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 번호는 고정 폭. 들여쓰기가 흔들리면 목록이 목록으로
                    // 읽히지 않는다.
                    Container(
                      width: 18,
                      height: 18,
                      margin: const EdgeInsets.only(top: 1.5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: p.indigo.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: p.indigo,
                        ),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        steps![i],
                        style: TextStyle(
                          fontSize: 12.5,
                          color: p.ink,
                          height: 1.62,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// 스카우트 자료실로 나가는 단 하나의 버튼.
///
/// 열리지 않아도 앱이 막히면 안 되므로, 실패하면 주소를 그대로 보여준다.
/// "브라우저를 열 수 없습니다" 만 남기면 사용자가 할 수 있는 일이 없다.
class _SiteButton extends StatelessWidget {
  const _SiteButton();

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final message = context.tr(
          'guide_open_failed',
          args: {'url': kScoutSiteUrl},
        );
        var ok = false;
        try {
          ok = await launchUrl(
            Uri.parse(kScoutSiteUrl),
            mode: LaunchMode.externalApplication,
          );
        } catch (_) {
          ok = false;
        }
        if (!ok) {
          messenger.showSnackBar(SnackBar(content: Text(message)));
        }
      },
      icon: const Icon(Icons.open_in_new_rounded, size: 16),
      label: Text(
        context.tr('guide_open_site'),
        style: const TextStyle(fontSize: 12.5),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: p.indigo,
        side: BorderSide(color: p.line),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

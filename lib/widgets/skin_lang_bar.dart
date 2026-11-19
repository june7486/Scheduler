import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';
import 'notebook_ui.dart';

/// Root navigator key — the top bar lives ABOVE the app's Navigator, so it
/// needs this key to present bottom sheets / dialogs.
final GlobalKey<NavigatorState> appNavKey = GlobalKey<NavigatorState>();

/// A slim bar that sits at the very top of the app and is ALWAYS visible.
///
/// Left: a skin picker pill (current skin emoji + name). Right: an icon
/// language toggle (한국어 / English). Tapping the skin pill opens a bottom
/// sheet with every skin plus a quick brightness switch.
class SkinLangBar extends StatelessWidget {
  const SkinLangBar({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    return Material(
      color: p.card,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: Row(
            children: [
              _SkinPill(store: store),
              const Spacer(),
              _LangToggle(store: store),
            ],
          ),
        ),
      ),
    );
  }
}

/// Current-skin pill → opens the skin picker.
class _SkinPill extends StatelessWidget {
  final Store store;
  const _SkinPill({required this.store});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showSkinPicker(appNavKey.currentContext ?? context, store),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: p.soft,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppSkins.emojiFor(store.skinKey),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(width: 6),
            Text(
              skinName(store.skinKey),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.ink,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.palette_outlined, size: 15, color: p.indigo),
          ],
        ),
      ),
    );
  }
}

/// Icon-only KO / EN language toggle (always visible at the top).
class _LangToggle extends StatelessWidget {
  final Store store;
  const _LangToggle({required this.store});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: p.soft,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.line),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.language, size: 15, color: p.inkSoft),
          const SizedBox(width: 4),
          _chip(context, '한', 'ko', '한국어'),
          _chip(context, 'EN', 'en', 'English'),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    String label,
    String code,
    String tooltip,
  ) {
    final sel = store.language == code;
    return GestureDetector(
      onTap: () {
        store.setLanguage(code);
        L10n.currentLang = code == 'en' ? AppLang.en : AppLang.ko;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: sel ? p.indigo : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? p.onAccent : p.inkSoft,
          ),
        ),
      ),
    );
  }
}

/// Localised display name for a skin id.
String skinName(String id) => tr('skin_$id');

/// Bottom sheet that lets the user choose a **design language**.
///
/// This is the top level of the look-and-feel hierarchy, and it is deliberately
/// not a recolour menu: each design changes geometry, decoration, typography and
/// rhythm. Colour lives one level down, inside the design, because a palette
/// makes sense *within* a language rather than instead of one.
void showDesignPicker(BuildContext context, Store store) {
  final designs = AppDesigns.ids;
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: p.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => Consumer<Store>(
      builder: (ctx, s, _) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.design_services_outlined,
                      size: 18,
                      color: p.indigo,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      ctx.tr('choose_design'),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  ctx.tr('choose_design_hint'),
                  style: TextStyle(fontSize: 11.5, color: p.inkSoft),
                ),
                const SizedBox(height: 14),
                // 한 목록으로 보여준다. 고밀도를 별도 섹션으로 떼어놓으면
                // '테마'가 아니라 '다른 기능'처럼 읽힌다. 테마는 테마다.
                // 밀도는 각 항목의 배지로만 알려준다.
                for (final id in designs)
                  _DesignRow(
                    id: id,
                    selected: s.designKey == id,
                    onTap: tumbleHaptic(() => s.setDesignKey(id)),
                  ),
                const SizedBox(height: 16),
                Divider(height: 1, color: p.line),
                const SizedBox(height: 12),
                Text(
                  ctx.tr('choose_color'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: p.inkSoft,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final id in AppSkins.ids)
                      _SkinTile(
                        id: id,
                        selected: s.skinKey == id,
                        onTap: () => s.setSkinKey(id),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// One design-language row: a live miniature of the design's geometry plus its
/// characteristics, so the choice is visible before it is applied.
class _DesignRow extends StatelessWidget {
  final String id;
  final bool selected;
  final VoidCallback onTap;
  const _DesignRow({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final d = AppDesigns.of(id);
    final s = d.surface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? p.indigo.withValues(alpha: 0.07) : p.soft,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? p.indigo : p.line,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              // Miniature of the surface spec.
              //
              // 고밀도 테마는 반지름과 테두리만으로는 구분되지 않는다. 그래서
              // 밀도 자체를 그림으로 보여준다: 행 수가 곧 그 테마의 주장이고,
              // 색만 다른 변형이 아니라는 유일한 증거다.
              // (paper 는 3줄, terminal 은 8줄 — 실제 화면 비율과 같은 방향)
              _DesignMiniature(id: id, spec: s),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(d.emoji, style: const TextStyle(fontSize: 13)),
                        const SizedBox(width: 6),
                        Text(
                          context.tr('design_$id'),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: p.ink,
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.check_circle, size: 14, color: p.indigo),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      context.tr('design_hint_$id'),
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: p.inkSoft,
                      ),
                    ),
                    if (AppDesigns.isDense(id)) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: p.indigo.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          context.tr(
                            'density_label',
                            args: {'n': s.densityScore.toStringAsFixed(1)},
                          ),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: p.indigo,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny wrapper so a tap-vibration can be added in one place (and stay a no-op
/// on web, where there is no haptic engine).
VoidCallback tumbleHaptic(VoidCallback action) => action;

/// Bottom sheet that lets the user choose a skin (+ a quick brightness switch).
///
/// ## 왜 이 패널을 다시 만들었나 — 측정값이 말해준 것
/// 390×760 화면에서 이 패널은 **거의 전부가 스크롤 아래**에 있었다.
/// '글꼴'은 875px, '글자 크기'는 1159px 지점 — 화면 밖이었다. 사용자가 이
/// 패널을 여는 이유는 대개 하나다: "글자가 안 보여서 키우고 싶다". 그런데
/// 정작 글자 크기 슬라이더가 가장 멀리 있었다. 순서가 뒤집혀 있었던 셈이다.
///
/// 범인은 크기가 아니라 **여백의 총합**이었다.
///   - 스킨 타일 150×77px 를 2열로 → 7개가 **4줄**, 338px
///   - 화면 테마 3개: 아이콘 위 + 글자 아래로 쌓아 개당 54px
///   - 손글씨 카드: 제목 + 설명 두 줄 + 큰 Switch 로 54px
///   - 글꼴 9개: '가나다' + 이름, 개당 35px
///
/// 셋 다 "정보는 하나인데 상자를 크게 그린" 경우다. 정보를 줄이지 않고
/// 상자만 줄인다 — 이게 압축이다.
///
/// ## 모든 테마에서 같은 크기
/// 이 패널은 테마를 *고르는* 자리다. 고르는 도중에 패널 크기가 테마를 따라
/// 변하면, 무엇을 기준으로 비교하는 중인지가 흔들린다. 그래서 [minimalChrome]
/// 같은 전역 상태를 읽지 않는다. 선택지는 항상 같은 자리에, 같은 크기로.
void showSkinPicker(BuildContext context, Store store) {
  // 기본 modal bottom sheet 은 화면의 9/16 까지만 열린다(760px 화면에서 414px).
  // 내용을 압축해도 그 상자 안에서는 여전히 스크롤이 남는다. 내용을 줄이는
  // 것과 상자를 조금 더 여는 것은 다른 일이고, 둘 다 필요하다.
  // 0.86 은 상태바/안전영역을 남기면서 "다 보인다"는 느낌을 주는 선.
  final maxSheetHeight = MediaQuery.sizeOf(context).height * 0.86;

  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: maxSheetHeight),
    backgroundColor: p.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => Consumer<Store>(
      builder: (ctx, s, _) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            // 위 14 → 10, 아래 22 → 12. 이 14px 만으로도 마지막 슬라이더가
            // 스크롤 없이 들어오는 화면이 생긴다.
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetHeader(Icons.palette_outlined, ctx.tr('choose_skin')),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (_, box) {
                    // 3열. 7개가 4줄 → 3줄이 된다 (338px → 150px).
                    const gap = 6.0;
                    final w = (box.maxWidth - gap * 2) / 3;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final id in AppSkins.ids)
                          _SkinTile(
                            id: id,
                            width: w,
                            selected: s.skinKey == id,
                            // Keep the sheet open so the user can also tweak
                            // brightness / font / size right after picking.
                            onTap: () => s.setSkinKey(id),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 10),
                _sectionLabel(ctx.tr('screen_theme')),
                const SizedBox(height: 5),
                _BrightnessRow(store: s),
                const SizedBox(height: 5),
                _HandwritingToggle(store: s),
                const SizedBox(height: 10),
                _sectionLabel(ctx.tr('font')),
                const SizedBox(height: 5),
                _FontSection(store: s),
                const SizedBox(height: 6),
                _FontSizeSlider(store: s),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The small icon + title line every sheet starts with.
Widget _sheetHeader(IconData icon, String title) {
  return Row(
    children: [
      Icon(icon, size: 16, color: p.indigo),
      const SizedBox(width: 6),
      Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: p.ink,
        ),
      ),
    ],
  );
}

/// The quiet grey caption above a group of controls.
Widget _sectionLabel(String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: p.inkSoft,
      letterSpacing: 0.3,
    ),
  );
}

/// One skin swatch.
///
/// ## 무엇을 줄였고 무엇을 남겼나
/// 예전 타일은 150×77px 에 이모지 16px, 이름 12.5px, 색 점 14px 를 담았다.
/// 7개를 2열로 놓으면 4줄이다. 상자를 줄이면서 **버리면 안 되는 것**은 색이다
/// — 이 패널에서 스킨을 고르는 기준은 결국 색이니까. 그래서 색 점은 남기되
/// 14px → 8px 로, 이름은 12.5 → 11px 로, 안쪽 여백은 10 → 6/7 로 줄이고
/// 폭은 [width] 로 받아 3열에 맞춘다.
class _SkinTile extends StatelessWidget {
  final String id;
  final bool selected;
  final VoidCallback onTap;
  final double width;
  const _SkinTile({
    required this.id,
    required this.selected,
    required this.onTap,
    this.width = 100,
  });

  @override
  Widget build(BuildContext context) {
    final light = AppSkins.lightFor(id);
    final dark = AppSkins.darkFor(id);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        decoration: BoxDecoration(
          color: light.bg,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? light.indigo : light.line,
            width: selected ? 1.8 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(light.emoji, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    skinName(id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: light.ink,
                      height: 1.15,
                    ),
                  ),
                ),
                // 체크 표시가 이름 자리를 잡아먹지 않도록, 선택된 타일에서만
                // 그리고 폭도 12px 로 묶는다. 이름이 잘리면 스킨을 못 고른다.
                if (selected)
                  Icon(Icons.check_circle, size: 12, color: light.indigo),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _dot(light.indigo, 8),
                const SizedBox(width: 3),
                _dot(light.teal, 8),
                const SizedBox(width: 3),
                _dot(light.bg, 8),
                const Spacer(),
                // 어두운 화면에서의 모습이라는 표시. 뜻은 남기고 크기만 줄인다.
                Icon(
                  Icons.dark_mode,
                  size: 10,
                  color: dark.indigo.withValues(alpha: 0.85),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color c, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: c,
      shape: BoxShape.circle,
      border: Border.all(color: const Color(0x22000000)),
    ),
  );
}

class _BrightnessRow extends StatelessWidget {
  final Store store;
  const _BrightnessRow({required this.store});

  @override
  Widget build(BuildContext context) {
    final items = <({String key, IconData icon, String label})>[
      (
        key: 'system',
        icon: Icons.brightness_auto,
        label: context.tr('follow_system'),
      ),
      (key: 'light', icon: Icons.light_mode, label: context.tr('light_mode')),
      (key: 'dark', icon: Icons.dark_mode, label: context.tr('dark_mode')),
    ];
    return Row(
      children: [
        for (final it in items) ...[
          Expanded(
            child: GestureDetector(
              onTap: () => store.setThemeModeKey(it.key),
              // 예전에는 아이콘 **위**, 글자 **아래**로 쌓아 개당 54px 였다.
              // 세로로 쌓는 것은 큰 상자에서만 값을 한다. 여기서는 상자가
              // 작으므로 가로로 눕히면 같은 정보가 30px 에 들어간다.
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: store.themeModeKey == it.key
                      ? p.indigo.withValues(alpha: 0.14)
                      : p.soft,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: store.themeModeKey == it.key ? p.indigo : p.line,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      it.icon,
                      size: 14,
                      color: store.themeModeKey == it.key
                          ? p.indigo
                          : p.inkSoft,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        it.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: store.themeModeKey == it.key
                              ? p.ink
                              : p.inkSoft,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (it.key != 'dark') const SizedBox(width: 6),
        ],
      ],
    );
  }
}

/// A switch for the hand-writing (pen) look, shown under the brightness row.
///
/// 예전에는 제목 + 설명 두 줄 + 표준 크기 Switch 로 54px 를 먹었다. 설명이
/// 차지한 줄이 패널에서 가장 값비싼 12px 중 하나였으므로, 설명은 Tooltip 으로
/// 옮기고 한 줄로 눕혔다. 스위치 자체도 48px 기본 터치 영역을 그대로 쓰면
/// 줄 높이가 의미 없어지므로 scale 로 줄인다.
class _HandwritingToggle extends StatelessWidget {
  final Store store;
  const _HandwritingToggle({required this.store});

  @override
  Widget build(BuildContext context) {
    final on = store.handwritingKey;
    return Tooltip(
      message: context.tr('handwriting_hint'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        decoration: BoxDecoration(
          color: on ? p.indigo.withValues(alpha: 0.10) : p.soft,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on ? p.indigo : p.line),
        ),
        child: Row(
          children: [
            const HandAsterisk(size: 12, seed: 5),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                context.tr('handwriting'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: p.ink,
                ),
              ),
            ),
            SizedBox(
              height: 28,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Switch(
                  value: on,
                  activeThumbColor: p.indigo,
                  onChanged: (v) => store.setHandwritingKey(v),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Font-family chooser: Windows default + 2 hand-writing + 6 typographic fonts.
///
/// 압축의 핵심은 '가나다' 견본을 버리지 않는 것이다. 글꼴 이름은 뜻이 없고,
/// 그 글꼴로 쓴 글자가 뜻이다. 대신 견본 15px → 12.5px, 안쪽 여백 12/8 → 8/4,
/// 항목 사이 8 → 5 로 줄여 개당 35px → 24px 로 만든다.
class _FontSection extends StatelessWidget {
  final Store store;
  const _FontSection({required this.store});

  String _label(BuildContext context, String id) => switch (id) {
    'system' => context.tr('font_system'),
    'pen' => context.tr('font_pen'),
    'gaegu' => context.tr('font_gaegu'),
    'gothic' => context.tr('font_gothic'),
    'myeongjo' => context.tr('font_myeongjo'),
    'dodum' => context.tr('font_dodum'),
    'jua' => context.tr('font_jua'),
    'dohyeon' => context.tr('font_dohyeon'),
    'black' => context.tr('font_black'),
    _ => id,
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            for (final id in AppFonts.ids)
              GestureDetector(
                onTap: () => store.setFontKey(id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: store.fontKey == id
                        ? p.indigo.withValues(alpha: 0.12)
                        : p.soft,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: store.fontKey == id ? p.indigo : p.line,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '가나다',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.1,
                          fontFamily: AppFonts.of(id).family,
                          color: store.fontKey == id ? p.ink : p.inkSoft,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _label(context, id),
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.1,
                          fontWeight: FontWeight.w600,
                          color: store.fontKey == id ? p.ink : p.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.info_outline, size: 11, color: p.inkSoft),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                context.tr('font_hand_note'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9.5, color: p.inkSoft),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Global text-size slider (0.85–1.60).
///
/// 이 패널을 여는 가장 흔한 이유가 "글자가 안 보인다" 이므로, 슬라이더는
/// 장식이 아니라 이 화면의 목적지다. ± 버튼을 18 → 15px 로 줄이고 슬라이더
/// 자체의 기본 48px 높이를 30px 로 묶어 한 줄에 앉힌다.
class _FontSizeSlider extends StatelessWidget {
  final Store store;
  const _FontSizeSlider({required this.store});

  @override
  Widget build(BuildContext context) {
    final v = store.fontScale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              context.tr('font_size'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: p.inkSoft,
                letterSpacing: 0.3,
              ),
            ),
            const Spacer(),
            Text(
              '${(v * 100).round()}%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: p.indigo,
              ),
            ),
          ],
        ),
        SizedBox(
          height: 30,
          child: Row(
            children: [
              GestureDetector(
                onTap: () => store.setFontScale((v - 0.05).clamp(0.85, 1.6)),
                child: Icon(
                  Icons.remove_circle_outline,
                  size: 15,
                  color: p.inkSoft,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  // 슬라이더의 기본 여백은 손가락을 위한 것이다. 여기서는
                  // 이미 패널 안이고 바로 옆에 ± 버튼이 있으므로, 그 여백을
                  // 줄여도 조작이 어려워지지 않는다.
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                  ),
                  child: Slider(
                    value: v,
                    min: 0.85,
                    max: 1.6,
                    divisions: 15,
                    activeColor: p.indigo,
                    label: '${(v * 100).round()}%',
                    onChanged: (nv) => store.setFontScale(nv),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => store.setFontScale((v + 0.05).clamp(0.85, 1.6)),
                child: Icon(
                  Icons.add_circle_outline,
                  size: 15,
                  color: p.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A 46×40 miniature of a design's rhythm — not just its corners.
///
/// The old preview drew one rectangle with a radius and a border, which meant
/// the four designs differed by a few pixels of corner. That is fine when the
/// choice is decorative, and useless when the user is asking "which of these
/// shows me the most at once".
///
/// So this draws *rows*. The row height comes straight from the same numbers the
/// real list uses (padding, gap, title size), which means the preview is an
/// honest scale model: Paper shows 3 rules, Terminal shows 8. A design cannot
/// claim to be dense here and not be dense on screen.
class _DesignMiniature extends StatelessWidget {
  const _DesignMiniature({required this.id, required this.spec});
  final String id;
  final SurfaceSpec spec;

  @override
  Widget build(BuildContext context) {
    // One real row, in miniature units. `densityScore` is 100 / row height, so
    // dividing back gives the row height the row widget would produce.
    final rowHeight = (100 / spec.densityScore).clamp(4.0, 40.0);
    // Scale so the densest design (rowHeight ~12) fits 8 rows in 40px.
    final unit = rowHeight * 0.42;
    final rows = (40 / (unit + (spec.rowGap * 0.15))).floor().clamp(1, 10);
    final lined = spec.rowDivider;

    return Container(
      width: 46,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(spec.radius),
        border: spec.borderWidth == 0
            ? Border.all(color: p.line, width: 0.6)
            : Border.all(color: p.line, width: spec.borderWidth),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (spec.edgeBar)
            Container(width: 3, color: p.indigo.withValues(alpha: 0.75)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < rows; i++)
                    Expanded(
                      child: Container(
                        margin: EdgeInsets.only(
                          bottom: lined ? 0 : 1.6,
                          top: i == 0 ? 0 : (lined ? 0 : 0.8),
                        ),
                        decoration: BoxDecoration(
                          color: spec.zebra && i.isOdd
                              ? p.indigo.withValues(alpha: 0.16)
                              : null,
                          border: lined
                              ? Border(
                                  bottom: BorderSide(
                                    color: p.ink.withValues(alpha: 0.22),
                                    width: 0.6,
                                  ),
                                )
                              : null,
                          borderRadius: BorderRadius.circular(
                            lined ? 0 : spec.radiusSmall,
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: 0.35 + ((i * 17) % 55) / 100,
                            child: Container(
                              height: (unit * 0.22).clamp(1.0, 2.4),
                              decoration: BoxDecoration(
                                color: p.ink.withValues(alpha: 0.30),
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                        ),
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
}

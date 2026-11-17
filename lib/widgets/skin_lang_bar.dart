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
      onTap: () => showSkinPicker(
        appNavKey.currentContext ?? context,
        store,
      ),
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
            Text(AppSkins.emojiFor(store.skinKey),
                style: const TextStyle(fontSize: 14)),
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
      BuildContext context, String label, String code, String tooltip) {
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
                    Icon(Icons.design_services_outlined,
                        size: 18, color: p.indigo),
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
                // 두 계열로 나눈다. 아홉 개를 한 줄로 늘어놓으면
                // "고밀도"가 그냥 목록의 아래쪽 항목처럼 보인다.
                for (final id in designs.where((e) => !AppDesigns.isDense(e)))
                  _DesignRow(
                    id: id,
                    selected: s.designKey == id,
                    onTap: tumbleHaptic(() => s.setDesignKey(id)),
                  ),

                if (designs.any(AppDesigns.isDense)) ...[
                  const SizedBox(height: 10),
                  Divider(height: 1, color: p.line),
                  const SizedBox(height: 12),
                  Text(
                    ctx.tr('choose_design_dense'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: p.ink,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    ctx.tr('choose_design_dense_hint'),
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.4,
                      color: p.inkSoft,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final id in designs.where(AppDesigns.isDense))
                    _DesignRow(
                      id: id,
                      selected: s.designKey == id,
                      onTap: tumbleHaptic(() => s.setDesignKey(id)),
                    ),
                ],
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
                            fontWeight:
                                selected ? FontWeight.w800 : FontWeight.w600,
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
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: p.indigo.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          context.tr('density_label', args: {
                            'n': s.densityScore.toStringAsFixed(1),
                          }),
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
void showSkinPicker(BuildContext context, Store store) {
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
                    Icon(Icons.palette_outlined, size: 18, color: p.indigo),
                    const SizedBox(width: 8),
                    Text(
                      ctx.tr('choose_skin'),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final id in AppSkins.ids)
                      _SkinTile(
                        id: id,
                        selected: s.skinKey == id,
                        // Keep the sheet open so the user can also tweak
                        // brightness / font / size right after picking a skin.
                        onTap: () => s.setSkinKey(id),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  ctx.tr('screen_theme'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: p.inkSoft,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 8),
                _BrightnessRow(store: s),
                const SizedBox(height: 6),
                _HandwritingToggle(store: s),
                const SizedBox(height: 16),
                _FontSection(store: s),
                const SizedBox(height: 8),
                _FontSizeSlider(store: s),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _SkinTile extends StatelessWidget {
  final String id;
  final bool selected;
  final VoidCallback onTap;
  const _SkinTile({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final light = AppSkins.lightFor(id);
    final dark = AppSkins.darkFor(id);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 150,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: light.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? light.indigo : light.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(light.emoji, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    skinName(id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: light.ink,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, size: 16, color: light.indigo),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _dot(light.indigo),
                const SizedBox(width: 4),
                _dot(light.teal),
                const SizedBox(width: 4),
                _dot(light.bg),
                const Spacer(),
                Icon(Icons.dark_mode, size: 13, color: dark.indigo),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color c) => Container(
        width: 14,
        height: 14,
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
      (key: 'system', icon: Icons.brightness_auto, label: context.tr('follow_system')),
      (key: 'light', icon: Icons.light_mode, label: context.tr('light_mode')),
      (key: 'dark', icon: Icons.dark_mode, label: context.tr('dark_mode')),
    ];
    return Row(
      children: [
        for (final it in items) ...[
          Expanded(
            child: GestureDetector(
              onTap: () => store.setThemeModeKey(it.key),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: store.themeModeKey == it.key
                      ? p.indigo.withValues(alpha: 0.14)
                      : p.soft,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: store.themeModeKey == it.key ? p.indigo : p.line,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(it.icon,
                        size: 18,
                        color: store.themeModeKey == it.key
                            ? p.indigo
                            : p.inkSoft),
                    const SizedBox(height: 4),
                    Text(
                      it.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: store.themeModeKey == it.key ? p.ink : p.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (it.key != 'dark') const SizedBox(width: 8),
        ],
      ],
    );
  }
}

/// A switch for the hand-writing (pen) look, shown under the brightness row.
class _HandwritingToggle extends StatelessWidget {
  final Store store;
  const _HandwritingToggle({required this.store});

  @override
  Widget build(BuildContext context) {
    final on = store.handwritingKey;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: p.soft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: [
          const HandAsterisk(size: 15, seed: 5),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('handwriting'),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: p.ink,
                  ),
                ),
                Text(
                  context.tr('handwriting_hint'),
                  style: TextStyle(fontSize: 10.5, color: p.inkSoft),
                ),
              ],
            ),
          ),
          Switch(
            value: on,
            activeThumbColor: p.indigo,
            onChanged: (v) => store.setHandwritingKey(v),
          ),
        ],
      ),
    );
  }
}

/// Font-family chooser: Windows default + 2 hand-writing + 6 typographic fonts.
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
        Text(
          context.tr('font'),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: p.inkSoft,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final id in AppFonts.ids)
              GestureDetector(
                onTap: () => store.setFontKey(id),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: store.fontKey == id
                        ? p.indigo.withValues(alpha: 0.12)
                        : p.soft,
                    borderRadius: BorderRadius.circular(10),
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
                          fontSize: 15,
                          fontFamily: AppFonts.of(id).family,
                          color: store.fontKey == id ? p.ink : p.inkSoft,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _label(context, id),
                        style: TextStyle(
                          fontSize: 11.5,
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
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.info_outline, size: 13, color: p.inkSoft),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                context.tr('font_hand_note'),
                style: TextStyle(fontSize: 10.5, color: p.inkSoft),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Global text-size slider (0.85–1.60).
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
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: p.inkSoft,
                letterSpacing: 0.3,
              ),
            ),
            const Spacer(),
            Text(
              '${(v * 100).round()}%',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: p.indigo,
              ),
            ),
          ],
        ),
        Row(
          children: [
            GestureDetector(
              onTap: () => store.setFontScale((v - 0.05).clamp(0.85, 1.6)),
              child: Icon(Icons.remove_circle_outline,
                  size: 18, color: p.inkSoft),
            ),
            Expanded(
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
            GestureDetector(
              onTap: () => store.setFontScale((v + 0.05).clamp(0.85, 1.6)),
              child: Icon(Icons.add_circle_outline,
                  size: 18, color: p.inkSoft),
            ),
          ],
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

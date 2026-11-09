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
              // Miniature of the surface spec: radius, border and edge bar are
              // exactly what separates the four designs.
              Container(
                width: 46,
                height: 40,
                decoration: BoxDecoration(
                  color: p.card,
                  borderRadius: BorderRadius.circular(s.radius),
                  border: s.borderWidth == 0
                      ? null
                      : Border.all(color: p.line, width: s.borderWidth),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: s.edgeBar ? 4 : 0,
                    height: 40,
                    decoration: BoxDecoration(
                      color: p.indigo,
                      borderRadius: BorderRadius.circular(s.radius),
                    ),
                  ),
                ),
              ),
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

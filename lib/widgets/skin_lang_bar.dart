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
      builder: (ctx, s, _) => Padding(
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
                    onTap: () {
                      s.setSkinKey(id);
                      Navigator.pop(ctx);
                    },
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
          ],
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

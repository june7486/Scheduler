import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/calendar_service.dart';
import '../services/session_service.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';
import '../widgets/settings_panels.dart';
import '../widgets/skin_lang_bar.dart';
import 'admin_screen.dart';
import 'login_screen.dart';
import 'report_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('settings'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (store.isMaster) ...[
              _Group(context.tr('master_admin')),
              _Tile(
                icon: Icons.admin_panel_settings_outlined,
                title: context.tr('master_console'),
                subtitle: context.tr('master_console_hint'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AdminScreen()),
                ),
              ),
              _Tile(
                icon: Icons.summarize_outlined,
                title: context.tr('user_reports'),
                subtitle:
                    'ID status · per-ID schedules · by-date, with preview',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ReportScreen()),
                ),
              ),
            ],
            _Group(context.tr('account')),
            _Tile(
              icon: Icons.lock_outline,
              title: context.tr('change_password'),
              subtitle: context.tr('current_user_is', args: {'id': store.username}),
              onTap: () => _changePassword(context, store),
            ),
            _Tile(
              icon: Icons.timer_outlined,
              title: context.tr('session_timeout'),
              subtitle: context.tr('session_1h'),
              onTap: () async {
                final m = await SessionService().remainingMinutes();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('session_remaining', args: {'m': '$m'}))),
                );
              },
            ),
            _Group(context.tr('items_tabs')),
            _Tile(
              icon: Icons.tab_outlined,
              title: context.tr('manage_tabs'),
              subtitle: context.tr('active_tabs', args: {'n': '${store.enabledCategories.length}'}),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ManageTabsScreen()),
              ),
            ),
            _Tile(
              icon: Icons.sort_outlined,
              title: context.tr('reorder_items'),
              subtitle: context.tr('reorder_hint'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ManageTabsScreen()),
              ),
            ),
            _Group(context.tr('output')),
            _Tile(
              icon: Icons.print_outlined,
              title: context.tr('output_items'),
              subtitle:
                  'Design mode: ${store.printDesignMode} · font ${store.baseFontSize.toStringAsFixed(0)}pt',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const OutputSettingsScreen()),
              ),
            ),
            _Group(context.tr('data_grp')),
            _Tile(
              icon: Icons.backup_outlined,
              title: context.tr('backup_all'),
              subtitle: context.tr('backup_hint'),
              onTap: () => _backup(context, store),
            ),
            _Tile(
              icon: Icons.restore_outlined,
              title: context.tr('restore'),
              subtitle: context.tr('restore_hint'),
              onTap: () => _restore(context, store),
            ),
            _Tile(
              icon: Icons.cleaning_services_outlined,
              title: context.tr('clear_cache'),
              subtitle: context.tr('clear_cache_hint'),
              onTap: () async {
                await store.clearCache();
                await SessionService().clearCache();
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(context.tr('cache_cleared'))));
              },
            ),
            _Tile(
              icon: Icons.delete_forever_outlined,
              title: context.tr('reset_all'),
              subtitle: context.tr('reset_hint'),
              danger: true,
              onTap: () => _wipe(context, store),
            ),
            _Group(context.tr('activity_log')),
            _Tile(
              icon: Icons.history,
              title: context.tr('activity_log'),
              subtitle: context.tr('entries', args: {'n': '${store.logs.length}'}),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LogScreen()),
              ),
            ),
            _Group(context.tr('display_grp')),
            _Tile(
              icon: Icons.palette_outlined,
              title: context.tr('skin'),
              subtitle: '${AppSkins.emojiFor(store.skinKey)}  ${context.tr('skin_${store.skinKey}')}',
              onTap: () => showSkinPicker(context, store),
            ),
            _Tile(
              icon: Icons.language_outlined,
              title: context.tr('language'),
              subtitle: '${context.tr('language_korean')} (${store.language == 'ko' ? '●' : '○'})  ·  '
                  '${context.tr('language_english')} (${store.language == 'en' ? '●' : '○'})',
              onTap: () => _pickLanguage(context, store),
            ),
            _Tile(
              icon: Icons.brightness_6_outlined,
              title: context.tr('screen_theme'),
              subtitle: _themeLabel(context, store),
              onTap: () => _pickTheme(context, store),
            ),
            _Group(context.tr('calendar_grp')),
            _Tile(
              icon: Icons.event_available_outlined,
              title: context.tr('calendar_sync'),
              subtitle: _calLabel(context, store),
              onTap: () => _pickCalendar(context, store),
            ),
            _Tile(
              icon: Icons.open_in_new,
              title: context.tr('open_calendar'),
              subtitle: context.tr('open_calendar_hint'),
              onTap: () => CalendarService.openCalendar(),
            ),
            _Group(context.tr('app_grp')),
            _Tile(
              icon: Icons.info_outline,
              title: context.tr('app_version'),
              subtitle:
                  'v${store.appVersion} (defined by stored build date & time)',
              onTap: () => _showVersion(context, store),
            ),
            _Tile(
              icon: Icons.link,
              title: context.tr('forward_address'),
              subtitle: store.forwardUrl,
              onTap: () => _editForwardUrl(context, store),
            ),
            _Tile(
              icon: Icons.open_in_new,
              title: context.tr('open_forward'),
              subtitle: store.forwardUrl,
              onTap: () async {
                final uri = Uri.parse(store.forwardUrl);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
            _Tile(
              icon: Icons.logout_rounded,
              title: context.tr('sign_out'),
              subtitle: context.tr('session_end'),
              onTap: () async {
                await SessionService().logout();
                if (!context.mounted) return;
                context.read<Store>().logoutCurrent();
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                );
              },
            ),
            const SizedBox(height: 24),
            Center(
              child: Text(
                'June\'s Scheduler · v${store.appVersion}',
                style: TextStyle(fontSize: 11, color: p.inkSoft),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _changePassword(BuildContext context, Store store) {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('change_password')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration: InputDecoration(hintText: context.tr('current_password')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: InputDecoration(hintText: context.tr('new_password')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              if (oldCtrl.text == store.password && newCtrl.text.length >= 4) {
                store.setPassword(newCtrl.text);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('password_updated'))),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.tr('check_pw')),
                  ),
                );
              }
            },
            child: Text(context.tr('save')),
          ),
        ],
      ),
    );
  }

  void _showVersion(BuildContext context, Store store) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('app_version')),
        content: Text(
          'v${store.appVersion}\n\n${context.tr('app_version_hint')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('ok')),
          ),
        ],
      ),
    );
  }

  void _editForwardUrl(BuildContext context, Store store) {
    final ctrl = TextEditingController(text: store.forwardUrl);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('forward_address')),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'https://example.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              store.setForwardUrl(ctrl.text.trim());
              Navigator.pop(context);
            },
            child: Text(context.tr('save')),
          ),
        ],
      ),
    );
  }

  Future<void> _backup(BuildContext context, Store store) async {
    final json = const JsonEncoder.withIndent(
      '  ',
    ).convert(store.exportBackup());
    final bytes = utf8.encode(json);
    await Share.shareXFiles([
      XFile.fromData(
        bytes,
        mimeType: 'application/json',
        name: 'june_scheduler_backup.json',
      ),
    ], subject: "June's Scheduler backup");
    store.addLog('Backup');
  }

  void _restore(BuildContext context, Store store) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('restore_backup')),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: ctrl,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: context.tr('paste_backup'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () async {
              try {
                final data = jsonDecode(ctrl.text) as Map<String, dynamic>;
                await store.importBackup(data);
                if (!context.mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('restore_done'))),
                );
              } catch (e) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(context.tr('invalid_backup', args: {'err': '$e'}))));
              }
            },
            child: Text(context.tr('restore')),
          ),
        ],
      ),
    );
  }

  String _themeLabel(BuildContext context, Store store) {
    switch (store.themeModeKey) {
      case 'light':
        return context.tr('light_mode');
      case 'dark':
        return context.tr('dark_mode');
      default:
        return context.tr('follow_system');
    }
  }

  String _calLabel(BuildContext context, Store store) {
    switch (store.calendarMode) {
      case 'manual':
        return context.tr('cal_mode_manual');
      case 'auto':
        return context.tr('cal_mode_auto');
      default:
        return context.tr('cal_mode_off');
    }
  }

  void _pickCalendar(BuildContext context, Store store) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                context.tr('calendar_sync'),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                context.tr('calendar_hint'),
                style: TextStyle(fontSize: 11.5, color: p.inkSoft),
              ),
            ),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: store.calendarMode,
              onChanged: (v) async {
                if (v == null) return;
                await store.setCalendarMode(v);
                if (!context.mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('calendar_changed'))),
                );
              },
              child: Column(
                children: [
                  RadioListTile<String>(
                    value: 'off',
                    activeColor: p.indigo,
                    secondary: const Icon(Icons.block_outlined),
                    title: Text(context.tr('cal_mode_off')),
                    subtitle: Text(context.tr('cal_mode_off_hint'),
                        style: const TextStyle(fontSize: 11)),
                  ),
                  RadioListTile<String>(
                    value: 'manual',
                    activeColor: p.indigo,
                    secondary: const Icon(Icons.touch_app_outlined),
                    title: Text(context.tr('cal_mode_manual')),
                    subtitle: Text(context.tr('cal_mode_manual_hint'),
                        style: const TextStyle(fontSize: 11)),
                  ),
                  RadioListTile<String>(
                    value: 'auto',
                    activeColor: p.indigo,
                    secondary: const Icon(Icons.sync_outlined),
                    title: Text(context.tr('cal_mode_auto')),
                    subtitle: Text(context.tr('cal_mode_auto_hint'),
                        style: const TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _pickLanguage(BuildContext context, Store store) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                context.tr('language'),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                context.tr('language_hint'),
                style: TextStyle(fontSize: 11.5, color: p.inkSoft),
              ),
            ),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: store.language,
              onChanged: (v) async {
                if (v == null) return;
                await store.setLanguage(v);
                if (!context.mounted) return;
                Navigator.pop(context);
              },
              child: Column(
                children: [
                  RadioListTile<String>(
                    value: 'ko',
                    activeColor: p.indigo,
                    title: Text(context.tr('language_korean')),
                  ),
                  RadioListTile<String>(
                    value: 'en',
                    activeColor: p.indigo,
                    title: Text(context.tr('language_english')),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _pickTheme(BuildContext context, Store store) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                context.tr('screen_theme'),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: store.themeModeKey,
              onChanged: (v) async {
                if (v == null) return;
                await store.setThemeModeKey(v);
                if (!context.mounted) return;
                Navigator.pop(context);
              },
              child: Column(
                children: [
                  RadioListTile<String>(
                    value: 'system',
                    activeColor: p.indigo,
                    secondary: const Icon(Icons.settings_suggest_outlined),
                    title: Text(context.tr('follow_system')),
                  ),
                  RadioListTile<String>(
                    value: 'light',
                    activeColor: p.indigo,
                    secondary: const Icon(Icons.light_mode_outlined),
                    title: Text(context.tr('light_mode')),
                  ),
                  RadioListTile<String>(
                    value: 'dark',
                    activeColor: p.indigo,
                    secondary: const Icon(Icons.dark_mode_outlined),
                    title: Text(context.tr('dark_mode')),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _wipe(BuildContext context, Store store) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('reset_content_q')),
        content: Text(context.tr('reset_content_msg')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () async {
              await store.wipeAll();
              if (!context.mounted) return;
              Navigator.pop(context);
            },
            child: Text(
              context.tr('reset'),
              style: TextStyle(color: p.danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String text;
  const _Group(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        color: p.indigo,
        letterSpacing: 1.0,
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        icon,
        size: 20,
        color: danger ? p.danger : p.indigo,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: danger ? p.danger : p.ink,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11.5, color: p.inkSoft),
      ),
      trailing: Icon(
        Icons.chevron_right,
        size: 18,
        color: p.inkSoft,
      ),
      onTap: onTap,
    );
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/calendar_service.dart';
import '../services/drive_service.dart';
import '../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../services/file_pick_web.dart' as picker;
import '../services/session_service.dart';
import '../services/sync_service.dart';
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
              icon: Icons.file_open_outlined,
              title: context.tr('restore_file'),
              subtitle: context.tr('restore_file_hint'),
              onTap: () => _restoreFromFile(context, store),
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
            _Group(context.tr('sync_grp')),
            _SyncPanel(store: store),
            _Group(context.tr('drive_grp')),
            _Tile(
              icon: Icons.add_to_drive_outlined,
              title: context.tr('drive_backup'),
              subtitle: context.tr('drive_backup_hint'),
              onTap: () => _backupToDrive(context, store),
            ),
            _Tile(
              icon: Icons.cloud_upload_outlined,
              title: context.tr('drive_upload'),
              subtitle: context.tr('drive_upload_hint'),
              onTap: () => _uploadToDrive(context, store),
            ),
            _Tile(
              icon: Icons.folder_open_outlined,
              title: context.tr('drive_open'),
              subtitle: _driveShort(store.driveUrl),
              onTap: () => DriveService.openFolder(store.driveUrl),
            ),
            _Tile(
              icon: Icons.edit_outlined,
              title: context.tr('drive_edit_link'),
              subtitle: _driveShort(store.driveUrl),
              onTap: () => _editDriveUrl(context, store),
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

  // ---------------- Google Drive ----------------

  String _driveShort(String url) {
    final m = RegExp(r'/(?:folders|d)/([A-Za-z0-9_-]+)').firstMatch(url);
    final id = m?.group(1);
    if (id == null) return url;
    return 'Google Drive \u00b7 ${id.substring(0, id.length < 8 ? id.length : 8)}\u2026';
  }

  String _driveStamp() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${p(n.month)}${p(n.day)}_${p(n.hour)}${p(n.minute)}';
  }

  /// Backs up all data to Google Drive: on web it downloads the JSON backup and
  /// opens the Drive folder so it can be dropped in; on mobile it shares the
  /// file so it can be saved to Drive.
  Future<void> _backupToDrive(BuildContext context, Store store) async {
    final messenger = ScaffoldMessenger.of(context);
    final dlMsg = context.tr('drive_downloaded');
    final doneMsg = context.tr('drive_backup_done');
    final name = 'june_scheduler_backup_${_driveStamp()}.json';
    final status = await DriveService.saveToDrive(
      store.exportBackup(),
      folderUrl: store.driveUrl,
      name: name,
    );
    store.addLog('Drive backup', name);
    final msg = status == 'drive_downloaded' ? dlMsg : doneMsg;
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Uploads the current data to Google Drive (download on web / share sheet on
  /// mobile, then opens the Drive folder).
  Future<void> _uploadToDrive(BuildContext context, Store store) async {
    final messenger = ScaffoldMessenger.of(context);
    final dlMsg = context.tr('drive_downloaded');
    final doneMsg = context.tr('drive_upload_done');
    final name = 'june_scheduler_upload_${_driveStamp()}.json';
    final status = await DriveService.saveToDrive(
      store.exportBackup(),
      folderUrl: store.driveUrl,
      name: name,
    );
    store.addLog('Drive upload', name);
    final msg = status == 'drive_downloaded' ? dlMsg : doneMsg;
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  void _editDriveUrl(BuildContext context, Store store) {
    final ctrl = TextEditingController(text: store.driveUrl);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('drive_edit_link')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('drive_link_hint'),
              style: TextStyle(fontSize: 11.5, color: p.inkSoft),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                hintText: 'https://drive.google.com/drive/folders/...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () async {
              await store.setDriveUrl(ctrl.text);
              if (!context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.tr('drive_link_saved'))),
              );
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

  /// Restores a backup JSON chosen from the device (web: file picker).
  Future<void> _restoreFromFile(BuildContext context, Store store) async {
    final messenger = ScaffoldMessenger.of(context);
    final okMsg = context.tr('restore_done');
    final cancelMsg = context.tr('restore_cancelled');
    final badMsg = context.tr('invalid_backup', args: {'err': 'JSON'});

    final text = await picker.pickTextFile();
    if (text == null) {
      messenger.showSnackBar(SnackBar(content: Text(cancelMsg)));
      return;
    }
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      await store.importBackup(data);
      messenger.showSnackBar(SnackBar(content: Text(okMsg)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(badMsg)));
    }
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

/// Cross-device sync controls: status, workspace code, manual sync, on/off.
class _SyncPanel extends StatelessWidget {
  final Store store;
  const _SyncPanel({required this.store});

  @override
  Widget build(BuildContext context) {
    final ko = store.language == 'ko';
    final svc = store.sync;
    final on = store.syncEnabled;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  on ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                  size: 18,
                  color: on ? p.indigo : p.inkSoft,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ko ? '기기 간 자동 동기화' : 'Sync across devices',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                ),
                Switch(
                  value: on,
                  activeThumbColor: p.indigo,
                  onChanged: (v) async {
                    if (v) {
                      await svc.start();
                      if (!store.syncEnabled) {
                        // Nothing configured yet → open the setup dialog.
                        await _setup(context, ko: ko);
                      }
                    } else {
                      await store.setSyncConfig(enabled: false);
                      svc.stop();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              on
                  ? svc.statusLabel(ko: ko)
                  : (ko
                        ? '꺼져 있음 — PC와 휴대폰 내용이 서로 다릅니다'
                        : 'Off — each device keeps its own data'),
              style: TextStyle(fontSize: 11.5, color: p.inkSoft),
            ),
            if (on) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    ko ? '동기화 코드' : 'Sync code',
                    style: TextStyle(fontSize: 11.5, color: p.inkSoft),
                  ),
                  const SizedBox(width: 8),
                  SelectableText(
                    store.syncCode,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                      color: p.ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _chipBtn(
                    icon: Icons.sync,
                    label: ko ? '지금 동기화' : 'Sync now',
                    onTap: () async {
                      try {
                        await svc.pull();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ko ? '동기화 완료' : 'Synced'),
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$e')),
                          );
                        }
                      }
                    },
                  ),
                  _chipBtn(
                    icon: Icons.copy_outlined,
                    label: ko ? '코드 복사' : 'Copy code',
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(text: store.syncCode),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              ko
                                  ? '코드를 복사했습니다 — 다른 기기에 입력하세요'
                                  : 'Copied — enter it on your other device',
                            ),
                          ),
                        );
                      }
                    },
                  ),
                  _chipBtn(
                    icon: Icons.refresh,
                    label: ko ? '새로 시작' : 'New code',
                    onTap: () async {
                      final oldCode = store.syncCode;
                      if (oldCode.isNotEmpty) {
                        await Clipboard.setData(ClipboardData(text: oldCode));
                      }
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ko
                                ? '새 코드를 발급했습니다. 이전 코드($oldCode)는 복사해 두었습니다.'
                                : 'New code issued. Old code ($oldCode) copied.',
                          ),
                          duration: const Duration(seconds: 5),
                        ),
                      );
                      await svc.createWorkspace();
                    },
                  ),
                  _chipBtn(
                    icon: Icons.login,
                    label: ko ? '코드로 연결' : 'Join by code',
                    onTap: () => _setup(context, ko: ko),
                  ),
                ],
              ),
              if (svc.lastSync != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${ko ? '마지막 동기화' : 'Last sync'} · '
                  '${_hhmmss(svc.lastSync!)}',
                  style: TextStyle(fontSize: 11, color: p.inkSoft),
                ),
              ],
            ] else ...[
              const SizedBox(height: 10),
              _chipBtn(
                icon: Icons.power_settings_new,
                label: ko ? '동기화 켜기' : 'Turn on sync',
                onTap: () => _setup(context, ko: ko),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _hhmmss(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';

  Widget _chipBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.indigo.withValues(alpha: 0.55)),
          color: p.indigo.withValues(alpha: 0.08),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: p.indigo),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: p.indigo,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Asks for an existing code (join) or offers to create a new workspace.
  Future<void> _setup(BuildContext context, {required bool ko}) async {
    final ctrl = TextEditingController(text: store.syncCode);
    final urlCtrl = TextEditingController(text: store.syncUrl);
    final svc = store.sync;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ko ? '자동 동기화 연결' : 'Connect auto-sync'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ko
                    ? 'PC에서 만든 코드를 휴대폰에 입력하면 두 기기가 같은 내용을 봅니다.'
                    : 'Enter the code from your PC so both devices show the same data.',
                style: TextStyle(fontSize: 12, color: p.inkSoft),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: ko ? '동기화 코드' : 'Sync code',
                  hintText: 'ABCD2345XY',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  labelText: ko ? '동기화 서버 (선택)' : 'Sync server (optional)',
                  hintText: SyncService.defaultBaseUrl,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ko ? '취소' : 'Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await store.setSyncConfig(url: urlCtrl.text.trim());
              final code = ctrl.text.trim();
              Navigator.pop(ctx);
              if (code.isEmpty) {
                await svc.createWorkspace();
              } else {
                await svc.joinWorkspace(code);
              }
            },
            child: Text(ko ? '연결' : 'Connect'),
          ),
        ],
      ),
    );
  }
}

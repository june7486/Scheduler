import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/calendar_service.dart';
import '../services/drive_service.dart';
import '../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../services/file_pick_web.dart' as picker;
import '../services/session_service.dart';
import '../services/cloud/sync_engine.dart';
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
            _Tile(
              icon: Icons.cloud_off_outlined,
              title: context.tr('reset_everywhere'),
              subtitle: context.tr('reset_everywhere_hint'),
              danger: true,
              onTap: () => _wipeEverywhere(context, store),
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
              icon: Icons.design_services_outlined,
              title: context.tr('design'),
              subtitle:
                  '${AppDesigns.of(store.designKey).emoji}  ${context.tr('design_${store.designKey}')}',
              onTap: () => showDesignPicker(context, store),
            ),
            _Tile(
              icon: Icons.palette_outlined,
              title: context.tr('choose_color'),
              subtitle:
                  '${AppSkins.emojiFor(store.skinKey)}  ${context.tr('skin_${store.skinKey}')}',
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
            const _NasPanel(),
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

  /// Wipes the workspace **on the server**, so every device follows.
  ///
  /// This is the "모든 앱 초기화" the user asked for. It is deliberately a
  /// separate, scarier action than the local wipe: a local wipe is undone by the
  /// next sync (the server still has everything), while this one is the truth.
  void _wipeEverywhere(BuildContext context, Store store) {
    var typed = '';
    final ready = ValueNotifier<bool>(false);

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('reset_everywhere')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('reset_everywhere_msg'),
              style: TextStyle(fontSize: 12.5, height: 1.45, color: p.inkSoft),
            ),
            const SizedBox(height: 14),
            ValueListenableBuilder<bool>(
              valueListenable: ready,
              builder: (_, ok, __) => TextField(
                enabled: !ok,
                onChanged: (v) => typed = v,
                decoration: InputDecoration(
                  hintText: context.tr('reset_type_word'),
                  isDense: true,
                ),
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
              // Requiring the literal word is the whole point: an irreversible,
              // all-devices action should not be one stray tap away.
              if (typed.trim().toUpperCase() != 'RESET') {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('reset_type_word'))),
                );
                return;
              }
              ready.value = true; // disable the field while it runs
              final err = await store.sync.resetRemote();
              if (!context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    err == null
                        ? context.tr('reset_everywhere_done')
                        : '${context.tr('reset_everywhere_fail')}: $err',
                  ),
                ),
              );
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

/// Cloud storage status. Everything is automatic — no codes, no toggles:
/// signing in binds the device to that account's server document.
class _SyncPanel extends StatelessWidget {
  final Store store;
  const _SyncPanel({required this.store});

  @override
  Widget build(BuildContext context) {
    final svc = store.sync;
    final ko = context.l10n.lang == AppLang.ko;
    final live = svc.state == SyncState.idle || svc.state == SyncState.syncing;
    final syncing = svc.state == SyncState.syncing || svc.pendingCount > 0;
    final notConfigured = svc.state == SyncState.notConfigured;

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
                  notConfigured
                      ? Icons.cloud_off_outlined
                      : live
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_queue_outlined,
                  size: 18,
                  color: notConfigured
                      ? p.danger
                      : live
                          ? p.teal
                          : p.inkSoft,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr('sync_grp'),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                ),
                if (syncing && !notConfigured)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: p.teal,
                    ),
                  )
                else
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (notConfigured
                              ? p.danger
                              : live
                                  ? p.teal
                                  : p.inkSoft)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      live ? context.tr('sync_live') : svc.statusLabel(ko: ko),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: notConfigured
                            ? p.danger
                            : live
                                ? p.teal
                                : p.inkSoft,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              context.tr('sync_server_copy'),
              style: TextStyle(fontSize: 11.5, color: p.inkSoft, height: 1.35),
            ),
            const SizedBox(height: 4),
            Text(
              context.tr('sync_auto_note'),
              style: TextStyle(fontSize: 11, color: p.inkSoft, height: 1.35),
            ),
            if (notConfigured)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  ko
                      ? 'Firebase 프로젝트를 연결하면 모든 기기에서 같은 자료를 봅니다.'
                      : 'Connect a Firebase project to share one dataset across devices.',
                  style: TextStyle(fontSize: 10.5, color: p.danger, height: 1.35),
                ),
              ),
            if (store.syncEnabled && svc.pendingCount > 0 && !notConfigured)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(Icons.cloud_upload_outlined, size: 12, color: p.teal),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        context.tr('sync_pending_n',
                            args: {'n': '${svc.pendingCount}'}),
                        style: TextStyle(fontSize: 10.5, color: p.teal),
                      ),
                    ),
                  ],
                ),
              ),
            if (svc.lastSync != null && !notConfigured)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${context.tr('sync_last')} · ${_hhmmss(svc.lastSync!)}'
                  ' · ${context.tr('sync_stored_on_server')}',
                  style: TextStyle(fontSize: 10.5, color: p.inkSoft),
                ),
              ),
            if (svc.state == SyncState.offline)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  context.tr('sync_offline_retry'),
                  style: TextStyle(fontSize: 10.5, color: p.danger),
                ),
              ),
            if (!notConfigured && store.syncEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => svc.syncNow(),
                    icon: const Icon(Icons.refresh, size: 14),
                    label: Text(
                      ko ? '지금 동기화' : 'Sync now',
                      style: const TextStyle(fontSize: 11),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: p.teal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _hhmmss(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';
}

/// Points the app at a sync server the user runs themselves (`server/nas/`).
///
/// Deliberately plain: one address, one optional key, two buttons. Leaving the
/// address empty returns the app to the hosted cloud, so the panel can never
/// trap a user in a half-configured state.
class _NasPanel extends StatefulWidget {
  const _NasPanel();

  @override
  State<_NasPanel> createState() => _NasPanelState();
}

class _NasPanelState extends State<_NasPanel> {
  late final TextEditingController _url =
      TextEditingController(text: context.read<Store>().nasUrl);
  late final TextEditingController _key =
      TextEditingController(text: context.read<Store>().nasSecret);

  bool _busy = false;
  bool _expanded = false;
  String _note = '';
  bool _noteOk = false;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final store = context.read<Store>();
    setState(() {
      _busy = true;
      _note = '';
    });
    final ok = await store.pingNas(
      url: _url.text,
      secret: _key.text,
    );
    if (!mounted) return;
    final ko = context.l10n.lang == AppLang.ko;
    setState(() {
      _busy = false;
      _noteOk = ok;
      _note = ok
          ? context.tr('nas_ok')
          : (ko ? 'NAS에 연결하지 못했습니다 — 주소와 키를 확인하세요' : context.tr('nas_fail'));
    });
  }

  Future<void> _save() async {
    final store = context.read<Store>();
    setState(() {
      _busy = true;
      _note = '';
    });
    await store.useNasBackend(url: _url.text, secret: _key.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _noteOk = true;
      _note = context.tr('nas_saved');
    });
    // A fresh engine is live now; nudge it once so the panel shows the truth.
    unawaited(store.sync.syncNow());
  }

  Future<void> _clear() async {
    final store = context.read<Store>();
    setState(() => _busy = true);
    await store.useNasBackend(url: '', secret: '');
    if (!mounted) return;
    _url.text = '';
    _key.text = '';
    setState(() {
      _busy = false;
      _noteOk = true;
      _note = context.tr('nas_cleared');
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.ac;
    final store = context.watch<Store>();
    final ko = context.l10n.lang == AppLang.ko;
    final active = store.usingNas;

    // The one real trap of a self-hosted backend: a browser refuses to let an
    // HTTPS page call an http:// address (mixed content). It looks like "the
    // NAS is broken" and no amount of retrying fixes it, so say it plainly
    // before the user types it in.
    final mixedBlocked = kIsWeb &&
        Uri.base.scheme == 'https' &&
        _url.text.trim().toLowerCase().startsWith('http://');

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
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
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(Icons.dns_outlined,
                      size: 18, color: active ? p.teal : p.inkSoft),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.tr('nas_grp'),
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (active ? p.teal : p.inkSoft)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      active ? context.tr('nas_active') : context.tr('nas_cloud'),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: active ? p.teal : p.inkSoft,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: p.inkSoft),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              context.tr('nas_guide'),
              style: TextStyle(fontSize: 11, color: p.inkSoft, height: 1.35),
            ),
            if (_expanded) ...[
              const SizedBox(height: 10),
              _NasField(
                controller: _url,
                label: context.tr('nas_title'),
                hint: context.tr('nas_hint'),
                enabled: !_busy,
                keyboard: TextInputType.url,
              ),
              const SizedBox(height: 8),
              _NasField(
                controller: _key,
                label: context.tr('nas_key'),
                hint: context.tr('nas_key_hint'),
                enabled: !_busy,
                obscure: true,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: _busy
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : const Icon(Icons.save_outlined, size: 15),
                    label: Text(
                      context.tr('nas_save'),
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: p.teal,
                      foregroundColor: p.onAccent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _busy ? null : _test,
                    style: TextButton.styleFrom(
                      foregroundColor: p.inkSoft,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      context.tr('nas_test'),
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                  const Spacer(),
                  if (active)
                    TextButton(
                      onPressed: _busy ? null : _clear,
                      style: TextButton.styleFrom(
                        foregroundColor: p.danger,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        ko ? '해제' : 'Clear',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
              if (_note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _note,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: _noteOk ? p.teal : p.danger,
                      height: 1.35,
                    ),
                  ),
                ),
              if (mixedBlocked)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    ko
                        ? '이 사이트는 https입니다. 브라우저는 https 페이지에서 '
                            'http:// 주소로 접속하는 것을 막습니다. '
                            'NAS를 https(역프록시·인증서)로 열거나, 안드로이드 앱에서 사용하세요.'
                        : 'This site is https. Browsers block an https page from '
                            'calling http://. Serve the NAS over https '
                            '(reverse proxy + certificate) or use the Android app.',
                    style: TextStyle(fontSize: 10.5, color: p.danger, height: 1.35),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NasField extends StatelessWidget {
  const _NasField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.enabled,
    this.obscure = false,
    this.keyboard,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;
  final bool obscure;
  final TextInputType? keyboard;

  @override
  Widget build(BuildContext context) {
    final p = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: p.inkSoft,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          enabled: enabled,
          obscureText: obscure,
          keyboardType: keyboard,
          autocorrect: false,
          style: TextStyle(fontSize: 12.5, color: p.ink),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(fontSize: 11.5, color: p.inkSoft),
            filled: true,
            fillColor: p.soft,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: p.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: p.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: p.teal),
            ),
          ),
        ),
      ],
    );
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/session_service.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';
import '../widgets/settings_panels.dart';
import 'admin_screen.dart';
import 'login_screen.dart';
import 'report_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (store.isMaster) ...[
              _Group('Master administration'),
              _Tile(
                icon: Icons.admin_panel_settings_outlined,
                title: 'Master console',
                subtitle: 'Manage IDs, passwords, and view all users\' data',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AdminScreen()),
                ),
              ),
              _Tile(
                icon: Icons.summarize_outlined,
                title: 'User reports & output',
                subtitle:
                    'ID status · per-ID schedules · by-date, with preview',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ReportScreen()),
                ),
              ),
            ],
            _Group('Account'),
            _Tile(
              icon: Icons.lock_outline,
              title: 'Change password',
              subtitle: 'Currently set for user "${store.username}"',
              onTap: () => _changePassword(context, store),
            ),
            _Tile(
              icon: Icons.timer_outlined,
              title: 'Session timeout',
              subtitle: 'Kept signed in for 1 hour, then re-login required',
              onTap: () async {
                final m = await SessionService().remainingMinutes();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Session remaining: ~$m min')),
                );
              },
            ),
            _Group('Items & Tabs'),
            _Tile(
              icon: Icons.tab_outlined,
              title: 'Manage tabs / categories',
              subtitle: '${store.enabledCategories.length} active tabs',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ManageTabsScreen()),
              ),
            ),
            _Tile(
              icon: Icons.sort_outlined,
              title: 'Reorder items',
              subtitle: 'Drag to change the order of tabs',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ManageTabsScreen()),
              ),
            ),
            _Group('Output'),
            _Tile(
              icon: Icons.print_outlined,
              title: 'Output items & design',
              subtitle:
                  'Design mode: ${store.printDesignMode} · font ${store.baseFontSize.toStringAsFixed(0)}pt',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const OutputSettingsScreen()),
              ),
            ),
            _Group('Data'),
            _Tile(
              icon: Icons.backup_outlined,
              title: 'Backup all data',
              subtitle: 'Export tasks, tabs, settings & voice notes as JSON',
              onTap: () => _backup(context, store),
            ),
            _Tile(
              icon: Icons.restore_outlined,
              title: 'Restore from backup',
              subtitle: 'Paste a backup JSON to restore',
              onTap: () => _restore(context, store),
            ),
            _Tile(
              icon: Icons.cleaning_services_outlined,
              title: 'Clear cache',
              subtitle: 'Clears logs and cached version info',
              onTap: () async {
                await store.clearCache();
                await SessionService().clearCache();
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Cache cleared.')));
              },
            ),
            _Tile(
              icon: Icons.delete_forever_outlined,
              title: 'Reset all content',
              subtitle: 'Delete every task and restore default tabs',
              danger: true,
              onTap: () => _wipe(context, store),
            ),
            _Group('Activity log'),
            _Tile(
              icon: Icons.history,
              title: 'Activity log',
              subtitle: '${store.logs.length} entries',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LogScreen()),
              ),
            ),
            _Group('App'),
            _Tile(
              icon: Icons.info_outline,
              title: 'App version',
              subtitle:
                  'v${store.appVersion} (defined by stored build date & time)',
              onTap: () => _showVersion(context, store),
            ),
            _Tile(
              icon: Icons.link,
              title: 'Forwarding address',
              subtitle: store.forwardUrl,
              onTap: () => _editForwardUrl(context, store),
            ),
            _Tile(
              icon: Icons.open_in_new,
              title: 'Open forwarding site',
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
              title: 'Sign out',
              subtitle: 'End the current session now',
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
                style: const TextStyle(fontSize: 11, color: AppColors.inkSoft),
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
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration: const InputDecoration(hintText: 'Current password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(hintText: 'New password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (oldCtrl.text == store.password && newCtrl.text.length >= 4) {
                store.setPassword(newCtrl.text);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password updated.')),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Check current password / min 4 chars.'),
                  ),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showVersion(BuildContext context, Store store) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('App version'),
        content: Text(
          'Version: v${store.appVersion}\n\n'
          'The version string is derived from the stored year, date and time. '
          'On a new visit, if the stored version is older, the app clears the '
          'cache and downloads the latest data again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
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
        title: const Text('Forwarding address'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'https://example.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              store.setForwardUrl(ctrl.text.trim());
              Navigator.pop(context);
            },
            child: const Text('Save'),
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
        title: const Text('Restore from backup'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: ctrl,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'Paste backup JSON here',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              try {
                final data = jsonDecode(ctrl.text) as Map<String, dynamic>;
                await store.importBackup(data);
                if (!context.mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Backup restored.')),
                );
              } catch (e) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Invalid backup: $e')));
              }
            },
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  void _wipe(BuildContext context, Store store) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset all content?'),
        content: const Text(
          'This deletes all tasks and restores default tabs.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await store.wipeAll();
              if (!context.mounted) return;
              Navigator.pop(context);
            },
            child: const Text(
              'Reset',
              style: TextStyle(color: AppColors.danger),
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
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        color: AppColors.indigo,
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
        color: danger ? AppColors.danger : AppColors.indigo,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: danger ? AppColors.danger : AppColors.ink,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 11.5, color: AppColors.inkSoft),
      ),
      trailing: const Icon(
        Icons.chevron_right,
        size: 18,
        color: AppColors.inkSoft,
      ),
      onTap: onTap,
    );
  }
}

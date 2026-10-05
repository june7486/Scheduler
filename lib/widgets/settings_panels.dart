import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';

/// Manage tabs/categories: add, rename, reorder, enable/disable, delete.
class ManageTabsScreen extends StatelessWidget {
  const ManageTabsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final cats = store.categories;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('manage_tabs_title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, size: 22),
            tooltip: context.tr('add_tab'),
            onPressed: () => _addTab(context, store),
          ),
        ],
      ),
      body: SafeArea(
        child: ReorderableListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: cats.length,
          onReorder: (oldI, newI) {
            if (newI > oldI) newI--;
            final list = [...cats];
            final item = list.removeAt(oldI);
            list.insert(newI, item);
            store.reorderCategories(list);
          },
          itemBuilder: (_, i) {
            final c = cats[i];
            final col = Color(c.colorValue);
            return Card(
              key: ValueKey(c.id),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: col.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(c.emoji, style: const TextStyle(fontSize: 16)),
                ),
                title: Text(
                  catLabel(c),
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Row(
                  children: [
                    Text(
                      c.showInTopTabs
                          ? context.tr('top_tab_on')
                          : context.tr('top_tab_off'),
                      style: TextStyle(
                        fontSize: 11,
                        color: p.inkSoft,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      context.tr('open_count', args: {
                        'n': '${store.taskCountFor(c.id)}',
                      }),
                      style: TextStyle(
                        fontSize: 11,
                        color: p.inkSoft,
                      ),
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: c.enabled,
                      activeThumbColor: p.indigo,
                      onChanged: (v) {
                        c.enabled = v;
                        store.saveCategory(c);
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 19,
                        color: p.danger,
                      ),
                      onPressed: () => _deleteTab(context, store, c),
                    ),
                  ],
                ),
                onTap: () => _editTab(context, store, c),
              ),
            );
          },
        ),
      ),
    );
  }

  void _addTab(BuildContext context, Store store) {
    final label = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('add_tab')),
        content: TextField(
          controller: label,
          decoration: InputDecoration(hintText: context.tr('tab_name')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              if (label.text.trim().isNotEmpty) {
                store.addCategory(label.text.trim());
              }
              Navigator.pop(context);
            },
            child: Text(context.tr('add')),
          ),
        ],
      ),
    );
  }

  void _editTab(BuildContext context, Store store, Category c) {
    final label = TextEditingController(text: catLabel(c));
    final emoji = TextEditingController(text: c.emoji);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('edit_tab')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              decoration: InputDecoration(hintText: context.tr('tab_name')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: emoji,
              decoration: InputDecoration(hintText: context.tr('emoji_hint')),
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
              c.label = label.text.trim().isEmpty ? c.label : label.text.trim();
              c.emoji = emoji.text.trim();
              store.saveCategory(c);
              Navigator.pop(context);
            },
            child: Text(context.tr('save')),
          ),
        ],
      ),
    );
  }

  void _deleteTab(BuildContext context, Store store, Category c) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.tr('delete_tab_q', args: {'name': catLabel(c)})),
        content: Text(context.tr('delete_tab_msg')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          TextButton(
            onPressed: () {
              store.deleteCategory(c.id);
              Navigator.pop(context);
            },
            child: Text(
              context.tr('delete'),
              style: TextStyle(color: p.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// Output settings (design mode, font, line spacing, orientation).
class OutputSettingsScreen extends StatelessWidget {
  const OutputSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('output_settings'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Head(context.tr('design_mode')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _modeChip(context, store, 'muji', context.tr('muji')),
                _modeChip(context, store, 'minimal', context.tr('minimal_design')),
                _modeChip(context, store, 'fancy', context.tr('fancy')),
                _modeChip(context, store, 'whitespace', context.tr('whitespace')),
              ],
            ),
            const SizedBox(height: 22),
            _Head(context.tr('default_font')),
            Text(
              '${store.baseFontSize.toStringAsFixed(0)} pt',
              style: TextStyle(fontSize: 12, color: p.inkSoft),
            ),
            Slider(
              value: store.baseFontSize,
              min: 8,
              max: 20,
              divisions: 12,
              activeColor: p.indigo,
              label: store.baseFontSize.toStringAsFixed(0),
              onChanged: (v) => store.setBaseFontSize(v),
            ),
            const SizedBox(height: 14),
            _Head(context.tr('app_theme')),
            Wrap(
              spacing: 8,
              children: [
                _themeChip(context, store, 'material', context.tr('theme_material')),
                _themeChip(context, store, 'minimal', context.tr('theme_minimal')),
                _themeChip(context, store, 'mix', context.tr('theme_mix')),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              context.tr('output_tip'),
              style: TextStyle(
                fontSize: 11.5,
                color: p.inkSoft,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeChip(
    BuildContext context,
    Store store,
    String value,
    String label,
  ) {
    final sel = store.printDesignMode == value;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: sel ? p.indigo : p.inkSoft,
        ),
      ),
      selected: sel,
      selectedColor: p.indigo.withValues(alpha: 0.14),
      side: BorderSide(color: sel ? p.indigo : p.line),
      onSelected: (_) => store.setPrintDesignMode(value),
    );
  }

  Widget _themeChip(
    BuildContext context,
    Store store,
    String value,
    String label,
  ) {
    final sel = store.appThemeMode == value;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: sel ? p.indigo : p.inkSoft,
        ),
      ),
      selected: sel,
      selectedColor: p.indigo.withValues(alpha: 0.14),
      side: BorderSide(color: sel ? p.indigo : p.line),
      onSelected: (_) => store.setAppThemeMode(value),
    );
  }
}

/// Activity log screen.
class LogScreen extends StatelessWidget {
  const LogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final logs = store.logs;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('activity_log')),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            tooltip: context.tr('clear_log'),
            onPressed: () => store.clearLogs(),
          ),
        ],
      ),
      body: SafeArea(
        child: logs.isEmpty
            ? Center(
                child: Text(
                  context.tr('no_activity'),
                  style: TextStyle(fontSize: 13, color: p.inkSoft),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: logs.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (_, i) {
                  final l = logs[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 6,
                          color: p.indigo,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.action,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (l.detail.isNotEmpty)
                                Text(
                                  l.detail,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: p.inkSoft,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '${l.timestamp.month}/${l.timestamp.day} '
                          '${l.timestamp.hour.toString().padLeft(2, '0')}:'
                          '${l.timestamp.minute.toString().padLeft(2, '0')}',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: p.inkSoft,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  final String text;
  const _Head(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: p.ink,
      ),
    ),
  );
}

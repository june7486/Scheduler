import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
        title: const Text('Manage Tabs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, size: 22),
            tooltip: 'Add tab',
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
                  c.label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Row(
                  children: [
                    Text(
                      'Top tab: ${c.showInTopTabs ? "on" : "off"}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.inkSoft,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${store.taskCountFor(c.id)} open',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.inkSoft,
                      ),
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: c.enabled,
                      activeThumbColor: AppColors.indigo,
                      onChanged: (v) {
                        c.enabled = v;
                        store.saveCategory(c);
                      },
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 19,
                        color: AppColors.danger,
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
        title: const Text('Add tab'),
        content: TextField(
          controller: label,
          decoration: const InputDecoration(hintText: 'Tab name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (label.text.trim().isNotEmpty) {
                store.addCategory(label.text.trim());
              }
              Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _editTab(BuildContext context, Store store, Category c) {
    final label = TextEditingController(text: c.label);
    final emoji = TextEditingController(text: c.emoji);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit tab'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              decoration: const InputDecoration(hintText: 'Tab name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: emoji,
              decoration: const InputDecoration(hintText: 'Emoji (e.g. 🎂)'),
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
              c.label = label.text.trim().isEmpty ? c.label : label.text.trim();
              c.emoji = emoji.text.trim();
              store.saveCategory(c);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _deleteTab(BuildContext context, Store store, Category c) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${c.label}"?'),
        content: const Text('Tasks in this tab will be moved to "Other".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              store.deleteCategory(c.id);
              Navigator.pop(context);
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.danger),
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
      appBar: AppBar(title: const Text('Output Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _Head('Design mode'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _modeChip(context, store, 'muji', 'Muji (plain)'),
                _modeChip(context, store, 'minimal', 'Minimal (underline)'),
                _modeChip(context, store, 'fancy', 'Fancy (graphic)'),
                _modeChip(context, store, 'whitespace', 'Whitespace'),
              ],
            ),
            const SizedBox(height: 22),
            const _Head('Default font size'),
            Text(
              '${store.baseFontSize.toStringAsFixed(0)} pt',
              style: const TextStyle(fontSize: 12, color: AppColors.inkSoft),
            ),
            Slider(
              value: store.baseFontSize,
              min: 8,
              max: 20,
              divisions: 12,
              activeColor: AppColors.indigo,
              label: store.baseFontSize.toStringAsFixed(0),
              onChanged: (v) => store.setBaseFontSize(v),
            ),
            const SizedBox(height: 14),
            const _Head('App theme (screen)'),
            Wrap(
              spacing: 8,
              children: [
                _themeChip(context, store, 'material', 'Material (Style 1)'),
                _themeChip(context, store, 'minimal', 'Minimal (Style 3)'),
                _themeChip(context, store, 'mix', 'Mix (1 + 3)'),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              'Tip: Open "Print / Export" from the top bar to preview and choose '
              'tabs, no-two-line, line spacing, orientation, font size and design mode.',
              style: TextStyle(
                fontSize: 11.5,
                color: AppColors.inkSoft,
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
          color: sel ? AppColors.indigo : AppColors.inkSoft,
        ),
      ),
      selected: sel,
      selectedColor: AppColors.indigo.withValues(alpha: 0.14),
      side: BorderSide(color: sel ? AppColors.indigo : AppColors.line),
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
          color: sel ? AppColors.indigo : AppColors.inkSoft,
        ),
      ),
      selected: sel,
      selectedColor: AppColors.indigo.withValues(alpha: 0.14),
      side: BorderSide(color: sel ? AppColors.indigo : AppColors.line),
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
        title: const Text('Activity Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            tooltip: 'Clear log',
            onPressed: () => store.clearLogs(),
          ),
        ],
      ),
      body: SafeArea(
        child: logs.isEmpty
            ? const Center(
                child: Text(
                  'No activity yet.',
                  style: TextStyle(fontSize: 13, color: AppColors.inkSoft),
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
                        const Icon(
                          Icons.circle,
                          size: 6,
                          color: AppColors.indigo,
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
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppColors.inkSoft,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '${l.timestamp.month}/${l.timestamp.day} '
                          '${l.timestamp.hour.toString().padLeft(2, '0')}:'
                          '${l.timestamp.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.inkSoft,
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
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
    ),
  );
}

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';

enum ReportType { userStatus, byUser, byDate }

/// Master-level reporting: user status, per-user schedules, and date-grouped
/// schedules across all users — all with full layout options + preview.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  ReportType _type = ReportType.userStatus;
  final Set<String> _selectedUsers = {};
  bool _noTwoLine = false;
  double _lineSpacing = 1.4;
  bool _landscape = false;
  double _fontSize = 11;
  final GlobalKey _previewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = context.read<Store>();
      setState(() {
        _selectedUsers
          ..clear()
          ..addAll(store.allUsers.map((u) => u.id));
      });
    });
  }

  List<User> _users(Store store) =>
      store.allUsers.where((u) => _selectedUsers.contains(u.id)).toList();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final users = store.allUsers;

    return Scaffold(
      appBar: AppBar(title: const Text('User Reports')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              flex: 5,
              child: Container(
                color: const Color(0xFFEDEFF5),
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _landscape ? 1.414 : 0.707,
                    child: RepaintBoundary(
                      key: _previewKey,
                      child: _buildPreview(store),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Sec('Report type'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _typeChip(ReportType.userStatus, 'ID status'),
                        _typeChip(ReportType.byUser, 'By ID (schedules)'),
                        _typeChip(ReportType.byDate, 'By date'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const _Sec('Users to include'),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: users.map((u) {
                        final sel = _selectedUsers.contains(u.id);
                        return FilterChip(
                          label: Text(
                            u.isMaster ? '★ ${u.id}' : u.id,
                            style: TextStyle(
                              fontSize: 11,
                              color: sel ? p.indigo : p.inkSoft,
                            ),
                          ),
                          selected: sel,
                          selectedColor: p.indigo.withValues(
                            alpha: 0.15,
                          ),
                          checkmarkColor: p.indigo,
                          side: BorderSide(
                            color: sel ? p.indigo : p.line,
                          ),
                          onSelected: (v) => setState(() {
                            v
                                ? _selectedUsers.add(u.id)
                                : _selectedUsers.remove(u.id);
                          }),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    const _Sec('Layout'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        'Prevent two-line wrapping',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      value: _noTwoLine,
                      activeThumbColor: p.indigo,
                      onChanged: (v) => setState(() => _noTwoLine = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        'Landscape orientation',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      value: _landscape,
                      activeThumbColor: p.indigo,
                      onChanged: (v) => setState(() => _landscape = v),
                    ),
                    Text(
                      'Line spacing — ${_lineSpacing.toStringAsFixed(1)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: p.inkSoft,
                      ),
                    ),
                    Slider(
                      value: _lineSpacing,
                      min: 1.0,
                      max: 2.5,
                      divisions: 15,
                      activeColor: p.indigo,
                      onChanged: (v) => setState(() => _lineSpacing = v),
                    ),
                    Text(
                      'Font size — ${_fontSize.toStringAsFixed(0)} pt',
                      style: TextStyle(
                        fontSize: 12,
                        color: p.inkSoft,
                      ),
                    ),
                    Slider(
                      value: _fontSize,
                      min: 8,
                      max: 20,
                      divisions: 12,
                      activeColor: p.indigo,
                      onChanged: (v) => setState(() => _fontSize = v),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _sharePdf(store),
                            icon: const Icon(
                              Icons.picture_as_pdf_outlined,
                              size: 18,
                            ),
                            label: const Text(
                              'PDF',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _shareImage(),
                            icon: const Icon(Icons.image_outlined, size: 18),
                            label: const Text(
                              'Image',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _print(store),
                            icon: const Icon(Icons.print_outlined, size: 18),
                            label: const Text(
                              'Print',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeChip(ReportType t, String label) {
    final sel = _type == t;
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
      onSelected: (_) => setState(() => _type = t),
    );
  }

  // ---------------- Preview ----------------
  Widget _buildPreview(Store store) {
    final base = TextStyle(fontSize: _fontSize, height: _lineSpacing);
    final date = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());
    return Container(
      color: p.card,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'JUNE\'S SCHEDULER — USER REPORT',
            style: base.copyWith(
              fontSize: _fontSize + 2,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          Text(
            date,
            style: base.copyWith(fontSize: _fontSize - 2, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          const Divider(thickness: 1),
          Expanded(child: _previewBody(store, base)),
        ],
      ),
    );
  }

  Widget _previewBody(Store store, TextStyle base) {
    switch (_type) {
      case ReportType.userStatus:
        return _userStatusPreview(store, base);
      case ReportType.byUser:
        return _byUserPreview(store, base);
      case ReportType.byDate:
        return _byDatePreview(store, base);
    }
  }

  Widget _userStatusPreview(Store store, TextStyle base) {
    final users = _users(store);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _row(['ID', 'Name', 'Open', 'Done', 'Created'], base, bold: true),
        const Divider(),
        ...users.map((u) {
          final tasks = store.tasksForOwner(u.id);
          final open = tasks.where((t) => !t.completed).length;
          final done = tasks.where((t) => t.completed).length;
          return _row([
            u.isMaster ? '★ ${u.id}' : u.id,
            u.displayName.isEmpty ? '—' : u.displayName,
            '$open',
            '$done',
            '${u.createdAt.year}-${u.createdAt.month.toString().padLeft(2, '0')}-${u.createdAt.day.toString().padLeft(2, '0')}',
          ], base);
        }),
      ],
    );
  }

  Widget _byUserPreview(Store store, TextStyle base) {
    final users = _users(store);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final u in users) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              '${u.isMaster ? "★ " : ""}${u.id}${u.displayName.isNotEmpty ? " (${u.displayName})" : ""}',
              style: base.copyWith(
                fontWeight: FontWeight.w800,
                color: p.indigo,
              ),
            ),
          ),
          ..._taskLines(store.tasksForOwner(u.id), base),
        ],
      ],
    );
  }

  Widget _byDatePreview(Store store, TextStyle base) {
    // Group all selected users' tasks by their scheduled date.
    final users = _users(store);
    final map = <String, List<Task>>{};
    for (final u in users) {
      for (final t in store.tasksForOwner(u.id)) {
        final d = t.dueDate ?? _taskDate(t);
        final key = DateFormat('yyyy-MM-dd').format(d);
        map.putIfAbsent(key, () => []).add(t);
      }
    }
    final keys = map.keys.toList()..sort();
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final k in keys) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              k,
              style: base.copyWith(
                fontWeight: FontWeight.w800,
                color: p.indigo,
              ),
            ),
          ),
          ..._taskLines(map[k]!, base, showOwner: true),
        ],
      ],
    );
  }

  DateTime _taskDate(Task t) {
    if (t.recurrence == 'monthly' && t.recurrenceDay != null) {
      final now = DateTime.now();
      return DateTime(now.year, now.month, t.recurrenceDay!);
    }
    return t.createdAt;
  }

  List<Widget> _taskLines(
    List<Task> tasks,
    TextStyle base, {
    bool showOwner = false,
  }) {
    if (tasks.isEmpty) {
      return [
        Text(
          '— no tasks —',
          style: base.copyWith(fontSize: _fontSize - 3, color: Colors.grey),
        ),
      ];
    }
    return tasks.map((t) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0xFFEEEEEE), width: 0.6),
          ),
        ),
        child: Row(
          children: [
            Text(t.completed ? '☑ ' : '☐ ', style: base),
            Expanded(
              child: Text(
                '${t.title}'
                '${t.amount != null ? "   ₩${t.amount!.toStringAsFixed(0)}" : ""}'
                '${showOwner ? "   ·  ${t.ownerId}" : ""}',
                maxLines: _noTwoLine ? 1 : 3,
                overflow: TextOverflow.ellipsis,
                style: base.copyWith(
                  fontSize: _fontSize - 1,
                  decoration: t.completed ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  Widget _row(List<String> cells, TextStyle base, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Text(
                cells[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base.copyWith(
                  fontSize: _fontSize - 1,
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- PDF ----------------
  Future<pw.Document> _buildPdf(Store store) async {
    final doc = pw.Document();
    final date = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());
    final format = _landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
    final base = pw.TextStyle(fontSize: _fontSize, height: _lineSpacing);

    doc.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(28),
        build: (ctx) {
          final w = <pw.Widget>[];
          w.add(
            pw.Text(
              "JUNE'S SCHEDULER — USER REPORT",
              style: pw.TextStyle(
                fontSize: _fontSize + 2,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          );
          w.add(
            pw.Text(
              date,
              style: pw.TextStyle(
                fontSize: _fontSize - 2,
                color: PdfColors.grey700,
              ),
            ),
          );
          w.add(pw.SizedBox(height: 4));
          w.add(pw.Divider(color: PdfColors.grey400));

          if (_type == ReportType.userStatus) {
            w.add(
              pw.Row(
                children: [
                  pw.Expanded(
                    flex: 3,
                    child: pw.Text(
                      'ID',
                      style: base.copyWith(fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                  pw.Expanded(
                    flex: 2,
                    child: pw.Text(
                      'Name',
                      style: base.copyWith(fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Text(
                      'Open',
                      style: base.copyWith(fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Text(
                      'Done',
                      style: base.copyWith(fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                ],
              ),
            );
            for (final u in _users(store)) {
              final tasks = store.tasksForOwner(u.id);
              final open = tasks.where((t) => !t.completed).length;
              final done = tasks.where((t) => t.completed).length;
              w.add(
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  decoration: pw.BoxDecoration(
                    border: pw.Border(
                      bottom: pw.BorderSide(
                        color: PdfColors.grey300,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: pw.Row(
                    children: [
                      pw.Expanded(
                        flex: 3,
                        child: pw.Text(
                          u.isMaster ? '★ ${u.id}' : u.id,
                          style: base,
                        ),
                      ),
                      pw.Expanded(
                        flex: 2,
                        child: pw.Text(
                          u.displayName.isEmpty ? '—' : u.displayName,
                          style: base,
                        ),
                      ),
                      pw.Expanded(child: pw.Text('$open', style: base)),
                      pw.Expanded(child: pw.Text('$done', style: base)),
                    ],
                  ),
                ),
              );
            }
          } else if (_type == ReportType.byUser) {
            for (final u in _users(store)) {
              w.add(
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 8, bottom: 2),
                  child: pw.Text(
                    '${u.isMaster ? "★ " : ""}${u.id}',
                    style: base.copyWith(
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.indigo800,
                    ),
                  ),
                ),
              );
              w.addAll(_pdfTaskLines(store.tasksForOwner(u.id), base));
            }
          } else {
            final users = _users(store);
            final map = <String, List<Task>>{};
            for (final u in users) {
              for (final t in store.tasksForOwner(u.id)) {
                final key = DateFormat(
                  'yyyy-MM-dd',
                ).format(t.dueDate ?? _taskDate(t));
                map.putIfAbsent(key, () => []).add(t);
              }
            }
            final keys = map.keys.toList()..sort();
            for (final k in keys) {
              w.add(
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 8, bottom: 2),
                  child: pw.Text(
                    k,
                    style: base.copyWith(
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.indigo800,
                    ),
                  ),
                ),
              );
              w.addAll(_pdfTaskLines(map[k]!, base, showOwner: true));
            }
          }
          return w;
        },
      ),
    );
    return doc;
  }

  List<pw.Widget> _pdfTaskLines(
    List<Task> tasks,
    pw.TextStyle base, {
    bool showOwner = false,
  }) {
    return tasks.map((t) {
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        decoration: pw.BoxDecoration(
          border: pw.Border(
            bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
          ),
        ),
        child: pw.Row(
          children: [
            pw.Text(t.completed ? '☑ ' : '☐ ', style: base),
            pw.Expanded(
              child: pw.Text(
                '${t.title}'
                '${t.amount != null ? "   ₩${t.amount!.toStringAsFixed(0)}" : ""}'
                '${showOwner ? "   ·  ${t.ownerId}" : ""}',
                maxLines: _noTwoLine ? 1 : 3,
                style: base.copyWith(
                  decoration: t.completed
                      ? pw.TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  Future<void> _sharePdf(Store store) async {
    final doc = await _buildPdf(store);
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'june_user_report.pdf',
    );
  }

  Future<void> _print(Store store) async {
    final doc = await _buildPdf(store);
    await Printing.layoutPdf(onLayout: (_) => doc.save());
  }

  Future<void> _shareImage() async {
    try {
      final boundary =
          _previewKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();
      await Share.shareXFiles([
        XFile.fromData(
          Uint8List.fromList(bytes),
          mimeType: 'image/png',
          name: 'june_user_report.png',
        ),
      ], subject: "June's Scheduler — User Report");
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Image export failed: $e')));
    }
  }
}

class _Sec extends StatelessWidget {
  final String text;
  const _Sec(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: p.ink,
        letterSpacing: 0.3,
      ),
    ),
  );
}

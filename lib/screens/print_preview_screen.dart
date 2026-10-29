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

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';

/// Output design modes requested by the user.
enum PrintDesign { muji, minimal, fancy, whitespace }

class PrintPreviewScreen extends StatefulWidget {
  const PrintPreviewScreen({super.key});

  @override
  State<PrintPreviewScreen> createState() => _PrintPreviewScreenState();
}

class _PrintPreviewScreenState extends State<PrintPreviewScreen> {
  final Set<String> _selectedTabs = {};
  bool _noTwoLine = false;
  double _lineSpacing = 1.4;
  bool _landscape = false;
  double _fontSize = 12;
  PrintDesign _design = PrintDesign.minimal;
  final GlobalKey _previewKey = GlobalKey();
  bool _showPreview = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = context.read<Store>();
      setState(() {
        _selectedTabs
          ..clear()
          ..addAll(store.enabledCategories.map((c) => c.id));
        _design = _designFromString(store.printDesignMode);
        _fontSize = store.baseFontSize;
      });
    });
  }

  PrintDesign _designFromString(String s) => switch (s) {
    'muji' => PrintDesign.muji,
    'fancy' => PrintDesign.fancy,
    'whitespace' => PrintDesign.whitespace,
    _ => PrintDesign.minimal,
  };

  String _designToString(PrintDesign d) => d.name;

  List<Task> _tasksFor(Store store) {
    final all = store.tasks
        .where((t) => _selectedTabs.contains(t.categoryId))
        .toList();
    return all;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final cats = store.enabledCategories;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('print_export')),
        actions: [
          IconButton(
            tooltip: _showPreview ? context.tr('hide_preview') : context.tr('show_preview'),
            icon: Icon(_showPreview ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showPreview = !_showPreview),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              flex: 5,
              child: Container(
                color: const Color(0xFFEDEFF5),
                padding: const EdgeInsets.all(12),
                child: _showPreview
                    ? Center(
                        child: AspectRatio(
                          aspectRatio: _landscape ? 1.414 : 0.707,
                          child: RepaintBoundary(
                            key: _previewKey,
                            child: _buildPreview(store, cats),
                          ),
                        ),
                      )
                    : Center(
                        child: Text(
                          context.tr('preview_hidden'),
                          style: TextStyle(
                            color: p.inkSoft,
                            fontSize: 13,
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
                    _SecTitle(context.tr('tabs_to_include')),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: cats.map((c) {
                        final sel = _selectedTabs.contains(c.id);
                        final col = Color(c.colorValue);
                        return FilterChip(
                          label: Text(
                            '${c.emoji} ${catLabel(c)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: sel ? ct(col) : p.inkSoft,
                            ),
                          ),
                          selected: sel,
                          selectedColor: col.withValues(alpha: 0.15),
                          checkmarkColor: col,
                          side: BorderSide(color: sel ? col : p.line),
                          onSelected: (v) => setState(() {
                            v
                                ? _selectedTabs.add(c.id)
                                : _selectedTabs.remove(c.id);
                          }),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    _SecTitle(context.tr('layout')),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        context.tr('no_two_line'),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      value: _noTwoLine,
                      activeThumbColor: p.indigo,
                      onChanged: (v) => setState(() => _noTwoLine = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        context.tr('landscape'),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      value: _landscape,
                      activeThumbColor: p.indigo,
                      onChanged: (v) => setState(() => _landscape = v),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${context.tr('line_spacing')} — ${_lineSpacing.toStringAsFixed(1)}',
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
                      label: _lineSpacing.toStringAsFixed(1),
                      onChanged: (v) => setState(() => _lineSpacing = v),
                    ),
                    Text(
                      '${context.tr('font_size')} — ${_fontSize.toStringAsFixed(0)} pt',
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
                      label: _fontSize.toStringAsFixed(0),
                      onChanged: (v) => setState(() => _fontSize = v),
                    ),
                    const SizedBox(height: 10),
                    _SecTitle(context.tr('design_mode')),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: PrintDesign.values.map((d) {
                        final sel = _design == d;
                        return ChoiceChip(
                          label: Text(
                            _designLabel(d),
                            style: TextStyle(
                              fontSize: 11.5,
                              color: sel ? p.indigo : p.inkSoft,
                            ),
                          ),
                          selected: sel,
                          selectedColor: p.indigo.withValues(
                            alpha: 0.14,
                          ),
                          side: BorderSide(
                            color: sel ? p.indigo : p.line,
                          ),
                          onSelected: (_) {
                            setState(() => _design = d);
                            store.setPrintDesignMode(_designToString(d));
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _exportPdf(store),
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
                            onPressed: () => _shareImage(store),
                            icon: const Icon(Icons.image_outlined, size: 18),
                            label: Text(
                              context.tr('image'),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _printNow(store),
                            icon: const Icon(Icons.print_outlined, size: 18),
                            label: Text(
                              context.tr('print'),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _email(store),
                        icon: const Icon(Icons.email_outlined, size: 18),
                        label: Text(
                          context.tr('send_email'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
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

  String _designLabel(PrintDesign d) => switch (d) {
    PrintDesign.muji => context.tr('muji'),
    PrintDesign.minimal => context.tr('minimal_design'),
    PrintDesign.fancy => context.tr('fancy'),
    PrintDesign.whitespace => context.tr('whitespace'),
  };

  // ---------------- In-app preview ----------------
  Widget _buildPreview(Store store, List<Category> cats) {
    final tasks = _tasksFor(store);
    final date = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());

    final base = TextStyle(fontSize: _fontSize, height: _lineSpacing);

    switch (_design) {
      case PrintDesign.muji:
        return _paper(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'JUNE\'S SCHEDULER',
                style: base.copyWith(
                  fontSize: _fontSize + 4,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                date,
                style: base.copyWith(
                  fontSize: _fontSize - 2,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(child: _plainList(tasks, base, store)),
            ],
          ),
          color: const Color(0xFFFAF9F6),
        );
      case PrintDesign.minimal:
        return _paper(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "June's Scheduler",
                style: base.copyWith(
                  fontSize: _fontSize + 3,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                date,
                style: base.copyWith(
                  fontSize: _fontSize - 2,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 6),
              const Divider(thickness: 1.2, color: Colors.black87),
              Expanded(child: _underlinedList(tasks, base, store)),
            ],
          ),
        );
      case PrintDesign.fancy:
        return _paper(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: p.indigo,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'JUNE',
                      style: base.copyWith(
                        color: p.card,
                        fontSize: _fontSize - 2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'SCHEDULER',
                    style: base.copyWith(
                      fontSize: _fontSize + 2,
                      fontWeight: FontWeight.w800,
                      color: p.indigo,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    date,
                    style: base.copyWith(
                      fontSize: _fontSize - 3,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _fancyBars(store, tasks, base),
              const SizedBox(height: 8),
              Expanded(child: _fancyList(tasks, base, store)),
            ],
          ),
        );
      case PrintDesign.whitespace:
        return _paper(
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "June's Scheduler",
                  style: base.copyWith(
                    fontSize: _fontSize + 4,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  date,
                  style: base.copyWith(
                    fontSize: _fontSize - 2,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: _underlinedList(tasks, base, store, extraSpace: true),
                ),
              ],
            ),
          ),
        );
    }
  }

  Widget _paper(Widget child, {Color? color}) => Container(
    color: color ?? p.card,
    padding: const EdgeInsets.all(14),
    child: child,
  );

  Widget _plainList(List<Task> tasks, TextStyle base, Store store) {
    return ListView(
      padding: EdgeInsets.zero,
      children: tasks.map((t) {
        final cat = store.categoryById(t.categoryId);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Text('□ ', style: base),
              Expanded(
                child: Text(
                  '${t.title}${t.note.isNotEmpty ? '  ·  ${t.note}' : ''}',
                  maxLines: _noTwoLine ? 1 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    decoration: t.completed ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              if (cat != null)
                Text(
                  '  ${catLabel(cat)}',
                  style: base.copyWith(
                    fontSize: _fontSize - 3,
                    color: Colors.grey,
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _underlinedList(
    List<Task> tasks,
    TextStyle base,
    Store store, {
    bool extraSpace = false,
  }) {
    return ListView(
      padding: EdgeInsets.zero,
      children: tasks.map((t) {
        final cat = store.categoryById(t.categoryId);
        return Container(
          padding: EdgeInsets.symmetric(vertical: extraSpace ? 7 : 4),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFDDDDDD), width: 0.6),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t.title,
                  maxLines: _noTwoLine ? 1 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    decoration: t.completed ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              if (cat != null)
                Text(
                  catLabel(cat),
                  style: base.copyWith(
                    fontSize: _fontSize - 3,
                    color: Colors.grey,
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _fancyList(List<Task> tasks, TextStyle base, Store store) {
    return ListView(
      padding: EdgeInsets.zero,
      children: tasks.map((t) {
        final cat = store.categoryById(t.categoryId);
        final col = cat != null ? Color(cat.colorValue) : p.indigo;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: col.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
            border: Border(left: BorderSide(color: col, width: 3)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t.title,
                  maxLines: _noTwoLine ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (cat != null)
                Text(
                  '${cat.emoji} ${catLabel(cat)}',
                  style: base.copyWith(fontSize: _fontSize - 3, color: ct(col)),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _fancyBars(Store store, List<Task> tasks, TextStyle base) {
    final counts = <String, int>{};
    for (final t in tasks) {
      counts[t.categoryId] = (counts[t.categoryId] ?? 0) + 1;
    }
    final maxC = counts.values.isEmpty
        ? 1
        : counts.values.reduce((a, b) => a > b ? a : b);
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      children: entries.take(6).map((e) {
        final cat = store.categoryById(e.key);
        final col = cat != null ? Color(cat.colorValue) : p.indigo;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(
            children: [
              SizedBox(
                width: 62,
                child: Text(
                  cat != null ? catLabel(cat) : e.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(fontSize: _fontSize - 3),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, c) {
                    return Stack(
                      children: [
                        Container(height: 9, color: const Color(0xFFEEEEEE)),
                        Container(
                          height: 9,
                          width: c.maxWidth * (e.value / maxC),
                          color: col,
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: 4),
              Text('${e.value}', style: base.copyWith(fontSize: _fontSize - 3)),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ---------------- PDF export ----------------
  Future<pw.Document> _buildPdf(Store store) async {
    final doc = pw.Document();
    final tasks = _tasksFor(store);
    final date = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());
    final format = _landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

    doc.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(28),
        build: (ctx) {
          final widgets = <pw.Widget>[];
          final base = pw.TextStyle(
            fontSize: _fontSize,
            height: _lineSpacing,
            color: _design == PrintDesign.fancy
                ? PdfColors.indigo800
                : PdfColors.black,
          );

          widgets.add(
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    "June's Scheduler",
                    style: pw.TextStyle(
                      fontSize: _fontSize + 4,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    date,
                    style: pw.TextStyle(
                      fontSize: _fontSize - 2,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
              ),
            ),
          );
          widgets.add(pw.SizedBox(height: 8));
          if (_design == PrintDesign.minimal ||
              _design == PrintDesign.whitespace) {
            widgets.add(pw.Divider(color: PdfColors.grey400));
          }

          for (final t in tasks) {
            final cat = store.categoryById(t.categoryId);
            final line = <pw.Widget>[
              pw.Expanded(
                child: pw.Text(
                  t.title,
                  maxLines: _noTwoLine ? 1 : 3,
                  style: base.copyWith(
                    decoration: t.completed
                        ? pw.TextDecoration.lineThrough
                        : null,
                  ),
                ),
              ),
              if (cat != null)
                pw.Text(
                  ' ${catLabel(cat)}',
                  style: pw.TextStyle(
                    fontSize: _fontSize - 3,
                    color: PdfColors.grey600,
                  ),
                ),
            ];
            if (_design == PrintDesign.fancy) {
              widgets.add(
                pw.Container(
                  margin: const pw.EdgeInsets.symmetric(vertical: 2),
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.indigo50,
                    border: pw.Border(
                      left: pw.BorderSide(color: PdfColors.indigo400, width: 2),
                    ),
                  ),
                  child: pw.Row(children: line),
                ),
              );
            } else {
              widgets.add(
                pw.Container(
                  padding: pw.EdgeInsets.symmetric(
                    vertical: _design == PrintDesign.whitespace ? 6 : 3,
                  ),
                  decoration: pw.BoxDecoration(
                    border: pw.Border(
                      bottom: pw.BorderSide(
                        color: PdfColors.grey300,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: pw.Row(children: line),
                ),
              );
            }
          }
          return widgets;
        },
      ),
    );
    return doc;
  }

  Future<void> _exportPdf(Store store) async {
    final doc = await _buildPdf(store);
    final bytes = await doc.save();
    await Printing.sharePdf(bytes: bytes, filename: 'june_scheduler.pdf');
  }

  Future<void> _printNow(Store store) async {
    final doc = await _buildPdf(store);
    await Printing.layoutPdf(onLayout: (_) => doc.save());
  }

  Future<void> _shareImage(Store store) async {
    try {
      final boundary =
          _previewKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();
      await Share.shareXFiles([
        XFile.fromData(
          bytes,
          mimeType: 'image/png',
          name: 'june_scheduler.png',
        ),
      ], subject: "June's Scheduler");
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('image_failed', args: {'err': '$e'}))));
    }
  }

  Future<void> _email(Store store) async {
    final doc = await _buildPdf(store);
    final bytes = await doc.save();
    final uri = Uri(
      scheme: 'mailto',
      query: "subject=${Uri.encodeComponent("June's Scheduler")}",
    );
    // On mobile, sharing the PDF is the reliable path; e-mail clients can attach it.
    await Share.shareXFiles(
      [
        XFile.fromData(
          Uint8List.fromList(bytes),
          mimeType: 'application/pdf',
          name: 'june_scheduler.pdf',
        ),
      ],
      subject: "June's Scheduler",
      text: 'Open in your e-mail client to attach: $uri',
    );
  }
}

class _SecTitle extends StatelessWidget {
  final String text;
  const _SecTitle(this.text);
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

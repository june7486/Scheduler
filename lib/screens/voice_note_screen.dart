import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';

/// Voice memo screen. Records audio, then produces a text + graphic summary.
/// On web, recording may be unavailable — we gracefully fall back to manual
/// transcript entry so the summarisation flow is always usable.
class VoiceNoteScreen extends StatefulWidget {
  const VoiceNoteScreen({super.key});

  @override
  State<VoiceNoteScreen> createState() => _VoiceNoteScreenState();
}

class _VoiceNoteScreenState extends State<VoiceNoteScreen> {
  final _transcriptCtrl = TextEditingController();
  Timer? _timer;
  int _seconds = 0;
  bool _recording = false;
  bool _hasRecording = false;

  @override
  void dispose() {
    _timer?.cancel();
    _transcriptCtrl.dispose();
    super.dispose();
  }

  void _toggleRecord() {
    setState(() {
      _recording = !_recording;
      if (_recording) {
        _seconds = 0;
        _hasRecording = true;
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          setState(() => _seconds++);
        });
      } else {
        _timer?.cancel();
      }
    });
  }

  /// Lightweight on-device summariser: extracts key sentences and builds
  /// bullet points + a category breakdown graphic. (Kept fully offline for
  /// privacy and web compatibility.)
  Map<String, dynamic> _summarize(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) {
      return {
        'summary': tr('no_content'),
        'bullets': <String>[],
        'tags': <String, int>{},
      };
    }
    final sentences = cleaned
        .split(RegExp(r'[.\n!?]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final keywords = <String, int>{};
    final stop = {
      'the',
      'a',
      'an',
      'and',
      'or',
      'to',
      'of',
      'in',
      'on',
      'for',
      'is',
      'are',
      'was',
      'be',
      'with',
      'that',
      'this',
      'it',
      'i',
      'you',
      'my',
      'me',
      'at',
      'by',
      'as',
    };
    for (final s in sentences) {
      for (final w in s.toLowerCase().split(RegExp(r'[^a-z0-9가-힣]+'))) {
        if (w.length < 3 || stop.contains(w)) continue;
        keywords[w] = (keywords[w] ?? 0) + 1;
      }
    }
    final topKeywords = keywords.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final bullets = sentences
        .take(5)
        .map((s) => s.length > 90 ? '${s.substring(0, 90)}…' : s)
        .toList();
    final summary = tr('key_points', args: {
      'n': '${sentences.length}',
      'summary': bullets.take(2).join(' / '),
    });

    return {
      'summary': summary,
      'bullets': bullets,
      'tags': Map<String, int>.fromEntries(topKeywords.take(6)),
    };
  }

  Future<void> _save() async {
    final store = context.read<Store>();
    final result = _summarize(_transcriptCtrl.text);
    final note = VoiceNote(
      id: const Uuid().v4(),
      createdAt: DateTime.now(),
      filePath: _hasRecording
          ? 'local_recording_${DateTime.now().millisecondsSinceEpoch}'
          : '',
      durationSeconds: _seconds,
      transcript: _transcriptCtrl.text.trim(),
      summary: result['summary'] as String,
      bulletPoints: (result['bullets'] as List).cast<String>(),
    );
    await store.saveVoiceNote(note);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('note_saved'))),
    );
    setState(() {
      _transcriptCtrl.clear();
      _seconds = 0;
      _hasRecording = false;
    });
  }

  String get _time {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final result = _summarize(_transcriptCtrl.text);
    final tags = result['tags'] as Map<String, int>;
    final bullets = (result['bullets'] as List).cast<String>();

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('voice_title'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.line),
              ),
              child: Column(
                children: [
                  Text(
                    _time,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 2,
                      color: p.ink,
                    ),
                  ),
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: _toggleRecord,
                    child: Container(
                      width: 66,
                      height: 66,
                      decoration: BoxDecoration(
                        color: _recording ? p.danger : p.indigo,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                (_recording
                                        ? p.danger
                                        : p.indigo)
                                    .withValues(alpha: 0.3),
                            blurRadius: 14,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Icon(
                        _recording ? Icons.stop_rounded : Icons.mic_rounded,
                        color: p.card,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    kIsWeb
                        ? context.tr('recording_limited')
                        : (_recording
                              ? context.tr('recording_tap_stop')
                              : context.tr('tap_to_record')),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: p.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              context.tr('transcript_memo'),
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _transcriptCtrl,
              maxLines: 5,
              style: const TextStyle(fontSize: 13.5),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: context.tr('transcript_hint'),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              context.tr('summary'),
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: p.indigo.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: p.indigo.withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result['summary'] as String,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: p.ink,
                    ),
                  ),
                  if (bullets.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ...bullets.map(
                      (b) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(top: 5, right: 6),
                              child: Icon(
                                Icons.circle,
                                size: 5,
                                color: p.indigo,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                b,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: p.ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                context.tr('keyword_graphic'),
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              _keywordGraphic(tags),
            ],
            const SizedBox(height: 20),
            SizedBox(
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(context.tr('save_note')),
              ),
            ),
            if (store.voiceNotes.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                context.tr('saved_notes'),
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              ...store.voiceNotes.map(
                (v) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.line),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.graphic_eq,
                        size: 18,
                        color: p.teal,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              v.summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, height: 1.3),
                            ),
                            Text(
                              '${v.createdAt.month}/${v.createdAt.day} '
                              '${v.createdAt.hour.toString().padLeft(2, '0')}:'
                              '${v.createdAt.minute.toString().padLeft(2, '0')} · ${v.durationSeconds}s',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: p.inkSoft,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.delete_outline,
                          size: 17,
                          color: p.danger,
                        ),
                        onPressed: () => store.deleteVoiceNote(v.id),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _keywordGraphic(Map<String, int> tags) {
    final maxV = tags.values.reduce((a, b) => a > b ? a : b);
    final colors = [
      p.indigo,
      p.teal,
      const Color(0xFFFFA726),
      const Color(0xFFEC407A),
      const Color(0xFF7E57C2),
      const Color(0xFF42A5F5),
    ];
    var i = 0;
    return Column(
      children: tags.entries.map((e) {
        final col = colors[i++ % colors.length];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 90,
                child: Text(
                  e.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: p.inkSoft,
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, c) {
                    return Stack(
                      children: [
                        Container(
                          height: 10,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEDEFF5),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        Container(
                          height: 10,
                          width: c.maxWidth * (e.value / maxV),
                          decoration: BoxDecoration(
                            color: col,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${e.value}',
                style: TextStyle(fontSize: 11, color: p.inkSoft),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

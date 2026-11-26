import 'package:flutter/material.dart';
import 'package:orchard_engine/orchard_engine.dart';
import 'package:share_plus/share_plus.dart';

import '../project.dart';
import 'theme.dart';

/// FL's File > Export, simplified: name, WAV / MP3, song or pattern loops.
Future<void> showExportDialog(BuildContext context, Project p) =>
    showDialog(context: context, barrierDismissible: false, builder: (_) => _ExportDialog(project: p));

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.project});
  final Project project;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final TextEditingController _name;
  ExportFormat _format = ExportFormat.mp3;
  late bool _song;
  int _repeats = 4;
  double? _progress; // null = not started
  String? _path;
  String? _error;

  Project get p => widget.project;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _name = TextEditingController(text: 'Мой трек ${now.day}.${now.month} ${now.hour}-${now.minute.toString().padLeft(2, '0')}');
    _song = p.clips.isNotEmpty;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (p.playing) p.stop();
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final path = await p.exportTrack(
        name: _name.text,
        format: _format,
        song: _song,
        repeats: _repeats,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
      );
      if (mounted) setState(() => _path = path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e'.split('\n').first;
          _progress = null;
        });
      }
    }
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(_path!)],
      text: _name.text,
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null && _path == null;
    final bars = _song ? p.songBars : (p.patternLength[p.pattern] / 16 * _repeats);
    final secs = bars * 4 * 60 / p.tempo;
    return AlertDialog(
      title: const Text('Экспорт трека'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: const ValueKey('exportName'),
            controller: _name,
            enabled: !busy && _path == null,
            decoration: const InputDecoration(labelText: 'Название'),
          ),
          const SizedBox(height: 16),
          Row(children: [
            const SizedBox(width: 90, child: Text('Формат', style: TextStyle(color: C.textDim))),
            SegmentedButton<ExportFormat>(
              segments: const [
                ButtonSegment(value: ExportFormat.mp3, label: Text('MP3')),
                ButtonSegment(value: ExportFormat.wav, label: Text('WAV')),
              ],
              selected: {_format},
              showSelectedIcon: false,
              onSelectionChanged: busy || _path != null ? null : (s) => setState(() => _format = s.first),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            const SizedBox(width: 90, child: Text('Что', style: TextStyle(color: C.textDim))),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, label: const Text('Песня'), enabled: p.clips.isNotEmpty),
                ButtonSegment(value: false, label: Text('Pattern ${p.pattern + 1}')),
              ],
              selected: {_song},
              showSelectedIcon: false,
              onSelectionChanged: busy || _path != null ? null : (s) => setState(() => _song = s.first),
            ),
            if (!_song) ...[
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: _repeats,
                items: [for (final r in [1, 2, 4, 8, 16]) DropdownMenuItem(value: r, child: Text('× $r'))],
                onChanged: busy || _path != null ? null : (v) => setState(() => _repeats = v ?? 4),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Text('Длина: ${secs.floor() ~/ 60}:${(secs.floor() % 60).toString().padLeft(2, '0')}',
              style: const TextStyle(color: C.textDim)),
          if (_progress != null) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress, minHeight: 10, borderRadius: BorderRadius.circular(5)),
          ],
          if (_path != null) ...[
            const SizedBox(height: 12),
            const Text('Готово!', style: TextStyle(color: C.green, fontWeight: FontWeight.w700, fontSize: 16)),
            SelectableText(_path!, style: const TextStyle(color: C.textDim, fontSize: 12)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text('Ошибка: $_error', style: const TextStyle(color: C.red)),
          ],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(_path == null ? 'Отмена' : 'Закрыть'),
        ),
        if (_path == null)
          FilledButton.icon(
            key: const ValueKey('exportRun'),
            onPressed: busy || (_song && p.clips.isEmpty) ? null : _run,
            icon: const Icon(Icons.file_download),
            label: const Text('Экспорт'),
          )
        else
          Builder(
            builder: (c) => FilledButton.icon(
              key: const ValueKey('exportShare'),
              onPressed: () => _share(c),
              icon: const Icon(Icons.share),
              label: const Text('Поделиться'),
            ),
          ),
      ],
    );
  }
}

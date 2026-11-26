import 'package:flutter/material.dart';
import 'package:orchard_engine/orchard_engine.dart';

import '../ai_helper.dart';
import '../project.dart';
import 'theme.dart';

/// "Помощник": Magenta models as big buttons.
Future<void> showHelperSheet(BuildContext context, Project p, AiHelper helper) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.panel,
      constraints: const BoxConstraints(maxWidth: double.infinity),
      builder: (_) => _HelperSheet(project: p, helper: helper),
    );

class _HelperSheet extends StatefulWidget {
  const _HelperSheet({required this.project, required this.helper});
  final Project project;
  final AiHelper helper;

  @override
  State<_HelperSheet> createState() => _HelperSheetState();
}

class _HelperSheetState extends State<_HelperSheet> {
  double _boldness = 1.0;
  int? _melodyCh; // null = new piano
  int _mixA = 0, _mixB = 1;
  int _prog = 0;
  String? _status;
  bool _error = false;
  bool _busy = false;

  Project get p => widget.project;
  AiHelper get h => widget.helper;

  @override
  void initState() {
    super.initState();
    final mel = h.melodicChannels();
    _melodyCh = mel.isEmpty ? null : mel.first;
    _mixA = p.pattern;
    _mixB = (p.pattern + 1) % kMaxPatterns;
  }

  Future<void> _run(String label, Future<String> Function(void Function(double) onDownload) action) async {
    setState(() {
      _busy = true;
      _error = false;
      _status = '$label…';
    });
    try {
      final done = await action((v) {
        if (mounted) setState(() => _status = 'Скачиваю модель… ${(v * 100).round()}%');
      });
      if (mounted) setState(() => _status = done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = e is StateError ? e.message : 'Не получилось: ${'$e'.split('\n').first}';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _action(String text, IconData icon, VoidCallback onTap, {Key? key}) => SizedBox(
        width: 230,
        height: 64,
        child: FilledButton.icon(
          key: key,
          style: FilledButton.styleFrom(
            backgroundColor: C.panelHi,
            foregroundColor: C.text,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          onPressed: _busy ? null : onTap,
          icon: Icon(icon, size: 26, color: C.accent),
          label: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: C.textDim, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: children),
        ]),
      );

  DropdownButton<int> _patternPick(int value, ValueChanged<int> on) => DropdownButton<int>(
        value: value,
        items: [for (var i = 0; i < kMaxPatterns; i++) DropdownMenuItem(value: i, child: Text('Pattern ${i + 1}'))],
        onChanged: _busy ? null : (v) => setState(() => on(v ?? 0)),
      );

  @override
  Widget build(BuildContext context) {
    final mel = h.melodicChannels();
    if (_melodyCh != null && !mel.contains(_melodyCh)) _melodyCh = mel.isEmpty ? null : mel.first;
    final t = _boldness;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome, color: C.accent, size: 28),
            const SizedBox(width: 10),
            const Text('Помощник', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(width: 24),
            const Text('Смелость', style: TextStyle(color: C.textDim)),
            SizedBox(
              width: 220,
              child: Slider(
                key: const ValueKey('boldness'),
                value: _boldness,
                min: 0.3,
                max: 1.6,
                onChanged: _busy ? null : (v) => setState(() => _boldness = v),
              ),
            ),
            Text(_boldness < 0.7 ? 'спокойно' : (_boldness < 1.2 ? 'интересно' : 'безумно'),
                style: const TextStyle(color: C.textDim)),
            const Spacer(),
            OutlinedButton.icon(
              key: const ValueKey('helperUndo'),
              onPressed: _busy || !h.canUndo
                  ? null
                  : () {
                      h.undo();
                      setState(() => _status = 'Отменил');
                    },
              icon: const Icon(Icons.undo),
              label: const Text('Отменить'),
            ),
          ]),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                if (_busy) const SizedBox(width: 10),
                Expanded(
                  child: Text(_status!,
                      style: TextStyle(color: _error ? C.red : (_busy ? C.text : C.green), fontSize: 15)),
                ),
              ]),
            ),
          _section('Бит (в новый паттерн)', [
            _action('Придумай бит', Icons.casino, key: const ValueKey('aiNewBeat'), () {
              _run('Придумываю бит', (d) async {
                await h.newBeat(temperature: t, onDownload: d);
                return 'Готово: Pattern ${p.pattern + 1}, нажми ▶';
              });
            }),
            _action('Ещё вариант', Icons.shuffle, () {
              _run('Делаю вариацию', (d) async {
                final from = p.pattern + 1;
                await h.varyBeat(amount: 0.25 + 0.4 * t, onDownload: d);
                return 'Вариация Pattern $from → Pattern ${p.pattern + 1}';
              });
            }),
            _action('Продолжи бит', Icons.redo, () {
              _run('Продолжаю бит', (d) async {
                await h.continueBeat(temperature: t, onDownload: d);
                return 'Готово: Pattern ${p.pattern + 1}';
              });
            }),
          ]),
          _section('Смешать два бита', [
            _patternPick(_mixA, (v) => _mixA = v),
            const Text('+', style: TextStyle(fontSize: 20)),
            _patternPick(_mixB, (v) => _mixB = v),
            _action('Смешай', Icons.merge_type, () {
              _run('Смешиваю', (d) async {
                await h.mixBeats(_mixA, _mixB, onDownload: d);
                return 'Смесь → Pattern ${p.pattern + 1}';
              });
            }),
          ]),
          _section('Мелодия (в текущий паттерн)', [
            const Text('Куда:', style: TextStyle(color: C.textDim)),
            DropdownButton<int?>(
              value: _melodyCh,
              items: [
                for (final c in mel) DropdownMenuItem(value: c, child: Text(p.channels[c].name)),
                const DropdownMenuItem(value: null, child: Text('Новое пианино')),
              ],
              onChanged: _busy ? null : (v) => setState(() => _melodyCh = v),
            ),
            _action('Придумай мелодию', Icons.music_note, key: const ValueKey('aiNewMelody'), () {
              _run('Сочиняю мелодию', (d) async {
                final ch = await h.newMelody(channel: _melodyCh, temperature: t, onDownload: d);
                _melodyCh = ch;
                return 'Мелодия в канале «${p.channels[ch].name}»';
              });
            }),
            _action('Продолжи мелодию', Icons.trending_flat, () {
              final ch = _melodyCh;
              if (ch == null) {
                setState(() {
                  _error = true;
                  _status = 'Выбери канал с началом мелодии';
                });
                return;
              }
              _run('Продолжаю мелодию', (d) async {
                await h.continueMelody(channel: ch, temperature: t, onDownload: d);
                return 'Продолжил «${p.channels[ch].name}»';
              });
            }),
          ]),
          _section('Мелодия под аккорды', [
            for (var i = 0; i < kProgressions.length; i++)
              ChoiceChip(
                label: Text(kProgressions[i].join(' – ')),
                selected: _prog == i,
                onSelected: _busy ? null : (_) => setState(() => _prog = i),
              ),
            _action('Сочини под аккорды', Icons.queue_music, () {
              _run('Сочиняю под аккорды', (d) async {
                final ch = await h.melodyOverChords(kProgressions[_prog],
                    channel: _melodyCh, temperature: t, onDownload: d);
                _melodyCh = ch;
                return 'Мелодия + аккорды ${kProgressions[_prog].join(' ')}';
              });
            }),
          ]),
          const SizedBox(height: 10),
          const Text('Модели Magenta (Google) работают прямо на планшете. При первом нажатии скачиваются (6–20 МБ).',
              style: TextStyle(color: C.textDim, fontSize: 12)),
        ]),
      ),
    );
  }
}

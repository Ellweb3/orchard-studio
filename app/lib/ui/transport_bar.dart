import 'package:flutter/material.dart';
import 'package:orchard_engine/orchard_engine.dart';

import '../project.dart';
import 'engine_clock.dart';
import 'export_dialog.dart';
import 'helper_sheet.dart';
import '../ai_helper.dart';
import 'theme.dart';
import 'widgets.dart';

class TransportBar extends StatelessWidget {
  const TransportBar({super.key, required this.project, required this.clock, required this.helper});
  final Project project;
  final EngineClock clock;
  final AiHelper helper;

  @override
  Widget build(BuildContext context) {
    final p = project;
    return Container(
      color: C.bar,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        BarButton(
          key: const ValueKey('play'),
          icon: p.playing ? Icons.pause : Icons.play_arrow,
          active: p.playing,
          color: C.green,
          onTap: p.togglePlay,
        ),
        const SizedBox(width: 8),
        BarButton(key: const ValueKey('stop'), icon: Icons.stop, onTap: p.stop),
        const SizedBox(width: 10),
        // FL's PAT / SONG switch
        GestureDetector(
          key: const ValueKey('patSong'),
          onTap: () => p.setSongMode(!p.songMode),
          child: Container(
            width: 64,
            height: 52,
            decoration: BoxDecoration(color: C.panelHi, borderRadius: BorderRadius.circular(10)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              _ModeLed('PAT', !p.songMode),
              const SizedBox(height: 4),
              _ModeLed('SONG', p.songMode),
            ]),
          ),
        ),
        const SizedBox(width: 16),
        _Tempo(project: p),
        const SizedBox(width: 16),
        Knob(
          value: p.swing,
          defaultValue: 0,
          onChanged: p.setSwing,
          label: 'SWING ${(p.swing * 100).round()}%',
          size: 46,
        ),
        const SizedBox(width: 12),
        BarButton(
          key: const ValueKey('metronome'),
          icon: Icons.timer_outlined,
          active: p.metronome,
          onTap: p.toggleMetronome,
        ),
        const SizedBox(width: 8),
        BarButton(
          key: const ValueKey('helper'),
          icon: Icons.auto_awesome,
          color: C.accent,
          onTap: () => showHelperSheet(context, p, helper),
        ),
        const SizedBox(width: 8),
        BarButton(
          key: const ValueKey('export'),
          icon: Icons.ios_share,
          onTap: () => showExportDialog(context, p),
        ),
        const SizedBox(width: 16),
        Expanded(child: _Patterns(project: p)),
        const SizedBox(width: 12),
        Knob(value: p.master, defaultValue: 0.8, onChanged: p.setMaster, label: 'MASTER', size: 46, color: C.green),
        const SizedBox(width: 6),
        PeakMeter(level: clock.masterLevel, width: 10, height: 52),
      ]),
    );
  }
}

class _ModeLed extends StatelessWidget {
  const _ModeLed(this.label, this.on);
  final String label;
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
        width: 52,
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: on ? (label == 'PAT' ? C.green : C.accent) : C.bar,
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: on ? Colors.black : C.textDim)),
      );
}

class _Tempo extends StatefulWidget {
  const _Tempo({required this.project});
  final Project project;

  @override
  State<_Tempo> createState() => _TempoState();
}

class _TempoState extends State<_Tempo> {
  double _start = 0, _dy = 0;

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    Widget step(IconData i, double d) => IconButton(
          onPressed: () => p.setTempo(p.tempo + d),
          icon: Icon(i, size: 28),
          color: C.text,
          style: IconButton.styleFrom(backgroundColor: C.panelHi, minimumSize: const Size(44, 52)),
        );
    return Row(children: [
      step(Icons.remove, -1),
      const SizedBox(width: 4),
      GestureDetector(
        // drag the display up/down like FL's tempo LCD
        onVerticalDragStart: (_) {
          _start = p.tempo;
          _dy = 0;
        },
        onVerticalDragUpdate: (d) {
          _dy += d.delta.dy;
          p.setTempo(_start - _dy / 4);
        },
        onDoubleTap: () => p.setTempo(130),
        child: Container(
          width: 104,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(p.tempo.toStringAsFixed(0),
                style: const TextStyle(
                    color: C.green, fontSize: 28, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            const Text('BPM', style: TextStyle(color: C.textDim, fontSize: 9, height: 0.9)),
          ]),
        ),
      ),
      const SizedBox(width: 4),
      step(Icons.add, 1),
    ]);
  }
}

class _Patterns extends StatelessWidget {
  const _Patterns({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context) {
    final p = project;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        const Text('PATTERN', style: TextStyle(color: C.textDim, fontSize: 11)),
        const SizedBox(width: 8),
        for (var i = 0; i < kMaxPatterns; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: BarButton(
              key: ValueKey('pattern$i'),
              text: '${i + 1}',
              size: 48,
              active: p.pattern == i,
              onTap: () => p.selectPattern(i),
            ),
          ),
      ]),
    );
  }
}

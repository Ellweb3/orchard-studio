import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orchard_engine/orchard_engine.dart';

import '../project.dart';
import '../song.dart';
import 'engine_clock.dart';
import 'theme.dart';
import 'widgets.dart';

const double kStripW = 96;

class MixerView extends StatelessWidget {
  const MixerView({super.key, required this.project, required this.clock});
  final Project project;
  final EngineClock clock;

  @override
  Widget build(BuildContext context) {
    // inserts that have channels first, then the rest
    final used = [for (var i = 1; i < kMixerInserts; i++) if (project.channels.any((c) => c.insert == i)) i];
    final free = [for (var i = 1; i < kMixerInserts; i++) if (!used.contains(i)) i];
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: C.panel, borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Row(children: [
        _Strip(project: project, clock: clock, index: 0),
        Container(width: 2, color: Colors.black54),
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [for (final i in [...used, ...free]) _Strip(project: project, clock: clock, index: i)],
            ),
          ),
        ),
      ]),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.project, required this.clock, required this.index});
  final Project project;
  final EngineClock clock;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final ins = p.inserts[index];
    final master = index == 0;
    return Container(
      width: master ? kStripW + 16 : kStripW,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.black26))),
      child: Column(children: [
        Text(master ? 'MASTER' : '$index',
            style: TextStyle(color: master ? C.accent : C.textDim, fontWeight: FontWeight.w700, fontSize: 12)),
        const SizedBox(height: 2),
        SizedBox(
          height: 32,
          child: Text(p.insertLabel(index),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.text, fontSize: 12)),
        ),
        const SizedBox(height: 4),
        for (var s = 0; s < kFxSlots; s++) _FxSlot(project: p, ins: index, slot: s),
        const SizedBox(height: 6),
        Knob(
          value: ins.pan,
          min: -1,
          max: 1,
          bipolar: true,
          defaultValue: 0,
          size: 38,
          color: C.textDim,
          onChanged: (v) => p.updateInsert(index, (d) => d.pan = v),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _Fader(value: ins.vol, onChanged: (v) => p.updateInsert(index, (d) => d.vol = v)),
            const SizedBox(width: 6),
            LayoutBuilder(
              builder: (_, box) => PeakMeter(level: clock.insertLevels[index], width: 10, height: box.maxHeight),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          height: 40,
          child: FilledButton(
            key: ValueKey('insMute$index'),
            style: FilledButton.styleFrom(
              backgroundColor: ins.mute ? C.panelHi : C.green,
              foregroundColor: ins.mute ? C.textDim : Colors.black,
              padding: EdgeInsets.zero,
            ),
            onPressed: () => p.updateInsert(index, (d) => d.mute = !d.mute),
            child: Text(ins.mute ? 'выкл' : 'вкл', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}

/// Vertical fader: drag, double-tap = 0 dB (0.8, FL).
class _Fader extends StatefulWidget {
  const _Fader({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_Fader> createState() => _FaderState();
}

class _FaderState extends State<_Fader> {
  double _start = 0;
  double _dy = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final h = box.maxHeight;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => widget.onChanged(0.8),
        onVerticalDragStart: (_) {
          _start = widget.value;
          _dy = 0;
        },
        onVerticalDragUpdate: (d) {
          _dy += d.delta.dy;
          widget.onChanged((_start - _dy / math.max(80, h - 30)).clamp(0.0, 1.0));
        },
        child: SizedBox(
          width: 40,
          height: h,
          child: CustomPaint(painter: _FaderPainter(widget.value)),
        ),
      );
    });
  }
}

class _FaderPainter extends CustomPainter {
  _FaderPainter(this.v);
  final double v;

  @override
  void paint(Canvas canvas, Size size) {
    const cap = 26.0;
    final travel = size.height - cap;
    final cx = size.width / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(cx - 3, cap / 2, 6, travel), const Radius.circular(3)),
      Paint()..color = C.bar,
    );
    // 0 dB mark
    final y0 = cap / 2 + travel * (1 - 0.8);
    canvas.drawLine(Offset(cx - 14, y0), Offset(cx + 14, y0), Paint()..color = C.textDim);
    final y = travel * (1 - v);
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(2, y, size.width - 4, cap), const Radius.circular(5));
    canvas.drawRRect(r, Paint()..color = const Color(0xFFB8C2C8));
    canvas.drawLine(Offset(6, y + cap / 2), Offset(size.width - 6, y + cap / 2),
        Paint()
          ..color = Colors.black87
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_FaderPainter o) => o.v != v;
}

class _FxSlot extends StatelessWidget {
  const _FxSlot({required this.project, required this.ins, required this.slot});
  final Project project;
  final int ins, slot;

  @override
  Widget build(BuildContext context) {
    final f = project.inserts[ins].fx[slot];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: f == null ? C.bar : (f.bypass ? C.panelHi : const Color(0xFF3E6B8A)),
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          key: ValueKey('fx$ins.$slot'),
          borderRadius: BorderRadius.circular(5),
          onTap: () => f == null ? _pickFx(context) : _editFx(context),
          child: SizedBox(
            height: 30,
            width: double.infinity,
            child: Center(
              child: Text(
                f == null ? '+' : kFxDefs[f.kind].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: f == null ? C.textDim : C.text, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickFx(BuildContext context) async {
    final kind = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: C.panel,
      constraints: const BoxConstraints(maxWidth: double.infinity),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            for (var k = 0; k < kFxDefs.length; k++)
              SizedBox(
                width: 180,
                height: 60,
                child: FilledButton.tonal(
                  key: ValueKey('fxKind$k'),
                  onPressed: () => Navigator.pop(c, k),
                  child: Text(kFxDefs[k].name, style: const TextStyle(fontSize: 16)),
                ),
              ),
          ]),
        ),
      ),
    );
    if (kind == null) return;
    project.setFx(ins, slot, kind);
    if (context.mounted) _editFx(context);
  }

  Future<void> _editFx(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        backgroundColor: C.panel,
        constraints: const BoxConstraints(maxWidth: double.infinity),
        builder: (c) => StatefulBuilder(builder: (c, setState) {
          final f = project.inserts[ins].fx[slot];
          if (f == null) return const SizedBox();
          final def = kFxDefs[f.kind];
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Text(def.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 12),
                  Text(ins == 0 ? 'Master' : 'Insert $ins', style: const TextStyle(color: C.textDim)),
                  const Spacer(),
                  const Text('Вкл'),
                  Switch(
                    value: !f.bypass,
                    onChanged: (on) {
                      project.setFxBypass(ins, slot, !on);
                      setState(() {});
                    },
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(c);
                      project.setFx(ins, slot, null);
                    },
                    icon: const Icon(Icons.delete_outline, color: C.red),
                    label: const Text('Убрать', style: TextStyle(color: C.red)),
                  ),
                ]),
                const SizedBox(height: 16),
                Wrap(spacing: 28, runSpacing: 16, children: [
                  for (var i = 0; i < def.params.length; i++)
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Knob(
                        value: f.params[i],
                        defaultValue: def.defaults[i],
                        size: 64,
                        onChanged: (v) {
                          project.setFxParam(ins, slot, i, v);
                          setState(() {});
                        },
                      ),
                      const SizedBox(height: 4),
                      Text(def.params[i], style: const TextStyle(fontSize: 13)),
                      Text(_paramText(f.kind, i, f.params[i]), style: const TextStyle(fontSize: 11, color: C.textDim)),
                    ]),
                ]),
              ]),
            ),
          );
        }),
      );
}

/// Readable values (mirrors the DSP mappings in engine/rust/src/fx.rs).
String _paramText(int kind, int i, double v) {
  String pct() => '${(v * 100).round()}%';
  switch ((kind, i)) {
    case (1, 0):
      final n = (1 + (v * 15).round()).clamp(1, 16);
      return '$n/16';
    case (1, 4):
      return v > 0.5 ? 'вкл' : 'выкл';
    case (2, 0):
      final hz = 20 * math.pow(1000, v);
      return hz >= 1000 ? '${(hz / 1000).toStringAsFixed(1)} кГц' : '${hz.round()} Гц';
    case (2, 2):
      return v < 0.33 ? 'LP' : (v < 0.66 ? 'BP' : 'HP');
    case (4, 0):
      return '${(-40 + v * 40).round()} дБ';
    case (4, 1):
      return '${(1 + v * 19).toStringAsFixed(1)}:1';
    case (4, 4):
      return '+${(v * 24).toStringAsFixed(1)} дБ';
    default:
      return pct();
  }
}

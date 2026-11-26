import 'package:flutter/material.dart';
import 'package:orchard_engine/orchard_engine.dart';

import '../project.dart';
import 'engine_clock.dart';
import 'theme.dart';
import 'widgets.dart';

const double kRowHeight = 64;
const double kRowControlsWidth = 300;

class ChannelRack extends StatelessWidget {
  const ChannelRack({super.key, required this.project, required this.clock});
  final Project project;
  final EngineClock clock;

  @override
  Widget build(BuildContext context) {
    final p = project;
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: C.panel, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        _Header(project: p),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            children: [
              for (var i = 0; i < p.channels.length; i++) _ChannelRow(project: p, clock: clock, index: i),
              const SizedBox(height: 6),
              if (p.canAddChannel)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: kRowControlsWidth - 10,
                    height: 48,
                    child: OutlinedButton.icon(
                      key: const ValueKey('addChannel'),
                      onPressed: () => _pickSound(context, (s) => p.addChannel(s)),
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить звук'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final len = p.patternLength[p.pattern];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 6),
      child: Row(children: [
        const Text('Channel rack', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: C.text)),
        const SizedBox(width: 12),
        Text('Pattern ${p.pattern + 1}', style: const TextStyle(color: C.accent, fontSize: 15)),
        const Spacer(),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 16, label: Text('16')),
            ButtonSegment(value: 32, label: Text('32')),
            ButtonSegment(value: 64, label: Text('64')),
          ],
          selected: {len},
          showSelectedIcon: false,
          onSelectionChanged: (s) => p.setPatternLength(s.first),
        ),
        const SizedBox(width: 10),
        IconButton(
          tooltip: 'Очистить паттерн',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text('Очистить Pattern ${p.pattern + 1}?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Нет')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Очистить')),
                ],
              ),
            );
            if (ok == true) p.clearPattern();
          },
        ),
      ]),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.project, required this.clock, required this.index});
  final Project project;
  final EngineClock clock;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final c = p.channels[index];
    final anySolo = p.channels.any((x) => x.solo);
    final audible = !c.mute && (!anySolo || c.solo);
    return SizedBox(
      height: kRowHeight,
      child: Row(children: [
        SizedBox(
          width: kRowControlsWidth,
          child: Row(children: [
            // LED: tap = mute, long press = solo (FL: right click)
            GestureDetector(
              key: ValueKey('led$index'),
              onTap: () => p.updateChannel(index, (c) => c.mute = !c.mute),
              onLongPress: () => p.updateChannel(index, (c) {
                final was = c.solo;
                for (final x in p.channels) {
                  x.solo = false;
                }
                c.solo = !was;
              }),
              child: Container(
                width: 36,
                height: 48,
                alignment: Alignment.center,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: audible ? C.green : C.bar,
                    border: Border.all(color: c.solo ? C.accent : Colors.black54, width: c.solo ? 3 : 1),
                  ),
                ),
              ),
            ),
            Knob(
              value: c.pan,
              min: -1,
              max: 1,
              bipolar: true,
              defaultValue: 0,
              size: 40,
              color: C.textDim,
              onChanged: (v) => p.updateChannel(index, (c) => c.pan = v),
            ),
            const SizedBox(width: 2),
            Knob(
              value: c.vol,
              defaultValue: kDefaultVolume,
              size: 40,
              color: C.green,
              onChanged: (v) => p.updateChannel(index, (c) => c.vol = v),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _NameButton(project: p, index: index),
            ),
            const SizedBox(width: 6),
            PeakMeter(level: clock.levels[index], width: 6, height: 44),
            const SizedBox(width: 8),
          ]),
        ),
        Expanded(child: _StepRow(project: p, clock: clock, ch: index)),
      ]),
    );
  }
}

class _NameButton extends StatelessWidget {
  const _NameButton({required this.project, required this.index});
  final Project project;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = project.channels[index];
    return Material(
      color: C.panelHi,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        key: ValueKey('name$index'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => project.preview(index),
        onLongPress: () => _channelMenu(context, project, index),
        child: SizedBox(
          height: 46,
          child: Center(
            child: Text(c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.text, fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}

/// Step pads. Tap toggles; drag sideways paints (or erases, if the first pad was on).
class _StepRow extends StatefulWidget {
  const _StepRow({required this.project, required this.clock, required this.ch});
  final Project project;
  final EngineClock clock;
  final int ch;

  @override
  State<_StepRow> createState() => _StepRowState();
}

class _StepRowState extends State<_StepRow> {
  bool _paint = true;
  int _last = -1;

  int _len() => widget.project.patternLength[widget.project.pattern];

  int _index(double x, double width) => (x / (width / _len())).floor().clamp(0, _len() - 1);

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return GestureDetector(
        key: ValueKey('steps${widget.ch}'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final i = _index(d.localPosition.dx, w);
          p.setStep(widget.ch, i, p.step(widget.ch, i) == 0);
        },
        onHorizontalDragStart: (d) {
          final i = _index(d.localPosition.dx, w);
          _paint = p.step(widget.ch, i) == 0;
          _last = i;
          p.setStep(widget.ch, i, _paint);
        },
        onHorizontalDragUpdate: (d) {
          final i = _index(d.localPosition.dx, w);
          if (i != _last) {
            _last = i;
            p.setStep(widget.ch, i, _paint);
          }
        },
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size(w, kRowHeight),
            painter: _StepPainter(
              steps: p.steps[p.pattern][widget.ch],
              length: _len(),
              playhead: widget.clock.step,
              version: Object.hashAll(p.steps[p.pattern][widget.ch].take(_len())),
            ),
          ),
        ),
      );
    });
  }
}

class _StepPainter extends CustomPainter {
  _StepPainter({required this.steps, required this.length, required this.playhead, required this.version})
      : super(repaint: playhead);
  final List<int> steps;
  final int length;
  final ValueNotifier<int> playhead;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / length;
    final gap = cell > 30 ? 4.0 : 2.0;
    final h = size.height - 12;
    final cur = playhead.value;
    for (var i = 0; i < length; i++) {
      final on = steps[i] > 0;
      final groupB = (i ~/ 4).isOdd;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * cell + gap / 2, 6, cell - gap, h),
        const Radius.circular(5),
      );
      Color color = on ? C.stepOn : (groupB ? C.stepOffB : C.stepOffA);
      if (i == cur) color = on ? C.playhead : Color.lerp(color, C.playhead, 0.35)!;
      canvas.drawRRect(r, Paint()..color = color);
      if (!on) {
        // inner shade for a "pad" look
        canvas.drawRRect(r.deflate(3), Paint()..color = Colors.black.withValues(alpha: 0.12));
      }
    }
  }

  @override
  bool shouldRepaint(_StepPainter o) => o.version != version || o.length != length || o.steps != steps;
}

// -------------------------------------------------------------- sheets
Future<void> _pickSound(BuildContext context, void Function(int sample) onPick) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: C.panel,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 12, runSpacing: 12, children: [
          for (var s = 0; s < kSounds.length; s++)
            SizedBox(
              width: 170,
              height: 64,
              child: FilledButton.tonal(
                key: ValueKey('sound$s'),
                onPressed: () {
                  onPick(s);
                  Navigator.pop(c);
                },
                child: Text(kSounds[s], style: const TextStyle(fontSize: 17)),
              ),
            ),
        ]),
      ),
    ),
  );
}

Future<void> _channelMenu(BuildContext context, Project p, int index) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: C.panel,
    builder: (c) => StatefulBuilder(builder: (c, setState) {
      final ch = p.channels[index];
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ch.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text('Звук', style: TextStyle(color: C.textDim)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var s = 0; s < kSounds.length; s++)
                ChoiceChip(
                  label: Text(kSounds[s]),
                  selected: ch.sample == s,
                  onSelected: (_) {
                    p.updateChannel(index, (c) {
                      if (c.name == kSounds[c.sample]) c.name = kSounds[s];
                      c.sample = s;
                    });
                    p.preview(index);
                    setState(() {});
                  },
                ),
            ]),
            const SizedBox(height: 16),
            Text('Высота: ${ch.pitch.round() >= 0 ? '+' : ''}${ch.pitch.round()} полутонов',
                style: const TextStyle(color: C.textDim)),
            Slider(
              value: ch.pitch,
              min: -24,
              max: 24,
              divisions: 48,
              onChanged: (v) {
                p.updateChannel(index, (c) => c.pitch = v);
                setState(() {});
              },
              onChangeEnd: (_) => p.preview(index),
            ),
            const SizedBox(height: 8),
            Row(children: [
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(c);
                  p.removeChannel(index);
                },
                icon: const Icon(Icons.delete_outline, color: C.red),
                label: const Text('Удалить канал', style: TextStyle(color: C.red)),
              ),
              const Spacer(),
              FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Готово')),
            ]),
          ]),
        ),
      );
    }),
  );
}

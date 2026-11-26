import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:orchard_engine/orchard_engine.dart';

import '../instruments.dart';
import '../project.dart';
import 'engine_clock.dart';
import 'instrument_picker.dart';
import 'theme.dart';
import 'widgets.dart';

const int kLowKey = 24; // C2 (FL naming: key 60 = C5)
const int kHighKey = 107; // B8
const double kKeyH = 26;
const double kKeyboardW = 84;
const _names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

String keyName(int k) => '${_names[k % 12]}${k ~/ 12}';
bool isBlack(int k) => const [1, 3, 6, 8, 10].contains(k % 12);

/// GM percussion map (MIDI key -> name) for drum kit channels.
const Map<int, String> kGmDrums = {
  35: 'Бочка 2', 36: 'Бочка', 37: 'Римшот', 38: 'Малый', 39: 'Хлопок', 40: 'Малый 2', 41: 'Том низ 2',
  42: 'Хэт закр.', 43: 'Том низ', 44: 'Хэт педаль', 45: 'Том ср. низ', 46: 'Хэт откр.', 47: 'Том ср.',
  48: 'Том ср. верх', 49: 'Крэш', 50: 'Том верх', 51: 'Райд', 52: 'Чайна', 53: 'Райд колокол',
  54: 'Бубен', 55: 'Сплэш', 56: 'Ковбелл', 57: 'Крэш 2', 58: 'Вибраслэп', 59: 'Райд 2', 60: 'Бонго верх',
  61: 'Бонго низ', 62: 'Конга глух.', 63: 'Конга откр.', 64: 'Конга низ', 65: 'Тимбал верх',
  66: 'Тимбал низ', 67: 'Агого верх', 68: 'Агого низ', 69: 'Кабаса', 70: 'Маракас', 71: 'Свисток кор.',
  72: 'Свисток дл.', 73: 'Гуиро кор.', 74: 'Гуиро дл.', 75: 'Клавес', 76: 'Вуд-блок верх',
  77: 'Вуд-блок низ', 78: 'Куика глух.', 79: 'Куика откр.', 80: 'Треугольник глух.', 81: 'Треугольник',
};

class PianoRollPage extends StatefulWidget {
  const PianoRollPage({super.key, required this.project, required this.clock, required this.channel});
  final Project project;
  final EngineClock clock;
  final int channel;

  @override
  State<PianoRollPage> createState() => _PianoRollPageState();
}

enum _Mode { none, move, resize, scroll }

class _PianoRollPageState extends State<PianoRollPage> {
  late final ScrollController _scroll;
  int _noteLen = 2 * kTicksPerStep; // last used length (FL keeps the last one)
  _Mode _mode = _Mode.none;
  NoteData? _drag;
  int _origPos = 0, _origLen = 0, _origKey = 0;
  Offset _start = Offset.zero;
  final Set<int> _held = {};

  Project get p => widget.project;
  int get ch => widget.channel;
  bool get _drums => p.channels[ch].inst.kind == InstKind.soundfont && p.channels[ch].inst.bank >= 128;

  @override
  void initState() {
    super.initState();
    final notes = p.channelNotes(ch);
    final center = _drums
        ? 44
        : notes.isEmpty
            ? 66
            : notes.map((n) => n.key).reduce((a, b) => a + b) ~/ notes.length;
    _scroll = ScrollController(initialScrollOffset: math.max(0, (kHighKey - center) * kKeyH - 220));
  }

  @override
  void dispose() {
    for (final k in _held) {
      p.noteOff(ch, k);
    }
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ geometry
  double _tpx(double w) => w / p.patternTicks; // px per tick
  int _keyAt(double y) => (kHighKey - (y / kKeyH).floor()).clamp(kLowKey, kHighKey);
  int _snap(double ticks) => (ticks / kTicksPerStep).floor() * kTicksPerStep;

  NoteData? _noteAt(Offset o, double w) {
    final k = _keyAt(o.dy);
    final t = o.dx / _tpx(w);
    for (final n in p.channelNotes(ch).reversed) {
      if (n.key == k && t >= n.pos && t < n.end) return n;
    }
    return null;
  }

  // ------------------------------------------------------------ gestures
  void _tap(TapUpDetails d, double w) {
    final hit = _noteAt(d.localPosition, w);
    if (hit != null) {
      p.removeNote(ch, hit);
    } else {
      final pos = _snap(d.localPosition.dx / _tpx(w));
      final key = _keyAt(d.localPosition.dy);
      p.addNote(ch, pos, math.min(_noteLen, p.patternTicks - pos), key);
      p.preview(ch, key);
    }
  }

  void _scaleStart(ScaleStartDetails d, double w) {
    _start = d.localFocalPoint;
    if (d.pointerCount >= 2) {
      _mode = _Mode.scroll;
      return;
    }
    final hit = _noteAt(d.localFocalPoint, w);
    if (hit != null) {
      final right = (hit.pos + (hit.len == 0 ? kTicksPerStep : hit.len)) * _tpx(w);
      final width = (hit.len == 0 ? kTicksPerStep : hit.len) * _tpx(w);
      _mode = (right - d.localFocalPoint.dx < math.max(16, width * 0.3)) ? _Mode.resize : _Mode.move;
      _drag = hit;
    } else {
      final pos = _snap(d.localFocalPoint.dx / _tpx(w));
      final key = _keyAt(d.localFocalPoint.dy);
      _drag = p.addNote(ch, pos, math.min(_noteLen, p.patternTicks - pos), key);
      _mode = _Mode.move;
      p.preview(ch, key);
    }
    _origPos = _drag!.pos;
    _origLen = _drag!.len == 0 ? kTicksPerStep : _drag!.len;
    _origKey = _drag!.key;
  }

  void _scaleUpdate(ScaleUpdateDetails d, double w) {
    if (d.pointerCount >= 2 || _mode == _Mode.scroll) {
      _mode = _Mode.scroll;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo((_scroll.offset - d.focalPointDelta.dy).clamp(0, max));
      return;
    }
    final n = _drag;
    if (n == null) return;
    final delta = d.localFocalPoint - _start;
    final dt = delta.dx / _tpx(w);
    if (_mode == _Mode.move) {
      final pos = _snap(_origPos + dt + kTicksPerStep / 2).clamp(0, p.patternTicks - kTicksPerStep);
      final key = (_origKey - (delta.dy / kKeyH).round()).clamp(kLowKey, kHighKey);
      if (pos != n.pos || key != n.key) {
        if (key != n.key) p.preview(ch, key);
        n
          ..pos = pos
          ..key = key;
        if (n.pos + n.len > p.patternTicks) n.len = p.patternTicks - n.pos;
        p.noteChanged(ch);
      }
    } else if (_mode == _Mode.resize) {
      final len = (_snap(_origLen + dt + kTicksPerStep / 2)).clamp(kTicksPerStep, p.patternTicks - n.pos);
      if (len != n.len) {
        n.len = len;
        _noteLen = len;
        p.noteChanged(ch);
      }
    }
  }

  void _scaleEnd() {
    _mode = _Mode.none;
    _drag = null;
  }

  // ------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: p,
          builder: (context, _) {
            if (ch >= p.channels.length) return const SizedBox();
            final c = p.channels[ch];
            return Column(children: [
              _toolbar(c),
              Expanded(
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 10,
                  child: Listener(
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        _scroll.jumpTo((_scroll.offset + e.scrollDelta.dy).clamp(0, _scroll.position.maxScrollExtent));
                      }
                    },
                    child: SingleChildScrollView(
                      controller: _scroll,
                      physics: const NeverScrollableScrollPhysics(),
                      child: SizedBox(
                        height: (kHighKey - kLowKey + 1) * kKeyH,
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _keyboard(),
                          Expanded(child: _grid()),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _toolbar(ChannelData c) {
    const lens = [1, 2, 4, 8, 16];
    const labels = ['1/16', '1/8', '1/4', '1/2', '1'];
    return Container(
      color: C.bar,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(children: [
        BarButton(key: const ValueKey('prBack'), icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
        const SizedBox(width: 12),
        BarButton(
          key: const ValueKey('prPlay'),
          icon: p.playing ? Icons.pause : Icons.play_arrow,
          active: p.playing,
          color: C.green,
          onTap: p.togglePlay,
        ),
        const SizedBox(width: 16),
        const Text('Piano roll', style: TextStyle(color: C.textDim, fontSize: 13)),
        const SizedBox(width: 8),
        Material(
          color: C.panelHi,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: const ValueKey('prInstrument'),
            borderRadius: BorderRadius.circular(10),
            onTap: () async {
              final spec = await pickInstrument(context, p.engine, current: c.inst);
              if (spec != null) {
                p.setInstrument(ch, spec);
                p.preview(ch, 60);
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(children: [
                Text(c.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: C.accent)),
                const SizedBox(width: 6),
                const Icon(Icons.expand_more, size: 20),
              ]),
            ),
          ),
        ),
        const Spacer(),
        const Text('Длина ноты', style: TextStyle(color: C.textDim, fontSize: 12)),
        const SizedBox(width: 8),
        SegmentedButton<int>(
          segments: [
            for (var i = 0; i < lens.length; i++)
              ButtonSegment(value: lens[i] * kTicksPerStep, label: Text(labels[i])),
          ],
          selected: {lens.map((l) => l * kTicksPerStep).contains(_noteLen) ? _noteLen : -1},
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          onSelectionChanged: (s) {
            if (s.isNotEmpty) setState(() => _noteLen = s.first);
          },
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Стереть ноты канала',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: () => p.clearChannel(ch),
        ),
      ]),
    );
  }

  Widget _keyboard() {
    final drums = _drums;
    return SizedBox(
      width: kKeyboardW,
      child: Column(children: [
        for (var k = kHighKey; k >= kLowKey; k--)
          GestureDetector(
            key: ValueKey('key$k'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) {
              _held.add(k);
              p.noteOn(ch, k);
            },
            onTapUp: (_) {
              _held.remove(k);
              p.noteOff(ch, k);
            },
            onTapCancel: () {
              _held.remove(k);
              p.noteOff(ch, k);
            },
            onVerticalDragUpdate: (d) =>
                _scroll.jumpTo((_scroll.offset - d.delta.dy).clamp(0, _scroll.position.maxScrollExtent)),
            child: Container(
              height: kKeyH,
              decoration: BoxDecoration(
                color: isBlack(k) ? const Color(0xFF1B1F22) : const Color(0xFFE4E7EA),
                border: const Border(bottom: BorderSide(color: Colors.black26, width: 0.5)),
              ),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                drums ? (kGmDrums[k] ?? '') : (k % 12 == 0 ? keyName(k) : ''),
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: drums ? 10 : 12,
                  fontWeight: FontWeight.w700,
                  color: isBlack(k) ? C.textDim : Colors.black87,
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _grid() => LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        return GestureDetector(
          key: const ValueKey('prGrid'),
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _tap(d, w),
          onScaleStart: (d) => _scaleStart(d, w),
          onScaleUpdate: (d) => _scaleUpdate(d, w),
          onScaleEnd: (_) => _scaleEnd(),
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size(w, box.maxHeight),
              painter: _GridPainter(
                notes: p.channelNotes(ch),
                ticks: p.patternTicks,
                playhead: widget.clock.ticks,
                version: Object.hashAll(p.channelNotes(ch).map((n) => Object.hash(n.pos, n.len, n.key))),
              ),
            ),
          ),
        );
      });
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.notes, required this.ticks, required this.playhead, required this.version})
      : super(repaint: playhead);
  final List<NoteData> notes;
  final int ticks;
  final ValueNotifier<double> playhead;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    final tpx = size.width / ticks;
    // rows
    for (var k = kHighKey; k >= kLowKey; k--) {
      final y = (kHighKey - k) * kKeyH;
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, kKeyH),
          Paint()..color = isBlack(k) ? const Color(0xFF2A3236) : const Color(0xFF343E44));
      if (k % 12 == 0) {
        canvas.drawLine(Offset(0, y + kKeyH), Offset(size.width, y + kKeyH), Paint()..color = Colors.black54);
      }
    }
    // step / beat / bar lines
    for (var t = 0; t <= ticks; t += kTicksPerStep) {
      final x = t * tpx;
      final bar = t % (kPpq * 4) == 0, beat = t % kPpq == 0;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = bar ? Colors.black : (beat ? Colors.black54 : Colors.black26)
          ..strokeWidth = bar ? 2 : 1,
      );
    }
    // notes
    for (final n in notes) {
      final len = n.len == 0 ? kTicksPerStep : n.len;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(n.pos * tpx + 1, (kHighKey - n.key) * kKeyH + 1, len * tpx - 2, kKeyH - 2),
        const Radius.circular(4),
      );
      canvas.drawRRect(r, Paint()..color = const Color(0xFF7FD36B));
      canvas.drawRRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0xFF2F5E27)
            ..strokeWidth = 1.5);
      // resize grip
      final gx = r.right - 6;
      canvas.drawLine(Offset(gx, r.top + 6), Offset(gx, r.bottom - 6),
          Paint()
            ..color = const Color(0xFF2F5E27)
            ..strokeWidth = 2);
      if (len * tpx > 34) {
        final tp = TextPainter(
          text: TextSpan(text: keyName(n.key), style: const TextStyle(fontSize: 10, color: Color(0xFF1C3A17))),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(r.left + 4, r.top + (kKeyH - 2 - tp.height) / 2));
      }
    }
    final ph = playhead.value;
    if (ph >= 0) {
      final x = ph * tpx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..color = C.playhead
        ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_GridPainter o) => o.version != version || o.ticks != ticks || o.notes != notes;
}

/// Small piano-roll preview drawn in the Channel Rack row (FL shows this
/// instead of steps when a channel has piano roll notes).
class NotePreviewPainter extends CustomPainter {
  NotePreviewPainter({required this.notes, required this.ticks, required this.playhead, required this.version})
      : super(repaint: playhead);
  final List<NoteData> notes;
  final int ticks;
  final ValueNotifier<int> playhead;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(2, 6, size.width - 4, size.height - 12), const Radius.circular(6));
    canvas.drawRRect(r, Paint()..color = const Color(0xFF2A3236));
    if (notes.isEmpty) return;
    var lo = notes.first.key, hi = notes.first.key;
    for (final n in notes) {
      lo = math.min(lo, n.key);
      hi = math.max(hi, n.key);
    }
    lo -= 2;
    hi += 2;
    final tpx = (size.width - 8) / ticks;
    final kh = (size.height - 16) / (hi - lo + 1);
    for (final n in notes) {
      final len = n.len == 0 ? kTicksPerStep : n.len;
      canvas.drawRect(
        Rect.fromLTWH(4 + n.pos * tpx, 8 + (hi - n.key) * kh, math.max(2, len * tpx - 1), math.max(2, kh)),
        Paint()..color = const Color(0xFF7FD36B),
      );
    }
    final s = playhead.value;
    if (s >= 0) {
      final x = 4 + s * kTicksPerStep * tpx;
      canvas.drawLine(Offset(x, 6), Offset(x, size.height - 6), Paint()
        ..color = C.playhead
        ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(NotePreviewPainter o) => o.version != version || o.ticks != ticks;
}

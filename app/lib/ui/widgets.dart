import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Touch knob: drag up/down (or sideways) to turn, double-tap to reset.
class Knob extends StatefulWidget {
  const Knob({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.defaultValue,
    this.bipolar = false,
    this.size = 44,
    this.color = C.accent,
    this.label,
  });

  final double value, min, max;
  final double? defaultValue;
  final bool bipolar;
  final double size;
  final Color color;
  final String? label;
  final ValueChanged<double> onChanged;

  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  double _start = 0;
  Offset _origin = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final norm = ((widget.value - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);
    final knob = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: widget.defaultValue == null ? null : () => widget.onChanged(widget.defaultValue!),
      onPanStart: (d) {
        _start = norm;
        _origin = d.globalPosition;
      },
      onPanUpdate: (d) {
        final delta = d.globalPosition - _origin;
        final n = (_start + (-delta.dy + delta.dx) / 200).clamp(0.0, 1.0);
        widget.onChanged(widget.min + n * (widget.max - widget.min));
      },
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(painter: _KnobPainter(norm, widget.bipolar, widget.color)),
      ),
    );
    if (widget.label == null) return knob;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      knob,
      const SizedBox(height: 2),
      Text(widget.label!, style: const TextStyle(fontSize: 10, color: C.textDim)),
    ]);
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter(this.v, this.bipolar, this.color);
  final double v;
  final bool bipolar;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 3;
    const start = math.pi * 0.75, sweep = math.pi * 1.5;
    final rect = Rect.fromCircle(center: c, radius: r);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = C.bar;
    canvas.drawArc(rect, start, sweep, false, track);
    final from = bipolar ? start + sweep / 2 : start;
    final to = start + sweep * v;
    canvas.drawArc(rect, math.min(from, to), (to - from).abs(), false, track..color = color);
    canvas.drawCircle(c, r - 6, Paint()..color = C.panelHi);
    final a = start + sweep * v;
    canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * (r - 14), c + Offset(math.cos(a), math.sin(a)) * (r - 6),
        Paint()
          ..color = C.text
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_KnobPainter o) => o.v != v || o.color != color;
}

/// Vertical peak meter fed by a ValueNotifier (0..1, linear).
class PeakMeter extends StatelessWidget {
  const PeakMeter({super.key, required this.level, this.width = 6, this.height = 36});
  final ValueNotifier<double> level;
  final double width, height;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: SizedBox(
          width: width,
          height: height,
          child: CustomPaint(painter: _MeterPainter(level)),
        ),
      );
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.level) : super(repaint: level);
  final ValueNotifier<double> level;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = C.bar);
    // dB scale, -48..0 dB
    final v = level.value;
    final db = v <= 0 ? -100.0 : 20 * math.log(v) / math.ln10;
    final h = ((db + 48) / 48).clamp(0.0, 1.0) * size.height;
    final color = v >= 0.99 ? C.red : (db > -6 ? C.accent : C.green);
    canvas.drawRect(Rect.fromLTWH(0, size.height - h, size.width, h), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MeterPainter o) => false;
}

/// Rounded toolbar button with an icon or text.
class BarButton extends StatelessWidget {
  const BarButton({super.key, this.icon, this.text, required this.onTap, this.active = false, this.color, this.size = 52});
  final IconData? icon;
  final String? text;
  final VoidCallback onTap;
  final bool active;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.black : (color ?? C.text);
    return Material(
      color: active ? (color ?? C.accent) : C.panelHi,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: size,
          width: text == null ? size : null,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: text == null ? 0 : 14),
            child: Center(
              child: icon != null
                  ? Icon(icon, color: fg, size: size * 0.55)
                  : Text(text!, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ),
      ),
    );
  }
}

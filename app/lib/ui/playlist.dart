import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orchard_engine/orchard_engine.dart';

import '../project.dart';
import '../song.dart';
import 'engine_clock.dart';
import 'theme.dart';

const double kTrackH = 64;
const double kBarW = 56;
const double kTrackHeaderW = 110;

/// One colour per pattern (FL colours clips by pattern).
const List<Color> kPatternColors = [
  Color(0xFF6FA8DC),
  Color(0xFFE88E5A),
  Color(0xFF8BC34A),
  Color(0xFFBA68C8),
  Color(0xFFFFD54F),
  Color(0xFF4DB6AC),
  Color(0xFFF06292),
  Color(0xFF90A4AE),
];

class PlaylistView extends StatefulWidget {
  const PlaylistView({super.key, required this.project, required this.clock});
  final Project project;
  final EngineClock clock;

  @override
  State<PlaylistView> createState() => _PlaylistViewState();
}

enum _Drag { none, move, resize }

class _PlaylistViewState extends State<PlaylistView> {
  final _hScroll = ScrollController(); // bar ruler
  final _gScroll = ScrollController(); // grid

  @override
  void initState() {
    super.initState();
    _gScroll.addListener(() {
      if (_hScroll.hasClients) _hScroll.jumpTo(_gScroll.offset);
    });
  }
  _Drag _mode = _Drag.none;
  ClipData? _clip;
  int _origStart = 0, _origLen = 0, _origTrack = 0;
  Offset _start = Offset.zero;

  Project get p => widget.project;

  @override
  void dispose() {
    _hScroll.dispose();
    _gScroll.dispose();
    super.dispose();
  }

  int _bar(double x) => (x / kBarW).floor().clamp(0, kPlaylistBars - 1);
  int _track(double y) => (y / kTrackH).floor().clamp(0, kPlaylistTracks - 1);

  void _tap(TapUpDetails d) {
    final t = _track(d.localPosition.dy), b = _bar(d.localPosition.dx);
    final hit = p.clipAt(t, b);
    if (hit != null) {
      p.removeClip(hit);
    } else {
      p.addClip(t, b, p.pattern);
    }
  }

  void _dragStart(ScaleStartDetails d) {
    _start = d.localFocalPoint;
    if (d.pointerCount >= 2) {
      _mode = _Drag.none;
      _clip = null;
      return;
    }
    final t = _track(d.localFocalPoint.dy), b = _bar(d.localFocalPoint.dx);
    var hit = p.clipAt(t, b);
    if (hit != null) {
      final right = hit.end * kBarW;
      _mode = right - d.localFocalPoint.dx < math.max(16, hit.len * kBarW * 0.3) ? _Drag.resize : _Drag.move;
    } else {
      hit = p.addClip(t, b, p.pattern);
      _mode = _Drag.move;
    }
    _clip = hit;
    _origStart = hit.start;
    _origLen = hit.len;
    _origTrack = hit.track;
  }

  void _dragUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      // two fingers scroll the arrangement
      final max = _gScroll.position.maxScrollExtent;
      _gScroll.jumpTo((_gScroll.offset - d.focalPointDelta.dx).clamp(0, max));
      return;
    }
    final c = _clip;
    if (c == null) return;
    final delta = d.localFocalPoint - _start;
    final db = (delta.dx / kBarW).round();
    if (_mode == _Drag.move) {
      final s = (_origStart + db).clamp(0, kPlaylistBars - c.len);
      final t = (_origTrack + (delta.dy / kTrackH).round()).clamp(0, kPlaylistTracks - 1);
      if (s != c.start || t != c.track) {
        c
          ..start = s
          ..track = t;
        p.clipChanged();
      }
    } else if (_mode == _Drag.resize) {
      final l = (_origLen + db).clamp(1, kPlaylistBars - c.start);
      if (l != c.len) {
        c.len = l;
        p.clipChanged();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: C.panel, borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Row(children: [
        _palette(),
        Container(width: 1, color: Colors.black45),
        Expanded(child: _arrangement()),
      ]),
    );
  }

  /// Pattern picker: the "brush" for new clips (FL's pattern selector).
  Widget _palette() => SizedBox(
        width: 150,
        child: ListView(padding: const EdgeInsets.all(10), children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Паттерны', style: TextStyle(color: C.textDim, fontSize: 13)),
          ),
          for (var i = 0; i < kMaxPatterns; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: p.pattern == i ? kPatternColors[i] : C.panelHi,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  key: ValueKey('plPattern$i'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => p.selectPattern(i),
                  child: SizedBox(
                    height: 48,
                    child: Row(children: [
                      const SizedBox(width: 10),
                      Container(width: 12, height: 12, decoration: BoxDecoration(color: kPatternColors[i], shape: BoxShape.circle)),
                      const SizedBox(width: 10),
                      Text('Pattern ${i + 1}',
                          style: TextStyle(
                              color: p.pattern == i ? Colors.black : C.text, fontWeight: FontWeight.w600, fontSize: 15)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );

  Widget _arrangement() {
    return Column(children: [
      Container(
        height: 34,
        color: C.bar,
        child: Row(children: [
          const SizedBox(width: kTrackHeaderW, child: Center(child: Text('Playlist', style: TextStyle(color: C.textDim)))),
          Expanded(
            child: SingleChildScrollView(
              controller: _hScroll,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: kBarW * kPlaylistBars,
                child: Row(children: [
                  for (var b = 0; b < kPlaylistBars; b++)
                    SizedBox(
                      width: kBarW,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text('${b + 1}',
                            style: TextStyle(color: b % 4 == 0 ? C.text : C.textDim, fontSize: 12)),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ]),
      ),
      Expanded(
        child: SingleChildScrollView(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: kTrackHeaderW,
              child: Column(children: [
                for (var t = 0; t < kPlaylistTracks; t++)
                  SizedBox(
                    height: kTrackH,
                    child: Row(children: [
                      const SizedBox(width: 10),
                      GestureDetector(
                        key: ValueKey('trackLed$t'),
                        onTap: () => p.toggleTrackMute(t),
                        child: Container(
                          width: 32,
                          height: 40,
                          alignment: Alignment.center,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle, color: p.trackMute[t] ? C.bar : C.green),
                          ),
                        ),
                      ),
                      Text('Track ${t + 1}', style: const TextStyle(color: C.text, fontSize: 13)),
                    ]),
                  ),
              ]),
            ),
            Expanded(
              child: Scrollbar(
                controller: _gScroll,
                thumbVisibility: true,
                interactive: true,
                thickness: 10,
                child: SingleChildScrollView(
                  controller: _gScroll,
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: GestureDetector(
                    key: const ValueKey('plGrid'),
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _tap,
                    // one finger edits clips, two fingers scroll
                    onScaleStart: _dragStart,
                    onScaleUpdate: _dragUpdate,
                    onScaleEnd: (_) {
                      _mode = _Drag.none;
                      _clip = null;
                    },
                    child: RepaintBoundary(
                      child: CustomPaint(
                        size: const Size(kBarW * kPlaylistBars, kTrackH * kPlaylistTracks),
                        painter: _PlaylistPainter(
                          clips: p.clips,
                          trackMute: p.trackMute,
                          ticks: widget.clock.ticks,
                          songMode: p.songMode,
                          version: Object.hashAll([
                            for (final c in p.clips) Object.hash(c.track, c.start, c.len, c.pattern),
                            ...p.trackMute,
                            p.songMode,
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _PlaylistPainter extends CustomPainter {
  _PlaylistPainter(
      {required this.clips, required this.trackMute, required this.ticks, required this.songMode, required this.version})
      : super(repaint: ticks);
  final List<ClipData> clips;
  final List<bool> trackMute;
  final ValueNotifier<double> ticks;
  final bool songMode;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    for (var t = 0; t < kPlaylistTracks; t++) {
      canvas.drawRect(Rect.fromLTWH(0, t * kTrackH, size.width, kTrackH),
          Paint()..color = t.isEven ? const Color(0xFF343E44) : const Color(0xFF2F383E));
    }
    for (var b = 0; b <= kPlaylistBars; b++) {
      canvas.drawLine(Offset(b * kBarW, 0), Offset(b * kBarW, size.height),
          Paint()
            ..color = b % 4 == 0 ? Colors.black : Colors.black38
            ..strokeWidth = b % 4 == 0 ? 1.5 : 1);
    }
    for (final c in clips) {
      final col = kPatternColors[c.pattern % kPatternColors.length];
      final muted = trackMute[c.track];
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(c.start * kBarW + 1, c.track * kTrackH + 3, c.len * kBarW - 2, kTrackH - 6),
        const Radius.circular(6),
      );
      canvas.drawRRect(r, Paint()..color = muted ? col.withValues(alpha: 0.3) : col);
      canvas.drawRRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.black54);
      final tp = TextPainter(
        text: TextSpan(
            text: 'Pattern ${c.pattern + 1}',
            style: const TextStyle(color: Colors.black87, fontSize: 12, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: c.len * kBarW - 12);
      tp.paint(canvas, Offset(r.left + 6, r.top + 6));
      canvas.drawLine(Offset(r.right - 6, r.top + 14), Offset(r.right - 6, r.bottom - 14),
          Paint()
            ..color = Colors.black54
            ..strokeWidth = 2);
    }
    final t = ticks.value;
    if (songMode && t >= 0) {
      final x = t / kTicksPerBar * kBarW;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..color = C.playhead
        ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_PlaylistPainter o) => o.version != version;
}

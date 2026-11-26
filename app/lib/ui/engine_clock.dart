import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:orchard_engine/orchard_engine.dart';

/// Polls the engine once per frame: playhead step and peak meters.
class EngineClock {
  EngineClock(this.engine, TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick)..start();
  }

  final OrchardEngine engine;
  late final Ticker _ticker;

  /// Current step of the playing pattern, -1 when stopped.
  final ValueNotifier<int> step = ValueNotifier(-1);
  final List<ValueNotifier<double>> levels = List.generate(kMaxChannels + 1, (_) => ValueNotifier(0));
  ValueNotifier<double> get masterLevel => levels[kMaxChannels];

  bool playing = false;

  void _tick(Duration _) {
    step.value = playing ? (engine.position / kTicksPerStep).floor() : -1;
    for (var i = 0; i <= kMaxChannels; i++) {
      final p = engine.takePeak(i);
      final l = levels[i];
      // fast attack, ~300 ms release
      l.value = p > l.value ? p : l.value * 0.88;
      if (l.value < 1e-4) l.value = 0;
    }
  }

  void dispose() => _ticker.dispose();
}

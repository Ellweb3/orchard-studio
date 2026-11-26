import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:orchard_engine/orchard_engine.dart';

/// Polls the engine once per frame: playhead step and peak meters.
class EngineClock {
  /// Own Ticker (not from a TickerProvider): route TickerMode must not mute
  /// it, the piano roll page covers the rack while it needs the playhead.
  EngineClock(this.engine) {
    _ticker = Ticker(_tick, debugLabel: 'EngineClock')..start();
  }

  final OrchardEngine engine;
  late final Ticker _ticker;

  /// Current step of the playing pattern, -1 when stopped.
  final ValueNotifier<int> step = ValueNotifier(-1);

  /// Playback position in ticks, -1 when stopped (piano roll playhead).
  final ValueNotifier<double> ticks = ValueNotifier(-1);
  final List<ValueNotifier<double>> levels = List.generate(kMaxChannels + 1, (_) => ValueNotifier(0));
  ValueNotifier<double> get masterLevel => levels[kMaxChannels];

  bool playing = false;

  void _tick(Duration _) {
    engine.collect();
    final pos = playing ? engine.position : -1.0;
    ticks.value = pos;
    step.value = playing ? (pos / kTicksPerStep).floor() : -1;
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
